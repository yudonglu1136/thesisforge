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

function projectArtifactForModes(data, snapshotId, selectedTpMode, selectedCcMode) {
  const cacheKey = `${snapshotId}:${selectedTpMode}:${selectedCcMode}`;
  const hit = projectedModeCache.get(cacheKey);
  if (hit) return hit;

  const { tp_modes: tpModes, mode_bundles: modeBundles, ...baseWithoutModes } = data;
  const bundleKey = `${selectedTpMode}__${selectedCcMode}`;
  const bundle =
    modeBundles?.[bundleKey] ?? (selectedCcMode === 'cc_off' ? tpModes?.[selectedTpMode] : null);
  if (!bundle) {
    const fallback = {
      ...baseWithoutModes,
      tp_mode: data.tp_mode ?? 'layered_itm',
      default_tp_mode: data.default_tp_mode ?? 'layered_itm',
      cc_mode: data.cc_mode ?? 'cc_off',
      default_cc_mode: data.default_cc_mode ?? 'cc_off',
    };
    projectedModeCache.set(cacheKey, fallback);
    return fallback;
  }

  const isDefaultCombo =
    selectedTpMode === (data.default_tp_mode ?? 'layered_itm') &&
    selectedCcMode === (data.default_cc_mode ?? 'cc_off');
  const projectedSeries = isDefaultCombo
    ? data.daily_series
    : data.daily_series.map((row, idx) => ({
        ...row,
        nav_u1: bundle.nav_u1?.[idx] ?? row.nav_u1,
        nav_b1c: bundle.nav_b1c?.[idx] ?? row.nav_b1c,
        nav_d2: bundle.nav_d2?.[idx] ?? row.nav_d2,
        nav_h2: bundle.nav_h2?.[idx] ?? row.nav_h2,
        nav_cc: bundle.nav_cc?.[idx] ?? row.nav_cc,
        active_slots: bundle.active_slots?.[idx] ?? row.active_slots,
        slot1_naked: bundle.slot1_naked?.[idx] ?? row.slot1_naked,
      }));

  const projected = {
    ...baseWithoutModes,
    tp_mode: selectedTpMode,
    default_tp_mode: data.default_tp_mode ?? 'layered_itm',
    tp_modes_meta: data.tp_modes_meta ?? [],
    cc_mode: selectedCcMode,
    default_cc_mode: data.default_cc_mode ?? 'cc_off',
    cc_modes_meta: data.cc_modes_meta ?? [],
    live_signal_state: bundle.live_signal_state ?? data.live_signal_state,
    live_signal_states_by_strategy:
      bundle.live_signal_states_by_strategy ?? data.live_signal_states_by_strategy ?? {},
    strategies_summary: bundle.strategies_summary ?? data.strategies_summary,
    daily_series: projectedSeries,
    events: bundle.events_by_strategy?.U1_PureOptions ?? data.events,
    events_by_strategy: bundle.events_by_strategy ?? data.events_by_strategy,
    trade_ledger: bundle.trade_ledgers_by_strategy?.U1_PureOptions ?? data.trade_ledger,
    trade_ledgers_by_strategy:
      bundle.trade_ledgers_by_strategy ?? data.trade_ledgers_by_strategy,
    cc_ledgers_by_strategy:
      bundle.cc_ledgers_by_strategy ?? data.cc_ledgers_by_strategy ?? {},
    crisis_windows: bundle.crisis_windows ?? data.crisis_windows,
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

export function loadCrisisObservatoryDashboard({
  asOf = null,
  strategy = null,
  tpMode = null,
  ccMode = null,
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
  const data = projectArtifactForModes(rawData, snapshotId, rawTpMode, rawCcMode);

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
      live_signal_state:
        data.live_signal_states_by_strategy?.[ledgerStrategy] ?? data.live_signal_state,
      events: data.events_by_strategy?.[ledgerStrategy] ?? data.events,
      trade_ledger: data.trade_ledgers_by_strategy?.[ledgerStrategy] ?? data.trade_ledger,
    };
  }

  const sourceSeries = extendedSeries ?? data.daily_series;
  const slicedSeries = sourceSeries.filter(row => row.date <= requestedAsOf);
  if (!slicedSeries.length) {
    fail('as_of_before_evaluation_window', 400);
  }

  const effDate = slicedSeries[slicedSeries.length - 1].date;
  const lastBar = slicedSeries[slicedSeries.length - 1];
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
  for (const sid of Object.keys(maskedLedgersByStrategy)) {
    const baseSt = data.live_signal_states_by_strategy?.[sid] ?? data.live_signal_state;
    cutoffStatesByStrategy[sid] = buildCutoffSignalState(lastBar, openTranchesForStrat(sid), baseSt);
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
    vix3m: lastBar.vix3m,
    vix_vix3m_ratio: lastBar.vix_ratio,
    vxn: lastBar.vxn,
    raw_crisis_score: lastBar.crisis_lights,
    smooth_crisis_score_5d: lastBar.smooth_lights,
    smooth_5d_score: lastBar.smooth_lights,
  };

  const ledgerStrategy = selectedStrategy === 'BH_Pure_QQQ' ? 'U1_PureOptions' : selectedStrategy;
  const visibleWindows = data.crisis_windows.filter(w => w.start_date <= effDate);

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
    six_crisis_lights: lightsAtCutoff,
    ad_line_signal: adSignal,
    strategies_summary: strategiesSummary,
    daily_series: slicedSeries,
    events: slicedEventsByStrategy[ledgerStrategy] ?? [],
    events_by_strategy: slicedEventsByStrategy,
    trade_ledger: maskedLedgersByStrategy[ledgerStrategy] ?? [],
    trade_ledgers_by_strategy: maskedLedgersByStrategy,
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
    snapshotId,
    file,
    extraDailyBars,
  });
}
