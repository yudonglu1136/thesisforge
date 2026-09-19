// Current quotes only; vendor-specific historical valuation evidence is immutable.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync,backup} from 'node:sqlite';
import {signature} from '../server/investmentMath.js';
import {openStrategyDatabase} from '../server/strategyDatabase.js';
import {validateClosingObservation} from '../server/strategyClosingObservation.js';
const [input,out]=process.argv.slice(2);
if(!input||!out||fs.existsSync(out))throw Error('Usage: completed-private-release NEW_PRIVATE_DIRECTORY');
process.umask(0o077);fs.mkdirSync(out,{mode:0o700});
const source=openStrategyDatabase(path.join(input,'strategy.sqlite')),cutoff=source.meta.cutoff,now=new Date().toISOString();
const candidates=source.db.prepare(`SELECT s.symbol,MAX(p.date) last FROM price_series s JOIN price_observations p ON s.id=p.series_id WHERE s.storage_kind='valuation_snapshot' AND s.quote_currency='USD' GROUP BY s.symbol HAVING last<?`).all(cutoff);
const accepted=[],failed=[],sha=s=>crypto.createHash('sha256').update(s).digest('hex');
let cursor=0;
await Promise.all(Array.from({length:4},async()=>{
 while(cursor<candidates.length){const candidate=candidates[cursor++];
  try{
   if(Date.parse(cutoff)-Date.parse(candidate.last)>31*86400000)throw Error('stale_identity_anchor');
   // Exact known share-class price symbols; no fuzzy ticker mapping.
   const symbol=({'BRK.B':'BRK-B','BF.B':'BF-B'})[candidate.symbol]??candidate.symbol;
   const url=`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?period1=${Date.parse(candidate.last)/1000}&period2=${Date.parse(cutoff)/1000+86400}&interval=1d&events=div%2Csplits&includeAdjustedClose=true`;
   const res=await fetch(url,{headers:{'User-Agent':'ThesisForge local research'},signal:AbortSignal.timeout(20000)});
   if(!res.ok)throw Error('provider_http_'+res.status);
   const content=await res.text(),c=JSON.parse(content).chart?.result?.[0];
   if(c?.meta?.symbol!==symbol||c.meta.currency!=='USD'||!['EQUITY','ETF'].includes(c.meta.instrumentType))throw Error('identity_or_unit_unverified');
   if(Object.values(c.events?.splits??{}).some(s=>s.date*1000>Date.parse(candidate.last)))throw Error('intervening_split_requires_model_review');
   const q=c.indicators?.quote?.[0],rows=(c.timestamp??[]).map((t,i)=>({date:new Date(t*1000).toISOString().slice(0,10),open:q.open[i],high:q.high[i],low:q.low[i],close:q.close[i],volume:q.volume[i]})).filter(p=>p.date>candidate.last&&p.date<=cutoff).map(validateClosingObservation);
   if(rows.at(-1)?.date!==cutoff||new Set(rows.map(p=>p.date)).size!==rows.length)throw Error('latest_session_unavailable');
   const filename=encodeURIComponent(candidate.symbol)+'.json';fs.writeFileSync(path.join(out,filename),content,{flag:'wx',mode:0o600});
   accepted.push({...candidate,priceSymbol:symbol,url,content,hash:sha(content),rows});
  }catch(e){failed.push({...candidate,error:e.message});}
  if((accepted.length+failed.length)%40===0)console.log(JSON.stringify({checked:accepted.length+failed.length,total:candidates.length,accepted:accepted.length,failed:failed.length}));
 }
}));
await backup(source.db,path.join(out,'strategy.sqlite'));
const runtimeOriginal=new DatabaseSync(path.join(input,'runtime.sqlite'),{readOnly:true});
await backup(runtimeOriginal,path.join(out,'runtime.sqlite'));
const db=new DatabaseSync(path.join(out,'strategy.sqlite')),runtime=new DatabaseSync(path.join(out,'runtime.sqlite'));
try{
 db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');runtime.exec('BEGIN IMMEDIATE');
 for(const r of accepted){
  const sid=signature(['current_comparison_quote',r.url,r.hash]);
  db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(sid,'current_comparison_quote',r.url,r.hash,r.content,now);
  const id=signature([sid,r.symbol,'valuation_snapshot']);
  db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(id,r.symbol,'yahoo','audited-series:yahoo_query1_chart','valuation_snapshot','yahoo_provider_historical_close',null,'USD','current_quote_identity_verified',sid);
  const insert=db.prepare('INSERT INTO price_observations VALUES (?,?,?,?,?,?,?,?,?,?)');
  for(const p of r.rows)insert.run(id,p.date,p.open,p.high,p.low,p.close,null,p.volume,now,p.openQuarantined?'close_only_open_quarantined':'provider_daily_close');
  const old=runtime.prepare('SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?').get(r.symbol);
  if(old){const snap=JSON.parse(old.payload_json);if(snap.currency!=='USD')throw Error('runtime_currency_mismatch');
   const prices=new Map((snap.priceHistory??[]).map(p=>[p.date,p]));
   for(const p of r.rows){if(prices.has(p.date))throw Error('new_quote_would_overwrite_history');prices.set(p.date,{...p,source:'audited-series:yahoo_query1_chart'});}
   snap.priceHistory=[...prices.values()].sort((a,b)=>a.date.localeCompare(b.date));
   snap.marketDataRefresh={cutoff,priceDate:cutoff,refreshedAt:now,source:'yahoo',priceSymbol:r.priceSymbol,modelInputsChanged:false};
   runtime.prepare('UPDATE valuation_ticker_snapshots SET generated_at=?,payload_json=? WHERE ticker=?').run(now,JSON.stringify(snap),r.symbol);
  }
 }
 const summary=JSON.parse(db.prepare("SELECT content FROM source_documents WHERE kind='market_refresh_summary' ORDER BY stored_at DESC LIMIT 1").get().content);
 summary.comparisonSecuritiesCurrent=db.prepare(`SELECT COUNT(DISTINCT s.symbol) n FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.storage_kind='valuation_snapshot' AND p.date=?`).get(cutoff).n;
 summary.comparisonQuoteFailures=failed.map(({symbol,error})=>({symbol,error}));
 const content=JSON.stringify(summary);db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(['market_refresh_summary',content]),'market_refresh_summary','local:current-comparison-quote-summary',sha(content),content,now);
 const counts={},tableHashes={};
 for(const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()){
  counts[table]=db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n;
  const columns=db.prepare(`PRAGMA table_info(${table})`).all(),fields=columns.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
  const order=columns.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),h=crypto.createHash('sha256');
  for(const row of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())h.update(JSON.stringify(row)+'\n');tableHashes[table]=h.digest('hex');
 }
 const sourceCounts=JSON.parse(source.meta.source_counts_json),manifestHash=signature({cutoff,counts,sourceCounts,tableHashes,security:source.meta.security_version,actions:source.meta.action_version});
 const prior=JSON.parse(fs.readFileSync(path.join(input,'strategy.sqlite.import.json'))),changedTables=Object.keys(tableHashes).filter(t=>tableHashes[t]!==prior.tableHashes[t]);
 if(changedTables.some(t=>!['source_documents','price_series','price_observations'].includes(t)))throw Error('protected_strategy_table_changed');
 db.prepare('UPDATE warehouse_meta SET generated_at=?,manifest_hash=? WHERE id=1').run(now,manifestHash);
 if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('foreign_key_violation');
 db.exec('COMMIT');runtime.exec('COMMIT');
 for(const d of [db,runtime])if(d.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('integrity_failed');
 const report={schemaVersion:1,cutoff,counts,sourceCounts,tableHashes,manifestHash,sourceGeneration:source.meta.manifest_hash,integrity:'ok',foreignKeys:0,sourceWrites:source.db.prepare('SELECT total_changes() n').get().n,
  summary,changedTables,accepted:accepted.map(({content,rows,...r})=>({...r,rows:rows.length})),failed,protectedInputsUnchanged:true,runtimeOriginalWrites:runtimeOriginal.prepare('SELECT total_changes() n').get().n};
 for(const name of ['strategy.sqlite.import.json','verification.json'])fs.writeFileSync(path.join(out,name),JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
 console.log(JSON.stringify({phase:'complete',accepted:accepted.length,failed,summary,generation:manifestHash}));
}finally{db.close();runtime.close();source.close();runtimeOriginal.close();}
