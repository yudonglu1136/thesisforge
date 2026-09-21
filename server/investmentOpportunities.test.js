import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { InvestmentSource } from './investmentSource.js';
import { InvestmentStore } from './investmentStore.js';
import { InvestmentService } from './investmentService.js';
import { fundamentalGuruQuarter } from './investmentFundamentals.js';
import { buildGuruHoldingsMatrix, buildOpportunities, opportunityCompanySummary, opportunityValuationBreakdown, opportunityValuations, opportunityTimeline, saveWatch, reviewWatch, saveWatchReview } from './investmentOpportunities.js';
const near=(a,b)=>assert.ok(Math.abs(a-b)<1e-10,`${a} != ${b}`);

test('trend uses distinct visible fiscal quarters, preserves latest pair, and never borrows future data', t => {
  const {source, db} = fixture(t);
  const insert = db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?,?,?,?,?)');
  const input = JSON.stringify({sourceRecord:{currency:'USD'},valuationSemantics:{fairValueFormula:'fixture',scoreInputs:{modelRoute:'operating_company'}}});
  const add = (date, period, value, financial = date, guidance = null) =>
    insert.run('STEADY', date, 'v1', period, financial, guidance, input, JSON.stringify({fairValue:value}));
  for(let i=0;i<8;i++)add(new Date(Date.UTC(2024,9+3*i,20)).toISOString().slice(0,10),`${2024+Math.floor((i+2)/4)}-Q${(i+2)%4+1}`,100*1.04**i);
  add('2026-07-25','2026-Q2',132); // another event, not another quarter
  add('2026-08-20','2026-Q2',800,'2026-09-01'); // future financial availability
  add('2026-08-21','2026-Q2',800,'2026-08-21','2026-09-01'); // future guidance
  add('2026-10-20','2026-Q3',800);
  const current = opportunityValuations(source,'2026-08-28').get('STEADY');
  assert.equal(current.trend.eligible,true); assert.equal(current.trend.points.length,8);
  assert.equal(current.trend.points.at(-1).date,'2026-07-25');
  assert.equal(current.previousDate,'2026-07-20'); assert.equal(current.date,'2026-07-25');
  const earlier=opportunityValuations(source,'2026-07-22').get('STEADY');
  assert.equal(earlier.trend.points.at(-1).date,'2026-07-20');
  const future=opportunityValuations(source,'2026-10-22').get('STEADY');
  assert.equal(future.trend.eligible,false); assert.ok(future.trend.reasons.includes('large_jump'));
  assert.equal(future.trend.points.at(-1).period,'2026-Q3'); // no old passing window
});

