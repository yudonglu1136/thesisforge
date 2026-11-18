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

test('defaultQuarter advances to 2026Q3 once Big 4 capex is 100% complete, hardware >=75% and calendar-quarter software reaches 50% (>=60% combined)', () => {
  const raw = artifact();
  // Add 10 hardware + 10 software so 5/10 software = 50% and 8/10 hardware = 80% (13/20 = 65% combined)
  raw.companies = [
    ...Array.from({ length: 10 }, (_, i) => ({ ticker: `HW${i}`, name: `HW ${i}`, issuerId: `hw:${i}`, group: 'hardware', sector: 'chips', currency: 'USD' })),
    ...Array.from({ length: 10 }, (_, i) => ({ ticker: `SW${i}`, name: `SW ${i}`, issuerId: `sw:${i}`, group: 'software', sector: 'saas', currency: 'USD' })),
    { ticker: 'CAP', name: 'Big4', issuerId: 'cap', group: 'capex', sector: 'hyperscaler', capexGroup: 'big4' },
  ];
  raw.facts = [];
  for (const c of raw.companies) {
    for (const [q, period, filed] of [['2026Q2', '2026-06-30', '2026-07-30'], ['2026Q3', '2026-09-30', '2026-10-30']]) {
      if (q === '2026Q3' && c.group === 'hardware' && Number(c.ticker.slice(2)) >= 8) continue;
      if (q === '2026Q3' && c.group === 'software' && Number(c.ticker.slice(2)) >= 5) continue;
      raw.facts.push({
        ticker: c.ticker, calendardate: period, reportperiod: period, datekey: filed, currency: 'USD',
        revenue: 1000, revenueusd: 1000, gp: 600, opinc: 200, ncfo: 250, netinc: 180, capex: -300, assets: 5000, sbcomp: 40,
        sourceRevisionId: `${c.ticker}:${q}`,
      });
    }
  }
  const svc = createAiInsightsService({ now: () => new Date('2026-11-18T12:00:00Z'), artifactLoader: () => raw });
  const view = svc.overview({ asOf: '2026-11-18' });
  assert.equal(view.selectedQuarter, '2026Q3');
  assert.equal(view.series.at(-1).quarter, '2026Q3');

  const inspectedOlder = svc.overview({ asOf: '2026-11-18', quarter: '2025Q3', window: 8 });
  assert.equal(inspectedOlder.selectedQuarter, '2025Q3');
  assert.equal(inspectedOlder.series.at(-1).quarter, '2026Q3', 'inspecting an in-window bar must keep 2026Q1-2026Q3 visible');
  assert.equal(inspectedOlder.sectors[0].series.at(-1).quarter, '2026Q3');
});

