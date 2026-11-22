import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import {
  GURU_COPYCAT_PLAYBOOK_VERSION,
  GURU_COPYCAT_SCHEME_IDS,
  loadGuruCopycatPlaybookDashboard,
  loadGuruCopycatPlaybookSnapshot,
} from './guruCopycatPlaybook.js';

test('loads flagship Guru Copycat Playbook with all 5 schemes, 16 gurus, 16-stock blueprint, and Q1 dump radar', () => {
  const dash = loadGuruCopycatPlaybookDashboard({ asOf: '2026-11-22' });
  assert.equal(dash.version, GURU_COPYCAT_PLAYBOOK_VERSION);
  assert.equal(dash.selectedSchemeId, 'barbell_70_30');
  assert.equal(dash.latestQuarter, '2026 Q3');
  assert.equal(dash.latestQuarterDate, '2026-09-30');
  assert.equal(dash.schemes.length, 5);
  assert.deepEqual(
    dash.schemes.map(s => s.id),
    [...GURU_COPYCAT_SCHEME_IDS],
  );

  // Verify full-horizon strict T+45 daily mark-to-market KPIs (50 realized quarters + live 2026 Q3 through 2026-11-17)
  const byId = Object.fromEntries(dash.schemes.map(s => [s.id, s]));
  assert.equal(byId.barbell_70_30.metrics.quarters, 50);
  assert.ok(Math.abs(byId.barbell_70_30.metrics.cagrPct - 16.86) < 0.05);
  assert.ok(byId.barbell_70_30.metrics.sharpe >= 1.05);
  assert.ok(Math.abs(byId.monopoly_compounders.metrics.cagrPct - 20.11) < 0.05);
  assert.ok(Math.abs(byId.monopoly_compounders.equalWeightVariant.winRatePct - 74.0) < 0.2);
  assert.ok(Math.abs(byId.pre2014_legends.metrics.cagrPct - 16.18) < 0.05);
  assert.equal(byId.pre2014_legends.metrics.bothHalvesBeat, true);
  assert.ok(Math.abs(byId.new_adds_catalyst.metrics.cagrPct - 17.81) < 0.05);
  assert.ok(Math.abs(byId.hf4_smart_flow.metrics.cagrPct - 15.89) < 0.05);
  assert.ok(byId.barbell_70_30.metrics.maxDrawdownPct > dash.benchmarks.SPY.maxDrawdownPct);
  assert.ok(dash.benchmarks.SPY.maxDrawdownPct < -33.0 && dash.benchmarks.SPY.maxDrawdownPct > -34.5);

  // Verify true daily mark-to-market NAV curve through 2026 Q2 realized + active 2026 Q3 live (3,146 trading sessions)
  assert.ok(dash.dailyCurve);
  assert.equal(dash.dailyCurve.startDate, '2014-05-16');
  assert.equal(dash.dailyCurve.endDate, '2026-11-17');
  assert.equal(dash.dailyCurve.dates.length, 3146);
  assert.equal(dash.dailyCurve.schemeNav.length, dash.dailyCurve.dates.length);
  assert.equal(dash.dailyCurve.spyNav.length, dash.dailyCurve.dates.length);
  assert.equal(dash.dailyCurve.qqqNav.length, dash.dailyCurve.dates.length);
  assert.equal(dash.dailyCurve.schemeNav[0], 100);
  assert.ok(Math.abs(dash.dailyCurve.schemeNav.at(-1) - byId.barbell_70_30.metrics.final100k) < 0.1);
  assert.ok(Math.abs(dash.dailyCurve.spyNav.at(-1) - dash.benchmarks.SPY.final100k) < 0.1);
  assert.ok(Math.abs(dash.dailyCurve.qqqNav.at(-1) - dash.benchmarks.QQQ.final100k) < 0.1);

  // Position count sensitivity & anti-patterns
  assert.equal(dash.positionCountSensitivity.length, 5);
  assert.equal(dash.antiPatterns.length, 3);

  // 16-Stock Master Blueprint
  assert.equal(dash.masterBlueprint16.length, 16);
  const bpSum = dash.masterBlueprint16.reduce((acc, r) => acc + r.targetWeightPct, 0);
  assert.equal(Math.round(bpSum), 100);

  // Q1 Active-HF Dumping Minefield Radar includes RDDT & NBIS with Guru Trap overlap warning on NBIS
  assert.ok(dash.q1HfDumpRadar.length >= 10);
  const nbis = dash.q1HfDumpRadar.find(r => r.ticker === 'NBIS');
  assert.ok(nbis, 'NBIS must appear in Q1 HF dump radar');
  assert.ok(nbis.guruOverlap.some(g => g.includes('GQG')));

  // Guru Exits & Heavy Slashes populated
  assert.ok(dash.guruExitsAndSlashes.length >= 5);

  // All 16 Tracked Gurus present with Top-12 holdings & retention stats
  assert.equal(dash.guruRoster.length, 16);
  const tci = dash.guruRoster.find(g => g.investorId === 'TCIFUN');
  assert.ok(tci);
  assert.equal(tci.thesisForgeGuruId, 'chris-hohn');
  assert.equal(tci.copyabilityGrade, 'A+');
  assert.ok(tci.top12Holdings.length >= 8);
  assert.equal(tci.top12Holdings[0].ticker, 'GE');

  // Snapshot timeline spans 2014 Q1 through 2026 Q3 (51 quarters)
  assert.equal(dash.snapshotTimeline.length, 51);
  assert.equal(dash.snapshotTimeline[0].quarter, '2014 Q1');
  assert.equal(dash.snapshotTimeline.at(-1).quarter, '2026 Q3');
  assert.equal(dash.activeSnapshot.quarter, '2026 Q3');
  assert.equal(dash.activeSnapshot.isLive, true);
});

