import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import {
  GURU_COPYCAT_PLAYBOOK_VERSION,
  GURU_COPYCAT_SCHEME_IDS,
  loadGuruCopycatPlaybookDashboard,
  loadGuruCopycatPlaybookSnapshot,
} from './guruCopycatPlaybook.js';

test('loads flagship 80% QQQ + 20% Ex-QQQ Monopoly Compounders as default, removes hf4_smart_flow, and populates all 16 gurus', () => {
  const dash = loadGuruCopycatPlaybookDashboard({ asOf: '2026-11-22' });
  assert.equal(dash.version, GURU_COPYCAT_PLAYBOOK_VERSION);
  assert.equal(dash.selectedSchemeId, 'qqq80_exqqq_monopoly');
  assert.equal(dash.latestQuarter, '2026 Q3');
  assert.equal(dash.latestQuarterDate, '2026-09-30');
  assert.equal(dash.schemes.length, 5);
  assert.ok(!GURU_COPYCAT_SCHEME_IDS.includes('hf4_smart_flow'));
  assert.deepEqual(
    dash.schemes.map(s => s.id),
    [...GURU_COPYCAT_SCHEME_IDS],
  );

  const byId = Object.fromEntries(dash.schemes.map(s => [s.id, s]));
  assert.equal(byId.hf4_smart_flow, undefined);

  // Flagship #1: 80% QQQ + 20% Ex-QQQ Monopoly Compounders (Top-5 Conviction + Top-8 Equal-Weight)
  const flagship = byId.qqq80_exqqq_monopoly;
  assert.equal(flagship.recommended, true);
  assert.equal(flagship.metrics.quarters, 50);
  assert.ok(flagship.metrics.cagrPct > 18.5 && flagship.metrics.cagrPct < 19.2);
  assert.ok(flagship.metrics.alphaVsQqqPct > 0.15, `expected positive alpha vs QQQ, got ${flagship.metrics.alphaVsQqqPct}`);
  assert.ok(flagship.metrics.annTurnoverPct < 28, `expected low turnover <28%, got ${flagship.metrics.annTurnoverPct}`);
  assert.ok(flagship.equalWeightVariant.cagrPct > flagship.metrics.cagrPct);
  assert.ok(flagship.equalWeightVariant.annTurnoverPct < 20);
  assert.ok(flagship.equalWeightVariant.roll3yWinQqqPct > 60);

  // Live 2026 Q3 Top-5 Conviction book = 80% QQQ + V, GE, MCO, UNH, SPGI
  const liveTickers = dash.activeSnapshot.holdings.map(h => h.ticker);
  assert.deepEqual(liveTickers, ['QQQ', 'V', 'GE', 'MCO', 'UNH', 'SPGI']);
  assert.equal(dash.activeSnapshot.holdings[0].weightPct, 80);

  // Remaining 4 schemes intact
  assert.ok(Math.abs(byId.barbell_70_30.metrics.cagrPct - 16.86) < 0.25);
  assert.ok(Math.abs(byId.monopoly_compounders.metrics.cagrPct - 20.11) < 0.25);
  assert.ok(Math.abs(byId.monopoly_compounders.equalWeightVariant.winRatePct - 74.0) < 0.5);
  assert.ok(Math.abs(byId.pre2014_legends.metrics.cagrPct - 16.18) < 0.25);
  assert.equal(byId.pre2014_legends.metrics.bothHalvesBeat, true);
  assert.ok(Math.abs(byId.new_adds_catalyst.metrics.cagrPct - 17.81) < 0.25);

  // Daily mark-to-market NAV curve
  assert.ok(dash.dailyCurve);
  assert.equal(dash.dailyCurve.startDate, '2014-05-16');
  assert.ok(dash.dailyCurve.endDate >= '2026-11-17');
  assert.ok(dash.dailyCurve.dates.length >= 3146);
  assert.equal(dash.dailyCurve.schemeNav.length, dash.dailyCurve.dates.length);
  assert.equal(dash.dailyCurve.spyNav.length, dash.dailyCurve.dates.length);
  assert.equal(dash.dailyCurve.qqqNav.length, dash.dailyCurve.dates.length);
  assert.equal(dash.dailyCurve.schemeNav[0], 100);
  assert.ok(Math.abs(dash.dailyCurve.schemeNav.at(-1) - flagship.metrics.final100k) < 0.15);
  assert.ok(Math.abs(dash.dailyCurve.spyNav.at(-1) - dash.benchmarks.SPY.final100k) < 0.15);
  assert.ok(Math.abs(dash.dailyCurve.qqqNav.at(-1) - dash.benchmarks.QQQ.final100k) < 0.15);

  // 16-Stock Master Blueprint & Q1 Active-HF Dumping Minefield Radar
  assert.equal(dash.masterBlueprint16.length, 16);
  const nbis = dash.q1HfDumpRadar.find(r => r.ticker === 'NBIS');
  assert.ok(nbis, 'NBIS must appear in Q1 HF dump radar');
  assert.ok(nbis.guruOverlap.some(g => g.includes('GQG')));

  // All 16 Tracked Gurus present with continuous daily MTM navEndDate
  assert.equal(dash.guruRoster.length, 16);
  const tci = dash.guruRoster.find(g => g.investorId === 'TCIFUN');
  assert.ok(tci);
  assert.equal(tci.thesisForgeGuruId, 'chris-hohn');
  assert.equal(tci.copyabilityGrade, 'A+');
  assert.equal(tci.navEndDate, dash.dailyCurve.endDate);
  assert.equal(tci.top12Holdings[0].ticker, 'GE');

  // Snapshot timeline spans 2014 Q1 through 2026 Q3 (51 quarters)
  assert.equal(dash.snapshotTimeline.length, 51);
  assert.equal(dash.snapshotTimeline[0].quarter, '2014 Q1');
  assert.equal(dash.snapshotTimeline.at(-1).quarter, '2026 Q3');
  assert.equal(dash.activeSnapshot.isLive, true);
});

