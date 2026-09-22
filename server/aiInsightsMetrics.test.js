import test from 'node:test';
import assert from 'node:assert/strict';
import { selectAiInsightsFacts, aggregateQuarter, capexValue, companyQuarter, scoreCompanies,
  quarterAt, quarterIndex } from './aiInsightsMetrics.js';

const dates = ['03-31', '06-30', '09-30', '12-31'];
export function fixture({ generationId = 'fixture1', factor = 1 } = {}) {
  const companies = ['hardware', 'software'].flatMap(group => Array.from({ length: 9 }, (_, i) => ({
    ticker: `${group[0].toUpperCase()}${i}`, name: `${group} ${i}`, issuerId: `${group}${i}`, group, sector: `${group}_sector`,
    firstPriceDate: '2000-01-01', currency: 'USD',
  }))).concat([{ ticker: 'C0', name: 'Capex 0', issuerId: 'capex0', group: 'capex', sector: 'hyperscaler', capexGroup: 'big4', currency: 'USD' },
    { ticker: 'C1', name: 'Capex 1', issuerId: 'capex1', group: 'capex', sector: 'cloud', capexGroup: 'neocloud', currency: 'USD' }]);
  const facts = companies.flatMap((company, ci) => Array.from({ length: 12 }, (_, i) => {
    const q = quarterAt(quarterIndex('2023Q3') + i), year = q.slice(0, 4), qi = Number(q.at(-1));
    const reportperiod = `${year}-${dates[qi - 1]}`;
    const datekey = new Date(Date.parse(reportperiod) + 40 * 86400000).toISOString().slice(0, 10);
    const revenue = factor * 1e6 * (100 + ci * 10) * Math.pow(1.015 + ci / 1000, i);
    return { ticker: company.ticker, dimension: 'ARQ', calendardate: reportperiod, reportperiod, datekey,
      fiscalperiod: q, currency: 'USD', revenue, revenueusd: revenue, gp: revenue * (.5 + ci / 200),
      opinc: revenue * (.1 + ci / 100), netinc: revenue * .10, ncfo: revenue * (.15 + ci / 100), capex: -revenue * .05,
      sbcomp: revenue * (.04 - ci / 1000), assets: revenue * 2, sourceRevisionId: `${company.ticker}-${q}`,
      source: { source: 'fixture', observedAt: datekey } };
  }));
  return { schemaVersion: 1, methodologyVersion: 'ai-insights-v1', universeVersion: 'fixture-universe',
    generationId, sourceManifestSha256: `source-${generationId}`, generatedAt: '2026-09-01T00:00:00Z', companies, facts };
}

test('PIT selects latest eligible ARQ revision by actual report date and disclosure date', () => {
  const artifact = fixture(), original = artifact.facts.find(r => r.ticker === 'H0' && r.calendardate === '2026-06-30');
  artifact.facts.push({ ...original, datekey: '2026-09-01', revenue: 999, revenueusd: 999, sourceRevisionId: 'restatement' });
  artifact.facts.push({ ...original, dimension: 'MRQ', datekey: '2026-08-31', revenue: 777, revenueusd: 777 });
  artifact.facts.push({ ...original, reportperiod: '2026-12-31', datekey: '2026-07-01', revenue: 888 });
  assert.equal(selectAiInsightsFacts(artifact, '2026-06-30').index.get('H0').has('2026Q2'), false);
  assert.equal(selectAiInsightsFacts(artifact, '2026-08-31').index.get('H0').get('2026Q2').revenue, original.revenue);
  assert.equal(selectAiInsightsFacts(artifact, '2026-09-01').index.get('H0').get('2026Q2').revenue, 999);
});

test('multiple operating periods in one mapped quarter are unavailable, not silently overwritten', () => {
  const artifact = fixture(), original = artifact.facts[0];
  artifact.facts.push({ ...original, reportperiod: '2023-08-31', datekey: '2023-11-01' });
  const selected = selectAiInsightsFacts(artifact, '2026-09-22');
  assert.equal(selected.index.get(original.ticker).get('2023Q3').ambiguous, true);
  assert.equal(selected.issues[0].code, 'ambiguous_calendar_mapping');
});

