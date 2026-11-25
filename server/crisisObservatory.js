import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import {
  CRISIS_OBSERVATORY_PUT_OTMS,
  CRISIS_OBSERVATORY_M7_TP_MODES,
  CRISIS_OBSERVATORY_ROLL_MODES,
  evalSkewIv,
  bsmPrice,
  simulateM7StrategyJS,
  buildM7LiveDashboardJS,
  extendM7LiveFromFeed,
  getLiveM7MarketFeed,
  normalizeLegacyExtraBarsToFeed,
} from './crisisObservatoryM7.js';

export {
  CRISIS_OBSERVATORY_PUT_OTMS,
  CRISIS_OBSERVATORY_M7_TP_MODES,
  CRISIS_OBSERVATORY_ROLL_MODES,
};

export const CRISIS_OBSERVATORY_VERSION = 'crisis-observatory-v3-m7';
export const CRISIS_OBSERVATORY_STRATEGIES = Object.freeze([
  'M7G_Graded',
  'M7_Ensemble',
  'U1_PureOptions',
  'B1c_PureAD',
  'D2_SixLights',
  'H2_G4_PriceGate',
  'NoPut_CallOnly',
  'BH_Pure_QQQ',
]);
export const CRISIS_OBSERVATORY_TP_MODES = Object.freeze([
  'layered_itm',
  'standard_dual',
  'both_4x',
]);
export const CRISIS_OBSERVATORY_CC_MODES = Object.freeze([
  'cc_off',
  'cc_d12_d35',
  'cc_d12_r45',
  'cc_d12_cr55',
]);
export const CRISIS_OBSERVATORY_SP_MODES = Object.freeze([
  'sp_off',
  'sp_14d_cap10',
  'sp_10d_vixf',
  'sp_14d_unf',
]);
export const CRISIS_OBSERVATORY_WC_MODES = Object.freeze([
  'wc_reclaim_30d_d35',
  'wc_30d_c5s5',
  'wc_14d_c0s2',
]);

const PUT_OTM_ALIASES = Object.freeze({
  '15': 'otm15',
  '-15': 'otm15',
  '-15%': 'otm15',
  '0.85': 'otm15',
  '20': 'otm20',
  '-20': 'otm20',
  '-20%': 'otm20',
  '0.80': 'otm20',
});

const M7_TP_ALIASES = Object.freeze({
  std: 'standard',
  STANDARD: 'standard',
  itm: 'itm_tp',
  ITM_TP: 'itm_tp',
});

const ROLL_MODE_ALIASES = Object.freeze({
  '90d': '90d_hold',
  hold: '90d_hold',
  '120d': '120d_roll50',
  roll50: '120d_roll50',
  '50d': '120d_roll50',
  '120d_50d': '120d_roll50',
});

const LEGACY_SP_MODE_ALIASES = Object.freeze({
  off: 'sp_off',
  cap10: 'sp_14d_cap10',
  vixf: 'sp_10d_vixf',
  unf: 'sp_14d_unf',
});

const LEGACY_WC_MODE_ALIASES = Object.freeze({
  reclaim: 'wc_reclaim_30d_d35',
  d35: 'wc_reclaim_30d_d35',
  reclaim_30d_d35: 'wc_reclaim_30d_d35',
  rec: 'wc_reclaim_30d_d35',
  default: 'wc_reclaim_30d_d35',
  '30d': 'wc_30d_c5s5',
  c5s5: 'wc_30d_c5s5',
  '14d': 'wc_14d_c0s2',
  c0s2: 'wc_14d_c0s2',
  legacy: 'wc_14d_c0s2',
});

const LEGACY_CC_MODE_ALIASES = Object.freeze({
  cc_high_vol: 'cc_d12_d35',
  cc_hv_8: 'cc_d12_d35',
  cc_hv_9: 'cc_d12_d35',
  cc_d12_3x: 'cc_d12_d35',
  cc_always: 'cc_d12_r45',
  cc_always_8: 'cc_d12_r45',
  cc_otm8_3x: 'cc_d12_r45',
});

const STRATEGY_NAV_KEYS = Object.freeze({
  M7G_Graded: 'nav_m7g',
  M7_Ensemble: 'nav_m7',
  U1_PureOptions: 'nav_u1',
  B1c_PureAD: 'nav_b1c',
  D2_SixLights: 'nav_d2',
  H2_G4_PriceGate: 'nav_h2',
  NoPut_CallOnly: 'nav_cc',
  BH_Pure_QQQ: 'nav_bh',
});

const LEGACY_STRATEGY_ALIASES = Object.freeze({
  U4_DualEngine: 'U1_PureOptions',
  M7G: 'M7G_Graded',
  M7: 'M7_Ensemble',
});

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultFile = path.resolve(projectRoot, 'server/config/crisis-observatory-dashboard.json');

let cachedArtifact = null;
const projectedModeCache = new Map();
const m7SimComboCache = new Map();

function fail(code, status = 503) {
  throw Object.assign(new Error(code), { status });
}

const isIsoDate = value =>
  /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;

const r2 = v => (Number.isFinite(v) ? Math.round(v * 100) / 100 : null);
const r3 = v => (Number.isFinite(v) ? Math.round(v * 1000) / 1000 : null);

function readArtifact(file = defaultFile) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch {
    fail('crisis_observatory_unavailable', 503);
  }
  if (
    cachedArtifact &&
    cachedArtifact.file === file &&
    cachedArtifact.mtimeMs === stat.mtimeMs &&
    cachedArtifact.size === stat.size
  ) {
    return cachedArtifact;
  }
  let raw;
  let parsed;
  try {
    raw = fs.readFileSync(file, 'utf8');
    parsed = JSON.parse(raw);
  } catch {
    fail('crisis_observatory_invalid', 503);
  }
  if (
    !parsed ||
    !Array.isArray(parsed.daily_series) ||
    parsed.daily_series.length === 0 ||
    !Array.isArray(parsed.six_crisis_lights) ||
    !Array.isArray(parsed.strategies_summary) ||
    !Array.isArray(parsed.crisis_windows)
  ) {
    fail('crisis_observatory_invalid', 503);
  }
  const snapshotId = createHash('sha256').update(raw).digest('hex').slice(0, 16);
  projectedModeCache.clear();
  m7SimComboCache.clear();
  cachedArtifact = {
    file,
    mtimeMs: stat.mtimeMs,
    size: stat.size,
    snapshotId,
    data: parsed,
  };
  return cachedArtifact;
}

function unpackTable(val) {
  if (!val) return [];
  if (Array.isArray(val)) return val;
  if (Array.isArray(val._cols) && Array.isArray(val._rows)) {
    const cols = val._cols;
    return val._rows.map(row => {
      const obj = {};
      for (let i = 0; i < cols.length; i += 1) {
        obj[cols[i]] = row[i] ?? null;
      }
      return obj;
    });
  }
  return [];
}

function unpackLedgerMap(rawMap) {
  if (!rawMap || typeof rawMap !== 'object') return {};
  const out = {};
  for (const [sid, val] of Object.entries(rawMap)) {
    out[sid] = unpackTable(val);
  }
  return out;
}

const EVENT_ORDER_RANK = Object.freeze({
  vix110_tp: 1,
  vix110_itm_tp: 1,
  vix110_4x_tp: 1,
  put5x_dte45_tp: 1,
  live_tp_armed: 1,
  live_roll50_armed: 1,
  roll_50d: 2,
  option_expiry: 2,
  shield_enter: 3,
  shield_exit: 4,
  slot1_naked_put: 5,
  slot2_naked_put: 6,
  slot3_naked_put: 7,
  slot1_collar: 6,
  slot2_collar: 7,
  slot3_collar: 8,
});

function synthesizeUnifiedEvents(strategyId, ledger) {
  const events = [];
  for (const tr of ledger ?? []) {
    const isNk = tr.tranche_type === 'naked_put';
    const sNum = Number(tr.slot_num || 1);
    const evType = isNk
      ? sNum === 1
        ? 'slot1_naked_put'
        : `slot${sNum}_naked_put`
      : `slot${sNum}_collar`;
    const openEv = {
      event_id: `${strategyId}_tr${tr.tranche_id}_open`,
      tranche_id: tr.tranche_id,
      strategy_id: strategyId,
      date: tr.entry_date,
      signal_date: tr.signal_date,
      event_type: evType,
      slot_num: sNum,
      tranche_type: tr.tranche_type,
      spot: tr.entry_spot,
      vxn: tr.entry_vxn,
      vix_ratio: tr.entry_vix_ratio,
      kp: tr.kp,
      kc: tr.kc,
      call_cap_pct: tr.call_cap_pct,
      entry_cost_usd: tr.entry_cost_usd,
      hedged_shares: tr.hedged_shares,
      sig_score: tr.sig_score,
      sig_ad_below50: tr.sig_ad_below50,
      trigger_en: tr.trigger_en,
      trigger_zh: tr.trigger_zh,
      linked_exit_date: tr.exit_date,
      linked_exit_spot: tr.exit_spot,
      linked_exit_reason: tr.exit_reason,
      net_pnl_usd: tr.net_pnl_usd,
      shares_added: tr.shares_added,
      delta_usd: tr.delta_usd,
      gamma_usd: tr.gamma_usd,
      vega_usd: tr.vega_usd,
      theta_slip_usd: tr.theta_slip_usd,
    };
    if (tr.crisis_prob !== undefined && tr.crisis_prob !== null) {
      Object.assign(openEv, {
        crisis_prob: tr.crisis_prob,
        p1: tr.p1,
        p2: tr.p2,
        p3: tr.p3,
        triggered_modules: tr.triggered_modules,
        trigger_code: tr.trigger_code,
        tier: tr.tier,
        max_slots: tr.max_slots,
        put_otm_pct: tr.put_otm_pct,
        contracts_est: tr.contracts_est,
        roi_mult: tr.roi_mult,
        tp_mode: tr.tp_mode,
        roll_mode: tr.roll_mode,
        target_dte: tr.target_dte,
      });
    }
    events.push(openEv);

    const exitReason = String(tr.exit_reason ?? '');
    const isOpenLive = Boolean(tr.is_open_live);
    const isLiveRollArmed = exitReason === 'live_roll50_armed_next_open';
    const isLiveArmed = exitReason === 'live_tp_armed_next_open' || isLiveRollArmed;
    const isRoll50 = exitReason === 'roll_50d';
    const isTp = exitReason.includes('tp') && !isOpenLive;
    const isPut5x = exitReason.includes('put_5x');
    const isItmTp = exitReason.includes('itm_tp');
    const is4xTp = exitReason.includes('4x_tp');
    const evExitDate = !isOpenLive ? tr.exit_date : tr.mtm_date;

    if ((!isOpenLive || isLiveArmed) && evExitDate) {
      const vrStr = Number(tr.exit_vix_ratio ?? 0).toFixed(3);
      const retPct = Number(tr.underlying_ret_pct ?? 0);
      const retStr = `${retPct >= 0 ? '+' : ''}${retPct.toFixed(1)}%`;
      let evTypeExit;
      let trigEnExit;
      let trigZhExit;
      if (isLiveRollArmed) {
        evTypeExit = 'live_roll50_armed';
        trigEnExit = `50-DTE Roll/Salvage Armed (${tr.rem_dte_at_exit} DTE left · Next Open)`;
        trigZhExit = `50-DTE 残值滚仓已触发（剩 ${tr.rem_dte_at_exit} 天 · 待次日开盘执行）`;
      } else if (isLiveArmed) {
        evTypeExit = 'live_tp_armed';
        trigEnExit = `Deep-ITM Panic TP Armed (${tr.rem_dte_at_exit} DTE left · VIX/3M ${vrStr} · Next Open)`;
        trigZhExit = `实值恐慌止盈已触发（剩余 ${tr.rem_dte_at_exit} 天 · VIX/3M ${vrStr} · 待次日开盘换股）`;
      } else if (isRoll50) {
        evTypeExit = 'roll_50d';
        const salvPct = Math.round(Number(tr.roi_mult ?? 0) * 100);
        trigEnExit = `50-DTE Residual Roll/Salvage (${tr.rem_dte_at_exit} DTE left · ${salvPct}% Value Saved)`;
        trigZhExit = `50-DTE 剩余残值滚仓/回收（剩 ${tr.rem_dte_at_exit} 天 · 回收 ${salvPct}% 残值）`;
      } else if (isPut5x) {
        const dteCapLbl = exitReason.includes('dte75') ? 75 : 45;
        evTypeExit = 'put5x_dte45_tp';
        trigEnExit = `5x Put Slow-Bear TP (${tr.rem_dte_at_exit} DTE <= ${dteCapLbl}, Deep ITM Lock)`;
        trigZhExit = `后半程 Put >= 5x 慢熊止盈（剩余 ${tr.rem_dte_at_exit} 天 <= ${dteCapLbl} · 深实值锁利）`;
      } else if (isItmTp) {
        evTypeExit = 'vix110_itm_tp';
        trigEnExit = `Deep-ITM Panic TP (QQQ <= K_P & VIX/3M ${vrStr} >= 1.10)`;
        trigZhExit = `实值恐慌止盈（跌破行权价且 VIX/3M ${vrStr} >= 1.10）`;
      } else if (is4xTp) {
        evTypeExit = 'vix110_4x_tp';
        trigEnExit = `4x Deep Panic TP (Put >= 4x & VIX/3M ${vrStr} >= 1.10)`;
        trigZhExit = `4x 深度恐慌止盈（Put >= 4x 且 VIX/3M ${vrStr} >= 1.10）`;
      } else if (isTp) {
        evTypeExit = 'vix110_tp';
        trigEnExit = `VIX/VIX3M ${vrStr} >= 1.10 Panic TP`;
        trigZhExit = `VIX/VIX3M ${vrStr} >= 1.10 恐慌止盈抄底`;
      } else {
        const tenorExp = exitReason.includes('120dte') ? 120 : 90;
        evTypeExit = 'option_expiry';
        trigEnExit = `${tenorExp}-DTE Expiry (${retStr} spot)`;
        trigZhExit = `${tenorExp}-DTE 到期结算（期间正股 ${retStr}）`;
      }

      const exitEv = {
        event_id: `${strategyId}_tr${tr.tranche_id}_exit`,
        tranche_id: tr.tranche_id,
        strategy_id: strategyId,
        date: evExitDate,
        signal_date: tr.signal_date,
        event_type: evTypeExit,
        slot_num: sNum,
        tranche_type: tr.tranche_type,
        spot: tr.exit_spot,
        vxn: tr.exit_vxn,
        vix_ratio: tr.exit_vix_ratio,
        kp: tr.kp,
        kc: tr.kc,
        call_cap_pct: tr.call_cap_pct,
        entry_spot: tr.entry_spot,
        entry_date: tr.entry_date,
        entry_cost_usd: tr.entry_cost_usd,
        hedged_shares: tr.hedged_shares,
        sig_score: tr.sig_score,
        sig_ad_below50: tr.sig_ad_below50,
        trigger_en: trigEnExit,
        trigger_zh: trigZhExit,
        net_pnl_usd: tr.net_pnl_usd,
        shares_added: tr.shares_added,
        delta_usd: tr.delta_usd,
        gamma_usd: tr.gamma_usd,
        vega_usd: tr.vega_usd,
        theta_slip_usd: tr.theta_slip_usd,
        convexity_mult: tr.convexity_mult,
      };
      if (tr.crisis_prob !== undefined && tr.crisis_prob !== null) {
        Object.assign(exitEv, {
          crisis_prob: tr.crisis_prob,
          trigger_code: tr.trigger_code,
          triggered_modules: tr.triggered_modules,
          max_slots: tr.max_slots,
          put_otm_pct: tr.put_otm_pct,
          contracts_est: tr.contracts_est,
          roi_mult: tr.roi_mult,
          tp_mode: tr.tp_mode,
          roll_mode: tr.roll_mode,
          exit_reason: exitReason,
        });
      }
      events.push(exitEv);
    }
  }
  events.sort((a, b) => {
    if (a.date !== b.date) return a.date < b.date ? -1 : 1;
    return (EVENT_ORDER_RANK[a.event_type] ?? 99) - (EVENT_ORDER_RANK[b.event_type] ?? 99);
  });
  return events;
}

