import fs from 'node:fs';
import assert from 'node:assert/strict';
const [reportFile] = process.argv.slice(2);
if (!reportFile || fs.existsSync(reportFile)) throw Error('Pass a NEW private report file');
const base='http://127.0.0.1:8789/api/investment',headers={Authorization:'Bearer local-dev-token','Content-Type':'application/json'};
const catalog=await (await fetch(base+'/strategy-lab?asOf=2026-09-10',{headers})).json();
assert.equal(catalog.storage.cutoff,'2026-09-10');
for(const symbol of ['KMLM','DBMF'])assert.equal(catalog.etfs.find(e=>e.ticker===symbol).last,'2026-09-10');
const original={asOf:'2026-09-10',start:'2021-09-10',end:'2026-09-10',managers:['bill-ackman'],topN:5,
  valuationEnabled:true,maxPremium:.3,excludedAllocation:'fully_invested',cta:'KMLM',ctaWeight:.3,costBps:10,
  leverage:{multiple:1,annualRate:.04,reset:'filing'}};
const cases=[
  {name:'exact screenshot',rules:original,status:'blocked'},
  {name:'unfiltered control',rules:{...original,valuationEnabled:false},status:'ready'},
  {name:'DBMF 50% control',rules:{...original,valuationEnabled:false,cta:'DBMF',ctaWeight:.5},status:'ready'},
  {name:'1.5x control',rules:{...original,valuationEnabled:false,leverage:{...original.leverage,multiple:1.5}},status:'ready'},
];
const checks=[];
for(const item of cases){
  const r=await fetch(base+'/strategy-backtests',{method:'POST',headers,body:JSON.stringify(item.rules),signal:AbortSignal.timeout(60000)});
  assert.equal(r.status,200); const body=await r.json();assert.equal(body.status,item.status,item.name);
  assert.equal(body.sources.generation,catalog.storage.generation);
  if(item.status==='blocked')assert.equal(body.failure.code,'no_eligible_stocks');
  const curves=Object.fromEntries(Object.entries(body.results??{}).filter(([,v])=>v.status==='ready').map(([k,v])=>{
    assert.equal(v.equity.at(-1).date,'2026-09-10');return [k,{rows:v.equity.length,last:v.equity.at(-1).date}];
  }));
  checks.push({name:item.name,status:body.status,failure:body.failure?.code??null,curves,snapshots:body.holdingSnapshots?.length??0});
}
const stale=await fetch(base+'/strategy-backtests',{method:'POST',headers,body:JSON.stringify({...original,asOf:'2026-09-11',end:'2026-09-11'})});
assert.equal(stale.status,422);const staleBody=await stale.json();
// The local API uses UTC: before September 11 UTC it rejects future_as_of
// first; afterwards the database's actual September 10 cutoff must reject it.
assert.ok(['future_as_of','strategy_database_cutoff_exceeded'].includes(staleBody.error));
const quotes=[];
for(const ticker of ['AMZN','MSFT','NVDA']){
  const r=await fetch(`${base}/research/${ticker}?asOf=2026-09-10`,{headers});assert.equal(r.status,200);const body=await r.json();
  assert.equal(body.priceHistory.at(-1).date,'2026-09-10');assert.ok(body.snapshot.availableAt<'2026-09-10');
  quotes.push({ticker,priceDate:body.priceHistory.at(-1).date,financialPublicationDate:body.snapshot.availableAt});
}
const report={status:'pass',scope:'local date/CTA/worker/research smoke; controls are not original filtered result',generation:catalog.storage.generation,
  storage:catalog.storage,checks,quotes,laterEndRejected:staleBody.error,savedRulesWritten:0};
fs.writeFileSync(reportFile,JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
console.log(JSON.stringify({status:report.status,generation:report.generation,checks,quotes}));