function fixture(t) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tf-opportunity-test-'));
  const file=path.join(dir,'source.sqlite'),db=new DatabaseSync(file);
  db.exec(`CREATE TABLE guru_snapshots(guru_id TEXT,payload_json TEXT);
    CREATE TABLE guru_exposure_snapshots(guru_id TEXT,payload_json TEXT);
    CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT);
    CREATE TABLE valuation_pit_model_runs(ticker TEXT,as_of_date TEXT,model_version TEXT,fiscal_period TEXT,
      financial_available_at TEXT,guidance_max_observed_at TEXT,input_json TEXT,output_json TEXT);`);
  const hold=(ticker,weight=.1)=>({id:ticker+'-COMMON',cusip:ticker,ticker,issuer:ticker+' fixture',shares:10,value:100,pctPortfolio:weight});
  for(const id of ['bill-ackman','gavin-baker','renaissance-technologies']) {
    const history=[{accessionNumber:'old-'+id,reportDate:'2026-03-31',filingDate:'2026-05-15',topHoldings:[hold('TEST')],largestChanges:[]},
      {accessionNumber:'new-'+id,reportDate:'2026-06-30',filingDate:'2026-08-14',topHoldings:[hold('TEST')],largestChanges:[]}];
    db.prepare('INSERT INTO guru_exposure_snapshots VALUES(?,?)').run(id,JSON.stringify({guru:{name:id},history}));
    db.prepare('INSERT INTO guru_snapshots VALUES(?,?)').run(id,JSON.stringify({summary:{reportDate:'2026-06-30',filingDate:'2026-08-14'},latestFiling:{accessionNumber:'new-'+id},
      holdings:[hold('TEST'),hold('TEST'),hold('MISS',null),{...hold('OPT'),id:'OPT-PUT'},hold('A.B')],
      activity:[{...hold('TEST'),action:'increased',changeShares:5,prevShares:15}]}));
  }
  for(const ticker of ['TEST','A.B']) {
    for(const [date,value,period] of [['2026-04-20',60,'2026-Q1'],['2026-07-20',66,'2026-Q2'],['2026-10-20',200,'2026-Q3']]) {
      const input={sourceRecord:{currency:'USD',reportperiod:date,dataset:'synthetic test fixture'},financial:{revenue_growth_pct:20},
        trailingTwelveMonths:{revenue_m:1000,shares_m:100,fcf_after_capex_m:200,operating_income_m:300},valuationSemantics:{fairValueFormula:'fixture_blend'},guidance:{evidence:[]}};
      db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?,?,?,?,?)').run(ticker,date,'v1',period,date,null,JSON.stringify(input),JSON.stringify({fairValue:value}));
    }
    db.prepare('INSERT INTO valuation_ticker_snapshots VALUES(?,?)').run(ticker,JSON.stringify({name:ticker,currency:'USD',priceHistory:[{date:'2026-05-31',close:50},{date:'2026-08-28',close:55},{date:'2026-10-30',close:300}]}));
  }
  const source=new InvestmentSource(file),storeFile=path.join(dir,'observations.sqlite'),store=new InvestmentStore(storeFile),service=new InvestmentService(source,store,()=> '2026-09-08');
  t.after(()=>{source.close();store.close();db.close();});
  return {db,source,store,service,storeFile};
}

test('institutional activity aggregates exact claims once per manager and includes every covered 13F filer',t=>{
  const {source}=fixture(t),r=buildOpportunities(source,'2026-08-28');
  const row=r.rows.find(x=>x.ticker==='TEST');
  assert.equal(row.managerCount,3);assert.equal(row.adds,3);assert.equal(row.managers[0].shares,20);
  assert.equal(row.newPositions,0);assert.equal(row.increases,3);assert.equal(row.reductions,0);assert.equal(row.exits,0);
  assert.deepEqual(r.coverage.activity,{newPositions:0,increases:3,reductions:0,exits:0});
  assert.equal(row.managers[0].weight,.2);assert.ok(!r.rows.some(x=>x.ticker==='OPT'));
  near(row.modelGap,.2);near(row.valuation.change,.1);
  assert.equal(row.valuation.previousFairValue,60);
  assert.equal(row.valuation.previousDate,'2026-04-20');
  assert.equal(r.coverage.fullBooks,3);assert.equal(r.coverage.extractedBooks,0);
});
test('Guru matrix preserves ownership semantics without loading universe valuations',t=>{
  const {source}=fixture(t),matrix=buildGuruHoldingsMatrix(source,'2026-08-28');
  const full=buildOpportunities(source,'2026-08-28');
  const project=r=>({ticker:r.ticker,managerCount:r.managerCount,medianWeight:r.medianWeight,
    newPositions:r.newPositions,increases:r.increases,reductions:r.reductions,exits:r.exits,adds:r.adds,trims:r.trims,
    managers:r.managers.map(m=>({guruId:m.guruId,shares:m.shares,weight:m.weight,action:m.action}))});
  assert.deepEqual(matrix.rows.map(project),full.rows.map(project));
  assert.ok(matrix.rows.every(r=>!('valuation' in r)&&!('price' in r)&&!('quality' in r)));
  const copy=buildGuruHoldingsMatrix(source,'2026-08-28');copy.rows[0].ticker='MUTATED';
  assert.notEqual(buildGuruHoldingsMatrix(source,'2026-08-28').rows[0].ticker,'MUTATED');
});
test('selected-company detail computes only that ticker and retains dated evidence',t=>{
  const {source}=fixture(t),detail=opportunityCompanySummary(source,'TEST','2026-08-28');
  assert.equal(detail.ticker,'TEST');assert.equal(detail.valuation.fairValue,66);assert.equal(detail.price.value,55);
  near(detail.modelGap,.2);assert.equal(detail.valuationStatus,'available');assert.equal(detail.events.length,6);
  const missing=opportunityCompanySummary(source,'MISS','2026-08-28');
  assert.equal(missing.valuation,null);assert.equal(missing.price.value,null);assert.equal(missing.modelGap,null);
});

