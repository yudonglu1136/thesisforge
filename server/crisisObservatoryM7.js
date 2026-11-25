// Pure-JS M7-Graded Three-Pillar Probabilistic Put Overlay Engine & Daily Live EOD Stepper.
// Zero Python subprocesses, zero external dependencies, strict Real-OPRA Ask/Bid (2015-2025) + OPRA-Calibrated BSM (2025-12-16 -> Live) parity.

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const INITIAL_CAPITAL = 200000.0;
const OPT_SLIP = 0.025;
const OPT_SLIP_SP = 0.03;
const OPT_COMM_PER_SH = 0.0065;
const STOCK_REBAL_FEE = 0.0003;
const MARGIN_SPREAD = 0.015;
const MIN_OPT_BID = 0.05;

export const CRISIS_OBSERVATORY_PROFILES = Object.freeze(['full_m7_adaptive', 'core3_adaptive']);
export const CRISIS_OBSERVATORY_PUT_OTMS = Object.freeze(['otm15', 'otm20']);
export const CRISIS_OBSERVATORY_M7_TP_MODES = Object.freeze(['standard', 'itm_tp']);
export const CRISIS_OBSERVATORY_ROLL_MODES = Object.freeze(['adaptive_120_90', '120d_roll50', '90d_hold']);
export const CRISIS_OBSERVATORY_FILL_MODES = Object.freeze(['ibkr_limit', 'ask_bid']);
export const DEFAULT_M7_FILL_MODE = 'ibkr_limit';

const IBKR_LIMIT_FRAC = 0.35;
const HARDCODED_BASE_BUDGET_PCT = 0.002;
const HARDCODED_M7_BUDGET_PCT = 0.0125;
const HARDCODED_BASE_DTE = 125;
const HARDCODED_BASE_ROLL_DTE = 75;
const HARDCODED_BASE_MONEYNESS = 0.85;
const HARDCODED_BASE_VIX_MAX = 20.0;
const HARDCODED_BASE_VR_MAX = 1.02;
const HARDCODED_M7_BASE_DTE = 125;
const HARDCODED_M7_BASE_ROLL_DTE = 75;
const HARDCODED_M7_CTA_DTE = 90;
const HARDCODED_M7_CTA_ROLL_DTE = 30;
const HARDCODED_NEAR_ITM_MULT = 1.05;
const HARDCODED_EXTREME_VIX_TP = 45.0;
const HARDCODED_LOCKOUT_DAYS = 5;
const HARDCODED_LOCKOUT_INV_THRESH = 1.0;

export const HARDCODED_RULESET_SPEC = Object.freeze({
  code: 'B020_M125_HARD75_NEARITM_5DLOCK',
  locked: true,
  base_book: {
    budget_pct_nav: 0.2,
    target_dte: 125,
    roll_dte: 75,
    otm_pct: 15,
    vix_max: 20.0,
    vix_ratio_max: 1.02,
  },
  m7_book: {
    budget_pct_nav_per_slot: 1.25,
    max_slots: 3,
    non_cta_target_dte: 125,
    non_cta_roll_dte: 75,
    cta_target_dte: 90,
    cta_roll_dte: 30,
    otm_pct: 15,
    vxn_max: 27.0,
    vix_ratio_max: 1.02,
    step_cooldown_days: 30,
    escalate_slot3_days: 21,
  },
  near_itm_tp: {
    vix_ratio_min: 1.1,
    near_itm_strike_mult: 1.05,
    vix_extreme_override: 45.0,
    late_5x_mult: 5.0,
    late_5x_max_dte_base: 60,
    late_5x_max_dte_m7: 45,
  },
  post_tp_lockout: {
    consecutive_days: 5,
    vix_ratio_unlock_max: 1.0,
    scope: 'both_books',
  },
});

const _m7Dir = path.dirname(fileURLToPath(import.meta.url));
const REAL_QUOTES_GZ = path.resolve(_m7Dir, 'config/crisis-observatory-real-quotes.json.gz');

const CODE_TO_SRC = Object.freeze({
  0: 'bsm_fallback',
  1: 'real_opra',
  2: 'real_opra_interp',
  3: 'real_polygon',
  4: 'real_polygon_interp',
});

let cachedRealQuotes = null;
let cachedRealQuotesMtime = -1;

export function getRealQuoteCache(file = REAL_QUOTES_GZ) {
  try {
    const st = fs.statSync(file);
    if (cachedRealQuotes && cachedRealQuotesMtime === st.mtimeMs) {
      return cachedRealQuotes;
    }
    const raw = zlib.gunzipSync(fs.readFileSync(file)).toString('utf8');
    cachedRealQuotes = JSON.parse(raw);
    cachedRealQuotesMtime = st.mtimeMs;
    return cachedRealQuotes;
  } catch {
    return null;
  }
}

export function formatOccSymbol(root, expStr, optType, strike) {
  const r = String(root || 'QQQ').trim().toUpperCase();
  const cleanExp = String(expStr || '').replace(/-/g, '');
  const yymmdd = cleanExp.length >= 8 ? cleanExp.slice(2, 8) : cleanExp.padStart(6, '0');
  const cp = String(optType || 'P').toLowerCase().startsWith('c') ? 'C' : 'P';
  const mills = Math.max(0, Math.round(Number(strike || 0) * 1000));
  return `${r}${yymmdd}${cp}${String(mills).padStart(8, '0')}`;
}

function classifyTradeSource(entrySrc, exitSrc) {
  const en = String(entrySrc || 'bsm_fallback');
  const ex = String(exitSrc || en);
  if (en.startsWith('real_opra') && ex.startsWith('real_opra')) {
    return 'real_opra';
  }
  if (en.startsWith('real_polygon') || ex.startsWith('real_polygon')) {
    return 'real_polygon';
  }
  return 'bsm_fallback';
}

function classifyQuoteSourceTag(entrySrc, exitSrc, entryDate, exitDate, opraMaxDate = '2025-12-15') {
  const en = String(entrySrc || 'bsm_fallback');
  const ex = String(exitSrc || '');
  const inOpraEn = en.startsWith('real_opra') && (!entryDate || entryDate <= opraMaxDate);
  const inOpraEx = ex.startsWith('real_opra') && Boolean(exitDate && exitDate <= opraMaxDate);
  return inOpraEn && inOpraEx ? 'REAL_OPRA' : 'CALIBRATED_BSM';
}

function execBuyPrice(bid, ask, mid, src, slipBsm = OPT_SLIP, fillMode = 'ask_bid') {
  if (fillMode === 'ibkr_limit') {
    const hs = 0.5 * Math.max(0.0, ask - bid);
    return mid + IBKR_LIMIT_FRAC * hs + OPT_COMM_PER_SH;
  }
  if (src === 'real_opra' || src === 'real_opra_interp') {
    return ask + OPT_COMM_PER_SH;
  }
  return mid * (1.0 + slipBsm) + OPT_COMM_PER_SH;
}

function execSellPrice(bid, ask, mid, src, slipBsm = OPT_SLIP, fillMode = 'ask_bid') {
  if (fillMode === 'ibkr_limit') {
    if (bid <= 0.0 || mid <= 0.0) return 0.0;
    const hs = 0.5 * Math.max(0.0, ask - bid);
    return Math.max(0.0, mid - IBKR_LIMIT_FRAC * hs - OPT_COMM_PER_SH);
  }
  if (src === 'real_opra' || src === 'real_opra_interp') {
    if (bid <= 0.0) return 0.0;
    return Math.max(0.0, bid - OPT_COMM_PER_SH);
  }
  if (mid <= 0.0) return 0.0;
  return Math.max(0.0, mid * (1.0 - slipBsm) - OPT_COMM_PER_SH);
}

function isExpiryDay(idx, msArr, expMs) {
  if (msArr[idx] >= expMs) return true;
  if (idx + 1 < msArr.length && msArr[idx + 1] > expMs) return true;
  return false;
}

const YF_SYMBOL_MAP = Object.freeze({
  QQQ: 'QQQ',
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
});

const YF_OPTIONAL_SIX_LIGHTS_MAP = Object.freeze({
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
});

const FRED_SIX_LIGHTS_LAGS = Object.freeze({
  BAA10Y: 1,
  DGS2: 1,
  NFCI: 5,
  DFF: 1,
  T10Y2Y: 1,
});

function clamp01(v) {
  if (!Number.isFinite(v) || v <= 0.0) return 0.0;
  if (v >= 1.0) return 1.0;
  return v;
}

function roundHalfUpInt(v) {
  return Math.floor(v + 0.5);
}

export function computeLiveStressIndexJS({
  hmm_p = 0.0,
  vxn = 0.0,
  vix_ratio = 0.0,
  dd_from_ath = 0.0,
  close = 0.0,
  sma200 = 0.0,
  ewmac = 0.0,
  hyg_lqd = 0.0,
  hyg_sma50 = 0.0,
  baa_rise63 = null,
  dgs2_jump63 = null,
  nfci_jump20 = null,
  def_ret20 = 0.0,
  rsp_spy = 0.0,
  rsp_sma50 = 0.0,
  iwm_qqq = 0.0,
  iwm_sma50 = 0.0,
  ad_below50 = false,
  vvix = 0.0,
  vvix_p75 = 0.0,
  skew10 = 0.0,
  skew_p75 = 0.0,
  vr_jump5 = 0.0,
} = {}) {
  const baaEff =
    baa_rise63 === null || baa_rise63 === undefined || !Number.isFinite(Number(baa_rise63)) || Number(baa_rise63) <= -900
      ? 0.0
      : Number(baa_rise63);
  const dgs2Eff =
    dgs2_jump63 === null || dgs2_jump63 === undefined || !Number.isFinite(Number(dgs2_jump63)) || Number(dgs2_jump63) <= -900
      ? 0.0
      : Number(dgs2_jump63);
  const nfciEff =
    nfci_jump20 === null || nfci_jump20 === undefined || !Number.isFinite(Number(nfci_jump20)) || Number(nfci_jump20) <= -900
      ? 0.0
      : Number(nfci_jump20);

  const regimeVol =
    clamp01(Number(hmm_p)) * 18.0 +
    clamp01((Number(vxn) - 20.0) / 20.0) * 7.0 +
    clamp01((Number(vix_ratio) - 0.9) / 0.2) * 5.0;

  const trendDd =
    clamp01((-Number(dd_from_ath) - 0.03) / 0.17) * 12.0 +
    (Number(sma200) > 0.0 && Number(close) < Number(sma200) ? 6.0 : 0.0) +
    clamp01(-Number(ewmac) / 0.8) * 7.0;

  const creditMacro =
    (Number(hyg_sma50) > 0.0 && Number(hyg_lqd) < Number(hyg_sma50) ? 8.0 : 0.0) +
    clamp01(Math.max(0.0, baaEff) / 0.25) * 8.0 +
    clamp01(Math.max(Math.max(0.0, dgs2Eff) / 0.5, Math.max(0.0, nfciEff) / 0.15)) * 9.0;

  const breadthTail =
    clamp01(Math.max(0.0, Number(def_ret20)) / 0.1) * 8.0 +
    (Number(rsp_sma50) > 0.0 && Number(rsp_spy) < Number(rsp_sma50) ? 2.0 : 0.0) +
    (Number(iwm_sma50) > 0.0 && Number(iwm_qqq) < Number(iwm_sma50) ? 2.0 : 0.0) +
    (ad_below50 ? 2.0 : 0.0) +
    (Number(vvix_p75) > 0.0 && Number(vvix) >= Number(vvix_p75) ? 2.0 : 0.0) +
    (Number(skew_p75) > 0.0 && Number(skew10) >= Number(skew_p75) ? 2.0 : 0.0) +
    (Number(vr_jump5) >= 0.06 ? 2.0 : 0.0);

  const rawTotal = Math.max(0.0, Math.min(100.0, regimeVol + trendDd + creditMacro + breadthTail));
  const idxInt = roundHalfUpInt(rawTotal);
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

  const r1 = x => Math.round(x * 10) / 10;
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

const M7_TP_SPECS = Object.freeze({
  standard: {
    id: 'standard',
    code: 'NEAR_ITM_105_5DLOCK',
    label_en: 'Near-ITM (VIX/3M>=1.10 & QQQ<=1.05×K | VIX>=45 | >=5x Late)',
    label_zh: '准实值止盈（倒挂>=1.10且<=1.05×K | VIX>=45 | 临期>=5x）',
  },
  itm_tp: {
    id: 'itm_tp',
    code: 'STRICT_ITM_100_5DLOCK',
    label_en: 'Strict ITM (VIX/3M>=1.10 & QQQ<=1.00×K | VIX>=45 | >=5x Late)',
    label_zh: '严格实值止盈（倒挂>=1.10且<=1.00×K | VIX>=45 | 临期>=5x）',
  },
});

const M7_MODULE_SHORT = Object.freeze({
  M0: { pillar: 'P1', points: 35, short_en: 'M0 Six Lights', short_zh: 'M0 六灯基线' },
  M6: { pillar: 'P1', points: 20, short_en: 'M6 Breadth/Def', short_zh: 'M6 宽度+防御' },
  M2: { pillar: 'P2', points: 20, short_en: 'M2 Vol Desk', short_zh: 'M2 期权台预警' },
  M5: { pillar: 'P2', points: 20, short_en: 'M5 Causal HMM', short_zh: 'M5 因果HMM' },
  M4: { pillar: 'P3', points: 35, short_en: 'M4 Bear Rally', short_zh: 'M4 熊市反弹自满' },
  M3: { pillar: 'P3', points: 20, short_en: 'M3 Credit/Macro', short_zh: 'M3 信用宏观压力' },
});

const r1 = v => (Number.isFinite(v) ? Math.round(v * 10) / 10 : null);
const r2 = v => (Number.isFinite(v) ? Math.round(v * 100) / 100 : null);
const r3 = v => (Number.isFinite(v) ? Math.round(v * 1000) / 1000 : null);
const r4 = v => (Number.isFinite(v) ? Math.round(v * 10000) / 10000 : null);
const r5 = v => (Number.isFinite(v) ? Math.round(v * 100000) / 100000 : null);

function erf(x) {
  const sign = x < 0 ? -1 : 1;
  const ax = Math.abs(x);
  const t = 1.0 / (1.0 + 0.3275911 * ax);
  const y =
    1.0 -
    ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t +
      0.254829592) *
      t *
      Math.exp(-ax * ax);
  return sign * y;
}

function normCdf(x) {
  return 0.5 * (1.0 + erf(x / Math.SQRT2));
}

