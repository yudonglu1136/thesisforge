import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { createAiInsightsService } from './investmentAiInsights.js';
import { quarterAt, quarterIndex } from './aiInsightsMetrics.js';

function artifact(generationId = 'generationA', scale = 1) {
  const companies = ['hardware', 'software'].flatMap(group => Array.from({ length: 9 }, (_, i) => ({
    ticker: `${group[0]}${i}`.toUpperCase(), name: `${group} ${i}`, issuerId: `${group}:${i}`, group, sector: `${group}_sector`, currency: 'USD' })))
    .concat([{ ticker: 'CAP', name: 'Capital company', issuerId: 'cap', group: 'capex', sector: 'hyperscaler', capexGroup: 'big4' }]);
  const facts = companies.flatMap((c, ci) => Array.from({ length: 12 }, (_, i) => {
    const q = quarterAt(quarterIndex('2023Q3') + i);
    const reportperiod = `${q.slice(0, 4)}-${['03-31', '06-30', '09-30', '12-31'][Number(q.at(-1)) - 1]}`;
    const revenue = scale * (1000 + 10 * ci) * Math.pow(1.02 + ci / 1000, i);
    return { ticker: c.ticker, calendardate: reportperiod, reportperiod,
      datekey: new Date(Date.parse(reportperiod) + 40 * 86400000).toISOString().slice(0, 10), currency: 'USD',
      revenue, revenueusd: revenue, gp: revenue * .5, opinc: revenue * (.1 + ci / 100),
      ncfo: revenue * .2, netinc: revenue * .1, capex: -revenue * .05, assets: revenue * 2, sbcomp: revenue * .02,
      sourceRevisionId: `${generationId}:${c.ticker}:${q}`, source: { source: 'fixture', key: `${c.ticker}:${q}` } };
  }));
  return { schemaVersion: 1, methodologyVersion: 'ai-insights-v1', universeVersion: 'universe-test', generationId,
    sourceManifestSha256: `source-${generationId}`, generatedAt: '2026-09-01T00:00:00Z', companies, facts };
}
const now = () => new Date('2026-09-22T12:00:00Z');
test('sector heatmap leaders use comparable dollar contribution, not issuer growth or absolute declines', () => {
  const raw = artifact();
  raw.companies = ['LARGE', 'FAST', 'DECLINE', 'FUTURE', 'SPIN'].map(ticker => ({
    ticker, name: ticker, group: 'hardware', sector: 'chips',
    ...(ticker === 'SPIN' ? { corporateActions: [{ type: 'spunofffrom', counterpartyTicker: 'LARGE', date: '2026-04-01', knownAt: '2026-04-01' }] } : {}),
  }));
  const values = { LARGE: [1000, 1300, 1400], FAST: [10, 10, 250], DECLINE: [2000, 1900, 100], FUTURE: [100, 100, 10000], SPIN: [100, 100, 5000] };
  raw.facts = raw.companies.flatMap(c => ['2025-06-30', '2026-03-31', '2026-06-30'].map((period, i) => ({
    ticker: c.ticker, calendardate: period, reportperiod: period, datekey: i === 2 ? (c.ticker === 'FUTURE' ? '2026-09-30' : '2026-08-01') : period,
    revenue: values[c.ticker][i], revenueusd: values[c.ticker][i], currency: 'USD', sourceRevisionId: `${c.ticker}:${period}`,
  })));
  const service = createAiInsightsService({ now, artifactLoader: () => raw });
  const view = service.overview({ quarter: '2026Q2', asOf: '2026-09-22' });
  const point = view.sectors[0].series.at(-1);
  const yoy = point.yoyComparison, qoq = point.qoqComparison;
  assert.equal(yoy.topContributor.ticker, 'LARGE');
  assert.equal(yoy.topContributor.delta, 400);
  assert.equal(yoy.topContributor.contribution, 400 / 3010);
  assert.equal(yoy.topContributor.priorEvidence.sourceRevisionId, 'LARGE:2025-06-30');
  assert.equal(yoy.topContributor.currentEvidence.datekey, '2026-08-01');
  assert.equal(yoy.leaderStatus, 'available');
  assert.equal(qoq.topContributor.ticker, 'FAST');
  assert.equal(qoq.topContributor.delta, 240);
  assert.equal(qoq.topContributor.contribution, 240 / 3210);
  assert.equal(yoy.contributions, undefined, 'do not ship a full issuer roster for every cell');
  assert.equal(point.coverage.yoyComparable, 3);
  assert.equal(view.sectors[0].series[0].yoyComparison.leaderStatus, 'unavailable');
});

