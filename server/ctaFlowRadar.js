import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const CTA_FLOW_RADAR_VERSION = 'cta-flow-radar-v1';
export const CTA_RADAR_ASSETS = Object.freeze(['SPY', 'QQQ']);
export const CTA_RADAR_HORIZONS = Object.freeze(['5D', '10D']);

const EWMAC_CONFIGS = Object.freeze([
  [2, 8, 10.6],
  [4, 16, 7.5],
  [8, 32, 5.3],
  [16, 64, 3.75],
  [32, 128, 2.65],
  [64, 256, 1.87],
]);
const CARVER_FDM = 1.26;
const SMA_WINDOWS = Object.freeze([10, 20, 50, 100, 200]);
const SMA_WEIGHTS = Object.freeze([0.1, 0.2, 0.25, 0.25, 0.2]);
const SHOCK_GRID_PCT = Object.freeze([-5, -3, -2, -1, 0, 1, 2, 3, 5]);
const FINE_GRID_PCT = Object.freeze(Array.from({ length: 65 }, (_, i) => Math.round((-8 + 0.25 * i) * 10000) / 10000));
const CURVE_MIN_PCT = -6;
const CURVE_MAX_PCT = 6;
const SQRT_252 = Math.sqrt(252);

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultFile = path.resolve(projectRoot, 'server/config/cta-flow-radar-dashboard.json');

let cachedArtifact = null;
const liveFeedCache = { fetchedAt: 0, byDate: null };
const LIVE_FEED_TTL_MS = 15 * 60 * 1000;

function fail(code, status = 503) {
  throw Object.assign(new Error(code), { status });
}

const isIsoDate = value =>
  /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;

const clip = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
const r2 = v => (Number.isFinite(v) ? Math.round(v * 100) / 100 : null);
const r3 = v => (Number.isFinite(v) ? Math.round(v * 1000) / 1000 : null);

function sampleStd(arr) {
  const n = arr.length;
  if (n < 2) return 0;
  let sum = 0;
  for (let i = 0; i < n; i += 1) sum += arr[i];
  const mean = sum / n;
  let sq = 0;
  for (let i = 0; i < n; i += 1) {
    const d = arr[i] - mean;
    sq += d * d;
  }
  return Math.sqrt(sq / (n - 1));
}

function readArtifact(file = defaultFile) {
  const resolved = path.resolve(file);
  let stat;
  try {
    stat = fs.statSync(resolved);
  } catch {
    fail('cta_flow_radar_unavailable', 503);
  }
  const cacheKey = `${resolved}:${stat.mtimeMs}:${stat.size}`;
  if (cachedArtifact?.key === cacheKey) return cachedArtifact;

  let raw;
  let parsed;
  try {
    raw = fs.readFileSync(resolved, 'utf8');
    parsed = JSON.parse(raw);
  } catch {
    fail('cta_flow_radar_corrupt', 503);
  }
  if (parsed?.version !== CTA_FLOW_RADAR_VERSION || !parsed?.assets?.SPY || !parsed?.assets?.QQQ) {
    fail('cta_flow_radar_version_mismatch', 503);
  }
  const snapshotId = createHash('sha256').update(raw).digest('hex').slice(0, 16);
  cachedArtifact = { key: cacheKey, snapshotId, data: parsed };
  return cachedArtifact;
}

function normalizeAsset(raw) {
  if (!raw) return 'SPY';
  const upper = String(raw).trim().toUpperCase();
  if (!CTA_RADAR_ASSETS.includes(upper)) fail('invalid_cta_asset', 400);
  return upper;
}

function normalizeHorizon(raw) {
  if (!raw) return '10D';
  const upper = String(raw).trim().toUpperCase();
  if (upper === '5' || upper === '5D' || upper === '1W') return '5D';
  if (upper === '10' || upper === '10D' || upper === '2W') return '10D';
  fail('invalid_cta_horizon', 400);
}

function interpLinear(x, xs, ys) {
  if (x <= xs[0]) return ys[0];
  if (x >= xs[xs.length - 1]) return ys[ys.length - 1];
  let lo = 0;
  let hi = xs.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (xs[mid] <= x) lo = mid;
    else hi = mid;
  }
  const x0 = xs[lo];
  const x1 = xs[hi];
  if (Math.abs(x1 - x0) < 1e-12) return ys[lo];
  const w = (x - x0) / (x1 - x0);
  return ys[lo] + w * (ys[hi] - ys[lo]);
}

