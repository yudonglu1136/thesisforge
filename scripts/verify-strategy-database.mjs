import fs from 'node:fs';
import {openStrategyDatabase,storedStrategyCatalog,loadStoredStrategyData} from '../server/strategyDatabase.js';
import {strategyComparisonPrices,strategyActionFor} from '../server/strategyLabSource.js';
const [file,sourceFile,previousReport,output]=process.argv.slice(2);
if(!file||!sourceFile||!fs.existsSync(sourceFile))throw Error('Usage: node scripts/verify-strategy-database.mjs warehouse.sqlite original.sqlite [previous-import.json] [new-verification.json]');
const {db,meta,close}=openStrategyDatabase(file);
try {
 db.prepare('ATTACH DATABASE ? AS original').run(sourceFile);
 const sourceCounts=JSON.parse(meta.source_counts_json),checks={};
 const rawCount=db.prepare("SELECT count(*) n FROM price_observations p JOIN price_series s ON s.id=p.series_id WHERE s.storage_kind='raw_price_points'").get().n;
 checks.rawPriceCount=rawCount===sourceCounts.price_points;
 checks.rawPricesUnchanged=db.prepare(`SELECT count(*) n FROM original.price_points o
  LEFT JOIN price_series s ON s.symbol=o.symbol AND s.source_label=COALESCE(o.source,'unknown') AND s.storage_kind='raw_price_points'
  LEFT JOIN price_observations p ON p.series_id=s.id AND p.date=o.date
  WHERE p.series_id IS NULL OR p.close IS NOT o.close OR p.adjusted_close IS NOT o.adjusted_close
   OR p.open IS NOT o.open OR p.high IS NOT o.high OR p.low IS NOT o.low OR p.volume IS NOT o.volume`).get().n===0;
 checks.financialsUnchanged=db.prepare(`SELECT count(*) n FROM original.valuation_pit_financials o LEFT JOIN financial_records r
  ON r.ticker=o.ticker AND r.fiscal_period=o.fiscal_period AND r.dimension=o.dimension
  WHERE r.id IS NULL OR r.raw_payload_json IS NOT o.payload_json OR r.available_at IS NOT o.available_at OR r.currency IS NOT o.currency`).get().n===0;
 checks.guidanceUnchanged=db.prepare(`SELECT count(*) n FROM original.valuation_pit_guidance o LEFT JOIN guidance_events r
  ON r.source_database=o.source_database AND r.source_event_id=o.source_id
  WHERE r.id IS NULL OR r.raw_payload_json IS NOT o.payload_json OR r.amount IS NOT o.amount OR r.observed_at IS NOT o.observed_at`).get().n===0;
 checks.modelsUnchanged=db.prepare(`SELECT count(*) n FROM original.valuation_pit_model_runs o LEFT JOIN valuation_nodes r
  ON r.ticker=o.ticker AND r.fiscal_period=o.fiscal_period AND r.model_version=o.model_version
  WHERE r.id IS NULL OR r.input_json IS NOT o.input_json OR r.output_json IS NOT o.output_json OR r.fair_value IS NOT json_extract(o.output_json,'$.fairValue')`).get().n===0;
 checks.integrity=db.prepare('PRAGMA main.integrity_check').get().integrity_check==='ok';
 checks.foreignKeys=db.prepare('PRAGMA main.foreign_key_check').all().length===0;
 checks.readOnly=db.prepare('PRAGMA query_only').get().query_only===1;
 checks.zeroSourceWrites=db.prepare('SELECT total_changes() n').get().n===0;
 const report=JSON.parse(fs.readFileSync(file+'.import.json','utf8'));
 if(previousReport) {
  const before=JSON.parse(fs.readFileSync(previousReport,'utf8'));
  checks.repeatManifest=before.manifestHash===report.manifestHash;
  checks.repeatTableHashes=JSON.stringify(before.tableHashes)===JSON.stringify(report.tableHashes);
 }
 const catalog=storedStrategyCatalog(file,meta.cutoff);
 checks.knownManagerQuarantined=catalog.managers.find(g=>g.id==='chamath-palihapitiya')?.identityStatus==='blocked';
 const rules={managers:['bill-ackman','chamath-palihapitiya','chris-hohn'],start:'2021-08-28',end:meta.cutoff,valuationEnabled:true};
 const data=loadStoredStrategyData(file,rules,{comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
 checks.databaseReader=data.sources.adapter==='strategy-structured-sqlite-v1';
 const dates=data.dates.filter(d=>d>=rules.start);
 checks.ctaComplete=['KMLM','DBMF'].every(t=>dates.every(d=>data.priceMaps.get(t)?.get(d)>0));
 const result={status:Object.values(checks).every(Boolean)?'pass':'fail',scope:'storage_integrity_and_reader_not_strategy_release',checks,
  schemaVersion:meta.schema_version,manifestHash:meta.manifest_hash,counts:report.counts,issues:report.issues,ctaSessions:dates.length};
 console.log(JSON.stringify(result,null,2));
 if(output)fs.writeFileSync(output,JSON.stringify(result,null,2),{flag:'wx',mode:0o600});
 if(result.status!=='pass')process.exitCode=1;
}finally{close();}
