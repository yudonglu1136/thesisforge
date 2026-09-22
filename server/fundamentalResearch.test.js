import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeFundamentalUniverse, buildFundamentalSeries, FactMetricsForDetail,
  FUNDAMENTAL_METHOD_VERSION, FUNDAMENTAL_RESEARCH_VERSION } from './fundamentalResearch.js';

const bilingual = value => typeof value === 'object' && value.en && value.zh;
function raw(companies) {
  return { version: 'fact-fundamental-universe-v1', as_of: '2026-09-21', catalog_generation: 'fixture', companies };
}
function company(ticker, metrics = {}, extra = {}) {
  return { ticker, name: `${ticker} fixture`, sector: 'Industrials', industry: 'Services',
    period_end: '2026-06-30', available_at: '2026-08-06', currency: 'USD',
    metrics: { ttmRevenue: 1_000_000_000, quarterCount: 8, ...metrics }, ...extra };
}

test('UBER-like facts produce the requested slowing-growth/margin-improvement path', () => {
  const result = analyzeFundamentalUniverse(raw([company('UBER', {
    revenueGrowth: .121729, priorRevenueGrowth: .144802,
    operatingMargin: .121317, operatingMarginPriorQuarter: .116602,
    operatingMarginPriorYear: .10, fcfMargin: .08, fcfMarginPriorYear: .07,
  })]), { lens: 'slowing_growth_margin_up', sort: 'change' });
  assert.equal(result.version, FUNDAMENTAL_RESEARCH_VERSION);
  assert.equal(result.methodVersion, FUNDAMENTAL_METHOD_VERSION);
  assert.equal(result.rows[0].ticker, 'UBER');
  assert.equal(result.rows[0].primarySignal.id, 'slowing_growth_margin_up');
  assert.ok(bilingual(result.rows[0].primarySignal.summary));
  assert.match(result.rankingBasis.en, /magnitude/);
});

test('missing periods and negative comparison bases stay unknown, not zero-filled', () => {
  const metrics = FactMetricsForDetail([
    { reportperiod: '2026-06-30', date: '2026-08-01', revenue: 10, netinccmn: 1 },
    { reportperiod: '2026-03-31', date: '2026-05-01', revenue: 9, netinccmn: -1 },
  ]);
  assert.equal(metrics.ttmRevenue, null);
  assert.equal(metrics.revenueGrowth, null);
  assert.equal(metrics.netIncomeGrowth, null);
  const result = analyzeFundamentalUniverse(raw([company('LOSS', metrics)]), { lens: 'growth_profit_sync' });
  assert.equal(result.rows.length, 0);
});

test('reported revision selection and four-quarter TTM never mix duplicate amendments', () => {
  const rows = [];
  const periods = ['2026-06-30', '2026-03-31', '2025-12-31', '2025-09-30',
    '2025-06-30', '2025-03-31', '2024-12-31', '2024-09-30'];
  for (let i = 0; i < periods.length; i++) {
    rows.push({ reportperiod: periods[i], date: `2026-0${Math.min(i + 1, 9)}-15`,
      fiscalperiod: `Q${4 - i % 4}`, revenue: 100 - i * 5, opinc: 20 - i, fcf: 12 - i, ncfo: 15 - i });
  }
  rows.push({ ...rows[0], date: '2026-08-20', revenue: 105, opinc: 22 });
  const series = buildFundamentalSeries(rows);
  assert.equal(series.at(-1).quarterlyRevenue, 105);
  assert.ok(Number.isFinite(series.at(-1).operatingMargin));
  assert.equal(series.length, 5);
});

