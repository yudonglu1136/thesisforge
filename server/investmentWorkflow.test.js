import test from 'node:test';
import strict from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import express from 'express';
import { calculateScenario, reverseScenario, calculateOperatingScenario, reverseOperatingScenario, operatingIsoValueCurve, signature, ratio, percentile, evaluateRules, compareGuruShares, overlap, isoDate, sleeveRisk, personalScenarioPackage, scenarioTemplates, validateScenario } from './investmentMath.js';
import { assertLineage, sourceNode, InvestmentSource } from './investmentSource.js';
import { DatabaseSync } from 'node:sqlite';
import { InvestmentStore } from './investmentStore.js';
import { InvestmentService } from './investmentService.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';
import { compactResearchSeries, saveResearchRecord } from './researchWorkbench.js';

const base={revenueM:1000,sharesM:100,currency:'USD'};
const assumptions={method:'parent_fcfe',discountType:'Ke',ownership:'parent_common',timing:'year_end',ke:.1,g:.025,growth:Array(5).fill(.1),margin:Array(5).fill(.2)};
const operating={method:'operating_fcff',discountType:'WACC',ownership:'enterprise',timing:'year_end',
  horizonYears:5,wacc:.1,g:.025,growth:Array(5).fill(.1),ebitMargin:Array(5).fill(.2),
  cashTaxRate:Array(5).fill(.25),dnaMargin:Array(5).fill(.04),capexMargin:Array(5).fill(.06),
  nwcInvestmentMargin:Array(5).fill(.01),netDebtM:100,nciM:20,nonOperatingAssetsM:10};
const rule={metric:'revenueGrowth',operator:'lt',threshold:.3,consecutive:2,scope:'new_financial_periods',severity:'review'};
const row=(periodEnd,availableAt,value)=>({period:periodEnd,periodEnd,availableAt,metrics:{revenueGrowth:value},source:{dataset:'synthetic test fixture'}});
const tmp=()=>fs.mkdtempSync(path.join(os.tmpdir(),'tf-workflow-test-'));
const near=(a,b)=>strict.ok(Math.abs(a-b)<1e-8,`${a} != ${b}`);

test('research overview price sampling is bounded and preserves both endpoints',()=>{
  const rows=Array.from({length:901},(_,i)=>({date:`point-${i}`,close:i}));
  const compact=compactResearchSeries(rows,360);
  strict.equal(compact.length,360);
  strict.equal(compact[0],rows[0]);
  strict.equal(compact.at(-1),rows.at(-1));
  strict.ok(compact.every((row,index)=>index===0||rows.indexOf(row)>rows.indexOf(compact[index-1])));
});

test('issuer-authored periodEndDate is supported without inventing a fiscal date or accepting a future date',()=>{
  const source=(record)=>({fiscal_period:'2026-Q2',financial_available_at:'2026-07-30',as_of_date:'2026-07-30',model_version:'fixture',
    input_json:JSON.stringify({sourceRecord:record}),output_json:'{}'});
  strict.equal(sourceNode(source({periodEndDate:'2026-06-30'})).periodEnd,'2026-06-30');
  for(const record of [{},{periodEndDate:'2027-06-30'},{periodEndDate:'2026-02-30'}]) strict.throws(()=>sourceNode(source(record)));
  strict.equal(sourceNode(source({reportperiod:'2026-03-31',periodEndDate:'2026-06-30'})).periodEnd,'2026-03-31');
});

