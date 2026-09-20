import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {claimClassification,immutableInsert,importStrategyDatabase,parseDocumentRows} from './strategyDatabaseImport.js';
import {openStrategyDatabase,loadStoredStrategyData,storedStrategyCatalog,strategyMarketHoldings} from './strategyDatabase.js';
import {strategyComparisonPrices,strategyActionFor} from './strategyLabSource.js';
import {selectedBook} from './strategyLab.js';
import {signature} from './investmentMath.js';
const sha=v=>crypto.createHash('sha256').update(v).digest('hex');
test('market loading preserves every Top 1–10 claim without loading the full unselected book',()=>{
 const holdings=Array.from({length:5000},(_,i)=>({cusip:'FIXTURE'+i,ticker:'T'+i,priceSymbol:'T'+i,value:5000-i,identityResolved:i!==1}));
 // A split claim outside the first ten rows becomes rank one after aggregation.
 holdings.push({...holdings[100],value:6000});
 const f={complete:true,holdings},histories=new Map([['g',[f]]]);
 const selected=strategyMarketHoldings(histories);
 assert.equal(selected.length,10);assert.equal(selected[0].ticker,'T100');
 assert.ok(selected.some(h=>h.identityResolved===false),'unresolved top claims must not disappear');
 for(let n=1;n<=10;n++)assert.deepEqual(selectedBook(f,n).holdings,selected.slice(0,n));
 assert.equal(f.holdings.length,5001,'source evidence must stay intact');
 const future={...f,holdings:[{cusip:'NEXT',ticker:'NEXT',value:1}]};
 histories.get('g').push(future);
 assert.ok(strategyMarketHoldings(histories).some(h=>h.ticker==='NEXT'),'all filing dates, not just the latest');
});
test('market loading cannot make invalid full books valid by hiding an unselected row',()=>{
 const f={complete:true,holdings:[{cusip:'GOOD',ticker:'GOOD',value:100},{cusip:'BAD',ticker:'BAD',value:null}]};
 assert.deepEqual(strategyMarketHoldings(new Map([['g',[f]]])),[]);
 assert.equal(selectedBook(f,1).error,'invalid_selected_book');
 const short={complete:false,holdings:[{cusip:'GOOD',ticker:'GOOD',value:100}]};
 assert.equal(strategyMarketHoldings(new Map([['g',[short]]]))[0].ticker,'GOOD');
 assert.equal(selectedBook(short,2).error,'insufficient_top_n_extract');
});
const xml='<informationTable><infoTable><nameOfIssuer>APPLE INC</nameOfIssuer><titleOfClass>COM</titleOfClass><cusip>037833100</cusip><value>100</value><shrsOrPrnAmt><sshPrnamt>10</sshPrnamt><sshPrnamtType>SH</sshPrnamtType></shrsOrPrnAmt></infoTable><infoTable><nameOfIssuer>UNITY SOFTWARE INC</nameOfIssuer><titleOfClass>NOTE 11/1</titleOfClass><cusip>91332UAB7</cusip><value>200</value><shrsOrPrnAmt><sshPrnamt>200</sshPrnamt><sshPrnamtType>PRN</sshPrnamtType></shrsOrPrnAmt></infoTable></informationTable>';
function fixture(t,{original=true,manager='bill-ackman',future=false}={}) {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'strategy-db-test-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
 const json=(name,data)=>{const f=path.join(dir,name);fs.writeFileSync(f,JSON.stringify(data));return f;};
 const dbFile=path.join(dir,'source.sqlite'),d=new DatabaseSync(dbFile);
 d.exec(`CREATE TABLE guru_exposure_snapshots(guru_id TEXT,payload_json TEXT);
 CREATE TABLE guru_backtests(guru_id TEXT,years INTEGER,payload_json TEXT);
 CREATE TABLE price_points(symbol TEXT,date TEXT,open REAL,high REAL,low REAL,close REAL,adjusted_close REAL,volume REAL,source TEXT,updated_at TEXT);
 CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT);
 CREATE TABLE valuation_pit_model_runs(ticker TEXT,fiscal_period TEXT,model_version TEXT,as_of_date TEXT,financial_available_at TEXT,guidance_max_observed_at TEXT,input_json TEXT,output_json TEXT);`);
 const accession='0000000001-25-000001',publicDate='2025-08-14',reportDate='2025-06-30';
 const h={id:'037833100-COMMON',cusip:'037833100',issuer:'APPLE INC',ticker:'AAPL',shares:10,value:100};
 d.prepare('INSERT INTO guru_exposure_snapshots VALUES (?,?)').run(manager,JSON.stringify({history:[{accessionNumber:accession,reportDate,filingDate:publicDate,positionCount:1,topHoldings:[h],filing:{form:'13F-HR',secUrl:'https://www.sec.gov/example'}}]}));
 for(const symbol of ['SPY','AAPL'])for(const date of ['2025-08-14','2025-08-15','2025-08-18'])d.prepare('INSERT INTO price_points VALUES (?,?,?,?,?,?,?,?,?,?)').run(symbol,date,10,11,9,10,9.5,100,'sharadar_fact_os_sep','2025-08-19');
 d.prepare('INSERT INTO valuation_ticker_snapshots VALUES (?,?)').run('AAPL',JSON.stringify({currency:'USD',priceSource:'sharadar_fact_os_sep',priceHistory:[{date:'2025-08-14',close:10},{date:'2025-08-18',close:11}]}));
 d.prepare('INSERT INTO valuation_pit_model_runs VALUES (?,?,?,?,?,?,?,?)').run('AAPL','2025-Q2','test-v1','2025-08-13',future?'2025-08-20':'2025-08-13',null,
  JSON.stringify({sourceRecord:{currency:'USD',datekey:'2025-08-13'},financial:{revenue_m:100,cfo_m:null},trailingTwelveMonths:{revenue_m:300},valuationSemantics:{fairValueFormula:'Test model'}}),JSON.stringify({fairValue:12}));
 d.close();
 const docs=[{url:'https://www.sec.gov/Archives/edgar/data/1/'+accession+'/table.xml',hash:sha(xml),accessionNumber:accession}];
 fs.writeFileSync(path.join(dir,accession+'.xml'),xml);
 const records=original?[{guruId:manager,accessionNumber:accession,reportDate,publicDate,commonLongValue:100,sourceHash:signature(docs),documents:docs,scale:1,
  holdings:[{...h,title:'COM',shareType:'SH',putCall:''}]}]:[];
 const points=[{date:'2025-08-14',close:20,adjustedClose:19},{date:'2025-08-15',close:21,adjustedClose:20},{date:'2025-08-18',close:22,adjustedClose:21}];
 const opts={sourceFile:dbFile,targetFile:path.join(dir,'strategy.sqlite'),cutoff:'2025-08-18',generatedAt:'2025-08-19T00:00:00Z',
  catalog:[{id:manager,name:manager,entityName:'Test',type:'manager13f',cik:manager==='chamath-palihapitiya'?'0001607841':'0000000001'}],
  manifestFile:json('manifest.json',{filings:[]}),securityFile:json('security.json',{securities:[],unresolved:[],ambiguous:[]}),
  filingFile:json('filings.json',{version:'strategy-original-filings-v1',records,recordsHash:signature(records)}),
  etfFile:json('etfs.json',{version:'strategy-etfs-v1',asOf:'2025-08-18',series:{KMLM:{symbol:'KMLM',currency:'USD',source:'sharadar_fact_os_sfp',sourceLabel:'sharadar_fact_os_sfp',returnBasis:'total_return_adjusted_close',inception:'2020-12-01',first:'2025-08-14',last:'2025-08-18',points,pointsSha256:sha(JSON.stringify(points))}}})};
 return {dir,opts};
}

