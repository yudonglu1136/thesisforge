// Population-derived current-session gaps; source cache recovery, no rule changes.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';
import {DatabaseSync,backup} from 'node:sqlite';
import {openStrategyDatabase} from '../server/strategyDatabase.js';
import {signature} from '../server/investmentMath.js';
import {confirmedDailyRows,reconcileRecoveredSeries} from '../server/strategySourceRecovery.js';
const [sourceFile,casesFile,out,start='2016-01-01',requestedSymbols]=process.argv.slice(2);
if(!sourceFile||!casesFile||!out||fs.existsSync(out))throw Error('Usage: strategy.sqlite population-cases.jsonl NEW_PRIVATE_DIRECTORY');
process.umask(0o077);fs.mkdirSync(out,{mode:0o700});
const source=openStrategyDatabase(sourceFile),cutoff=source.meta.cutoff,now=new Date().toISOString();
if(!/^\d{4}-\d{2}-\d{2}$/.test(start)||start>=cutoff)throw Error('invalid_source_window');
const cases=fs.readFileSync(casesFile,'utf8').trim().split('\n').map(JSON.parse);
const candidates=[...new Set(cases.filter(c=>c.failure?.code==='missing_active_price'&&c.failure.date>='2026-08-28').flatMap(c=>c.failure.tickers??[]))].sort();
const symbols=requestedSymbols?requestedSymbols.split(','):candidates;
if(symbols.some(s=>!candidates.includes(s)))throw Error('symbol_not_in_population_failures');
const repairs=[],failed=[],sha=v=>crypto.createHash('sha256').update(v).digest('hex');
for(const symbol of symbols){try{
 const priceSymbol=({'BRK.A':'BRK-A','BRK.B':'BRK-B','BF.B':'BF-B'})[symbol]??symbol;
 const documents=[];
 for(const host of ['query1','query2']){
  const url=`https://${host}.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(priceSymbol)}?period1=${Date.parse(start)/1000}&period2=${Date.parse(cutoff)/1000+86400}&interval=1d&events=div%2Csplits&includeAdjustedClose=true`;
  const res=await fetch(url,{headers:{'User-Agent':'ThesisForge local research'},signal:AbortSignal.timeout(25000)});if(!res.ok)throw Error('provider_http_'+res.status);
  const content=await res.text();fs.writeFileSync(path.join(out,`${symbol}-${host}.json`),content,{flag:'wx',mode:0o600});documents.push({url,hash:sha(content),content});
 }
 const confirmed=confirmedDailyRows(...documents.map(d=>JSON.parse(d.content)),priceSymbol,start,cutoff);
 const existing=source.db.prepare(`SELECT p.*,s.source_label FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.symbol=? AND s.storage_kind='raw_price_points' AND s.provider='yahoo' AND p.date>=? AND p.date<=? ORDER BY p.date`).all(symbol,start,cutoff);
 const r=reconcileRecoveredSeries(existing,confirmed.rows,confirmed);repairs.push({...r,symbol,priceSymbol,sourceWindow:{start,end:cutoff},documents});
 console.log(JSON.stringify({symbol,rows:r.rows.length,overlap:r.overlap,corrections:r.corrections.length}));
}catch(e){failed.push({symbol,error:e.message});console.log(JSON.stringify({symbol,error:e.message}));}}
await backup(source.db,path.join(out,'strategy.sqlite'));const db=new DatabaseSync(path.join(out,'strategy.sqlite'));
try{
 db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
 for(const r of repairs){
  for(const d of r.documents)db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(['full_daily_recovery',d.url,d.hash]),'full_daily_recovery',d.url,d.hash,d.content,now);
  const proof=JSON.stringify({...r,documents:r.documents.map(({content,...d})=>d)}),sid=signature(['recovery_audit',proof]);
  db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(sid,'full_daily_recovery_audit',`private:boundary-${r.symbol}`,sha(proof),proof,now);
  for(const c of r.corrections)db.prepare('UPDATE price_observations SET open=?,high=?,low=?,close=?,adjusted_close=?,volume=?,observed_at=?,quality_status=? WHERE series_id=? AND date=?').run(c.fresh.open,c.fresh.high,c.fresh.low,c.fresh.close,c.fresh.adjustedClose,c.fresh.volume,now,c.reason,c.old.series_id,c.old.date);
  const id=signature([sid,r.symbol,'raw_price_points']);db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(id,r.symbol,'yahoo','audited-series:yahoo_query1_chart','raw_price_points','yahoo_provider_historical_close','total_return_adjusted_close','USD','full_daily_source_verified',sid);
  const insert=db.prepare('INSERT INTO price_observations VALUES (?,?,?,?,?,?,?,?,?,?)');
  for(const p of r.rows)insert.run(id,p.date,p.open,p.high,p.low,p.close,p.adjustedClose,p.volume,now,'two_responses_all_overlaps_reconciled');
 }
 const summary=JSON.parse(db.prepare("SELECT content FROM source_documents WHERE kind='market_refresh_summary' ORDER BY stored_at DESC LIMIT 1").get().content);
 summary.rawSecuritiesCurrent=db.prepare(`SELECT COUNT(DISTINCT s.symbol) n FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.storage_kind='raw_price_points' AND p.date=?`).get(cutoff).n;
 const content=JSON.stringify(summary);db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(['market_refresh_summary',content]),'market_refresh_summary','local:boundary-recovery-summary',sha(content),content,now);
 const counts={},tableHashes={};
 for(const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()){
  counts[table]=db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n;const columns=db.prepare(`PRAGMA table_info(${table})`).all(),fields=columns.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));const order=columns.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),h=crypto.createHash('sha256');for(const row of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())h.update(JSON.stringify(row)+'\n');tableHashes[table]=h.digest('hex');
 }
 const sourceCounts=JSON.parse(source.meta.source_counts_json),manifestHash=signature({cutoff,counts,sourceCounts,tableHashes,security:source.meta.security_version,actions:source.meta.action_version});
 const prior=JSON.parse(fs.readFileSync(sourceFile+'.import.json')),changedTables=Object.keys(tableHashes).filter(t=>tableHashes[t]!==prior.tableHashes[t]);if(changedTables.some(t=>!['source_documents','price_series','price_observations'].includes(t)))throw Error('protected_table_changed');
 db.prepare('UPDATE warehouse_meta SET generated_at=?,manifest_hash=? WHERE id=1').run(now,manifestHash);if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('foreign_key_violation');db.exec('COMMIT');if(db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('integrity_failed');
 const report={schemaVersion:1,cutoff,counts,sourceCounts,tableHashes,manifestHash,sourceGeneration:source.meta.manifest_hash,changedTables,integrity:'ok',foreignKeys:0,sourceWrites:source.db.prepare('SELECT total_changes() n').get().n,symbols,failed,repairs:repairs.map(({documents,rows,...r})=>({...r,added:rows.length,documents:documents.map(({content,...d})=>d)})),summary};
 fs.writeFileSync(path.join(out,'strategy.sqlite.import.json'),JSON.stringify(report,null,2),{flag:'wx',mode:0o600});console.log(JSON.stringify({phase:'complete',repaired:repairs.length,failed,generation:manifestHash}));
}finally{db.close();source.close();}