function getUnpackedM7Tables(rawData) {
  if (cachedArtifact && cachedArtifact.data === rawData && cachedArtifact.unpackedM7) {
    return cachedArtifact.unpackedM7;
  }
  const evalBars = unpackTable(rawData.m7_eval_bars);
  const sigM0On = unpackTable(rawData.m7_signals?.m0on);
  const sigM0Off = unpackTable(rawData.m7_signals?.m0off);
  const featRows = unpackTable(rawData.m7_feature_table);
  const dateToIdx = new Map(evalBars.map((r, idx) => [r.date, idx]));
  const unpacked = {
    evalBars,
    sigM0On,
    sigM0Off,
    featRows,
    dateToIdx,
    coeffs: rawData.opra_90dte_poly3_coeffs_desc ?? [],
  };
  if (cachedArtifact && cachedArtifact.data === rawData) {
    cachedArtifact.unpackedM7 = unpacked;
  }
  return unpacked;
}

function computeM7WinStatsJS(baseWindows, dateToIdx, navArr, ledger) {
  return (baseWindows ?? []).map(w => {
    const c0 = dateToIdx.get(w.crash_start_date);
    const c1 = dateToIdx.get(w.crash_end_date);
    if (c0 === undefined || c1 === undefined || c1 < c0) {
      return w.strategy_stats?.M7G_Graded ?? {};
    }
    const z0 = w.start_date;
    const z1 = w.end_date;
    const qRet = Number(w.qqq_ret_pct ?? 0);
    const qMdd = Number(w.qqq_mdd ?? 0);
    const mSub = navArr.slice(c0, c1 + 1);
    const mRet = mSub.length >= 2 && mSub[0] > 0 ? (mSub[mSub.length - 1] / mSub[0] - 1) * 100 : 0;
    let mpk = mSub[0] ?? 0;
    let mMdd = 0;
    for (const v of mSub) {
      if (v > mpk) mpk = v;
      const dd = mpk > 0 ? (v / mpk - 1) * 100 : 0;
      if (dd < mMdd) mMdd = dd;
    }
    const ledInWin = (ledger ?? []).filter(t => {
      const exDt = t.exit_date || t.mtm_date || '';
      return (t.entry_date >= z0 && t.entry_date <= z1) || (exDt && exDt >= z0 && exDt <= z1);
    });
    const tpHarv = ledInWin.reduce((acc, t) => {
      const ex = String(t.exit_reason ?? '');
      return (ex.includes('tp') || t.is_open_live) && Number(t.net_pnl_usd) > 0
        ? acc + Number(t.net_pnl_usd)
        : acc;
    }, 0);
    const tpSh = ledInWin.reduce((acc, t) => {
      const ex = String(t.exit_reason ?? '');
      return (ex.includes('tp') || t.is_open_live) && Number(t.shares_added) > 0
        ? acc + Number(t.shares_added)
        : acc;
    }, 0);
    const netAll = ledInWin.reduce((acc, t) => acc + Number(t.net_pnl_usd ?? 0), 0);
    return {
      ret_pct: r2(mRet),
      mdd_pct: r2(mMdd),
      dd_cushion_pct: r2(mMdd - qMdd),
      excess_ret_pct: r2(mRet - qRet),
      harvested_tp_usd: r2(tpHarv),
      shares_added_tp: r2(tpSh),
      net_option_pnl_usd: r2(netAll),
      tranche_ids: ledInWin.map(t => t.tranche_id),
    };
  });
}

function resolveM7EffectiveBundle(
  rawData,
  snapshotId,
  {
    putOtm = 'otm15',
    m7TpMode = 'standard',
    rollMode = '120d_roll50',
    m0Enabled = true,
    ccMode = 'cc_off',
    spMode = 'sp_off',
    wcMode = 'wc_reclaim_30d_d35',
  } = {},
) {
  const m0Tag = m0Enabled ? 'm0on' : 'm0off';
  const baseKey = `${putOtm}__${m7TpMode}__${rollMode}__${m0Tag}`;
  const baseM7 = rawData.m7_bundles?.[baseKey];
  const defaultWc = rawData.default_wc_mode || 'wc_reclaim_30d_d35';
  const effWc = spMode === 'sp_off' ? defaultWc : wcMode || defaultWc;

  if (ccMode === 'cc_off' && spMode === 'sp_off' && baseM7) {
    return {
      putOtm,
      m7TpMode,
      rollMode,
      m0Enabled,
      summaries: baseM7.summaries ?? {},
      ledgers: unpackLedgerMap(baseM7.ledgers),
      ccLedgers: { M7G_Graded: [], M7_Ensemble: [] },
      spLedgers: { M7G_Graded: [], M7_Ensemble: [] },
      events: baseM7.events ?? {},
      m7LiveDashboards: baseM7.m7_live_dashboards ?? {},
      liveSignalStates: baseM7.live_signal_states ?? {},
      liveSpStates: baseM7.live_sp_states ?? {},
      windowStats: baseM7.window_stats ?? {},
      nav_m7g: baseM7.nav_m7g ?? [],
      nav_m7: baseM7.nav_m7 ?? [],
      m7g_active_slots: baseM7.m7g_active_slots ?? [],
      m7_active_slots: baseM7.m7_active_slots ?? [],
    };
  }

  const comboKey = `${snapshotId}:${baseKey}:${ccMode}:${spMode}:${effWc}`;
  const cachedCombo = m7SimComboCache.get(comboKey);
  if (cachedCombo) return cachedCombo;

  const { evalBars, sigM0On, sigM0Off, featRows, dateToIdx, coeffs } = getUnpackedM7Tables(rawData);
  const sigSeries = m0Enabled ? sigM0On : sigM0Off;
  if (!evalBars.length || !sigSeries.length) return null;

  const lastEval = evalBars[evalBars.length - 1];
  const lastSig = sigSeries[sigSeries.length - 1];
  const lastFeat = featRows[featRows.length - 1] ?? {};
  const lastDailyBar = rawData.daily_series[rawData.daily_series.length - 1];

  const summaries = {};
  const ledgers = {};
  const ccLedgers = {};
  const spLedgers = {};
  const events = {};
  const m7LiveDashboards = {};
  const liveSignalStates = {};
  const liveSpStates = {};
  const windowStats = {};
  const sims = {};

  for (const sid of ['M7G_Graded', 'M7_Ensemble']) {
    const sim = simulateM7StrategyJS(evalBars, coeffs, sid, sigSeries, {
      putOtm,
      m7TpMode,
      rollMode,
      m0Enabled,
      ccMode,
      spMode,
      wcMode: effWc,
    });
    sims[sid] = sim;
    const metaRef = baseM7?.summaries?.[sid] ?? {};
    summaries[sid] = {
      ...metaRef,
      ...sim.summary,
    };
    ledgers[sid] = sim.ledger;
    ccLedgers[sid] = sim.cc_ledger;
    spLedgers[sid] = sim.sp_ledger;
    events[sid] = synthesizeUnifiedEvents(sid, sim.ledger);
    m7LiveDashboards[sid] = buildM7LiveDashboardJS(lastEval, lastSig, lastFeat, sim, coeffs, {
      putOtm,
      m7TpMode,
      rollMode,
      m0Enabled,
    });
    const openTrs = sim.active_tranches_eod ?? [];
    liveSignalStates[sid] = buildCutoffSignalState(
      lastDailyBar,
      openTrs,
      baseM7?.live_signal_states?.[sid] ?? rawData.live_signal_state,
    );
    const maskedSp = maskSimpleOptionLedgerAtCutoff(sim.sp_ledger, rawData.as_of_date);
    liveSpStates[sid] = buildCutoffSpState(
      rawData.daily_series,
      spMode,
      effWc,
      maskedSp,
      baseM7?.live_sp_states?.[sid] ?? rawData.live_sp_state,
      rawData.as_of_date,
    );
    windowStats[sid] = computeM7WinStatsJS(rawData.crisis_windows, dateToIdx, sim.nav, sim.ledger);
  }

  const computed = {
    putOtm,
    m7TpMode,
    rollMode,
    m0Enabled,
    summaries,
    ledgers,
    ccLedgers,
    spLedgers,
    events,
    m7LiveDashboards,
    liveSignalStates,
    liveSpStates,
    windowStats,
    nav_m7g: sims.M7G_Graded.nav.map(r2),
    nav_m7: sims.M7_Ensemble.nav.map(r2),
    m7g_active_slots: sims.M7G_Graded.active_slots,
    m7_active_slots: sims.M7_Ensemble.active_slots,
  };
  if (m7SimComboCache.size >= 64) {
    const oldest = m7SimComboCache.keys().next().value;
    m7SimComboCache.delete(oldest);
  }
  m7SimComboCache.set(comboKey, computed);
  return computed;
}

function hydrateCrisisWindows(baseWindows, bundleWindows, m7Bundle = null) {
  const baseById = new Map((baseWindows ?? []).map(w => [w.id, w]));
  const merged =
    Array.isArray(bundleWindows) && bundleWindows.length
      ? bundleWindows.map(w => ({
          ...(baseById.get(w.id) ?? {}),
          ...w,
        }))
      : (baseWindows ?? []).map(w => ({ ...w }));

  if (!m7Bundle?.windowStats) return merged;
  return merged.map((w, idx) => {
    const m7gSt = m7Bundle.windowStats.M7G_Graded?.[idx];
    const m7St = m7Bundle.windowStats.M7_Ensemble?.[idx];
    if (!m7gSt && !m7St) return w;
    return {
      ...w,
      strategy_stats: {
        ...(w.strategy_stats ?? {}),
        ...(m7gSt ? { M7G_Graded: m7gSt } : {}),
        ...(m7St ? { M7_Ensemble: m7St } : {}),
      },
      m7g_mdd: m7gSt?.mdd_pct ?? w.m7g_mdd,
      m7_mdd: m7St?.mdd_pct ?? w.m7_mdd,
      excess_ret_m7g: m7gSt?.excess_ret_pct ?? w.excess_ret_m7g,
      dd_cushion_m7g: m7gSt?.dd_cushion_pct ?? w.dd_cushion_m7g,
      harvested_usd_m7g: m7gSt?.harvested_tp_usd ?? w.harvested_usd_m7g,
      shares_added_m7g: m7gSt?.shares_added_tp ?? w.shares_added_m7g,
    };
  });
}

function resolveModeBundle(
  rawData,
  tpMode,
  ccMode,
  spMode = 'sp_off',
  wcMode = 'wc_reclaim_30d_d35',
) {
  const modeBundles = rawData.mode_bundles;
  const tpModes = rawData.tp_modes;
  const defaultWc = rawData.default_wc_mode || 'wc_reclaim_30d_d35';
  const effWc = wcMode || defaultWc;
  const bundleKey =
    spMode === 'sp_off'
      ? `${tpMode}__${ccMode}`
      : effWc === defaultWc
        ? `${tpMode}__${ccMode}__${spMode}`
        : `${tpMode}__${ccMode}__${spMode}__${effWc}`;
  return (
    modeBundles?.[bundleKey] ??
    modeBundles?.[`${tpMode}__${ccMode}__${spMode}__${effWc}`] ??
    modeBundles?.[`${tpMode}__${ccMode}__${spMode}`] ??
    (ccMode === 'cc_off' && spMode === 'sp_off' ? tpModes?.[tpMode] : null) ??
    null
  );
}

function getBundleNavArray(rawData, bundle, navKey) {
  if (bundle && Array.isArray(bundle[navKey])) return bundle[navKey];
  return (rawData.daily_series ?? []).map(row => Number(row[navKey] ?? row.nav_bh ?? 0));
}

function computeDailyExcessReturns(navArr, bhArr, maxLen = null) {
  const n = Math.min(navArr.length, bhArr.length, maxLen ?? navArr.length);
  if (n < 3) return [];
  const out = new Array(n - 1);
  for (let i = 1; i < n; i += 1) {
    const pNav = Number(navArr[i - 1]);
    const cNav = Number(navArr[i]);
    const pBh = Number(bhArr[i - 1]);
    const cBh = Number(bhArr[i]);
    const rStrat = pNav > 0 ? cNav / pNav - 1 : 0;
    const rBh = pBh > 0 ? cBh / pBh - 1 : 0;
    out[i - 1] = rStrat - rBh;
  }
  return out;
}

function pearsonCorr(xs, ys) {
  const n = Math.min(xs.length, ys.length);
  if (n < 5) return null;
  let sx = 0;
  let sy = 0;
  for (let i = 0; i < n; i += 1) {
    sx += xs[i];
    sy += ys[i];
  }
  const mx = sx / n;
  const my = sy / n;
  let num = 0;
  let vx = 0;
  let vy = 0;
  for (let i = 0; i < n; i += 1) {
    const dx = xs[i] - mx;
    const dy = ys[i] - my;
    num += dx * dy;
    vx += dx * dx;
    vy += dy * dy;
  }
  if (vx <= 1e-18 || vy <= 1e-18) return null;
  return r3(num / Math.sqrt(vx * vy));
}

function computeSeriesMetricsFromArray(dailyRows, navArr, bhEndNav) {
  const n = Math.min(dailyRows.length, navArr.length);
  if (n < 2) return null;
  const startNav = Number(navArr[0]);
  const endNav = Number(navArr[n - 1]);
  const startMs = Date.parse(`${dailyRows[0].date}T00:00:00Z`);
  const endMs = Date.parse(`${dailyRows[n - 1].date}T00:00:00Z`);
  const years = Math.max((endMs - startMs) / (365.25 * 86400 * 1000), 1 / 252);
  const cagr = startNav > 0 ? (Math.pow(endNav / startNav, 1 / years) - 1) * 100 : 0;
  let peak = startNav;
  let maxDd = 0;
  for (let i = 0; i < n; i += 1) {
    const v = Number(navArr[i]);
    if (v > peak) peak = v;
    const dd = peak > 0 ? (v / peak - 1) * 100 : 0;
    if (dd < maxDd) maxDd = dd;
  }
  const calmar = maxDd < -1e-6 ? cagr / Math.abs(maxDd) : 0;
  const lastClose = Number(dailyRows[n - 1].qqq_close);
  const finalSh = lastClose > 0 ? endNav / lastClose : 0;
  const bhSh = lastClose > 0 ? bhEndNav / lastClose : 0;
  return {
    end_nav: r2(endNav),
    cagr_pct: r2(cagr),
    max_dd_pct: r2(maxDd),
    calmar: r3(calmar),
    final_shares: r2(finalSh),
    bh_final_shares: r2(bhSh),
  };
}

