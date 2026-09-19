// Refresh a NEW private database generation; original observations are immutable.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';
import {DatabaseSync,backup} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {openStrategyDatabase} from '../server/strategyDatabase.js';
import {verifiedPriceGaps} from '../server/strategyPriceGapRepair.js';
import {verifiedComparisonExtension,terminalCloseCorrection} from '../server/strategyFreshness.js';
import {signature} from '../server/investmentMath.js';
import {validateClosingObservation} from '../server/strategyClosingObservation.js';

const [sourceFile,cutoff,out,cacheDirectory]=process.argv.slice(2);
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
if(!sourceFile||!/^\d{4}-\d{2}-\d{2}$/.test(cutoff??'')||!out||fs.existsSync(out)||path.resolve(out).startsWith(root+path.sep))throw Error('Usage: source.sqlite YYYY-MM-DD NEW_PRIVATE_DIRECTORY_OUTSIDE_REPO');
process.umask(0o077);
const source=openStrategyDatabase(sourceFile),overlapStart='2026-01-01',now=new Date().toISOString();
if(cutoff<=source.meta.cutoff||cutoff>now.slice(0,10))throw Error('invalid_refresh_cutoff');
fs.mkdirSync(out,{recursive:true,mode:0o700});
const save=(name,data)=>fs.writeFileSync(path.join(out,name),typeof data==='string'?data:JSON.stringify(data,null,2),{flag:'wx',mode:0o600});
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const series=source.db.prepare(`SELECT s.*,MAX(p.date) last_date FROM price_series s JOIN price_observations p ON p.series_id=s.id GROUP BY s.id`).all();
const selected=series.filter(s=>s.storage_kind!=='raw_price_points'||s.last_date>='2026-06-01');
const yahooSymbols=[...new Set(selected.filter(s=>s.provider==='yahoo').map(s=>s.symbol))].sort();
const sharadarSymbols=[...new Set(selected.filter(s=>s.provider==='sharadar').map(s=>s.symbol))].sort();
const plan={cutoff,previousCutoff:source.meta.cutoff,sourceGeneration:source.meta.manifest_hash,overlapStart,yahooSymbols,sharadarSymbols,
 policy:'New generation: append verified daily prices; separately audit confirmed final-observation corrections; no new model/filing dates inferred',startedAt:now};
