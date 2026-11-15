import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { releaseRoot, dataReleaseId, retainDataRelease } from './dataReleaseContext.js';

export const QQQ_SCHD_ROTATION_VERSION = 'qqq-schd-rotation-v1';
export const QQQ_SCHD_ANALYSIS_VERSION = 'qqq-schd-range-attribution-v1';
export const QQQ_SCHD_MODES = Object.freeze(['m6', 'm4', 'm7']);
export const QQQ_SCHD_WINDOWS = Object.freeze(['live_2011', 'full_2000']);

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultFile = path.resolve(projectRoot, 'server/config/qqq-schd-rotation-dashboard.json');
const builderScript = path.resolve(projectRoot, 'scripts/build-qqq-schd-rotation-artifact.py');
const runtimeCacheDir = path.resolve(
  process.env.QQQ_SCHD_ROTATION_CACHE_DIR ||
    (process.env.NODE_ENV === 'production' && fs.existsSync('/var/app/data')
      ? '/var/app/data/qqq-schd-rotation-cache'
      : path.join(os.tmpdir(), 'thesisforge-qqq-schd-rotation-cache')),
);

function fail(code, status = 503) {
  throw Object.assign(new Error(code), { status });
}

const isIsoDate = value =>
  /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;

const round = (v, digits = 4) => {
  if (!Number.isFinite(v)) return null;
  const f = 10 ** digits;
  return Math.round(v * f) / f;
};

export function computeRotationWindowMetrics(dates, navs, qqqNavs, rfRets, weights = null) {
  const n = dates.length;
  if (n < 2) return null;
  const d0 = Date.parse(`${dates[0]}T00:00:00Z`);
  const d1 = Date.parse(`${dates[n - 1]}T00:00:00Z`);
  const years = Math.max((d1 - d0) / (86400_000 * 365.25), 1 / 365.25);

  const base = navs[0] > 0 ? navs[0] : 1;
  const norm = navs.map(v => v / base);
  const qBase = qqqNavs[0] > 0 ? qqqNavs[0] : 1;
  const qNorm = qqqNavs.map(v => v / qBase);

  const mult = norm[n - 1];
  const totalReturn = mult - 1;
  const cagr = mult > 0 ? mult ** (1 / years) - 1 : -1;

  const portRets = [];
  const exRets = [];
  for (let i = 1; i < n; i++) {
    const pr = norm[i - 1] > 0 ? norm[i] / norm[i - 1] - 1 : 0;
    portRets.push(pr);
    exRets.push(pr - (Number.isFinite(rfRets?.[i]) ? rfRets[i] : 0));
  }

  const mean = arr => (arr.length ? arr.reduce((a, b) => a + b, 0) / arr.length : 0);
  const sampleStd = arr => {
    if (arr.length < 2) return 0;
    const m = mean(arr);
    const v = arr.reduce((acc, x) => acc + (x - m) ** 2, 0) / (arr.length - 1);
    return Math.sqrt(Math.max(v, 0));
  };
  const popStd = arr => {
    if (!arr.length) return 0;
    const m = mean(arr);
    const v = arr.reduce((acc, x) => acc + (x - m) ** 2, 0) / arr.length;
    return Math.sqrt(Math.max(v, 0));
  };

  const mPr = mean(portRets);
  const vol = sampleStd(portRets) * Math.sqrt(252);
  const s0 = popStd(portRets);
  const sharpeZeroRf = s0 > 1e-16 ? (mPr / s0) * Math.sqrt(252) : 0;

  const mEx = mean(exRets);
  const stdEx = sampleStd(exRets);
  const sharpe = stdEx > 1e-16 ? (mEx / stdEx) * Math.sqrt(252) : 0;

  const dnSq = exRets.length
    ? exRets.reduce((acc, x) => acc + Math.min(x, 0) ** 2, 0) / exRets.length
    : 0;
  const sortino = dnSq > 1e-16 ? (mEx * 252) / (Math.sqrt(dnSq) * Math.sqrt(252)) : 0;

  let peak = norm[0];
  let mdd = 0;
  let ddSqSum = 0;
  for (let i = 0; i < n; i++) {
    if (norm[i] > peak) peak = norm[i];
    const ddFrac = peak > 0 ? norm[i] / peak - 1 : 0;
    if (ddFrac < mdd) mdd = ddFrac;
    const ddPct = ddFrac * 100;
    ddSqSum += ddPct * ddPct;
  }
  const calmar = Math.abs(mdd) > 1e-9 ? cagr / Math.abs(mdd) : null;
  const ulcerIndex = Math.sqrt(ddSqSum / n);

  let winRate3y = null;
  if (n > 756) {
    let wins3 = 0;
    for (let i = 756; i < n; i++) {
      if (norm[i] / norm[i - 756] >= qNorm[i] / qNorm[i - 756]) wins3++;
    }
    winRate3y = wins3 / (n - 756);
  }

  let winRate5y = null;
  if (n > 1260) {
    let wins5 = 0;
    for (let i = 1260; i < n; i++) {
      if (norm[i] / norm[i - 1260] >= qNorm[i] / qNorm[i - 1260]) wins5++;
    }
    winRate5y = wins5 / (n - 1260);
  }

  let avgQqqWeight = null;
  let switchCount = 0;
  let annualTurnover = null;
  if (Array.isArray(weights) && weights.length === n) {
    avgQqqWeight = mean(weights);
    let turnSum = 0;
    for (let i = 1; i < n; i++) {
      const diff = Math.abs(weights[i] - weights[i - 1]);
      turnSum += diff;
      if (diff >= 0.0999) switchCount++;
    }
    annualTurnover = turnSum / years;
  }

  return {
    observations: n,
    startDate: dates[0],
    endDate: dates[n - 1],
    years: round(years, 4),
    endingMultiple: round(mult, 4),
    endingValue: round(mult, 4),
    totalReturn: round(totalReturn, 6),
    cagr: round(cagr, 6),
    volatility: round(vol, 6),
    sharpe: round(sharpe, 3),
    sharpeZeroRf: round(sharpeZeroRf, 4),
    sortino: round(sortino, 3),
    maxDrawdown: round(mdd, 6),
    calmar: round(calmar, 3),
    ulcerIndex: round(ulcerIndex, 2),
    avgQqqWeight: round(avgQqqWeight, 4),
    switchCount,
    annualTurnover: round(annualTurnover, 4),
    winRate3y: round(winRate3y, 4),
    winRate5y: round(winRate5y, 4),
  };
}