function clip(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

function polyvalDesc(coeffs, x) {
  let acc = 0.0;
  for (let i = 0; i < coeffs.length; i += 1) {
    acc = acc * x + coeffs[i];
  }
  return acc;
}

export function evalSkewIv(S, K, T, r, q, vxnPct, coeffs) {
  const tEff = Math.max(T, 1.0 / 365.0);
  const fwd = S * Math.exp((r - q) * tEff);
  const logM = clip(Math.log(K / fwd), -0.22, 0.2);
  const ratio = clip(polyvalDesc(coeffs, logM), 0.72, 1.55);
  return Math.max(0.06, (vxnPct / 100.0) * ratio);
}

export function bsmPrice(S, K, T, r, q, sigma, optType) {
  if (T <= 1e-8 || sigma <= 1e-8) {
    return optType === 'call' ? Math.max(0.0, S - K) : Math.max(0.0, K - S);
  }
  const sqrtT = Math.sqrt(T);
  const d1 = (Math.log(S / K) + (r - q + 0.5 * sigma * sigma) * T) / (sigma * sqrtT);
  const d2 = d1 - sigma * sqrtT;
  if (optType === 'call') {
    return S * Math.exp(-q * T) * normCdf(d1) - K * Math.exp(-r * T) * normCdf(d2);
  }
  return K * Math.exp(-r * T) * normCdf(-d2) - S * Math.exp(-q * T) * normCdf(-d1);
}

export function bsmDelta(S, K, T, r, q, sigma, optType) {
  if (T <= 1e-8 || sigma <= 1e-8) {
    if (optType === 'call') return S > K ? 1.0 : 0.0;
    return S < K ? -1.0 : 0.0;
  }
  const sqrtT = Math.sqrt(T);
  const d1 = (Math.log(S / K) + (r - q + 0.5 * sigma * sigma) * T) / (sigma * sqrtT);
  const discQ = Math.exp(-q * T);
  return optType === 'call' ? discQ * normCdf(d1) : discQ * (normCdf(d1) - 1.0);
}

function bsmCallDelta(S, K, T, r, q, sigma) {
  if (T <= 1e-8 || sigma <= 1e-8) return S > K ? 1.0 : 0.0;
  const d1 = (Math.log(S / K) + (r - q + 0.5 * sigma * sigma) * T) / (sigma * Math.sqrt(T));
  return Math.exp(-q * T) * normCdf(d1);
}

function solveCallStrikeForDelta(S, T, r, q, vxnPct, coeffs, targetDelta) {
  let lo = S * 1.02;
  let hi = S * 1.3;
  const sqrtT = Math.sqrt(Math.max(T, 1e-6));
  const discQ = Math.exp(-q * T);
  for (let it = 0; it < 30; it += 1) {
    const mid = 0.5 * (lo + hi);
    const sig = evalSkewIv(S, mid, T, r, q, vxnPct, coeffs);
    const d1 = (Math.log(S / mid) + (r - q + 0.5 * sig * sig) * T) / (sig * sqrtT);
    const delta = discQ * normCdf(d1);
    if (delta > targetDelta) lo = mid;
    else hi = mid;
  }
  return 0.5 * (lo + hi);
}

function solveCallStrikeForBid(S, T, r, q, vxnPct, coeffs, targetBid, slip = OPT_SLIP) {
  if (targetBid < 0.05) return null;
  let lo = S * 1.01;
  let hi = S * 1.4;
  const bidAt = kc => {
    const sig = evalSkewIv(S, kc, T, r, q, vxnPct, coeffs);
    return bsmPrice(S, kc, T, r, q, sig, 'call') * (1.0 - slip);
  };
  if (bidAt(lo) < targetBid) return null;
  for (let it = 0; it < 30; it += 1) {
    const mid = 0.5 * (lo + hi);
    if (bidAt(mid) >= targetBid) lo = mid;
    else hi = mid;
  }
  return lo;
}

function optExecPriceSp(S, K, T, r, q, vxnPct, coeffs, optType, side, slip = OPT_SLIP) {
  const sigma = evalSkewIv(S, K, T, r, q, vxnPct, coeffs);
  const mid = bsmPrice(S, K, T, r, q, sigma, optType);
  if (side === 'sell') return [Math.max(0.0, mid * (1.0 - slip) - OPT_COMM_PER_SH), mid];
  if (side === 'buy') return [mid * (1.0 + slip) + OPT_COMM_PER_SH, mid];
  return [mid, mid];
}

export function decomposeNakedPutConvexity(
  s0,
  s1,
  kp,
  t0,
  t1,
  r0,
  r1,
  q0,
  q1,
  vxn0,
  vxn1,
  coeffs,
  actualNetPnlSh,
) {
  const sp0 = evalSkewIv(s0, kp, t0, r0, q0, vxn0, coeffs);
  const p0Mid = bsmPrice(s0, kp, t0, r0, q0, sp0, 'put');
  const delta0 = bsmDelta(s0, kp, t0, r0, q0, sp0, 'put');
  const dvDelta = delta0 * (s1 - s0);

  const spS1 = evalSkewIv(s1, kp, t0, r0, q0, vxn0, coeffs);
  const pS1 = bsmPrice(s1, kp, t0, r0, q0, spS1, 'put');
  const dvGamma = pS1 - p0Mid - dvDelta;

  let dvVega = 0.0;
  if (t1 > 1e-6) {
    const spT1V0 = evalSkewIv(s1, kp, t1, r1, q1, vxn0, coeffs);
    const spT1V1 = evalSkewIv(s1, kp, t1, r1, q1, vxn1, coeffs);
    const pT1V0 = bsmPrice(s1, kp, t1, r1, q1, spT1V0, 'put');
    const pT1V1 = bsmPrice(s1, kp, t1, r1, q1, spT1V1, 'put');
    dvVega = pT1V1 - pT1V0;
  }
  const dvThetaSlip = actualNetPnlSh - (dvDelta + dvGamma + dvVega);
  const convMult = dvDelta > 0.2 && actualNetPnlSh > 0 ? actualNetPnlSh / dvDelta : null;
  return { delta0, dvDelta, dvGamma, dvVega, dvThetaSlip, convMult };
}

function parseIsoDayMs(d) {
  return Date.parse(`${d}T00:00:00Z`);
}

function addCalendarDays(isoDateStr, days) {
  const dt = new Date(parseIsoDayMs(isoDateStr) + days * 86400000);
  return dt.toISOString().slice(0, 10);
}

function diffDays(dLaterMs, dEarlierMs) {
  return Math.round((dLaterMs - dEarlierMs) / 86400000);
}

function bisectLeftMs(msArr, targetMs) {
  let lo = 0;
  let hi = msArr.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (msArr[mid] < targetMs) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

function pickExpiryStrictMax14(msArr, dates, curIdx, targetDte, hardCapDte = 14) {
  const curMs = msArr[curIdx];
  const targetMs = curMs + targetDte * 86400000;
  let pos = bisectLeftMs(msArr, targetMs);
  if (pos < dates.length) {
    let expMs = msArr[pos];
    while (diffDays(expMs, curMs) > hardCapDte && pos > curIdx + 1) {
      pos -= 1;
      expMs = msArr[pos];
    }
    return [dates[pos], expMs, Math.max(1, diffDays(expMs, curMs))];
  }
  const capDays = Math.min(targetDte, hardCapDte);
  const expMs = curMs + capDays * 86400000;
  return [new Date(expMs).toISOString().slice(0, 10), expMs, Math.max(1, capDays)];
}

export function evalCore3Signal(sigDay) {
  const m0 = Boolean(sigDay?.M0);
  const m6 = Boolean(sigDay?.M6);
  const m4 = Boolean(sigDay?.M4);
  const p1 = sigDay?.p1_c3 !== undefined ? Number(sigDay.p1_c3) : Math.min(45.0, (m0 ? 35.0 : 0.0) + (m6 ? 20.0 : 0.0));
  const p2 = 0.0;
  const p3 = sigDay?.p3_c3 !== undefined ? Number(sigDay.p3_c3) : m4 ? 35.0 : 0.0;
  const prob = sigDay?.crisis_prob_c3 !== undefined ? Number(sigDay.crisis_prob_c3) : Math.min(100.0, p1 + p3);
  const targetSlots =
    sigDay?.target_slots_c3 !== undefined
      ? Number(sigDay.target_slots_c3)
      : prob >= 65.0
        ? 3
        : prob >= 45.0
          ? 2
          : prob >= 35.0
            ? 1
            : 0;
  const mask = (m0 ? 1 : 0) | (m6 ? 2 : 0) | (m4 ? 16 : 0);
  return { p1, p2, p3, prob, targetSlots, mask };
}

export function formatM7TriggerLabels(sigDay, maxSlots, core3Only = false) {
  const mods = [];
  const p1Parts = [];
  const p2Parts = [];
  const p3Parts = [];
  if (sigDay?.M0) {
    mods.push('M0');
    p1Parts.push('M0');
  }
  if (sigDay?.M6) {
    mods.push('M6');
    p1Parts.push('M6');
  }
  if (!core3Only && sigDay?.M2) {
    mods.push('M2');
    p2Parts.push('M2');
  }
  if (!core3Only && sigDay?.M5) {
    mods.push('M5');
    p2Parts.push('M5');
  }
  if (sigDay?.M4) {
    mods.push('M4');
    p3Parts.push('M4');
  }
  if (!core3Only && sigDay?.M3) {
    mods.push('M3');
    p3Parts.push('M3');
  }

  const pillarTags = [];
  if (p1Parts.length) pillarTags.push(`P1:${p1Parts.join('+')}`);
  if (p2Parts.length) pillarTags.push(`P2:${p2Parts.join('+')}`);
  if (p3Parts.length) pillarTags.push(`P3:${p3Parts.join('+')}`);
  const codeStr = pillarTags.length ? pillarTags.join(' + ') : core3Only ? 'Core-3' : 'M7';

  let prob;
  let tSlots;
  if (core3Only) {
    const c3 = evalCore3Signal(sigDay);
    prob = Math.round(c3.prob);
    tSlots = c3.targetSlots || 1;
  } else {
    prob = Math.round(Number(sigDay?.crisis_prob ?? 0));
    tSlots = Number((maxSlots === 3 ? sigDay?.target_slots_m7g : sigDay?.target_slots_m7) || 1);
  }
  const trigEn = `${codeStr} · Score ${prob}% (Target ${tSlots}/${maxSlots} Slots)`;
  const trigZh = `${codeStr} · 概率 ${prob}%（目标 ${tSlots}/${maxSlots} 槽）`;
  return { mods, codeStr, trigEn, trigZh };
}

function computeM7BhBaseline(evalBars, useReal = true) {
  const n = evalBars.length;
  const preSh = new Array(n);
  const postSh = new Array(n);
  const nav = new Array(n);
  const px0 = useReal ? Number(evalBars[0].close) : Number(evalBars[0].open);
  let sh = INITIAL_CAPITAL / (px0 * (1.0 + STOCK_REBAL_FEE));
  for (let i = 0; i < n; i += 1) {
    const cl = Number(evalBars[i].close);
    const div = Number(evalBars[i].dividends);
    preSh[i] = sh;
    if (div > 0 && sh > 0) {
      sh += (sh * div) / (cl * (1.0 + STOCK_REBAL_FEE));
    }
    postSh[i] = sh;
    nav[i] = sh * cl;
  }
  return { nav, preSh, postSh, finalSh: sh, endNav: nav[n - 1] };
}

export function simulateM7StrategyJS(
  evalBars,
  coeffs,
  strategyId,
  sigSeries,
  {
    putOtm = 'otm15',
    m7TpMode = 'standard',
    rollMode = 'adaptive_120_90',
    m0Enabled = true,
    ccMode = 'cc_off',
    spMode = 'sp_off',
    wcMode = 'wc_reclaim_30d_d35',
    realQuoteCache = undefined,
    fillMode = DEFAULT_M7_FILL_MODE,
  } = {},
) {
  const realCache = realQuoteCache === undefined ? getRealQuoteCache() : realQuoteCache;
  const useReal = Boolean(realCache && realCache.selections && realCache.contracts);
  const effFillMode = CRISIS_OBSERVATORY_FILL_MODES.includes(fillMode) ? fillMode : DEFAULT_M7_FILL_MODE;
  const isCore3 = strategyId === 'Core3_Adaptive';
  const isGraded = strategyId === 'M7G_Graded' || isCore3;
  const maxSlots = isGraded ? 3 : 2;

  // Safety guardrail: never allow 90D Hold on Core-3 (degrades to 0.87x PF)
  let effRollMode = rollMode;
  if (isCore3 && effRollMode === '90d_hold') {
    effRollMode = 'adaptive_120_90';
  }
  if (!['adaptive_120_90', 'adaptive_125_90', '120d_roll50', '90d_hold'].includes(effRollMode)) {
    effRollMode = 'adaptive_120_90';
  }

  const baseEnabled = true;
  const baseBudgetPct = 0.002;
  const m7FixedBudgetPct = 0.0125;
  const baseDte = 125;
  const baseRollDte = 75;
  const baseMoneyness = 0.85;
  const baseVixMax = 20.0;
  const baseVrMax = 1.02;
  const extremeVixTp = 45.0;

  const otmPctInt = putOtm === 'otm20' ? 20 : 15;
  const putMoneyness = putOtm === 'otm20' ? 0.8 : 0.85;
  const requireItmTp = m7TpMode === 'itm_tp';
  const nearItmMult = requireItmTp ? 1.0 : 1.05;
  const tpCode = requireItmTp ? 'STRICT_ITM_100_5DLOCK' : 'NEAR_ITM_105_5DLOCK';
  const isAdaptive = effRollMode === 'adaptive_120_90' || effRollMode === 'adaptive_125_90';
  const isRoll50 = effRollMode === '120d_roll50';
  const targetDte = isAdaptive ? 125 : isRoll50 ? 120 : 90;
  const rollDteThr = isAdaptive ? 75 : isRoll50 ? 50 : 0;
  const putMultMaxDteBase = 60;
  const putMultMaxDteM7 = 45;
  const vixRatioTp = 1.1;
  const putMultTp = 5.0;
  const stepCalDays = 30;
  const escalateMinDays = 21;
  const lockoutDays = 5;
  const lockoutInvThresh = 1.0;
  const opraMaxD = useReal ? String(realCache?.opra_range?.[1] || realCache?.opra_date_max || '2025-12-15') : '';

  const slotsForSig = sd => {
    if (isCore3) return evalCore3Signal(sd).targetSlots;
    if (isGraded) return Number(sd.target_slots_m7g ?? 0);
    return Number(sd.target_slots_m7 ?? 0);
  };
  const probTuple = sd => {
    if (isCore3) {
      const c3 = evalCore3Signal(sd);
      return [c3.prob, c3.p1, c3.p2, c3.p3];
    }
    return [Number(sd.crisis_prob ?? 0), Number(sd.p1 ?? 0), Number(sd.p2 ?? 0), Number(sd.p3 ?? 0)];
  };
  const tenorForSig = isCtaFlag => {
    if (isAdaptive) {
      return isCtaFlag ? [90, 30] : [125, 75];
    }
    if (isRoll50) {
      return [120, 50];
    }
    return [90, 0];
  };

  const bhM7 = computeM7BhBaseline(evalBars, useReal);
  const nDays = evalBars.length;
  const dates = evalBars.map(r => r.date);
  const msArr = dates.map(parseIsoDayMs);
  const finalBhSh = bhM7.finalSh;
  const finalCl = Number(evalBars[nDays - 1].close);

  const qStats = {
    totalLookups: 0,
    realOpraHits: 0,
    realPolygonHits: 0,
    bsmFallbacks: 0,
    opraWindowFallbacks: 0,
  };
  const recSrc = (src, dStr = '') => {
    qStats.totalLookups += 1;
    if (String(src).startsWith('real_opra')) qStats.realOpraHits += 1;
    else if (String(src).startsWith('real_polygon')) qStats.realPolygonHits += 1;
    else {
      qStats.bsmFallbacks += 1;
      if (opraMaxD && dStr && dStr <= opraMaxD) qStats.opraWindowFallbacks += 1;
    }
  };
  const isExp = (idx, expMs) => (useReal ? isExpiryDay(idx, msArr, expMs) : msArr[idx] >= expMs);

  const selectRec = (d, tag) => {
    if (!useReal) return null;
    const raw = realCache.selections[`${d}|${tag}`];
    if (!raw) return null;
    const [exp, kCents, bid, ask, iv, dl, srcCode] = raw;
    const expMs = parseIsoDayMs(exp);
    const src = CODE_TO_SRC[srcCode] || 'real_opra';
    const strike = kCents / 100.0;
    return {
      exp,
      expMs,
      strike,
      k_cents: kCents,
      bid,
      ask,
      mid: 0.5 * (bid + ask),
      iv: iv !== null && Number.isFinite(iv) ? iv : null,
      delta: dl !== null && Number.isFinite(dl) ? dl : null,
      source: src,
      occ_symbol: formatOccSymbol('QQQ', exp, tag.startsWith('p_') || tag.startsWith('sp_') ? 'put' : 'call', strike),
    };
  };

  const lookupOpt = (
    dStr,
    optType,
    expStr,
    kVal,
    kCents,
    spotPx,
    remDays,
    rC,
    qC,
    vxnC,
    lastIv,
    slipBsm = OPT_SLIP,
    ivRatioAnchor = null,
  ) => {
    if (useReal && kCents !== null && kCents !== undefined) {
      const ckey = `${optType[0]}|${expStr}|${kCents}`;
      const dayRec = realCache.contracts[ckey]?.[dStr];
      if (dayRec) {
        const [bid, ask, ivRaw, dlRaw, srcCode] = dayRec;
        const mid = 0.5 * (bid + ask);
        const src = CODE_TO_SRC[srcCode] || 'real_opra';
        const tR = Math.max(1, remDays) / 365.0;
        const iv =
          ivRaw !== null && Number.isFinite(ivRaw)
            ? ivRaw
            : lastIv !== null && Number.isFinite(lastIv)
              ? lastIv
              : evalSkewIv(spotPx, kVal, tR, rC, qC, vxnC, coeffs);
        const dl =
          dlRaw !== null && Number.isFinite(dlRaw)
            ? dlRaw
            : bsmDelta(spotPx, kVal, tR, rC, qC, iv, optType);
        recSrc(src, dStr);
        return { bid, ask, mid, iv, delta: dl, src };
      }
    }
    const tR = Math.max(0, remDays) / 365.0;
    const opraMax = opraMaxD || '2025-12-15';
    let sig;
    if (
      useReal &&
      lastIv !== null &&
      lastIv !== undefined &&
      Number.isFinite(lastIv) &&
      lastIv >= 0.04 &&
      lastIv <= 2.5 &&
      dStr <= opraMax
    ) {
      sig = Number(lastIv);
    } else {
      const baseSig = evalSkewIv(spotPx, kVal, Math.max(tR, 1.0 / 365.0), rC, qC, vxnC, coeffs);
      if (
        ivRatioAnchor !== null &&
        ivRatioAnchor !== undefined &&
        Number.isFinite(ivRatioAnchor) &&
        ivRatioAnchor >= 0.5 &&
        ivRatioAnchor <= 2.0
      ) {
        sig = clip(baseSig * clip(Number(ivRatioAnchor), 0.7, 1.4), 0.04, 2.5);
      } else {
        sig = baseSig;
      }
    }
    const mid = bsmPrice(spotPx, kVal, tR, rC, qC, sig, optType);
    const dl = bsmDelta(spotPx, kVal, tR, rC, qC, sig, optType);
    recSrc('bsm_fallback', dStr);
    const bidOut = Math.max(0.0, mid * (1.0 - slipBsm));
    const askOut = Math.max(bidOut, mid * (1.0 + slipBsm));
    return {
      bid: bidOut,
      ask: askOut,
      mid,
      iv: sig,
      delta: dl,
      src: 'bsm_fallback',
    };
  };

  const buyPx = (bid, ask, mid, src, slipBsm = OPT_SLIP) =>
    useReal ? execBuyPrice(bid, ask, mid, src, slipBsm, effFillMode) : mid * (1.0 + slipBsm) + OPT_COMM_PER_SH;
  const sellPx = (bid, ask, mid, src, slipBsm = OPT_SLIP) =>
    useReal
      ? execSellPrice(bid, ask, mid, src, slipBsm, effFillMode)
      : Math.max(0.0, mid * (1.0 - slipBsm) - OPT_COMM_PER_SH);

  const px0 = useReal ? Number(evalBars[0].close) : Number(evalBars[0].open);
  let coreShares = INITIAL_CAPITAL / (px0 * (1.0 + STOCK_REBAL_FEE));
  let m7Active = [];
  let baseActive = [];
  let pendingSig = null;
  let pendingBaseOpen = false;
  let baseDaysHedged = 0;
  let baseGateOpenDays = 0;

  let postTpLockout = false;
  let nonInvertedStreak = 0;
  let m7LockedPrevEod = false;
  let baseLockedPrevEod = false;
  let lockoutDaysTotal = 0;
  const lockoutEpisodes = [];
  let curEp = null;
  let lastTpDate = null;
  let lastUnlockDate = null;

  const ccEnabled = ccMode !== 'cc_off';
  const ccDte = 25;
  const ccAthLimit = 0.03;
  const ccMinVxn = 0.0;
  const ccTargetDelta = 0.12;
  const ccMinOtm = 0.05;
  let ccStopDelta = null;
  let ccRollMode = null;
  let ccMaxRolls = 3;
  if (ccMode === 'cc_d12_d35') ccStopDelta = 0.35;
  else if (ccMode === 'cc_d12_r45') {
    ccStopDelta = 0.45;
    ccRollMode = 'fresh_30d';
    ccMaxRolls = 3;
  } else if (ccMode === 'cc_d12_cr55') {
    ccStopDelta = 0.55;
    ccRollMode = 'credit_45d';
    ccMaxRolls = 3;
  }

  let activeCc = null;
  let pendingCc = null;
  let pendingCcDeploy = false;
  let ccCash = 0.0;
  let ccGrossPrem = 0.0;
  let ccGrossLoss = 0.0;
  let ccFundedPuts = 0.0;
  let ccAssignedCnt = 0;
  let ccTid = 0;
  const ccLedger = [];

  const spEnabled = spMode !== 'sp_off';
  const spDte = spMode === 'sp_10d_vixf' ? 10 : 14;
  const spOtmPct = 0.05;
  const spMaxLev = spMode === 'sp_14d_cap10' ? 0.1 : 0.2;
  const spRequireVixFalling = spMode === 'sp_10d_vixf';
  const spVixThr = 1.0;

  let spCash = 0.0;
  let assignedShares = 0.0;
  let assignedCostK = 0.0;
  let activeSp = null;
  let activeWc = null;
  let pendingSp = null;
  let pendingWc = null;
  let spTid = 0;
  let wcTid = 0;
  let curCycleId = 0;
  let curCycleStartMs = null;
  let maxWheelCycleDays = 0;
  let spMarginInterestTotal = 0.0;
  let spCommTotal = 0.0;
  let spAssignCount = 0;
  let daysShortPutOpen = 0;
  let daysLevered = 0;
  let maxGrossStockLev = 1.0;
  let maxNotionalLev = 1.0;
  const spClosedLedger = [];
  const wcClosedLedger = [];

  const sweepSpCash = px => {
    if (Math.abs(spCash) > 1e-8) {
      const denom = px * (1.0 + (spCash > 0 ? STOCK_REBAL_FEE : -STOCK_REBAL_FEE));
      coreShares += spCash / denom;
      spCash = 0.0;
    }
  };

  const currentNavApprox = px => {
    let navV = (coreShares + assignedShares) * px + ccCash + spCash;
    for (const trM of m7Active) navV += Number(trM.last_mtm_usd ?? trM.entry_cost_usd);
    for (const trB of baseActive) navV += Number(trB.last_mtm_usd ?? trB.entry_cost_usd);
    return Math.max(navV, 1.0);
  };

  const estimateNavExec = (exPx, vxnE, rC, qC, curMs, dStr) => {
    let mtmP = 0.0;
    for (const tr of [...m7Active, ...baseActive]) {
      const remD = Math.max(1, diffDays(tr.expMs, curMs));
      const { mid: pmO } = lookupOpt(dStr, 'put', tr.exp_date, tr.kp, tr.k_cents, exPx, remD, rC, qC, vxnE, tr.last_iv, OPT_SLIP);
      mtmP += tr.hedged_shares * pmO;
    }
    let mtmCcO = 0.0;
    if (activeCc !== null) {
      const remCO = Math.max(1, diffDays(activeCc.expMs, curMs));
      const { mid: cmO } = lookupOpt(dStr, 'call', activeCc.exp_date, activeCc.kc, activeCc.k_cents, exPx, remCO, rC, qC, vxnE, activeCc.last_iv, OPT_SLIP);
      mtmCcO = -activeCc.shares * cmO;
    }
    return Math.max(1.0, (coreShares + assignedShares) * exPx + ccCash + spCash + mtmP + mtmCcO);
  };

  const selectOrSynthPut = (idxDay, dStr, spotPx, tDte, moneynessVal, otmInt, rEn, qEn, vxnEn) => {
    const curMs = msArr[idxDay];
    let cEn = null;
    if (useReal) {
      cEn = selectRec(dStr, `p_${tDte}_${otmInt}`);
      if (cEn === null && opraMaxD && dStr <= opraMaxD) {
        qStats.opraWindowFallbacks += 1;
        return null;
      }
    }
    let expDate;
    let expMs;
    let entryDteVal;
    let tEn;
    let kp;
    let kCentsEn;
    let enBidRaw;
    let enAskRaw;
    let midEn;
    let putAskEn;
    let ivEn;
    let srcEn;
    let occEn;
    if (cEn !== null) {
      recSrc(cEn.source, dStr);
      expDate = cEn.exp;
      expMs = cEn.expMs;
      entryDteVal = Math.max(1, diffDays(expMs, curMs));
      tEn = entryDteVal / 365.0;
      kp = cEn.strike;
      kCentsEn = cEn.k_cents;
      enBidRaw = cEn.bid;
      enAskRaw = cEn.ask;
      midEn = cEn.mid;
      putAskEn = buyPx(enBidRaw, enAskRaw, midEn, cEn.source, OPT_SLIP);
      ivEn = cEn.iv;
      srcEn = cEn.source;
      occEn = cEn.occ_symbol || formatOccSymbol('QQQ', expDate, 'put', kp);
    } else {
      const targetMs = curMs + tDte * 86400000;
      const pos = bisectLeftMs(msArr, targetMs);
      expDate = pos < nDays ? dates[pos] : new Date(targetMs).toISOString().slice(0, 10);
      expMs = pos < nDays ? msArr[pos] : targetMs;
      entryDteVal = Math.max(1, diffDays(expMs, curMs));
      tEn = entryDteVal / 365.0;
      kp = r2(spotPx * moneynessVal);
      kCentsEn = Math.round(kp * 100.0);
      ivEn = evalSkewIv(spotPx, kp, tEn, rEn, qEn, vxnEn, coeffs);
      midEn = bsmPrice(spotPx, kp, tEn, rEn, qEn, ivEn, 'put');
      enBidRaw = Math.max(0.0, midEn * (1.0 - OPT_SLIP));
      enAskRaw = midEn * (1.0 + OPT_SLIP);
      putAskEn = buyPx(enBidRaw, enAskRaw, midEn, 'bsm_fallback', OPT_SLIP);
      srcEn = 'bsm_fallback';
      occEn = formatOccSymbol('QQQ', expDate, 'put', kp);
      recSrc('bsm_fallback', dStr);
    }
    let ivAnchorEn = null;
    if (String(srcEn).startsWith('real_opra') && ivEn !== null && Number.isFinite(ivEn) && ivEn >= 0.02 && ivEn <= 3.0) {
      const bsmIvRef = evalSkewIv(spotPx, kp, Math.max(tEn, 1.0 / 365.0), rEn, qEn, vxnEn, coeffs);
      ivAnchorEn = clip(ivEn / Math.max(bsmIvRef, 0.05), 0.5, 2.0);
    }
    return {
      expDate,
      expMs,
      entryDteVal,
      tEn,
      kp,
      kCentsEn,
      enBidRaw,
      enAskRaw,
      midEn,
      putAskEn,
      ivEn: ivEn !== null && Number.isFinite(ivEn) ? ivEn : null,
      ivAnchorEn,
      srcEn,
      occEn,
    };
  };

  const fundPutEntry = (entryCostUsd, cashFromSalvage, spotPx) => {
    let remNeed = entryCostUsd - cashFromSalvage;
    let dShEntry = 0.0;
    if (remNeed < -1e-8) {
      dShEntry = -remNeed / (spotPx * (1.0 + STOCK_REBAL_FEE));
      coreShares += dShEntry;
    } else if (remNeed > 1e-8) {
      if (ccEnabled && ccCash > 0.0) {
        const useCc = Math.min(ccCash, remNeed);
        ccCash -= useCc;
        ccFundedPuts += useCc;
        remNeed -= useCc;
      }
      if (remNeed > 1e-8) {
        dShEntry = -remNeed / (spotPx * (1.0 - STOCK_REBAL_FEE));
        coreShares += dShEntry;
      }
    }
    return dShEntry;
  };

  const navList = new Array(nDays);
  const equivShList = new Array(nDays);
  const anyActiveList = new Array(nDays);
  const activeSlotsList = new Array(nDays);
  const ledger = [];
  let tid = 0;

  const buildClosedLedgerRow = (
    tr,
    exitDateStr,
    idxDay,
    remDays,
    tRem,
    exitSpotPx,
    exitVxnVal,
    exitVixVal,
    exitVrVal,
    rC,
    qC,
    bEx,
    aEx,
    sellPxVal,
    srcEx,
    exitRsn,
    dSh,
    multComp,
  ) => {
    const hs = tr.hedged_shares;
    const exitUsd = hs * sellPxVal;
    const costPart = tr.entry_cost_usd;
    const roiMult = costPart > 1e-6 ? exitUsd / costPart : 0.0;
    const actualNetSh = sellPxVal - tr.entry_put_ask;
    const conv = decomposeNakedPutConvexity(
      tr.entry_spot,
      exitSpotPx,
      tr.kp,
      tr.T_entry,
      tRem,
      tr.entry_r,
      rC,
      tr.entry_q,
      qC,
      tr.entry_vxn,
      exitVxnVal,
      coeffs,
      actualNetSh,
    );
    const enSrc = tr.entry_source || 'bsm_fallback';
    const qTag = classifyQuoteSourceTag(enSrc, srcEx, tr.entry_date, exitDateStr, opraMaxD || '2025-12-15');
    const occSym = String(tr.occ_symbol || formatOccSymbol('QQQ', tr.exp_date, 'put', tr.kp));
    const isBaseB = tr.book === 'base';
    const netPnlRounded = r2(exitUsd - costPart);
    const dUsd = r2(conv.dvDelta * hs);
    const gUsd = r2(conv.dvGamma * hs);
    const vUsd = r2(conv.dvVega * hs);
    return {
      tranche_id: tr.tranche_id,
      strategy_id: strategyId,
      book: tr.book,
      book_label_en: isBaseB ? 'Book B · 0.20% Base' : 'Book M · 1.25% M7G',
      book_label_zh: isBaseB ? 'B账本 · 0.20%常态基底' : 'M账本 · 1.25%战术M7G',
      budget_pct_nav: isBaseB ? 0.2 : 1.25,
      entry_pct_nav: tr.entry_pct_nav,
      nav_at_entry: r2(tr.nav_at_entry),
      slot_num: tr.slot_num,
      tier: tr.tier,
      max_slots: maxSlots,
      tranche_type: 'naked_put',
      put_otm_pct: Number(tr.put_otm_pct || otmPctInt),
      tp_mode: tpCode,
      roll_mode: effRollMode,
      target_dte: Number(tr.target_dte || targetDte),
      roll_dte: Number(tr.roll_dte_thr || 0),
      is_cta: Boolean(tr.is_cta),
      quoteSource: qTag,
      quote_source: qTag,
      occSymbol: occSym,
      occ_symbol: occSym,
      exp: tr.exp_date,
      strike: r2(tr.kp),
      near_itm_strike_105: r2(tr.kp * nearItmMult),
      entryBid: r3(Number(tr.entry_bid_raw ?? tr.entry_put_ask)),
      entryAsk: r3(Number(tr.entry_ask_raw ?? tr.entry_put_ask)),
      exitBid: r3(bEx),
      exitAsk: r3(aEx),
      pricing_source: classifyTradeSource(enSrc, srcEx),
      entry_source: enSrc,
      exit_source: srcEx,
      signal_date: tr.signal_date,
      entry_date: tr.entry_date,
      planned_exp_date: tr.exp_date,
      exit_date: exitDateStr,
      actual_days_held: diffDays(msArr[idxDay], tr.entryMs),
      rem_dte_at_exit: remDays,
      exit_reason: exitRsn,
      sig_score: tr.sig_score,
      sig_ad_below50: tr.sig_ad_below50,
      crisis_prob: tr.crisis_prob,
      p1: tr.p1,
      p2: tr.p2,
      p3: tr.p3,
      triggered_modules: tr.triggered_modules,
      trigger_code: tr.trigger_code,
      trigger_en: tr.trigger_en,
      trigger_zh: tr.trigger_zh,
      entry_spot: r2(tr.entry_spot),
      entry_vxn: r2(tr.entry_vxn),
      entry_vix: r2(Number(tr.entry_vix || 0)),
      entry_vix_ratio: r3(tr.entry_vix_ratio),
      kp: r2(tr.kp),
      kc: null,
      call_cap_pct: null,
      hedged_shares: r2(hs),
      contracts_est: r2(hs / 100.0),
      slot_coverage: r4(tr.hedged_ratio),
      entry_put_ask_sh: r4(tr.entry_put_ask),
      tp_target_5x_sh: r4(5.0 * tr.entry_put_ask),
      entry_cost_usd: r2(costPart),
      entry_shares_sold: r4(tr.entry_shares_sold),
      exit_spot: r2(exitSpotPx),
      exit_vxn: r2(exitVxnVal),
      exit_vix: r2(exitVixVal),
      exit_vix_ratio: r3(exitVrVal),
      underlying_ret_pct: r2((exitSpotPx / tr.entry_spot - 1.0) * 100.0),
      put_exit_val_sh: r4(sellPxVal),
      call_exit_cost_sh: 0.0,
      exit_net_cash_usd: r2(exitUsd),
      net_pnl_usd: netPnlRounded,
      roi_mult: r2(roiMult),
      exit_shares_delta: r2(dSh),
      shares_added: r2(tr.entry_shares_sold + dSh),
      delta0: r4(conv.delta0),
      delta_usd: dUsd,
      gamma_usd: gUsd,
      vega_usd: vUsd,
      theta_slip_usd: r2(netPnlRounded - (dUsd + gUsd + vUsd)),
      convexity_mult: conv.convMult !== null ? r2(conv.convMult) : null,
      comp_entry_cost_usd: r2(tr.comp_entry_cost_usd),
      comp_put_gain_usd: r2(dSh * multComp),
      comp_call_drag_usd: 0.0,
    };
  };

  const openM7Tranche = (
    idxDay,
    dStr,
    spotPx,
    vxnEn,
    vixEn,
    rEn,
    qEn,
    capSlotsVal,
    sigPrev,
    prevRow,
    multMorningVal,
    cashFromSalvage = 0.0,
  ) => {
    const isCtaFlag = Boolean(sigPrev?.M4);
    const [tDte, rlDte] = tenorForSig(isCtaFlag);
    const cPack = selectOrSynthPut(idxDay, dStr, spotPx, tDte, putMoneyness, otmPctInt, rEn, qEn, vxnEn);
    if (cPack === null) {
      if (cashFromSalvage > 1e-8) {
        coreShares += cashFromSalvage / (spotPx * (1.0 + STOCK_REBAL_FEE));
      }
      return null;
    }
    const putAskEn = cPack.putAskEn;
    const curNav = currentNavApprox(spotPx) + cashFromSalvage;
    const budgetUsd = curNav * m7FixedBudgetPct;
    if (putAskEn < 0.03 || budgetUsd <= 1.0) {
      if (cashFromSalvage > 1e-8) {
        coreShares += cashFromSalvage / (spotPx * (1.0 + STOCK_REBAL_FEE));
      }
      return null;
    }
    const hedgedSh = budgetUsd / putAskEn;
    const entryCostUsd = budgetUsd;
    const dShEntry = fundPutEntry(entryCostUsd, cashFromSalvage, spotPx);
    tid += 1;
    const usedSlots = new Set(m7Active.map(t => t.slot_num));
    let slotNum = 1;
    while (usedSlots.has(slotNum)) slotNum += 1;
    const hr = hedgedSh / Math.max(coreShares, 1e-6);
    const { mods, codeStr, trigEn, trigZh } = formatM7TriggerLabels(sigPrev, maxSlots, isCore3);
    const [cProbR, p1R, p2R, p3R] = probTuple(sigPrev);
    return {
      tranche_id: tid,
      book: 'm7',
      slot_num: slotNum,
      tier: capSlotsVal,
      is_cta: isCtaFlag,
      target_dte: tDte,
      roll_dte_thr: rlDte,
      put_otm_pct: otmPctInt,
      occ_symbol: cPack.occEn,
      signal_date: String(prevRow.date),
      sig_score: Number(prevRow.score),
      sig_ad_below50:
        prevRow.ad_line !== undefined && prevRow.ad_sma50 !== undefined
          ? Number(prevRow.ad_line) < Number(prevRow.ad_sma50)
          : Boolean(prevRow.ad_below50),
      crisis_prob: cProbR,
      p1: p1R,
      p2: p2R,
      p3: p3R,
      triggered_modules: mods,
      trigger_code: codeStr,
      trigger_en: trigEn,
      trigger_zh: trigZh,
      entry_date: dStr,
      entryMs: msArr[idxDay],
      exp_date: cPack.expDate,
      expMs: cPack.expMs,
      entry_dte: cPack.entryDteVal,
      T_entry: cPack.tEn,
      entry_spot: spotPx,
      entry_vxn: vxnEn,
      entry_vix: vixEn,
      entry_vix_ratio: Number(prevRow.vix_ratio),
      entry_r: rEn,
      entry_q: qEn,
      kp: cPack.kp,
      k_cents: cPack.kCentsEn,
      last_iv: cPack.ivEn,
      iv_ratio_anchor: cPack.ivAnchorEn,
      entry_source: cPack.srcEn,
      entry_bid_raw: cPack.enBidRaw,
      entry_ask_raw: cPack.enAskRaw,
      hedged_shares: hedgedSh,
      ref_cov_sh: 0.0,
      hedged_ratio: hr,
      entry_put_ask: putAskEn,
      entry_cost_usd: entryCostUsd,
      entry_pct_nav: r3((entryCostUsd / Math.max(curNav, 1.0)) * 100.0),
      nav_at_entry: curNav,
      last_mtm_usd: entryCostUsd,
      entry_shares_sold: dShEntry,
      comp_entry_cost_usd: dShEntry * multMorningVal,
      pending_tp: false,
      pending_roll: false,
      tp_trigger_ratio: 0.0,
      tp_reason: '',
    };
  };

  const openBaseTranche = (
    idxDay,
    dStr,
    spotPx,
    vxnEn,
    vixEn,
    rEn,
    qEn,
    sigPrev,
    prevRow,
    multMorningVal,
    budgetUsd,
    cashFromSalvage = 0.0,
  ) => {
    const cPack = selectOrSynthPut(idxDay, dStr, spotPx, baseDte, baseMoneyness, 15, rEn, qEn, vxnEn);
    if (cPack === null) {
      if (cashFromSalvage > 1e-8) {
        coreShares += cashFromSalvage / (spotPx * (1.0 + STOCK_REBAL_FEE));
      }
      return null;
    }
    const putAskEn = cPack.putAskEn;
    if (putAskEn < 0.03 || budgetUsd <= 1.0) {
      if (cashFromSalvage > 1e-8) {
        coreShares += cashFromSalvage / (spotPx * (1.0 + STOCK_REBAL_FEE));
      }
      return null;
    }
    const curNav = currentNavApprox(spotPx) + cashFromSalvage;
    const hedgedSh = budgetUsd / putAskEn;
    const entryCostUsd = budgetUsd;
    const dShEntry = fundPutEntry(entryCostUsd, cashFromSalvage, spotPx);
    tid += 1;
    const hr = hedgedSh / Math.max(coreShares, 1e-6);
    const [cProbR, p1R, p2R, p3R] = probTuple(sigPrev);
    const prevVix = Number(prevRow.vix ?? 0);
    const prevVr = Number(prevRow.vix_ratio ?? 0);
    return {
      tranche_id: tid,
      book: 'base',
      slot_num: 0,
      tier: 0,
      is_cta: false,
      target_dte: baseDte,
      roll_dte_thr: baseRollDte,
      put_otm_pct: 15,
      occ_symbol: cPack.occEn,
      signal_date: String(prevRow.date),
      sig_score: Number(prevRow.score),
      sig_ad_below50:
        prevRow.ad_line !== undefined && prevRow.ad_sma50 !== undefined
          ? Number(prevRow.ad_line) < Number(prevRow.ad_sma50)
          : Boolean(prevRow.ad_below50),
      crisis_prob: cProbR,
      p1: p1R,
      p2: p2R,
      p3: p3R,
      triggered_modules: ['B_VIX20'],
      trigger_code: 'BASE_VIX20',
      trigger_en: `Book B 0.20% Base Floor (VIX ${prevVix.toFixed(1)}<=20 & VIX/3M ${prevVr.toFixed(3)}<1.02 · 125D->75D)`,
      trigger_zh: `B账本 0.20%常态基底（VIX ${prevVix.toFixed(1)}<=20 且 VIX/3M ${prevVr.toFixed(3)}<1.02 · 125D→75D硬换）`,
      entry_date: dStr,
      entryMs: msArr[idxDay],
      exp_date: cPack.expDate,
      expMs: cPack.expMs,
      entry_dte: cPack.entryDteVal,
      T_entry: cPack.tEn,
      entry_spot: spotPx,
      entry_vxn: vxnEn,
      entry_vix: vixEn,
      entry_vix_ratio: prevVr,
      entry_r: rEn,
      entry_q: qEn,
      kp: cPack.kp,
      k_cents: cPack.kCentsEn,
      last_iv: cPack.ivEn,
      iv_ratio_anchor: cPack.ivAnchorEn,
      entry_source: cPack.srcEn,
      entry_bid_raw: cPack.enBidRaw,
      entry_ask_raw: cPack.enAskRaw,
      hedged_shares: hedgedSh,
      ref_cov_sh: 0.0,
      hedged_ratio: hr,
      entry_put_ask: putAskEn,
      entry_cost_usd: entryCostUsd,
      entry_pct_nav: r3((entryCostUsd / Math.max(curNav, 1.0)) * 100.0),
      nav_at_entry: curNav,
      last_mtm_usd: entryCostUsd,
      entry_shares_sold: dShEntry,
      comp_entry_cost_usd: dShEntry * multMorningVal,
      pending_tp: false,
      pending_roll: false,
      tp_trigger_ratio: 0.0,
      tp_reason: '',
    };
  };

  for (let i = 0; i < nDays; i += 1) {
    const row = evalBars[i];
    const sigD = sigSeries[i];
    const d = dates[i];
    const curMs = msArr[i];
    const op = Number(row.open);
    const cl = Number(row.close);
    const div = Number(row.dividends);
    const vxnCl = Number(row.vxn);
    const vixCl = Number(row.vix ?? 0);
    const vixR = Number(row.vix_ratio);
    const rCur = Number(row.r);
    const qCur = Number(row.div_yield);
    const ddCur = Number(row.dd_from_ath);

    const execPx = useReal ? cl : op;
    let vxnEx = vxnCl;
    if (!useReal && i > 0) {
      const prevVxn = Number(evalBars[i - 1].vxn);
      const prevCl = Number(evalBars[i - 1].close);
      vxnEx = Math.max(10.0, prevVxn - 0.45 * (op / prevCl - 1.0) * 100.0);
    }

    const multMorning = (finalBhSh / bhM7.preSh[i]) * finalCl;
    const multEod = (finalBhSh / bhM7.postSh[i]) * finalCl;

    if (i > 0) {
      const dtYr = Math.max(1, diffDays(curMs, msArr[i - 1])) / 365.0;
      const rPrev = Number(evalBars[i - 1].r);
      if (ccCash > 0.0) ccCash *= 1.0 + rPrev * dtYr;
      if (spCash > 0.0) spCash *= 1.0 + rPrev * dtYr;
      else if (spCash < 0.0) {
        const mInt = Math.abs(spCash) * (rPrev + MARGIN_SPREAD) * dtYr;
        spCash -= mInt;
        spMarginInterestTotal += mInt;
      }
    }

    if (i > 0 && pendingCcDeploy && ccCash > 1.0) {
      coreShares += ccCash / (execPx * (1.0 + STOCK_REBAL_FEE));
      ccCash = 0.0;
      pendingCcDeploy = false;
    }

    if (i > 0 && activeCc !== null && activeCc.pending_close) {
      const remCc = Math.max(0, diffDays(activeCc.expMs, curMs));
      let cAskEx;
      let srcCcEx;
      if (isExp(i, activeCc.expMs)) {
        cAskEx = Math.max(0.0, execPx - activeCc.kc);
        srcCcEx = activeCc.entry_source || 'bsm_fallback';
      } else {
        const qCc = lookupOpt(d, 'call', activeCc.exp_date, activeCc.kc, activeCc.k_cents, execPx, remCc, rCur, qCur, vxnEx, activeCc.last_iv, OPT_SLIP);
        cAskEx = buyPx(qCc.bid, qCc.ask, qCc.mid, qCc.src, OPT_SLIP);
        srcCcEx = qCc.src;
      }
      const costCl = activeCc.shares * cAskEx;
      ccGrossLoss += costCl;
      if (ccCash >= costCl) ccCash -= costCl;
      else {
        coreShares -= (costCl - ccCash) / (execPx * (1.0 - STOCK_REBAL_FEE));
        ccCash = 0.0;
      }
      const closeReason = activeCc.close_reason || 'panic_close_uncap';
      const oldRolls = Number(activeCc.roll_count || 0);
      const oldSh = activeCc.shares;
      const enCcSrc = activeCc.entry_source || 'bsm_fallback';
      ccLedger.push({
        cc_id: activeCc.cc_id,
        entry_date: activeCc.entry_date,
        exit_date: d,
        entry_spot: r2(activeCc.entry_spot),
        kc: r2(activeCc.kc),
        exit_spot: r2(execPx),
        entry_vxn: r2(activeCc.entry_vxn),
        shares: r2(oldSh),
        prem_usd: r2(activeCc.prem_usd),
        loss_usd: r2(costCl),
        net_pnl_usd: r2(activeCc.prem_usd - costCl),
        exit_reason: closeReason,
        roll_gen: oldRolls,
        pricing_source: classifyTradeSource(enCcSrc, srcCcEx),
      });
      activeCc = null;
      if (
        (closeReason === 'delta_roll_up' || closeReason === 'delta_credit_roll') &&
        ccRollMode !== null &&
        oldRolls < ccMaxRolls
      ) {
        const rollDays = ccRollMode === 'credit_45d' ? 45 : 30;
        let cRoll = null;
        if (useReal) {
          if (ccRollMode === 'credit_45d') {
            cRoll = selectRec(d, `cc_45_cr_${Math.round(cAskEx * 100)}`);
          } else if (ccRollMode === 'fresh_30d') {
            cRoll = selectRec(d, 'cc_30_d12');
          }
        }
        let expDateR;
        let expMsR;
        let kcNew = null;
        let kCentsR = null;
        let cBidR = 0.0;
        let ivR = null;
        let srcR = 'bsm_fallback';
        if (cRoll !== null) {
          recSrc(cRoll.source);
          expDateR = cRoll.exp;
          expMsR = cRoll.expMs;
          kcNew = cRoll.strike;
          kCentsR = cRoll.k_cents;
          cBidR = sellPx(cRoll.bid, cRoll.ask, cRoll.mid, cRoll.source, OPT_SLIP);
          ivR = cRoll.iv;
          srcR = cRoll.source;
        } else {
          const targetMs = curMs + rollDays * 86400000;
          const posR = bisectLeftMs(msArr, targetMs);
          expDateR = posR < nDays ? dates[posR] : new Date(targetMs).toISOString().slice(0, 10);
          expMsR = posR < nDays ? msArr[posR] : targetMs;
          const tR = Math.max(1, diffDays(expMsR, curMs)) / 365.0;
          if (ccRollMode === 'credit_45d') {
            kcNew = solveCallStrikeForBid(execPx, tR, rCur, qCur, vxnEx, coeffs, cAskEx, OPT_SLIP);
          } else if (ccRollMode === 'fresh_30d') {
            kcNew = Math.max(
              execPx * (1.0 + ccMinOtm),
              solveCallStrikeForDelta(execPx, tR, rCur, qCur, vxnEx, coeffs, ccTargetDelta),
            );
          }
          if (kcNew !== null && kcNew > execPx * 1.01) {
            ivR = evalSkewIv(execPx, kcNew, tR, rCur, qCur, vxnEx, coeffs);
            const cmR = bsmPrice(execPx, kcNew, tR, rCur, qCur, ivR, 'call');
            cBidR = sellPx(cmR * (1.0 - OPT_SLIP), cmR * (1.0 + OPT_SLIP), cmR, 'bsm_fallback', OPT_SLIP);
            kCentsR = Math.round(kcNew * 100.0);
            recSrc('bsm_fallback');
          }
        }
        if (kcNew !== null && kcNew > execPx * 1.01 && cBidR >= 0.05) {
          const premR = oldSh * cBidR;
          ccTid += 1;
          ccGrossPrem += premR;
          ccCash += premR;
          activeCc = {
            cc_id: ccTid,
            entry_date: d,
            entryMs: curMs,
            exp_date: expDateR,
            expMs: expMsR,
            entry_spot: execPx,
            entry_vxn: vxnEx,
            kc: kcNew,
            k_cents: kCentsR,
            last_iv: ivR,
            entry_source: srcR,
            shares: oldSh,
            prem_usd: premR,
            pending_close: false,
            roll_count: oldRolls + 1,
          };
        }
      }
    }

    // 1A. Pending T+1 Close Exits for Book M (1.25% M7G)
    if (i > 0 && m7Active.length > 0) {
      const stillM7 = [];
      const m7RollReps = [];
      const prevRowM = evalBars[i - 1];
      const prevSigM = sigSeries[i - 1];
      const prevCapM = Math.min(maxSlots, slotsForSig(prevSigM));
      const prevAffordableM = Number(prevRowM.vxn) <= 27.0 && Number(prevRowM.vix_ratio) < 1.02;
      for (const tr of m7Active) {
        if (!tr.pending_tp && !tr.pending_roll) {
          stillM7.push(tr);
          continue;
        }
        const remDays = Math.max(0, diffDays(tr.expMs, curMs));
        const tRem = remDays / 365.0;
        const qEx = lookupOpt(
          d,
          'put',
          tr.exp_date,
          tr.kp,
          tr.k_cents,
          execPx,
          remDays,
          rCur,
          qCur,
          vxnEx,
          tr.last_iv,
          OPT_SLIP,
          tr.iv_ratio_anchor,
        );
        const putBid = sellPx(qEx.bid, qEx.ask, qEx.mid, qEx.src, OPT_SLIP);
        const exitUsd = tr.hedged_shares * putBid;
        const exitRsn = String(tr.tp_reason || 'roll_75d');
        let dSh = 0.0;
        if (exitRsn.startsWith('roll_')) {
          if (prevCapM > stillM7.length + m7RollReps.length && prevAffordableM) {
            if (!m7LockedPrevEod) {
              m7RollReps.push([exitUsd, prevCapM, prevSigM]);
            } else {
              if (curEp !== null) curEp.blocked_m7_rolls += 1;
              if (exitUsd > 1e-10) {
                dSh = exitUsd / (execPx * (1.0 + STOCK_REBAL_FEE));
                coreShares += dSh;
              }
            }
          } else if (exitUsd > 1e-10) {
            dSh = exitUsd / (execPx * (1.0 + STOCK_REBAL_FEE));
            coreShares += dSh;
          }
        } else if (exitUsd > 1e-10) {
          dSh = exitUsd / (execPx * (1.0 + STOCK_REBAL_FEE));
          coreShares += dSh;
        }

        ledger.push(
          buildClosedLedgerRow(
            tr,
            d,
            i,
            remDays,
            tRem,
            execPx,
            vxnEx,
            vixCl,
            vixR,
            rCur,
            qCur,
            qEx.bid,
            qEx.ask,
            putBid,
            qEx.src,
            exitRsn,
            dSh,
            multMorning,
          ),
        );
      }
      m7Active = stillM7;
      for (const [salvUsd, capSl, rSigD] of m7RollReps) {
        const nt = openM7Tranche(i, d, execPx, vxnEx, vixCl, rCur, qCur, capSl, rSigD, prevRowM, multMorning, salvUsd);
        if (nt !== null) m7Active.push(nt);
      }
    }

    // 1B. Pending T+1 Close Exits for Book B (0.20% Base VIX<=20 Gate)
    if (i > 0 && baseActive.length > 0) {
      const stillBase = [];
      let baseRollCash = 0.0;
      let wantBaseReopen = false;
      const prevRowB = evalBars[i - 1];
      const prevSigB = sigSeries[i - 1];
      const prevGateOk = Number(prevRowB.vix ?? 0) <= baseVixMax && Number(prevRowB.vix_ratio) < baseVrMax;
      for (const tr of baseActive) {
        if (!tr.pending_tp && !tr.pending_roll) {
          stillBase.push(tr);
          continue;
        }
        const remDays = Math.max(0, diffDays(tr.expMs, curMs));
        const tRem = remDays / 365.0;
        const qEx = lookupOpt(
          d,
          'put',
          tr.exp_date,
          tr.kp,
          tr.k_cents,
          execPx,
          remDays,
          rCur,
          qCur,
          vxnEx,
          tr.last_iv,
          OPT_SLIP,
          tr.iv_ratio_anchor,
        );
        const putBid = sellPx(qEx.bid, qEx.ask, qEx.mid, qEx.src, OPT_SLIP);
        const exitUsd = tr.hedged_shares * putBid;
        const exitRsn = String(tr.tp_reason || 'roll_75d');
        let dSh = 0.0;
        if (exitRsn === 'roll_75d') {
          if (prevGateOk && !wantBaseReopen) {
            if (!baseLockedPrevEod) {
              wantBaseReopen = true;
              baseRollCash += exitUsd;
            } else {
              if (curEp !== null) curEp.blocked_base_rolls += 1;
              if (exitUsd > 1e-10) {
                dSh = exitUsd / (execPx * (1.0 + STOCK_REBAL_FEE));
                coreShares += dSh;
              }
            }
          } else if (exitUsd > 1e-10) {
            dSh = exitUsd / (execPx * (1.0 + STOCK_REBAL_FEE));
            coreShares += dSh;
          }
        } else if (exitUsd > 1e-10) {
          dSh = exitUsd / (execPx * (1.0 + STOCK_REBAL_FEE));
          coreShares += dSh;
        }

        ledger.push(
          buildClosedLedgerRow(
            tr,
            d,
            i,
            remDays,
            tRem,
            execPx,
            vxnEx,
            vixCl,
            vixR,
            rCur,
            qCur,
            qEx.bid,
            qEx.ask,
            putBid,
            qEx.src,
            exitRsn,
            dSh,
            multMorning,
          ),
        );
      }
      baseActive = stillBase;
      if (wantBaseReopen) {
        const curNav = currentNavApprox(execPx) + baseRollCash;
        const bud = curNav * baseBudgetPct;
        const ntB = openBaseTranche(i, d, execPx, vxnEx, vixCl, rCur, qCur, prevSigB, prevRowB, multMorning, bud, baseRollCash);
        if (ntB !== null) baseActive.push(ntB);
      }
    }

    // 2A. Pending New Book M Entry at T+1 Close
    if (i > 0 && pendingSig !== null && m7Active.length < pendingSig.cap_slots) {
      const ntM = openM7Tranche(
        i,
        d,
        execPx,
        vxnEx,
        vixCl,
        rCur,
        qCur,
        pendingSig.cap_slots,
        sigSeries[i - 1],
        evalBars[i - 1],
        multMorning,
        0.0,
      );
      if (ntM !== null) m7Active.push(ntM);
    }
    pendingSig = null;

    // 2B. Pending New Book B Entry at T+1 Close
    if (i > 0 && pendingBaseOpen && baseActive.length === 0) {
      const curNav = currentNavApprox(execPx);
      const bud = curNav * baseBudgetPct;
      const ntB = openBaseTranche(
        i,
        d,
        execPx,
        vxnEx,
        vixCl,
        rCur,
        qCur,
        sigSeries[i - 1],
        evalBars[i - 1],
        multMorning,
        bud,
        0.0,
      );
      if (ntB !== null) baseActive.push(ntB);
    }
    pendingBaseOpen = false;

    // 2C. Engine 2 & Engine 3 T+1 Executions
    if (i > 0 && ccEnabled && pendingCc !== null && activeCc === null) {
      const rCc = pendingCc.r;
      const qCc = pendingCc.q;
      const vxnCc = vxnEx;
      const ccSh = Math.max(0.0, coreShares);
      if (ccSh > 1e-6) {
        const cCc = useReal ? selectRec(d, 'cc_25_d12') : null;
        let expDateCc;
        let expMsCc;
        let kcCc;
        let kCentsCc;
        let cBidCc;
        let ivCc;
        let srcCc;
        if (cCc !== null) {
          recSrc(cCc.source);
          expDateCc = cCc.exp;
          expMsCc = cCc.expMs;
          kcCc = cCc.strike;
          kCentsCc = cCc.k_cents;
          cBidCc = sellPx(cCc.bid, cCc.ask, cCc.mid, cCc.source, OPT_SLIP);
          ivCc = cCc.iv;
          srcCc = cCc.source;
        } else {
          const targetMs = curMs + ccDte * 86400000;
          const posCc = bisectLeftMs(msArr, targetMs);
          expDateCc = posCc < nDays ? dates[posCc] : new Date(targetMs).toISOString().slice(0, 10);
          expMsCc = posCc < nDays ? msArr[posCc] : targetMs;
          const tCc = Math.max(1, diffDays(expMsCc, curMs)) / 365.0;
          kcCc = Math.max(
            execPx * (1.0 + ccMinOtm),
            solveCallStrikeForDelta(execPx, tCc, rCc, qCc, vxnCc, coeffs, ccTargetDelta),
          );
          ivCc = evalSkewIv(execPx, kcCc, tCc, rCc, qCc, vxnCc, coeffs);
          const cmCc = bsmPrice(execPx, kcCc, tCc, rCc, qCc, ivCc, 'call');
          cBidCc = sellPx(cmCc * (1.0 - OPT_SLIP), cmCc * (1.0 + OPT_SLIP), cmCc, 'bsm_fallback', OPT_SLIP);
          kCentsCc = Math.round(kcCc * 100.0);
          srcCc = 'bsm_fallback';
          recSrc('bsm_fallback');
        }
        if (cBidCc >= 0.04) {
          const premUsd = ccSh * cBidCc;
          ccTid += 1;
          ccGrossPrem += premUsd;
          ccCash += premUsd;
          activeCc = {
            cc_id: ccTid,
            entry_date: d,
            entryMs: curMs,
            exp_date: expDateCc,
            expMs: expMsCc,
            entry_spot: execPx,
            entry_vxn: vxnCc,
            kc: kcCc,
            k_cents: kCentsCc,
            last_iv: ivCc,
            entry_source: srcCc,
            shares: ccSh,
            prem_usd: premUsd,
            pending_close: false,
            roll_count: 0,
          };
        }
      }
      pendingCc = null;
    }

    if (i > 0 && spEnabled && pendingWc !== null && assignedShares > 1e-6 && activeWc === null) {
      const pw = pendingWc;
      pendingWc = null;
      const vxnWc = vxnEx;
      let cWc = null;
      if (useReal) {
        if (wcMode === 'wc_reclaim_30d_d35') {
          cWc = selectRec(d, `wc_30_d35_${Math.round(assignedCostK * 100)}`);
        } else if (wcMode === 'wc_30d_c5s5') {
          const minKWc = Math.max(assignedCostK * 1.05, execPx * 1.05);
          cWc = selectRec(d, `wc_30_k_${Math.round(minKWc * 100)}`);
        } else {
          const minKWc = Math.max(assignedCostK, execPx * 1.02);
          cWc = selectRec(d, `wc_${spDte}_k_${Math.round(minKWc * 100)}`);
        }
      }
      let expDateWc;
      let expMsWc;
      let actDteWc;
      let kcWc;
      let kCentsWc;
      let cBidWc;
      let ivWc;
      let srcWc;
      if (cWc !== null) {
        recSrc(cWc.source);
        expDateWc = cWc.exp;
        expMsWc = cWc.expMs;
        actDteWc = Math.max(1, diffDays(expMsWc, curMs));
        kcWc = cWc.strike;
        kCentsWc = cWc.k_cents;
        cBidWc = sellPx(cWc.bid, cWc.ask, cWc.mid, cWc.source, OPT_SLIP_SP);
        ivWc = cWc.iv;
        srcWc = cWc.source;
      } else {
        if (wcMode === 'wc_reclaim_30d_d35' || wcMode === 'wc_30d_c5s5') {
          const targetWcMs = curMs + 30 * 86400000;
          const posWc = bisectLeftMs(msArr, targetWcMs);
          expDateWc = posWc < nDays ? dates[posWc] : new Date(targetWcMs).toISOString().slice(0, 10);
          expMsWc = posWc < nDays ? msArr[posWc] : targetWcMs;
          actDteWc = Math.max(1, diffDays(expMsWc, curMs));
          if (wcMode === 'wc_reclaim_30d_d35') {
            const kD35 = solveCallStrikeForDelta(execPx, actDteWc / 365.0, pw.r, pw.q, vxnWc, coeffs, 0.35);
            kcWc = Math.max(assignedCostK, kD35);
          } else {
            kcWc = Math.max(assignedCostK * 1.05, execPx * 1.05);
          }
        } else {
          [expDateWc, expMsWc, actDteWc] = pickExpiryStrictMax14(msArr, dates, i, spDte, 14);
          kcWc = Math.max(assignedCostK, execPx * 1.02);
        }
        [cBidWc] = optExecPriceSp(execPx, kcWc, actDteWc / 365.0, pw.r, pw.q, vxnWc, coeffs, 'call', 'sell', OPT_SLIP_SP);
        kCentsWc = Math.round(kcWc * 100.0);
        ivWc = null;
        srcWc = 'bsm_fallback';
        recSrc('bsm_fallback');
      }
      if (cBidWc >= MIN_OPT_BID) {
        const premWc = assignedShares * cBidWc;
        spCommTotal += assignedShares * OPT_COMM_PER_SH;
        spCash += premWc;
        wcTid += 1;
        activeWc = {
          wc_id: wcTid,
          cycle_id: curCycleId,
          signal_date: pw.signal_date,
          entry_date: d,
          entryMs: curMs,
          exp_date: expDateWc,
          expMs: expMsWc,
          dte: actDteWc,
          entry_spot: execPx,
          kc: kcWc,
          k_cents: kCentsWc,
          last_iv: ivWc,
          entry_source: srcWc,
          assigned_cost_k: assignedCostK,
          shares: assignedShares,
          prem_usd: premWc,
        };
      }
    }

    if (i > 0 && spEnabled && pendingSp !== null && activeSp === null && assignedShares <= 1e-6) {
      const ps = pendingSp;
      pendingSp = null;
      const vxnSp = vxnEx;
      const cSp = useReal ? selectRec(d, `sp_${spDte}_5`) : null;
      let expDateSp;
      let expMsSp;
      let actDteSp;
      let kpSp;
      let kCentsSp;
      let pBidSp;
      let ivSp;
      let srcSp;
      if (cSp !== null) {
        recSrc(cSp.source);
        expDateSp = cSp.exp;
        expMsSp = cSp.expMs;
        actDteSp = Math.max(1, diffDays(expMsSp, curMs));
        kpSp = cSp.strike;
        kCentsSp = cSp.k_cents;
        pBidSp = sellPx(cSp.bid, cSp.ask, cSp.mid, cSp.source, OPT_SLIP_SP);
        ivSp = cSp.iv;
        srcSp = cSp.source;
      } else {
        [expDateSp, expMsSp, actDteSp] = pickExpiryStrictMax14(msArr, dates, i, spDte, 14);
        kpSp = execPx * (1.0 - spOtmPct);
        [pBidSp] = optExecPriceSp(execPx, kpSp, actDteSp / 365.0, ps.r, ps.q, vxnSp, coeffs, 'put', 'sell', OPT_SLIP_SP);
        kCentsSp = Math.round(kpSp * 100.0);
        ivSp = null;
        srcSp = 'bsm_fallback';
        recSrc('bsm_fallback');
      }
      if (pBidSp >= MIN_OPT_BID) {
        const navOpen = estimateNavExec(execPx, vxnSp, ps.r, ps.q, curMs, d);
        const putSh = (spMaxLev * navOpen) / kpSp;
        const premSp = putSh * pBidSp;
        spCommTotal += putSh * OPT_COMM_PER_SH;
        spCash += premSp;
        spTid += 1;
        curCycleId = spTid;
        curCycleStartMs = curMs;
        activeSp = {
          sp_id: spTid,
          cycle_id: curCycleId,
          signal_date: ps.signal_date,
          entry_date: d,
          entryMs: curMs,
          exp_date: expDateSp,
          expMs: expMsSp,
          dte: actDteSp,
          entry_spot: execPx,
          kp: kpSp,
          k_cents: kCentsSp,
          last_iv: ivSp,
          entry_source: srcSp,
          shares: putSh,
          prem_usd: premSp,
          entry_vix_ratio: ps.vix_ratio,
        };
      }
    }

    // 3. Dividends DRIP
    if (div > 0.0 && coreShares > 0.0) {
      coreShares += (coreShares * div) / (cl * (1.0 + STOCK_REBAL_FEE));
      if (assignedShares > 0.0) spCash += assignedShares * div;
    }

    const wasActiveToday = m7Active.length > 0 || baseActive.length > 0;
    const activeSlotsToday = m7Active.length;

    // 4. EOD Expiries (safety fallback for 90d_hold comparison)
    for (const bookRef of [m7Active, baseActive]) {
      const stillExp = [];
      for (const tr of bookRef) {
        if (isExp(i, tr.expMs)) {
          const putIntr = Math.max(0.0, tr.kp - cl);
          const settleUsd = tr.hedged_shares * putIntr;
          let dSh = 0.0;
          if (settleUsd > 0.0) {
            dSh = settleUsd / (cl * (1.0 + STOCK_REBAL_FEE));
            coreShares += dSh;
          }
          const enSrc = String(tr.entry_source || 'bsm_fallback');
          const exSrcExp = useReal && opraMaxD && d <= opraMaxD ? 'real_opra' : enSrc;
          const trTgtD = Number(tr.target_dte || targetDte);
          ledger.push(
            buildClosedLedgerRow(
              tr,
              d,
              i,
              0,
              0.0,
              cl,
              vxnCl,
              vixCl,
              vixR,
              rCur,
              qCur,
              putIntr,
              putIntr,
              putIntr,
              exSrcExp,
              `expiry_${trTgtD}dte`,
              dSh,
              multEod,
            ),
          );
        } else {
          stillExp.push(tr);
        }
      }
      bookRef.length = 0;
      bookRef.push(...stillExp);
    }

    // 5. Daily EOD MTM & Near-ITM TP / Hard-Roll Check
    const gateOkToday = vixCl <= baseVixMax && vixR < baseVrMax;
    if (gateOkToday) baseGateOpenDays += 1;
    let anyTpTriggeredToday = false;
    const tpTriggersToday = [];

    let m7MtmTotal = 0.0;
    for (const tr of m7Active) {
      const remDays = Math.max(1, diffDays(tr.expMs, curMs));
      const qM = lookupOpt(
        d,
        'put',
        tr.exp_date,
        tr.kp,
        tr.k_cents,
        cl,
        remDays,
        rCur,
        qCur,
        vxnCl,
        tr.last_iv,
        OPT_SLIP,
        tr.iv_ratio_anchor,
      );
      if (Number.isFinite(qM.iv) && qM.iv > 0.05) {
        tr.last_iv = qM.iv;
        if (String(qM.src).startsWith('real_opra') && qM.iv <= 3.0) {
          const bsmIvM = evalSkewIv(cl, tr.kp, Math.max(remDays / 365.0, 1.0 / 365.0), rCur, qCur, vxnCl, coeffs);
          tr.iv_ratio_anchor = clip(qM.iv / Math.max(bsmIvM, 0.05), 0.5, 2.0);
        }
      }
      const putMid = qM.mid;
      const valUsd = tr.hedged_shares * putMid;
      tr.last_mtm_usd = valUsd;
      m7MtmTotal += valUsd;
      const trRollThrCur = Number(tr.roll_dte_thr || 0);
      if (!tr.pending_tp && !tr.pending_roll) {
        const nearItmOk = (vixR >= vixRatioTp && cl <= tr.kp * nearItmMult) || vixCl >= extremeVixTp;
        if (nearItmOk) {
          tr.pending_tp = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = requireItmTp ? 'vix_inv_1.10_itm_tp' : 'tp_near_itm';
          anyTpTriggeredToday = true;
          tpTriggersToday.push(`m7:${tr.tp_reason}`);
        } else if (remDays <= putMultMaxDteM7 && tr.entry_put_ask > 1e-6 && putMid >= tr.entry_put_ask * putMultTp) {
          tr.pending_tp = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = 'tp_5x_late';
          anyTpTriggeredToday = true;
          tpTriggersToday.push('m7:tp_5x_late');
        } else if (trRollThrCur > 0 && remDays <= trRollThrCur) {
          tr.pending_roll = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = `roll_${trRollThrCur}d`;
        }
      }
    }

    let baseMtmTotal = 0.0;
    for (const tr of baseActive) {
      const remDays = Math.max(1, diffDays(tr.expMs, curMs));
      const qB = lookupOpt(
        d,
        'put',
        tr.exp_date,
        tr.kp,
        tr.k_cents,
        cl,
        remDays,
        rCur,
        qCur,
        vxnCl,
        tr.last_iv,
        OPT_SLIP,
        tr.iv_ratio_anchor,
      );
      if (Number.isFinite(qB.iv) && qB.iv > 0.05) {
        tr.last_iv = qB.iv;
        if (String(qB.src).startsWith('real_opra') && qB.iv <= 3.0) {
          const bsmIvB = evalSkewIv(cl, tr.kp, Math.max(remDays / 365.0, 1.0 / 365.0), rCur, qCur, vxnCl, coeffs);
          tr.iv_ratio_anchor = clip(qB.iv / Math.max(bsmIvB, 0.05), 0.5, 2.0);
        }
      }
      const putMidB = qB.mid;
      const valUsdB = tr.hedged_shares * putMidB;
      tr.last_mtm_usd = valUsdB;
      baseMtmTotal += valUsdB;
      if (!tr.pending_tp && !tr.pending_roll) {
        const nearItmOkB = (vixR >= vixRatioTp && cl <= tr.kp * nearItmMult) || vixCl >= extremeVixTp;
        if (nearItmOkB) {
          tr.pending_tp = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = requireItmTp ? 'base_vix_inv_1.10_itm_tp' : 'base_tp_near_itm';
          anyTpTriggeredToday = true;
          tpTriggersToday.push(`base:${tr.tp_reason}`);
        } else if (remDays <= putMultMaxDteBase && tr.entry_put_ask > 1e-6 && putMidB >= tr.entry_put_ask * putMultTp) {
          tr.pending_tp = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = 'base_tp_5x_late';
          anyTpTriggeredToday = true;
          tpTriggersToday.push('base:tp_5x_late');
        } else if (remDays <= baseRollDte) {
          tr.pending_roll = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = gateOkToday ? 'roll_75d' : 'salvage_vix_expensive';
        }
      }
    }

    const putMtm = m7MtmTotal + baseMtmTotal;
    if (baseActive.length > 0) baseDaysHedged += 1;

    // 5b. Engine 2 & Engine 3 EOD MTM/Expiries
    let ccMtm = 0.0;
    if (activeCc !== null) {
      if (isExp(i, activeCc.expMs)) {
        const payCc = Math.max(0.0, cl - activeCc.kc);
        const lossCc = activeCc.shares * payCc;
        if (payCc > 0.0) {
          ccAssignedCnt += 1;
          ccGrossLoss += lossCc;
          if (ccCash >= lossCc) ccCash -= lossCc;
          else {
            coreShares -= (lossCc - ccCash) / (cl * (1.0 - STOCK_REBAL_FEE));
            ccCash = 0.0;
          }
        }
        const ccEnSrc = activeCc.entry_source || 'bsm_fallback';
        ccLedger.push({
          cc_id: activeCc.cc_id,
          entry_date: activeCc.entry_date,
          exit_date: d,
          entry_spot: r2(activeCc.entry_spot),
          kc: r2(activeCc.kc),
          exit_spot: r2(cl),
          entry_vxn: r2(activeCc.entry_vxn),
          shares: r2(activeCc.shares),
          prem_usd: r2(activeCc.prem_usd),
          loss_usd: r2(lossCc),
          net_pnl_usd: r2(activeCc.prem_usd - lossCc),
          exit_reason: payCc > 0.0 ? 'assigned_breach' : 'expired_worthless',
          roll_gen: Number(activeCc.roll_count || 0),
          pricing_source: classifyTradeSource(ccEnSrc, ccEnSrc),
        });
        activeCc = null;
      } else {
        const remCc = Math.max(1, diffDays(activeCc.expMs, curMs));
        const qCcM = lookupOpt(d, 'call', activeCc.exp_date, activeCc.kc, activeCc.k_cents, cl, remCc, rCur, qCur, vxnCl, activeCc.last_iv, OPT_SLIP);
        if (Number.isFinite(qCcM.iv) && qCcM.iv >= 0.03 && qCcM.iv <= 2.5) activeCc.last_iv = qCcM.iv;
        ccMtm = -activeCc.shares * qCcM.mid;
        const curDelta = qCcM.delta;
        if (remCc >= 3 && vixR >= 1.1) {
          activeCc.pending_close = true;
          activeCc.close_reason = 'panic_close_uncap';
        } else if (ccStopDelta !== null && curDelta >= ccStopDelta) {
          activeCc.pending_close = true;
          activeCc.close_reason =
            ccRollMode === 'fresh_30d'
              ? 'delta_roll_up'
              : ccRollMode === 'credit_45d'
                ? 'delta_credit_roll'
                : 'delta_stop';
        }
      }
    }

    let spMtm = 0.0;
    if (activeSp !== null) {
      daysShortPutOpen += 1;
      if (isExp(i, activeSp.expMs)) {
        const spEnSrc = activeSp.entry_source || 'bsm_fallback';
        if (cl >= activeSp.kp) {
          spClosedLedger.push({
            leg_id: `SP-${activeSp.sp_id}`,
            sp_id: activeSp.sp_id,
            cycle_id: activeSp.cycle_id,
            leg_type: 'short_put',
            is_open_live: false,
            pricing_source: classifyTradeSource(spEnSrc, spEnSrc),
            signal_date: activeSp.signal_date,
            entry_date: activeSp.entry_date,
            exit_date: d,
            dte: activeSp.dte,
            entry_spot: r2(activeSp.entry_spot),
            strike: r2(activeSp.kp),
            kp: r2(activeSp.kp),
            exit_spot: r2(cl),
            shares: r2(activeSp.shares),
            prem_usd: r2(activeSp.prem_usd),
            exit_cost_usd: 0.0,
            net_pnl_usd: r2(activeSp.prem_usd),
            exit_reason: 'expired_otm',
          });
          activeSp = null;
          if (assignedShares <= 1e-6) {
            curCycleStartMs = null;
            sweepSpCash(cl);
          }
        } else {
          assignedShares = activeSp.shares;
          assignedCostK = activeSp.kp;
          spCash -= assignedShares * activeSp.kp;
          spAssignCount += 1;
          const intrCost = activeSp.shares * (activeSp.kp - cl);
          spClosedLedger.push({
            leg_id: `SP-${activeSp.sp_id}`,
            sp_id: activeSp.sp_id,
            cycle_id: activeSp.cycle_id,
            leg_type: 'short_put',
            is_open_live: false,
            pricing_source: classifyTradeSource(spEnSrc, spEnSrc),
            signal_date: activeSp.signal_date,
            entry_date: activeSp.entry_date,
            exit_date: d,
            dte: activeSp.dte,
            entry_spot: r2(activeSp.entry_spot),
            strike: r2(activeSp.kp),
            kp: r2(activeSp.kp),
            exit_spot: r2(cl),
            shares: r2(activeSp.shares),
            prem_usd: r2(activeSp.prem_usd),
            exit_cost_usd: r2(intrCost),
            net_pnl_usd: r2(activeSp.prem_usd - intrCost),
            exit_reason: 'assigned_wheel',
          });
          activeSp = null;
        }
      } else {
        const remSp = Math.max(1, diffDays(activeSp.expMs, curMs));
        const qSpM = lookupOpt(d, 'put', activeSp.exp_date, activeSp.kp, activeSp.k_cents, cl, remSp, rCur, qCur, vxnCl, activeSp.last_iv, OPT_SLIP_SP);
        if (Number.isFinite(qSpM.iv) && qSpM.iv >= 0.03 && qSpM.iv <= 2.5) activeSp.last_iv = qSpM.iv;
        spMtm = -activeSp.shares * qSpM.mid;
      }
    }

    let wcMtm = 0.0;
    if (activeWc !== null) {
      if (isExp(i, activeWc.expMs)) {
        const wcEnSrc = activeWc.entry_source || 'bsm_fallback';
        if (cl > activeWc.kc) {
          spCash += assignedShares * activeWc.kc;
          const stockGain = activeWc.shares * (activeWc.kc - activeWc.assigned_cost_k);
          wcClosedLedger.push({
            leg_id: `WC-${activeWc.wc_id}`,
            wc_id: activeWc.wc_id,
            cycle_id: activeWc.cycle_id,
            leg_type: 'wheel_call',
            is_open_live: false,
            pricing_source: classifyTradeSource(wcEnSrc, wcEnSrc),
            signal_date: activeWc.signal_date,
            entry_date: activeWc.entry_date,
            exit_date: d,
            dte: activeWc.dte,
            entry_spot: r2(activeWc.entry_spot),
            strike: r2(activeWc.kc),
            kc: r2(activeWc.kc),
            assigned_cost_k: r2(activeWc.assigned_cost_k),
            exit_spot: r2(cl),
            shares: r2(activeWc.shares),
            prem_usd: r2(activeWc.prem_usd),
            exit_cost_usd: 0.0,
            stock_gain_usd: r2(stockGain),
            net_pnl_usd: r2(activeWc.prem_usd + stockGain),
            exit_reason: 'called_away',
          });
          assignedShares = 0.0;
          assignedCostK = 0.0;
          activeWc = null;
          if (curCycleStartMs !== null) {
            maxWheelCycleDays = Math.max(maxWheelCycleDays, diffDays(curMs, curCycleStartMs));
            curCycleStartMs = null;
          }
          sweepSpCash(cl);
        } else {
          wcClosedLedger.push({
            leg_id: `WC-${activeWc.wc_id}`,
            wc_id: activeWc.wc_id,
            cycle_id: activeWc.cycle_id,
            leg_type: 'wheel_call',
            is_open_live: false,
            pricing_source: classifyTradeSource(wcEnSrc, wcEnSrc),
            signal_date: activeWc.signal_date,
            entry_date: activeWc.entry_date,
            exit_date: d,
            dte: activeWc.dte,
            entry_spot: r2(activeWc.entry_spot),
            strike: r2(activeWc.kc),
            kc: r2(activeWc.kc),
            assigned_cost_k: r2(activeWc.assigned_cost_k),
            exit_spot: r2(cl),
            shares: r2(activeWc.shares),
            prem_usd: r2(activeWc.prem_usd),
            exit_cost_usd: 0.0,
            stock_gain_usd: 0.0,
            net_pnl_usd: r2(activeWc.prem_usd),
            exit_reason: 'expired_otm',
          });
          activeWc = null;
        }
      } else {
        const remWc = Math.max(1, diffDays(activeWc.expMs, curMs));
        const qWcM = lookupOpt(d, 'call', activeWc.exp_date, activeWc.kc, activeWc.k_cents, cl, remWc, rCur, qCur, vxnCl, activeWc.last_iv, OPT_SLIP_SP);
        if (Number.isFinite(qWcM.iv) && qWcM.iv >= 0.03 && qWcM.iv <= 2.5) activeWc.last_iv = qWcM.iv;
        wcMtm = -activeWc.shares * qWcM.mid;
      }
    }

    const nav = (coreShares + assignedShares) * cl + ccCash + spCash + putMtm + ccMtm + spMtm + wcMtm;
    if (spEnabled) {
      const grossStockLev = ((coreShares + assignedShares) * cl) / Math.max(nav, 1.0);
      const putNotional = activeSp !== null ? activeSp.shares * activeSp.kp : 0.0;
      const notionalLev = ((coreShares + assignedShares) * cl + putNotional) / Math.max(nav, 1.0);
      if (assignedShares > 1e-6) daysLevered += 1;
      maxGrossStockLev = Math.max(maxGrossStockLev, grossStockLev);
      maxNotionalLev = Math.max(maxNotionalLev, notionalLev);
    }

    navList[i] = nav;
    equivShList[i] = nav / cl;
    anyActiveList[i] = wasActiveToday || m7Active.length > 0 || baseActive.length > 0 ? 1 : 0;
    activeSlotsList[i] = Math.max(activeSlotsToday, m7Active.length);

    // 5.5 Strictly Causal EOD Post-TP Lockout State Machine (VIX/VIX3M < 1.00 x 5 consecutive trading days)
    if (lockoutDays > 0) {
      if (anyTpTriggeredToday) {
        lastTpDate = d;
        if (!postTpLockout) {
          curEp = {
            start_signal_date: d,
            start_idx: i,
            triggers: [...tpTriggersToday],
            start_vix: r2(vixCl),
            start_vr: r3(vixR),
            start_spot: r2(cl),
            unlock_eod_date: null,
            trading_days_locked: 0,
            re_inversions: 0,
            blocked_base_entries: 0,
            blocked_m7_entries: 0,
            blocked_base_rolls: 0,
            blocked_m7_rolls: 0,
          };
          lockoutEpisodes.push(curEp);
        } else if (curEp !== null) {
          curEp.triggers.push(...tpTriggersToday);
        }
        postTpLockout = true;
        nonInvertedStreak = 0;
        lockoutDaysTotal += 1;
        if (curEp !== null) curEp.trading_days_locked += 1;
      } else if (postTpLockout) {
        if (vixR < lockoutInvThresh) {
          nonInvertedStreak += 1;
          if (nonInvertedStreak >= lockoutDays) {
            postTpLockout = false;
            nonInvertedStreak = 0;
            lastUnlockDate = d;
            if (curEp !== null) {
              curEp.unlock_eod_date = d;
              curEp.unlock_vix = r2(vixCl);
              curEp.unlock_vr = r3(vixR);
              curEp.unlock_spot = r2(cl);
              curEp.cal_days_locked = diffDays(curMs, msArr[curEp.start_idx]);
              curEp = null;
            }
          } else {
            lockoutDaysTotal += 1;
            if (curEp !== null) curEp.trading_days_locked += 1;
          }
        } else {
          if (nonInvertedStreak > 0 && curEp !== null) curEp.re_inversions += 1;
          nonInvertedStreak = 0;
          lockoutDaysTotal += 1;
          if (curEp !== null) curEp.trading_days_locked += 1;
        }
      }
    }

    const m7LockedToday = postTpLockout;
    const baseLockedToday = postTpLockout;
    m7LockedPrevEod = m7LockedToday;
    baseLockedPrevEod = baseLockedToday;

    // 6A. Book M Tactical EOD Entry Signal -> T+1 Close
    const capSlots = Math.min(maxSlots, slotsForSig(sigD));
    const effM7 = m7Active.filter(t => !(t.pending_tp || t.pending_roll));
    if (capSlots > effM7.length && vxnCl <= 27.0 && vixR < 1.02) {
      const reqGap = capSlots === 3 ? escalateMinDays : stepCalDays;
      const lastMsM = effM7.length ? Math.max(...effM7.map(t => t.entryMs)) : null;
      if (lastMsM === null || diffDays(curMs, lastMsM) >= reqGap) {
        if (!m7LockedToday) {
          const { mods, codeStr, trigEn, trigZh } = formatM7TriggerLabels(sigD, maxSlots, isCore3);
          const [cProbS, p1S, p2S, p3S] = probTuple(sigD);
          pendingSig = {
            signal_date: d,
            is_cta: Boolean(sigD.M4),
            vxn: vxnCl,
            close: cl,
            vix_ratio: vixR,
            r: rCur,
            q: qCur,
            cap_slots: capSlots,
            tier: capSlots,
            sig_score: Number(row.score),
            sig_ad_below50:
              row.ad_line !== undefined && row.ad_sma50 !== undefined
                ? Number(row.ad_line) < Number(row.ad_sma50)
                : Boolean(row.ad_below50),
            crisis_prob: cProbS,
            p1: p1S,
            p2: p2S,
            p3: p3S,
            triggered_modules: mods,
            trigger_code: codeStr,
            trigger_en: trigEn,
            trigger_zh: trigZh,
          };
        } else if (curEp !== null) {
          curEp.blocked_m7_entries += 1;
        }
      }
    }

    // 6B. Book B Floor EOD Entry Signal (VIX <= 20 & VIX/3M < 1.02) -> T+1 Close
    if (baseEnabled && gateOkToday) {
      const effBase = baseActive.filter(t => !(t.pending_tp || t.pending_roll));
      if (effBase.length === 0) {
        if (!baseLockedToday) {
          pendingBaseOpen = true;
        } else if (curEp !== null) {
          curEp.blocked_base_entries += 1;
        }
      }
    }

    if (ccEnabled && i < nDays - 1) {
      if (activeCc === null && ddCur >= -ccAthLimit && vxnCl >= ccMinVxn) {
        pendingCc = { close: cl, vxn: vxnCl, r: rCur, q: qCur };
      }
      if (ccCash > 1.0 && vixR >= 1.1) pendingCcDeploy = true;
    }

    const wcReclaimReady = wcMode === 'wc_reclaim_30d_d35' ? cl >= assignedCostK : true;
    if (spEnabled && assignedShares > 1e-6 && activeWc === null && wcReclaimReady) {
      pendingWc = { signal_date: d, close: cl, vxn: vxnCl, vix_ratio: vixR, r: rCur, q: qCur };
    }
    if (spEnabled && activeSp === null && assignedShares <= 1e-6) {
      let trigSp = vixR >= spVixThr;
      if (trigSp && spRequireVixFalling) trigSp = Boolean(row.vix_falling);
      if (trigSp) {
        pendingSp = { signal_date: d, close: cl, vxn: vxnCl, vix_ratio: vixR, r: rCur, q: qCur };
      }
    }
  }

  ledger.sort((a, b) =>
    a.entry_date !== b.entry_date ? a.entry_date.localeCompare(b.entry_date) : a.tranche_id - b.tranche_id,
  );
  const closedTradesCount = ledger.length;
  const lastR = evalBars[nDays - 1];
  const lastD = dates[nDays - 1];
  const lastMs = msArr[nDays - 1];
  const lastCl = Number(lastR.close);
  const lastVxn = Number(lastR.vxn);
  const lastVix = Number(lastR.vix ?? 0);
  const lastVr = Number(lastR.vix_ratio);
  const lastRf = Number(lastR.r);
  const lastQ = Number(lastR.div_yield);
  const multLast = (finalBhSh / bhM7.postSh[nDays - 1]) * finalCl;

  const serializeOpenTranche = tr => {
    const remD = Math.max(1, diffDays(tr.expMs, lastMs));
    const tRem = remD / 365.0;
    const qLast = lookupOpt(
      lastD,
      'put',
      tr.exp_date,
      tr.kp,
      tr.k_cents,
      lastCl,
      remD,
      lastRf,
      lastQ,
      lastVxn,
      tr.last_iv,
      OPT_SLIP,
      tr.iv_ratio_anchor,
    );
    const pm = qLast.mid;
    const hs = tr.hedged_shares;
    const mtmCashUsd = hs * pm;
    const mtmNetPnl = mtmCashUsd - tr.entry_cost_usd;
    const roiMult = tr.entry_cost_usd > 1e-6 ? mtmCashUsd / tr.entry_cost_usd : 0.0;
    const estDSh = Math.abs(mtmCashUsd) > 1e-8 ? mtmCashUsd / (lastCl * (1.0 + STOCK_REBAL_FEE)) : 0.0;
    const estShAdded = tr.entry_shares_sold + estDSh;
    const actualNetSh = pm - tr.entry_put_ask;
    const conv = decomposeNakedPutConvexity(
      tr.entry_spot,
      lastCl,
      tr.kp,
      tr.T_entry,
      tRem,
      tr.entry_r,
      lastRf,
      tr.entry_q,
      lastQ,
      tr.entry_vxn,
      lastVxn,
      coeffs,
      actualNetSh,
    );
    const trTgtD = Number(tr.target_dte || targetDte);
    const trRollD = Number(tr.roll_dte_thr || 0);
    const isArmed = Boolean(tr.pending_tp || tr.pending_roll);
    const armedReason = String(tr.tp_reason || '');
    const liveReason =
      isArmed && (armedReason.startsWith('roll_') || armedReason.startsWith('salvage_'))
        ? `live_${armedReason}_armed_next_open`
        : isArmed
          ? 'live_tp_armed_next_open'
          : 'open_live_mtm';
    const netPnlRounded = r2(mtmNetPnl);
    const dUsd = r2(conv.dvDelta * hs);
    const gUsd = r2(conv.dvGamma * hs);
    const vUsd = r2(conv.dvVega * hs);
    const enSrcL = tr.entry_source || 'bsm_fallback';
    const psL = classifyTradeSource(enSrcL, qLast.src);
    const qTagLive = classifyQuoteSourceTag(enSrcL, qLast.src, tr.entry_date, lastD, opraMaxD || '2025-12-15');
    const occSym = String(tr.occ_symbol || formatOccSymbol('QQQ', tr.exp_date, 'put', tr.kp));
    const isBaseB = tr.book === 'base';
    const ledRow = {
      tranche_id: tr.tranche_id,
      strategy_id: strategyId,
      book: tr.book,
      book_label_en: isBaseB ? 'Book B · 0.20% Base' : 'Book M · 1.25% M7G',
      book_label_zh: isBaseB ? 'B账本 · 0.20%常态基底' : 'M账本 · 1.25%战术M7G',
      budget_pct_nav: isBaseB ? 0.2 : 1.25,
      entry_pct_nav: tr.entry_pct_nav,
      nav_at_entry: r2(tr.nav_at_entry),
      slot_num: tr.slot_num,
      tier: tr.tier,
      max_slots: maxSlots,
      tranche_type: 'naked_put',
      put_otm_pct: Number(tr.put_otm_pct || otmPctInt),
      tp_mode: tpCode,
      roll_mode: effRollMode,
      target_dte: trTgtD,
      roll_dte: trRollD,
      is_cta: Boolean(tr.is_cta),
      quoteSource: qTagLive,
      quote_source: qTagLive,
      occSymbol: occSym,
      occ_symbol: occSym,
      exp: tr.exp_date,
      strike: r2(tr.kp),
      near_itm_strike_105: r2(tr.kp * nearItmMult),
      entryBid: r3(Number(tr.entry_bid_raw ?? tr.entry_put_ask)),
      entryAsk: r3(Number(tr.entry_ask_raw ?? tr.entry_put_ask)),
      exitBid: r3(qLast.bid),
      exitAsk: r3(qLast.ask),
      pricing_source: psL,
      entry_source: enSrcL,
      exit_source: qLast.src,
      signal_date: tr.signal_date,
      entry_date: tr.entry_date,
      planned_exp_date: tr.exp_date,
      exit_date: null,
      mtm_date: lastD,
      is_open_live: true,
      pending_tp: isArmed,
      pending_tp_reason: armedReason,
      actual_days_held: diffDays(lastMs, tr.entryMs),
      rem_dte_at_exit: remD,
      exit_reason: liveReason,
      sig_score: tr.sig_score,
      sig_ad_below50: tr.sig_ad_below50,
      crisis_prob: tr.crisis_prob,
      p1: tr.p1,
      p2: tr.p2,
      p3: tr.p3,
      triggered_modules: tr.triggered_modules,
      trigger_code: tr.trigger_code,
      trigger_en: tr.trigger_en,
      trigger_zh: tr.trigger_zh,
      entry_spot: r2(tr.entry_spot),
      entry_vxn: r2(tr.entry_vxn),
      entry_vix: r2(Number(tr.entry_vix || 0)),
      entry_vix_ratio: r3(tr.entry_vix_ratio),
      kp: r2(tr.kp),
      kc: null,
      call_cap_pct: null,
      hedged_shares: r2(hs),
      contracts_est: r2(hs / 100.0),
      slot_coverage: r4(tr.hedged_ratio),
      entry_put_ask_sh: r4(tr.entry_put_ask),
      tp_target_5x_sh: r4(5.0 * tr.entry_put_ask),
      entry_cost_usd: r2(tr.entry_cost_usd),
      entry_shares_sold: r4(tr.entry_shares_sold),
      exit_spot: r2(lastCl),
      exit_vxn: r2(lastVxn),
      exit_vix: r2(lastVix),
      exit_vix_ratio: r3(lastVr),
      underlying_ret_pct: r2((lastCl / tr.entry_spot - 1.0) * 100.0),
      put_exit_val_sh: r4(pm),
      call_exit_cost_sh: 0.0,
      exit_net_cash_usd: r2(mtmCashUsd),
      net_pnl_usd: netPnlRounded,
      roi_mult: r2(roiMult),
      exit_shares_delta: r2(estDSh),
      shares_added: r2(estShAdded),
      delta0: r4(conv.delta0),
      delta_usd: dUsd,
      gamma_usd: gUsd,
      vega_usd: vUsd,
      theta_slip_usd: r2(netPnlRounded - (dUsd + gUsd + vUsd)),
      convexity_mult: conv.convMult !== null ? r2(conv.convMult) : null,
      comp_entry_cost_usd: r2(tr.comp_entry_cost_usd),
      comp_put_gain_usd: r2(((hs * pm) / lastCl) * multLast),
      comp_call_drag_usd: 0.0,
    };
    const serRow = {
      tranche_id: tr.tranche_id,
      book: tr.book,
      book_label_en: isBaseB ? 'Book B · 0.20% Base' : 'Book M · 1.25% M7G',
      book_label_zh: isBaseB ? 'B账本 · 0.20%常态基底' : 'M账本 · 1.25%战术M7G',
      budget_pct_nav: isBaseB ? 0.2 : 1.25,
      slot_num: tr.slot_num,
      tier: tr.tier,
      tranche_type: 'naked_put',
      put_otm_pct: Number(tr.put_otm_pct || otmPctInt),
      roll_mode: effRollMode,
      target_dte: trTgtD,
      roll_dte: trRollD,
      is_cta: Boolean(tr.is_cta),
      occSymbol: occSym,
      quoteSource: qTagLive,
      days_to_roll: trRollD > 0 ? Math.max(0, remD - trRollD) : null,
      days_to_roll50: trRollD > 0 ? Math.max(0, remD - trRollD) : null,
      pricing_source: psL,
      entry_date: tr.entry_date,
      exp_date: tr.exp_date,
      rem_dte: remD,
      entry_spot: r2(tr.entry_spot),
      mtm_spot: r2(lastCl),
      mtm_date: lastD,
      kp: r2(tr.kp),
      near_itm_strike_105: r2(tr.kp * nearItmMult),
      kc: null,
      hedged_shares: r2(hs),
      contracts_est: r2(hs / 100.0),
      entry_put_ask_sh: r4(tr.entry_put_ask),
      tp_target_5x_sh: r4(5.0 * tr.entry_put_ask),
      entry_cost_usd: r2(tr.entry_cost_usd),
      mtm_put_val_sh: r4(pm),
      mtm_call_val_sh: 0.0,
      mtm_pnl_usd: netPnlRounded,
      roi_mult: r2(roiMult),
      est_shares_added: r2(estShAdded),
      pending_tp: isArmed,
      tp_reason: armedReason,
      tp_trigger_ratio: r3(Number(tr.tp_trigger_ratio || lastVr)),
      trigger_code: tr.trigger_code,
      crisis_prob: tr.crisis_prob,
    };
    return [ledRow, serRow];
  };

  const baseActiveSerialized = [];
  for (const trB of baseActive) {
    const [lrB, srB] = serializeOpenTranche(trB);
    ledger.push(lrB);
    baseActiveSerialized.push(srB);
  }
  const activeTranchesSerialized = [];
  for (const trM of m7Active) {
    const [lrM, srM] = serializeOpenTranche(trM);
    ledger.push(lrM);
    activeTranchesSerialized.push(srM);
  }

  const yrs = Math.max(diffDays(lastMs, msArr[0]) / 365.25, 1 / 252);
  const cagr = Math.pow(navList[nDays - 1] / navList[0], 1.0 / yrs) - 1.0;
  const rets = [];
  const exRets = [];
  for (let j = 1; j < nDays; j += 1) {
    const rDaily = navList[j] / navList[j - 1] - 1.0;
    rets.push(rDaily);
    exRets.push(rDaily - Number(evalBars[j].r || 0) / 252.0);
  }
  const meanR = rets.length ? rets.reduce((a, b) => a + b, 0) / rets.length : 0.0;
  let sq = 0.0;
  for (let j = 0; j < rets.length; j += 1) sq += (rets[j] - meanR) ** 2;
  const vol = Math.sqrt(sq / Math.max(1, rets.length - 1)) * Math.sqrt(252.0);
  const meanEx = exRets.length ? exRets.reduce((a, b) => a + b, 0) / exRets.length : 0.0;
  let sqEx = 0.0;
  for (let j = 0; j < exRets.length; j += 1) sqEx += (exRets[j] - meanEx) ** 2;
  const stdEx = Math.sqrt(sqEx / Math.max(1, exRets.length - 1));
  const sharpe = stdEx > 1e-12 ? (meanEx / stdEx) * Math.sqrt(252.0) : 0.0;
  const downEx = exRets.filter(x => x < 0);
  let sortino = 0.0;
  if (downEx.length > 2) {
    const muNeg = downEx.reduce((a, b) => a + b, 0) / downEx.length;
    const sqNeg = downEx.reduce((a, x) => a + (x - muNeg) ** 2, 0);
    const downStd = Math.sqrt(sqNeg / (downEx.length - 1));
    if (downStd > 1e-12) sortino = (meanEx / downStd) * Math.sqrt(252.0);
  }

  let peak = navList[0];
  let mdd = 0.0;
  for (let j = 0; j < nDays; j += 1) {
    if (navList[j] > peak) peak = navList[j];
    const dd = navList[j] / peak - 1.0;
    if (dd < mdd) mdd = dd;
  }
  const calmar = mdd < 0 ? cagr / Math.abs(mdd) : 0.0;

  const closedRows = ledger.filter(x => !x.is_open_live);
  const closedBase = closedRows.filter(x => x.book === 'base');
  const closedM7 = closedRows.filter(x => x.book === 'm7');
  const bookPf = rowsSub => {
    const w = rowsSub.filter(x => Number(x.net_pnl_usd) > 0).reduce((a, x) => a + Number(x.net_pnl_usd), 0);
    const l = rowsSub.filter(x => Number(x.net_pnl_usd) < 0).reduce((a, x) => a - Number(x.net_pnl_usd), 0);
    return l > 1e-6 ? r2(w / l) : w > 0 ? 99.0 : 0.0;
  };
  const winCnt = closedRows.filter(x => Number(x.net_pnl_usd) > 0).length;
  const winRatePct = closedRows.length > 0 ? (winCnt / closedRows.length) * 100.0 : 0.0;
  const profitFactor = bookPf(closedRows);
  const basePf = bookPf(closedBase);
  const m7Pf = bookPf(closedM7);

  const nTp = closedRows.filter(x => String(x.exit_reason).includes('tp')).length;
  const baseTpCnt = closedBase.filter(x => String(x.exit_reason).includes('tp')).length;
  const m7TpCnt = closedM7.filter(x => String(x.exit_reason).includes('tp')).length;
  const rollExits = closedRows.filter(
    x => String(x.exit_reason).startsWith('roll_') || String(x.exit_reason).startsWith('salvage_'),
  );
  const rollSalvageCount = rollExits.length;
  const roll75dCount = closedRows.filter(x => x.exit_reason === 'roll_75d').length;
  const roll30dCount = closedRows.filter(x => x.exit_reason === 'roll_30d').length;
  const roll50dCount = closedRows.filter(x => x.exit_reason === 'roll_50d').length;
  const salvageVixExpCount = closedRows.filter(x => x.exit_reason === 'salvage_vix_expensive').length;
  const avgRollSalvagePct =
    rollSalvageCount > 0
      ? (rollExits.reduce((a, x) => a + Number(x.roi_mult || 0), 0) / rollSalvageCount) * 100.0
      : 0.0;
  const annGrossSpendPct =
    (closedRows.reduce(
      (a, x) => a + Number(x.entry_cost_usd || 0) / Math.max(Number(x.nav_at_entry || INITIAL_CAPITAL), 1.0),
      0.0,
    ) /
      yrs) *
    100.0;
  const annNetBleedPct =
    (closedRows
      .filter(x => !String(x.exit_reason).includes('tp'))
      .reduce(
        (a, x) =>
          a +
          (Number(x.entry_cost_usd || 0) - Number(x.exit_net_cash_usd || 0)) /
            Math.max(Number(x.nav_at_entry || INITIAL_CAPITAL), 1.0),
        0.0,
      ) /
      yrs) *
    100.0;

  const nakedSpent = ledger.reduce((a, x) => a + Number(x.entry_cost_usd || 0), 0);
  const closedSpent = closedRows.reduce((a, x) => a + Number(x.entry_cost_usd || 0), 0);
  const grossPut = closedRows.reduce((a, x) => a + Number(x.exit_net_cash_usd || 0), 0);
  const payoutToCost = closedSpent > 1e-6 ? grossPut / closedSpent : 0.0;
  const netAlpha = navList[nDays - 1] - bhM7.endNav;
  const activeSum = anyActiveList.reduce((a, b) => a + b, 0);
  const pctActive = (activeSum / nDays) * 100.0;
  const activeDays = Math.max(1, activeSum);
  const extraShVsBh = equivShList[nDays - 1] - finalBhSh;
  const extraShPct = finalBhSh > 0 ? (extraShVsBh / finalBhSh) * 100.0 : 0.0;
  const maxRoi = closedRows.reduce((mx, x) => Math.max(mx, Number(x.roi_mult || 0)), 0.0);

  const spWins = spClosedLedger.filter(x => x.net_pnl_usd > 0).length;
  const spWinRate = spClosedLedger.length ? (spWins / spClosedLedger.length) * 100.0 : 0.0;
  const spGrossPremVal = spClosedLedger.reduce((a, x) => a + x.prem_usd, 0);
  const wcGrossPremVal = wcClosedLedger.reduce((a, x) => a + x.prem_usd, 0);
  const wcCalledCnt = wcClosedLedger.filter(x => x.exit_reason === 'called_away').length;

  let openSpSer = null;
  let openWcSer = null;
  const spCombinedLedger = [...spClosedLedger, ...wcClosedLedger];
  if (activeSp !== null) {
    const remSpLast = Math.max(1, diffDays(activeSp.expMs, lastMs));
    const qSpLast = lookupOpt(lastD, 'put', activeSp.exp_date, activeSp.kp, activeSp.k_cents, lastCl, remSpLast, lastRf, lastQ, lastVxn, activeSp.last_iv, OPT_SLIP_SP);
    const mtmCostSp = activeSp.shares * qSpLast.mid;
    openSpSer = {
      leg_id: `SP-${activeSp.sp_id}`,
      sp_id: activeSp.sp_id,
      cycle_id: activeSp.cycle_id,
      leg_type: 'short_put',
      is_open_live: true,
      pricing_source: classifyTradeSource(activeSp.entry_source || 'bsm_fallback', qSpLast.src),
      signal_date: activeSp.signal_date,
      entry_date: activeSp.entry_date,
      exp_date: activeSp.exp_date,
      exit_date: null,
      dte: activeSp.dte,
      rem_dte: remSpLast,
      entry_spot: r2(activeSp.entry_spot),
      strike: r2(activeSp.kp),
      kp: r2(activeSp.kp),
      exit_spot: r2(lastCl),
      shares: r2(activeSp.shares),
      prem_usd: r2(activeSp.prem_usd),
      exit_cost_usd: r2(mtmCostSp),
      mtm_pnl_usd: r2(activeSp.prem_usd - mtmCostSp),
      net_pnl_usd: r2(activeSp.prem_usd - mtmCostSp),
      exit_reason: 'open_live_short_put',
    };
    spCombinedLedger.push(openSpSer);
  }
  if (activeWc !== null) {
    const remWcLast = Math.max(1, diffDays(activeWc.expMs, lastMs));
    const qWcLast = lookupOpt(lastD, 'call', activeWc.exp_date, activeWc.kc, activeWc.k_cents, lastCl, remWcLast, lastRf, lastQ, lastVxn, activeWc.last_iv, OPT_SLIP_SP);
    const mtmCostWc = activeWc.shares * qWcLast.mid;
    openWcSer = {
      leg_id: `WC-${activeWc.wc_id}`,
      wc_id: activeWc.wc_id,
      cycle_id: activeWc.cycle_id,
      leg_type: 'wheel_call',
      is_open_live: true,
      pricing_source: classifyTradeSource(activeWc.entry_source || 'bsm_fallback', qWcLast.src),
      signal_date: activeWc.signal_date,
      entry_date: activeWc.entry_date,
      exp_date: activeWc.exp_date,
      exit_date: null,
      dte: activeWc.dte,
      rem_dte: remWcLast,
      entry_spot: r2(activeWc.entry_spot),
      strike: r2(activeWc.kc),
      kc: r2(activeWc.kc),
      assigned_cost_k: r2(activeWc.assigned_cost_k),
      exit_spot: r2(lastCl),
      shares: r2(activeWc.shares),
      prem_usd: r2(activeWc.prem_usd),
      exit_cost_usd: r2(mtmCostWc),
      mtm_pnl_usd: r2(activeWc.prem_usd - mtmCostWc),
      net_pnl_usd: r2(activeWc.prem_usd - mtmCostWc),
      exit_reason: 'open_live_wheel_call',
    };
    spCombinedLedger.push(openWcSer);
  }
  spCombinedLedger.sort((a, b) =>
    a.entry_date !== b.entry_date
      ? a.entry_date.localeCompare(b.entry_date)
      : (a.leg_type === 'short_put' ? 0 : 1) - (b.leg_type === 'short_put' ? 0 : 1),
  );
  if (curCycleStartMs !== null && assignedShares > 1e-6) {
    maxWheelCycleDays = Math.max(maxWheelCycleDays, diffDays(lastMs, curCycleStartMs));
  }

  const endGrossLev = ((coreShares + assignedShares) * lastCl) / Math.max(navList[nDays - 1], 1.0);
  const endPutNotional = activeSp !== null ? activeSp.shares * activeSp.kp : 0.0;
  const endNotionalLev = ((coreShares + assignedShares) * lastCl + endPutNotional) / Math.max(navList[nDays - 1], 1.0);

  const allLegSources = [
    ...ledger.map(x => String(x.pricing_source || 'bsm_fallback')),
    ...ccLedger.map(x => String(x.pricing_source || 'bsm_fallback')),
    ...spCombinedLedger.map(x => String(x.pricing_source || 'bsm_fallback')),
  ];
  const realOpraTrCnt = allLegSources.filter(s => s === 'real_opra').length;
  const realPolyTrCnt = allLegSources.filter(s => s === 'real_polygon').length;
  const realTrCnt = realOpraTrCnt + realPolyTrCnt;
  const simTrCnt = allLegSources.length - realTrCnt;
  const realTrPct = allLegSources.length > 0 ? (realTrCnt / allLegSources.length) * 100.0 : 0.0;
  const realLk = qStats.realOpraHits + qStats.realPolygonHits;
  const realHitPct = qStats.totalLookups > 0 ? (realLk / qStats.totalLookups) * 100.0 : 0.0;

  const blkBEn = lockoutEpisodes.reduce((a, e) => a + Number(e.blocked_base_entries || 0), 0);
  const blkMEn = lockoutEpisodes.reduce((a, e) => a + Number(e.blocked_m7_entries || 0), 0);
  const blkBRl = lockoutEpisodes.reduce((a, e) => a + Number(e.blocked_base_rolls || 0), 0);
  const blkMRl = lockoutEpisodes.reduce((a, e) => a + Number(e.blocked_m7_rolls || 0), 0);

  const summary = {
    id: strategyId,
    profile: isCore3 ? 'core3_adaptive' : 'full_m7_adaptive',
    arch: 'b020_m125_dual_book_hard_roll_5d_lockout',
    ruleset_code: HARDCODED_RULESET_SPEC.code,
    base_budget_pct: 0.2,
    m7_budget_pct: 1.25,
    base_vix_gate_max: baseVixMax,
    lockout_days: lockoutDays,
    lockout_inv_thresh: lockoutInvThresh,
    pricing_basis: useReal ? 'real_opra_2015_2025_calibrated_bsm' : 'bsm_simulated',
    fill_mode: effFillMode,
    real_trades_count: realTrCnt,
    real_opra_trades_count: realOpraTrCnt,
    real_polygon_trades_count: realPolyTrCnt,
    sim_trades_count: simTrCnt,
    real_trades_pct: r1(realTrPct),
    real_quote_lookups: qStats.totalLookups,
    real_quote_hits: realLk,
    real_quote_hit_pct: r1(realHitPct),
    opra_window_fallbacks: qStats.opraWindowFallbacks,
    opra_window_end: useReal ? String(realCache.opra_date_max || '') : '',
    polygon_window_end: useReal ? String(realCache.polygon_date_max || '') : '',
    put_otm: putOtm,
    put_otm_pct: otmPctInt,
    m7_tp_mode: m7TpMode,
    roll_mode: effRollMode,
    target_dte: targetDte,
    roll_dte: rollDteThr,
    m0_enabled: m0Enabled,
    max_slots: maxSlots,
    slot_coverage: 0.5,
    end_nav: r2(navList[nDays - 1]),
    bh_parity_end_nav: r2(bhM7.endNav),
    net_alpha_usd: r2(netAlpha),
    cagr_pct: r2(cagr * 100.0),
    vol_pct: r2(vol * 100.0),
    max_dd_pct: r2(mdd * 100.0),
    sharpe: r3(sharpe),
    sortino: r3(sortino),
    calmar: r3(calmar),
    win_rate_pct: r1(winRatePct),
    profit_factor: profitFactor,
    base_pf: basePf,
    m7_pf: m7Pf,
    payout_to_cost: r3(payoutToCost),
    final_shares: r2(equivShList[nDays - 1]),
    bh_final_shares: r2(finalBhSh),
    extra_shares_vs_bh: r2(extraShVsBh),
    extra_shares_pct: r2(extraShPct),
    pct_days_hedged: r1(pctActive),
    base_days_hedged_pct: r1((baseDaysHedged / Math.max(nDays, 1)) * 100.0),
    base_gate_open_pct: r1((baseGateOpenDays / Math.max(nDays, 1)) * 100.0),
    alpha_per_active_day_usd: r2(netAlpha / activeDays),
    tranches_total: ledger.length,
    closed_trades_count: closedTradesCount,
    base_trades_count: closedBase.length,
    m7_trades_count: closedM7.length,
    naked_count: ledger.length,
    collar_count: 0,
    tp_count: nTp,
    base_tp_count: baseTpCnt,
    m7_tp_count: m7TpCnt,
    roll_salvage_count: rollSalvageCount,
    roll_75d_count: roll75dCount,
    roll_30d_count: roll30dCount,
    roll_50d_count: roll50dCount,
    salvage_vix_expensive_count: salvageVixExpCount,
    avg_roll_salvage_pct: r1(avgRollSalvagePct),
    ann_gross_spend_pct_nav: r2(annGrossSpendPct),
    ann_net_bleed_pct_nav: r2(annNetBleedPct),
    base_net_pnl_usd: r2(closedBase.reduce((a, x) => a + Number(x.net_pnl_usd || 0), 0)),
    m7_net_pnl_usd: r2(closedM7.reduce((a, x) => a + Number(x.net_pnl_usd || 0), 0)),
    net_option_pnl_usd: r2(closedRows.reduce((a, x) => a + Number(x.net_pnl_usd || 0), 0)),
    lockout_episodes_count: lockoutEpisodes.length,
    lockout_days_total: lockoutDaysTotal,
    blocked_base_entries: blkBEn,
    blocked_m7_entries: blkMEn,
    blocked_base_rolls: blkBRl,
    blocked_m7_rolls: blkMRl,
    max_roi_mult: r2(maxRoi),
    naked_prem_spent_usd: r2(nakedSpent),
    gross_put_monetized_usd: r2(grossPut),
    gross_call_drag_usd: 0.0,
    sum_delta_usd: r2(ledger.reduce((a, x) => a + Number(x.delta_usd || 0), 0)),
    sum_gamma_usd: r2(ledger.reduce((a, x) => a + Number(x.gamma_usd || 0), 0)),
    sum_vega_usd: r2(ledger.reduce((a, x) => a + Number(x.vega_usd || 0), 0)),
    sum_theta_slip_usd: r2(ledger.reduce((a, x) => a + Number(x.theta_slip_usd || 0), 0)),
    cc_mode: ccMode,
    cc_trades_count: ccLedger.length,
    cc_assigned_count: ccAssignedCnt,
    cc_stop_count: ccLedger.filter(x => ['delta_stop', 'delta_roll_up', 'delta_credit_roll'].includes(x.exit_reason)).length,
    cc_roll_count: ccLedger.filter(x => Number(x.roll_gen || 0) > 0).length,
    cc_active_years: new Set(ccLedger.map(x => String(x.entry_date).slice(0, 4))).size,
    cc_gross_prem_usd: r2(ccGrossPrem),
    cc_gross_loss_usd: r2(ccGrossLoss),
    cc_net_pnl_usd: r2(ccGrossPrem - ccGrossLoss),
    cc_funded_puts_usd: r2(ccFundedPuts),
    cc_cash_end_usd: r2(ccCash),
    sp_mode: spMode,
    wc_mode: wcMode,
    sp_trades_count: spClosedLedger.length + (openSpSer ? 1 : 0),
    sp_win_rate_pct: r1(spWinRate),
    sp_assignments_count: spAssignCount,
    wc_trades_count: wcClosedLedger.length + (openWcSer ? 1 : 0),
    wc_called_away_count: wcCalledCnt,
    sp_gross_prem_usd: r2(spGrossPremVal),
    wc_gross_prem_usd: r2(wcGrossPremVal),
    margin_interest_usd: r2(spMarginInterestTotal),
    sp_comm_usd: r2(spCommTotal),
    days_short_put_open: daysShortPutOpen,
    days_levered_stock: daysLevered,
    max_wheel_cycle_days: maxWheelCycleDays,
    max_gross_stock_lev: r3(maxGrossStockLev),
    max_notional_lev: r3(maxNotionalLev),
    end_assigned_shares: r2(assignedShares),
    end_sp_cash_usd: r2(spCash),
  };

  const spLiveEod = {
    sp_mode: spMode,
    wc_mode: wcMode,
    enabled: spEnabled,
    dte: spDte,
    max_lev_pct: Math.round(spMaxLev * 100),
    require_vix_falling: spRequireVixFalling,
    open_short_put: openSpSer,
    open_wheel_call: openWcSer,
    assigned_shares: r2(assignedShares),
    assigned_cost_k: assignedShares > 1e-6 ? r2(assignedCostK) : null,
    sp_cash_usd: r2(spCash),
    gross_stock_lev: r3(endGrossLev),
    notional_lev: r3(endNotionalLev),
    pending_sp_next_open: pendingSp !== null && activeSp === null && assignedShares <= 1e-6,
    pending_wc_next_open: pendingWc !== null && assignedShares > 1e-6 && activeWc === null,
  };

  const lockoutStateEod = {
    locked: postTpLockout,
    non_inverted_streak: nonInvertedStreak,
    required_streak: lockoutDays,
    vix_ratio_unlock_max: lockoutInvThresh,
    last_tp_date: lastTpDate,
    last_unlock_date: lastUnlockDate,
    episodes_count: lockoutEpisodes.length,
    trading_days_locked: lockoutDaysTotal,
    blocked_base_entries: blkBEn,
    blocked_m7_entries: blkMEn,
    blocked_base_rolls: blkBRl,
    blocked_m7_rolls: blkMRl,
    blocked_total: blkBEn + blkMEn + blkBRl + blkMRl,
    episodes: lockoutEpisodes,
  };

  return {
    summary,
    nav: navList,
    equiv_shares: equivShList,
    any_active: anyActiveList,
    active_slots: activeSlotsList,
    ledger,
    cc_ledger: ccLedger,
    sp_ledger: spCombinedLedger,
    active_tranches_eod: activeTranchesSerialized,
    base_active_tranches_eod: baseActiveSerialized,
    all_active_tranches_eod: [...baseActiveSerialized, ...activeTranchesSerialized],
    pending_sig_eod: pendingSig,
    pending_base_open_eod: pendingBaseOpen,
    lockout_state_eod: lockoutStateEod,
    sp_live_eod: spLiveEod,
  };
}

export function buildM7LiveDashboardJS(
  row,
  sigDay,
  featRow,
  m7Sim,
  coeffs,
  {
    putOtm = 'otm15',
    m7TpMode = 'standard',
    rollMode = 'adaptive_120_90',
    m0Enabled = true,
    isPitReplay = false,
  } = {},
) {
  const d = String(row.date);
  const cl = Number(row.close);
  const ddPct = Number(row.dd_from_ath) * 100.0;
  const vixNow = Number(row.vix ?? 0);
  const vxn = Number(row.vxn);
  const vr = Number(row.vix_ratio);
  const rCur = Number(row.r);
  const qCur = Number(row.div_yield);
  const sc = Number(row.score);
  const adLine = Number(row.ad_line);
  const adSma50 = Number(row.ad_sma50);
  const adBelow = adLine < adSma50;

  const strategyId = String(m7Sim.summary.id || 'M7G_Graded');
  const fillModeCur = String(m7Sim.summary.fill_mode || DEFAULT_M7_FILL_MODE);
  const isCore3 = strategyId === 'Core3_Adaptive';
  const effRollMode =
    isCore3 && rollMode === '90d_hold'
      ? 'adaptive_120_90'
      : CRISIS_OBSERVATORY_ROLL_MODES.includes(rollMode)
        ? rollMode
        : 'adaptive_120_90';
  const isAdaptive = effRollMode === 'adaptive_120_90';
  const isRoll50 = effRollMode === '120d_roll50';
  const isCtaNow = Boolean(sigDay.M4);
  let entryDte = 90;
  let rollDte = 0;
  if (isAdaptive) {
    entryDte = isCtaNow ? HARDCODED_M7_CTA_DTE : HARDCODED_M7_BASE_DTE;
    rollDte = isCtaNow ? HARDCODED_M7_CTA_ROLL_DTE : HARDCODED_M7_BASE_ROLL_DTE;
  } else if (isRoll50) {
    entryDte = 120;
    rollDte = 50;
  }
  const fiveXDte = 45;
  const nearItmMult = m7TpMode === 'itm_tp' ? 1.0 : HARDCODED_NEAR_ITM_MULT;

  const maxSlots = Number(m7Sim.summary.max_slots || 3);
  const isGraded = maxSlots === 3;
  const c3Eval = evalCore3Signal(sigDay);
  const prob = isCore3
    ? Number(sigDay.crisis_prob_c3 ?? c3Eval.crisis_prob_c3)
    : Number(sigDay.crisis_prob ?? 0);
  const p1 = isCore3 ? Number(sigDay.p1_c3 ?? c3Eval.p1_c3) : Number(sigDay.p1 ?? 0);
  const p2 = isCore3 ? 0 : Number(sigDay.p2 ?? 0);
  const p3 = isCore3 ? Number(sigDay.p3_c3 ?? c3Eval.p3_c3) : Number(sigDay.p3 ?? 0);
  const targetSlots = isCore3
    ? Number(sigDay.target_slots_c3 ?? c3Eval.target_slots_c3)
    : Number(isGraded ? sigDay.target_slots_m7g : sigDay.target_slots_m7);

  const activeTr = m7Sim.active_tranches_eod ?? [];
  const baseTr = m7Sim.base_active_tranches_eod ?? [];
  const allOpenTr = m7Sim.all_active_tranches_eod ?? [...baseTr, ...activeTr];
  const activeSlots = activeTr.length;
  const baseActiveSlots = baseTr.length;
  const effActiveTr = activeTr.filter(t => !Boolean(t.pending_tp));
  const effBaseTr = baseTr.filter(t => !Boolean(t.pending_tp));
  const pendSig = m7Sim.pending_sig_eod;
  const pendBaseOpen = Boolean(m7Sim.pending_base_open_eod);
  const lockEod = m7Sim.lockout_state_eod ?? {};

  const lockedBy5d = Boolean(lockEod.locked);
  const nonInvStreak = Number(lockEod.non_inverted_streak ?? 0);
  const reqLockStreak = Number(lockEod.required_streak ?? HARDCODED_LOCKOUT_DAYS);
  const unlockVrMax = Number(lockEod.vix_ratio_unlock_max ?? HARDCODED_LOCKOUT_INV_THRESH);
  const isNonInvToday = vr < unlockVrMax;
  const lastTpDtStr = lockEod.last_tp_date ?? null;
  const lastUnlockDtStr = lockEod.last_unlock_date ?? null;
  const lockEpCnt = Number(lockEod.episodes_count ?? 0);
  const lockDaysTot = Number(lockEod.trading_days_locked ?? 0);
  const lockBlkTot = Number(lockEod.blocked_total ?? 0);

  const baseVixOk = vixNow <= HARDCODED_BASE_VIX_MAX;
  const baseVrOk = vr < HARDCODED_BASE_VR_MAX;
  const baseRawGateOpen = baseVixOk && baseVrOk;
  const baseGateOpen = baseRawGateOpen && !lockedBy5d;

  const vxnRedOk = vxn <= 27.0;
  const vrRedOk = vr < 1.02;
  const redlineBlocked = !(vxnRedOk && vrRedOk);

  const reqGap = targetSlots === 3 ? 21 : 30;
  const curMs = parseIsoDayMs(d);
  let lastEntryDateStr = null;
  let daysSinceLast = null;
  if (effActiveTr.length > 0) {
    lastEntryDateStr = effActiveTr.reduce(
      (mx, t) => (t.entry_date > mx ? t.entry_date : mx),
      effActiveTr[0].entry_date,
    );
    daysSinceLast = diffDays(curMs, parseIsoDayMs(lastEntryDateStr));
  }
  const cooldownPassed = daysSinceLast === null || daysSinceLast >= reqGap;
  const { mods: modsActive, codeStr: trigCode } = formatM7TriggerLabels(sigDay, maxSlots, isCore3);

  const fv = (k, defVal = 0.0) => {
    const v = featRow?.[k];
    return v === null || v === undefined || !Number.isFinite(Number(v)) ? defVal : Number(v);
  };
  const fvOpt = k => {
    const v = featRow?.[k];
    return v === null || v === undefined || !Number.isFinite(Number(v)) ? null : Number(v);
  };
  const fmtSigned = (n, dec = 2) => `${n >= 0 ? '+' : ''}${n.toFixed(dec)}`;
  const rspSpyV = fv('rsp_spy');
  const rspSmaV = fv('rsp_sma50');
  const iwmQqqV = fv('iwm_qqq');
  const iwmSmaV = fv('iwm_sma50');
  const defRet20Raw = fv('def_ret20');
  const defRet20Pct = defRet20Raw * 100.0;
  const skew10V = fv('skew10');
  const skewP75V = fv('skew_p75');
  const vvixV = fv('vvix');
  const vvixP75V = fv('vvix_p75');
  const vrJ5V = fv('vr_jump5');
  const hmmPV = fv('hmm_p');
  const hmmP5V = fv('hmm_p5');
  const ewmacV = fv('ewmac');
  const ema20V = fv('ema20');
  const sma200V = fv('sma200');
  const hygV = fv('hyg_lqd');
  const hygSmaV = fv('hyg_sma50');
  const baaV = fv('baa_lag1');
  const baaROpt = fvOpt('baa_rise63');
  const baaRV = baaROpt ?? 0.0;
  const dgs2JOpt = fvOpt('dgs2_jump63');
  const dgs2JV = dgs2JOpt ?? 0.0;
  const nfciJOpt = fvOpt('nfci_jump20');
  const nfciJV = nfciJOpt ?? 0.0;
  const adDiffInt = Math.round(adLine - adSma50);

  const stressPack = computeLiveStressIndexJS({
    hmm_p: hmmPV,
    vxn,
    vix_ratio: vr,
    dd_from_ath: Number(row.dd_from_ath),
    close: cl,
    sma200: sma200V,
    ewmac: ewmacV,
    hyg_lqd: hygV,
    hyg_sma50: hygSmaV,
    baa_rise63: baaROpt,
    dgs2_jump63: dgs2JOpt,
    nfci_jump20: nfciJOpt,
    def_ret20: defRet20Raw,
    rsp_spy: rspSpyV,
    rsp_sma50: rspSmaV,
    iwm_qqq: iwmQqqV,
    iwm_sma50: iwmSmaV,
    ad_below50: adBelow,
    vvix: vvixV,
    vvix_p75: vvixP75V,
    skew10: skew10V,
    skew_p75: skewP75V,
    vr_jump5: vrJ5V,
  });
  const stressIdx = stressPack.live_stress_index;
  const stressLblEn = stressPack.live_stress_label_en;
  const stressLblZh = stressPack.live_stress_label_zh;

  let bbStatus;
  let bbLblEn;
  let bbLblZh;
  let bbDetEn;
  let bbDetZh;
  if (lockedBy5d) {
    bbStatus = 'LOCKED_BY_5D';
    bbLblEn = `LOCKED BY 5D POST-TP GATE (${nonInvStreak}/${reqLockStreak}d < 1.00)`;
    bbLblZh = `止盈后 5D 静默锁死（解除倒挂进度 ${nonInvStreak}/${reqLockStreak} 天）`;
    bbDetEn = `Book B 0.20% floor put re-entry is paused until VIX/VIX3M < ${unlockVrMax.toFixed(2)} holds for ${reqLockStreak} consecutive trading days (currently ${nonInvStreak}/${reqLockStreak}, VIX ${vixNow.toFixed(2)}).`;
    bbDetZh = `B账本 0.20% 常态底仓在崩盘止盈后暂停新开/滚仓，须等 VIX/VIX3M < ${unlockVrMax.toFixed(2)} 连续满 ${reqLockStreak} 个交易日才解锁（当前 ${nonInvStreak}/${reqLockStreak} 天，VIX ${vixNow.toFixed(2)}）。`;
  } else if (baseGateOpen) {
    bbStatus = 'GATE_OPEN';
    bbLblEn = `OPEN · VIX ${vixNow.toFixed(2)} <= 20 & VIX/3M ${vr.toFixed(3)} < 1.02`;
    bbLblZh = `门控开启 · VIX ${vixNow.toFixed(2)} <= 20 且 VIX/3M ${vr.toFixed(3)} < 1.02`;
    if (baseTr.length > 0) {
      const b0 = baseTr[0];
      bbDetEn = `Active 0.20% NAV floor put (${b0.occSymbol} · K=$${Number(b0.kp).toFixed(2)} · ${b0.rem_dte}D left) — hard-rolls cleanly at <= 75 DTE while VIX <= 20.`;
      bbDetZh = `在途持有 0.20% 净值常态底仓（${b0.occSymbol} · 行权 $${Number(b0.kp).toFixed(2)} · 剩 ${b0.rem_dte} 天）—— VIX <= 20 期间剩 <=75 天自动硬换新 125D Put。`;
    } else {
      bbDetEn = 'Calm IV window open: T+1 Close deploys 0.20% NAV into 125D -15% OTM floor put.';
      bbDetZh = '低波窗口开启：次日收盘按 0.20% 净值买入 125D -15% OTM 常态底仓 Put。';
    }
  } else {
    bbStatus = 'GATE_CLOSED_HIGH_VIX';
    bbLblEn = `CLOSED · VIX ${vixNow.toFixed(2)} > 20 or VIX/3M ${vr.toFixed(3)} >= 1.02`;
    bbLblZh = `门控关闭 · VIX ${vixNow.toFixed(2)} > 20 或 VIX/3M ${vr.toFixed(3)} >= 1.02（禁买贵底仓）`;
    if (baseTr.length > 0) {
      const b0 = baseTr[0];
      bbDetEn = `Existing floor put (${b0.occSymbol} · K=$${Number(b0.kp).toFixed(2)} · ${b0.rem_dte}D left) continues shielding; if it hits <= 75 DTE while VIX > 20, it salvages residual cash into QQQ without re-buying expensive IV.`;
      bbDetZh = `存量底仓（${b0.occSymbol} · 行权 $${Number(b0.kp).toFixed(2)} · 剩 ${b0.rem_dte} 天）继续护航；若 VIX > 20 期间跌至 <=75 天则直接回收残值换股，绝不追买高波贵 Put。`;
    } else {
      bbDetEn = `VIX ${vixNow.toFixed(2)} exceeds 20.0 gate — Book B waits on standby until VIX <= 20 & VIX/3M < 1.02.`;
      bbDetZh = `当前 VIX ${vixNow.toFixed(2)} 高于 20.0 门控线 —— B账本静默待命，待 VIX <= 20 低波回归再建底仓。`;
    }
  }

  const bookBVixGate = {
    open: baseGateOpen,
    raw_gate_open: baseRawGateOpen,
    status: bbStatus,
    vix: r2(vixNow),
    vix_max: HARDCODED_BASE_VIX_MAX,
    vix_ok: baseVixOk,
    vix_ratio: r3(vr),
    vix_ratio_max: HARDCODED_BASE_VR_MAX,
    vix_ratio_ok: baseVrOk,
    locked_by_5d: lockedBy5d,
    budget_pct: 0.2,
    target_dte: HARDCODED_BASE_DTE,
    roll_dte: HARDCODED_BASE_ROLL_DTE,
    otm_pct: 15,
    active_slots: baseActiveSlots,
    active_tranche: baseTr.length > 0 ? baseTr[0] : null,
    pending_open_t1: pendBaseOpen,
    status_label_en: bbLblEn,
    status_label_zh: bbLblZh,
    detail_en: bbDetEn,
    detail_zh: bbDetZh,
  };

  let lkLblEn;
  let lkLblZh;
  let lkDetEn;
  let lkDetZh;
  if (lockedBy5d) {
    const remLk = Math.max(1, reqLockStreak - nonInvStreak);
    lkLblEn = `LOCKED · Non-Inverted Streak ${nonInvStreak}/${reqLockStreak}D (${remLk}D left)`;
    lkLblZh = `止盈静默锁死中 · 解除倒挂连续 ${nonInvStreak}/${reqLockStreak} 天（还需 ${remLk} 天）`;
    lkDetEn = `Triggered by crash TP on ${lastTpDtStr || d}. Today VIX/VIX3M = ${vr.toFixed(3)} (${isNonInvToday ? '< 1.00 contango' : '>= 1.00 still inverted -> streak reset to 0'}): blocks all new puts & 75D/30D re-buys across Book B & Book M until 5 consecutive days < 1.00.`;
    lkDetZh = `自 ${lastTpDtStr || d} 崩盘止盈起进入静默锁死；今日 VIX/VIX3M = ${vr.toFixed(3)}（${isNonInvToday ? '< 1.00 已退回正斜率' : '>= 1.00 仍在倒挂 -> 计数清零'}）—— 双账本新开与滚仓续买全面冻结，直至连续 ${reqLockStreak} 个交易日 < 1.00 解锁。`;
  } else {
    lkLblEn = `UNLOCKED · Clear to Execute (Last TP ${lastTpDtStr || 'None'})`;
    lkLblZh = `已解锁就绪 · 允许正常开仓/硬换（上次止盈 ${lastTpDtStr || '无'}）`;
    lkDetEn = `Rule: after any crash TP, freeze all new buys & roll re-buys until VIX/VIX3M < 1.00 for 5 consecutive trading days (${lockEpCnt} historical episodes / ${lockDaysTot} locked days).`;
    lkDetZh = `铁律：任意槽位触发崩盘止盈后立即停买，须等 VIX/VIX3M < 1.00 连续满 5 个交易日且不反跳才允许再买（历史共触发 ${lockEpCnt} 轮 / 锁定 ${lockDaysTot} 个交易日）。`;
  }

  const postTpLockoutBlock = {
    locked: lockedBy5d,
    non_inverted_streak: nonInvStreak,
    required_streak: reqLockStreak,
    vix_ratio_now: r3(vr),
    vix_ratio_unlock_max: unlockVrMax,
    is_non_inverted_today: isNonInvToday,
    last_tp_date: lastTpDtStr,
    last_unlock_date: lastUnlockDtStr,
    episodes_count: lockEpCnt,
    trading_days_locked: lockDaysTot,
    blocked_base_entries: Number(lockEod.blocked_base_entries ?? 0),
    blocked_m7_entries: Number(lockEod.blocked_m7_entries ?? 0),
    blocked_total: lockBlkTot,
    status_label_en: lkLblEn,
    status_label_zh: lkLblZh,
    detail_en: lkDetEn,
    detail_zh: lkDetZh,
  };

  const anyTpArmed = allOpenTr.some(
    t =>
      Boolean(t.pending_tp) &&
      !String(t.tp_reason || '').startsWith('roll_') &&
      !String(t.tp_reason || '').startsWith('salvage_'),
  );
  const anyM7RollArmed = activeTr.some(
    t => Boolean(t.pending_tp) && String(t.tp_reason || '').startsWith('roll_'),
  );
  const anyBaseRollArmed = baseTr.some(
    t =>
      Boolean(t.pending_tp) &&
      (String(t.tp_reason || '').startsWith('roll_') || String(t.tp_reason || '').startsWith('salvage_')),
  );
  const armedRollSlot = activeTr.find(
    t => Boolean(t.pending_tp) && String(t.tp_reason || '').startsWith('roll_'),
  );
  const armedRollD = armedRollSlot ? Number(armedRollSlot.roll_dte || 75) : rollDte > 0 ? rollDte : 75;
  const otmLbl = putOtm === 'otm20' ? '-20% OTM' : '-15% OTM';
  const tenorLblEn = isAdaptive
    ? `${entryDte}D (Hard Roll@${rollDte}D)`
    : isRoll50
      ? '120D (Roll@50D)'
      : '90D';
  const tenorLblZh = isAdaptive
    ? `${entryDte}D（剩${rollDte}天硬换）`
    : isRoll50
      ? '120D（剩50天滚仓）'
      : '90D';

  const m7WantsEntry = targetSlots > effActiveTr.length && vxnRedOk && vrRedOk && cooldownPassed;
  const baseWantsEntry = baseRawGateOpen && effBaseTr.length === 0;

  let t1Code;
  let t1Tone;
  let t1BadgeEn;
  let t1BadgeZh;
  let t1TitleEn;
  let t1TitleZh;

  if (anyTpArmed) {
    t1Code = 'TP_ARMED_NEXT_OPEN';
    t1Tone = 'tp';
    t1BadgeEn = 'T+1 EXEC: NEAR-ITM BOTTOM CLEARANCE -> MONETIZE PUTS & ENTER 5D LOCKOUT';
    t1BadgeZh = 'T+1 执行指令：准实值底部出清触发 · 全额变现抄底 QQQ 并启动 5D 静默锁死';
    t1TitleEn = 'Near-ITM Panic Take-Profit Armed — Monetize Put(s) Into QQQ & Lock Re-Entry Until 5D Non-Inverted';
    t1TitleZh = '准实值恐慌止盈已触发 —— 次日变现全部达标 Put 换入 QQQ，并同步冻结新买直至解除倒挂满 5 天';
  } else if (anyM7RollArmed && targetSlots > 0 && !redlineBlocked && !lockedBy5d) {
    t1Code = 'ROLL_75D_AND_REOPEN';
    t1Tone = 'armed';
    t1BadgeEn = `T+1 EXEC: ${armedRollD}-DTE HARD ROLL -> SALVAGE & OPEN 1.25% ${entryDte}D ${otmLbl} PUT`;
    t1BadgeZh = `T+1 执行指令：剩 <=${armedRollD} DTE 硬换 · 回收残值并按 1.25% 预算换入新 ${entryDte}D ${otmLbl} Put`;
    t1TitleEn = `Low-Vol Gate ${Math.round(prob)}% (${trigCode}) Active at <=${armedRollD} DTE — Hard-Roll Into Fresh 1.25% NAV ${entryDte}-DTE ${otmLbl} Put`;
    t1TitleZh = `在途战术槽剩 <=${armedRollD} DTE 且买盾分 ${Math.round(prob)}%（${trigCode}）仍亮 —— 次日硬换入新 1.25% 净值 ${entryDte}D ${otmLbl} Put`;
  } else if (anyM7RollArmed) {
    t1Code = 'SALVAGE_75D_EXIT';
    t1Tone = 'active';
    t1BadgeEn = `T+1 EXEC: ${armedRollD}-DTE HARD EXIT -> HARVEST RESIDUAL TO QQQ`;
    t1BadgeZh = `T+1 执行指令：剩 <=${armedRollD} DTE 硬退回收残值复投 QQQ（信号关闭或静默锁死）`;
    t1TitleEn = `Slot Reached <=${armedRollD} DTE With Gate Off/Locked — Exit Cleanly Before Theta Cliff & Sweep Into QQQ`;
    t1TitleZh = `在途槽位剩 <=${armedRollD} DTE 且买盾门控关闭/锁死 —— 在 Theta 悬崖前硬退回收残值并复投 QQQ`;
  } else if (pendSig !== null) {
    const nextSlotIdx = effActiveTr.length + 1;
    t1Code = 'OPEN_NEW_SLOT';
    t1Tone = 'armed';
    t1BadgeEn = `T+1 EXEC: BUY BOOK M SLOT ${nextSlotIdx}/${maxSlots} (1.25% NAV · ${tenorLblEn} ${otmLbl} PUT)`;
    t1BadgeZh = `T+1 执行指令：新开 M账本第 ${nextSlotIdx}/${maxSlots} 槽（1.25% 净值固定预算 · ${tenorLblZh} ${otmLbl} Put）`;
    t1TitleEn = `Real-Time Stress ${stressIdx}% · Low-Vol Gate ${Math.round(prob)}% (${trigCode}) -> Deploy 1.25% NAV Into ${entryDte}-DTE ${otmLbl} Put`;
    t1TitleZh = `实时压力 ${stressIdx}% · 低波买盾分 ${Math.round(prob)}%（${trigCode}）-> 次日按 1.25% 净值固定预算买入第 ${nextSlotIdx}/${maxSlots} 槽 ${tenorLblZh} ${otmLbl} Put`;
  } else if (lockedBy5d && (m7WantsEntry || baseWantsEntry || targetSlots > effActiveTr.length)) {
    const remLkD = Math.max(1, reqLockStreak - nonInvStreak);
    t1Code = 'POST_TP_LOCKOUT_WAIT';
    t1Tone = 'blocked';
    t1BadgeEn = `T+1 EXEC: 5D POST-TP LOCKOUT (${nonInvStreak}/${reqLockStreak}D VIX/3M < 1.00 · ${remLkD}D LEFT)`;
    t1BadgeZh = `T+1 执行指令：止盈后 5D 静默锁死（解除倒挂 ${nonInvStreak}/${reqLockStreak} 天 · 还需 ${remLkD} 天）`;
    t1TitleEn = `Post-TP Lockout Active Since ${lastTpDtStr || d} (VIX/3M ${vr.toFixed(3)}) — No Re-Buying Until 5 Consecutive Non-Inverted Days (< 1.00) Complete`;
    t1TitleZh = `崩盘止盈后静默门控生效（上次止盈 ${lastTpDtStr || d}，今日 VIX/3M ${vr.toFixed(3)}）—— 须等连续 5 个交易日解除倒挂（< 1.00）且不反跳后才恢复买盾`;
  } else if (targetSlots > effActiveTr.length && redlineBlocked) {
    t1Code = 'REDLINE_BLOCKED';
    t1Tone = 'blocked';
    t1BadgeEn = 'T+1 EXEC: HARD REDLINE BLOCKED (NO NEW PUTS IN HIGH IV)';
    t1BadgeZh = 'T+1 执行指令：风控红线锁死禁开新仓（拒绝高波追买天价 Put）';
    t1TitleEn = `Real-Time Stress ${stressIdx}% (${stressLblEn}) · Hard Redline Active (VXN ${vxn.toFixed(1)} > 27 or VIX/3M ${vr.toFixed(3)} >= 1.02) — Chasing Expensive Puts Forbidden`;
    t1TitleZh = `实时危机压力 ${stressIdx}%（${stressLblZh}）· 绝对风控红线生效（VXN ${vxn.toFixed(1)} > 27 或 VIX/3M ${vr.toFixed(3)} >= 1.02）—— 严禁高波追高买贵盾`;
  } else if (targetSlots > effActiveTr.length && !cooldownPassed) {
    const remWait = Math.max(1, reqGap - (daysSinceLast ?? 0));
    t1Code = 'COOLDOWN_WAIT';
    t1Tone = 'cooldown';
    t1BadgeEn = `T+1 EXEC: COOLDOWN WAIT (${daysSinceLast}D / ${reqGap}D · ${remWait}D LEFT)`;
    t1BadgeZh = `T+1 执行指令：加仓冷却期等待中（距上槽 ${daysSinceLast}/${reqGap} 天 · 还需 ${remWait} 天）`;
    t1TitleEn = `Low-Vol Entry Gate ${Math.round(prob)}% Wants ${targetSlots} Slots, Waiting ${remWait} Calendar Days for ${reqGap}D Step Cooldown`;
    t1TitleZh = `低波买盾执行分 ${Math.round(prob)}% 指向 ${targetSlots} 槽，当前距上一槽仅 ${daysSinceLast} 天（未满 ${reqGap} 天冷却期，暂缓加槽）`;
  } else if (anyBaseRollArmed && baseGateOpen) {
    t1Code = 'ROLL_BASE_75D';
    t1Tone = 'armed';
    t1BadgeEn = 'T+1 EXEC: BOOK B 75-DTE HARD ROLL -> REFRESH 0.20% NAV 125D -15% OTM PUT';
    t1BadgeZh = 'T+1 执行指令：B账本 <=75 DTE 硬换 -> 按 0.20% 净值续换新 125D -15% OTM 底仓 Put';
    t1TitleEn = `VIX ${vixNow.toFixed(2)} <= 20 Calm Gate Open — Salvage 75D Floor Put & Refresh 0.20% NAV 125D -15% OTM Put`;
    t1TitleZh = `VIX ${vixNow.toFixed(2)} <= 20 低波门控开启 —— 次日回收剩 <=75 天旧底仓残值并硬换新 125D -15% OTM 底仓 Put`;
  } else if (anyBaseRollArmed) {
    t1Code = 'SALVAGE_BASE_75D';
    t1Tone = 'active';
    t1BadgeEn = 'T+1 EXEC: BOOK B 75-DTE SALVAGE EXIT (VIX > 20 GATE CLOSED · NO RE-BUY)';
    t1BadgeZh = 'T+1 执行指令：B账本 <=75 DTE 残值退出（VIX > 20 门控关闭 · 禁追高续买）';
    t1TitleEn = `Book B Floor Put Reached <=75 DTE With VIX ${vixNow.toFixed(2)} > 20 — Harvest Residual Cash Into QQQ`;
    t1TitleZh = `B账本底仓剩 <=75 天且 VIX ${vixNow.toFixed(2)} > 20 —— 次日回收残值换入 QQQ，等待低波回归再建底仓`;
  } else if (pendBaseOpen) {
    t1Code = 'OPEN_BASE_FLOOR';
    t1Tone = 'armed';
    t1BadgeEn = 'T+1 EXEC: OPEN BOOK B 0.20% BASE PUT (125D -15% OTM · VIX <= 20)';
    t1BadgeZh = 'T+1 执行指令：开启 B账本 0.20% 常态底仓（125D -15% OTM Put · VIX <= 20）';
    t1TitleEn = `Calm VIX Gate Open (VIX ${vixNow.toFixed(2)} <= 20 & VIX/3M ${vr.toFixed(3)} < 1.02) — Deploy 0.20% NAV Floor Put`;
    t1TitleZh = `常态低波门控达标（VIX ${vixNow.toFixed(2)} <= 20 且 VIX/3M ${vr.toFixed(3)} < 1.02）—— 次日按 0.20% 净值建仓 125D -15% OTM 底仓 Put`;
  } else if (activeSlots > 0 || baseActiveSlots > 0) {
    t1Code = 'HOLD_ACTIVE_SLOTS';
    t1Tone = 'active';
    t1BadgeEn = `T+1 EXEC: HOLD ${baseActiveSlots} BASE (0.20%) + ${activeSlots}/${maxSlots} M7G (1.25%) PUT(S) · HARD ROLL 75D/30D`;
    t1BadgeZh = `T+1 执行指令：持有 B账本 ${baseActiveSlots} 槽(0.20%) + M账本 ${activeSlots}/${maxSlots} 槽(1.25%) · 盯紧准实值止盈与 75D/30D 硬换`;
    t1TitleEn = `Real-Time Stress ${stressIdx}% (${stressLblEn}) · Dual-Book Shield Active (${baseActiveSlots} Base + ${activeSlots}/${maxSlots} M7G Slots) Over 100% Uncapped QQQ Core`;
    t1TitleZh = `实时危机压力 ${stressIdx}%（${stressLblZh}）· 双账本在途护航（B账本 ${baseActiveSlots} 槽 + M账本 ${activeSlots}/${maxSlots} 槽 · 100% QQQ 底仓无封顶持有）`;
  } else {
    const profLblEn = isCore3 ? 'Core-3 Minimal' : 'Full M7G Dual-Book';
    const profLblZh = isCore3 ? '精简3核双账本' : '全套M7G双账本';
    t1Code = 'STANDBY';
    t1Tone = 'standby';
    if (lockedBy5d) {
      t1BadgeEn = `T+1 EXEC: POST-TP 5D LOCKOUT STANDBY (${nonInvStreak}/${reqLockStreak}D < 1.00)`;
      t1BadgeZh = `T+1 执行指令：止盈后 5D 静默待命（解除倒挂 ${nonInvStreak}/${reqLockStreak} 天 · 100% QQQ）`;
      t1TitleEn = `Real-Time Stress ${stressIdx}% (${stressLblEn}) · Post-TP Lockout Freezes Re-Entry Until VIX/VIX3M < 1.00 Holds for 5 Consecutive Days (${nonInvStreak}/5)`;
      t1TitleZh = `实时危机压力 ${stressIdx}%（${stressLblZh}）· 崩盘止盈后静默锁死中，须等 VIX/VIX3M < 1.00 连续满 5 天（当前 ${nonInvStreak}/5）才允许再买`;
    } else if (redlineBlocked || !baseVixOk) {
      t1BadgeEn = `T+1 EXEC: STANDBY (100% QQQ · VIX ${vixNow.toFixed(1)} > 20 GATE FREEZE)`;
      t1BadgeZh = `T+1 执行指令：空盾待命（100% 满仓 QQQ · VIX ${vixNow.toFixed(1)} > 20 高波门控禁追贵盾）`;
      t1TitleEn = `Real-Time Stress ${stressIdx}% (${stressLblEn}) · ${profLblEn} Low-Vol Gate ${Math.round(prob)}% (VIX ${vixNow.toFixed(1)} > 20 / VXN ${vxn.toFixed(1)} Freezes Chasing Expensive Puts — Hold 100% QQQ Uncapped)`;
      t1TitleZh = `实时危机压力 ${stressIdx}%（${stressLblZh}）· ${profLblZh}低波买盾分 ${Math.round(prob)}%（VIX ${vixNow.toFixed(1)} > 20 / VXN ${vxn.toFixed(1)} 冻结禁追买高价 Put —— 100% QQQ 零损耗待弹）`;
    } else {
      t1BadgeEn = 'T+1 EXEC: STANDBY · ZERO TACTICAL DRAG (100% QQQ CRUISE)';
      t1BadgeZh = 'T+1 执行指令：静默待命 · 100% 满仓 QQQ 复利巡航';
      t1TitleEn = `Real-Time Stress ${stressIdx}% (${stressLblEn}) · ${profLblEn} Low-Vol Entry Gate ${Math.round(prob)}% (< 35% Threshold) — 100% QQQ Compounding`;
      t1TitleZh = `实时危机压力 ${stressIdx}%（${stressLblZh}）· ${profLblZh}低波买盾分 ${Math.round(prob)}%（低于 35% 开仓线）—— 100% QQQ 顺风复利`;
    }
  }

  const tauCalc = entryDte / 365.0;
  const tauBase = HARDCODED_BASE_DTE / 365.0;
  const k10 = cl * 0.9;
  const k15 = cl * 0.85;
  const k20 = cl * 0.8;
  const iv10 = evalSkewIv(cl, k10, tauCalc, rCur, qCur, vxn, coeffs);
  const iv15 = evalSkewIv(cl, k15, tauCalc, rCur, qCur, vxn, coeffs);
  const iv20 = evalSkewIv(cl, k20, tauCalc, rCur, qCur, vxn, coeffs);
  const iv15Base = evalSkewIv(cl, k15, tauBase, rCur, qCur, vxn, coeffs);
  const mid10 = bsmPrice(cl, k10, tauCalc, rCur, qCur, iv10, 'put');
  const mid15 = bsmPrice(cl, k15, tauCalc, rCur, qCur, iv15, 'put');
  const mid20 = bsmPrice(cl, k20, tauCalc, rCur, qCur, iv20, 'put');
  const mid15Base = bsmPrice(cl, k15, tauBase, rCur, qCur, iv15Base, 'put');
  const slipEff = fillModeCur === 'ibkr_limit' ? IBKR_LIMIT_FRAC * OPT_SLIP : OPT_SLIP;
  const ask10Ref = mid10 * (1.0 + slipEff) + OPT_COMM_PER_SH;
  const ask15 = mid15 * (1.0 + slipEff) + OPT_COMM_PER_SH;
  const ask20 = mid20 * (1.0 + slipEff) + OPT_COMM_PER_SH;
  const ask15Base = mid15Base * (1.0 + slipEff) + OPT_COMM_PER_SH;
  const skewRatio = iv20 / Math.max(iv10, 1e-6);
  const favorable20 = skewRatio <= 1.18;
  const selAsk = putOtm === 'otm20' ? ask20 : ask15;
  const selK = putOtm === 'otm20' ? k20 : k15;
  const sampleNav1000 = 1000.0 * cl;
  const budget1000 = sampleNav1000 * HARDCODED_M7_BUDGET_PCT;
  const baseBudget1000 = sampleNav1000 * HARDCODED_BASE_BUDGET_PCT;
  const contracts1000 = budget1000 / Math.max(selAsk, 1e-6) / 100.0;
  const baseContracts1000 = baseBudget1000 / Math.max(ask15Base, 1e-6) / 100.0;

  const rollFormulaEn = isAdaptive
    ? ' · Hard Roll: P1/P2 & Book B 125D->75D, CTA M4 90D->30D'
    : isRoll50
      ? ' · Salvage/Roll at <= 50 DTE'
      : '';
  const rollFormulaZh = isAdaptive
    ? ' · 硬换规则：P1/P2 与 B账本 125D->75D、CTA(M4) 90D->30D'
    : isRoll50
      ? ' · 剩 <=50 DTE 残值滚仓/平仓'
      : '';

  const sizingCalc = {
    qqq_spot: r2(cl),
    vix: r2(vixNow),
    vxn: r2(vxn),
    dte: entryDte,
    roll_dte: rollDte,
    base_dte: HARDCODED_BASE_DTE,
    base_roll_dte: HARDCODED_BASE_ROLL_DTE,
    base_budget_pct: 0.2,
    m7_budget_pct: 1.25,
    fill_mode: fillModeCur,
    roll_mode: effRollMode,
    selected_otm: putOtm,
    formula_en: `Hard-Coded Fixed-% Sizing: Book B Floor = 0.20% NAV (125D -15% OTM, VIX<=20) · Book M Tactical = 1.25% NAV / Slot (${entryDte}D ${otmLbl})${rollFormulaEn}`,
    formula_zh: `写死双账本固定预算：B账本常态基底 = 0.20% 净值（125D -15% OTM，VIX<=20）· M账本战术槽 = 1.25% 净值/槽（${entryDte}D ${otmLbl}）${rollFormulaZh}`,
    ref_otm10: { otm_pct: 10, strike: r2(k10), iv_pct: r2(iv10 * 100.0), mid_sh: r2(mid10), ask_sh: r2(ask10Ref) },
    otm15: {
      otm_pct: 15,
      strike: r2(k15),
      iv_pct: r2(iv15 * 100.0),
      mid_sh: r2(mid15),
      ask_sh: r2(ask15),
      base_125d_ask_sh: r2(ask15Base),
    },
    otm20: { otm_pct: 20, strike: r2(k20), iv_pct: r2(iv20 * 100.0), mid_sh: r2(mid20), ask_sh: r2(ask20) },
    skew_ratio_20_10: r3(skewRatio),
    skew_switch_threshold: 1.18,
    favorable_otm20_skew: favorable20,
    skew_tip_en: favorable20
      ? `Tail Skew Favorable: IV(-20%)/IV(-10%) = ${skewRatio.toFixed(3)} <= 1.18 — locked ruleset uses -15% OTM (1.05xK Near-ITM TP).`
      : `Steep Tail Skew: IV(-20%)/IV(-10%) = ${skewRatio.toFixed(3)} > 1.18 — locked -15% OTM avoids overpaying deep-tail skew.`,
    skew_tip_zh: favorable20
      ? `当前偏度比 IV(-20%)/IV(-10%) = ${skewRatio.toFixed(3)} <= 1.18（写死规则统一采用 -15% OTM 配合 1.05×K 准实值止盈）。`
      : `尾部偏度较陡：IV(-20%)/IV(-10%) = ${skewRatio.toFixed(3)} > 1.18 —— 写死默认 -15% OTM 规避深虚值高溢价。`,
    default_qqq_shares: 1000,
    model_qqq_shares: r2(Number(m7Sim.summary.final_shares ?? 1000)),
    sample_1000sh_nav_usd: r2(sampleNav1000),
    sample_1000sh_budget_usd: r2(budget1000),
    sample_1000sh_base_budget_usd: r2(baseBudget1000),
    sample_1000sh_base_strike: r2(k15),
    sample_1000sh_base_ask: r2(ask15Base),
    sample_1000sh_base_contracts: r2(baseContracts1000),
    sample_1000sh_selected_strike: r2(selK),
    sample_1000sh_selected_ask: r2(selAsk),
    sample_1000sh_contracts: r2(contracts1000),
  };

  const tpSpec = M7_TP_SPECS[m7TpMode] ?? M7_TP_SPECS.standard;
  const rollRuleEn = isAdaptive
    ? '; else hard-roll/exit at DTE <= 75 (Book B & Non-CTA 125D) or DTE <= 30 (CTA M4 90D); after any TP, lock all re-entries until 5 consecutive days VIX/VIX3M < 1.00.'
    : isRoll50
      ? '; else at DTE <= 50 salvage residual; after any TP, lock re-entries for 5 consecutive days VIX/VIX3M < 1.00.'
      : '.';
  const rollRuleZh = isAdaptive
    ? '；未止盈则在 B账本/非CTA槽 DTE<=75、CTA(M4)槽 DTE<=30 硬换/退出；一旦触发止盈，双账本锁定禁买直至连续 5 天 VIX/VIX3M < 1.00。'
    : isRoll50
      ? '；未止盈且 DTE <= 50 时回收残值；止盈后连续 5 天 VIX/VIX3M < 1.00 才恢复买盾。'
      : '。';
  const tpRuleEn =
    (m7TpMode === 'itm_tp'
      ? 'Exit 100% at T+1 Close when EOD (VIX/VIX3M >= 1.10 AND QQQ <= Strike Kp) OR VIX >= 45 OR (Late DTE & Put Mid >= 5x Cost)'
      : 'Exit 100% at T+1 Close when EOD (VIX/VIX3M >= 1.10 AND QQQ <= 1.05 x Strike Kp) OR VIX >= 45 OR (DTE <= 60/45 & Put Mid >= 5x Cost)') +
    rollRuleEn;
  const tpRuleZh =
    (m7TpMode === 'itm_tp'
      ? '收盘满足（VIX/VIX3M >= 1.10 且 QQQ <= 行权价 Kp）或 VIX >= 45 或（临期中间价 >= 5 倍成本）次日 100% 出清换股'
      : '收盘满足（VIX/VIX3M >= 1.10 且 QQQ <= 1.05×Kp 准实值）或 VIX >= 45 极值恐慌 或（DTE <= 60/45 且中间价 >= 5 倍成本）次日 100% 出清换股') +
    rollRuleZh;

  const tpSlotsLive = [];
  const nearItmOpenRows = [];
  for (const tr of allOpenTr) {
    const kpTr = Number(tr.kp);
    const nearKTr = r2(kpTr * nearItmMult);
    const remTr = Number(tr.rem_dte);
    const trRd = Number(tr.roll_dte || 0);
    const isBaseT = String(tr.book || 'm7') === 'base';
    const fiveXCapTr = isBaseT ? 60 : fiveXDte;
    const isItm = cl <= kpTr;
    const isNearItm = cl <= kpTr * nearItmMult;
    const tpVixOk = (vr >= 1.1 && isNearItm) || vixNow >= HARDCODED_EXTREME_VIX_TP;
    const tp5xOk = remTr <= fiveXCapTr && Number(tr.mtm_put_val_sh) >= Number(tr.tp_target_5x_sh);
    const rollDue = Boolean(trRd > 0 && remTr <= trRd && !tpVixOk && !tp5xOk);
    tpSlotsLive.push({
      book: isBaseT ? 'base' : 'm7',
      book_label_en: tr.book_label_en || (isBaseT ? 'Book B · 0.20% Base' : 'Book M · 1.25% M7G'),
      book_label_zh: tr.book_label_zh || (isBaseT ? 'B账本 · 0.20%常态基底' : 'M账本 · 1.25%战术M7G'),
      slot_num: tr.slot_num,
      occSymbol: tr.occSymbol || '',
      entry_date: tr.entry_date,
      exp_date: tr.exp_date,
      rem_dte: remTr,
      roll_dte: trRd,
      days_to_roll: trRd > 0 ? Math.max(0, remTr - trRd) : null,
      days_to_roll50: trRd > 0 ? Math.max(0, remTr - trRd) : null,
      roll50_due: rollDue,
      kp: kpTr,
      near_itm_strike_105: nearKTr,
      spot_vs_kp_pct: r2((cl / kpTr - 1.0) * 100.0),
      is_itm: isItm,
      is_near_itm: isNearItm,
      entry_ask_sh: tr.entry_put_ask_sh,
      current_mid_sh: tr.mtm_put_val_sh,
      target_5x_mid_sh: tr.tp_target_5x_sh,
      roi_mult: tr.roi_mult,
      mtm_pnl_usd: tr.mtm_pnl_usd,
      vix_leg_met: tpVixOk,
      five_x_leg_met: tp5xOk,
      pending_tp: Boolean(tr.pending_tp),
      tp_reason: tr.tp_reason || '',
    });
    nearItmOpenRows.push({
      book: isBaseT ? 'base' : 'm7',
      slot_num: tr.slot_num,
      occSymbol: tr.occSymbol || '',
      kp: kpTr,
      near_itm_strike_105: nearKTr,
      spot_le_near_itm: isNearItm,
      rem_dte: remTr,
      roi_mult: tr.roi_mult,
      triggered: Boolean(tpVixOk || tp5xOk),
    });
  }

  const nearItmTpRule = {
    tp_mode: m7TpMode,
    vix_now: r2(vixNow),
    vix_extreme: HARDCODED_EXTREME_VIX_TP,
    vix_extreme_met: vixNow >= HARDCODED_EXTREME_VIX_TP,
    vix_ratio_now: r3(vr),
    vix_ratio_min: 1.1,
    vix_ratio_met: vr >= 1.1,
    near_itm_mult: nearItmMult,
    qqq_spot_now: r2(cl),
    simulated_next_kp: r2(selK),
    simulated_next_near_itm_px: r2(selK * nearItmMult),
    formula_en: '(VIX/VIX3M >= 1.10 & QQQ <= 1.05×K) OR VIX >= 45 OR Late >= 5x -> 100% Clear & Reload QQQ',
    formula_zh: '(VIX/VIX3M >= 1.10 且 QQQ <= 1.05×K 准实值) 或 VIX >= 45 或 临期 >=5x -> 100% 底部出清抄底 QQQ',
    open_tranches: nearItmOpenRows,
  };

  const tpMonitor = {
    tp_mode: m7TpMode,
    tp_code: tpSpec.code,
    roll_mode: effRollMode,
    five_x_max_dte: fiveXDte,
    roll_dte: rollDte,
    label_en: tpSpec.label_en,
    label_zh: tpSpec.label_zh,
    rule_en: tpRuleEn,
    rule_zh: tpRuleZh,
    vix_now: r2(vixNow),
    vix_extreme_target: HARDCODED_EXTREME_VIX_TP,
    vix_extreme_met: vixNow >= HARDCODED_EXTREME_VIX_TP,
    vix_ratio_now: r3(vr),
    vix_ratio_target: 1.1,
    vix_ratio_met: vr >= 1.1,
    near_itm_mult: nearItmMult,
    qqq_spot_now: r2(cl),
    simulated_next_slot_kp: r2(selK),
    simulated_next_slot_near_itm_px: r2(selK * nearItmMult),
    simulated_next_slot_5x_mid: r2(5.0 * selAsk),
    open_slots: tpSlotsLive,
  };

  const m0AthOk = ddPct >= -5.0;
  const m0AdOk = Boolean(m0Enabled && adBelow);
  const m0ScOk = Boolean(m0Enabled && sc >= 4);
  const m0VgOk = vxn <= 22.0;
  const m0Trig = Boolean(sigDay.M0);
  const m0Sensor = Boolean(m0Enabled && m0AthOk && (m0AdOk || m0ScOk));
  let m0Met = 0;
  let m0Status = 'CALM';
  let m0HintEn = `Breadth healthy & macro lights ${sc}/6 — calm regime`;
  let m0HintZh = `市场宽度健康且宏观六灯 ${sc}/6 —— 平静巡航`;
  if (!m0Enabled) {
    m0Met = 0;
    m0Status = 'DISABLED_M0_OFF';
    m0HintEn = 'M0 Six-Lights baseline switch disabled by user';
    m0HintZh = '用户已手动关闭 M0 六灯基线开关';
  } else if (m0Trig) {
    m0Met = Number(m0AthOk) + Number(m0AdOk) + Number(m0ScOk);
    m0Status = 'ARMED_BUY';
    m0HintEn = 'Near-ATH fragility active & VXN <= 22 — contributing +35% to P1';
    m0HintZh = '高位顶背离确认且 VXN <= 22 —— 已为 P1 贡献 +35% 买盾分';
  } else if (m0Sensor && !m0VgOk) {
    m0Met = Number(m0AthOk) + Number(m0AdOk) + Number(m0ScOk);
    m0Status = 'SENSOR_RED_VOL_BLOCKED';
    m0HintEn = `Breadth/Macro warning lit near highs · Blocked by VXN ${vxn.toFixed(1)} > 22.0`;
    m0HintZh = `高位宽度/六灯预警已亮 · 因 VXN ${vxn.toFixed(1)} > 22.0 暂禁追买`;
  } else if (m0AdOk || m0ScOk) {
    m0Met = Number(m0AthOk) + Number(m0AdOk) + Number(m0ScOk);
    m0Status = 'WARMING_UP';
    m0HintEn = `Macro/AD warning lit (${m0Met}/3) · M0 only arms near highs (QQQ ${fmtSigned(ddPct, 1)}% < -5% ATH)`;
    m0HintZh = `宽度/六灯已亮 (${m0Met}/3) · M0 仅在距前高 -5% 内潜伏（当前 ${fmtSigned(ddPct, 1)}%）`;
  } else if (sc === 3) {
    m0Met = 1;
    m0Status = 'WARMING_UP';
    m0HintEn = `Macro lights warming (${sc}/6) · Needs >=4/6 lights or AD < 50DMA`;
    m0HintZh = `宏观六灯预热中 (${sc}/6) · 需亮满 >=4/6 灯或 AD 跌破 50DMA`;
  }

  const m6RspOk = rspSmaV > 0 && rspSpyV < rspSmaV;
  const m6IwmOk = (iwmSmaV > 0 && iwmQqqV < iwmSmaV) || (m0Enabled && adBelow);
  const m6DefOk = defRet20Pct >= 2.5;
  const m6VgOk = vxn <= 25.0 && vr <= 0.92;
  const m6Trig = Boolean(sigDay.M6);
  const m6Sensor = Boolean(m6RspOk && m6IwmOk && m6DefOk);
  const m6Met = Number(m6RspOk) + Number(m6IwmOk) + Number(m6DefOk);
  let m6Status = 'CALM';
  let m6HintEn = 'Equal-weight, small-caps & tech leadership intact (0/3)';
  let m6HintZh = '等权、小盘与科技领涨结构完好（0/3 平静）';
  if (m6Trig) {
    m6Status = 'ARMED_BUY';
    m6HintEn = 'All 3 breadth + defensive rotation checks lit in low vol (+20%)';
    m6HintZh = '宽度恶化 + 防御轮动 3/3 全亮且低波达标（+20% 买盾分）';
  } else if (m6Sensor && !m6VgOk) {
    m6Status = 'SENSOR_RED_VOL_BLOCKED';
    m6HintEn = `Breadth + defensive rotation 3/3 lit · Vol gate VXN ${vxn.toFixed(1)} / VIX/3M ${vr.toFixed(3)} freezes chasing`;
    m6HintZh = '宽度恶化与防御抢跑 3/3 预警已亮 · 因高波红线暂缓追高买贵盾';
  } else if (m6Met > 0) {
    m6Status = 'WARMING_UP';
    const missEn = [];
    const missZh = [];
    if (!m6RspOk) {
      missEn.push('RSP/SPY<SMA50');
      missZh.push('等权走弱');
    }
    if (!m6IwmOk) {
      missEn.push('IWM/QQQ<SMA50');
      missZh.push('小盘走弱');
    }
    if (!m6DefOk) {
      missEn.push('Def/XLK>=+2.5%');
      missZh.push('防御轮动>=+2.5%');
    }
    m6HintEn = `Breadth/Rotation ${m6Met}/3 lit · Awaiting ${missEn.join(' & ')} (& VXN<=25)`;
    m6HintZh = `宽度/防御已亮 ${m6Met}/3 · 待触发${missZh.join('、')}（且低波达标）`;
  }

  const m2CoreA = skewP75V > 0 && vvixP75V > 0 && skew10V >= skewP75V && vvixV >= vvixP75V;
  const m2CoreB = vrJ5V >= 0.06 && vvixV >= 100.0;
  const m2VgOk = vxn <= 24.0 && vr <= 1.02;
  const m2Trig = isCore3 ? false : Boolean(sigDay.M2);
  const m2Sensor = isCore3 ? false : Boolean(m2Trig || (m2CoreA && vr >= 0.85) || (m2CoreB && vr >= 0.92));
  const m2Met = isCore3
    ? 0
    : Number(Boolean(sigDay.M2_silent_tail) || m2CoreA) +
      Number(Boolean(sigDay.M2_term_inflection) || m2CoreB);
  let m2Status = 'CALM';
  let m2HintEn = 'SKEW & VVIX below tail alert thresholds (0/2)';
  let m2HintZh = 'SKEW 偏度与 VVIX 均未触发买尾异动（0/2 平静）';
  if (isCore3) {
    m2Status = 'DISABLED_IN_CORE3';
    m2HintEn = 'Omitted in Core-3 Minimal (switch to Full M7 Shield to enable)';
    m2HintZh = '精简 3 核模式下已关闭（切换全套 M7 护盾可启用外生预警）';
  } else if (m2Trig) {
    m2Status = 'ARMED_BUY';
    m2HintEn = 'Options desk skew/VVIX tail warning active in calm IV (+20%)';
    m2HintZh = '期权台偏度/VVIX 买尾预警在低波区触发（+20% 买盾分）';
  } else if (m2Sensor && !m2VgOk) {
    m2Status = 'SENSOR_RED_VOL_BLOCKED';
    m2HintEn = `Options tail stress ${m2Met}/2 active · High-IV gate (VXN ${vxn.toFixed(1)} > 24) blocks chasing`;
    m2HintZh = `期权台尾部异动 ${m2Met}/2 已亮 · 因高波门控（VXN ${vxn.toFixed(1)} > 24）禁追高`;
  } else if (m2Met > 0) {
    m2Status = 'WARMING_UP';
    m2HintEn = `Tail skew/VVIX warming (${m2Met}/2) · Awaiting calm term-structure window`;
    m2HintZh = `偏度/VVIX 异动预热 (${m2Met}/2) · 等待期限结构落入低波击球区`;
  }

  const m5CurOk = hmmPV >= 0.55;
  const m5FreshOk = hmmP5V < 0.4;
  const m5VgOk = vxn <= 24.0 && vr < 1.02;
  const m5Trig = isCore3 ? false : Boolean(sigDay.M5);
  const m5Sensor = isCore3 ? false : Boolean(m5CurOk && m5FreshOk);
  const m5Met = isCore3 ? 0 : m5CurOk && m5FreshOk ? 2 : m5CurOk || hmmPV >= 0.25 ? 1 : 0;
  let m5Status = 'CALM';
  let m5HintEn = `Hamilton stress probability ${(hmmPV * 100.0).toFixed(1)}% < 55% — calm regime`;
  let m5HintZh = `因果 HMM 高压后验概率 ${(hmmPV * 100.0).toFixed(1)}% < 55% —— 平静低波态`;
  if (isCore3) {
    m5Status = 'DISABLED_IN_CORE3';
    m5HintEn = 'Omitted in Core-3 Minimal (switch to Full M7 Shield to enable)';
    m5HintZh = '精简 3 核模式下已关闭（切换全套 M7 护盾可启用外生预警）';
  } else if (m5Trig) {
    m5Status = 'ARMED_BUY';
    m5HintEn = 'Fresh HMM stress regime jump in calm IV (+20%)';
    m5HintZh = '因果 HMM 初入高压跃迁且低波达标（+20% 买盾分）';
  } else if (m5Sensor && !m5VgOk) {
    m5Status = 'SENSOR_RED_VOL_BLOCKED';
    m5HintEn = `Fresh HMM regime jump 2/2 lit · High-IV gate (VXN ${vxn.toFixed(1)}) blocks chasing`;
    m5HintZh = `HMM 状态跃迁 2/2 已亮 · 因高波红线（VXN ${vxn.toFixed(1)}）暂禁追买`;
  } else if (m5CurOk && !m5FreshOk) {
    m5Status = 'WARMING_UP';
    m5HintEn = `HMM already in persistent stress (${(hmmPV * 100.0).toFixed(0)}% · 1/2) · M5 only fires on fresh jump (P_t-5 < 40%)`;
    m5HintZh = `HMM 已处于持续高压态 (${(hmmPV * 100.0).toFixed(0)}% · 1/2) · M5 仅在初入跃迁瞬间（5日前<40%）买盾`;
  } else if (m5Met > 0) {
    m5Status = 'WARMING_UP';
    m5HintEn = `HMM stress rising (${(hmmPV * 100.0).toFixed(1)}%) · Needs >= 55% with VXN <= 24`;
    m5HintZh = `HMM 高压概率抬头 (${(hmmPV * 100.0).toFixed(1)}%) · 达 >=55% 且 VXN<=24 触发`;
  }

  const m4Below200 = sma200V > 0 && cl < sma200V;
  const m4Ewmac = ewmacV < 0.0;
  const m4Ema20 = ema20V > 0 && cl > ema20V;
  const m4VgOk = vxn <= 27.0 && vr <= 0.88;
  const m4Trig = Boolean(sigDay.M4);
  const m4Sensor = Boolean(m4Below200 && m4Ewmac && m4Ema20);
  const m4Met = m4Below200 || m4Ewmac ? Number(m4Below200) + Number(m4Ewmac) + Number(m4Ema20) : 0;
  let m4Status = 'CALM';
  let m4HintEn = `Uptrend intact above SMA200 ($${sma200V.toFixed(1)}) & EWMAC >= 0`;
  let m4HintZh = `牛市主趋势完好（站稳 200DMA $${sma200V.toFixed(1)} 且 EWMAC>=0）`;
  if (m4Trig) {
    m4Status = 'ARMED_BUY';
    m4HintEn = 'Bear rally above EMA20 with cheap IV — buying Put shield (+35%)';
    m4HintZh = '熊市死猫跳上穿 EMA20 且波动率回落 —— 触发买盾（+35%）';
  } else if (m4Sensor && !m4VgOk) {
    m4Status = 'SENSOR_RED_VOL_BLOCKED';
    m4HintEn = `Bear bounce 3/3 met · Waiting for IV crush (VXN ${vxn.toFixed(1)}<=27 & VIX/3M ${vr.toFixed(3)}<=0.88)`;
    m4HintZh = '熊市反抽 3/3 已满足 · 等待波动率回落（VXN<=27 且 VIX/3M<=0.88）再低买';
  } else if (m4Below200 && m4Ewmac && !m4Ema20) {
    m4Status = 'WARMING_UP';
    m4HintEn = `Bear trend broken (2/3) · Awaiting bounce > EMA20 ($${ema20V.toFixed(1)}) & VXN <= 27`;
    m4HintZh = `趋势已破位 2/3 · 等待反抽 EMA20 ($${ema20V.toFixed(1)}) 且 VXN <= 27`;
  } else if (m4Met > 0) {
    m4Status = 'WARMING_UP';
    m4HintEn = `Trend weakening (${m4Met}/3) · Needs QQQ < SMA200 ($${sma200V.toFixed(1)}), EWMAC < 0 & > EMA20`;
    m4HintZh = `趋势转弱预热 (${m4Met}/3) · 需跌破 200DMA ($${sma200V.toFixed(1)}) 且 EWMAC<0 后反抽 EMA20`;
  }

  const m3Hyg = hygSmaV > 0 && hygV < hygSmaV;
  const m3Baa = baaROpt !== null && baaRV >= 0.15;
  const m3Macro = (dgs2JOpt !== null && dgs2JV >= 0.4) || (nfciJOpt !== null && nfciJV >= 0.1);
  const m3VgOk = vxn <= 26.0 && vr <= 0.92;
  const m3Trig = isCore3 ? false : Boolean(sigDay.M3);
  const m3Sensor = isCore3 ? false : Boolean(m3Hyg && (m3Baa || m3Macro));
  const m3Met = isCore3 ? 0 : Number(m3Hyg) + Number(m3Baa) + Number(m3Macro);
  let m3Status = 'CALM';
  let m3HintEn = 'Credit spreads & financial conditions benign (0/3)';
  let m3HintZh = '高收益债利差与金融条件平稳（0/3 平静）';
  if (isCore3) {
    m3Status = 'DISABLED_IN_CORE3';
    m3HintEn = 'Omitted in Core-3 Minimal (switch to Full M7 Shield to enable)';
    m3HintZh = '精简 3 核模式下已关闭（切换全套 M7 护盾可启用信用雷达）';
  } else if (m3Trig) {
    m3Status = 'ARMED_BUY';
    m3HintEn = 'Credit spread + macro stress lit in low vol (+20%)';
    m3HintZh = '信用利差与宏观紧缩共振且低波达标（+20% 买盾分）';
  } else if (m3Sensor && !m3VgOk) {
    m3Status = 'SENSOR_RED_VOL_BLOCKED';
    m3HintEn = `Credit/Macro ${m3Met}/3 warning lit · High-vol redline pauses chasing expensive puts`;
    m3HintZh = `信用与宏观 ${m3Met}/3 预警已亮 · 因高波红线暂缓追高买贵盾`;
  } else if (m3Met > 0) {
    m3Status = 'WARMING_UP';
    if (!m3Hyg) {
      m3HintEn = `Macro leg lit (${m3Met}/3) · Needs HYG/LQD < SMA50 (${hygSmaV.toFixed(4)})`;
      m3HintZh = `宏观分项已亮 (${m3Met}/3) · 待 HYG/LQD 跌破 50DMA (${hygSmaV.toFixed(4)})`;
    } else {
      m3HintEn = `HYG/LQD weak (${m3Met}/3) · Needs Baa >=+15bp, 2Y >=+40bp or NFCI >=+0.10`;
      m3HintZh = `高收益债走弱 (${m3Met}/3) · 待 Baa走阔>=15bp 或 2Y>=40bp / NFCI>=0.10`;
    }
  }

  const pillars = [
    {
      id: 'P1',
      title_en: 'Pillar 1 · Calm-Top Fragility',
      title_zh: '第一支柱 P1 · 高位脆弱与顶背离',
      subtitle_en: 'Detects stealth breadth decay & defensive rotation near highs while IV is cheap',
      subtitle_zh: '捕捉指数高位横盘期内部宽度恶化与防御板块暗中抢跑（低波潜伏买盾）',
      score: Math.round(p1),
      cap: 45,
      disabled_in_core3: false,
      modules: [
        {
          id: 'M0',
          name_en: 'M0 Six Lights Baseline',
          name_zh: 'M0 六灯基线开关',
          points: 35,
          earned_points: m0Trig ? 35 : 0,
          triggered: m0Trig,
          raw_triggered: Boolean(sigDay.M0),
          sensor_triggered: m0Sensor,
          readiness_met: m0Met,
          readiness_total: 3,
          status_code: m0Status,
          next_trigger_hint_en: m0HintEn,
          next_trigger_hint_zh: m0HintZh,
          pluggable: true,
          enabled: m0Enabled,
          disabled_in_core3: false,
          vol_gate_passed: m0VgOk,
          vol_gate_en: `VXN ${vxn.toFixed(2)} <= 22.0`,
          vol_gate_zh: `VXN ${vxn.toFixed(2)} <= 22.0 低波门控`,
          metrics: [
            {
              label_en: 'QQQ vs ATH',
              label_zh: 'QQQ 距历史前高',
              value: `${fmtSigned(ddPct, 2)}% ($${cl.toFixed(2)})`,
              threshold: '>= -5.00% (0.95*ATH)',
              passed: m0AthOk,
            },
            {
              label_en: 'A-D Line < SMA50',
              label_zh: '腾落线 AD < 50DMA',
              value: `${adDiffInt >= 0 ? '+' : ''}${adDiffInt.toLocaleString('en-US')}`,
              threshold: '< 0',
              passed: m0AdOk,
            },
            {
              label_en: 'Macro Crisis Lights',
              label_zh: '宏观六灯亮灯数',
              value: `${sc} / 6`,
              threshold: '>= 4 / 6',
              passed: m0ScOk,
            },
          ],
        },
        {
          id: 'M6',
          name_en: 'M6 Breadth + Defensive Rotation',
          name_zh: 'M6 宽度恶化 + 防御轮动',
          points: 20,
          earned_points: m6Trig ? 20 : 0,
          triggered: m6Trig,
          raw_triggered: Boolean(sigDay.M6),
          sensor_triggered: m6Sensor,
          readiness_met: m6Met,
          readiness_total: 3,
          status_code: m6Status,
          next_trigger_hint_en: m6HintEn,
          next_trigger_hint_zh: m6HintZh,
          pluggable: false,
          enabled: true,
          disabled_in_core3: false,
          vol_gate_passed: m6VgOk,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=25 & VIX/3M ${vr.toFixed(3)}<=0.92`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=25 且 VIX/3M ${vr.toFixed(3)}<=0.92`,
          metrics: [
            {
              label_en: 'RSP/SPY vs SMA50',
              label_zh: '等权 RSP/SPY vs 50DMA',
              value: `${rspSpyV.toFixed(4)} vs ${rspSmaV.toFixed(4)}`,
              threshold: '< SMA50',
              passed: m6RspOk,
            },
            {
              label_en: 'IWM/QQQ (<SMA50 or AD)',
              label_zh: '小盘 IWM/QQQ (<50DMA 或 AD弱)',
              value: `${iwmQqqV.toFixed(4)} vs ${iwmSmaV.toFixed(4)}`,
              threshold: `< SMA50${m0Enabled ? ' or AD<50D' : ''}`,
              passed: m6IwmOk,
            },
            {
              label_en: '(XLP+XLU+XLV)/XLK 20D',
              label_zh: '防御/科技 20日超额轮动',
              value: `${fmtSigned(defRet20Pct, 2)}%`,
              threshold: '>= +2.50%',
              passed: m6DefOk,
            },
          ],
        },
      ],
    },
    {
      id: 'P2',
      title_en: 'Pillar 2 · Exogenous Shock Ignition',
      title_zh: '第二支柱 P2 · 外生黑天鹅启爆',
      subtitle_en: isCore3
        ? 'Off in Core-3 Minimal (omits exogenous shock sensors M2 & M5 for low-frequency purity)'
        : 'Requires dual-sensor consensus (M2 + M5 = 40% >= 35%) to catch sudden shocks like 2020-01-28',
      subtitle_zh: isCore3
        ? '精简 3 核模式下已关闭（剔除外生预警 M2 & M5，专注低频高赔率主趋势崩盘）'
        : '要求期权台偏度与因果 HMM 双传感器共振（20+20=40% >= 35%），精准捕获 2020-01-28 等突发黑天鹅',
      score: Math.round(p2),
      cap: isCore3 ? 0 : 40,
      disabled_in_core3: isCore3,
      modules: [
        {
          id: 'M2',
          name_en: 'M2 Options Desk Warning',
          name_zh: 'M2 期权台尾部预警',
          points: 20,
          earned_points: m2Trig ? 20 : 0,
          triggered: m2Trig,
          raw_triggered: Boolean(sigDay.M2),
          sensor_triggered: m2Sensor,
          readiness_met: m2Met,
          readiness_total: 2,
          status_code: m2Status,
          next_trigger_hint_en: m2HintEn,
          next_trigger_hint_zh: m2HintZh,
          pluggable: false,
          enabled: !isCore3,
          disabled_in_core3: isCore3,
          vol_gate_passed: m2VgOk,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=24 & VIX/3M ${vr.toFixed(3)}<=1.02`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=24 且 VIX/3M ${vr.toFixed(3)}<=1.02`,
          metrics: [
            {
              label_en: 'A) Silent Tail (SKEW10 & VVIX)',
              label_zh: 'A) 静默买尾 (SKEW10 & VVIX>=P75)',
              value: `SKEW ${skew10V.toFixed(1)}/${skewP75V.toFixed(1)} · VVIX ${vvixV.toFixed(1)}/${vvixP75V.toFixed(1)}`,
              threshold: '>=252D P75 & 0.85<=V/V3M<=0.98',
              passed: Boolean(sigDay.M2_silent_tail) || m2CoreA,
            },
            {
              label_en: 'B) Term Inflection (5D Jump)',
              label_zh: 'B) 期限拐点 (5日跃升 & VVIX>=100)',
              value: `Δ5D ${fmtSigned(vrJ5V, 3)} · VVIX ${vvixV.toFixed(1)}`,
              threshold: '0.92..1.02 & Δ>=+0.06 & VVIX>=100',
              passed: Boolean(sigDay.M2_term_inflection) || m2CoreB,
            },
          ],
        },
        {
          id: 'M5',
          name_en: 'M5 Causal HMM Regime Transition',
          name_zh: 'M5 因果 HMM 状态跃迁',
          points: 20,
          earned_points: m5Trig ? 20 : 0,
          triggered: m5Trig,
          raw_triggered: Boolean(sigDay.M5),
          sensor_triggered: m5Sensor,
          readiness_met: m5Met,
          readiness_total: 2,
          status_code: m5Status,
          next_trigger_hint_en: m5HintEn,
          next_trigger_hint_zh: m5HintZh,
          pluggable: false,
          enabled: !isCore3,
          disabled_in_core3: isCore3,
          vol_gate_passed: m5VgOk,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=24 & VIX/3M ${vr.toFixed(3)}<1.02`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=24 且 VIX/3M ${vr.toFixed(3)}<1.02`,
          metrics: [
            {
              label_en: 'Hamilton P_t(Stress)',
              label_zh: '当前高压态后验概率 P_t',
              value: `${(hmmPV * 100.0).toFixed(1)}%`,
              threshold: '>= 55.0%',
              passed: m5CurOk,
            },
            {
              label_en: '5D Prior P_{t-5}(Stress)',
              label_zh: '5日前后验概率 P_{t-5}（新鲜跃迁）',
              value: `${(hmmP5V * 100.0).toFixed(1)}%`,
              threshold: '< 40.0%',
              passed: m5FreshOk,
            },
          ],
        },
      ],
    },
    {
      id: 'P3',
      title_en: 'Pillar 3 · Bear Continuation & Credit Crunch',
      title_zh: '第三支柱 P3 · 熊市延续与信用紧缩',
      subtitle_en: 'Buys cheap puts on bear-market dead-cat rallies (>EMA20 while <SMA200 & EWMAC<0) + lagged FRED credit stress',
      subtitle_zh: '专抓 2022 式慢熊死猫跳自满期（跌破年线且 EWMAC<0 但反弹上穿 EMA20 压低波动率）叠加滞后信用压力',
      score: Math.round(p3),
      cap: isCore3 ? 35 : 45,
      disabled_in_core3: false,
      modules: [
        {
          id: 'M4',
          name_en: 'M4 CTA Bear-Rally Complacency',
          name_zh: 'M4 CTA 熊市反弹自满',
          points: 35,
          earned_points: m4Trig ? 35 : 0,
          triggered: m4Trig,
          raw_triggered: Boolean(sigDay.M4),
          sensor_triggered: m4Sensor,
          readiness_met: m4Met,
          readiness_total: 3,
          status_code: m4Status,
          next_trigger_hint_en: m4HintEn,
          next_trigger_hint_zh: m4HintZh,
          pluggable: false,
          enabled: true,
          disabled_in_core3: false,
          vol_gate_passed: m4VgOk,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=27 & VIX/3M ${vr.toFixed(3)}<=0.88`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=27 且 VIX/3M ${vr.toFixed(3)}<=0.88`,
          metrics: [
            {
              label_en: 'QQQ < SMA200',
              label_zh: '熊市主趋势 QQQ < 200DMA',
              value: `$${cl.toFixed(2)} vs $${sma200V.toFixed(2)}`,
              threshold: '< SMA200',
              passed: m4Below200,
            },
            {
              label_en: '3-Speed EWMAC (16/32/64)',
              label_zh: '三速 EWMAC 趋势均值',
              value: fmtSigned(ewmacV, 2),
              threshold: '< 0.00',
              passed: m4Ewmac,
            },
            {
              label_en: 'Bear Bounce QQQ > EMA20',
              label_zh: '死猫跳反弹 QQQ > EMA20',
              value: `$${cl.toFixed(2)} vs $${ema20V.toFixed(2)}`,
              threshold: '> EMA20',
              passed: m4Ema20,
            },
          ],
        },
        {
          id: 'M3',
          name_en: 'M3 Credit & Macro Stress (FRED PIT)',
          name_zh: 'M3 信用利差与宏观压力 (FRED 严格滞后)',
          points: 20,
          earned_points: m3Trig ? 20 : 0,
          triggered: m3Trig,
          raw_triggered: Boolean(sigDay.M3),
          sensor_triggered: m3Sensor,
          readiness_met: m3Met,
          readiness_total: 3,
          status_code: m3Status,
          next_trigger_hint_en: m3HintEn,
          next_trigger_hint_zh: m3HintZh,
          pluggable: false,
          enabled: !isCore3,
          disabled_in_core3: isCore3,
          vol_gate_passed: m3VgOk,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=26 & VIX/3M ${vr.toFixed(3)}<=0.92`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=26 且 VIX/3M ${vr.toFixed(3)}<=0.92`,
          metrics: [
            {
              label_en: 'HYG/LQD < SMA50',
              label_zh: '高收益/投资级 HYG/LQD < 50DMA',
              value: `${hygV.toFixed(4)} vs ${hygSmaV.toFixed(4)}`,
              threshold: '< SMA50',
              passed: m3Hyg,
            },
            {
              label_en: 'BAA10Y (+1d lag) 63D Widening',
              label_zh: 'Baa利差 (+1日滞后) 63D走阔',
              value: `${baaV.toFixed(2)}% (${fmtSigned(baaROpt !== null ? baaRV * 100.0 : 0.0, 0)}bp)`,
              threshold: '>= +15bp (+0.15)',
              passed: m3Baa,
            },
            {
              label_en: 'DGS2 (+1d) 63D / NFCI (+5d) 20D',
              label_zh: '2Y美债(+1日)63D / NFCI(+5日)20D',
              value: `2Y ${fmtSigned(dgs2JOpt !== null ? dgs2JV * 100.0 : 0.0, 0)}bp · NFCI ${fmtSigned(nfciJOpt !== null ? nfciJV : 0.0, 2)}`,
              threshold: '2Y>=+40bp OR NFCI>=+0.10',
              passed: m3Macro,
            },
          ],
        },
      ],
    },
  ];

  const allModsFlat = pillars.flatMap(p => p.modules);
  const sensorRedCount = allModsFlat.filter(m => m.enabled && m.sensor_triggered).length;
  const volBlockedSensorCount = allModsFlat.filter(m => m.status_code === 'SENSOR_RED_VOL_BLOCKED').length;
  const warmingCount = allModsFlat.filter(m => m.status_code === 'WARMING_UP').length;

  const dataFreshness = {
    yahoo_eod_date: d,
    fred_baa_date: String(featRow?.baa_obs_date || ''),
    fred_baa_lag_days: 1,
    fred_dgs2_date: String(featRow?.dgs2_obs_date || ''),
    fred_dgs2_lag_days: 1,
    fred_nfci_date: String(featRow?.nfci_obs_date || ''),
    fred_nfci_lag_days: 5,
    ad_line_date: String(row.ad_line_date || d),
    is_pit_replay: Boolean(isPitReplay || row._is_pit_replay),
  };

  return {
    as_of_date: d,
    strategy_id: strategyId,
    profile: isCore3 ? 'core3_adaptive' : 'full_m7_adaptive',
    fill_mode: fillModeCur,
    put_otm: putOtm,
    m7_tp_mode: m7TpMode,
    roll_mode: effRollMode,
    m0_enabled: m0Enabled,
    hardcoded_ruleset: { ...HARDCODED_RULESET_SPEC, fill_mode: fillModeCur },
    book_b_vix_gate: bookBVixGate,
    post_tp_lockout: postTpLockoutBlock,
    near_itm_tp_rule: nearItmTpRule,
    crisis_prob: Math.round(prob),
    p1_score: Math.round(p1),
    p2_score: Math.round(p2),
    p3_score: Math.round(p3),
    live_stress_index: stressIdx,
    live_stress_level: stressPack.live_stress_level,
    live_stress_label_en: stressLblEn,
    live_stress_label_zh: stressLblZh,
    live_stress_breakdown: stressPack.live_stress_breakdown,
    sensor_red_count: sensorRedCount,
    vol_blocked_sensor_count: volBlockedSensorCount,
    warming_count: warmingCount,
    data_freshness: dataFreshness,
    target_slots: targetSlots,
    active_slots: activeSlots,
    base_active_slots: baseActiveSlots,
    max_slots: maxSlots,
    triggered_modules: modsActive,
    trigger_code: modsActive.length ? trigCode : 'NONE',
    tier_rule_en: isCore3
      ? 'Book B: 0.20% NAV (VIX<=20, 125D->75D) + Book M Core-3 (1.25% NAV/slot): M0=35% (1) · M0+M6=45% (2) · M4=35% (1) · M0+M4=70% (3)'
      : 'Book B: 0.20% NAV (VIX<=20, 125D->75D) + Book M Full M7G (1.25% NAV/slot): <35%=0 · 35-44%=1 · 45-64%=2 · >=65%=3 Slots',
    tier_rule_zh: isCore3
      ? 'B账本：0.20%净值(VIX<=20, 125D->75D) + M账本精简3核(1.25%/槽)：M0=35%(1槽) · M0+M6=45%(2槽) · M4=35%(1槽) · M0+M4=70%(3槽)'
      : 'B账本：0.20%净值(VIX<=20, 125D->75D) + M账本全套M7G(1.25%/槽)：<35%=0槽 · 35–44%=1槽 · 45–64%=2槽 · >=65%=3槽满配',
    redline: {
      blocked: redlineBlocked,
      vxn: r2(vxn),
      vxn_max: 27.0,
      vxn_ok: vxnRedOk,
      vix_ratio: r3(vr),
      vix_ratio_max: 1.02,
      vix_ratio_ok: vrRedOk,
      label_en: redlineBlocked
        ? `REDLINE BLOCKED (VXN ${vxn.toFixed(1)} > 27 or VIX/3M ${vr.toFixed(3)} >= 1.02)`
        : `REDLINE CLEAR (VXN ${vxn.toFixed(1)} <= 27 & VIX/3M ${vr.toFixed(3)} < 1.02)`,
      label_zh: redlineBlocked
        ? `红线禁开生效（VXN ${vxn.toFixed(1)} > 27 或 VIX/3M ${vr.toFixed(3)} >= 1.02）`
        : `风控红线安全（VXN ${vxn.toFixed(1)} <= 27 且 VIX/3M ${vr.toFixed(3)} < 1.02）`,
    },
    cooldown: {
      required_days: reqGap,
      days_since_last_entry: daysSinceLast,
      last_entry_date: lastEntryDateStr,
      passed: cooldownPassed,
      label_en:
        daysSinceLast === null
          ? `No open slots (${reqGap}D cooldown ready)`
          : `${daysSinceLast}D since ${lastEntryDateStr} (Req >= ${reqGap}D: ${cooldownPassed ? 'READY' : 'WAIT'})`,
      label_zh:
        daysSinceLast === null
          ? `当前无在途槽位（${reqGap}天阶梯冷却已就绪）`
          : `距上槽 ${lastEntryDateStr} 已过 ${daysSinceLast} 天（要求 >= ${reqGap} 天：${cooldownPassed ? '已就绪' : '冷却中'}）`,
    },
    t1_action: {
      code: t1Code,
      tone: t1Tone,
      badge_en: t1BadgeEn,
      badge_zh: t1BadgeZh,
      title_en: t1TitleEn,
      title_zh: t1TitleZh,
    },
    sizing_calculator: sizingCalc,
    tp_monitor: tpMonitor,
    pillars,
  };
}

// ============================================================================
// Pure-JS Causal M7 Signal + Hamilton Forward Filter for Daily Live EOD Refresh
// ============================================================================

function quantileLinear(vals, q) {
  const s = vals.slice().sort((a, b) => a - b);
  const n = s.length;
  if (!n) return NaN;
  if (n === 1) return s[0];
  const pos = (n - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  if (lo === hi) return s[lo];
  const frac = pos - lo;
  return s[lo] * (1.0 - frac) + s[hi] * frac;
}

function meanTail(arr, win) {
  if (arr.length < win) return null;
  let sum = 0.0;
  for (let i = arr.length - win; i < arr.length; i += 1) {
    const v = arr[i];
    if (v === null || v === undefined || !Number.isFinite(v)) return null;
    sum += v;
  }
  return sum / win;
}

function stdTailDdof1(arr, win) {
  if (arr.length < win || win < 2) return null;
  const mu = meanTail(arr, win);
  if (mu === null) return null;
  let sq = 0.0;
  for (let i = arr.length - win; i < arr.length; i += 1) sq += (arr[i] - mu) ** 2;
  return Math.sqrt(Math.max(0.0, sq / (win - 1)));
}

function hamiltonStepJS(stateP, xRow, A, means, vars) {
  const pred = [
    stateP[0] * A[0][0] + stateP[1] * A[1][0],
    stateP[0] * A[0][1] + stateP[1] * A[1][1],
  ];
  const logp = [0.0, 0.0];
  for (let k = 0; k < 2; k += 1) {
    let lp = Math.log(Math.max(pred[k], 1e-300));
    for (let d = 0; d < xRow.length; d += 1) {
      const v = Math.max(vars[k][d], 1e-6);
      const diff = xRow[d] - means[k][d];
      lp += -0.5 * (Math.log(2.0 * Math.PI * v) + (diff * diff) / v);
    }
    logp[k] = lp;
  }
  const m = Math.max(logp[0], logp[1]);
  const w0 = Math.exp(logp[0] - m);
  const w1 = Math.exp(logp[1] - m);
  const s = w0 + w1;
  return [w0 / s, w1 / s];
}

function alignFredLagWithMeta(fredMap, calDates, idx, lagDays) {
  const srcIdx = Math.max(0, idx - lagDays);
  const targetDate = calDates[srcIdx];
  let bestDate = '';
  let bestVal = null;
  if (fredMap && typeof fredMap === 'object') {
    for (const [dt, val] of Object.entries(fredMap)) {
      if (dt <= targetDate && dt > bestDate && Number.isFinite(val)) {
        bestDate = dt;
        bestVal = val;
      }
    }
  }
  return { value: bestVal, obsDate: bestDate };
}

function alignFredLagForIndex(fredMap, calDates, idx, lagDays) {
  return alignFredLagWithMeta(fredMap, calDates, idx, lagDays).value;
}

function fmtSignedFixed(val, dec = 1) {
  return `${val >= 0 ? '+' : ''}${val.toFixed(dec)}`;
}

function fmtSignedInt(val) {
  const n = Math.round(val);
  return `${n >= 0 ? '+' : ''}${n}`;
}

function buildSixCrisisLightsJS({
  dgs2,
  dgs2Lo,
  dgs2Ma,
  dff,
  dffLo,
  sig1,
  baa,
  baaLo,
  baaMa,
  sig2,
  ad,
  adMa63,
  pct200Frac,
  pct200HiFrac,
  sig3,
  cop,
  copHi,
  copMa,
  sig4,
  dc,
  dcLo,
  dcMa,
  sig5,
  yc,
  ycHi,
  nfci,
  nfciLo,
  sig6,
}) {
  const dgs2Bps = Math.round((dgs2 - dgs2Lo) * 100.0);
  const dffBps = Math.round((dff - dffLo) * 100.0);
  const baaBps = Math.round((baa - baaLo) * 100.0);
  const baaRel = baaLo > 0 ? (baa / baaLo - 1.0) * 100.0 : 0.0;
  const pct200 = pct200Frac * 100.0;
  const pct200Hi = pct200HiFrac * 100.0;
  const pct200Drop = pct200Hi - pct200;
  const copDd = copHi > 0 ? (cop / copHi - 1.0) * 100.0 : 0.0;
  const dcGain = dcLo > 0 ? (dc / dcLo - 1.0) * 100.0 : 0.0;
  const ycFlatBps = Math.round((ycHi - yc) * 100.0);
  const nfciChg = nfci - nfciLo;
  const adStr = Math.round(ad).toLocaleString('en-US');
  const adMa63Str = Math.round(adMa63).toLocaleString('en-US');

  return [
    {
      key: 'sig1_fed',
      index: 1,
      lit: Boolean(sig1),
      name_en: 'Fed Policy & Front-End Rates Tightening',
      name_zh: '联储政策与前端利率紧缩',
      short_en: 'Fed / 2Y Yield',
      short_zh: '前端利率紧缩',
      reading_value: `2Y ${dgs2.toFixed(2)}% (${fmtSignedInt(dgs2Bps)} bps)`,
      secondary_value: `DFF ${dff.toFixed(2)}% (${fmtSignedInt(dffBps)} bps)`,
      threshold_en: '2Y >= +50 bps off 12M low & > 63DMA, OR Fed Funds >= +20 bps',
      threshold_zh: '2Y 美债较12月低点回升 >= 50bp 且高于63日均线，或联邦基金利率抬升 >= 20bp',
      diagnostic_en: `2Y UST at ${dgs2.toFixed(2)}% vs 12M low ${dgs2Lo.toFixed(2)}% (63DMA ${dgs2Ma.toFixed(2)}%); Fed Funds ${dff.toFixed(2)}%.`,
      diagnostic_zh: `2Y 美债 ${dgs2.toFixed(2)}%（较12月低点 ${dgs2Lo.toFixed(2)}% 抬升 ${fmtSignedInt(dgs2Bps)}bp，63DMA ${dgs2Ma.toFixed(2)}%）；DFF ${dff.toFixed(2)}%。`,
    },
    {
      key: 'sig2_credit',
      index: 2,
      lit: Boolean(sig2),
      name_en: 'Corporate Credit Spread Widening',
      name_zh: '企业信用利差走阔',
      short_en: 'Baa-10Y Credit',
      short_zh: '信用利差走阔',
      reading_value: `${baa.toFixed(2)}% (${fmtSignedFixed(baaRel, 1)}%)`,
      secondary_value: `${fmtSignedInt(baaBps)} bps vs 12M low`,
      threshold_en: "Moody's Baa-10Y widens >= +20 bps or >= +12% off 12M low & > 63DMA",
      threshold_zh: '穆迪 Baa-10Y 利差较12月低点走阔 >= 20bp 或相对走阔 >= 12%，且高于63日均线',
      diagnostic_en: `Baa-10Y spread at ${baa.toFixed(2)}% vs 12M tightest ${baaLo.toFixed(2)}% (${fmtSignedFixed(baaRel, 1)}%, 63DMA ${baaMa.toFixed(2)}%).`,
      diagnostic_zh: `Baa-10Y 信用利差 ${baa.toFixed(2)}%（较12月最低 ${baaLo.toFixed(2)}% 相对走阔 ${fmtSignedFixed(baaRel, 1)}%，高于 63DMA ${baaMa.toFixed(2)}%）。`,
    },
    {
      key: 'sig3_breadth',
      index: 3,
      lit: Boolean(sig3),
      name_en: 'Market Breadth & >200DMA Breakdown',
      name_zh: '全美市场宽度与年线占比塌缩',
      short_en: 'Breadth / >200D',
      short_zh: '市场宽度塌缩',
      reading_value: `${pct200.toFixed(1)}% >200D (-${pct200Drop.toFixed(1)}pp)`,
      secondary_value: `AD ${adStr} vs 63D ${adMa63Str}`,
      threshold_en: 'US Liquid AD Line < 63DMA & < 12M high AND Stocks >200DMA down >= 8pp',
      threshold_zh: '全美高流动性普通股 AD Line 跌破63日均线，且站上200日均线个股占比回落 >= 8个百分点',
      diagnostic_en: `Only ${pct200.toFixed(1)}% of liquid stocks above 200DMA (down ${pct200Drop.toFixed(1)}pp from ${pct200Hi.toFixed(1)}% 12M peak); AD < 63DMA.`,
      diagnostic_zh: `仅 ${pct200.toFixed(1)}% 股票站上200DMA（较12月峰值 ${pct200Hi.toFixed(1)}% 骤降 ${pct200Drop.toFixed(1)}pp），AD 跌破 63DMA。`,
    },
    {
      key: 'sig4_copper',
      index: 4,
      lit: Boolean(sig4),
      name_en: 'Dr. Copper Industrial Demand Breakdown',
      name_zh: '铜博士实体工业需求破位',
      short_en: 'Dr. Copper',
      short_zh: '铜博士破位',
      reading_value: `$${cop.toFixed(2)}/lb (${fmtSignedFixed(copDd, 1)}%)`,
      secondary_value: `63DMA $${copMa.toFixed(2)}/lb`,
      threshold_en: 'HG Copper falls <= -10% off 12M high AND trades below 63DMA',
      threshold_zh: 'COMEX 铜价较过去12个月高点回撤 >= 10% 且跌破 63 日均线',
      diagnostic_en: `Copper at $${cop.toFixed(3)}/lb, ${copDd.toFixed(1)}% below 12M high $${copHi.toFixed(3)} and below 63DMA $${copMa.toFixed(3)}.`,
      diagnostic_zh: `铜价报 $${cop.toFixed(2)}/磅，较12月高点 $${copHi.toFixed(2)} 下跌 ${Math.abs(copDd).toFixed(1)}% 且位于 63DMA ($${copMa.toFixed(2)}) 下方。`,
    },
    {
      key: 'sig5_defensive',
      index: 5,
      lit: Boolean(sig5),
      name_en: 'Defensives Outperforming Cyclicals',
      name_zh: '防御板块显著跑赢周期板块',
      short_en: 'DEF / CYC Ratio',
      short_zh: '防御跑赢周期',
      reading_value: `${dc.toFixed(3)} (${fmtSignedFixed(dcGain, 1)}%)`,
      secondary_value: `63DMA ${dcMa.toFixed(3)}`,
      threshold_en: '(XLU+XLP+XLV)/(XLY+XLI+XLB+XLF) rises >= +5% off 12M low & > 63DMA',
      threshold_zh: '公用事业/必选/医疗相对可选/工业/材料/金融比值较12月低点反弹 >= 5% 且站上63日均线',
      diagnostic_en: `Defensive/Cyclical ratio at ${dc.toFixed(3)}, +${dcGain.toFixed(1)}% off 12M trough ${dcLo.toFixed(3)} (63DMA ${dcMa.toFixed(3)}).`,
      diagnostic_zh: `防御/周期相对强弱比升至 ${dc.toFixed(3)}，较12月低点 ${dcLo.toFixed(3)} 走强 +${dcGain.toFixed(1)}%（高于 63DMA ${dcMa.toFixed(3)}）。`,
    },
    {
      key: 'sig6_macro',
      index: 6,
      lit: Boolean(sig6),
      name_en: 'Yield Curve & Financial Conditions Squeeze',
      name_zh: '收益率曲线熊平与金融条件收紧',
      short_en: '10Y-2Y / NFCI',
      short_zh: '曲线与金融条件',
      reading_value: `10Y-2Y ${fmtSignedFixed(yc, 2)}% (-${ycFlatBps}bp)`,
      secondary_value: `NFCI ${fmtSignedFixed(nfci, 3)} (${fmtSignedFixed(nfciChg, 3)})`,
      threshold_en: '10Y-2Y flattens >= 40 bps (<0.75%) OR < 0%, OR Chicago Fed NFCI +0.12',
      threshold_zh: '10Y-2Y 利差较12月峰值走平 >= 40bp（且<0.75%）或倒挂 < 0%，或芝加哥联储 NFCI 收紧 >= 0.12',
      diagnostic_en: `10Y-2Y at ${fmtSignedFixed(yc, 2)}% (flattened ${ycFlatBps} bps from 12M high ${fmtSignedFixed(ycHi, 2)}%); NFCI ${fmtSignedFixed(nfci, 3)}.`,
      diagnostic_zh: `10Y-2Y 报 ${fmtSignedFixed(yc, 2)}%（较12月高点 ${fmtSignedFixed(ycHi, 2)}% 熊平压窄 ${ycFlatBps}bp）；NFCI 报 ${fmtSignedFixed(nfci, 3)}。`,
    },
  ];
}

export function extendM7LiveFromFeed(rawData, liveFeed, requestedAsOf) {
  const tail = rawData.m7_live_tail_state;
  if (!tail || !Array.isArray(tail.tail_dates) || !tail.tail_dates.length) return null;
  const lastArtifactDate = tail.tail_dates[tail.tail_dates.length - 1];
  if (requestedAsOf <= lastArtifactDate) return null;

  const qqqMap = liveFeed?.yahoo?.QQQ;
  if (!qqqMap || typeof qqqMap.keys !== 'function') return null;
  const newDates = [...qqqMap.keys()]
    .filter(d => d > lastArtifactDate && d <= requestedAsOf && Number.isFinite(qqqMap.get(d)?.close) && qqqMap.get(d).close > 0)
    .sort();
  if (!newDates.length) return null;

  const calDates = tail.tail_dates.slice();
  const yf = {};
  for (const k of Object.keys(YF_SYMBOL_MAP)) {
    yf[k] = (tail.yf_tail?.[k] ?? []).slice();
  }
  const fredRaw = {
    BAA10Y: { ...(tail.fred_tail?.BAA10Y ?? {}) },
    DGS2: { ...(tail.fred_tail?.DGS2 ?? {}) },
    NFCI: { ...(tail.fred_tail?.NFCI ?? {}) },
    DFF: { ...(tail.fred_tail?.DFF ?? {}) },
    T10Y2Y: { ...(tail.fred_tail?.T10Y2Y ?? {}) },
  };
  for (const fid of Object.keys(FRED_SIX_LIGHTS_LAGS)) {
    const incoming = liveFeed?.fred?.[fid];
    if (incoming && typeof incoming === 'object') {
      for (const [dt, val] of Object.entries(incoming)) {
        if (Number.isFinite(val)) fredRaw[fid][dt] = val;
      }
    }
  }

  const slTail = tail.six_lights_tail ?? null;
  const slDgs2 = (slTail?.dgs2 ?? []).slice();
  const slDff = (slTail?.dff ?? []).slice();
  const slBaa = (slTail?.baa10y ?? []).slice();
  const slCopper = (slTail?.copper ?? []).slice();
  const slDefCyc = (slTail?.def_cyc ?? []).slice();
  const slT10y2y = (slTail?.t10y2y ?? []).slice();
  const slNfci = (slTail?.nfci ?? []).slice();
  const slScores = (slTail?.scores ?? []).slice();
  const breadthFb = slTail?.breadth_fallback ?? null;

  let ema20 = Number(tail.ewm_state.ema20);
  let e16 = Number(tail.ewm_state.e16);
  let e32 = Number(tail.ewm_state.e32);
  let e64 = Number(tail.ewm_state.e64);
  let e128 = Number(tail.ewm_state.e128);
  let e256 = Number(tail.ewm_state.e256);
  const cnt = tail.welford_4d.count.slice();
  const meanAcc = tail.welford_4d.mean.slice();
  const m2Acc = tail.welford_4d.m2.slice();
  let stateP = tail.hmm.state_p.slice();
  const pHmmTail = tail.p_hmm_tail.slice();
  const { xlp0, xlu0, xlv0, xlk0 } = {
    xlp0: Number(tail.base_2013.XLP),
    xlu0: Number(tail.base_2013.XLU),
    xlv0: Number(tail.base_2013.XLV),
    xlk0: Number(tail.base_2013.XLK),
  };

  // Precompute skew10 & lagged FRED history over existing tail so 252D quantiles & 63D/20D diffs work seamlessly
  const skew10Hist = [];
  for (let i = 0; i < calDates.length; i += 1) {
    if (i < 9) skew10Hist.push(null);
    else {
      let s = 0;
      for (let k = i - 9; k <= i; k += 1) s += yf.SKEW[k];
      skew10Hist.push(s / 10.0);
    }
  }
  const baaLagHist = calDates.map((_, idx) => alignFredLagForIndex(fredRaw.BAA10Y, calDates, idx, 1));
  const dgs2LagHist = calDates.map((_, idx) => alignFredLagForIndex(fredRaw.DGS2, calDates, idx, 1));
  const nfciLagHist = calDates.map((_, idx) => alignFredLagForIndex(fredRaw.NFCI, calDates, idx, 5));

  const unpackColsRows = tbl => {
    const cols = tbl._cols;
    return tbl._rows.map(r => Object.fromEntries(cols.map((c, idx) => [c, r[idx]])));
  };

  const evalBars = unpackColsRows(rawData.m7_eval_bars);
  const sigM0On = unpackColsRows(rawData.m7_signals.m0on);
  const sigM0Off = unpackColsRows(rawData.m7_signals.m0off);
  const featRows = unpackColsRows(rawData.m7_feature_table);
  const newDailyRowsMeta = [];
  const sixCrisisLightsByDate = {};

  for (const d of newDates) {
    const prevCalDate = calDates[calDates.length - 1];
    calDates.push(d);
    const idx = calDates.length - 1;
    for (const k of Object.keys(YF_SYMBOL_MAP)) {
      const barObj = liveFeed?.yahoo?.[k]?.get(d);
      const prevVal = yf[k][yf[k].length - 1];
      const nextVal = Number.isFinite(barObj?.close) && barObj.close > 0 ? Number(barObj.close) : prevVal;
      yf[k].push(nextVal);
    }

    const qBar = qqqMap.get(d);
    const prevEval = evalBars[evalBars.length - 1];
    const cl = yf.QQQ[idx];
    const op = Number.isFinite(qBar?.open) && qBar.open > 0 ? Number(qBar.open) : cl;
    const vix = yf.VIX[idx];
    const vix3m = yf.VIX3M[idx];
    const vr = vix3m > 0 ? vix / vix3m : Number(prevEval.vix_ratio);
    const vxn = yf.VXN[idx];
    const vvixNow = yf.VVIX[idx];
    const runAth = Math.max(Number(prevEval.running_ath), cl);
    const ddFromAth = cl / runAth - 1.0;
    const prevVix = Number(prevEval.vix);
    const vixFalling = vix < prevVix;

    // Skew10 & 252D quantiles
    let s10 = 0.0;
    for (let k = idx - 9; k <= idx; k += 1) s10 += yf.SKEW[k];
    const skew10Now = s10 / 10.0;
    skew10Hist.push(skew10Now);
    const skewWin = skew10Hist.slice(Math.max(0, skew10Hist.length - 252)).filter(Number.isFinite);
    const skewP75Now = skewWin.length >= 126 ? quantileLinear(skewWin, 0.75) : skew10Now;
    const vvixWin = yf.VVIX.slice(Math.max(0, yf.VVIX.length - 252)).filter(Number.isFinite);
    const vvixP75Now = vvixWin.length >= 126 ? quantileLinear(vvixWin, 0.75) : vvixNow;

    // FRED lagged values + causal observation dates
    const baaMeta = alignFredLagWithMeta(fredRaw.BAA10Y, calDates, idx, 1);
    const dgs2Meta = alignFredLagWithMeta(fredRaw.DGS2, calDates, idx, 1);
    const nfciMeta = alignFredLagWithMeta(fredRaw.NFCI, calDates, idx, 5);
    const dffMeta = alignFredLagWithMeta(fredRaw.DFF, calDates, idx, 1);
    const ycMeta = alignFredLagWithMeta(fredRaw.T10Y2Y, calDates, idx, 1);
    const baaNow = baaMeta.value;
    const dgs2Now = dgs2Meta.value;
    const nfciNow = nfciMeta.value;
    baaLagHist.push(baaNow);
    dgs2LagHist.push(dgs2Now);
    nfciLagHist.push(nfciNow);

    const baaWin63 = baaLagHist.slice(Math.max(0, baaLagHist.length - 63)).filter(Number.isFinite);
    const baaMin63 = baaWin63.length >= 30 ? Math.min(...baaWin63) : null;
    const baaRise = baaNow !== null && baaMin63 !== null ? baaNow - baaMin63 : -999.0;
    const dgs2Prev63 = idx >= 63 ? dgs2LagHist[idx - 63] : null;
    const dgs2Jump = dgs2Now !== null && dgs2Prev63 !== null ? dgs2Now - dgs2Prev63 : -999.0;
    const nfciPrev20 = idx >= 20 ? nfciLagHist[idx - 20] : null;
    const nfciJump = nfciNow !== null && nfciPrev20 !== null ? nfciNow - nfciPrev20 : -999.0;

    // Dynamically recompute post-artifact Six Crisis Lights from Yahoo + FRED
    let sc = Number(prevEval.score);
    let score5d = sc;
    let lightsMask = null;
    const adLineDate = String(breadthFb?.date || prevEval.ad_line_date || lastArtifactDate);
    if (slDgs2.length > 0 && slBaa.length > 0 && slCopper.length > 0 && slDefCyc.length > 0) {
      const dgs2Cur = dgs2Now ?? slDgs2[slDgs2.length - 1];
      const dffCur = dffMeta.value ?? slDff[slDff.length - 1];
      const baaCur = baaNow ?? slBaa[slBaa.length - 1];
      const ycCur = ycMeta.value ?? slT10y2y[slT10y2y.length - 1];
      const nfciCur = nfciNow ?? slNfci[slNfci.length - 1];

      const copPrev = slCopper[slCopper.length - 1];
      const hgCur = liveFeed?.yahoo?.HG_F?.get(d)?.close;
      const hgPrev = liveFeed?.yahoo?.HG_F?.get(prevCalDate)?.close;
      const copCur =
        Number.isFinite(hgCur) && hgCur > 0 && Number.isFinite(hgPrev) && hgPrev > 0
          ? copPrev * (Number(hgCur) / Number(hgPrev))
          : copPrev;

      const dcPrev = slDefCyc[slDefCyc.length - 1];
      const cycSyms = ['XLY', 'XLI', 'XLB', 'XLF'];
      const hasLiveCyc = cycSyms.every(
        sym =>
          Number.isFinite(liveFeed?.yahoo?.[sym]?.get(d)?.close) &&
          liveFeed.yahoo[sym].get(d).close > 0 &&
          Number.isFinite(liveFeed?.yahoo?.[sym]?.get(prevCalDate)?.close) &&
          liveFeed.yahoo[sym].get(prevCalDate).close > 0,
      );
      let dcCur = dcPrev;
      if (hasLiveCyc) {
        const defSumCur = yf.XLU[idx] + yf.XLP[idx] + yf.XLV[idx];
        const defSumPrev = yf.XLU[idx - 1] + yf.XLP[idx - 1] + yf.XLV[idx - 1];
        const cycSumCur = cycSyms.reduce((s, sym) => s + Number(liveFeed.yahoo[sym].get(d).close), 0);
        const cycSumPrev = cycSyms.reduce(
          (s, sym) => s + Number(liveFeed.yahoo[sym].get(prevCalDate).close),
          0,
        );
        if (defSumPrev > 0 && cycSumCur > 0 && cycSumPrev > 0) {
          dcCur = dcPrev * ((defSumCur / cycSumCur) / (defSumPrev / cycSumPrev));
        }
      }

      slDgs2.push(dgs2Cur);
      slDff.push(dffCur);
      slBaa.push(baaCur);
      slCopper.push(copCur);
      slDefCyc.push(dcCur);
      slT10y2y.push(ycCur);
      slNfci.push(nfciCur);

      const min252 = arr => Math.min(...arr.slice(-252));
      const max252 = arr => Math.max(...arr.slice(-252));
      const ma63 = arr => meanTail(arr, Math.min(63, arr.length)) ?? arr[arr.length - 1];

      const dgs2Lo = min252(slDgs2);
      const dgs2Ma = ma63(slDgs2);
      const dffLo = min252(slDff);
      const sig1 = (dgs2Cur - dgs2Lo >= 0.5 && dgs2Cur > dgs2Ma) || dffCur - dffLo >= 0.2;

      const baaLo = min252(slBaa);
      const baaMa = ma63(slBaa);
      const sig2 =
        (baaCur - baaLo >= 0.2 || (baaLo > 0 && baaCur / baaLo - 1.0 >= 0.12)) && baaCur > baaMa;

      const sig3 = Boolean(breadthFb?.sig3_breadth ?? sc >= 6);

      const copHi = max252(slCopper);
      const copMa = ma63(slCopper);
      const sig4 = copHi > 0 && copCur / copHi - 1.0 <= -0.1 && copCur < copMa;

      const dcLo = min252(slDefCyc);
      const dcMa = ma63(slDefCyc);
      const sig5 = dcLo > 0 && dcCur / dcLo - 1.0 >= 0.05 && dcCur > dcMa;

      const ycHi = max252(slT10y2y);
      const nfciLo = min252(slNfci);
      const sig6 = (ycHi - ycCur >= 0.4 && ycCur < 0.75) || ycCur < 0.0 || nfciCur - nfciLo >= 0.12;

      lightsMask =
        (sig1 ? 1 : 0) |
        (sig2 ? 2 : 0) |
        (sig3 ? 4 : 0) |
        (sig4 ? 8 : 0) |
        (sig5 ? 16 : 0) |
        (sig6 ? 32 : 0);
      sc =
        Number(sig1) + Number(sig2) + Number(sig3) + Number(sig4) + Number(sig5) + Number(sig6);
      slScores.push(sc);
      score5d = meanTail(slScores, Math.min(5, slScores.length)) ?? sc;

      const liveLights = buildSixCrisisLightsJS({
        dgs2: dgs2Cur,
        dgs2Lo,
        dgs2Ma,
        dff: dffCur,
        dffLo,
        sig1,
        baa: baaCur,
        baaLo,
        baaMa,
        sig2,
        ad: Number(breadthFb?.ad_line ?? prevEval.ad_line ?? 0),
        adMa63: Number(breadthFb?.ad_sma63 ?? prevEval.ad_sma50 ?? 0),
        pct200Frac: Number(breadthFb?.pct_200d ?? 0),
        pct200HiFrac: Number(breadthFb?.pct200_hi252 ?? 0),
        sig3,
        cop: copCur,
        copHi,
        copMa,
        sig4,
        dc: dcCur,
        dcLo,
        dcMa,
        sig5,
        yc: ycCur,
        ycHi,
        nfci: nfciCur,
        nfciLo,
        sig6,
      });
      sixCrisisLightsByDate[d] = {
        lights: liveLights,
        score: sc,
        score_5d: r2(score5d),
        lights_mask: lightsMask,
      };
    }

    // SMA200, EMA20, 3-speed EWMAC
    const sma200Now = meanTail(yf.QQQ, 200) ?? cl;
    const stepEwm = (prev, span, x) => {
      const a = 2.0 / (span + 1.0);
      return (1.0 - a) * prev + a * x;
    };
    ema20 = stepEwm(ema20, 20, cl);
    e16 = stepEwm(e16, 16, cl);
    e32 = stepEwm(e32, 32, cl);
    e64 = stepEwm(e64, 64, cl);
    e128 = stepEwm(e128, 128, cl);
    e256 = stepEwm(e256, 256, cl);

    const diffs60 = [];
    for (let k = idx - 59; k <= idx; k += 1) diffs60.push(yf.QQQ[k] - yf.QQQ[k - 1]);
    const pxVol = stdTailDdof1(diffs60, 60);
    const ewmacNow =
      pxVol && pxVol > 0
        ? ((e16 - e64) / pxVol + (e32 - e128) / pxVol + (e64 - e256) / pxVol) / 3.0
        : 0.0;

    // HYG/LQD, RSP/SPY, IWM/QQQ, Def/Tech 20D
    const hygArr50 = [];
    const rspArr50 = [];
    const iwmArr50 = [];
    for (let k = idx - 49; k <= idx; k += 1) {
      hygArr50.push(yf.HYG[k] / Math.max(yf.LQD[k], 1e-8));
      rspArr50.push(yf.RSP[k] / Math.max(yf.SPY[k], 1e-8));
      iwmArr50.push(yf.IWM[k] / Math.max(yf.QQQ[k], 1e-8));
    }
    const hygNow = hygArr50[hygArr50.length - 1];
    const hygSma50 = meanTail(hygArr50, 50) ?? hygNow;
    const rspNow = rspArr50[rspArr50.length - 1];
    const rspSma50 = meanTail(rspArr50, 50) ?? rspNow;
    const iwmNow = iwmArr50[iwmArr50.length - 1];
    const iwmSma50 = meanTail(iwmArr50, 50) ?? iwmNow;

    const defAt = k =>
      ((yf.XLP[k] / xlp0 + yf.XLU[k] / xlu0 + yf.XLV[k] / xlv0) / 3.0) / (yf.XLK[k] / xlk0);
    const defRet20 = defAt(idx) / defAt(idx - 20) - 1.0;

    // Causal 4D Welford standardization (shift(1) before update) + Hamilton step
    const logRets20 = [];
    for (let k = idx - 19; k <= idx; k += 1) logRets20.push(Math.log(yf.QQQ[k] / yf.QQQ[k - 1]));
    const rv20Ann = (stdTailDdof1(logRets20, 20) ?? 0.15 / Math.sqrt(252.0)) * Math.sqrt(252.0);
    const raw4 = [
      Math.log(yf.QQQ[idx] / yf.QQQ[idx - 5]),
      Math.log(Math.max(rv20Ann, 0.05)),
      -Math.log(hygNow / (yf.HYG[idx - 20] / Math.max(yf.LQD[idx - 20], 1e-8))),
      vr,
    ];
    const zRow = [];
    for (let dim = 0; dim < 4; dim += 1) {
      const stdD = Math.sqrt(m2Acc[dim] / Math.max(1, cnt[dim] - 1));
      const zv = stdD > 0 ? (raw4[dim] - meanAcc[dim]) / stdD : 0.0;
      zRow.push(clip(zv, -4.5, 4.5));
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
    const hpPrev5 = pHmmTail[pHmmTail.length - 6] ?? 0.0;

    const vrPrev5 = yf.VIX[idx - 5] / Math.max(yf.VIX3M[idx - 5], 1e-6);
    const vrJ5 = vr - vrPrev5;

    const m2A = skew10Now >= skewP75Now && vvixNow >= vvixP75Now && vr >= 0.85 && vr <= 0.98;
    const m2B = vr >= 0.92 && vr <= 1.02 && vrJ5 >= 0.06 && vvixNow >= 100.0;
    const m2 = (m2A || m2B) && vxn <= 24.0;
    const m3 = hygNow < hygSma50 && (baaRise >= 0.15 || dgs2Jump >= 0.4 || nfciJump >= 0.1) && vxn <= 26.0 && vr <= 0.92;
    const m4 = cl < sma200Now && ewmacNow < 0.0 && cl > ema20 && vxn <= 27.0 && vr <= 0.88;
    const m5 = hpCur >= 0.55 && hpPrev5 < 0.4 && vxn <= 24.0 && vr < 1.02;

    const athOk = ddFromAth >= -0.05;
    const adBelow = Boolean(prevEval.ad_below50);
    const m0Raw = athOk && (adBelow || sc >= 4) && vxn <= 22.0;

    const liveStressDay = computeLiveStressIndexJS({
      hmm_p: r5(hpCur),
      vxn,
      vix_ratio: vr,
      dd_from_ath: ddFromAth,
      close: cl,
      sma200: r5(sma200Now),
      ewmac: r5(ewmacNow),
      hyg_lqd: r5(hygNow),
      hyg_sma50: r5(hygSma50),
      baa_rise63: baaRise > -900 ? r5(baaRise) : null,
      dgs2_jump63: dgs2Jump > -900 ? r5(dgs2Jump) : null,
      nfci_jump20: nfciJump > -900 ? r5(nfciJump) : null,
      def_ret20: r5(defRet20),
      rsp_spy: r5(rspNow),
      rsp_sma50: r5(rspSma50),
      iwm_qqq: r5(iwmNow),
      iwm_sma50: r5(iwmSma50),
      ad_below50: adBelow,
      vvix: r5(vvixNow),
      vvix_p75: r5(vvixP75Now),
      skew10: r5(skew10Now),
      skew_p75: r5(skewP75Now),
      vr_jump5: r5(vrJ5),
    });

    const makeSigObj = m0On => {
      const m0 = m0On ? m0Raw : false;
      const m6Small = m0On ? iwmNow < iwmSma50 || adBelow : iwmNow < iwmSma50;
      const m6 = rspNow < rspSma50 && m6Small && defRet20 >= 0.025 && vxn <= 25.0 && vr <= 0.92;
      const p1 = Math.min(45.0, (m0 ? 35.0 : 0.0) + (m6 ? 20.0 : 0.0));
      const p2 = Math.min(40.0, (m2 ? 20.0 : 0.0) + (m5 ? 20.0 : 0.0));
      const p3 = Math.min(45.0, (m4 ? 35.0 : 0.0) + (m3 ? 20.0 : 0.0));
      const prob = Math.min(100.0, p1 + p2 + p3);
      const tM7g = prob >= 65.0 ? 3 : prob >= 45.0 ? 2 : prob >= 35.0 ? 1 : 0;
      const tM7 = prob >= 35.0 ? 2 : 0;
      const mask =
        (m0 ? 1 : 0) | (m6 ? 2 : 0) | (m2 ? 4 : 0) | (m5 ? 8 : 0) | (m4 ? 16 : 0) | (m3 ? 32 : 0);
      const p1C3 = p1;
      const p2C3 = 0.0;
      const p3C3 = m4 ? 35.0 : 0.0;
      const probC3 = Math.min(100.0, p1C3 + p3C3);
      const tC3 = probC3 >= 65.0 ? 3 : probC3 >= 45.0 ? 2 : probC3 >= 35.0 ? 1 : 0;
      const maskC3 = (m0 ? 1 : 0) | (m6 ? 2 : 0) | (m4 ? 16 : 0);
      return {
        date: d,
        M0: m0,
        M6: m6,
        M2: m2,
        M2_silent_tail: m2A,
        M2_term_inflection: m2B,
        M5: m5,
        M4: m4,
        M3: m3,
        p1,
        p2,
        p3,
        crisis_prob: prob,
        target_slots_m7g: tM7g,
        target_slots_m7: tM7,
        mask,
        p1_c3: p1C3,
        p2_c3: p2C3,
        p3_c3: p3C3,
        crisis_prob_c3: probC3,
        target_slots_c3: tC3,
        mask_c3: maskC3,
        redline_blocked: vxn > 27.0 || vr >= 1.02,
        hmm_p: r4(hpCur),
        live_stress: liveStressDay.live_stress_index,
      };
    };

    const sOn = makeSigObj(true);
    const sOff = makeSigObj(false);
    sigM0On.push(sOn);
    sigM0Off.push(sOff);

    const nextEvalBar = {
      date: d,
      open: op,
      close: cl,
      dividends: 0.0,
      vxn,
      vix,
      vix3m,
      vix_ratio: vr,
      r: Number(prevEval.r),
      div_yield: Number(prevEval.div_yield),
      dd_from_ath: ddFromAth,
      score: sc,
      ad_below50: adBelow,
      vix_falling: vixFalling,
      ad_line: Number(prevEval.ad_line),
      ad_sma50: Number(prevEval.ad_sma50),
      ad_line_date: adLineDate,
      running_ath: runAth,
    };
    evalBars.push(nextEvalBar);

    const featObj = {
      date: d,
      skew10: r5(skew10Now),
      skew_p75: r5(skewP75Now),
      vvix: r5(vvixNow),
      vvix_p75: r5(vvixP75Now),
      vr_jump5: r5(vrJ5),
      hmm_p: r5(hpCur),
      hmm_p5: r5(hpPrev5),
      ewmac: r5(ewmacNow),
      ema20: r5(ema20),
      sma200: r5(sma200Now),
      hyg_lqd: r5(hygNow),
      hyg_sma50: r5(hygSma50),
      baa_lag1: baaNow !== null ? r5(baaNow) : null,
      baa_rise63: baaRise > -900 ? r5(baaRise) : null,
      dgs2_lag1: dgs2Now !== null ? r5(dgs2Now) : null,
      dgs2_jump63: dgs2Jump > -900 ? r5(dgs2Jump) : null,
      nfci_lag5: nfciNow !== null ? r5(nfciNow) : null,
      nfci_jump20: nfciJump > -900 ? r5(nfciJump) : null,
      rsp_spy: r5(rspNow),
      rsp_sma50: r5(rspSma50),
      iwm_qqq: r5(iwmNow),
      iwm_sma50: r5(iwmSma50),
      def_ret20: r5(defRet20),
      baa_obs_date: baaMeta.obsDate,
      dgs2_obs_date: dgs2Meta.obsDate,
      nfci_obs_date: nfciMeta.obsDate,
    };
    featRows.push(featObj);
    newDailyRowsMeta.push({ evalBar: nextEvalBar, sigOn: sOn, sigOff: sOff, feat: featObj, sma200Now });
  }

  return { evalBars, sigM0On, sigM0Off, featRows, newDailyRowsMeta, sixCrisisLightsByDate };
}

async function fetchYahooChart15d(symbol) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5500);
  try {
    const enc = encodeURIComponent(symbol);
    const resp = await fetch(
      `https://query1.finance.yahoo.com/v8/finance/chart/${enc}?range=15d&interval=1d`,
      { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: controller.signal },
    );
    if (!resp.ok) return null;
    const json = await resp.json();
    const res0 = json?.chart?.result?.[0];
    const ts = res0?.timestamp ?? [];
    const quote = res0?.indicators?.quote?.[0] ?? {};
    const opens = quote.open ?? [];
    const closes = quote.close ?? [];
    const out = new Map();
    for (let i = 0; i < ts.length; i += 1) {
      const c = closes[i];
      if (!Number.isFinite(c) || c <= 0) continue;
      const o = Number.isFinite(opens[i]) && opens[i] > 0 ? opens[i] : c;
      const dt = new Date(ts[i] * 1000).toISOString().slice(0, 10);
      out.set(dt, { open: o, close: c });
    }
    return out;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
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

async function fetchFredRecent(seriesId) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5500);
  try {
    const enc = encodeURIComponent(seriesId);
    const resp = await fetch(
      `https://fred.stlouisfed.org/graph/fredgraph.csv?id=${enc}&cosd=2025-06-01`,
      {
        headers: { 'User-Agent': 'Mozilla/5.0' },
        signal: controller.signal,
      },
    );
    if (!resp.ok) return null;
    const txt = await resp.text();
    return parseFredCsvText(txt);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

const liveM7Cache = { fetchedAt: 0, feed: null, inFlight: null };
const LIVE_M7_TTL_MS = 15 * 60 * 1000;

export async function getLiveM7MarketFeed() {
  const now = Date.now();
  if (liveM7Cache.feed && now - liveM7Cache.fetchedAt < LIVE_M7_TTL_MS) {
    return liveM7Cache.feed;
  }
  if (liveM7Cache.inFlight) return liveM7Cache.inFlight;

  liveM7Cache.inFlight = (async () => {
    try {
      const allYfMap = { ...YF_SYMBOL_MAP, ...YF_OPTIONAL_SIX_LIGHTS_MAP };
      const yfKeys = Object.keys(allYfMap);
      const fredKeys = Object.keys(FRED_SIX_LIGHTS_LAGS);
      const [yfResults, fredResults] = await Promise.all([
        Promise.all(yfKeys.map(k => fetchYahooChart15d(allYfMap[k]))),
        Promise.all(fredKeys.map(fid => fetchFredRecent(fid))),
      ]);
      const yahoo = {};
      yfKeys.forEach((k, idx) => {
        if (yfResults[idx]) yahoo[k] = yfResults[idx];
      });
      if (!yahoo.QQQ) return null;
      const fred = {};
      fredKeys.forEach((fid, idx) => {
        if (fredResults[idx]) fred[fid] = fredResults[idx];
      });
      const feed = { yahoo, fred };
      liveM7Cache.fetchedAt = Date.now();
      liveM7Cache.feed = feed;
      return feed;
    } finally {
      liveM7Cache.inFlight = null;
    }
  })();

  return liveM7Cache.inFlight;
}

export function normalizeLegacyExtraBarsToFeed(extraDailyBars) {
  if (!Array.isArray(extraDailyBars) || !extraDailyBars.length) return null;
  const yahoo = {
    QQQ: new Map(),
    VIX: new Map(),
    VIX3M: new Map(),
    VXN: new Map(),
  };
  for (const b of extraDailyBars) {
    if (!b || !b.date || !(Number(b.qqqClose) > 0)) continue;
    const cl = Number(b.qqqClose);
    const op = Number.isFinite(b.qqqOpen) && b.qqqOpen > 0 ? Number(b.qqqOpen) : cl;
    yahoo.QQQ.set(b.date, { open: op, close: cl });
    if (Number.isFinite(b.vixClose) && b.vixClose > 0) yahoo.VIX.set(b.date, { open: b.vixClose, close: b.vixClose });
    if (Number.isFinite(b.vix3mClose) && b.vix3mClose > 0) yahoo.VIX3M.set(b.date, { open: b.vix3mClose, close: b.vix3mClose });
    if (Number.isFinite(b.vxnClose) && b.vxnClose > 0) yahoo.VXN.set(b.date, { open: b.vxnClose, close: b.vxnClose });
  }
  return yahoo.QQQ.size > 0 ? { yahoo, fred: {} } : null;
}