test('supports Top-8 Equal-Weight toggle on flagship qqq80_exqqq_monopoly and falls back cleanly on legacy hf4_smart_flow URL', () => {
  const eqFlagship = loadGuruCopycatPlaybookDashboard({
    asOf: '2026-11-22',
    scheme: 'qqq80_exqqq_monopoly',
    weightMode: 'equal',
  });
  const qqq80 = eqFlagship.schemes.find(s => s.id === 'qqq80_exqqq_monopoly');
  assert.equal(qqq80.activeWeightMode, 'equal');
  assert.ok(qqq80.metrics.cagrPct > qqq80.convictionVariant.cagrPct);
  assert.ok(Math.abs(eqFlagship.dailyCurve.schemeNav.at(-1) - qqq80.metrics.final100k) < 0.15);
  // Top-8 Equal-Weight 2026 Q3 book adds TSM, PGR, TDG (9 lines total: QQQ + 8 stocks at 2.5% each)
  assert.deepEqual(
    eqFlagship.activeSnapshot.holdings.map(h => h.ticker),
    ['QQQ', 'V', 'GE', 'MCO', 'UNH', 'SPGI', 'TSM', 'PGR', 'TDG'],
  );
  assert.equal(eqFlagship.activeSnapshot.holdings[1].weightPct, 2.5);

  // Legacy hf4_smart_flow query parameter cleanly falls back to qqq80_exqqq_monopoly
  const fallback = loadGuruCopycatPlaybookDashboard({
    asOf: '2026-11-22',
    scheme: 'hf4_smart_flow',
  });
  assert.equal(fallback.selectedSchemeId, 'qqq80_exqqq_monopoly');

  const snapResp = loadGuruCopycatPlaybookSnapshot({
    asOf: '2026-11-22',
    scheme: 'qqq80_exqqq_monopoly',
    weightMode: 'equal',
    quarter: '2022 Q2',
  });
  assert.equal(snapResp.schemeId, 'qqq80_exqqq_monopoly');
  assert.equal(snapResp.weightMode, 'equal');
  assert.equal(snapResp.snapshot.quarter, '2022 Q2');
  assert.equal(snapResp.snapshot.isLive, false);
  assert.equal(snapResp.snapshot.holdings.length, 9);
});

test('enforces strict point-in-time cutoff without leaking future 13F filings or exit returns', () => {
  const pit = loadGuruCopycatPlaybookDashboard({
    asOf: '2022-09-01',
    scheme: 'pre2014_legends',
  });
  assert.equal(pit.latestQuarter, '2022 Q2');
  assert.equal(pit.snapshotTimeline.at(-1).quarter, '2022 Q2');
  assert.equal(pit.activeSnapshot.isLive, true);
  assert.equal(pit.activeSnapshot.portRetPct, null);
  assert.equal(pit.activeSnapshot.holdings[0].realizedRetPct, null);
  assert.equal(pit.masterBlueprint16.length, 0);
  assert.ok(pit.dailyCurve);
  assert.ok(pit.dailyCurve.endDate <= '2022-09-01');
  assert.ok(pit.dailyCurve.dates.at(-1) <= '2022-09-01');
});

test('extends daily NAV curve and headline KPIs automatically from live SQLite price_points or FactOS livePriceRows', () => {
  const base = loadGuruCopycatPlaybookDashboard({ asOf: '2026-11-22' });
  const baseEnd = base.dailyCurve.endDate;
  const baseDays = base.dailyCurve.tradingDays;

  const db = new DatabaseSync(':memory:');
  db.exec('CREATE TABLE price_points (symbol TEXT NOT NULL, date TEXT NOT NULL, close REAL NOT NULL, adjusted_close REAL, PRIMARY KEY (symbol, date));');
  const ins = db.prepare('INSERT INTO price_points (symbol, date, close, adjusted_close) VALUES (?, ?, ?, ?)');
  ins.run('SPY', '2026-11-23', 750.0, 750.0);
  ins.run('QQQ', '2026-11-23', 672.0, 672.0);
  ins.run('SPY', '2026-11-24', 758.0, 758.0);
  ins.run('QQQ', '2026-11-24', 680.0, 680.0);

  const liveNov23 = loadGuruCopycatPlaybookDashboard({ asOf: '2026-11-23', source: { db } });
  assert.ok(liveNov23.dailyCurve.endDate > baseEnd);
  assert.equal(liveNov23.dailyCurve.endDate, '2026-11-23');
  assert.equal(liveNov23.dailyCurve.tradingDays, baseDays + 1);
  assert.equal(liveNov23.latestPriceDate, '2026-11-23');

  const liveNov25 = loadGuruCopycatPlaybookDashboard({ asOf: '2026-11-25', source: { db } });
  assert.equal(liveNov25.dailyCurve.endDate, '2026-11-24');
  assert.equal(liveNov25.dailyCurve.tradingDays, baseDays + 2);
  assert.equal(liveNov25.dailyCurve.liveExtendedDays, 2);
  assert.ok(liveNov25.dailyCurve.qqqNav.at(-1) > liveNov23.dailyCurve.qqqNav.at(-1));
  const activeMetrics = liveNov25.schemes.find(s => s.id === 'qqq80_exqqq_monopoly').metrics;
  assert.equal(activeMetrics.final100k, liveNov25.dailyCurve.schemeNav.at(-1));
  db.close();
});