function buildEngineAttributionByStrategy(
  rawData,
  snapshotId,
  selectedTpMode,
  selectedCcMode,
  selectedSpMode,
  selectedWcMode,
  {
    putOtm = 'otm15',
    m7TpMode = 'standard',
    rollMode = '120d_roll50',
    m0Enabled = true,
    cutoffSeries = null,
    liveScale = 1.0,
  } = {},
) {
  const defaultWc = rawData.default_wc_mode || 'wc_reclaim_30d_d35';
  const bE1 = resolveModeBundle(rawData, selectedTpMode, 'cc_off', 'sp_off', defaultWc);
  const bE2 = resolveModeBundle(rawData, selectedTpMode, selectedCcMode, 'sp_off', defaultWc);
  const bE3Standalone = resolveModeBundle(
    rawData,
    selectedTpMode,
    'cc_off',
    selectedSpMode,
    selectedWcMode,
  );
  const bCur = resolveModeBundle(
    rawData,
    selectedTpMode,
    selectedCcMode,
    selectedSpMode,
    selectedWcMode,
  );

  const m7E1 = resolveM7EffectiveBundle(rawData, snapshotId, {
    putOtm,
    m7TpMode,
    rollMode,
    m0Enabled,
    ccMode: 'cc_off',
    spMode: 'sp_off',
    wcMode: defaultWc,
  });
  const m7E2 =
    selectedCcMode === 'cc_off'
      ? m7E1
      : resolveM7EffectiveBundle(rawData, snapshotId, {
          putOtm,
          m7TpMode,
          rollMode,
          m0Enabled,
          ccMode: selectedCcMode,
          spMode: 'sp_off',
          wcMode: defaultWc,
        });
  const m7Cur =
    selectedSpMode === 'sp_off'
      ? m7E2
      : resolveM7EffectiveBundle(rawData, snapshotId, {
          putOtm,
          m7TpMode,
          rollMode,
          m0Enabled,
          ccMode: selectedCcMode,
          spMode: selectedSpMode,
          wcMode: selectedWcMode,
        });

  const summaryMap = (bundle, m7B) => {
    const list = bundle?.strategies_summary ?? rawData.strategies_summary ?? [];
    const base = Object.fromEntries(list.map(s => [s.id, s]));
    if (m7B?.summaries) {
      Object.assign(base, m7B.summaries);
    }
    return base;
  };
  const m1 = summaryMap(bE1, m7E1);
  const m2 = summaryMap(bE2, m7E2);
  const m3Solo = summaryMap(bE3Standalone, null);
  const mCur = summaryMap(bCur, m7Cur);

  const baseSeries = rawData.daily_series ?? [];
  const bhArr = baseSeries.map(r => Number(r.nav_bh ?? 0));
  const useCutoffSlice =
    Array.isArray(cutoffSeries) &&
    cutoffSeries.length > 0 &&
    cutoffSeries.length < baseSeries.length;
  const effLen = useCutoffSlice ? cutoffSeries.length : baseSeries.length;
  const bhEndCutoff = useCutoffSlice ? Number(cutoffSeries[cutoffSeries.length - 1].nav_bh ?? 0) : null;

  const navE2SoloArr = getBundleNavArray(rawData, bE2, 'nav_cc');
  const navE3SoloArr = getBundleNavArray(rawData, bE3Standalone, 'nav_cc');
  const exE2Solo = selectedCcMode !== 'cc_off' ? computeDailyExcessReturns(navE2SoloArr, bhArr, effLen) : [];
  const exE3Solo = selectedSpMode !== 'sp_off' ? computeDailyExcessReturns(navE3SoloArr, bhArr, effLen) : [];
  const corrE2E3 = exE2Solo.length && exE3Solo.length ? pearsonCorr(exE2Solo, exE3Solo) : null;

  const navArrayFor = (bundle, m7B, sid) => {
    const navKey = STRATEGY_NAV_KEYS[sid] ?? 'nav_bh';
    if ((sid === 'M7G_Graded' || sid === 'M7_Ensemble') && m7B && Array.isArray(m7B[navKey]) && m7B[navKey].length) {
      return m7B[navKey];
    }
    return getBundleNavArray(rawData, bundle, navKey);
  };

  const metricFor = (bundle, m7B, sMap, sid) => {
    const rawS = sMap[sid] ?? mCur[sid] ?? mCur.BH_Pure_QQQ ?? {};
    if (useCutoffSlice) {
      const arr = navArrayFor(bundle, m7B, sid).slice(0, effLen);
      const sliced = computeSeriesMetricsFromArray(cutoffSeries, arr, bhEndCutoff);
      return { ...rawS, ...(sliced ?? {}) };
    }
    if (liveScale !== 1.0 && Number.isFinite(liveScale) && liveScale > 0) {
      const endNav = r2(Number(rawS.end_nav ?? 0) * liveScale);
      return { ...rawS, end_nav: endNav };
    }
    return rawS;
  };

  const sBh = metricFor(bCur, m7Cur, mCur, 'BH_Pure_QQQ');
  const out = {};

  for (const sid of CRISIS_OBSERVATORY_STRATEGIES) {
    const isM7Strat = sid === 'M7G_Graded' || sid === 'M7_Ensemble';
    const hasE1 = sid !== 'NoPut_CallOnly' && sid !== 'BH_Pure_QQQ';
    const hasE2 = selectedCcMode !== 'cc_off' && sid !== 'BH_Pure_QQQ';
    const hasE3 = selectedSpMode !== 'sp_off' && sid !== 'BH_Pure_QQQ';

    const s1 = hasE1 ? metricFor(bE1, m7E1, m1, sid) : sBh;
    const s2 = hasE2 ? metricFor(bE2, m7E2, m2, sid) : s1;
    const s3 = hasE3 ? metricFor(bCur, m7Cur, mCur, sid) : s2;
    const s2Solo = hasE2 ? metricFor(bE2, null, m2, 'NoPut_CallOnly') : sBh;
    const s3Solo = hasE3 ? metricFor(bE3Standalone, null, m3Solo, 'NoPut_CallOnly') : sBh;

    const bhNav =
      !useCutoffSlice && isM7Strat && Number.isFinite(Number(s3.bh_parity_end_nav))
        ? r2(Number(s3.bh_parity_end_nav) * (liveScale !== 1.0 && Number.isFinite(liveScale) && liveScale > 0 ? liveScale : 1.0))
        : Number(sBh.end_nav ?? 0);
    const bhSh =
      !useCutoffSlice && isM7Strat && Number.isFinite(Number(s3.bh_final_shares))
        ? Number(s3.bh_final_shares)
        : Number(sBh.final_shares ?? 0);
    const totNav = Number(s3.end_nav ?? bhNav);
    const totAlpha = r2(totNav - bhNav);
    const totExtraSh = r2(Number(s3.final_shares ?? bhSh) - bhSh);

    const d1Usd = hasE1 ? r2(Number(s1.end_nav ?? bhNav) - bhNav) : 0;
    const d2Usd = hasE2 ? r2(Number(s2.end_nav ?? s1.end_nav) - Number(s1.end_nav ?? bhNav)) : 0;
    const d3Usd = hasE3 ? r2(totNav - Number(s2.end_nav ?? s1.end_nav)) : 0;

    const d1Sh = hasE1 ? r2(Number(s1.final_shares ?? bhSh) - bhSh) : 0;
    const d2Sh = hasE2 ? r2(Number(s2.final_shares ?? s1.final_shares) - Number(s1.final_shares ?? bhSh)) : 0;
    const d3Sh = hasE3 ? r2(Number(s3.final_shares ?? s2.final_shares) - Number(s2.final_shares ?? bhSh)) : 0;

    const sharePct = delta =>
      Math.abs(totAlpha) > 1e-6 ? Math.round((delta / totAlpha) * 1000) / 10 : 0;
    const extraShPct = dSh => (bhSh > 0 ? r2((dSh / bhSh) * 100) : 0);

    const exE1 = hasE1
      ? computeDailyExcessReturns(navArrayFor(bE1, m7E1, sid), bhArr, effLen)
      : [];
    const corrE1E2 = hasE1 && hasE2 ? pearsonCorr(exE1, exE2Solo) : null;
    const corrE1E3 = hasE1 && hasE3 ? pearsonCorr(exE1, exE3Solo) : null;

    const curSummary = mCur[sid] ?? s3;
    const e1Meta = m1[sid] ?? curSummary;
    const e1ModeId = !hasE1
      ? 'off'
      : isM7Strat
        ? `${sid}::${putOtm}::${rollMode}::${m7TpMode}`
        : `${sid}::${selectedTpMode}`;

    out[sid] = {
      strategy_id: sid,
      base_end_nav: r2(bhNav),
      base_shares: r2(bhSh),
      base_cagr_pct: r2(Number(sBh.cagr_pct ?? 0)),
      base_max_dd_pct: r2(Number(sBh.max_dd_pct ?? 0)),
      base_calmar: r3(Number(sBh.calmar ?? 0)),
      total_end_nav: r2(totNav),
      total_alpha_usd: totAlpha,
      total_extra_shares: totExtraSh,
      total_extra_shares_pct: extraShPct(totExtraSh),
      active_engines_count: (hasE1 ? 1 : 0) + (hasE2 ? 1 : 0) + (hasE3 ? 1 : 0),
      correlations: {
        e1_e2: corrE1E2,
        e1_e3: corrE1E3,
        e2_e3: hasE2 && hasE3 ? corrE2E3 : null,
      },
      engine1: {
        active: hasE1,
        mode_id: e1ModeId,
        delta_usd: d1Usd,
        standalone_alpha_usd: d1Usd,
        share_of_alpha_pct: hasE1 ? sharePct(d1Usd) : 0,
        delta_shares: d1Sh,
        delta_extra_pct: extraShPct(d1Sh),
        delta_cagr_pp: hasE1 ? r2(Number(s1.cagr_pct ?? 0) - Number(sBh.cagr_pct ?? 0)) : 0,
        delta_mdd_pp: hasE1 ? r2(Number(s1.max_dd_pct ?? 0) - Number(sBh.max_dd_pct ?? 0)) : 0,
        delta_calmar: hasE1 ? r3(Number(s1.calmar ?? 0) - Number(sBh.calmar ?? 0)) : 0,
        tranches_total: Number(e1Meta.tranches_total ?? 0),
        tp_count: Number(e1Meta.tp_count ?? 0),
        roll_50d_count: Number(e1Meta.roll_50d_count ?? 0),
        avg_roll_salvage_pct: r2(Number(e1Meta.avg_roll_salvage_pct ?? 0)),
        naked_prem_spent_usd: r2(Number(e1Meta.naked_prem_spent_usd ?? 0)),
        gross_put_monetized_usd: r2(Number(e1Meta.gross_put_monetized_usd ?? 0)),
        pct_days_hedged: r2(Number(e1Meta.pct_days_hedged ?? 0)),
      },
      engine2: {
        active: hasE2,
        mode_id: selectedCcMode,
        delta_usd: d2Usd,
        standalone_alpha_usd: hasE2 ? r2(Number(s2Solo.end_nav ?? bhNav) - bhNav) : 0,
        share_of_alpha_pct: hasE2 ? sharePct(d2Usd) : 0,
        delta_shares: d2Sh,
        delta_extra_pct: extraShPct(d2Sh),
        delta_cagr_pp: hasE2 ? r2(Number(s2.cagr_pct ?? 0) - Number(s1.cagr_pct ?? 0)) : 0,
        delta_mdd_pp: hasE2 ? r2(Number(s2.max_dd_pct ?? 0) - Number(s1.max_dd_pct ?? 0)) : 0,
        delta_calmar: hasE2 ? r3(Number(s2.calmar ?? 0) - Number(s1.calmar ?? 0)) : 0,
        trades_count: Number(curSummary.cc_trades_count ?? 0),
        active_years: Number(curSummary.cc_active_years ?? 0),
        stop_count: Number(curSummary.cc_stop_count ?? 0),
        roll_count: Number(curSummary.cc_roll_count ?? 0),
        assigned_count: Number(curSummary.cc_assigned_count ?? 0),
        gross_prem_usd: r2(Number(curSummary.cc_gross_prem_usd ?? 0)),
        gross_loss_usd: r2(Number(curSummary.cc_gross_loss_usd ?? 0)),
        funded_puts_usd: r2(Number(curSummary.cc_funded_puts_usd ?? 0)),
      },
      engine3: {
        active: hasE3,
        mode_id: selectedSpMode,
        wc_mode: selectedWcMode,
        delta_usd: d3Usd,
        standalone_alpha_usd: hasE3 ? r2(Number(s3Solo.end_nav ?? bhNav) - bhNav) : 0,
        share_of_alpha_pct: hasE3 ? sharePct(d3Usd) : 0,
        delta_shares: d3Sh,
        delta_extra_pct: extraShPct(d3Sh),
        delta_cagr_pp: hasE3 ? r2(Number(s3.cagr_pct ?? 0) - Number(s2.cagr_pct ?? 0)) : 0,
        delta_mdd_pp: hasE3 ? r2(Number(s3.max_dd_pct ?? 0) - Number(s2.max_dd_pct ?? 0)) : 0,
        delta_calmar: hasE3 ? r3(Number(s3.calmar ?? 0) - Number(s2.calmar ?? 0)) : 0,
        sp_trades_count: Number(curSummary.sp_trades_count ?? 0),
        sp_win_rate_pct: r2(Number(curSummary.sp_win_rate_pct ?? 0)),
        sp_assignments_count: Number(curSummary.sp_assignments_count ?? 0),
        wc_trades_count: Number(curSummary.wc_trades_count ?? 0),
        wc_called_away_count: Number(curSummary.wc_called_away_count ?? 0),
        gross_prem_usd: r2(Number(curSummary.sp_gross_prem_usd ?? 0) + Number(curSummary.wc_gross_prem_usd ?? 0)),
        margin_interest_usd: r2(Number(curSummary.margin_interest_usd ?? 0)),
        days_levered_stock: Number(curSummary.days_levered_stock ?? 0),
        max_wheel_cycle_days: Number(curSummary.max_wheel_cycle_days ?? 0),
        max_gross_stock_lev: r3(Number(curSummary.max_gross_stock_lev ?? 1.0)),
      },
    };
  }
  return out;
}

