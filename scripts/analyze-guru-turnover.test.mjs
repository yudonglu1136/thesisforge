import test from 'node:test';
import assert from 'node:assert/strict';
import { correlation, ranks, turnover, weights, performance, inference } from './analyze-guru-turnover.mjs';
const close = (a, b) => assert(Math.abs(a - b) < 1e-10, `${a} vs ${b}`);
test('correlation, ties and constant vectors', () => {
  close(correlation([1, 2, 3], [3, 2, 1]), -1);
  assert.equal(correlation([1, 1, 1], [1, 2, 3]), null);
  assert.deepEqual(ranks([4, 1, 1, 3]), [4, 1.5, 1.5, 3]);
});
test('drift-only portfolio does not turn over', () => {
  close(turnover(new Map([['A', .6], ['B', .4]]), new Map([['A', .6], ['B', .4]])).oneWay, 0);
  close(turnover(new Map([['A', .6], ['B', .4]]), new Map([['A', .5], ['B', .5]])).oneWay, .1);
});
test('full replacement and cash definitions', () => {
  close(turnover(new Map([['A', 1]]), new Map([['B', 1]])).oneWay, 1);
  const t = turnover(new Map([['A', 1]]), new Map([['__CASH__', 1]]));
  close(t.oneWay, 1); close(t.securityMin, 0); close(t.twoWayTraded, 1);
});
test('cash and stock acquisitions preserve economic identities', () => {
  const q = { cashWeight: .1, contributions: [{ ticker: 'OLD', weight: .6, endingWeight: .5, corporateActionResolution: { considerationType: 'cash', timing: 'while_position_active' } }, { ticker: 'PRIOR', weight: .3, endingWeight: .4, corporateActionResolution: { considerationType: 'stock', timing: 'while_position_active', successorTicker: 'NEW' } }] };
  const w = weights(q, true); close(w.get('__CASH__'), .6); close(w.get('NEW'), .4);
  close(turnover(w, new Map([['__CASH__', .6], ['NEW', .4]])).oneWay, 0);
  assert.throws(() => weights({ cashWeight: 0, contributions: [{ ticker: 'A', weight: .5 }] }));
});
test('CAGR uses elapsed calendar time, Sharpe daily sample volatility', () => {
  const eq = [{ date: '2024-01-01', value: 1 }, { date: '2024-07-01', value: 1.1 }, { date: '2025-01-01', value: 1.32 }];
  const p = performance(eq); close(p.cagr, 1.32 ** (365.25 / 366) - 1);
  close(p.sharpe, .15 / Math.sqrt(.005) * Math.sqrt(252));
});
test('inference is deterministic and recognizes strong monotonic relation', () => {
  const rows = Array.from({ length: 10 }, (_, i) => ({ annualTurnover: i, cagr: i }));
  const a = inference(rows, 'annualTurnover', 'cagr', 1000), b = inference(rows, 'annualTurnover', 'cagr', 1000);
  assert.deepEqual(a, b); close(a.pearson, 1); close(a.spearman, 1); assert(a.pearsonPermutationP < .01);
});
