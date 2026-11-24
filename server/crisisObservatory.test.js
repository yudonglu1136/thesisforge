import test from 'node:test';
import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import express from 'express';
import {
  CRISIS_OBSERVATORY_VERSION,
  CRISIS_OBSERVATORY_STRATEGIES,
  CRISIS_OBSERVATORY_TP_MODES,
  CRISIS_OBSERVATORY_CC_MODES,
  CRISIS_OBSERVATORY_SP_MODES,
  CRISIS_OBSERVATORY_WC_MODES,
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
  assert.equal(doc.cc_modes_meta.length, 4);
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

  // Selectable 4-way 25D 12Δ Covered-Call overlays: cc_d12_d35, cc_d12_r45, cc_d12_cr55 (+ legacy aliases)
  const d35Doc = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_d35',
  });
  assert.equal(d35Doc.cc_mode, 'cc_d12_d35');
  assert.ok(Math.abs(d35Doc.daily_series.at(-1).nav_u1 - 1714946.88) <= 2.0);
  assert.equal(d35Doc.cc_ledgers_by_strategy.U1_PureOptions.length, 75);

  const r45Doc = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_r45',
  });
  assert.equal(r45Doc.cc_mode, 'cc_d12_r45');
  assert.ok(Math.abs(r45Doc.daily_series.at(-1).nav_u1 - 1704612.32) <= 2.0);
  assert.equal(r45Doc.cc_ledgers_by_strategy.U1_PureOptions.length, 71);

  const cr55Doc = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_cr55',
  });
  assert.equal(cr55Doc.cc_mode, 'cc_d12_cr55');
  assert.ok(Math.abs(cr55Doc.daily_series.at(-1).nav_u1 - 1688796.56) <= 2.0);
  assert.equal(cr55Doc.cc_ledgers_by_strategy.U1_PureOptions.length, 71);

  // Legacy cc_high_vol / cc_always aliases map cleanly
  const legacyCcAlias = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', ccMode: 'cc_high_vol' });
  assert.equal(legacyCcAlias.cc_mode, 'cc_d12_d35');
  const legacyAlwaysAlias = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', ccMode: 'cc_always_8' });
  assert.equal(legacyAlwaysAlias.cc_mode, 'cc_d12_r45');

  // Legacy U4_DualEngine query alias maps cleanly to U1_PureOptions
  const legacyAlias = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', strategy: 'U4_DualEngine' });
  assert.equal(legacyAlias.selected_strategy_id, 'U1_PureOptions');
  assert.equal(doc.sp_mode, 'sp_off');
  assert.equal(doc.wc_mode, 'wc_reclaim_30d_d35');
  assert.equal(doc.sp_modes_meta.length, 4);
  assert.equal(doc.wc_modes_meta.length, 3);
  assert.equal(doc.live_sp_state.position_state, 'disabled');

  // 3rd Engine (Short-DTE Panic Put Wheel) — NEW DEFAULT wc_reclaim_30d_d35 (Hold uncapped < K_assign, then 30D 0.35Δ Call)
  const spCap10 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_d35',
    spMode: 'sp_14d_cap10',
  });
  assert.equal(spCap10.sp_mode, 'sp_14d_cap10');
  assert.equal(spCap10.wc_mode, 'wc_reclaim_30d_d35');
  const cap10U1 = Object.fromEntries(spCap10.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(cap10U1.end_nav - 1805855.89) <= 0.1, `Expected $1,805,855.89, got ${cap10U1.end_nav}`);
  assert.equal(cap10U1.cagr_pct, 20.34);
  assert.equal(cap10U1.max_dd_pct, -30.96);
  assert.equal(cap10U1.sharpe, 0.881);
  assert.equal(cap10U1.calmar, 0.657);
  assert.ok(Math.abs(cap10U1.margin_interest_usd - 3842.41) <= 0.05);
  assert.ok(Math.abs(cap10U1.wc_gross_prem_usd - 8956.46) <= 0.05);
  assert.equal(cap10U1.days_levered_stock, 337);
  assert.equal(cap10U1.max_wheel_cycle_days, 355);
  assert.equal(cap10U1.max_gross_stock_lev, 1.135);
  assert.equal(cap10U1.sp_trades_count, 44);
  assert.equal(cap10U1.sp_assignments_count, 5);
  assert.equal(cap10U1.wc_trades_count, 8);
  assert.equal(cap10U1.wc_called_away_count, 4);
  assert.equal(spCap10.live_sp_state.position_state, 'wheel_assigned_wait_reclaim');
  assert.equal(spCap10.live_sp_state.min_next_wc_strike, 625.43);
  assert.ok(spCap10.live_sp_state.badge_zh.includes('水下暂不卖 Call，等涨回 >= $625.43'));
  assert.equal(spCap10.live_sp_state.backwardation_active, true);
  assert.equal(spCap10.live_sp_state.vix_falling, false);
  assert.ok(spCap10.sp_ledger.length === 52 && !Array.isArray(spCap10.sp_ledger._rows));
  assert.ok(
    spCap10.sp_ledger.some(r => r.leg_type === 'short_put') &&
      spCap10.sp_ledger.some(r => r.leg_type === 'wheel_call'),
  );
  assert.ok(spCap10.crisis_windows[0].title_en && spCap10.crisis_windows[0].title_zh);

  // Orthogonal 3-engine attribution breakdown: exact additive identity & real correlations
  const attrCap10 = spCap10.engine_attribution_by_strategy?.U1_PureOptions;
  assert.ok(attrCap10, 'engine_attribution_by_strategy must be populated');
  assert.equal(attrCap10.active_engines_count, 3);
  assert.ok(Math.abs(attrCap10.engine1.delta_usd - 366272.47) <= 0.5);
  assert.ok(Math.abs(attrCap10.engine2.delta_usd - 60369.63) <= 0.5);
  assert.ok(Math.abs(attrCap10.engine3.delta_usd - 90909.01) <= 0.5);
  assert.ok(
    Math.abs(
      attrCap10.base_end_nav +
        attrCap10.engine1.delta_usd +
        attrCap10.engine2.delta_usd +
        attrCap10.engine3.delta_usd -
        attrCap10.total_end_nav,
    ) <= 0.05,
    'Base + E1 + E2 + E3 must reconcile to total_end_nav to the penny',
  );
  assert.ok(
    Math.abs(
      attrCap10.engine1.share_of_alpha_pct +
        attrCap10.engine2.share_of_alpha_pct +
        attrCap10.engine3.share_of_alpha_pct -
        100.0,
    ) <= 0.2,
  );
  assert.ok(Number.isFinite(attrCap10.correlations.e1_e2));
  assert.ok(attrCap10.correlations.e1_e3 < 0 && attrCap10.correlations.e2_e3 < 0);

  const gzBytes = zlib.gzipSync(JSON.stringify(spCap10)).length;
  assert.ok(gzBytes < 420 * 1024, `Projected single-mode gzipped payload must stay compact (<420 KB), got ${gzBytes}`);

  const spVixf = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_d35',
    spMode: 'sp_10d_vixf',
  });
  const vixfU1 = Object.fromEntries(spVixf.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(vixfU1.end_nav - 1838505.47) <= 0.1, `Expected $1,838,505.47, got ${vixfU1.end_nav}`);
  assert.equal(vixfU1.max_dd_pct, -30.38);
  assert.equal(vixfU1.calmar, 0.676);
  assert.ok(Math.abs(vixfU1.margin_interest_usd - 1250.65) <= 0.05);
  assert.equal(vixfU1.sp_trades_count, 27);
  assert.equal(vixfU1.sp_assignments_count, 3);
  assert.equal(vixfU1.wc_trades_count, 5);
  assert.equal(vixfU1.wc_called_away_count, 3);
  assert.equal(spVixf.live_sp_state.position_state, 'flat_standby');

  const spUnf = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_d35',
    spMode: 'sp_14d_unf',
  });
  const unfU1 = Object.fromEntries(spUnf.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(unfU1.end_nav - 1901035.03) <= 0.1, `Expected $1,901,035.03, got ${unfU1.end_nav}`);
  assert.equal(unfU1.cagr_pct, 20.87);
  assert.ok(Math.abs(unfU1.margin_interest_usd - 7942.77) <= 0.05);
  assert.equal(unfU1.max_gross_stock_lev, 1.276);

  // COMPARE TOGGLE: wc_30d_c5s5 (Immediate 30D + max(1.05*Cost, 1.05*Spot))
  const spCap10Immediate = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_d35',
    spMode: 'sp_14d_cap10',
    wcMode: 'wc_30d_c5s5',
  });
  assert.equal(spCap10Immediate.wc_mode, 'wc_30d_c5s5');
  const cap10ImmU1 = Object.fromEntries(spCap10Immediate.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(cap10ImmU1.end_nav - 1819738.31) <= 0.1);
  assert.equal(cap10ImmU1.calmar, 0.685);
  assert.ok(Math.abs(cap10ImmU1.margin_interest_usd - 1481.18) <= 0.05);
  assert.equal(spCap10Immediate.live_sp_state.position_state, 'wheel_assigned_wc_armed');
  assert.equal(spCap10Immediate.live_sp_state.min_next_wc_strike, 656.7);
  assert.ok(spCap10Immediate.live_sp_state.badge_zh.includes('30D Wheel Call（K >= $656.70，max(1.05×成本, 1.05×现价)）'));

  // LEGACY COMPARE TOGGLE: wc_14d_c0s2 (14D + max(Cost, 1.02*Spot)) preserves 100% penny parity with 2f28247
  const spCap10Legacy = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_d35',
    spMode: 'sp_14d_cap10',
    wcMode: 'wc_14d_c0s2',
  });
  assert.equal(spCap10Legacy.wc_mode, 'wc_14d_c0s2');
  const cap10LegacyU1 = Object.fromEntries(spCap10Legacy.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(cap10LegacyU1.end_nav - 1779823.16) <= 0.1);
  assert.equal(cap10LegacyU1.calmar, 0.677);
  assert.ok(Math.abs(cap10LegacyU1.margin_interest_usd - 816.85) <= 0.05);
  assert.equal(spCap10Legacy.live_sp_state.min_next_wc_strike, 625.43);
  assert.ok(spCap10Legacy.live_sp_state.badge_zh.includes('14D Wheel Call（K >= $625.43，max(成本, 1.02×现价)）'));

  const spUnfLegacy = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_d35',
    spMode: 'sp_14d_unf',
    wcMode: 'wc_14d_c0s2',
  });
  const unfLegacyU1 = Object.fromEntries(spUnfLegacy.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(unfLegacyU1.end_nav - 1846991.83) <= 0.1);

  // Standalone Engine 3 on Pure QQQ (NoPut_CallOnly + cc_off + sp_14d_unf)
  const spStandaloneRec = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'NoPut_CallOnly',
    tpMode: 'layered_itm',
    ccMode: 'cc_off',
    spMode: 'sp_14d_unf',
  });
  const standaloneRecNoPut = Object.fromEntries(spStandaloneRec.strategies_summary.map(s => [s.id, s])).NoPut_CallOnly;
  assert.ok(Math.abs(standaloneRecNoPut.end_nav - 1427923.23) <= 0.1);

  const spStandalone30d = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'NoPut_CallOnly',
    tpMode: 'layered_itm',
    ccMode: 'cc_off',
    spMode: 'sp_14d_unf',
    wcMode: 'wc_30d_c5s5',
  });
  const standalone30dNoPut = Object.fromEntries(spStandalone30d.strategies_summary.map(s => [s.id, s])).NoPut_CallOnly;
  assert.ok(Math.abs(standalone30dNoPut.end_nav - 1449831.69) <= 0.1);

  const spStandaloneLegacy = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'NoPut_CallOnly',
    tpMode: 'layered_itm',
    ccMode: 'cc_off',
    spMode: 'sp_14d_unf',
    wcMode: 'wc_14d_c0s2',
  });
  const standaloneNoPut = Object.fromEntries(spStandaloneLegacy.strategies_summary.map(s => [s.id, s])).NoPut_CallOnly;
  assert.ok(Math.abs(standaloneNoPut.end_nav - 1387278.02) <= 0.1, `Expected $1,387,278.02, got ${standaloneNoPut.end_nav}`);
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

  // Live runtime forward extension on sp_14d_cap10 + wc_reclaim_30d_d35:
  // On 2026-11-23 QQQ rebounds to $626.70 >= $625.43 cost -> transitions from wait_reclaim to wheel_assigned_wc_armed!
  const liveExtSp = await loadCrisisObservatoryDashboardLive({
    asOf: '2026-11-23',
    strategy: 'U1_PureOptions',
    tpMode: 'layered_itm',
    ccMode: 'cc_d12_d35',
    spMode: 'sp_14d_cap10',
    fetchLiveBars: async () => [
      { date: '2026-11-20', qqqClose: 608.45, vixClose: 35.89, vix3mClose: 30.94, vxnClose: 45.25 },
      { date: '2026-11-23', qqqClose: 626.7, vixClose: 27.4, vix3mClose: 28.5, vxnClose: 36.1 },
    ],
  });
  assert.equal(liveExtSp.wc_mode, 'wc_reclaim_30d_d35');
  assert.equal(liveExtSp.live_sp_state.position_state, 'wheel_assigned_wc_armed');
  assert.ok(liveExtSp.live_sp_state.min_next_wc_strike > 626.7);
  assert.ok(liveExtSp.live_sp_state.badge_zh.includes('30D 0.35Δ Wheel Call'));
});

