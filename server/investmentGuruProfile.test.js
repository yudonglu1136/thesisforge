import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { InvestmentSource } from './investmentSource.js';
import { performance } from './guruTurnoverMath.js';
import { manager13fBacktestMethodVersion, manager13fSecurityMasterVersion } from './backtest.js';

test('guruDetail enriches style profile, key moves, valuation overlay and cutoff-bounded backtests', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'guru-profile-test-'));
  const file = path.join(dir, 'source.sqlite');
  const db = new DatabaseSync(file);
  db.exec(`
    CREATE TABLE guru_snapshots(guru_id TEXT, payload_json TEXT);
    CREATE TABLE guru_exposure_snapshots(guru_id TEXT, payload_json TEXT);
    CREATE TABLE guru_backtests(guru_id TEXT, years INTEGER, payload_json TEXT);
    CREATE TABLE guru_backtest_proxies(guru_id TEXT, years INTEGER, payload_json TEXT);
    CREATE TABLE valuation_ticker_snapshots(ticker TEXT, payload_json TEXT);
    CREATE TABLE valuation_pit_model_runs(ticker TEXT, as_of_date TEXT, model_version TEXT, fiscal_period TEXT,
      financial_available_at TEXT, guidance_max_observed_at TEXT, input_json TEXT, output_json TEXT);
  `);

  db.prepare('INSERT INTO guru_exposure_snapshots VALUES(?,?)').run('dev-kantesaria', JSON.stringify({
    guru: { id: 'dev-kantesaria', name: 'Dev Kantesaria', entityName: 'Valley Forge Capital Management, LP' },
    history: [
      {
        accessionNumber: 'vf-q1',
        reportDate: '2026-03-31',
        filingDate: '2026-05-15',
        quarterLabel: '2026 Q1',
        reported13fValue: 3375000000,
        positionCount: 7,
        turnoverProxy: 0.06,
        topHoldings: [
          { id: 'FICO-COMMON', ticker: 'FICO', issuer: 'Fair Isaac', shares: 769342, value: 821000000, pctPortfolio: 0.243 },
        ],
        largestChanges: [],
      },
      {
        accessionNumber: 'vf-q2',
        reportDate: '2026-06-30',
        filingDate: '2026-08-14',
        quarterLabel: '2026 Q2',
        reported13fValue: 3116000000,
        previous13fValue: 3375000000,
        positionCount: 7,
        turnoverProxy: 0.08,
        topHoldings: [
          { id: 'FICO-COMMON', ticker: 'FICO', issuer: 'Fair Isaac', shares: 672186, value: 803000000, pctPortfolio: 0.258 },
        ],
        largestChanges: [],
      },
    ],
  }));

  db.prepare('INSERT INTO guru_snapshots VALUES(?,?)').run('dev-kantesaria', JSON.stringify({
    summary: {
      reportDate: '2026-06-30',
      filingDate: '2026-08-14',
      totalValue: 3116000000,
      commonLongValue: 3116000000,
      previousCommonLongValue: 3375000000,
      totalPositions: 7,
      newPositions: 1,
      increasedPositions: 0,
      reducedPositions: 1,
      soldOutPositions: 0,
      top10Weight: 1,
      concentrationHhi: 0.188,
      turnoverProxy: 0.08,
    },
    latestFiling: { accessionNumber: 'vf-q2' },
    holdings: [
      { id: 'FICO-COMMON', cusip: 'FICO', ticker: 'FICO', issuer: 'Fair Isaac', shares: 672186, value: 803000000, pctCommonLong: 0.258, action: 'reduced', changeShares: -97156, changePct: -0.126 },
      { id: 'ASML-COMMON', cusip: 'ASML', ticker: 'ASML', issuer: 'ASML Holding', shares: 200000, value: 340000000, pctCommonLong: 0.109, action: 'new', changeShares: 200000, changePct: null },
    ],
    activity: [
      { id: 'FICO-COMMON', cusip: 'FICO', ticker: 'FICO', issuer: 'Fair Isaac', shares: 672186, prevShares: 769342, changeShares: -97156, changePct: -0.126, value: 803000000, previousValue: 821000000, valueChange: -18000000, action: 'reduced', pctCommonLong: 0.258 },
      { id: 'ASML-COMMON', cusip: 'ASML', ticker: 'ASML', issuer: 'ASML Holding', shares: 200000, prevShares: 0, changeShares: 200000, value: 340000000, previousValue: 0, valueChange: 340000000, action: 'new', pctCommonLong: 0.109 },
    ],
  }));

  db.prepare('INSERT INTO valuation_ticker_snapshots VALUES(?,?)').run('FICO', JSON.stringify({
    name: 'Fair Isaac',
    sector: 'Technology',
    currency: 'USD',
    priceHistory: [{ date: '2026-08-20', close: 800 }, { date: '2026-10-01', close: 1200 }],
  }));
  const input = { sourceRecord: { currency: 'USD', reportperiod: '2026-06-30' }, valuationSemantics: { fairValueFormula: 'dcf' } };
  db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?,?,?,?,?)').run(
    'FICO', '2026-08-01', 'v1', '2026-Q2', '2026-08-01', null, JSON.stringify(input), JSON.stringify({ fairValue: 1000 })
  );

  const equity = [
    { date: '2022-08-15', value: 1.0, benchmark: 1.0 },
    { date: '2023-08-15', value: 1.2, benchmark: 1.1 },
    { date: '2024-08-15', value: 1.5, benchmark: 1.25 },
    { date: '2025-08-15', value: 1.8, benchmark: 1.4 },
    { date: '2026-08-20', value: 2.1, benchmark: 1.6 },
    { date: '2026-11-01', value: 2.5, benchmark: 1.7 },
  ];
  const bt = {
    status: 'ready',
    generatedAt: '2026-11-14',
    guru: { id: 'dev-kantesaria' },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      minimumExecutionCoverage: 0.9,
      years: 5,
      benchmark: 'SPY',
    },
    window: { start: equity[0].date, end: equity.at(-1).date },
    equity,
    summary: { ...performance(equity), averagePositions: 7, averageCoverage: 1 },
    dataQuality: { minimumExecutionCoverage: 0.9, minimumObservedExecutionCoverage: 1, attributionReconciliation: { difference: 0 } },
    rebalances: [{ coveragePct: 1, commonLongValue: 100, selectedValue: 100 }],
    quarterContributions: equity.slice(0, -1).map((e, i) => ({
      label: `Period ${i + 1}`,
      reportDate: i === 3 ? '2026-03-31' : `202${i + 2}-06-30`,
      filingDate: e.date,
      executionDate: e.date,
      endDate: equity[i + 1].date,
      nextExecutionDate: equity[i + 1].date,
      portfolioReturn: equity[i + 1].value / e.value - 1,
      benchmarkReturn: equity[i + 1].benchmark / e.benchmark - 1,
      attributionReconciliation: 0,
      cashWeight: 0,
      contributions: [{
        ticker: 'FICO',
        issuer: 'Fair Isaac',
        weight: 1,
        endingWeight: 1,
        returnPct: equity[i + 1].value / e.value - 1,
        contributionPct: equity[i + 1].value / e.value - 1,
      }],
    })),
  };
  db.prepare('INSERT INTO guru_backtests VALUES(?,5,?)').run('dev-kantesaria', JSON.stringify(bt));

  const source = new InvestmentSource(file);
  t.after(() => { source.close(); db.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  const detail = source.guruDetail('dev-kantesaria', '2026-08-25');
  assert.equal(detail.styleProfile.concentrationTier, 'ultra_concentrated');
  assert.equal(detail.styleProfile.turnoverTier, 'low_turnover');
  assert.equal(detail.latest.bookScope, 'full_book');
  assert.equal(detail.latest.topHoldings.length, 2);
  assert.equal(detail.latest.keyBuys[0].ticker, 'ASML');
  assert.equal(detail.latest.keySells[0].ticker, 'FICO');
  assert.equal(detail.latest.topHoldings[0].sector, 'Technology');
  // Model gap uses 2026-08-20 close (800) vs 1000 fairValue = +0.25, never 2026-10-01 future close
  assert.ok(Math.abs(detail.latest.topHoldings[0].modelGap - 0.25) < 1e-9);

  // Backtest curve is strictly clipped to <= 2026-08-25 (excludes 2026-11-01 point!)
  assert.equal(detail.backtest.status, 'ready');
  const w5 = detail.backtest.windows['5Y'];
  assert.equal(w5.endDate, '2026-08-20');
  assert.ok(Math.abs(w5.totalReturn - 1.1) < 1e-9);
  assert.ok(w5.attribution.topContributors.some(c => c.ticker === 'FICO'));
});