function buildDrawdownSeries(navs, endIdx = navs.length - 1, startIdx = 0) {
  let peak = navs[startIdx] > 0 ? navs[startIdx] : 1;
  const out = new Array(endIdx - startIdx + 1);
  for (let i = startIdx; i <= endIdx; i++) {
    if (navs[i] > peak) peak = navs[i];
    out[i - startIdx] = peak > 0 ? round(navs[i] / peak - 1, 6) : 0;
  }
  return out;
}

function computeYearlyFromSeries(ser, endIdx) {
  const dates = ser.dates.slice(0, endIdx + 1);
  const years = [...new Set(dates.map(d => d.slice(0, 4)))].sort();
  return years.map((yr, idxY) => {
    const firstIdx = dates.findIndex(d => d.startsWith(`${yr}-`));
    let lastIdx = firstIdx;
    for (let i = dates.length - 1; i >= firstIdx; i--) {
      if (dates[i].startsWith(`${yr}-`)) {
        lastIdx = i;
        break;
      }
    }
    const baseIdx = firstIdx > 0 ? firstIdx - 1 : 0;
    const partial =
      (idxY === 0 && dates[0] > `${yr}-01-05`) ||
      (idxY === years.length - 1 && dates.at(-1) < `${yr}-12-28`);
    const row = {
      year: Number(yr),
      label: partial ? `${yr}*` : yr,
      partial,
      from: dates[baseIdx],
      to: dates[lastIdx],
    };
    for (const k of ['m6', 'm4', 'm7', 'qqq', 'schd', 'static7030']) {
      const baseVal = firstIdx > 0 ? ser[k][baseIdx] : ser[k][0];
      row[k] = baseVal > 0 ? round(ser[k][lastIdx] / baseVal - 1, 6) : 0;
    }
    return row;
  });
}

