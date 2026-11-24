import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const CRISIS_OBSERVATORY_VERSION = 'crisis-observatory-v2';
export const CRISIS_OBSERVATORY_STRATEGIES = Object.freeze([
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
  'wc_30d_c5s5',
  'wc_14d_c0s2',
]);

const LEGACY_SP_MODE_ALIASES = Object.freeze({
  off: 'sp_off',
  cap10: 'sp_14d_cap10',
  vixf: 'sp_10d_vixf',
  unf: 'sp_14d_unf',
});

const LEGACY_WC_MODE_ALIASES = Object.freeze({
  '30d': 'wc_30d_c5s5',
  c5s5: 'wc_30d_c5s5',
  default: 'wc_30d_c5s5',
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
  U1_PureOptions: 'nav_u1',
  B1c_PureAD: 'nav_b1c',
  D2_SixLights: 'nav_d2',
  H2_G4_PriceGate: 'nav_h2',
  NoPut_CallOnly: 'nav_cc',
  BH_Pure_QQQ: 'nav_bh',
});

const LEGACY_STRATEGY_ALIASES = Object.freeze({
  U4_DualEngine: 'U1_PureOptions',
});

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultFile = path.resolve(projectRoot, 'server/config/crisis-observatory-dashboard.json');

let cachedArtifact = null;
const projectedModeCache = new Map();
const liveFeedCache = { fetchedAt: 0, bars: null };
const LIVE_FEED_TTL_MS = 15 * 60 * 1000;

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
  option_expiry: 2,
  shield_enter: 3,
  shield_exit: 4,
  slot1_naked_put: 5,
  slot1_collar: 6,
  slot2_collar: 7,
  slot3_collar: 8,
});

function synthesizeUnifiedEvents(strategyId, ledger) {
  const events = [];
  for (const tr of ledger ?? []) {
    const isNk = tr.tranche_type === 'naked_put';
    const evType = isNk ? 'slot1_naked_put' : `slot${tr.slot_num}_collar`;
    events.push({
      event_id: `${strategyId}_tr${tr.tranche_id}_open`,
      tranche_id: tr.tranche_id,
      strategy_id: strategyId,
      date: tr.entry_date,
      signal_date: tr.signal_date,
      event_type: evType,
      slot_num: tr.slot_num,
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
    });

    const exitReason = String(tr.exit_reason ?? '');
    const isOpenLive = Boolean(tr.is_open_live);
    const isLiveArmed = exitReason === 'live_tp_armed_next_open';
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
      if (isLiveArmed) {
        evTypeExit = 'live_tp_armed';
        trigEnExit = `Deep-ITM Panic TP Armed (${tr.rem_dte_at_exit} DTE left · VIX/3M ${vrStr} · Next Open)`;
        trigZhExit = `实值恐慌止盈已触发（剩余 ${tr.rem_dte_at_exit} 天 · VIX/3M ${vrStr} · 待次日开盘换股）`;
      } else if (isPut5x) {
        evTypeExit = 'put5x_dte45_tp';
        trigEnExit = `5x Put Slow-Bear TP (${tr.rem_dte_at_exit} DTE <= 45, Deep ITM Lock)`;
        trigZhExit = `后半程 Put >= 5x 慢熊止盈（剩余 ${tr.rem_dte_at_exit} 天 <= 45 · 深实值锁利）`;
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
        evTypeExit = 'option_expiry';
        trigEnExit = `90-DTE Expiry (${retStr} spot)`;
        trigZhExit = `90-DTE 到期结算（期间正股 ${retStr}）`;
      }

      events.push({
        event_id: `${strategyId}_tr${tr.tranche_id}_exit`,
        tranche_id: tr.tranche_id,
        strategy_id: strategyId,
        date: evExitDate,
        signal_date: tr.signal_date,
        event_type: evTypeExit,
        slot_num: tr.slot_num,
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
      });
    }
  }
  events.sort((a, b) => {
    if (a.date !== b.date) return a.date < b.date ? -1 : 1;
    return (EVENT_ORDER_RANK[a.event_type] ?? 99) - (EVENT_ORDER_RANK[b.event_type] ?? 99);
  });
  return events;
}

function hydrateCrisisWindows(baseWindows, bundleWindows) {
  if (!Array.isArray(bundleWindows) || !bundleWindows.length) return baseWindows ?? [];
  const baseById = new Map((baseWindows ?? []).map(w => [w.id, w]));
  return bundleWindows.map(w => ({
    ...(baseById.get(w.id) ?? {}),
    ...w,
  }));
}

