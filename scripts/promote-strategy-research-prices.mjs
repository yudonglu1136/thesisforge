// New local generations only. Preserve dated financial/model/Guru inputs.
// A newer daily quote may use a different explicitly named vendor, but this
// never rewrites an old vendor's history or calls their adjustment bases equal.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync,backup} from 'node:sqlite';
import {signature} from '../server/investmentMath.js';
import {openStrategyDatabase} from '../server/strategyDatabase.js';
const [strategyFile,runtimeFile,out,filingAuditFile]=process.argv.slice(2);
if(!strategyFile||!runtimeFile||!out||fs.existsSync(out))throw Error('Usage: strategy.sqlite runtime.sqlite NEW_PRIVATE_DIRECTORY');
process.umask(0o077);fs.mkdirSync(out,{mode:0o700});
const save=(name,data)=>fs.writeFileSync(path.join(out,name),JSON.stringify(data,null,2),{flag:'wx',mode:0o600});
const original=openStrategyDatabase(strategyFile),cutoff=original.meta.cutoff,now=new Date().toISOString();
const filingAudit=filingAuditFile?JSON.parse(fs.readFileSync(filingAuditFile,'utf8')):null;
const filingCheck=filingAudit?.cutoff===cutoff&&filingAudit.managers?.length>0&&filingAudit.managers.every(m=>m.filers?.length>0&&m.filers.every(f=>!f.error));
const newHoldingFilings=filingCheck?filingAudit.managers.flatMap(m=>m.unimported??[]).filter(f=>/^13F-HR/.test(f.form)).length:null;
const runtimeOriginal=new DatabaseSync(runtimeFile,{readOnly:true});
await backup(original.db,path.join(out,'strategy.sqlite'));
await backup(runtimeOriginal,path.join(out,'runtime.sqlite'));
const db=new DatabaseSync(path.join(out,'strategy.sqlite')),runtime=new DatabaseSync(path.join(out,'runtime.sqlite'));
const supplements=[];
try{
 db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
 for(const {symbol,currency,last} of db.prepare(`SELECT s.symbol,s.quote_currency currency,MAX(p.date) last FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.storage_kind='valuation_snapshot' GROUP BY s.symbol HAVING COUNT(DISTINCT s.quote_currency)=1`).all()){
  if(currency!=='USD'||last>=cutoff)continue;
  // Verified fresh USD observations only, with exact security identity and
  // document hash inherited from the market refresh. Unknown units fail closed.
  const source=db.prepare(`SELECT s.* FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.symbol=? AND s.storage_kind='raw_price_points' AND s.provider='yahoo' AND s.quote_currency='USD' AND s.status='overlap_verified' AND p.date=? LIMIT 1`).get(symbol,cutoff);
  if(!source)continue;
  const rows=db.prepare('SELECT * FROM price_observations WHERE series_id=? AND date>? AND date<=? ORDER BY date').all(source.id,last,cutoff);
  if(!rows.length||rows.at(-1).date!==cutoff)continue;
  const id=signature(['new_dated_comparison_quotes',source.id,last,cutoff]);
  db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(id,symbol,'yahoo',source.source_label,'valuation_snapshot',source.close_basis,null,'USD','dated_provider_quote',source.source_id);
  db.prepare('INSERT INTO price_observations SELECT ?,date,open,high,low,close,NULL,volume,observed_at,quality_status FROM price_observations WHERE series_id=? AND date>? AND date<=?').run(id,source.id,last,cutoff);
  supplements.push({symbol,previousPriceDate:last,last:cutoff,rows:rows.length,sourceId:source.source_id,source:'yahoo',policy:'new_dated_quote_only; prior_vendor_history_unchanged'});
 }
 const rawCount=db.prepare(`SELECT COUNT(DISTINCT s.symbol) n FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.storage_kind='raw_price_points' AND p.date=?`).get(cutoff).n;
 const comparisonCount=db.prepare(`SELECT COUNT(DISTINCT s.symbol) n FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.storage_kind='valuation_snapshot' AND p.date=?`).get(cutoff).n;
 const summary={cutoff,rawSecuritiesCurrent:rawCount,comparisonSecuritiesCurrent:comparisonCount,ctaCurrent:['KMLM','DBMF'],
  fundamentals:{status:'not_refreshed',reason:'provider_subscription_required'},filings:{status:filingCheck?'official_directories_checked':'not_checked',newHoldingsFilings:newHoldingFilings,checkedThrough:filingCheck?cutoff:null,auditHash:filingCheck?signature(filingAudit):null},
  policy:'Dates are actual observations. Older filings/models are not restamped; coverage does not imply every security or every backtest is ready.'};
 const content=JSON.stringify(summary),hash=signature(summary);
 db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(['market_refresh_summary',hash]),'market_refresh_summary','local:market-refresh-summary',hash,content,now);
 const counts={},tableHashes={};
 for(const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()){
  counts[table]=db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n;
  const columns=db.prepare(`PRAGMA table_info(${table})`).all(),fields=columns.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
  const order=columns.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),h=crypto.createHash('sha256');
  for(const row of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())h.update(JSON.stringify(row)+'\n');
  tableHashes[table]=h.digest('hex');
 }
 const sourceCounts=JSON.parse(original.meta.source_counts_json),manifestHash=signature({cutoff,counts,sourceCounts,tableHashes,security:original.meta.security_version,actions:original.meta.action_version});
 db.prepare('UPDATE warehouse_meta SET generated_at=?,manifest_hash=? WHERE id=1').run(now,manifestHash);
 if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('strategy_foreign_key_violation');db.exec('COMMIT');
 console.log(JSON.stringify({phase:'strategy',...summary}));

 runtime.exec('BEGIN IMMEDIATE');
 const correctionKinds=['daily_close_corrected_with_audit','confirmed_terminal_daily_close','confirmed_recent_dividend_vintage'];
 const rawRows=db.prepare(`SELECT s.symbol,s.source_label source,p.* FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.storage_kind='raw_price_points' AND (s.status IN ('overlap_verified','full_daily_source_verified') OR p.quality_status IN (?,?,?)) AND p.date<=? ORDER BY s.symbol,p.date`).all(...correctionKinds,cutoff);
 const insert=runtime.prepare('INSERT INTO price_points(symbol,date,open,high,low,close,adjusted_close,volume,source,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(symbol,date) DO NOTHING');
 const select=runtime.prepare('SELECT * FROM price_points WHERE symbol=? AND date=?');
 const update=runtime.prepare('UPDATE price_points SET open=?,high=?,low=?,close=?,adjusted_close=?,volume=?,source=?,updated_at=? WHERE symbol=? AND date=?');
 let inserted=0,corrected=0,snapshots=0;const conflicts=[];
 for(const p of rawRows){
  const old=select.get(p.symbol,p.date);
  if(!old)inserted+=Number(insert.run(p.symbol,p.date,p.open,p.high,p.low,p.close,p.adjusted_close,p.volume,p.source,p.observed_at).changes);
  else if(correctionKinds.includes(p.quality_status)){
   update.run(p.open,p.high,p.low,p.close,p.adjusted_close,p.volume,p.source,p.observed_at,p.symbol,p.date);corrected++;
  }else if(old.close!==p.close||old.adjusted_close!==p.adjusted_close)conflicts.push({symbol:p.symbol,date:p.date,reason:'retained_existing_runtime_observation'});
 }
 for(const row of runtime.prepare('SELECT ticker,payload_json FROM valuation_ticker_snapshots ORDER BY ticker').all()){
  const snap=JSON.parse(row.payload_json);if(snap.currency!=='USD')continue;
  const existing=new Map((snap.priceHistory??[]).map(p=>[p.date,p])),last=[...existing.keys()].sort().at(-1);
  const rows=db.prepare(`SELECT p.*,s.source_label source FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.symbol=? AND s.storage_kind='valuation_snapshot' AND s.quote_currency='USD' AND (p.date>? OR p.quality_status='daily_close_corrected_with_audit') AND p.date<=? ORDER BY p.date`).all(row.ticker,last??'',cutoff);
  if(!rows.length)continue;
  for(const p of rows)existing.set(p.date,{date:p.date,open:p.open,high:p.high,low:p.low,close:p.close,volume:p.volume,source:p.source});
  snap.priceHistory=[...existing.values()].sort((a,b)=>a.date.localeCompare(b.date));
  snap.marketDataRefresh={cutoff,priceDate:snap.priceHistory.at(-1).date,refreshedAt:now,generation:manifestHash,modelInputsChanged:false};
  runtime.prepare('UPDATE valuation_ticker_snapshots SET generated_at=?,payload_json=? WHERE ticker=?').run(now,JSON.stringify(snap),row.ticker);snapshots++;
 }
 runtime.exec('COMMIT');
 // Each model/source table remains byte-for-byte identical at the row level.
 runtime.prepare('ATTACH DATABASE ? AS original').run(path.resolve(runtimeFile));
 const protectedTables=['valuation_pit_financials','valuation_pit_guidance','valuation_pit_model_runs','valuation_pit_price_observations','guru_exposure_snapshots','guru_backtests','guru_backtest_proxies'];
 const protectedAudit=[];
 for(const table of protectedTables){
  if(!runtime.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(table))continue;
  const changed=runtime.prepare(`SELECT COUNT(*) n FROM (SELECT * FROM main.${table} EXCEPT SELECT * FROM original.${table})`).get().n;
  const removed=runtime.prepare(`SELECT COUNT(*) n FROM (SELECT * FROM original.${table} EXCEPT SELECT * FROM main.${table})`).get().n;
  if(changed||removed)throw Error('protected_table_changed_'+table);protectedAudit.push({table,changed,removed});
 }
 for(const [label,d] of [['strategy',db],['runtime',runtime]])if(d.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error(label+'_integrity_failed');
 const report={schemaVersion:1,cutoff,counts,sourceCounts,tableHashes,manifestHash,sourceGeneration:original.meta.manifest_hash,sourceWrites:original.db.prepare('SELECT total_changes() n').get().n,
  integrity:'ok',foreignKeys:0,summary,supplements,runtime:{inserted,corrected,snapshots,conflicts,protectedAudit,sourceWrites:runtimeOriginal.prepare('SELECT total_changes() n').get().n}};
 save('strategy.sqlite.import.json',report);save('verification.json',report);
 console.log(JSON.stringify({phase:'complete',generation:manifestHash,comparisonCount,runtime:report.runtime}));
}finally{db.close();runtime.close();original.close();runtimeOriginal.close();}
