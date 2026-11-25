import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const DEFAULT_KMLM20_SEED_GZ = path.resolve(
  projectRoot,
  'server/config/crisis-observatory-kmlm20-seed.json.gz',
);

export const CRISIS_OBSERVATORY_OVERLAY_MODES = Object.freeze([
  'core_100x',
  'kmlm20_120x',
]);
export const DEFAULT_OVERLAY_MODE = 'core_100x';

export const CRISIS_OBSERVATORY_FIN_MODES = Object.freeze([
  'box_35bp',
  'ibkr_150bp',
]);
export const DEFAULT_FIN_MODE = 'box_35bp';

export const CRISIS_OBSERVATORY_KMLM_WINDOWS = Object.freeze([
  '5yr_live',
  '11yr_stitched',
]);
export const DEFAULT_KMLM_WINDOW = '5yr_live';

export const INITIAL_CAPITAL_USD = 200000.0;
export const KMLM_REBAL_FEE = 0.0005;
export const KMLM_WEIGHT = 0.20;
export const FIN_SPREAD_BOX = 0.0035;
export const FIN_SPREAD_IBKR = 0.0150;

const OVERLAY_ALIASES = Object.freeze({
  core: 'core_100x',
  '1.00x': 'core_100x',
  '1x': 'core_100x',
  baseline: 'core_100x',
  prod: 'core_100x',
  default: 'core_100x',
  kmlm: 'kmlm20_120x',
  kmlm20: 'kmlm20_120x',
  kmlm_20: 'kmlm20_120x',
  kmlm_20_hypothesis: 'kmlm20_120x',
  hypothesis: 'kmlm20_120x',
  '1.20x': 'kmlm20_120x',
  '1.2x': 'kmlm20_120x',
});

const FIN_MODE_ALIASES = Object.freeze({
  box: 'box_35bp',
  spx_box: 'box_35bp',
  mnq: 'box_35bp',
  '35bp': 'box_35bp',
  default: 'box_35bp',
  ibkr: 'ibkr_150bp',
  margin: 'ibkr_150bp',
  '150bp': 'ibkr_150bp',
});

const KMLM_WIN_ALIASES = Object.freeze({
  '5yr': '5yr_live',
  '5y': '5yr_live',
  live5y: '5yr_live',
  pure: '5yr_live',
  default: '5yr_live',
  '11yr': '11yr_stitched',
  '11y': '11yr_stitched',
  stitched: '11yr_stitched',
  full: '11yr_stitched',
});

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

export function normalizeOverlayMode(raw) {
  if (raw == null || raw === '') return DEFAULT_OVERLAY_MODE;
  const s = String(raw).trim().toLowerCase();
  if (CRISIS_OBSERVATORY_OVERLAY_MODES.includes(s)) return s;
  if (OVERLAY_ALIASES[s]) return OVERLAY_ALIASES[s];
  throw badRequest(`invalid_crisis_observatory_overlay_mode:${raw}`);
}

export function normalizeFinMode(raw) {
  if (raw == null || raw === '') return DEFAULT_FIN_MODE;
  const s = String(raw).trim().toLowerCase();
  if (CRISIS_OBSERVATORY_FIN_MODES.includes(s)) return s;
  if (FIN_MODE_ALIASES[s]) return FIN_MODE_ALIASES[s];
  throw badRequest(`invalid_crisis_observatory_fin_mode:${raw}`);
}

export function normalizeKmlmWindow(raw) {
  if (raw == null || raw === '') return DEFAULT_KMLM_WINDOW;
  const s = String(raw).trim().toLowerCase();
  if (CRISIS_OBSERVATORY_KMLM_WINDOWS.includes(s)) return s;
  if (KMLM_WIN_ALIASES[s]) return KMLM_WIN_ALIASES[s];
  throw badRequest(`invalid_crisis_observatory_kmlm_window:${raw}`);
}

const r1 = v => (Number.isFinite(v) ? Math.round(v * 10) / 10 : 0);
const r2 = v => (Number.isFinite(v) ? Math.round(v * 100) / 100 : 0);
const r3 = v => (Number.isFinite(v) ? Math.round(v * 1000) / 1000 : 0);

let cachedSeed = null;
const computedPayloadCache = new Map();

export function readKmlm20Seed(seedFile = DEFAULT_KMLM20_SEED_GZ) {
  let stat;
  try {
    stat = fs.statSync(seedFile);
  } catch {
    return null;
  }
  if (
    cachedSeed &&
    cachedSeed.file === seedFile &&
    cachedSeed.mtimeMs === stat.mtimeMs &&
    cachedSeed.size === stat.size
  ) {
    return cachedSeed.data;
  }
  try {
    const gz = fs.readFileSync(seedFile);
    const raw = zlib.gunzipSync(gz).toString('utf8');
    const parsed = JSON.parse(raw);
    computedPayloadCache.clear();
    cachedSeed = {
      file: seedFile,
      mtimeMs: stat.mtimeMs,
      size: stat.size,
      data: parsed,
    };
    return parsed;
  } catch {
    return null;
  }
}

function isoDateToDays(iso) {
  return Math.round(Date.parse(`${iso}T00:00:00Z`) / 86400000);
}

export function regTCrashToCall(weight, maintMargin) {
  const x = 1.0 - weight / ((1.0 + weight) * (1.0 - maintMargin));
  return r2(-x * 100.0);
}

export function pctChangeZeroFirst(vals) {
  const n = vals.length;
  const out = new Array(n).fill(0.0);
  for (let i = 1; i < n; i += 1) {
    const prev = vals[i - 1];
    const cur = vals[i];
    if (prev !== null && prev !== undefined && cur !== null && cur !== undefined && prev > 0.0) {
      out[i] = cur / prev - 1.0;
    }
  }
  return out;
}

export function pearsonCorrJS(xs, ys) {
  const n = Math.min(xs.length, ys.length);
  if (n < 3) return 0.0;
  let sx = 0.0;
  let sy = 0.0;
  for (let i = 0; i < n; i += 1) {
    sx += xs[i];
    sy += ys[i];
  }
  const mx = sx / n;
  const my = sy / n;
  let vx = 0.0;
  let vy = 0.0;
  let cov = 0.0;
  for (let i = 0; i < n; i += 1) {
    const dx = xs[i] - mx;
    const dy = ys[i] - my;
    vx += dx * dx;
    vy += dy * dy;
    cov += dx * dy;
  }
  const stdX = Math.sqrt(vx / n);
  const stdY = Math.sqrt(vy / n);
  if (stdX <= 1e-10 || stdY <= 1e-10) return 0.0;
  return (cov / n) / (stdX * stdY);
}

function sampleStdJS(vals) {
  const m = vals.length;
  if (m < 2) return 0.0;
  let sum = 0.0;
  for (let i = 0; i < m; i += 1) sum += vals[i];
  const mu = sum / m;
  let acc = 0.0;
  for (let i = 0; i < m; i += 1) {
    const d = vals[i] - mu;
    acc += d * d;
  }
  return Math.sqrt(acc / (m - 1));
}

function maxDrawdownJS(vals) {
  if (!vals || vals.length === 0) return 0.0;
  let pk = vals[0];
  let mdd = 0.0;
  for (let i = 0; i < vals.length; i += 1) {
    const v = vals[i];
    if (v > pk) pk = v;
    const dd = v / pk - 1.0;
    if (dd < mdd) mdd = dd;
  }
  return mdd;
}

export function buildTpAndLockoutJS(dates, vixArr, vrArr, episodes) {
  const n = dates.length;
  const dIdx = new Map();
  for (let i = 0; i < n; i += 1) dIdx.set(dates[i], i);
  const tpDayInfo = new Map();
  const lockoutMask = new Array(n).fill(false);
  for (const ep of episodes ?? []) {
    const sD = ep?.start_signal_date;
    const sI = sD && dIdx.has(sD) ? dIdx.get(sD) : ep?.start_idx;
    if (!Number.isInteger(sI) || sI < 0 || sI >= n) continue;
    const uD = ep?.unlock_eod_date;
    const uI = uD && dIdx.has(uD) ? dIdx.get(uD) : null;
    tpDayInfo.set(sI, {
      start_date: dates[sI],
      unlock_date: uD ?? null,
      unlock_idx: uI,
      vix: r2(Number(vixArr[sI] ?? 0)),
      vr: r2(Number(vrArr[sI] ?? 0)),
    });
    const endJ = uI !== null ? uI : n;
    for (let j = sI; j < endJ; j += 1) lockoutMask[j] = true;
  }
  return { tpDayInfo, lockoutMask };
}