function resolveModeBundle(rawData, tpMode, ccMode, spMode = 'sp_off', wcMode = 'wc_30d_c5s5') {
  const modeBundles = rawData.mode_bundles;
  const tpModes = rawData.tp_modes;
  const effWc = wcMode || rawData.default_wc_mode || 'wc_30d_c5s5';
  const defaultWc = rawData.default_wc_mode || 'wc_30d_c5s5';
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
  selectedTpMode,
  selectedCcMode,
  selectedSpMode,
  selectedWcMode,
  { cutoffSeries = null, liveScale = 1.0 } = {},
) {
  const bE1 = resolveModeBundle(rawData, selectedTpMode, 'cc_off', 'sp_off', 'wc_30d_c5s5');
  const bE2 = resolveModeBundle(rawData, selectedTpMode, selectedCcMode, 'sp_off', 'wc_30d_c5s5');
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

  const summaryMap = bundle => {
    const list = bundle?.strategies_summary ?? rawData.strategies_summary ?? [];
    return Object.fromEntries(list.map(s => [s.id, s]));
  };
  const m1 = summaryMap(bE1);
  const m2 = summaryMap(bE2);
  const m3Solo = summaryMap(bE3Standalone);
  const mCur = summaryMap(bCur);

  const baseSeries = rawData.daily_series ?? [];
  const bhArr = baseSeries.map(r => Number(r.nav_bh ?? 0));
  const useCutoffSlice = Array.isArray(cutoffSeries) && cutoffSeries.length > 0 && cutoffSeries.length < baseSeries.length;
  const effLen = useCutoffSlice ? cutoffSeries.length : baseSeries.length;
  const bhEndCutoff = useCutoffSlice ? Number(cutoffSeries[cutoffSeries.length - 1].nav_bh ?? 0) : null;

  const navE2SoloArr = getBundleNavArray(rawData, bE2, 'nav_cc');
  const navE3SoloArr = getBundleNavArray(rawData, bE3Standalone, 'nav_cc');
  const exE2Solo = selectedCcMode !== 'cc_off' ? computeDailyExcessReturns(navE2SoloArr, bhArr, effLen) : [];
  const exE3Solo = selectedSpMode !== 'sp_off' ? computeDailyExcessReturns(navE3SoloArr, bhArr, effLen) : [];
  const corrE2E3 = exE2Solo.length && exE3Solo.length ? pearsonCorr(exE2Solo, exE3Solo) : null;

  const metricFor = (bundle, sMap, sid) => {
    const rawS = sMap[sid] ?? mCur[sid] ?? mCur.BH_Pure_QQQ ?? {};
    const navKey = STRATEGY_NAV_KEYS[sid] ?? 'nav_bh';
    if (useCutoffSlice) {
      const arr = getBundleNavArray(rawData, bundle, navKey).slice(0, effLen);
      const sliced = computeSeriesMetricsFromArray(cutoffSeries, arr, bhEndCutoff);
      return { ...rawS, ...(sliced ?? {}) };
    }
    if (liveScale !== 1.0 && Number.isFinite(liveScale) && liveScale > 0) {
      const endNav = r2(Number(rawS.end_nav ?? 0) * liveScale);
      return { ...rawS, end_nav: endNav };
    }
    return rawS;
  };

  const sBh = metricFor(bCur, mCur, 'BH_Pure_QQQ');
  const out = {};

  for (const sid of CRISIS_OBSERVATORY_STRATEGIES) {
    const hasE1 = sid !== 'NoPut_CallOnly' && sid !== 'BH_Pure_QQQ';
    const hasE2 = selectedCcMode !== 'cc_off' && sid !== 'BH_Pure_QQQ';
    const hasE3 = selectedSpMode !== 'sp_off' && sid !== 'BH_Pure_QQQ';

    const s1 = hasE1 ? metricFor(bE1, m1, sid) : sBh;
    const s2 = hasE2 ? metricFor(bE2, m2, sid) : s1;
    const s3 = hasE3 ? metricFor(bCur, mCur, sid) : s2;
    const s2Solo = hasE2 ? metricFor(bE2, m2, 'NoPut_CallOnly') : sBh;
    const s3Solo = hasE3 ? metricFor(bE3Standalone, m3Solo, 'NoPut_CallOnly') : sBh;

    const bhNav = Number(sBh.end_nav ?? 0);
    const bhSh = Number(sBh.final_shares ?? 0);
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

    const navKey = STRATEGY_NAV_KEYS[sid] ?? 'nav_u1';
    const exE1 = hasE1 ? computeDailyExcessReturns(getBundleNavArray(rawData, bE1, navKey), bhArr, effLen) : [];
    const corrE1E2 = hasE1 && hasE2 ? pearsonCorr(exE1, exE2Solo) : null;
    const corrE1E3 = hasE1 && hasE3 ? pearsonCorr(exE1, exE3Solo) : null;

    const curSummary = mCur[sid] ?? s3;
    const e1Meta = m1[sid] ?? curSummary;

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
        mode_id: hasE1 ? `${sid}::${selectedTpMode}` : 'off',
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
  selectedWcMode = 'wc_30d_c5s5',
) {
  const effectiveWcMode = selectedWcMode || 'wc_30d_c5s5';
  const cacheWcKey = selectedSpMode === 'sp_off' ? 'wc_30d_c5s5' : effectiveWcMode;
  const cacheKey = `${snapshotId}:${selectedTpMode}:${selectedCcMode}:${selectedSpMode}:${cacheWcKey}`;
  const hit = projectedModeCache.get(cacheKey);
  if (hit) return hit;

  const {
    tp_modes: tpModes,
    mode_bundles: modeBundles,
    tp_slot_series: tpSlotSeries,
    ...baseWithoutModes
  } = data;
  const bundleKey =
    selectedSpMode === 'sp_off'
      ? `${selectedTpMode}__${selectedCcMode}`
      : effectiveWcMode === 'wc_30d_c5s5'
        ? `${selectedTpMode}__${selectedCcMode}__${selectedSpMode}`
        : `${selectedTpMode}__${selectedCcMode}__${selectedSpMode}__${effectiveWcMode}`;
  const bundle =
    modeBundles?.[bundleKey] ??
    modeBundles?.[`${selectedTpMode}__${selectedCcMode}__${selectedSpMode}`] ??
    (selectedCcMode === 'cc_off' && selectedSpMode === 'sp_off' ? tpModes?.[selectedTpMode] : null);
  if (!bundle) {
    const fallback = {
      ...baseWithoutModes,
      tp_mode: data.tp_mode ?? 'layered_itm',
      default_tp_mode: data.default_tp_mode ?? 'layered_itm',
      cc_mode: data.cc_mode ?? 'cc_off',
      default_cc_mode: data.default_cc_mode ?? 'cc_off',
      sp_mode: data.sp_mode ?? 'sp_off',
      default_sp_mode: data.default_sp_mode ?? 'sp_off',
      wc_mode: effectiveWcMode,
      default_wc_mode: data.default_wc_mode ?? 'wc_30d_c5s5',
    };
    projectedModeCache.set(cacheKey, fallback);
    return fallback;
  }

  const isDefaultCombo =
    selectedTpMode === (data.default_tp_mode ?? 'layered_itm') &&
    selectedCcMode === (data.default_cc_mode ?? 'cc_off') &&
    selectedSpMode === (data.default_sp_mode ?? 'sp_off');
  const activeSlotsArr = bundle.active_slots ?? tpSlotSeries?.[selectedTpMode]?.active_slots;
  const slot1NakedArr = bundle.slot1_naked ?? tpSlotSeries?.[selectedTpMode]?.slot1_naked;
  const projectedSeries = isDefaultCombo
    ? data.daily_series
    : data.daily_series.map((row, idx) => ({
        ...row,
        nav_u1: bundle.nav_u1?.[idx] ?? row.nav_u1,
        nav_b1c: bundle.nav_b1c?.[idx] ?? row.nav_b1c,
        nav_d2: bundle.nav_d2?.[idx] ?? row.nav_d2,
        nav_h2: bundle.nav_h2?.[idx] ?? row.nav_h2,
        nav_cc: bundle.nav_cc?.[idx] ?? row.nav_cc,
        active_slots: activeSlotsArr?.[idx] ?? row.active_slots,
        slot1_naked: slot1NakedArr?.[idx] ?? row.slot1_naked,
      }));

  const unpackedTradeLedgers = bundle.trade_ledgers_by_strategy
    ? unpackLedgerMap(bundle.trade_ledgers_by_strategy)
    : data.trade_ledgers_by_strategy ?? {};
  const unpackedCcLedgers = bundle.cc_ledgers_by_strategy
    ? unpackLedgerMap(bundle.cc_ledgers_by_strategy)
    : data.cc_ledgers_by_strategy ?? {};
  const unpackedSpLedgers = bundle.sp_ledgers_by_strategy
    ? unpackLedgerMap(bundle.sp_ledgers_by_strategy)
    : data.sp_ledgers_by_strategy ?? {};

  const eventsByStrategy = {};
  for (const [sid, led] of Object.entries(unpackedTradeLedgers)) {
    eventsByStrategy[sid] =
      bundle.events_by_strategy?.[sid] ?? synthesizeUnifiedEvents(sid, led);
  }

  const hydratedWindows = hydrateCrisisWindows(data.crisis_windows, bundle.crisis_windows);
  const engineAttributionByStrategy = buildEngineAttributionByStrategy(
    data,
    selectedTpMode,
    selectedCcMode,
    selectedSpMode,
    effectiveWcMode,
  );

  const projected = {
    ...baseWithoutModes,
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
    default_wc_mode: data.default_wc_mode ?? 'wc_30d_c5s5',
    wc_modes_meta: data.wc_modes_meta ?? [],
    live_signal_state: bundle.live_signal_state ?? data.live_signal_state,
    live_signal_states_by_strategy:
      bundle.live_signal_states_by_strategy ?? data.live_signal_states_by_strategy ?? {},
    live_sp_state: bundle.live_sp_state ?? data.live_sp_state ?? null,
    live_sp_states_by_strategy:
      bundle.live_sp_states_by_strategy ?? data.live_sp_states_by_strategy ?? {},
    strategies_summary: bundle.strategies_summary ?? data.strategies_summary,
    engine_attribution_by_strategy: engineAttributionByStrategy,
    daily_series: projectedSeries,
    events: eventsByStrategy.U1_PureOptions ?? data.events,
    events_by_strategy: eventsByStrategy,
    trade_ledger: unpackedTradeLedgers.U1_PureOptions ?? data.trade_ledger,
    trade_ledgers_by_strategy: unpackedTradeLedgers,
    cc_ledgers_by_strategy: unpackedCcLedgers,
    sp_ledger: unpackedSpLedgers.U1_PureOptions ?? [],
    sp_ledgers_by_strategy: unpackedSpLedgers,
    crisis_windows: hydratedWindows,
  };
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
        exit_shares_delta: null,
        shares_added: null,
        delta_usd: null,
        gamma_usd: null,
        vega_usd: null,
        theta_slip_usd: null,
        convexity_mult: null,
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
  const effWcMode = wcMode || 'wc_30d_c5s5';
  const wcDteLbl = effWcMode === 'wc_30d_c5s5' ? '30D' : dteLbl;
  const wcFormulaZh =
    effWcMode === 'wc_30d_c5s5' ? 'max(1.05×成本, 1.05×现价)' : 'max(成本, 1.02×现价)';
  const wcFormulaEn =
    effWcMode === 'wc_30d_c5s5' ? 'max(1.05x Cost, 1.05x Spot)' : 'max(Cost, 1.02x Spot)';
  const capPct = spMode === 'sp_14d_cap10' ? 10 : 20;

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
    if (isPostLive) {
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
  };
}

export function loadCrisisObservatoryDashboard({
  asOf = null,
  strategy = null,
  tpMode = null,
  ccMode = null,
  spMode = null,
  wcMode = null,
  snapshotId: expectedSnapshotId = null,
  file = defaultFile,
  extraDailyBars = null,
} = {}) {
  const { data: rawData, snapshotId } = readArtifact(file);
  if (expectedSnapshotId && expectedSnapshotId !== snapshotId) {
    fail('crisis_observatory_snapshot_changed', 409);
  }

  const rawTpMode = tpMode ? String(tpMode).trim() : rawData.default_tp_mode ?? 'layered_itm';
  if (!CRISIS_OBSERVATORY_TP_MODES.includes(rawTpMode)) {
    fail('invalid_crisis_observatory_tp_mode', 400);
  }
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
  const requestedWcMode = wcMode ? String(wcMode).trim() : rawData.default_wc_mode ?? 'wc_30d_c5s5';
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
  );

  const rawStrategy = strategy
    ? String(strategy).trim()
    : data.default_strategy_id ?? 'U1_PureOptions';
  const selectedStrategy = LEGACY_STRATEGY_ALIASES[rawStrategy] ?? rawStrategy;
  if (!CRISIS_OBSERVATORY_STRATEGIES.includes(selectedStrategy)) {
    fail('invalid_crisis_observatory_strategy', 400);
  }

  const requestedAsOf = asOf ? String(asOf).trim() : data.as_of_date;
  if (!isIsoDate(requestedAsOf)) fail('invalid_as_of_date', 400);

  const extendedSeries =
    requestedAsOf > data.as_of_date && Array.isArray(extraDailyBars) && extraDailyBars.length > 0
      ? extendLiveBars(data, extraDailyBars, requestedAsOf)
      : null;

  // Fast path: exact audited snapshot when requestedAsOf >= artifact.as_of_date and no live tail
  if (!extendedSeries && requestedAsOf >= data.as_of_date) {
    const ledgerStrategy = selectedStrategy === 'BH_Pure_QQQ' ? 'U1_PureOptions' : selectedStrategy;
    return {
      ...data,
      version: CRISIS_OBSERVATORY_VERSION,
      snapshotId,
      requestedAsOf,
      liveExtended: false,
      selected_strategy_id: selectedStrategy,
      tp_mode: rawTpMode,
      cc_mode: rawCcMode,
      sp_mode: rawSpMode,
      wc_mode: rawWcMode,
      live_signal_state:
        data.live_signal_states_by_strategy?.[ledgerStrategy] ?? data.live_signal_state,
      live_sp_state:
        data.live_sp_states_by_strategy?.[ledgerStrategy] ?? data.live_sp_state ?? null,
      events: data.events_by_strategy?.[ledgerStrategy] ?? data.events,
      trade_ledger: data.trade_ledgers_by_strategy?.[ledgerStrategy] ?? data.trade_ledger,
      sp_ledger: data.sp_ledgers_by_strategy?.[ledgerStrategy] ?? [],
    };
  }

  const sourceSeries = extendedSeries ?? data.daily_series;
  const slicedSeries = sourceSeries.filter(row => row.date <= requestedAsOf);
  if (!slicedSeries.length) {
    fail('as_of_before_evaluation_window', 400);
  }

  const effDate = slicedSeries[slicedSeries.length - 1].date;
  const lastBar = slicedSeries[slicedSeries.length - 1];
  const prevBar = slicedSeries.length >= 2 ? slicedSeries[slicedSeries.length - 2] : lastBar;
  const bhEndNav = Number(lastBar.nav_bh);

  const strategiesSummary = data.strategies_summary.map(item => {
    const navKey = STRATEGY_NAV_KEYS[item.id];
    const metrics = computeSeriesMetrics(slicedSeries, navKey, bhEndNav);
    const rawLed = data.trade_ledgers_by_strategy?.[item.id] ?? [];
    const maskedLed = maskLedgerAtCutoff(rawLed, effDate);
    return {
      ...item,
      ...(metrics ?? {}),
      tranche_count: maskedLed.length,
    };
  });

  const maskedLedgersByStrategy = {};
  for (const [sid, led] of Object.entries(data.trade_ledgers_by_strategy ?? {})) {
    maskedLedgersByStrategy[sid] = maskLedgerAtCutoff(led, effDate);
  }

  const maskedCcLedgersByStrategy = {};
  for (const [sid, led] of Object.entries(data.cc_ledgers_by_strategy ?? {})) {
    maskedCcLedgersByStrategy[sid] = maskSimpleOptionLedgerAtCutoff(led, effDate);
  }

  const maskedSpLedgersByStrategy = {};
  for (const [sid, led] of Object.entries(data.sp_ledgers_by_strategy ?? {})) {
    maskedSpLedgersByStrategy[sid] = maskSimpleOptionLedgerAtCutoff(led, effDate);
  }

  const slicedEventsByStrategy = {};
  for (const [sid, evs] of Object.entries(data.events_by_strategy ?? {})) {
    slicedEventsByStrategy[sid] = (evs ?? []).filter(e => e.date <= effDate);
  }

  const isPostArtifactLive = effDate > data.as_of_date;
  const openTranchesForStrat = sid =>
    (maskedLedgersByStrategy[sid] ?? []).filter(
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

  const ledgerStrategy = selectedStrategy === 'BH_Pure_QQQ' ? 'U1_PureOptions' : selectedStrategy;
  const visibleWindows = data.crisis_windows.filter(w => w.start_date <= effDate);
  const artifactLastBh = Number(rawData.daily_series?.[rawData.daily_series.length - 1]?.nav_bh ?? 0);
  const liveScale =
    isPostArtifactLive && artifactLastBh > 0 ? Number(lastBar.nav_bh) / artifactLastBh : 1.0;
  const cutoffEngineAttribution = buildEngineAttributionByStrategy(
    rawData,
    rawTpMode,
    rawCcMode,
    rawSpMode,
    rawWcMode,
    isPostArtifactLive ? { liveScale } : { cutoffSeries: slicedSeries },
  );

  return {
    ...data,
    version: CRISIS_OBSERVATORY_VERSION,
    snapshotId,
    as_of_date: effDate,
    asOfDate: effDate,
    dataThrough: effDate,
    requestedAsOf,
    liveExtended: Boolean(extendedSeries),
    selected_strategy_id: selectedStrategy,
    tp_mode: rawTpMode,
    cc_mode: rawCcMode,
    sp_mode: rawSpMode,
    wc_mode: rawWcMode,
    evaluation_window: {
      ...data.evaluation_window,
      end: effDate,
      trading_days: slicedSeries.length,
    },
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

async function fetchYahooSymbol15d(symbol) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 6000);
  try {
    const enc = encodeURIComponent(symbol);
    const resp = await fetch(`https://query1.finance.yahoo.com/v8/finance/chart/${enc}?range=15d&interval=1d`, {
      headers: { 'User-Agent': 'Mozilla/5.0' },
      signal: controller.signal,
    });
    if (!resp.ok) return null;
    const json = await resp.json();
    const res0 = json?.chart?.result?.[0];
    const ts = res0?.timestamp ?? [];
    const quote = res0?.indicators?.quote?.[0] ?? {};
    const closes = quote.close ?? [];
    const out = new Map();
    for (let i = 0; i < ts.length; i += 1) {
      const c = closes[i];
      if (!Number.isFinite(c) || c <= 0) continue;
      const dt = new Date(ts[i] * 1000).toISOString().slice(0, 10);
      out.set(dt, c);
    }
    return out;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function getLiveRecentCrisisBars() {
  const now = Date.now();
  if (liveFeedCache.bars && now - liveFeedCache.fetchedAt < LIVE_FEED_TTL_MS) {
    return liveFeedCache.bars;
  }
  const [qqq, vix, vix3m, vxn] = await Promise.all([
    fetchYahooSymbol15d('QQQ'),
    fetchYahooSymbol15d('^VIX'),
    fetchYahooSymbol15d('^VIX3M'),
    fetchYahooSymbol15d('^VXN'),
  ]);
  if (!qqq) return null;
  const dates = [...qqq.keys()].sort();
  const bars = dates.map(d => ({
    date: d,
    qqqClose: qqq.get(d),
    vixClose: vix?.get(d) ?? null,
    vix3mClose: vix3m?.get(d) ?? null,
    vxnClose: vxn?.get(d) ?? null,
  }));
  liveFeedCache.fetchedAt = now;
  liveFeedCache.bars = bars;
  return bars;
}

export async function loadCrisisObservatoryDashboardLive({
  asOf = null,
  strategy = null,
  tpMode = null,
  ccMode = null,
  spMode = null,
  wcMode = null,
  snapshotId = null,
  file = defaultFile,
  fetchLiveBars = null,
} = {}) {
  const { data } = readArtifact(file);
  const requestedAsOf = asOf ? String(asOf).trim() : new Date().toISOString().slice(0, 10);
  if (!isIsoDate(requestedAsOf)) fail('invalid_as_of_date', 400);

  let extraDailyBars = null;
  const liveEnabled = process.env.LIVE_MARKET_TAIL_ENABLED === 'true' || typeof fetchLiveBars === 'function';
  if (liveEnabled && requestedAsOf > data.as_of_date) {
    try {
      extraDailyBars = await (fetchLiveBars ? fetchLiveBars() : getLiveRecentCrisisBars());
    } catch {
      extraDailyBars = null;
    }
  }
  return loadCrisisObservatoryDashboard({
    asOf: requestedAsOf,
    strategy,
    tpMode,
    ccMode,
    spMode,
    wcMode,
    snapshotId,
    file,
    extraDailyBars,
  });
}