test('FCFE reproduces independent hand calculation and excludes debt/NCI',()=>{
  const r=calculateScenario(base,assumptions);
  const annual=[220,242,266.2,292.82,322.102];
  const explicit=annual.reduce((s,x,i)=>s+x/1.1**(i+1),0);
  const terminal=322.102*1.025/.075/1.1**5;
  near(r.fairValue,(explicit+terminal)/100);near(r.explicitPvM,1000);near(r.forecast[4].fcfeM,322.102);
  strict.equal(r.netDebtDeductedM,0);strict.equal(r.nciDeductedM,0);
});
test('ten-year FCFE preserves every explicit year and matches an independent hand calculation',()=>{
  const ten={...assumptions,horizonYears:10,growth:Array(10).fill(.05),margin:Array(10).fill(.15)};
  const r=calculateScenario(base,ten);
  let revenue=base.revenueM,explicit=0,lastFcfe=0;
  for(let year=1;year<=10;year++){
    revenue*=1.05;lastFcfe=revenue*.15;explicit+=lastFcfe/1.1**year;
  }
  const terminal=lastFcfe*1.025/(.1-.025)/1.1**10;
  strict.equal(r.forecast.length,10);strict.equal(r.terminalYear,10);
  near(r.explicitPvM,explicit);near(r.terminalPvM,terminal);
  near(r.fairValue,(explicit+terminal)/base.sharesM);
});
test('negative explicit FCFE remains negative and is disclosed as a financing need',()=>{
  const margins=[-.2,-.1,.02,.08,.15];
  const r=calculateScenario(base,{...assumptions,margin:margins});
  strict.deepEqual(r.negativeExplicitYears,[1,2]);
  strict.ok(r.forecast[0].fcfeM<0&&r.forecast[1].fcfeM<0);
  near(r.financingNeedM,-r.forecast[0].fcfeM-r.forecast[1].fcfeM);
});
test('ten-year reverse DCF substitutes back into the same forward engine',()=>{
  const ten={...assumptions,horizonYears:10,growth:Array(10).fill(.075),margin:Array(10).fill(.18)};
  const price=calculateScenario(base,ten).fairValue;
  const solved=reverseScenario(base,ten,price,'growth');
  strict.equal(solved.status,'solved');strict.equal(solved.scenario.horizonYears,10);
  near(solved.value,.075);near(solved.diagnostics.verifiedForwardValue,price);
  near(solved.residual,0);
});
test('operating FCFF bridge matches an independent five-year hand calculation',()=>{
  const r=calculateOperatingScenario(base,operating);
  let revenue=1000,explicit=0,last=0;
  for(let year=1;year<=5;year++){
    revenue*=1.1;
    const ebit=revenue*.2,nopat=ebit-ebit*.25;
    last=nopat+revenue*.04-revenue*.06-revenue*.01;
    explicit+=last/1.1**year;
    near(r.forecast[year-1].fcffM,last);
  }
  const terminal=last*1.025/(.1-.025)/1.1**5;
  near(r.explicitPvM,explicit);near(r.terminalPvM,terminal);
  near(r.enterpriseValueM,explicit+terminal);
  near(r.equityValueM,explicit+terminal-100-20+10);
  near(r.fairValue,r.equityValueM/100);
});
test('operating FCFF supports ten years and preserves early financing need',()=>{
  const a={...operating,horizonYears:10,growth:Array(10).fill(.05),ebitMargin:[-.2,-.1,...Array(8).fill(.2)],
    cashTaxRate:Array(10).fill(.25),dnaMargin:Array(10).fill(.02),capexMargin:Array(10).fill(.12),nwcInvestmentMargin:Array(10).fill(.03)};
  const r=calculateScenario(base,a);
  strict.equal(r.forecast.length,10);strict.deepEqual(r.negativeExplicitYears,[1,2]);
  strict.ok(r.financingNeedM>0);strict.ok(r.forecast[0].cashTaxM===0);
  near(r.equityValueM,r.enterpriseValueM-a.netDebtM-a.nciM+a.nonOperatingAssetsM);
});
test('operating reverse DCF solves one variable, verifies forward value, and reports bounds',()=>{
  const price=calculateScenario(base,operating).fairValue;
  for(const variable of ['growth','mature_ebit_margin','reinvestment']){
    const r=reverseOperatingScenario(base,operating,price,variable);
    strict.equal(r.status,'solved');near(r.scenario.fairValue,price);near(r.residual,0);
  }
  strict.equal(reverseOperatingScenario(base,operating,1e9,'growth').status,'outside_bounds');
});
test('growth and mature-margin iso-value curve exposes non-unique price explanations',()=>{
  const price=calculateScenario(base,operating).fairValue;
  const curve=operatingIsoValueCurve(base,operating,price,{growthRange:[.05,.15],marginRange:[0,.5],steps:10});
  strict.equal(curve.status,'calculated');strict.ok(curve.points.length>1);
  curve.points.forEach(point=>near(point.verifiedValue,price));
});
test('repeatable exact output and key-order independent signature',()=>{
  strict.deepEqual(calculateScenario(base,assumptions),calculateScenario(base,structuredClone(assumptions)));
  strict.equal(signature({a:2,b:1}),signature({b:1,a:2}));
});
test('terminal edit boundaries reject 8 percent and valid edits reconcile TV PV and equity',()=>{
  strict.throws(()=>calculateScenario(base,{...assumptions,g:.08}),/invalid_terminal_spread/);
  strict.throws(()=>calculateScenario(base,{...assumptions,ke:.04,g:.03}),/invalid_terminal_spread/);
  let previous=0;
  for(const g of [0,.025,.04,.05]) {
    const r=calculateScenario(base,{...assumptions,g});
    const terminal=r.forecast[4].fcfeM*(1+g)/(assumptions.ke-g);
    near(r.terminalValueM,terminal);
    near(r.terminalPvM,terminal/(1+assumptions.ke)**5);
    near(r.fairValue*base.sharesM,r.explicitPvM+r.terminalPvM);
    near(r.terminalShare,r.terminalPvM/r.equityValueM);
    strict.ok(r.fairValue>previous);previous=r.fairValue;
  }
});
test('reverse revenue growth round-trips the forward valuation',()=>{
  const p=calculateScenario(base,assumptions).fairValue;
  const r=reverseScenario(base,assumptions,p);near(r.value,.1);near(r.residual,0);
});
test('reverse terminal margin fixes the other four margins',()=>{
  const p=calculateScenario(base,assumptions).fairValue;
  const r=reverseScenario(base,assumptions,p,'terminal_margin');near(r.value,.2);
  strict.equal(reverseScenario(base,assumptions,1e9).status,'outside_bounds');
});
test('Ke/WACC, missing shares, zero revenue, invalid spread fail closed',()=>{
  for(const a of [{...assumptions,discountType:'WACC'},{...assumptions,g:.1},{...assumptions,netDebtDeduction:10},{...assumptions,ke:NaN},{...assumptions,growth:[null,...assumptions.growth.slice(1)]}]) strict.throws(()=>calculateScenario(base,a));
  for(const b of [{...base,sharesM:0},{...base,revenueM:null}])strict.throws(()=>calculateScenario(b,assumptions));
});
test('missing values are not zero; invalid denominators stay unavailable',()=>{
  strict.equal(ratio(null,4),null);strict.equal(ratio(1,0),null);strict.equal(ratio(1,-1),null);strict.equal(percentile(.2,[.1,null,.3]),null);
});
test('source lineage rejects a future nested guidance or FX record',()=>{
  strict.throws(()=>assertLineage({guidance:{evidence:[{observedAt:'2026-07-02'}]}},'2026-07-01'));
  strict.throws(()=>assertLineage({source:{fx:{rateDate:'2026-07-02'}}},'2026-07-01'));
  assertLineage({lastupdatedExcludedFromPitCutoff:'2026-07-02',datekey:'2026-07-01'},'2026-07-01');
});
test('calendar dates reject rollover and nonsensical timestamps',()=>{
  strict.throws(()=>isoDate('2026-02-30'));strict.throws(()=>isoDate('2026-9-1'));strict.equal(isoDate('2024-02-29'),'2024-02-29');
});
test('only new public periods contribute to a consecutive trigger',()=>{
  const history=[row('2026-03-31','2026-04-20',.1),row('2026-06-30','2026-07-20',.2),row('2026-09-30','2026-10-20',.25)];
  strict.equal(evaluateRules([rule],history,'2026-03-31','2026-07-21')[0].status,'insufficient_data');
  strict.equal(evaluateRules([rule],history,'2026-03-31','2026-10-21')[0].status,'review_required');
});
test('duplicate updates, missing quarter and null metric cannot count as consecutive',()=>{
  const a=row('2026-06-30','2026-07-20',.1),b=row('2026-06-30','2026-08-20',.2),c=row('2026-12-31','2027-02-20',.1);
  strict.equal(evaluateRules([rule],[a,b],'2026-03-31','2026-08-21')[0].status,'insufficient_data');
  strict.equal(evaluateRules([rule],[a,c],'2026-03-31','2027-02-21')[0].status,'insufficient_data');
  strict.equal(evaluateRules([rule],[a,row('2026-09-30','2026-10-20',null)],'2026-03-31','2026-10-21')[0].status,'insufficient_data');
});
test('Guru price-driven weight change is not a share purchase',()=>{
  const a={cusip:'123',shares:100,weight:.1},b={cusip:'123',shares:100,weight:.2};
  strict.equal(compareGuruShares(a,b,{splitFactor:1}).status,'unchanged');
  strict.equal(compareGuruShares(a,{...b,shares:200},{splitFactor:2}).status,'unchanged');
  strict.equal(compareGuruShares(a,b).status,'corporate_action_unverified');
  strict.equal(compareGuruShares(a,{...b,cusip:'456'},{splitFactor:1}).status,'not_comparable');
});
test('portfolio overlap reports shared, added and excluded securities',()=>{
  strict.deepEqual(overlap([{ticker:'A',weight:.6},{ticker:'B',weight:.4}],[{ticker:'A',weight:.5},{ticker:'C',weight:.5}]).map(x=>x.kind),['shared','user_added','not_in_fundamental']);
});

test('CTA stays a separate sleeve: exact date alignment and hand-checkable weights',()=>{
  const equityNav=[{date:'2026-06-01',nav:100},{date:'2026-06-02',nav:110},{date:'2026-06-03',nav:99}];
  const ctaNav=[{date:'2026-06-01',nav:100},{date:'2026-06-02',nav:90},{date:'2026-06-03',nav:99}];
  const r=sleeveRisk({equityNav,ctaNav,ctaWeight:.5});near(r.combined.totalReturn,0);near(r.correlation,-1);
  strict.equal(sleeveRisk({equityNav,ctaNav:[],ctaWeight:.5}).metrics,null);
  strict.throws(()=>sleeveRisk({equityNav,ctaNav:ctaNav.slice(1),ctaWeight:.5}));
});