test('validates parameters and serves both /api/investment/crisis-observatory and /api/discover/crisis-observatory', async t => {
  assert.equal(CRISIS_OBSERVATORY_STRATEGIES.length, 6);
  assert.deepEqual(CRISIS_OBSERVATORY_TP_MODES, ['layered_itm', 'standard_dual', 'both_4x']);
  assert.deepEqual(CRISIS_OBSERVATORY_CC_MODES, ['cc_off', 'cc_d12_d35', 'cc_d12_r45', 'cc_d12_cr55']);
  assert.deepEqual(CRISIS_OBSERVATORY_SP_MODES, ['sp_off', 'sp_14d_cap10', 'sp_10d_vixf', 'sp_14d_unf']);
  assert.deepEqual(CRISIS_OBSERVATORY_WC_MODES, ['wc_reclaim_30d_d35', 'wc_30d_c5s5', 'wc_14d_c0s2']);

  // Pure Call-only comparison strategy (NoPut_CallOnly)
  const callOnlyDoc = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'NoPut_CallOnly',
    ccMode: 'cc_d12_d35',
  });
  assert.equal(callOnlyDoc.selected_strategy_id, 'NoPut_CallOnly');
  assert.ok(Math.abs(callOnlyDoc.daily_series.at(-1).nav_cc - 1364435.75) <= 2.0);
  assert.throws(() => loadCrisisObservatoryDashboard({ strategy: 'UNKNOWN' }), /invalid_crisis_observatory_strategy/);
  assert.throws(() => loadCrisisObservatoryDashboard({ tpMode: 'UNKNOWN_TP' }), /invalid_crisis_observatory_tp_mode/);
  assert.throws(() => loadCrisisObservatoryDashboard({ ccMode: 'UNKNOWN_CC' }), /invalid_crisis_observatory_cc_mode/);
  assert.throws(() => loadCrisisObservatoryDashboard({ spMode: 'UNKNOWN_SP' }), /invalid_crisis_observatory_sp_mode/);
  assert.throws(() => loadCrisisObservatoryDashboard({ wcMode: 'UNKNOWN_WC' }), /invalid_crisis_observatory_wc_mode/);
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

  const resSp = await fetch(
    `http://127.0.0.1:${port}/api/investment/crisis-observatory?strategy=U1_PureOptions&tpMode=layered_itm&ccMode=cc_d12_d35&spMode=sp_14d_cap10&asOf=2026-11-20`,
    { headers: authHeaders },
  );
  assert.equal(resSp.status, 200);
  const bodySp = await resSp.json();
  assert.equal(bodySp.sp_mode, 'sp_14d_cap10');
  assert.equal(bodySp.wc_mode, 'wc_reclaim_30d_d35');
  const httpU1 = Object.fromEntries(bodySp.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(httpU1.end_nav - 1805855.89) <= 0.1);

  const resSp30d = await fetch(
    `http://127.0.0.1:${port}/api/investment/crisis-observatory?strategy=U1_PureOptions&tpMode=layered_itm&ccMode=cc_d12_d35&spMode=sp_14d_cap10&wcMode=wc_30d_c5s5&asOf=2026-11-20`,
    { headers: authHeaders },
  );
  assert.equal(resSp30d.status, 200);
  const bodySp30d = await resSp30d.json();
  assert.equal(bodySp30d.wc_mode, 'wc_30d_c5s5');
  const http30dU1 = Object.fromEntries(bodySp30d.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(http30dU1.end_nav - 1819738.31) <= 0.1);

  const resSpLegacy = await fetch(
    `http://127.0.0.1:${port}/api/discover/crisis-observatory?strategy=U1_PureOptions&tpMode=layered_itm&ccMode=cc_d12_d35&spMode=sp_14d_cap10&wcMode=wc_14d_c0s2&asOf=2026-11-20`,
    { headers: authHeaders },
  );
  assert.equal(resSpLegacy.status, 200);
  const bodySpLegacy = await resSpLegacy.json();
  assert.equal(bodySpLegacy.wc_mode, 'wc_14d_c0s2');
  const httpLegacyU1 = Object.fromEntries(bodySpLegacy.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(httpLegacyU1.end_nav - 1779823.16) <= 0.1);
});
