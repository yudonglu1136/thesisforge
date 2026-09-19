import test from 'node:test';
import assert from 'node:assert/strict';
import {strategyRegressionCases,regressionGate,yearsBefore} from './strategy-regression-matrix.mjs';

test('dynamic population covers every integer Top N, all four horizons and all manager pairs',()=>{
 const ids=Array.from({length:12},(_,i)=>'manager-'+i),cases=strategyRegressionCases(ids,'2026-08-28');
 assert.equal(new Set(cases.map(c=>c.id)).size,cases.length);
 assert.equal(cases.filter(c=>c.kind==='manager_top_horizon').length,12*10*4);
 assert.equal(cases.filter(c=>c.kind==='every_manager_pair').length,12*11/2);
 for(const id of ids)for(const topN of [1,2,3,4,5,6,7,8,9,10])for(const years of [1,3,5,10])
  assert.ok(cases.some(c=>c.kind==='manager_top_horizon'&&c.rules.managers[0]===id&&c.rules.topN===topN&&c.rules.start===yearsBefore('2026-08-28',years)));
 assert.ok(cases.some(c=>c.rules.managers.length===10));
 for(const id of ids) {
  const rules=cases.filter(c=>c.rules.managers.length===1&&c.rules.managers[0]===id).map(c=>c.rules);
  assert.deepEqual(new Set(rules.map(r=>r.cta)),new Set(['none','KMLM','DBMF']));
  assert.deepEqual(new Set(rules.map(r=>r.leverage.multiple)),new Set([1,1.25,1.5,2]));
  assert.deepEqual(new Set(rules.map(r=>r.maxPremium)),new Set([0,.15,.3,1]));
 }
});
test('one passing screenshot can never satisfy the full gate',()=>{
 const cases=[{id:'screenshot'},{id:'other'}];
 assert.equal(regressionGate([{id:'screenshot',status:'ready'}],cases).status,'fail');
 assert.equal(regressionGate([{id:'screenshot',status:'ready'},{id:'other',status:'blocked'}],cases).status,'fail');
 assert.equal(regressionGate([{id:'screenshot',status:'ready'},{id:'other',status:'error'}],cases).status,'fail');
 assert.equal(regressionGate([{id:'screenshot',status:'ready'},{id:'other',status:'ready'}],cases).status,'pass');
});
test('missing, duplicate and unexpected rows fail even with no blocked curves',()=>{
 const expected=[{id:'one'},{id:'two'}];
 for(const actual of [['one'],['one','one','two'],['one','two','surprise']])
  assert.equal(regressionGate(actual.map(id=>({id,status:'ready'})),expected).status,'fail');
 assert.throws(()=>strategyRegressionCases(['same','same'],'2026-08-28'));
});
test('leap-day horizon clamps to month end rather than drifting to March',()=>{
 assert.equal(yearsBefore('2024-02-29',1),'2023-02-28');
 assert.equal(yearsBefore('2024-02-29',4),'2020-02-29');
});
test('empty plans, duplicate expectations and unknown statuses never report a pass',()=>{
 assert.equal(regressionGate([],[]).status,'fail');
 assert.equal(regressionGate([{id:'a',status:'ready'}],[{id:'a'},{id:'a'}]).status,'fail');
 for(const status of ['degraded','pending',null,undefined])
  assert.equal(regressionGate([{id:'a',status}],[{id:'a'}]).status,'fail');
});