test('shadow ranks aggregate duplicates, excludes options and waits for filing availability',()=>{
  const {service:s,store}=setup();
  const records=[{id:'a-COMMON',cusip:'a',ticker:'AAA',value:40,shares:4},{id:'a-COMMON',cusip:'a',ticker:'AAA',value:40,shares:4},{id:'b-COMMON',cusip:'b',ticker:'BBB',value:70,shares:7},{id:'c-COMMON',cusip:'c',ticker:'CCC',value:60,shares:6},{id:'d-PUT',cusip:'d',ticker:'DDD',value:999,shares:9}];
  s.source.guruCatalog=()=>[{id:'test-guru'}];
  s.source.guruHistory=(_,asOf)=>asOf<'2026-08-14'?[]:[{filingDate:'2026-08-14',reportDate:'2026-06-30',accessionNumber:'test',topHoldings:records}];
  s.strategy('alice',{operationId:'strategy_version_001',asOf:'2026-08-14',managers:['test-guru'],topN:3});
  strict.equal(s.shadow('alice','2026-08-13').status,'incomplete');
  const r=s.shadow('alice','2026-08-14');strict.deepEqual(r.holdings.map(x=>x.ticker),['AAA','BBB','CCC']);near(r.holdings[0].weight,1/3);
  strict.equal(r.rules.valuationFilter,false);strict.equal(r.performance,null);store.close();
});

function fakeSource() {
  const data=(ticker,asOf)=>{
    const later=asOf>='2026-07-20';const b={...base,revenueM:ticker==='MSFT'?2000:1000};if(later)b.revenueM*=1.1;
    const metrics={revenueGrowth:later?.2:.4,operatingMargin:.3,fcfMargin:.2,capexIntensity:.05};
    const snapshot={ticker,asOf,period:later?'2026-Q2':'2026-Q1',periodEnd:later?'2026-06-30':'2026-03-31',availableAt:later?'2026-07-20':'2026-04-20',base:b,metrics,price:{value:50,date:asOf,currency:'USD'},source:{hash:'test'}};
    return {ticker,asOf,base:b,snapshot:{...snapshot,id:signature(snapshot)},templates:{Base:assumptions},provenance:[],history:[row('2026-03-31','2026-04-20',.4),row('2026-06-30','2026-07-20',.2)]};
  };
  return {company:data,price:(_,asOf)=>({value:50,date:asOf,currency:'USD'}),discovery:()=>[],guruCatalog:()=>[],guruHistory:()=>[],
    db:{prepare:sql=>sql==='PRAGMA data_version'?{get:()=>({data_version:1})}:{all:()=>[]}}};
}
function setup(){const file=path.join(tmp(),'decisions.sqlite'),store=new InvestmentStore(file,()=> '2026-09-08T12:00:00.000Z'),service=new InvestmentService(fakeSource(),store,()=> '2026-09-08');return{file,store,service};}

const draftBody=(s,changes={})=>({ticker:'ISRG',asOf:'2026-06-01',snapshotId:s.source.company('ISRG','2026-06-01').snapshot.id,
  operationId:'worksheet_test_0001',expectedHead:null,name:'My base',hypothesis:'Synthetic fixture',assumptions:structuredClone(assumptions),...changes});
test('worksheet edits restore after DB reopen, per owner/ticker; no scenario or decision created',()=>{
  const {service:s,store,file}=setup();
  const b=draftBody(s);b.assumptions.growth[1]=.25;
  const r=s.saveWorksheet('alice',b);near(r.result.forecast[1].growth,.25);
  strict.equal(store.list('alice','scenario').length,0);strict.equal(store.list('alice','decision').length,0);
  strict.equal(r.ownershipConfirmed,false);store.close();
  const reopened=new InvestmentStore(file),s2=new InvestmentService(fakeSource(),reopened,()=> '2026-09-08');
  const research=s2.research('alice','ISRG','2026-06-01');
  strict.equal(research.activeWorksheet.id,r.id);strict.equal(research.worksheetHead,r.id);
  strict.deepEqual(research.activeWorksheet.assumptions,b.assumptions);
  strict.equal(s2.research('bob','ISRG','2026-06-01').activeWorksheet,null);
  strict.equal(s2.research('alice','MSFT','2026-06-01').activeWorksheet,null);
  reopened.close();
});
test('worksheet carries assumptions forward, not future data backward; new base recomputes only value',()=>{
  const {service:s,store}=setup();const r=s.saveWorksheet('alice',draftBody(s));
  strict.equal(s.research('alice','ISRG','2026-05-31').activeWorksheet,null);
  const later=s.research('alice','ISRG','2026-08-01');
  strict.deepEqual(later.activeWorksheet.assumptions,r.assumptions);strict.equal(later.worksheetHead,null);
  strict.notEqual(later.snapshot.id,r.snapshot.id);
  near(s.calculate({ticker:'ISRG',asOf:'2026-08-01',assumptions:r.assumptions}).result.fairValue/r.result.fairValue,1.1);
  store.close();
});
test('worksheet retry is idempotent; stale tabs cannot overwrite newer drafts or formal scenarios',()=>{
  const {service:s,store}=setup(),b=draftBody(s),r=s.saveWorksheet('alice',b);
  strict.equal(s.saveWorksheet('alice',b).id,r.id);
  strict.throws(()=>s.saveWorksheet('alice',{...b,operationId:'worksheet_test_0002'}),e=>e.status===409);
  const formal=s.saveScenario('alice',{...b,operationId:'formal_scenario_001',ownershipConfirmed:true});
  strict.equal(s.research('alice','ISRG',b.asOf).activeWorksheet.id,formal.id);
  strict.throws(()=>s.saveWorksheet('alice',{...b,expectedHead:r.id,operationId:'worksheet_test_0003'}),e=>e.status===409);
  const next=s.saveWorksheet('alice',{...b,expectedHead:formal.id,operationId:'worksheet_test_0004'});
  strict.equal(s.research('alice','ISRG',b.asOf).activeWorksheet.id,next.id);
  strict.equal(store.get('alice',formal.id).kind,'scenario');store.close();
});
test('legacy LOCAL QA scenario is preserved but cannot silently seed a user worksheet',()=>{
  const {service:s,store}=setup();
  const qa=s.saveScenario('alice',{...draftBody(s),name:'LOCAL QA — workflow check',ownershipConfirmed:true});
  const r=s.research('alice','ISRG','2026-08-01');
  strict.equal(r.activeWorksheet,null);strict.equal(r.worksheetIgnoredTestVersions,1);
  strict.equal(r.scenarios[0].id,qa.id);strict.deepEqual(r.templates.Base,assumptions);
  store.close();
});
test('partial drafts persist without calculation; forged values/owners and unsafe shapes do not become results',()=>{
  const {service:s,store}=setup(),b=draftBody(s);b.assumptions.margin[2]=null;
  const r=s.saveWorksheet('alice',{...b,owner:'bob',result:{fairValue:99999}});
  strict.equal(r.result,null);strict.equal(r.validationError,'invalid_fcfe_margin_path');
  strict.equal(s.research('bob','ISRG',b.asOf).activeWorksheet,null);
  strict.equal(s.research('alice','ISRG',b.asOf).activeWorksheet.assumptions.margin[2],null);
  for(const patch of [{hypothesis:'x'.repeat(4001)},{snapshotId:'stale'},{assumptions:{...assumptions,netDebtDeduction:1}},{assumptions:{...assumptions,growth:[1]}}])
    strict.throws(()=>s.saveWorksheet('alice',{...b,...patch,operationId:'worksheet_invalid_01',expectedHead:r.id}));
  store.close();
});
test('historical seed uses normalized growth and cycle cash conversion, with bounded disclosed fallbacks',()=>{
  const score={modelRoute:'operating_company',methodWeights:{'fcfe-dcf':0},equityDcf:null,revenueGrowth:13.365668,cycleFcfMargin:2.42647,cycleSampleCount:8};
  const {templates,reconciliation}=personalScenarioPackage({...base,fcfM:-12},score,true);
  near(templates.Base.growth[0],.13365668);near(templates.Base.margin[0],.0242647);
  strict.equal(reconciliation.startingForecast.marginBasis,'stored_cycle_cfo_minus_capex_margin');
  strict.equal(reconciliation.startingForecast.notManagementGuidance,true);
  for(const growth of [-1000,1000,NaN]) {
    const p=personalScenarioPackage(base,{...score,revenueGrowth:growth,cycleFcfMargin:200},true);
    validateScenario(p.templates.Base);strict.ok(calculateScenario(base,p.templates.Base).fairValue>0);
  }
});
test('worksheet HTTP uses authenticated identity and private no-store; anonymous write denied',async()=>{
  const {service:s,store}=setup(),app=express();app.use(express.json());
  app.use((req,_res,next)=>{if(req.headers.authorization==='Bearer fixture-alice')req.user={id:'alice'};next();});
  registerInvestmentRoutes(app,s);const server=app.listen(0);await new Promise(r=>server.once('listening',r));
  try {
    const url=`http://127.0.0.1:${server.address().port}/api/investment/valuation-drafts`;
    strict.equal((await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(draftBody(s))})).status,401);
    const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer fixture-alice'},body:JSON.stringify({...draftBody(s),owner:'bob'})});
    strict.equal(response.status,200);strict.equal(response.headers.get('cache-control'),'private, no-store');
    strict.equal((await response.json()).kind,'valuation_draft');strict.equal(store.list('bob').length,0);
  } finally {await new Promise(r=>server.close(r));store.close();}
});