test('weighted aggregate uses paired prior-revenue weights and retains disclosed total separately', () => {
  const companies = [{ ticker: 'A' }, { ticker: 'B' }, { ticker: 'C' }];
  const row = (q, revenueusd) => ({ reportperiod: q === '2026Q2' ? '2026-06-30' : '2025-06-30', revenueusd });
  const index = new Map([['A', new Map([['2026Q2', row('2026Q2', 120)], ['2025Q2', row('2025Q2', 100)]])],
    ['B', new Map([['2026Q2', row('2026Q2', 180)], ['2025Q2', row('2025Q2', 200)]])],
    ['C', new Map([['2026Q2', row('2026Q2', 1000)]])]]);
  const metric = aggregateQuarter(companies, index, '2026Q2');
  assert.equal(metric.amount, 1300);
  assert.equal(metric.yoyComparison.current, 300);
  assert.equal(metric.yoy, 0);
  assert.deepEqual(metric.coverage, { expected: 3, disclosed: 3, yoyComparable: 2, qoqComparable: 0 });
  assert.equal(metric.yoyComparison.contributions.reduce((total, c) => total + c.contribution, 0), metric.yoy);
  assert.equal(metric.yoyComparison.contributions.reduce((total, c) => total + c.weight, 0), 1);
});

test('signed capex, zero evidence, and period FX preserve accounting meaning', () => {
  assert.equal(capexValue({ currency: 'USD', capex: 20 }).amount, -20);
  assert.equal(capexValue({ currency: 'USD', capex: 0 }).status, 'provider_zero_unverified');
  assert.equal(capexValue({ currency: 'USD', capex: 0, capexZeroVerified: true }).amount, -0);
  assert.equal(capexValue({ currency: 'USD', capex: -100, revenue: 1000, revenueusd: 10 }).amount, 1,
    'current currency metadata cannot override historical period FX');
  assert.equal(capexValue({ currency: 'EUR', capex: -100 }).amount, null);
  assert.equal(capexValue({ currency: 'USD', currencyBasis: 'current_financial_master_not_period_verified', capex: -100 }).amount, null);
});

test('TTM requires four contiguous quarters; absent bases do not become zero', () => {
  const artifact = fixture();
  artifact.facts = artifact.facts.filter(r => !(r.ticker === 'H0' && r.calendardate === '2026-03-31'));
  const index = selectAiInsightsFacts(artifact, '2026-09-22').index;
  const row = companyQuarter(artifact.companies[0], index.get('H0'), '2026Q2', '2026-09-22');
  assert.equal(row.revenueQoQ, null);
  assert.equal(row.ttmOperatingMargin, null);
  assert.ok(Number.isFinite(row.revenueYoY));
  const metric = aggregateQuarter([artifact.companies[0]], index, '2026Q2');
  assert.equal(metric.qoq, null);
});

test('negative margins remain observations, complete scores require eight peers and no reweighting', () => {
  const artifact = fixture(), index = selectAiInsightsFacts(artifact, '2026-09-22').index;
  const rows = artifact.companies.filter(c => c.group === 'hardware').map(c => companyQuarter(c, index.get(c.ticker), '2026Q2', '2026-09-22'));
  rows[0].ttmOperatingMargin = -.25;
  rows[0].sbcRatio = null;
  scoreCompanies(rows);
  assert.equal(rows[0].ttmOperatingMargin, -.25);
  assert.ok(Number.isFinite(rows[0].growthScore));
  assert.equal(rows[0].qualityScore, null);
  assert.equal(rows[0].compositeScore, null);
  assert.ok(Number.isFinite(rows[1].qualityScore));
  assert.equal(rows[1].scoreStatus.quality.eligiblePeers, 8);
  assert.equal(rows[1].qualityScore, rows[1].scoreBreakdown.quality.reduce((s, c) => s + c.contribution, 0));
  const tooSmall = rows.slice(0, 7).map(r => ({ ...r, scoreBreakdown: {}, scoreStatus: {}, rank: {} }));
  scoreCompanies(tooSmall);
  assert.ok(tooSmall.every(r => r.growthScore === null));
});