function findThresholdStrikePct(fineGrid, flowRow, thresholdB, direction = 'down') {
  const zeroIdx = fineGrid.indexOf(0);
  if (zeroIdx < 0) return null;
  if (direction === 'down') {
    for (let j = zeroIdx; j >= 0; j -= 1) {
      if (flowRow[j] <= thresholdB) {
        if (j === zeroIdx) return 0;
        const f1 = flowRow[j + 1];
        const f0 = flowRow[j];
        const g1 = fineGrid[j + 1];
        const g0 = fineGrid[j];
        const w = Math.abs(f0 - f1) > 1e-9 ? (thresholdB - f1) / (f0 - f1) : 0;
        return g1 + w * (g0 - g1);
      }
    }
    return null;
  }
  for (let j = zeroIdx; j < fineGrid.length; j += 1) {
    if (flowRow[j] >= thresholdB) {
      if (j === zeroIdx) return 0;
      const f0 = flowRow[j - 1];
      const f1 = flowRow[j];
      const g0 = fineGrid[j - 1];
      const g1 = fineGrid[j];
      const w = Math.abs(f1 - f0) > 1e-9 ? (thresholdB - f0) / (f1 - f0) : 0;
      return g0 + w * (g1 - g0);
    }
  }
  return null;
}

function simulateSurfaceFromState(state, gridPct, horizonDays) {
  const gLen = gridPct.length;
  const {
    px0,
    var36,
    longPctVol,
    capCtaB,
    capVcB,
    posCarverB,
    posSmaB,
    posHybridB,
    posVcB,
    trailingPx200,
    trailingRet60,
    emaFast,
    emaSlow,
    ctaTargetVol,
    vcTargetVol,
  } = state;

  const shortAsym = 0.65;
  const maxLev = 1.65;
  const alphaVol = 2 / 37;
  const eta = 0.5;
  const afList = EWMAC_CONFIGS.map(c => 2 / (c[0] + 1));
  const asList = EWMAC_CONFIGS.map(c => 2 / (c[1] + 1));
  const scList = EWMAC_CONFIGS.map(c => c[2]);

  const histSmaSums = new Map();
  for (const wLen of SMA_WINDOWS) {
    const maxH = Math.min(horizonDays, wLen - 1);
    for (let hCnt = 1; hCnt <= maxH; hCnt += 1) {
      const need = wLen - hCnt;
      let s = 0;
      for (let i = trailingPx200.length - need; i < trailingPx200.length; i += 1) s += trailingPx200[i];
      histSmaSums.set(`${wLen}:${hCnt}`, s);
    }
  }

  const flowCarverB = new Array(gLen);
  const flowSmaB = new Array(gLen);
  const flowVcB = new Array(gLen);
  const flowCombinedB = new Array(gLen);
  const endFCarver = new Array(gLen);
  const endFSma = new Array(gLen);

  for (let gIdx = 0; gIdx < gLen; gIdx += 1) {
    const rTot = gridPct[gIdx] / 100;
    let varCur = var36;
    let prevP = px0;
    const ef = emaFast.slice();
    const es = emaSlow.slice();
    let posC = posCarverB;
    let posS = posSmaB;
    let posH = posHybridB;
    let posV = posVcB;
    const futPx = [];
    const futRet = [];
    let fC = 0;
    let fS = 0;

    for (let h = 0; h < horizonDays; h += 1) {
      const hCnt = h + 1;
      const pH = px0 * (1 + rTot * (hCnt / horizonDays));
      const dpH = pH - prevP;
      const rH = dpH / Math.max(prevP, 1e-8);
      futPx.push(pH);
      futRet.push(rH);

      varCur = (1 - alphaVol) * varCur + alphaVol * dpH * dpH;
      const annV36 = (Math.sqrt(varCur) / pH) * SQRT_252;
      const annVCarver = Math.max(0.7 * annV36 + 0.3 * longPctVol, 0.07);
      const sigPB = Math.max((annVCarver / SQRT_252) * pH, 1e-8);

      let fSum = 0;
      for (let k = 0; k < 6; k += 1) {
        ef[k] = afList[k] * pH + (1 - afList[k]) * ef[k];
        es[k] = asList[k] * pH + (1 - asList[k]) * es[k];
        fSum += clip((scList[k] * (ef[k] - es[k])) / sigPB, -20, 20);
      }
      fC = clip(CARVER_FDM * (fSum / 6), -20, 20);

      let futSum = 0;
      for (let m = 0; m < futPx.length; m += 1) futSum += futPx[m];
      let smaAcc = 0;
      for (let mIdx = 0; mIdx < SMA_WINDOWS.length; mIdx += 1) {
        const wLen = SMA_WINDOWS[mIdx];
        let smVal;
        if (hCnt >= wLen) {
          let sub = 0;
          for (let q = hCnt - wLen; q < hCnt; q += 1) sub += futPx[q];
          smVal = sub / wLen;
        } else {
          smVal = (histSmaSums.get(`${wLen}:${hCnt}`) + futSum) / wLen;
        }
        smaAcc += SMA_WEIGHTS[mIdx] * (pH >= smVal ? 1 : -1);
      }
      fS = 20 * smaAcc;
      const fHyb = 0.5 * fC + 0.5 * fS;

      const vSc = ctaTargetVol / annVCarver;
      const buf = 0.1 * capCtaB * Math.min(vSc, maxLev);

      const stepExec = (fNow, curP) => {
        const asym = fNow >= 0 ? 1 : shortAsym;
        const u = clip((fNow / 10) * vSc * asym, -maxLev * shortAsym, maxLev);
        const tgt = capCtaB * u;
        let des = curP;
        if (tgt > curP + buf) des = tgt - buf;
        else if (tgt < curP - buf) des = tgt + buf;
        return (1 - eta) * curP + eta * des;
      };
      posC = stepExec(fC, posC);
      posS = stepExec(fS, posS);
      posH = stepExec(fHyb, posH);

      const r20W = hCnt >= 20 ? futRet.slice(-20) : trailingRet60.slice(-(20 - hCnt)).concat(futRet);
      const r60W = trailingRet60.slice(-(60 - hCnt)).concat(futRet);
      const rv20H = sampleStd(r20W) * SQRT_252;
      const rv60H = sampleStd(r60W) * SQRT_252;
      const vcRat =
        0.6 * clip(vcTargetVol / Math.max(rv20H, 0.08), 0, 1) +
        0.4 * clip(vcTargetVol / Math.max(rv60H, 0.08), 0, 1);
      posV = (1 - eta) * posV + eta * (capVcB * vcRat);
      prevP = pH;
    }

    const fcB = posC - posCarverB;
    const fsB = posS - posSmaB;
    const fvB = posV - posVcB;
    flowCarverB[gIdx] = fcB;
    flowSmaB[gIdx] = fsB;
    flowVcB[gIdx] = fvB;
    flowCombinedB[gIdx] = fcB + fvB;
    endFCarver[gIdx] = fC;
    endFSma[gIdx] = fS;
  }

  return { flowCarverB, flowSmaB, flowVcB, flowCombinedB, endFCarver, endFSma };
}

