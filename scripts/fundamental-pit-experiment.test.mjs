import test from 'node:test';
import assert from 'node:assert/strict';
import {assess, screen, valuationCheck, quarterlySchedule, RULES} from './fundamental-pit-experiment.mjs';

const cutoff = '2025-09-30';
function company(ticker = 'TEST', growth = .2) {
  return {ticker, availableAt: '2025-08-10', periodEnd: '2025-06-30',
    metrics: {revenueGrowth: growth, operatingMargin: .10, fcfMargin: .05},
    price: {currency: 'USD'}, valuation: {currency: 'USD', fairValue: 100, date: '2025-08-10'},
    quality: {status: 'available', years: Array.from({length: 5}, (_, i) => ({
      year: 2024 - i, periodEnd: `${2024 - i}-12-31`, availableAt: `${2025 - i}-02-15`, roic: .15,
    }))}};
}
test('exact Discover thresholds all pass; each failing or missing factor fails', () => {
  assert.equal(assess(company('TEST', .15), cutoff).passes, true);
  for (const key of ['revenueGrowth', 'operatingMargin', 'fcfMargin']) {
    for (const value of [null, NaN, 0]) {
      const row = company(); row.metrics[key] = value;
      assert.equal(assess(row, cutoff).passes, false);
    }
  }
});
test('ROIC needs five consecutive public fiscal years; no missing-year or healthy-year fallback', () => {
  for (const mutate of [
    r => {r.quality.years[2].roic = .149;},
    r => {r.quality.years[2].roic = null;},
    r => {r.quality.years[2].year -= 1;},
    r => {r.quality.years[2].periodEnd = '2021-01-01';},
    r => {r.quality.years.pop();},
    r => {r.quality.years[0].availableAt = '2025-10-01';},
    r => {r.quality.status = 'stale';},
  ]) {const row = company(); mutate(row); assert.equal(assess(row, cutoff).passes, false);}
});
test('future statements and non-USD quotes never enter historical selections', () => {
  const future = company('FUTURE', 10); future.availableAt = '2025-10-01';
  const fx = company('FX', 10); fx.price.currency = 'GBP';
  const prior = company('PAST');
  assert.deepEqual(screen([future, fx, prior], cutoff).selected.map(r => r.ticker), ['PAST']);
});
test('Top 10 ranks by current growth, then worst ROIC, then ticker; does not mutate rows', () => {
  const rows = Array.from({length: 12}, (_, i) => company(`T${i}`, .2 + i / 100));
  const before = structuredClone(rows);
  assert.deepEqual(screen(rows, cutoff).selected.map(r => r.ticker), ['T11','T10','T9','T8','T7','T6','T5','T4','T3','T2']);
  assert.deepEqual(rows, before);
  assert.deepEqual(screen([company('Z'), company('A')], cutoff).selected.map(r => r.ticker), ['A','Z']);
});
test('30% premium uses price/value minus 1, not negative UI value/price gap', () => {
  assert.equal(valuationCheck(company(), cutoff, 130).status, 'eligible');
  assert.equal(valuationCheck(company(), cutoff, 130.01).status, 'expensive');
  assert.equal(valuationCheck(company(), cutoff, 70).status, 'eligible');
  assert.equal(valuationCheck(company(), cutoff, null).status, 'comparison_price_missing');
  const noValue = company(); noValue.valuation.fairValue = null;
  assert.equal(valuationCheck(noValue, cutoff, 100).status, 'no_model');
  const future = company(); future.valuation.date = '2025-10-01';
  assert.equal(valuationCheck(future, cutoff, 100).status, 'model_not_public');
});
test('only the next trading session at each calendar quarter is executable', () => {
  const dates = ['2016-09-29','2016-09-30','2016-10-03','2016-10-04','2016-12-30','2017-01-03','2017-01-04'];
  assert.deepEqual(quarterlySchedule(dates, RULES), [
    {executionDate: '2016-10-03', decisionDate: '2016-09-30'},
    {executionDate: '2017-01-03', decisionDate: '2016-12-30'},
  ]);
});
test('50% premium override changes only valuation eligibility and preserves 30% defaults', () => {
  const rules = {...RULES, maxPremium: .50};
  const row = company();
  assert.equal(valuationCheck(row, cutoff, 150, rules).status, 'eligible');
  assert.equal(valuationCheck(row, cutoff, 150.01, rules).status, 'expensive');
  assert.equal(valuationCheck(row, cutoff, 140, rules).status, 'eligible');
  assert.equal(valuationCheck(row, cutoff, 140).status, 'expensive');
  assert.equal(valuationCheck(row, cutoff, 140, rules).maxPremium, .50);
  assert.equal(RULES.maxPremium, .30);
  assert.deepEqual(screen([row], cutoff, rules).selected, screen([row], cutoff, RULES).selected);
});
