import test from 'node:test';
import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import express from 'express';
import {
  CRISIS_OBSERVATORY_VERSION,
  CRISIS_OBSERVATORY_PROFILES,
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
  loadCrisisObservatoryPitSnapshot,
} from './crisisObservatory.js';
import { parseFredCsvText, computeLiveStressIndexJS } from './crisisObservatoryM7.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

test('loads canonical 2026-11-20 M7-Graded & Core-3 Crisis Observatory payload with MIT Real-OPRA (2015-2025) + Calibrated BSM & Adaptive Roll', () => {
  const doc = loadCrisisObservatoryDashboard({ asOf: '2026-11-20' });
  assert.equal(doc.version, CRISIS_OBSERVATORY_VERSION);
  assert.equal(doc.as_of_date, '2026-11-20');
  assert.equal(doc.profile, 'full_m7_adaptive');
  assert.equal(doc.selected_profile, 'full_m7_adaptive');
  assert.equal(doc.core3_roll_locked, false);
  assert.equal(doc.selected_strategy_id, 'M7G_Graded');
  assert.equal(doc.put_otm, 'otm15');
  assert.equal(doc.m7_tp_mode, 'standard');
  assert.equal(doc.roll_mode, 'adaptive_120_90');
  assert.equal(doc.m0_enabled, true);
  assert.equal(doc.tp_mode, 'layered_itm');
  assert.equal(doc.cc_mode, 'cc_off');
  assert.equal(doc.pricing_provenance?.mode, 'real_opra_calibrated_bsm');
  assert.equal(doc.pricing_provenance?.segment1_real_opra?.trading_days, 2749);
  assert.equal(doc.pricing_provenance?.segment1_real_opra?.quotes_count, 9875299);
  assert.equal(doc.pricing_provenance?.segment1_real_opra?.execution_fallbacks, 0);
  assert.equal(
    doc.pricing_provenance?.audited_opra_benchmarks_2015_2025?.full_m7_adaptive_ask_bid?.end_nav,
    1451369.05,
  );
  assert.equal(
    doc.pricing_provenance?.audited_opra_benchmarks_2015_2025?.core3_adaptive_ask_bid?.end_nav,
    1481937.31,
  );
  assert.equal(doc.tp_modes, undefined, 'Raw tp_modes bundle must be stripped from API wire response');
  assert.equal(doc.mode_bundles, undefined, 'Raw mode_bundles must be stripped from API wire response');
  assert.equal(doc.m7_bundles, undefined, 'Raw m7_bundles must be stripped from API wire response');
  assert.equal(doc.m7_signals, undefined, 'Raw m7_signals must be stripped from API wire response');
  assert.equal(doc.m7_feature_table, undefined, 'Raw m7_feature_table must be stripped from API wire response');
  assert.equal(doc.m7_live_tail_state, undefined, 'Raw m7_live_tail_state must be stripped from API wire response');
  assert.equal(doc.m7_eval_bars, undefined, 'Raw m7_eval_bars must be stripped from API wire response');
  assert.equal(doc.profiles_meta.length, 2);
  assert.equal(doc.put_otm_meta.length, 2);
  assert.equal(doc.m7_tp_modes_meta.length, 2);
  assert.equal(doc.m7_roll_modes_meta.length, 3);
  assert.equal(doc.tp_modes_meta.length, 3);
  assert.equal(doc.cc_modes_meta.length, 4);
  assert.ok(doc.snapshotId && doc.snapshotId.length === 16);

  // Verify 2025-12-15 -> 2025-12-16 OPRA-to-BSM seam continuity (0.0000% jump)
  const bar1215 = doc.daily_series.find(r => r.date === '2025-12-15');
  const bar1216 = doc.daily_series.find(r => r.date === '2025-12-16');
  assert.equal(bar1215.nav_m7g, 1451369.05);
  assert.equal(bar1215.nav_c3, 1481937.31);
  assert.equal(
    doc.pricing_provenance?.audited_opra_benchmarks_2015_2025?.qqq_bh_end_nav,
    1286327.45,
  );
  const qRetSeam = bar1216.qqq_close / bar1215.qqq_close - 1;
  const m7RetSeam = bar1216.nav_m7g / bar1215.nav_m7g - 1;
  const c3RetSeam = bar1216.nav_c3 / bar1215.nav_c3 - 1;
  assert.ok(Math.abs(m7RetSeam - qRetSeam) < 1e-5, '0.0000% seam tracking jump on Full M7');
  assert.ok(Math.abs(c3RetSeam - qRetSeam) < 1e-5, '0.0000% seam tracking jump on Core-3');

  // Verify quoteSource tagging & real OCC contract metadata in trade_ledger
  const opraTrades = doc.trade_ledger.filter(t => t.entry_date <= '2025-12-15');
  const bsmTrades = doc.trade_ledger.filter(t => t.entry_date > '2025-12-15');
  assert.equal(opraTrades.length, 45);
  assert.equal(bsmTrades.length, 2);
  assert.ok(opraTrades.every(t => t.quoteSource === 'REAL_OPRA' && String(t.occSymbol || '').startsWith('QQQ')));
  assert.ok(bsmTrades.every(t => t.quoteSource === 'CALIBRATED_BSM'));

  // Verify M7 Live Dashboard 3-Pillar + Sizing + TP Monitor (default adaptive_120_90)
  const m7Dash = doc.m7_live_dashboard;
  assert.ok(m7Dash, 'm7_live_dashboard must be populated');
  assert.equal(m7Dash.as_of_date, '2026-11-20');
  assert.equal(m7Dash.strategy_id, 'M7G_Graded');
  assert.equal(m7Dash.profile, 'full_m7_adaptive');
  assert.equal(m7Dash.put_otm, 'otm15');
  assert.equal(m7Dash.m7_tp_mode, 'standard');
  assert.equal(m7Dash.roll_mode, 'adaptive_120_90');
  assert.equal(m7Dash.m0_enabled, true);
  assert.equal(m7Dash.pillars.length, 3);
  assert.equal(m7Dash.pillars[0].modules.length, 2);
  assert.equal(m7Dash.pillars[1].modules.length, 2);
  assert.equal(m7Dash.pillars[2].modules.length, 2);
  assert.equal(m7Dash.redline.blocked, true);
  assert.equal(m7Dash.sizing_calculator.dte, 120);
  assert.equal(m7Dash.sizing_calculator.roll_dte, 50);
  assert.equal(m7Dash.sizing_calculator.skew_switch_threshold, 1.18);
  assert.ok(m7Dash.sizing_calculator.sample_1000sh_budget_usd > 0);
  assert.equal(m7Dash.tp_monitor.tp_code, 'STANDARD');

  // Option 2: Core-3 Minimal (Adaptive) + SAFETY GUARDRAIL against 90D Hold
  const c3Doc = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    profile: 'core3_adaptive',
    rollMode: '90d_hold', // must be locked/clamped to adaptive_120_90!
  });
  assert.equal(c3Doc.profile, 'core3_adaptive');
  assert.equal(c3Doc.selected_strategy_id, 'Core3_Adaptive');
  assert.equal(c3Doc.roll_mode, 'adaptive_120_90');
  assert.equal(c3Doc.core3_roll_locked, true);
  assert.equal(c3Doc.trade_ledger.length, 32);
  assert.equal(c3Doc.trade_ledger.filter(t => t.quoteSource === 'REAL_OPRA').length, 30);
  assert.equal(c3Doc.m7_live_dashboard.strategy_id, 'Core3_Adaptive');
  assert.equal(c3Doc.m7_live_dashboard.pillars[1].disabled_in_core3, true);
  assert.equal(c3Doc.m7_live_dashboard.pillars[1].modules[0].disabled_in_core3, true); // M2
  assert.equal(c3Doc.m7_live_dashboard.pillars[1].modules[1].disabled_in_core3, true); // M5
  assert.equal(c3Doc.m7_live_dashboard.pillars[2].modules[1].disabled_in_core3, true); // M3
  assert.equal(c3Doc.m7_live_dashboard.pillars[2].modules[0].disabled_in_core3, false); // M4 active

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

  // Real-OPRA Strict Ask/Bid + Post-2025 Calibrated BSM Champions
  const smap = Object.fromEntries(doc.strategies_summary.map(s => [s.id, s]));
  assert.equal(smap.U4_DualEngine, undefined);
  assert.equal(smap.M7G_Graded.pricing_basis, 'real_opra_2015_2025_calibrated_bsm');
  assert.equal(smap.M7G_Graded.real_trades_pct, 95.7);
  assert.ok(Math.abs(smap.M7G_Graded.end_nav - 1466143.41) <= 0.1);
  assert.equal(smap.M7G_Graded.cagr_pct, 18.25);
  assert.equal(smap.M7G_Graded.max_dd_pct, -28.32);
  assert.equal(smap.M7G_Graded.calmar, 0.645);
  assert.equal(smap.M7G_Graded.sharpe, 0.918);
  assert.equal(smap.M7G_Graded.roll_50d_count, 28);
  assert.equal(smap.M7G_Graded.roll_30d_count, 4);
  assert.ok(doc.events.some(ev => ev.event_type === 'roll_50d'));
  assert.ok(doc.events.some(ev => ev.event_type === 'roll_30d'));
  assert.ok(Math.abs(smap.Core3_Adaptive.end_nav - 1497022.85) <= 0.1);
  assert.equal(smap.Core3_Adaptive.tranches_total, 32);
  assert.equal(smap.Core3_Adaptive.real_opra_trades_count, 30);
  assert.ok(Math.abs(smap.M7_Ensemble.end_nav - 1437260.55) <= 0.1);
  assert.ok(Math.abs(smap.U1_PureOptions.end_nav - 1322402.31) <= 0.5);
  assert.ok(smap.M7G_Graded.end_nav > smap.U1_PureOptions.end_nav + 140000);
  assert.ok(Math.abs(smap.B1c_PureAD.end_nav - 1347636.26) <= 0.5);
  assert.ok(Math.abs(smap.D2_SixLights.end_nav - 1351686.36) <= 0.5);
  assert.ok(Math.abs(smap.H2_G4_PriceGate.end_nav - 1252925.34) <= 0.5);
  assert.ok(Math.abs(smap.BH_Pure_QQQ.end_nav - 1288304.78) <= 0.02);

  // Selectable M7 Tenor/Roll Mode (`120d_roll50` & `90d_hold`), Put OTM (`otm20`), TP (`itm_tp`), and M0 OFF
  const m7Roll50 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    rollMode: '120d_roll50',
  });
  const m7Roll50S = Object.fromEntries(m7Roll50.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7Roll50S.end_nav - 1436762.5) <= 0.1);
  assert.equal(m7Roll50S.roll_50d_count, 33);

  const m7Hold15 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    rollMode: '90d_hold',
  });
  assert.equal(m7Hold15.roll_mode, '90d_hold');
  assert.equal(m7Hold15.m7_live_dashboard.sizing_calculator.dte, 90);
  const m7Hold15S = Object.fromEntries(m7Hold15.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7Hold15S.end_nav - 1343816.19) <= 0.1);
  assert.equal(m7Hold15S.cagr_pct, 17.39);
  assert.equal(m7Hold15S.max_dd_pct, -28.05);
  assert.ok(smap.M7G_Graded.end_nav > m7Roll50S.end_nav && m7Roll50S.end_nav > m7Hold15S.end_nav);

  const m7Otm20Roll = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    putOtm: 'otm20',
    rollMode: '120d_roll50',
  });
  const m7Otm20RollS = Object.fromEntries(m7Otm20Roll.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7Otm20RollS.end_nav - 1420675.17) <= 0.1);
  assert.equal(m7Otm20RollS.roll_50d_count, 33);

  const m7Otm20Hold = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    putOtm: 'otm20',
    rollMode: '90d_hold',
  });
  const m7Otm20HoldS = Object.fromEntries(m7Otm20Hold.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7Otm20HoldS.end_nav - 1274910.48) <= 0.1);

  const m7ItmTp = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    m7TpMode: 'itm_tp',
    rollMode: '90d_hold',
  });
  const m7ItmS = Object.fromEntries(m7ItmTp.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7ItmS.end_nav - 1290849.77) <= 0.1);
  assert.equal(m7ItmS.max_dd_pct, -27.87);

  const m7NoM0 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    m0Enabled: 'false',
  });
  assert.equal(m7NoM0.m0_enabled, false);
  assert.equal(m7NoM0.m7_live_dashboard.pillars[0].modules[0].enabled, false);

  // M7G_Graded + Engine 3 dynamic pure-JS Real-OPRA combo
  const m7Cap10 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'M7G_Graded',
    putOtm: 'otm15',
    rollMode: 'adaptive_120_90',
    spMode: 'sp_14d_cap10',
  });
  const m7Cap10S = Object.fromEntries(m7Cap10.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(m7Cap10S.end_nav - 1561466.56) <= 2.5, `Expected $1,561,466.56, got ${m7Cap10S.end_nav}`);
  assert.equal(m7Cap10S.max_dd_pct, -28.17);
  assert.equal(m7Cap10S.calmar, 0.67);

  // M7G_Graded + Engine 2 + Engine 3 dynamic pure-JS combo & additive 3-engine attribution
  const m7Combo3 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'M7G_Graded',
    putOtm: 'otm15',
    rollMode: 'adaptive_120_90',
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
    ) <= 0.1,
  );

  assert.equal(doc.crisis_windows.length, 7);
  assert.equal(doc.crisis_windows.at(-1).id, '2026-08_11_LIVE');
  assert.ok(doc.crisis_windows[2].m7_narrative_zh.includes('2020-01-28'));
  assert.equal(doc.daily_series.length, 2990);
  assert.ok(Number.isFinite(doc.daily_series.at(-1).nav_m7g));
  assert.ok(Number.isFinite(doc.daily_series.at(-1).nav_c3));
  assert.ok(Number.isFinite(doc.daily_series.at(-1).m7_prob));
  assert.deepEqual(doc.shield_events, []);

  // Legacy aliases map cleanly
  const legacyCcAlias = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', ccMode: 'cc_high_vol' });
  assert.equal(legacyCcAlias.cc_mode, 'cc_d12_d35');
  const legacyAlwaysAlias = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', ccMode: 'cc_always_8' });
  assert.equal(legacyAlwaysAlias.cc_mode, 'cc_d12_r45');
  const legacyAlias = loadCrisisObservatoryDashboard({ asOf: '2026-11-20', strategy: 'U4_DualEngine' });
  assert.equal(legacyAlias.selected_strategy_id, 'U1_PureOptions');
  assert.equal(doc.sp_mode, 'sp_off');
  assert.equal(doc.wc_mode, 'wc_reclaim_30d_d35');
  assert.equal(doc.sp_modes_meta.length, 4);
  assert.equal(doc.wc_modes_meta.length, 3);
  assert.equal(doc.live_sp_state.position_state, 'disabled');

  // 3rd Engine (Short-DTE Panic Put Wheel) on strict real OPRA quotes (default wc_reclaim_30d_d35 + cc_off)
  const spCap10 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'U1_PureOptions',
    tpMode: 'layered_itm',
    ccMode: 'cc_off',
    spMode: 'sp_14d_cap10',
  });
  assert.equal(spCap10.sp_mode, 'sp_14d_cap10');
  assert.equal(spCap10.wc_mode, 'wc_reclaim_30d_d35');
  const cap10U1 = Object.fromEntries(spCap10.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(cap10U1.end_nav - 1393555.72) <= 0.1, `Expected $1,393,555.72, got ${cap10U1.end_nav}`);
  assert.equal(cap10U1.max_dd_pct, -32.88);
  assert.ok(cap10U1.real_trades_pct >= 90.0);
  assert.equal(spCap10.live_sp_state.position_state, 'wheel_assigned_wait_reclaim');
  assert.equal(spCap10.live_sp_state.min_next_wc_strike, 623.29);
  assert.ok(
    spCap10.sp_ledger.some(r => r.leg_type === 'short_put') &&
      spCap10.sp_ledger.some(r => r.leg_type === 'wheel_call'),
  );
  assert.ok(spCap10.crisis_windows[0].title_en && spCap10.crisis_windows[0].title_zh);

  // Additive 3-engine attribution identity on legacy U1 + Engine 3
  const attrCap10 = spCap10.engine_attribution_by_strategy?.U1_PureOptions;
  assert.ok(attrCap10, 'engine_attribution_by_strategy must be populated');
  assert.ok(
    Math.abs(
      attrCap10.base_end_nav +
        attrCap10.engine1.delta_usd +
        attrCap10.engine2.delta_usd +
        attrCap10.engine3.delta_usd -
        attrCap10.total_end_nav,
    ) <= 0.1,
  );

  const gzBytes = zlib.gzipSync(JSON.stringify(spCap10)).length;
  assert.ok(gzBytes < 520 * 1024, `Projected single-mode gzipped payload must stay compact (<520 KB), got ${gzBytes}`);

  // Standalone Engine 3 on Pure QQQ (NoPut_CallOnly + cc_off + sp_14d_unf)
  const spStandaloneRec = loadCrisisObservatoryDashboard({
    asOf: '2026-11-20',
    strategy: 'NoPut_CallOnly',
    tpMode: 'layered_itm',
    ccMode: 'cc_off',
    spMode: 'sp_14d_unf',
  });
  const standaloneRecNoPut = Object.fromEntries(spStandaloneRec.strategies_summary.map(s => [s.id, s])).NoPut_CallOnly;
  assert.ok(Math.abs(standaloneRecNoPut.end_nav - 1429966.08) <= 0.1);
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
  assert.deepEqual(CRISIS_OBSERVATORY_PROFILES, ['full_m7_adaptive', 'core3_adaptive']);
  assert.equal(CRISIS_OBSERVATORY_STRATEGIES.length, 9);
  assert.deepEqual(CRISIS_OBSERVATORY_PUT_OTMS, ['otm15', 'otm20']);
  assert.deepEqual(CRISIS_OBSERVATORY_M7_TP_MODES, ['standard', 'itm_tp']);
  assert.deepEqual(CRISIS_OBSERVATORY_ROLL_MODES, ['adaptive_120_90', '120d_roll50', '90d_hold']);
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
  assert.ok(Math.abs(callOnlyDoc.daily_series.at(-1).nav_cc - 1285518.97) <= 2.0);
  assert.throws(() => loadCrisisObservatoryDashboard({ profile: 'UNKNOWN_PROFILE' }), /invalid_crisis_observatory_profile/);
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

  // Authenticated -> 200 default Full M7 Shield (adaptive_120_90) + Core-3 Minimal (co_profile=core3_adaptive) + putOtm=otm20
  const authHeaders = { 'x-test-auth': '1' };
  const [resM7Def, resC3Guard, resM7Roll] = await Promise.all([
    fetch(`http://127.0.0.1:${port}/api/investment/crisis-observatory?asOf=2026-11-20`, {
      headers: authHeaders,
    }),
    fetch(
      `http://127.0.0.1:${port}/api/discover/crisis-observatory?co_profile=core3_adaptive&rollMode=90d_hold&asOf=2026-11-20`,
      { headers: authHeaders },
    ),
    fetch(
      `http://127.0.0.1:${port}/api/discover/crisis-observatory?putOtm=otm20&rollMode=120d_roll50&m7TpMode=standard&m0Enabled=true&asOf=2026-11-20`,
      { headers: authHeaders },
    ),
  ]);
  assert.equal(resM7Def.status, 200);
  assert.equal(resC3Guard.status, 200);
  assert.equal(resM7Roll.status, 200);
  const bodyM7Def = await resM7Def.json();
  const bodyC3Guard = await resC3Guard.json();
  const bodyM7Roll = await resM7Roll.json();
  assert.equal(bodyM7Def.profile, 'full_m7_adaptive');
  assert.equal(bodyM7Def.selected_strategy_id, 'M7G_Graded');
  assert.equal(bodyM7Def.roll_mode, 'adaptive_120_90');
  assert.equal(bodyC3Guard.profile, 'core3_adaptive');
  assert.equal(bodyC3Guard.selected_strategy_id, 'Core3_Adaptive');
  assert.equal(bodyC3Guard.roll_mode, 'adaptive_120_90', 'Core-3 must never allow 90D Hold');
  assert.equal(bodyC3Guard.core3_roll_locked, true);
  assert.equal(bodyM7Roll.put_otm, 'otm20');
  assert.equal(bodyM7Roll.roll_mode, '120d_roll50');
  const httpM7Roll = Object.fromEntries(bodyM7Roll.strategies_summary.map(s => [s.id, s])).M7G_Graded;
  assert.ok(Math.abs(httpM7Roll.end_nav - 1420675.17) <= 0.1);
  assert.equal(httpM7Roll.sharpe, 0.905);

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
    `http://127.0.0.1:${port}/api/investment/crisis-observatory?strategy=U1_PureOptions&tpMode=layered_itm&ccMode=cc_off&spMode=sp_14d_cap10&asOf=2026-11-20`,
    { headers: authHeaders },
  );
  assert.equal(resSp.status, 200);
  const bodySp = await resSp.json();
  assert.equal(bodySp.sp_mode, 'sp_14d_cap10');
  assert.equal(bodySp.wc_mode, 'wc_reclaim_30d_d35');
  const httpU1 = Object.fromEntries(bodySp.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(httpU1.end_nav - 1393555.72) <= 0.1);

  const resSp30d = await fetch(
    `http://127.0.0.1:${port}/api/investment/crisis-observatory?strategy=U1_PureOptions&tpMode=layered_itm&ccMode=cc_off&spMode=sp_14d_cap10&wcMode=wc_30d_c5s5&asOf=2026-11-20`,
    { headers: authHeaders },
  );
  assert.equal(resSp30d.status, 200);
  const bodySp30d = await resSp30d.json();
  assert.equal(bodySp30d.wc_mode, 'wc_30d_c5s5');
  const http30dU1 = Object.fromEntries(bodySp30d.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(http30dU1.end_nav - 1386765.62) <= 0.1);

  const resSpLegacy = await fetch(
    `http://127.0.0.1:${port}/api/discover/crisis-observatory?strategy=U1_PureOptions&tpMode=layered_itm&ccMode=cc_off&spMode=sp_14d_cap10&wcMode=wc_14d_c0s2&asOf=2026-11-20`,
    { headers: authHeaders },
  );
  assert.equal(resSpLegacy.status, 200);
  const bodySpLegacy = await resSpLegacy.json();
  assert.equal(bodySpLegacy.wc_mode, 'wc_14d_c0s2');
  const httpLegacyU1 = Object.fromEntries(bodySpLegacy.strategies_summary.map(s => [s.id, s])).U1_PureOptions;
  assert.ok(Math.abs(httpLegacyU1.end_nav - 1372072.61) <= 0.1);

  // Historical PIT snapshot API (/api/investment/crisis-observatory/pit & /api/discover/crisis-observatory/pit)
  const unauthPit = await fetch(`http://127.0.0.1:${port}/api/investment/crisis-observatory/pit?date=2020-01-28`);
  assert.equal(unauthPit.status, 401);
  const badPit = await fetch(`http://127.0.0.1:${port}/api/investment/crisis-observatory/pit?date=not-a-date`, {
    headers: authHeaders,
  });
  assert.equal(badPit.status, 400);

  const [resPitInv, resPitC3_2020, resPitDisc] = await Promise.all([
    fetch(`http://127.0.0.1:${port}/api/investment/crisis-observatory/pit?date=2020-01-28`, {
      headers: authHeaders,
    }),
    fetch(`http://127.0.0.1:${port}/api/discover/crisis-observatory/pit?date=2020-01-28&co_profile=core3_adaptive`, {
      headers: authHeaders,
    }),
    fetch(`http://127.0.0.1:${port}/api/discover/crisis-observatory/pit?date=2022-08-16&co_profile=core3_adaptive`, {
      headers: authHeaders,
    }),
  ]);
  assert.equal(resPitInv.status, 200);
  assert.equal(resPitC3_2020.status, 200);
  assert.equal(resPitDisc.status, 200);
  const pit2020 = await resPitInv.json();
  const pit2020C3 = await resPitC3_2020.json();
  const pit2022 = await resPitDisc.json();
  assert.equal(pit2020.pit_mode, true);
  assert.equal(pit2020.pit_date, '2020-01-28');
  assert.equal(pit2020.is_historical_pit, true);
  assert.equal(pit2020.prev_date, '2020-01-27');
  assert.equal(pit2020.next_date, '2020-01-29');
  assert.equal(pit2020.daily_series, undefined);
  assert.equal(pit2020.live_market_snapshot.qqq_close, 221.45);
  assert.equal(pit2020.m7_live_dashboard.crisis_prob, 40);
  assert.equal(pit2020.m7_live_dashboard.p2_score, 40);
  const p2Mods = pit2020.m7_live_dashboard.pillars.find(p => p.id === 'P2').modules;
  assert.equal(p2Mods.find(m => m.id === 'M2').triggered, true);
  assert.equal(p2Mods.find(m => m.id === 'M5').triggered, true);
  assert.equal(pit2020.ad_line_signal.last_top_divergence_date, '');

  // On 2020-01-28 exogenous shock, Core-3 omits M2 & M5 -> crisis_prob = 0, disabled_in_core3 = true
  assert.equal(pit2020C3.profile, 'core3_adaptive');
  assert.equal(pit2020C3.selected_strategy_id, 'Core3_Adaptive');
  assert.equal(pit2020C3.m7_live_dashboard.crisis_prob, 0);
  assert.equal(pit2020C3.m7_live_dashboard.p2_score, 0);
  const p2ModsC3 = pit2020C3.m7_live_dashboard.pillars.find(p => p.id === 'P2').modules;
  assert.equal(p2ModsC3.find(m => m.id === 'M2').disabled_in_core3, true);
  assert.equal(p2ModsC3.find(m => m.id === 'M5').disabled_in_core3, true);

  // On 2022-08-16 bear-market bounce, Core-3 captures M4 (+35%) identically
  assert.equal(pit2022.pit_date, '2022-08-16');
  assert.equal(pit2022.live_market_snapshot.qqq_close, 332.28);
  assert.equal(pit2022.m7_live_dashboard.crisis_prob, 35);
  assert.equal(pit2022.m7_live_dashboard.p3_score, 35);
  assert.equal(pit2022.m7_live_dashboard.sizing_calculator.dte, 90, 'Adaptive M4 CTA signal uses 90->30 tenor');
  assert.equal(pit2022.m7_live_dashboard.sizing_calculator.roll_dte, 30);
  const p3Mods = pit2022.m7_live_dashboard.pillars.find(p => p.id === 'P3').modules;
  assert.equal(p3Mods.find(m => m.id === 'M4').triggered, true);
  assert.equal(p3Mods.find(m => m.id === 'M3').disabled_in_core3, true);

  const pit2025 = loadCrisisObservatoryPitSnapshot({ date: '2025-04-04' });
  assert.equal(pit2025.pit_date, '2025-04-04');
  assert.equal(pit2025.live_market_snapshot.qqq_close, 422.67);
  assert.equal(pit2025.m7_live_dashboard.active_slots, 1);
  assert.equal(pit2025.m7_live_dashboard.tp_monitor.open_slots[0].kp, 440);
  assert.equal(pit2025.m7_live_dashboard.tp_monitor.open_slots[0].pending_tp, true);
});

