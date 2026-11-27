import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const CRISIS_OBSERVATORY_VERSION = 'crisis-observatory-v3-plan-d';
export const CRISIS_OBSERVATORY_STRATEGY_CODE = 'PlanD_TalebB020M125_DualCTA_CONT2M';
export const CRISIS_OBSERVATORY_PUT_ENGINE = 'B020_M125';
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

function normCdfJS(x) {
  const t = 1 / (1 + 0.2316419 * Math.abs(x));
  const d = 0.3989422804014327 * Math.exp(-0.5 * x * x);
  const p =
    d *
    t *
    (0.31938153 +
      t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + 1.330274429 * t))));
  return x >= 0 ? 1 - p : p;
}

function bsmPutJS(S, K, T, r, q, sig) {
  if (T <= 1e-6 || sig <= 1e-6 || S <= 0 || K <= 0) return Math.max(0, K - S);
  const sq = Math.sqrt(T);
  const d1 = (Math.log(S / K) + (r - q + 0.5 * sig * sig) * T) / (sig * sq);
  const d2 = d1 - sig * sq;
  return Math.max(0, K * Math.exp(-r * T) * normCdfJS(-d2) - S * Math.exp(-q * T) * normCdfJS(-d1));
}

function evalSkewIvJS(S, K, T, r, q, vxnPct, coeffs) {
  const base = Math.max(0.08, Number(vxnPct) / 100);
  const fwd = S * Math.exp((r - q) * T);
  const lm = Math.max(-0.55, Math.min(0.35, Math.log(K / Math.max(fwd, 1e-6))));
  const c = Array.isArray(coeffs) && coeffs.length >= 4 ? coeffs : [1.0, -0.58, 0.85, -0.15];
  const mult = Math.max(0.65, Math.min(2.2, c[0] + c[1] * lm + c[2] * lm * lm + c[3] * Math.sqrt(Math.max(T, 0.01))));
  return Math.max(0.08, Math.min(1.6, base * mult));
}

const DEFAULT_OPRA_CAL_Z13 = [
  -0.083434, -0.186627, 0.015502, -0.028041, -0.40721, 0.039988,
  -0.587775, 0.03441, -0.011351, -0.130406, -0.045917, -0.008629, -0.11675,
];
const DEFAULT_OPRA_CAL_HS5 = [-5.243303, 0.02148, -0.342642, 0.024492, -3.358657];

function evalCalibratedOpraIvJS(S, K, remD, r, q, vxnPct, vixRatio, skewSpot, z13) {
  const beta = Array.isArray(z13) && z13.length === 13 ? z13 : DEFAULT_OPRA_CAL_Z13;
  const tEff = Math.max(Number(remD) || 1, 1) / 365;
  const fwd = Math.max(1e-6, S * Math.exp((r - q) * tEff));
  const logM = Math.log(Math.max(K, 1e-6) / fwd);
  const sig0 = Math.max(0.08, Math.min(1.0, vxnPct / 100));
  const dteC = Math.max(15, Math.min(220, Number(remD) || 90));
  const sqt = Math.sqrt(dteC / 365);
  const z = Math.max(-2.8, Math.min(1.5, logM / Math.max(sig0 * sqt, 1e-4)));
  const tau = Math.log(dteC / 90);
  const nu = Math.log(Math.max(0.7, Math.min(1.5, Number(vixRatio) || 0.9)));
  const nuPos = Math.max(0, nu);
  const sc = (Math.max(105, Math.min(175, Number(skewSpot) || 135)) - 135) / 100;
  const lv = Math.log(Math.max(10, Math.min(90, vxnPct)) / 22);
  const feats = [1, z, z * z, tau, nu, nuPos, tau * nu, tau * nuPos, z * tau, z * nu, sc, z * sc, lv];
  let logRat = 0;
  for (let i = 0; i < 13; i += 1) logRat += beta[i] * feats[i];
  return Math.max(0.06, Math.min(2.0, (vxnPct / 100) * Math.exp(logRat)));
}

function evalCalibratedOpraHsJS(mid, remD, vixPct, logM, hs5) {
  const g = Array.isArray(hs5) && hs5.length === 5 ? hs5 : DEFAULT_OPRA_CAL_HS5;
  const feats = [
    1,
    Math.log(Math.max(0.2, Math.min(200, mid))),
    Math.log(Math.max(15, Math.min(220, Number(remD) || 90)) / 90),
    Math.log(Math.max(10, Math.min(90, Number(vixPct) || 20)) / 20),
    Math.max(-0.28, Math.min(0.12, logM)),
  ];
  let acc = 0;
  for (let i = 0; i < 5; i += 1) acc += g[i] * feats[i];
  return Math.max(0.002, Math.min(0.1, Math.exp(acc)));
}