test('net asset disposals pause quality score and gross-profit growth uses disclosed period USD conversion', () => {
  const artifact = fixture(), index = selectAiInsightsFacts(artifact, '2026-09-22').index;
  const periods = index.get('H0');
  periods.get('2026Q2').capex = 1e6;
  for (const q of ['2025Q2', '2025Q1', '2024Q4', '2024Q3']) periods.get(q).currency = 'EUR';
  const row = companyQuarter(artifact.companies[0], periods, '2026Q2', '2026-09-22');
  assert.ok(Number.isFinite(row.ttmGrossProfitYoY));
  const original = row.ttmGrossProfitYoY;
  for (const q of ['2025Q2', '2025Q1', '2024Q4', '2024Q3']) periods.get(q).revenueusd /= 2;
  assert.ok(companyQuarter(artifact.companies[0], periods, '2026Q2', '2026-09-22').ttmGrossProfitYoY > original);
  assert.deepEqual(row.cashQualityIssues, ['net_disposal_inflow_requires_bridge']);
});

test('known scope breaks pause scores without leaking later events into PIT', () => {
  const artifact = fixture(), company = artifact.companies[0], index = selectAiInsightsFacts(artifact, '2026-09-22').index;
  company.corporateActions = [{ date: '2025-02-24', knownAt: '2026-09-20', type: 'spinoff' }];
  const before = companyQuarter(company, index.get(company.ticker), '2026Q2', '2026-09-19');
  const after = companyQuarter(company, index.get(company.ticker), '2026Q2', '2026-09-22');
  assert.equal(before.comparability.growth, 'reported_basis');
  assert.equal(after.comparability.growth, 'scope_bridge_required');
  assert.equal(after.comparability.quality, 'scope_bridge_required');
  assert.equal(before.revenueYoY, after.revenueYoY);
});

test('fiscal labels alone do not make long stub periods comparable', () => {
  const artifact = fixture(), index = selectAiInsightsFacts(artifact, '2026-09-22').index;
  index.get('H0').get('2026Q2').reportperiod = '2026-08-31';
  const row = companyQuarter(artifact.companies[0], index.get('H0'), '2026Q2', '2026-09-22');
  assert.equal(row.revenueQoQ, null);
  assert.equal(row.revenueYoY, null);
  assert.equal(aggregateQuarter([artifact.companies[0]], index, '2026Q2').yoy, null);
});

test('pre-spin revenue is not added to the parent and scope-breaking comparisons stay out of weighted growth', () => {
  const companies = [{ ticker: 'PARENT', corporateActions: [{ type: 'spinoff', date: '2025-02-24', knownAt: '2025-02-24' }] },
    { ticker: 'CHILD', corporateActions: [{ type: 'spunofffrom', counterpartyTicker: 'PARENT', date: '2025-02-24', knownAt: '2025-02-24' }] }];
  const index = new Map(companies.map(c => [c.ticker, new Map([
    ['2024Q4', { reportperiod: '2024-12-31', revenueusd: c.ticker === 'PARENT' ? 100 : 40 }],
    ['2025Q1', { reportperiod: '2025-03-31', revenueusd: c.ticker === 'PARENT' ? 65 : 45 }],
  ])]));
  const pre = aggregateQuarter(companies, index, '2024Q4', 'revenue', { asOf: '2025-06-30' });
  assert.equal(pre.amount, 100);
  assert.equal(pre.missing[0].reason, 'pre_spin_parent_overlap');
  const post = aggregateQuarter(companies, index, '2025Q1', 'revenue', { asOf: '2025-06-30' });
  assert.equal(post.amount, 110);
  assert.equal(post.qoq, null);
  assert.equal(post.coverage.qoqComparable, 0);
  assert.ok(post.qoqComparison.excluded.some(r => r.reason === 'scope_bridge_required'));
});