test('Guru detail and discovery respect the public filing cutoff and keep missing values null',()=>{
  const file=path.join(tmp(),'source.sqlite'),db=new DatabaseSync(file);
  db.exec('CREATE TABLE guru_exposure_snapshots(guru_id TEXT,payload_json TEXT)');
  const payload={guru:{name:'Test manager',entityName:'Fixture only',avatarUrl:'/guru-avatars/test.png'},history:[
    {accessionNumber:'future',quarterLabel:'2026 Q2',reportDate:'2026-06-30',filingDate:'2026-08-14',reported13fValue:123,topHoldings:[]},
    {accessionNumber:'eligible',quarterLabel:'2026 Q1',reportDate:'2026-03-31',filingDate:'2026-05-15',topHoldings:[]},
    {accessionNumber:'bad-period',reportDate:'2026-06-30',filingDate:'2026-05-01',topHoldings:[]},
  ]};
  db.prepare('INSERT INTO guru_exposure_snapshots VALUES (?,?)').run('test',JSON.stringify(payload));db.close();
  const source=new InvestmentSource(file),{service:s,store}=setup();s.source=source;source.discovery=()=>[];
  const detail=source.guruDetail('test','2026-06-01');
  strict.deepEqual(detail.history.map(h=>h.accessionNumber),['eligible']);strict.equal(detail.guru.avatar,'/guru-avatars/test.png');
  strict.equal(detail.coverage,'reported_top_holdings_and_largest_changes_only');
  strict.throws(()=>source.guruDetail('unknown','2026-06-01'),/unknown_guru/);
  const result=s.discover('alice','2026-06-01');strict.equal(result.gurus[0].latest.accession,'eligible');
  strict.equal(result.gurus[0].latest.reported13fValue,null);strict.equal(result.gurus[0].latest.positionCount,null);
  strict.equal(s.discover('alice','2026-04-01').gurus[0].latest,null);source.close();store.close();
});

test('selected historical Guru filing is validated and frozen instead of replaced by the latest book',()=>{
  const{service:s,store}=setup();s.source.guruCatalog=()=>[{id:'test-guru',name:'Test manager'}];
  const filing={accessionNumber:'selected-old',reportDate:'2025-12-31',filingDate:'2026-02-14',topHoldings:[{id:'123-COMMON',ticker:'ISRG',shares:42,pctPortfolio:.1}],filing:{secUrl:'https://www.sec.gov/example'}};
  s.source.guruHistory=()=>[filing];
  const scenario=save(s);
  const body={ticker:'ISRG',asOf:'2026-06-01',operationId:'dated_guru_evidence_01',action:'Watch',scenarioId:scenario.id,units:0,targetWeight:0,notes:'Actual selected source',rules:[],sourceGuruIds:['test-guru'],discoveryOrigin:'guru_disclosure',entryEvidence:{guruId:'test-guru',accession:'selected-old'}};
  const d=s.saveDecision('alice',body);strict.equal(d.discovery[0].accession,'selected-old');strict.equal(d.discovery[0].shares,42);
  strict.equal(d.discovery[0].availableAt,'2026-02-14');strict.equal(d.discovery.length,1);
  strict.throws(()=>s.saveDecision('alice',{...body,operationId:'dated_guru_evidence_02',entryEvidence:{guruId:'test-guru',accession:'future'}}),/entry_disclosure_not_available/);
  filing.topHoldings[0].ticker='OTHER';
  strict.throws(()=>s.saveDecision('alice',{...body,operationId:'dated_guru_evidence_03'}),/entry_holding_not_available/);
  strict.equal(store.get('alice',d.id).discovery[0].ticker,'ISRG');store.close();
});

test('Then vs Now exposes matching original and active scenario baselines after a Change',()=>{
  const{service:s,store}=setup();const a=save(s),d=decide(s,a),current=s.research('alice','ISRG','2026-08-01');
  const changed={...assumptions,ke:.12};
  const b=s.saveScenario('alice',{ticker:'ISRG',asOf:'2026-08-01',snapshotId:current.snapshot.id,operationId:'distinct_assumptions_01',name:'Revised',assumptions:changed,ownershipConfirmed:true,parentId:a.id});
  s.saveReview('alice',{operationId:'distinct_review_01',decisionId:d.id,asOf:'2026-08-01',expectedHeadId:d.id,action:'Change',notes:'Higher required return',scenarioId:b.id});
  const review=s.reviewContext('alice',d.id,'2026-08-01');
  near(review.thenValue,a.result.fairValue);near(review.activeThenValue,b.result.fairValue);
  near(review.sameAssumptions.fairValue,b.result.fairValue);near(review.originalSameAssumptions.fairValue,a.result.fairValue*1.1);
  strict.notEqual(review.sameAssumptions.fairValue,review.originalSameAssumptions.fairValue);
  strict.equal(review.delta.find(x=>x.metric==='revenueGrowth').then,.4);
  strict.equal(review.activeDelta.find(x=>x.metric==='revenueGrowth').then,.2);store.close();
});