function estimateBsmOptionMicroJS(cl, vxn, effrPct, coeffs, opts = {}) {
  const r = Math.max(0, Number(effrPct ?? 4.0) / 100);
  const q = 0.006;
  const t125 = 125 / 365;
  const t90 = 90 / 365;
  const vixEff = Number.isFinite(Number(opts.vix)) && Number(opts.vix) > 0 ? Number(opts.vix) : Math.max(10, vxn * 0.85);
  const vrEff = Number.isFinite(Number(opts.vr)) && Number(opts.vr) > 0 ? Number(opts.vr) : 0.9;
  const skewEff = Number.isFinite(Number(opts.skewSpot)) && Number(opts.skewSpot) > 0 ? Number(opts.skewSpot) : 135;
  const z13 = opts.opraCalZ13 ?? DEFAULT_OPRA_CAL_Z13;
  const hs5 = opts.opraCalHs5 ?? DEFAULT_OPRA_CAL_HS5;

  const kAtm = Math.round(cl);
  const k10 = Math.round(cl * 0.9);
  const k15 = Math.round(cl * 0.85);
  const k20 = Math.round(cl * 0.8);
  const ivAtm = evalCalibratedOpraIvJS(cl, kAtm, 125, r, q, vxn, vrEff, skewEff, z13);
  const iv10 = evalCalibratedOpraIvJS(cl, k10, 125, r, q, vxn, vrEff, skewEff, z13);
  const iv15 = evalCalibratedOpraIvJS(cl, k15, 125, r, q, vxn, vrEff, skewEff, z13);
  const iv20 = evalCalibratedOpraIvJS(cl, k20, 125, r, q, vxn, vrEff, skewEff, z13);
  // UNIFORM -15% OTM (k15) for M4 90D under Plan D Taleb rules
  const iv90 = evalCalibratedOpraIvJS(cl, k15, 90, r, q, vxn, vrEff, skewEff, z13);
  const mid15 = Math.max(0.05, bsmPutJS(cl, k15, t125, r, q, iv15));
  const mid90 = Math.max(0.05, bsmPutJS(cl, k15, t90, r, q, iv90));
  const fwd125 = cl * Math.exp((r - q) * t125);
  const fwd90 = cl * Math.exp((r - q) * t90);
  const hs15 = evalCalibratedOpraHsJS(mid15, 125, vixEff, Math.log(Math.max(k15, 1) / Math.max(fwd125, 1)), hs5);
  const hs90 = evalCalibratedOpraHsJS(mid90, 90, vixEff, Math.log(Math.max(k15, 1) / Math.max(fwd90, 1)), hs5);
  const bid15 = Math.max(0.01, mid15 * (1 - hs15));
  const ask15 = mid15 * (1 + hs15);
  const bid90 = Math.max(0.01, mid90 * (1 - hs90));
  const ask90 = mid90 * (1 + hs90);
  const lmt15 = mid15 + 0.35 * (ask15 - bid15) * 0.5 + 0.0065;
  const lmt90 = mid90 + 0.35 * (ask90 - bid90) * 0.5 + 0.0065;
  return {
    opra_src: 'bsm_est',
    opra_sk20_10: r3(iv20 / Math.max(iv10, 0.05)),
    opra_sk15_atm: r3(iv15 / Math.max(ivAtm, 0.05)),
    p125_k: k15,
    p125_dte: 125,
    p125_bid: r2(bid15),
    p125_ask: r2(ask15),
    p125_mid: r2(mid15),
    p125_lmt: r3(lmt15),
    p125_hs: r2(hs15 * 100),
    p125_iv: r1(iv15 * 100),
    p125_lot_pct: r3((lmt15 / Math.max(cl, 1)) * 100),
    p125_mid_pct: r3((mid15 / Math.max(cl, 1)) * 100),
    p90_k: k15,
    p90_dte: 90,
    p90_bid: r2(bid90),
    p90_ask: r2(ask90),
    p90_mid: r2(mid90),
    p90_lmt: r3(lmt90),
    p90_hs: r2(hs90 * 100),
    p90_iv: r1(iv90 * 100),
    p90_lot_pct: r3((lmt90 / Math.max(cl, 1)) * 100),
    p90_mid_pct: r3((mid90 / Math.max(cl, 1)) * 100),
  };
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

    // Contango streak & Post-TP 5D Lockout (Plan D tp_near_itm_late5x: (VR>=1.10 & Near-ITM) OR VIX>=45.0)
    contangoStreak = vr < 1.0 ? contangoStreak + 1 : 0;
    const openStrikes = Array.isArray(tail.put_gate_state?.open_puts_strikes)
      ? tail.put_gate_state.open_puts_strikes
      : [];
    const nearItmLive = openStrikes.length
      ? openStrikes.some(k => cl <= Number(k) * 1.05)
      : ddAth <= -0.11;
    if ((vr >= 1.1 && nearItmLive) || vix >= 45.0) {
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

    const skewSpotCur = Number(yf.SKEW[yf.SKEW.length - 1] ?? skew10Now);
    const bsmMicro = estimateBsmOptionMicroJS(cl, vxn, effrPct, tail.opra_skew_coeffs, {
      vix,
      vr,
      skewSpot: skewSpotCur,
      opraCalZ13: tail.opra_cal_z13,
      opraCalHs5: tail.opra_cal_hs5,
    });

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
      skew_spot: r2(skewSpotCur),
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
      m7g_slots: (() => {
        const p1E = Math.min(45, (m0Entry ? 35 : 0) + (m6Entry ? 20 : 0));
        const p2E = Math.min(40, (m2Entry ? 20 : 0) + (m5Entry ? 20 : 0));
        const scE = Math.min(100, p1E + p2E + (m3Entry ? 10 : 0) + (m4Entry ? 35 : 0));
        return scE >= 65 ? 3 : scE >= 45 ? 2 : scE >= 35 ? 1 : 0;
      })(),
      ...bsmMicro,
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

function crashToCallPctJS(grossLev, maintMargin) {
  const lev = Math.max(1.01, Number(grossLev) || 1.2);
  const debtOverAssets = (lev - 1.0) / lev;
  const x = 1.0 - debtOverAssets / Math.max(0.01, 1.0 - maintMargin);
  return r2(-x * 100.0);
}

export function buildLiveCockpit(
  row,
  { isPitReplay = false, rollEcon = null, openStrikes = null, liveGrossLev = null, peakDriftLev = 1.257 } = {},
) {
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

  // Plan D exact scoring: min(100, P1 + P2 + 10*M3 + 35*M4_latch_v2) -> M7G_tier_45_65 (1-3 slots x 1.25% NAV)
  const p1Raw = Math.min(45, (m0Raw ? 35 : 0) + (m6Raw ? 20 : 0));
  const p2Raw = Math.min(40, (m2Raw ? 20 : 0) + (m5Raw ? 20 : 0));
  const p3Raw = Math.min(45, (m4Raw ? 35 : 0) + (m3Raw ? 10 : 0));
  const rawCrisisProb = Math.min(100, p1Raw + p2Raw + p3Raw);
  const rawTargetSlots = rawCrisisProb >= 65 ? 3 : rawCrisisProb >= 45 ? 2 : rawCrisisProb >= 35 ? 1 : 0;

  const p1Ent = Math.min(45, (m0Ent ? 35 : 0) + (m6Ent ? 20 : 0));
  const p2Ent = Math.min(40, (m2Ent ? 20 : 0) + (m5Ent ? 20 : 0));
  const p3Ent = Math.min(45, (m4Ent ? 35 : 0) + (m3Ent ? 10 : 0));
  const nonM4EntProb = Math.min(100, p1Ent + p2Ent + (m3Ent ? 10 : 0));
  const entryCrisisProb = Math.min(100, p1Ent + p2Ent + p3Ent);
  const entrySlotsFromScore =
    entryCrisisProb >= 65 ? 3 : entryCrisisProb >= 45 ? 2 : entryCrisisProb >= 35 ? 1 : 0;
  const rowM7Slots = row.m7g_slots != null ? Number(row.m7g_slots) : entrySlotsFromScore;
  const m7VolGateOk = !postTpLock && vr < 1.02 && (m4Ent ? vxn <= 28.0 && vr <= 0.9 : vxn <= 27.0);
  const actionableSlots = m7VolGateOk ? Math.min(3, Math.max(entrySlotsFromScore, rowM7Slots)) : 0;
  const actionableBudgetPct = r2(actionableSlots * 1.25);

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

  // Vol-gate status (transparently separates Track A raw alert from Track B vol-gated M7G entry!)
  let volGateStatus = 'ENTRY_ALLOWED';
  let volGateReasonEn = 'Low-to-moderate vol regime (VXN <= 27 & VR < 1.02): M7G ladder slots permitted whenever pillars fire.';
  let volGateReasonZh = '中低波窗口（VXN <= 27 且 VR < 1.02）：只要三支柱得分达标即可按阶梯开槽（1-3 x 1.25%）。';
  if (postTpLock) {
    volGateStatus = 'POST_TP_LOCKOUT';
    volGateReasonEn = `Post-TP 5D contango lockout active (${tpLockStreak}/5 consecutive days VIX/VIX3M < 1.00 since ${lastTpDate ?? 'last TP'}). BOTH Base & M7G books locked.`;
    volGateReasonZh = `止盈后 5 日正向期限结构锁仓中（自 ${lastTpDate ?? '上次止盈'} 起连续 VIX/VIX3M < 1.00：${tpLockStreak}/5 天），常态与危机双账本均暂停追买新 Put。`;
  } else if (vr >= 1.02 || vxn > (m4Ent ? 28.0 : 27.0)) {
    volGateStatus = 'HIGH_VOL_NO_CHASE';
    volGateReasonEn = `High-vol no-chase guard active (VXN ${vxn.toFixed(1)}, VIX/VIX3M ${vr.toFixed(3)}): Track A raw alerts (${rawCrisisProb} / ${rawTargetSlots} slots) reflect live stress, while Track B blocks paying panic IV.`;
    volGateReasonZh = `高波禁追保护生效（VXN ${vxn.toFixed(1)}，VIX/VIX3M ${vr.toFixed(3)}）：轨道 A 原始预警（${rawCrisisProb} / ${rawTargetSlots} 槽）如实反映实时压力，轨道 B 禁止高波追买昂贵新 Put。`;
  }

  // Sleeve A status (B020 Baseline Floor: 0.20% NAV, VIX <= 20.0 & VIX/VIX3M < 1.02 & not in 5D Lockout, Hard 75D roll)
  let sleeveAStatus = 'OPEN_READY';
  let sleeveATone = 'mint';
  let sleeveAValEn = 'READY · 0.20% (125D -15%)';
  let sleeveAValZh = '允许建仓/75D强滚';
  let sleeveADetEn = `VIX ${vix.toFixed(1)} <= 20.0 & VR ${vr.toFixed(3)} < 1.02 & unlocked. Maintain 0.20% NAV 125D -15% OTM Put with Hard 75D roll.`;
  let sleeveADetZh = `VIX ${vix.toFixed(1)} <= 20.0 且 VIX/3M ${vr.toFixed(3)} < 1.02 且未锁仓，正常维护 0.20% NAV 125D -15% OTM 常态盾（75D 强制滚仓）。`;
  if (postTpLock) {
    sleeveAStatus = 'POST_TP_LOCKOUT';
    sleeveATone = 'coral';
    sleeveAValEn = `LOCKED ${tpLockStreak}/5D`;
    sleeveAValZh = `止盈锁仓 ${tpLockStreak}/5 天`;
    sleeveADetEn = `5D post-TP contango lockout blocks new 0.20% entries (${tpLockStreak}/5D VR < 1.00).`;
    sleeveADetZh = `止盈后 5 日正向锁仓中（${tpLockStreak}/5 天），暂不重开 0.20% 常态盾。`;
  } else if (vr >= 1.02) {
    sleeveAStatus = 'PAUSED_INVERTED';
    sleeveATone = 'coral';
    sleeveAValEn = `INVERTED (${vr.toFixed(2)}) · WATCH TP`;
    sleeveAValZh = `倒挂 (${vr.toFixed(2)}) · 盯止盈`;
    sleeveADetEn = 'VIX/VIX3M >= 1.02 inverted: no new 0.20% buys; existing put watches Near-ITM / VIX>=45 TP or Hard 75D salvage.';
    sleeveADetZh = '期限结构倒挂 >= 1.02：暂停新开 0.20% 常态盾；已有仓位盯紧近实值/VIX>=45 止盈或 75D 回收。';
  } else if (vix > 20.0) {
    sleeveAStatus = 'PAUSED_VIX_GT_20';
    sleeveATone = 'amber';
    sleeveAValEn = `PAUSED (VIX ${vix.toFixed(1)} > 20)`;
    sleeveAValZh = `暂停新开 (VIX ${vix.toFixed(1)} > 20)`;
    sleeveADetEn = 'VIX > 20.0 pauses new 0.20% baseline buys; existing put salvages at <= 75 DTE if VIX stays > 20.';
    sleeveADetZh = 'VIX > 20.0 暂停新开 0.20% 常态盾；已有仓位到 <= 75 DTE 时回收残值落袋。';
  }

  // Sleeve B status (M7G_tier_45_65 Graded Ladder: 1-3 Slots x 1.25% NAV = up to 3.75% NAV, UNIFORM -15% OTM!)
  const sleeveBM4Ready = actionableSlots > 0 && m4Ent;
  const sleeveBR1Ready = actionableSlots > 0 && !m4Ent;
  let sleeveBStatus = 'STANDBY';
  let sleeveBTone = 'muted';
  let sleeveBValEn = '0/3 SLOTS (0.00%)';
  let sleeveBValZh = '0/3 槽待命 (0.00%)';
  let sleeveBDetEn = 'No vol-gated crisis pillar >= 35. Core 1.20x QQQ + Dual-CTA compounds unencumbered.';
  let sleeveBDetZh = '三支柱未达低波开槽阈值（>=35），1.20x 核心仓与双CTA 顺畅复利。';
  if (sleeveBM4Ready) {
    sleeveBStatus = 'OPEN_ROUTE2_M4';
    sleeveBTone = 'lilac';
    sleeveBValEn = `FIRE M4 · ${actionableSlots}/3 (${actionableBudgetPct.toFixed(2)}%) · 90D -15%`;
    sleeveBValZh = `触发 M4 · ${actionableSlots}/3 槽 (${actionableBudgetPct.toFixed(2)}%) · 90D -15%`;
    sleeveBDetEn = `Slow-Bear +8% Latch ON + Dead-Cat Bounce + VXN <= 28 & VR <= 0.90 -> ${actionableSlots} slot(s) x 1.25% NAV in UNIFORM 90D -15% OTM Put (Hard 30D roll).`;
    sleeveBDetZh = `慢熊 +8% 磁滞锁存开启 + 死猫反抽 + VXN<=28 & VR<=0.90 -> 激活 ${actionableSlots} 槽 x 1.25% NAV，统一买 90D -15% OTM（30D 强制滚仓）。`;
  } else if (sleeveBR1Ready) {
    sleeveBStatus = 'OPEN_ROUTE1_125D';
    sleeveBTone = 'amber';
    sleeveBValEn = `FIRE ${actionableSlots}/3 (${actionableBudgetPct.toFixed(2)}%) · 125D -15%`;
    sleeveBValZh = `触发 ${actionableSlots}/3 槽 (${actionableBudgetPct.toFixed(2)}%) · 125D -15%`;
    sleeveBDetEn = `Crisis score ${entryCrisisProb} (>=35: 1s, >=45: 2s, >=65: 3s) in low-vol window -> ${actionableSlots} slot(s) x 1.25% NAV in 125D -15% OTM Put (Hard 75D roll).`;
    sleeveBDetZh = `危机得分 ${entryCrisisProb}（>=35开1槽 / >=45开2槽 / >=65开3槽）且处低波窗口 -> 激活 ${actionableSlots} 槽 x 1.25% NAV，买 125D -15% OTM（75D 强滚）。`;
  } else if (postTpLock) {
    sleeveBStatus = 'POST_TP_LOCKOUT';
    sleeveBTone = 'coral';
    sleeveBValEn = `LOCKED ${tpLockStreak}/5D (RAW ${rawTargetSlots}/3)`;
    sleeveBValZh = `止盈锁仓 ${tpLockStreak}/5 天（原 ${rawTargetSlots}/3）`;
    sleeveBDetEn = `Raw alerts ${rawCrisisProb} (${rawTargetSlots}/3 slots) lit, but 5D post-TP contango lockout blocks re-entry until 5D VR < 1.00.`;
    sleeveBDetZh = `原始结构预警 ${rawCrisisProb}（对应 ${rawTargetSlots}/3 槽）已亮，但处于止盈后 5 日锁仓期，须待连续 5 日 VIX/3M < 1.00 解锁。`;
  } else if (rawCrisisProb >= 35 || stressPack.live_stress_index >= 50) {
    sleeveBStatus = 'RAW_ALERT_HIGH_VOL';
    sleeveBTone = 'amber';
    sleeveBValEn = `RAW ${rawTargetSlots}/3 (${rawCrisisProb}) · NO CHASE`;
    sleeveBValZh = `预警 ${rawTargetSlots}/3 (${rawCrisisProb}) · 禁追`;
    sleeveBDetEn = `Live Stress ${stressPack.live_stress_index}/100 & Raw Score ${rawCrisisProb} (${rawTargetSlots}/3 slots) lit, but high IV blocks chasing new puts.`;
    sleeveBDetZh = `实时压力 ${stressPack.live_stress_index}/100、原始得分 ${rawCrisisProb}（${rawTargetSlots}/3 槽）已亮，高波禁追新单，持仓盯止盈。`;
  }

  // Exact live target strike: UNIFORM -15% OTM (K = 0.85 * S) for BOTH 125D AND 90D M4!
  const strike15Exact = r2(qqq * 0.85);
  const strike15Round = Math.round(qqq * 0.85);

  // Right-Tail Take-Profit (`tp_near_itm_late5x`)
  const activeStrikesArr = Array.isArray(openStrikes) && openStrikes.length ? openStrikes.map(Number).filter(Number.isFinite) : [];
  const refStrikeForTp = activeStrikesArr.length ? Math.max(...activeStrikesArr) : strike15Round;
  const nearItmThresholdSpot = r2(refStrikeForTp * 1.05);
  const nearItmOk = activeStrikesArr.length ? qqq <= nearItmThresholdSpot : ddAthPct <= -11.0;
  const tpFullVrOk = vr >= 1.1;
  const tpVixPanicOk = vix >= 45.0;
  const tpFullTriggered = (tpFullVrOk && nearItmOk) || tpVixPanicOk;

  // Natural-Drift Box Leverage Guard (NO daily 1.20x forced drawdown cap!)
  const liveLev =
    Number.isFinite(Number(liveGrossLev)) && Number(liveGrossLev) > 0.8
      ? r3(Number(liveGrossLev))
      : r3(Math.min(1.27, Math.max(1.16, 1.2 / Math.max(0.92, 1.0 + Math.min(0, ddAthPct / 100.0) * 0.35))));
  const liveLtvPct = r2(((liveLev - 1.0) / Math.max(liveLev, 1.0)) * 100.0);
  const pmCrashLivePct = crashToCallPctJS(liveLev, 0.15);
  const regTCrashLivePct = crashToCallPctJS(liveLev, 0.25);
  const boxAnnualDragPct = r2(0.2 * boxRatePct);

  const rollStats = {
    gross_turnover_pct_nav_yr: Number(rollEcon?.put_gross_turnover_pct_nav_yr ?? 6.13),
    roll_salvage_pct: Number(rollEcon?.put_roll_salvage_pct ?? 67.8),
    true_net_bleed_pct_nav_yr: Number(rollEcon?.put_true_net_bleed_pct_nav_yr ?? 2.03),
    put_net_pnl_usd: Number(rollEcon?.put_net_pnl_usd ?? 121171.24),
    put_payoff_mult: Number(rollEcon?.put_payoff_mult ?? 1.58),
  };

  // Master Command Center Action Directive (Plan D Double-Champion)
  let actionCode = 'HOLD_STEADY_CORE';
  let severity = 'calm';
  let headlineEn = `Calm Compounding · Hold 100% QQQ + 10% DBMF + 10% KMLM (Live ${liveLev.toFixed(2)}x · Natural Drift)`;
  let headlineZh = `平稳复利期 · 持有 100% QQQ + 10% DBMF + 10% KMLM（当前 ${liveLev.toFixed(2)}x · 无底部砍仓线）`;
  let summaryEn = `Live Stress ${stressPack.live_stress_index}/100 (${stressPack.live_stress_label_en}). Natural-drift Box stack (no forced crash liquidation; quarterly 1.20x calibration) + B020_M125 Uniform -15% OTM Put engine.`;
  let summaryZh = `实时危机压力 ${stressPack.live_stress_index}/100（${stressPack.live_stress_label_zh}）。无强制底部砍仓线的 Box 叠加（平稳季调回 1.20x）+ B020_M125 统一 -15% OTM 期权核平稳运行。`;

  if (tpFullTriggered) {
    actionCode = 'TRIGGER_FULL_TP';
    severity = 'action';
    headlineEn = tpVixPanicOk
      ? `RIGHT-TAIL FULL TP ARMED · VIX Panic (${vix.toFixed(1)} >= 45.0) -> Liquidate 100% Active Puts`
      : `RIGHT-TAIL FULL TP ARMED · Inverted (${vr.toFixed(3)} >= 1.10) & Near-ITM (QQQ <= $${nearItmThresholdSpot.toFixed(1)}) -> Liquidate 100%`;
    headlineZh = tpVixPanicOk
      ? `右尾全额止盈触发 · VIX 恐慌爆表（${vix.toFixed(1)} >= 45.0）-> T+1 100% 清仓活跃 Put`
      : `右尾全额止盈触发 · 期限倒挂（${vr.toFixed(3)} >= 1.10）且近实值（QQQ <= $${nearItmThresholdSpot.toFixed(1)}）-> T+1 100% 清仓`;
    summaryEn = 'Liquidate 100% of active Base & M7G puts at T+1 Close, reinvest proceeds 100% lump-sum into QQQ at T+1, and lock BOTH books for 5 consecutive contango days (VIX/VIX3M < 1.00).';
    summaryZh = 'T+1 收盘 100% 清仓全部活跃 Put，所得收益 T+1 一次性 100% 全额回买 QQQ（绝不分批踏空），并对常态/危机双账本开启止盈后 5 日正向期限结构锁仓。';
  } else if (c2mConfirmed && (dbAthPct > 0 || kmAthPct > 0)) {
    actionCode = 'TRIGGER_CTA_ROTATION';
    severity = 'action';
    headlineEn = `DUAL-CTA CONT_2M CONFIRMED (${c2mDays}d <= -12%) · Rotate Winning CTA -> QQQ in 5 Tranches (1Y LTCG)`;
    headlineZh = `双CTA CONT_2M 慢熊确认（连续 ${c2mDays} 天 <= -12%）· 分 5 批切出盈利 CTA 买 QQQ（1年 LTCG 锁）`;
    summaryEn = `QQQ stayed <= -12% for ${c2mDays} continuous calendar days. Sell profitable DBMF/KMLM sleeve(s) in 5 equal 20% tranches spaced 5 trading days apart into QQQ; mechanically hold 365 days before restoring 1.20x.`;
    summaryZh = `QQQ 已连续 ${c2mDays} 自然日处于 <= -12% 回撤区间。对自前高盈利 > 0% 的 CTA 分 5 批（每次 20%、间隔 5 交易日）换入 QQQ，并机械锁定持有 365 天后再恢复 1.20x。`;
  } else if (sleeveBM4Ready) {
    actionCode = 'OPEN_SLEEVE_B_M4';
    severity = 'action';
    headlineEn = `M4 +8% LATCH DEAD-CAT FIRED · Buy ${actionableSlots}/3 Slot(s) (${actionableBudgetPct.toFixed(2)}% NAV) 90D -15% OTM QQQ Put`;
    headlineZh = `M4 +8% 磁滞锁存死猫跳触发 · T+1 买入 ${actionableSlots}/3 槽（${actionableBudgetPct.toFixed(2)}% NAV）90D -15% OTM Put`;
    summaryEn = `Slow-Bear +8% Latch ARMED + QQQ < 200DMA + EWMAC < 0 + QQQ > EMA20 + VXN ${vxn.toFixed(1)} <= 28 & VR ${vr.toFixed(3)} <= 0.90. UNIFORM -15% OTM ($${strike15Round} strike), Hard 30D roll.`;
    summaryZh = `慢熊 +8% 磁滞锁存已开，满足破年线反抽 EMA20 且波动率自满（VXN ${vxn.toFixed(1)} <= 28、VR ${vr.toFixed(3)} <= 0.90）。统一买 90D -15% OTM（$${strike15Round} 行权价），30D 强制滚仓。`;
  } else if (sleeveBR1Ready) {
    actionCode = 'OPEN_SLEEVE_B_ROUTE1';
    severity = 'action';
    headlineEn = `M7G GRADED LADDER FIRED (${entryCrisisProb} -> ${actionableSlots}/3 Slots) · Buy ${actionableBudgetPct.toFixed(2)}% NAV 125D -15% OTM Put`;
    headlineZh = `M7G 阶梯危机盾触发（得分 ${entryCrisisProb} -> ${actionableSlots}/3 槽）· T+1 买入 ${actionableBudgetPct.toFixed(2)}% NAV 125D -15% OTM Put`;
    summaryEn = `Low-vol structural warning lit (Score ${entryCrisisProb}: >=35 1s, >=45 2s, >=65 3s). Open/scale up to ${actionableSlots} x 1.25% NAV in 125D -15% OTM ($${strike15Round} strike) with Hard 75D roll (recovers ${rollStats.roll_salvage_pct}% salvage).`;
    summaryZh = `低波结构预警达标（得分 ${entryCrisisProb}：>=35 开1槽、>=45 开2槽、>=65 开3槽）。建仓/加码至 ${actionableSlots} x 1.25% NAV 的 125D -15% OTM（$${strike15Round}），75D 强制早滚回收 ${rollStats.roll_salvage_pct}% 残值。`;
  } else if (stressPack.live_stress_index >= 50 || rawCrisisProb >= 35 || postTpLock) {
    actionCode = 'HOLD_HIGH_VOL_WATCH_TP';
    severity = stressPack.live_stress_index >= 75 ? 'crisis' : 'elevated';
    headlineEn = postTpLock
      ? `ACTIVE STRESS (${stressPack.live_stress_index}/100) · 5D Post-TP Lockout (${tpLockStreak}/5D) · Natural Drift ${liveLev.toFixed(2)}x (No Forced Sell)`
      : `HIGH-VOL STRESS (${stressPack.live_stress_index}/100) · Raw ${rawCrisisProb} (${rawTargetSlots}/3 Slots) · No IV Chasing, Watch Right-Tail TP`;
    headlineZh = postTpLock
      ? `高压危机态（压力 ${stressPack.live_stress_index}/100）· 止盈后 5D 锁仓（${tpLockStreak}/5 天）· 允许自然漂移 ${liveLev.toFixed(2)}x 绝不底部砍仓`
      : `高压警戒态（压力 ${stressPack.live_stress_index}/100）· 原始预警 ${rawCrisisProb}（${rawTargetSlots}/3 槽）· 高波禁追，盯紧右尾止盈`;
    summaryEn = `QQQ ${fmtSigned(ddAthPct, 2)}% from ATH, VIX ${vix.toFixed(2)}, VXN ${vxn.toFixed(2)}, VIX/VIX3M ${vr.toFixed(3)}. Natural leverage ${liveLev.toFixed(2)}x (PM cushion ${pmCrashLivePct}%). ${c2mActive ? `CONT_2M timer running: ${c2mDays}/60d.` : `Watch Full TP (VR>=1.10 & Near-ITM <=$${nearItmThresholdSpot.toFixed(0)} OR VIX>=45).`}`;
    summaryZh = `QQQ 距前高 ${fmtSigned(ddAthPct, 2)}%，VIX ${vix.toFixed(2)}，VXN ${vxn.toFixed(2)}，VIX/VIX3M ${vr.toFixed(3)}。当前杠杆 ${liveLev.toFixed(2)}x（IBKR PM 强平垫 ${pmCrashLivePct}%）。${c2mActive ? `双CTA CONT_2M 计时运行中：连续 ${c2mDays}/60 天。` : `盯防右尾止盈（VR>=1.10 且近实值 <=$${nearItmThresholdSpot.toFixed(0)} 或 VIX>=45）。`}`;
  } else if (sleeveAStatus === 'OPEN_READY') {
    actionCode = 'OPEN_SLEEVE_A';
    severity = 'calm';
    headlineEn = `Calm Low-Vol · Core ${liveLev.toFixed(2)}x Active + B020 Baseline (0.20% NAV 125D -15% OTM) Ready`;
    headlineZh = `低波顺风期 · 核心 ${liveLev.toFixed(2)}x 运行 + B020 常态盾（0.20% NAV 125D -15% OTM）可建仓/75D强滚`;
    summaryEn = `VIX ${vix.toFixed(2)} <= 20.0 & VIX/VIX3M ${vr.toFixed(3)} < 1.02. Maintain 0.20% NAV 125D -15% OTM baseline Put (Hard 75D roll -> ${rollStats.true_net_bleed_pct_nav_yr}% NAV/yr true net bleed) + 20% Dual-CTA Box stack.`;
    summaryZh = `VIX ${vix.toFixed(2)} <= 20.0 且 VIX/VIX3M ${vr.toFixed(3)} < 1.02。维持 0.20% NAV 125D -15% OTM 常态尾盾（75D 强滚真实净耗仅 ${rollStats.true_net_bleed_pct_nav_yr}% NAV/yr）与 20% 双CTA Box 叠加。`;
  }

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
      route_badge_en: 'M4: 90D->30D (-15% OTM) · M3: 125D->75D (-15% OTM)',
      route_badge_zh: 'M4: 90D->30D (-15% OTM) · M3: 125D->75D (-15% OTM)',
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
          name_zh: 'M4 慢熊死猫跳（+8% 磁滞锁存）',
          points: 35,
          route_tag_en: '90D -> 30D (-15% OTM)',
          route_tag_zh: '90D -> 30D (-15% OTM)',
          raw_alert: m4Raw,
          vol_gate_ok: vxn <= 28.0 && vr <= 0.9,
          entry_triggered: m4Ent,
          status_code: sensorStatus(m4Raw, m4Ent, !latchArmed && qqq < sma200),
          vol_gate_rule_en: 'Latch ON & VXN <= 28.0 & VIX/3M <= 0.90',
          vol_gate_rule_zh: '锁存开启 且 VXN <= 28 & VIX/3M <= 0.90',
          metrics: [
            { label_en: '+8% Slow-Bear Latch', label_zh: '+8% 慢熊磁滞锁存', value: latchArmed ? 'ARMED (ON)' : `OFF (CTA ${fmtSigned(ctaHi252Pct, 1)}%)`, passed: latchArmed },
            { label_en: 'QQQ < 200DMA & EWMAC < 0', label_zh: '破年线且 EWMAC < 0', value: `${qqq < sma200 ? '<200D' : '>200D'} · ${fmtSigned(ewmac, 2)}`, passed: qqq < sma200 && ewmac < 0 },
            { label_en: 'Dead-Cat QQQ > EMA20', label_zh: '反抽站上 EMA20', value: `$${qqq.toFixed(1)} vs $${ema20.toFixed(1)}`, passed: qqq > ema20 },
            { label_en: 'Complacency Gate', label_zh: '自满低波门控', value: `VXN ${vxn.toFixed(1)}<=28 · VR ${vr.toFixed(2)}<=0.90`, passed: vxn <= 28.0 && vr <= 0.9 },
          ],
          explanation_en: m4Ent
            ? 'Structural slow-bear dead-cat complacency confirmed! Route 2 fires UNIFORM 90D -15% OTM Put (1.25% NAV/slot, Hard 30D roll).'
            : m4Raw
              ? `Latch ON & dead-cat bounce active, waiting for vol complacency (VXN ${vxn.toFixed(1)} <= 28, VR ${vr.toFixed(2)} <= 0.90).`
              : !latchArmed
                ? `Slow-Bear +8% Hysteresis Latch is OFF (Corr60 ${fmtSigned(corr60, 2)}, DualCTA ${fmtSigned(ctaHi252Pct, 1)}% since 1Y high) — blocks false non-slow-bear triggers.`
                : 'Latch ARMED; waiting for QQQ bounce above EMA20 with VXN <= 28 & VR <= 0.90.',
          explanation_zh: m4Ent
            ? '结构性慢熊死猫跳自满确认！Route 2 统一触发买入 90D -15% OTM Put（每槽 1.25% NAV，30D 强制滚仓）。'
            : m4Raw
              ? `慢熊锁存已开且出现死猫反抽，但等待波动率回落自满（VXN ${vxn.toFixed(1)}<=28、VR ${vr.toFixed(2)}<=0.90）。`
              : !latchArmed
                ? `慢熊 +8% 磁滞锁存开关为 OFF（Corr60 ${fmtSigned(corr60, 2)}，双CTA 距1年高点 ${fmtSigned(ctaHi252Pct, 1)}%），自动过滤非慢熊假信号。`
                : '慢熊锁存已激活，等待 QQQ 反抽站上 EMA20 且 VXN <= 28、VIX/3M <= 0.90。',
        },
        {
          id: 'M3',
          name_en: 'M3 Credit & Financial Conditions Squeeze',
          name_zh: 'M3 信用利差与金融条件收紧',
          points: 10,
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
            ? 'HY credit breakdown + macro tightening confirmed in low-vol window (+10 pts).'
            : m3Raw
              ? `Credit tightening structure LIT, blocked by elevated vol (VXN ${vxn.toFixed(1)} > 26 or VR ${vr.toFixed(2)} > 0.92).`
              : 'Credit spreads and financial conditions stable.',
          explanation_zh: m3Ent
            ? '高收益债相对走弱叠加宏观利差/金融条件收紧，低波窗口触发（+10 分）。'
            : m3Raw
              ? `信用与宏观紧缩结构已亮，但当前高波（VXN ${vxn.toFixed(1)} / VR ${vr.toFixed(2)}）禁追新单。`
              : '信用利差与金融条件整体稳定。',
        },
      ],
    },
  ];

  // 5 Live Sub-Engine Status Pills for Section 1 Hero Card (Plan D Double-Champion)
  const subEngines = [
    {
      id: 'leverage_cap',
      status_code: 'NATURAL_DRIFT_120X',
      tone: 'mint',
      label_en: 'Box Leverage (No Crash Cap)',
      label_zh: 'Box 杠杆（无底部砍仓）',
      value_en: `Live ${liveLev.toFixed(2)}x · Box ${boxRatePct.toFixed(2)}%`,
      value_zh: `实时 ${liveLev.toFixed(2)}x · Box ${boxRatePct.toFixed(2)}%`,
      detail_en: `Natural drift <= ${peakDriftLev.toFixed(2)}x · PM Call ${pmCrashLivePct}% · Qtrly 1.20x`,
      detail_zh: `允许自然漂移 <= ${peakDriftLev.toFixed(2)}x · PM强平垫 ${pmCrashLivePct}% · 平稳季调 1.20x`,
    },
    {
      id: 'sleeve_a',
      status_code: sleeveAStatus,
      tone: sleeveATone,
      label_en: 'B020 Baseline (0.20%)',
      label_zh: 'B020 常态盾 (0.20%)',
      value_en: sleeveAValEn,
      value_zh: sleeveAValZh,
      detail_en: sleeveADetEn,
      detail_zh: sleeveADetZh,
    },
    {
      id: 'sleeve_b',
      status_code: sleeveBStatus,
      tone: sleeveBTone,
      label_en: 'M7G Ladder (1-3 x 1.25%)',
      label_zh: 'M7G 阶梯盾 (1-3x1.25%)',
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
          budget_sleeve_b_pct: 1.25,
          budget_sleeve_b_slot_pct: 1.25,
          max_slots: 3,
          max_budget_sleeve_b_pct: 3.75,
        },
        route2_m4_90d_15otm: {
          target_dte: 90,
          roll_dte: 30,
          recycle_dte: 30,
          otm_pct: -15,
          exact_strike: strike15Exact,
          suggested_strike: strike15Round,
          budget_sleeve_b_pct: 1.25,
          budget_sleeve_b_slot_pct: 1.25,
        },
        route2_m4_90d_10otm: {
          target_dte: 90,
          roll_dte: 30,
          recycle_dte: 30,
          otm_pct: -15,
          exact_strike: strike15Exact,
          suggested_strike: strike15Round,
          budget_sleeve_b_pct: 1.25,
          budget_sleeve_b_slot_pct: 1.25,
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
        restore_rule_en: 'Mechanically hold rotated QQQ for 365 calendar days (US LTCG lock) before restoring 10% DBMF + 10% KMLM (1.200x target).',
        restore_rule_zh: '机械持有换入的 QQQ 满 1 年（365 自然日 LTCG 锁定）后再恢复 10% DBMF + 10% KMLM（季调校准回 1.200x）。',
      },
      leverage_guard: {
        daily_forced_delev_cap: false,
        hard_cap: null,
        target_gross: 1.2,
        live_gross_leverage: liveLev,
        live_ltv_pct: liveLtvPct,
        observed_peak_drift_11y: r3(Number(peakDriftLev)),
        target_qqq_pct: 100.0,
        target_dbmf_pct: 10.0,
        target_kmlm_pct: 10.0,
        target_debt_pct: 20.0,
        init_ltv_pct: 16.67,
        ibkr_pm_maint_pct: 15.0,
        ibkr_pm_crash_cushion_pct: pmCrashLivePct,
        ibkr_pm_nominal_cushion_pct: crashToCallPctJS(1.2, 0.15),
        reg_t_maint_pct: 25.0,
        reg_t_crash_cushion_pct: regTCrashLivePct,
        reg_t_nominal_cushion_pct: crashToCallPctJS(1.2, 0.25),
        effr_pct: effrPct,
        box_rate_pct: boxRatePct,
        ibkr_rate_pct: ibkrRatePct,
        box_annual_drag_pct_nav: boxAnnualDragPct,
        policy_en: 'NO daily 1.20x forced crash deleveraging cap (natural drift up to approx 1.26x avoids crash-bottom QQQ liquidations; quarterly calm calibration restores 1.20x).',
        policy_zh: '取消每日 1.20x 强制去杠杆砍仓线（崩盘期允许自然漂移至约 1.26x，绝不在底部割肉 QQQ；平稳无锁仓期按季校准回 1.20x）。',
      },
    },
    three_pillars: {
      ...stressPack,
      raw_crisis_prob: rawCrisisProb,
      raw_target_slots: rawTargetSlots,
      entry_crisis_prob: entryCrisisProb,
      non_m4_entry_prob: nonM4EntProb,
      actionable_m7g_slots: actionableSlots,
      actionable_m7g_budget_pct: actionableBudgetPct,
      m4_entry_triggered: m4Ent,
      vol_gate_status: volGateStatus,
      vol_gate_reason_en: volGateReasonEn,
      vol_gate_reason_zh: volGateReasonZh,
      m7g_ladder_and_bleed: {
        tier_ladder: 'M7G_tier_45_65',
        budget_per_slot_pct: 1.25,
        max_slots: 3,
        max_budget_pct: 3.75,
        raw_target_slots: rawTargetSlots,
        actionable_slots: actionableSlots,
        actionable_budget_pct: actionableBudgetPct,
        thresholds: { slot1: 35, slot2: 45, slot3: 65 },
        uniform_otm_pct: -15,
        ...rollStats,
      },
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
        vix_ok: vix <= 20.0,
        vr_ok: vr < 1.02,
        vix,
        vix_max: 20.0,
        vr,
        vr_max: 1.02,
      },
      pillars,
    },
    tp_and_microstructure: {
      tier1_partial: {
        mode: 'late_5x_full_tp',
        rule_en: 'Late 5x TP: Remaining DTE <= 60D (Base) / <= 45D (Crisis) AND Option ROI >= 5.0x -> 100% liquidate at T+1 Close.',
        rule_zh: '晚段 5x 止盈：剩余到期 <= 60D（常态盾）/ <= 45D（危机盾）且期权回报 >= 5.0x -> T+1 100% 清仓。',
        dte_limit_base: 60,
        dte_limit_crisis: 45,
        roi_mult_target: 5.0,
        contango_ok: vr < 1.0,
        vr,
      },
      tier2_full: {
        mode: 'tp_near_itm_or_vix45',
        triggered_today: tpFullTriggered,
        vr_ok: tpFullVrOk,
        near_itm_ok: nearItmOk,
        vix_panic_ok: tpVixPanicOk,
        dd_ok: nearItmOk,
        vr,
        vr_target: 1.1,
        vr_gap: r3(1.1 - vr),
        vix,
        vix_panic_target: 45.0,
        ref_strike: refStrikeForTp,
        near_itm_spot_target: nearItmThresholdSpot,
        dd_pct: ddAthPct,
        dd_target: -11.0,
        dd_gap_pp: r2(ddAthPct - -11.0),
        rule_en: 'Full Right-Tail TP: (VIX/VIX3M >= 1.10 AND QQQ <= 1.05 x Strike [Near-ITM]) OR VIX >= 45.0 -> 100% liquidate ALL active puts.',
        rule_zh: '右尾全额止盈：（VIX/VIX3M >= 1.10 且 QQQ <= 1.05 倍行权价 [近实值]）或 VIX >= 45.0 -> 100% 全额清仓所有活跃 Put。',
      },
      deploy_5d_rule_en: 'T+1 lump-sum 100% immediate reinvestment into QQQ (never 5D tranche-lagged) + 5D Post-TP Contango Lockout (VIX/VIX3M < 1.00 for 5 consecutive days) on BOTH books.',
      deploy_5d_rule_zh: '止盈收益 T+1 一次性 100% 全额回买 QQQ（杜绝分批踏空），并对常态与危机双账本开启止盈后 5 日正向期限结构锁仓（连续 5 日 VIX/3M < 1.00 解锁）。',
      roll_economics: rollStats,
      metrics: {
        vix,
        vxn,
        vix3m,
        vix_ratio: vr,
        vr_jump5: vrJ5,
        skew_spot: row.skew_spot != null ? Number(row.skew_spot) : Number(row.skew10),
        skew10: Number(row.skew10),
        skew_p75: Number(row.skew_p75),
        vvix: Number(row.vvix),
        vvix_p75: Number(row.vvix_p75),
        qqq_ath_dd_pct: ddAthPct,
        opra_sk20_10: row.opra_sk20_10 != null ? Number(row.opra_sk20_10) : null,
        opra_sk15_atm: row.opra_sk15_atm != null ? Number(row.opra_sk15_atm) : null,
      },
      option_pricing: {
        quote_source: row.opra_src ?? 'bsm_est',
        skew_ratio: {
          opra_iv_20_10: row.opra_sk20_10 != null ? Number(row.opra_sk20_10) : null,
          opra_iv_15_atm: row.opra_sk15_atm != null ? Number(row.opra_sk15_atm) : null,
          cboe_skew_spot: row.skew_spot != null ? Number(row.skew_spot) : Number(row.skew10),
          cboe_skew10: Number(row.skew10),
          cboe_skew_p75: Number(row.skew_p75),
        },
        put_125d_15otm: {
          otm_pct: -15,
          strike: row.p125_k != null ? Number(row.p125_k) : strike15Round,
          dte: row.p125_dte != null ? Number(row.p125_dte) : 125,
          bid: row.p125_bid != null ? Number(row.p125_bid) : null,
          ask: row.p125_ask != null ? Number(row.p125_ask) : null,
          mid: row.p125_mid != null ? Number(row.p125_mid) : null,
          ibkr_limit_buy: row.p125_lmt != null ? Number(row.p125_lmt) : null,
          half_spread_pct: row.p125_hs != null ? Number(row.p125_hs) : null,
          iv_pct: row.p125_iv != null ? Number(row.p125_iv) : null,
          one_put_usd: row.p125_lmt != null ? r2(Number(row.p125_lmt) * 100) : null,
          one_put_mid_usd: row.p125_mid != null ? r2(Number(row.p125_mid) * 100) : null,
          one_lot_qqq_usd: r2(qqq * 100),
          put_to_lot_pct: row.p125_lot_pct != null ? Number(row.p125_lot_pct) : null,
          mid_to_lot_pct: row.p125_mid_pct != null ? Number(row.p125_mid_pct) : null,
        },
        put_90d_15otm: {
          otm_pct: -15,
          strike: row.p90_k != null ? Number(row.p90_k) : strike15Round,
          dte: row.p90_dte != null ? Number(row.p90_dte) : 90,
          bid: row.p90_bid != null ? Number(row.p90_bid) : null,
          ask: row.p90_ask != null ? Number(row.p90_ask) : null,
          mid: row.p90_mid != null ? Number(row.p90_mid) : null,
          ibkr_limit_buy: row.p90_lmt != null ? Number(row.p90_lmt) : null,
          half_spread_pct: row.p90_hs != null ? Number(row.p90_hs) : null,
          iv_pct: row.p90_iv != null ? Number(row.p90_iv) : null,
          one_put_usd: row.p90_lmt != null ? r2(Number(row.p90_lmt) * 100) : null,
          one_put_mid_usd: row.p90_mid != null ? r2(Number(row.p90_mid) * 100) : null,
          one_lot_qqq_usd: r2(qqq * 100),
          put_to_lot_pct: row.p90_lot_pct != null ? Number(row.p90_lot_pct) : null,
          mid_to_lot_pct: row.p90_mid_pct != null ? Number(row.p90_mid_pct) : null,
        },
        put_90d_10otm: {
          otm_pct: -15,
          strike: row.p90_k != null ? Number(row.p90_k) : strike15Round,
          dte: row.p90_dte != null ? Number(row.p90_dte) : 90,
          bid: row.p90_bid != null ? Number(row.p90_bid) : null,
          ask: row.p90_ask != null ? Number(row.p90_ask) : null,
          mid: row.p90_mid != null ? Number(row.p90_mid) : null,
          ibkr_limit_buy: row.p90_lmt != null ? Number(row.p90_lmt) : null,
          half_spread_pct: row.p90_hs != null ? Number(row.p90_hs) : null,
          iv_pct: row.p90_iv != null ? Number(row.p90_iv) : null,
          one_put_usd: row.p90_lmt != null ? r2(Number(row.p90_lmt) * 100) : null,
          one_put_mid_usd: row.p90_mid != null ? r2(Number(row.p90_mid) * 100) : null,
          one_lot_qqq_usd: r2(qqq * 100),
          put_to_lot_pct: row.p90_lot_pct != null ? Number(row.p90_lot_pct) : null,
          mid_to_lot_pct: row.p90_mid_pct != null ? Number(row.p90_mid_pct) : null,
        },
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
  const win11 = artifactObj.unpackedWindows['11y_opra'];
  const rollEconRef = win11?.kpi_opra_verified_primary ?? win11?.kpi_primary ?? null;
  const peakDriftLev = Number(win11?.kpi_primary?.peak_gross_leverage ?? 1.257);
  const pitHistNow = buildPitHistoryForWindow(activeWin, effectiveAsOf);
  const openStrikesNow = (pitHistNow?.active_puts_on_date ?? []).map(p => Number(p.strike)).filter(Number.isFinite);
  const openStrikesFallback = (activeWin?.open_puts_at_end ?? []).map(p => Number(p.strike)).filter(Number.isFinite);
  const liveGrossLevNow = pitHistNow?.nav_snapshot?.lev ?? null;

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
        opra_cutoff_date: w.opra_cutoff_date ?? '2025-12-15',
        sim_extension_days: w.sim_extension_days ?? 0,
        zero_splice: w.zero_splice,
      };
    }),
    ruleset: artifactObj.data.ruleset,
    data_freshness: freshness,
    live_cockpit: buildLiveCockpit(selectedRow, {
      isPitReplay,
      rollEcon: rollEconRef,
      openStrikes: openStrikesNow.length ? openStrikesNow : openStrikesFallback,
      liveGrossLev: liveGrossLevNow,
      peakDriftLev,
    }),
    backtest: {
      initial_capital: artifactObj.data.backtest.initial_capital,
      opra_provenance: artifactObj.data.backtest.opra_provenance,
      active_window: activeWin,
      window_kpis: {
        '11y_opra': {
          kpi_primary: artifactObj.unpackedWindows['11y_opra'].kpi_primary,
          kpi_stress: artifactObj.unpackedWindows['11y_opra'].kpi_stress,
          kpi_qqq: artifactObj.unpackedWindows['11y_opra'].kpi_qqq,
          kpi_opra_verified_primary: artifactObj.unpackedWindows['11y_opra'].kpi_opra_verified_primary ?? null,
          kpi_opra_verified_qqq: artifactObj.unpackedWindows['11y_opra'].kpi_opra_verified_qqq ?? null,
        },
        '5y_live': {
          kpi_primary: artifactObj.unpackedWindows['5y_live'].kpi_primary,
          kpi_stress: artifactObj.unpackedWindows['5y_live'].kpi_stress,
          kpi_qqq: artifactObj.unpackedWindows['5y_live'].kpi_qqq,
          kpi_opra_verified_primary: artifactObj.unpackedWindows['5y_live'].kpi_opra_verified_primary ?? null,
          kpi_opra_verified_qqq: artifactObj.unpackedWindows['5y_live'].kpi_opra_verified_qqq ?? null,
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

function buildPitHistoryForWindow(activeWin, targetDate) {
  if (!activeWin) return null;
  const series = Array.isArray(activeWin.daily_series) ? activeWin.daily_series : [];
  const putLedger = Array.isArray(activeWin.put_ledger) ? activeWin.put_ledger : [];
  const openEnd = Array.isArray(activeWin.open_puts_at_end) ? activeWin.open_puts_at_end : [];
  const ctaRot = Array.isArray(activeWin.cta_rotation_ledger) ? activeWin.cta_rotation_ledger : [];
  const ctaRes = Array.isArray(activeWin.cta_restore_ledger) ? activeWin.cta_restore_ledger : [];

  let navSnapshot = null;
  for (let i = series.length - 1; i >= 0; i -= 1) {
    if (series[i].date <= targetDate) {
      if (series[i].date === targetDate) navSnapshot = series[i];
      break;
    }
  }

  const eventsOnDate = [];
  const seenOpenKey = new Set();
  const eventDateSet = new Set();
  const tpByDate = new Map();

  let cumTpCount = 0;
  let cumClosedCount = 0;
  let cumRealizedPnl = 0;

  for (const t of putLedger) {
    eventDateSet.add(t.entry_date);
    eventDateSet.add(t.exit_date);
    const isTp = String(t.exit_reason ?? '').includes('tp_');
    if (isTp) {
      const prev = tpByDate.get(t.exit_date) ?? {
        date: t.exit_date,
        count: 0,
        max_roi: 0,
        net_pnl_usd: 0,
        reason: t.exit_reason,
      };
      prev.count += 1;
      prev.max_roi = Math.max(prev.max_roi, Number(t.roi_mult ?? 0));
      prev.net_pnl_usd = r2(prev.net_pnl_usd + Number(t.net_pnl_usd ?? 0));
      tpByDate.set(t.exit_date, prev);
    }
    if (t.exit_date <= targetDate) {
      cumClosedCount += 1;
      cumRealizedPnl += Number(t.net_pnl_usd ?? 0);
      if (isTp) cumTpCount += 1;
    }

    if (t.exit_date === targetDate) {
      const action = isTp
        ? 'PUT_TP'
        : String(t.exit_reason ?? '').startsWith('roll_')
          ? 'PUT_ROLL'
          : 'PUT_CLOSE';
      eventsOnDate.push({
        priority: isTp ? 0 : 2,
        action,
        sleeve: t.sleeve,
        tranche_id: t.tranche_id,
        date: t.exit_date,
        entry_date: t.entry_date,
        exit_date: t.exit_date,
        exp: t.exp,
        strike: t.strike,
        entry_dte: t.entry_dte,
        exit_dte: t.exit_dte,
        entry_spot: t.entry_spot,
        exit_spot: t.exit_spot,
        entry_fill: t.entry_fill,
        exit_fill: t.exit_fill,
        exit_bid: t.exit_bid ?? null,
        exit_ask: t.exit_ask ?? null,
        exit_mid: t.exit_mid ?? null,
        exit_vix: t.exit_vix ?? null,
        exit_vr: t.exit_vr ?? null,
        exit_dd_pct: t.exit_dd_pct ?? null,
        entry_lot_pct: t.entry_lot_pct ?? null,
        exit_lot_pct: t.exit_lot_pct ?? null,
        entry_sk20_10: t.entry_sk20_10 ?? null,
        contracts: t.contracts ?? null,
        exit_frac: t.exit_frac ?? 1.0,
        cost_usd: t.cost_usd,
        exit_usd: t.exit_usd,
        net_pnl_usd: t.net_pnl_usd,
        roi_mult: t.roi_mult,
        reason: t.exit_reason,
        quote_source: t.quote_source ?? 'REAL_OPRA',
      });
    }
    if (t.entry_date === targetDate && !seenOpenKey.has(t.tranche_id)) {
      seenOpenKey.add(t.tranche_id);
      eventsOnDate.push({
        priority: 1,
        action: 'PUT_OPEN',
        sleeve: t.sleeve,
        tranche_id: t.tranche_id,
        date: t.entry_date,
        entry_date: t.entry_date,
        exit_date: t.exit_date,
        exp: t.exp,
        strike: t.strike,
        entry_dte: t.entry_dte,
        entry_spot: t.entry_spot,
        entry_fill: t.entry_fill,
        entry_bid: t.entry_bid ?? null,
        entry_ask: t.entry_ask ?? null,
        entry_mid: t.entry_mid ?? null,
        entry_hs_pct: t.entry_hs_pct ?? null,
        entry_lot_pct: t.entry_lot_pct ?? null,
        entry_sk20_10: t.entry_sk20_10 ?? null,
        entry_vix: t.entry_vix ?? null,
        entry_vr: t.entry_vr ?? null,
        contracts: t.contracts ?? null,
        cost_usd: t.cost_usd,
        eventual_exit_date: t.exit_date,
        eventual_roi_mult: t.roi_mult,
        eventual_reason: t.exit_reason,
        reason: 'open_ibkr_limit_35pct',
        quote_source: t.entry_date > (activeWin.opra_cutoff_date ?? '2025-12-15') ? 'BSM_SIM_2026' : 'REAL_OPRA',
      });
    }
  }

  for (const op of openEnd) {
    eventDateSet.add(op.entry_date);
    if (op.entry_date === targetDate && !seenOpenKey.has(op.tranche_id)) {
      seenOpenKey.add(op.tranche_id);
      eventsOnDate.push({
        priority: 1,
        action: 'PUT_OPEN',
        sleeve: op.sleeve,
        tranche_id: op.tranche_id,
        date: op.entry_date,
        entry_date: op.entry_date,
        exp: op.exp,
        strike: op.strike,
        entry_dte: op.entry_dte,
        entry_spot: op.entry_spot,
        entry_fill: op.entry_fill,
        entry_bid: op.entry_bid ?? null,
        entry_ask: op.entry_ask ?? null,
        entry_mid: op.entry_mid ?? null,
        entry_hs_pct: op.entry_hs_pct ?? null,
        entry_lot_pct: op.entry_lot_pct ?? null,
        entry_sk20_10: op.entry_sk20_10 ?? null,
        entry_vix: op.entry_vix ?? null,
        entry_vr: op.entry_vr ?? null,
        contracts: op.contracts ?? null,
        cost_usd: op.cost_usd,
        reason: 'open_ibkr_limit_35pct',
        quote_source: op.quote_source ?? (op.entry_date > (activeWin.opra_cutoff_date ?? '2025-12-15') ? 'BSM_SIM_2026' : 'REAL_OPRA'),
      });
    }
  }

  for (const cr of ctaRot) {
    eventDateSet.add(cr.date);
    if (cr.date === targetDate) {
      eventsOnDate.push({
        priority: 1,
        action: 'CTA_ROTATE',
        sleeve: cr.sleeve,
        date: cr.date,
        tranche: cr.tranche,
        sold_usd: cr.sold_usd,
        qqq_dd_pct: cr.qqq_dd_pct,
        restore_due: cr.restore_due,
        reason: 'cont_2m_cta_to_qqq',
      });
    }
  }
  for (const rs of ctaRes) {
    eventDateSet.add(rs.date);
    if (rs.date === targetDate) {
      eventsOnDate.push({
        priority: 2,
        action: 'CTA_RESTORE',
        sleeve: rs.sleeve,
        date: rs.date,
        restored_usd: rs.restored_usd,
        lots_matured: rs.lots_matured,
        reason: '1y_mechanical_restore',
      });
    }
  }
  eventsOnDate.sort((a, b) => a.priority - b.priority);

  // Active open Put tranches held on targetDate (entry_date <= targetDate < exit_date)
  const activePuts = [];
  const seenActive = new Set();
  const winEnd = activeWin.end_date ?? '2025-12-15';
  const winStart = activeWin.start_date ?? '2015-01-02';
  if (targetDate >= winStart && targetDate <= winEnd) {
    for (const t of putLedger) {
      if (t.entry_date <= targetDate && targetDate < t.exit_date && !seenActive.has(t.tranche_id)) {
        seenActive.add(t.tranche_id);
        activePuts.push({
          tranche_id: t.tranche_id,
          sleeve: t.sleeve,
          entry_date: t.entry_date,
          exp: t.exp,
          strike: t.strike,
          rem_dte: Math.max(0, diffCalendarDaysIso(t.exp, targetDate)),
          entry_fill: t.entry_fill,
          entry_lot_pct: t.entry_lot_pct ?? null,
          cost_usd: t.cost_usd,
          contracts: t.contracts ?? null,
          eventual_exit_date: t.exit_date,
          eventual_roi_mult: t.roi_mult,
          eventual_reason: t.exit_reason,
        });
      }
    }
    for (const op of openEnd) {
      if (op.entry_date <= targetDate && !seenActive.has(op.tranche_id)) {
        seenActive.add(op.tranche_id);
        activePuts.push({
          tranche_id: op.tranche_id,
          sleeve: op.sleeve,
          entry_date: op.entry_date,
          exp: op.exp,
          strike: op.strike,
          rem_dte: Math.max(0, diffCalendarDaysIso(op.exp, targetDate)),
          entry_fill: op.entry_fill,
          entry_lot_pct: op.entry_lot_pct ?? null,
          cost_usd: op.cost_usd,
          contracts: op.contracts ?? null,
          eventual_exit_date: null,
          eventual_roi_mult: null,
          eventual_reason: 'open_at_window_end',
        });
      }
    }
  }

  const sortedEvents = Array.from(eventDateSet).sort();
  const tpDates = Array.from(tpByDate.values()).sort((a, b) => a.date.localeCompare(b.date));
  let prevEventDate = null;
  let nextEventDate = null;
  for (const ed of sortedEvents) {
    if (ed < targetDate) prevEventDate = ed;
    else if (ed > targetDate && !nextEventDate) nextEventDate = ed;
  }
  let prevTpDate = null;
  let nextTpDate = null;
  for (const tp of tpDates) {
    if (tp.date < targetDate) prevTpDate = tp.date;
    else if (tp.date > targetDate && !nextTpDate) nextTpDate = tp.date;
  }

  const opraCutoff = activeWin.opra_cutoff_date ?? '2025-12-15';
  return {
    window_id: activeWin.id,
    in_opra_window: targetDate >= winStart && targetDate <= winEnd,
    opra_cutoff_date: opraCutoff,
    is_sim_extension: targetDate > opraCutoff,
    nav_snapshot: navSnapshot,
    events_on_date: eventsOnDate,
    active_puts_on_date: activePuts,
    tp_dates: tpDates,
    prev_event_date: prevEventDate,
    next_event_date: nextEventDate,
    prev_tp_date: prevTpDate,
    next_tp_date: nextTpDate,
    cum_put_stats_to_date: {
      tp_count: cumTpCount,
      closed_count: cumClosedCount,
      realized_net_pnl_usd: r2(cumRealizedPnl),
    },
  };
}

export function loadCrisisObservatoryPitSnapshot({
  date = null,
  window = DEFAULT_CRISIS_WINDOW,
  file = defaultFile,
  liveFeed = null,
} = {}) {
  if (!date || !isIsoDate(date)) fail('invalid_pit_date', 400);
  const winId = normalizeWindowId(window);
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
  const activeWin = artifactObj.unpackedWindows[winId];
  const win11 = artifactObj.unpackedWindows['11y_opra'];
  const rollEconRef = win11?.kpi_opra_verified_primary ?? win11?.kpi_primary ?? null;
  const peakDriftLev = Number(win11?.kpi_primary?.peak_gross_leverage ?? 1.257);
  const pitHistory = buildPitHistoryForWindow(activeWin, row.date);
  const openStrikesOnDate = (pitHistory?.active_puts_on_date ?? []).map(p => Number(p.strike)).filter(Number.isFinite);
  const liveGrossLevOnDate = pitHistory?.nav_snapshot?.lev ?? null;

  return {
    version: CRISIS_OBSERVATORY_VERSION,
    strategy_code: CRISIS_OBSERVATORY_STRATEGY_CODE,
    requested_date: date,
    date: row.date,
    window: winId,
    prev_date: prevDate,
    next_date: nextDate,
    latest_date: latestDate,
    live_cockpit: buildLiveCockpit(row, {
      isPitReplay: row.date < latestDate,
      rollEcon: rollEconRef,
      openStrikes: openStrikesOnDate,
      liveGrossLev: liveGrossLevOnDate,
      peakDriftLev,
    }),
    pit_history: pitHistory,
  };
}

export async function loadCrisisObservatoryPitSnapshotLive(options = {}) {
  const liveFeed = await getLiveV2MarketFeed().catch(() => null);
  return loadCrisisObservatoryPitSnapshot({ ...options, liveFeed });
}
