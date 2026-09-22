import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { earningsPeriod, earningsResearch, visibleEarningsQa } from './investmentEarnings.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

const qa=(p='Q12026',date='2026-04-20')=>({ticker:'TEST',fiscalPeriod:p,callDate:date,question:'Synthetic question?',answer:'Synthetic management answer.',questionZh:'测试问题？',answerZh:'测试回答。',url:'https://example.com/call'});
const transcript=(p='Q12026',date='2026-04-20')=>({qaCoverage:{ticker:'TEST',fiscalPeriod:p,status:'has_qa',callDate:date,researchAvailableAt:date,url:'https://example.com/call'},qa:[qa(p,date)]});
function setup(){
  const db=new DatabaseSync(':memory:');
  db.exec('CREATE TABLE valuation_ticker_snapshots(ticker TEXT, payload_json TEXT)');
  const rows=[['2026-Q1','2026-04-20'],['2026-Q2','2026-07-20']];
  const nodes=rows.map(([period,date],i)=>({period,periodEnd:i?'2026-06-30':'2026-03-31',availableAt:date,
    metrics:{revenueGrowth:.2+i*.1,operatingMargin:.3,fcfMargin:null,capexIntensity:0},actual:{revenueM:100+i*20},
    source:{dataset:'Synthetic fixture',modelVersion:'v1',hash:'test',url:null},input:{sourceRecord:{currency:'USD'}},
    publishedFairValue:100+i*10,publishedFormula:'fixture',guidance:{evidence:[
      {fiscalPeriod:period,observedAt:date,excerpt:`Synthetic ${period} guidance.`},
      {fiscalPeriod:period,observedAt:'2027-01-01',excerpt:'future forbidden'},
      {fiscalPeriod:'2025-Q1',observedAt:date,excerpt:'wrong quarter forbidden'},
    ]}}));
  const history=rows.map(([p,date],i)=>({fiscalYear:2026,fiscalQuarter:`Q${i+1}`,asOfDate:date,
    dataSnapshot:{youtubeEarnings:transcript(`Q${i+1}2026`,date)},secretUnrelatedField:'do not expose'}));
  db.prepare('INSERT INTO valuation_ticker_snapshots VALUES (?,?)').run('TEST',JSON.stringify({history,unrelated:'hidden'}));
  return {db,periods:(_,asOf)=>nodes.filter(n=>n.availableAt<=asOf),nodes};
}
test('fiscal quarter normalization does not accept guidance years or guess periods',()=>{
  for(const p of ['FY2027 Q2','2027-Q2','Q2 FY2027'])assert.equal(earningsPeriod(p),'2027-Q2');
  for(const p of ['2027','Q5 2027','we guide 2027 Q2',''])assert.equal(earningsPeriod(p),null);
});
test('exact dated quarter selection, prior comparisons, safe source allowlist and no writes',()=>{
  const s=setup();
  const before=s.db.prepare('SELECT payload_json FROM valuation_ticker_snapshots').get().payload_json;
  const r=earningsResearch(s,'test','2026-08-28');
  assert.deepEqual(r.periods.map(p=>p.period),['2026-Q2','2026-Q1']);
  assert.equal(r.selected.period,'2026-Q2');assert.equal(r.selected.model.delta,10);
  assert.equal(r.selected.qa[0].callDate,'2026-07-20');assert.equal(r.selected.qa[0].answerZh,'测试回答。');
  assert.equal(r.selected.guidance.length,1);assert.equal(r.selected.metrics[2].value,null);assert.equal(r.selected.metrics[3].value,0);
  assert.equal(r.selected.includedInValuationInputs,false);
  assert(!JSON.stringify(r).includes('secretUnrelatedField'));assert(!JSON.stringify(r).includes('forbidden'));
  assert.equal(s.db.prepare('SELECT payload_json FROM valuation_ticker_snapshots').get().payload_json,before);
  s.db.close();
});
test('historical cutoff excludes later quarters and explicit unavailable quarter fails closed',()=>{
  const s=setup(),r=earningsResearch(s,'TEST','2026-06-01');
  assert.deepEqual(r.periods.map(p=>p.period),['2026-Q1']);
  assert.equal(r.selected.model.previous,null);
  assert.throws(()=>earningsResearch(s,'TEST','2026-06-01','2026-Q2'),/earnings_period_unavailable/);
  assert.throws(()=>earningsResearch(s,'TEST','2026-06-01','2027'),/invalid_earnings_period/);
  assert.equal(earningsResearch(s,'TEST','2026-01-01').selected,null);s.db.close();
});
test('quarterly guidance uses the same source review and exact selected node as the valuation page',()=>{
  const s=setup(); const seen=[];
  s.reviewGuidance=(ticker,node)=>{seen.push([ticker,node.period,node.availableAt]);return {audit:{status:'review_required'},
    evidence:[{excerpt:'Stored historical actual retained as context.',disposition:'research_only',growthYoy:null}]};};
  const result=earningsResearch(s,'TEST','2026-08-28','2026-Q1');
  assert.deepEqual(seen,[['TEST','2026-Q1','2026-04-20']]);
  assert.equal(result.selected.guidance[0].growthYoy,null);
  assert.equal(result.selected.guidanceAudit.status,'review_required');s.db.close();
});
test('changed model method cannot be presented as a comparable value change',()=>{
  const s=setup();s.nodes[1].publishedFormula='new method';
  assert.equal(earningsResearch(s,'TEST','2026-08-28').selected.model.delta,null);s.db.close();
});
test('call availability and source identities are separately enforced',()=>{
  assert.equal(visibleEarningsQa(transcript(),'OTHER','2026-Q1','2026-08-28').qa.length,0);
  assert.equal(visibleEarningsQa(transcript(),'TEST','2026-Q2','2026-08-28').qa.length,0);
  assert.equal(visibleEarningsQa(transcript(),'TEST','2026-Q1','2026-04-19').qa.length,0);
  const t=transcript();t.qaCoverage.researchAvailableAt='2026-08-01';
  assert.equal(visibleEarningsQa(t,'TEST','2026-Q1','2026-06-01').qa.length,0);
  t.qaCoverage.researchAvailableAt='2026-04-20';t.qa.push({...qa(),ticker:'OTHER'},qa('Q22026'),qa('Q12026','2027-01-01'));
  assert.equal(visibleEarningsQa(t,'TEST','2026-Q1','2026-06-01').qa.length,1);
  t.qaCoverage.callDate=null;t.qaCoverage.researchAvailableAt=null;
  assert.equal(visibleEarningsQa(t,'TEST','2026-Q1','2026-08-28').qa.length,0);
});
test('research route remains authenticated and read-only',async()=>{
  const routes=new Map(),app={get:(p,h)=>routes.set(`GET ${p}`,h),post:()=>{}};
  const source=setup();registerInvestmentRoutes(app,{source,date:d=>d});
  const route=routes.get('GET /api/investment/research/:ticker/earnings');
  let status=200,body,headers={};const res={setHeader:(k,v)=>headers[k]=v,status:s=>{status=s;return res;},json:v=>body=v};
  await route({query:{asOf:'2026-08-28'},params:{ticker:'TEST'}},res);assert.equal(status,401);
  status=200;await route({user:{id:'alice'},query:{asOf:'2026-08-28',period:'2026-Q1'},params:{ticker:'TEST'}},res);
  assert.equal(status,200);assert.equal(body.selected.period,'2026-Q1');assert.equal(headers['Cache-Control'],'private, no-store');
  source.db.close();
});