test('COMMON suffix is not a common equity classification',()=>{
 assert.equal(claimClassification({id:'91332UAB7-COMMON'}).type,'unknown');
 assert.equal(claimClassification({title:'NOTE 11/1',shareType:'PRN'}).type,'non_common');
 assert.equal(claimClassification({title:'COM',shareType:'SH'}).type,'common');
 assert.equal(claimClassification({putCall:'PUT',title:'COM',shareType:'SH'}).type,'option');
});
test('raw SEC parsing retains debt and amount type for evidence',()=>{
 const rows=parseDocumentRows(xml);assert.equal(rows.length,2);assert.equal(rows[1].shareType,'PRN');assert.equal(rows[1].value,200);
});
test('immutable insert accepts identical rows and rolls back conflicting batch',()=>{
 const d=new DatabaseSync(':memory:');d.exec('CREATE TABLE example(id TEXT PRIMARY KEY, value REAL) STRICT');
 immutableInsert(d,'example',{id:'a',value:1});immutableInsert(d,'example',{id:'a',value:1});
 d.exec('BEGIN');immutableInsert(d,'example',{id:'b',value:2});
 assert.throws(()=>immutableInsert(d,'example',{id:'a',value:9}),/immutable_record_conflict/);d.exec('ROLLBACK');
 assert.equal(d.prepare('SELECT count(*) n FROM example').get().n,1);d.close();
});
test('imports typed holdings, real ETF prices, model metrics and conflicting price evidence',t=>{
 const {opts}=fixture(t);const result=importStrategyDatabase(opts);
 assert.equal(result.sourceWrites,0);assert.equal(result.integrity,'ok');assert.equal(result.foreignKeys,0);
 const {db,close}=openStrategyDatabase(opts.targetFile);
 assert.equal(db.prepare('SELECT count(*) n FROM document_holdings').get().n,2);
 assert.equal(db.prepare('SELECT count(*) n FROM verified_common_holdings').get().n,1);
 assert.equal(db.prepare("SELECT value FROM valuation_metrics WHERE metric='cfo_m'").get().value,null);
 assert.equal(db.prepare("SELECT count(*) n FROM coverage_issues WHERE category='comparison_price'").get().n,1);
 assert.equal(db.prepare("SELECT conversion_ratio FROM corporate_actions WHERE id='arch-resources-core-natural-resources-2025'").get().conversion_ratio,1.326);
 assert.throws(()=>db.exec('DELETE FROM managers'),/readonly/);close();
});
test('legacy Top10 remains queryable but cannot silently become a verified book',t=>{
 const {opts}=fixture(t,{original:false});importStrategyDatabase(opts);
 const {db,close}=openStrategyDatabase(opts.targetFile);
 assert.equal(db.prepare('SELECT count(*) n FROM filing_holdings').get().n,1);
 assert.equal(db.prepare('SELECT count(*) n FROM verified_common_holdings').get().n,0);close();
 const r=loadStoredStrategyData(opts.targetFile,{managers:['bill-ackman'],start:'2025-08-15',end:'2025-08-18',valuationEnabled:true},{comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
 assert.equal(selectedBook(r.histories.get('bill-ackman')[0],1).error,'filing_classification_unverified');
});
test('known manager mismatch is preserved and blocks consumption',t=>{
 const {opts}=fixture(t,{manager:'chamath-palihapitiya'});importStrategyDatabase(opts);
 const c=storedStrategyCatalog(opts.targetFile,'2025-08-18');assert.equal(c.managers[0].identityStatus,'blocked');
 assert.equal(c.managers[0].avatar,'/guru-avatars/chamath-palihapitiya.png');
 assert.equal(c.etfs[0].available,true);
 const r=loadStoredStrategyData(opts.targetFile,{managers:['chamath-palihapitiya'],start:'2025-08-15',end:'2025-08-18',valuationEnabled:false},{comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
 assert.equal(selectedBook(r.histories.get('chamath-palihapitiya')[0],1).error,'manager_identity_mismatch');
});
test('reader loads from SQLite without the original ETF or filing JSON',t=>{
 const {opts}=fixture(t);importStrategyDatabase(opts);
 fs.unlinkSync(opts.etfFile);fs.unlinkSync(opts.filingFile);
 const r=loadStoredStrategyData(opts.targetFile,{managers:['bill-ackman'],start:'2025-08-15',end:'2025-08-18',valuationEnabled:true},{comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
 assert.equal(r.priceMaps.get('KMLM').get('2025-08-15'),20);
 assert.equal(r.valuations.get('AAPL')[0].fairValue,12);
 assert.equal(selectedBook(r.histories.get('bill-ackman')[0],1).holdings[0].ticker,'AAPL');
 assert.equal(r.comparisonPrices.get('AAPL').points.has('2025-08-15'),false,'conflict must not be silently bypassed');
});
test('GOOG-only selection loads its reviewed company model without substituting GOOGL holdings or prices',t=>{
 const {opts}=fixture(t);importStrategyDatabase(opts);
 // Synthetic fixture mutation only: retain the valid schema and node lineage.
 const d=new DatabaseSync(opts.targetFile);
 d.exec("UPDATE valuation_nodes SET ticker='GOOGL',input_json=json_set(input_json,'$.sourceRecord.sourceTicker','GOOGL')");
 d.close();
 const r=loadStoredStrategyData(opts.targetFile,{managers:[],start:'2025-08-15',end:'2025-08-18',valuationEnabled:true},
   {comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor,extraSymbols:['GOOG']});
 assert.equal(r.valuations.get('GOOGL')[0].sourceTicker,'GOOGL');
 assert.equal(r.valuations.get('GOOGL')[0].fairValue,12);
 assert.deepEqual(r.valuations.get('GOOG'),[]);
 assert.equal(r.priceMaps.has('GOOG'),true);assert.equal(r.priceMaps.has('GOOGL'),false);
 assert.equal(r.histories.size,0,'loading a model is not selecting a holding');
});
test('future lineage is stored as invalid, excluded by consumption, not repaired',t=>{
 const {opts}=fixture(t,{future:true});importStrategyDatabase(opts);
 const r=loadStoredStrategyData(opts.targetFile,{managers:['bill-ackman'],start:'2025-08-15',end:'2025-08-18',valuationEnabled:true},{comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
 assert.equal(r.valuations.get('AAPL').length,0);
 const {db,close}=openStrategyDatabase(opts.targetFile);assert.equal(db.prepare('SELECT quality_status FROM valuation_nodes').get().quality_status,'lineage_invalid');close();
});
test('two imports have identical manifests and existing target is never overwritten',t=>{
 const {opts,dir}=fixture(t);const a=importStrategyDatabase(opts),b=importStrategyDatabase({...opts,targetFile:path.join(dir,'second.sqlite')});
 assert.deepEqual(a.counts,b.counts);assert.equal(a.manifestHash,b.manifestHash);
 assert.throws(()=>importStrategyDatabase(opts),/target_must_be_new/);
});
test('one changed adjusted close changes the generation even with identical counts',t=>{
 const {opts,dir}=fixture(t);const a=importStrategyDatabase(opts);
 const d=new DatabaseSync(opts.sourceFile);d.exec("UPDATE price_points SET adjusted_close=9.4 WHERE symbol='AAPL' AND date='2025-08-15'");d.close();
 const b=importStrategyDatabase({...opts,targetFile:path.join(dir,'changed.sqlite')});
 assert.deepEqual(a.counts,b.counts);assert.notEqual(a.tableHashes.price_observations,b.tableHashes.price_observations);assert.notEqual(a.manifestHash,b.manifestHash);
});
test('corrupt XML aborts transaction and does not publish a complete generation',t=>{
 const {opts,dir}=fixture(t);fs.writeFileSync(path.join(dir,'0000000001-25-000001.xml'),'tampered');
 assert.throws(()=>importStrategyDatabase(opts),/source_document_hash_mismatch/);
 assert.throws(()=>openStrategyDatabase(opts.targetFile),/strategy_database_incomplete/);
});
test('original SEC cover is stored with its hash and corrupt cover cannot publish a generation',t=>{
 const {opts,dir}=fixture(t),artifact=JSON.parse(fs.readFileSync(opts.filingFile));
 const cover='<edgarSubmission><formType>13F-HR</formType></edgarSubmission>';
 const accession=artifact.records[0].accessionNumber;
 artifact.records[0].coverDocuments=[{accessionNumber:accession,url:'https://www.sec.gov/Archives/cover.xml',hash:sha(cover)}];
 artifact.recordsHash=signature(artifact.records);fs.writeFileSync(opts.filingFile,JSON.stringify(artifact));
 const file=path.join(dir,accession+'.cover.xml');fs.writeFileSync(file,cover);
 importStrategyDatabase(opts);
 const {db,close}=openStrategyDatabase(opts.targetFile);
 assert.deepEqual({...db.prepare("SELECT sha256,content FROM source_documents WHERE kind='sec_cover'").get()},{sha256:sha(cover),content:cover});close();
 fs.writeFileSync(file,'tampered');
 const next={...opts,targetFile:path.join(dir,'bad-cover.sqlite')};
 assert.throws(()=>importStrategyDatabase(next),/source_document_hash_mismatch/);
 assert.throws(()=>openStrategyDatabase(next.targetFile),/strategy_database_incomplete/);
});
test('schema/version mismatch and requests beyond cutoff fail closed',t=>{
 const {opts}=fixture(t);importStrategyDatabase(opts);
 assert.throws(()=>loadStoredStrategyData(opts.targetFile,{end:'2026-01-01'},{}),/cutoff_exceeded/);
 const d=new DatabaseSync(opts.targetFile);d.exec("UPDATE warehouse_meta SET security_version='stale'");d.close();
 assert.throws(()=>openStrategyDatabase(opts.targetFile),/version_mismatch/);
});