export function simPureCtaBlueprintJS({
  dates,
  rCore,
  rQqq,
  qqqPx,
  sleeves,
  effr,
  vix,
  finSpread,
  tpDayInfo = new Map(),
  lockoutActiveByDay = [],
  mode = 'rot_vix20',
  negRule = 'strict_both',
  ddThresh = -0.12,
  reloadVix = 20.0,
  reloadTd = 60,
  feeRate = KMLM_REBAL_FEE,
}) {
  const n = dates.length;
  const dayNums = dates.map(isoDateToDays);
  const nSl = sleeves.length;
  let totW = 0.0;
  for (let k = 0; k < nSl; k += 1) totW += sleeves[k][1];

  const eq = new Float64Array(n);
  const ltv = new Float64Array(n);
  const inQqqByDay = new Uint8Array(n);
  let coreVal = INITIAL_CAPITAL_USD;
  const slVals = sleeves.map(s => INITIAL_CAPITAL_USD * s[1]);
  const slInQqq = new Array(nSl).fill(false);
  const slSavedAth = new Array(nSl).fill(0.0);
  const slRotIdx = new Array(nSl).fill(-1);
  const slPendingToQqq = new Array(nSl).fill(false);
  const slPendingToHedge = new Array(nSl).fill(false);
  const slMeta = new Array(nSl).fill(null);
  let pendingDriftRebal = false;

  let loan = INITIAL_CAPITAL_USD * totW;
  eq[0] = INITIAL_CAPITAL_USD;
  let sumSl0 = 0.0;
  for (let k = 0; k < nSl; k += 1) sumSl0 += slVals[k];
  ltv[0] = loan / Math.max(coreVal + sumSl0, 1e-6);
  let totInterest = 0.0;
  let totTurnover = 0.0;
  let rebalCnt = 0;
  const rotLog = [];

  let runAthPx = Number(qqqPx[0]);
  let runAthIdx = 0;
  const isStatic = mode === 'static_drift' || mode === 'static_qtr';

  const sumArr = arr => {
    let s = 0.0;
    for (let j = 0; j < arr.length; j += 1) s += arr[j];
    return s;
  };

  for (let i = 1; i < n; i += 1) {
    const calDays = Math.max(1, dayNums[i] - dayNums[i - 1]);
    coreVal *= 1.0 + Number(rCore[i]);
    for (let k = 0; k < nSl; k += 1) {
      slVals[k] *= 1.0 + Number(slInQqq[k] ? rQqq[i] : sleeves[k][2][i]);
    }
    const intToday = loan * Math.max(0.0, Number(effr[i - 1]) + finSpread) * (calDays / 360.0);
    loan += intToday;
    totInterest += intToday;
    let curEq = Math.max(1.0, coreVal + sumArr(slVals) - loan);

    let didRebalToday = false;
    for (let k = 0; k < nSl; k += 1) {
      if (slPendingToQqq[k] && !slInQqq[k]) {
        const traded = 2.0 * slVals[k];
        totTurnover += traded / Math.max(curEq, 1.0);
        slVals[k] = Math.max(0.0, slVals[k] * (1.0 - 2.0 * feeRate));
        slInQqq[k] = true;
        slRotIdx[k] = i;
        slPendingToQqq[k] = false;
        if (slMeta[k] !== null) {
          slMeta[k].exec_date = dates[i];
          slMeta[k].qqq_in = Number(qqqPx[i]);
          slMeta[k].asset_out = Number(sleeves[k][3][i]);
          slMeta[k].usd_rot = r2(slVals[k]);
        }
      } else if (slPendingToHedge[k] && slInQqq[k]) {
        const traded = 2.0 * slVals[k];
        totTurnover += traded / Math.max(curEq, 1.0);
        slVals[k] = Math.max(0.0, slVals[k] * (1.0 - 2.0 * feeRate));
        slInQqq[k] = false;
        slPendingToHedge[k] = false;
        if (slMeta[k] !== null) {
          const m = slMeta[k];
          const qr = (Number(qqqPx[i]) / m.qqq_in - 1.0) * 100.0;
          const ar = (Number(sleeves[k][3][i]) / m.asset_out - 1.0) * 100.0;
          m.reload_date = dates[i];
          m.hold_td = i - slRotIdx[k];
          m.qqq_hold_ret_pct = r2(qr);
          m.asset_hold_ret_pct = r2(ar);
          m.spread_pp = r2(qr - ar);
          m.est_alpha_usd = Math.round(m.usd_rot * (qr - ar) / 100.0);
          slMeta[k] = null;
        }
        curEq = Math.max(1.0, coreVal + sumArr(slVals) - loan);
        const tgtCore = curEq;
        let dTr = Math.abs(tgtCore - coreVal);
        for (let j = 0; j < nSl; j += 1) {
          dTr += Math.abs(curEq * sleeves[j][1] - slVals[j]);
        }
        totTurnover += dTr / Math.max(curEq, 1.0);
        const curEqA = Math.max(1.0, curEq - dTr * feeRate);
        coreVal = curEqA;
        for (let j = 0; j < nSl; j += 1) slVals[j] = curEqA * sleeves[j][1];
        loan = curEqA * totW;
        rebalCnt += 1;
        didRebalToday = true;
      }
    }

    const anyInQqq = slInQqq.some(Boolean);
    if (totW > 1e-8 && !anyInQqq && !didRebalToday) {
      let doRebal = false;
      if (mode === 'static_drift') {
        if (pendingDriftRebal) {
          doRebal = true;
          pendingDriftRebal = false;
        }
      } else if (i < n - 1) {
        const qCur = Math.floor((Number(dates[i].slice(5, 7)) - 1) / 3);
        const qNxt = Math.floor((Number(dates[i + 1].slice(5, 7)) - 1) / 3);
        if (qCur !== qNxt || dates[i].slice(0, 4) !== dates[i + 1].slice(0, 4)) {
          doRebal = true;
        }
      }
      if (doRebal) {
        curEq = Math.max(1.0, coreVal + sumArr(slVals) - loan);
        const tgtCore = curEq;
        let dTr = Math.abs(tgtCore - coreVal);
        for (let j = 0; j < nSl; j += 1) {
          dTr += Math.abs(curEq * sleeves[j][1] - slVals[j]);
        }
        totTurnover += dTr / Math.max(curEq, 1.0);
        const curEqA = Math.max(1.0, curEq - dTr * feeRate);
        coreVal = curEqA;
        for (let j = 0; j < nSl; j += 1) slVals[j] = curEqA * sleeves[j][1];
        loan = curEqA * totW;
        rebalCnt += 1;
      }
    }

    const slSum = sumArr(slVals);
    curEq = Math.max(1.0, coreVal + slSum - loan);
    eq[i] = curEq;
    ltv[i] = loan / Math.max(coreVal + slSum, 1e-6);
    inQqqByDay[i] = slInQqq.some(Boolean) ? 1 : 0;

    if (Number(qqqPx[i]) >= runAthPx) {
      runAthPx = Number(qqqPx[i]);
      runAthIdx = i;
    }

    if (mode === 'static_drift' && totW > 1e-8) {
      const curSlW = slSum / Math.max(curEq, 1e-6);
      if (Math.abs(curSlW - totW) >= 0.025 || Math.abs(coreVal / curEq - 1.0) >= 0.04) {
        pendingDriftRebal = true;
      }
    }

    if (!isStatic) {
      for (let k = 0; k < nSl; k += 1) {
        if (slInQqq[k] && !slPendingToHedge[k] && i > slRotIdx[k]) {
          let trigRel = false;
          if (mode === 'rot_ath') {
            trigRel = Number(qqqPx[i]) >= slSavedAth[k];
          } else if (mode === 'rot_60td') {
            trigRel = i - slRotIdx[k] >= reloadTd;
          } else if (mode === 'rot_vix20') {
            trigRel = !lockoutActiveByDay[i] && Number(vix[i]) <= reloadVix;
          } else if (mode === 'rot_vix20_or_60td') {
            trigRel =
              i - slRotIdx[k] >= reloadTd ||
              (!lockoutActiveByDay[i] && Number(vix[i]) <= reloadVix);
          }
          if (trigRel) slPendingToHedge[k] = true;
        }
      }

      if (tpDayInfo.has(i)) {
        const tPk = runAthIdx;
        const qqqDd = Number(qqqPx[i]) / Math.max(Number(qqqPx[tPk]), 1e-6) - 1.0;
        const ddOk = qqqDd <= ddThresh;
        for (let k = 0; k < nSl; k += 1) {
          if (slInQqq[k]) continue;
          const [sName, , rA, pxA] = sleeves[k];
          const aRet = Number(pxA[i]) / Math.max(Number(pxA[tPk]), 1e-6) - 1.0;
          const loC = i - tPk >= 5 ? tPk + 1 : Math.max(1, i - 19);
          const rqSeg = rQqq.slice(loC, i + 1);
          const raSeg = rA.slice(loC, i + 1);
          const corrVal = pearsonCorrJS(rqSeg, raSeg);
          const cond =
            negRule === 'strict_both'
              ? Boolean(ddOk && aRet > 0.0 && corrVal < 0.0)
              : Boolean(ddOk && corrVal < 0.0);
          let reasonTag = 'ROTATE';
          if (!cond) {
            if (!ddOk) reasonTag = 'HOLD_DD_SHALLOW';
            else if (corrVal >= 0.0) reasonTag = 'HOLD_POS_CORR';
            else reasonTag = 'HOLD_CTA_NEG_RET';
          }
          const ev = {
            tp_date: dates[i],
            ath_date: dates[tPk],
            sleeve: sName,
            qqq_dd_pct: r2(qqqDd * 100.0),
            asset_ret_pct: r2(aRet * 100.0),
            corr: r3(corrVal),
            vix_eod: r2(Number(vix[i])),
            dd_ok: ddOk,
            decision: cond ? 'ROTATE' : 'HOLD',
            reason: reasonTag,
          };
          rotLog.push(ev);
          if (cond) {
            slPendingToQqq[k] = true;
            slSavedAth[k] = runAthPx;
            slMeta[k] = ev;
          }
        }
      }
    }
  }

  const yrs = (dayNums[n - 1] - dayNums[0]) / 365.25;
  let peakLtv = 0.0;
  let sumLtv = 0.0;
  let minEqRatio = 1.0;
  let sumEq = 0.0;
  for (let i = 0; i < n; i += 1) {
    if (ltv[i] > peakLtv) peakLtv = ltv[i];
    sumLtv += ltv[i];
    const eqR = 1.0 - ltv[i];
    if (eqR < minEqRatio) minEqRatio = eqR;
    sumEq += eq[i];
  }
  const meanEq = sumEq / Math.max(n, 1);

  return {
    nav: Array.from(eq),
    ltv: Array.from(ltv),
    in_qqq_by_day: Array.from(inQqqByDay),
    peak_ltv_pct: r2(peakLtv * 100.0),
    avg_ltv_pct: r2((sumLtv / Math.max(n, 1)) * 100.0),
    min_eq_ratio_pct: r2(minEqRatio * 100.0),
    ann_interest_pct_nav: r3(((totInterest / Math.max(meanEq, 1.0)) / Math.max(yrs, 0.1)) * 100.0),
    tot_interest_usd: r2(totInterest),
    ann_turnover_pct: r1((totTurnover / Math.max(yrs, 0.1)) * 100.0),
    rebal_cnt: rebalCnt,
    rot_cnt: rotLog.filter(e => e.decision === 'ROTATE').length,
    rot_log: rotLog,
    end_in_qqq: slInQqq.some(Boolean),
    end_ltv_pct: r2(ltv[n - 1] * 100.0),
    end_loan_usd: r2(loan),
  };
}

