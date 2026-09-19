// New local generation only; no canonical/production writes, no price overwrite.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync,backup} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {verifiedPriceGaps} from '../server/strategyPriceGapRepair.js';
import {signature} from '../server/investmentMath.js';
import {openStrategyDatabase} from '../server/strategyDatabase.js';

const [sourceFile,casesFile,out]=process.argv.slice(2);
if(!sourceFile||!casesFile||!out||fs.existsSync(out))throw Error('Usage: strategy.sqlite cases.jsonl NEW_PRIVATE_OUTPUT_DIRECTORY');
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
if(path.resolve(out).startsWith(root+path.sep))throw Error('Use a private output directory outside the repository');
const source=openStrategyDatabase(sourceFile),cutoff=source.meta.cutoff,start='2016-07-01';
const cases=fs.readFileSync(casesFile,'utf8').trim().split('\n').map(JSON.parse);
const symbols=[...new Set(cases.flatMap(r=>r.failure?.tickers??[r.failure?.ticker])
  .filter(t=>/^[A-Z]{1,5}$/.test(t??'')&&!['SPY','KMLM','DBMF'].includes(t)))].sort();
fs.mkdirSync(out,{recursive:true,mode:0o700});
const save=(name,data)=>fs.writeFileSync(path.join(out,name),typeof data==='string'?data:JSON.stringify(data,null,2),{flag:'wx',mode:0o600});
const now=new Date().toISOString(),sha=x=>crypto.createHash('sha256').update(x).digest('hex');
save('plan.json',{sourceGeneration:source.meta.manifest_hash,start,cutoff,symbols,policy:'append_verified_provider_observations_only; every_overlap_reconciled; no_existing_row_changes',startedAt:now});
const dates=source.db.prepare(`SELECT DISTINCT p.date FROM price_observations p JOIN price_series s ON s.id=p.series_id
  WHERE s.symbol='SPY' AND s.storage_kind='raw_price_points' AND p.date BETWEEN ? AND ? ORDER BY p.date`).all(start,cutoff).map(r=>r.date);
const select=source.db.prepare(`SELECT p.* FROM price_observations p JOIN price_series s ON s.id=p.series_id
  WHERE s.symbol=? AND s.storage_kind='raw_price_points' AND p.date BETWEEN ? AND ? ORDER BY p.date,s.id`);
const repairs=[],failures=[];
try {
  for(const symbol of symbols) {
    try {
      const url=`https://query1.finance.yahoo.com/v8/finance/chart/${symbol}?period1=${Date.parse(start)/1000}&period2=${Date.parse(cutoff)/1000+86400}&interval=1d&events=div%2Csplits`;
      const response=await fetch(url,{headers:{'User-Agent':'Mozilla/5.0'},signal:AbortSignal.timeout(25000)});
      if(!response.ok)throw Error('provider_http_'+response.status);
      const body=await response.text();save(symbol+'.json',body);
      const result=verifiedPriceGaps({symbol,response:JSON.parse(body),existing:select.all(symbol,start,cutoff),sessions:new Set(dates),start,end:cutoff});
      repairs.push({...result,url,sourceHash:sha(body)});console.log(JSON.stringify({symbol,added:result.rows.length,overlap:result.overlap,remaining:result.remainingMissing.length}));
    } catch(e){failures.push({symbol,error:e.message});console.log(JSON.stringify({symbol,error:e.message}));}
  }
  save('provider-audit.json',{repairs:repairs.map(({rows,...r})=>({...r,added:rows.length})),failures});
  if(!repairs.some(r=>r.rows.length))throw Error('no_verified_gaps_recovered');
  const candidate=path.join(out,'strategy.sqlite');
  await backup(source.db,candidate);fs.chmodSync(candidate,0o600);
  const db=new DatabaseSync(candidate);
  try {
    db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
    for(const r of repairs.filter(r=>r.rows.length)) {
      const content=fs.readFileSync(path.join(out,r.symbol+'.json'),'utf8');
      if(sha(content)!==r.sourceHash)throw Error('source_hash_mismatch');
      const sourceId=signature(['verified_yahoo_gap_repair',r.url,r.sourceHash]);
      db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(sourceId,'verified_yahoo_gap_repair',r.url,r.sourceHash,content,now);
      const id=signature([sourceId,r.symbol,r.adjustmentScale]);
      db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(id,r.symbol,'yahoo','audited-gap:yahoo_chart','raw_price_points','provider_split_adjusted','total_return_adjusted_close','USD','verified',sourceId);
      const insert=db.prepare('INSERT INTO price_observations VALUES (?,?,?,?,?,?,?,?,?,?)');
      for(const p of r.rows)insert.run(id,p.date,p.open,p.high,p.low,p.close,p.adjustedClose,p.volume,now,'overlap_reconciled');
    }
    const counts={},tableHashes={};
    for(const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()) {
      counts[table]=db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n;
      const columns=db.prepare(`PRAGMA table_info(${table})`).all();
      const fields=columns.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
      const order=columns.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),hash=crypto.createHash('sha256');
      for(const row of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())hash.update(JSON.stringify(row)+'\n');
      tableHashes[table]=hash.digest('hex');
    }
    const sourceCounts=JSON.parse(source.meta.source_counts_json);
    const manifestHash=signature({cutoff,counts,sourceCounts,tableHashes,security:source.meta.security_version,actions:source.meta.action_version});
    db.prepare('UPDATE warehouse_meta SET manifest_hash=?,generated_at=? WHERE id=1').run(manifestHash,now);
    if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('foreign_key_violation');
    db.exec('COMMIT');
    if(db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('integrity_failed');
    const prior=JSON.parse(fs.readFileSync(sourceFile+'.import.json','utf8'));
    const changedTables=Object.keys(tableHashes).filter(t=>tableHashes[t]!==prior.tableHashes[t]);
    if(changedTables.some(t=>!['source_documents','price_series','price_observations'].includes(t)))throw Error('unexpected_table_change');
    db.prepare('ATTACH DATABASE ? AS original').run(path.resolve(sourceFile));
    const changedExistingRows=db.prepare(`SELECT COUNT(*) n FROM original.price_observations o LEFT JOIN main.price_observations p ON p.series_id=o.series_id AND p.date=o.date
      WHERE p.date IS NULL OR p.close IS NOT o.close OR p.adjusted_close IS NOT o.adjusted_close OR p.open IS NOT o.open OR p.high IS NOT o.high OR p.low IS NOT o.low OR p.volume IS NOT o.volume`).get().n;
    if(changedExistingRows)throw Error('existing_price_mutated');
    const report={schemaVersion:1,cutoff,counts,sourceCounts,tableHashes,manifestHash,sourceWrites:source.db.prepare('SELECT total_changes() n').get().n,
      sourceGeneration:source.meta.manifest_hash,changedTables,changedExistingRows,integrity:'ok',foreignKeys:0,
      addedRows:repairs.reduce((s,r)=>s+r.rows.length,0),repairedSymbols:repairs.filter(r=>r.rows.length).map(r=>r.symbol),failures};
    save('strategy.sqlite.import.json',report);save('verification.json',report);
    console.log(JSON.stringify({generation:manifestHash,addedRows:report.addedRows,symbols:report.repairedSymbols,changedTables,changedExistingRows}));
  } finally {db.close();}
} finally {source.close();}
