import test from 'node:test';
import assert from 'node:assert/strict';
import { buildDividendResearch, DIVIDEND_RESEARCH_VERSION } from './dividendResearch.js';

test('buildDividendResearch returns Snowball yield channel, growth streaks, and FCF safety for AAPL and JNJ', async () => {
  const aapl = await buildDividendResearch({}, 'AAPL', '2026-11-17');
  assert.equal(aapl.version, DIVIDEND_RESEARCH_VERSION);
  assert.equal(aapl.ticker, 'AAPL');
  assert.equal(aapl.status, 'paying');
  assert.equal(aapl.summary.frequency, 'quarterly');
  assert.equal(aapl.summary.frequencyPerYear, 4);
  assert.ok(aapl.summary.currentYield > 0.001 && aapl.summary.currentYield < 0.03);
  assert.ok(aapl.summary.avgYield5y > 0);
  assert.ok(aapl.summary.consecutiveYearsPaid >= 9);
  assert.ok(aapl.summary.consecutiveYearsGrown >= 8);
  assert.equal(aapl.summary.safetyLevel, 'very_safe');
  assert.ok(aapl.yieldHistory.length >= 200 && aapl.yieldHistory.length <= 530);
  assert.ok(aapl.annualPayouts.length >= 8);
  assert.ok(aapl.events.length >= 30);
  assert.equal(aapl.seasonality.length, 12);

  // Warm cache hit must complete in < 50ms
  const t0 = performance.now();
  const warm = await buildDividendResearch({}, 'AAPL', '2026-11-17');
  const dt = performance.now() - t0;
  assert.ok(dt < 50, `Expected warm cache < 50ms, got ${dt.toFixed(2)}ms`);
  assert.equal(warm.summary.ttmDps, aapl.summary.ttmDps);
});

test('buildDividendResearch handles monthly REITs (CFO payout) and ETFs and non-payers cleanly', async () => {
  const reit = await buildDividendResearch({}, 'O', '2026-11-17');
  assert.equal(reit.status, 'paying');
  assert.equal(reit.isReit, true);
  assert.equal(reit.summary.frequency, 'monthly');
  assert.equal(reit.summary.safetyBasis, 'cfo_payout');
  assert.ok(reit.summary.fcfPayoutRatio > 0 && reit.summary.fcfPayoutRatio < 1);

  const etf = await buildDividendResearch({}, 'SCHD', '2026-11-17');
  assert.equal(etf.status, 'paying');
  assert.equal(etf.hasCorporateFacts, false);
  assert.equal(etf.summary.safetyLevel, 'fund_distribution');
  assert.ok(etf.summary.currentYield > 0.015);

  const nonPayer = await buildDividendResearch({}, 'AMZN', '2026-11-17');
  assert.equal(nonPayer.status, 'no_dividends');
  assert.equal(nonPayer.summary.currentYield, 0);
  assert.equal(nonPayer.summary.cagr5y, null);
  assert.equal(nonPayer.events.length, 0);
});
