import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { analysePortfolio, registerPortfolioAnalysisRoute } from './investmentPortfolio.js';
import { isoDate } from './investmentMath.js';

const asOf='2026-08-28';
const pos=(ticker,quantity,price,extra={})=>({ticker,name:`${ticker} synthetic test`,assetCategory:'STK',currency:'USD',quantity,price,localValue:quantity*price,...extra});
const account=(positions,currency='USD')=>({currency,reportDate:'2026-08-27',reportedNav:positions.reduce((s,p)=>s+p.localValue,0),positions});
const payload=(accounts)=>({source:{mode:'live',userScoped:true},connection:{status:'linked'},analysisAccounts:accounts});
const valuations=new Map([['AAA',{fairValue:120,currency:'USD',date:'2026-07-20',formula:'synthetic'}],['BBB',{fairValue:40,currency:'USD',date:'2026-07-25'}]]);
const book=(full=true)=>({guru:{id:'fixture',name:'Fixture manager',avatar:'/guru-avatars/fixture.png'},filing:{reportDate:'2026-06-30',filingDate:'2026-08-14',accessionNumber:'test'},full,
  holdings:[{ticker:'AAA',cusip:'AAA-CLAIM',value:300,shares:3},{ticker:'CCC',value:700,shares:7}]});
const base=()=>payload([account([pos('AAA',10,100),pos('BBB',20,50),pos('CCC',5,100),pos('CASH',500,1,{assetCategory:'CASH'})])]);
const run=(p=base(),options={})=>analysePortfolio(p,{asOf,valuations,books:[book()],...options});
const near=(a,b)=>assert.ok(Math.abs(a-b)<1e-8,`${a} != ${b}`);