test('published valuation breakdown exposes exact component outputs, weights and bounded inputs',t=>{
  const {source,db}=fixture(t);
  const row=db.prepare("SELECT input_json FROM valuation_pit_model_runs WHERE ticker='TEST' AND as_of_date='2026-07-20'").get();
  const input=JSON.parse(row.input_json);
  input.valuationSemantics.scoreInputs={valuationRevenue:1000,evSalesMultiple:5,
    normalizedNetIncome:120,normalizedMargin:.12,targetPE:20,valuationFreeCashFlow:100,
    sharesM:100,methodWeights:{'ev-sales-equity-value':.6,'normalized-earnings-power':.4}};
  db.prepare("UPDATE valuation_pit_model_runs SET input_json=?,output_json=? WHERE ticker='TEST' AND as_of_date='2026-07-20'")
    .run(JSON.stringify(input),JSON.stringify({fairValue:56,method:'fixture blend',methodOutputs:[
      {key:'ev-sales-equity-value',label:'EV sales',value:60,format:'currency',description:'fixture'},
      {key:'normalized-earnings-power',label:'Earnings',value:50,format:'currency',description:'fixture'},
    ]}));
  const result=opportunityValuationBreakdown(source,'TEST','2026-08-28');
  assert.equal(result.components.length,2);assert.equal(result.components[0].weight,.6);
  assert.equal(result.components[0].parameters.find(row=>row.key==='evSalesMultiple').value,5);
  assert.equal(result.weightedValue,56);assert.equal(result.reconciliationDifference,0);
  assert.equal(result.fairValue,56);assert.equal(result.modelVersion,'v1');
});

test('AMZN Q2 published ledger keeps unavailable DCF separate and reconciles the exact earnings value',t=>{
  const {source,db}=fixture(t);
  const row=db.prepare("SELECT input_json FROM valuation_pit_model_runs WHERE ticker='TEST' AND as_of_date='2026-07-20'").get();
  const input=JSON.parse(row.input_json);
  input.valuationSemantics.scoreInputs={
    normalizedNetIncome:90592.07222972096,sharesM:10903,targetPE:28.366266291421454,
    methodWeights:{'normalized-earnings-power':1,'fcfe-dcf':0},equityDcf:null,
  };
  const fairValue=235.6928225956114;
  db.prepare("UPDATE valuation_pit_model_runs SET input_json=?,output_json=? WHERE ticker='TEST' AND as_of_date='2026-07-20'")
    .run(JSON.stringify(input),JSON.stringify({fairValue,method:'published AMZN 2026-Q2 fixture',methodOutputs:[
      {key:'normalized-earnings-power',label:'Normalized earnings power',value:235.69282259561143,format:'currency'},
      {key:'fcfe-dcf',label:'FCFE DCF',value:null,format:'currency',description:'No supported DCF at this node'},
    ]}));
  const result=opportunityValuationBreakdown(source,'TEST','2026-08-28');
  const earnings=result.components.find(row=>row.key==='normalized-earnings-power');
  const dcf=result.components.find(row=>row.key==='fcfe-dcf');
  near(earnings.steps.at(-1).output,fairValue);assert.equal(earnings.weight,1);
  assert.equal(dcf.output,null);assert.equal(dcf.weight,0);assert.equal(dcf.status,'not_applicable');
  near(result.weightedValue,235.69282259561143);near(result.fairValue,fairValue);
  near(result.reconciliationDifference,-2.842170943040401e-14);
  assert.equal(result.reconciliationStatus,'reconciled');
});

