import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import {
  CRISIS_OBSERVATORY_VERSION,
  CRISIS_OBSERVATORY_STRATEGY_CODE,
  CRISIS_OBSERVATORY_WINDOWS,
  parseFredCsvText,
  computeLiveStressIndexJS,
  loadCrisisObservatoryDashboard,
  loadCrisisObservatoryPitSnapshot,
  extendV2LiveFromFeed,
} from './crisisObservatory.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

test('loads clean v3.0 Double-Champion (Plan D) payload with real MIT OPRA 11Y & 5Y benchmarks and zero legacy clutter', () => {
  const doc = loadCrisisObservatoryDashboard();
  assert.equal(doc.version, CRISIS_OBSERVATORY_VERSION);
  assert.equal(doc.strategy_code, CRISIS_OBSERVATORY_STRATEGY_CODE);
  assert.equal(doc.selected_window, '11y_opra');
  assert.deepEqual(
    doc.windows_meta.map(w => w.id),
    [...CRISIS_OBSERVATORY_WINDOWS],
  );
  assert.equal(doc.pit_daily_index, undefined, 'Raw pit_daily_index must be stripped from HTTP payload');
  assert.equal(doc.live_tail_state, undefined, 'Raw live_tail_state must be stripped from HTTP payload');

  // Strict zero Wheel / Collar / Covered Call / Short Put / internal DB / char 126 hygiene
  const serialized = JSON.stringify(doc);
  assert.equal(serialized.includes(String.fromCharCode(126)), false, 'ASCII 126 must never appear');
  for (const banned of [
    'Wheel',
    'wheel',
    'Covered Call',
    'Short Put',
    '卖Call',
    '领口',
    'Core3_Adaptive',
    'U1_PureOptions',
    'FactOS',
    'FACT OS',
    'Sharadar',
    'DuckDB',
    'SQLite',
  ]) {
    assert.equal(serialized.includes(banned), false, `Forbidden legacy term found: ${banned}`);
  }

  // Verified 11Y MIT OPRA (<=2025-12-15) + OPRA-Calibrated 2026 Extension (through 2026-11-25)
  const k11 = doc.backtest.window_kpis['11y_opra'].kpi_primary;
  const k11Opra = doc.backtest.window_kpis['11y_opra'].kpi_opra_verified_primary;
  const k11Stress = doc.backtest.window_kpis['11y_opra'].kpi_stress;
  const k11Qqq = doc.backtest.window_kpis['11y_opra'].kpi_qqq;
  assert.equal(doc.backtest.opra_provenance.quotes_count, 6382288);
  assert.equal(doc.backtest.opra_provenance.bsm_calibration.fit_quotes_count, 1500755);
  assert.equal(k11Opra.end_nav, 926278.08);
  assert.equal(k11Opra.cagr_pct, 22.54);
  assert.equal(k11Opra.max_dd_pct, -24.31);
  assert.equal(k11Opra.calmar, 0.927);
  assert.equal(k11Opra.put_gross_turnover_pct_nav_yr, 6.13);
  assert.equal(k11Opra.put_roll_salvage_pct, 67.8);
  assert.equal(k11Opra.put_true_net_bleed_pct_nav_yr, 2.03);
  assert.equal(k11.end_nav, 987611.4);
  assert.equal(k11.cagr_pct, 21.23);
  assert.equal(k11.max_dd_pct, -24.31);
  assert.equal(k11.calmar, 0.873);
  assert.equal(k11.peak_gross_leverage, 1.2582);
  assert.equal(k11.put_trades_m4, 3);
  assert.equal(k11.cta_rotation_count, 10);
  assert.ok(k11Stress.end_nav > k11Qqq.end_nav, 'Even stress Ask/Bid + IBKR 150bp must beat QQQ');
  assert.equal(doc.backtest.active_window.crisis_comparison.length, 9);

  // Verified Zero-Splice Live window (2020.12-2026.11) + immutable real-OPRA sub-window (<=2025-12-15)
  const doc5 = loadCrisisObservatoryDashboard({ window: '5y_live' });
  assert.equal(doc5.selected_window, '5y_live');
  const k5 = doc5.backtest.active_window.kpi_primary;
  const k5Opra = doc5.backtest.active_window.kpi_opra_verified_primary;
  assert.equal(doc5.backtest.active_window.zero_splice, true);
  assert.equal(k5Opra.end_nav, 295807.52);
  assert.equal(k5Opra.cagr_pct, 24.05);
  assert.equal(k5Opra.max_dd_pct, -23.67);
  assert.equal(k5Opra.calmar, 1.016);
  assert.equal(k5.end_nav, 315394.35);
  assert.equal(k5.cagr_pct, 21.19);
  assert.equal(k5.max_dd_pct, -23.67);
  assert.equal(k5.calmar, 0.895);
  assert.equal(k5.peak_gross_leverage, 1.2493);
  assert.equal(k5.put_trades_m4, 3);
});