test('heatmap ties are explicit and deterministic; flat, shrinking and invalid-base cells have no growth winner', () => {
  const raw = artifact();
  raw.companies = ['ZZZ', 'AAA'].map(ticker => ({ ticker, name: ticker, group: 'hardware', sector: 'test' }));
  raw.facts = raw.companies.flatMap(c => [100, 110, 110, 90, 120].map((revenue, i) => {
    const period = ['2025-06-30', '2025-09-30', '2025-12-31', '2026-03-31', '2026-06-30'][i];
    return { ticker: c.ticker, calendardate: period, reportperiod: period, datekey: period, revenue, revenueusd: revenue, currency: 'USD' };
  }));
  const view = createAiInsightsService({ now, artifactLoader: () => raw }).overview({ quarter: '2026Q2' });
  const points = view.sectors[0].series;
  assert.equal(points.at(-1).yoyComparison.topContributor.ticker, 'AAA');
  assert.equal(points.at(-1).yoyComparison.topContributor.tiedCount, 2);
  for (const index of [-2, -3]) {
    assert.equal(points.at(index).qoqComparison.topContributor, null);
    assert.equal(points.at(index).qoqComparison.leaderStatus, 'no_positive_contributor');
  }
  for (const row of raw.facts) if (row.calendardate === '2025-06-30') row.revenue = row.revenueusd = 0;
  const invalid = createAiInsightsService({ now, artifactLoader: () => raw }).overview({ quarter: '2026Q2' });
  assert.equal(invalid.sectors[0].series.at(-1).yoyComparison.topContributor, null);
  assert.equal(invalid.sectors[0].series.at(-1).yoyComparison.leaderStatus, 'unavailable');
});
function fakeService() {
  const artifacts = new Map([['generationA', artifact()], ['generationB', artifact('generationB', 2)]]);
  let active = 'generationA';
  return { artifacts, setActive: generation => { active = generation; },
    service: createAiInsightsService({ now, artifactLoader: generation => artifacts.get(generation || active) }) };
}

test('overview, rankings, detail, and comparison pin one generation across publication', () => {
  const { service, setActive } = fakeService();
  const first = service.overview({ asOf: '2026-09-22' });
  assert.equal(first.selectedQuarter, '2026Q2');
  assert.equal(first.series.length, 8);
  const oldValue = first.companies.find(r => r.ticker === 'H0').revenue;
  setActive('generationB');
  const pinned = { snapshotId: first.snapshotId };
  assert.equal(service.company('H0', pinned).company.revenue, oldValue);
  assert.equal(service.rankings(pinned).snapshotId, first.snapshotId);
  const comparison = service.compare({ ...pinned, tickers: 'H0,H1' });
  assert.ok(comparison.companies.every(c => c.snapshotId === first.snapshotId));
  assert.equal(service.overview().companies.find(r => r.ticker === 'H0').revenue, oldValue * 2);
  assert.throws(() => service.company('H0', { ...pinned, quarter: '2026Q1' }), /snapshot_context_mismatch/);
  assert.throws(() => service.company('H0', { ...pinned, asOf: '2026-08-31' }), /snapshot_context_mismatch/);
});

test('search, sector, revenue filters, and pagination do not alter scores or benchmark ranks', () => {
  const { service } = fakeService();
  const initial = service.rankings({ group: 'hardware', sort: 'revenue_qoq' });
  const target = initial.rows.find(r => r.ticker === 'H4');
  const filtered = service.rankings({ snapshotId: initial.snapshotId, search: 'H4', minRevenue: '1', sort: 'revenueQoQ', limit: '1' });
  assert.equal(filtered.total, 1);
  assert.equal(filtered.rows[0].compositeScore, target.compositeScore);
  assert.deepEqual(filtered.rows[0].rank, target.rank);
  assert.equal(filtered.rows[0].scoreStatus.growth.eligiblePeers, 9);
});

