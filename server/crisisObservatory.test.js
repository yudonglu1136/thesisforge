import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import {
  CRISIS_OBSERVATORY_VERSION,
  CRISIS_OBSERVATORY_STRATEGIES,
  CRISIS_OBSERVATORY_TP_MODES,
  CRISIS_OBSERVATORY_CC_MODES,
  loadCrisisObservatoryDashboard,
  loadCrisisObservatoryDashboardLive,
} from './crisisObservatory.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

test('loads canonical 2026-11-20 Crisis Observatory payload with selectable TP modes and zero T-Bill shield', () => {
  const doc = loadCrisisObservatoryDashboard({ asOf: '2026-11-20' });
  assert.equal(doc.version, CRISIS_OBSERVATORY_VERSION);
  assert.equal(doc.as_of_date, '2026-11-20');
  assert.equal(doc.selected_strategy_id, 'U1_PureOptions');
  assert.equal(doc.tp_mode, 'layered_itm');
  assert.equal(doc.cc_mode, 'cc_off');
  assert.equal(doc.tp_modes, undefined, 'Raw tp_modes bundle must be stripped from API wire response');
  assert.equal(doc.mode_bundles, undefined, 'Raw mode_bundles must be stripped from API wire response');
  assert.equal(doc.tp_modes_meta.length, 3);
  assert.equal(doc.cc_modes_meta.length, 3);
  assert.ok(doc.snapshotId && doc.snapshotId.length === 16);

  const snap = doc.live_market_snapshot;
  assert.equal(snap.qqq_close, 608.45);
  assert.equal(snap.running_ath, 759.66);
  assert.equal(snap.dd_from_ath_pct, -19.9);
  assert.equal(snap.vix, 35.89);
  assert.equal(snap.vix3m, 30.94);
  assert.equal(snap.vix_vix3m_ratio, 1.16);
  assert.equal(snap.vxn, 45.25);
  assert.equal(snap.raw_crisis_score, 6);

  assert.equal(doc.six_crisis_lights.length, 6);
  assert.ok(doc.six_crisis_lights.every(item => item.lit === true));
  assert.equal(doc.ad_line_signal.below_50ma, true);
  assert.equal(doc.ad_line_signal.days_below_50ma, 5);

  const sig = doc.live_signal_state;
  assert.equal(sig.regime_code, 'VIX110_TP_TRIGGERED');
  assert.equal(sig.target_equity_pct, 100);
  assert.equal(sig.target_tbill_pct, 0);
  assert.equal(sig.slow_bear_shield, undefined);
  assert.equal(sig.slot1_naked_put.status, 'TP_TRIGGERED_NEXT_OPEN');
  assert.equal(sig.slot2_collar.status, 'FROZEN_BELOW_ATH5');
  assert.equal(sig.gate_checklist.length, 5);

  const smap = Object.fromEntries(doc.strategies_summary.map(s => [s.id, s]));
  assert.equal(smap.U4_DualEngine, undefined);
  assert.ok(Math.abs(smap.U1_PureOptions.end_nav - 1654577.25) <= 0.5);
  assert.ok(Math.abs(smap.U1_PureOptions.net_alpha_usd - 366272.47) <= 0.5);
  assert.equal(smap.U1_PureOptions.cagr_pct, 19.46);
  assert.equal(smap.U1_PureOptions.max_dd_pct, -31.52);
  assert.equal(smap.U1_PureOptions.sharpe, 0.859);
  assert.ok(Math.abs(smap.B1c_PureAD.end_nav - 1587800.99) <= 0.5);
  assert.ok(Math.abs(smap.D2_SixLights.end_nav - 1497620.82) <= 0.5);
  assert.ok(Math.abs(smap.H2_G4_PriceGate.end_nav - 1402250.68) <= 0.5);
  assert.ok(Math.abs(smap.BH_Pure_QQQ.end_nav - 1288304.78) <= 0.02);

  assert.equal(doc.crisis_windows.length, 7);
  assert.equal(doc.crisis_windows.at(-1).id, '2026-08_11_LIVE');
  assert.equal(doc.daily_series.length, 2990);
  assert.deepEqual(doc.shield_events, []);

  // Selectable TP mode projections: standard_dual and both_4x
  const stdDoc = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', tpMode: 'standard_dual' });
  assert.equal(stdDoc.tp_mode, 'standard_dual');
  assert.equal(stdDoc.live_signal_state.regime_code, 'LOW_SPOT_FREEZE_NO_NEW_COLLAR');
  assert.ok(Math.abs(stdDoc.daily_series.at(-1).nav_u1 - 1625377.79) <= 0.5);

  const d4xDoc = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', tpMode: 'both_4x' });
  assert.equal(d4xDoc.tp_mode, 'both_4x');
  assert.ok(Math.abs(d4xDoc.daily_series.at(-1).nav_u1 - 1643122.56) <= 0.5);

  // Selectable Covered-Call cash-accumulation overlays (25D / 20-30 DTE): cc_high_vol and cc_always
  const hvDoc = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_high_vol',
  });
  assert.equal(hvDoc.cc_mode, 'cc_high_vol');
  assert.ok(Math.abs(hvDoc.daily_series.at(-1).nav_u1 - 1683324.68) <= 1.0);
  assert.equal(hvDoc.cc_ledgers_by_strategy.U1_PureOptions.length, 14);

  const alDoc = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_always',
  });
  assert.equal(alDoc.cc_mode, 'cc_always');
  assert.ok(Math.abs(alDoc.daily_series.at(-1).nav_u1 - 1619515.10) <= 1.0);
  assert.equal(alDoc.cc_ledgers_by_strategy.U1_PureOptions.length, 35);

  // Legacy U4_DualEngine query alias maps cleanly to U1_PureOptions
  const legacyAlias = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', strategy: 'U4_DualEngine' });
  assert.equal(legacyAlias.selected_strategy_id, 'U1_PureOptions');
});