test('fundamentals Guru drilldown stays exact to ticker, quarter and public cutoff',t=>{
  const {source}=fixture(t);
  const latest=fundamentalGuruQuarter(source,'TEST','2026-08-28');
  assert.equal(latest.version,'fundamental-guru-quarter-v1');assert.equal(latest.reportDate,'2026-06-30');
  assert.equal(latest.adds,3);assert.equal(latest.managerCount,3);
  assert.ok(latest.managers.every(m=>m.ticker==='TEST'&&m.reportDate===latest.reportDate&&m.availableAt<=latest.asOf));
  assert.ok(latest.managers.every(m=>m.avatar&&m.shares===20));
  const earlier=fundamentalGuruQuarter(source,'TEST','2026-08-28','2026-03-31');
  assert.equal(earlier.adds,0);assert.equal(earlier.coverage.extractedBooks,3);
  assert.ok(earlier.managers.every(m=>m.shares===10&&m.reportDate==='2026-03-31'));
  assert.throws(()=>fundamentalGuruQuarter(source,'TEST','2026-06-01','2026-06-30'));
  assert.throws(()=>fundamentalGuruQuarter(source,'bad/ticker','2026-08-28'));
  const empty=fundamentalGuruQuarter(source,'MISSING','2026-08-28');
  assert.equal(empty.ticker,'MISSING');assert.deepEqual(empty.managers,[]);assert.equal(empty.coverage.reportedManagers,3);
  assert.equal(fundamentalGuruQuarter(source,'A.B','2026-08-28').managers[0].ticker,'A.B');
});
test('historical cutoff never borrows latest full books, prices, model or future filings',t=>{
  const {source}=fixture(t),r=buildOpportunities(source,'2026-06-01');
  assert.deepEqual(r.rows.map(x=>x.ticker),['TEST']);assert.equal(r.coverage.extractedBooks,3);
  assert.equal(r.rows[0].valuation.fairValue,60);assert.equal(r.rows[0].price.value,50);
  assert.equal(r.rows[0].valuation.previousFairValue,undefined);
  assert.ok(opportunityTimeline(source,'TEST','2026-06-01').every(e=>e.date<='2026-06-01'));
  assert.throws(()=>buildOpportunities(source,'2026-06-01','2026-06-30'));
});
test('missing models and weights remain explicit null; ticker punctuation is preserved',t=>{
  const {source}=fixture(t),r=buildOpportunities(source,'2026-08-28');
  const miss=r.rows.find(x=>x.ticker==='MISS');assert.equal(miss.valuationStatus,'not_modeled');assert.equal(miss.price.value,null);
  assert.equal(miss.medianWeight,null);assert.equal(miss.managers[0].weight,null);
  assert.ok(r.rows.some(x=>x.ticker==='A.B'));assert.throws(()=>opportunityTimeline(source,'bad/ticker','2026-06-01'));
});
test('revision endpoints remain observed but missing currency cannot claim comparability',t=>{
  const {db,source}=fixture(t);
  db.prepare(`UPDATE valuation_pit_model_runs SET input_json=json_remove(input_json,'$.sourceRecord.currency') WHERE ticker='TEST'`).run();
  const row=buildOpportunities(source,'2026-08-28').rows.find(r=>r.ticker==='TEST');
  assert.equal(row.valuation.previousFairValue,60);
  assert.equal(row.valuation.fairValue,66);
  assert.equal(row.valuation.comparable,false);
  assert.equal(row.valuation.change,null);
});
test('discovery economic route is taken from the dated model and never inferred from growth',t=>{
  const {db,source}=fixture(t);
  db.prepare(`UPDATE valuation_pit_model_runs SET input_json=json_set(input_json,'$.valuationSemantics.scoreInputs.modelRoute','operating_company') WHERE as_of_date='2026-07-20'`).run();
  const current=buildOpportunities(source,'2026-08-28').rows.find(r=>r.ticker==='TEST');
  assert.equal(current.valuation.modelRoute,'operating_company');
  const historic=buildOpportunities(source,'2026-06-01').rows.find(r=>r.ticker==='TEST');
  assert.equal(historic.valuation.modelRoute,null);
  assert.equal(historic.valuation.revenueGrowth,.2);
});
test('accession mismatch falls back to honest historical extract',t=>{
  const {db,source}=fixture(t);
  db.prepare(`UPDATE guru_snapshots SET payload_json=json_set(payload_json,'$.latestFiling.accessionNumber','different-amendment')`).run();
  const r=buildOpportunities(source,'2026-08-28');assert.equal(r.coverage.fullBooks,0);assert.equal(r.rows.length,1);
});
test('null model output cannot be counted as a comparable valuation',t=>{
  const {db,source}=fixture(t);
  db.prepare(`UPDATE valuation_pit_model_runs SET output_json='{"fairValue":null}' WHERE ticker='TEST' AND as_of_date='2026-07-20'`).run();
  const row=buildOpportunities(source,'2026-08-28').rows.find(x=>x.ticker==='TEST');
  assert.equal(row.modelGap,null);assert.equal(row.valuationStatus,'not_modeled');
});
test('read cache returns isolated copies and invalidates after external source commits',t=>{
  const {source,db}=fixture(t),first=buildOpportunities(source,'2026-08-28');first.rows[0].ticker='MUTATED';
  assert.notEqual(buildOpportunities(source,'2026-08-28').rows[0].ticker,'MUTATED');
  db.prepare(`UPDATE valuation_pit_model_runs SET output_json='{"fairValue":77}' WHERE as_of_date='2026-07-20'`).run();
  assert.equal(buildOpportunities(source,'2026-08-28').rows.find(x=>x.ticker==='TEST').valuation.fairValue,77);
});
test('save needs no scenario, is idempotent, immutable, owner-scoped and survives reopen',t=>{
  const {service,store,storeFile}=fixture(t),body={operationId:'watch_operation_001',ticker:'TEST',asOf:'2026-06-01',origin:'adds'};
  const w=saveWatch(service,'alice',body);assert.equal(saveWatch(service,'alice',body).id,w.id);
  assert.equal(w.baseline.published.fairValue,60);assert.equal(store.list('alice','scenario').length,0);
  assert.throws(()=>store.get('bob',w.id));assert.throws(()=>store.db.prepare("UPDATE investment_events SET ticker='BAD'").run());
  const reopened=new InvestmentStore(storeFile);assert.equal(reopened.get('alice',w.id).baseline.asOf,'2026-06-01');reopened.close();
  assert.throws(()=>saveWatch(service,'alice',{...body,ticker:'A.B'}));
});
test('13F research watch freezes only bounded dated evidence for later review',t=>{
  const {service}=fixture(t),watch=saveWatch(service,'alice',{
    operationId:'watch_13f_evidence_001',ticker:'TEST',asOf:'2026-06-01',origin:'13f_insight',
    researchEvidence:{methodVersion:'institutional-behavior-v1',headlineKey:'net_increase_balanced_breadth',
      reportDate:'2026-03-31',previousReportDate:'2025-12-31',availableAt:'2026-05-15',
      evidence:{breadth:{adds:3,trims:2},shares:{netUnitsChangeK:50},weights:{importantChangesEvaluated:2},ignored:['x']},
      importantChanges:[{investorId:'manager-1',name:'Manager One',action:'increased',unitsChangeK:20,
        currentWeight:.04,previousWeight:.03,weightChangeBps:100,
        continuity:'increased_3_quarters',consecutiveDirectionQuarters:3,tags:['shares_and_weight_up']},
      ],unbounded:'discard me'},
  });
  assert.equal(watch.origin,'13f_insight');
  assert.equal(watch.researchEvidence.kind,'institutional_13f_analysis');
  assert.equal(watch.researchEvidence.reportDate,'2026-03-31');
  assert.equal(watch.researchEvidence.importantChanges[0].consecutiveDirectionQuarters,3);
  assert.equal('unbounded' in watch.researchEvidence,false);
});
test('review separates price/model change, detects new filings, records acknowledgment without overwriting original',t=>{
  const {service,store}=fixture(t),w=saveWatch(service,'alice',{operationId:'watch_operation_001',ticker:'TEST',asOf:'2026-06-01'});
  const r=reviewWatch(service,'alice',w.id,'2026-08-28');assert.equal(r.status,'new_evidence');
  near(r.modelChange,.1);near(r.priceChange,.1);assert.equal(r.newFilings.length,3);
  const body={operationId:'review_operation_001',watchId:w.id,asOf:'2026-08-28',comparisonId:r.comparisonId};
  const a=saveWatchReview(service,'alice',body);assert.equal(saveWatchReview(service,'alice',body).id,a.id);
  const after=reviewWatch(service,'alice',w.id,'2026-08-28');assert.equal(after.status,'unchanged');assert.equal(after.newFilings.length,0);
  assert.equal(store.get('alice',w.id).baseline.published.fairValue,60);near(after.modelChange,.1);
  assert.throws(()=>reviewWatch(service,'alice',w.id,'2026-05-01'));
});
test('method changes do not masquerade as investment returns; stale review is rejected',t=>{
  const {service,db}=fixture(t),w=saveWatch(service,'alice',{operationId:'watch_operation_001',ticker:'TEST',asOf:'2026-06-01'});
  const r=reviewWatch(service,'alice',w.id,'2026-08-28');
  db.prepare(`UPDATE valuation_pit_model_runs SET model_version='v2' WHERE as_of_date='2026-07-20'`).run();
  const changed=reviewWatch(service,'alice',w.id,'2026-08-28');assert.equal(changed.comparable,false);assert.equal(changed.modelChange,null);
  assert.throws(()=>saveWatchReview(service,'alice',{operationId:'review_operation_001',watchId:w.id,asOf:'2026-08-28',comparisonId:r.comparisonId}));
});
test('unmodeled holding can be watched without substituting another company',t=>{
  const {service}=fixture(t),w=saveWatch(service,'alice',{operationId:'watch_operation_001',ticker:'MISS',asOf:'2026-08-28'});
  assert.equal(w.ticker,'MISS');assert.equal(w.baseline.published,null);assert.equal(w.baseline.evidence.length,3);
  assert.equal(reviewWatch(service,'alice',w.id,'2026-08-28').status,'data_unavailable');
});

test('personal decision retains server-verified candidate context without opting managers into monitoring',t=>{
  const {service,source,store}=fixture(t),c=source.company('TEST','2026-08-28');
  const scenario=store.write('alice','scenario','TEST','scenario_fixture_001',{},()=>({asOf:'2026-08-28',snapshot:c.snapshot}));
  const body={operationId:'decision_fixture_001',ticker:'TEST',asOf:'2026-08-28',scenarioId:scenario.id,action:'Watch',notes:'Test only',rules:[],units:0,targetWeight:0,sourceGuruIds:[],
    candidateContext:{lens:'adds',reportDate:'2026-06-30',evidence:[{guruId:'forged'}]}};
  const d=service.saveDecision('alice',body);
  assert.equal(d.candidateContext.evidence.length,3);assert.equal(d.discovery.length,0);
  assert.ok(!d.candidateContext.evidence.some(e=>e.guruId==='forged'));
  assert.throws(()=>service.saveDecision('alice',{...body,operationId:'decision_fixture_002',candidateContext:{lens:'unverified'}}));
});