test('day-level PIT, empty-quarter views, and default broad quarter never borrow later results', () => {
  const { service, artifacts } = fakeService();
  const raw = artifacts.get('generationA');
  raw.facts.push({ ...raw.facts.find(r => r.ticker === 'H0'), calendardate: '2026-09-30', reportperiod: '2026-08-31', datekey: '2026-09-10' });
  const broad = service.overview();
  assert.equal(broad.selectedQuarter, '2026Q2');
  assert.equal(broad.context.latestReportedQuarter, '2026Q3');
  const sparse = service.overview({ quarter: '2026Q3' });
  assert.equal(sparse.summary.hardware.coverage.disclosed, 1);
  assert.equal(sparse.summary.capex.amount, null);
  const empty = service.overview({ asOf: '2026-06-30', quarter: '2026Q2' });
  assert.equal(empty.status, 'empty');
  assert.equal(empty.summary.hardware.amount, null);
  assert.ok(empty.companies.every(row => row.revenue === null));
});

test('detail supplies current and comparison-quarter evidence, score components, and precise source IDs', () => {
  const { service } = fakeService();
  const detail = service.company('H0', { quarter: '2026Q2' });
  assert.equal(detail.history.length, 8);
  assert.equal(detail.comparisonEvidence.length, 8);
  assert.equal(detail.comparisonEvidence[4].quarter, '2025Q2');
  assert.ok(detail.sourceRefs.includes('generationA:H0:2025Q2'));
  assert.equal(detail.company.scoreBreakdown.growth.length, 4);
  assert.equal(detail.company.scoreBreakdown.quality.length, 5);
  assert.equal(detail.context.universeMode, 'fixed_current_basket');
  assert.equal(detail.context.availabilityPrecision, 'date');
});

test('request validation rejects invalid parameters without fabricated fallbacks', () => {
  const { service } = fakeService();
  for (const query of [{ asOf: '2026-02-30' }, { asOf: '2026-09-23' }, { quarter: '2026Q5' }, { window: '7' },
    { capexBasis: 'leases' }, { snapshotId: '../invalid' }]) assert.throws(() => service.overview(query));
  assert.throws(() => service.compare({ tickers: 'H0' }), /two_to_four/);
  assert.throws(() => service.company('UNKNOWN'), /not_covered/);
  assert.throws(() => service.rankings({ sort: 'arbitrary' }), /invalid_ai_insights_sort/);
});

function publish(root, raw) {
  const dir = path.join(root, 'derived/ai-insights/generations');
  fs.mkdirSync(dir, { recursive: true });
  const bytes = JSON.stringify(raw);
  const manifest = { schemaVersion: 1, generationId: raw.generationId,
    artifactPath: `derived/ai-insights/generations/${raw.generationId}.json`,
    artifactSha256: crypto.createHash('sha256').update(bytes).digest('hex') };
  fs.writeFileSync(path.join(root, manifest.artifactPath), bytes);
  fs.writeFileSync(path.join(dir, `${raw.generationId}.manifest.json`), JSON.stringify(manifest));
  fs.writeFileSync(path.join(root, 'derived/ai-insights/manifest.json'), JSON.stringify(manifest));
}

test('immutable current and historical generations both require valid checksums; missing data is explicit', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-insights-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  assert.throws(() => createAiInsightsService({ factRoot: root, now }).overview(), { status: 503 });
  publish(root, artifact());
  const first = createAiInsightsService({ factRoot: root, now }).overview();
  publish(root, artifact('generationB', 2));
  assert.equal(createAiInsightsService({ factRoot: root, now }).company('H0', { snapshotId: first.snapshotId }).snapshotId, first.snapshotId);
  fs.appendFileSync(path.join(root, 'derived/ai-insights/generations/generationA.json'), ' ');
  assert.throws(() => createAiInsightsService({ factRoot: root, now }).overview({ snapshotId: first.snapshotId }), /checksum_mismatch/);
  fs.appendFileSync(path.join(root, 'derived/ai-insights/generations/generationB.json'), ' ');
  assert.throws(() => createAiInsightsService({ factRoot: root, now }).overview(), /checksum_mismatch/);
});