export function validateQqqSchdRotationDashboard(payload) {
  if (payload?.version !== QQQ_SCHD_ROTATION_VERSION) {
    fail('qqq_schd_rotation_snapshot_invalid');
  }
  if (
    !isIsoDate(payload.liveInceptionDate) ||
    !isIsoDate(payload.fullInceptionDate) ||
    !isIsoDate(payload.dataThrough) ||
    !/^[a-f0-9]{64}$/.test(payload.lineage?.sourceGeneration ?? '') ||
    payload.lineage?.sourceWrites !== false ||
    payload.lineage?.pointInTimeFundamentals !== true ||
    payload.lineage?.tPlusOneExecution !== true ||
    payload.lineage?.allDailyNavReconciled !== true
  ) {
    fail('qqq_schd_rotation_snapshot_invalid');
  }

  for (const winKey of QQQ_SCHD_WINDOWS) {
    const win = payload.windows?.[winKey];
    const ser = win?.series;
    if (!win || !ser || !Array.isArray(ser.dates) || ser.dates.length < 2) {
      fail('qqq_schd_rotation_snapshot_invalid');
    }
    if (ser.dates.at(-1) !== payload.dataThrough) {
      fail('qqq_schd_rotation_snapshot_invalid');
    }
    const n = ser.dates.length;
    for (const col of ['m6', 'm4', 'm7', 'qqq', 'schd', 'static7030', 'm6w', 'm4w', 'm7w', 'rfRet']) {
      if (!Array.isArray(ser[col]) || ser[col].length !== n) {
        fail('qqq_schd_rotation_snapshot_invalid');
      }
    }
    for (let i = 0; i < n; i++) {
      if (
        !isIsoDate(ser.dates[i]) ||
        (i > 0 && ser.dates[i] <= ser.dates[i - 1]) ||
        !['m6', 'm4', 'm7', 'qqq', 'schd', 'static7030'].every(k => Number.isFinite(ser[k][i]) && ser[k][i] > 0)
      ) {
        fail('qqq_schd_rotation_snapshot_invalid');
      }
    }
  }

  for (const modeId of QQQ_SCHD_MODES) {
    const m = payload.modes?.[modeId];
    if (
      !m ||
      m.id !== modeId ||
      !Array.isArray(m.blueprint) ||
      m.blueprint.length !== 4 ||
      !Array.isArray(m.switches) ||
      !m.metrics?.live_2011 ||
      !m.metrics?.full_2000
    ) {
      fail('qqq_schd_rotation_snapshot_invalid');
    }
  }

  if (!payload.liveRadar || !Array.isArray(payload.regimeAttribution) || !Array.isArray(payload.taxSensitivity)) {
    fail('qqq_schd_rotation_snapshot_invalid');
  }

  return payload;
}

const fileCaches = new Map();
let promotedRuntimeFile = null;
let refreshInFlight = null;
let lastCheckedCatalogGen = null;

function readValidatedArtifact(targetFile) {
  const resolved = path.resolve(String(targetFile));
  let stat;
  try {
    stat = fs.statSync(resolved);
  } catch {
    fail('qqq_schd_rotation_snapshot_unavailable');
  }
  const cacheKey = `${resolved}:${stat.ino}:${stat.size}:${stat.mtimeMs}`;
  const existing = fileCaches.get(resolved);
  if (existing?.key === cacheKey) return existing;

  let parsed, source;
  try {
    source = fs.readFileSync(resolved, 'utf8');
    parsed = validateQqqSchdRotationDashboard(JSON.parse(source));
  } catch (err) {
    if (err.status) throw err;
    fail('qqq_schd_rotation_snapshot_unavailable');
  }
  const id = createHash('sha256').update(source).digest('hex');
  const entry = { key: cacheKey, payload: parsed, id, file: resolved };
  fileCaches.set(resolved, entry);
  return entry;
}

function resolvePythonBinary() {
  if (process.env.FACT_OS_PYTHON) return process.env.FACT_OS_PYTHON;
  if (process.env.NODE_ENV === 'production' && fs.existsSync('/opt/thesisforge-fact-os/bin/python')) {
    return '/opt/thesisforge-fact-os/bin/python';
  }
  return path.join(projectRoot, '.venv-fact-os/bin/python');
}

function spawnPythonJson(python, args, envOverrides = {}, timeoutMs = 45_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(python, args, {
      cwd: projectRoot,
      env: {
        PATH: process.env.PATH || '/usr/bin:/bin',
        PYTHONUNBUFFERED: '1',
        LANG: 'en_US.UTF-8',
        FACT_OS_TEMP_ROOT: process.env.FACT_OS_TEMP_ROOT || path.join(os.tmpdir(), 'thesisforge-fact-os-tmp'),
        ...envOverrides,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let finished = false;
    const done = (err, val) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      if (err) reject(err);
      else resolve(val);
    };
    const timer = setTimeout(() => {
      child.kill();
      done(new Error('qqq_schd_refresh_timeout'));
    }, timeoutMs);
    child.stdout.on('data', chunk => {
      stdout += chunk;
    });
    child.stderr.resume();
    child.on('error', err => done(err));
    child.on('close', code => {
      if (code !== 0) return done(new Error(`qqq_schd_refresh_exit_${code}`));
      try {
        done(null, JSON.parse(stdout.trim()));
      } catch (err) {
        done(err);
      }
    });
  });
}

