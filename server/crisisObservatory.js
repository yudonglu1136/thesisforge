import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const CRISIS_OBSERVATORY_VERSION = 'crisis-observatory-v1';
export const CRISIS_OBSERVATORY_STRATEGIES = Object.freeze([
  'U4_DualEngine',
  'U1_PureOptions',
  'B1c_PureAD',
  'D2_SixLights',
  'H2_G4_PriceGate',
  'BH_Pure_QQQ',
]);

const STRATEGY_NAV_KEYS = Object.freeze({
  U4_DualEngine: 'nav_u4',
  U1_PureOptions: 'nav_u1',
  B1c_PureAD: 'nav_b1c',
  D2_SixLights: 'nav_d2',
  H2_G4_PriceGate: 'nav_h2',
  BH_Pure_QQQ: 'nav_bh',
});

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultFile = path.resolve(projectRoot, 'server/config/crisis-observatory-dashboard.json');

let cachedArtifact = null;
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
  cachedArtifact = {
    file,
    mtimeMs: stat.mtimeMs,
    size: stat.size,
    snapshotId,
    data: parsed,
  };
  return cachedArtifact;
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
  return {
    end_nav: r2(endNav),
    net_alpha_usd: r2(endNav - bhEndNav),
    cagr_pct: r2(cagr),
    max_dd_pct: r2(maxDd),
    sharpe: r3(sharpe),
    calmar: r3(calmar),
    final_shares: lastClose > 0 ? r2(endNav / lastClose) : null,
  };
}