test('template comparison is separate from the edited personal scenario',()=>{
  const{service:s,store}=setup();const result=s.calculate({ticker:'ISRG',asOf:'2026-06-01',assumptions:{...assumptions,ke:.12}});
  near(result.templateResults.Base,calculateScenario(base,assumptions).fairValue);
  strict.notEqual(result.templateResults.Base,result.result.fairValue);store.close();
});
function save(s,ticker='ISRG',owner='alice',date='2026-06-01',parentId=null){const c=s.research(owner,ticker,date);return s.saveScenario(owner,{ticker,asOf:date,snapshotId:c.snapshot.id,operationId:`scenario_${ticker}_${date}_${parentId??'first'}`,name:'Base',assumptions,ownershipConfirmed:true,parentId});}
function decide(s,scenario,owner='alice'){return s.saveDecision(owner,{ticker:scenario.ticker,asOf:scenario.asOf,operationId:`decision_${scenario.ticker}_${scenario.asOf}`,action:'Invest',scenarioId:scenario.id,units:10,targetWeight:.1,notes:'Test thesis',rules:[{...rule,consecutive:1}]});}
test('value-chain research saves with explicit retrospective classification provenance',()=>{
  const {service:s,store}=setup();const scenario=save(s);
  const body={ticker:'ISRG',asOf:scenario.asOf,operationId:'value_flow_decision_01',action:'Watch',scenarioId:scenario.id,units:0,targetWeight:0,notes:'Industry research',discoveryOrigin:'value_flow'};
  const d=s.saveDecision('alice',body);
  strict.equal(d.discoveryOrigin.kind,'value_flow');strict.equal(d.discoveryOrigin.classificationVersion,'2026-08-14');strict.equal(d.discoveryOrigin.retrospectiveClassification,true);
  strict.equal(s.store.list('bob','decision').length,0);store.close();
});
test('AI Insights decisions retain the server-verified snapshot and no fabricated client financials',()=>{
  const {service:s,store}=setup();const scenario=save(s);
  s.aiInsights={company(ticker,query){
    strict.equal(ticker,'ISRG');strict.equal(query.asOf,scenario.asOf);strict.equal(query.snapshotId,'fixture-analysis');
    return {context:{snapshotId:'fixture-analysis',asOf:query.asOf,selectedQuarter:'2026Q1',universeVersion:'fixture-universe',methodologyVersion:'fixture-method',catalogGeneration:'fixture-catalog'},company:{sourceRevisionId:'fixture-source'}};
  }};
  const body={ticker:'ISRG',asOf:scenario.asOf,operationId:'ai_insights_decision_01',action:'Watch',scenarioId:scenario.id,units:0,targetWeight:0,notes:'AI research',discoveryOrigin:'ai_insights',discoveryContext:{snapshotId:'fixture-analysis',quarter:'2026Q1',window:8,group:'hardware',sort:'quality',selected:'ISRG',revenue:999,tickers:['CRDO','ALAB']}};
  const d=s.saveDecision('alice',body);
  strict.equal(d.discoveryOrigin.kind,'ai_insights');strict.equal(d.discoveryOrigin.snapshotId,'fixture-analysis');
  strict.equal(d.discoveryContext.catalogGeneration,'fixture-catalog');strict.equal(d.discoveryContext.sourceRevisionId,'fixture-source');
  strict.equal(d.discoveryContext.filters.selected,'ISRG');
  strict.equal(d.discoveryContext.revenue,undefined);strict.deepEqual(d.discoveryContext.compareTickers,['CRDO','ALAB']);
  strict.throws(()=>s.saveDecision('alice',{...body,operationId:'ai_insights_decision_02',discoveryContext:{}}),/ai_insights_snapshot_required/);
  store.close();
});
test('AI Insights observations use server-verified source references without a valuation decision',()=>{
  const {service:s,store}=setup();
  s.aiInsights={company(ticker,query){
    strict.equal(ticker,'ISRG');strict.equal(query.asOf,'2026-06-01');strict.equal(query.snapshotId,'fixture-analysis');
    return {context:{snapshotId:'fixture-analysis',asOf:query.asOf,selectedQuarter:'2026Q1',window:8,
      universeVersion:'fixture-universe',methodologyVersion:'fixture-method',generationId:'fixture-generation'},
      sourceRefs:['sf1:verified-a','sf1:verified-b']};
  }};
  const record=saveResearchRecord(s,'alice',{operationId:'ai_research_record_01',ticker:'ISRG',asOf:'2026-06-01',
    question:'Does revenue growth convert into cash?',supportingEvidence:'reviewed',opposingEvidence:'capex rising',
    evidenceRefs:['client:untrusted'],discoveryOrigin:'ai_insights',
    discoveryContext:{snapshotId:'fixture-analysis',quarter:'2026Q1',window:8,group:'hardware',tickers:['CRDO','ALAB'],revenue:999}});
  strict.deepEqual(record.evidenceRefs,['sf1:verified-a','sf1:verified-b']);
  strict.equal(record.discoveryContext.generationId,'fixture-generation');
  strict.equal(record.discoveryContext.revenue,undefined);
  strict.deepEqual(record.discoveryContext.compareTickers,['CRDO','ALAB']);
  strict.equal(record.personalScenarioId,null);
  strict.throws(()=>saveResearchRecord(s,'alice',{operationId:'ai_research_record_02',ticker:'ISRG',asOf:'2026-06-01',
    question:'Invalid snapshot',discoveryOrigin:'ai_insights',discoveryContext:{}}),/ai_insights_snapshot_required/);
  store.close();
});
test('fundamental workbench origins preserve evidence and support the all-company screen below 15 percent growth',t=>{
  const {service:s,store}=setup(),db=new DatabaseSync(':memory:');t.after(()=>{store.close();db.close();});
  db.exec(`CREATE TABLE valuation_pit_model_runs(ticker TEXT,as_of_date TEXT,model_version TEXT,fiscal_period TEXT,financial_available_at TEXT,guidance_max_observed_at TEXT,input_json TEXT,output_json TEXT);
    CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT);`);
  const input={sourceRecord:{reportperiod:'2026-03-31',datekey:'2026-04-20',currency:'USD',dimension:'ARQ'},financial:{revenue_growth_pct:5},trailingTwelveMonths:{revenue_m:100,operating_income_m:20,fcf_after_capex_m:10},valuationSemantics:{scoreInputs:{modelRoute:'operating_company'},fairValueFormula:'test'}};
  db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?,?,?,?,?)').run('ISRG','2026-04-20','v1','2026-Q1','2026-04-20',null,JSON.stringify(input),'{"fairValue":100}');
  s.source.db=db;const scenario=save(s);
  const body={ticker:'ISRG',asOf:scenario.asOf,operationId:'fundamental_decision_01',action:'Watch',scenarioId:scenario.id,units:0,targetWeight:0,notes:'Business change research',discoveryOrigin:'fundamental_research'};
  const result=s.saveDecision('alice',body);
  strict.equal(result.discoveryOrigin.kind,'fundamental_research');strict.equal(result.discoveryOrigin.ruleVersion,'fundamental-changes-v1');
  strict.deepEqual(result.discoveryOrigin.matchedScreens,[]);strict.equal(result.discoveryOrigin.sourceHash.length,64);
  strict.equal(s.store.list('bob','decision').length,0);
  db.exec(`UPDATE valuation_pit_model_runs SET input_json=json_set(input_json,'$.valuationSemantics.scoreInputs.modelRoute','bank')`);s.source={...s.source};
  strict.throws(()=>s.saveDecision('alice',{...body,operationId:'fundamental_decision_bad'}),/invalid_fundamental_company/);
});
test('two issuers save different deterministic scenario results',()=>{const{service:s,store}=setup();const a=save(s),b=save(s,'MSFT');near(b.result.fairValue,a.result.fairValue*2);store.close();});
test('snapshots survive close/reopen and SQL UPDATE/DELETE is prohibited',()=>{
  const{service:s,store,file}=setup();const a=save(s),d=decide(s,a);store.close();const reopened=new InvestmentStore(file);
  strict.deepEqual(reopened.get('alice',d.id),d);strict.throws(()=>reopened.db.prepare('UPDATE investment_events SET ticker=?').run('B'));
  strict.throws(()=>reopened.db.exec('DELETE FROM investment_events'));reopened.close();
});
test('cross-owner scenario reads and decisions are rejected',()=>{
  const{service:s,store}=setup();const a=save(s);strict.throws(()=>store.get('bob',a.id));strict.throws(()=>decide(s,a,'bob'));store.close();
});
test('idempotency returns same event and conflicts are rejected',()=>{
  const{service:s,store}=setup();strict.equal(save(s).id,save(s).id);
  const c=s.research('alice','ISRG','2026-06-01');strict.throws(()=>s.saveScenario('alice',{ticker:'ISRG',asOf:'2026-06-01',operationId:'scenario_ISRG_2026-06-01_first',snapshotId:c.snapshot.id,name:'Different',assumptions,ownershipConfirmed:true}));store.close();
});
test('PIT update changes base, not saved forecasts, and triggers review',()=>{
  const{service:s,store}=setup();const a=save(s),d=decide(s,a),original=signature(store.get('alice',d.id));
  const c=s.reviewContext('alice',d.id,'2026-08-01');strict.equal(c.reviewRequired,true);near(c.sameAssumptions.fairValue,a.result.fairValue*1.1);
  strict.equal(signature(store.get('alice',d.id)),original);strict.deepEqual(c.activeScenario.assumptions,a.assumptions);store.close();
});
test('Maintain records review and clears same-period attention without rewriting scenario',()=>{
  const{service:s,store}=setup();const a=save(s),d=decide(s,a);const c=s.reviewContext('alice',d.id,'2026-08-01');
  const r=s.saveReview('alice',{operationId:'maintain_review_01',decisionId:d.id,asOf:'2026-08-01',expectedHeadId:c.headId,action:'Maintain',notes:'Thesis unchanged'});
  strict.equal(r.scenario.id,a.id);strict.equal(s.home('alice','2026-08-01').attention.length,0);
  strict.equal(store.list('alice','scenario').length,1);store.close();
});
test('Change requires new version; stale review write and backdated review rejected',()=>{
  const{service:s,store}=setup();const a=save(s),d=decide(s,a),b=save(s,'ISRG','alice','2026-08-01',a.id);
  const command={operationId:'change_review_01',decisionId:d.id,asOf:'2026-08-01',expectedHeadId:d.id,action:'Change',notes:'Updated model',scenarioId:b.id};
  const r=s.saveReview('alice',command);strict.equal(r.scenario.id,b.id);strict.equal(store.get('alice',d.id).scenario.id,a.id);
  strict.throws(()=>s.saveReview('alice',{...command,operationId:'change_review_02'}));
  strict.throws(()=>s.saveReview('alice',{...command,operationId:'change_review_03',asOf:'2026-06-01'}));store.close();
});
test('future review or decision cannot leak into historical portfolio',()=>{
  const{service:s,store}=setup();const a=save(s),d=decide(s,a);
  s.saveReview('alice',{operationId:'exit_review_001',decisionId:d.id,asOf:'2026-08-01',expectedHeadId:d.id,action:'Exit',notes:'Exit paper position'});
  strict.equal(s.portfolio('alice','2026-05-01').positions.length,0);
  strict.equal(s.portfolio('alice','2026-06-01').positions.length,1);
  strict.equal(s.portfolio('alice','2026-08-01').positions.length,0);store.close();
});
test('missing CTA does not produce zero risk or invented diversification',()=>{const{service:s,store}=setup();const b=s.portfolio('alice','2026-08-01');strict.equal(b.cta.metrics,null);strict.equal(b.combinedRisk,null);store.close();});
test('unknown or mismatched price currency cannot become zero portfolio value',()=>{
  const{service:s,store}=setup();decide(s,save(s));
  for(const price of [{value:null,currency:'USD'},{value:50,currency:'GBP'}]){
    s.source.price=()=>price;const b=s.portfolio('alice','2026-08-01');strict.equal(b.totals[0].marketValue,null);strict.equal(b.totals[0].unpriced,1);strict.equal(b.positions[0].weight,null);
  }store.close();
});
test('missing comparison price disables reverse solve, never the forward DCF',()=>{
  const{service:s,store}=setup();const r=s.calculate({ticker:'ISRG',asOf:'2026-06-01',assumptions,reversePrice:null});
  near(r.result.fairValue,calculateScenario(base,assumptions).fairValue);strict.equal(r.reverse.status,'unavailable');strict.equal(r.reverse.value,null);store.close();
});
test('new scenario versions and review histories obey the research cutoff',()=>{
  const{service:s,store}=setup();const a=save(s),d=decide(s,a);save(s,'ISRG','alice','2026-08-01',a.id);
  s.saveReview('alice',{operationId:'history_review_001',decisionId:d.id,asOf:'2026-08-01',expectedHeadId:d.id,action:'Maintain',notes:'Saved history'});
  strict.equal(s.research('alice','ISRG','2026-06-01').scenarios.length,1);
  strict.equal(s.reviewContext('alice',d.id,'2026-06-01').reviewHistory.length,0);
  strict.equal(s.reviewContext('alice',d.id,'2026-08-01').reviewHistory.length,1);store.close();
});
test('only explicitly selected discovery managers enter monitoring',()=>{
  const{service:s,store}=setup();const c=s.source.company.bind(s.source);
  s.source.company=(...args)=>({...c(...args),provenance:[{guruId:'one',availableAt:'2026-05-15'},{guruId:'two',availableAt:'2026-05-15'}]});
  const a=save(s);const d=decide(s,a);strict.deepEqual(d.discovery,[]);
  const m=save(s,'MSFT');const selected=s.saveDecision('alice',{ticker:'MSFT',asOf:m.asOf,operationId:'explicit_discovery_001',action:'Watch',scenarioId:m.id,units:0,targetWeight:0,notes:'Selected source',sourceGuruIds:['two'],discoveryOrigin:'guru_disclosure'});
  strict.deepEqual(selected.discovery.map(x=>x.guruId),['two']);store.close();
});
test('paper position changes invalidate unreconciled cost lots',()=>{
  const{service:s,store}=setup();const d=decide(s,save(s));strict.equal(s.portfolio('alice','2026-06-01').positions[0].cost,500);
  s.saveReview('alice',{operationId:'add_review_001',decisionId:d.id,asOf:'2026-08-01',expectedHeadId:d.id,action:'Add',notes:'Research allocation only',units:15});
  strict.equal(s.portfolio('alice','2026-08-01').positions[0].cost,null);strict.equal(s.reviewContext('alice',d.id,'2026-08-01').activeUnits,15);store.close();
});
test('HTTP routes require identity, ignore supplied owner, and do not cache private payloads',async()=>{
  const{service:s,store}=setup();const app=express();app.use(express.json());app.use((r,_,next)=>{if(r.headers['x-test-user'])r.user={id:r.headers['x-test-user']};next();});registerInvestmentRoutes(app,s);
  const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));const url=`http://127.0.0.1:${server.address().port}`;
  try{
    strict.equal((await fetch(url+'/api/investment/home')).status,401);const a=save(s);
    const r=await fetch(url+'/api/investment/research/ISRG?asOf=2026-06-01&owner=alice',{headers:{'x-test-user':'bob'}});
    strict.match(r.headers.get('cache-control'),/no-store/);strict.deepEqual((await r.json()).scenarios,[]);strict.ok(a.id);
    const holdings=await fetch(url+'/api/investment/guru-holdings?asOf=2026-06-01',{headers:{'x-test-user':'alice'}});
    strict.equal(holdings.status,200);strict.match(holdings.headers.get('cache-control'),/max-age=300/);
    strict.ok(holdings.headers.get('etag'));const holdingsPayload=await holdings.json();
    strict.ok(Array.isArray(holdingsPayload.gurus));
    strict.ok(holdingsPayload.gurus.every(g=>typeof g.followed==='boolean'));
  }finally{await new Promise(r=>server.close(r));store.close();}
});

