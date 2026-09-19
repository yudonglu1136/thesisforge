// Finalize a new private release; never edit the served or source generations.
import fs from 'node:fs'; import path from 'node:path'; import crypto from 'node:crypto';
import {DatabaseSync, backup} from 'node:sqlite';
import {openStrategyDatabase} from '../server/strategyDatabase.js';
import {signature} from '../server/investmentMath.js';
import {validateClosingObservation} from '../server/strategyClosingObservation.js';
const [strategyFile,runtimeFile,out] = process.argv.slice(2);
if (!strategyFile || !runtimeFile || !out || fs.existsSync(out)) throw Error('Usage: strategy.sqlite runtime.sqlite NEW_PRIVATE_DIRECTORY');
process.umask(0o077); fs.mkdirSync(out,{mode:0o700});
const source=openStrategyDatabase(strategyFile), originalRuntime=new DatabaseSync(runtimeFile,{readOnly:true});
await backup(source.db,path.join(out,'strategy.sqlite')); await backup(originalRuntime,path.join(out,'runtime.sqlite'));
const db=new DatabaseSync(path.join(out,'strategy.sqlite')), runtime=new DatabaseSync(path.join(out,'runtime.sqlite'));
const now=new Date().toISOString(),cutoff=source.meta.cutoff;
try {
  const anomalies=db.prepare(`SELECT s.symbol,s.storage_kind,p.* FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE p.date>'2026-08-28' AND p.date<=? AND p.open IS NOT NULL AND (p.open<p.low OR p.open>p.high OR p.open<=0)`).all(cutoff);
  db.exec('BEGIN IMMEDIATE'); runtime.exec('BEGIN IMMEDIATE');
  for(const row of anomalies) {
    const checked=validateClosingObservation(row); if(!checked.openQuarantined)throw Error('unexpected_valid_open');
    db.prepare("UPDATE price_observations SET open=NULL,quality_status='close_only_open_quarantined' WHERE series_id=? AND date=?").run(row.series_id,row.date);
    if(row.storage_kind==='raw_price_points')runtime.prepare('UPDATE price_points SET open=NULL WHERE symbol=? AND date=? AND open=? AND close=?').run(row.symbol,row.date,row.open,row.close);
    const snapshot=runtime.prepare('SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?').get(row.symbol);
    if(snapshot){const p=JSON.parse(snapshot.payload_json);let changed=false;for(const point of p.priceHistory??[])if(point.date===row.date&&point.open===row.open&&point.close===row.close){point.open=null;point.openQuality='quarantined_source_range_conflict';changed=true;}if(changed)runtime.prepare('UPDATE valuation_ticker_snapshots SET payload_json=? WHERE ticker=?').run(JSON.stringify(p),row.symbol);}
  }
  const proof={cutoff,anomalies,policy:'Open unavailable when outside source range; raw response retained. Closing/adjusted prices unchanged. Not a verified OHLC bar.'},content=JSON.stringify(proof);
  db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run(signature(proof),'open_field_quarantine','local:open-field-quarantine',signature(content),content,now);
  const counts={},tableHashes={};
  for(const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()) {
    counts[table]=db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n;
    const cols=db.prepare(`PRAGMA table_info(${table})`).all(), fields=cols.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
    const order=cols.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),h=crypto.createHash('sha256');
    for(const row of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())h.update(JSON.stringify(row)+'\n'); tableHashes[table]=h.digest('hex');
  }
  const sourceCounts=JSON.parse(source.meta.source_counts_json),manifestHash=signature({cutoff,counts,sourceCounts,tableHashes,security:source.meta.security_version,actions:source.meta.action_version});
  const prior=JSON.parse(fs.readFileSync(strategyFile+'.import.json'));
  for(const table of Object.keys(tableHashes))if(!['source_documents','price_observations'].includes(table)&&tableHashes[table]!==prior.tableHashes[table])throw Error('protected_table_changed');
  db.prepare('UPDATE warehouse_meta SET generated_at=?,manifest_hash=? WHERE id=1').run(now,manifestHash);
  db.prepare('ATTACH DATABASE ? AS original').run(path.resolve(strategyFile));
  const columns='series_id,date,close,adjusted_close';
  if(db.prepare(`SELECT COUNT(*) n FROM (SELECT ${columns} FROM main.price_observations EXCEPT SELECT ${columns} FROM original.price_observations)`).get().n)throw Error('closing_price_changed');
  if(db.prepare('PRAGMA foreign_key_check').all().length)throw Error('foreign_key_error');db.exec('COMMIT');runtime.exec('COMMIT');
  for(const d of [db,runtime])if(d.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('integrity_error');
  const report={schemaVersion:1,cutoff,counts,sourceCounts,tableHashes,manifestHash,sourceGeneration:source.meta.manifest_hash,integrity:'ok',foreignKeys:0,sourceWrites:0,closingPricesChanged:0,openFieldsQuarantined:anomalies.length,summary:prior.summary,policy:proof.policy};
  fs.writeFileSync(path.join(out,'strategy.sqlite.import.json'),JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
  console.log(JSON.stringify({generation:manifestHash,quarantined:anomalies.length,closingPricesChanged:0,integrity:'ok'}));
}finally{db.close();runtime.close();source.close();originalRuntime.close();}
