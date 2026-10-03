import test from 'node:test';
import assert from 'node:assert/strict';
import { attachQqqBenchmark } from './ruleBenchmark.js';
import {loadInvestorStyleDashboard,validateInvestorStyleDashboard} from './investorStyleDashboard.js';
const snapshot = () => ({universe:{id:'nasdaq100'},backtest:{curve:[{date:'2026-09-30',spy:1},{date:'2026-10-01',spy:1.1}]}});
const history = [{date:'2026-09-30',value:100},{date:'2026-10-01',value:120}];
test('QQQ is a separate total-return benchmark without changing SPY or the input',()=>{
  const source=snapshot(),result=attachQqqBenchmark(source,source,history,'a'.repeat(64));
  assert.deepEqual(result.backtest.curve.map(r=>r.qqq),[1,1.2]);
  assert.deepEqual(result.backtest.curve.map(r=>r.spy),[1,1.1]);
  assert.equal(source.backtest.curve[0].qqq,undefined);
});
test('missing, duplicate, nonpositive and nonfinite marks fail closed',()=>{
  for(const h of [history.slice(1),[...history,history[0]],history.map(r=>({...r,value:0})),history.map(r=>({...r,value:NaN}))])
    assert.throws(()=>attachQqqBenchmark(snapshot(),snapshot(),h,'a'.repeat(64)));
});
test('extensions retain published history and bridge adjusted-price scale',()=>{
  const source=attachQqqBenchmark(snapshot(),snapshot(),history,'a'.repeat(64));
  const next=structuredClone(source);next.backtest.curve.push({date:'2026-10-02',spy:1.2});
  const result=attachQqqBenchmark(source,next,[{date:'2026-09-30',value:50},{date:'2026-10-01',value:60},{date:'2026-10-02',value:66}],'b'.repeat(64));
  assert.deepEqual(result.backtest.curve.map(r=>r.qqq),[1,1.2,1.32]);
});
test('snapshot validator rejects partial QQQ and wrong basis but keeps legacy readable',()=>{
  const source=loadInvestorStyleDashboard({universe:'nasdaq100'});
  const marks=source.backtest.curve.map((r,i)=>({date:r.date,value:100+i}));
  const result=attachQqqBenchmark(source,source,marks,'a'.repeat(64));
  assert.doesNotThrow(()=>validateInvestorStyleDashboard(result));
  delete result.backtest.curve[1].qqq;
  assert.throws(()=>validateInvestorStyleDashboard(result));
  const wrong=attachQqqBenchmark(source,source,marks,'a'.repeat(64));
  wrong.backtest.qqqBenchmark.priceType='close';
  assert.throws(()=>validateInvestorStyleDashboard(wrong));
  assert.doesNotThrow(()=>validateInvestorStyleDashboard(source));
});