test('computes real-time Dual-Track Stress vs M7G Slots, Natural-Drift Box Guard, Slow-Bear +8% Latch, and CONT_2M timer accurately on live 2026-11-25 and historical crises', () => {
  const live = loadCrisisObservatoryDashboard({ asOf: '2026-11-25' });
  const c = live.live_cockpit;
  assert.equal(c.date, '2026-11-25');
  assert.equal(c.market.qqq_close, 633.93);
  assert.equal(c.market.qqq_ath_dd_pct, -16.55);
  assert.ok(c.three_pillars.live_stress_index >= 75, 'Live selloff must reflect Active Crisis stress, never 0');
  assert.ok(c.three_pillars.raw_crisis_prob >= 40, 'Raw structural alerts must light up independently of vol gate');
  assert.equal(c.three_pillars.raw_target_slots, 2);
  assert.equal(c.three_pillars.actionable_m7g_slots, 0, 'Vol-gated entry slots must block panic IV chasing');
  assert.equal(c.three_pillars.vol_gate_status, 'HIGH_VOL_NO_CHASE');
  assert.equal(c.dual_cta_radar.leverage_guard.daily_forced_delev_cap, false);
  assert.ok(c.dual_cta_radar.leverage_guard.live_gross_leverage > 1.2 && c.dual_cta_radar.leverage_guard.live_gross_leverage < 1.27);
  assert.ok(c.dual_cta_radar.leverage_guard.ibkr_pm_crash_cushion_pct < -70);
  assert.equal(c.dual_cta_radar.slow_bear_latch.armed, false);
  assert.equal(c.dual_cta_radar.cont_2m_timer.active, true);
  assert.equal(c.dual_cta_radar.cont_2m_timer.continuous_cal_days, 9);
  assert.equal(c.dual_cta_radar.cont_2m_timer.timer_start_date, '2026-11-16');
  assert.equal(c.dual_cta_radar.cont_2m_timer.projected_confirm_date, '2027-01-15');
  assert.equal(c.command_center.sub_engines.length, 5);
  // UNIFORM -15% OTM for BOTH Route 1 125D AND M4 90D!
  assert.equal(c.command_center.target_strikes.route1_125d_15otm.suggested_strike, Math.round(633.93 * 0.85));
  assert.equal(c.command_center.target_strikes.route2_m4_90d_15otm.suggested_strike, Math.round(633.93 * 0.85));
  assert.equal(c.command_center.target_strikes.route2_m4_90d_15otm.otm_pct, -15);
  assert.equal(c.tp_and_microstructure.option_pricing.put_90d_15otm.strike, Math.round(633.93 * 0.85));

  // Historical PIT 2022-03-18: Slow-Bear +8% Latch ARMED & M4 dead-cat bounce FIRED at Uniform -15% OTM!
  const pitM4 = loadCrisisObservatoryPitSnapshot({ date: '2022-03-18' });
  assert.equal(pitM4.date, '2022-03-18');
  assert.equal(pitM4.live_cockpit.is_pit_replay, true);
  assert.equal(pitM4.live_cockpit.dual_cta_radar.slow_bear_latch.armed, true);
  assert.equal(pitM4.live_cockpit.three_pillars.m4_entry_triggered, true);
  assert.equal(pitM4.live_cockpit.three_pillars.actionable_m7g_slots, 1);
  assert.equal(pitM4.live_cockpit.command_center.action_code, 'OPEN_SLEEVE_B_M4');

  // Historical PIT 2022-06-06: CONT_2M >= 60d confirmed & DBMF/KMLM positive since ATH!
  const pitCta = loadCrisisObservatoryPitSnapshot({ date: '2022-06-06' });
  assert.equal(pitCta.live_cockpit.dual_cta_radar.cont_2m_timer.confirmed, true);
  assert.ok(pitCta.live_cockpit.dual_cta_radar.cont_2m_timer.continuous_cal_days >= 60);
  assert.equal(pitCta.live_cockpit.dual_cta_radar.cont_2m_timer.dbmf_positive_since_ath, true);
  assert.equal(pitCta.live_cockpit.dual_cta_radar.cont_2m_timer.kmlm_positive_since_ath, true);

  // Historical PIT 2025-04-07: Real OPRA 3-Put Right-Tail TP Harvest (2 M7G + 1 Base after roll slot-cap bug fix)
  const pitOpraTp = loadCrisisObservatoryPitSnapshot({ date: '2025-04-07', window: '5y_live' });
  const op = pitOpraTp.live_cockpit.tp_and_microstructure.option_pricing;
  assert.equal(op.quote_source, 'real_opra');
  assert.ok(op.skew_ratio.opra_iv_20_10 > 1.0);
  assert.ok(op.put_125d_15otm.put_to_lot_pct > 0.5 && op.put_125d_15otm.put_to_lot_pct < 10.0);
  assert.ok(op.put_90d_15otm.put_to_lot_pct > 0.5 && op.put_90d_15otm.put_to_lot_pct < 10.0);
  assert.equal(pitOpraTp.pit_history.window_id, '5y_live');
  const tpEvents0407 = pitOpraTp.pit_history.events_on_date.filter(e => e.action === 'PUT_TP');
  assert.equal(tpEvents0407.length, 3, 'Exactly 2 legitimate M7G slots + 1 Base slot must harvest on 2025-04-07');
  assert.ok(tpEvents0407.some(e => e.roi_mult >= 6.3));
  assert.ok(pitOpraTp.pit_history.tp_dates.some(t => t.date === '2025-04-07'));

  // Historical PIT 2025-02-20: Active open puts held prior to 2025-04-07 TP
  const pitActive = loadCrisisObservatoryPitSnapshot({ date: '2025-02-20', window: '11y_opra' });
  assert.ok(pitActive.pit_history.active_puts_on_date.length >= 2);
  assert.ok(pitActive.pit_history.active_puts_on_date.some(p => p.eventual_exit_date === '2025-04-07'));

  // Post-OPRA 2026 OPRA-Residual-Calibrated BSM Extension PIT replay (2026-11-06 Base Put TP!)
  const pit2026Tp = loadCrisisObservatoryPitSnapshot({ date: '2026-11-06', window: '11y_opra' });
  assert.equal(pit2026Tp.pit_history.in_opra_window, true);
  assert.equal(pit2026Tp.pit_history.is_sim_extension, true);
  assert.ok(pit2026Tp.pit_history.nav_snapshot && pit2026Tp.pit_history.nav_snapshot.nav_v2 > 950000);
  assert.ok(pit2026Tp.pit_history.events_on_date.some(e => e.action === 'PUT_TP' && e.quote_source === 'BSM_SIM_2026'));
});

