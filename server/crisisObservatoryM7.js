// Pure-JS M7-Graded Three-Pillar Probabilistic Put Overlay Engine & Daily Live EOD Stepper.
// Zero Python subprocesses, zero external dependencies, strict T+1 Open zero-lookahead parity.

const INITIAL_CAPITAL = 200000.0;
const OPT_SLIP = 0.025;
const OPT_COMM_PER_SH = 0.0065;
const STOCK_REBAL_FEE = 0.0003;
const MARGIN_SPREAD = 0.015;
const MIN_OPT_BID = 0.03;

export const CRISIS_OBSERVATORY_PUT_OTMS = Object.freeze(['otm15', 'otm20']);
export const CRISIS_OBSERVATORY_M7_TP_MODES = Object.freeze(['standard', 'itm_tp']);
export const CRISIS_OBSERVATORY_ROLL_MODES = Object.freeze(['90d_hold', '120d_roll50']);

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

const FRED_LAGS = Object.freeze({
  BAA10Y: 1,
  DGS2: 1,
  NFCI: 5,
});

const M7_TP_SPECS = Object.freeze({
  standard: {
    id: 'standard',
    code: 'STANDARD',
    label_en: 'Standard (VIX/3M >= 1.10 OR 5x)',
    label_zh: '标准止盈（VIX/3M >= 1.10 或 5x）',
  },
  itm_tp: {
    id: 'itm_tp',
    code: 'ITM_TP',
    label_en: 'ITM_TP (VIX/3M >= 1.10 & ITM OR 5x)',
    label_zh: '实值止盈 ITM_TP（倒挂>=1.10且进实值 或 5x）',
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

export function formatM7TriggerLabels(sigDay, maxSlots) {
  const mods = [];
  for (const mKey of ['M0', 'M6', 'M2', 'M5', 'M4', 'M3']) {
    if (sigDay[mKey]) mods.push(mKey);
  }
  const prob = Number(sigDay.crisis_prob ?? 0);
  const p1 = Number(sigDay.p1 ?? 0);
  const p2 = Number(sigDay.p2 ?? 0);
  const p3 = Number(sigDay.p3 ?? 0);
  const tSlots = Number(maxSlots === 3 ? sigDay.target_slots_m7g : sigDay.target_slots_m7);

  const pParts = [];
  if (p1 > 0) {
    const p1m = ['M0', 'M6'].filter(m => sigDay[m]).join('+');
    pParts.push(`P1:${p1m}(${Math.round(p1)})`);
  }
  if (p2 > 0) {
    const p2m = ['M2', 'M5'].filter(m => sigDay[m]).join('+');
    pParts.push(`P2:${p2m}(${Math.round(p2)})`);
  }
  if (p3 > 0) {
    const p3m = ['M4', 'M3'].filter(m => sigDay[m]).join('+');
    pParts.push(`P3:${p3m}(${Math.round(p3)})`);
  }
  const codeStr = pParts.length ? pParts.join(' + ') : 'M7>=35';
  const modZh = mods.map(m => M7_MODULE_SHORT[m].short_zh).join(' + ');
  const modEn = mods.map(m => M7_MODULE_SHORT[m].short_en).join(' + ');
  const trigEn = `Score ${Math.round(prob)}% -> ${tSlots}/${maxSlots} Slots [${codeStr}] (${modEn})`;
  const trigZh = `危机概率 ${Math.round(prob)}% -> 目标 ${tSlots}/${maxSlots} 槽 [${codeStr}]（${modZh}）`;
  return { mods, codeStr, trigEn, trigZh };
}

function computeM7BhBaseline(evalBars) {
  const n = evalBars.length;
  const preSh = new Array(n);
  const postSh = new Array(n);
  const nav = new Array(n);
  let sh = INITIAL_CAPITAL / Number(evalBars[0].close);
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
    rollMode = '90d_hold',
    m0Enabled = true,
    ccMode = 'cc_off',
    spMode = 'sp_off',
    wcMode = 'wc_reclaim_30d_d35',
  } = {},
) {
  const isGraded = strategyId === 'M7G_Graded';
  const maxSlots = isGraded ? 3 : 2;
  const slotCoverage = 0.5;
  const otmPctInt = putOtm === 'otm20' ? 20 : 15;
  const putMoneyness = putOtm === 'otm20' ? 0.8 : 0.85;
  const requireItmTp = m7TpMode === 'itm_tp';
  const tpCode = requireItmTp ? 'ITM_TP' : 'STANDARD';
  const isRoll50 = rollMode === '120d_roll50';
  const targetDte = isRoll50 ? 120 : 90;
  const refDte = targetDte;
  const rollDteThr = isRoll50 ? 50 : 0;
  const putMultMaxDte = isRoll50 ? 75 : 45;
  const refMoneyness = 0.9;
  const vixRatioTp = 1.1;
  const putMultTp = 5.0;
  const stepCalDays = 30;
  const escalateMinDays = 21;

  const bhM7 = computeM7BhBaseline(evalBars);
  const nDays = evalBars.length;
  const dates = evalBars.map(r => r.date);
  const msArr = dates.map(parseIsoDayMs);
  const finalBhSh = bhM7.finalSh;
  const finalCl = Number(evalBars[nDays - 1].close);

  let coreShares = INITIAL_CAPITAL / Number(evalBars[0].close);
  let activeTranches = [];
  let pendingSig = null;

  const ccEnabled = ccMode !== 'cc_off';
  const ccDte = 25;
  const ccAthLimit = 0.03;
  const ccMinVxn = 0.0;
  const ccTargetDelta = 0.12;
  const ccMinOtm = 0.05;
  let ccStopDelta = null;
  let ccRollMode = null;
  let ccMaxRolls = 0;
  if (ccMode === 'cc_d12_d35') ccStopDelta = 0.35;
  else if (ccMode === 'cc_d12_r45') {
    ccStopDelta = 0.45;
    ccRollMode = 'fresh_30d';
    ccMaxRolls = 2;
  } else if (ccMode === 'cc_d12_cr55') {
    ccStopDelta = 0.55;
    ccRollMode = 'credit_45d';
    ccMaxRolls = 2;
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
    if (spCash > 1.0 && activeSp === null && assignedShares <= 1e-6) {
      coreShares += spCash / (px * (1.0 + STOCK_REBAL_FEE));
      spCash = 0.0;
    }
  };

  const estimateNavOpen = (opPx, vxnO, rC, qC, curMs) => {
    let mtmP = 0.0;
    for (const tr of activeTranches) {
      const remD = Math.max(1, diffDays(tr.expMs, curMs));
      const tO = remD / 365.0;
      const spIv = evalSkewIv(opPx, tr.kp, tO, rC, qC, vxnO, coeffs);
      mtmP += tr.hedged_shares * bsmPrice(opPx, tr.kp, tO, rC, qC, spIv, 'put');
    }
    let mtmCcO = 0.0;
    if (activeCc !== null) {
      const remCO = Math.max(1, diffDays(activeCc.expMs, curMs));
      const tCO = remCO / 365.0;
      const scIvC = evalSkewIv(opPx, activeCc.kc, tCO, rC, qC, vxnO, coeffs);
      mtmCcO = -activeCc.shares * bsmPrice(opPx, activeCc.kc, tCO, rC, qC, scIvC, 'call');
    }
    return Math.max(1.0, (coreShares + assignedShares) * opPx + ccCash + spCash + mtmP + mtmCcO);
  };

  const navList = new Array(nDays);
  const equivShList = new Array(nDays);
  const anyActiveList = new Array(nDays);
  const activeSlotsList = new Array(nDays);
  const ledger = [];
  let tid = 0;

  for (let i = 0; i < nDays; i += 1) {
    const row = evalBars[i];
    const sigD = sigSeries[i];
    const d = dates[i];
    const curMs = msArr[i];
    const op = Number(row.open);
    const cl = Number(row.close);
    const div = Number(row.dividends);
    const vxnCl = Number(row.vxn);
    const vixR = Number(row.vix_ratio);
    const rCur = Number(row.r);
    const qCur = Number(row.div_yield);
    const ddCur = Number(row.dd_from_ath);

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
      coreShares += ccCash / (op * (1.0 + STOCK_REBAL_FEE));
      ccCash = 0.0;
      pendingCcDeploy = false;
    }

    if (i > 0 && activeCc !== null && activeCc.pending_close) {
      const prevVxn = Number(evalBars[i - 1].vxn);
      const prevCl = Number(evalBars[i - 1].close);
      const vxnOpCc = Math.max(10.0, prevVxn - 0.45 * (op / prevCl - 1.0) * 100.0);
      const remCc = Math.max(0, diffDays(activeCc.expMs, curMs));
      const tCc = remCc / 365.0;
      const scEx = evalSkewIv(op, activeCc.kc, tCc, rCur, qCur, vxnOpCc, coeffs);
      const cAskEx = bsmPrice(op, activeCc.kc, tCc, rCur, qCur, scEx, 'call') * (1.0 + OPT_SLIP);
      const costCl = activeCc.shares * cAskEx;
      ccGrossLoss += costCl;
      if (ccCash >= costCl) ccCash -= costCl;
      else {
        coreShares -= (costCl - ccCash) / (op * (1.0 - STOCK_REBAL_FEE));
        ccCash = 0.0;
      }
      const closeReason = activeCc.close_reason || 'panic_close_uncap';
      const oldRolls = Number(activeCc.roll_count || 0);
      const oldSh = activeCc.shares;
      ccLedger.push({
        cc_id: activeCc.cc_id,
        entry_date: activeCc.entry_date,
        exit_date: d,
        entry_spot: r2(activeCc.entry_spot),
        kc: r2(activeCc.kc),
        exit_spot: r2(op),
        entry_vxn: r2(activeCc.entry_vxn),
        shares: r2(oldSh),
        prem_usd: r2(activeCc.prem_usd),
        loss_usd: r2(costCl),
        net_pnl_usd: r2(activeCc.prem_usd - costCl),
        exit_reason: closeReason,
        roll_gen: oldRolls,
      });
      activeCc = null;
      if (
        (closeReason === 'delta_roll_up' || closeReason === 'delta_credit_roll') &&
        ccRollMode !== null &&
        oldRolls < ccMaxRolls
      ) {
        const rollDays = ccRollMode === 'credit_45d' ? 45 : 30;
        const targetMs = curMs + rollDays * 86400000;
        const posR = bisectLeftMs(msArr, targetMs);
        const expDateR = posR < nDays ? dates[posR] : new Date(targetMs).toISOString().slice(0, 10);
        const expMsR = posR < nDays ? msArr[posR] : targetMs;
        const tR = Math.max(1, diffDays(expMsR, curMs)) / 365.0;
        let kcNew = null;
        if (ccRollMode === 'credit_45d') {
          kcNew = solveCallStrikeForBid(op, tR, rCur, qCur, vxnOpCc, coeffs, cAskEx, OPT_SLIP);
        } else if (ccRollMode === 'fresh_30d') {
          kcNew = Math.max(
            op * (1.0 + ccMinOtm),
            solveCallStrikeForDelta(op, tR, rCur, qCur, vxnOpCc, coeffs, ccTargetDelta),
          );
        }
        if (kcNew !== null && kcNew > op * 1.01) {
          const scR = evalSkewIv(op, kcNew, tR, rCur, qCur, vxnOpCc, coeffs);
          const cBidR = bsmPrice(op, kcNew, tR, rCur, qCur, scR, 'call') * (1.0 - OPT_SLIP);
          if (cBidR >= 0.05) {
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
              entry_spot: op,
              entry_vxn: vxnOpCc,
              kc: kcNew,
              shares: oldSh,
              prem_usd: premR,
              pending_close: false,
              roll_count: oldRolls + 1,
            };
          }
        }
      }
    }

    // 1. Pending M7 TP / 50D Roll Exits at T+1 Open
    if (i > 0 && activeTranches.some(t => t.pending_tp)) {
      const prevVxn = Number(evalBars[i - 1].vxn);
      const prevCl = Number(evalBars[i - 1].close);
      const vxnOp = Math.max(10.0, prevVxn - 0.45 * (op / prevCl - 1.0) * 100.0);
      const stillOpen = [];
      for (const tr of activeTranches) {
        if (!tr.pending_tp) {
          stillOpen.push(tr);
          continue;
        }
        const remDays = Math.max(0, diffDays(tr.expMs, curMs));
        const tRem = remDays / 365.0;
        const sigEx = evalSkewIv(op, tr.kp, tRem, rCur, qCur, vxnOp, coeffs);
        const putBid = Math.max(
          0.0,
          bsmPrice(op, tr.kp, tRem, rCur, qCur, sigEx, 'put') * (1.0 - OPT_SLIP) - OPT_COMM_PER_SH,
        );
        const exitUsd = tr.hedged_shares * putBid;
        let dSh = 0.0;
        if (Math.abs(exitUsd) > 1e-10) {
          const denom = op * (1.0 + (exitUsd >= 0 ? STOCK_REBAL_FEE : -STOCK_REBAL_FEE));
          dSh = exitUsd / denom;
          coreShares += dSh;
        }
        const roiMult = tr.entry_cost_usd > 1e-6 ? exitUsd / tr.entry_cost_usd : 0.0;
        const actualNetSh = putBid - tr.entry_put_ask;
        const conv = decomposeNakedPutConvexity(
          tr.entry_spot,
          op,
          tr.kp,
          tr.T_entry,
          tRem,
          tr.entry_r,
          rCur,
          tr.entry_q,
          qCur,
          tr.entry_vxn,
          vxnOp,
          coeffs,
          actualNetSh,
        );
        const hs = tr.hedged_shares;
        const netPnlRounded = r2(exitUsd - tr.entry_cost_usd);
        const dUsd = r2(conv.dvDelta * hs);
        const gUsd = r2(conv.dvGamma * hs);
        const vUsd = r2(conv.dvVega * hs);
        ledger.push({
          tranche_id: tr.tranche_id,
          strategy_id: strategyId,
          slot_num: tr.slot_num,
          tier: tr.tier,
          max_slots: maxSlots,
          tranche_type: 'naked_put',
          put_otm_pct: otmPctInt,
          tp_mode: tpCode,
          roll_mode: rollMode,
          target_dte: targetDte,
          signal_date: tr.signal_date,
          entry_date: tr.entry_date,
          planned_exp_date: tr.exp_date,
          exit_date: d,
          actual_days_held: diffDays(curMs, tr.entryMs),
          rem_dte_at_exit: remDays,
          exit_reason: tr.tp_reason,
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
          exit_spot: r2(op),
          exit_vxn: r2(vxnOp),
          exit_vix_ratio: r3(tr.tp_trigger_ratio),
          underlying_ret_pct: r2((op / tr.entry_spot - 1.0) * 100.0),
          put_exit_val_sh: r4(putBid),
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
          comp_put_gain_usd: r2(dSh * multMorning),
          comp_call_drag_usd: 0.0,
        });
      }
      activeTranches = stillOpen;
    }

    // 2. Pending New M7 Tranche Entry at T+1 Open
    if (i > 0 && pendingSig !== null && activeTranches.length < pendingSig.cap_slots) {
      const vxnEn = Math.max(10.0, pendingSig.vxn - 0.45 * (op / pendingSig.close - 1.0) * 100.0);
      const rEn = pendingSig.r;
      const qEn = pendingSig.q;

      const refTargetMs = curMs + refDte * 86400000;
      const posRef = bisectLeftMs(msArr, refTargetMs);
      const expMsRef = posRef < nDays ? msArr[posRef] : refTargetMs;
      const tRef = Math.max(1, diffDays(expMsRef, curMs)) / 365.0;
      const kpRef = op * refMoneyness;
      const sigRef = evalSkewIv(op, kpRef, tRef, rEn, qEn, vxnEn, coeffs);
      const putAskRef = bsmPrice(op, kpRef, tRef, rEn, qEn, sigRef, 'put') * (1.0 + 0.025);

      const targetMs = curMs + targetDte * 86400000;
      const pos = bisectLeftMs(msArr, targetMs);
      const expDate = pos < nDays ? dates[pos] : new Date(targetMs).toISOString().slice(0, 10);
      const expMs = pos < nDays ? msArr[pos] : targetMs;
      const tEn = Math.max(1, diffDays(expMs, curMs)) / 365.0;
      const kp = op * putMoneyness;
      const sigPEn = evalSkewIv(op, kp, tEn, rEn, qEn, vxnEn, coeffs);
      const midEn = bsmPrice(op, kp, tEn, rEn, qEn, sigPEn, 'put');
      const putAskEn = midEn * (1.0 + OPT_SLIP) + OPT_COMM_PER_SH;

      let alreadyRefCov = 0.0;
      for (const t of activeTranches) alreadyRefCov += t.ref_cov_sh;
      const costShFracRef = putAskRef / (op * (1.0 - STOCK_REBAL_FEE));
      const maxCov = coreShares * (slotCoverage * Math.max(2, pendingSig.cap_slots));
      const availShRef = Math.max(0.0, maxCov - alreadyRefCov);
      const refHedgedSh = Math.min(coreShares * slotCoverage, availShRef / (1.0 + costShFracRef));
      const refBudgetUsd = refHedgedSh * putAskRef;

      if (putAskEn >= 0.03 && refBudgetUsd > 1.0) {
        const hedgedSh = refBudgetUsd / putAskEn;
        const entryCostUsd = refBudgetUsd;
        let dShEntry = 0.0;
        if (ccEnabled && ccCash >= entryCostUsd) {
          ccCash -= entryCostUsd;
          ccFundedPuts += entryCostUsd;
        } else if (ccEnabled && ccCash > 0.0) {
          const paidCc = ccCash;
          ccFundedPuts += paidCc;
          const remCost = entryCostUsd - paidCc;
          ccCash = 0.0;
          dShEntry = -remCost / (op * (1.0 - STOCK_REBAL_FEE));
          coreShares += dShEntry;
        } else {
          dShEntry = -entryCostUsd / (op * (1.0 - STOCK_REBAL_FEE));
          coreShares += dShEntry;
        }

        tid += 1;
        const usedSlots = new Set(activeTranches.map(t => t.slot_num));
        let slotNum = 1;
        while (usedSlots.has(slotNum)) slotNum += 1;
        const hr = hedgedSh / Math.max(coreShares, 1e-6);
        activeTranches.push({
          tranche_id: tid,
          slot_num: slotNum,
          tier: pendingSig.tier,
          signal_date: pendingSig.signal_date,
          sig_score: pendingSig.sig_score,
          sig_ad_below50: pendingSig.sig_ad_below50,
          crisis_prob: pendingSig.crisis_prob,
          p1: pendingSig.p1,
          p2: pendingSig.p2,
          p3: pendingSig.p3,
          triggered_modules: pendingSig.triggered_modules,
          trigger_code: pendingSig.trigger_code,
          trigger_en: pendingSig.trigger_en,
          trigger_zh: pendingSig.trigger_zh,
          entry_date: d,
          entryMs: curMs,
          exp_date: expDate,
          expMs,
          T_entry: tEn,
          entry_spot: op,
          entry_vxn: vxnEn,
          entry_vix_ratio: pendingSig.vix_ratio,
          entry_r: rEn,
          entry_q: qEn,
          kp,
          hedged_shares: hedgedSh,
          ref_cov_sh: refHedgedSh,
          hedged_ratio: hr,
          entry_put_ask: putAskEn,
          entry_cost_usd: entryCostUsd,
          entry_shares_sold: dShEntry,
          comp_entry_cost_usd: dShEntry * multMorning,
          pending_tp: false,
          tp_trigger_ratio: 0.0,
          tp_reason: '',
        });
      }
      pendingSig = null;
    }

    // 2b. Engine 2 & Engine 3 T+1 Open
    if (i > 0 && ccEnabled && pendingCc !== null && activeCc === null) {
      const vxnCc = Math.max(10.0, pendingCc.vxn - 0.45 * (op / pendingCc.close - 1.0) * 100.0);
      const rCc = pendingCc.r;
      const qCc = pendingCc.q;
      const ccSh = Math.max(0.0, coreShares);
      if (ccSh > 1e-6) {
        const targetMs = curMs + ccDte * 86400000;
        const posCc = bisectLeftMs(msArr, targetMs);
        const expDateCc = posCc < nDays ? dates[posCc] : new Date(targetMs).toISOString().slice(0, 10);
        const expMsCc = posCc < nDays ? msArr[posCc] : targetMs;
        const tCc = Math.max(1, diffDays(expMsCc, curMs)) / 365.0;
        const kcCc = Math.max(
          op * (1.0 + ccMinOtm),
          solveCallStrikeForDelta(op, tCc, rCc, qCc, vxnCc, coeffs, ccTargetDelta),
        );
        const scCc = evalSkewIv(op, kcCc, tCc, rCc, qCc, vxnCc, coeffs);
        const cBidCc = bsmPrice(op, kcCc, tCc, rCc, qCc, scCc, 'call') * (1.0 - OPT_SLIP);
        if (cBidCc >= 0.05) {
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
            entry_spot: op,
            entry_vxn: vxnCc,
            kc: kcCc,
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
      const vxnWc = Math.max(10.0, pw.vxn - 0.45 * (op / pw.close - 1.0) * 100.0);
      let expDateWc;
      let expMsWc;
      let actDteWc;
      let kcWc;
      if (wcMode === 'wc_reclaim_30d_d35' || wcMode === 'wc_30d_c5s5') {
        const targetWcMs = curMs + 30 * 86400000;
        const posWc = bisectLeftMs(msArr, targetWcMs);
        expDateWc = posWc < nDays ? dates[posWc] : new Date(targetWcMs).toISOString().slice(0, 10);
        expMsWc = posWc < nDays ? msArr[posWc] : targetWcMs;
        actDteWc = Math.max(1, diffDays(expMsWc, curMs));
        if (wcMode === 'wc_reclaim_30d_d35') {
          const kD35 = solveCallStrikeForDelta(op, actDteWc / 365.0, pw.r, pw.q, vxnWc, coeffs, 0.35);
          kcWc = Math.max(assignedCostK, kD35);
        } else {
          kcWc = Math.max(assignedCostK * 1.05, op * 1.05);
        }
      } else {
        [expDateWc, expMsWc, actDteWc] = pickExpiryStrictMax14(msArr, dates, i, spDte, 14);
        kcWc = Math.max(assignedCostK, op * 1.02);
      }
      const [cBidWc] = optExecPriceSp(op, kcWc, actDteWc / 365.0, pw.r, pw.q, vxnWc, coeffs, 'call', 'sell', OPT_SLIP);
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
          entry_spot: op,
          kc: kcWc,
          assigned_cost_k: assignedCostK,
          shares: assignedShares,
          prem_usd: premWc,
        };
      }
    }

    if (i > 0 && spEnabled && pendingSp !== null && activeSp === null && assignedShares <= 1e-6) {
      const ps = pendingSp;
      pendingSp = null;
      const vxnSp = Math.max(10.0, ps.vxn - 0.45 * (op / ps.close - 1.0) * 100.0);
      const [expDateSp, expMsSp, actDteSp] = pickExpiryStrictMax14(msArr, dates, i, spDte, 14);
      const kpSp = op * (1.0 - spOtmPct);
      const [pBidSp] = optExecPriceSp(op, kpSp, actDteSp / 365.0, ps.r, ps.q, vxnSp, coeffs, 'put', 'sell', OPT_SLIP);
      if (pBidSp >= MIN_OPT_BID) {
        const navOpen = estimateNavOpen(op, vxnSp, ps.r, ps.q, curMs);
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
          entry_spot: op,
          kp: kpSp,
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

    const wasActiveToday = activeTranches.length > 0;
    const activeSlotsToday = activeTranches.length;

    // 4. EOD Expiries
    const stillOpenExp = [];
    for (const tr of activeTranches) {
      if (curMs >= tr.expMs) {
        const putIntr = Math.max(0.0, tr.kp - cl);
        const settleUsd = tr.hedged_shares * putIntr;
        let dSh = 0.0;
        if (Math.abs(settleUsd) > 1e-10) {
          dSh = settleUsd / (cl * (1.0 + STOCK_REBAL_FEE));
          coreShares += dSh;
        }
        const roiMult = tr.entry_cost_usd > 1e-6 ? settleUsd / tr.entry_cost_usd : 0.0;
        const actualNetSh = putIntr - tr.entry_put_ask;
        const conv = decomposeNakedPutConvexity(
          tr.entry_spot,
          cl,
          tr.kp,
          tr.T_entry,
          0.0,
          tr.entry_r,
          rCur,
          tr.entry_q,
          qCur,
          tr.entry_vxn,
          vxnCl,
          coeffs,
          actualNetSh,
        );
        const hs = tr.hedged_shares;
        const netPnlRounded = r2(settleUsd - tr.entry_cost_usd);
        const dUsd = r2(conv.dvDelta * hs);
        const gUsd = r2(conv.dvGamma * hs);
        const vUsd = r2(conv.dvVega * hs);
        ledger.push({
          tranche_id: tr.tranche_id,
          strategy_id: strategyId,
          slot_num: tr.slot_num,
          tier: tr.tier,
          max_slots: maxSlots,
          tranche_type: 'naked_put',
          put_otm_pct: otmPctInt,
          tp_mode: tpCode,
          roll_mode: rollMode,
          target_dte: targetDte,
          signal_date: tr.signal_date,
          entry_date: tr.entry_date,
          planned_exp_date: tr.exp_date,
          exit_date: d,
          actual_days_held: diffDays(curMs, tr.entryMs),
          rem_dte_at_exit: 0,
          exit_reason: isRoll50 ? 'expiry_120dte' : 'expiry_90dte',
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
          exit_spot: r2(cl),
          exit_vxn: r2(vxnCl),
          exit_vix_ratio: r3(vixR),
          underlying_ret_pct: r2((cl / tr.entry_spot - 1.0) * 100.0),
          put_exit_val_sh: r4(putIntr),
          call_exit_cost_sh: 0.0,
          exit_net_cash_usd: r2(settleUsd),
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
          comp_put_gain_usd: r2(dSh * multEod),
          comp_call_drag_usd: 0.0,
        });
      } else {
        stillOpenExp.push(tr);
      }
    }
    activeTranches = stillOpenExp;

    // 5. EOD MTM & TP / 50D Roll Check
    let putMtm = 0.0;
    for (const tr of activeTranches) {
      const remDays = Math.max(1, diffDays(tr.expMs, curMs));
      const tRem = remDays / 365.0;
      const sigP = evalSkewIv(cl, tr.kp, tRem, rCur, qCur, vxnCl, coeffs);
      const putMid = bsmPrice(cl, tr.kp, tRem, rCur, qCur, sigP, 'put');
      putMtm += tr.hedged_shares * putMid;
      if (!tr.pending_tp) {
        const vixOk = vixR >= vixRatioTp && (requireItmTp ? cl <= tr.kp : true);
        if (vixOk) {
          tr.pending_tp = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = requireItmTp ? 'vix_inv_1.10_itm_tp' : 'vix_inv_1.10_tp';
        } else if (remDays <= putMultMaxDte && tr.entry_put_ask > 1e-6 && putMid >= tr.entry_put_ask * putMultTp) {
          tr.pending_tp = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = isRoll50 ? 'put_5x_dte75_tp' : 'put_5x_dte45_tp';
        } else if (isRoll50 && remDays <= rollDteThr) {
          tr.pending_tp = true;
          tr.tp_trigger_ratio = vixR;
          tr.tp_reason = 'roll_50d';
        }
      }
    }

    // 5b. Engine 2 & Engine 3 EOD MTM/Expiries
    let ccMtm = 0.0;
    if (activeCc !== null) {
      if (d === activeCc.exp_date) {
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
        });
        activeCc = null;
      } else {
        const remCc = Math.max(1, diffDays(activeCc.expMs, curMs));
        const tCc = remCc / 365.0;
        const scCc = evalSkewIv(cl, activeCc.kc, tCc, rCur, qCur, vxnCl, coeffs);
        const cmCc = bsmPrice(cl, activeCc.kc, tCc, rCur, qCur, scCc, 'call');
        ccMtm = -activeCc.shares * cmCc;
        const curDelta = bsmCallDelta(cl, activeCc.kc, tCc, rCur, qCur, scCc);
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
      if (d === activeSp.exp_date) {
        if (cl >= activeSp.kp) {
          spClosedLedger.push({
            leg_id: `SP-${activeSp.sp_id}`,
            sp_id: activeSp.sp_id,
            cycle_id: activeSp.cycle_id,
            leg_type: 'short_put',
            is_open_live: false,
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
        const [, pmSp] = optExecPriceSp(cl, activeSp.kp, remSp / 365.0, rCur, qCur, vxnCl, coeffs, 'put', 'buy', OPT_SLIP);
        spMtm = -activeSp.shares * pmSp;
      }
    }

    let wcMtm = 0.0;
    if (activeWc !== null) {
      if (d === activeWc.exp_date) {
        if (cl > activeWc.kc) {
          spCash += assignedShares * activeWc.kc;
          const stockGain = activeWc.shares * (activeWc.kc - activeWc.assigned_cost_k);
          wcClosedLedger.push({
            leg_id: `WC-${activeWc.wc_id}`,
            wc_id: activeWc.wc_id,
            cycle_id: activeWc.cycle_id,
            leg_type: 'wheel_call',
            is_open_live: false,
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
        const [, cmWc] = optExecPriceSp(cl, activeWc.kc, remWc / 365.0, rCur, qCur, vxnCl, coeffs, 'call', 'buy', OPT_SLIP);
        wcMtm = -activeWc.shares * cmWc;
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
    anyActiveList[i] = wasActiveToday || activeTranches.length > 0 ? 1 : 0;
    activeSlotsList[i] = Math.max(activeSlotsToday, activeTranches.length);

    // 6. EOD M7 Signal & Hard Redline Gate for T+1 Open
    const capSlots = Number(isGraded ? sigD.target_slots_m7g : sigD.target_slots_m7);
    const redlineBlocked = vxnCl > 27.0 || vixR >= 1.02;
    const effOpen = isRoll50 ? activeTranches.filter(t => !t.pending_tp) : activeTranches;
    if (capSlots > 0 && !redlineBlocked && effOpen.length < capSlots) {
      const minGap = capSlots <= 2 ? stepCalDays : escalateMinDays;
      const recent = effOpen.some(t => diffDays(curMs, t.entryMs) < minGap);
      if (!recent) {
        const { mods, codeStr, trigEn, trigZh } = formatM7TriggerLabels(sigD, maxSlots);
        pendingSig = {
          signal_date: d,
          vxn: vxnCl,
          close: cl,
          vix_ratio: vixR,
          r: rCur,
          q: qCur,
          cap_slots: capSlots,
          tier: capSlots,
          sig_score: Number(row.score),
          sig_ad_below50: Boolean(row.ad_below50),
          crisis_prob: Number(sigD.crisis_prob),
          p1: Number(sigD.p1),
          p2: Number(sigD.p2),
          p3: Number(sigD.p3),
          triggered_modules: mods,
          trigger_code: codeStr,
          trigger_en: trigEn,
          trigger_zh: trigZh,
        };
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

  const closedTradesCount = ledger.length;
  const lastR = evalBars[nDays - 1];
  const lastD = dates[nDays - 1];
  const lastMs = msArr[nDays - 1];
  const lastCl = Number(lastR.close);
  const lastVxn = Number(lastR.vxn);
  const lastVr = Number(lastR.vix_ratio);
  const lastRf = Number(lastR.r);
  const lastQ = Number(lastR.div_yield);
  const multLast = (finalBhSh / bhM7.postSh[nDays - 1]) * finalCl;

  const activeTranchesSerialized = [];
  for (const tr of activeTranches) {
    const remD = Math.max(1, diffDays(tr.expMs, lastMs));
    const tRem = remD / 365.0;
    const spIv = evalSkewIv(lastCl, tr.kp, tRem, lastRf, lastQ, lastVxn, coeffs);
    const pm = bsmPrice(lastCl, tr.kp, tRem, lastRf, lastQ, spIv, 'put');
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
    const isArmed = Boolean(tr.pending_tp);
    const armedReason = tr.tp_reason || '';
    const liveReason =
      isArmed && armedReason === 'roll_50d'
        ? 'live_roll50_armed_next_open'
        : isArmed
          ? 'live_tp_armed_next_open'
          : 'open_live_mtm';
    const netPnlRounded = r2(mtmNetPnl);
    const dUsd = r2(conv.dvDelta * hs);
    const gUsd = r2(conv.dvGamma * hs);
    const vUsd = r2(conv.dvVega * hs);
    ledger.push({
      tranche_id: tr.tranche_id,
      strategy_id: strategyId,
      slot_num: tr.slot_num,
      tier: tr.tier,
      max_slots: maxSlots,
      tranche_type: 'naked_put',
      put_otm_pct: otmPctInt,
      tp_mode: tpCode,
      roll_mode: rollMode,
      target_dte: targetDte,
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
    });
    activeTranchesSerialized.push({
      tranche_id: tr.tranche_id,
      slot_num: tr.slot_num,
      tier: tr.tier,
      tranche_type: 'naked_put',
      put_otm_pct: otmPctInt,
      roll_mode: rollMode,
      target_dte: targetDte,
      roll_dte: rollDteThr,
      days_to_roll50: isRoll50 ? Math.max(0, remD - 50) : null,
      entry_date: tr.entry_date,
      exp_date: tr.exp_date,
      rem_dte: remD,
      entry_spot: r2(tr.entry_spot),
      mtm_spot: r2(lastCl),
      mtm_date: lastD,
      kp: r2(tr.kp),
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
    });
  }

  const yrs = Math.max(diffDays(lastMs, msArr[0]) / 365.25, 1 / 252);
  const cagr = Math.pow(navList[nDays - 1] / INITIAL_CAPITAL, 1.0 / yrs) - 1.0;
  const rets = [];
  for (let j = 1; j < nDays; j += 1) rets.push(navList[j] / navList[j - 1] - 1.0);
  const meanR = rets.length ? rets.reduce((a, b) => a + b, 0) / rets.length : 0.0;
  let sq = 0.0;
  for (let j = 0; j < rets.length; j += 1) sq += (rets[j] - meanR) ** 2;
  const vol = Math.sqrt(sq / Math.max(1, rets.length - 1)) * Math.sqrt(252.0);
  const sharpe = vol > 0 ? (meanR * 252.0) / vol : 0.0;
  const negRets = rets.filter(x => x < 0);
  let sortino = 0.0;
  if (negRets.length > 1) {
    const muNeg = negRets.reduce((a, b) => a + b, 0) / negRets.length;
    const sqNeg = negRets.reduce((a, x) => a + (x - muNeg) ** 2, 0);
    const downStd = Math.sqrt(sqNeg / (negRets.length - 1)) * Math.sqrt(252.0);
    if (downStd > 0) sortino = (meanR * 252.0) / downStd;
  }

  let peak = navList[0];
  let mdd = 0.0;
  for (let j = 0; j < nDays; j += 1) {
    if (navList[j] > peak) peak = navList[j];
    const dd = navList[j] / peak - 1.0;
    if (dd < mdd) mdd = dd;
  }
  const calmar = mdd < 0 ? cagr / Math.abs(mdd) : 0.0;

  const nTp = ledger.filter(x => !x.is_open_live && String(x.exit_reason).includes('tp')).length;
  const rollExits = ledger.filter(x => !x.is_open_live && x.exit_reason === 'roll_50d');
  const rollSalvageCount = rollExits.length;
  const avgRollSalvagePct =
    rollSalvageCount > 0
      ? (rollExits.reduce((a, x) => a + Number(x.roi_mult || 0), 0) / rollSalvageCount) * 100.0
      : 0.0;
  const nakedSpent = ledger.reduce((a, x) => a + Number(x.entry_cost_usd || 0), 0);
  const grossPut = ledger
    .filter(x => !x.is_open_live)
    .reduce((a, x) => a + Number(x.exit_net_cash_usd || 0), 0);
  const netAlpha = navList[nDays - 1] - bhM7.endNav;
  const activeSum = anyActiveList.reduce((a, b) => a + b, 0);
  const pctActive = (activeSum / nDays) * 100.0;
  const activeDays = Math.max(1, activeSum);
  const extraShVsBh = equivShList[nDays - 1] - finalBhSh;
  const extraShPct = finalBhSh > 0 ? (extraShVsBh / finalBhSh) * 100.0 : 0.0;
  const maxRoi = ledger
    .filter(x => !x.is_open_live)
    .reduce((mx, x) => Math.max(mx, Number(x.roi_mult || 0)), 0.0);

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
    const [, pmSpLast] = optExecPriceSp(lastCl, activeSp.kp, remSpLast / 365.0, lastRf, lastQ, lastVxn, coeffs, 'put', 'buy', OPT_SLIP);
    const mtmCostSp = activeSp.shares * pmSpLast;
    openSpSer = {
      leg_id: `SP-${activeSp.sp_id}`,
      sp_id: activeSp.sp_id,
      cycle_id: activeSp.cycle_id,
      leg_type: 'short_put',
      is_open_live: true,
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
      net_pnl_usd: r2(activeSp.prem_usd - mtmCostSp),
      exit_reason: 'open_live_mtm',
    };
    spCombinedLedger.push(openSpSer);
  }
  if (activeWc !== null) {
    const remWcLast = Math.max(1, diffDays(activeWc.expMs, lastMs));
    const [, cmWcLast] = optExecPriceSp(lastCl, activeWc.kc, remWcLast / 365.0, lastRf, lastQ, lastVxn, coeffs, 'call', 'buy', OPT_SLIP);
    const mtmCostWc = activeWc.shares * cmWcLast;
    const stockUnreal = activeWc.shares * (lastCl - activeWc.assigned_cost_k);
    openWcSer = {
      leg_id: `WC-${activeWc.wc_id}`,
      wc_id: activeWc.wc_id,
      cycle_id: activeWc.cycle_id,
      leg_type: 'wheel_call',
      is_open_live: true,
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
      stock_gain_usd: r2(stockUnreal),
      net_pnl_usd: r2(activeWc.prem_usd - mtmCostWc + stockUnreal),
      exit_reason: 'open_live_mtm',
    };
    spCombinedLedger.push(openWcSer);
  }
  spCombinedLedger.sort((a, b) =>
    a.entry_date !== b.entry_date ? a.entry_date.localeCompare(b.entry_date) : String(a.leg_id).localeCompare(String(b.leg_id)),
  );
  if (curCycleStartMs !== null) {
    maxWheelCycleDays = Math.max(maxWheelCycleDays, diffDays(lastMs, curCycleStartMs));
  }

  const endGrossLev = ((coreShares + assignedShares) * lastCl) / Math.max(navList[nDays - 1], 1.0);
  const endPutNotional = activeSp !== null ? activeSp.shares * activeSp.kp : 0.0;
  const endNotionalLev = ((coreShares + assignedShares) * lastCl + endPutNotional) / Math.max(navList[nDays - 1], 1.0);

  const summary = {
    id: strategyId,
    arch: 'm7_equal_dollar',
    put_otm: putOtm,
    put_otm_pct: otmPctInt,
    m7_tp_mode: m7TpMode,
    roll_mode: rollMode,
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
    final_shares: r2(equivShList[nDays - 1]),
    bh_final_shares: r2(finalBhSh),
    extra_shares_vs_bh: r2(extraShVsBh),
    extra_shares_pct: r2(extraShPct),
    pct_days_hedged: r1(pctActive),
    alpha_per_active_day_usd: r2(netAlpha / activeDays),
    tranches_total: ledger.length,
    closed_trades_count: closedTradesCount,
    naked_count: ledger.length,
    collar_count: 0,
    tp_count: nTp,
    roll_salvage_count: rollSalvageCount,
    roll_50d_count: rollSalvageCount,
    avg_roll_salvage_pct: r1(avgRollSalvagePct),
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

  return {
    summary,
    nav: navList,
    equiv_shares: equivShList,
    active_slots: activeSlotsList,
    ledger,
    cc_ledger: ccLedger,
    sp_ledger: spCombinedLedger,
    active_tranches_eod: activeTranchesSerialized,
    pending_sig_eod: pendingSig,
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
    rollMode = '90d_hold',
    m0Enabled = true,
  } = {},
) {
  const d = String(row.date);
  const cl = Number(row.close);
  const ddPct = Number(row.dd_from_ath) * 100.0;
  const vxn = Number(row.vxn);
  const vr = Number(row.vix_ratio);
  const rCur = Number(row.r);
  const qCur = Number(row.div_yield);
  const sc = Number(row.score);
  const adLine = Number(row.ad_line);
  const adSma50 = Number(row.ad_sma50);
  const adBelow = adLine < adSma50;

  const isRoll50 = rollMode === '120d_roll50';
  const entryDte = isRoll50 ? 120 : 90;
  const fiveXDte = isRoll50 ? 75 : 45;
  const rollDte = isRoll50 ? 50 : 0;

  const maxSlots = Number(m7Sim.summary.max_slots || 3);
  const isGraded = maxSlots === 3;
  const prob = Number(sigDay.crisis_prob ?? 0);
  const p1 = Number(sigDay.p1 ?? 0);
  const p2 = Number(sigDay.p2 ?? 0);
  const p3 = Number(sigDay.p3 ?? 0);
  const targetSlots = Number(isGraded ? sigDay.target_slots_m7g : sigDay.target_slots_m7);

  const activeTr = m7Sim.active_tranches_eod ?? [];
  const activeSlots = activeTr.length;
  const effActiveTr = isRoll50 ? activeTr.filter(t => !t.pending_tp) : activeTr;
  const pendSig = m7Sim.pending_sig_eod;

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
  const { mods: modsActive, codeStr: trigCode } = formatM7TriggerLabels(sigDay, maxSlots);

  const anyTpArmed = activeTr.some(t => Boolean(t.pending_tp) && t.tp_reason !== 'roll_50d');
  const anyRoll50Armed = activeTr.some(t => Boolean(t.pending_tp) && t.tp_reason === 'roll_50d');
  const otmLbl = putOtm === 'otm20' ? '-20% OTM' : '-15% OTM';
  const tenorLblEn = isRoll50 ? '120D (Roll@50D)' : '90D';
  const tenorLblZh = isRoll50 ? '120D（剩50天滚仓）' : '90D';

  let t1Code;
  let t1Tone;
  let t1BadgeEn;
  let t1BadgeZh;
  let t1TitleEn;
  let t1TitleZh;

  if (anyTpArmed) {
    t1Code = 'TP_ARMED_NEXT_OPEN';
    t1Tone = 'tp';
    t1BadgeEn = 'T+1 OPEN: TAKE-PROFIT MONETIZE & RELOAD QQQ';
    t1BadgeZh = 'T+1 开盘指令：触发恐慌止盈 · 变现 Put 抄底加仓 QQQ';
    t1TitleEn = 'Panic Take-Profit Triggered — Monetize Active Put Slot(s) at Next Open';
    t1TitleZh = '恐慌止盈阈值已触发 —— 次日开盘全额平仓变现并复投 QQQ 正股';
  } else if (anyRoll50Armed && pendSig !== null) {
    t1Code = 'ROLL_50D_AND_REOPEN';
    t1Tone = 'armed';
    t1BadgeEn = `T+1 OPEN: 50-DTE ROLL -> HARVEST RESIDUAL & OPEN 120D ${otmLbl} PUT`;
    t1BadgeZh = `T+1 开盘指令：剩 <=50 DTE 触发滚仓 · 回收残值并换入新 120D ${otmLbl} Put`;
    t1TitleEn = `Score ${Math.round(prob)}% (${trigCode}) Active at <=50 DTE — Salvage Expiring Slot & Roll Into Fresh 120-DTE ${otmLbl} Put`;
    t1TitleZh = `在途槽位剩 <=50 DTE 且综合概率 ${Math.round(prob)}%（${trigCode}）仍亮 —— 次日开盘回收残值并滚入新 120D ${otmLbl} Put`;
  } else if (anyRoll50Armed) {
    t1Code = 'SALVAGE_50D_EXIT';
    t1Tone = 'active';
    t1BadgeEn = 'T+1 OPEN: 50-DTE SALVAGE EXIT -> HARVEST RESIDUAL TO QQQ';
    t1BadgeZh = 'T+1 开盘指令：剩 <=50 DTE 信号熄灭 · 平仓回收残值复投 QQQ';
    t1TitleEn = 'Slot Reached <=50 DTE With M7 Signal Off — Exit Before Theta Cliff & Reinvest Residual Cash Into QQQ';
    t1TitleZh = '在途槽位剩 <=50 DTE 且 M7 信号已解除 —— 在 Theta 悬崖前平仓回收残值并复投 QQQ';
  } else if (pendSig !== null) {
    const nextSlotIdx = effActiveTr.length + 1;
    t1Code = 'OPEN_NEW_SLOT';
    t1Tone = 'armed';
    t1BadgeEn = `T+1 OPEN: BUY 1 NEW SLOT (SLOT ${nextSlotIdx}/${maxSlots} · ${tenorLblEn} ${otmLbl} PUT)`;
    t1BadgeZh = `T+1 开盘指令：新开 1 槽保护（第 ${nextSlotIdx}/${maxSlots} 槽 · ${tenorLblZh} ${otmLbl} Put）`;
    t1TitleEn = `Score ${Math.round(prob)}% (${trigCode}) -> Open Slot ${nextSlotIdx}/${maxSlots} Equal-Dollar ${entryDte}-DTE ${otmLbl} Put`;
    t1TitleZh = `综合概率 ${Math.round(prob)}%（${trigCode}）-> 次日开盘按等金额预算买入第 ${nextSlotIdx}/${maxSlots} 槽 ${tenorLblZh} ${otmLbl} Put`;
  } else if (targetSlots > effActiveTr.length && redlineBlocked) {
    t1Code = 'REDLINE_BLOCKED';
    t1Tone = 'blocked';
    t1BadgeEn = 'T+1 OPEN: HARD REDLINE BLOCKED (NO NEW PUTS IN HIGH IV)';
    t1BadgeZh = 'T+1 开盘指令：风控红线锁死禁开新仓（拒绝高波追买天价 Put）';
    t1TitleEn = `Hard Risk Redline Active (VXN ${vxn.toFixed(2)} > 27 or VIX/3M ${vr.toFixed(3)} >= 1.02) — New Entries Strictly Forbidden`;
    t1TitleZh = `绝对风控红线生效（VXN ${vxn.toFixed(2)} > 27 或 VIX/3M ${vr.toFixed(3)} >= 1.02）—— 严禁在恐慌高波区新开任何槽位`;
  } else if (targetSlots > effActiveTr.length && !cooldownPassed) {
    const remWait = Math.max(1, reqGap - (daysSinceLast ?? 0));
    t1Code = 'COOLDOWN_WAIT';
    t1Tone = 'cooldown';
    t1BadgeEn = `T+1 OPEN: COOLDOWN WAIT (${daysSinceLast}D / ${reqGap}D · ${remWait}D LEFT)`;
    t1BadgeZh = `T+1 开盘指令：加仓冷却期等待中（距上槽 ${daysSinceLast}/${reqGap} 天 · 还需 ${remWait} 天）`;
    t1TitleEn = `Score ${Math.round(prob)}% Wants ${targetSlots} Slots, Waiting ${remWait} Calendar Days for ${reqGap}D Step Cooldown`;
    t1TitleZh = `综合概率 ${Math.round(prob)}% 指向 ${targetSlots} 槽，当前距上一槽仅 ${daysSinceLast} 天（未满 ${reqGap} 天冷却期，暂缓加槽）`;
  } else if (activeSlots > 0) {
    const rollNoteEn = isRoll50 ? ' · ROLL @ <=50 DTE' : '';
    const rollNoteZh = isRoll50 ? ' · 剩<=50天滚仓' : '';
    t1Code = 'HOLD_ACTIVE_SLOTS';
    t1Tone = 'active';
    t1BadgeEn = `T+1 OPEN: HOLD ${activeSlots}/${maxSlots} ACTIVE PUT SLOT(S) · MONITOR TP${rollNoteEn}`;
    t1BadgeZh = `T+1 开盘指令：继续持有 ${activeSlots}/${maxSlots} 槽在途 Put · 盯紧止盈线${rollNoteZh}`;
    t1TitleEn = `${activeSlots}/${maxSlots} Equal-Dollar ${entryDte}D Put Slot(s) Shielding 100% Uncapped QQQ Core`;
    t1TitleZh = `当前 ${activeSlots}/${maxSlots} 槽等金额 ${entryDte}D 裸 Put 在途护航 · 100% QQQ 底仓无封顶持有`;
  } else {
    t1Code = 'STANDBY';
    t1Tone = 'standby';
    if (redlineBlocked) {
      t1BadgeEn = 'T+1 OPEN: STANDBY (100% QQQ · HIGH-VOL REDLINE FREEZE)';
      t1BadgeZh = 'T+1 开盘指令：空盾待命（100% 满仓 QQQ · 恐慌高波红线冻结禁买）';
      t1TitleEn = `Score ${Math.round(prob)}% (<35%) & High-IV Redline Active (VXN ${vxn.toFixed(1)}, VIX/3M ${vr.toFixed(3)}) — Hold 100% QQQ Uncapped`;
      t1TitleZh = `危机概率 ${Math.round(prob)}% (<35%) 且处于高波红线区（VXN ${vxn.toFixed(1)}、VIX/3M ${vr.toFixed(3)}）—— 100% QQQ 零损耗待弹`;
    } else {
      t1BadgeEn = 'T+1 OPEN: STANDBY · ZERO PUT SPEND (100% QQQ CRUISE)';
      t1BadgeZh = 'T+1 开盘指令：静默待命 · 零保费损耗（100% 满仓 QQQ 复利巡航）';
      t1TitleEn = `Composite Crisis Score ${Math.round(prob)}% (< 35% Threshold) — Zero Option Drag, 100% QQQ Compounding`;
      t1TitleZh = `三支柱综合危机概率 ${Math.round(prob)}%（低于 35% 开仓线）—— 零期权保费损耗，100% QQQ 顺风复利`;
    }
  }

  const tauCalc = entryDte / 365.0;
  const k10 = cl * 0.9;
  const k15 = cl * 0.85;
  const k20 = cl * 0.8;
  const iv10 = evalSkewIv(cl, k10, tauCalc, rCur, qCur, vxn, coeffs);
  const iv15 = evalSkewIv(cl, k15, tauCalc, rCur, qCur, vxn, coeffs);
  const iv20 = evalSkewIv(cl, k20, tauCalc, rCur, qCur, vxn, coeffs);
  const mid10 = bsmPrice(cl, k10, tauCalc, rCur, qCur, iv10, 'put');
  const mid15 = bsmPrice(cl, k15, tauCalc, rCur, qCur, iv15, 'put');
  const mid20 = bsmPrice(cl, k20, tauCalc, rCur, qCur, iv20, 'put');
  const ask10Ref = mid10 * 1.025;
  const ask15 = mid15 * (1.0 + OPT_SLIP) + OPT_COMM_PER_SH;
  const ask20 = mid20 * (1.0 + OPT_SLIP) + OPT_COMM_PER_SH;
  const skewRatio = iv20 / Math.max(iv10, 1e-6);
  const favorable20 = skewRatio <= 1.18;
  const selAsk = putOtm === 'otm20' ? ask20 : ask15;
  const selK = putOtm === 'otm20' ? k20 : k15;
  const budget1000 = 500.0 * ask10Ref;
  const contracts1000 = budget1000 / Math.max(selAsk, 1e-6) / 100.0;

  const sizingCalc = {
    qqq_spot: r2(cl),
    vxn: r2(vxn),
    dte: entryDte,
    roll_dte: rollDte,
    roll_mode: rollMode,
    selected_otm: putOtm,
    formula_en:
      `Per-Slot Budget = Current QQQ Shares × 50% × Ask(${entryDte}D -10% OTM Put)` +
      (isRoll50 ? ' · Salvage/Roll at <= 50 DTE' : ''),
    formula_zh:
      `单槽美元预算 = 当前持有 QQQ 股数 × 50% × ${entryDte}-DTE -10% OTM Put 卖一价(Ask)` +
      (isRoll50 ? ' · 剩 <=50 DTE 残值滚仓/平仓' : ''),
    ref_otm10: { otm_pct: 10, strike: r2(k10), iv_pct: r2(iv10 * 100.0), mid_sh: r2(mid10), ask_sh: r2(ask10Ref) },
    otm15: { otm_pct: 15, strike: r2(k15), iv_pct: r2(iv15 * 100.0), mid_sh: r2(mid15), ask_sh: r2(ask15) },
    otm20: { otm_pct: 20, strike: r2(k20), iv_pct: r2(iv20 * 100.0), mid_sh: r2(mid20), ask_sh: r2(ask20) },
    skew_ratio_20_10: r3(skewRatio),
    skew_switch_threshold: 1.18,
    favorable_otm20_skew: favorable20,
    skew_tip_en: favorable20
      ? `Tail Skew Favorable: IV(-20%)/IV(-10%) = ${skewRatio.toFixed(3)} <= 1.18 — switching equal budget to -20% OTM offers superior crash convexity!`
      : `Steep Tail Skew: IV(-20%)/IV(-10%) = ${skewRatio.toFixed(3)} > 1.18 — keep default -15% OTM to avoid overpaying deep-tail skew.`,
    skew_tip_zh: favorable20
      ? `偏度性价比极佳：当前 IV(-20%)/IV(-10%) = ${skewRatio.toFixed(3)} <= 1.18 —— 等金额切换至 -20% OTM 可获更高崩盘凸性赔率！`
      : `尾部偏度较陡：当前 IV(-20%)/IV(-10%) = ${skewRatio.toFixed(3)} > 1.18 —— 建议维持默认 -15% OTM，避免为深虚值高偏度溢价买单。`,
    default_qqq_shares: 1000,
    model_qqq_shares: r2(Number(m7Sim.summary.final_shares ?? 1000)),
    sample_1000sh_budget_usd: r2(budget1000),
    sample_1000sh_selected_strike: r2(selK),
    sample_1000sh_selected_ask: r2(selAsk),
    sample_1000sh_contracts: r2(contracts1000),
  };

  const tpSpec = M7_TP_SPECS[m7TpMode] ?? M7_TP_SPECS.standard;
  const tpRuleEn =
    (m7TpMode === 'itm_tp'
      ? `Exit at T+1 Open when EOD (VIX/VIX3M >= 1.10 AND QQQ <= Strike Kp) OR (DTE <= ${fiveXDte} AND Put Mid >= 5x Cost)`
      : `Exit at T+1 Open when EOD VIX/VIX3M >= 1.10 OR (DTE <= ${fiveXDte} AND Put Mid >= 5x Cost)`) +
    (isRoll50 ? '; else at DTE <= 50 salvage residual (and roll into fresh 120D Put if M7 stays active).' : '.');
  const tpRuleZh =
    (m7TpMode === 'itm_tp'
      ? `收盘同时满足（VIX/VIX3M >= 1.10 且 QQQ <= 行权价 Kp 实值），或（DTE <= ${fiveXDte} 且中间价 >= 5 倍成本）次日开盘止盈`
      : `收盘触发 VIX/VIX3M >= 1.10 恐慌倒挂，或（DTE <= ${fiveXDte} 且期权中间价 >= 5 倍成本）次日开盘止盈`) +
    (isRoll50 ? '；未止盈且 DTE <= 50 时次日开盘回收残值（信号仍亮则同步滚入新 120D Put）。' : '。');

  const tpSlotsLive = activeTr.map(tr => {
    const kpTr = Number(tr.kp);
    const remTr = Number(tr.rem_dte);
    const isItm = cl <= kpTr;
    const tpVixOk = vr >= 1.1 && (m7TpMode === 'itm_tp' ? isItm : true);
    const tp5xOk = remTr <= fiveXDte && Number(tr.mtm_put_val_sh) >= Number(tr.tp_target_5x_sh);
    const roll50Due = Boolean(isRoll50 && remTr <= 50 && !tpVixOk && !tp5xOk);
    return {
      slot_num: tr.slot_num,
      entry_date: tr.entry_date,
      exp_date: tr.exp_date,
      rem_dte: remTr,
      days_to_roll50: isRoll50 ? Math.max(0, remTr - 50) : null,
      roll50_due: roll50Due,
      kp: kpTr,
      spot_vs_kp_pct: r2((cl / kpTr - 1.0) * 100.0),
      is_itm: isItm,
      entry_ask_sh: tr.entry_put_ask_sh,
      current_mid_sh: tr.mtm_put_val_sh,
      target_5x_mid_sh: tr.tp_target_5x_sh,
      roi_mult: tr.roi_mult,
      mtm_pnl_usd: tr.mtm_pnl_usd,
      vix_leg_met: tpVixOk,
      five_x_leg_met: tp5xOk,
      pending_tp: Boolean(tr.pending_tp),
      tp_reason: tr.tp_reason || '',
    };
  });

  const tpMonitor = {
    tp_mode: m7TpMode,
    tp_code: tpSpec.code,
    roll_mode: rollMode,
    five_x_max_dte: fiveXDte,
    roll_dte: rollDte,
    label_en: tpSpec.label_en,
    label_zh: tpSpec.label_zh,
    rule_en: tpRuleEn,
    rule_zh: tpRuleZh,
    vix_ratio_now: r3(vr),
    vix_ratio_target: 1.1,
    vix_ratio_met: vr >= 1.1,
    qqq_spot_now: r2(cl),
    simulated_next_slot_kp: r2(selK),
    simulated_next_slot_5x_mid: r2(5.0 * selAsk),
    open_slots: tpSlotsLive,
  };

  const fv = (k, defVal = 0.0) => {
    const v = featRow?.[k];
    return v === null || v === undefined || !Number.isFinite(Number(v)) ? defVal : Number(v);
  };
  const fmtSigned = (n, dec = 2) => `${n >= 0 ? '+' : ''}${n.toFixed(dec)}`;
  const rspSpyV = fv('rsp_spy');
  const rspSmaV = fv('rsp_sma50');
  const iwmQqqV = fv('iwm_qqq');
  const iwmSmaV = fv('iwm_sma50');
  const defRet20Pct = fv('def_ret20') * 100.0;
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
  const baaRV = fv('baa_rise63');
  const dgs2JV = fv('dgs2_jump63');
  const nfciJV = fv('nfci_jump20');
  const adDiffInt = Math.round(adLine - adSma50);

  const pillars = [
    {
      id: 'P1',
      title_en: 'Pillar 1 · Calm-Top Fragility',
      title_zh: '第一支柱 P1 · 高位脆弱与顶背离',
      subtitle_en: 'Detects stealth breadth decay & defensive rotation near highs while IV is cheap',
      subtitle_zh: '捕捉指数高位横盘期内部宽度恶化与防御板块暗中抢跑（低波潜伏买盾）',
      score: Math.round(p1),
      cap: 45,
      modules: [
        {
          id: 'M0',
          name_en: 'M0 Six Lights Baseline',
          name_zh: 'M0 六灯基线开关',
          points: 35,
          earned_points: sigDay.M0 ? 35 : 0,
          triggered: Boolean(sigDay.M0),
          pluggable: true,
          enabled: m0Enabled,
          vol_gate_passed: vxn <= 22.0,
          vol_gate_en: `VXN ${vxn.toFixed(2)} <= 22.0`,
          vol_gate_zh: `VXN ${vxn.toFixed(2)} <= 22.0 低波门控`,
          metrics: [
            {
              label_en: 'QQQ vs ATH',
              label_zh: 'QQQ 距历史前高',
              value: `${fmtSigned(ddPct, 2)}% ($${cl.toFixed(2)})`,
              threshold: '>= -5.00% (0.95*ATH)',
              passed: ddPct >= -5.0,
            },
            {
              label_en: 'A-D Line < SMA50',
              label_zh: '腾落线 AD < 50DMA',
              value: `${adDiffInt >= 0 ? '+' : ''}${adDiffInt.toLocaleString('en-US')}`,
              threshold: '< 0',
              passed: Boolean(m0Enabled && adBelow),
            },
            {
              label_en: 'Macro Crisis Lights',
              label_zh: '宏观六灯亮灯数',
              value: `${sc} / 6`,
              threshold: '>= 4 / 6',
              passed: Boolean(m0Enabled && sc >= 4),
            },
          ],
        },
        {
          id: 'M6',
          name_en: 'M6 Breadth + Defensive Rotation',
          name_zh: 'M6 宽度恶化 + 防御轮动',
          points: 20,
          earned_points: sigDay.M6 ? 20 : 0,
          triggered: Boolean(sigDay.M6),
          pluggable: false,
          enabled: true,
          vol_gate_passed: vxn <= 25.0 && vr <= 0.92,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=25 & VIX/3M ${vr.toFixed(3)}<=0.92`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=25 且 VIX/3M ${vr.toFixed(3)}<=0.92`,
          metrics: [
            {
              label_en: 'RSP/SPY vs SMA50',
              label_zh: '等权 RSP/SPY vs 50DMA',
              value: `${rspSpyV.toFixed(4)} vs ${rspSmaV.toFixed(4)}`,
              threshold: '< SMA50',
              passed: rspSmaV > 0 && rspSpyV < rspSmaV,
            },
            {
              label_en: 'IWM/QQQ (<SMA50 or AD)',
              label_zh: '小盘 IWM/QQQ (<50DMA 或 AD弱)',
              value: `${iwmQqqV.toFixed(4)} vs ${iwmSmaV.toFixed(4)}`,
              threshold: `< SMA50${m0Enabled ? ' or AD<50D' : ''}`,
              passed: (iwmSmaV > 0 && iwmQqqV < iwmSmaV) || (m0Enabled && adBelow),
            },
            {
              label_en: '(XLP+XLU+XLV)/XLK 20D',
              label_zh: '防御/科技 20日超额轮动',
              value: `${fmtSigned(defRet20Pct, 2)}%`,
              threshold: '>= +2.50%',
              passed: defRet20Pct >= 2.5,
            },
          ],
        },
      ],
    },
    {
      id: 'P2',
      title_en: 'Pillar 2 · Exogenous Shock Ignition',
      title_zh: '第二支柱 P2 · 外生黑天鹅启爆',
      subtitle_en: 'Requires dual-sensor consensus (M2 + M5 = 40% >= 35%) to catch sudden shocks like 2020-01-28',
      subtitle_zh: '要求期权台偏度与因果 HMM 双传感器共振（20+20=40% >= 35%），精准捕获 2020-01-28 等突发黑天鹅',
      score: Math.round(p2),
      cap: 40,
      modules: [
        {
          id: 'M2',
          name_en: 'M2 Options Desk Warning',
          name_zh: 'M2 期权台尾部预警',
          points: 20,
          earned_points: sigDay.M2 ? 20 : 0,
          triggered: Boolean(sigDay.M2),
          pluggable: false,
          enabled: true,
          vol_gate_passed: vxn <= 24.0,
          vol_gate_en: `VXN ${vxn.toFixed(2)} <= 24.0`,
          vol_gate_zh: `VXN ${vxn.toFixed(2)} <= 24.0`,
          metrics: [
            {
              label_en: 'A) Silent Tail (SKEW10 & VVIX)',
              label_zh: 'A) 静默买尾 (SKEW10 & VVIX>=P75)',
              value: `SKEW ${skew10V.toFixed(1)}/${skewP75V.toFixed(1)} · VVIX ${vvixV.toFixed(1)}/${vvixP75V.toFixed(1)}`,
              threshold: '>=252D P75 & 0.85<=V/V3M<=0.98',
              passed: Boolean(sigDay.M2_silent_tail),
            },
            {
              label_en: 'B) Term Inflection (5D Jump)',
              label_zh: 'B) 期限拐点 (5日跃升 & VVIX>=100)',
              value: `Δ5D ${fmtSigned(vrJ5V, 3)} · VVIX ${vvixV.toFixed(1)}`,
              threshold: '0.92..1.02 & Δ>=+0.06 & VVIX>=100',
              passed: Boolean(sigDay.M2_term_inflection),
            },
          ],
        },
        {
          id: 'M5',
          name_en: 'M5 Causal HMM Regime Transition',
          name_zh: 'M5 因果 HMM 状态跃迁',
          points: 20,
          earned_points: sigDay.M5 ? 20 : 0,
          triggered: Boolean(sigDay.M5),
          pluggable: false,
          enabled: true,
          vol_gate_passed: vxn <= 24.0 && vr < 1.02,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=24 & VIX/3M ${vr.toFixed(3)}<1.02`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=24 且 VIX/3M ${vr.toFixed(3)}<1.02`,
          metrics: [
            {
              label_en: 'Hamilton P_t(Stress)',
              label_zh: '当前高压态后验概率 P_t',
              value: `${(hmmPV * 100.0).toFixed(1)}%`,
              threshold: '>= 55.0%',
              passed: hmmPV >= 0.55,
            },
            {
              label_en: '5D Prior P_{t-5}(Stress)',
              label_zh: '5日前后验概率 P_{t-5}（新鲜跃迁）',
              value: `${(hmmP5V * 100.0).toFixed(1)}%`,
              threshold: '< 40.0%',
              passed: hmmP5V < 0.4,
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
      cap: 45,
      modules: [
        {
          id: 'M4',
          name_en: 'M4 CTA Bear-Rally Complacency',
          name_zh: 'M4 CTA 熊市反弹自满',
          points: 35,
          earned_points: sigDay.M4 ? 35 : 0,
          triggered: Boolean(sigDay.M4),
          pluggable: false,
          enabled: true,
          vol_gate_passed: vxn <= 27.0 && vr <= 0.88,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=27 & VIX/3M ${vr.toFixed(3)}<=0.88`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=27 且 VIX/3M ${vr.toFixed(3)}<=0.88`,
          metrics: [
            {
              label_en: 'QQQ < SMA200',
              label_zh: '熊市主趋势 QQQ < 200DMA',
              value: `$${cl.toFixed(2)} vs $${sma200V.toFixed(2)}`,
              threshold: '< SMA200',
              passed: sma200V > 0 && cl < sma200V,
            },
            {
              label_en: '3-Speed EWMAC (16/32/64)',
              label_zh: '三速 EWMAC 趋势均值',
              value: fmtSigned(ewmacV, 2),
              threshold: '< 0.00',
              passed: ewmacV < 0.0,
            },
            {
              label_en: 'Bear Bounce QQQ > EMA20',
              label_zh: '死猫跳反弹 QQQ > EMA20',
              value: `$${cl.toFixed(2)} vs $${ema20V.toFixed(2)}`,
              threshold: '> EMA20',
              passed: ema20V > 0 && cl > ema20V,
            },
          ],
        },
        {
          id: 'M3',
          name_en: 'M3 Credit & Macro Stress (FRED PIT)',
          name_zh: 'M3 信用利差与宏观压力 (FRED 严格滞后)',
          points: 20,
          earned_points: sigDay.M3 ? 20 : 0,
          triggered: Boolean(sigDay.M3),
          pluggable: false,
          enabled: true,
          vol_gate_passed: vxn <= 26.0 && vr <= 0.92,
          vol_gate_en: `VXN ${vxn.toFixed(1)}<=26 & VIX/3M ${vr.toFixed(3)}<=0.92`,
          vol_gate_zh: `VXN ${vxn.toFixed(1)}<=26 且 VIX/3M ${vr.toFixed(3)}<=0.92`,
          metrics: [
            {
              label_en: 'HYG/LQD < SMA50',
              label_zh: '高收益/投资级 HYG/LQD < 50DMA',
              value: `${hygV.toFixed(4)} vs ${hygSmaV.toFixed(4)}`,
              threshold: '< SMA50',
              passed: hygSmaV > 0 && hygV < hygSmaV,
            },
            {
              label_en: 'BAA10Y (+1d lag) 63D Widening',
              label_zh: 'Baa利差 (+1日滞后) 63D走阔',
              value: `${baaV.toFixed(2)}% (${fmtSigned(baaRV * 100.0, 0)}bp)`,
              threshold: '>= +15bp (+0.15)',
              passed: baaRV >= 0.15,
            },
            {
              label_en: 'DGS2 (+1d) 63D / NFCI (+5d) 20D',
              label_zh: '2Y美债(+1日)63D / NFCI(+5日)20D',
              value: `2Y ${fmtSigned(dgs2JV * 100.0, 0)}bp · NFCI ${fmtSigned(nfciJV, 2)}`,
              threshold: '2Y>=+40bp OR NFCI>=+0.10',
              passed: dgs2JV >= 0.4 || nfciJV >= 0.1,
            },
          ],
        },
      ],
    },
  ];

  return {
    as_of_date: d,
    strategy_id: m7Sim.summary.id,
    put_otm: putOtm,
    m7_tp_mode: m7TpMode,
    roll_mode: rollMode,
    m0_enabled: m0Enabled,
    crisis_prob: Math.round(prob),
    p1_score: Math.round(p1),
    p2_score: Math.round(p2),
    p3_score: Math.round(p3),
    target_slots: targetSlots,
    active_slots: activeSlots,
    max_slots: maxSlots,
    triggered_modules: modsActive,
    trigger_code: modsActive.length ? trigCode : 'NONE',
    tier_rule_en: '<35%: 0 Slots · 35-44%: 1 Slot · 45-64%: 2 Slots · >=65%: 3 Slots',
    tier_rule_zh: '<35%：0槽 · 35–44%：1槽 · 45–64%：2槽 · >=65%：3槽满配',
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

function alignFredLagForIndex(fredMap, calDates, idx, lagDays) {
  const srcIdx = Math.max(0, idx - lagDays);
  const targetDate = calDates[srcIdx];
  let bestDate = '';
  let bestVal = null;
  for (const [dt, val] of Object.entries(fredMap)) {
    if (dt <= targetDate && dt > bestDate && Number.isFinite(val)) {
      bestDate = dt;
      bestVal = val;
    }
  }
  return bestVal;
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
  };
  for (const fid of Object.keys(FRED_LAGS)) {
    const incoming = liveFeed?.fred?.[fid];
    if (incoming && typeof incoming === 'object') {
      for (const [dt, val] of Object.entries(incoming)) {
        if (Number.isFinite(val)) fredRaw[fid][dt] = val;
      }
    }
  }

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

  for (const d of newDates) {
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

    // FRED lagged values
    const baaNow = alignFredLagForIndex(fredRaw.BAA10Y, calDates, idx, 1);
    const dgs2Now = alignFredLagForIndex(fredRaw.DGS2, calDates, idx, 1);
    const nfciNow = alignFredLagForIndex(fredRaw.NFCI, calDates, idx, 5);
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
    const sc = Number(prevEval.score);
    const m0Raw = athOk && (adBelow || sc >= 4) && vxn <= 22.0;

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
        redline_blocked: vxn > 27.0 || vr >= 1.02,
        hmm_p: r4(hpCur),
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
    };
    featRows.push(featObj);
    newDailyRowsMeta.push({ evalBar: nextEvalBar, sigOn: sOn, sigOff: sOff, feat: featObj, sma200Now });
  }

  return { evalBars, sigM0On, sigM0Off, featRows, newDailyRowsMeta };
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

async function fetchFredRecent(seriesId) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5500);
  try {
    const resp = await fetch(`https://fred.stlouisfed.org/graph/fredgraph.csv?id=${seriesId}`, {
      headers: { 'User-Agent': 'Mozilla/5.0' },
      signal: controller.signal,
    });
    if (!resp.ok) return null;
    const txt = await resp.text();
    const tailTxt = txt.length > 6000 ? txt.slice(-6000) : txt;
    const lines = tailTxt.split(/\r?\n/);
    const out = {};
    for (const line of lines) {
      const parts = line.split(',');
      if (parts.length < 2) continue;
      const d = parts[0].trim();
      if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) continue;
      const v = Number(parts[1].trim());
      if (Number.isFinite(v)) out[d] = v;
    }
    return out;
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
      const yfKeys = Object.keys(YF_SYMBOL_MAP);
      const fredKeys = Object.keys(FRED_LAGS);
      const [yfResults, fredResults] = await Promise.all([
        Promise.all(yfKeys.map(k => fetchYahooChart15d(YF_SYMBOL_MAP[k]))),
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
