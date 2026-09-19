import {test} from 'node:test';
import assert from 'node:assert/strict';
import {reconcileAppend,comparisonExtension,reconcileConfirmedHistory,confirmPriceSeries,validateMarketCutoff,reconcileCtaExtension} from './append-all-local-prices.mjs';

const fresh = Array.from({length: 64}, (_, i) => ({date:new Date(Date.UTC(2026,0,i+1)).toISOString().slice(0,10),
  open:100,high:101,low:99,close:100+i,adjusted_close:(100+i)*.9}));
const old = fresh.slice(0,60).map(p=>({...p,adjusted_close:p.adjusted_close*2}));
test('appends real missing dates on a constant, fully reconciled return basis',()=>{
  const r=reconcileAppend(old,fresh);assert.equal(r.rows.length,4);assert.equal(r.scale,2);
  assert.equal(r.rows[0].adjusted_close,fresh[60].adjusted_close*2);
  assert.equal(old.length,60);
});
test('rejects a split or changed interior closing price',()=>{
  assert.throws(()=>reconcileAppend(old,fresh.map((p,i)=>i===3?{...p,close:p.close/2}:p)),/close_basis/);
});
test('rejects mixed dividend adjustment vintages',()=>{
  assert.throws(()=>reconcileAppend(old,fresh.map((p,i)=>i===3?{...p,adjusted_close:p.adjusted_close*1.02}:p)),/adjusted_return_basis/);
});
test('does not invent a missing day',()=>{
  const r=reconcileAppend(old,[...fresh.slice(0,60),fresh[63]]);assert.equal(r.rows.length,1);
});
test('does not waive overlap evidence',()=>assert.throws(()=>reconcileAppend(old.slice(0,10),fresh),/insufficient/));
test('a comparison quote after a split is blocked until model share basis is reviewed',()=>{
  const snap={currency:'USD',priceHistory:[{date:'2026-08-19',close:100}]};
  assert.throws(()=>comparisonExtension(snap,[],{splits:{a:{date:Date.parse('2026-09-01')/1000}}},'USD','2026-09-10'),/split/);
});
test('only appends newer comparison quotes and keeps old ones immutable',()=>{
  const snap={currency:'USD',priceHistory:[fresh[61]]},before=JSON.stringify(snap);
  const r=comparisonExtension(snap,fresh,{},'USD','2026-09-10');assert.equal(r.rows.length,2);
  assert.equal(r.rows[0].adjusted_close,null);assert.equal(JSON.stringify(snap),before);
});
test('unknown currencies cannot be silently converted',()=>{
  assert.throws(()=>comparisonExtension({currency:'USD',priceHistory:[fresh[0]]},fresh,{},'GBp','2026-09-10'),/currency/);
});
test('confirmed full history supplies absent adjusted fields without treating null as zero',()=>{
  const r=reconcileConfirmedHistory(old.map(p=>({...p,adjusted_close:null})),fresh);
  assert.equal(r.rows.length,64);assert.equal(r.scale,1);
});
test('confirmed full history still rejects an incompatible existing close',()=>{
  assert.throws(()=>reconcileConfirmedHistory([{...old[0],close:900}],fresh),/close_conflict/);
});
test('confirmation tolerates float representation within the existing adjusted-series contract',()=>{
  const c=new Map(fresh.map((p,i)=>[p.date,{close:p.close,adj:p.adjusted_close*(1+(i%2)*2e-7)}]));
  assert.equal(confirmPriceSeries(fresh,c).overlap,64);
});
test('confirmation cannot authorize a changed close or dividend adjustment',()=>{
  const c=new Map(fresh.map(p=>[p.date,{close:p.close,adj:p.adjusted_close}]));
  c.set(fresh[4].date,{close:fresh[4].close,adj:fresh[4].adjusted_close*1.002});
  assert.throws(()=>confirmPriceSeries(fresh,c),/adjustment/);
});
test('market date advance requires the exact completed benchmark session',()=>{
  const now=new Date('2026-09-12T12:00:00Z');
  validateMarketCutoff('2026-09-10','2026-09-11',['2026-09-10','2026-09-11'],now);
  for(const [date,sessions] of [['2026-09-12',['2026-09-12']],['2026-09-09',['2026-09-09']],
    ['2026-09-11',['2026-09-10']],['2026-09-11',['2026-09-11','2026-09-11']]])
    assert.throws(()=>validateMarketCutoff('2026-09-10',date,sessions,now));
  assert.throws(()=>validateMarketCutoff('2026-01-01','2026-02-30',['2026-02-30'],now));
});
test('CTA refresh preserves its independent full-history return basis',()=>{
  const metadata={symbol:'KMLM',currency:'USD',instrumentType:'ETF'};
  const r=reconcileCtaExtension(old,fresh,metadata,'KMLM',fresh.at(-1).date);
  assert.equal(r.rows.length,4);assert.equal(r.scale,2);
  assert.equal(r.rows[0].date,fresh[60].date);
  assert.equal(r.rows[0].adjusted_close,fresh[60].adjusted_close*2);
  assert.throws(()=>reconcileCtaExtension(old,fresh,{...metadata,symbol:'DBMF'},'KMLM',fresh.at(-1).date),/identity/);
  assert.throws(()=>reconcileCtaExtension(old,fresh,{...metadata,currency:'GBP'},'KMLM',fresh.at(-1).date),/currency/);
  assert.throws(()=>reconcileCtaExtension(old,fresh,metadata,'KMLM','2026-09-11'),/target_session/);
  assert.throws(()=>reconcileCtaExtension(old,fresh.map((p,i)=>i===5?{...p,close:500}:p),metadata,'KMLM',fresh.at(-1).date),/close_basis/);
});