function projectArtifactForModes(
  data,
  snapshotId,
  selectedTpMode,
  selectedCcMode,
  selectedSpMode = 'sp_off',
  selectedWcMode = 'wc_reclaim_30d_d35',
  selectedPutOtm = 'otm15',
  selectedM7TpMode = 'standard',
  selectedRollMode = '120d_roll50',
  selectedM0Enabled = true,
) {
  const defaultWcMode = data.default_wc_mode ?? 'wc_reclaim_30d_d35';
  const effectiveWcMode = selectedWcMode || defaultWcMode;
  const cacheWcKey = selectedSpMode === 'sp_off' ? defaultWcMode : effectiveWcMode;
  const m0Tag = selectedM0Enabled ? 'm0on' : 'm0off';
  const cacheKey = `${snapshotId}:${selectedPutOtm}:${selectedM7TpMode}:${selectedRollMode}:${m0Tag}:${selectedTpMode}:${selectedCcMode}:${selectedSpMode}:${cacheWcKey}`;
  const hit = projectedModeCache.get(cacheKey);
  if (hit) return hit;

  const {
    tp_modes: tpModes,
    mode_bundles: modeBundles,
    tp_slot_series: tpSlotSeries,
    m7_bundles: _m7Bundles,
    m7_signals: _m7Signals,
    m7_feature_table: _m7FeatureTable,
    m7_live_tail_state: _m7LiveTailState,
    m7_eval_bars: _m7EvalBars,
    opra_90dte_poly3_coeffs_desc: _opraCoeffs,
    ...baseWithoutModes
  } = data;

  const bundleKey =
    selectedSpMode === 'sp_off'
      ? `${selectedTpMode}__${selectedCcMode}`
      : effectiveWcMode === defaultWcMode
        ? `${selectedTpMode}__${selectedCcMode}__${selectedSpMode}`
        : `${selectedTpMode}__${selectedCcMode}__${selectedSpMode}__${effectiveWcMode}`;
  const bundle =
    modeBundles?.[bundleKey] ??
    modeBundles?.[`${selectedTpMode}__${selectedCcMode}__${selectedSpMode}`] ??
    (selectedCcMode === 'cc_off' && selectedSpMode === 'sp_off' ? tpModes?.[selectedTpMode] : null);

  const m7Eff = resolveM7EffectiveBundle(data, snapshotId, {
    putOtm: selectedPutOtm,
    m7TpMode: selectedM7TpMode,
    rollMode: selectedRollMode,
    m0Enabled: selectedM0Enabled,
    ccMode: selectedCcMode,
    spMode: selectedSpMode,
    wcMode: effectiveWcMode,
  });

  if (!bundle && !m7Eff) {
    const fallback = {
      ...baseWithoutModes,
      put_otm: selectedPutOtm,
      m7_tp_mode: selectedM7TpMode,
      roll_mode: selectedRollMode,
      m0_enabled: selectedM0Enabled,
      tp_mode: data.tp_mode ?? 'layered_itm',
      default_tp_mode: data.default_tp_mode ?? 'layered_itm',
      cc_mode: data.cc_mode ?? 'cc_off',
      default_cc_mode: data.default_cc_mode ?? 'cc_off',
      sp_mode: data.sp_mode ?? 'sp_off',
      default_sp_mode: data.default_sp_mode ?? 'sp_off',
      wc_mode: effectiveWcMode,
      default_wc_mode: defaultWcMode,
    };
    projectedModeCache.set(cacheKey, fallback);
    return fallback;
  }

  const isDefaultLegacy =
    selectedTpMode === (data.default_tp_mode ?? 'layered_itm') &&
    selectedCcMode === (data.default_cc_mode ?? 'cc_off') &&
    selectedSpMode === (data.default_sp_mode ?? 'sp_off');
  const isDefaultM7 =
    selectedPutOtm === (data.default_put_otm ?? 'otm15') &&
    selectedM7TpMode === (data.default_m7_tp_mode ?? 'standard') &&
    selectedRollMode === (data.default_roll_mode ?? '120d_roll50') &&
    selectedM0Enabled === Boolean(data.default_m0_enabled ?? true) &&
    selectedCcMode === (data.default_cc_mode ?? 'cc_off') &&
    selectedSpMode === (data.default_sp_mode ?? 'sp_off');

  const activeSlotsArr = bundle?.active_slots ?? tpSlotSeries?.[selectedTpMode]?.active_slots;
  const slot1NakedArr = bundle?.slot1_naked ?? tpSlotSeries?.[selectedTpMode]?.slot1_naked;
  const sigAltSeries = !selectedM0Enabled ? getUnpackedM7Tables(data).sigM0Off : null;

  const projectedSeries =
    isDefaultLegacy && isDefaultM7
      ? data.daily_series
      : data.daily_series.map((row, idx) => {
          const sdOff = sigAltSeries?.[idx];
          return {
            ...row,
            nav_m7g: m7Eff?.nav_m7g?.[idx] ?? row.nav_m7g,
            nav_m7: m7Eff?.nav_m7?.[idx] ?? row.nav_m7,
            m7_prob: sdOff ? Math.round(Number(sdOff.crisis_prob ?? 0)) : row.m7_prob,
            m7_p1: sdOff ? Math.round(Number(sdOff.p1 ?? 0)) : row.m7_p1,
            m7_p2: sdOff ? Math.round(Number(sdOff.p2 ?? 0)) : row.m7_p2,
            m7_p3: sdOff ? Math.round(Number(sdOff.p3 ?? 0)) : row.m7_p3,
            m7_target_slots: sdOff ? Number(sdOff.target_slots_m7g ?? 0) : row.m7_target_slots,
            m7_active_slots: m7Eff?.m7g_active_slots?.[idx] ?? row.m7_active_slots,
            m7_mask: sdOff ? Number(sdOff.mask ?? 0) : row.m7_mask,
            nav_u1: bundle?.nav_u1?.[idx] ?? row.nav_u1,
            nav_b1c: bundle?.nav_b1c?.[idx] ?? row.nav_b1c,
            nav_d2: bundle?.nav_d2?.[idx] ?? row.nav_d2,
            nav_h2: bundle?.nav_h2?.[idx] ?? row.nav_h2,
            nav_cc: bundle?.nav_cc?.[idx] ?? row.nav_cc,
            active_slots: activeSlotsArr?.[idx] ?? row.active_slots,
            slot1_naked: slot1NakedArr?.[idx] ?? row.slot1_naked,
          };
        });

  const legacyTradeLedgers = bundle?.trade_ledgers_by_strategy
    ? unpackLedgerMap(bundle.trade_ledgers_by_strategy)
    : unpackLedgerMap(data.trade_ledgers_by_strategy ?? {});
  const unpackedTradeLedgers = {
    ...(m7Eff?.ledgers ?? {}),
    ...legacyTradeLedgers,
    ...(m7Eff?.ledgers?.M7G_Graded ? { M7G_Graded: m7Eff.ledgers.M7G_Graded } : {}),
    ...(m7Eff?.ledgers?.M7_Ensemble ? { M7_Ensemble: m7Eff.ledgers.M7_Ensemble } : {}),
  };

  const legacyCcLedgers = bundle?.cc_ledgers_by_strategy
    ? unpackLedgerMap(bundle.cc_ledgers_by_strategy)
    : unpackLedgerMap(data.cc_ledgers_by_strategy ?? {});
  const unpackedCcLedgers = {
    ...legacyCcLedgers,
    ...(m7Eff?.ccLedgers ?? {}),
  };

  const legacySpLedgers = bundle?.sp_ledgers_by_strategy
    ? unpackLedgerMap(bundle.sp_ledgers_by_strategy)
    : unpackLedgerMap(data.sp_ledgers_by_strategy ?? {});
  const unpackedSpLedgers = {
    ...legacySpLedgers,
    ...(m7Eff?.spLedgers ?? {}),
  };

  const eventsByStrategy = {};
  for (const [sid, led] of Object.entries(unpackedTradeLedgers)) {
    if (sid === 'M7G_Graded' || sid === 'M7_Ensemble') {
      eventsByStrategy[sid] = m7Eff?.events?.[sid] ?? synthesizeUnifiedEvents(sid, led);
    } else {
      eventsByStrategy[sid] =
        bundle?.events_by_strategy?.[sid] ?? synthesizeUnifiedEvents(sid, led);
    }
  }

  const legacySummaries = (bundle?.strategies_summary ?? data.strategies_summary ?? []).filter(
    s => s.id !== 'M7G_Graded' && s.id !== 'M7_Ensemble',
  );
  const strategiesSummary = [
    ...(m7Eff?.summaries?.M7G_Graded ? [m7Eff.summaries.M7G_Graded] : []),
    ...(m7Eff?.summaries?.M7_Ensemble ? [m7Eff.summaries.M7_Ensemble] : []),
    ...legacySummaries,
  ];

  const hydratedWindows = hydrateCrisisWindows(
    data.crisis_windows,
    bundle?.crisis_windows,
    m7Eff,
  );
  const engineAttributionByStrategy = buildEngineAttributionByStrategy(
    data,
    snapshotId,
    selectedTpMode,
    selectedCcMode,
    selectedSpMode,
    effectiveWcMode,
    {
      putOtm: selectedPutOtm,
      m7TpMode: selectedM7TpMode,
      rollMode: selectedRollMode,
      m0Enabled: selectedM0Enabled,
    },
  );

  const liveSignalStatesByStrategy = {
    ...(data.live_signal_states_by_strategy ?? {}),
    ...(bundle?.live_signal_states_by_strategy ?? {}),
    ...(m7Eff?.liveSignalStates ?? {}),
  };
  const liveSpStatesByStrategy = {
    ...(data.live_sp_states_by_strategy ?? {}),
    ...(bundle?.live_sp_states_by_strategy ?? {}),
    ...(m7Eff?.liveSpStates ?? {}),
  };
  const m7LiveDashboardsByStrategy =
    m7Eff?.m7LiveDashboards ?? data.m7_live_dashboards_by_strategy ?? {};

  const projected = {
    ...baseWithoutModes,
    put_otm: selectedPutOtm,
    default_put_otm: data.default_put_otm ?? 'otm15',
    put_otm_meta: data.put_otm_meta ?? [],
    m7_tp_mode: selectedM7TpMode,
    default_m7_tp_mode: data.default_m7_tp_mode ?? 'standard',
    m7_tp_modes_meta: data.m7_tp_modes_meta ?? [],
    roll_mode: selectedRollMode,
    default_roll_mode: data.default_roll_mode ?? '120d_roll50',
    m7_roll_modes_meta: data.m7_roll_modes_meta ?? [],
    m0_enabled: selectedM0Enabled,
    default_m0_enabled: data.default_m0_enabled ?? true,
    tp_mode: selectedTpMode,
    default_tp_mode: data.default_tp_mode ?? 'layered_itm',
    tp_modes_meta: data.tp_modes_meta ?? [],
    cc_mode: selectedCcMode,
    default_cc_mode: data.default_cc_mode ?? 'cc_off',
    cc_modes_meta: data.cc_modes_meta ?? [],
    sp_mode: selectedSpMode,
    default_sp_mode: data.default_sp_mode ?? 'sp_off',
    sp_modes_meta: data.sp_modes_meta ?? [],
    wc_mode: effectiveWcMode,
    default_wc_mode: defaultWcMode,
    wc_modes_meta: data.wc_modes_meta ?? [],
    m7_live_dashboard:
      m7LiveDashboardsByStrategy.M7G_Graded ?? data.m7_live_dashboard ?? null,
    m7_live_dashboards_by_strategy: m7LiveDashboardsByStrategy,
    live_signal_state: bundle?.live_signal_state ?? data.live_signal_state,
    live_signal_states_by_strategy: liveSignalStatesByStrategy,
    live_sp_state: bundle?.live_sp_state ?? data.live_sp_state ?? null,
    live_sp_states_by_strategy: liveSpStatesByStrategy,
    strategies_summary: strategiesSummary,
    engine_attribution_by_strategy: engineAttributionByStrategy,
    daily_series: projectedSeries,
    events: eventsByStrategy.M7G_Graded ?? data.events,
    events_by_strategy: eventsByStrategy,
    trade_ledger: unpackedTradeLedgers.M7G_Graded ?? data.trade_ledger,
    trade_ledgers_by_strategy: unpackedTradeLedgers,
    cc_ledgers_by_strategy: unpackedCcLedgers,
    sp_ledger: unpackedSpLedgers.M7G_Graded ?? [],
    sp_ledgers_by_strategy: unpackedSpLedgers,
    crisis_windows: hydratedWindows,
  };
  if (projectedModeCache.size >= 64) {
    const oldestKey = projectedModeCache.keys().next().value;
    projectedModeCache.delete(oldestKey);
  }
  projectedModeCache.set(cacheKey, projected);
  return projected;
}

function computeSeriesMetrics(dailyRows, navKey, bhEndNav) {
  if (!dailyRows.length) return null;
  const startNav = Number(dailyRows[0][navKey]);
  const endNav = Number(dailyRows[dailyRows.length - 1][navKey]);
  const startMs = Date.parse(`${dailyRows[0].date}T00:00:00Z`);
  const endMs = Date.parse(`${dailyRows[dailyRows.length - 1].date}T00:00:00Z`);
  const years = Math.max((endMs - startMs) / (365.25 * 86400 * 1000), 1 / 252);
  const cagr = (Math.pow(endNav / startNav, 1 / years) - 1) * 100;

  let peak = startNav;
  let maxDd = 0;
  const rets = [];
  for (let i = 0; i < dailyRows.length; i += 1) {
    const v = Number(dailyRows[i][navKey]);
    if (v > peak) peak = v;
    const dd = (v / peak - 1) * 100;
    if (dd < maxDd) maxDd = dd;
    if (i > 0) {
      const prev = Number(dailyRows[i - 1][navKey]);
      if (prev > 0) rets.push(v / prev - 1);
    }
  }
  let sharpe = 0;
  if (rets.length >= 2) {
    const mean = rets.reduce((a, b) => a + b, 0) / rets.length;
    let sq = 0;
    for (let i = 0; i < rets.length; i += 1) sq += (rets[i] - mean) ** 2;
    const std = Math.sqrt(sq / (rets.length - 1));
    if (std > 1e-12) sharpe = (mean / std) * Math.sqrt(252);
  }
  const calmar = maxDd < -1e-6 ? cagr / Math.abs(maxDd) : 0;
  const lastClose = Number(dailyRows[dailyRows.length - 1].qqq_close);
  const finalSh = lastClose > 0 ? endNav / lastClose : null;
  const bhSh = lastClose > 0 ? bhEndNav / lastClose : null;
  const extraSh = finalSh !== null && bhSh !== null ? finalSh - bhSh : null;
  const extraPct = extraSh !== null && bhSh > 0 ? (extraSh / bhSh) * 100 : null;
  return {
    end_nav: r2(endNav),
    net_alpha_usd: r2(endNav - bhEndNav),
    cagr_pct: r2(cagr),
    max_dd_pct: r2(maxDd),
    sharpe: r3(sharpe),
    calmar: r3(calmar),
    final_shares: finalSh !== null ? r2(finalSh) : null,
    bh_final_shares: bhSh !== null ? r2(bhSh) : null,
    extra_shares_vs_bh: extraSh !== null ? r2(extraSh) : null,
    extra_shares_pct: extraPct !== null ? r2(extraPct) : null,
  };
}