test('slices historical asOf cutoffs without lookahead and masks future tranche exits', async () => {
  // On 2026-10-15, both Slot 1 (entered 2026-08-31) and Slot 2 (entered 2026-10-05) are OPEN;
  // their eventual 2026-11-06 VIX/VIX3M>=1.10 take-profit must NOT leak into 2026-10-15!
  const midOct = loadCrisisObservatoryDashboard({
    asOf: '2026-10-15',
    strategy: 'U1_PureOptions',
  });
  assert.equal(midOct.as_of_date, '2026-10-15');
  assert.equal(midOct.selected_strategy_id, 'U1_PureOptions');
  assert.equal(midOct.daily_series.at(-1).date, '2026-10-15');
  assert.ok(!midOct.events.some(ev => ev.date > '2026-10-15'));

  const openTranches = midOct.trade_ledger.filter(t => t.exit_date === null);
  assert.equal(openTranches.length, 2, 'Both Slot 1 Naked Put and Slot 2 Collar are active on 2026-10-15');
  assert.ok(openTranches.every(t => t.exit_reason === 'open_as_of_cutoff' && t.net_pnl_usd === null));
  assert.equal(midOct.live_signal_state.regime_code, 'DUAL_SLOT_FULL_SHIELD');
  assert.equal(midOct.live_signal_state.target_equity_pct, 100);
  assert.equal(midOct.live_signal_state.target_tbill_pct, 0);

  // Live runtime forward extension onto 2026-11-23 stays 100% QQQ pure options
  const liveExt = await loadCrisisObservatoryDashboardLive({
    asOf: '2026-11-23',
    strategy: 'U1_PureOptions',
    fetchLiveBars: async () => [
      {
        date: '2026-11-20',
        qqqClose: 608.45,
        vixClose: 35.89,
        vix3mClose: 30.94,
        vxnClose: 45.25,
      },
      {
        date: '2026-11-23',
        qqqClose: 626.7,
        vixClose: 27.4,
        vix3mClose: 28.5,
        vxnClose: 36.1,
      },
    ],
  });
  assert.equal(liveExt.liveExtended, true);
  assert.equal(liveExt.as_of_date, '2026-11-23');
  assert.equal(liveExt.live_market_snapshot.qqq_close, 626.7);
  assert.equal(liveExt.live_signal_state.regime_code, 'LOW_SPOT_FREEZE_NO_NEW_COLLAR');
  assert.equal(liveExt.live_signal_states_by_strategy.U1_PureOptions.regime_code, 'LOW_SPOT_FREEZE_NO_NEW_COLLAR');
  assert.equal(liveExt.live_signal_state.target_equity_pct, 100);
  assert.equal(liveExt.live_signal_state.target_tbill_pct, 0);
});