export async function refreshQqqSchdRotationFromCanonical({ factRoot = null, currentDataThrough = null } = {}) {
  const root = path.resolve(
    factRoot ?? releaseRoot('canonical', process.env.FACT_OS_ROOT || path.join(projectRoot, 'data/fact_os')),
  );
  const catalogFile = path.join(root, 'manifests/catalog.json');
  const python = resolvePythonBinary();
  if (!fs.existsSync(catalogFile) || !fs.existsSync(python) || !fs.existsSync(builderScript)) {
    return { refreshed: false, reason: 'runtime_or_catalog_missing' };
  }

  const catalogGen = createHash('sha256').update(fs.readFileSync(catalogFile)).digest('hex');
  fs.mkdirSync(runtimeCacheDir, { recursive: true });
  const envOverrides = process.env.FACT_OS_LEASE_ROOT
    ? { FACT_OS_LEASE_ROOT: process.env.FACT_OS_LEASE_ROOT }
    : dataReleaseId()
      ? { FACT_OS_LEASE_ROOT: '/var/app/data/fact-os-leases' }
      : {};

  let releaseGuard = null;
  if (!factRoot && dataReleaseId()) {
    try {
      releaseGuard = retainDataRelease();
    } catch {
      releaseGuard = null;
    }
  }

  try {
    const probe = await spawnPythonJson(python, [builderScript, '--fact-root', root, '--probe-max-date'], envOverrides, 20_000);
    if (!probe?.maxDate || !isIsoDate(probe.maxDate)) {
      return { refreshed: false, reason: 'invalid_max_date' };
    }
    const baselineThrough = currentDataThrough ?? readValidatedArtifact(promotedRuntimeFile ?? defaultFile).payload.dataThrough;
    if (probe.maxDate <= baselineThrough) {
      lastCheckedCatalogGen = catalogGen;
      return { refreshed: false, reason: 'up_to_date', maxDate: probe.maxDate };
    }

    const cachedOut = path.join(runtimeCacheDir, `qqq-schd-rotation-${catalogGen.slice(0, 16)}-${probe.maxDate}.json`);
    if (!fs.existsSync(cachedOut)) {
      await spawnPythonJson(
        python,
        [builderScript, '--forward-extend', '--fact-root', root, '--base-artifact', defaultFile, '--output', cachedOut],
        envOverrides,
        45_000,
      );
    }
    const verified = readValidatedArtifact(cachedOut);
    promotedRuntimeFile = verified.file;
    lastCheckedCatalogGen = catalogGen;
    return {
      refreshed: true,
      file: verified.file,
      snapshotId: verified.id,
      dataThrough: verified.payload.dataThrough,
    };
  } finally {
    if (releaseGuard) releaseGuard();
  }
}

function maybeScheduleBackgroundRefresh(currentDataThrough) {
  if (process.env.QQQ_SCHD_ROTATION_AUTO_REFRESH === '0') return;
  if (process.env.NODE_ENV !== 'production' && process.env.QQQ_SCHD_ROTATION_AUTO_REFRESH !== '1') return;
  if (refreshInFlight) return;
  try {
    const root = path.resolve(
      releaseRoot('canonical', process.env.FACT_OS_ROOT || path.join(projectRoot, 'data/fact_os')),
    );
    const catalogFile = path.join(root, 'manifests/catalog.json');
    if (!fs.existsSync(catalogFile)) return;
    const stat = fs.statSync(catalogFile);
    const quickSig = `${root}:${stat.size}:${stat.mtimeMs}`;
    if (lastCheckedCatalogGen === quickSig) return;
    lastCheckedCatalogGen = quickSig;
    refreshInFlight = refreshQqqSchdRotationFromCanonical({ factRoot: root, currentDataThrough })
      .catch(err => {
        console.warn('[qqq-schd-rotation] background canonical refresh skipped:', err?.message || 'unknown');
      })
      .finally(() => {
        refreshInFlight = null;
      });
  } catch {
    // Non-blocking best-effort forward refresh.
  }
}