function maskLedgerAtCutoff(ledger, asOfDate) {
  const out = [];
  for (const tr of ledger ?? []) {
    if (tr.entry_date > asOfDate) continue;
    if ((tr.exit_date && tr.exit_date <= asOfDate) || (tr.is_open_live && tr.mtm_date && tr.mtm_date <= asOfDate)) {
      out.push(tr);
    } else {
      out.push({
        ...tr,
        exit_date: null,
        exit_reason: 'open_as_of_cutoff',
        actual_days_held: null,
        rem_dte_at_exit: null,
        exit_spot: null,
        exit_vxn: null,
        exit_vix_ratio: null,
        underlying_ret_pct: null,
        put_exit_val_sh: null,
        call_exit_cost_sh: null,
        exit_net_cash_usd: null,
        net_pnl_usd: null,
        roi_mult: null,
        exit_shares_delta: null,
        shares_added: null,
        delta_usd: null,
        gamma_usd: null,
        vega_usd: null,
        theta_slip_usd: null,
        convexity_mult: null,
        comp_put_gain_usd: null,
        comp_call_drag_usd: null,
      });
    }
  }
  return out;
}

function buildCutoffSignalState(lastBar, openU1Tranches, baseSignalState) {
  const ddPct = Number(lastBar.dd_ath_pct);
  const vxn = Number(lastBar.vxn);
  const vr = Number(lastBar.vix_ratio);
  const sc = Number(lastBar.crisis_lights);
  const sc5 = Number(lastBar.smooth_lights);
  const cl = Number(lastBar.qqq_close);
  const ma200 = Number(lastBar.qqq_ma200);
  const adBelow = Number(lastBar.ad_line) < Number(lastBar.ad_sma50);
  const athOk = ddPct >= -5.0;
  const vxnOk = vxn <= 22.0;
  const lightsOk = sc >= 4;
  const tpOk = vr >= 1.1;

  const s1Open = openU1Tranches.find(t => t.slot_num === 1) ?? null;
  const s2Open = openU1Tranches.find(t => t.slot_num === 2) ?? null;

  let regimeCode = 'CRUISE_UNHEDGED';
  let titleEn = 'BULL CRUISE UNHEDGED (100% QQQ · ZERO CALL DRAG)';
  let titleZh = '顺风巡航零期权拖累（100% 满仓 QQQ 复利）';
  if (s1Open && s2Open) {
    regimeCode = 'DUAL_SLOT_FULL_SHIELD';
    titleEn = 'SLOT 1 NAKED PUT + SLOT 2 ZERO-COST COLLAR FULL HEDGE ACTIVE (100% QQQ)';
    titleZh = '首仓裸 Put + 次仓零成本 Collar 双槽满盾保护中（100% 满仓 QQQ）';
  } else if (s1Open) {
    regimeCode = 'SLOT1_NAKED_PUT_ACTIVE';
    titleEn = 'SLOT 1 (50% NAKED -10% PUT) ACTIVE · 100% QQQ UNLIMITED UPSIDE RETAINED';
    titleZh = '首仓 50% 裸 -10% Put 持盾中 · 100% QQQ 保留完整向上冲顶收益';
  } else if (!athOk) {
    regimeCode = 'LOW_SPOT_FREEZE_NO_NEW_COLLAR';
    titleEn = 'DRAWDOWN > 5% OFF ATH · HARD FREEZE ON NEW COLLARS (100% QQQ REBOUND CAPTURE)';
    titleZh = '距历史前高回撤超 5% · 严禁低位新开或续作 Collar（100% QQQ 保留完整反弹斜率）';
  }

  const dev200 = ma200 > 0 ? ((cl / ma200 - 1) * 100).toFixed(2) : '0.00';
  const adSpread = Math.round(Number(lastBar.ad_vs_50ma));
  const adSpreadStr = `${adSpread >= 0 ? '+' : ''}${adSpread}`;

  return {
    ...baseSignalState,
    regime_code: regimeCode,
    regime_title_en: titleEn,
    regime_title_zh: titleZh,
    regime_subtitle_en: `QQQ $${cl.toFixed(2)} (${ddPct.toFixed(2)}% vs ATH, ${dev200}% vs 200DMA) · ${sc}/6 Crisis Lights ON (5D avg ${sc5.toFixed(1)}) · VIX/VIX3M ${vr.toFixed(3)} · 100% QQQ Pure Options`,
    regime_subtitle_zh: `QQQ 现价 $${cl.toFixed(2)}（距前高 ${ddPct.toFixed(2)}%，偏离年线 ${dev200}%）· 危机灯 ${sc}/6 亮灯（5日均值 ${sc5.toFixed(1)}）· VIX/VIX3M ${vr.toFixed(3)} · 100% 满仓 QQQ 纯期权`,
    target_equity_pct: 100.0,
    target_tbill_pct: 0.0,
    active_option_slots: openU1Tranches.length,
    slot1_naked_put: {
      ...baseSignalState.slot1_naked_put,
      status: s1Open ? 'ACTIVE_OPEN' : 'STANDBY',
      status_label_en: s1Open ? 'ACTIVE' : 'STANDBY',
      status_label_zh: s1Open ? '持仓保护中' : '待命',
      open_position: s1Open,
    },
    slot2_collar: {
      ...baseSignalState.slot2_collar,
      status: s2Open ? 'ACTIVE_OPEN' : !athOk ? 'FROZEN_BELOW_ATH5' : 'STANDBY_WAIT_30D',
      status_label_en: s2Open ? 'ACTIVE' : !athOk ? 'HARD FROZEN (DD > 5%)' : 'STANDBY (>=30D STEP)',
      status_label_zh: s2Open ? '持盾保护中' : !athOk ? '低位铁律冻结（禁卖Call）' : '待命（距首仓满30日开启）',
      open_position: s2Open,
    },
    gate_checklist: [
      {
        key: 'ath_within_5pct',
        passed: athOk,
        label_en: 'ATH <= 5%',
        label_zh: '距前高 <= 5%',
        current_value: `${ddPct.toFixed(2)}%`,
        reading: `${ddPct.toFixed(2)}%`,
      },
      {
        key: 'vxn_le_22',
        passed: vxnOk,
        label_en: 'VXN <= 22',
        label_zh: 'VXN <= 22 低波门控',
        current_value: vxn.toFixed(2),
        reading: vxn.toFixed(2),
      },
      {
        key: 'ad_below_50dma',
        passed: adBelow,
        label_en: 'AD Line < 50DMA',
        label_zh: 'AD Line < 50DMA',
        current_value: adSpreadStr,
        reading: adSpreadStr,
      },
      {
        key: 'crisis_lights_ge_4',
        passed: lightsOk,
        label_en: 'Crisis Lights >= 4',
        label_zh: '危机灯 >= 4 盏',
        current_value: `${sc} / 6`,
        reading: `${sc} / 6`,
      },
      {
        key: 'vix_ratio_ge_110_tp',
        passed: tpOk,
        label_en: 'VIX/VIX3M >= 1.10 TP',
        label_zh: 'VIX/VIX3M >= 1.10 止盈',
        current_value: vr.toFixed(3),
        reading: vr.toFixed(3),
      },
    ],
  };
}

function extendLiveBars(baseData, extraDailyBars, requestedAsOf) {
  const baseSeries = baseData.daily_series;
  const lastBase = baseSeries[baseSeries.length - 1];
  const fresh = (extraDailyBars ?? [])
    .filter(b => isIsoDate(b.date) && b.date > lastBase.date && b.date <= requestedAsOf && Number(b.qqqClose) > 0)
    .sort((a, b) => a.date.localeCompare(b.date));
  if (!fresh.length) return null;

  const series = baseSeries.slice();

  for (const b of fresh) {
    const prev = series[series.length - 1];
    const cl = Number(b.qqqClose);
    const prevCl = Number(prev.qqq_close);
    const qqqRet = prevCl > 0 ? cl / prevCl - 1 : 0;
    const runAth = Math.max(Number(prev.running_ath), cl);
    const ddAthPct = (cl / runAth - 1) * 100;
    const tailCloses = series.slice(-199).map(x => Number(x.qqq_close)).concat([cl]);
    const ma200 = tailCloses.reduce((a, c) => a + c, 0) / tailCloses.length;

    const vix = Number.isFinite(b.vixClose) && b.vixClose > 0 ? Number(b.vixClose) : Number(prev.vix);
    const vix3m = Number.isFinite(b.vix3mClose) && b.vix3mClose > 0 ? Number(b.vix3mClose) : Number(prev.vix3m);
    const vr = vix3m > 0 ? vix / vix3m : Number(prev.vix_ratio);
    const vxn = Number.isFinite(b.vxnClose) && b.vxnClose > 0 ? Number(b.vxnClose) : Number(prev.vxn);

    const nextRow = {
      ...prev,
      date: b.date,
      qqq_close: r2(cl),
      qqq_ma200: r2(ma200),
      running_ath: r2(runAth),
      dd_ath_pct: r2(ddAthPct),
      nav_m7g: r2(Number(prev.nav_m7g ?? prev.nav_bh) * (1 + qqqRet)),
      nav_m7: r2(Number(prev.nav_m7 ?? prev.nav_bh) * (1 + qqqRet)),
      nav_bh: r2(Number(prev.nav_bh) * (1 + qqqRet)),
      nav_u1: r2(Number(prev.nav_u1) * (1 + qqqRet)),
      nav_b1c: r2(Number(prev.nav_b1c) * (1 + qqqRet)),
      nav_d2: r2(Number(prev.nav_d2) * (1 + qqqRet)),
      nav_h2: r2(Number(prev.nav_h2) * (1 + qqqRet)),
      nav_cc: r2(Number(prev.nav_cc ?? prev.nav_bh) * (1 + qqqRet)),
      vix: r2(vix),
      vix3m: r2(vix3m),
      vix_ratio: r3(vr),
      vxn: r2(vxn),
    };
    series.push(nextRow);
  }
  return series;
}

function extractExtraBarsFromFeed(liveM7Feed) {
  const qqqMap = liveM7Feed?.yahoo?.QQQ;
  if (!qqqMap || typeof qqqMap.keys !== 'function') return null;
  const vixMap = liveM7Feed?.yahoo?.VIX;
  const vix3mMap = liveM7Feed?.yahoo?.VIX3M;
  const vxnMap = liveM7Feed?.yahoo?.VXN;
  const dates = [...qqqMap.keys()].sort();
  return dates.map(d => ({
    date: d,
    qqqOpen: qqqMap.get(d)?.open ?? qqqMap.get(d)?.close,
    qqqClose: qqqMap.get(d)?.close,
    vixClose: vixMap?.get(d)?.close ?? null,
    vix3mClose: vix3mMap?.get(d)?.close ?? null,
    vxnClose: vxnMap?.get(d)?.close ?? null,
  }));
}

function parseM0EnabledParam(val, rawData) {
  if (val === null || val === undefined || val === '') {
    return Boolean(rawData.default_m0_enabled ?? true);
  }
  if (typeof val === 'boolean') return val;
  const s = String(val).trim().toLowerCase();
  if (['1', 'true', 'on', 'yes', 'm0on'].includes(s)) return true;
  if (['0', 'false', 'off', 'no', 'm0off'].includes(s)) return false;
  fail('invalid_crisis_observatory_m0_enabled', 400);
}

function maskSimpleOptionLedgerAtCutoff(ledger, asOfDate) {
  const out = [];
  for (const leg of ledger ?? []) {
    if (leg.entry_date > asOfDate) continue;
    if (leg.exit_date && leg.exit_date <= asOfDate && !leg.is_open_live) {
      out.push(leg);
    } else {
      out.push({
        ...leg,
        exit_date: null,
        exit_spot: null,
        exit_cost_usd: null,
        net_pnl_usd: null,
        stock_gain_usd: null,
        is_open_live: true,
        exit_reason: 'open_as_of_cutoff',
      });
    }
  }
  return out;
}