test('hand reconciliation: aggregate value, model gap and NAV contribution',()=>{
  const g=run().groups[0];
  near(g.netValue,3000);near(g.cash,500);near(g.longValue,2500);near(g.equityValue,2500);
  near(g.coverage.weight,.8);assert.equal(g.coverage.count,2);
  near(g.valuation.coveredMark,2000);near(g.valuation.coveredModel,2000);near(g.valuation.delta,0);near(g.valuation.markedRemainderValue,3000);
  near(g.positions[0].modelDelta,200);near(g.positions[1].modelDelta,-200);near(g.positions[0].contribution,200/3000);
  assert.equal(g.positions[2].modelValue,null);near(g.reconciliation,0);
});
test('uniform stock stress includes missing-model equity and does not invent expected return',()=>{
  const g=run().groups[0];near(g.stress[0].pnl,-500);near(g.stress[0].netImpact,-1/6);near(g.stress[0].remaining,2500);
  assert.equal(g.expectedReturn,undefined);assert.equal(g.sharpe,undefined);
});
test('concentration aggregates same name across accounts, without mixing base currencies',()=>{
  const p=base();p.analysisAccounts.push(account([pos('AAA',10,100)]));p.analysisAccounts.push(account([pos('EU',2,30,{currency:'EUR'})],'EUR'));
  const r=run(p);assert.equal(r.groups.length,2);near(r.groups[0].netValue,4000);near(r.groups[1].netValue,60);near(r.groups[0].concentration[0].weight,2000/3500);
});
test('missing market value is not zero; no whole-book percentage or NAV scenario',()=>{
  const p=base();p.analysisAccounts[0].positions.push(pos('MISSING',1,2,{localValue:null}));
  const g=run(p).groups[0];assert.equal(g.netValue,null);assert.equal(g.unpriced,1);assert.equal(g.valuation.netImpact,null);assert.equal(g.stress[0].remaining,null);
  assert.equal(g.positions.at(-1).value,null);
});
test('all-unpriced and empty books have null denominator metrics',()=>{
  const g=run(payload([account([pos('A',1,2,{localValue:null})])])).groups[0];
  assert.equal(g.coverage.weight,null);assert.equal(g.top5Weight,null);assert.equal(g.valuation.delta,null);
  assert.equal(run(payload([account([])])).groups[0].comparisons[0].overlap,null);
});
test('separate FX: require explicit report FX for a foreign-currency holding',()=>{
  let p=payload([account([pos('AAA',10,100,{currency:'EUR'})])]);
  let g=run(p).groups[0];assert.equal(g.positions[0].value,null);assert.equal(g.positions[0].modelStatus,'units_or_fx_unverified');
  p.analysisAccounts[0].positions[0].fxRateToBase=1.2;
  g=run(p,{valuations:new Map([['AAA',{fairValue:120,currency:'EUR',date:'2026-07-20'}]])}).groups[0];
  near(g.netValue,1200);near(g.valuation.coveredModel,1440);near(g.valuation.delta,240);
});
test('unknown base currency never defaults to USD',()=>{
  const g=run(payload([account([pos('AAA',10,100)],'')])).groups[0];assert.equal(g.currency,null);assert.equal(g.netValue,null);
});
test('model quote currency mismatch is explicit, no 100x pence conversion',()=>{
  const p=payload([account([pos('AAA',10,100,{currency:'GBP'})],'GBP')]);
  assert.equal(run(p).groups[0].positions[0].modelStatus,'currency_mismatch');
  p.analysisAccounts[0].positions[0].price=10000;
  assert.equal(run(p).groups[0].positions[0].modelStatus,'units_or_fx_unverified');
});
test('reported units are never inferred, overwritten or trusted when inconsistent',()=>{
  const p=base();p.analysisAccounts[0].positions[0].quantity=1000;const before=JSON.stringify(p);
  const row=run(p).groups[0].positions[0];assert.equal(row.quantity,1000);assert.equal(row.modelValue,null);assert.equal(JSON.stringify(p),before);
});
test('shorts, options and cash have no common-equity DCF',()=>{
  const p=payload([account([pos('AAA',-2,100),pos('AAA',2,10,{assetCategory:'OPT'}),pos('CASH',500,1,{assetCategory:'CASH'})])]);
  const g=run(p).groups[0];assert.ok(g.positions.every(p=>p.modelStatus==='outside_model_scope'));near(g.shortValue,-200);near(g.otherValue,20);assert.equal(g.valuation.delta,null);assert.equal(g.stress[0].pnl,null);
});
test('future model and missing report date cannot produce a model value',()=>{
  const p=base();assert.equal(run(p,{valuations:new Map([['AAA',{fairValue:120,currency:'USD',date:'2026-09-01'}]])}).groups[0].positions[0].modelValue,null);
  p.analysisAccounts[0].reportDate=null;assert.equal(run(p).groups[0].positions[0].modelStatus,'report_date_missing');
});
test('holdings after research cutoff are labelled latest reports, never hidden as PIT ownership',()=>{
  const p=base();p.analysisAccounts[0].reportDate='2026-09-01';const r=run(p);
  assert.deepEqual(r.groups[0].reportDates,['2026-09-01']);assert.equal(r.asOf,asOf);assert.match(r.methodology.holdings,/not reconstructed/);
});
test('valid full Guru book uses common-long weights, not manager AUM',()=>{
  const g=run().groups[0];const c=g.comparisons[0];assert.equal(c.sharedCount,2);near(c.sharedUserWeight,.6);near(c.overlap,.5);
  near(c.differences.find(r=>r.ticker==='AAA').difference,.1);near(c.differences.find(r=>r.ticker==='CCC').difference,-.5);
  assert.equal(c.availableAt,'2026-08-14');assert.equal(c.avatar,'/guru-avatars/fixture.png');
});
test('bounded historical extract never gets renormalized into a full Guru portfolio',()=>{
  const c=run(base(),{books:[book(false)]}).groups[0].comparisons[0];assert.equal(c.overlap,null);assert.equal(c.complete,false);assert.ok(c.differences.every(r=>r.guruWeight===null));near(c.sharedUserWeight,.6);
});
test('incomplete numeric Guru book is not called complete',()=>{
  const b=book();b.holdings.push({ticker:'MISS',value:null,shares:10});const c=run(base(),{books:[b]}).groups[0].comparisons[0];assert.equal(c.complete,false);assert.equal(c.overlap,null);
});
test('CUSIP conflict is not merged as the same claim',()=>{
  const p=base();p.analysisAccounts[0].positions[0].cusip='OTHER-CLAIM';const c=run(p).groups[0].comparisons[0];assert.equal(c.overlap,null);assert.equal(c.sharedCount,1);assert.equal(c.differences.find(r=>r.ticker==='AAA').identity,'claim_mismatch');
});
test('future Guru disclosures are excluded',()=>{
  const b=book();b.filing.filingDate='2026-09-01';assert.equal(run(base(),{books:[b]}).groups[0].comparisons.length,0);
});
test('sector unknown and portfolio reconciliation remain visible',()=>{
  const p=base();p.analysisAccounts[0].reportedNav=3010;const g=run(p).groups[0];near(g.reconciliation,-10);assert.equal(g.sectors[0].name,'Unclassified');
});
test('zero and negative NAV never get misleading percentage outputs',()=>{
  for(const cash of [-2500,-3000]){const p=base();p.analysisAccounts[0].positions[3].localValue=cash;const g=run(p).groups[0];assert.equal(g.valuation.netImpact,null);assert.equal(g.positions[0].netWeight,null);}
});
test('sample, fallback and non-owner payloads are never displayed',()=>{
  for(const mode of ['sample','fallback','error']){const p=base();p.source.mode=mode;assert.equal(run(p).groups.length,0);}
  const p=base();p.source.userScoped=false;assert.equal(run(p).status,'account_required');
});
test('connected unsupported report and partial accounts are explicit',()=>{
  const p=base();p.analysisAccounts=[];p.holdings=[{ticker:'AAA'}];assert.equal(run(p).status,'report_inputs_unavailable');
  const q=base();q.connection.status='linked_partial';assert.equal(run(q).status,'partial_accounts');
});
test('API owner comes from auth only; private no-store; development preview cannot use real operator account',async()=>{
  const calls=[];const app=express();app.use((req,res,next)=>{if(req.headers['x-test-user'])req.user={id:req.headers['x-test-user'],adminPortfolioHash:'a'.repeat(40)};next();});
  registerPortfolioAnalysisRoute(app,{date:isoDate},async options=>{calls.push(options);return {source:{mode:'sample'}};});
  const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));const url=`http://127.0.0.1:${server.address().port}/api/investment/portfolio-analysis?asOf=${asOf}&owner=alice&adminPortfolioHash=${'b'.repeat(40)}`;
  try{
    assert.equal((await fetch(url)).status,401);
    const dev=await fetch(url,{headers:{'x-test-user':'local-dev-user'}});assert.equal((await dev.json()).status,'preview_account');assert.equal(calls.length,0);
    const r=await fetch(url,{headers:{'x-test-user':'bob'}});assert.equal(r.status,200);assert.match(r.headers.get('cache-control'),/private, no-store/);assert.match(r.headers.get('server-timing'),/portfolio-read/);assert.equal((await r.json()).status,'account_required');
    const home=await fetch(`${url}&scope=home`,{headers:{'x-test-user':'bob'}});assert.equal(home.status,200);await home.json();
    assert.deepEqual(calls,[
      {user:{id:'bob'},forceRefresh:false,preferSaved:true,includeAnalytics:true},
      {user:{id:'bob'},forceRefresh:false,preferSaved:true,includeAnalytics:false}
    ]);
  }finally{await new Promise(r=>server.close(r));}
});