function findCutoffIndex(dates, cutoff) {
  let lo = 0;
  let hi = dates.length - 1;
  let ans = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (dates[mid] <= cutoff) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

function buildCurveRows(ser, endIdx) {
  const m6Dd = buildDrawdownSeries(ser.m6, endIdx, 0);
  const m4Dd = buildDrawdownSeries(ser.m4, endIdx, 0);
  const m7Dd = buildDrawdownSeries(ser.m7, endIdx, 0);
  const qqqDd = buildDrawdownSeries(ser.qqq, endIdx, 0);
  const schdDd = buildDrawdownSeries(ser.schd, endIdx, 0);
  const s70Dd = buildDrawdownSeries(ser.static7030, endIdx, 0);

  const rows = new Array(endIdx + 1);
  for (let i = 0; i <= endIdx; i++) {
    rows[i] = {
      date: ser.dates[i],
      m6: ser.m6[i],
      m4: ser.m4[i],
      m7: ser.m7[i],
      qqq: ser.qqq[i],
      schd: ser.schd[i],
      static7030: ser.static7030[i],
      m6Dd: m6Dd[i],
      m4Dd: m4Dd[i],
      m7Dd: m7Dd[i],
      qqqDd: qqqDd[i],
      schdDd: schdDd[i],
      static7030Dd: s70Dd[i],
      m6w: ser.m6w[i],
      m4w: ser.m4w[i],
      m7w: ser.m7w[i],
      posPe: ser.posPe[i],
      fcfYield: ser.fcfYield[i],
      vix: ser.vix[i],
      rsi14: ser.rsi14[i],
      dd2y: ser.dd2y[i],
      ma150Dist: ser.ma150Dist[i],
      qqqAdj: ser.qqqAdj[i],
    };
  }
  return rows;
}

function sliceSwitchesAtCutoff(switches, fullSer, cutoffDate, windowId) {
  const filtered = switches.filter(sw => sw.date <= cutoffDate && (windowId === 'full_2000' || sw.inLiveWindow));
  const cutIdx = findCutoffIndex(fullSer.dates, cutoffDate);
  if (cutIdx < 0) return [];
  const dateToIdx = new Map();
  for (let i = 0; i <= cutIdx; i++) dateToIdx.set(fullSer.dates[i], i);

  return filtered.map((sw, idx) => {
    const isLast = idx === filtered.length - 1;
    if (!isLast && sw.nextSwitchDate <= cutoffDate) {
      return sw;
    }
    const startIdx = dateToIdx.get(sw.date);
    if (startIdx === undefined) return sw;
    const modeCol = sw.switchId.slice(0, 2).toLowerCase();
    const sRet = fullSer[modeCol][cutIdx] / fullSer[modeCol][startIdx] - 1;
    const qRet = fullSer.qqq[cutIdx] / fullSer.qqq[startIdx] - 1;
    const dRet = fullSer.schd[cutIdx] / fullSer.schd[startIdx] - 1;
    return {
      ...sw,
      nextSwitchDate: cutoffDate,
      isOpenRegime: true,
      holdingDays: cutIdx - startIdx,
      intervalStrategyReturn: round(sRet, 6),
      intervalQqqReturn: round(qRet, 6),
      intervalSchdReturn: round(dRet, 6),
      intervalExcessVsQqq: round(sRet - qRet, 6),
    };
  });
}

function sliceRadarAtCutoff(payload, fullSer, cutIdx) {
  const cutDate = fullSer.dates[cutIdx];
  if (cutDate === payload.dataThrough) {
    return payload.liveRadar;
  }
  const qAdj = fullSer.qqqAdj[cutIdx];
  const posPe = fullSer.posPe[cutIdx];
  const fcfYieldPct = fullSer.fcfYield[cutIdx];
  const vix = fullSer.vix[cutIdx];
  const rsi14 = fullSer.rsi14[cutIdx];
  const dd2yPct = fullSer.dd2y[cutIdx];
  const ma150DistPct = fullSer.ma150Dist[cutIdx];
  const m6w = fullSer.m6w[cutIdx];
  const m4w = fullSer.m4w[cutIdx];
  const m7w = fullSer.m7w[cutIdx];

  const describeAlloc = w => {
    const qPct = Math.round(w * 1000) / 10;
    const sPct = Math.round((1 - w) * 1000) / 10;
    if (w >= 0.99) {
      return {
        qqqWeight: w,
        schdWeight: 0,
        stateLabel: { en: 'Full Offense · 100% QQQ', zh: '满仓进攻 · 100% QQQ' },
        actionInstruction: {
          en: 'Holding 100% QQQ in growth compounding regime.',
          zh: '处于满仓 QQQ 复利进攻状态。',
        },
      };
    }
    if (w <= 0.01) {
      return {
        qqqWeight: 0,
        schdWeight: 1,
        stateLabel: { en: 'Defensive Hold · 100% SCHD', zh: '防守持仓 · 100% SCHD' },
        actionInstruction: {
          en: 'Holding 100% SCHD defensive cash-cow buffer; waiting for left-side panic or right-side FCF recovery.',
          zh: '战术仓驻守 100% SCHD 防守避险，静待左侧恐慌极值或右侧现金流修复买点。',
        },
      };
    }
    return {
      qqqWeight: w,
      schdWeight: round(1 - w, 4),
      stateLabel: { en: `Staged Mix · ${qPct}% QQQ / ${sPct}% SCHD`, zh: `分批配置 · ${qPct}% QQQ / ${sPct}% SCHD` },
      actionInstruction: {
        en: `Active staged allocation: ${qPct}% QQQ and ${sPct}% SCHD.`,
        zh: `当前分批配比：${qPct}% QQQ 与 ${sPct}% SCHD。`,
      },
    };
  };

  return {
    ...payload.liveRadar,
    asOfDate: cutDate,
    qqqClose: qAdj,
    dd2yPct,
    ma150DistPct,
    posPe,
    fcfYieldPct,
    pFcf: fcfYieldPct && fcfYieldPct > 0 ? round(100 / fcfYieldPct, 2) : null,
    vix,
    rsi14,
    allocations: {
      m6: describeAlloc(m6w),
      m4: describeAlloc(m4w),
      m7: describeAlloc(m7w),
    },
  };
}

export function loadQqqSchdRotationDashboard({
  file = null,
  asOf = null,
  mode = 'm6',
  window = 'live_2011',
  snapshotId = null,
} = {}) {
  if (asOf !== null && !isIsoDate(asOf)) fail('invalid_as_of', 400);
  if (!QQQ_SCHD_MODES.includes(mode)) fail('invalid_strategy_mode', 400);
  if (!QQQ_SCHD_WINDOWS.includes(window)) fail('invalid_strategy_window', 400);

  const activeFile = file ?? promotedRuntimeFile ?? defaultFile;
  const { payload, id } = readValidatedArtifact(activeFile);
  if (!file) maybeScheduleBackgroundRefresh(payload.dataThrough);
  if (snapshotId && snapshotId !== id) fail('qqq_schd_rotation_snapshot_changed', 409);

  const cutoff = asOf && asOf < payload.dataThrough ? asOf : payload.dataThrough;
  const winObj = payload.windows[window];
  const ser = winObj.series;
  const cutIdx = findCutoffIndex(ser.dates, cutoff);

  if (cutIdx < 1) {
    return {
      version: payload.version,
      status: 'unavailable_before_first_observation',
      snapshotId: id,
      requestedAsOf: asOf,
      dataThrough: cutIdx === 0 ? ser.dates[0] : null,
      window,
      selectedMode: mode,
      liveInceptionDate: payload.liveInceptionDate,
      fullInceptionDate: payload.fullInceptionDate,
      modesSummary: {},
      backtest: { curve: [] },
      lineage: { ...payload.lineage, snapshotId: id },
    };
  }

  const atFullEnd = ser.dates[cutIdx] === payload.dataThrough;
  const fullSer = payload.windows.full_2000.series;
  const fullCutIdx = findCutoffIndex(fullSer.dates, cutoff);
  const liveSer = payload.windows.live_2011.series;
  const liveCutIdx = findCutoffIndex(liveSer.dates, cutoff);

  const sliceMetricsFor = (wSer, wCutIdx, col, wCol = null) => {
    if (wCutIdx < 1) return null;
    return computeRotationWindowMetrics(
      wSer.dates.slice(0, wCutIdx + 1),
      wSer[col].slice(0, wCutIdx + 1),
      wSer.qqq.slice(0, wCutIdx + 1),
      wSer.rfRet.slice(0, wCutIdx + 1),
      wCol ? wSer[wCol].slice(0, wCutIdx + 1) : null,
    );
  };

  const modesSummary = {};
  for (const mk of QQQ_SCHD_MODES) {
    const mDef = payload.modes[mk];
    const mLive = atFullEnd ? mDef.metrics.live_2011 : sliceMetricsFor(liveSer, liveCutIdx, mk, `${mk}w`);
    const mFull = atFullEnd ? mDef.metrics.full_2000 : sliceMetricsFor(fullSer, fullCutIdx, mk, `${mk}w`);
    modesSummary[mk] = {
      id: mk,
      code: mDef.code,
      badge: mDef.badge,
      name: mDef.name,
      shortLabel: mDef.shortLabel,
      summary: mDef.summary,
      accountFit: mDef.accountFit,
      metrics: window === 'live_2011' ? mLive : mFull,
      metricsByWindow: {
        live_2011: mLive,
        full_2000: mFull,
      },
    };
  }

  const benchmarks = atFullEnd
    ? winObj.benchmarks
    : {
        qqq: sliceMetricsFor(ser, cutIdx, 'qqq'),
        schd: sliceMetricsFor(ser, cutIdx, 'schd'),
        static7030: sliceMetricsFor(ser, cutIdx, 'static7030'),
      };

  const activeModeDef = payload.modes[mode];
  const switches = sliceSwitchesAtCutoff(activeModeDef.switches, fullSer, ser.dates[cutIdx], window);
  const curve = buildCurveRows(ser, cutIdx);
  const yearlyReturns = atFullEnd ? winObj.yearlyReturns : computeYearlyFromSeries(ser, cutIdx);
  const radar = sliceRadarAtCutoff(payload, fullSer, fullCutIdx);

  return {
    version: payload.version,
    status: 'ready',
    snapshotId: id,
    generatedAt: payload.generatedAt,
    requestedAsOf: asOf,
    dataThrough: ser.dates[cutIdx],
    liveInceptionDate: payload.liveInceptionDate,
    fullInceptionDate: payload.fullInceptionDate,
    window,
    windowLabel: winObj.label,
    availableWindows: QQQ_SCHD_WINDOWS.map(wk => ({
      id: wk,
      label: payload.windows[wk].label,
      inceptionDate: payload.windows[wk].series.inceptionDate,
      observations: wk === 'live_2011' ? Math.max(0, liveCutIdx + 1) : Math.max(0, fullCutIdx + 1),
    })),
    selectedMode: mode,
    defaultMode: payload.defaultMode,
    executionAssumptions: payload.executionAssumptions,
    modesSummary,
    mode: {
      id: activeModeDef.id,
      code: activeModeDef.code,
      badge: activeModeDef.badge,
      name: activeModeDef.name,
      shortLabel: activeModeDef.shortLabel,
      summary: activeModeDef.summary,
      accountFit: activeModeDef.accountFit,
      blueprint: activeModeDef.blueprint,
      metrics: modesSummary[mode].metrics,
      metricsByWindow: modesSummary[mode].metricsByWindow,
      switches,
      allSwitches27y: sliceSwitchesAtCutoff(activeModeDef.switches, fullSer, ser.dates[cutIdx], 'full_2000'),
    },
    benchmarks,
    backtest: {
      inceptionDate: ser.dates[0],
      endDate: ser.dates[cutIdx],
      observations: curve.length,
      curve,
      yearlyReturns,
    },
    canonicalComparison: winObj.canonicalComparison,
    canonicalComparisonByWindow: {
      live_2011: payload.windows.live_2011.canonicalComparison,
      full_2000: payload.windows.full_2000.canonicalComparison,
    },
    robustnessGrid: winObj.robustnessGrid,
    robustnessGridByWindow: {
      live_2011: payload.windows.live_2011.robustnessGrid,
      full_2000: payload.windows.full_2000.robustnessGrid,
    },
    traps: payload.traps,
    sopTable: payload.sopTable,
    regimeAttribution: payload.regimeAttribution.filter(r => r.start <= ser.dates[cutIdx]),
    taxSensitivity: payload.taxSensitivity,
    liveRadar: radar,
    lineage: {
      ...payload.lineage,
      snapshotId: id,
    },
  };
}

export function analyzeQqqSchdRotationRange({
  file = null,
  asOf = null,
  mode = 'm6',
  window = 'live_2011',
  snapshotId = null,
  start = null,
  end = null,
} = {}) {
  if (asOf !== null && !isIsoDate(asOf)) fail('invalid_as_of', 400);
  if (!QQQ_SCHD_MODES.includes(mode)) fail('invalid_strategy_mode', 400);
  if (!QQQ_SCHD_WINDOWS.includes(window)) fail('invalid_strategy_window', 400);

  const activeFile = file ?? promotedRuntimeFile ?? defaultFile;
  const { payload, id } = readValidatedArtifact(activeFile);
  if (!file) maybeScheduleBackgroundRefresh(payload.dataThrough);
  if (!snapshotId || snapshotId !== id) fail('qqq_schd_rotation_snapshot_changed', 409);

  if (!isIsoDate(start) || !isIsoDate(end) || start >= end) {
    fail('invalid_analysis_range', 400);
  }

  const cutoff = asOf && asOf < payload.dataThrough ? asOf : payload.dataThrough;
  const ser = payload.windows[window].series;
  const maxIdx = findCutoffIndex(ser.dates, cutoff);
  if (maxIdx < 1) fail('invalid_analysis_range', 400);

  // Snap start forward to first trading session >= start, and end backward to last session <= end
  let first = -1;
  for (let i = 0; i <= maxIdx; i++) {
    if (ser.dates[i] >= start) {
      first = i;
      break;
    }
  }
  const last = findCutoffIndex(ser.dates.slice(0, maxIdx + 1), end);
  if (first < 0 || last < 0 || first >= last) {
    fail('invalid_analysis_range', 400);
  }

  const subDates = ser.dates.slice(first, last + 1);
  const subStrat = ser[mode].slice(first, last + 1);
  const subQqq = ser.qqq.slice(first, last + 1);
  const subSchd = ser.schd.slice(first, last + 1);
  const subS70 = ser.static7030.slice(first, last + 1);
  const subRf = ser.rfRet.slice(first, last + 1);
  const subW = ser[`${mode}w`].slice(first, last + 1);

  const metrics = computeRotationWindowMetrics(subDates, subStrat, subQqq, subRf, subW);
  const qqqMetrics = computeRotationWindowMetrics(subDates, subQqq, subQqq, subRf);
  const schdMetrics = computeRotationWindowMetrics(subDates, subSchd, subQqq, subRf);
  const static7030Metrics = computeRotationWindowMetrics(subDates, subS70, subQqq, subRf);

  // Sleeve attribution across [first, last]
  let qqqSleeveLog = 0;
  let schdSleeveLog = 0;
  let costDragSum = 0;
  let qqqDaysDominant = 0;
  let schdDaysDominant = 0;
  for (let i = first; i <= last; i++) {
    const w = ser[`${mode}w`][i];
    if (w >= 0.5) qqqDaysDominant++;
    else schdDaysDominant++;
    if (i > first) {
      const qRet = ser.qqq[i - 1] > 0 ? ser.qqq[i] / ser.qqq[i - 1] - 1 : 0;
      const sRet = ser.schd[i - 1] > 0 ? ser.schd[i] / ser.schd[i - 1] - 1 : 0;
      const turn = Math.abs(w - ser[`${mode}w`][i - 1]);
      const tc = turn * 2 * (payload.executionAssumptions.slippageBpsPerSide / 10000);
      qqqSleeveLog += w * qRet;
      schdSleeveLog += (1 - w) * sRet;
      costDragSum += tc;
    }
  }

  const m6Dd = buildDrawdownSeries(ser.m6, last, first);
  const m4Dd = buildDrawdownSeries(ser.m4, last, first);
  const m7Dd = buildDrawdownSeries(ser.m7, last, first);
  const qqqDd = buildDrawdownSeries(ser.qqq, last, first);
  const schdDd = buildDrawdownSeries(ser.schd, last, first);
  const s70Dd = buildDrawdownSeries(ser.static7030, last, first);

  const bM6 = ser.m6[first];
  const bM4 = ser.m4[first];
  const bM7 = ser.m7[first];
  const bQqq = ser.qqq[first];
  const bSchd = ser.schd[first];
  const bS70 = ser.static7030[first];

  const rebasedCurve = new Array(last - first + 1);
  for (let i = first; i <= last; i++) {
    const k = i - first;
    rebasedCurve[k] = {
      date: ser.dates[i],
      m6: round(ser.m6[i] / bM6, 6),
      m4: round(ser.m4[i] / bM4, 6),
      m7: round(ser.m7[i] / bM7, 6),
      qqq: round(ser.qqq[i] / bQqq, 6),
      schd: round(ser.schd[i] / bSchd, 6),
      static7030: round(ser.static7030[i] / bS70, 6),
      m6Dd: m6Dd[k],
      m4Dd: m4Dd[k],
      m7Dd: m7Dd[k],
      qqqDd: qqqDd[k],
      schdDd: schdDd[k],
      static7030Dd: s70Dd[k],
      m6w: ser.m6w[i],
      m4w: ser.m4w[i],
      m7w: ser.m7w[i],
      posPe: ser.posPe[i],
      fcfYield: ser.fcfYield[i],
      vix: ser.vix[i],
      rsi14: ser.rsi14[i],
      dd2y: ser.dd2y[i],
      ma150Dist: ser.ma150Dist[i],
      qqqAdj: ser.qqqAdj[i],
    };
  }

  const switchesInRange = payload.modes[mode].switches.filter(
    sw => sw.date >= subDates[0] && sw.date <= subDates.at(-1),
  );

  return {
    version: QQQ_SCHD_ANALYSIS_VERSION,
    snapshotId: id,
    mode,
    window,
    requestedStart: start,
    requestedEnd: end,
    start: subDates[0],
    end: subDates.at(-1),
    observations: subDates.length,
    metrics,
    benchmarks: {
      qqq: qqqMetrics,
      schd: schdMetrics,
      static7030: static7030Metrics,
    },
    comparison: {
      excessReturnVsQqq: round(metrics.totalReturn - qqqMetrics.totalReturn, 6),
      excessCagrVsQqq: round(metrics.cagr - qqqMetrics.cagr, 6),
      excessReturnVsSchd: round(metrics.totalReturn - schdMetrics.totalReturn, 6),
      excessReturnVsStatic7030: round(metrics.totalReturn - static7030Metrics.totalReturn, 6),
      maxDrawdownImprovementVsQqq: round(metrics.maxDrawdown - qqqMetrics.maxDrawdown, 6),
      ulcerReductionRatioVsQqq:
        qqqMetrics.ulcerIndex > 0 ? round(metrics.ulcerIndex / qqqMetrics.ulcerIndex - 1, 4) : null,
    },
    allocationAttribution: {
      startQqqWeight: subW[0],
      endQqqWeight: subW.at(-1),
      avgQqqWeight: metrics.avgQqqWeight,
      avgSchdWeight: round(1 - (metrics.avgQqqWeight ?? 0), 4),
      qqqDominantDays: qqqDaysDominant,
      schdDominantDays: schdDaysDominant,
      additiveQqqContribution: round(qqqSleeveLog, 6),
      additiveSchdContribution: round(schdSleeveLog, 6),
      switchingCostDrag: round(costDragSum, 6),
      switchCount: switchesInRange.length,
    },
    switchesInRange,
    curve: rebasedCurve,
    lineage: {
      portfolioSnapshotId: id,
      sourceSnapshotGeneration: payload.lineage?.sourceGeneration ?? null,
      allDailyNavReconciled: true,
      method: QQQ_SCHD_ANALYSIS_VERSION,
    },
  };
}