function buildCutoffSpState(
  slicedSeries,
  spMode,
  wcMode,
  maskedSpLedger,
  baseSpState,
  artifactAsOfDate = null,
) {
  const lastBar = slicedSeries[slicedSeries.length - 1];
  const prevBar = slicedSeries.length >= 2 ? slicedSeries[slicedSeries.length - 2] : lastBar;
  const effDate = lastBar.date;
  const spotCl = Number(lastBar.qqq_close ?? 0);
  const vix = Number(lastBar.vix ?? 0);
  const prevVix = Number(prevBar.vix ?? vix);
  const vixChg = vix - prevVix;
  const vixFalling = slicedSeries.length >= 2 && vix < prevVix;
  const vix3m = Number(lastBar.vix3m ?? 0);
  const vr = Number(lastBar.vix_ratio ?? 0);
  const invOn = vr >= 1.0;
  const unfGate = invOn;
  const vixfGate = Boolean(invOn && vixFalling);
  const enabled = spMode !== 'sp_off';
  const reqFall = spMode === 'sp_10d_vixf';
  const modeGate = reqFall ? vixfGate : unfGate;
  const dteLbl = spMode === 'sp_10d_vixf' ? '10D' : '14D';
  const effWcMode = wcMode || 'wc_reclaim_30d_d35';
  const isReclaim30d = effWcMode === 'wc_reclaim_30d_d35';
  const wcDteLbl = isReclaim30d || effWcMode === 'wc_30d_c5s5' ? '30D' : dteLbl;
  const wcFormulaZh = isReclaim30d
    ? '涨回接货价后卖 30D 0.35Δ'
    : effWcMode === 'wc_30d_c5s5'
      ? 'max(1.05×成本, 1.05×现价)'
      : 'max(成本, 1.02×现价)';
  const wcFormulaEn = isReclaim30d
    ? 'Reclaim K_assign -> 30D 0.35Δ'
    : effWcMode === 'wc_30d_c5s5'
      ? 'max(1.05x Cost, 1.05x Spot)'
      : 'max(Cost, 1.02x Spot)';
  const capPct = spMode === 'sp_14d_cap10' ? 10 : 20;
  const estimate30dD35Strike = (spotPx, barVxn, floorK) => {
    const sigma = Math.max(Number(barVxn ?? 25) / 100, 0.12);
    // N^-1(0.65) = 0.38532 for 0.35-Delta 30-calendar-day call
    const rawK = spotPx * Math.exp(0.38532 * sigma * Math.sqrt(30 / 365));
    return Math.max(floorK, rawK);
  };

  const openSpLeg =
    enabled
      ? (maskedSpLedger ?? []).find(
          x => x.leg_type === 'short_put' && x.exit_reason === 'open_as_of_cutoff',
        ) ?? null
      : null;
  const openWcLeg =
    enabled
      ? (maskedSpLedger ?? []).find(
          x => x.leg_type === 'wheel_call' && x.exit_reason === 'open_as_of_cutoff',
        ) ?? null
      : null;

  let unclosedAssignLeg = null;
  if (enabled && !openSpLeg && !openWcLeg) {
    const calledAwayCycles = new Set(
      (maskedSpLedger ?? [])
        .filter(
          x => x.leg_type === 'wheel_call' && x.exit_reason === 'called_away' && x.exit_date <= effDate,
        )
        .map(x => x.cycle_id),
    );
    const assigns = (maskedSpLedger ?? []).filter(
      x =>
        x.leg_type === 'short_put' &&
        x.exit_reason === 'assigned_wheel' &&
        x.exit_date <= effDate &&
        !calledAwayCycles.has(x.cycle_id),
    );
    if (assigns.length > 0) {
      unclosedAssignLeg = assigns[assigns.length - 1];
    }
  }

  const chgStr = `${vixChg >= 0 ? '+' : ''}${vixChg.toFixed(2)}`;
  let positionState = 'disabled';
  let statusTone = 'neutral';
  let minNextWcStrike = null;
  let badgeEn;
  let badgeZh;
  let detailEn = baseSpState?.detail_en ?? '';
  let detailZh = baseSpState?.detail_zh ?? '';
  if (!enabled) {
    const invZh = invOn ? '倒挂满足 >=1.00' : '未倒挂 <1.00';
    const invEn = invOn ? 'Inverted >=1.00' : 'Contango <1.00';
    const dirZh = vixFalling ? `回落 ${chgStr}` : `冲高 ${chgStr}`;
    const dirEn = vixFalling ? `Falling ${chgStr}` : `Rising ${chgStr}`;
    badgeZh = `第三引擎已关闭 · 0 杠杆（VIX/3M ${vr.toFixed(3)} ${invZh} · VIX ${vix.toFixed(2)} ${dirZh}）`;
    badgeEn = `Engine 3 Off · 0 Leverage (VIX/3M ${vr.toFixed(3)} ${invEn} · VIX ${vix.toFixed(2)} ${dirEn})`;
  } else if (openWcLeg) {
    positionState = 'wheel_call_open';
    statusTone = 'wheel';
    badgeZh = `反向 Wheel 持仓中（${Math.round(Number(openWcLeg.shares))}股）· 已卖 ${wcDteLbl} Call K=$${Number(openWcLeg.strike).toFixed(2)}`;
    badgeEn = `Wheel Call Active (${Math.round(Number(openWcLeg.shares))} sh) · Short ${wcDteLbl} Call K=$${Number(openWcLeg.strike).toFixed(2)}`;
  } else if (unclosedAssignLeg) {
    const asgnSh = Number(unclosedAssignLeg.shares ?? 0);
    const asgnK = Number(unclosedAssignLeg.strike ?? 0);
    const isPostLive = artifactAsOfDate && effDate > artifactAsOfDate && effDate > unclosedAssignLeg.exit_date;
    if (isReclaim30d) {
      const postBars = slicedSeries.filter(b => b.date > unclosedAssignLeg.exit_date);
      const firstReclaimIdx = postBars.findIndex(b => Number(b.qqq_close ?? 0) >= asgnK);
      if (firstReclaimIdx === -1) {
        const gapPct = (asgnK / Math.max(spotCl, 1e-6) - 1) * 100;
        positionState = 'wheel_assigned_wait_reclaim';
        statusTone = 'wheel';
        minNextWcStrike = r2(asgnK);
        badgeZh = `已接货进 Wheel（${Math.round(asgnSh)}股 @ $${asgnK.toFixed(2)}）· 水下暂不卖 Call，等涨回 >= $${asgnK.toFixed(2)}（差 +${gapPct.toFixed(1)}%）再卖 30D 0.35Δ Call`;
        badgeEn = `Assigned into Wheel (${Math.round(asgnSh)} sh @ $${asgnK.toFixed(2)}) · Holding Uncapped until QQQ >= $${asgnK.toFixed(2)} (+${gapPct.toFixed(1)}%), then Sell 30D 0.35Δ Call`;
        detailZh = `水下阶段严禁封顶卖 Call 且禁止再卖新 Put；按 IBKR 基准利率 +1.50% 计息，100% 保留反弹斜率，待收盘涨回 >= $${asgnK.toFixed(2)} 后次日开盘卖 30D 0.35Δ Call 清债。`;
        detailEn = `No capped calls or new puts while underwater (QQQ $${spotCl.toFixed(2)} < $${asgnK.toFixed(2)}); holds 100% uncapped recovery until EOD reclaim >= $${asgnK.toFixed(2)}, then sells 30D 0.35Δ Call.`;
      } else if (firstReclaimIdx === postBars.length - 1) {
        const estKc = estimate30dD35Strike(spotCl, lastBar.vxn ?? lastBar.vix ?? 25, asgnK);
        positionState = 'wheel_assigned_wc_armed';
        statusTone = 'wheel';
        minNextWcStrike = r2(estKc);
        badgeZh = `已涨回接货价 >= $${asgnK.toFixed(2)}（${Math.round(asgnSh)}股） -> 次日开盘卖 30D 0.35Δ Wheel Call（预估 K=$${estKc.toFixed(2)}，${wcFormulaZh}）`;
        badgeEn = `Reclaimed K_assign >= $${asgnK.toFixed(2)} (${Math.round(asgnSh)} sh) -> Next Open Sell 30D 0.35Δ Wheel Call (Est. K=$${estKc.toFixed(2)}, ${wcFormulaEn})`;
        detailZh = `QQQ 收盘 $${spotCl.toFixed(2)} 已涨回接货成本 $${asgnK.toFixed(2)}，次日开盘卖出 30D 0.35Δ Covered Call（行权价约 $${estKc.toFixed(2)}）启动清债去杠杆。`;
        detailEn = `QQQ closed at $${spotCl.toFixed(2)} >= $${asgnK.toFixed(2)} cost basis; armed to sell 30D 0.35Δ Covered Call (est. K=$${estKc.toFixed(2)}) at next Open to clear margin debt.`;
      } else {
        const sellBar = postBars[firstReclaimIdx + 1] ?? lastBar;
        const openPxEst = Number(sellBar.qqq_close ?? spotCl);
        const estKc = estimate30dD35Strike(openPxEst, sellBar.vxn ?? sellBar.vix ?? 25, asgnK);
        positionState = 'wheel_call_open';
        statusTone = 'wheel';
        minNextWcStrike = r2(estKc);
        badgeZh = `反向 Wheel 持仓中（${Math.round(asgnSh)}股 @ $${asgnK.toFixed(2)}）· 已卖 30D 0.35Δ Call K=$${estKc.toFixed(2)}（${wcFormulaZh}）`;
        badgeEn = `Wheel Call Active (${Math.round(asgnSh)} sh @ $${asgnK.toFixed(2)}) · Short 30D 0.35Δ Call K=$${estKc.toFixed(2)} (${wcFormulaEn})`;
        detailZh = `已在涨回 $${asgnK.toFixed(2)} 后卖出 30D 0.35Δ Call（K=$${estKc.toFixed(2)}）；到期若 QQQ 高于行权价即自动被 Call 走清零融资负债。`;
        detailEn = `Sold 30D 0.35Δ Call (K=$${estKc.toFixed(2)}) after reclaiming $${asgnK.toFixed(2)}; assigned stock clears margin debt if QQQ closes above strike at expiry.`;
      }
    } else if (isPostLive) {
      const firstPostBar =
        slicedSeries.find(b => b.date > unclosedAssignLeg.exit_date) ?? lastBar;
      const openPxEst = Number(firstPostBar.qqq_close ?? spotCl);
      const estKc =
        effWcMode === 'wc_30d_c5s5'
          ? Math.max(asgnK * 1.05, openPxEst * 1.05)
          : Math.max(asgnK, openPxEst * 1.02);
      positionState = 'wheel_call_open';
      statusTone = 'wheel';
      minNextWcStrike = r2(estKc);
      badgeZh = `反向 Wheel 持仓中（${Math.round(asgnSh)}股 @ $${asgnK.toFixed(2)}）· 已卖 ${wcDteLbl} Call K=$${estKc.toFixed(2)}（${wcFormulaZh}）`;
      badgeEn = `Wheel Call Active (${Math.round(asgnSh)} sh @ $${asgnK.toFixed(2)}) · Short ${wcDteLbl} Call K=$${estKc.toFixed(2)} (${wcFormulaEn})`;
    } else {
      const minKc =
        effWcMode === 'wc_30d_c5s5'
          ? Math.max(asgnK * 1.05, spotCl * 1.05)
          : Math.max(asgnK, spotCl * 1.02);
      positionState = 'wheel_assigned_wc_armed';
      statusTone = 'wheel';
      minNextWcStrike = r2(minKc);
      badgeZh = `已接货进 Wheel（${Math.round(asgnSh)}股 @ $${asgnK.toFixed(2)}） -> 次日开盘卖 ${wcDteLbl} Wheel Call（K >= $${minKc.toFixed(2)}，${wcFormulaZh}）`;
      badgeEn = `Assigned into Wheel (${Math.round(asgnSh)} sh @ $${asgnK.toFixed(2)}) -> Next Open Sell ${wcDteLbl} Wheel Call (K >= $${minKc.toFixed(2)}, ${wcFormulaEn})`;
    }
  } else if (openSpLeg) {
    positionState = 'short_put_open';
    statusTone = 'active';
    badgeZh = `持仓 ${dteLbl} 恐慌卖 Put（K=$${Number(openSpLeg.strike).toFixed(2)} · ${Math.round(Number(openSpLeg.shares))}股）`;
    badgeEn = `Live ${dteLbl} Short Put Open (K=$${Number(openSpLeg.strike).toFixed(2)} · ${Math.round(Number(openSpLeg.shares))} sh)`;
  } else if (modeGate) {
    positionState = 'entry_armed_next_open';
    statusTone = 'armed';
    badgeZh = `信号触发 -> 次日开盘卖 ${dteLbl} 5% OTM Put（名义帽 <= ${capPct}% · VIX/3M ${vr.toFixed(3)}）`;
    badgeEn = `Signal Triggered -> Sell ${dteLbl} 5% OTM Put Next Open (<= ${capPct}% Cap · VIX/3M ${vr.toFixed(3)})`;
  } else {
    positionState = 'flat_standby';
    statusTone = 'neutral';
    badgeZh =
      invOn && reqFall && !vixFalling
        ? `空仓等待恐慌拐点 · VIX/3M ${vr.toFixed(3)} 已倒挂但 VIX ${chgStr} 未回落`
        : `空仓待命 · 0 持仓 0 利息（VIX/3M ${vr.toFixed(3)} 未倒挂）`;
    badgeEn =
      invOn && reqFall && !vixFalling
        ? `Flat · Waiting for VIX Crest (VIX/3M ${vr.toFixed(3)} >= 1.00, VIX ${chgStr} Rising)`
        : `Flat Standby · 0 Margin Debt (VIX/3M ${vr.toFixed(3)} < 1.00)`;
  }

  return {
    ...(baseSpState ?? {}),
    as_of_date: lastBar.date,
    sp_mode: spMode,
    wc_mode: effWcMode,
    enabled,
    vix: r2(vix),
    prev_vix: r2(prevVix),
    vix_change: r2(vixChg),
    vix_falling: vixFalling,
    vix3m: r2(vix3m),
    vix_vix3m_ratio: r3(vr),
    backwardation_active: invOn,
    unfiltered_signal_on: unfGate,
    vix_falling_signal_on: vixfGate,
    mode_entry_gate_met: modeGate,
    position_state: positionState,
    status_tone: statusTone,
    min_next_wc_strike: minNextWcStrike,
    badge_en: badgeEn,
    badge_zh: badgeZh,
    detail_en: detailEn,
    detail_zh: detailZh,
  };
}