test('currency and economic-model metadata survive ranking; price divergence is evidence-based', () => {
  const result = analyzeFundamentalUniverse(raw([
    company('GBP', {
      revenueGrowth: .05, priorRevenueGrowth: .06,
      operatingMargin: .22, operatingMarginPriorQuarter: .21, operatingMarginPriorYear: .19,
      fcfMargin: .15, fcfMarginPriorYear: .14,
    }, { currency: 'GBP', market: { priceReturn: -.25 } }),
    company('BANK', { revenueGrowth: null }, { sector: 'Financial Services', industry: 'Banks' }),
  ]), { lens: 'operating_pricing_divergence' });
  assert.equal(result.rows[0].ticker, 'GBP');
  assert.equal(result.rows[0].currency, 'GBP');
  assert.equal(result.rows[0].primarySignal.id, 'operating_pricing_divergence');
  assert.equal(result.rows[0].economicTemplate, 'operating_company');
  const bank = analyzeFundamentalUniverse(raw([company('BANK', {}, { industry: 'Banks' })]), { search: 'BANK' }).rows[0];
  assert.equal(bank.economicTemplate, 'banking');
});

test('search includes fact companies without a valuation model', () => {
  const result = analyzeFundamentalUniverse(raw([
    company('FACTONLY', { revenueGrowth: null }, { valuationStatus: 'not_modeled' }),
  ]), { search: 'factonly' });
  assert.equal(result.rows.length, 1);
  assert.equal(result.rows[0].ticker, 'FACTONLY');
  assert.equal(result.rows[0].primarySignal, null);
});

test('default discovery excludes tiny-base and unbounded-margin noise but search still finds it', () => {
  const noisy = company('TINY', {
    ttmRevenue: 25_000_000, revenueGrowth: 12, priorRevenueGrowth: .20,
    operatingMargin: -8, operatingMarginPriorQuarter: -9,
  });
  const ranked = analyzeFundamentalUniverse(raw([noisy]), { lens: 'slowing_growth_margin_up' });
  assert.equal(ranked.rows.length, 0);
  const searched = analyzeFundamentalUniverse(raw([noisy]), { search: 'TINY' });
  assert.equal(searched.rows[0].ticker, 'TINY');
  assert.equal(searched.rows[0].primarySignal, null);
});

test('user evidence thresholds are applied before ranking and preserve missing as missing', () => {
  const companies = [
    company('PASS', { revenueGrowth: .18, priorRevenueGrowth: .22,
      operatingMargin: .14, operatingMarginPriorQuarter: .15, operatingMarginPriorYear: .10,
      fcfMargin: .09, fcfMarginPriorYear: .08 }),
    company('LOWCASH', { revenueGrowth: .20, priorRevenueGrowth: .24,
      operatingMargin: .16, operatingMarginPriorQuarter: .15, operatingMarginPriorYear: .11,
      fcfMargin: .02, fcfMarginPriorYear: .01 }),
    company('MISSING', { revenueGrowth: .20, priorRevenueGrowth: .24,
      operatingMargin: .16, operatingMarginPriorQuarter: .15, operatingMarginPriorYear: .11,
      fcfMargin: null, fcfMarginPriorYear: null }),
  ];
  const result = analyzeFundamentalUniverse(raw(companies), {
    lens: 'growth_profit_sync', minRevenueGrowth: '.15',
    minOperatingMargin: '.10', minFcfMargin: '.05',
  });
  assert.deepEqual(result.rows.map(row => row.ticker), ['PASS']);
  assert.deepEqual(result.filters, {
    minRevenueGrowth: .15, minOperatingMargin: .10, minFcfMargin: .05,
  });
});

test('browse all facts is model independent, paged, and has an explicit stable metric order', () => {
  const input = raw([
    company('LOW', { revenueGrowth: .03 }),
    company('HIGH', { revenueGrowth: .25 }),
    company('UNKNOWN', { revenueGrowth: null }, { industry: 'Banks' }),
  ]);
  const result = analyzeFundamentalUniverse(input, { lens: 'all', sort: 'growth', limit: 1 });
  assert.equal(result.totalMatches, 3);
  assert.equal(result.rows[0].ticker, 'HIGH');
  assert.equal(result.hasMore, true);
  assert.equal(analyzeFundamentalUniverse(input, { lens: 'all', sort: 'growth', limit: 1, offset: 1 }).rows[0].ticker, 'LOW');
  assert.equal(analyzeFundamentalUniverse(input, { lens: 'all', sort: 'growth', offset: 2 }).rows[0].ticker, 'UNKNOWN');
});
