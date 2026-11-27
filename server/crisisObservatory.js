import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const CRISIS_OBSERVATORY_VERSION = 'crisis-observatory-v2-master';
export const CRISIS_OBSERVATORY_STRATEGY_CODE = 'V2_QQQ_DUALCTA_TAILPUT_SINGLE';
export const CRISIS_OBSERVATORY_WINDOWS = Object.freeze(['11y_opra', '5y_live']);
export const DEFAULT_CRISIS_WINDOW = '11y_opra';

const WINDOW_ALIASES = Object.freeze({
  '11y': '11y_opra',
  '11yr': '11y_opra',
  '11y_opra': '11y_opra',
  all: '11y_opra',
  full: '11y_opra',
  '5y': '5y_live',
  '5yr': '5y_live',
  '5yr_live': '5y_live',
  '5y_live': '5y_live',
  live: '5y_live',
  zero_splice: '5y_live',
});

const YF_LIVE_MAP = Object.freeze({
  QQQ: 'QQQ',
  DBMF: 'DBMF',
  KMLM: 'KMLM',
  SPY: 'SPY',
  RSP: 'RSP',
  IWM: 'IWM',
  XLP: 'XLP',
  XLU: 'XLU',
  XLV: 'XLV',
  XLK: 'XLK',
  HYG: 'HYG',
  LQD: 'LQD',
  VXN: '^VXN',
  VIX: '^VIX',
  VIX3M: '^VIX3M',
  VVIX: '^VVIX',
  SKEW: '^SKEW',
  HG_F: 'HG=F',
  XLY: 'XLY',
  XLI: 'XLI',
  XLB: 'XLB',
  XLF: 'XLF',
});

const FRED_LAGS = Object.freeze({
  BAA10Y: 1,
  DGS2: 1,
  NFCI: 5,
  DFF: 1,
  T10Y2Y: 1,
});

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultFile = path.resolve(projectRoot, 'server/config/crisis-observatory-dashboard.json');

let cachedArtifact = null;
const liveResponseCache = new Map();
const liveFeedCache = { fetchedAt: 0, feed: null, inFlight: null };
const LIVE_FEED_TTL_MS = 15 * 60 * 1000;

function fail(code, status = 503) {
  throw Object.assign(new Error(code), { status });
}

const isIsoDate = value =>
  /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;

const r1 = v => (Number.isFinite(v) ? Math.round(v * 10) / 10 : null);
const r2 = v => (Number.isFinite(v) ? Math.round(v * 100) / 100 : null);
const r3 = v => (Number.isFinite(v) ? Math.round(v * 1000) / 1000 : null);
const r4 = v => (Number.isFinite(v) ? Math.round(v * 10000) / 10000 : null);
const r5 = v => (Number.isFinite(v) ? Math.round(v * 100000) / 100000 : null);

function clamp01(v) {
  if (!Number.isFinite(v) || v <= 0) return 0;
  if (v >= 1) return 1;
  return v;
}

function fmtSigned(v, dec = 2) {
  if (!Number.isFinite(v)) return 'n/a';
  const sign = v >= 0 ? '+' : '';
  return `${sign}${v.toFixed(dec)}`;
}

function addCalendarDaysIso(isoDate, days) {
  if (!isIsoDate(isoDate)) return null;
  const ms = Date.parse(`${isoDate}T00:00:00Z`) + days * 86400 * 1000;
  return new Date(ms).toISOString().slice(0, 10);
}

function diffCalendarDaysIso(d1, d0) {
  if (!isIsoDate(d1) || !isIsoDate(d0)) return 0;
  return Math.round((Date.parse(`${d1}T00:00:00Z`) - Date.parse(`${d0}T00:00:00Z`)) / (86400 * 1000));
}

function quantileLinear(arr, q) {
  if (!arr.length) return 0;
  const s = arr.slice().sort((a, b) => a - b);
  if (s.length === 1) return s[0];
  const pos = (s.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  if (lo === hi) return s[lo];
  return s[lo] + (pos - lo) * (s[hi] - s[lo]);
}

function meanTail(arr, n) {
  if (!arr.length || n <= 0) return null;
  const sub = arr.slice(-n);
  let sum = 0;
  for (const x of sub) sum += x;
  return sum / sub.length;
}

function stdTailDdof1(arr, n) {
  if (arr.length < Math.max(2, n)) return null;
  const sub = arr.slice(-n);
  const mu = sub.reduce((a, b) => a + b, 0) / sub.length;
  let sq = 0;
  for (const x of sub) sq += (x - mu) * (x - mu);
  return Math.sqrt(Math.max(0, sq / (sub.length - 1)));
}

function pearsonCorr(xs, ys) {
  const n = Math.min(xs.length, ys.length);
  if (n < 5) return 0;
  let mx = 0;
  let my = 0;
  const ox = xs.length - n;
  const oy = ys.length - n;
  for (let i = 0; i < n; i += 1) {
    mx += xs[ox + i];
    my += ys[oy + i];
  }
  mx /= n;
  my /= n;
  let num = 0;
  let dx = 0;
  let dy = 0;
  for (let i = 0; i < n; i += 1) {
    const a = xs[ox + i] - mx;
    const b = ys[oy + i] - my;
    num += a * b;
    dx += a * a;
    dy += b * b;
  }
  const denom = Math.sqrt(dx * dy);
  if (denom <= 1e-12) return 0;
  return Math.max(-1, Math.min(1, num / denom));
}

function hamiltonStepJS(stateP, zRow, A, means, vars) {
  const pred = [
    stateP[0] * A[0][0] + stateP[1] * A[1][0],
    stateP[0] * A[0][1] + stateP[1] * A[1][1],
  ];
  const logLik = [0, 0];
  for (let st = 0; st < 2; st += 1) {
    let ll = 0;
    for (let dim = 0; dim < 4; dim += 1) {
      const v = Math.max(1e-6, vars[st][dim]);
      const diff = zRow[dim] - means[st][dim];
      ll += -0.5 * (Math.log(2 * Math.PI * v) + (diff * diff) / v);
    }
    logLik[st] = ll;
  }
  const m = Math.max(logLik[0], logLik[1]);
  const p0 = pred[0] * Math.exp(logLik[0] - m);
  const p1 = pred[1] * Math.exp(logLik[1] - m);
  const tot = p0 + p1;
  if (!Number.isFinite(tot) || tot <= 0) return [0.5, 0.5];
  return [p0 / tot, p1 / tot];
}

function alignFredLagWithMeta(rawMap, calDates, idx, lag) {
  const effIdx = idx - lag;
  if (effIdx < 0 || !rawMap) return { value: null, obsDate: null };
  const cutoff = calDates[effIdx];
  let bestD = null;
  let bestV = null;
  for (const [d, v] of Object.entries(rawMap)) {
    if (d <= cutoff && Number.isFinite(Number(v))) {
      if (bestD === null || d > bestD) {
        bestD = d;
        bestV = Number(v);
      }
    }
  }
  return { value: bestV, obsDate: bestD };
}

export function parseFredCsvText(txt) {
  if (typeof txt !== 'string' || !txt) return {};
  const tailTxt = txt.length > 16000 ? txt.slice(-16000) : txt;
  const lines = tailTxt.split(/\r?\n/);
  const out = {};
  for (const line of lines) {
    const parts = line.split(',');
    if (parts.length < 2) continue;
    const d = parts[0].trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) continue;
    const rawVal = parts[1].trim();
    if (!rawVal || rawVal === '.') continue;
    const v = Number(rawVal);
    if (Number.isFinite(v)) out[d] = v;
  }
  return out;
}

export function computeLiveStressIndexJS({
  hmm_p = 0,
  vxn = 0,
  vix_ratio = 0,
  dd_from_ath = 0,
  close = 0,
  sma200 = 0,
  ewmac = 0,
  hyg_lqd = 0,
  hyg_sma50 = 0,
  baa_rise63 = null,
  dgs2_jump63 = null,
  nfci_jump20 = null,
  def_ret20 = 0,
  rsp_spy = 0,
  rsp_sma50 = 0,
  iwm_qqq = 0,
  iwm_sma50 = 0,
  ad_below50 = false,
  vvix = 0,
  vvix_p75 = 0,
  skew10 = 0,
  skew_p75 = 0,
  vr_jump5 = 0,
} = {}) {
  const baaEff =
    baa_rise63 === null || baa_rise63 === undefined || !Number.isFinite(Number(baa_rise63)) || Number(baa_rise63) <= -900
      ? 0
      : Number(baa_rise63);
  const dgs2Eff =
    dgs2_jump63 === null || dgs2_jump63 === undefined || !Number.isFinite(Number(dgs2_jump63)) || Number(dgs2_jump63) <= -900
      ? 0
      : Number(dgs2_jump63);
  const nfciEff =
    nfci_jump20 === null || nfci_jump20 === undefined || !Number.isFinite(Number(nfci_jump20)) || Number(nfci_jump20) <= -900
      ? 0
      : Number(nfci_jump20);

  const regimeVol =
    clamp01(Number(hmm_p)) * 18.0 +
    clamp01((Number(vxn) - 20.0) / 20.0) * 7.0 +
    clamp01((Number(vix_ratio) - 0.9) / 0.2) * 5.0;

  const trendDd =
    clamp01((-Number(dd_from_ath) - 0.03) / 0.17) * 12.0 +
    (Number(sma200) > 0 && Number(close) < Number(sma200) ? 6.0 : 0.0) +
    clamp01(-Number(ewmac) / 0.8) * 7.0;

  const creditMacro =
    (Number(hyg_sma50) > 0 && Number(hyg_lqd) < Number(hyg_sma50) ? 8.0 : 0.0) +
    clamp01(Math.max(0, baaEff) / 0.25) * 8.0 +
    clamp01(Math.max(Math.max(0, dgs2Eff) / 0.5, Math.max(0, nfciEff) / 0.15)) * 9.0;

  const breadthTail =
    clamp01(Math.max(0, Number(def_ret20)) / 0.1) * 8.0 +
    (Number(rsp_sma50) > 0 && Number(rsp_spy) < Number(rsp_sma50) ? 2.0 : 0.0) +
    (Number(iwm_sma50) > 0 && Number(iwm_qqq) < Number(iwm_sma50) ? 2.0 : 0.0) +
    (ad_below50 ? 2.0 : 0.0) +
    (Number(vvix_p75) > 0 && Number(vvix) >= Number(vvix_p75) ? 2.0 : 0.0) +
    (Number(skew_p75) > 0 && Number(skew10) >= Number(skew_p75) ? 2.0 : 0.0) +
    (Number(vr_jump5) >= 0.06 ? 2.0 : 0.0);

  const rawTotal = Math.max(0, Math.min(100, regimeVol + trendDd + creditMacro + breadthTail));
  const idxInt = Math.floor(rawTotal + 0.5);
  let level = 'calm';
  let lblEn = 'Calm Low-Vol';
  let lblZh = '平静低波';
  if (idxInt >= 75) {
    level = 'crisis';
    lblEn = 'Active Crisis';
    lblZh = '危机爆发中';
  } else if (idxInt >= 50) {
    level = 'elevated';
    lblEn = 'Elevated Stress';
    lblZh = '高压警戒';
  } else if (idxInt >= 25) {
    level = 'building';
    lblEn = 'Stress Building';
    lblZh = '隐患蓄力';
  }
  return {
    live_stress_index: idxInt,
    live_stress_level: level,
    live_stress_label_en: lblEn,
    live_stress_label_zh: lblZh,
    live_stress_breakdown: {
      regime_vol: r1(regimeVol),
      regime_vol_cap: 30,
      trend_dd: r1(trendDd),
      trend_dd_cap: 25,
      credit_macro: r1(creditMacro),
      credit_macro_cap: 25,
      breadth_tail: r1(breadthTail),
      breadth_tail_cap: 20,
    },
  };
}

function unpackTable(val) {
  if (!val) return [];
  if (Array.isArray(val)) return val;
  if (Array.isArray(val._cols) && Array.isArray(val._rows)) {
    const cols = val._cols;
    return val._rows.map(row => {
      const obj = {};
      for (let i = 0; i < cols.length; i += 1) obj[cols[i]] = row[i] ?? null;
      return obj;
    });
  }
  return [];
}

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
    parsed.version !== CRISIS_OBSERVATORY_VERSION ||
    !parsed.backtest?.windows?.['11y_opra'] ||
    !parsed.backtest?.windows?.['5y_live'] ||
    !parsed.pit_daily_index ||
    !parsed.live_tail_state
  ) {
    fail('crisis_observatory_invalid', 503);
  }
  const snapshotId = createHash('sha256').update(raw).digest('hex').slice(0, 16);
  const pitRows = unpackTable(parsed.pit_daily_index);
  const pitByDate = new Map(pitRows.map(r => [r.date, r]));
  const unpackedWindows = {};
  for (const wid of CRISIS_OBSERVATORY_WINDOWS) {
    const w = parsed.backtest.windows[wid];
    unpackedWindows[wid] = {
      ...w,
      daily_series: unpackTable(w.daily_series),
    };
  }
  liveResponseCache.clear();
  cachedArtifact = {
    file,
    mtimeMs: stat.mtimeMs,
    size: stat.size,
    snapshotId,
    data: parsed,
    pitRows,
    pitByDate,
    unpackedWindows,
  };
  return cachedArtifact;
}