test('supports Equal-Weight toggle on Monopoly Compounders and historical quarter snapshot lookup', () => {
  const eqDash = loadGuruCopycatPlaybookDashboard({
    asOf: '2026-11-21',
    scheme: 'monopoly_compounders',
    weightMode: 'equal',
    quarter: '2022 Q2',
  });
  const mono = eqDash.schemes.find(s => s.id === 'monopoly_compounders');
  assert.equal(mono.activeWeightMode, 'equal');
  assert.ok(Math.abs(mono.metrics.winRatePct - 74.0) < 0.2);
  assert.ok(eqDash.dailyCurve);
  assert.ok(Math.abs(eqDash.dailyCurve.schemeNav.at(-1) - mono.metrics.final100k) < 0.1);
  assert.equal(eqDash.activeSnapshot.quarter, '2022 Q2');
  assert.equal(eqDash.activeSnapshot.isLive, false);
  assert.ok(Number.isFinite(eqDash.activeSnapshot.portRetPct));
  assert.ok(eqDash.activeSnapshot.holdings.length > 0);
  assert.ok(Number.isFinite(eqDash.activeSnapshot.holdings[0].realizedRetPct));

  const snapResp = loadGuruCopycatPlaybookSnapshot({
    asOf: '2026-11-21',
    scheme: 'hf4_smart_flow',
    quarter: '2020-03-31',
  });
  assert.equal(snapResp.schemeId, 'hf4_smart_flow');
  assert.equal(snapResp.snapshot.quarter, '2020 Q1');
  assert.equal(snapResp.snapshot.isLive, false);
  assert.equal(snapResp.snapshot.holdings.length, 15);
});

test('enforces strict point-in-time cutoff without leaking future 13F filings or exit returns', () => {
  const pit = loadGuruCopycatPlaybookDashboard({
    asOf: '2022-09-01',
    scheme: 'pre2014_legends',
  });
  // On 2022-09-01, 2022 Q2 (filed 2022-08-15) is the latest visible filing; 2022 Q3 (filed Nov 2022) must be hidden!
  assert.equal(pit.latestQuarter, '2022 Q2');
  assert.equal(pit.snapshotTimeline.at(-1).quarter, '2022 Q2');
  // And 2022 Q2 entered Aug 2022 with exit in Nov 2022 (> 2022-09-01), so its forward return must be masked as live!
  assert.equal(pit.activeSnapshot.isLive, true);
  assert.equal(pit.activeSnapshot.portRetPct, null);
  assert.equal(pit.activeSnapshot.holdings[0].realizedRetPct, null);
  assert.equal(pit.masterBlueprint16.length, 0);
  // Daily NAV curve must also stop strictly on or before cutoff
  assert.ok(pit.dailyCurve);
  assert.ok(pit.dailyCurve.endDate <= '2022-09-01');
  assert.ok(pit.dailyCurve.dates.at(-1) <= '2022-09-01');
  assert.ok(pit.dailyCurve.dates.length > 2000 && pit.dailyCurve.dates.length < 2200);
});

test('extends daily NAV curve automatically from live SQLite price_points through asOf without lookahead', () => {
  const db = new DatabaseSync(':memory:');
  db.exec('CREATE TABLE price_points (symbol TEXT NOT NULL, date TEXT NOT NULL, close REAL NOT NULL, adjusted_close REAL, PRIMARY KEY (symbol, date));');
  const ins = db.prepare('INSERT INTO price_points (symbol, date, close, adjusted_close) VALUES (?, ?, ?, ?)');
  // Insert two newer trading sessions after 2026-11-17 anchor (2026-11-18 and 2026-11-20)
  ins.run('SPY', '2026-11-18', 739.76, 739.76); // +1.0% vs 732.44
  ins.run('QQQ', '2026-11-18', 663.52, 663.52); // +1.0% vs 656.95
  ins.run('SPY', '2026-11-20', 747.09, 747.09); // +2.0% vs 732.44
  ins.run('QQQ', '2026-11-20', 670.09, 670.09); // +2.0% vs 656.95

  const liveNov19 = loadGuruCopycatPlaybookDashboard({ asOf: '2026-11-19', source: { db } });
  assert.equal(liveNov19.dailyCurve.endDate, '2026-11-18');
  assert.equal(liveNov19.dailyCurve.tradingDays, 3147);
  assert.equal(liveNov19.latestPriceDate, '2026-11-18');

  const liveNov22 = loadGuruCopycatPlaybookDashboard({ asOf: '2026-11-22', source: { db } });
  assert.equal(liveNov22.dailyCurve.endDate, '2026-11-20');
  assert.equal(liveNov22.dailyCurve.tradingDays, 3148);
  assert.equal(liveNov22.dailyCurve.liveExtendedDays, 2);
  assert.ok(liveNov22.dailyCurve.spyNav.at(-1) > liveNov19.dailyCurve.spyNav.at(-1));
  db.close();
});
