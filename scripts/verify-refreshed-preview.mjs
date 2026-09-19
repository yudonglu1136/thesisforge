// Loopback-only smoke tests; computes research runs but never saves user rules.
import fs from 'node:fs';
import assert from 'node:assert/strict';
const [origin,out]=process.argv.slice(2),base=new URL(origin);
assert.ok(base.protocol==='http:'&&base.hostname==='127.0.0.1'&&out&&!fs.existsSync(out));
const headers={Authorization:'Bearer local-dev-token','Content-Type':'application/json'},rows=[];
const get=async p=>{const r=await fetch(new URL(p,base),{headers});assert.equal(r.status,200);return r.json();};
const catalog=await get('/api/investment/strategy-lab?asOf=2026-09-11');
assert.equal(catalog.storage.cutoff,'2026-09-11');assert.equal(catalog.managers.length,32);
for(const symbol of ['KMLM','DBMF'])assert.equal(catalog.etfs.find(x=>x.ticker===symbol).last,'2026-09-11');
assert.equal((await fetch(new URL('/api/investment/strategy-lab?asOf=2026-09-11',base))).status,401);
const rules={managers:[],topN:5,valuationEnabled:false,maxPremium:.3,excludedAllocation:'fully_invested',cta:'none',ctaWeight:0,costBps:10,
  start:'2021-09-11',end:'2026-09-11',asOf:'2026-09-11',leverage:{multiple:1,annualRate:.04,reset:'filing'}};
const cases=[
  {name:'QQQ_KMLM_annual_1.5x',equityMix:{weights:{QQQ:1}},cta:'KMLM',ctaWeight:.3,ctaPolicy:{mode:'scheduled',frequency:'annually'},leverage:{multiple:1.5,annualRate:.04,reset:'filing'}},
  ...[null,.3,.5].map(p=>({name:`four_factors_${p??'off'}`,equityMix:{weights:{factors:1}},valuationEnabled:p!==null,maxPremium:p??.3})),
  {name:'growth_5y',equityMix:{weights:{factors:1},factors:{enabled:['growth'],rankBy:'growth'}}},
  {name:'operating_margin_5y',equityMix:{weights:{factors:1},factors:{enabled:['operatingMargin'],rankBy:'operatingMargin'}}},
  {name:'guru_annual_cta',managers:['bill-ackman','chris-hohn','dev-kantesaria'],equityMix:{weights:{guru:1}},valuationEnabled:true,maxPremium:.61,
    cta:'KMLM',ctaWeight:.3,ctaPolicy:{mode:'scheduled',frequency:'annually'}}];
for(const {name,...config} of cases){
  const start=performance.now();
  const r=await fetch(new URL('/api/investment/strategy-backtests',base),{method:'POST',headers,body:JSON.stringify({...rules,...config})});
  const result=await r.json();assert.equal(r.status,200,JSON.stringify(result));
  assert.equal(result.sources.generation,catalog.storage.generation);
  assert.ok(['ready','blocked'].includes(result.status));
  if(result.status==='ready'){
    assert.equal(result.results.blend.equity.at(-1).date,'2026-09-11');
    assert.ok(result.holdingSnapshots.length>0);
    for(const s of result.holdingSnapshots){assert.equal(s.cashWeight,0);assert.ok(Math.abs(s.positions.reduce((n,p)=>n+p.weight,0)-1)<1e-8);}
  }else assert.ok(result.failure?.code);
  const row={name,status:result.status,ms:Math.round(performance.now()-start),failure:result.failure??null,
    snapshots:result.holdingSnapshots.length,curves:Object.fromEntries(Object.entries(result.results).map(([k,v])=>[k,{status:v.status,last:v.equity?.at(-1)?.date,metrics:v.metrics}]))};
  rows.push(row);console.log(JSON.stringify({...row,curves:undefined}));
}
fs.writeFileSync(out,JSON.stringify({origin,cutoff:catalog.storage.cutoff,generation:catalog.storage.generation,managers:catalog.managers.length,
  anonymous:401,scope:'Loopback authenticated API; computed only; no user rules saved. Explicit source/rule blocks are not ready runs.',rows},null,2),{flag:'wx',mode:0o600});
