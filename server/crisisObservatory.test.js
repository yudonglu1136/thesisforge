import test from 'node:test';
import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import express from 'express';
import {
  CRISIS_OBSERVATORY_VERSION,
  CRISIS_OBSERVATORY_STRATEGIES,
  CRISIS_OBSERVATORY_PUT_OTMS,
  CRISIS_OBSERVATORY_M7_TP_MODES,
  CRISIS_OBSERVATORY_ROLL_MODES,
  CRISIS_OBSERVATORY_TP_MODES,
  CRISIS_OBSERVATORY_CC_MODES,
  CRISIS_OBSERVATORY_SP_MODES,
  CRISIS_OBSERVATORY_WC_MODES,
  loadCrisisObservatoryDashboard,
  loadCrisisObservatoryDashboardLive,
} from './crisisObservatory.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

test('loads canonical 2026-11-20 M7-Graded Crisis Observatory payload with Tenor/Roll, OTM, TP, M0 & 3-Engine modes', () => {
  const doc = loadCrisisObservatoryDashboard({ asOf: '2026-11-20' });
  assert.equal(doc.version, CRISIS_OBSERVATORY_VERSION);
  assert.equal(doc.as_of_date, '2026-11-20');
  assert.equal(doc.selected_strategy_id, 'M7G_Graded');
  assert.equal(doc.put_otm, 'otm15');
  assert.equal(doc.m7_tp_mode, 'standard');
  assert.equal(doc.roll_mode, '90d_hold');
  assert.equal(doc.m0_enabled, true);
  assert.equal(doc.tp_mode, 'layered_itm');
  assert.equal(doc.cc_mode, 'cc_off');
  assert.equal(doc.tp_modes, undefined, 'Raw tp_modes bundle must be stripped from API wire response');
  assert.equal(doc.mode_bundles, undefined, 'Raw mode_bundles must be stripped from API wire response');
  assert.equal(doc.m7_bundles, undefined, 'Raw m7_bundles must be stripped from API wire response');
  assert.equal(doc.m7_signals, undefined, 'Raw m7_signals must be stripped from API wire response');
  assert.equal(doc.m7_feature_table, undefined, 'Raw m7_feature_table must be stripped from API wire response');
  assert.equal(doc.m7_live_tail_state, undefined, 'Raw m7_live_tail_state must be stripped from API wire response');
  assert.equal(doc.m7_eval_bars, undefined, 'Raw m7_eval_bars must be stripped from API wire response');
  assert.equal(doc.put_otm_meta.length, 2);
  assert.equal(doc.m7_tp_modes_meta.length, 2);
  assert.equal(doc.m7_roll_modes_meta.length, 2);
  assert.equal(doc.tp_modes_meta.length, 3);
  assert.equal(doc.cc_modes_meta.length, 4);
  assert.ok(doc.snapshotId && doc.snapshotId.length === 16);

  // Verify M7 Live Dashboard 3-Pillar + Sizing + TP Monitor
  const m7Dash = doc.m7_live_dashboard;
  assert.ok(m7Dash, 'm7_live_dashboard must be populated');
  assert.equal(m7Dash.as_of_date, '2026-11-20');
  assert.equal(m7Dash.strategy_id, 'M7G_Graded');
  assert.equal(m7Dash.put_otm, 'otm15');
  assert.equal(m7Dash.m7_tp_mode, 'standard');
  assert.equal(m7Dash.roll_mode, '90d_hold');
  assert.equal(m7Dash.m0_enabled, true);
  assert.equal(m7Dash.pillars.length, 3);
  assert.equal(m7Dash.pillars[0].modules.length, 2);
  assert.equal(m7Dash.pillars[1].modules.length, 2);
  assert.equal(m7Dash.pillars[2].modules.length, 2);
  assert.equal(m7Dash.redline.blocked, true);
  assert.equal(m7Dash.sizing_calculator.dte, 90);
  assert.equal(m7Dash.sizing_calculator.skew_switch_threshold, 1.18);
  assert.ok(m7Dash.sizing_calculator.sample_1000sh_budget_usd > 0);
  assert.equal(m7Dash.tp_monitor.tp_code, 'STANDARD');

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

  // Legacy U1 live signal state when U1_PureOptions is selected
  const u1Doc = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', strategy: 'U1_PureOptions' });
  const sig = u1Doc.live_signal_state;
  assert.equal(sig.regime_code, 'VIX110_TP_TRIGGERED');
  assert.equal(sig.target_equity_pct, 100);
  assert.equal(sig.target_tbill_pct, 0);
  assert.equal(sig.slow_bear_shield, undefined);
  assert.equal(sig.slot1_naked_put.status, 'TP_TRIGGERED_NEXT_OPEN');
  assert.equal(sig.slot2_collar.status, 'FROZEN_BELOW_ATH5');
  assert.equal(sig.gate_checklist.length, 5);

  const smap = Object.fromEntries(doc.strategies_summary.map(s => [s.id, s]));
  assert.equal(smap.U4_DualEngine, undefined);
  assert.ok(Math.abs(smap.M7G_Graded.end_nav - 1682250.03) <= 0.1);
  assert.equal(smap.M7G_Graded.cagr_pct, 19.63);
  assert.equal(smap.M7G_Graded.max_dd_pct, -28.02);
  assert.equal(smap.M7G_Graded.calmar, 0.701);
  assert.equal(smap.M7G_Graded.sharpe, 0.983);
  assert.ok(Math.abs(smap.M7_Ensemble.end_nav - 1676747.11) <= 0.1);
  assert.ok(Math.abs(smap.U1_PureOptions.end_nav - 1654577.25) <= 0.5);
  assert.ok(Math.abs(smap.U1_PureOptions.net_alpha_usd - 366272.47) <= 0.5);
  assert.equal(smap.U1_PureOptions.cagr_pct, 19.46);
  assert.equal(smap.U1_PureOptions.max_dd_pct, -31.52);
  assert.equal(smap.U1_PureOptions.sharpe, 0.859);
  assert.ok(Math.abs(smap.B1c_PureAD.end_nav - 1587800.99) <= 0.5);
  assert.ok(Math.abs(smap.D2_SixLights.end_nav - 1497620.82) <= 0.5);
  assert.ok(Math.abs(smap.H2_G4_PriceGate.end_nav - 1402250.68) <= 0.5);
  assert.ok(Math.abs(smap.BH_Pure_QQQ.end_nav - 1288304.78) <= 0.02);

  // Selectable M7 Tenor/Roll Mode (`120d_roll50`), Put OTM (`otm20`), TP (`itm_tp`), and M0 OFF
  const m7Roll15 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    rollMode: '120d_roll50',
  });
  assert.equal(m7Roll15.roll_mode, '120d_roll50');
  assert.equal(m7Roll15.m7_live_dashboard.sizing_calculator.dte, 120);
  assert.equal(m7Roll15.m7_live_dashboard.sizing_calculator.roll_dte, 50);
  const m7Roll15S = Object.fromEntries(m7Roll15.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7Roll15S.end_nav - 1625935.17) <= 0.1);
  assert.equal(m7Roll15S.cagr_pct, 19.29);
  assert.equal(m7Roll15S.max_dd_pct, -28.43);
  assert.equal(m7Roll15S.sharpe, 0.983);
  assert.equal(m7Roll15S.roll_50d_count, 32);
  assert.ok(Math.abs(m7Roll15S.avg_roll_salvage_pct - 37.6) <= 0.2);
  assert.ok(m7Roll15.events.some(ev => ev.event_type === 'roll_50d'));

  const m7Otm20Hold = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    putOtm: 'otm20',
  });
  const m7Otm20HoldS = Object.fromEntries(m7Otm20Hold.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7Otm20HoldS.end_nav - 1856309.08) <= 0.1);
  assert.equal(m7Otm20HoldS.cagr_pct, 20.62);
  assert.equal(m7Otm20HoldS.max_dd_pct, -27.98);
  assert.equal(m7Otm20HoldS.sharpe, 1.029);

  const m7Otm20Roll = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    putOtm: 'otm20',
    rollMode: '120d_roll50',
  });
  const m7Otm20RollS = Object.fromEntries(m7Otm20Roll.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7Otm20RollS.end_nav - 1823635.0) <= 0.1);
  assert.equal(m7Otm20RollS.sharpe, 1.038);
  assert.equal(m7Otm20RollS.roll_50d_count, 32);

  const m7ItmTp = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    m7TpMode: 'itm_tp',
  });
  const m7ItmS = Object.fromEntries(m7ItmTp.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7ItmS.end_nav - 1523801.1) <= 0.1);
  assert.equal(m7ItmS.max_dd_pct, -24.44);
  assert.equal(m7ItmS.calmar, 0.763);
  assert.equal(m7ItmTp.m7_live_dashboard.active_slots, 1);

  const m7NoM0 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    m0Enabled: 'false',
  });
  assert.equal(m7NoM0.m0_enabled, false);
  assert.equal(m7NoM0.m7_live_dashboard.pillars[0].modules[0].enabled, false);

  // M7G_Graded + Engine 2 + Engine 3 dynamic pure-JS combo & additive 3-engine attribution
  const m7Combo3 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'M7G_Graded',
    putOtm: 'otm15',
    rollMode: '90d_hold',
    ccMode: 'cc_d12_d35',
    spMode: 'sp_14d_cap10',
  });
  const attrM7Combo = m7Combo3.engine_attribution_by_strategy?.M7G_Graded;
  assert.ok(attrM7Combo);
  assert.equal(attrM7Combo.active_engines_count, 3);
  assert.ok(
    Math.abs(
      attrM7Combo.base_end_nav +
        attrM7Combo.engine1.delta_usd +
        attrM7Combo.engine2.delta_usd +
        attrM7Combo.engine3.delta_usd -
        attrM7Combo.total_end_nav,
    ) <= 0.05,
  );

  assert.equal(doc.crisis_windows.length, 7);
  assert.equal(doc.crisis_windows.at(-1).id, '2026-08_11_LIVE');
  assert.ok(doc.crisis_windows[2].m7_narrative_zh.includes('2020-01-28'));
  assert.equal(doc.daily_series.length, 2990);
  assert.ok(Number.isFinite(doc.daily_series.at(-1).nav_m7g));
  assert.ok(Number.isFinite(doc.daily_series.at(-1).m7_prob));
  assert.deepEqual(doc.shield_events, []);

  // Selectable TP mode projections: standard_dual and both_4x
  const stdDoc = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', strategy: 'U1_PureOptions', tpMode: 'standard_dual' });
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
    strategy: 'U1_PureOptions',
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
  assert.ok(gzBytes < 480 * 1024, `Projected single-mode gzipped payload must stay compact (<480 KB), got ${gzBytes}`);

  const spVixf = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'U1_PureOptions',
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
    strategy: 'U1_PureOptions',
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
    strategy: 'U1_PureOptions',
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
    strategy: 'U1_PureOptions',
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
    strategy: 'U1_PureOptions',
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