function buildMatrixRows(pxNow, surfGrid, fineSurf, breakevenPct) {
  const zeroIdx = SHOCK_GRID_PCT.indexOf(0);
  const cZero = surfGrid.flowCarverB[zeroIdx];
  const totZero = surfGrid.flowCombinedB[zeroIdx];
  const rows = SHOCK_GRID_PCT.map((pct, i) => {
    const cVal = surfGrid.flowCarverB[i];
    const totVal = surfGrid.flowCombinedB[i];
    return {
      movePct: pct,
      targetPrice: r2(pxNow * (1 + pct / 100)),
      carverCtaFlowB: r2(cVal),
      marginalCarverFlowB: r2(cVal - cZero),
      smaCtaFlowB: r2(surfGrid.flowSmaB[i]),
      volControlFlowB: r2(surfGrid.flowVcB[i]),
      combinedFlowB: r2(totVal),
      marginalCombinedFlowB: r2(totVal - totZero),
      projectedCarverForecast: r2(surfGrid.endFCarver[i]),
      projectedSmaForecast: r2(surfGrid.endFSma[i]),
      isBaselineRow: pct === 0,
      isBreakevenRow: false,
    };
  });

  if (
    Number.isFinite(breakevenPct) &&
    breakevenPct >= CURVE_MIN_PCT &&
    breakevenPct <= CURVE_MAX_PCT &&
    SHOCK_GRID_PCT.every(p => Math.abs(breakevenPct - p) >= 0.15)
  ) {
    const cBe = interpLinear(breakevenPct, FINE_GRID_PCT, fineSurf.flowCarverB);
    const sBe = interpLinear(breakevenPct, FINE_GRID_PCT, fineSurf.flowSmaB);
    const vBe = interpLinear(breakevenPct, FINE_GRID_PCT, fineSurf.flowVcB);
    const fcBe = interpLinear(breakevenPct, FINE_GRID_PCT, fineSurf.endFCarver);
    const fsBe = interpLinear(breakevenPct, FINE_GRID_PCT, fineSurf.endFSma);
    rows.push({
      movePct: r2(breakevenPct),
      targetPrice: r2(pxNow * (1 + breakevenPct / 100)),
      carverCtaFlowB: r2(cBe),
      marginalCarverFlowB: r2(cBe - cZero),
      smaCtaFlowB: r2(sBe),
      volControlFlowB: r2(vBe),
      combinedFlowB: 0,
      marginalCombinedFlowB: r2(0 - totZero),
      projectedCarverForecast: r2(fcBe),
      projectedSmaForecast: r2(fsBe),
      isBaselineRow: false,
      isBreakevenRow: true,
    });
    rows.sort((a, b) => a.movePct - b.movePct);
  }
  return rows;
}

