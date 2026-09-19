import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {holdingResolutionVersion} from '../server/cusipOverrides.js';
import {manager13fCorporateActionCatalogVersion} from '../server/corporateActions.js';

const sha=s=>crypto.createHash('sha256').update(s).digest('hex');
test('real price-refresh CLI advances equities and CTA together, preserves financials/users, and reads both databases back', t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'tf-nonfinancial-refresh-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const input=path.join(root,'input'),harvest=path.join(root,'harvest'),out=path.join(root,'candidate');
  for(const d of [input,harvest,path.join(harvest,'responses')])fs.mkdirSync(d,{recursive:true});
  const db=new DatabaseSync(path.join(input,'strategy.sqlite'));
  db.exec(fs.readFileSync(new URL('../server/strategyDatabaseSchema.sql',import.meta.url),'utf8'));
  db.prepare('INSERT INTO warehouse_meta VALUES (1,1,?,?,\'complete\',?,?,?,?)')
    .run('2026-09-10','2026-09-11T00:00:00Z',holdingResolutionVersion(),manager13fCorporateActionCatalogVersion,'prior','{}');
  db.prepare('INSERT INTO source_documents VALUES (?,?,?,?,?,?)').run('source','synthetic_fixture','fixture',sha('fixture'),'fixture','2026-09-10');
  const dates=Array.from({length:80},(_,i)=>new Date(Date.UTC(2026,6,24+i)).toISOString().slice(0,10)).filter(d=>d<='2026-09-11');
  const staged=new DatabaseSync(path.join(harvest,'prices.sqlite'));
  staged.exec(`CREATE TABLE series(symbol TEXT PRIMARY KEY,provider_symbol TEXT,currency TEXT,first_date TEXT,last_date TEXT,row_count INTEGER,source_sha256 TEXT,metadata_json TEXT,events_json TEXT,status TEXT);
    CREATE TABLE prices(symbol TEXT,date TEXT,open REAL,high REAL,low REAL,close REAL,adjusted_close REAL,volume REAL,quality_status TEXT,PRIMARY KEY(symbol,date));
    CREATE TABLE audit(symbol TEXT PRIMARY KEY,payload_json TEXT);`);
  // 80 overlap observations ending on 9/10, followed by one actual fixture bar.
  dates.splice(0,dates.length,...Array.from({length:81},(_,i)=>new Date(Date.UTC(2026,8,11-80+i)).toISOString().slice(0,10)));
  const symbols=['SPY','KMLM','DBMF','AZN','AZN.L','LSEG.L'];
  for(const symbol of symbols){
    const kind=['KMLM','DBMF'].includes(symbol)?'cta_etf':'raw_price_points';
    const currency=symbol.endsWith('.L')?'GBp':'USD',unit=currency==='GBp'?100:1;
    db.prepare('INSERT INTO price_series VALUES (?,?,?,?,?,?,?,?,?,?)').run(symbol,symbol,'yahoo','fixture',kind,'close','total_return_adjusted_close','USD','verified','source');
    const response=JSON.stringify({fixture:symbol});
    fs.writeFileSync(path.join(harvest,'responses',symbol+'.json'),response);
    staged.prepare('INSERT INTO series VALUES (?,?,?,?,?,?,?,?,?,?)').run(symbol,symbol,currency,dates[0],'2026-09-11',dates.length,sha(response),JSON.stringify({symbol,currency,instrumentType:'ETF'}),'{}','current');
    staged.prepare('INSERT INTO audit VALUES (?,?)').run(symbol,JSON.stringify({status:'current',rejected:[]}));
    for(const date of dates){
      staged.prepare('INSERT INTO prices VALUES (?,?,?,?,?,?,?,?,?)').run(symbol,date,100*unit,101*unit,99*unit,100*unit,90*unit,1000,'verified_daily_bar');
      if(date<'2026-09-11')db.prepare('INSERT INTO price_observations VALUES (?,?,?,?,?,?,?,?,?,?)').run(symbol,date,100*unit,101*unit,99*unit,100*unit,180*unit,1000,'2026-09-10','verified');
    }
    if(kind==='cta_etf')db.prepare('INSERT INTO etf_catalog VALUES (?,?,?,?,?,?,?,?)').run(symbol,dates[0],dates[0],'2026-09-10',symbol,'fixture',sha('points'),'2026-09-10');
  }
  staged.close();
  fs.writeFileSync(path.join(harvest,'plan.json'),JSON.stringify({cutoff:'2026-09-11',symbols}));
  const tableHashes={};
  for(const {name:table} of db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all()){
    const cols=db.prepare(`PRAGMA table_info(${table})`).all(),fields=cols.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
    const order=cols.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name),h=crypto.createHash('sha256');
    for(const r of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())h.update(JSON.stringify(r)+'\n');
    tableHashes[table]=h.digest('hex');
  }
  fs.writeFileSync(path.join(input,'strategy.sqlite.import.json'),JSON.stringify({tableHashes}));db.close();
  const runtime=new DatabaseSync(path.join(input,'runtime.sqlite'));
  runtime.exec(`CREATE TABLE price_points(symbol TEXT,date TEXT,open REAL,high REAL,low REAL,close REAL,adjusted_close REAL,volume REAL,source TEXT,updated_at TEXT,PRIMARY KEY(symbol,date));
    CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY,generated_at TEXT,payload_json TEXT);
    CREATE TABLE cache_revisions(scope TEXT PRIMARY KEY,revision INTEGER);
    CREATE TABLE valuation_pit_financials(ticker TEXT,available_at TEXT,revenue REAL);
    INSERT INTO valuation_pit_financials VALUES ('AVGO','2026-06-09',100);
    CREATE TABLE saved_assumptions(owner TEXT,payload TEXT); INSERT INTO saved_assumptions VALUES ('fixture-owner','keep-me');`);
  for(const ticker of ['AZN','LSEG'])runtime.prepare('INSERT INTO valuation_ticker_snapshots VALUES (?,?,?)').run(ticker,'2026-09-10',JSON.stringify({ticker,currency:'GBP',
    priceHistory:dates.filter(d=>d<'2026-09-11').map(date=>({date,close:100})),financialModel:{revenue:100,availableAt:'2026-06-09'}}));
  runtime.close();
  const oldHash=sha(fs.readFileSync(path.join(input,'runtime.sqlite')));
  const result=spawnSync(process.execPath,[new URL('./append-all-local-prices.mjs',import.meta.url).pathname,input,harvest,out],{encoding:'utf8',timeout:30000});
  assert.equal(result.status,0,result.stderr+'\n'+result.stdout);
  const report=JSON.parse(fs.readFileSync(path.join(out,'verification.json')));
  assert.equal(report.cutoff,'2026-09-11');assert.deepEqual(report.summary.ctaUpdated,['DBMF','KMLM']);
  assert.equal(report.summary.ctaRowsAdded,2);assert.equal(report.oldPriceChanges,0);
  assert.equal(report.summary.financialApiStatus,'deferred_by_user');
  const check=new DatabaseSync(path.join(out,'strategy.sqlite'),{readOnly:true});
  assert.equal(check.prepare('SELECT cutoff FROM warehouse_meta').get().cutoff,'2026-09-11');
  for(const r of check.prepare('SELECT * FROM etf_catalog').all()){
    assert.equal(r.last_date,'2026-09-11');
    assert.equal(check.prepare('SELECT COUNT(*) n FROM price_observations WHERE series_id=?').get(r.series_id).n,81);
    assert.equal(check.prepare('SELECT adjusted_close FROM price_observations WHERE series_id=? AND date=?').get(r.series_id,'2026-09-11').adjusted_close,180);
  }
  check.close();
  const rc=new DatabaseSync(path.join(out,'runtime.sqlite'),{readOnly:true});
  assert.equal(rc.prepare('SELECT available_at FROM valuation_pit_financials').get().available_at,'2026-06-09');
  assert.equal(rc.prepare('SELECT payload FROM saved_assumptions').get().payload,'keep-me');
  for(const ticker of ['AZN','LSEG']){
    const snapshot=JSON.parse(rc.prepare('SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?').get(ticker).payload_json);
    assert.equal(snapshot.priceHistory.at(-1).date,'2026-09-11');
    assert.equal(snapshot.priceHistory.at(-1).close,100);
    assert.equal(snapshot.marketDataRefresh.priceSymbol,ticker+'.L');
    assert.deepEqual(snapshot.financialModel,{revenue:100,availableAt:'2026-06-09'});
  }
  rc.close();
  assert.equal(sha(fs.readFileSync(path.join(input,'runtime.sqlite'))),oldHash);
});
