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

test('loads clean v2.0 Single Master Strategy payload with real MIT OPRA 11Y & 5Y benchmarks and zero legacy clutter', () => {
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

  // Verified 11Y MIT OPRA benchmarks
  const k11 = doc.backtest.window_kpis['11y_opra'].kpi_primary;
  const k11Stress = doc.backtest.window_kpis['11y_opra'].kpi_stress;
  const k11Qqq = doc.backtest.window_kpis['11y_opra'].kpi_qqq;
  assert.equal(doc.backtest.opra_provenance.quotes_count, 6382288);
  assert.equal(doc.backtest.opra_provenance.execution_fallbacks, 0);
  assert.equal(k11.end_nav, 707763.27);
  assert.equal(k11.cagr_pct, 19.57);
  assert.equal(k11.max_dd_pct, -28.47);
  assert.equal(k11.calmar, 0.687);
  assert.equal(k11.peak_gross_leverage, 1.2);
  assert.equal(k11.put_trades_m4, 3);
  assert.equal(k11.cta_rotation_slices, 10);
  assert.ok(k11Stress.end_nav > k11Qqq.end_nav, 'Even stress Ask/Bid + IBKR 150bp must beat QQQ');
  assert.equal(doc.backtest.active_window.crisis_comparison.length, 8);

  // Verified 5Y Zero-Splice Live window
  const doc5 = loadCrisisObservatoryDashboard({ window: '5y_live' });
  assert.equal(doc5.selected_window, '5y_live');
  const k5 = doc5.backtest.active_window.kpi_primary;
  assert.equal(doc5.backtest.active_window.zero_splice, true);
  assert.equal(k5.end_nav, 235714.95);
  assert.equal(k5.cagr_pct, 18.57);
  assert.equal(k5.max_dd_pct, -28.47);
  assert.equal(k5.calmar, 0.652);
  assert.equal(k5.peak_gross_leverage, 1.2);
  assert.equal(k5.put_trades_m4, 3);
});

test('computes real-time Dual-Track Stress vs Vol-Gate, Slow-Bear +8% Latch, and CONT_2M timer accurately on live 2026-11-25 and historical 2022 slow bear', () => {
  const live = loadCrisisObservatoryDashboard({ asOf: '2026-11-25' });
  const c = live.live_cockpit;
  assert.equal(c.date, '2026-11-25');
  assert.equal(c.market.qqq_close, 633.93);
  assert.equal(c.market.qqq_ath_dd_pct, -16.55);
  assert.ok(c.three_pillars.live_stress_index >= 75, 'Live selloff must reflect Active Crisis stress, never 0');
  assert.ok(c.three_pillars.raw_crisis_prob >= 40, 'Raw structural alerts must light up independently of vol gate');
  assert.equal(c.three_pillars.entry_crisis_prob, 0, 'Vol-gated entry score must block panic IV chasing');
  assert.equal(c.three_pillars.vol_gate_status, 'POST_TP_LOCKOUT');
  assert.equal(c.dual_cta_radar.slow_bear_latch.armed, false);
  assert.equal(c.dual_cta_radar.cont_2m_timer.active, true);
  assert.equal(c.dual_cta_radar.cont_2m_timer.continuous_cal_days, 9);
  assert.equal(c.dual_cta_radar.cont_2m_timer.timer_start_date, '2026-11-16');
  assert.equal(c.dual_cta_radar.cont_2m_timer.projected_confirm_date, '2027-01-15');
  assert.equal(c.command_center.sub_engines.length, 5);
  assert.equal(c.command_center.target_strikes.route1_125d_15otm.suggested_strike, Math.round(633.93 * 0.85));
  assert.equal(c.command_center.target_strikes.route2_m4_90d_10otm.suggested_strike, Math.round(633.93 * 0.9));

  // Historical PIT 2022-03-18: Slow-Bear +8% Latch ARMED & M4 dead-cat bounce FIRED!
  const pitM4 = loadCrisisObservatoryPitSnapshot({ date: '2022-03-18' });
  assert.equal(pitM4.date, '2022-03-18');
  assert.equal(pitM4.live_cockpit.is_pit_replay, true);
  assert.equal(pitM4.live_cockpit.dual_cta_radar.slow_bear_latch.armed, true);
  assert.equal(pitM4.live_cockpit.three_pillars.m4_entry_triggered, true);
  assert.equal(pitM4.live_cockpit.command_center.action_code, 'OPEN_SLEEVE_B_M4');

  // Historical PIT 2022-06-06: CONT_2M >= 60d confirmed & DBMF/KMLM positive since ATH!
  const pitCta = loadCrisisObservatoryPitSnapshot({ date: '2022-06-06' });
  assert.equal(pitCta.live_cockpit.dual_cta_radar.cont_2m_timer.confirmed, true);
  assert.ok(pitCta.live_cockpit.dual_cta_radar.cont_2m_timer.continuous_cal_days >= 60);
  assert.equal(pitCta.live_cockpit.dual_cta_radar.cont_2m_timer.dbmf_positive_since_ath, true);
  assert.equal(pitCta.live_cockpit.dual_cta_radar.cont_2m_timer.kmlm_positive_since_ath, true);

  // Historical PIT 2026-11-20: Tier 2 Full TP triggered (VR 1.16 >= 1.10 & DD -19.9% <= -10%)
  const pitTp = loadCrisisObservatoryPitSnapshot({ date: '2026-11-20' });
  assert.equal(pitTp.live_cockpit.tp_and_microstructure.tier2_full.triggered_today, true);
  assert.equal(pitTp.live_cockpit.command_center.action_code, 'TRIGGER_FULL_TP');

  // Historical PIT 2025-04-07: Real OPRA Put TP events, Skew Ratio, and 1-Put / 1-Lot QQQ ratio
  const pitOpraTp = loadCrisisObservatoryPitSnapshot({ date: '2025-04-07', window: '5y_live' });
  const op = pitOpraTp.live_cockpit.tp_and_microstructure.option_pricing;
  assert.equal(op.quote_source, 'real_opra');
  assert.ok(op.skew_ratio.opra_iv_20_10 > 1.0);
  assert.ok(op.put_125d_15otm.put_to_lot_pct > 0.5 && op.put_125d_15otm.put_to_lot_pct < 10.0);
  assert.ok(op.put_90d_10otm.put_to_lot_pct > 0.5 && op.put_90d_10otm.put_to_lot_pct < 10.0);
  assert.equal(pitOpraTp.pit_history.window_id, '5y_live');
  assert.ok(pitOpraTp.pit_history.events_on_date.some(e => e.action === 'PUT_TP' && e.roi_mult >= 4.0));
  assert.ok(pitOpraTp.pit_history.tp_dates.some(t => t.date === '2025-04-07'));

  // Historical PIT 2025-02-20: Active open puts held prior to 2025-04-07 TP
  const pitActive = loadCrisisObservatoryPitSnapshot({ date: '2025-02-20', window: '11y_opra' });
  assert.ok(pitActive.pit_history.active_puts_on_date.length >= 2);
  assert.ok(pitActive.pit_history.active_puts_on_date.some(p => p.eventual_exit_date === '2025-04-07'));
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
  assert.equal(extended.live_cockpit.three_pillars.post_tp_lockout.non_inv_streak, 1);
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