function stepAssetFromCheckpoint(baseAsset, cpAsset, bars) {
  const ticker = baseAsset.ticker;
  const cal = baseAsset.calibration;
  const ctaCap2026 = cal.ctaRiskCap2026B;
  const ctaTargetVol = cal.ctaTargetVolPct / 100;
  const vcCap2026 = cal.vcAum2026B;
  const vcTargetVol = cal.vcTargetVolPct / 100;
  const sellCliff2026B = cal.sellCliff2026B;
  const sqz5dB = ticker === 'SPY' ? 15 : 10;
  const sqz10dB = ticker === 'SPY' ? 15 : 8;

  const trailingPx200 = cpAsset.trailingPx200.slice();
  const trailingRet60 = cpAsset.trailingRet60.slice();
  let var36 = cpAsset.var36;
  let sumVol2520 = cpAsset.trailingAnnVol2520Sum;
  const head600 = cpAsset.trailingAnnVol2520Head600.slice();
  let headIdx = 0;
  const ef = cpAsset.emaFast.slice();
  const es = cpAsset.emaSlow.slice();
  let posCarverB = cpAsset.posCarverB;
  let posSmaB = cpAsset.posSmaB;
  let posHybridB = cpAsset.posHybridB;
  let posVcB = cpAsset.posVcB;

  const alphaVol = 2 / 37;
  const eta = 0.5;
  const shortAsym = 0.65;
  const maxLev = 1.65;
  const afList = EWMAC_CONFIGS.map(c => 2 / (c[0] + 1));
  const asList = EWMAC_CONFIGS.map(c => 2 / (c[1] + 1));
  const scList = EWMAC_CONFIGS.map(c => c[2]);

  const fPostCp = [];
  const trajAll = [];
  let lastSnapshot = null;

  for (let i = 0; i < bars.length; i += 1) {
    const [dt, spyAdj, spyUnadj, qqqAdj, qqqUnadj, vix, vix3m, ctaMult, vcMult] = bars[i];
    const px = ticker === 'SPY' ? spyAdj : qqqAdj;
    const pxUnadj = ticker === 'SPY' ? spyUnadj : qqqUnadj;
    const prevPx = trailingPx200[trailingPx200.length - 1];
    const dp = px - prevPx;
    const ret = prevPx > 0 ? dp / prevPx : 0;

    trailingPx200.push(px);
    if (trailingPx200.length > 200) trailingPx200.shift();
    trailingRet60.push(ret);
    if (trailingRet60.length > 60) trailingRet60.shift();

    var36 = (1 - alphaVol) * var36 + alphaVol * dp * dp;
    const annPctVol36 = (Math.sqrt(var36) / px) * SQRT_252;
    const dropped = headIdx < head600.length ? head600[headIdx] : annPctVol36;
    headIdx += 1;
    sumVol2520 = sumVol2520 - dropped + annPctVol36;
    const longPctVol = sumVol2520 / 2520;
    const annVolCarver = Math.max(0.7 * annPctVol36 + 0.3 * longPctVol, 0.07);
    const sigPBlend = Math.max((annVolCarver / SQRT_252) * px, 1e-8);

    const fIndiv = new Array(6);
    const flip1dPx = new Array(6);
    let fSum = 0;
    for (let k = 0; k < 6; k += 1) {
      ef[k] = afList[k] * px + (1 - afList[k]) * ef[k];
      es[k] = asList[k] * px + (1 - asList[k]) * es[k];
      fIndiv[k] = clip((scList[k] * (ef[k] - es[k])) / sigPBlend, -20, 20);
      flip1dPx[k] = ((1 - asList[k]) * es[k] - (1 - afList[k]) * ef[k]) / (afList[k] - asList[k]);
      fSum += fIndiv[k];
    }
    const fCarver = clip(CARVER_FDM * (fSum / 6), -20, 20);
    fPostCp.push(fCarver);

    const smaVals = SMA_WINDOWS.map(wLen => {
      let s = 0;
      for (let q = trailingPx200.length - wLen; q < trailingPx200.length; q += 1) s += trailingPx200[q];
      return s / wLen;
    });
    let smaAcc = 0;
    for (let m = 0; m < SMA_WINDOWS.length; m += 1) {
      smaAcc += SMA_WEIGHTS[m] * (px >= smaVals[m] ? 1 : -1);
    }
    const fSma = 20 * smaAcc;
    const fHybrid = 0.5 * fCarver + 0.5 * fSma;

    const capCtaB = ctaCap2026 * ctaMult;
    const capVcB = vcCap2026 * vcMult;
    const volScalar = ctaTargetVol / annVolCarver;
    const bufB = 0.1 * capCtaB * Math.min(volScalar, maxLev);

    const stepPos = (fNow, prevExec) => {
      const asym = fNow >= 0 ? 1 : shortAsym;
      const u = clip((fNow / 10) * volScalar * asym, -maxLev * shortAsym, maxLev);
      const tgt = capCtaB * u;
      let des = prevExec;
      if (tgt > prevExec + bufB) des = tgt - bufB;
      else if (tgt < prevExec - bufB) des = tgt + bufB;
      return { tgt, exec: (1 - eta) * prevExec + eta * des };
    };

    const cStep = stepPos(fCarver, posCarverB);
    const sStep = stepPos(fSma, posSmaB);
    const hStep = stepPos(fHybrid, posHybridB);
    posCarverB = cStep.exec;
    posSmaB = sStep.exec;
    posHybridB = hStep.exec;

    const rv20 = sampleStd(trailingRet60.slice(-20)) * SQRT_252;
    const rv60 = sampleStd(trailingRet60) * SQRT_252;
    const vcRat =
      0.6 * clip(vcTargetVol / Math.max(rv20, 0.08), 0, 1) +
      0.4 * clip(vcTargetVol / Math.max(rv60, 0.08), 0, 1);
    posVcB = (1 - eta) * posVcB + eta * (capVcB * vcRat);

    const posCombinedB = posCarverB + posVcB;
    const prevCombined = trajAll.length ? trajAll[trajAll.length - 1].posCombinedB : posCombinedB;
    const vixRatio = vix3m > 0 ? vix / vix3m : 0.9;
    trajAll.push({
      date: dt,
      close: r2(pxUnadj),
      pxAdj: px,
      fCarver: r2(fCarver),
      fSma: r2(fSma),
      posCarverB: r2(posCarverB),
      posVcB: r2(posVcB),
      posCombinedB: r2(posCombinedB),
      dailyFlowB: r2(posCombinedB - prevCombined),
      vixRatio: r3(vixRatio),
    });

    if (i === bars.length - 1) {
      lastSnapshot = {
        dt,
        px,
        pxUnadj,
        vix,
        vix3m,
        vixRatio,
        ctaMult,
        var36,
        longPctVol,
        annVolCarver,
        rv20,
        rv60,
        fIndiv,
        flip1dPx,
        fCarver,
        smaVals,
        fSma,
        fHybrid,
        capCtaB,
        capVcB,
        tgtCarverB: cStep.tgt,
        posCarverB,
        posSmaB,
        posHybridB,
        posVcB,
        posCombinedB,
      };
    }
  }

  const s = lastSnapshot;
  const stateObj = {
    px0: s.px,
    var36: s.var36,
    longPctVol: s.longPctVol,
    capCtaB: s.capCtaB,
    capVcB: s.capVcB,
    posCarverB: s.posCarverB,
    posSmaB: s.posSmaB,
    posHybridB: s.posHybridB,
    posVcB: s.posVcB,
    trailingPx200,
    trailingRet60,
    emaFast: ef,
    emaSlow: es,
    ctaTargetVol,
    vcTargetVol,
  };

  const surf5d = simulateSurfaceFromState(stateObj, SHOCK_GRID_PCT, 5);
  const surf10d = simulateSurfaceFromState(stateObj, SHOCK_GRID_PCT, 10);
  const fine5d = simulateSurfaceFromState(stateObj, FINE_GRID_PCT, 5);
  const fine10d = simulateSurfaceFromState(stateObj, FINE_GRID_PCT, 10);

  const fineZeroIdx = FINE_GRID_PCT.indexOf(0);
  const idxM5 = FINE_GRID_PCT.indexOf(-5);
  const idxM3 = FINE_GRID_PCT.indexOf(-3);
  const idxP3 = FINE_GRID_PCT.indexOf(3);
  const idxP5 = FINE_GRID_PCT.indexOf(5);

  const c5Zero = fine5d.flowCarverB[fineZeroIdx];
  const t5Zero = fine5d.flowCombinedB[fineZeroIdx];
  const c10Zero = fine10d.flowCarverB[fineZeroIdx];
  const t10Zero = fine10d.flowCombinedB[fineZeroIdx];

  const carvEq = fine5d.flowCarverB.map(v => v / s.ctaMult);
  const totEq = fine5d.flowCombinedB.map(v => v / s.ctaMult);
  const margAsym3 = Math.max(carvEq[idxP3] - carvEq[fineZeroIdx], 0) / Math.max(-(carvEq[idxM3] - carvEq[fineZeroIdx]), 0.5);
  const margAsym5 = Math.max(carvEq[idxP5] - carvEq[fineZeroIdx], 0) / Math.max(-(carvEq[idxM5] - carvEq[fineZeroIdx]), 0.5);

  const zero5dPct = findThresholdStrikePct(FINE_GRID_PCT, fine5d.flowCombinedB, 0, 'up');
  const zero10dPct = findThresholdStrikePct(FINE_GRID_PCT, fine10d.flowCombinedB, 0, 'up');
  const sqz5dPct = findThresholdStrikePct(FINE_GRID_PCT, fine5d.flowCombinedB, sqz5dB, 'up');
  const sqz10dPct = findThresholdStrikePct(FINE_GRID_PCT, fine10d.flowCombinedB, sqz10dB, 'up');
  const sellCliffPct = findThresholdStrikePct(FINE_GRID_PCT, totEq, sellCliff2026B, 'down');

  const pre = cpAsset.fCarverPre2025;
  let leCount = 0;
  for (let i = 0; i < pre.length; i += 1) if (pre[i] <= s.fCarver) leCount += 1;
  for (let i = 0; i < fPostCp.length; i += 1) if (fPostCp[i] <= s.fCarver) leCount += 1;
  const pctile12y = Math.round((leCount / (pre.length + fPostCp.length)) * 1000) / 10;

  const recent25 = trajAll.slice(-25);
  const peakRecent = Math.max(...recent25.map(x => x.posCombinedB));
  const cumDelev = s.posCombinedB - peakRecent;
  const primaryActive = s.fCarver <= -10 && margAsym3 >= 1.8;

  const completedEps = baseAsset.signals.primaryExhaustionBuy.completedEpisodes;
  const ewmacComponents = EWMAC_CONFIGS.map(([lf, ls, sc], k) => ({
    rule: `EWMAC(${lf},${ls})`,
    fastSpan: lf,
    slowSpan: ls,
    scalar: sc,
    emaFast: r2(ef[k]),
    emaSlow: r2(es[k]),
    forecast: r2(s.fIndiv[k]),
    flip1dPrice: r2(s.flip1dPx[k]),
    pctTo1dFlip: r2((s.flip1dPx[k] / s.pxUnadj - 1) * 100),
  }));
  const smaComponents = SMA_WINDOWS.map((wLen, mIdx) => ({
    ma: `SMA${wLen}`,
    window: wLen,
    weight: SMA_WEIGHTS[mIdx],
    level: r2(s.smaVals[mIdx]),
    pctDistanceFromSpot: r2((s.smaVals[mIdx] / s.pxUnadj - 1) * 100),
    state: s.px >= s.smaVals[mIdx] ? 'LONG' : 'SHORT',
  }));

  const flowCurve = [];
  for (let gIdx = 0; gIdx < FINE_GRID_PCT.length; gIdx += 1) {
    const pct = FINE_GRID_PCT[gIdx];
    if (pct < CURVE_MIN_PCT || pct > CURVE_MAX_PCT) continue;
    flowCurve.push({
      movePct: pct,
      targetPrice: r2(s.pxUnadj * (1 + pct / 100)),
      carver5dB: r2(fine5d.flowCarverB[gIdx]),
      marginalCarver5dB: r2(fine5d.flowCarverB[gIdx] - c5Zero),
      sma5dB: r2(fine5d.flowSmaB[gIdx]),
      vc5dB: r2(fine5d.flowVcB[gIdx]),
      combined5dB: r2(fine5d.flowCombinedB[gIdx]),
      marginalCombined5dB: r2(fine5d.flowCombinedB[gIdx] - t5Zero),
      carver10dB: r2(fine10d.flowCarverB[gIdx]),
      marginalCarver10dB: r2(fine10d.flowCarverB[gIdx] - c10Zero),
      sma10dB: r2(fine10d.flowSmaB[gIdx]),
      vc10dB: r2(fine10d.flowVcB[gIdx]),
      combined10dB: r2(fine10d.flowCombinedB[gIdx]),
      marginalCombined10dB: r2(fine10d.flowCombinedB[gIdx] - t10Zero),
    });
  }

  return {
    ...baseAsset,
    liveState: {
      asOfDate: s.dt,
      spotClose: r2(s.pxUnadj),
      vixClose: r2(s.vix),
      vix3mClose: r2(s.vix3m),
      vixVix3mRatio: r3(s.vixRatio),
      vixBackwardation: s.vixRatio >= 1.0,
      fCarver: r2(s.fCarver),
      fSma: r2(s.fSma),
      fHybrid: r2(s.fHybrid),
      carverForecast12YrPercentile: pctile12y,
      annVolCarverPct: r2(s.annVolCarver * 100),
      rv20Pct: r2(s.rv20 * 100),
      rv60Pct: r2(s.rv60 * 100),
      posCarverCtaB: r2(s.posCarverB),
      tgtUnbufferedCarverCtaB: r2(s.tgtCarverB),
      posSmaCtaB: r2(s.posSmaB),
      posVolControlB: r2(s.posVcB),
      posCombinedSysB: r2(s.posCombinedB),
      recentPeakCombinedSysB: r2(peakRecent),
      recentCumDeleveragingB: r2(cumDelev),
      flatInertia5dCarverB: r2(c5Zero),
      flatInertia5dCombinedB: r2(t5Zero),
      flatInertia10dCarverB: r2(c10Zero),
      flatInertia10dCombinedB: r2(t10Zero),
      marginalAsymmetry3Pct5d: r2(margAsym3),
      marginalAsymmetry5Pct5d: r2(margAsym5),
      zeroNetFlowBreakeven5dPct: zero5dPct !== null ? r2(zero5dPct) : null,
      zeroNetFlowBreakeven5dPx: zero5dPct !== null ? r2(s.pxUnadj * (1 + zero5dPct / 100)) : null,
      zeroNetFlowBreakeven10dPct: zero10dPct !== null ? r2(zero10dPct) : null,
      zeroNetFlowBreakeven10dPx: zero10dPct !== null ? r2(s.pxUnadj * (1 + zero10dPct / 100)) : null,
      squeezeIgnition5dPct: sqz5dPct !== null ? r2(sqz5dPct) : null,
      squeezeIgnition5dPx: sqz5dPct !== null ? r2(s.pxUnadj * (1 + sqz5dPct / 100)) : null,
      squeezeIgnition10dPct: sqz10dPct !== null ? r2(sqz10dPct) : null,
      squeezeIgnition10dPx: sqz10dPct !== null ? r2(s.pxUnadj * (1 + sqz10dPct / 100)) : null,
      sellCliff5dPct: sellCliffPct !== null ? r2(sellCliffPct) : null,
      sellCliff5dPx: sellCliffPct !== null ? r2(s.pxUnadj * (1 + sellCliffPct / 100)) : null,
    },
    signals: {
      primaryExhaustionBuy: {
        ...baseAsset.signals.primaryExhaustionBuy,
        active: primaryActive,
        triggerRank: primaryActive ? completedEps + 1 : null,
        currentF: r2(s.fCarver),
        currentConvexity3Pct: r2(margAsym3),
        currentConvexity5Pct: r2(margAsym5),
      },
      vixBackwardationGuardrail: {
        ...baseAsset.signals.vixBackwardationGuardrail,
        vixInverted: s.vixRatio >= 1.0,
        vixRatio: r3(s.vixRatio),
        vixClose: r2(s.vix),
        vix3mClose: r2(s.vix3m),
      },
    },
    ewmacComponents,
    smaComponents,
    flowCurve,
    matrix5d: buildMatrixRows(s.pxUnadj, surf5d, fine5d, zero5dPct),
    matrix10d: buildMatrixRows(s.pxUnadj, surf10d, fine10d, zero10dPct),
    recentTrajectory: trajAll.slice(-45).map(({ pxAdj, ...rest }) => rest),
  };
}