test('multi-method FCFE worksheet preserves cash flows and discloses post-DCF adjustments',()=>{
  const forecast=calculateScenario(base,assumptions);
  const dcf={discountRate:.1,terminalGrowth:.025,fairValue:forecast.fairValue*.96,
    annualCashFlows:forecast.forecast.map(r=>({growth:r.growth,fcfM:r.fcfeM}))};
  const score={modelRoute:'multi_method_growth',methodWeights:{'fcfe-dcf':.32},revenueGrowth:30,valuationRevenue:1300,equityDcf:dcf,cycleHaircut:.96};
  const pkg=personalScenarioPackage(base,score,true);
  near(pkg.templates.Base.growth[0],.3);
  const result=calculateScenario(base,pkg.templates.Base);
  for(let i=0;i<5;i++)near(result.forecast[i].fcfeM,forecast.forecast[i].fcfeM);
  near(result.forecast[0].revenueM,1300);
  near(result.fairValue,forecast.fairValue);
  near(pkg.reconciliation.difference,forecast.fairValue*.04);
  near(pkg.reconciliation.publishedDcfValue,dcf.fairValue);
  strict.equal(result.netDebtDeductedM,0);
});
test('personal worksheet route allowlist still excludes financial/NCI/customer cash and mixed currencies',()=>{
  const dcf={discountRate:.1,terminalGrowth:.025,annualCashFlows:Array.from({length:5},()=>({growth:.1,fcfM:200}))};
  const score={modelRoute:'multi_method_growth',methodWeights:{'fcfe-dcf':.32},equityDcf:dcf};
  for(const route of ['bank','customer_cash_flow','insurance','lseg_parent_economic','unknown'])
    strict.equal(personalScenarioPackage(base,{...score,modelRoute:route},true).templates,null);
  strict.equal(personalScenarioPackage(base,score,false).templates,null);
  strict.equal(personalScenarioPackage(base,{...score,methodWeights:{}},true).templates,null);
  strict.equal(personalScenarioPackage({...base,sharesM:null},score,true).templates,null);
});
test('mechanical stresses stay valid at supported growth and Ke bounds',()=>{
  for(const growth of [-.94,2]) {
    const dcf={discountRate:.04,terminalGrowth:0,annualCashFlows:Array.from({length:5},(_,i)=>({growth,fcfM:200*(1+growth)**i}))};
    const templates=scenarioTemplates(base,dcf,[0,growth,growth,growth,growth]);
    strict.ok(templates);
    Object.values(templates).forEach(validateScenario);
  }
});
test('TTM anchors do not become zero first-year growth; cash flows and published value remain unchanged',()=>{
  const b={...base,revenueM:1000};
  const dcf={discountRate:.09,terminalGrowth:.025,initialGrowth:.15,
    annualCashFlows:[0,.12,.09,.06,.025].map((growth,i)=>({year:i+1,growth,fcfM:200+i*20}))};
  for(const reportedGrowth of [.15,0,-.1]) {
    const score={modelRoute:'operating_company',methodWeights:{'fcfe-dcf':.26},equityDcf:dcf,
      revenueGrowth:reportedGrowth*100,valuationRevenue:1000,forwardRevenueYears:0};
    const before=signature(score),p=personalScenarioPackage(b,score,true);
    near(p.templates.Base.growth[0],reportedGrowth);
    near(p.templates.Base.growth[4],.025);
    const result=calculateScenario(b,p.templates.Base);
    dcf.annualCashFlows.forEach((r,i)=>near(result.forecast[i].fcfeM,r.fcfM));
    strict.equal(signature(score),before);
    strict.equal(p.reconciliation.startingForecast.notManagementGuidance,true);
  }
});
test('quarter and fiscal-year valuation bases never override rolling forecast growth, and missing is not zero',()=>{
  const dcf={discountRate:.09,terminalGrowth:.025,initialGrowth:.15,
    annualCashFlows:[0,.12,.09,.06,.025].map((growth,i)=>({year:i+1,growth,fcfM:200+i*20}))};
  const score={modelRoute:'multi_method_growth',methodWeights:{'fcfe-dcf':.32},equityDcf:dcf,revenueGrowth:18};
  for(const source of ['full_year_guidance','quarterly_guidance_blend','formula_forward']) {
    const p=personalScenarioPackage(base,{...score,valuationRevenue:800,forwardRevenueSource:source},true);
    near(p.templates.Base.growth[0],.18);
  }
  near(personalScenarioPackage(base,{...score,revenueGrowth:null},true).templates.Base.growth[0],.15);
  strict.equal(personalScenarioPackage(base,{...score,revenueGrowth:null,equityDcf:{...dcf,initialGrowth:null}},true).templates,null);
  strict.equal(scenarioTemplates(base,dcf),null);
});
test('earnings-only company gets a labeled computable analyst seed, with no published value changes',()=>{
  const b={...base,fcfM:-12};
  const score={modelRoute:'operating_company',methodWeights:{'fcfe-dcf':0,'normalized-earnings-power':1},equityDcf:null};
  const before=signature(score),p=personalScenarioPackage(b,score,true);
  strict.equal(signature(score),before);
  near(p.templates.Base.growth[0],.05);near(p.templates.Base.growth[4],.025);
  strict.deepEqual(p.templates.Base.margin,Array(5).fill(.03));
  strict.equal(p.reconciliation.startingForecast.marginBasis,'illustrative_3_percent');
  strict.equal(p.reconciliation.startingForecast.recoveryAssumed,true);
  strict.equal(p.reconciliation.publishedDcfValue,null);
  strict.equal(p.reconciliation.basis,'user_defined_cashflow_path');
  strict.ok(calculateScenario(b,p.templates.Base).fairValue>0);
  const a={...p.templates.Base,growth:Array(5).fill(.1),margin:Array(5).fill(.2)};
  near(calculateScenario(b,a).fairValue,calculateScenario(base,assumptions).fairValue);
});
test('blank private route does not bypass security, currency, actual-base or broken-DCF gates',()=>{
  const score={modelRoute:'operating_company',methodWeights:{'fcfe-dcf':0},equityDcf:null};
  for(const route of ['bank','insurance','customer_cash_flow','lseg_parent_economic','unknown'])
    strict.equal(personalScenarioPackage(base,{...score,modelRoute:route},true).templates,null);
  strict.equal(personalScenarioPackage(base,score,false).templates,null);
  for(const field of ['sharesM','revenueM'])for(const value of [null,0,-1,NaN])
    strict.equal(personalScenarioPackage({...base,[field]:value},score,true).templates,null);
  strict.equal(personalScenarioPackage(base,{...score,methodWeights:{'fcfe-dcf':.4}},true).templates,null);
});
test('independent starting hypotheses calculate and persist separately from published value',()=>{
  const {service:s,store}=setup();
  const original=s.source.company.bind(s.source);
  s.source.company=(...args)=>{const c=original(...args),p=personalScenarioPackage(c.base,{modelRoute:'operating_company',methodWeights:{'fcfe-dcf':0},equityDcf:null},true);
    return {...c,templates:p.templates,templateReconciliation:p.reconciliation,published:{fairValue:99,dcf:null}};};
  const company=s.research('alice','ISRG','2026-06-01');
  const body={ticker:'ISRG',asOf:'2026-06-01',snapshotId:company.snapshot.id,assumptions};
  const result=s.calculate(body);
  near(result.templateResults.Base,calculateScenario(company.base,company.templates.Base).fairValue);
  near(result.result.fairValue,calculateScenario(company.base,assumptions).fairValue);
  strict.ok(s.calculate({...body,assumptions:company.templates.Base}).result.fairValue>0);
  const saved=s.saveScenario('alice',{...body,operationId:'independent_manual_01',name:'My forecast',hypothesis:'Synthetic QA only',ownershipConfirmed:true});
  strict.equal(saved.templateReconciliation.basis,'user_defined_cashflow_path');
  strict.equal(s.research('bob','ISRG','2026-06-01').scenarios.length,0);
  strict.equal(s.research('alice','ISRG','2026-06-01').scenarios[0].id,saved.id);
  strict.deepEqual(s.research('alice','ISRG','2026-06-01').published,{fairValue:99,dcf:null});
  store.close();
});
test('personal revenue edit is represented once by growth, with future rates unchanged',()=>{
  const a={...assumptions,growth:[.1,1500/1100-1,.1,.1,.1]};
  const r=calculateScenario(base,a);
  near(r.forecast[1].revenueM,1500);near(r.forecast[2].revenueM,1650);
  near(r.forecast[1].fcfeM,300);
  near(reverseScenario(base,a,r.fairValue,'terminal_margin').value,.2);
});
test('saved hypothesis and calculation persist per owner across reopening with immutable parent versions',()=>{
  const {service:s,store,file}=setup();const c=s.research('alice','ISRG','2026-06-01');
  const request={ticker:'ISRG',asOf:c.asOf,snapshotId:c.snapshot.id,operationId:'hypothesis_alice_001',name:'  Margin thesis  ',hypothesis:'Revenue grows; cash conversion holds.',ownershipConfirmed:true,assumptions};
  const a=s.saveScenario('alice',request);
  const b=s.saveScenario('alice',{...request,operationId:'hypothesis_alice_002',parentId:a.id,hypothesis:'Lower year-two margin.',assumptions:{...assumptions,margin:[.2,.15,.2,.2,.2]}});
  strict.equal(b.version,2);strict.equal(b.parentId,a.id);strict.notEqual(b.result.fairValue,a.result.fairValue);
  strict.deepEqual(s.saveScenario('alice',request),a);
  strict.equal(s.research('bob','ISRG',c.asOf).scenarios.length,0);
  strict.throws(()=>s.saveScenario('bob',{...request,operationId:'hypothesis_bob_001',parentId:a.id}),/record_not_found/);
  store.close();const reopened=new InvestmentStore(file);
  strict.equal(reopened.get('alice',a.id).hypothesis,request.hypothesis);
  strict.equal(reopened.get('alice',a.id).name,'Margin thesis');
  strict.equal(reopened.get('alice',b.id).hypothesis,'Lower year-two margin.');
  strict.deepEqual(reopened.get('alice',b.id).result,calculateScenario(base,b.assumptions));
  strict.equal(reopened.list('bob','scenario').length,0);reopened.close();
});
test('invalid hypothesis and stale snapshot cannot be saved or calculated',()=>{
  const {service:s,store}=setup();const c=s.research('alice','ISRG','2026-06-01');
  const request={ticker:'ISRG',asOf:c.asOf,snapshotId:c.snapshot.id,operationId:'invalid_hypothesis_001',name:'Case',ownershipConfirmed:true,assumptions};
  for(const hypothesis of [12,{text:'bad'},'x'.repeat(4001)])strict.throws(()=>s.saveScenario('alice',{...request,hypothesis}),/invalid_hypothesis/);
  strict.throws(()=>s.calculate({...request,snapshotId:'stale'}),/actual_base_changed_reload/);
  strict.equal(store.list('alice').length,0);store.close();
});
test('HTTP save and reload use authenticated owner, never caller-supplied owner or result',async()=>{
  const {service:s,store}=setup();const app=express();app.use(express.json());
  app.use((r,_,next)=>{if(r.headers['x-test-user'])r.user={id:r.headers['x-test-user']};next();});registerInvestmentRoutes(app,s);
  const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));const root=`http://127.0.0.1:${server.address().port}/api/investment`;
  const body={ticker:'ISRG',asOf:'2026-06-01',snapshotId:s.research('alice','ISRG','2026-06-01').snapshot.id,operationId:'http_private_worksheet_001',name:'Private',hypothesis:'Private assumption',assumptions,ownershipConfirmed:true,owner:'bob',result:{fairValue:999999}};
  try {
    const post=await fetch(root+'/scenarios',{method:'POST',headers:{'Content-Type':'application/json','x-test-user':'alice'},body:JSON.stringify(body)});
    strict.equal(post.status,200);strict.match(post.headers.get('cache-control'),/private, no-store/);
    const saved=await post.json();near(saved.result.fairValue,calculateScenario(base,assumptions).fairValue);
    for(const owner of ['alice','bob']){
      const r=await fetch(root+'/research/ISRG?asOf=2026-06-01&owner=alice',{headers:{'x-test-user':owner}});
      const result=await r.json();strict.equal(result.scenarios.length,owner==='alice'?1:0);
    }
    const unauth=await fetch(root+'/scenarios',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});strict.equal(unauth.status,401);
  } finally {await new Promise(r=>server.close(r));store.close();}
});