export function normalizeWindowId(raw) {
  if (!raw) return DEFAULT_CRISIS_WINDOW;
  const k = String(raw).trim().toLowerCase();
  return WINDOW_ALIASES[k] ?? DEFAULT_CRISIS_WINDOW;
}

async function fetchYahooChart1mo(symbol, timeoutMs = 5500) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const enc = encodeURIComponent(symbol);
    const resp = await fetch(
      `https://query1.finance.yahoo.com/v8/finance/chart/${enc}?range=1mo&interval=1d`,
      { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: controller.signal },
    );
    if (!resp.ok) return null;
    const json = await resp.json();
    const res0 = json?.chart?.result?.[0];
    const ts = res0?.timestamp ?? [];
    const quote = res0?.indicators?.quote?.[0] ?? {};
    const adjArr = res0?.indicators?.adjclose?.[0]?.adjclose ?? [];
    const opens = quote.open ?? [];
    const closes = quote.close ?? [];
    const out = new Map();
    for (let i = 0; i < ts.length; i += 1) {
      const c = closes[i];
      if (!Number.isFinite(c) || c <= 0) continue;
      const a = Number.isFinite(adjArr[i]) && adjArr[i] > 0 ? adjArr[i] : c;
      const o = Number.isFinite(opens[i]) && opens[i] > 0 ? opens[i] : c;
      const dt = new Date(ts[i] * 1000).toISOString().slice(0, 10);
      out.set(dt, { open: o, close: c, adj: a });
    }
    return out;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function fetchFredRecent(seriesId, timeoutMs = 5500) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const enc = encodeURIComponent(seriesId);
    const resp = await fetch(
      `https://fred.stlouisfed.org/graph/fredgraph.csv?id=${enc}&cosd=2025-06-01`,
      { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: controller.signal },
    );
    if (!resp.ok) return null;
    return parseFredCsvText(await resp.text());
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function fetchNyFedEffrRecent(timeoutMs = 5000) {
  const urls = [
    'https://markets.newyorkfed.org/api/rates/unsecured/effr/last/15.json',
    'https://markets.newyorkfed.org/api/rates/unsecured/effr/last/5.json',
  ];
  for (const url of urls) {
    try {
      const resp = await fetch(url, {
        headers: { 'User-Agent': 'Mozilla/5.0' },
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (!resp.ok) continue;
      const obj = await resp.json();
      const out = {};
      for (const row of obj?.refRates ?? []) {
        if (row?.effectiveDate && Number.isFinite(Number(row.percentRate))) {
          out[String(row.effectiveDate)] = Number(row.percentRate) / 100.0;
        }
      }
      if (Object.keys(out).length > 0) return out;
    } catch {
      // try fallback
    }
  }
  return null;
}

export async function getLiveV2MarketFeed({ force = false } = {}) {
  const now = Date.now();
  if (!force && liveFeedCache.feed && now - liveFeedCache.fetchedAt < LIVE_FEED_TTL_MS) {
    return liveFeedCache.feed;
  }
  if (!force && liveFeedCache.inFlight) return liveFeedCache.inFlight;

  liveFeedCache.inFlight = (async () => {
    try {
      const yfKeys = Object.keys(YF_LIVE_MAP);
      const fredKeys = Object.keys(FRED_LAGS);
      const [yfResults, fredResults, effrRes] = await Promise.all([
        Promise.all(yfKeys.map(k => fetchYahooChart1mo(YF_LIVE_MAP[k]))),
        Promise.all(fredKeys.map(fid => fetchFredRecent(fid))),
        fetchNyFedEffrRecent(),
      ]);
      const yahoo = {};
      yfKeys.forEach((k, idx) => {
        if (yfResults[idx]) yahoo[k] = yfResults[idx];
      });
      if (!yahoo.QQQ) return liveFeedCache.feed;
      const fred = {};
      fredKeys.forEach((fid, idx) => {
        if (fredResults[idx]) fred[fid] = fredResults[idx];
      });
      const qqqDates = [...yahoo.QQQ.keys()].sort();
      const feed = {
        fetchedAt: new Date().toISOString(),
        stamp: qqqDates[qqqDates.length - 1] ?? 'seed',
        yahoo,
        fred,
        effr: effrRes ?? {},
      };
      liveFeedCache.fetchedAt = Date.now();
      liveFeedCache.feed = feed;
      return feed;
    } catch {
      return liveFeedCache.feed;
    } finally {
      liveFeedCache.inFlight = null;
    }
  })();

  return liveFeedCache.inFlight;
}

export function extendV2LiveFromFeed(artifactObj, liveFeed, requestedAsOf) {
  const tail = artifactObj?.data?.live_tail_state;
  if (!tail || !Array.isArray(tail.tail_dates) || !tail.tail_dates.length) return null;
  const lastArtifactDate = tail.tail_dates[tail.tail_dates.length - 1];
  const qqqMap = liveFeed?.yahoo?.QQQ;
  if (!qqqMap || typeof qqqMap.keys !== 'function') return null;

  const capAsOf = requestedAsOf && isIsoDate(requestedAsOf) ? requestedAsOf : '2099-12-31';
  const newDates = [...qqqMap.keys()]
    .filter(d => d > lastArtifactDate && d <= capAsOf && Number(qqqMap.get(d)?.close) > 0)
    .sort();
  if (!newDates.length) {
    return {
      extraPitRows: [],
      fredLatest: { ...(artifactObj.data.data_freshness?.fred_as_of ?? {}) },
      effrLatest: artifactObj.data.data_freshness?.effr_as_of ?? null,
    };
  }

  const calDates = tail.tail_dates.slice();
  const yf = {};
  for (const k of Object.keys(tail.yf_tail)) yf[k] = tail.yf_tail[k].slice();

  const fredRaw = {};
  for (const fid of Object.keys(FRED_LAGS)) {
    fredRaw[fid] = { ...(tail.fred_tail?.[fid] ?? {}), ...(liveFeed?.fred?.[fid] ?? {}) };
  }
  const effrRaw = { ...(tail.effr_tail ?? {}), ...(liveFeed?.effr ?? {}) };

  const slTail = tail.six_lights_tail ?? {};
  const slDgs2 = (slTail.dgs2 ?? []).slice();
  const slDff = (slTail.dff ?? []).slice();
  const slBaa = (slTail.baa10y ?? []).slice();
  const slCop = (slTail.copper ?? []).slice();
  const slDc = (slTail.def_cyc ?? []).slice();
  const slYc = (slTail.t10y2y ?? []).slice();
  const slNfci = (slTail.nfci ?? []).slice();
  const slScores = (slTail.scores ?? []).slice();
  const bf = slTail.breadth_fallback ?? {};

  let { ema20, e16, e32, e64, e128, e256 } = tail.ewm_state;
  const cnt = tail.welford_4d.count.slice();
  const meanAcc = tail.welford_4d.mean.slice();
  const m2Acc = tail.welford_4d.m2.slice();
  let stateP = tail.hmm.state_p.slice();
  const pHmmTail = tail.p_hmm_tail.slice();
  const { XLP: xlp0, XLU: xlu0, XLV: xlv0, XLK: xlk0 } = tail.base_2013;

  const trDates = (tail.tr_tail_dates ?? tail.tail_dates).slice();
  const qTr = (tail.qqq_tr_tail ?? []).slice();
  const dbTr = (tail.dbmf_tr_tail ?? []).slice();
  const kmTr = (tail.kmlm_tr_tail ?? []).slice();
  const ctaTr = (tail.cta_tr_tail ?? []).slice();

  let runAthTr = Number(tail.running_ath_tr);
  let runAthSpot = Number(tail.running_ath_spot);
  let runAthDate = String(tail.running_ath_date);
  let runAthDbTr = Number(tail.running_ath_dbmf_tr);
  let runAthKmTr = Number(tail.running_ath_kmlm_tr);
  let runAthCtaTr = Number(tail.running_ath_cta_tr);

  let latchArmed = Boolean(tail.latch_state?.armed);
  let latchArmDate = tail.latch_state?.arm_date ?? null;
  let latchPeak = Number(tail.latch_state?.peak_cta_gain ?? 0);
  let above200 = Number(tail.latch_state?.above_200dma_streak ?? 0);
  let contStart = tail.cont_2m_state?.timer_start ?? null;
  let contangoStreak = Number(tail.put_gate_state?.contango_streak ?? 0);
  let postTpLock = Boolean(tail.put_gate_state?.post_tp_lockout);
  let lockStreak = Number(tail.put_gate_state?.lockout_streak ?? 0);
  let lastTpDate = tail.put_gate_state?.last_tp_date ?? null;
  const adBelow = Boolean(tail.put_gate_state?.ad_below50);

  const skew10Hist = calDates.map((_, idx) => {
    if (idx < 9) return null;
    let s = 0;
    for (let k = idx - 9; k <= idx; k += 1) s += yf.SKEW[k];
    return s / 10.0;
  });
  const baaLagHist = calDates.map((_, idx) => alignFredLagWithMeta(fredRaw.BAA10Y, calDates, idx, 1).value);
  const dgs2LagHist = calDates.map((_, idx) => alignFredLagWithMeta(fredRaw.DGS2, calDates, idx, 1).value);
  const nfciLagHist = calDates.map((_, idx) => alignFredLagWithMeta(fredRaw.NFCI, calDates, idx, 5).value);

  const sortedEffrDates = Object.keys(effrRaw).sort();
  const extraPitRows = [];

  for (const d of newDates) {
    const prevD = calDates[calDates.length - 1];
    calDates.push(d);
    trDates.push(d);
    const idx = calDates.length - 1;

    for (const k of Object.keys(yf)) {
      const bar = liveFeed?.yahoo?.[k]?.get(d);
      const prevV = yf[k][yf[k].length - 1];
      const nextV = Number.isFinite(bar?.close) && bar.close > 0 ? Number(bar.close) : prevV;
      yf[k].push(nextV);
    }

    const cl = yf.QQQ[idx];
    const dbSpot = yf.DBMF[idx];
    const kmSpot = yf.KMLM[idx];
    const vix = yf.VIX[idx];
    const vix3m = yf.VIX3M[idx];
    const vr = vix3m > 0 ? vix / vix3m : 1.0;
    const vxn = yf.VXN[idx];
    const vvixNow = yf.VVIX[idx];

    // Step TR series using Yahoo adj close ratio when available, else close ratio
    const stepRatio = sym => {
      const bCur = liveFeed?.yahoo?.[sym]?.get(d);
      const bPrev = liveFeed?.yahoo?.[sym]?.get(prevD);
      if (bCur?.adj > 0 && bPrev?.adj > 0) return bCur.adj / bPrev.adj;
      const arr = yf[sym];
      return arr[arr.length - 1] / Math.max(arr[arr.length - 2], 1e-8);
    };
    const rQ = stepRatio('QQQ') - 1.0;
    const rDb = stepRatio('DBMF') - 1.0;
    const rKm = stepRatio('KMLM') - 1.0;
    const nextQTr = qTr[qTr.length - 1] * (1.0 + rQ);
    const nextDbTr = dbTr[dbTr.length - 1] * (1.0 + rDb);
    const nextKmTr = kmTr[kmTr.length - 1] * (1.0 + rKm);
    const nextCtaTr = ctaTr[ctaTr.length - 1] * (1.0 + 0.5 * rDb + 0.5 * rKm);
    qTr.push(nextQTr);
    dbTr.push(nextDbTr);
    kmTr.push(nextKmTr);
    ctaTr.push(nextCtaTr);

    if (nextQTr >= runAthTr) {
      runAthTr = nextQTr;
      runAthSpot = Math.max(runAthSpot, cl);
      runAthDate = d;
      runAthDbTr = nextDbTr;
      runAthKmTr = nextKmTr;
      runAthCtaTr = nextCtaTr;
    }
    const ddAth = nextQTr / runAthTr - 1.0;
    const dbAth = nextDbTr / runAthDbTr - 1.0;
    const kmAth = nextKmTr / runAthKmTr - 1.0;
    const ctaAth = nextCtaTr / runAthCtaTr - 1.0;

    // 252D rolling high & Corr60(DualCTA, QQQ)
    const trIdx = qTr.length - 1;
    const lo = Math.max(0, trIdx - 251);
    let jHi = lo;
    for (let k = lo + 1; k <= trIdx; k += 1) {
      if (qTr[k] > qTr[jHi]) jHi = k;
    }
    const dd252 = nextQTr / qTr[jHi] - 1.0;
    const dbHi252 = nextDbTr / dbTr[jHi] - 1.0;
    const kmHi252 = nextKmTr / kmTr[jHi] - 1.0;
    const ctaHi252 = nextCtaTr / ctaTr[jHi] - 1.0;

    const rqWin = [];
    const rctaWin = [];
    const cStart = Math.max(1, trIdx - 59);
    for (let k = cStart; k <= trIdx; k += 1) {
      rqWin.push(qTr[k] / qTr[k - 1] - 1.0);
      rctaWin.push(ctaTr[k] / ctaTr[k - 1] - 1.0);
    }
    const corr60 = pearsonCorr(rqWin, rctaWin);

    // Skew10 / VVIX quantiles
    let s10 = 0;
    for (let k = idx - 9; k <= idx; k += 1) s10 += yf.SKEW[k];
    const skew10Now = s10 / 10.0;
    skew10Hist.push(skew10Now);
    const skWin = skew10Hist.slice(-252).filter(Number.isFinite);
    const skewP75Now = skWin.length >= 126 ? quantileLinear(skWin, 0.75) : skew10Now;
    const vvWin = yf.VVIX.slice(-252).filter(Number.isFinite);
    const vvixP75Now = vvWin.length >= 126 ? quantileLinear(vvWin, 0.75) : vvixNow;

    // FRED lagged values
    const baaNow = alignFredLagWithMeta(fredRaw.BAA10Y, calDates, idx, 1).value;
    const dgs2Now = alignFredLagWithMeta(fredRaw.DGS2, calDates, idx, 1).value;
    const nfciNow = alignFredLagWithMeta(fredRaw.NFCI, calDates, idx, 5).value;
    const dffNow = alignFredLagWithMeta(fredRaw.DFF, calDates, idx, 1).value;
    const ycNow = alignFredLagWithMeta(fredRaw.T10Y2Y, calDates, idx, 1).value;
    baaLagHist.push(baaNow);
    dgs2LagHist.push(dgs2Now);
    nfciLagHist.push(nfciNow);

    const baaWin63 = baaLagHist.slice(-63).filter(Number.isFinite);
    const baaRise = baaNow !== null && baaWin63.length >= 30 ? baaNow - Math.min(...baaWin63) : null;
    const dgs2Jump = dgs2Now !== null && idx >= 63 && dgs2LagHist[idx - 63] !== null ? dgs2Now - dgs2LagHist[idx - 63] : null;
    const nfciJump = nfciNow !== null && idx >= 20 && nfciLagHist[idx - 20] !== null ? nfciNow - nfciLagHist[idx - 20] : null;

    // Six-Lights score
    const dgs2Cur = dgs2Now ?? slDgs2[slDgs2.length - 1];
    const dffCur = dffNow ?? slDff[slDff.length - 1];
    const baaCur = baaNow ?? slBaa[slBaa.length - 1];
    const ycCur = ycNow ?? slYc[slYc.length - 1];
    const nfciCur = nfciNow ?? slNfci[slNfci.length - 1];
    const hgCur = liveFeed?.yahoo?.HG_F?.get(d)?.close;
    const hgPrev = liveFeed?.yahoo?.HG_F?.get(prevD)?.close;
    const copCur = hgCur > 0 && hgPrev > 0 ? slCop[slCop.length - 1] * (hgCur / hgPrev) : slCop[slCop.length - 1];
    const cycSyms = ['XLY', 'XLI', 'XLB', 'XLF'];
    let dcCur = slDc[slDc.length - 1];
    if (cycSyms.every(sym => liveFeed?.yahoo?.[sym]?.get(d)?.close > 0 && liveFeed?.yahoo?.[sym]?.get(prevD)?.close > 0)) {
      const defC = yf.XLU[idx] + yf.XLP[idx] + yf.XLV[idx];
      const defP = yf.XLU[idx - 1] + yf.XLP[idx - 1] + yf.XLV[idx - 1];
      const cycC = cycSyms.reduce((s, sym) => s + liveFeed.yahoo[sym].get(d).close, 0);
      const cycP = cycSyms.reduce((s, sym) => s + liveFeed.yahoo[sym].get(prevD).close, 0);
      if (defP > 0 && cycC > 0 && cycP > 0) dcCur *= (defC / cycC) / (defP / cycP);
    }
    slDgs2.push(dgs2Cur);
    slDff.push(dffCur);
    slBaa.push(baaCur);
    slCop.push(copCur);
    slDc.push(dcCur);
    slYc.push(ycCur);
    slNfci.push(nfciCur);

    const min252 = arr => Math.min(...arr.slice(-252));
    const max252 = arr => Math.max(...arr.slice(-252));
    const sig1 = (dgs2Cur - min252(slDgs2) >= 0.5 && dgs2Cur > (meanTail(slDgs2, 63) ?? dgs2Cur)) || dffCur - min252(slDff) >= 0.2;
    const baaLo = min252(slBaa);
    const sig2 = (baaCur - baaLo >= 0.2 || (baaLo > 0 && baaCur / baaLo - 1 >= 0.12)) && baaCur > (meanTail(slBaa, 63) ?? baaCur);
    const sig3 = Boolean(bf.sig3_breadth);
    const copHi = max252(slCop);
    const sig4 = copHi > 0 && copCur / copHi - 1 <= -0.1 && copCur < (meanTail(slCop, 63) ?? copCur);
    const dcLo = min252(slDc);
    const sig5 = dcLo > 0 && dcCur / dcLo - 1 >= 0.05 && dcCur > (meanTail(slDc, 63) ?? dcCur);
    const sig6 = (max252(slYc) - ycCur >= 0.4 && ycCur < 0.75) || ycCur < 0 || nfciCur - min252(slNfci) >= 0.12;
    const sc = Number(sig1) + Number(sig2) + Number(sig3) + Number(sig4) + Number(sig5) + Number(sig6);
    slScores.push(sc);

    // Trend / EWMAC
    const sma200Now = meanTail(yf.QQQ, 200) ?? cl;
    const stepEwm = (prev, span, x) => (1 - 2 / (span + 1)) * prev + (2 / (span + 1)) * x;
    ema20 = stepEwm(ema20, 20, cl);
    e16 = stepEwm(e16, 16, cl);
    e32 = stepEwm(e32, 32, cl);
    e64 = stepEwm(e64, 64, cl);
    e128 = stepEwm(e128, 128, cl);
    e256 = stepEwm(e256, 256, cl);
    const diffs60 = [];
    for (let k = idx - 59; k <= idx; k += 1) diffs60.push(yf.QQQ[k] - yf.QQQ[k - 1]);
    const pxVol = stdTailDdof1(diffs60, 60);
    const ewmacNow = pxVol && pxVol > 0 ? ((e16 - e64) / pxVol + (e32 - e128) / pxVol + (e64 - e256) / pxVol) / 3.0 : 0;

    // Cross-asset ratios
    const hygArr = [];
    const rspArr = [];
    const iwmArr = [];
    for (let k = idx - 49; k <= idx; k += 1) {
      hygArr.push(yf.HYG[k] / Math.max(yf.LQD[k], 1e-8));
      rspArr.push(yf.RSP[k] / Math.max(yf.SPY[k], 1e-8));
      iwmArr.push(yf.IWM[k] / Math.max(yf.QQQ[k], 1e-8));
    }
    const hygNow = hygArr[hygArr.length - 1];
    const hygSma50 = meanTail(hygArr, 50) ?? hygNow;
    const rspNow = rspArr[rspArr.length - 1];
    const rspSma50 = meanTail(rspArr, 50) ?? rspNow;
    const iwmNow = iwmArr[iwmArr.length - 1];
    const iwmSma50 = meanTail(iwmArr, 50) ?? iwmNow;
    const defAt = k => ((yf.XLP[k] / xlp0 + yf.XLU[k] / xlu0 + yf.XLV[k] / xlv0) / 3.0) / (yf.XLK[k] / xlk0);
    const defRet20 = defAt(idx) / defAt(idx - 20) - 1.0;

    // Causal 4D Welford + Hamilton HMM
    const logR20 = [];
    for (let k = idx - 19; k <= idx; k += 1) logR20.push(Math.log(yf.QQQ[k] / yf.QQQ[k - 1]));
    const rv20Ann = (stdTailDdof1(logR20, 20) ?? 0.15 / Math.sqrt(252)) * Math.sqrt(252);
    const raw4 = [
      Math.log(yf.QQQ[idx] / yf.QQQ[idx - 5]),
      Math.log(Math.max(rv20Ann, 0.05)),
      -Math.log(hygNow / (yf.HYG[idx - 20] / Math.max(yf.LQD[idx - 20], 1e-8))),
      vr,
    ];
    const zRow = [];
    for (let dim = 0; dim < 4; dim += 1) {
      const sd = Math.sqrt(m2Acc[dim] / Math.max(1, cnt[dim] - 1));
      const zv = sd > 0 ? (raw4[dim] - meanAcc[dim]) / sd : 0;
      zRow.push(Math.max(-4.5, Math.min(4.5, zv)));
    }
    for (let dim = 0; dim < 4; dim += 1) {
      cnt[dim] += 1;
      const delta = raw4[dim] - meanAcc[dim];
      meanAcc[dim] += delta / cnt[dim];
      m2Acc[dim] += delta * (raw4[dim] - meanAcc[dim]);
    }
    stateP = hamiltonStepJS(stateP, zRow, tail.hmm.A, tail.hmm.means, tail.hmm.vars);
    const hpCur = stateP[1];
    pHmmTail.push(hpCur);
    const hpPrev5 = pHmmTail[pHmmTail.length - 6] ?? 0;
    const vrJ5 = vr - yf.VIX[idx - 5] / Math.max(yf.VIX3M[idx - 5], 1e-6);

    // Slow-Bear +8% Hysteresis Latch
    const below200 = cl < sma200Now;
    above200 = below200 ? 0 : above200 + 1;
    if (!latchArmed) {
      if (below200 && dd252 <= -0.1 && corr60 < 0 && ctaHi252 >= 0.08) {
        latchArmed = true;
        latchArmDate = d;
        latchPeak = ctaHi252;
      }
    } else {
      latchPeak = Math.max(latchPeak, ctaHi252);
      if (above200 >= 10) {
        latchArmed = false;
        latchArmDate = null;
        latchPeak = 0;
      }
    }

    // CONT_2M Continuous 60-day DD <= -12% Timer
    let contDays = 0;
    if (ddAth <= -0.12) {
      if (!contStart) contStart = d;
      contDays = diffCalendarDaysIso(d, contStart);
    } else {
      contStart = null;
      contDays = 0;
    }

    // Contango streak & Post-TP 5D Lockout
    contangoStreak = vr < 1.0 ? contangoStreak + 1 : 0;
    if (vr >= 1.1 && ddAth <= -0.1) {
      postTpLock = true;
      lockStreak = 0;
      lastTpDate = d;
    } else if (postTpLock) {
      if (vr < 1.0) {
        lockStreak += 1;
        if (lockStreak >= 5) {
          postTpLock = false;
          lockStreak = 0;
        }
      } else {
        lockStreak = 0;
      }
    }

    // Dual-Track Raw vs Vol-Gated 6 sensors
    const m0Raw = (adBelow || sc >= 4) && ddAth >= -0.05;
    const m0Entry = m0Raw && vxn <= 22.0;
    const m6Raw = rspNow < rspSma50 && (iwmNow < iwmSma50 || adBelow) && defRet20 >= 0.025;
    const m6Entry = m6Raw && vxn <= 25.0 && vr <= 0.92;
    const m2A = skew10Now >= skewP75Now && vvixNow >= vvixP75Now && vr >= 0.85;
    const m2B = vr >= 0.92 && vrJ5 >= 0.06 && vvixNow >= 100.0;
    const m2Raw = m2A || m2B;
    const m2Entry =
      ((skew10Now >= skewP75Now && vvixNow >= vvixP75Now && vr >= 0.85 && vr <= 0.98) ||
        (vr >= 0.92 && vr <= 1.02 && vrJ5 >= 0.06 && vvixNow >= 100.0)) &&
      vxn <= 24.0;
    const m5Raw = hpCur >= 0.55;
    const m5Entry = hpCur >= 0.55 && hpPrev5 < 0.4 && vxn <= 24.0 && vr < 1.02;
    const m4Raw = latchArmed && below200 && ewmacNow < 0 && cl > ema20;
    const m4Entry = m4Raw && vxn <= 28.0 && vr <= 0.9;
    const creditHit = (baaRise !== null && baaRise >= 0.15) || (dgs2Jump !== null && dgs2Jump >= 0.4) || (nfciJump !== null && nfciJump >= 0.1);
    const m3Raw = hygNow < hygSma50 && creditHit;
    const m3Entry = m3Raw && vxn <= 26.0 && vr <= 0.92;

    const stress = computeLiveStressIndexJS({
      hmm_p: hpCur, vxn, vix_ratio: vr, dd_from_ath: ddAth, close: cl, sma200: sma200Now, ewmac: ewmacNow,
      hyg_lqd: hygNow, hyg_sma50: hygSma50, baa_rise63: baaRise, dgs2_jump63: dgs2Jump, nfci_jump20: nfciJump,
      def_ret20: defRet20, rsp_spy: rspNow, rsp_sma50: rspSma50, iwm_qqq: iwmNow, iwm_sma50: iwmSma50,
      ad_below50: adBelow, vvix: vvixNow, vvix_p75: vvixP75Now, skew10: skew10Now, skew_p75: skewP75Now, vr_jump5: vrJ5,
    });

    let effrPct = 3.88;
    for (let ei = sortedEffrDates.length - 1; ei >= 0; ei -= 1) {
      if (sortedEffrDates[ei] <= d) {
        effrPct = Number(effrRaw[sortedEffrDates[ei]]) * 100.0;
        break;
      }
    }

    extraPitRows.push({
      date: d,
      qqq: r2(cl),
      ath: r2(runAthSpot),
      ath_date: runAthDate,
      dd_ath: r2(ddAth * 100),
      hi252_date: trDates[jHi],
      dd252: r2(dd252 * 100),
      sma200: r2(sma200Now),
      ema20: r2(ema20),
      ewmac: r3(ewmacNow),
      dbmf: r2(dbSpot),
      kmlm: r2(kmSpot),
      db_ath: r2(dbAth * 100),
      km_ath: r2(kmAth * 100),
      cta_ath: r2(ctaAth * 100),
      db_hi252: r2(dbHi252 * 100),
      km_hi252: r2(kmHi252 * 100),
      cta_hi252: r2(ctaHi252 * 100),
      corr60: r3(corr60),
      latch: latchArmed ? 1 : 0,
      latch_arm: latchArmDate,
      latch_pk: r2(latchPeak * 100),
      abv200: above200,
      c2m_d: contDays,
      c2m_s: contStart,
      vix: r2(vix),
      vxn: r2(vxn),
      vix3m: r2(vix3m),
      vr: r3(vr),
      vr_j5: r3(vrJ5),
      skew10: r2(skew10Now),
      skew_p75: r2(skewP75Now),
      vvix: r2(vvixNow),
      vvix_p75: r2(vvixP75Now),
      hmm_p: r4(hpCur),
      hmm_p5: r4(hpPrev5),
      hyg_lqd: r4(hygNow),
      hyg_sma50: r4(hygSma50),
      baa_r: baaRise !== null ? r3(baaRise) : null,
      dgs2_j: dgs2Jump !== null ? r3(dgs2Jump) : null,
      nfci_j: nfciJump !== null ? r3(nfciJump) : null,
      rsp_spy: r4(rspNow),
      rsp_sma50: r4(rspSma50),
      iwm_qqq: r4(iwmNow),
      iwm_sma50: r4(iwmSma50),
      def_ret20: r2(defRet20 * 100),
      sc6: sc,
      ad_b50: adBelow ? 1 : 0,
      effr: r2(effrPct),
      ct_strk: contangoStreak,
      tp_lock: postTpLock ? 1 : 0,
      tp_lstrk: lockStreak,
      last_tp: lastTpDate,
      stress: stress.live_stress_index,
      raw_mask:
        (m0Raw ? 1 : 0) | (m6Raw ? 2 : 0) | (m2Raw ? 4 : 0) | (m5Raw ? 8 : 0) | (m4Raw ? 16 : 0) | (m3Raw ? 32 : 0),
      ent_mask:
        (m0Entry ? 1 : 0) | (m6Entry ? 2 : 0) | (m2Entry ? 4 : 0) | (m5Entry ? 8 : 0) | (m4Entry ? 16 : 0) | (m3Entry ? 32 : 0),
    });
  }

  const fredLatest = {};
  for (const fid of Object.keys(FRED_LAGS)) {
    const ks = Object.keys(fredRaw[fid]).sort();
    fredLatest[fid] = ks[ks.length - 1] ?? null;
  }
  const effrLatest = sortedEffrDates[sortedEffrDates.length - 1] ?? null;

  return { extraPitRows, fredLatest, effrLatest };
}

export function buildLiveCockpit(row, { isPitReplay = false } = {}) {
  const qqq = Number(row.qqq);
  const ath = Number(row.ath);
  const ddAthPct = Number(row.dd_ath);
  const dd252Pct = Number(row.dd252);
  const sma200 = Number(row.sma200);
  const ema20 = Number(row.ema20);
  const ewmac = Number(row.ewmac);
  const vix = Number(row.vix);
  const vxn = Number(row.vxn);
  const vix3m = Number(row.vix3m);
  const vr = Number(row.vr);
  const vrJ5 = Number(row.vr_j5 ?? 0);
  const effrPct = Number(row.effr ?? 3.88);
  const boxRatePct = r2(effrPct + 0.35);
  const ibkrRatePct = r2(effrPct + 1.5);

  const latchArmed = Boolean(row.latch);
  const above200 = Number(row.abv200 ?? 0);
  const corr60 = Number(row.corr60 ?? 0);
  const ctaHi252Pct = Number(row.cta_hi252 ?? 0);
  const dbAthPct = Number(row.db_ath ?? 0);
  const kmAthPct = Number(row.km_ath ?? 0);
  const ctaAthPct = Number(row.cta_ath ?? 0);
  const c2mDays = Number(row.c2m_d ?? 0);
  const c2mStart = row.c2m_s ?? null;
  const c2mActive = c2mStart !== null && ddAthPct <= -12.0;
  const c2mConfirmed = c2mActive && c2mDays >= 60;
  const c2mProjected = c2mStart ? addCalendarDaysIso(c2mStart, 60) : null;

  const contangoStreak = Number(row.ct_strk ?? 0);
  const postTpLock = Boolean(row.tp_lock);
  const tpLockStreak = Number(row.tp_lstrk ?? 0);
  const lastTpDate = row.last_tp ?? null;

  const rawMask = Number(row.raw_mask ?? 0);
  const entMask = Number(row.ent_mask ?? 0);
  const hasBit = (mask, bit) => (mask & bit) !== 0;

  const m0Raw = hasBit(rawMask, 1);
  const m6Raw = hasBit(rawMask, 2);
  const m2Raw = hasBit(rawMask, 4);
  const m5Raw = hasBit(rawMask, 8);
  const m4Raw = hasBit(rawMask, 16);
  const m3Raw = hasBit(rawMask, 32);

  const m0Ent = hasBit(entMask, 1);
  const m6Ent = hasBit(entMask, 2);
  const m2Ent = hasBit(entMask, 4);
  const m5Ent = hasBit(entMask, 8);
  const m4Ent = hasBit(entMask, 16);
  const m3Ent = hasBit(entMask, 32);

  const p1Raw = Math.min(45, (m0Raw ? 35 : 0) + (m6Raw ? 20 : 0));
  const p2Raw = Math.min(40, (m2Raw ? 20 : 0) + (m5Raw ? 20 : 0));
  const p3Raw = Math.min(45, (m4Raw ? 35 : 0) + (m3Raw ? 20 : 0));
  const rawCrisisProb = Math.min(100, p1Raw + p2Raw + p3Raw);

  const p1Ent = Math.min(45, (m0Ent ? 35 : 0) + (m6Ent ? 20 : 0));
  const p2Ent = Math.min(40, (m2Ent ? 20 : 0) + (m5Ent ? 20 : 0));
  const p3Ent = Math.min(45, (m4Ent ? 35 : 0) + (m3Ent ? 20 : 0));
  const nonM4EntProb = Math.min(100, p1Ent + p2Ent + (m3Ent ? 20 : 0));
  const entryCrisisProb = Math.min(100, p1Ent + p2Ent + p3Ent);

  const stressPack = computeLiveStressIndexJS({
    hmm_p: row.hmm_p,
    vxn,
    vix_ratio: vr,
    dd_from_ath: ddAthPct / 100.0,
    close: qqq,
    sma200,
    ewmac,
    hyg_lqd: row.hyg_lqd,
    hyg_sma50: row.hyg_sma50,
    baa_rise63: row.baa_r,
    dgs2_jump63: row.dgs2_j,
    nfci_jump20: row.nfci_j,
    def_ret20: Number(row.def_ret20 ?? 0) / 100.0,
    rsp_spy: row.rsp_spy,
    rsp_sma50: row.rsp_sma50,
    iwm_qqq: row.iwm_qqq,
    iwm_sma50: row.iwm_sma50,
    ad_below50: Boolean(row.ad_b50),
    vvix: row.vvix,
    vvix_p75: row.vvix_p75,
    skew10: row.skew10,
    skew_p75: row.skew_p75,
    vr_jump5: vrJ5,
  });

  // Vol-gate status (transparently separates raw alert from vol-gated entry!)
  let volGateStatus = 'ENTRY_ALLOWED';
  let volGateReasonEn = 'Low-to-moderate vol regime: new Put entries permitted whenever a pillar fires.';
  let volGateReasonZh = '中低波环境：只要三支柱信号触发即允许按规则建仓 Put。';
  if (postTpLock) {
    volGateStatus = 'POST_TP_LOCKOUT';
    volGateReasonEn = `Post-TP 5D contango lockout active (${tpLockStreak}/5 consecutive days VIX/VIX3M < 1.00 since ${lastTpDate ?? 'last TP'}). Do not re-buy puts prematurely.`;
    volGateReasonZh = `止盈后 5 日正向期限结构锁仓中（自 ${lastTpDate ?? '上次止盈'} 起连续 VIX/VIX3M < 1.00：${tpLockStreak}/5 天），禁止过早追回新 Put。`;
  } else if (vr >= 1.02 || vxn > 28.0) {
    volGateStatus = 'HIGH_VOL_NO_CHASE';
    volGateReasonEn = `High-vol no-chase guard active (VXN ${vxn.toFixed(1)}, VIX/VIX3M ${vr.toFixed(3)}): raw alerts reflect live stress, but new Put entries are blocked to avoid paying panic IV.`;
    volGateReasonZh = `高波禁追保护生效（VXN ${vxn.toFixed(1)}，VIX/VIX3M ${vr.toFixed(3)}）：原始预警反映实时危机压力，但禁止追高买入昂贵新 Put，现有持仓等待止盈。`;
  }

  // Sleeve A status
  let sleeveAStatus = 'OPEN_READY';
  let sleeveATone = 'mint';
  let sleeveAValEn = 'READY · 125D -15%';
  let sleeveAValZh = '允许建仓/滚仓';
  let sleeveADetEn = `VIX ${vix.toFixed(1)} < 20 & ${contangoStreak}D contango (>= 5D). Maintain 0.2% NAV baseline Put.`;
  let sleeveADetZh = `VIX ${vix.toFixed(1)} < 20 且连续 ${contangoStreak} 日非倒挂（>=5日），正常持有/滚仓 0.2% NAV 常态盾。`;
  if (vr >= 1.0) {
    sleeveAStatus = 'HOLD_INVERTED';
    sleeveATone = 'coral';
    sleeveAValEn = `INVERTED (${vr.toFixed(2)}) · HOLD`;
    sleeveAValZh = `倒挂 (${vr.toFixed(2)}) · 持仓不换`;
    sleeveADetEn = 'VIX/VIX3M >= 1.00 inverted: HOLD existing Put (do NOT roll into panic IV; watch Tier 2 TP).';
    sleeveADetZh = '期限结构倒挂 >= 1.00：现有 Put 死拿不滚仓，严禁高波追新单，盯紧二档止盈。';
  } else if (vix >= 20.0) {
    sleeveAStatus = 'PAUSED_VIX_GE_20';
    sleeveATone = 'amber';
    sleeveAValEn = `PAUSED (VIX ${vix.toFixed(1)} >= 20)`;
    sleeveAValZh = `暂停新开 (VIX ${vix.toFixed(1)} >= 20)`;
    sleeveADetEn = 'VIX >= 20.0 blocks new 0.2% baseline entries; existing put rolls at <= 75 DTE if non-inverted.';
    sleeveADetZh = 'VIX >= 20.0 暂停新开 0.2% 常态盾；已有仓位在非倒挂且 <= 75 DTE 时正常滚仓。';
  } else if (contangoStreak < 5) {
    sleeveAStatus = 'WAIT_CONTANGO_5D';
    sleeveATone = 'sky';
    sleeveAValEn = `WAIT ${contangoStreak}/5D CONTANGO`;
    sleeveAValZh = `等待正向 ${contangoStreak}/5 天`;
    sleeveADetEn = `VIX < 20 ok, waiting for 5 consecutive days VIX/VIX3M < 1.00 (${contangoStreak}/5).`;
    sleeveADetZh = `VIX < 20 已满足，等待连续 5 日 VIX/VIX3M < 1.00（当前 ${contangoStreak}/5 天）。`;
  }

  // Sleeve B status
  const sleeveBM4Ready = !postTpLock && vr < 1.02 && m4Ent;
  const sleeveBR1Ready = !postTpLock && vr < 1.02 && !m4Ent && nonM4EntProb >= 35;
  let sleeveBStatus = 'STANDBY';
  let sleeveBTone = 'muted';
  let sleeveBValEn = 'STANDBY (0%)';
  let sleeveBValZh = '待命观察';
  let sleeveBDetEn = 'No vol-gated crisis pillar >= 35%. Core 1.20x QQQ + Dual-CTA compounds unencumbered.';
  let sleeveBDetZh = '三支柱均未达低波建仓阈值，1.20x 核心仓位顺畅复利运行。';
  if (sleeveBM4Ready) {
    sleeveBStatus = 'OPEN_ROUTE2_M4';
    sleeveBTone = 'lilac';
    sleeveBValEn = 'FIRE M4 · 90D -10%';
    sleeveBValZh = '触发 M4 · 90D -10%';
    sleeveBDetEn = 'Slow-Bear Latch ON + Dead-Cat Bounce + VXN <= 28 & VR <= 0.90 -> Buy 1.0% NAV 90D -10% OTM Put.';
    sleeveBDetZh = '慢熊锁存开启 + 死猫跳 + VXN<=28 & VR<=0.90 -> T+1 买入 1.0% NAV 90D -10% OTM Put。';
  } else if (sleeveBR1Ready) {
    sleeveBStatus = 'OPEN_ROUTE1_125D';
    sleeveBTone = 'amber';
    sleeveBValEn = `FIRE R1 (${nonM4EntProb}%) · 125D -15%`;
    sleeveBValZh = `触发 R1 (${nonM4EntProb}%) · 125D -15%`;
    sleeveBDetEn = `Non-M4 crisis score ${nonM4EntProb}% >= 35% in low-vol window -> Buy 1.0% NAV 125D -15% OTM Put.`;
    sleeveBDetZh = `非 M4 支柱综合得分 ${nonM4EntProb}% >= 35% 且处于低波窗口 -> T+1 买入 1.0% NAV 125D -15% OTM Put。`;
  } else if (postTpLock) {
    sleeveBStatus = 'POST_TP_LOCKOUT';
    sleeveBTone = 'coral';
    sleeveBValEn = `LOCKED ${tpLockStreak}/5D`;
    sleeveBValZh = `止盈锁仓 ${tpLockStreak}/5 天`;
    sleeveBDetEn = `Raw alerts ${rawCrisisProb}% lit, but 5D post-TP contango lockout blocks re-entry until 5D VR < 1.00.`;
    sleeveBDetZh = `原始结构预警 ${rawCrisisProb}% 已亮，但处于止盈后 5 日锁仓期，须待连续 5 日 VIX/3M < 1.00 解锁。`;
  } else if (rawCrisisProb >= 35 || stressPack.live_stress_index >= 50) {
    sleeveBStatus = 'RAW_ALERT_HIGH_VOL';
    sleeveBTone = 'amber';
    sleeveBValEn = `RAW ${rawCrisisProb}% · NO CHASE`;
    sleeveBValZh = `预警 ${rawCrisisProb}% · 高波禁追`;
    sleeveBDetEn = `Live Stress ${stressPack.live_stress_index}/100 & Raw Alert ${rawCrisisProb}% lit, but high IV blocks chasing new puts.`;
    sleeveBDetZh = `实时压力 ${stressPack.live_stress_index}/100、原始预警 ${rawCrisisProb}% 已亮，但隐波过高禁止追单，现有仓位盯止盈。`;
  }

  // Tier 2 Full TP status
  const tpFullVrOk = vr >= 1.1;
  const tpFullDdOk = ddAthPct <= -10.0;
  const tpFullTriggered = tpFullVrOk && tpFullDdOk;

  // Master Command Center Action Directive
  let actionCode = 'HOLD_STEADY_CORE';
  let severity = 'calm';
  let headlineEn = 'Calm Compounding · Hold 100% QQQ + 10% DBMF + 10% KMLM (<= 1.20x)';
  let headlineZh = '平稳复利期 · 维持 100% QQQ + 10% DBMF + 10% KMLM（严守 <= 1.20x 红线）';
  let summaryEn = `Live Stress ${stressPack.live_stress_index}/100 (${stressPack.live_stress_label_en}). Maintain 1.20x core stack and Sleeve A 0.2% baseline Put rules.`;
  let summaryZh = `实时危机压力 ${stressPack.live_stress_index}/100（${stressPack.live_stress_label_zh}）。保持 1.20x 核心仓位，并按规则维护 0.2% 常态 Put 盾。`;

  if (tpFullTriggered) {
    actionCode = 'TRIGGER_FULL_TP';
    severity = 'action';
    headlineEn = `TIER 2 FULL TP ARMED · Liquidate 100% Active Puts (VIX/3M ${vr.toFixed(3)} >= 1.10 & ATH DD ${ddAthPct.toFixed(1)}% <= -10%)`;
    headlineZh = `二档全额止盈触发 · T+1 清仓 100% Put（倒挂 ${vr.toFixed(3)} >= 1.10 且回撤 ${ddAthPct.toFixed(1)}% <= -10%）`;
    summaryEn = 'Liquidate 100% of active Sleeve A & B puts at T+1 Close, deploy proceeds equally across 5 trading days (1/5/day) into QQQ (excess above 1.20x pays debt first), and start 5D contango lockout.';
    summaryZh = 'T+1 收盘 100% 清仓所有活跃 Put，所得现金分 5 个交易日等额（每日 1/5）回买 QQQ（超出 1.200x 杠杆上限优先还债），同时开启止盈后 5 日正向锁仓。';
  } else if (c2mConfirmed && (dbAthPct > 0 || kmAthPct > 0)) {
    actionCode = 'TRIGGER_CTA_ROTATION';
    severity = 'action';
    headlineEn = `DUAL-CTA 2-MONTH BEAR ROTATION CONFIRMED (${c2mDays}d <= -12%) · Rotate Winning CTA -> QQQ in 5 Tranches`;
    headlineZh = `双CTA 2个月持续熊市确认（连续 ${c2mDays} 天 <= -12%）· 分 5 批切出盈利 CTA 买 QQQ`;
    summaryEn = `QQQ stayed <= -12% for ${c2mDays} continuous calendar days. Sell profitable DBMF/KMLM sleeve(s) in 5 equal 20% tranches spaced 5 trading days apart into QQQ; hold mechanically for 365 days.`;
    summaryZh = `QQQ 已连续 ${c2mDays} 自然日处于 <= -12% 回撤区间。对自前高盈利 > 0% 的 CTA 分 5 批（每次 20%，间隔 5 交易日）换入 QQQ，并机械锁定持有 1 年。`;
  } else if (sleeveBM4Ready) {
    actionCode = 'OPEN_SLEEVE_B_M4';
    severity = 'action';
    headlineEn = 'M4 SLOW-BEAR DEAD-CAT BOUNCE FIRED · Buy 1.0% NAV 90D -10% OTM QQQ Put';
    headlineZh = 'M4 慢熊死猫跳触发 · T+1 买入 1.0% NAV 90D -10% OTM QQQ Put';
    summaryEn = `Slow-Bear +8% Latch ARMED + QQQ < 200DMA + EWMAC < 0 + QQQ > EMA20 + low-vol complacency (VXN ${vxn.toFixed(1)} <= 28, VR ${vr.toFixed(3)} <= 0.90). Recycle salvage at <= 30 DTE.`;
    summaryZh = `慢熊 +8% 滞回锁存已开，且满足破年线反抽 EMA20 + 波动率自满（VXN ${vxn.toFixed(1)} <= 28、VR ${vr.toFixed(3)} <= 0.90）。买 90D -10% OTM Put，<= 30 DTE 非倒挂回收残值。`;
  } else if (sleeveBR1Ready) {
    actionCode = 'OPEN_SLEEVE_B_ROUTE1';
    severity = 'action';
    headlineEn = `THREE-PILLAR ROUTE 1 FIRED (${nonM4EntProb}%) · Buy 1.0% NAV 125D -15% OTM QQQ Put`;
    headlineZh = `三支柱 Route 1 危机预警触发（${nonM4EntProb}%）· T+1 买入 1.0% NAV 125D -15% OTM Put`;
    summaryEn = `Low-vol structural warning lit across P1/P2/M3 (${nonM4EntProb}% >= 35%). Open 1.0% NAV Sleeve B 125D -15% OTM Put at T+1 Close; roll at <= 75 DTE if still lit.`;
    summaryZh = `P1/P2/M3 低波潜伏预警达标（${nonM4EntProb}% >= 35%）。T+1 收盘建仓 1.0% NAV 125D -15% OTM 危机盾，<= 75 DTE 非倒挂时信号仍亮则滚仓、熄灭则回收。`;
  } else if (stressPack.live_stress_index >= 50 || rawCrisisProb >= 35 || postTpLock) {
    actionCode = 'HOLD_HIGH_VOL_WATCH_TP';
    severity = stressPack.live_stress_index >= 75 ? 'crisis' : 'elevated';
    headlineEn = postTpLock
      ? `ACTIVE STRESS (${stressPack.live_stress_index}/100) · Post-TP Lockout (${tpLockStreak}/5D) · Hold Core <= 1.20x & Do Not Chase Puts`
      : `HIGH-VOL STRESS (${stressPack.live_stress_index}/100) · Raw Alerts ${rawCrisisProb}% Lit · No New Put Chasing`;
    headlineZh = postTpLock
      ? `高压危机态（压力 ${stressPack.live_stress_index}/100）· 止盈后锁仓 ${tpLockStreak}/5 天 · 严控 <= 1.20x 杠杆且禁追昂贵新 Put`
      : `高压警戒态（压力 ${stressPack.live_stress_index}/100）· 原始预警 ${rawCrisisProb}% 已亮 · 高波禁追新 Put，持盾盯止盈`;
    summaryEn = `QQQ ${fmtSigned(ddAthPct, 2)}% from ATH, VIX ${vix.toFixed(2)}, VXN ${vxn.toFixed(2)}, VIX/VIX3M ${vr.toFixed(3)}. Raw structural alerts (${rawCrisisProb}%) confirm live stress while vol-gate prevents paying panic IV. ${c2mActive ? `CONT_2M timer running: ${c2mDays}/60d.` : 'Watch Tier 2 Full TP (VR >= 1.10 & DD <= -10%).'}`;
    summaryZh = `QQQ 距前高 ${fmtSigned(ddAthPct, 2)}%，VIX ${vix.toFixed(2)}，VXN ${vxn.toFixed(2)}，VIX/VIX3M ${vr.toFixed(3)}。原始结构预警（${rawCrisisProb}%）如实反映实时压力，但高波门控/止盈锁仓阻止追买高价新 Put。${c2mActive ? `双CTA 2月熊市计时器运行中：连续 ${c2mDays}/60 天。` : '密切盯防二档全额止盈（VIX/3M >= 1.10 且回撤 <= -10%）。'}`;
  } else if (sleeveAStatus === 'OPEN_READY') {
    actionCode = 'OPEN_SLEEVE_A';
    severity = 'calm';
    headlineEn = 'Calm Low-Vol · Core 1.20x Active + Sleeve A (0.2% NAV 125D -15% OTM) Open/Roll Ready';
    headlineZh = '低波顺风期 · 维持 1.20x 核心仓 + 0.2% 常态盾（125D -15% OTM）可正常持有/滚仓';
    summaryEn = `VIX ${vix.toFixed(2)} < 20.0 & ${contangoStreak}D contango (>= 5D). Maintain 0.2% NAV baseline tail put and 100% QQQ + 10% DBMF + 10% KMLM <= 1.200x.`;
    summaryZh = `VIX ${vix.toFixed(2)} < 20.0 且已连续 ${contangoStreak} 日非倒挂（>= 5 日）。正常维护 0.2% NAV 常态尾盾，核心仓位严守 <= 1.200x 上限。`;
  }

  // Exact live target strikes computed from live QQQ spot
  const strike15Exact = r2(qqq * 0.85);
  const strike15Round = Math.round(qqq * 0.85);
  const strike10Exact = r2(qqq * 0.9);
  const strike10Round = Math.round(qqq * 0.9);

  // Build 3 Pillars with Dual-Track Raw vs Vol-Gate badges on every single sensor!
  const sensorStatus = (rawLit, entLit, specialBlocked = false) => {
    if (entLit) return 'ACTIONABLE';
    if (rawLit) return 'RAW_ALERT_HIGH_VOL';
    if (specialBlocked) return 'LATCH_OFF';
    return 'CALM';
  };

  const baaR = row.baa_r;
  const dgs2J = row.dgs2_j;
  const nfciJ = row.nfci_j;

  const pillars = [
    {
      id: 'P1',
      title_en: 'P1 · Top Fragility & Breadth',
      title_zh: 'P1 · 顶部脆弱性与宽度背离',
      route_badge_en: 'Route 1 · 125D -> 75D (-15% OTM)',
      route_badge_zh: 'Route 1 · 125D -> 75D (-15% OTM)',
      raw_score: p1Raw,
      entry_score: p1Ent,
      max_score: 45,
      raw_alert_lit: p1Raw > 0,
      entry_lit: p1Ent > 0,
      vol_blocked: p1Raw > 0 && p1Ent === 0,
      sensors: [
        {
          id: 'M0',
          name_en: 'M0 Six-Lights & Breadth Near High',
          name_zh: 'M0 六灯宏观 + 高位宽度背离',
          points: 35,
          route_tag_en: '125D -15%',
          route_tag_zh: '125D -15%',
          raw_alert: m0Raw,
          vol_gate_ok: vxn <= 22.0,
          entry_triggered: m0Ent,
          status_code: sensorStatus(m0Raw, m0Ent),
          vol_gate_rule_en: 'VXN <= 22.0',
          vol_gate_rule_zh: '低波门控 VXN <= 22.0',
          metrics: [
            { label_en: 'ATH Drawdown', label_zh: '距 ATH 回撤', value: `${fmtSigned(ddAthPct, 2)}% (>= -5%)`, passed: ddAthPct >= -5.0 },
            { label_en: '6-Lights Score', label_zh: '六灯危机得分', value: `${row.sc6 ?? 0} / 6`, passed: Number(row.sc6 ?? 0) >= 4 },
            { label_en: 'AD < 50DMA', label_zh: '宽度 AD < 50DMA', value: row.ad_b50 ? 'YES' : 'NO', passed: Boolean(row.ad_b50) },
            { label_en: 'VXN Gate', label_zh: 'VXN 门控', value: `${vxn.toFixed(1)} (<= 22)`, passed: vxn <= 22.0 },
          ],
          explanation_en: m0Ent
            ? 'Near-high macro/breadth warning active in low-vol zone.'
            : m0Raw
              ? `Near-high macro/breadth warning LIT, blocked by high VXN (${vxn.toFixed(1)} > 22).`
              : ddAthPct < -5.0
                ? `Already ${fmtSigned(ddAthPct, 1)}% off ATH (M0 only arms within -5% of highs).`
                : 'Near-high breadth and 6-Lights calm.',
          explanation_zh: m0Ent
            ? '高位六灯/宽度预警在低波窗口激活。'
            : m0Raw
              ? `高位宏观/宽度预警已亮，但 VXN ${vxn.toFixed(1)} > 22 高波禁追。`
              : ddAthPct < -5.0
                ? `当前已回调 ${fmtSigned(ddAthPct, 1)}%（M0 仅在距前高 -5% 内潜伏建仓）。`
                : '高位宽度与宏观六灯平稳。',
        },
        {
          id: 'M6',
          name_en: 'M6 Equal-Weight & Defensive Rotation',
          name_zh: 'M6 宽度塌缩 + 防御轮动',
          points: 20,
          route_tag_en: '125D -15%',
          route_tag_zh: '125D -15%',
          raw_alert: m6Raw,
          vol_gate_ok: vxn <= 25.0 && vr <= 0.92,
          entry_triggered: m6Ent,
          status_code: sensorStatus(m6Raw, m6Ent),
          vol_gate_rule_en: 'VXN <= 25.0 & VIX/3M <= 0.92',
          vol_gate_rule_zh: '低波门控 VXN <= 25 & VR <= 0.92',
          metrics: [
            { label_en: 'RSP/SPY < 50D', label_zh: '等权 RSP/SPY 破线', value: `${Number(row.rsp_spy).toFixed(3)} vs ${Number(row.rsp_sma50).toFixed(3)}`, passed: Number(row.rsp_spy) < Number(row.rsp_sma50) },
            { label_en: 'IWM/QQQ < 50D', label_zh: '小盘 IWM/QQQ 破线', value: `${Number(row.iwm_qqq).toFixed(3)} vs ${Number(row.iwm_sma50).toFixed(3)}`, passed: Number(row.iwm_qqq) < Number(row.iwm_sma50) },
            { label_en: 'Def/Tech 20D', label_zh: '防御/科技 20D', value: `${fmtSigned(Number(row.def_ret20), 2)}% (>= +2.5%)`, passed: Number(row.def_ret20) >= 2.5 },
          ],
          explanation_en: m6Ent
            ? 'Smart-money rotation into XLP/XLU/XLV while breadth deteriorates at cheap vol.'
            : m6Raw
              ? `Defensive rotation & breadth breakdown LIT, blocked by vol gate (VXN ${vxn.toFixed(1)}, VR ${vr.toFixed(2)}).`
              : 'No simultaneous breadth collapse + defensive rotation.',
          explanation_zh: m6Ent
            ? '大资金向防御板块轮动且市场宽度走弱，低波窗口允许建仓。'
            : m6Raw
              ? `宽度恶化+防御轮动结构已亮，但当前高波（VXN ${vxn.toFixed(1)}，VR ${vr.toFixed(2)}）禁追。`
              : '未同时出现等权/小盘破位与防御板块大幅跑赢。',
        },
      ],
    },
    {
      id: 'P2',
      title_en: 'P2 · Exogenous Shock & Options Desk',
      title_zh: 'P2 · 外生黑天鹅与期权台异动',
      route_badge_en: 'Route 1 · 125D -> 75D (-15% OTM)',
      route_badge_zh: 'Route 1 · 125D -> 75D (-15% OTM)',
      raw_score: p2Raw,
      entry_score: p2Ent,
      max_score: 40,
      raw_alert_lit: p2Raw > 0,
      entry_lit: p2Ent > 0,
      vol_blocked: p2Raw > 0 && p2Ent === 0,
      sensors: [
        {
          id: 'M2',
          name_en: 'M2 Skew / VVIX & Term Inflection',
          name_zh: 'M2 偏度 / VVIX 与期限拐点',
          points: 20,
          route_tag_en: '125D -15%',
          route_tag_zh: '125D -15%',
          raw_alert: m2Raw,
          vol_gate_ok: vxn <= 24.0 && vr <= 1.02,
          entry_triggered: m2Ent,
          status_code: sensorStatus(m2Raw, m2Ent),
          vol_gate_rule_en: 'VXN <= 24.0 & VIX/3M <= 1.02',
          vol_gate_rule_zh: '低波门控 VXN <= 24 & VR <= 1.02',
          metrics: [
            { label_en: 'SKEW 10D vs P75', label_zh: 'SKEW 10D 对比 P75', value: `${Number(row.skew10).toFixed(1)} / ${Number(row.skew_p75).toFixed(1)}`, passed: Number(row.skew10) >= Number(row.skew_p75) },
            { label_en: 'VVIX vs P75', label_zh: 'VVIX 对比 P75', value: `${Number(row.vvix).toFixed(1)} / ${Number(row.vvix_p75).toFixed(1)}`, passed: Number(row.vvix) >= Number(row.vvix_p75) },
            { label_en: '5D VR Jump', label_zh: '5日期限陡峭跳升', value: `${fmtSigned(vrJ5, 3)} (>= +0.06)`, passed: vrJ5 >= 0.06 },
          ],
          explanation_en: m2Ent
            ? 'Options desk pricing silent left-tail / term inflection while VXN <= 24.'
            : m2Raw
              ? `Options desk tail stress LIT (VVIX ${Number(row.vvix).toFixed(1)}, VR ${vr.toFixed(3)}), blocked by high vol (VXN ${vxn.toFixed(1)} > 24).`
              : 'Options skew and term-structure momentum normal.',
          explanation_zh: m2Ent
            ? '期权台隐含左尾偏度/期限斜率异动，且 VXN <= 24 处于廉价买盾期。'
            : m2Raw
              ? `期权台恐慌结构已亮（VVIX ${Number(row.vvix).toFixed(1)}，VR ${vr.toFixed(3)}），因 VXN ${vxn.toFixed(1)} > 24 高波禁追。`
              : '期权偏度与期限结构变化平稳。',
        },
        {
          id: 'M5',
          name_en: 'M5 Causal 4D Hamilton HMM Regime',
          name_zh: 'M5 因果 4D Hamilton HMM 状态跃迁',
          points: 20,
          route_tag_en: '125D -15%',
          route_tag_zh: '125D -15%',
          raw_alert: m5Raw,
          vol_gate_ok: vxn <= 24.0 && vr < 1.02 && Number(row.hmm_p5 ?? 0) < 0.4,
          entry_triggered: m5Ent,
          status_code: sensorStatus(m5Raw, m5Ent),
          vol_gate_rule_en: 'Fresh jump (P_t-5 < 40%) & VXN <= 24',
          vol_gate_rule_zh: '初入跃迁 (5日前<40%) 且 VXN <= 24',
          metrics: [
            { label_en: 'HMM Stress P(t)', label_zh: 'HMM 危机概率 P(t)', value: `${(Number(row.hmm_p) * 100).toFixed(1)}% (>= 55%)`, passed: Number(row.hmm_p) >= 0.55 },
            { label_en: 'HMM P(t-5)', label_zh: '5日前概率 P(t-5)', value: `${(Number(row.hmm_p5) * 100).toFixed(1)}% (< 40%)`, passed: Number(row.hmm_p5) < 0.4 },
            { label_en: 'Vol Gate', label_zh: '低波门控', value: `VXN ${vxn.toFixed(1)} / VR ${vr.toFixed(2)}`, passed: vxn <= 24.0 && vr < 1.02 },
          ],
          explanation_en: m5Ent
            ? 'Fresh 4D HMM transition into stress regime while option IV is still affordable.'
            : m5Raw
              ? `HMM in active crisis state (${(Number(row.hmm_p) * 100).toFixed(0)}%); M5 only buys on fresh onset when VXN <= 24.`
              : `HMM calm regime (Stress prob ${(Number(row.hmm_p) * 100).toFixed(1)}%).`,
          explanation_zh: m5Ent
            ? '4D 因果 HMM 刚从平静态跃迁至压力态且隐波尚便宜，触发建仓。'
            : m5Raw
              ? `HMM 已处于持续高压危机态（${(Number(row.hmm_p) * 100).toFixed(0)}%）；M5 仅在初入跃迁且 VXN <= 24 时买盾。`
              : `HMM 处于低波平静态（危机概率 ${(Number(row.hmm_p) * 100).toFixed(1)}%）。`,
        },
      ],
    },
    {
      id: 'P3',
      title_en: 'P3 · Slow-Bear Dead-Cat & Credit Squeeze',
      title_zh: 'P3 · 慢熊死猫跳与信用紧缩',
      route_badge_en: 'M4: 90D->30D (-10%) · M3: 125D->75D (-15%)',
      route_badge_zh: 'M4: 90D->30D (-10%) · M3: 125D->75D (-15%)',
      raw_score: p3Raw,
      entry_score: p3Ent,
      max_score: 45,
      raw_alert_lit: p3Raw > 0,
      entry_lit: p3Ent > 0,
      vol_blocked: p3Raw > 0 && p3Ent === 0,
      sensors: [
        {
          id: 'M4',
          name_en: 'M4 Slow-Bear Dead-Cat (+8% Latch)',
          name_zh: 'M4 慢熊死猫跳（+8% 滞回锁存）',
          points: 35,
          route_tag_en: '90D -> 30D (-10% OTM)',
          route_tag_zh: '90D -> 30D (-10% OTM)',
          raw_alert: m4Raw,
          vol_gate_ok: vxn <= 28.0 && vr <= 0.9,
          entry_triggered: m4Ent,
          status_code: sensorStatus(m4Raw, m4Ent, !latchArmed && qqq < sma200),
          vol_gate_rule_en: 'Latch ON & VXN <= 28.0 & VIX/3M <= 0.90',
          vol_gate_rule_zh: '锁存开启 且 VXN <= 28 & VIX/3M <= 0.90',
          metrics: [
            { label_en: '+8% Slow-Bear Latch', label_zh: '+8% 慢熊滞回锁存', value: latchArmed ? 'ARMED (ON)' : `OFF (CTA ${fmtSigned(ctaHi252Pct, 1)}%)`, passed: latchArmed },
            { label_en: 'QQQ < 200DMA & EWMAC < 0', label_zh: '破年线且 EWMAC < 0', value: `${qqq < sma200 ? '<200D' : '>200D'} · ${fmtSigned(ewmac, 2)}`, passed: qqq < sma200 && ewmac < 0 },
            { label_en: 'Dead-Cat QQQ > EMA20', label_zh: '反抽站上 EMA20', value: `$${qqq.toFixed(1)} vs $${ema20.toFixed(1)}`, passed: qqq > ema20 },
            { label_en: 'Complacency Gate', label_zh: '自满低波门控', value: `VXN ${vxn.toFixed(1)}<=28 · VR ${vr.toFixed(2)}<=0.90`, passed: vxn <= 28.0 && vr <= 0.9 },
          ],
          explanation_en: m4Ent
            ? 'Structural slow-bear dead-cat complacency confirmed! Route 2 fires 90D -10% OTM Put (recycle at <= 30 DTE).'
            : m4Raw
              ? `Latch ON & dead-cat bounce active, waiting for vol complacency (VXN ${vxn.toFixed(1)} <= 28, VR ${vr.toFixed(2)} <= 0.90).`
              : !latchArmed
                ? `Slow-Bear +8% Hysteresis Latch is OFF (Corr60 ${fmtSigned(corr60, 2)}, DualCTA ${fmtSigned(ctaHi252Pct, 1)}% since 1Y high) — blocks false non-slow-bear triggers.`
                : 'Latch ARMED; waiting for QQQ bounce above EMA20 with VXN <= 28 & VR <= 0.90.',
          explanation_zh: m4Ent
            ? '结构性慢熊死猫跳自满确认！Route 2 触发买入 90D -10% OTM Put（<= 30 DTE 回收残值）。'
            : m4Raw
              ? `慢熊锁存已开且出现死猫反抽，但等待波动率回落自满（VXN ${vxn.toFixed(1)}<=28、VR ${vr.toFixed(2)}<=0.90）。`
              : !latchArmed
                ? `慢熊 +8% 滞回锁存开关为 OFF（Corr60 ${fmtSigned(corr60, 2)}，双CTA 距1年高点 ${fmtSigned(ctaHi252Pct, 1)}%），自动过滤非慢熊假信号。`
                : '慢熊锁存已激活，等待 QQQ 反抽站上 EMA20 且 VXN <= 28、VIX/3M <= 0.90。',
        },
        {
          id: 'M3',
          name_en: 'M3 Credit & Financial Conditions Squeeze',
          name_zh: 'M3 信用利差与金融条件收紧',
          points: 20,
          route_tag_en: '125D -15%',
          route_tag_zh: '125D -15%',
          raw_alert: m3Raw,
          vol_gate_ok: vxn <= 26.0 && vr <= 0.92,
          entry_triggered: m3Ent,
          status_code: sensorStatus(m3Raw, m3Ent),
          vol_gate_rule_en: 'VXN <= 26.0 & VIX/3M <= 0.92',
          vol_gate_rule_zh: '低波门控 VXN <= 26 & VR <= 0.92',
          metrics: [
            { label_en: 'HYG/LQD < 50DMA', label_zh: '高收益债 HYG/LQD 破线', value: `${Number(row.hyg_lqd).toFixed(4)} vs ${Number(row.hyg_sma50).toFixed(4)}`, passed: Number(row.hyg_lqd) < Number(row.hyg_sma50) },
            { label_en: 'Baa 63D Rise', label_zh: 'Baa 63日走阔', value: baaR !== null ? `${fmtSigned(baaR, 2)}% (>= +0.15)` : 'n/a', passed: baaR !== null && baaR >= 0.15 },
            { label_en: '2Y / NFCI Jump', label_zh: '2Y / NFCI 跃升', value: `${dgs2J !== null ? fmtSigned(dgs2J, 2) : 'n/a'} / ${nfciJ !== null ? fmtSigned(nfciJ, 2) : 'n/a'}`, passed: (dgs2J !== null && dgs2J >= 0.4) || (nfciJ !== null && nfciJ >= 0.1) },
          ],
          explanation_en: m3Ent
            ? 'HY credit breakdown + macro tightening confirmed in low-vol window.'
            : m3Raw
              ? `Credit tightening structure LIT, blocked by elevated vol (VXN ${vxn.toFixed(1)} > 26 or VR ${vr.toFixed(2)} > 0.92).`
              : 'Credit spreads and financial conditions stable.',
          explanation_zh: m3Ent
            ? '高收益债相对走弱叠加宏观利差/金融条件收紧，低波窗口触发。'
            : m3Raw
              ? `信用与宏观紧缩结构已亮，但当前高波（VXN ${vxn.toFixed(1)} / VR ${vr.toFixed(2)}）禁追新单。`
              : '信用利差与金融条件整体稳定。',
        },
      ],
    },
  ];

  // 5 Live Sub-Engine Status Pills for Section 1 Hero Card
  const subEngines = [
    {
      id: 'leverage_cap',
      status_code: 'ENFORCED_120X',
      tone: 'mint',
      label_en: '1.20x Leverage Cap',
      label_zh: '1.20x 杠杆红线',
      value_en: `<= 1.200x · Box ${boxRatePct.toFixed(2)}%`,
      value_zh: `<= 1.200x · Box ${boxRatePct.toFixed(2)}%`,
      detail_en: `100% QQQ + 10% DBMF + 10% KMLM (EFFR ${effrPct.toFixed(2)}% + 35bp)`,
      detail_zh: `100% QQQ + 10% DBMF + 10% KMLM（EFFR ${effrPct.toFixed(2)}% + 35bp）`,
    },
    {
      id: 'sleeve_a',
      status_code: sleeveAStatus,
      tone: sleeveATone,
      label_en: '0.2% Baseline Put',
      label_zh: '0.2% 常态盾',
      value_en: sleeveAValEn,
      value_zh: sleeveAValZh,
      detail_en: sleeveADetEn,
      detail_zh: sleeveADetZh,
    },
    {
      id: 'sleeve_b',
      status_code: sleeveBStatus,
      tone: sleeveBTone,
      label_en: '1.0% Three-Pillar Put',
      label_zh: '1.0% 三支柱危机盾',
      value_en: sleeveBValEn,
      value_zh: sleeveBValZh,
      detail_en: sleeveBDetEn,
      detail_zh: sleeveBDetZh,
    },
    {
      id: 'slow_bear_latch',
      status_code: latchArmed ? 'ARMED' : 'OFF',
      tone: latchArmed ? 'lilac' : 'sky',
      label_en: 'M4 +8% Slow-Bear Latch',
      label_zh: 'M4 +8% 慢熊滞回锁存',
      value_en: latchArmed ? `ARMED · Reset ${above200}/10D` : `OFF · CTA ${fmtSigned(ctaHi252Pct, 1)}%`,
      value_zh: latchArmed ? `已锁存 · 复位 ${above200}/10天` : `未锁存 · CTA ${fmtSigned(ctaHi252Pct, 1)}%`,
      detail_en: latchArmed
        ? `Armed ${row.latch_arm}, Peak CTA ${fmtSigned(Number(row.latch_pk ?? 0), 1)}%, Corr60 ${fmtSigned(corr60, 2)}`
        : `Requires QQQ<200D, DD252<=-10%, Corr60<0 (${fmtSigned(corr60, 2)}), CTA>=+8%`,
      detail_zh: latchArmed
        ? `锁存于 ${row.latch_arm}，峰值 CTA ${fmtSigned(Number(row.latch_pk ?? 0), 1)}%，Corr60 ${fmtSigned(corr60, 2)}`
        : `需破200D、DD252<=-10%、Corr60<0（现 ${fmtSigned(corr60, 2)}）、CTA>=+8%`,
    },
    {
      id: 'cta_timer',
      status_code: c2mConfirmed ? 'CONFIRMED' : c2mActive ? 'RUNNING' : 'IDLE',
      tone: c2mConfirmed ? 'coral' : c2mActive ? 'amber' : 'muted',
      label_en: 'Dual-CTA 2M Timer',
      label_zh: '双CTA 2月熊市计时器',
      value_en: c2mActive ? `${c2mDays} / 60D (${c2mConfirmed ? 'CONFIRMED' : `Est ${c2mProjected}`})` : `IDLE (DD ${fmtSigned(ddAthPct, 1)}%)`,
      value_zh: c2mActive ? `持续 ${c2mDays} / 60天${c2mConfirmed ? ' · 已确认' : ` (预计 ${c2mProjected})`}` : `待命 (回撤 ${fmtSigned(ddAthPct, 1)}%)`,
      detail_en: c2mActive
        ? `Started ${c2mStart} · DBMF ${fmtSigned(dbAthPct, 1)}%, KMLM ${fmtSigned(kmAthPct, 1)}% since ATH`
        : 'Starts when QQQ ATH DD <= -12.0% continuously for 60 calendar days',
      detail_zh: c2mActive
        ? `起算日 ${c2mStart} · 自前高 DBMF ${fmtSigned(dbAthPct, 1)}%、KMLM ${fmtSigned(kmAthPct, 1)}%`
        : '当 QQQ 距历史高点连续 <= -12.0% 满 60 自然日触发 5 批换仓',
    },
  ];

  return {
    date: row.date,
    is_pit_replay: isPitReplay,
    market: {
      qqq_close: qqq,
      qqq_ath: ath,
      qqq_ath_date: row.ath_date,
      qqq_ath_dd_pct: ddAthPct,
      qqq_hi252_date: row.hi252_date,
      qqq_dd252_pct: dd252Pct,
      qqq_sma200: sma200,
      qqq_ema20: ema20,
      qqq_ewmac: ewmac,
      dbmf_close: Number(row.dbmf),
      kmlm_close: Number(row.kmlm),
      dbmf_ret_since_ath_pct: dbAthPct,
      kmlm_ret_since_ath_pct: kmAthPct,
      dual_cta_ret_since_ath_pct: ctaAthPct,
      dbmf_ret_since_hi252_pct: Number(row.db_hi252),
      kmlm_ret_since_hi252_pct: Number(row.km_hi252),
      dual_cta_ret_since_hi252_pct: ctaHi252Pct,
      dual_cta_corr60: corr60,
      vix,
      vxn,
      vix3m,
      vix_ratio: vr,
      vr_jump5: vrJ5,
      skew10: Number(row.skew10),
      skew_p75: Number(row.skew_p75),
      vvix: Number(row.vvix),
      vvix_p75: Number(row.vvix_p75),
      hmm_p: Number(row.hmm_p),
      hmm_p5: Number(row.hmm_p5),
      effr_pct: effrPct,
      box_rate_pct: boxRatePct,
      ibkr_rate_pct: ibkrRatePct,
    },
    command_center: {
      action_code: actionCode,
      severity,
      headline_en: headlineEn,
      headline_zh: headlineZh,
      summary_en: summaryEn,
      summary_zh: summaryZh,
      sub_engines: subEngines,
      target_strikes: {
        route1_125d_15otm: {
          target_dte: 125,
          roll_dte: 75,
          otm_pct: -15,
          exact_strike: strike15Exact,
          suggested_strike: strike15Round,
          budget_sleeve_a_pct: 0.2,
          budget_sleeve_b_pct: 1.0,
        },
        route2_m4_90d_10otm: {
          target_dte: 90,
          recycle_dte: 30,
          otm_pct: -10,
          exact_strike: strike10Exact,
          suggested_strike: strike10Round,
          budget_sleeve_b_pct: 1.0,
        },
      },
    },
    dual_cta_radar: {
      slow_bear_latch: {
        armed: latchArmed,
        arm_date: row.latch_arm ?? null,
        peak_cta_gain_pct: Number(row.latch_pk ?? 0),
        above_200dma_streak: above200,
        reset_target_days: 10,
        corr60,
        dual_cta_gain_since_hi252_pct: ctaHi252Pct,
        dbmf_gain_since_hi252_pct: Number(row.db_hi252),
        kmlm_gain_since_hi252_pct: Number(row.km_hi252),
        gates: [
          {
            id: 'qqq_below_200dma',
            label_en: 'QQQ < 200DMA',
            label_zh: 'QQQ 跌破 200DMA',
            passed: qqq < sma200,
            value: `$${qqq.toFixed(2)} vs $${sma200.toFixed(2)}`,
          },
          {
            id: 'qqq_dd252_le_10',
            label_en: 'QQQ 252D DD <= -10.0%',
            label_zh: 'QQQ 距252日高点 <= -10%',
            passed: dd252Pct <= -10.0,
            value: `${fmtSigned(dd252Pct, 2)}%`,
          },
          {
            id: 'corr60_neg',
            label_en: 'Corr60(DualCTA, QQQ) < 0',
            label_zh: '60日相关性 Corr60 < 0',
            passed: corr60 < 0,
            value: fmtSigned(corr60, 3),
          },
          {
            id: 'cta_gain_ge_8pct',
            label_en: 'DualCTA Gain >= +8.0%',
            label_zh: '双CTA 自1Y高点涨 >= +8%',
            passed: ctaHi252Pct >= 8.0,
            value: `${fmtSigned(ctaHi252Pct, 2)}%`,
          },
        ],
      },
      cont_2m_timer: {
        active: c2mActive,
        confirmed: c2mConfirmed,
        timer_start_date: c2mStart,
        continuous_cal_days: c2mDays,
        target_cal_days: 60,
        projected_confirm_date: c2mProjected,
        qqq_ath_dd_pct: ddAthPct,
        threshold_dd_pct: -12.0,
        dbmf_positive_since_ath: dbAthPct > 0,
        kmlm_positive_since_ath: kmAthPct > 0,
        dbmf_ret_since_ath_pct: dbAthPct,
        kmlm_ret_since_ath_pct: kmAthPct,
        dual_cta_ret_since_ath_pct: ctaAthPct,
        rotation_rule_en: 'Sell 5 equal tranches (20% each) spaced 5 trading days apart -> buy QQQ immediately (cancel remaining if QQQ DD > -12.0%).',
        rotation_rule_zh: '确认后分 5 批等额（每批 20%、间隔 5 交易日）卖出盈利 CTA 并即时买 QQQ（回撤缩窄至 > -12% 立即终止剩余批次）。',
        restore_rule_en: 'Mechanically hold rotated QQQ for 365 calendar days before restoring 10% DBMF + 10% KMLM (<= 1.200x cap).',
        restore_rule_zh: '机械持有换入的 QQQ 满 1 年（365 自然日）后再恢复 10% DBMF + 10% KMLM（严守 <= 1.200x 杠杆红线）。',
      },
      leverage_guard: {
        hard_cap: 1.2,
        target_gross: 1.2,
        target_qqq_pct: 100.0,
        target_dbmf_pct: 10.0,
        target_kmlm_pct: 10.0,
        target_debt_pct: 20.0,
        init_ltv_pct: 16.67,
        reg_t_crash_cushion_pct: -77.78,
        effr_pct: effrPct,
        box_rate_pct: boxRatePct,
        ibkr_rate_pct: ibkrRatePct,
      },
    },
    three_pillars: {
      ...stressPack,
      raw_crisis_prob: rawCrisisProb,
      entry_crisis_prob: entryCrisisProb,
      non_m4_entry_prob: nonM4EntProb,
      m4_entry_triggered: m4Ent,
      vol_gate_status: volGateStatus,
      vol_gate_reason_en: volGateReasonEn,
      vol_gate_reason_zh: volGateReasonZh,
      post_tp_lockout: {
        active: postTpLock,
        non_inv_streak: tpLockStreak,
        target_days: 5,
        last_tp_trigger_date: lastTpDate,
      },
      sleeve_a_gate: {
        status: sleeveAStatus,
        contango_streak: contangoStreak,
        target_days: 5,
        vix_ok: vix < 20.0,
        vix,
        vix_max: 20.0,
        vr,
      },
      pillars,
    },
    tp_and_microstructure: {
      tier1_partial: {
        rule_en: 'Return >= 5.0x AND VIX/VIX3M < 1.00 -> take 50% partial TP starting from shortest-DTE tranche.',
        rule_zh: '持仓回报 >= 5.0x 且 VIX/VIX3M < 1.00 -> 优先止盈最短剩余到期仓位的 50%。',
        contango_ok: vr < 1.0,
        vr,
      },
      tier2_full: {
        triggered_today: tpFullTriggered,
        vr_ok: tpFullVrOk,
        dd_ok: tpFullDdOk,
        vr,
        vr_target: 1.1,
        vr_gap: r3(1.1 - vr),
        dd_pct: ddAthPct,
        dd_target: -10.0,
        dd_gap_pp: r2(ddAthPct - -10.0),
        rule_en: 'VIX/VIX3M >= 1.10 AND QQQ ATH Drawdown <= -10.0% -> Liquidate 100% of ALL active puts.',
        rule_zh: 'VIX/VIX3M >= 1.10 且 QQQ 距历史高点回落 <= -10.0% -> 100% 全额清仓所有活跃 Put。',
      },
      deploy_5d_rule_en: 'Deploy realized TP cash equally over 5 trading days (1/5 per day) into QQQ; excess above 1.200x repays debt first.',
      deploy_5d_rule_zh: '止盈现金分 5 个交易日等额（每日 1/5）分批买入 QQQ；超出 1.200x 杠杆上限的部分优先偿还借款。',
      metrics: {
        vix,
        vxn,
        vix3m,
        vix_ratio: vr,
        vr_jump5: vrJ5,
        skew10: Number(row.skew10),
        skew_p75: Number(row.skew_p75),
        vvix: Number(row.vvix),
        vvix_p75: Number(row.vvix_p75),
        qqq_ath_dd_pct: ddAthPct,
      },
    },
  };
}

function getCombinedPitIndex(artifactObj, liveFeed, requestedAsOf) {
  let pitRows = artifactObj.pitRows;
  let pitByDate = artifactObj.pitByDate;
  let liveExtendedDays = 0;
  let fredAsOf = artifactObj.data.data_freshness?.fred_as_of ?? {};
  let effrAsOf = artifactObj.data.data_freshness?.effr_as_of ?? null;

  if (liveFeed) {
    const ext = extendV2LiveFromFeed(artifactObj, liveFeed, requestedAsOf);
    if (ext && ext.extraPitRows.length > 0) {
      pitRows = pitRows.concat(ext.extraPitRows);
      pitByDate = new Map(pitByDate);
      for (const r of ext.extraPitRows) pitByDate.set(r.date, r);
      liveExtendedDays = ext.extraPitRows.length;
      fredAsOf = ext.fredLatest;
      effrAsOf = ext.effrLatest;
    }
  }
  return { pitRows, pitByDate, liveExtendedDays, fredAsOf, effrAsOf };
}

export function loadCrisisObservatoryDashboard({
  asOf = null,
  window = DEFAULT_CRISIS_WINDOW,
  snapshotId = null,
  file = defaultFile,
  liveFeed = null,
} = {}) {
  if (asOf !== null && asOf !== undefined && asOf !== '' && !isIsoDate(asOf)) {
    fail('invalid_as_of', 400);
  }
  const winId = normalizeWindowId(window);
  const artifactObj = readArtifact(file);
  const requestedAsOf = asOf && isIsoDate(asOf) ? asOf : null;

  const feedStamp = liveFeed?.stamp ?? 'static';
  const cacheKey = `${artifactObj.snapshotId}|${winId}|${requestedAsOf ?? 'latest'}|${feedStamp}`;
  if (liveResponseCache.has(cacheKey)) {
    return liveResponseCache.get(cacheKey);
  }

  const { pitRows, liveExtendedDays, fredAsOf, effrAsOf } = getCombinedPitIndex(
    artifactObj,
    liveFeed,
    requestedAsOf,
  );

  // Select latest PIT row <= requestedAsOf
  let selectedRow = pitRows[pitRows.length - 1];
  if (requestedAsOf) {
    let found = null;
    for (let i = pitRows.length - 1; i >= 0; i -= 1) {
      if (pitRows[i].date <= requestedAsOf) {
        found = pitRows[i];
        break;
      }
    }
    if (!found) fail('as_of_before_history', 400);
    selectedRow = found;
  }

  const effectiveAsOf = selectedRow.date;
  const isPitReplay = Boolean(requestedAsOf && effectiveAsOf < pitRows[pitRows.length - 1].date);
  const activeWin = artifactObj.unpackedWindows[winId];

  const freshness = {
    market_as_of: effectiveAsOf,
    fred_as_of: fredAsOf,
    effr_as_of: effrAsOf,
    live_extended_days: liveExtendedDays,
    fetched_at: liveFeed?.fetchedAt ?? artifactObj.data.generated_at,
    source_summary_en: `Market closes through ${effectiveAsOf} · FRED macro & NY Fed EFFR (${effrAsOf ?? effectiveAsOf})`,
    source_summary_zh: `美股/波动率收盘截至 ${effectiveAsOf} · FRED 宏观利差与纽约联储 EFFR（${effrAsOf ?? effectiveAsOf}）`,
  };

  const payload = Object.freeze({
    version: CRISIS_OBSERVATORY_VERSION,
    strategy_code: CRISIS_OBSERVATORY_STRATEGY_CODE,
    snapshotId: snapshotId || artifactObj.snapshotId,
    generated_at: artifactObj.data.generated_at,
    as_of_date: effectiveAsOf,
    asOfDate: effectiveAsOf,
    dataThrough: effectiveAsOf,
    selected_window: winId,
    windows_meta: CRISIS_OBSERVATORY_WINDOWS.map(wid => {
      const w = artifactObj.unpackedWindows[wid];
      return {
        id: w.id,
        label_en: w.label_en,
        label_zh: w.label_zh,
        start_date: w.start_date,
        end_date: w.end_date,
        zero_splice: w.zero_splice,
      };
    }),
    ruleset: artifactObj.data.ruleset,
    data_freshness: freshness,
    live_cockpit: buildLiveCockpit(selectedRow, { isPitReplay }),
    backtest: {
      initial_capital: artifactObj.data.backtest.initial_capital,
      opra_provenance: artifactObj.data.backtest.opra_provenance,
      active_window: activeWin,
      window_kpis: {
        '11y_opra': {
          kpi_primary: artifactObj.unpackedWindows['11y_opra'].kpi_primary,
          kpi_stress: artifactObj.unpackedWindows['11y_opra'].kpi_stress,
          kpi_qqq: artifactObj.unpackedWindows['11y_opra'].kpi_qqq,
        },
        '5y_live': {
          kpi_primary: artifactObj.unpackedWindows['5y_live'].kpi_primary,
          kpi_stress: artifactObj.unpackedWindows['5y_live'].kpi_stress,
          kpi_qqq: artifactObj.unpackedWindows['5y_live'].kpi_qqq,
        },
      },
    },
  });

  if (liveResponseCache.size > 40) liveResponseCache.clear();
  liveResponseCache.set(cacheKey, payload);
  return payload;
}

export async function loadCrisisObservatoryDashboardLive(options = {}) {
  const liveFeed = await getLiveV2MarketFeed().catch(() => null);
  return loadCrisisObservatoryDashboard({ ...options, liveFeed });
}

export function loadCrisisObservatoryPitSnapshot({
  date = null,
  file = defaultFile,
  liveFeed = null,
} = {}) {
  if (!date || !isIsoDate(date)) fail('invalid_pit_date', 400);
  const artifactObj = readArtifact(file);
  const { pitRows } = getCombinedPitIndex(artifactObj, liveFeed, null);

  let matchIdx = -1;
  for (let i = pitRows.length - 1; i >= 0; i -= 1) {
    if (pitRows[i].date <= date) {
      matchIdx = i;
      break;
    }
  }
  if (matchIdx < 0) fail('pit_date_before_history', 400);
  const row = pitRows[matchIdx];
  const prevDate = matchIdx > 0 ? pitRows[matchIdx - 1].date : null;
  const nextDate = matchIdx + 1 < pitRows.length ? pitRows[matchIdx + 1].date : null;
  const latestDate = pitRows[pitRows.length - 1].date;

  return {
    version: CRISIS_OBSERVATORY_VERSION,
    strategy_code: CRISIS_OBSERVATORY_STRATEGY_CODE,
    requested_date: date,
    date: row.date,
    prev_date: prevDate,
    next_date: nextDate,
    latest_date: latestDate,
    live_cockpit: buildLiveCockpit(row, { isPitReplay: row.date < latestDate }),
  };
}

export async function loadCrisisObservatoryPitSnapshotLive(options = {}) {
  const liveFeed = await getLiveV2MarketFeed().catch(() => null);
  return loadCrisisObservatoryPitSnapshot({ ...options, liveFeed });
}