function formatPublicResponse(doc, snapshotId, { selectedAsset, selectedHorizon, requestedAsOf, liveExtended = false }) {
  const { runtimeCheckpoint, ...publicDoc } = doc;
  return {
    ...publicDoc,
    snapshotId,
    requestedAsOf,
    selectedAsset,
    selectedHorizon,
    availableAssets: CTA_RADAR_ASSETS,
    availableHorizons: CTA_RADAR_HORIZONS,
    liveExtended,
  };
}

export function loadCtaFlowRadarDashboard({
  asOf = null,
  asset = 'SPY',
  horizon = '10D',
  file = defaultFile,
  extraDailyBars = null,
} = {}) {
  const { snapshotId, data } = readArtifact(file);
  const selectedAsset = normalizeAsset(asset);
  const selectedHorizon = normalizeHorizon(horizon);

  const requestedAsOf = asOf ? String(asOf).trim() : data.asOfDate;
  if (!isIsoDate(requestedAsOf)) fail('invalid_as_of_date', 400);
  if (requestedAsOf < '2014-01-02') fail('cta_radar_before_coverage', 400);

  const cp = data.runtimeCheckpoint;
  const baseBars = cp?.dailyBarsFrom2025 ?? [];

  let mergedBars = baseBars;
  let hasLiveExtension = false;
  if (Array.isArray(extraDailyBars) && extraDailyBars.length > 0 && baseBars.length > 0) {
    const lastBase = baseBars[baseBars.length - 1];
    const lastDate = lastBase[0];
    let prevSpyAdj = lastBase[1];
    let prevSpyUnadj = lastBase[2];
    let prevQqqAdj = lastBase[3];
    let prevQqqUnadj = lastBase[4];
    let prevVix = lastBase[5];
    let prevVix3m = lastBase[6];
    const lastCtaMult = lastBase[7];
    const lastVcMult = lastBase[8];

    const appended = [];
    for (const b of extraDailyBars) {
      if (!b?.date || b.date <= lastDate || b.date > requestedAsOf) continue;
      if (!Number.isFinite(b.spyClose) || !Number.isFinite(b.qqqClose)) continue;
      const spyUnadj = Number(b.spyClose);
      const qqqUnadj = Number(b.qqqClose);
      const spyAdj = Number.isFinite(b.spyAdjClose)
        ? prevSpyAdj * (Number(b.spyAdjClose) / prevSpyUnadj)
        : prevSpyAdj * (spyUnadj / prevSpyUnadj);
      const qqqAdj = Number.isFinite(b.qqqAdjClose)
        ? prevQqqAdj * (Number(b.qqqAdjClose) / prevQqqUnadj)
        : prevQqqAdj * (qqqUnadj / prevQqqUnadj);
      const vix = Number.isFinite(b.vixClose) && b.vixClose > 0 ? Number(b.vixClose) : prevVix;
      const vix3m = Number.isFinite(b.vix3mClose) && b.vix3mClose > 0 ? Number(b.vix3mClose) : prevVix3m;

      appended.push([b.date, spyAdj, spyUnadj, qqqAdj, qqqUnadj, vix, vix3m, lastCtaMult, lastVcMult]);
      prevSpyAdj = spyAdj;
      prevSpyUnadj = spyUnadj;
      prevQqqAdj = qqqAdj;
      prevQqqUnadj = qqqUnadj;
      prevVix = vix;
      prevVix3m = vix3m;
    }
    if (appended.length > 0) {
      mergedBars = baseBars.concat(appended);
      hasLiveExtension = true;
    }
  }

  // Exact fast-path when requestedAsOf >= artifact.asOfDate and no newer live bars exist
  if (!hasLiveExtension && requestedAsOf >= data.asOfDate) {
    return formatPublicResponse(data, snapshotId, {
      selectedAsset,
      selectedHorizon,
      requestedAsOf,
      liveExtended: false,
    });
  }

  // Dynamic zero-lookahead stepping from 2024-12-31 checkpoint for historical cutoffs (>=2025-01-02) or live extension
  const slicedBars = mergedBars.filter(b => b[0] <= requestedAsOf);
  if (cp && slicedBars.length > 0) {
    const effDate = slicedBars[slicedBars.length - 1][0];
    const spyStepped = stepAssetFromCheckpoint(data.assets.SPY, cp.assets.SPY, slicedBars);
    const qqqStepped = stepAssetFromCheckpoint(data.assets.QQQ, cp.assets.QQQ, slicedBars);
    const steppedDoc = {
      ...data,
      asOfDate: effDate,
      evaluationWindow: {
        ...data.evaluationWindow,
        end: effDate,
      },
      assets: {
        SPY: spyStepped,
        QQQ: qqqStepped,
      },
    };
    return formatPublicResponse(steppedDoc, snapshotId, {
      selectedAsset,
      selectedHorizon,
      requestedAsOf,
      liveExtended: hasLiveExtension,
    });
  }

  return formatPublicResponse(data, snapshotId, {
    selectedAsset,
    selectedHorizon,
    requestedAsOf,
    liveExtended: false,
  });
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
    const adjs = res0?.indicators?.adjclose?.[0]?.adjclose ?? closes;
    const out = new Map();
    for (let i = 0; i < ts.length; i += 1) {
      const c = closes[i];
      if (!Number.isFinite(c) || c <= 0) continue;
      const a = Number.isFinite(adjs[i]) && adjs[i] > 0 ? adjs[i] : c;
      const dt = new Date(ts[i] * 1000).toISOString().slice(0, 10);
      out.set(dt, { close: c, adjClose: a });
    }
    return out;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function getLiveRecentCtaBars() {
  const now = Date.now();
  if (liveFeedCache.byDate && now - liveFeedCache.fetchedAt < LIVE_FEED_TTL_MS) {
    return liveFeedCache.byDate;
  }
  const [spy, qqq, vix, vix3m] = await Promise.all([
    fetchYahooSymbol15d('SPY'),
    fetchYahooSymbol15d('QQQ'),
    fetchYahooSymbol15d('^VIX'),
    fetchYahooSymbol15d('^VIX3M'),
  ]);
  if (!spy || !qqq) return null;
  const dates = [...spy.keys()].filter(d => qqq.has(d)).sort();
  const bars = dates.map(d => ({
    date: d,
    spyClose: spy.get(d).close,
    spyAdjClose: spy.get(d).adjClose,
    qqqClose: qqq.get(d).close,
    qqqAdjClose: qqq.get(d).adjClose,
    vixClose: vix?.get(d)?.close ?? null,
    vix3mClose: vix3m?.get(d)?.close ?? null,
  }));
  liveFeedCache.fetchedAt = now;
  liveFeedCache.byDate = bars;
  return bars;
}

export async function loadCtaFlowRadarDashboardLive({
  asOf = null,
  asset = 'SPY',
  horizon = '10D',
  file = defaultFile,
  fetchLiveBars = null,
} = {}) {
  const { data } = readArtifact(file);
  const requestedAsOf = asOf ? String(asOf).trim() : new Date().toISOString().slice(0, 10);
  if (!isIsoDate(requestedAsOf)) fail('invalid_as_of_date', 400);

  let extraDailyBars = null;
  const liveEnabled = process.env.LIVE_MARKET_TAIL_ENABLED === 'true' || typeof fetchLiveBars === 'function';
  if (liveEnabled && requestedAsOf > data.asOfDate) {
    try {
      extraDailyBars = await (fetchLiveBars ? fetchLiveBars() : getLiveRecentCtaBars());
    } catch {
      extraDailyBars = null;
    }
  }
  return loadCtaFlowRadarDashboard({
    asOf: requestedAsOf,
    asset,
    horizon,
    file,
    extraDailyBars,
  });
}