save('plan.json',plan);
const harvest=spawn('python3',[path.join(root,'scripts/fetch-strategy-sharadar.py'),path.join(out,'plan.json'),out],{stdio:['ignore','inherit','inherit']});
const harvested=new Promise((resolve,reject)=>{harvest.on('error',reject);harvest.on('exit',code=>code===0?resolve():reject(Error('sharadar_harvest_failed')));});
const downloaded=new Map(),failures=[];
async function yahoo(symbol){
 const url=`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?period1=${Date.parse(overlapStart)/1000}&period2=${Date.parse(cutoff)/1000+86400}&interval=1d&events=div%2Csplits&includeAdjustedClose=true`;
 for(let attempt=0;attempt<2;attempt++){
  try{
   const cached=cacheDirectory&&path.join(cacheDirectory,'yahoo-'+encodeURIComponent(symbol)+'.json');
   let body;
   if(cached&&fs.existsSync(cached))body=fs.readFileSync(cached,'utf8');
   else {const res=await fetch(url,{headers:{'User-Agent':'ThesisForge local research'},signal:AbortSignal.timeout(25000)});if(!res.ok)throw Error('provider_http_'+res.status);body=await res.text();}
   const payload=JSON.parse(body),c=payload.chart?.result?.[0];
   if(c?.meta?.symbol!==symbol||payload.chart?.error)throw Error('provider_identity_mismatch');
   const name='yahoo-'+encodeURIComponent(symbol)+'.json';save(name,body);
   downloaded.set(symbol,{payload,url,hash:sha(body),name});return;
  }catch(e){if(attempt===1)failures.push({symbol,provider:'yahoo',error:e.message});}
 }
}
await yahoo('SPY');
const spy=downloaded.get('SPY')?.payload.chart.result[0];
const sessions=new Set((spy?.timestamp??[]).map(t=>new Date(t*1000).toISOString().slice(0,10)).filter(d=>d<=cutoff));
if(!sessions.has(cutoff))throw Error('benchmark_target_session_unavailable');
let cursor=0,completed=0;
await Promise.all(Array.from({length:4},async()=>{
 while(cursor<yahooSymbols.length){const symbol=yahooSymbols[cursor++];if(symbol!=='SPY')await yahoo(symbol);completed++;
  if(completed%40===0)console.log(JSON.stringify({provider:'yahoo',completed,total:yahooSymbols.length,failures:failures.length}));
 }
}));
await harvested;
const paid=JSON.parse(fs.readFileSync(path.join(out,'sharadar-results.json'),'utf8'));
const sourceRows=source.db.prepare(`SELECT p.* FROM price_observations p WHERE p.series_id=? AND p.date>=? AND p.date<=? ORDER BY p.date`);
const repairs=[],processed=new Set();
const confirmations=new Map(),corrections=[];
const yahooRows=c=>{const q=c.indicators.quote[0],adj=c.indicators.adjclose?.[0]?.adjclose;return(c.timestamp??[]).map((t,i)=>({date:new Date(t*1000).toISOString().slice(0,10),close:q.close[i],adjustedClose:adj?.[i],open:q.open?.[i],high:q.high?.[i],low:q.low?.[i],volume:q.volume?.[i]})).filter(p=>p.date<=cutoff&&sessions.has(p.date)&&p.close>0);};
for(const s of selected){
 const key=[s.symbol,s.provider,s.storage_kind].join('|');if(processed.has(key))continue;processed.add(key);
 try{
  const group=series.filter(p=>p.symbol===s.symbol&&p.provider===s.provider&&p.storage_kind===s.storage_kind);
  let existing=group.flatMap(g=>sourceRows.all(g.id,overlapStart,cutoff));
  let fresh,doc,currency=s.quote_currency;
  if(s.provider==='yahoo'){
   doc=downloaded.get(s.symbol);if(!doc)throw Error('provider_download_unavailable');
   const c=doc.payload.chart.result[0],q=c.indicators.quote[0],adj=c.indicators.adjclose?.[0]?.adjclose;
   if(c.meta.currency!=='USD')throw Error('non_usd_quote_requires_separate_unit_audit');
   currency='USD';
   fresh=(c.timestamp??[]).map((t,i)=>({date:new Date(t*1000).toISOString().slice(0,10),close:q.close[i],adjustedClose:adj?.[i],open:q.open?.[i],high:q.high?.[i],low:q.low?.[i],volume:q.volume?.[i]}))
    .filter(p=>p.date<=cutoff&&sessions.has(p.date)&&p.close>0);
  }else if(s.provider==='sharadar'){
   fresh=paid.rows.filter(r=>r.ticker===s.symbol).map(r=>({date:String(r.date).slice(0,10),close:r.close,adjustedClose:r.closeadj,open:r.open,high:r.high,low:r.low,volume:r.volume})).filter(p=>p.date<=cutoff&&sessions.has(p.date));
   const content=JSON.stringify(fresh);doc={url:`sharadar:stocks/${s.symbol}/${overlapStart}/${cutoff}`,hash:sha(content),content};
   // Snapshot currency comes from the audited source, never inferred for raw-only unknown currencies.
   currency=group.find(g=>g.quote_currency)?.quote_currency??null;
  }else throw Error('unrecognized_provider');
  let verified;
  let pendingCorrections=[];
  if(s.provider==='yahoo'&&existing.some(p=>fresh.some(f=>f.date===p.date&&Math.abs(f.close-p.close)>1e-7*Math.max(1,f.close,p.close)))){
   if(!confirmations.has(s.symbol)){
    const url=doc.url.replace('query1.finance','query2.finance'),response=await fetch(url,{headers:{'User-Agent':'ThesisForge local research'},signal:AbortSignal.timeout(25000)});
    if(!response.ok)throw Error('correction_confirmation_unavailable');
    const body=await response.text(),c=JSON.parse(body).chart?.result?.[0];
    if(c?.meta?.symbol!==s.symbol||c?.meta?.currency!=='USD')throw Error('correction_confirmation_identity_mismatch');
    save('confirmed-'+encodeURIComponent(s.symbol)+'.json',body);confirmations.set(s.symbol,{rows:yahooRows(c),hash:sha(body)});
   }
   pendingCorrections=terminalCloseCorrection({existing,fresh,confirmation:confirmations.get(s.symbol).rows,minimumOverlap:s.storage_kind==='valuation_snapshot'?20:60});
   const corrected=new Set(pendingCorrections.map(r=>r.old.date));
   // Scale for adjusted-close correction is independently anchored by the rest of the history.
   const prior=existing.filter(p=>!corrected.has(p.date)),probe=s.storage_kind==='valuation_snapshot'?null:verifiedPriceGaps({symbol:s.symbol,response:doc.payload,existing:prior,sessions,start:overlapStart,end:cutoff});
   for(const c of pendingCorrections)c.fresh={...c.fresh,adjustedClose:s.storage_kind==='valuation_snapshot'?null:c.fresh.adjustedClose*probe.adjustmentScale};
   existing=existing.map(p=>{const c=pendingCorrections.find(c=>c.old.series_id===p.series_id&&c.old.date===p.date);return c?{...p,close:c.fresh.close,adjusted_close:c.fresh.adjustedClose}:p;});
  }
  if(s.storage_kind==='valuation_snapshot'){
   if(currency!=='USD')throw Error('comparison_currency_unverified');
   verified=verifiedComparisonExtension({existing,fresh,end:cutoff});
  }else if(s.provider==='yahoo')verified=verifiedPriceGaps({symbol:s.symbol,response:doc.payload,existing,sessions,start:overlapStart,end:cutoff});
  else throw Error('sharadar_raw_return_basis_requires_separate_audit');
  // A refresh must reach the requested close; stale/delisted sources are retained and disclosed.
  if(fresh.at(-1)?.date!==cutoff&&[...fresh].sort((a,b)=>a.date.localeCompare(b.date)).at(-1)?.date!==cutoff)throw Error('provider_not_current');
  const oldLast=group.map(g=>g.last_date).sort().at(-1);
  const rows=verified.rows.filter(p=>p.date>oldLast).map(validateClosingObservation).sort((a,b)=>a.date.localeCompare(b.date));
  corrections.push(...pendingCorrections.map(c=>({...c,symbol:s.symbol,kind:s.storage_kind,sourceHash:doc.hash,confirmationHash:confirmations.get(s.symbol).hash})));
  repairs.push({symbol:s.symbol,provider:s.provider,kind:s.storage_kind,currency,rows,doc,
   overlap:verified.overlap,adjustmentScale:verified.adjustmentScale??null,oldLast,last:fresh.map(r=>r.date).sort().at(-1),oldSeries:s});
 }catch(e){failures.push({symbol:s.symbol,provider:s.provider,kind:s.storage_kind,error:e.message});}
}
save('provider-audit.json',{repairs:repairs.map(({rows,doc,oldSeries,...r})=>({...r,added:rows.length,sourceHash:doc.hash})),failures,fundamentals:paid.fundamentals,providerFailures:paid.failures});
save('terminal-corrections.json',corrections);
for(const symbol of ['SPY','KMLM','DBMF'])if(!repairs.some(r=>r.symbol===symbol&&r.last===cutoff&&r.kind===(symbol==='SPY'?'raw_price_points':'cta_etf')))throw Error('mandatory_series_not_verified_'+symbol);
console.log(JSON.stringify({phase:'backup',accepted:repairs.length,failures:failures.length}));
const candidate=path.join(out,'strategy.sqlite');await backup(source.db,candidate);fs.chmodSync(candidate,0o600);
const db=new DatabaseSync(candidate);
try{
 db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
 for(const c of corrections)db.prepare('UPDATE price_observations SET open=?,high=?,low=?,close=?,adjusted_close=?,volume=?,observed_at=?,quality_status=? WHERE series_id=? AND date=?').run(c.fresh.open??null,c.fresh.high??null,c.fresh.low??null,c.fresh.close,c.fresh.adjustedClose,c.fresh.volume??null,now,'daily_close_corrected_with_audit',c.old.series_id,c.old.date);
 if(corrections.length){const content=JSON.stringify(corrections),hash=sha(content);db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(['terminal_close_corrections',hash]),'terminal_close_corrections','private:terminal-corrections.json',hash,content,now);}
 const insert=db.prepare('INSERT INTO price_observations VALUES (?,?,?,?,?,?,?,?,?,?)');
 const documents=new Set();
 for(const r of repairs.filter(r=>r.rows.length)){
  const content=r.doc.content??fs.readFileSync(path.join(out,r.doc.name),'utf8');
  if(sha(content)!==r.doc.hash)throw Error('source_hash_mismatch');
  const sourceId=signature(['market_refresh',r.doc.url,r.doc.hash]);
  if(!documents.has(sourceId)){db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(sourceId,'market_refresh',r.doc.url,r.doc.hash,content,now);documents.add(sourceId);}
  const id=signature([sourceId,r.kind,r.symbol,r.adjustmentScale]);
  const label=r.provider==='yahoo'?'audited-series:yahoo_query1_chart':'sharadar-paid-api-split-adjusted';
  db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(id,r.symbol,r.provider,label,r.kind,r.oldSeries.close_basis,
   r.kind==='valuation_snapshot'?null:'total_return_adjusted_close',r.currency,'overlap_verified',sourceId);
  if(r.kind==='cta_etf')db.prepare('INSERT INTO price_observations SELECT ?,date,open,high,low,close,adjusted_close,volume,observed_at,quality_status FROM price_observations WHERE series_id=?').run(id,r.oldSeries.id);
  for(const p of r.rows)insert.run(id,p.date,p.open??null,p.high??null,p.low??null,p.close,p.adjustedClose??null,p.volume??null,now,p.openQuarantined?'close_only_open_quarantined':'overlap_reconciled');
  if(r.kind==='cta_etf'){
   const points=db.prepare('SELECT date,close,adjusted_close adjustedClose FROM price_observations WHERE series_id=? ORDER BY date').all(id);
   db.prepare('UPDATE etf_catalog SET last_date=?,series_id=?,source_url=?,points_hash=?,downloaded_at=? WHERE symbol=?').run(r.last,id,r.doc.url,sha(JSON.stringify(points)),now,r.symbol);
  }
 }
 const counts={},tableHashes={};
 for(const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()){
  counts[table]=db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n;
  const columns=db.prepare(`PRAGMA table_info(${table})`).all(),fields=columns.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
  const order=columns.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),hash=crypto.createHash('sha256');
  for(const row of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())hash.update(JSON.stringify(row)+'\n');
  tableHashes[table]=hash.digest('hex');
 }
 const sourceCounts=JSON.parse(source.meta.source_counts_json),manifestHash=signature({cutoff,counts,sourceCounts,tableHashes,security:source.meta.security_version,actions:source.meta.action_version});
 db.prepare('UPDATE warehouse_meta SET cutoff=?,generated_at=?,manifest_hash=? WHERE id=1').run(cutoff,now,manifestHash);
 if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('foreign_key_violation');db.exec('COMMIT');
 if(db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('integrity_failed');
 db.prepare('ATTACH DATABASE ? AS original').run(path.resolve(sourceFile));
 const changedExistingRows=db.prepare(`SELECT COUNT(*) n FROM original.price_observations o LEFT JOIN main.price_observations p ON p.series_id=o.series_id AND p.date=o.date WHERE p.date IS NULL OR p.close IS NOT o.close OR p.adjusted_close IS NOT o.adjusted_close OR p.open IS NOT o.open OR p.high IS NOT o.high OR p.low IS NOT o.low OR p.volume IS NOT o.volume`).get().n;
 if(changedExistingRows!==corrections.length)throw Error('unexpected_existing_price_mutation');
 const prior=JSON.parse(fs.readFileSync(sourceFile+'.import.json','utf8')),changedTables=Object.keys(tableHashes).filter(t=>tableHashes[t]!==prior.tableHashes[t]);
 if(changedTables.some(t=>!['source_documents','price_series','price_observations','etf_catalog'].includes(t)))throw Error('unexpected_table_change');
 const report={schemaVersion:1,cutoff,counts,sourceCounts,tableHashes,manifestHash,sourceGeneration:source.meta.manifest_hash,changedTables,changedExistingRows,
  sourceWrites:source.db.prepare('SELECT total_changes() n').get().n,integrity:'ok',foreignKeys:0,acceptedSeries:repairs.length,addedRows:repairs.reduce((s,r)=>s+r.rows.length,0),failures,
  fundamentals:paid.fundamentals,financialsAndFilingsRefreshed:false};
 save('strategy.sqlite.import.json',report);save('verification.json',report);
 console.log(JSON.stringify({phase:'complete',generation:manifestHash,addedRows:report.addedRows,acceptedSeries:repairs.length,failures:failures.length,changedExistingRows}));
}finally{db.close();source.close();}
