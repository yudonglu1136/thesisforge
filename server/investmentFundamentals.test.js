import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import express from 'express';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildFundamentals, fundamentalScreens } from './investmentFundamentals.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';
const near=(x,y)=>assert.ok(Math.abs(x-y)<1e-10,`${x} != ${y}`);
function fixture(t){
  const db=new DatabaseSync(':memory:');t.after(()=>db.close());
  db.exec(`CREATE TABLE valuation_pit_model_runs(ticker TEXT,as_of_date TEXT,model_version TEXT,fiscal_period TEXT,financial_available_at TEXT,guidance_max_observed_at TEXT,input_json TEXT,output_json TEXT);
    CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT);`);
  for(const ticker of ['ACC','DIV','BANK']){
    for(const [date,period,end,growth,op,cash] of [['2026-02-01','2025-Q4','2025-12-31',10,20,12],['2026-05-01','2026-Q1','2026-03-31',30,25,ticker==='DIV'?8:14],['2026-08-01','2026-Q2','2026-06-30',60,30,18]]){
      const input={sourceRecord:{reportperiod:end,datekey:date,currency:'USD',dataset:'SYNTHETIC TEST ONLY',dimension:'ARQ'},financial:{revenue_growth_pct:growth},trailingTwelveMonths:{revenue_m:100,operating_income_m:op,fcf_after_capex_m:cash,capex_m:5},valuationSemantics:{scoreInputs:{modelRoute:ticker==='BANK'?'bank':'operating_company'},fairValueFormula:'test'}};
      db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?,?,?,?,?)').run(ticker,date,'v1',period,date,null,JSON.stringify(input),JSON.stringify({fairValue:120}));
    }
    db.prepare('INSERT INTO valuation_ticker_snapshots VALUES(?,?)').run(ticker,JSON.stringify({name:ticker,currency:'USD',priceHistory:[{date:'2026-05-29',close:100},{date:'2026-08-28',close:200}]}));
  }
  return {db,run:(date='2026-06-01')=>buildFundamentals({db},date)};
}
test('distinct questions produce distinct transparent subsets; null does not pass',()=>{
  assert.deepEqual(fundamentalScreens({revenueGrowth:.3,operatingMargin:.2,fcfMargin:.1},{revenueGrowth:.05,operatingMargin:.02,fcfMargin:0}),['acceleration','profit','cash']);
  assert.deepEqual(fundamentalScreens({revenueGrowth:.3,operatingMargin:-.2,fcfMargin:-.1},{revenueGrowth:null,operatingMargin:-.02,fcfMargin:null}),['divergence']);
  assert.deepEqual(fundamentalScreens({revenueGrowth:null},{revenueGrowth:.1,operatingMargin:.1,fcfMargin:.1}),[]);
});
test('latest cutoff, prior-quarter changes and gap reconcile exactly',t=>{
  const {run}=fixture(t),r=run(),n=r.companies[0];
  assert.equal(r.coverage.total,3);assert.equal(r.coverage.operating,2);assert.equal(r.coverage.excluded,1);
  assert.equal(n.period,'2026-Q1');assert.equal(n.previous.period,'2025-Q4');near(n.changes.revenueGrowth,.2);near(n.changes.operatingMargin,.05);near(n.modelGap,.2);
  assert.equal(n.quality.status,'unavailable');assert.deepEqual(n.quality.years,[]);
  assert.equal(r.counts.divergence,1);assert.equal(r.counts.cash,1);assert.equal(run('2026-08-28').companies[0].period,'2026-Q2');
});
test('invalid latest availability and nested lineage are withheld, never replaced by older values',t=>{
  const {db,run}=fixture(t);
  db.exec(`UPDATE valuation_pit_model_runs SET financial_available_at='2026-09-01' WHERE ticker='ACC' AND as_of_date='2026-05-01';
    UPDATE valuation_pit_model_runs SET input_json=json_set(input_json,'$.nested.fx.rateDate','2026-09-01') WHERE ticker='DIV' AND as_of_date='2026-05-01'`);
  const r=run();assert.equal(r.coverage.invalid,2);assert.equal(r.companies.length,0);
});
test('same-quarter amendments do not create a fake prior quarter',t=>{
  const {db,run}=fixture(t);const r=db.prepare("SELECT * FROM valuation_pit_model_runs WHERE ticker='ACC' AND as_of_date='2026-05-01'").get();
  db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?,?,?,?,?)').run(r.ticker,'2026-05-02','v1',r.fiscal_period,r.financial_available_at,null,r.input_json,r.output_json);
  assert.equal(run().companies[0].previous.period,'2025-Q4');near(run().companies[0].changes.revenueGrowth,.2);
});
test('ART, nonadjacent quarters and model-version changes do not support delta screens',t=>{
  for(const statement of ["input_json=json_set(input_json,'$.sourceRecord.dimension','ART')", "input_json=json_set(input_json,'$.sourceRecord.reportperiod','2026-05-01')", "model_version='v2'"]){
    const {db,run}=fixture(t);db.exec(`UPDATE valuation_pit_model_runs SET ${statement} WHERE ticker='ACC' AND as_of_date='2026-05-01'`);
    const r=run().companies[0];assert.equal(r.previous,null);assert.equal(r.changes.revenueGrowth,null);assert.deepEqual(r.screens,[]);
    if(statement.includes('ART'))assert.equal(r.metrics.revenueGrowth,null);
  }
});
test('null cash flow remains unknown and does not create a negative or positive screen',t=>{
  const {db,run}=fixture(t);db.exec(`UPDATE valuation_pit_model_runs SET input_json=json_set(input_json,'$.trailingTwelveMonths.fcf_after_capex_m',null) WHERE ticker='ACC'`);
  const r=run().companies[0];assert.equal(r.metrics.fcfMargin,null);assert.equal(r.changes.fcfMargin,null);assert.ok(!r.screens.includes('cash'));assert.ok(!r.screens.includes('divergence'));
});
test('growth and revenue-stage operating businesses are included regardless of valuation formula',t=>{
  const {db,run}=fixture(t);
  db.exec(`UPDATE valuation_pit_model_runs SET input_json=json_set(input_json,'$.valuationSemantics.scoreInputs.modelRoute','multi_method_growth') WHERE ticker='ACC';
    UPDATE valuation_pit_model_runs SET input_json=json_set(input_json,'$.valuationSemantics.scoreInputs.modelRoute','revenue_stage') WHERE ticker='DIV'`);
  assert.deepEqual(run().companies.map(c=>c.ticker),['ACC','DIV']);assert.equal(run().coverage.excluded,1);
});
test('mixed currencies, stale and absent prices withhold gaps without erasing financials',t=>{
  const {db,run}=fixture(t);db.exec(`UPDATE valuation_ticker_snapshots SET payload_json=json_set(payload_json,'$.currency','GBP') WHERE ticker='ACC'`);
  assert.equal(run().companies[0].modelGap,null);assert.equal(run().companies[0].valuationStatus,'currency_unverified');
  const stale=run('2026-06-15').companies[1];assert.equal(stale.modelGap,null);assert.equal(stale.valuationStatus,'stale_price');assert.equal(stale.price.value,100);
  assert.equal(run('2026-02-02').companies[1].valuationStatus,'no_price');
});
test('cached output is isolated from consumer mutation and bound to cutoff',t=>{
  const {db}=fixture(t),source={db};const a=buildFundamentals(source,'2026-06-01');a.companies[0].metrics.revenueGrowth=999;
  assert.equal(buildFundamentals(source,'2026-06-01').companies[0].metrics.revenueGrowth,.3);
  assert.equal(buildFundamentals(source,'2026-08-28').companies[0].metrics.revenueGrowth,.6);
  assert.throws(()=>buildFundamentals(source,'2026-02-30'));
});
test('PIT replay caches multiple dates without future prices or duplicate-date changes',t=>{
  const {db}=fixture(t),source={db};
  const prices=[{date:'2026-08-28',close:200},{date:'2026-05-29',close:90},
    {date:'2026-05-29',close:100,source:'last reported duplicate'},
    {date:'2026-05-30',close:0},{date:'2026-05-31',close:null},{close:999}];
  db.prepare("UPDATE valuation_ticker_snapshots SET payload_json=? WHERE ticker='ACC'").run(JSON.stringify({name:'ACC',currency:'USD',priceHistory:prices}));
  const expected=buildFundamentals(source,'2026-06-01');
  assert.equal(expected.companies[0].price.value,100);
  assert.equal(expected.companies[0].price.source,'last reported duplicate');
  assert.equal(buildFundamentals(source,'2026-08-28').companies[0].price.value,200);
  assert.equal(buildFundamentals(source,'2026-02-02').companies[0].price.value,null);
  assert.deepEqual(buildFundamentals(source,'2026-06-01'),expected);
  // More than the bounded replay window must remain numerically identical.
  for(let day=1;day<=50;day++)buildFundamentals(source,new Date(Date.UTC(2026,5,day)).toISOString().slice(0,10));
  assert.deepEqual(buildFundamentals(source,'2026-06-01'),expected);
});
test('same-connection corrections invalidate cached prices and financial observations',t=>{
  const {db}=fixture(t),source={db};
  assert.equal(buildFundamentals(source,'2026-06-01').companies[0].price.value,100);
  db.exec(`UPDATE valuation_ticker_snapshots SET payload_json=json_set(payload_json,'$.priceHistory[0].close',110) WHERE ticker='ACC';
    UPDATE valuation_pit_model_runs SET financial_available_at='2026-09-01' WHERE ticker='DIV' AND as_of_date='2026-05-01'`);
  const updated=buildFundamentals(source,'2026-06-01');
  assert.equal(updated.companies[0].price.value,110);assert.equal(updated.coverage.invalid,1);
  assert.equal(updated.companies.length,1);
});
test('external database corrections invalidate a source cache without reopening it',t=>{
  const {db}=fixture(t),dir=fs.mkdtempSync(path.join(os.tmpdir(),'fundamentals-cache-'));
  t.after(()=>fs.rmSync(dir,{recursive:true}));
  const file=path.join(dir,'fixture.sqlite');db.prepare('VACUUM INTO ?').run(file);
  const reader=new DatabaseSync(file,{readOnly:true}),writer=new DatabaseSync(file);
  t.after(()=>{reader.close();writer.close();});
  const source={db:reader};assert.equal(buildFundamentals(source,'2026-06-01').companies[0].price.value,100);
  writer.exec(`UPDATE valuation_ticker_snapshots SET payload_json=json_set(payload_json,'$.priceHistory[0].close',115) WHERE ticker='ACC'`);
  assert.equal(buildFundamentals(source,'2026-06-01').companies[0].price.value,115);
});
test('unused non-operating snapshot price arrays are not consumed by an operating screen',t=>{
  const {db,run}=fixture(t);
  db.exec(`UPDATE valuation_ticker_snapshots SET payload_json=json_set(payload_json,'$.priceHistory','unused malformed array') WHERE ticker='BANK'`);
  assert.equal(run().companies.length,2);
});
test('cached metadata chooses newest period revision and never falls back from invalid newest version',t=>{
  const {db}=fixture(t),source={db};
  const r=db.prepare("SELECT * FROM valuation_pit_model_runs WHERE ticker='ACC' AND as_of_date='2026-05-01'").get();
  buildFundamentals(source,'2026-06-01');
  db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?,?,?,?,?)').run(r.ticker,r.as_of_date,'v2',r.fiscal_period,'2026-09-01',null,r.input_json,r.output_json);
  const updated=buildFundamentals(source,'2026-06-01');
  assert.equal(updated.coverage.invalid,1);assert.ok(!updated.companies.some(c=>c.ticker==='ACC'));
  assert.ok(buildFundamentals(source,'2026-02-02').companies.some(c=>c.ticker==='ACC'));
});
test('route requires authentication and preserves private cache policy',async t=>{
  const {db}=fixture(t),app=express();app.use((r,_,next)=>{if(r.headers['x-test-user'])r.user={id:r.headers['x-test-user']};next();});
  registerInvestmentRoutes(app,{source:{db},date:d=>d,
    fundamentalDiscovery:async date=>({version:'fundamental-research-v2',asOf:date,rows:[{ticker:'ACC'}]})});
  const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
  try{const url=`http://127.0.0.1:${server.address().port}/api/investment/fundamentals?asOf=2026-06-01`;
    assert.equal((await fetch(url)).status,401);
    assert.equal((await fetch(url.replace('/fundamentals?','/fundamentals/ACC/gurus?'))).status,401);
    const r=await fetch(url,{headers:{'x-test-user':'alice'}});assert.equal(r.status,200);assert.match(r.headers.get('cache-control'),/private/);assert.equal((await r.json()).rows.length,1);
  }finally{await new Promise(r=>server.close(r));}
});