export function calcPerfJS(dates, nav, benchNav, rfArr, extra = null) {
  const n = dates.length;
  const yrs = (isoDateToDays(dates[n - 1]) - isoDateToDays(dates[0])) / 365.25;
  const tot = nav[n - 1] / nav[0] - 1.0;
  const cagr = Math.pow(nav[n - 1] / nav[0], 1.0 / Math.max(yrs, 0.1)) - 1.0;
  const bhCagr = Math.pow(benchNav[n - 1] / benchNav[0], 1.0 / Math.max(yrs, 0.1)) - 1.0;
  const mdd = maxDrawdownJS(nav);
  const calmar = mdd < -1e-6 ? cagr / Math.abs(mdd) : 0.0;

  const rets = new Array(n - 1);
  const ex = new Array(n - 1);
  const dn = [];
  let sumEx = 0.0;
  for (let j = 1; j < n; j += 1) {
    const r = nav[j] / nav[j - 1] - 1.0;
    const e = r - Number(rfArr[j] ?? 0) / 252.0;
    rets[j - 1] = r;
    ex[j - 1] = e;
    sumEx += e;
    if (e < 0.0) dn.push(e);
  }
  const meanEx = sumEx / Math.max(ex.length, 1);
  const vol = sampleStdJS(rets) * Math.sqrt(252.0);
  const stdEx = sampleStdJS(ex);
  const sharpe = stdEx > 1e-12 ? (meanEx / stdEx) * Math.sqrt(252.0) : 0.0;
  const stdDn = dn.length > 2 ? sampleStdJS(dn) : 0.0;
  const sortino = stdDn > 1e-12 ? (meanEx / stdDn) * Math.sqrt(252.0) : 0.0;

  const yearsSet = [...new Set(dates.map(d => d.slice(0, 4)))].sort();
  const yearly = {};
  for (const ys of yearsSet) {
    const idxs = [];
    for (let i = 0; i < n; i += 1) {
      if (dates[i].startsWith(ys)) idxs.push(i);
    }
    if (idxs.length < 5) continue;
    const i0 = Math.max(0, idxs[0] - 1);
    const i1 = idxs[idxs.length - 1];
    const sub = nav.slice(i0, i1 + 1);
    const subB = benchNav.slice(i0, i1 + 1);
    const rS = (sub[sub.length - 1] / sub[0] - 1.0) * 100.0;
    const rB = (subB[subB.length - 1] / subB[0] - 1.0) * 100.0;
    yearly[ys] = {
      ret_pct: r2(rS),
      bench_ret_pct: r2(rB),
      alpha_pp: r2(rS - rB),
      mdd_pct: r2(maxDrawdownJS(sub) * 100.0),
    };
  }

  const crisisDefs = {
    '2022_BEAR': ['2021-11-19', '2022-12-30'],
    '2024_YEN': ['2024-07-10', '2024-09-10'],
    '2025_TAR': ['2025-02-19', '2025-05-15'],
    '2020_COVID': ['2020-02-12', '2020-04-30'],
  };
  const crises = {};
  for (const [cid, [sD, eD]] of Object.entries(crisisDefs)) {
    const sub = [];
    const subB = [];
    for (let i = 0; i < n; i += 1) {
      if (dates[i] >= sD && dates[i] <= eD) {
        sub.push(nav[i]);
        subB.push(benchNav[i]);
      }
    }
    if (sub.length < 5) continue;
    crises[cid] = {
      ret_pct: r2((sub[sub.length - 1] / sub[0] - 1.0) * 100.0),
      mdd_pct: r2(maxDrawdownJS(sub) * 100.0),
      bench_mdd_pct: r2(maxDrawdownJS(subB) * 100.0),
    };
  }

  const out = {
    start_date: dates[0],
    end_date: dates[n - 1],
    years: r2(yrs),
    final_nav: r2(nav[n - 1]),
    tot_ret_pct: r2(tot * 100.0),
    cagr_pct: r2(cagr * 100.0),
    excess_cagr_pp: r2((cagr - bhCagr) * 100.0),
    vol_pct: r2(vol * 100.0),
    mdd_pct: r2(mdd * 100.0),
    calmar: r3(calmar),
    sharpe: r3(sharpe),
    sortino: r3(sortino),
    yearly,
    crises,
  };
  if (extra && typeof extra === 'object') {
    for (const [k, v] of Object.entries(extra)) {
      if (k !== 'nav' && k !== 'ltv' && k !== 'in_qqq_by_day') {
        out[k] = v;
      }
    }
  }
  return out;
}

const KEY_CHART_DATES = new Set([
  '2015-08-24',
  '2015-08-25',
  '2015-10-06',
  '2018-12-20',
  '2018-12-24',
  '2020-02-19',
  '2020-03-09',
  '2020-03-20',
  '2020-12-02',
  '2020-12-03',
  '2021-12-27',
  '2022-05-18',
  '2022-05-19',
  '2022-08-11',
  '2022-12-28',
  '2024-07-10',
  '2024-08-05',
  '2025-02-19',
  '2025-04-04',
  '2025-04-08',
  '2025-12-15',
]);