test('parseFredCsvText handles holiday dots and computeLiveStressIndexJS is bounded 0-100', () => {
  const parsed = parseFredCsvText('DATE,BAA10Y\n2026-11-24,1.65\n2026-11-25,.\n2026-11-26,1.72\n');
  assert.deepEqual(parsed, { '2026-11-24': 1.65, '2026-11-26': 1.72 });
  const calm = computeLiveStressIndexJS({ vxn: 14, vix_ratio: 0.85, dd_from_ath: -0.01 });
  assert.ok(calm.live_stress_index >= 0 && calm.live_stress_index < 25);
  assert.equal(calm.live_stress_level, 'calm');
});

test('live EOD stepper extends seamlessly beyond artifact cutoff date with synthetic feed', () => {
  const synthYahoo = {};
  const mapOf = (d, close) => new Map([[d, { open: close, close, adj: close }]]);
  const nextDay = '2026-11-27';
  synthYahoo.QQQ = mapOf(nextDay, 642.5);
  synthYahoo.DBMF = mapOf(nextDay, 31.7);
  synthYahoo.KMLM = mapOf(nextDay, 29.0);
  synthYahoo.VIX = mapOf(nextDay, 24.5);
  synthYahoo.VIX3M = mapOf(nextDay, 25.1);
  synthYahoo.VXN = mapOf(nextDay, 32.0);
  const extended = loadCrisisObservatoryDashboard({
    liveFeed: {
      fetchedAt: '2026-11-27T21:30:00Z',
      stamp: nextDay,
      yahoo: synthYahoo,
      fred: {},
      effr: { '2026-11-25': 0.0388 },
    },
  });
  assert.equal(extended.as_of_date, nextDay);
  assert.equal(extended.data_freshness.live_extended_days, 1);
  assert.equal(extended.live_cockpit.market.qqq_close, 642.5);
  assert.equal(extended.live_cockpit.tp_and_microstructure.option_pricing.put_90d_15otm.strike, Math.round(642.5 * 0.85));
  assert.equal(typeof extendV2LiveFromFeed, 'function');
});