test('parseFredCsvText skips US holiday empty/dot cells without zero corruption and Dual-Track scorer + live six_crisis_lights work end-to-end', () => {
  const fredCsvSample = [
    'observation_date,BAA10Y',
    '2026-08-25,1.42',
    '2026-10-12,', // Columbus Day empty cell (previously Number("") === 0 bug!)
    '2026-11-11,', // Veterans Day empty cell
    '2026-11-20,1.62',
    '2026-11-23,1.59',
    '2026-11-26,.', // FRED dot missing value
    '',
  ].join('\n');
  const parsedBaa = parseFredCsvText(fredCsvSample);
  assert.equal('2026-10-12' in parsedBaa, false, 'Empty holiday cell must NEVER become 0.0');
  assert.equal('2026-11-11' in parsedBaa, false, 'Empty holiday cell must NEVER become 0.0');
  assert.equal('2026-11-26' in parsedBaa, false, 'Dot cell must NEVER become NaN/0.0');
  assert.equal(parsedBaa['2026-08-25'], 1.42);
  assert.equal(parsedBaa['2026-11-23'], 1.59);

  // Calm vs Crisis unit check on computeLiveStressIndexJS
  const calmStress = computeLiveStressIndexJS({
    hmm_p: 0.02,
    vxn: 14.5,
    vix_ratio: 0.84,
    dd_from_ath: -0.005,
    close: 650,
    sma200: 590,
    ewmac: 0.9,
    hyg_lqd: 0.74,
    hyg_sma50: 0.73,
    baa_rise63: -0.04,
    dgs2_jump63: -0.1,
    nfci_jump20: -0.03,
    def_ret20: -0.02,
    rsp_spy: 0.31,
    rsp_sma50: 0.3,
    iwm_qqq: 0.42,
    iwm_sma50: 0.41,
    ad_below50: false,
    vvix: 85,
    vvix_p75: 105,
    skew10: 2.1,
    skew_p75: 3.4,
    vr_jump5: -0.01,
  });
  assert.ok(calmStress.live_stress_index < 25);
  assert.equal(calmStress.live_stress_level, 'calm');

  // Historical PIT Dual-Track parity: calm 2017 bull vs 2020 COVID crash
  const pitCalm = loadCrisisObservatoryPitSnapshot({ date: '2017-07-14' });
  assert.ok(pitCalm.m7_live_dashboard.live_stress_index < 25);
  assert.equal(pitCalm.m7_live_dashboard.live_stress_level, 'calm');
  assert.equal(pitCalm.m7_live_dashboard.data_freshness.is_pit_replay, true);

  const pitCrash = loadCrisisObservatoryPitSnapshot({ date: '2020-03-20' });
  assert.ok(pitCrash.m7_live_dashboard.live_stress_index >= 75);
  assert.equal(pitCrash.m7_live_dashboard.live_stress_level, 'crisis');
  assert.equal(pitCrash.m7_live_dashboard.crisis_prob, 0, 'Low-vol entry gate stays 0% during peak IV');
  assert.equal(pitCrash.m7_live_dashboard.data_freshness.is_pit_replay, true);

  // Post-artifact live feed (2026-11-23 & 2026-11-24) with holiday-clean FRED & sector ETFs
  const mkMap = entries =>
    new Map(entries.map(([d, c]) => [d, { open: c, close: c }]));
  const syntheticLiveFeed = {
    yahoo: {
      QQQ: mkMap([
        ['2026-11-20', 608.45],
        ['2026-11-23', 626.7],
        ['2026-11-24', 638.1],
      ]),
      VIX: mkMap([
        ['2026-11-20', 35.89],
        ['2026-11-23', 29.8],
        ['2026-11-24', 28.4],
      ]),
      VIX3M: mkMap([
        ['2026-11-20', 30.94],
        ['2026-11-23', 28.1],
        ['2026-11-24', 27.44],
      ]),
      VXN: mkMap([
        ['2026-11-20', 45.25],
        ['2026-11-23', 38.2],
        ['2026-11-24', 36.4],
      ]),
      SKEW: mkMap([
        ['2026-11-20', 132.0],
        ['2026-11-23', 133.0],
        ['2026-11-24', 134.0],
      ]),
      VVIX: mkMap([
        ['2026-11-20', 112.0],
        ['2026-11-23', 106.0],
        ['2026-11-24', 102.0],
      ]),
      HYG: mkMap([
        ['2026-11-20', 77.2],
        ['2026-11-23', 75.2],
        ['2026-11-24', 75.0],
      ]),
      LQD: mkMap([
        ['2026-11-20', 108.5],
        ['2026-11-23', 109.4],
        ['2026-11-24', 109.5],
      ]),
      RSP: mkMap([
        ['2026-11-20', 175.0],
        ['2026-11-23', 177.0],
        ['2026-11-24', 178.5],
      ]),
      SPY: mkMap([
        ['2026-11-20', 605.0],
        ['2026-11-23', 618.0],
        ['2026-11-24', 626.0],
      ]),
      IWM: mkMap([
        ['2026-11-20', 222.0],
        ['2026-11-23', 226.0],
        ['2026-11-24', 228.0],
      ]),
      XLP: mkMap([
        ['2026-11-20', 82.0],
        ['2026-11-23', 82.4],
        ['2026-11-24', 82.6],
      ]),
      XLU: mkMap([
        ['2026-11-20', 80.0],
        ['2026-11-23', 80.5],
        ['2026-11-24', 80.8],
      ]),
      XLV: mkMap([
        ['2026-11-20', 146.0],
        ['2026-11-23', 146.5],
        ['2026-11-24', 147.0],
      ]),
      XLK: mkMap([
        ['2026-11-20', 225.0],
        ['2026-11-23', 231.0],
        ['2026-11-24', 235.0],
      ]),
      HG_F: mkMap([
        ['2026-11-20', 4.12],
        ['2026-11-23', 4.08],
        ['2026-11-24', 4.05],
      ]),
      XLY: mkMap([
        ['2026-11-20', 202.0],
        ['2026-11-23', 205.0],
        ['2026-11-24', 207.0],
      ]),
      XLI: mkMap([
        ['2026-11-20', 136.0],
        ['2026-11-23', 137.0],
        ['2026-11-24', 138.0],
      ]),
      XLB: mkMap([
        ['2026-11-20', 89.0],
        ['2026-11-23', 89.5],
        ['2026-11-24', 90.0],
      ]),
      XLF: mkMap([
        ['2026-11-20', 49.0],
        ['2026-11-23', 49.4],
        ['2026-11-24', 49.8],
      ]),
    },
    fred: {
      BAA10Y: parsedBaa,
      DGS2: parseFredCsvText('DATE,DGS2\n2026-08-25,3.38\n2026-10-12,\n2026-11-11,\n2026-11-20,4.61\n2026-11-23,4.63\n'),
      NFCI: parseFredCsvText('DATE,NFCI\n2026-11-13,-0.48\n'),
      DFF: parseFredCsvText('DATE,DFF\n2026-11-20,4.58\n2026-11-23,4.58\n'),
      T10Y2Y: parseFredCsvText('DATE,T10Y2Y\n2026-11-20,0.27\n2026-11-23,0.29\n'),
    },
  };

  const live24 = loadCrisisObservatoryDashboard({
    asOf: '2026-11-24',
    liveM7Feed: syntheticLiveFeed,
  });
  assert.equal(live24.as_of_date, '2026-11-24');
  assert.equal(live24.liveExtended, true);
  const d24 = live24.m7_live_dashboard;
  assert.ok(d24.live_stress_index >= 75, `Expected Active Crisis >=75 on 2026-11-24, got ${d24.live_stress_index}`);
  assert.equal(d24.live_stress_level, 'crisis');
  assert.equal(d24.crisis_prob, 0);
  assert.equal(d24.data_freshness.yahoo_eod_date, '2026-11-24');
  assert.equal(d24.data_freshness.fred_baa_date, '2026-11-23');
  assert.equal(d24.data_freshness.ad_line_date, '2026-11-20');
  assert.equal(d24.data_freshness.is_pit_replay, false);

  const mods24 = Object.fromEntries(d24.pillars.flatMap(p => p.modules).map(m => [m.id, m]));
  assert.equal(mods24.M3.status_code, 'SENSOR_RED_VOL_BLOCKED');
  assert.equal(mods24.M4.status_code, 'WARMING_UP');
  const baaMetric = mods24.M3.metrics.find(m => /baa/i.test(m.label_en));
  assert.ok(baaMetric && !baaMetric.value.includes('+159bp'), `Baa 63D rise must not be holiday-corrupted: ${baaMetric?.value}`);

  // Verify live six_crisis_lights dynamically recomputes post-artifact sig2_credit to 1.59% (not frozen 1.62%)
  const sig2 = live24.six_crisis_lights.find(l => l.key === 'sig2_credit');
  assert.ok(sig2.reading_value.startsWith('1.59%'), `Expected live sig2_credit 1.59%, got ${sig2.reading_value}`);
});