function sampleSeries(dates, curvesObj, step = 3) {
  const n = dates.length;
  const idxs = [];
  for (let i = 0; i < n; i += 1) {
    if (i === 0 || i === n - 1 || i % step === 0 || KEY_CHART_DATES.has(dates[i])) {
      idxs.push(i);
    }
  }
  const series = {};
  for (const [k, arr] of Object.entries(curvesObj)) {
    series[k] = idxs.map(j => Math.round(arr[j]));
  }
  return {
    dates: idxs.map(j => dates[j]),
    series,
  };
}

// Live KMLM + NY Fed EFFR 15-minute cached fetcher
const LIVE_KMLM_TTL_MS = 15 * 60 * 1000;
let liveKmlmCache = null;
let liveKmlmFetchedAtMs = 0;
let liveKmlmInFlight = null;

async function fetchYahooSeries(symbol, timeoutMs = 4500) {
  const symUrl = encodeURIComponent(symbol);
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${symUrl}?range=2y&interval=1d&events=div,split`;
  const resp = await fetch(url, {
    headers: { 'User-Agent': 'Mozilla/5.0' },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!resp.ok) throw new Error(`yahoo_${symbol}_${resp.status}`);
  const data = await resp.json();
  const res = data?.chart?.result?.[0];
  const ts = res?.timestamp ?? [];
  const quoteClose = res?.indicators?.quote?.[0]?.close ?? [];
  const adjClose = res?.indicators?.adjclose?.[0]?.adjclose ?? quoteClose;
  const byDate = {};
  for (let i = 0; i < ts.length; i += 1) {
    const t = ts[i];
    const adj = adjClose[i] ?? quoteClose[i];
    const cl = quoteClose[i] ?? adjClose[i];
    if (!Number.isFinite(t) || !Number.isFinite(adj)) continue;
    const d = new Date(t * 1000).toISOString().slice(0, 10);
    byDate[d] = { adj: Number(adj), close: Number.isFinite(cl) ? Number(cl) : Number(adj) };
  }
  return byDate;
}

async function fetchNyFedEffrRecent(timeoutMs = 4500) {
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
      const rows = obj?.refRates ?? [];
      const byDate = {};
      for (const r of rows) {
        if (r?.effectiveDate && Number.isFinite(Number(r.percentRate))) {
          byDate[String(r.effectiveDate)] = Number(r.percentRate) / 100.0;
        }
      }
      if (Object.keys(byDate).length > 0) return byDate;
    } catch {
      // try fallback URL
    }
  }
  return null;
}

export async function getLiveKmlmEffrFeed({ force = false } = {}) {
  const now = Date.now();
  if (!force && liveKmlmCache && now - liveKmlmFetchedAtMs < LIVE_KMLM_TTL_MS) {
    return liveKmlmCache;
  }
  if (!force && liveKmlmInFlight) return liveKmlmInFlight;

  liveKmlmInFlight = (async () => {
    try {
      const [kmlm, qqq, vix, effr] = await Promise.all([
        fetchYahooSeries('KMLM').catch(() => null),
        fetchYahooSeries('QQQ').catch(() => null),
        fetchYahooSeries('^VIX').catch(() => null),
        fetchNyFedEffrRecent().catch(() => null),
      ]);
      if (!kmlm && !effr) return liveKmlmCache;
      const stampDates = [
        ...Object.keys(kmlm ?? {}),
        ...Object.keys(qqq ?? {}),
        ...Object.keys(effr ?? {}),
      ].sort();
      const feed = {
        fetchedAt: new Date().toISOString(),
        stamp: stampDates.length > 0 ? stampDates[stampDates.length - 1] : 'seed',
        kmlm,
        qqq,
        vix,
        effr,
      };
      liveKmlmCache = feed;
      liveKmlmFetchedAtMs = Date.now();
      return feed;
    } catch {
      return liveKmlmCache;
    } finally {
      liveKmlmInFlight = null;
    }
  })();

  return liveKmlmInFlight;
}

function mergeTail2026WithFeed(seedTail, seedEffrLatest, liveFeed, maxAsOf = null) {
  const mapByDate = new Map();
  const baseDates = seedTail?.dates ?? [];
  for (let i = 0; i < baseDates.length; i += 1) {
    const d = baseDates[i];
    mapByDate.set(d, {
      qqq_adj: Number(seedTail.qqq_adj[i]),
      qqq_close: Number(seedTail.qqq_adj[i]),
      kmlm_adj: Number(seedTail.kmlm_adj[i]),
      kmlm_close: Number(seedTail.kmlm_adj[i]),
      vix: Number(seedTail.vix[i]),
      effr: Number(seedTail.effr[i]),
    });
  }

  let effrLatestDate = seedEffrLatest?.effective_date ?? '2026-11-24';
  let effrLatestDecimal = Number(seedEffrLatest?.effr_pct ?? 3.88) / 100.0;

  if (liveFeed?.effr) {
    for (const [d, rateDec] of Object.entries(liveFeed.effr)) {
      if ((!maxAsOf || d <= maxAsOf) && d >= effrLatestDate && Number.isFinite(rateDec)) {
        effrLatestDate = d;
        effrLatestDecimal = rateDec;
      }
    }
  }

  if (liveFeed?.qqq && liveFeed?.kmlm) {
    const liveDates = Object.keys(liveFeed.qqq)
      .filter(d => d >= '2025-12-31' && Boolean(liveFeed.kmlm[d]))
      .sort();
    for (const d of liveDates) {
      const existing = mapByDate.get(d);
      const qObj = liveFeed.qqq[d];
      const kObj = liveFeed.kmlm[d];
      const vObj = liveFeed.vix?.[d];
      const efVal = liveFeed.effr?.[d];
      mapByDate.set(d, {
        qqq_adj: Number(qObj.adj),
        qqq_close: Number(qObj.close),
        kmlm_adj: Number(kObj.adj),
        kmlm_close: Number(kObj.close),
        vix: Number.isFinite(vObj?.close)
          ? Number(vObj.close)
          : (existing?.vix ?? 20.0),
        effr: Number.isFinite(efVal)
          ? Number(efVal)
          : (existing?.effr ?? effrLatestDecimal),
      });
    }
  }

  const sortedDates = [...mapByDate.keys()]
    .filter(d => !maxAsOf || d <= maxAsOf)
    .sort();

  // Forward-fill effr & vix cleanly
  let lastEf = effrLatestDecimal;
  let lastVx = 20.0;
  const d26 = [];
  const qqqAdj = [];
  const qqqCl = [];
  const kmlmAdj = [];
  const kmlmCl = [];
  const vixArr = [];
  const efArr = [];

  for (let i = 0; i < sortedDates.length; i += 1) {
    const d = sortedDates[i];
    const row = mapByDate.get(d);
    if (Number.isFinite(row.effr) && row.effr > 0) lastEf = row.effr;
    if (Number.isFinite(row.vix) && row.vix > 0) lastVx = row.vix;
    d26.push(d);
    qqqAdj.push(row.qqq_adj);
    qqqCl.push(row.qqq_close);
    kmlmAdj.push(row.kmlm_adj);
    kmlmCl.push(row.kmlm_close);
    vixArr.push(lastVx);
    efArr.push(lastEf);
  }

  return {
    dates: d26,
    qqq_adj: qqqAdj,
    qqq_close: qqqCl,
    kmlm_adj: kmlmAdj,
    kmlm_close: kmlmCl,
    vix: vixArr,
    effr: efArr,
    effr_latest_date: effrLatestDate,
    effr_latest_pct: r2(effrLatestDecimal * 100.0),
    is_live_fetched: Boolean(liveFeed?.kmlm || liveFeed?.effr),
    fetched_at: liveFeed?.fetchedAt ?? null,
  };
}

export function buildHypothesisKmlm20Payload({
  asOf = null,
  profile = 'full_m7_adaptive',
  fillMode = 'ibkr_limit',
  overlayMode = DEFAULT_OVERLAY_MODE,
  finMode = DEFAULT_FIN_MODE,
  kmlmWindow = DEFAULT_KMLM_WINDOW,
  m7LiveDashboard = null,
  liveMarketSnapshot = null,
  liveKmlmFeed = null,
  seedFile = DEFAULT_KMLM20_SEED_GZ,
} = {}) {
  const seed = readKmlm20Seed(seedFile);
  if (!seed || !seed.d11) return null;

  const normOverlay = normalizeOverlayMode(overlayMode);
  const normFin = normalizeFinMode(finMode);
  const normWin = normalizeKmlmWindow(kmlmWindow);
  const isCore3 = profile === 'core3_adaptive';
  const isAskBid = fillMode === 'ask_bid';
  const feedStamp = liveKmlmFeed?.stamp ?? 'seed';
  const m7LockActive = Boolean(m7LiveDashboard?.post_tp_lockout?.active);
  const m7ArmedCnt = Number(m7LiveDashboard?.near_itm_tp_rule?.armed_count ?? 0);

  const cacheKey = [
    asOf ?? 'latest',
    isCore3 ? 'c3' : 'm7g',
    isAskBid ? 'ab' : 'lim',
    normOverlay,
    normFin,
    normWin,
    feedStamp,
    m7LockActive ? 'L1' : 'L0',
    m7ArmedCnt,
  ].join('|');

  if (computedPayloadCache.has(cacheKey)) {
    return computedPayloadCache.get(cacheKey);
  }

  const d11Obj = seed.d11;
  const d11 = d11Obj.dates;
  const n11 = d11.length;

  const coreLim11 = isCore3 ? d11Obj.c3_lim_nav : d11Obj.m7g_lim_nav;
  const coreAb11 = isCore3 ? d11Obj.c3_ab_nav : d11Obj.m7g_ab_nav;
  const eps11 = isCore3 ? d11Obj.c3_lockout_episodes : d11Obj.m7g_lockout_episodes;

  const pxQqq11 = d11Obj.qqq_adj;
  const pxKmRaw11 = d11Obj.kmlm_adj;
  const pxAq11 = d11Obj.aqmix_adj;
  const effr11 = d11Obj.effr;
  const vix11 = d11Obj.vix;
  const vr11 = d11Obj.vr;

  const spliceIdx = d11.indexOf('2020-12-03');
  const rAq11 = pctChangeZeroFirst(pxAq11);
  const rKmRaw11 = pctChangeZeroFirst(pxKmRaw11);
  const rKm11 = new Array(n11);
  const pxKm11 = new Array(n11);
  let accKm = 100.0;
  for (let i = 0; i < n11; i += 1) {
    rKm11[i] = i < spliceIdx ? rAq11[i] : rKmRaw11[i];
    accKm *= 1.0 + rKm11[i];
    pxKm11[i] = accKm;
  }

  const rQqq11 = pctChangeZeroFirst(pxQqq11);
  const rLim11 = pctChangeZeroFirst(coreLim11);
  const rAb11 = pctChangeZeroFirst(coreAb11);
  const bh11 = pxQqq11.map(x => INITIAL_CAPITAL_USD * (x / pxQqq11[0]));
  const { tpDayInfo: tp11, lockoutMask: lk11 } = buildTpAndLockoutJS(d11, vix11, vr11, eps11);

  // 5-Year Pure Live KMLM Window (2020-12-02 -> 2025-12-15, ZERO proxy)
  const i5 = d11.indexOf('2020-12-02');
  const d5 = d11.slice(i5);
  const rLim5 = rLim11.slice(i5); rLim5[0] = 0.0;
  const rAb5 = rAb11.slice(i5); rAb5[0] = 0.0;
  const rQqq5 = rQqq11.slice(i5); rQqq5[0] = 0.0;
  const pxQqq5 = pxQqq11.slice(i5);
  const rKm5 = rKmRaw11.slice(i5); rKm5[0] = 0.0;
  const pxKm5 = pxKmRaw11.slice(i5).map(Number);
  const effr5 = effr11.slice(i5);
  const vix5 = vix11.slice(i5);
  const bh5 = pxQqq5.map(x => INITIAL_CAPITAL_USD * (x / pxQqq5[0]));
  const coreLim5 = coreLim11.slice(i5).map(x => INITIAL_CAPITAL_USD * (x / coreLim11[i5]));
  const coreAb5 = coreAb11.slice(i5).map(x => INITIAL_CAPITAL_USD * (x / coreAb11[i5]));
  const tp5 = new Map();
  for (const [k, v] of tp11.entries()) {
    if (k >= i5) tp5.set(k - i5, v);
  }
  const lk5 = lk11.slice(i5);

  const sl11 = [['KMLM', KMLM_WEIGHT, rKm11, pxKm11]];
  const sl5 = [['KMLM', KMLM_WEIGHT, rKm5, pxKm5]];

  const runPair = (finSpread, modeCode) => {
    const s11Lim = simPureCtaBlueprintJS({
      dates: d11, rCore: rLim11, rQqq: rQqq11, qqqPx: pxQqq11, sleeves: sl11,
      effr: effr11, vix: vix11, finSpread, tpDayInfo: tp11, lockoutActiveByDay: lk11, mode: modeCode,
    });
    const s11Ab = simPureCtaBlueprintJS({
      dates: d11, rCore: rAb11, rQqq: rQqq11, qqqPx: pxQqq11, sleeves: sl11,
      effr: effr11, vix: vix11, finSpread, tpDayInfo: tp11, lockoutActiveByDay: lk11, mode: modeCode,
    });
    const s5Lim = simPureCtaBlueprintJS({
      dates: d5, rCore: rLim5, rQqq: rQqq5, qqqPx: pxQqq5, sleeves: sl5,
      effr: effr5, vix: vix5, finSpread, tpDayInfo: tp5, lockoutActiveByDay: lk5, mode: modeCode,
    });
    const s5Ab = simPureCtaBlueprintJS({
      dates: d5, rCore: rAb5, rQqq: rQqq5, qqqPx: pxQqq5, sleeves: sl5,
      effr: effr5, vix: vix5, finSpread, tpDayInfo: tp5, lockoutActiveByDay: lk5, mode: modeCode,
    });

    const activeS11 = isAskBid ? s11Ab : s11Lim;
    const activeS5 = isAskBid ? s5Ab : s5Lim;

    const p11 = calcPerfJS(d11, activeS11.nav, bh11, effr11, {
      ...activeS11,
      ibkr_limit_final_nav: r2(s11Lim.nav[s11Lim.nav.length - 1]),
      ab_final_nav: r2(s11Ab.nav[s11Ab.nav.length - 1]),
    });
    const p5 = calcPerfJS(d5, activeS5.nav, bh5, effr5, {
      ...activeS5,
      ibkr_limit_final_nav: r2(s5Lim.nav[s5Lim.nav.length - 1]),
      ab_final_nav: r2(s5Ab.nav[s5Ab.nav.length - 1]),
    });

    return { s11Lim, s11Ab, s5Lim, s5Ab, activeS11, activeS5, p11, p5 };
  };

  const boxRot = runPair(FIN_SPREAD_BOX, 'rot_vix20');
  const boxStatic = runPair(FIN_SPREAD_BOX, 'static_drift');
  const ibkrRot = runPair(FIN_SPREAD_IBKR, 'rot_vix20');
  const ibkrStatic = runPair(FIN_SPREAD_IBKR, 'static_drift');

  const activeCore11 = isAskBid ? coreAb11 : coreLim11;
  const activeCore5 = isAskBid ? coreAb5 : coreLim5;

  const qqqPerf11 = calcPerfJS(d11, bh11, bh11, effr11);
  const corePerf11 = calcPerfJS(d11, activeCore11, bh11, effr11, {
    ibkr_limit_final_nav: r2(coreLim11[coreLim11.length - 1]),
    ab_final_nav: r2(coreAb11[coreAb11.length - 1]),
  });
  const qqqPerf5 = calcPerfJS(d5, bh5, bh5, effr5);
  const corePerf5 = calcPerfJS(d5, activeCore5, bh5, effr5, {
    ibkr_limit_final_nav: r2(coreLim5[coreLim5.length - 1]),
    ab_final_nav: r2(coreAb5[coreAb5.length - 1]),
  });

  // Live 2026 YTD & Live 4-Gate Signal (strictly causal <= asOf if historical)
  const merged26 = mergeTail2026WithFeed(
    seed.tail_2026_seed,
    seed.effr_seed_latest,
    liveKmlmFeed,
    asOf && asOf >= '2026-01-05' ? asOf : null,
  );

  let live2026Ytd = null;
  let liveAthDate = '2026-10-06';
  let liveQqqDdPct = Number(liveMarketSnapshot?.dd_from_ath_pct ?? -19.90);
  let liveKmlmRetSinceAthPct = -7.70;
  let liveCorrSinceAth = 0.092;
  let kmlmSpotClose = 28.80;
  let kmlmYtdPct = 10.94;
  let qqqYtdPct = 3.56;
  let liveAsOf26 = asOf ?? '2026-11-25';
  let liveVixClose = Number(liveMarketSnapshot?.vix ?? 20.0);

  if (merged26.dates.length >= 5) {
    const d26 = merged26.dates;
    const pq26 = merged26.qqq_adj;
    const pk26 = merged26.kmlm_adj;
    const rq26 = pctChangeZeroFirst(pq26);
    const rk26 = pctChangeZeroFirst(pk26);
    const ef26 = merged26.effr;
    const vx26 = merged26.vix;

    liveAsOf26 = d26[d26.length - 1];
    kmlmSpotClose = r2(merged26.kmlm_close[merged26.kmlm_close.length - 1]);
    if (!liveMarketSnapshot?.vix) {
      liveVixClose = r2(vx26[vx26.length - 1]);
    }

    qqqYtdPct = r2((pq26[pq26.length - 1] / pq26[0] - 1.0) * 100.0);
    kmlmYtdPct = r2((pk26[pk26.length - 1] / pk26[0] - 1.0) * 100.0);

    // Running ATH inside 2026 window up to latest session
    let athIdx = 0;
    let athVal = pq26[0];
    for (let i = 1; i < pq26.length; i += 1) {
      if (pq26[i] >= athVal) {
        athVal = pq26[i];
        athIdx = i;
      }
    }
    liveAthDate = d26[athIdx];
    liveQqqDdPct = r2((pq26[pq26.length - 1] / Math.max(athVal, 1e-6) - 1.0) * 100.0);
    liveKmlmRetSinceAthPct = r2((pk26[pk26.length - 1] / Math.max(pk26[athIdx], 1e-6) - 1.0) * 100.0);
    const loLive = pq26.length - 1 - athIdx >= 5 ? athIdx + 1 : Math.max(1, pq26.length - 20);
    liveCorrSinceAth = r3(pearsonCorrJS(rq26.slice(loLive), rk26.slice(loLive)));

    const idxO6 = d26.indexOf('2026-10-06');
    const idxN20 = d26.indexOf('2026-11-20');
    const qqqQ4 = idxO6 >= 0 && idxN20 > idxO6
      ? r2((pq26[idxN20] / pq26[idxO6] - 1.0) * 100.0)
      : liveQqqDdPct;
    const kmlmQ4 = idxO6 >= 0 && idxN20 > idxO6
      ? r2((pk26[idxN20] / pk26[idxO6] - 1.0) * 100.0)
      : liveKmlmRetSinceAthPct;
    const corrQ4 = idxO6 >= 0 && idxN20 > idxO6
      ? r3(pearsonCorrJS(rq26.slice(idxO6 + 1, idxN20 + 1), rk26.slice(idxO6 + 1, idxN20 + 1)))
      : liveCorrSinceAth;

    const sl26 = [['KMLM', KMLM_WEIGHT, rk26, pk26]];
    const s26Box = simPureCtaBlueprintJS({
      dates: d26, rCore: rq26, rQqq: rq26, qqqPx: pq26, sleeves: sl26,
      effr: ef26, vix: vx26, finSpread: FIN_SPREAD_BOX, mode: 'static_qtr',
    });
    const s26Ibkr = simPureCtaBlueprintJS({
      dates: d26, rCore: rq26, rQqq: rq26, qqqPx: pq26, sleeves: sl26,
      effr: ef26, vix: vx26, finSpread: FIN_SPREAD_IBKR, mode: 'static_qtr',
    });

    const mk26Perf = simObj => {
      const nv = simObj.nav;
      const ytd = (nv[nv.length - 1] / nv[0] - 1.0) * 100.0;
      const q4Ret = idxO6 >= 0 && idxN20 > idxO6
        ? (nv[idxN20] / nv[idxO6] - 1.0) * 100.0
        : 0.0;
      return {
        ytd_pct: r2(ytd),
        alpha_pp: r2(ytd - qqqYtdPct),
        q4_crash_pct: r2(q4Ret),
        mdd_pct: r2(maxDrawdownJS(nv) * 100.0),
        peak_ltv_pct: simObj.peak_ltv_pct,
        ann_interest_pct_nav: simObj.ann_interest_pct_nav,
      };
    };

    live2026Ytd = {
      window: `${d26[0]} -> ${d26[d26.length - 1]}`,
      q4_window: idxO6 >= 0 && idxN20 > idxO6 ? `${d26[idxO6]} -> ${d26[idxN20]}` : `${liveAthDate} -> ${liveAsOf26}`,
      standalone: {
        QQQ_ytd: qqqYtdPct,
        KMLM_ytd: kmlmYtdPct,
        QQQ_q4: qqqQ4,
        KMLM_q4: kmlmQ4,
        KMLM_q4_corr: corrQ4,
      },
      box_35bp: mk26Perf(s26Box),
      ibkr_150bp: mk26Perf(s26Ibkr),
    };
  }

  // Historical PIT check if asOf <= 2025-12-15
  let sleeveInQqqNow = false;
  if (asOf && asOf <= '2025-12-15') {
    let idxPit = d11.length - 1;
    while (idxPit > 0 && d11[idxPit] > asOf) idxPit -= 1;
    sleeveInQqqNow = Boolean(boxRot.activeS11.in_qqq_by_day[idxPit]);
    liveAsOf26 = d11[idxPit];
    liveVixClose = r2(vix11[idxPit]);
    kmlmSpotClose = pxKmRaw11[idxPit] !== null ? r2(Number(pxKmRaw11[idxPit])) : r2(pxAq11[idxPit]);
    let athI = 0;
    for (let j = 1; j <= idxPit; j += 1) {
      if (pxQqq11[j] >= pxQqq11[athI]) athI = j;
    }
    liveAthDate = d11[athI];
    liveQqqDdPct = r2((pxQqq11[idxPit] / Math.max(pxQqq11[athI], 1e-6) - 1.0) * 100.0);
    liveKmlmRetSinceAthPct = r2((pxKm11[idxPit] / Math.max(pxKm11[athI], 1e-6) - 1.0) * 100.0);
    const loH = idxPit - athI >= 5 ? athI + 1 : Math.max(1, idxPit - 19);
    liveCorrSinceAth = r3(pearsonCorrJS(rQqq11.slice(loH, idxPit + 1), rKm11.slice(loH, idxPit + 1)));
  }

  const g1CoreTp = m7ArmedCnt > 0;
  const g2Dd12 = liveQqqDdPct <= -12.0;
  const g3KmlmPos = liveKmlmRetSinceAthPct > 0.0;
  const g4NegCorr = liveCorrSinceAth < 0.0;
  const allFourRotate = !sleeveInQqqNow && g1CoreTp && g2Dd12 && g3KmlmPos && g4NegCorr;
  const reloadReady = sleeveInQqqNow && !m7LockActive && liveVixClose <= 20.0;

  let actionCode = 'HOLD_KMLM_SLEEVE';
  let actionEn = 'HOLD 20% KMLM Sleeve (Smart Hold · Do NOT Rotate to QQQ)';
  let actionZh = '维持 +20% KMLM 独立叠仓（智能持有 · 不切股抄底 QQQ）';
  let reasonEn = !g4NegCorr
    ? `Daily Corr(QQQ, KMLM) since ${liveAthDate} is ${liveCorrSinceAth >= 0 ? '+' : ''}${liveCorrSinceAth.toFixed(3)} (>= 0) and KMLM is ${liveKmlmRetSinceAthPct >= 0 ? '+' : ''}${liveKmlmRetSinceAthPct.toFixed(2)}%. Strict 4-gate filter keeps 20% KMLM intact as crisis diversifier.`
    : !g3KmlmPos
      ? `KMLM return since ${liveAthDate} is ${liveKmlmRetSinceAthPct.toFixed(2)}% (<= 0%). Anti-whipsaw rule forbids selling KMLM at a loss.`
      : !g2Dd12
        ? `QQQ drawdown from ATH is ${liveQqqDdPct.toFixed(2)}% (> -12.0% threshold).`
        : 'Waiting for Core B020_M125 Near-ITM Crash Put Take-Profit signal.';
  let reasonZh = !g4NegCorr
    ? `自高点 ${liveAthDate} 以来 Corr(QQQ, KMLM) = ${liveCorrSinceAth >= 0 ? '+' : ''}${liveCorrSinceAth.toFixed(3)}（>= 0 正相关）且 KMLM 区间 ${liveKmlmRetSinceAthPct >= 0 ? '+' : ''}${liveKmlmRetSinceAthPct.toFixed(2)}%，未形成危机负相关赚钱效应，四门控严格拦截切股，继续持有 20% KMLM。`
    : !g3KmlmPos
      ? `自高点 ${liveAthDate} 以来 KMLM 收益 ${liveKmlmRetSinceAthPct.toFixed(2)}%（<= 0%），防震荡铁律禁止亏损割肉 CTA。`
      : !g2Dd12
        ? `当前 QQQ 距高点回撤 ${liveQqqDdPct.toFixed(2)}%（未达 <= -12.0% 深度危机线）。`
        : '当前核心仓 B020_M125 尚未触发准实值崩盘止盈（TP），维持常态 100% Core + 20% KMLM 叠仓。';

  if (allFourRotate) {
    actionCode = 'ROTATE_KMLM_TO_QQQ';
    actionEn = 'ROTATE 20% KMLM -> QQQ at Next Close (All 4 NegCorr Gates Met)';
    actionZh = '触发危机切股：明日收盘卖空 20% KMLM 悉数换入 QQQ（四门控全亮）';
    reasonEn = 'Core Put TP armed + QQQ DD <= -12% + KMLM positive crisis gain + negative daily correlation.';
    reasonZh = '核心仓崩盘 Put 止盈触发 + QQQ 回撤 <= -12% + KMLM 危机正收益 + 负相关，锁定 CTA 危机浮盈换入超跌 QQQ。';
  } else if (reloadReady) {
    actionCode = 'RELOAD_KMLM_20PCT';
    actionEn = 'RELOAD 20% KMLM Sleeve (VIX <= 20 & 5D Lockout Cleared)';
    actionZh = '触发常态回补：VIX <= 20 且 5日禁买锁解除，恢复 100% Core + 20% KMLM';
    reasonEn = `VIX (${liveVixClose.toFixed(2)} <= 20) and 5D Post-TP Lockout cleared; reset to 1.20x Return-Stacking.`;
    reasonZh = `VIX (${liveVixClose.toFixed(2)} <= 20) 且 5天倒挂禁买锁已解除，重置回 100% 核心仓 + 20% KMLM 常态叠仓。`;
  } else if (sleeveInQqqNow) {
    actionCode = 'HOLD_ROTATED_QQQ';
    actionEn = 'HOLD Rotated 1.20x QQQ Rebound Position (Awaiting VIX <= 20 & 5D Unlock)';
    actionZh = '持有切股后 1.20x QQQ 反弹仓位（等待 VIX <= 20 且 5日解锁回补 KMLM）';
    reasonEn = `20% sleeve currently riding QQQ rebound until VIX <= 20 (now ${liveVixClose.toFixed(2)}) and 5D lockout clears.`;
    reasonZh = `20% 叠仓正在吃 QQQ 底部V型反弹，待 VIX <= 20（当前 ${liveVixClose.toFixed(2)}）且 5日禁买锁解除后回补 KMLM。`;
  }

  const effrPct = merged26.effr_latest_pct;
  const boxRatePct = r2(effrPct + 0.35);
  const ibkrRatePct = r2(effrPct + 1.50);
  const activeFinRatePct = normFin === 'ibkr_150bp' ? ibkrRatePct : boxRatePct;

  const box11 = boxRot.s11Lim;
  const ibkr11 = ibkrRot.s11Lim;
  const pBox11 = calcPerfJS(d11, box11.nav, bh11, effr11, box11);
  const pIbkr11 = calcPerfJS(d11, ibkr11.nav, bh11, effr11, ibkr11);

  const marginSafety = {
    weight_pct: 20.0,
    gross_leverage: 1.20,
    init_ltv_pct: r2((KMLM_WEIGHT / (1.0 + KMLM_WEIGHT)) * 100.0),
    peak_ltv_11yr_pct: pBox11.peak_ltv_pct,
    peak_ltv_11yr_ibkr_pct: pIbkr11.peak_ltv_pct,
    peak_ltv_5yr_pct: boxRot.s5Lim.peak_ltv_pct,
    peak_ltv_5yr_ibkr_pct: ibkrRot.s5Lim.peak_ltv_pct,
    peak_ltv_2026_pct: live2026Ytd?.box_35bp?.peak_ltv_pct ?? 19.94,
    peak_ltv_2026_ibkr_pct: live2026Ytd?.ibkr_150bp?.peak_ltv_pct ?? 19.97,
    min_eq_ratio_11yr_pct: pBox11.min_eq_ratio_pct,
    crash_to_regt_25_pct: regTCrashToCall(KMLM_WEIGHT, 0.25),
    crash_to_regt_35_pct: regTCrashToCall(KMLM_WEIGHT, 0.35),
    ann_int_box_pct: pBox11.ann_interest_pct_nav,
    ann_int_ibkr_pct: pIbkr11.ann_interest_pct_nav,
    tot_int_11yr_box_usd: pBox11.tot_interest_usd,
    tot_int_11yr_ibkr_usd: pIbkr11.tot_interest_usd,
    box_vs_ibkr_11yr_saved_usd: Math.round(pBox11.final_nav - pIbkr11.final_nav),
  };

  const episodesAll = (seed.episodes_7_historical_and_q4 ?? []).filter(
    ep => !asOf || ep.tp_date <= asOf || ep.tp_date === '2026-11-20',
  );

  const curves5yr = sampleSeries(
    d5,
    {
      qqq_bh: bh5,
      core_100x: activeCore5,
      kmlm20_box: boxRot.activeS5.nav,
      kmlm20_ibkr: ibkrRot.activeS5.nav,
      kmlm20_static_box: boxStatic.activeS5.nav,
    },
    3,
  );
  const curves11yr = {
    ...sampleSeries(
      d11,
      {
        qqq_bh: bh11,
        core_100x: activeCore11,
        kmlm20_box: boxRot.activeS11.nav,
        kmlm20_ibkr: ibkrRot.activeS11.nav,
        kmlm20_static_box: boxStatic.activeS11.nav,
      },
      5,
    ),
    splice_date: '2020-12-03',
  };

  const activeBacktest = normWin === '11yr_stitched'
    ? (normFin === 'ibkr_150bp' ? ibkrRot.p11 : boxRot.p11)
    : (normFin === 'ibkr_150bp' ? ibkrRot.p5 : boxRot.p5);
  const activeCorePerf = normWin === '11yr_stitched' ? corePerf11 : corePerf5;
  const activeQqqPerf = normWin === '11yr_stitched' ? qqqPerf11 : qqqPerf5;

  const payload = {
    id: 'kmlm_20_hypothesis',
    code: 'B020_M125_PLUS_20PCT_KMLM_DD12_NEGCORR',
    status: 'HYPOTHESIS',
    is_active_overlay: normOverlay === 'kmlm20_120x',
    selected_overlay_mode: normOverlay,
    selected_fin_mode: normFin,
    selected_window: normWin,
    profile: isCore3 ? 'core3_adaptive' : 'full_m7_adaptive',
    fill_mode: isAskBid ? 'ask_bid' : 'ibkr_limit',
    badge_en: 'HYPOTHESIS · 1.20x (+20% KMLM Stack)',
    badge_zh: '版本假说 · 1.20x（+20% KMLM 杠杆叠仓）',
    title_en: '1.20x Return-Stacking Hypothesis: 100% Locked Core (B020_M125) + 20% Pure KMLM',
    title_zh: '1.20x 杠杆叠仓版本假说：100% 锁死双账本核心仓（B020_M125）+ 20% 纯 KMLM 危机管理期货',
    disclaimer_en:
      'Hypothesis Overlay (Research Preview): Keeps the 1.00x B020_M125 production core 100% unchanged and stacks +20% KMLM (0% GLD) via SPX Box (+0.35%) or IBKR Margin (+1.50%) with strict 4-gate anti-overfitting NegCorr rotation.',
    disclaimer_zh:
      '版本假说（研究验证版）：1.00x B020_M125 生产核心仓 100% 原封不动，在此之上通过 SPX Box（+0.35%）或 IBKR 融资（+1.50%）叠仓 +20% 纯 KMLM（0% 黄金），执行零前视四门控负相关危机切股与 VIX<=20 解锁回补。',
    architecture: {
      core_weight_pct: 100.0,
      kmlm_weight_pct: 20.0,
      gld_weight_pct: 0.0,
      gross_leverage: 1.20,
      rebal_fee_bps: 5.0,
      normal_rebal_en: 'Quarterly calendar calibration (with ±2.5pp [17.5%, 22.5%] drift band audit)',
      normal_rebal_zh: '常态按季再平衡校准杠杆（同步提供 ±2.5pp [17.5%, 22.5%] 漂移带对照）',
      rotation_rule_en:
        'Rotate 20% KMLM -> QQQ at T+1 Close ONLY when ALL 4 hold at T EOD: (1) Core B020_M125 Put TP triggers, (2) QQQ DD from ATH <= -12.0%, (3) KMLM Return(ATH->T) > 0%, (4) Daily Corr(QQQ, KMLM; ATH..T) < 0.',
      rotation_rule_zh:
        '仅当 T 日收盘同时满足全部 4 项门控时于 T+1 收盘将 20% KMLM 切入 QQQ：(1) 核心仓崩盘 Put 触发止盈，(2) QQQ 距高点回撤 <= -12.0%，(3) KMLM 自高点累计收益 > 0%，(4) 区间日收益相关系数 Corr(QQQ, KMLM) < 0。',
      reload_rule_en: 'Reload back to 100% Core + 20% KMLM at T+1 Close once 5D Post-TP Lockout clears AND VIX <= 20.0.',
      reload_rule_zh: '当止盈后连续 5 天 VIX/VIX3M < 1.00 禁买锁解除 且 VIX <= 20.0 时，次日收盘回补恢复 100% 核心仓 + 20% KMLM。',
    },
    financing: {
      effr_effective_date: merged26.effr_latest_date,
      effr_pct: effrPct,
      box_spread_pct: 0.35,
      ibkr_spread_pct: 1.50,
      box_rate_pct: boxRatePct,
      ibkr_rate_pct: ibkrRatePct,
      active_mode: normFin,
      active_rate_pct: activeFinRatePct,
      accrual_basis: 'Actual/360 causal T-1 official NY Fed EFFR',
      is_live_fetched: merged26.is_live_fetched,
      fetched_at: merged26.fetched_at,
    },
    live_signal: {
      as_of_date: liveAsOf26,
      kmlm_spot_close: kmlmSpotClose,
      kmlm_ytd_pct: kmlmYtdPct,
      qqq_ytd_pct: qqqYtdPct,
      vix_close: r2(liveVixClose),
      lockout_5d_active: m7LockActive,
      core_tp_armed_today: g1CoreTp,
      ath_date: liveAthDate,
      qqq_dd_from_ath_pct: liveQqqDdPct,
      kmlm_ret_since_ath_pct: liveKmlmRetSinceAthPct,
      corr_qqq_kmlm_since_ath: liveCorrSinceAth,
      sleeve_state: sleeveInQqqNow ? 'ROTATED_TO_QQQ' : 'HELD_IN_KMLM',
      action_code: actionCode,
      action_label_en: actionEn,
      action_label_zh: actionZh,
      reason_summary_en: reasonEn,
      reason_summary_zh: reasonZh,
      live_target_ltv_pct: 16.67,
      q4_2026_tp_audit: {
        tp_date: '2026-11-20',
        ath_date: '2026-10-06',
        qqq_dd_pct: live2026Ytd?.standalone?.QQQ_q4 ?? -19.90,
        kmlm_ret_pct: live2026Ytd?.standalone?.KMLM_q4 ?? -7.70,
        corr: live2026Ytd?.standalone?.KMLM_q4_corr ?? 0.092,
        decision: 'HOLD',
        reason: 'HOLD_POS_CORR',
        verdict_en: '2026-11-20 Core Put TP Audit: QQQ -19.90%, KMLM -7.70%, Corr +0.092 (>= 0) -> SMART HOLD (Zero Whipsaw Rotation)',
        verdict_zh: '2026-11-20 核心仓止盈日审计：QQQ -19.90%，KMLM -7.70%，日相关 +0.092（>= 0 正相关）→ 智能持有不切股（零假动作磨损）',
      },
      four_gates: [
        {
          id: 'gate_1_core_tp',
          pass: g1CoreTp,
          current_reading: g1CoreTp ? 'ARMED' : 'IDLE',
          threshold: 'Core Put TP Armed',
          label_en: '1. Core B020_M125 Crash Put TP',
          label_zh: '1. 核心仓 B020_M125 崩盘 Put 止盈触发',
        },
        {
          id: 'gate_2_qqq_dd12',
          pass: g2Dd12,
          current_reading: `${liveQqqDdPct.toFixed(2)}%`,
          threshold: '<= -12.0%',
          label_en: '2. QQQ Drawdown from ATH <= -12%',
          label_zh: '2. QQQ 距前高回撤 <= -12.0%',
        },
        {
          id: 'gate_3_kmlm_pos_ret',
          pass: g3KmlmPos,
          current_reading: `${liveKmlmRetSinceAthPct >= 0 ? '+' : ''}${liveKmlmRetSinceAthPct.toFixed(2)}%`,
          threshold: '> 0.0%',
          label_en: '3. KMLM Crisis Return (ATH->Now) > 0%',
          label_zh: '3. KMLM 危机区间收益（前高至今）> 0%',
        },
        {
          id: 'gate_4_neg_corr',
          pass: g4NegCorr,
          current_reading: `${liveCorrSinceAth >= 0 ? '+' : ''}${liveCorrSinceAth.toFixed(3)}`,
          threshold: '< 0.000',
          label_en: '4. Daily Corr(QQQ, KMLM) < 0',
          label_zh: '4. 区间日收益相关 Corr(QQQ, KMLM) < 0',
        },
      ],
      reload_gate: {
        pass: !m7LockActive && liveVixClose <= 20.0,
        vix_ok: liveVixClose <= 20.0,
        lockout_clear: !m7LockActive,
        vix_close: r2(liveVixClose),
        lockout_active: m7LockActive,
        label_en: 'Reload Gate: VIX <= 20.0 AND 5D Post-TP Lockout Cleared',
        label_zh: '常态回补门控：VIX <= 20.0 且 5天止盈后倒挂禁买锁已解除',
      },
    },
    margin_safety: marginSafety,
    active_summary: {
      window_id: normWin,
      fin_mode: normFin,
      fill_mode: isAskBid ? 'ask_bid' : 'ibkr_limit',
      kmlm20: activeBacktest,
      core_100x: activeCorePerf,
      qqq_bh: activeQqqPerf,
      net_alpha_vs_core_usd: r2(activeBacktest.final_nav - activeCorePerf.final_nav),
      net_alpha_vs_qqq_usd: r2(activeBacktest.final_nav - activeQqqPerf.final_nav),
      mdd_improvement_vs_core_pp: r2(activeBacktest.mdd_pct - activeCorePerf.mdd_pct),
      calmar_gain_vs_core: r3(activeBacktest.calmar - activeCorePerf.calmar),
    },
    backtest_5yr_live: {
      window: seed.windows?.window_5yr_live ?? '2020-12-02 -> 2025-12-15',
      is_pure_live_etf: true,
      proxy_used: false,
      note_en: '100% Live KMLM ETF + Real MIT OPRA QQQ Option Chain ($200,000 start, zero proxy splicing).',
      note_zh: '100% KMLM 实盘 ETF + MIT 真实 OPRA 期权链（$200,000 起投，零代换拼接）。',
      qqq_bh: qqqPerf5,
      core_100x: corePerf5,
      box_35bp: {
        reload_vix20_5d: boxRot.p5,
        static_drift_250bp: boxStatic.p5,
      },
      ibkr_150bp: {
        reload_vix20_5d: ibkrRot.p5,
        static_drift_250bp: ibkrStatic.p5,
      },
    },
    backtest_11yr: {
      window: seed.windows?.window_11yr ?? '2015-01-02 -> 2025-12-15',
      is_pure_live_etf: false,
      proxy_used: true,
      splice_date: '2020-12-03',
      splice_note_en: seed.windows?.splice_note_en ?? '',
      splice_note_zh: seed.windows?.splice_note_zh ?? '',
      qqq_bh: qqqPerf11,
      core_100x: corePerf11,
      box_35bp: {
        reload_vix20_5d: boxRot.p11,
        static_drift_250bp: boxStatic.p11,
      },
      ibkr_150bp: {
        reload_vix20_5d: ibkrRot.p11,
        static_drift_250bp: ibkrStatic.p11,
      },
    },
    live_2026_ytd: live2026Ytd,
    episodes_7: episodesAll,
    curves_5yr: curves5yr,
    curves_11yr: curves11yr,
  };

  if (computedPayloadCache.size >= 64) {
    const oldestKey = computedPayloadCache.keys().next().value;
    computedPayloadCache.delete(oldestKey);
  }
  computedPayloadCache.set(cacheKey, payload);
  return payload;
}