test('serves both /api/investment/crisis-observatory and /api/discover/crisis-observatory with auth & legacy param safety', async t => {
  const app = express();
  app.use((req, _res, next) => {
    if (req.headers.authorization === 'Bearer test-token') {
      req.user = { id: 'user-v2' };
    }
    next();
  });
  const stubService = {
    date: v => (typeof v === 'string' && v.trim() ? v.trim() : null),
    source: { canonicalMarket: false },
  };
  registerInvestmentRoutes(app, stubService);
  const server = app.listen(0);
  t.after(() => server.close());
  const port = server.address().port;

  // Unauthenticated must return 401
  const unauth = await fetch(`http://127.0.0.1:${port}/api/discover/crisis-observatory`);
  assert.equal(unauth.status, 401);

  // Authenticated with legacy bookmarked query params still returns clean v2.0 single-strategy payload
  const res = await fetch(
    `http://127.0.0.1:${port}/api/discover/crisis-observatory?window=5y_live&co_profile=core3_adaptive&co_wcMode=wc_30d_c5s5&asOf=2026-11-25`,
    { headers: { Authorization: 'Bearer test-token' } },
  );
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.version, CRISIS_OBSERVATORY_VERSION);
  assert.equal(body.selected_window, '5y_live');
  assert.equal(body.as_of_date, '2026-11-25');

  // PIT route
  const pitRes = await fetch(
    `http://127.0.0.1:${port}/api/discover/crisis-observatory/pit?date=2022-03-18`,
    { headers: { Authorization: 'Bearer test-token' } },
  );
  assert.equal(pitRes.status, 200);
  const pitBody = await pitRes.json();
  assert.equal(pitBody.date, '2022-03-18');
  assert.equal(pitBody.live_cockpit.dual_cta_radar.slow_bear_latch.armed, true);

  // Invalid date must return 400
  const badPit = await fetch(
    `http://127.0.0.1:${port}/api/investment/crisis-observatory/pit?date=not-a-date`,
    { headers: { Authorization: 'Bearer test-token' } },
  );
  assert.equal(badPit.status, 400);
});