function maskLedgerAtCutoff(ledger, asOfDate) {
  const out = [];
  for (const tr of ledger ?? []) {
    if (tr.entry_date > asOfDate) continue;
    if (tr.exit_date && tr.exit_date <= asOfDate) {
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

function buildCutoffSignalState(lastBar, openU4Tranches, baseSignalState) {
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
  const inShield = Boolean(lastBar.shield_active);

  const s1Open = openU4Tranches.find(t => t.slot_num === 1) ?? null;
  const s2Open = openU4Tranches.find(t => t.slot_num === 2) ?? null;

  let regimeCode = 'CRUISE_UNHEDGED';
  let titleEn = 'BULL CRUISE UNHEDGED (100% QQQ · ZERO CALL DRAG)';
  let titleZh = '顺风巡航零期权拖累（100% 满仓 QQQ 复利）';
  if (inShield) {
    regimeCode = 'SLOW_BEAR_SHIELD_ACTIVE';
    titleEn = 'SLOW-BEAR 50% T-BILL SHIELD ACTIVE';
    titleZh = '五灯破年线 50% 美债慢熊盾运行中';
  } else if (s1Open && s2Open) {
    regimeCode = 'DUAL_SLOT_FULL_SHIELD';
    titleEn = 'SLOT 1 NAKED PUT + SLOT 2 ZERO-COST COLLAR FULL HEDGE ACTIVE';
    titleZh = '首仓裸 Put + 次仓零成本 Collar 双槽满盾保护中';
  } else if (s1Open) {
    regimeCode = 'SLOT1_NAKED_PUT_ACTIVE';
    titleEn = 'SLOT 1 (50% NAKED -10% PUT) ACTIVE · UNLIMITED UPSIDE RETAINED';
    titleZh = '首仓 50% 裸 -10% Put 持盾中 · 保留 100% 向上冲顶收益';
  } else if (!athOk) {
    regimeCode = 'LOW_SPOT_FREEZE_NO_NEW_COLLAR';
    titleEn = 'DRAWDOWN > 5% OFF ATH · HARD FREEZE ON NEW COLLARS (100% QQQ REBOUND CAPTURE)';
    titleZh = '距历史前高回撤超 5% · 严禁低位新开或续作 Collar（保留 100% 反弹斜率）';
  }

  const dev200 = ma200 > 0 ? ((cl / ma200 - 1) * 100).toFixed(2) : '0.00';
  return {
    ...baseSignalState,
    regime_code: regimeCode,
    regime_title_en: titleEn,
    regime_title_zh: titleZh,
    regime_subtitle_en: `QQQ $${cl.toFixed(2)} (${ddPct.toFixed(2)}% vs ATH, ${dev200}% vs 200DMA) · ${sc}/6 Crisis Lights ON (5D avg ${sc5.toFixed(1)}) · VIX/VIX3M ${vr.toFixed(3)}`,
    regime_subtitle_zh: `QQQ 现价 $${cl.toFixed(2)}（距前高 ${ddPct.toFixed(2)}%，偏离年线 ${dev200}%）· 危机灯 ${sc}/6 亮灯（5日均值 ${sc5.toFixed(1)}）· VIX/VIX3M ${vr.toFixed(3)}`,
    target_equity_pct: inShield ? 50.0 : 100.0,
    target_tbill_pct: inShield ? 50.0 : 0.0,
    active_option_slots: openU4Tranches.length,
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
    slow_bear_shield: {
      ...baseSignalState.slow_bear_shield,
      status: inShield ? 'ACTIVE' : 'STANDBY',
      status_label_en: inShield ? 'ACTIVE (50% T-BILL)' : 'STANDBY (100% QQQ)',
      status_label_zh: inShield ? '激活避险中（50% 短债）' : '未激活（100% 现货）',
    },
    gate_checklist: [
      {
        key: 'ath_5pct',
        passed: athOk,
        label_en: 'Near High (DD >= -5%)',
        label_zh: '高位区 (距ATH <= 5%)',
        reading: `${ddPct.toFixed(2)}%`,
      },
      {
        key: 'vxn_22',
        passed: vxnOk,
        label_en: 'Cheap Vol (VXN <= 22)',
        label_zh: '低波区 (VXN <= 22)',
        reading: vxn.toFixed(2),
      },
      {
        key: 'ad_50dma',
        passed: adBelow,
        label_en: 'AD Line < 50DMA',
        label_zh: '腾落线 < 50DMA',
        reading: `${Math.round(Number(lastBar.ad_vs_50ma))}`,
      },
      {
        key: 'lights_4',
        passed: lightsOk,
        label_en: 'Crisis Lights >= 4/6',
        label_zh: '危机灯 >= 4/6',
        reading: `${sc}/6`,
      },
      {
        key: 'vix_tp_110',
        passed: tpOk,
        label_en: 'Panic TP (VIX/3M >= 1.10)',
        label_zh: '恐慌止盈 (VIX/3M >= 1.10)',
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
  let shieldActive = Boolean(lastBase.shield_active);
  let pendingReload = baseData.live_signal_state?.slow_bear_shield?.status === 'ACTIVE_RELOAD_ARMED';
  let pendingEnter = false;
  const rDaily = ((Number(baseData.live_market_snapshot?.tbill_3m_pct ?? 4.25) / 100) / 252);

  for (const b of fresh) {
    const prev = series[series.length - 1];
    if (pendingReload && shieldActive) {
      shieldActive = false;
      pendingReload = false;
    } else if (pendingEnter && !shieldActive) {
      shieldActive = true;
      pendingEnter = false;
    }

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

    const u4Ret = shieldActive ? 0.5 * qqqRet + 0.5 * rDaily : qqqRet;
    const nextRow = {
      ...prev,
      date: b.date,
      qqq_close: r2(cl),
      qqq_ma200: r2(ma200),
      running_ath: r2(runAth),
      dd_ath_pct: r2(ddAthPct),
      nav_bh: r2(Number(prev.nav_bh) * (1 + qqqRet)),
      nav_u4: r2(Number(prev.nav_u4) * (1 + u4Ret)),
      nav_u1: r2(Number(prev.nav_u1) * (1 + qqqRet)),
      nav_b1c: r2(Number(prev.nav_b1c) * (1 + qqqRet)),
      nav_d2: r2(Number(prev.nav_d2) * (1 + qqqRet)),
      nav_h2: r2(Number(prev.nav_h2) * (1 + qqqRet)),
      vix: r2(vix),
      vix3m: r2(vix3m),
      vix_ratio: r3(vr),
      vxn: r2(vxn),
      shield_active: shieldActive,
    };
    series.push(nextRow);

    if (!shieldActive && Number(nextRow.smooth_lights) >= 4.8 && cl < ma200) {
      pendingEnter = true;
    } else if (shieldActive && (Number(nextRow.smooth_lights) <= 3.0 || cl > ma200 * 1.01 || vix >= 34 || vr >= 1.1)) {
      pendingReload = true;
    }
  }
  return series;
}

export function loadCrisisObservatoryDashboard({
  asOf = null,
  strategy = null,
  snapshotId: expectedSnapshotId = null,
  file = defaultFile,
  extraDailyBars = null,
} = {}) {
  const { data, snapshotId } = readArtifact(file);
  if (expectedSnapshotId && expectedSnapshotId !== snapshotId) {
    fail('crisis_observatory_snapshot_changed', 409);
  }

  const selectedStrategy = strategy
    ? String(strategy).trim()
    : data.default_strategy_id ?? 'U4_DualEngine';
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
    const ledgerStrategy = selectedStrategy === 'BH_Pure_QQQ' ? 'U4_DualEngine' : selectedStrategy;
    return {
      ...data,
      version: CRISIS_OBSERVATORY_VERSION,
      snapshotId,
      requestedAsOf,
      liveExtended: false,
      selected_strategy_id: selectedStrategy,
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

  const openU4Tranches = (maskedLedgersByStrategy.U4_DualEngine ?? []).filter(t => t.exit_date === null);
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
    smooth_5d_score: lastBar.smooth_lights,
  };

  const ledgerStrategy = selectedStrategy === 'BH_Pure_QQQ' ? 'U4_DualEngine' : selectedStrategy;
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
    evaluation_window: {
      ...data.evaluation_window,
      end: effDate,
      trading_days: slicedSeries.length,
    },
    live_market_snapshot: liveSnap,
    live_signal_state: buildCutoffSignalState(lastBar, openU4Tranches, data.live_signal_state),
    six_crisis_lights: lightsAtCutoff,
    ad_line_signal: adSignal,
    strategies_summary: strategiesSummary,
    daily_series: slicedSeries,
    events: slicedEventsByStrategy[ledgerStrategy] ?? [],
    events_by_strategy: slicedEventsByStrategy,
    trade_ledger: maskedLedgersByStrategy[ledgerStrategy] ?? [],
    trade_ledgers_by_strategy: maskedLedgersByStrategy,
    shield_events: (data.shield_events ?? []).filter(e => e.date <= effDate),
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
    snapshotId,
    file,
    extraDailyBars,
  });
}