export function loadCrisisObservatoryDashboard({
  asOf = null,
  strategy = null,
  putOtm = null,
  m7TpMode = null,
  rollMode = null,
  m0Enabled = null,
  tpMode = null,
  ccMode = null,
  spMode = null,
  wcMode = null,
  snapshotId: expectedSnapshotId = null,
  file = defaultFile,
  extraDailyBars = null,
  liveM7Feed = null,
} = {}) {
  const { data: rawData, snapshotId } = readArtifact(file);
  if (expectedSnapshotId && expectedSnapshotId !== snapshotId) {
    fail('crisis_observatory_snapshot_changed', 409);
  }

  const requestedPutOtm = putOtm ? String(putOtm).trim() : rawData.default_put_otm ?? 'otm15';
  const rawPutOtm = PUT_OTM_ALIASES[requestedPutOtm] ?? requestedPutOtm;
  if (!CRISIS_OBSERVATORY_PUT_OTMS.includes(rawPutOtm)) {
    fail('invalid_crisis_observatory_put_otm', 400);
  }

  let rawTpMode = rawData.default_tp_mode ?? 'layered_itm';
  let inferredM7TpFromTpMode = null;
  if (tpMode) {
    const trimmedTp = String(tpMode).trim();
    const mappedM7Tp = M7_TP_ALIASES[trimmedTp] ?? trimmedTp;
    if (CRISIS_OBSERVATORY_TP_MODES.includes(trimmedTp)) {
      rawTpMode = trimmedTp;
    } else if (!m7TpMode && CRISIS_OBSERVATORY_M7_TP_MODES.includes(mappedM7Tp)) {
      inferredM7TpFromTpMode = mappedM7Tp;
    } else {
      fail('invalid_crisis_observatory_tp_mode', 400);
    }
  }

  const requestedM7Tp = m7TpMode
    ? String(m7TpMode).trim()
    : inferredM7TpFromTpMode ?? rawData.default_m7_tp_mode ?? 'standard';
  const rawM7TpMode = M7_TP_ALIASES[requestedM7Tp] ?? requestedM7Tp;
  if (!CRISIS_OBSERVATORY_M7_TP_MODES.includes(rawM7TpMode)) {
    fail('invalid_crisis_observatory_m7_tp_mode', 400);
  }

  const requestedRollMode = rollMode ? String(rollMode).trim() : rawData.default_roll_mode ?? '120d_roll50';
  const rawRollMode = ROLL_MODE_ALIASES[requestedRollMode] ?? requestedRollMode;
  if (!CRISIS_OBSERVATORY_ROLL_MODES.includes(rawRollMode)) {
    fail('invalid_crisis_observatory_roll_mode', 400);
  }

  const rawM0Enabled = parseM0EnabledParam(m0Enabled, rawData);

  const requestedCcMode = ccMode ? String(ccMode).trim() : rawData.default_cc_mode ?? 'cc_off';
  const rawCcMode = LEGACY_CC_MODE_ALIASES[requestedCcMode] ?? requestedCcMode;
  if (!CRISIS_OBSERVATORY_CC_MODES.includes(rawCcMode)) {
    fail('invalid_crisis_observatory_cc_mode', 400);
  }
  const requestedSpMode = spMode ? String(spMode).trim() : rawData.default_sp_mode ?? 'sp_off';
  const rawSpMode = LEGACY_SP_MODE_ALIASES[requestedSpMode] ?? requestedSpMode;
  if (!CRISIS_OBSERVATORY_SP_MODES.includes(rawSpMode)) {
    fail('invalid_crisis_observatory_sp_mode', 400);
  }
  const requestedWcMode = wcMode ? String(wcMode).trim() : rawData.default_wc_mode ?? 'wc_reclaim_30d_d35';
  const rawWcMode = LEGACY_WC_MODE_ALIASES[requestedWcMode] ?? requestedWcMode;
  if (!CRISIS_OBSERVATORY_WC_MODES.includes(rawWcMode)) {
    fail('invalid_crisis_observatory_wc_mode', 400);
  }

  const data = projectArtifactForModes(
    rawData,
    snapshotId,
    rawTpMode,
    rawCcMode,
    rawSpMode,
    rawWcMode,
    rawPutOtm,
    rawM7TpMode,
    rawRollMode,
    rawM0Enabled,
  );

  const rawStrategy = strategy
    ? String(strategy).trim()
    : data.default_strategy_id ?? 'M7G_Graded';
  const selectedStrategy = LEGACY_STRATEGY_ALIASES[rawStrategy] ?? rawStrategy;
  if (!CRISIS_OBSERVATORY_STRATEGIES.includes(selectedStrategy)) {
    fail('invalid_crisis_observatory_strategy', 400);
  }

  const requestedAsOf = asOf ? String(asOf).trim() : data.as_of_date;
  if (!isIsoDate(requestedAsOf)) fail('invalid_as_of_date', 400);

  const effectiveFeed =
    liveM7Feed ??
    (Array.isArray(extraDailyBars) && extraDailyBars.length > 0
      ? normalizeLegacyExtraBarsToFeed(extraDailyBars)
      : null);
  const effectiveExtraBars =
    Array.isArray(extraDailyBars) && extraDailyBars.length > 0
      ? extraDailyBars
      : effectiveFeed
        ? extractExtraBarsFromFeed(effectiveFeed)
        : null;

  const extendedSeries =
    requestedAsOf > data.as_of_date && Array.isArray(effectiveExtraBars) && effectiveExtraBars.length > 0
      ? extendLiveBars(data, effectiveExtraBars, requestedAsOf)
      : null;

  const extendedM7 =
    requestedAsOf > data.as_of_date && effectiveFeed
      ? extendM7LiveFromFeed(rawData, effectiveFeed, requestedAsOf)
      : null;

  const m7TargetStrat = selectedStrategy === 'M7_Ensemble' ? 'M7_Ensemble' : 'M7G_Graded';

  // Fast path: exact audited snapshot when requestedAsOf >= artifact.as_of_date and no live tail
  if (!extendedSeries && !extendedM7 && requestedAsOf >= data.as_of_date) {
    const ledgerStrategy = selectedStrategy === 'BH_Pure_QQQ' ? 'M7G_Graded' : selectedStrategy;
    return {
      ...data,
      version: CRISIS_OBSERVATORY_VERSION,
      snapshotId,
      requestedAsOf,
      liveExtended: false,
      selected_strategy_id: selectedStrategy,
      put_otm: rawPutOtm,
      m7_tp_mode: rawM7TpMode,
      roll_mode: rawRollMode,
      m0_enabled: rawM0Enabled,
      tp_mode: rawTpMode,
      cc_mode: rawCcMode,
      sp_mode: rawSpMode,
      wc_mode: rawWcMode,
      m7_live_dashboard:
        data.m7_live_dashboards_by_strategy?.[m7TargetStrat] ?? data.m7_live_dashboard ?? null,
      live_signal_state:
        data.live_signal_states_by_strategy?.[ledgerStrategy] ?? data.live_signal_state,
      live_sp_state:
        data.live_sp_states_by_strategy?.[ledgerStrategy] ?? data.live_sp_state ?? null,
      events: data.events_by_strategy?.[ledgerStrategy] ?? data.events,
      trade_ledger: data.trade_ledgers_by_strategy?.[ledgerStrategy] ?? data.trade_ledger,
      sp_ledger: data.sp_ledgers_by_strategy?.[ledgerStrategy] ?? [],
    };
  }

  let sourceSeries = extendedSeries ?? data.daily_series;
  let liveM7SimOverrides = null;

  if (extendedM7 && Array.isArray(sourceSeries) && sourceSeries.length > data.daily_series.length) {
    const coeffs = rawData.opra_90dte_poly3_coeffs_desc ?? [];
    const sigSeriesLive = rawM0Enabled ? extendedM7.sigM0On : extendedM7.sigM0Off;
    const simM7g = simulateM7StrategyJS(extendedM7.evalBars, coeffs, 'M7G_Graded', sigSeriesLive, {
      putOtm: rawPutOtm,
      m7TpMode: rawM7TpMode,
      rollMode: rawRollMode,
      m0Enabled: rawM0Enabled,
      ccMode: rawCcMode,
      spMode: rawSpMode,
      wcMode: rawWcMode,
    });
    const simM7 = simulateM7StrategyJS(extendedM7.evalBars, coeffs, 'M7_Ensemble', sigSeriesLive, {
      putOtm: rawPutOtm,
      m7TpMode: rawM7TpMode,
      rollMode: rawRollMode,
      m0Enabled: rawM0Enabled,
      ccMode: rawCcMode,
      spMode: rawSpMode,
      wcMode: rawWcMode,
    });
    const lastEvalLive = extendedM7.evalBars[extendedM7.evalBars.length - 1];
    const lastSigLive = sigSeriesLive[sigSeriesLive.length - 1];
    const lastFeatLive = extendedM7.featRows[extendedM7.featRows.length - 1] ?? {};
    const dashM7g = buildM7LiveDashboardJS(lastEvalLive, lastSigLive, lastFeatLive, simM7g, coeffs, {
      putOtm: rawPutOtm,
      m7TpMode: rawM7TpMode,
      rollMode: rawRollMode,
      m0Enabled: rawM0Enabled,
    });
    const dashM7 = buildM7LiveDashboardJS(lastEvalLive, lastSigLive, lastFeatLive, simM7, coeffs, {
      putOtm: rawPutOtm,
      m7TpMode: rawM7TpMode,
      rollMode: rawRollMode,
      m0Enabled: rawM0Enabled,
    });

    const sigByDate = new Map(sigSeriesLive.map((s, idx) => [s.date, { s, idx }]));
    sourceSeries = sourceSeries.map(row => {
      const hit = sigByDate.get(row.date);
      if (!hit || row.date <= data.as_of_date) return row;
      const { s, idx } = hit;
      return {
        ...row,
        nav_m7g: r2(simM7g.nav[idx]),
        nav_m7: r2(simM7.nav[idx]),
        m7_prob: Math.round(Number(s.crisis_prob ?? 0)),
        m7_p1: Math.round(Number(s.p1 ?? 0)),
        m7_p2: Math.round(Number(s.p2 ?? 0)),
        m7_p3: Math.round(Number(s.p3 ?? 0)),
        m7_target_slots: Number(s.target_slots_m7g ?? 0),
        m7_active_slots: Number(simM7g.active_slots[idx] ?? 0),
        m7_mask: Number(s.mask ?? 0),
        hmm_p: r3(Number(s.hmm_p ?? 0)),
      };
    });

    liveM7SimOverrides = {
      sims: { M7G_Graded: simM7g, M7_Ensemble: simM7 },
      dashboards: { M7G_Graded: dashM7g, M7_Ensemble: dashM7 },
    };
  }

  const slicedSeries = sourceSeries.filter(row => row.date <= requestedAsOf);
  if (!slicedSeries.length) {
    fail('as_of_before_evaluation_window', 400);
  }

  const effDate = slicedSeries[slicedSeries.length - 1].date;
  const lastBar = slicedSeries[slicedSeries.length - 1];
  const prevBar = slicedSeries.length >= 2 ? slicedSeries[slicedSeries.length - 2] : lastBar;
  const bhEndNav = Number(lastBar.nav_bh);
  const isPostArtifactLive = effDate > data.as_of_date;

  const maskedLedgersByStrategy = {};
  for (const [sid, led] of Object.entries(data.trade_ledgers_by_strategy ?? {})) {
    if (liveM7SimOverrides?.sims?.[sid]) {
      maskedLedgersByStrategy[sid] = liveM7SimOverrides.sims[sid].ledger;
    } else {
      maskedLedgersByStrategy[sid] = maskLedgerAtCutoff(led, effDate);
    }
  }

  const maskedCcLedgersByStrategy = {};
  for (const [sid, led] of Object.entries(data.cc_ledgers_by_strategy ?? {})) {
    if (liveM7SimOverrides?.sims?.[sid]) {
      maskedCcLedgersByStrategy[sid] = liveM7SimOverrides.sims[sid].cc_ledger;
    } else {
      maskedCcLedgersByStrategy[sid] = maskSimpleOptionLedgerAtCutoff(led, effDate);
    }
  }

  const maskedSpLedgersByStrategy = {};
  for (const [sid, led] of Object.entries(data.sp_ledgers_by_strategy ?? {})) {
    if (liveM7SimOverrides?.sims?.[sid]) {
      maskedSpLedgersByStrategy[sid] = maskSimpleOptionLedgerAtCutoff(
        liveM7SimOverrides.sims[sid].sp_ledger,
        effDate,
      );
    } else {
      maskedSpLedgersByStrategy[sid] = maskSimpleOptionLedgerAtCutoff(led, effDate);
    }
  }

  const slicedEventsByStrategy = {};
  for (const [sid, evs] of Object.entries(data.events_by_strategy ?? {})) {
    if (liveM7SimOverrides?.sims?.[sid]) {
      slicedEventsByStrategy[sid] = synthesizeUnifiedEvents(sid, liveM7SimOverrides.sims[sid].ledger);
    } else if (effDate < data.as_of_date && (sid === 'M7G_Graded' || sid === 'M7_Ensemble')) {
      slicedEventsByStrategy[sid] = synthesizeUnifiedEvents(sid, maskedLedgersByStrategy[sid]);
    } else {
      slicedEventsByStrategy[sid] = (evs ?? []).filter(e => e.date <= effDate);
    }
  }

  const strategiesSummary = data.strategies_summary.map(item => {
    if (liveM7SimOverrides?.sims?.[item.id]) {
      return {
        ...item,
        ...liveM7SimOverrides.sims[item.id].summary,
      };
    }
    const navKey = STRATEGY_NAV_KEYS[item.id];
    const metrics = computeSeriesMetrics(slicedSeries, navKey, bhEndNav);
    const maskedLed = maskedLedgersByStrategy[item.id] ?? [];
    return {
      ...item,
      ...(metrics ?? {}),
      tranche_count: maskedLed.length,
    };
  });

  // Leak-free historical cutoff M7 live dashboard reconstruction when effDate < artifact.as_of_date
  let cutoffM7Dashboards = liveM7SimOverrides?.dashboards ?? data.m7_live_dashboards_by_strategy ?? {};
  if (!isPostArtifactLive && effDate < data.as_of_date) {
    const { evalBars, sigM0On, sigM0Off, featRows, dateToIdx, coeffs } = getUnpackedM7Tables(rawData);
    const cutIdx = dateToIdx.get(effDate);
    if (cutIdx !== undefined && cutIdx >= 0) {
      const subEval = evalBars.slice(0, cutIdx + 1);
      const subSig = (rawM0Enabled ? sigM0On : sigM0Off).slice(0, cutIdx + 1);
      const featAtCut = featRows[cutIdx] ?? {};
      const rebuilt = {};
      for (const sid of ['M7G_Graded', 'M7_Ensemble']) {
        const subSim = simulateM7StrategyJS(subEval, coeffs, sid, subSig, {
          putOtm: rawPutOtm,
          m7TpMode: rawM7TpMode,
          rollMode: rawRollMode,
          m0Enabled: rawM0Enabled,
          ccMode: rawCcMode,
          spMode: rawSpMode,
          wcMode: rawWcMode,
        });
        rebuilt[sid] = buildM7LiveDashboardJS(
          subEval[cutIdx],
          subSig[cutIdx],
          featAtCut,
          subSim,
          coeffs,
          {
            putOtm: rawPutOtm,
            m7TpMode: rawM7TpMode,
            rollMode: rawRollMode,
            m0Enabled: rawM0Enabled,
          },
        );
      }
      cutoffM7Dashboards = rebuilt;
    }
  }

  const openTranchesForStrat = sid =>
    liveM7SimOverrides?.sims?.[sid]
      ? liveM7SimOverrides.sims[sid].active_tranches_eod ?? []
      : (maskedLedgersByStrategy[sid] ?? []).filter(
          t => t.exit_date === null && !(isPostArtifactLive && t.is_open_live && t.pending_tp),
        );
  const cutoffStatesByStrategy = {};
  const cutoffSpStatesByStrategy = {};
  for (const sid of Object.keys(maskedLedgersByStrategy)) {
    const baseSt = data.live_signal_states_by_strategy?.[sid] ?? data.live_signal_state;
    cutoffStatesByStrategy[sid] = buildCutoffSignalState(lastBar, openTranchesForStrat(sid), baseSt);
    const baseSpSt = data.live_sp_states_by_strategy?.[sid] ?? data.live_sp_state;
    cutoffSpStatesByStrategy[sid] = buildCutoffSpState(
      slicedSeries,
      rawSpMode,
      rawWcMode,
      maskedSpLedgersByStrategy[sid] ?? [],
      baseSpSt,
      data.as_of_date,
    );
  }
  const openU1Tranches = openTranchesForStrat('U1_PureOptions');
  const maskBits = Number(lastBar.lights_mask ?? 0);
  const lightsAtCutoff = data.six_crisis_lights.map((light, idx) => ({
    ...light,
    lit: effDate === data.as_of_date ? light.lit : Boolean((maskBits >> idx) & 1),
  }));

  let streakBelow50 = 0;
  for (let i = slicedSeries.length - 1; i >= 0; i -= 1) {
    if (Number(slicedSeries[i].ad_line) < Number(slicedSeries[i].ad_sma50)) streakBelow50 += 1;
    else break;
  }

  const adBelow = Number(lastBar.ad_line) < Number(lastBar.ad_sma50);
  const athOk = Number(lastBar.dd_ath_pct) >= -5.0;
  const adSignal =
    effDate === data.as_of_date
      ? data.ad_line_signal
      : {
          ...data.ad_line_signal,
          ad_line: lastBar.ad_line,
          ad_sma50: lastBar.ad_sma50,
          spread_vs_50ma: lastBar.ad_vs_50ma,
          below_50ma: adBelow,
          days_below_50ma: streakBelow50,
          pct_above_200d: lastBar.pct_200d,
          top_divergence_active: Boolean(athOk && adBelow),
          last_top_divergence_date:
            data.ad_line_signal?.last_top_divergence_date &&
            data.ad_line_signal.last_top_divergence_date <= effDate
              ? data.ad_line_signal.last_top_divergence_date
              : '',
          status_en:
            athOk && adBelow
              ? 'TOP DIVERGENCE ACTIVE (ATH<=5% & AD<50DMA)'
              : adBelow
                ? 'BREADTH BREAKDOWN (AD < 50DMA)'
                : 'HEALTHY BREADTH (AD >= 50DMA)',
          status_zh:
            athOk && adBelow
              ? '高位顶背离亮灯（距ATH<=5% 且 AD<50DMA）'
              : adBelow
                ? '市场宽度破位（AD 位于 50DMA 下方）'
                : '市场宽度健康（AD 站上 50DMA）',
        };

  const vixNow = Number(lastBar.vix ?? 0);
  const vixPrev = Number(prevBar.vix ?? vixNow);
  const liveSnap = {
    ...data.live_market_snapshot,
    as_of_date: effDate,
    qqq_close: lastBar.qqq_close,
    running_ath: lastBar.running_ath,
    dd_from_ath_pct: lastBar.dd_ath_pct,
    qqq_ma200: lastBar.qqq_ma200,
    qqq_vs_200ma_pct:
      Number(lastBar.qqq_ma200) > 0
        ? r2((Number(lastBar.qqq_close) / Number(lastBar.qqq_ma200) - 1) * 100)
        : 0,
    vix: lastBar.vix,
    prev_vix: r2(vixPrev),
    vix_change: r2(vixNow - vixPrev),
    vix_falling: slicedSeries.length >= 2 && vixNow < vixPrev,
    vix3m: lastBar.vix3m,
    vix_vix3m_ratio: lastBar.vix_ratio,
    vxn: lastBar.vxn,
    raw_crisis_score: lastBar.crisis_lights,
    smooth_crisis_score_5d: lastBar.smooth_lights,
    smooth_5d_score: lastBar.smooth_lights,
  };

  const ledgerStrategy = selectedStrategy === 'BH_Pure_QQQ' ? 'M7G_Graded' : selectedStrategy;
  const visibleWindows = data.crisis_windows
    .filter(w => w.start_date <= effDate)
    .map(w => (isPostArtifactLive && w.is_live ? { ...w, end_date: effDate } : w));
  const artifactLastBh = Number(rawData.daily_series?.[rawData.daily_series.length - 1]?.nav_bh ?? 0);
  const liveScale =
    isPostArtifactLive && artifactLastBh > 0 ? Number(lastBar.nav_bh) / artifactLastBh : 1.0;
  const cutoffEngineAttribution = buildEngineAttributionByStrategy(
    rawData,
    snapshotId,
    rawTpMode,
    rawCcMode,
    rawSpMode,
    rawWcMode,
    {
      putOtm: rawPutOtm,
      m7TpMode: rawM7TpMode,
      rollMode: rawRollMode,
      m0Enabled: rawM0Enabled,
      ...(isPostArtifactLive ? { liveScale } : { cutoffSeries: slicedSeries }),
    },
  );

  return {
    ...data,
    version: CRISIS_OBSERVATORY_VERSION,
    snapshotId,
    as_of_date: effDate,
    asOfDate: effDate,
    dataThrough: effDate,
    requestedAsOf,
    liveExtended: Boolean(extendedSeries || extendedM7),
    selected_strategy_id: selectedStrategy,
    put_otm: rawPutOtm,
    m7_tp_mode: rawM7TpMode,
    roll_mode: rawRollMode,
    m0_enabled: rawM0Enabled,
    tp_mode: rawTpMode,
    cc_mode: rawCcMode,
    sp_mode: rawSpMode,
    wc_mode: rawWcMode,
    evaluation_window: {
      ...data.evaluation_window,
      end: effDate,
      end_date: effDate,
      trading_days: slicedSeries.length,
    },
    m7_live_dashboard:
      cutoffM7Dashboards[m7TargetStrat] ?? cutoffM7Dashboards.M7G_Graded ?? data.m7_live_dashboard ?? null,
    m7_live_dashboards_by_strategy: cutoffM7Dashboards,
    live_market_snapshot: liveSnap,
    live_signal_state:
      cutoffStatesByStrategy[ledgerStrategy] ??
      buildCutoffSignalState(lastBar, openU1Tranches, data.live_signal_state),
    live_signal_states_by_strategy: cutoffStatesByStrategy,
    live_sp_state:
      cutoffSpStatesByStrategy[ledgerStrategy] ??
      buildCutoffSpState(
        slicedSeries,
        rawSpMode,
        rawWcMode,
        maskedSpLedgersByStrategy[ledgerStrategy] ?? [],
        data.live_sp_state,
        data.as_of_date,
      ),
    live_sp_states_by_strategy: cutoffSpStatesByStrategy,
    six_crisis_lights: lightsAtCutoff,
    ad_line_signal: adSignal,
    strategies_summary: strategiesSummary,
    engine_attribution_by_strategy: cutoffEngineAttribution,
    daily_series: slicedSeries,
    events: slicedEventsByStrategy[ledgerStrategy] ?? [],
    events_by_strategy: slicedEventsByStrategy,
    trade_ledger: maskedLedgersByStrategy[ledgerStrategy] ?? [],
    trade_ledgers_by_strategy: maskedLedgersByStrategy,
    cc_ledgers_by_strategy: maskedCcLedgersByStrategy,
    sp_ledger: maskedSpLedgersByStrategy[ledgerStrategy] ?? [],
    sp_ledgers_by_strategy: maskedSpLedgersByStrategy,
    shield_events: [],
    crisis_windows: visibleWindows,
  };
}

