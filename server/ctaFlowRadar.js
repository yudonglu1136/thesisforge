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
const r1 = v => (Number.isFinite(v) ? Math.round(v * 10) / 10 : null);
const r2 = v => (Number.isFinite(v) ? Math.round(v * 100) / 100 : null);
const r3 = v => (Number.isFinite(v) ? Math.round(v * 1000) / 1000 : null);
const r4 = v => (Number.isFinite(v) ? Math.round(v * 10000) / 10000 : null);

function medianVal(arr) {
  if (!arr.length) return null;
  const s = arr.slice().sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function percentileLinear(arr, qPct) {
  if (!arr.length) return null;
  const s = arr.slice().sort((a, b) => a - b);
  if (s.length === 1) return s[0];
  const pos = (qPct / 100) * (s.length - 1);
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  if (lo === hi) return s[lo];
  const w = pos - lo;
  return s[lo] + w * (s[hi] - s[lo]);
}

function logGamma(z) {
  const p = [
    0.9999999999998099,
    676.5203681218851,
    -1259.1392167224028,
    771.3234287776531,
    -176.6150291621406,
    12.507343278686905,
    -0.13857109526572012,
    9.984369578019572e-6,
    1.5056327351493116e-7,
  ];
  if (z < 0.5) {
    return Math.log(Math.PI / Math.sin(Math.PI * z)) - logGamma(1 - z);
  }
  const zm = z - 1;
  let x = p[0];
  for (let i = 1; i < p.length; i += 1) x += p[i] / (zm + i);
  const t = zm + 7.5;
  return 0.5 * Math.log(2 * Math.PI) + (zm + 0.5) * Math.log(t) - t + Math.log(x);
}

function betacf(a, b, x) {
  const maxIt = 200;
  const eps = 3e-12;
  const fpMin = 1e-30;
  const qab = a + b;
  const qap = a + 1;
  const qam = a - 1;
  let c = 1;
  let d = 1 - (qab * x) / qap;
  if (Math.abs(d) < fpMin) d = fpMin;
  d = 1 / d;
  let h = d;
  for (let m = 1; m <= maxIt; m += 1) {
    const m2 = 2 * m;
    let aa = (m * (b - m) * x) / ((qam + m2) * (a + m2));
    d = 1 + aa * d;
    if (Math.abs(d) < fpMin) d = fpMin;
    c = 1 + aa / c;
    if (Math.abs(c) < fpMin) c = fpMin;
    d = 1 / d;
    h *= d * c;
    aa = (-(a + m) * (qab + m) * x) / ((a + m2) * (qap + m2));
    d = 1 + aa * d;
    if (Math.abs(d) < fpMin) d = fpMin;
    c = 1 + aa / c;
    if (Math.abs(c) < fpMin) c = fpMin;
    d = 1 / d;
    const delta = d * c;
    h *= delta;
    if (Math.abs(delta - 1) < eps) break;
  }
  return h;
}

function betainc(a, b, x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const bt = Math.exp(logGamma(a + b) - logGamma(a) - logGamma(b) + a * Math.log(x) + b * Math.log(1 - x));
  if (x < (a + 1) / (a + b + 2)) return (bt * betacf(a, b, x)) / a;
  return 1 - (bt * betacf(b, a, 1 - x)) / b;
}

function welchTTestPVal(xa, ya) {
  const nx = xa.length;
  const ny = ya.length;
  if (nx < 2 || ny < 2) return null;
  const mx = xa.reduce((acc, v) => acc + v, 0) / nx;
  const my = ya.reduce((acc, v) => acc + v, 0) / ny;
  let sqx = 0;
  let sqy = 0;
  for (let i = 0; i < nx; i += 1) sqx += (xa[i] - mx) ** 2;
  for (let i = 0; i < ny; i += 1) sqy += (ya[i] - my) ** 2;
  const vx = sqx / (nx - 1);
  const vy = sqy / (ny - 1);
  const se2 = vx / nx + vy / ny;
  if (se2 <= 1e-18) return 1;
  const tStat = (mx - my) / Math.sqrt(se2);
  const dfNum = se2 * se2;
  const dfDen = (vx / nx) ** 2 / (nx - 1) + (vy / ny) ** 2 / (ny - 1);
  const df = dfNum / Math.max(dfDen, 1e-18);
  const xBeta = df / (df + tStat * tStat);
  return betainc(0.5 * df, 0.5, xBeta);
}

function declusterIndices(mask, minGap = 20) {
  const kept = [];
  let lastIdx = -999999;
  for (let i = 0; i < mask.length; i += 1) {
    if (mask[i] && i - lastIdx >= minGap) {
      kept.push(i);
      lastIdx = i;
    }
  }
  return kept;
}

function summarizeForwardList(rets, baseAllRets, baseNonoverlapRets) {
  const n = rets.length;
  const bWin = baseAllRets.length
    ? (baseAllRets.filter(v => v > 0).length / baseAllRets.length) * 100
    : null;
  const bMean = baseAllRets.length
    ? baseAllRets.reduce((acc, v) => acc + v, 0) / baseAllRets.length
    : null;
  const bMed = baseAllRets.length ? medianVal(baseAllRets) : null;

  if (n === 0) {
    return {
      nCompleted: 0,
      winCount: 0,
      winRatePct: null,
      medianRetPct: null,
      meanRetPct: null,
      minRetPct: null,
      maxRetPct: null,
      p25RetPct: null,
      p75RetPct: null,
      baselineWinRatePct: bWin !== null ? r1(bWin) : null,
      baselineMeanRetPct: bMean !== null ? r2(bMean) : null,
      baselineMedianRetPct: bMed !== null ? r2(bMed) : null,
      excessMeanRetPct: null,
      excessMedianRetPct: null,
      pValVsBaseline: null,
    };
  }

  const winCount = rets.filter(v => v > 0).length;
  const meanR = rets.reduce((acc, v) => acc + v, 0) / n;
  const medR = medianVal(rets);
  const pVal = n >= 2 && baseNonoverlapRets.length >= 2 ? welchTTestPVal(rets, baseNonoverlapRets) : null;

  return {
    nCompleted: n,
    winCount,
    winRatePct: r1((winCount / n) * 100),
    medianRetPct: r2(medR),
    meanRetPct: r2(meanR),
    minRetPct: r2(Math.min(...rets)),
    maxRetPct: r2(Math.max(...rets)),
    p25RetPct: r2(percentileLinear(rets, 25)),
    p75RetPct: r2(percentileLinear(rets, 75)),
    baselineWinRatePct: bWin !== null ? r1(bWin) : null,
    baselineMeanRetPct: bMean !== null ? r2(bMean) : null,
    baselineMedianRetPct: bMed !== null ? r2(bMed) : null,
    excessMeanRetPct: bMean !== null ? r2(meanR - bMean) : null,
    excessMedianRetPct: bMed !== null ? r2(medR - bMed) : null,
    pValVsBaseline: pVal !== null ? r4(pVal) : null,
  };
}

function computeSingleRegimeBacktest({
  regimeId,
  titleEn,
  titleZh,
  ruleEn,
  ruleZh,
  mask,
  series,
  cooldownDays = 20,
  waitWindowDays = 20,
}) {
  const m = series.length;
  const epIndices = declusterIndices(mask, cooldownDays);
  const horizonsCfg = [10, 20, 60, 120];
  const ddWindows = [10, 20, 60];

  const baseAll = {};
  const baseNonoverlap = {};
  for (const h of horizonsCfg) {
    const allR = [];
    const nonOv = [];
    if (m > h) {
      for (let j = 0; j < m - h; j += 1) {
        allR.push((series[j + h][1] / series[j][1] - 1) * 100);
      }
      const step = Math.max(h, cooldownDays);
      for (let j = 0; j < m - h; j += step) {
        nonOv.push((series[j + h][1] / series[j][1] - 1) * 100);
      }
    }
    baseAll[h] = allR;
    baseNonoverlap[h] = nonOv;
  }

  const ddSummary = {};
  for (const w of ddWindows) {
    const drops = [];
    const troughDays = [];
    for (const idx of epIndices) {
      if (idx + w >= m) continue;
      const p0 = series[idx][1];
      let minR = 0;
      let minD = 0;
      for (let d = 1; d <= w; d += 1) {
        const rd = (series[idx + d][1] / p0 - 1) * 100;
        if (rd < minR) {
          minR = rd;
          minD = d;
        }
      }
      drops.push(minR);
      troughDays.push(minD);
    }
    if (drops.length) {
      ddSummary[`${w}D`] = {
        nCompleted: drops.length,
        medianDropPct: r2(medianVal(drops)),
        meanDropPct: r2(drops.reduce((a, v) => a + v, 0) / drops.length),
        worstDropPct: r2(Math.min(...drops)),
        bestDropPct: r2(Math.max(...drops)),
        zeroFurtherDropCount: drops.filter(v => v >= -1e-9).length,
        dropGe2PctCount: drops.filter(v => v <= -2).length,
        dropGe5PctCount: drops.filter(v => v <= -5).length,
        medianDaysToTrough: r1(medianVal(troughDays)),
        meanDaysToTrough: r1(troughDays.reduce((a, v) => a + v, 0) / troughDays.length),
        maxDaysToTrough: Math.max(...troughDays),
      };
    } else {
      ddSummary[`${w}D`] = {
        nCompleted: 0,
        medianDropPct: null,
        meanDropPct: null,
        worstDropPct: null,
        bestDropPct: null,
        zeroFurtherDropCount: 0,
        dropGe2PctCount: 0,
        dropGe5PctCount: 0,
        medianDaysToTrough: null,
        meanDaysToTrough: null,
        maxDaysToTrough: null,
      };
    }
  }

  const fwdSummary = {};
  for (const h of horizonsCfg) {
    const retsH = epIndices
      .filter(idx => idx + h < m)
      .map(idx => (series[idx + h][1] / series[idx][1] - 1) * 100);
    fwdSummary[`${h}D`] = summarizeForwardList(retsH, baseAll[h], baseNonoverlap[h]);
  }

  const eligibleDipEps = epIndices.filter(idx => idx + waitWindowDays < m);
  const dipSpecs = [
    ['dip_0pct', 0, '0% (Buy Signal Close)', '0%（信号日收盘即买）', '100% immediate entry at signal-day close', '信号触发当日收盘 100% 直接买入'],
    ['dip_2pct', -2, '-2% Dip Limit (20D)', '再跌 -2% 挂单（20D内）', 'Buy at first close <= -2% below signal close within 20 trading days', '信号后 20 个交易日内首次收盘跌破 -2% 买入'],
    ['dip_3pct', -3, '-3% Dip Limit (20D)', '再跌 -3% 挂单（20D内）', 'Buy at first close <= -3% below signal close within 20 trading days', '信号后 20 个交易日内首次收盘跌破 -3% 买入'],
    ['dip_5pct', -5, '-5% Dip Limit (20D)', '再跌 -5% 挂单（20D内）', 'Buy at first close <= -5% below signal close within 20 trading days', '信号后 20 个交易日内首次收盘跌破 -5% 买入'],
  ];

  const dipMatrix = [];
  for (const [modeId, dipPct, lblEn, lblZh, rEn, rZh] of dipSpecs) {
    const filledEntries = [];
    const missedIndices = [];
    for (const idx of eligibleDipEps) {
      const p0 = series[idx][1];
      if (Math.abs(dipPct) < 1e-9) {
        filledEntries.push([idx, idx, p0]);
      } else {
        const thresh = p0 * (1 + dipPct / 100);
        let hitK = null;
        for (let k = idx + 1; k <= idx + waitWindowDays; k += 1) {
          if (series[k][1] <= thresh + 1e-12) {
            hitK = k;
            break;
          }
        }
        if (hitK !== null) filledEntries.push([idx, hitK, series[hitK][1]]);
        else missedIndices.push(idx);
      }
    }

    const maes20d = [];
    const fillWaits = [];
    for (const [sigIdx, fillK, fillPx] of filledEntries) {
      fillWaits.push(fillK - sigIdx);
      if (fillK + 20 < m) {
        let minAfter = 0;
        for (let d = 1; d <= 20; d += 1) {
          const rd = (series[fillK + d][1] / fillPx - 1) * 100;
          if (rd < minAfter) minAfter = rd;
        }
        maes20d.push(minAfter);
      }
    }

    const missed20 = missedIndices
      .filter(idx => idx + 20 < m)
      .map(idx => (series[idx + 20][1] / series[idx][1] - 1) * 100);
    const missed60 = missedIndices
      .filter(idx => idx + 60 < m)
      .map(idx => (series[idx + 60][1] / series[idx][1] - 1) * 100);

    const modeHorizons = {};
    for (const h of horizonsCfg) {
      const hRets = filledEntries
        .filter(([, fillK]) => fillK + h < m)
        .map(([, fillK, fillPx]) => (series[fillK + h][1] / fillPx - 1) * 100);
      if (hRets.length) {
        const wC = hRets.filter(v => v > 0).length;
        modeHorizons[`${h}D`] = {
          nFilled: hRets.length,
          winCount: wC,
          winRatePct: r1((wC / hRets.length) * 100),
          medianRetPct: r2(medianVal(hRets)),
          meanRetPct: r2(hRets.reduce((a, v) => a + v, 0) / hRets.length),
          minRetPct: r2(Math.min(...hRets)),
          maxRetPct: r2(Math.max(...hRets)),
        };
      } else {
        modeHorizons[`${h}D`] = {
          nFilled: 0,
          winCount: 0,
          winRatePct: null,
          medianRetPct: null,
          meanRetPct: null,
          minRetPct: null,
          maxRetPct: null,
        };
      }
    }

    const nElig = eligibleDipEps.length;
    const nFill = filledEntries.length;
    dipMatrix.push({
      id: modeId,
      dipPct,
      labelEn: lblEn,
      labelZh: lblZh,
      ruleEn: rEn,
      ruleZh: rZh,
      eligibleEpisodes: nElig,
      filledCount: nFill,
      missedCount: missedIndices.length,
      fillRatePct: nElig > 0 ? r1((nFill / nElig) * 100) : null,
      avgDeployedCapitalPct: nElig > 0 ? r1((nFill / nElig) * 100) : null,
      avgDaysToFill: fillWaits.length ? r1(fillWaits.reduce((a, v) => a + v, 0) / fillWaits.length) : null,
      postEntry20dMaeMedianPct: maes20d.length ? r2(medianVal(maes20d)) : null,
      postEntry20dMaeMeanPct: maes20d.length ? r2(maes20d.reduce((a, v) => a + v, 0) / maes20d.length) : null,
      postEntry20dMaeWorstPct: maes20d.length ? r2(Math.min(...maes20d)) : null,
      missed20dMeanRetPct: missed20.length ? r2(missed20.reduce((a, v) => a + v, 0) / missed20.length) : null,
      missed60dMeanRetPct: missed60.length ? r2(missed60.reduce((a, v) => a + v, 0) / missed60.length) : null,
      horizons: modeHorizons,
    });
  }

  // 5th Mode: 3-Tranche DCA (0% / -2% / -5%)
  const dcaDeployedList = [];
  const dcaMaes20d = [];
  const dcaHorizonsRets = { 10: [], 20: [], 60: [], 120: [] };
  const dcaDeployedHorizonsRets = { 10: [], 20: [], 60: [], 120: [] };

  for (const idx of eligibleDipEps) {
    const p0 = series[idx][1];
    let k2 = null;
    let k5 = null;
    for (let k = idx + 1; k <= idx + waitWindowDays; k += 1) {
      if (k2 === null && series[k][1] <= p0 * 0.98 + 1e-12) k2 = k;
      if (k5 === null && series[k][1] <= p0 * 0.95 + 1e-12) k5 = k;
    }
    const tranchesFilled = 1 + (k2 !== null ? 1 : 0) + (k5 !== null ? 1 : 0);
    dcaDeployedList.push((tranchesFilled / 3) * 100);

    const dcaEquityAt = tIdx => {
      const eq1 = series[tIdx][1] / p0;
      const eq2 = k2 !== null && k2 <= tIdx ? series[tIdx][1] / series[k2][1] : 1;
      const eq3 = k5 !== null && k5 <= tIdx ? series[tIdx][1] / series[k5][1] : 1;
      return (eq1 + eq2 + eq3) / 3;
    };
    const dcaDeployedRetAt = tIdx => {
      const gains = [series[tIdx][1] / p0 - 1];
      if (k2 !== null && k2 <= tIdx) gains.push(series[tIdx][1] / series[k2][1] - 1);
      if (k5 !== null && k5 <= tIdx) gains.push(series[tIdx][1] / series[k5][1] - 1);
      return (gains.reduce((a, v) => a + v, 0) / gains.length) * 100;
    };

    let minDca20 = 0;
    for (let d = 1; d <= waitWindowDays; d += 1) {
      const rd = (dcaEquityAt(idx + d) - 1) * 100;
      if (rd < minDca20) minDca20 = rd;
    }
    dcaMaes20d.push(minDca20);

    for (const h of horizonsCfg) {
      if (idx + h < m) {
        dcaHorizonsRets[h].push((dcaEquityAt(idx + h) - 1) * 100);
        dcaDeployedHorizonsRets[h].push(dcaDeployedRetAt(idx + h));
      }
    }
  }

  const dcaHorizonsOut = {};
  for (const h of horizonsCfg) {
    const hr = dcaHorizonsRets[h];
    const dr = dcaDeployedHorizonsRets[h];
    if (hr.length) {
      const wc = hr.filter(v => v > 0).length;
      dcaHorizonsOut[`${h}D`] = {
        nFilled: hr.length,
        winCount: wc,
        winRatePct: r1((wc / hr.length) * 100),
        medianRetPct: r2(medianVal(hr)),
        meanRetPct: r2(hr.reduce((a, v) => a + v, 0) / hr.length),
        minRetPct: r2(Math.min(...hr)),
        maxRetPct: r2(Math.max(...hr)),
        deployedMedianRetPct: dr.length ? r2(medianVal(dr)) : null,
        deployedMeanRetPct: dr.length ? r2(dr.reduce((a, v) => a + v, 0) / dr.length) : null,
      };
    } else {
      dcaHorizonsOut[`${h}D`] = {
        nFilled: 0,
        winCount: 0,
        winRatePct: null,
        medianRetPct: null,
        meanRetPct: null,
        minRetPct: null,
        maxRetPct: null,
        deployedMedianRetPct: null,
        deployedMeanRetPct: null,
      };
    }
  }

  const nEligDca = eligibleDipEps.length;
  dipMatrix.push({
    id: 'dca_3tranche',
    dipPct: null,
    labelEn: '3-Tranche DCA (0% / -2% / -5%)',
    labelZh: '分 3 批阶梯买（0% / -2% / -5%）',
    ruleEn: '1/3 at signal close + 1/3 at -2% + 1/3 at -5% within 20D (unfilled cash earns 0%)',
    ruleZh: '信号日收盘买 1/3 + 再跌 -2% 买 1/3 + 再跌 -5% 买 1/3（20D内未触发部分按现金 0% 计）',
    eligibleEpisodes: nEligDca,
    filledCount: nEligDca,
    missedCount: 0,
    fillRatePct: nEligDca > 0 ? 100 : null,
    avgDeployedCapitalPct: dcaDeployedList.length
      ? r1(dcaDeployedList.reduce((a, v) => a + v, 0) / dcaDeployedList.length)
      : null,
    avgDaysToFill: nEligDca > 0 ? 0 : null,
    postEntry20dMaeMedianPct: dcaMaes20d.length ? r2(medianVal(dcaMaes20d)) : null,
    postEntry20dMaeMeanPct: dcaMaes20d.length ? r2(dcaMaes20d.reduce((a, v) => a + v, 0) / dcaMaes20d.length) : null,
    postEntry20dMaeWorstPct: dcaMaes20d.length ? r2(Math.min(...dcaMaes20d)) : null,
    missed20dMeanRetPct: null,
    missed60dMeanRetPct: null,
    horizons: dcaHorizonsOut,
  });

  const ledger = epIndices.map((idx, rankZero) => {
    const daysElapsed = m - 1 - idx;
    const status = daysElapsed < 10 ? 'LIVE' : daysElapsed < 120 ? 'PARTIAL' : 'COMPLETED';
    const p0 = series[idx][1];

    const epDd = w => {
      if (idx + w >= m) return [null, null, null];
      let minR = 0;
      let minD = 0;
      for (let d = 1; d <= w; d += 1) {
        const rd = (series[idx + d][1] / p0 - 1) * 100;
        if (rd < minR) {
          minR = rd;
          minD = d;
        }
      }
      return [r2(minR), minD, series[idx + minD][0]];
    };

    const [dd10] = epDd(10);
    const [dd20, dt20, tDate20] = epDd(20);
    const [dd60, dt60] = epDd(60);

    const retAt = h => (idx + h < m ? r2((series[idx + h][1] / p0 - 1) * 100) : null);
    let liveRunningRetPct = 0;
    let liveRunningMaxDropPct = 0;
    if (daysElapsed >= 1) {
      liveRunningRetPct = r2((series[m - 1][1] / p0 - 1) * 100);
      let minRun = 0;
      for (let d = 1; d <= daysElapsed; d += 1) {
        const rd = (series[idx + d][1] / p0 - 1) * 100;
        if (rd < minRun) minRun = rd;
      }
      liveRunningMaxDropPct = r2(minRun);
    }

    let f2 = null;
    let f3 = null;
    let f5 = null;
    let dcaDep = null;
    if (idx + waitWindowDays < m) {
      f2 = false;
      f3 = false;
      f5 = false;
      for (let k = idx + 1; k <= idx + waitWindowDays; k += 1) {
        if (series[k][1] <= p0 * 0.98 + 1e-12) f2 = true;
        if (series[k][1] <= p0 * 0.97 + 1e-12) f3 = true;
        if (series[k][1] <= p0 * 0.95 + 1e-12) f5 = true;
      }
      dcaDep = r1(((1 + (f2 ? 1 : 0) + (f5 ? 1 : 0)) / 3) * 100);
    }

    return {
      rank: rankZero + 1,
      date: series[idx][0],
      status,
      daysElapsed,
      signalClose: r2(series[idx][2]),
      fCarver: r2(series[idx][3]),
      convexity3Pct: r2(series[idx][4]),
      vixRatio: r3(series[idx][5]),
      vixClose: r2(series[idx][6]),
      maxDrop10dPct: dd10,
      maxDrop20dPct: dd20,
      maxDrop60dPct: dd60,
      daysToTrough20d: dt20,
      daysToTrough60d: dt60,
      troughDate20d: tDate20,
      ret10dPct: retAt(10),
      ret20dPct: retAt(20),
      ret60dPct: retAt(60),
      ret120dPct: retAt(120),
      liveRunningRetPct,
      liveRunningMaxDropPct,
      filledDip2Pct: f2,
      filledDip3Pct: f3,
      filledDip5Pct: f5,
      dcaDeployedPct: dcaDep,
    };
  });

  const nComp20 = ddSummary['20D'].nCompleted;
  return {
    id: regimeId,
    titleEn,
    titleZh,
    ruleEn,
    ruleZh,
    cooldownDays,
    activeToday: mask.length ? Boolean(mask[mask.length - 1]) : false,
    totalEpisodes: epIndices.length,
    completedEpisodes10d: fwdSummary['10D'].nCompleted,
    completedEpisodes20d: nComp20,
    completedEpisodes60d: fwdSummary['60D'].nCompleted,
    completedEpisodes120d: fwdSummary['120D'].nCompleted,
    livePendingCount: ledger.filter(row => row.status === 'LIVE').length,
    smallSampleCaveat: nComp20 < 12,
    postSignalDrawdown: ddSummary,
    forwardHorizons: fwdSummary,
    dipEntryMatrix: dipMatrix,
    episodes: ledger,
  };
}

function computeSignalBacktestFromSeries(series) {
  const maskExh = series.map(r => r[3] <= -10 && r[4] >= 1.8);
  const maskQ2 = series.map(r => r[3] <= -10 && r[4] >= 1.8 && r[5] >= 1.0);
  const maskVix = series.map(r => r[5] >= 1.0);

  return {
    basis: 'close_to_close_total_return_adjusted',
    priceMethodologyEn:
      'Strict zero-lookahead close-to-close total-return series (dividend & split adjusted) for all forward returns, post-signal drawdowns, and 20-day limit-order dip fills; spot close displays unadjusted exchange close on signal date.',
    priceMethodologyZh:
      '严格零前视收盘对收盘全收益序列（含分红复权与拆股校准）计算全部后续最大再跌、20 日内挂单触发成交及 +10/+20/+60/+120 日涨幅；信号日价格展示当日交易所实际收盘价。',
    cooldownTradingDays: 20,
    dipWaitWindowDays: 20,
    defaultRegimeId: 'exhaustion_convexity',
    regimeOrder: ['exhaustion_convexity', 'quadrant2_combo', 'vix_backwardation_lock'],
    dipModeOrder: ['dip_0pct', 'dip_2pct', 'dip_3pct', 'dip_5pct', 'dca_3tranche'],
    regimes: {
      exhaustion_convexity: computeSingleRegimeBacktest({
        regimeId: 'exhaustion_convexity',
        titleEn: 'Short Exhaustion + Convexity Turn',
        titleZh: '空头衰竭 + 凸性拐点',
        ruleEn: 'Carver F <= -10.0 AND +3%/-3% Pure Marginal Convexity >= 1.80x (>=20D cooldown)',
        ruleZh: 'Carver F <= -10.0 且 +3%/-3% 纯价格边际凸性 >= 1.80x（>=20 交易日冷却去重）',
        mask: maskExh,
        series,
      }),
      quadrant2_combo: computeSingleRegimeBacktest({
        regimeId: 'quadrant2_combo',
        titleEn: 'Quadrant 2 Combo (+ VIX Lock >= 1.00)',
        titleZh: '组合象限 2（叠加 VIX 倒挂 >= 1.00）',
        ruleEn: 'Carver F <= -10.0 AND Convexity >= 1.80x AND VIX/VIX3M >= 1.00 (>=20D cooldown)',
        ruleZh: 'Carver F <= -10.0 + 凸性 >= 1.80x + VIX/VIX3M >= 1.00 期现倒挂共振（今日 SPY 实盘象限）',
        mask: maskQ2,
        series,
      }),
      vix_backwardation_lock: computeSingleRegimeBacktest({
        regimeId: 'vix_backwardation_lock',
        titleEn: 'VIX Backwardation Lock Only',
        titleZh: '仅 VIX 倒挂恐慌锁',
        ruleEn: 'VIX / VIX3M >= 1.00 term-structure inversion onset (>=20D cooldown)',
        ruleZh: '仅 VIX / VIX3M >= 1.00 期现倒挂首次触发（无趋势耗尽过滤，>=20 交易日冷却去重）',
        mask: maskVix,
        series,
      }),
    },
  };
}

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
  const evalPostCp = [];
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

    const daySurf3 = simulateSurfaceFromState(
      {
        px0: px,
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
        emaFast: ef,
        emaSlow: es,
        ctaTargetVol,
        vcTargetVol,
      },
      [-3, 0, 3],
      5,
    );
    const cEqM3 = daySurf3.flowCarverB[0] / ctaMult;
    const cEq0 = daySurf3.flowCarverB[1] / ctaMult;
    const cEqP3 = daySurf3.flowCarverB[2] / ctaMult;
    const dayMargAsym3 = Math.max(cEqP3 - cEq0, 0) / Math.max(-(cEqM3 - cEq0), 0.5);
    evalPostCp.push([dt, px, pxUnadj, fCarver, dayMargAsym3, vixRatio, vix]);

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

  const fullEvalSeries = Array.isArray(cpAsset.evalSeriesPre2025)
    ? cpAsset.evalSeriesPre2025.concat(evalPostCp)
    : null;
  const dynamicSignalBacktest = fullEvalSeries
    ? computeSignalBacktestFromSeries(fullEvalSeries)
    : baseAsset.signalBacktest;

  let completedEps = baseAsset.signals.primaryExhaustionBuy.completedEpisodes;
  let historicalTriggerDates = baseAsset.signals.primaryExhaustionBuy.historicalTriggerDates;
  if (fullEvalSeries) {
    const margMask15 = fullEvalSeries.map(r => r[3] <= -10 && r[4] >= 1.8);
    const margIdx15 = declusterIndices(margMask15, 15);
    completedEps = margIdx15.filter(idx => idx + 63 < fullEvalSeries.length).length;
    historicalTriggerDates = margIdx15.map(idx => fullEvalSeries[idx][0]);
  }

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
        completedEpisodes: completedEps,
        historicalTriggerDates,
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
    signalBacktest: dynamicSignalBacktest,
    signal_backtest: dynamicSignalBacktest,
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
