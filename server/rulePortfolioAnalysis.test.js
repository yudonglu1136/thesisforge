import test from 'node:test';
import assert from 'node:assert/strict';
import { buildRuleLedger, analyzeRuleRange, createRuleAnalysisService } from './rulePortfolioAnalysis.js';

const dates = ['2024-01-02', '2024-01-03', '2024-01-04', '2024-01-05'];
const prices = new Map([
  ['AAA', new Map(dates.map((d, i) => [d, [100, 110, 120, 100][i]]))],
  ['BBB', new Map(dates.map((d, i) => [d, [100, 90, 80, 90][i]]))],
]);
function fixture() {
  const style = { id: 'quality_rank', quarters: [
    { executionDate: dates[0], positions: [{ ticker: 'AAA', weight: .5 }, { ticker: 'BBB', weight: .5 }], cashWeight: 0 },
    { executionDate: dates[2], positions: [{ ticker: 'AAA', weight: 1 }], cashWeight: 0 },
  ], corporateActions: [], trades: [
    { date: dates[0], turnover: 1, costFraction: .0025 },
    { date: dates[2], turnover: .8, costFraction: .002 },
  ] };
  const values = [.9975, .9975, .995505, .995505 * 100 / 120];
  return { snapshotId: 'fixture', styles: [style, { ...style, id: 'ackman' }],
    backtest: { curve: dates.map((date, i) => ({ date, quality_rank: values[i], ackman: values[i] })) } };
}
const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} != ${b}`);

test('range turnover reconciles real simulated buys and sells at each pre-cost NAV', () => {
  const ledger = buildRuleLedger(fixture(), prices);
  for (const s of analyzeRuleRange(ledger, dates[0], dates[3]).styles) {
    assert.equal(s.turnover.version, 'rule-range-turnover-v1');
    close(s.turnover.buyRatio, 1.4); // entry 100%, then add 40%
    close(s.turnover.sellRatio, .4);
    close(s.turnover.twoWay, 1.8);
    close(s.turnover.oneWay, .9);
    close(s.turnover.annualizedOneWay, .9 * 252 / 3);
    close(s.turnover.buyNotional, 1 + .399);
    close(s.turnover.sellNotional, .399);
    assert.equal(s.turnover.executions, 2);
    assert.equal(s.turnover.includesInitialEntry, true);
  }
  const clipped = analyzeRuleRange(ledger, dates[1], dates[2]).styles[0].turnover;
  close(clipped.oneWay, .4);
  close(clipped.annualizedOneWay, .4 * 252);
  assert.equal(clipped.executions, 1);
  assert.equal(clipped.includesInitialEntry, false);
  // Starting at that day's post-trade closing mark excludes its trading,
  // exactly like the return and fee interval. No rebalance means measured 0.
  const after = analyzeRuleRange(ledger, dates[2], dates[3]).styles[0].turnover;
  close(after.oneWay, 0); close(after.annualizedOneWay, 0);
  assert.equal(after.executions, 0);
});

test('full-range attribution includes entry fees and ties to every published net NAV', () => {
  const ledger = buildRuleLedger(fixture(), prices);
  const result = analyzeRuleRange(ledger, dates[0], dates[3]);
  assert.equal(result.styles.length, 2);
  for (const s of result.styles) {
    close(s.metrics.totalReturn, .995505 * 100 / 120 - 1);
    close(s.reconciliation.stockPnl, s.metrics.totalReturn);
    close(s.reconciliation.difference, 0);
    assert.equal(s.holdings.length, 2);
    assert.equal(s.distribution.reduce((n, b) => n + b.count, 0), 2);
    assert.equal(s.tradeStats.wins, 0);
    assert.equal(s.tradeStats.losses, 2);
    assert.equal(s.tradeStats.payoffRatio, null);
    assert.equal(s.tradeStats.payoffStatus, 'no_winners');
    assert.equal(s.holdings.find(r => r.ticker === 'AAA').openAtEnd, true);
    assert.equal(s.holdings.find(r => r.ticker === 'BBB').openAtEnd, false);
  }
});

test('range clips marks, not trades; costs at the opening mark are excluded', () => {
  const result = analyzeRuleRange(buildRuleLedger(fixture(), prices), dates[1], dates[2]).styles[0];
  close(result.metrics.totalReturn, -.002);
  const winner = result.best, loser = result.worst;
  assert.equal(winner.ticker, 'AAA'); assert.equal(loser.ticker, 'BBB');
  close(winner.netContribution, .05 - .001);
  close(loser.netContribution, -.05 - .001);
  close(result.tradeStats.winRate, .5); close(result.tradeStats.payoffRatio, .049 / .051);
  assert.equal(winner.openingMark.date, dates[1]);
  assert.equal(winner.openingMark.price, 110);
  assert.equal(winner.purchases[0].date, dates[0]);
  assert.equal(winner.purchases[0].price, 100);
  assert.equal(winner.sales.length, 0); // boundary mark must never become a fake sale
  assert.equal(loser.sales[0].date, dates[2]); assert.equal(loser.sales[0].price, 80);
  assert.equal(result.metrics.observations, 2);
});

test('missing prices, duplicate dates, invalid range and incompatible snapshot fail closed', () => {
  const missing = new Map(prices); missing.set('AAA', new Map([[dates[0], 100]]));
  assert.throws(() => buildRuleLedger(fixture(), missing), /missing_active_price/);
  const bad = fixture(); bad.backtest.curve[2].quality_rank += .01;
  assert.throws(() => buildRuleLedger(bad, prices), /rule_analysis_nav_mismatch/);
  const duplicate = fixture(); duplicate.backtest.curve[1].date = dates[0];
  assert.throws(() => buildRuleLedger(duplicate, prices), /invalid_rule_curve/);
  const ledger = buildRuleLedger(fixture(), prices);
  for (const [start, end] of [[dates[1], dates[1]], ['2023-12-31', dates[3]], [dates[3], dates[0]]]) {
    assert.throws(() => analyzeRuleRange(ledger, start, end), /invalid_analysis_range/);
  }
});

test('displayed but unexecuted latest selection is not charged or treated as a buy', () => {
  const f = fixture();
  f.styles.forEach(s => s.quarters.push({ executionDate: dates[3], positions: [{ ticker: 'BBB', weight: 1 }], cashWeight: 0 }));
  const r = analyzeRuleRange(buildRuleLedger(f, prices), dates[0], dates[3]).styles[0];
  assert.equal(r.holdings.find(h => h.ticker === 'BBB').purchases.length, 1);
  assert.equal(r.holdings.find(h => h.ticker === 'AAA').openAtEnd, true);
});

test('sample volatility, Sharpe and drawdown use unsampled daily net NAV', () => {
  const r = analyzeRuleRange(buildRuleLedger(fixture(), prices), dates[0], dates[3]).styles[0];
  const returns = [0, -.002, 100 / 120 - 1];
  const mean = sum(returns) / 3, variance = sum(returns.map(v => (v - mean) ** 2)) / 2;
  close(r.metrics.volatility, Math.sqrt(variance * 252));
  close(r.metrics.sharpeZeroRf, mean / Math.sqrt(variance) * Math.sqrt(252));
  close(r.metrics.maxDrawdown, .995505 * 100 / 120 - 1);
  const oneReturn = analyzeRuleRange(buildRuleLedger(fixture(), prices), dates[0], dates[1]).styles[0];
  assert.equal(oneReturn.metrics.volatility, null); assert.equal(oneReturn.metrics.sharpeZeroRf, null);
});
const sum = values => values.reduce((a, b) => a + b, 0);

test('stock conversion retains its exact successor claim and does not fabricate turnover', () => {
  const f = fixture();
  f.styles = [{ id: 'quality_rank', quarters: [
    { executionDate: dates[0], positions: [{ ticker: 'AAA', weight: 1 }], cashWeight: 0 },
    { executionDate: dates[2], positions: [{ ticker: 'BBB', weight: 1 }], cashWeight: 0 },
  ], trades: [{ date: dates[0], turnover: 1, costFraction: 0 }, { date: dates[2], turnover: 0, costFraction: 0 }],
  corporateActions: [{ ticker: 'AAA', executionDate: dates[0], actionId: 'verified-exchange', effectiveDate: dates[1], considerationType: 'stock', successorTicker: 'BBB', successorSharesPerShare: 2 }] }];
  f.backtest.curve = dates.map((date, i) => ({ date, quality_rank: [1, 1.1, 1.2, 1.3][i] }));
  const maps = new Map([['AAA', new Map([[dates[0], 100]])], ['BBB', new Map(dates.slice(1).map((d, i) => [d, 55 + i * 5]))]]);
  const r = analyzeRuleRange(buildRuleLedger(f, maps, { costBps: 0 }), dates[0], dates[3]).styles[0];
  close(r.reconciliation.stockPnl, .3);
  assert.equal(r.holdings.flatMap(h => h.sales).length, 0);
  assert.equal(r.holdings.flatMap(h => h.purchases).length, 1);
  assert.equal(r.tradeStats.payoffStatus, 'no_losers'); assert.equal(r.tradeStats.payoffRatio, null);
  close(r.turnover.oneWay, .5); // Entry only; the exchange is not trading.
  close(analyzeRuleRange(buildRuleLedger(f, maps, { costBps: 0 }), dates[1], dates[3]).styles[0].turnover.oneWay, 0);
});

test('as-of response cannot include later executions; changing generation during read fails', async () => {
  let generation = 'a';
  const service = createRuleAnalysisService({ load: () => fixture(), generation: async () => generation,
    prices: async () => { generation = 'b'; return prices; } });
  await assert.rejects(service({ asOf: dates[3], snapshotId: 'fixture', start: dates[0], end: dates[3] }), /generation_changed/);
  const early = analyzeRuleRange(buildRuleLedger(fixture(), prices), dates[0], dates[1]);
  assert.ok(early.styles.every(s => s.holdings.every(h => [...h.purchases, ...h.sales].every(e => e.date <= dates[1]))));
});

test('cash acquisition is settlement, not a sale; zero variance Sharpe is unavailable', () => {
  const f = fixture();
  f.backtest.curve = dates.map((date, i) => ({ date, quality_rank: i ? 1.1 : 1 }));
  f.styles = [{ id: 'quality_rank', quarters: [{ executionDate: dates[0], positions: [{ ticker: 'AAA', weight: 1 }], cashWeight: 0 }],
    trades: [{ date: dates[0], turnover: 1, costFraction: 0 }],
    corporateActions: [{ ticker: 'AAA', executionDate: dates[0], effectiveDate: dates[1], considerationType: 'cash', terminalCashEntitlementPerShare: 110 }] }];
  const ledger = buildRuleLedger(f, new Map([['AAA', new Map([[dates[0], 100]])]]), { costBps: 0 });
  const full = analyzeRuleRange(ledger, dates[0], dates[3]).styles[0];
  close(full.metrics.totalReturn, .1);
  assert.equal(full.best.sales.length, 0); assert.equal(full.best.openAtEnd, false);
  assert.equal(full.best.corporateActions[0].considerationType, 'cash');
  const flat = analyzeRuleRange(ledger, dates[1], dates[3]).styles[0];
  assert.equal(flat.metrics.sharpeZeroRf, null); assert.equal(flat.tradeStats.winRate, null);
});

test('concurrent reads share immutable replay; generation changes invalidate it; failures retry', async () => {
  let generation = 'a', reads = 0, broken = false;
  const service = createRuleAnalysisService({ load: () => fixture(), generation: async () => generation,
    prices: async () => { reads++; if (broken) throw new Error('unavailable'); return prices; } });
  const args = { asOf: dates[3], snapshotId: 'fixture', start: dates[0], end: dates[3] };
  const [a, b] = await Promise.all([service(args), service(args)]);
  assert.equal(reads, 1); assert.deepEqual(a, b);
  generation = 'b'; broken = true;
  await assert.rejects(service(args), /unavailable/);
  broken = false; await service(args); assert.equal(reads, 3);
});