test('validates parameters and serves both /api/investment/crisis-observatory and /api/discover/crisis-observatory', async t => {
  assert.equal(CRISIS_OBSERVATORY_STRATEGIES.length, 5);
  assert.deepEqual(CRISIS_OBSERVATORY_TP_MODES, ['layered_itm', 'standard_dual', 'both_4x']);
  assert.deepEqual(CRISIS_OBSERVATORY_CC_MODES, ['cc_off', 'cc_high_vol', 'cc_always']);
  assert.throws(() => loadCrisisObservatoryDashboard({ strategy: 'UNKNOWN' }), /invalid_crisis_observatory_strategy/);
  assert.throws(() => loadCrisisObservatoryDashboard({ tpMode: 'UNKNOWN_TP' }), /invalid_crisis_observatory_tp_mode/);
  assert.throws(() => loadCrisisObservatoryDashboard({ ccMode: 'UNKNOWN_CC' }), /invalid_crisis_observatory_cc_mode/);
  assert.throws(() => loadCrisisObservatoryDashboard({ asOf: '2012-01-01' }), /as_of_before_evaluation_window/);
  assert.throws(() => loadCrisisObservatoryDashboard({ asOf: 'not-a-date' }), /invalid_as_of_date/);
  assert.throws(
    () => loadCrisisObservatoryDashboard({ snapshotId: 'deadbeef00000000' }),
    /crisis_observatory_snapshot_changed/,
  );

  const app = express();
  app.use((req, _res, next) => {
    if (req.headers['x-test-auth'] === '1') {
      req.user = { id: '11111111-1111-4111-8111-111111111111' };
    }
    next();
  });
  const fakeService = {
    source: { canonicalMarket: false },
    date: v => v || '2026-11-20',
  };
  registerInvestmentRoutes(app, fakeService);
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const port = server.address().port;

  // Unauthenticated -> 401 on both endpoints
  const unauthInv = await fetch(`http://127.0.0.1:${port}/api/investment/crisis-observatory`);
  assert.equal(unauthInv.status, 401);
  const unauthDisc = await fetch(`http://127.0.0.1:${port}/api/discover/crisis-observatory`);
  assert.equal(unauthDisc.status, 401);

  // Authenticated -> 200 on both endpoints with identical data
  const authHeaders = { 'x-test-auth': '1' };
  const [resInv, resDisc] = await Promise.all([
    fetch(`http://127.0.0.1:${port}/api/investment/crisis-observatory?strategy=U1_PureOptions&asOf=2026-11-20`, {
      headers: authHeaders,
    }),
    fetch(`http://127.0.0.1:${port}/api/discover/crisis-observatory?strategy=U1_PureOptions&asOf=2026-11-20`, {
      headers: authHeaders,
    }),
  ]);
  assert.equal(resInv.status, 200);
  assert.equal(resDisc.status, 200);
  const bodyInv = await resInv.json();
  const bodyDisc = await resDisc.json();
  assert.equal(bodyInv.as_of_date, '2026-11-20');
  assert.equal(bodyDisc.as_of_date, '2026-11-20');
  assert.equal(bodyInv.selected_strategy_id, 'U1_PureOptions');
  assert.equal(bodyInv.snapshotId, bodyDisc.snapshotId);
  assert.equal(bodyDisc.live_market_snapshot.qqq_close, 608.45);
  assert.equal(bodyDisc.six_crisis_lights.length, 6);
});