test('sector heatmap exposes operating profit and FCF series with signed-base turnaround handling', () => {
  const raw = artifact();
  raw.companies = [
    { ticker: 'LEAD', name: 'Leader', group: 'software', sector: 'cloud' },
    { ticker: 'PEER', name: 'Peer', group: 'software', sector: 'cloud' },
  ];
  // 2025Q2: sector opinc = -30 + 10 = -20 (negative base), fcf = 40 + 60 = 100
  // 2026Q2: sector opinc = +50 + 20 = +70 (turnaround_positive!), fcf = 120 + 70 = 190 (+90% YoY, LEAD +80pp)
  // Note: LEAD has capex = 0 (asset-light software like AppLovin) with explicit provider fcf = 120!
  raw.facts = [
    { ticker: 'LEAD', calendardate: '2025-06-30', reportperiod: '2025-06-30', datekey: '2025-07-25', currency: 'USD', revenue: 200, revenueusd: 200, opinc: -30, ncfo: 40, capex: 0, fcf: 40 },
    { ticker: 'PEER', calendardate: '2025-06-30', reportperiod: '2025-06-30', datekey: '2025-07-25', currency: 'USD', revenue: 200, revenueusd: 200, opinc: 10, ncfo: 80, capex: -20, fcf: 60 },
    { ticker: 'LEAD', calendardate: '2026-06-30', reportperiod: '2026-06-30', datekey: '2026-07-25', currency: 'USD', revenue: 300, revenueusd: 300, opinc: 50, ncfo: 120, capex: 0, fcf: 120 },
    { ticker: 'PEER', calendardate: '2026-06-30', reportperiod: '2026-06-30', datekey: '2026-07-25', currency: 'USD', revenue: 250, revenueusd: 250, opinc: 20, ncfo: 95, capex: -25, fcf: 70 },
  ];
  const view = createAiInsightsService({ now, artifactLoader: () => raw }).overview({ quarter: '2026Q2', asOf: '2026-09-22' });
  const sec = view.sectors[0];
  const prof = sec.profitSeries.at(-1).yoyComparison;
  assert.equal(prof.growth, null);
  assert.equal(prof.turnaroundStatus, 'turnaround_positive');
  assert.equal(prof.topImprover.ticker, 'LEAD');
  assert.equal(prof.topImprover.delta, 80);

  const fcf = sec.fcfSeries.at(-1).yoyComparison;
  assert.ok(Math.abs(fcf.growth - 0.9) < 1e-12);
  assert.equal(fcf.topContributor.ticker, 'LEAD');
  assert.ok(Math.abs(fcf.topContributor.contribution - 0.8) < 1e-12);
});

test('profit and FCF sector leaders exclude cash-burning/loss-making companies and prefer above-breakeven compounders over write-off rebounds', () => {
  const raw = artifact();
  raw.companies = [
    { ticker: 'NVDA', name: 'NVIDIA', group: 'hardware', sector: 'chips' },
    { ticker: 'INTC', name: 'Intel', group: 'hardware', sector: 'chips' },
  ];
  // 2026Q1 -> 2026Q2 QoQ:
  // Profit: INTC rebounded from -$9,000M write-off to +$400M (raw delta +$9,400M, above-breakeven +$400M),
  // while NVDA grew profit from +$21,000M to +$25,000M (above-breakeven +$4,000M) -> NVDA must win!
  // FCF: INTC narrowed cash burn from -$4,400M to -$1,500M (delta +$2,900M, still < 0!),
  // while NVDA had a seasonal dip +$20,000M -> +$14,000M -> INTC must NOT be crowned FCF winner!
  raw.facts = [
    { ticker: 'NVDA', calendardate: '2026-03-31', reportperiod: '2026-03-31', datekey: '2026-05-01', currency: 'USD', revenue: 40000, revenueusd: 40000, opinc: 21000, ncfo: 21000, capex: -1000, fcf: 20000 },
    { ticker: 'INTC', calendardate: '2026-03-31', reportperiod: '2026-03-31', datekey: '2026-05-01', currency: 'USD', revenue: 12000, revenueusd: 12000, opinc: -9000, ncfo: -1400, capex: -3000, fcf: -4400 },
    { ticker: 'NVDA', calendardate: '2026-06-30', reportperiod: '2026-06-30', datekey: '2026-08-01', currency: 'USD', revenue: 46000, revenueusd: 46000, opinc: 25000, ncfo: 15500, capex: -1500, fcf: 14000 },
    { ticker: 'INTC', calendardate: '2026-06-30', reportperiod: '2026-06-30', datekey: '2026-08-01', currency: 'USD', revenue: 12500, revenueusd: 12500, opinc: 400, ncfo: 1000, capex: -2500, fcf: -1500 },
  ];
  const view = createAiInsightsService({ now, artifactLoader: () => raw }).overview({ quarter: '2026Q2', asOf: '2026-09-22' });
  const sec = view.sectors[0];
  assert.equal(sec.profitSeries.at(-1).qoqComparison.topContributor.ticker, 'NVDA');
  assert.equal(sec.fcfSeries.at(-1).qoqComparison.topContributor, null);
  assert.equal(sec.fcfSeries.at(-1).qoqComparison.leaderStatus, 'no_positive_contributor');
});