test('slices historical asOf cutoffs without lookahead and extends M7 causally on live EOD bars', async () => {
  // Leak-free M7G_Graded cutoff on 2026-10-15: 35% score -> 1 graded Put slot (8/31), future 11/06 TP masked!
  const midOctM7 = loadCrisisObservatoryDashboard({
    asOf: '2026-10-15',
    strategy: 'M7G_Graded',
  });
  assert.equal(midOctM7.as_of_date, '2026-10-15');
  assert.equal(midOctM7.m7_live_dashboard.as_of_date, '2026-10-15');
  assert.equal(midOctM7.m7_live_dashboard.active_slots, 1);
  assert.ok(!midOctM7.events.some(ev => ev.date > '2026-10-15'));
  const openM7 = midOctM7.trade_ledger.filter(t => t.exit_date === null);
  assert.equal(openM7.length, 1);
  assert.ok(openM7.every(t => t.exit_reason === 'open_as_of_cutoff' && t.net_pnl_usd === null && t.roi_mult === null));

  // Meanwhile M7_Ensemble (>=35% -> 2 slots) has 2 open slots on 2026-10-15
  const midOctEns = loadCrisisObservatoryDashboard({
    asOf: '2026-10-15',
    strategy: 'M7_Ensemble',
  });
  assert.equal(midOctEns.m7_live_dashboard.active_slots, 2);
  assert.equal(midOctEns.trade_ledger.filter(t => t.exit_date === null).length, 2);

  // On 2026-10-15, both Slot 1 (entered 2026-08-31) and Slot 2 (entered 2026-10-05) are OPEN on U1_PureOptions too
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

  // Live runtime forward extension onto 2026-11-23 steps M7 causally and updates m7_live_dashboard
  const liveExtM7 = await loadCrisisObservatoryDashboardLive({
    asOf: '2026-11-23',
    strategy: 'M7G_Graded',
    rollMode: '120d_roll50',
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
  assert.equal(liveExtM7.liveExtended, true);
  assert.equal(liveExtM7.as_of_date, '2026-11-23');
  assert.equal(liveExtM7.m7_live_dashboard.as_of_date, '2026-11-23');
  assert.equal(liveExtM7.m7_live_dashboard.roll_mode, '120d_roll50');
  assert.equal(liveExtM7.m7_live_dashboard.sizing_calculator.qqq_spot, 626.7);
  assert.equal(liveExtM7.m7_live_dashboard.redline.blocked, true, 'VXN 36.1 > 27 must trigger redline block');

  // Live runtime forward extension onto 2026-11-23 stays 100% QQQ pure options on U1
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
  assert.equal(CRISIS_OBSERVATORY_STRATEGIES.length, 8);
  assert.deepEqual(CRISIS_OBSERVATORY_PUT_OTMS, ['otm15', 'otm20']);
  assert.deepEqual(CRISIS_OBSERVATORY_M7_TP_MODES, ['standard', 'itm_tp']);
  assert.deepEqual(CRISIS_OBSERVATORY_ROLL_MODES, ['90d_hold', '120d_roll50']);
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
  assert.throws(() => loadCrisisObservatoryDashboard({ putOtm: 'otm99' }), /invalid_crisis_observatory_put_otm/);
  assert.throws(() => loadCrisisObservatoryDashboard({ m7TpMode: 'UNKNOWN_M7TP' }), /invalid_crisis_observatory_m7_tp_mode/);
  assert.throws(() => loadCrisisObservatoryDashboard({ rollMode: 'UNKNOWN_ROLL' }), /invalid_crisis_observatory_roll_mode/);
  assert.throws(() => loadCrisisObservatoryDashboard({ m0Enabled: 'maybe' }), /invalid_crisis_observatory_m0_enabled/);
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

  // Authenticated -> 200 default M7G_Graded + rollMode=120d_roll50 + putOtm=otm20
  const authHeaders = { 'x-test-auth': '1' };
  const [resM7Def, resM7Roll] = await Promise.all([
    fetch(`http://127.0.0.1:${port}/api/investment/crisis-observatory?asOf=2026-11-20`, {
      headers: authHeaders,
    }),
    fetch(
      `http://127.0.0.1:${port}/api/discover/crisis-observatory?putOtm=otm20&rollMode=120d_roll50&m7TpMode=standard&m0Enabled=true&asOf=2026-11-20`,
      { headers: authHeaders },
    ),
  ]);
  assert.equal(resM7Def.status, 200);
  assert.equal(resM7Roll.status, 200);
  const bodyM7Def = await resM7Def.json();
  const bodyM7Roll = await resM7Roll.json();
  assert.equal(bodyM7Def.selected_strategy_id, 'M7G_Graded');
  assert.equal(bodyM7Def.roll_mode, '90d_hold');
  assert.equal(bodyM7Roll.put_otm, 'otm20');
  assert.equal(bodyM7Roll.roll_mode, '120d_roll50');
  const httpM7Roll = Object.fromEntries(bodyM7Roll.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(httpM7Roll.end_nav - 1823635.0) <= 0.1);
  assert.equal(httpM7Roll.sharpe, 1.038);

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
