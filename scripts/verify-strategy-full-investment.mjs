// Read-only, local HTTP acceptance for the user's original five-year basket.
// Does not save strategy rules or mutate the source database.
import assert from 'node:assert/strict';
import fs from 'node:fs';
const [out,base='http://127.0.0.1:8789']=process.argv.slice(2);
assert.ok(out&&!fs.existsSync(out),'supply a NEW output directory');
assert.ok(['127.0.0.1','localhost'].includes(new URL(base).hostname),'local only');
const token=process.env.STRATEGY_VERIFY_TOKEN;assert.ok(token,'STRATEGY_VERIFY_TOKEN required');
const rules={managers:['dev-kantesaria','li-lu','samantha-mclemore'],topN:5,
 valuationEnabled:true,maxPremium:.27,excludedAllocation:'fully_invested',cta:'KMLM',ctaWeight:.3,
 costBps:10,start:'2021-08-28',end:'2026-08-28',asOf:'2026-08-28',leverage:{multiple:1,annualRate:.04,reset:'filing'}};
const cases=[
 ['screenshot',{}],['default-30',{maxPremium:.3}],['no-valuation',{valuationEnabled:false}],
 ['no-cta',{cta:'none',ctaWeight:0}],['dbmf-half',{cta:'DBMF',ctaWeight:.5}],
 ['leveraged',{leverage:{multiple:1.5,annualRate:.04,reset:'filing'}}],
];
fs.mkdirSync(out,{mode:0o700});const report=[];
for(const [name,change] of cases){
 const requested={...rules,...change};
 const response=await fetch(base+'/api/investment/strategy-backtests',{method:'POST',
  headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(requested),signal:AbortSignal.timeout(60000)});
 assert.equal(response.status,200);assert.match(response.headers.get('cache-control')??'',/private/);
 const result=await response.json();assert.equal(result.status,'ready',name+': '+JSON.stringify(result.failure));
 assert.deepEqual(result.requested,{start:rules.start,end:rules.end});
 const snapshots=result.holdingSnapshots;
 assert.ok(snapshots.length>0);assert.equal(snapshots.length,result.ledger.length);
 const curve=requested.leverage.multiple>1?result.results.leveraged.equity:result.results.blend.equity;
 for(const [i,s] of snapshots.entries()){
  assert.equal(s.cashWeight,0);assert.ok(Math.abs(s.positions.reduce((v,h)=>v+h.weight,0)-1)<1e-10);
  assert.equal(s.date,result.ledger[i].executionDate);
  assert.equal(s.nav,curve.find(point=>point.date===s.date).value);
  assert.ok(s.filings.every(f=>f.publicDate<s.date));
  const stocks=s.positions.filter(h=>h.kind==='stock');assert.ok(stocks.length>0);
  stocks.forEach(h=>assert.ok(Math.abs(h.weight-(1-requested.ctaWeight)/stocks.length)<1e-10));
 }
 fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(result),{flag:'wx',mode:0o600});
 const row={name,status:'pass',observations:curve.length,snapshots:snapshots.length,
  cashWeights:[...new Set(snapshots.map(s=>s.cashWeight))],firstDate:snapshots[0].date,
  firstPositions:snapshots[0].positions.map(({ticker,weight})=>({ticker,weight}))};report.push(row);console.log(JSON.stringify(row));
}
fs.writeFileSync(out+'/summary.json',JSON.stringify({status:'pass',savedRulesWritten:0,report},null,2),{flag:'wx',mode:0o600});