const PIT_SNAPSHOT_CACHE_MAX = 256;
const pitSnapshotCache = new Map();

function readCachedPitSnapshot(cacheKey) {
  const hit = pitSnapshotCache.get(cacheKey);
  if (!hit) return null;
  // Refresh LRU order
  pitSnapshotCache.delete(cacheKey);
  pitSnapshotCache.set(cacheKey, hit);
  return hit;
}

function writeCachedPitSnapshot(cacheKey, value) {
  if (pitSnapshotCache.has(cacheKey)) {
    pitSnapshotCache.delete(cacheKey);
  } else if (pitSnapshotCache.size >= PIT_SNAPSHOT_CACHE_MAX) {
    const oldestKey = pitSnapshotCache.keys().next().value;
    if (oldestKey !== undefined) pitSnapshotCache.delete(oldestKey);
  }
  pitSnapshotCache.set(cacheKey, value);
}

export function loadCrisisObservatoryPitSnapshot({
  date = null,
  asOf = null,
  strategy = null,
  putOtm = null,
  m7TpMode = null,
  rollMode = null,
  m0Enabled = null,
  tpMode = null,
  ccMode = null,
  spMode = null,
  wcMode = null,
  file = defaultFile,
  extraDailyBars = null,
  liveM7Feed = null,
} = {}) {
  const { data: rawData, snapshotId } = readArtifact(file);
  const rawDate = date ?? asOf ?? rawData.as_of_date;
  const targetDate = String(rawDate ?? '').trim();
  if (!isIsoDate(targetDate)) fail('invalid_pit_date', 400);

  const hasLiveTail =
    Boolean(liveM7Feed) || (Array.isArray(extraDailyBars) && extraDailyBars.length > 0);
  const cacheKey = hasLiveTail
    ? null
    : [
        snapshotId,
        targetDate,
        strategy ?? '',
        putOtm ?? '',
        m7TpMode ?? '',
        rollMode ?? '',
        m0Enabled ?? '',
        tpMode ?? '',
        ccMode ?? '',
        spMode ?? '',
        wcMode ?? '',
      ].join('|');

  if (cacheKey) {
    const cached = readCachedPitSnapshot(cacheKey);
    if (cached) return cached;
  }

  const slicedDoc = loadCrisisObservatoryDashboard({
    asOf: targetDate,
    strategy,
    putOtm,
    m7TpMode,
    rollMode,
    m0Enabled,
    tpMode,
    ccMode,
    spMode,
    wcMode,
    file,
    extraDailyBars,
    liveM7Feed,
  });

  const baseDates = (rawData.daily_series ?? []).map(r => r.date);
  let allDates = baseDates;
  if (hasLiveTail) {
    const extraDates = (
      Array.isArray(extraDailyBars) && extraDailyBars.length > 0
        ? extraDailyBars
        : extractExtraBarsFromFeed(liveM7Feed)
    )
      .map(b => b?.date)
      .filter(d => isIsoDate(d) && d > rawData.as_of_date);
    if (extraDates.length > 0) {
      allDates = [...baseDates, ...new Set(extraDates)].sort();
    }
  }

  const effDate = slicedDoc.as_of_date;
  const latestDate = allDates.length > 0 ? allDates[allDates.length - 1] : rawData.as_of_date;
  const effIdx = allDates.indexOf(effDate);
  const prevDate = effIdx > 0 ? allDates[effIdx - 1] : null;
  const nextDate = effIdx >= 0 && effIdx + 1 < allDates.length ? allDates[effIdx + 1] : null;
  const isHistoricalPit = effDate < latestDate;
  const lastBar =
    Array.isArray(slicedDoc.daily_series) && slicedDoc.daily_series.length > 0
      ? slicedDoc.daily_series[slicedDoc.daily_series.length - 1]
      : null;

  const lightsPit = (slicedDoc.six_crisis_lights ?? []).map(light => ({
    ...light,
    pit_historical: isHistoricalPit,
    ...(isHistoricalPit
      ? {
          reading_value:
            light.key === 'sig3_breadth' && lastBar && Number.isFinite(Number(lastBar.pct_200d))
              ? `${Number(lastBar.pct_200d).toFixed(1)}%`
              : light.lit
                ? 'PIT ON'
                : 'PIT OFF',
        }
      : {}),
  }));

  const payload = {
    version: CRISIS_OBSERVATORY_VERSION,
    snapshotId: slicedDoc.snapshotId,
    pit_mode: true,
    pit_date: effDate,
    requested_date: targetDate,
    latest_as_of_date: latestDate,
    is_historical_pit: isHistoricalPit,
    prev_date: prevDate,
    next_date: nextDate,
    as_of_date: effDate,
    asOfDate: effDate,
    selected_strategy_id: slicedDoc.selected_strategy_id,
    put_otm: slicedDoc.put_otm,
    m7_tp_mode: slicedDoc.m7_tp_mode,
    roll_mode: slicedDoc.roll_mode,
    m0_enabled: slicedDoc.m0_enabled,
    tp_mode: slicedDoc.tp_mode,
    cc_mode: slicedDoc.cc_mode,
    sp_mode: slicedDoc.sp_mode,
    wc_mode: slicedDoc.wc_mode,
    liveExtended: Boolean(slicedDoc.liveExtended),
    pit_bar: lastBar,
    live_market_snapshot: slicedDoc.live_market_snapshot,
    m7_live_dashboard: slicedDoc.m7_live_dashboard,
    m7_live_dashboards_by_strategy: slicedDoc.m7_live_dashboards_by_strategy,
    six_crisis_lights: lightsPit,
    ad_line_signal: slicedDoc.ad_line_signal,
    live_signal_state: slicedDoc.live_signal_state,
    live_signal_states_by_strategy: slicedDoc.live_signal_states_by_strategy,
    live_sp_state: slicedDoc.live_sp_state,
    live_sp_states_by_strategy: slicedDoc.live_sp_states_by_strategy,
    strategies_summary: slicedDoc.strategies_summary,
  };

  if (cacheKey) {
    writeCachedPitSnapshot(cacheKey, payload);
  }
  return payload;
}

export async function loadCrisisObservatoryPitSnapshotLive({
  date = null,
  asOf = null,
  strategy = null,
  putOtm = null,
  m7TpMode = null,
  rollMode = null,
  m0Enabled = null,
  tpMode = null,
  ccMode = null,
  spMode = null,
  wcMode = null,
  file = defaultFile,
  fetchLiveBars = null,
  fetchLiveM7Feed = null,
} = {}) {
  const { data } = readArtifact(file);
  const rawDate = date ?? asOf ?? data.as_of_date;
  const targetDate = String(rawDate ?? '').trim();
  if (!isIsoDate(targetDate)) fail('invalid_pit_date', 400);

  let extraDailyBars = null;
  let liveM7Feed = null;
  const liveEnabled =
    process.env.LIVE_MARKET_TAIL_ENABLED === 'true' ||
    typeof fetchLiveBars === 'function' ||
    typeof fetchLiveM7Feed === 'function';

  if (liveEnabled && targetDate > data.as_of_date) {
    try {
      if (typeof fetchLiveM7Feed === 'function') {
        liveM7Feed = await fetchLiveM7Feed();
      } else if (typeof fetchLiveBars === 'function') {
        extraDailyBars = await fetchLiveBars();
        liveM7Feed = normalizeLegacyExtraBarsToFeed(extraDailyBars);
      } else {
        liveM7Feed = await getLiveM7MarketFeed();
      }
    } catch {
      extraDailyBars = null;
      liveM7Feed = null;
    }
  }

  return loadCrisisObservatoryPitSnapshot({
    date: targetDate,
    strategy,
    putOtm,
    m7TpMode,
    rollMode,
    m0Enabled,
    tpMode,
    ccMode,
    spMode,
    wcMode,
    file,
    extraDailyBars,
    liveM7Feed,
  });
}

export async function loadCrisisObservatoryDashboardLive({
  asOf = null,
  strategy = null,
  putOtm = null,
  m7TpMode = null,
  rollMode = null,
  m0Enabled = null,
  tpMode = null,
  ccMode = null,
  spMode = null,
  wcMode = null,
  snapshotId = null,
  file = defaultFile,
  fetchLiveBars = null,
  fetchLiveM7Feed = null,
} = {}) {
  const { data } = readArtifact(file);
  const requestedAsOf = asOf ? String(asOf).trim() : new Date().toISOString().slice(0, 10);
  if (!isIsoDate(requestedAsOf)) fail('invalid_as_of_date', 400);

  let extraDailyBars = null;
  let liveM7Feed = null;
  const liveEnabled =
    process.env.LIVE_MARKET_TAIL_ENABLED === 'true' ||
    typeof fetchLiveBars === 'function' ||
    typeof fetchLiveM7Feed === 'function';

  if (liveEnabled && requestedAsOf > data.as_of_date) {
    try {
      if (typeof fetchLiveM7Feed === 'function') {
        liveM7Feed = await fetchLiveM7Feed();
      } else if (typeof fetchLiveBars === 'function') {
        extraDailyBars = await fetchLiveBars();
        liveM7Feed = normalizeLegacyExtraBarsToFeed(extraDailyBars);
      } else {
        liveM7Feed = await getLiveM7MarketFeed();
      }
    } catch {
      extraDailyBars = null;
      liveM7Feed = null;
    }
  }
  return loadCrisisObservatoryDashboard({
    asOf: requestedAsOf,
    strategy,
    putOtm,
    m7TpMode,
    rollMode,
    m0Enabled,
    tpMode,
    ccMode,
    spMode,
    wcMode,
    snapshotId,
    file,
    extraDailyBars,
    liveM7Feed,
  });
}
