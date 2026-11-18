import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { strategyMetrics } from './strategyLab.js';
import { releaseRoot, dataReleaseId, retainDataRelease } from './dataReleaseContext.js';

export const BREAKOUT_ARTIFACT_VERSION = 'hot-breakout-pullback-v1';
export const BREAKOUT_ANALYSIS_VERSION = 'breakout-range-attribution-v1';
export const BREAKOUT_MODES = Object.freeze(['flagship', 'balanced']);

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultFile = path.resolve(projectRoot, 'server/config/hot-breakout-pullback-dashboard.json');
const builderScript = path.resolve(projectRoot, 'scripts/build-breakout-pullback-artifact.py');
const runtimeCacheDir = path.resolve(
  process.env.BREAKOUT_PULLBACK_CACHE_DIR ||
    (process.env.NODE_ENV === 'production' && fs.existsSync('/var/app/data')
      ? '/var/app/data/breakout-pullback-cache'
      : path.join(os.tmpdir(), 'thesisforge-breakout-pullback-cache')),
);

function fail(code, status = 503) {
  throw Object.assign(new Error(code), { status });
}

const isIsoDate = value =>
  /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;

const sum = xs => xs.reduce((a, b) => a + b, 0);
const near = (a, b, tol = 1e-7) =>
  Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= tol * Math.max(1, Math.abs(b));
const round4 = v => (Number.isFinite(v) ? Math.round(v * 10000) / 10000 : null);

function withCalmar(metrics) {
  if (!metrics) return null;
  const calmar =
    metrics.cagr !== null && Number.isFinite(metrics.maxDrawdown) && metrics.maxDrawdown < -1e-9
      ? metrics.cagr / Math.abs(metrics.maxDrawdown)
      : null;
  return { ...metrics, calmar };
}

export function validateBreakoutPullbackDashboard(payload) {
  if (payload?.version !== BREAKOUT_ARTIFACT_VERSION) {
    fail('breakout_pullback_snapshot_invalid');
  }
  const curve = Array.isArray(payload.backtest?.curve) ? payload.backtest.curve : [];
  if (
    curve.length < 2 ||
    !isIsoDate(payload.inceptionDate) ||
    !isIsoDate(payload.dataThrough) ||
    curve[0].date !== payload.inceptionDate ||
    curve.at(-1).date !== payload.dataThrough ||
    !/^[a-f0-9]{64}$/.test(payload.lineage?.sourceGeneration ?? '') ||
    payload.lineage?.sourceWrites !== false ||
    payload.lineage?.survivorshipBiasFree !== true ||
    payload.lineage?.allDailyNavReconciled !== true
  ) {
    fail('breakout_pullback_snapshot_invalid');
  }

  for (let i = 0; i < curve.length; i++) {
    const row = curve[i];
    if (
      !isIsoDate(row.date) ||
      (i > 0 && row.date <= curve[i - 1].date) ||
      !['flagship', 'balanced', 'spy', 'qqq'].every(k => Number.isFinite(row[k]) && row[k] > 0)
    ) {
      fail('breakout_pullback_snapshot_invalid');
    }
  }

  for (const modeId of BREAKOUT_MODES) {
    const mode = payload.modes?.[modeId];
    if (
      !mode ||
      mode.id !== modeId ||
      !Array.isArray(mode.blueprint) ||
      mode.blueprint.length !== 5 ||
      !Array.isArray(mode.lots) ||
      !Array.isArray(mode.episodes)
    ) {
      fail('breakout_pullback_snapshot_invalid');
    }
    const computed = withCalmar(strategyMetrics(curve.map(r => ({ date: r.date, value: r[modeId] }))));
    if (!computed) fail('breakout_pullback_snapshot_invalid');
    for (const k of ['totalReturn', 'endingValue', 'cagr', 'maxDrawdown', 'volatility', 'sharpeZeroRf']) {
      if (!near(computed[k], mode.metrics?.[k], 1e-6)) {
        fail('breakout_pullback_snapshot_invalid');
      }
    }
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
    fail('breakout_pullback_snapshot_unavailable');
  }
  const cacheKey = `${resolved}:${stat.ino}:${stat.size}:${stat.mtimeMs}`;
  const existing = fileCaches.get(resolved);
  if (existing?.key === cacheKey) return existing;

  let parsed, source;
  try {
    source = fs.readFileSync(resolved, 'utf8');
    parsed = validateBreakoutPullbackDashboard(JSON.parse(source));
  } catch (err) {
    if (err.status) throw err;
    fail('breakout_pullback_snapshot_unavailable');
  }
  const id = createHash('sha256').update(source).digest('hex');
  const entry = { key: cacheKey, payload: parsed, id, file: resolved, slices: new Map() };
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

function spawnPythonJson(python, args, envOverrides = {}, timeoutMs = 120_000) {
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
      done(new Error('breakout_refresh_timeout'));
    }, timeoutMs);
    child.stdout.on('data', chunk => {
      stdout += chunk;
    });
    child.stderr.resume();
    child.on('error', err => done(err));
    child.on('close', code => {
      if (code !== 0) return done(new Error(`breakout_refresh_exit_${code}`));
      try {
        done(null, JSON.parse(stdout.trim()));
      } catch (err) {
        done(err);
      }
    });
  });
}

export async function refreshBreakoutPullbackFromCanonical({ factRoot = null, currentDataThrough = null } = {}) {
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
    const probe = await spawnPythonJson(python, [builderScript, '--fact-root', root, '--probe-max-date'], envOverrides, 30_000);
    if (!probe?.maxDate || !isIsoDate(probe.maxDate)) {
      return { refreshed: false, reason: 'invalid_max_date' };
    }
    const baselineThrough = currentDataThrough ?? readValidatedArtifact(promotedRuntimeFile ?? defaultFile).payload.dataThrough;
    if (probe.maxDate <= baselineThrough) {
      lastCheckedCatalogGen = catalogGen;
      return { refreshed: false, reason: 'up_to_date', maxDate: probe.maxDate };
    }

    const cachedOut = path.join(runtimeCacheDir, `hot-breakout-${catalogGen.slice(0, 16)}-${probe.maxDate}.json`);
    if (!fs.existsSync(cachedOut)) {
      await spawnPythonJson(
        python,
        [builderScript, '--fact-root', root, '--output', cachedOut],
        envOverrides,
        180_000,
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

const MIN_AUTO_REFRESH_MEMORY_BYTES = 3.5 * 1024 * 1024 * 1024;

function maybeScheduleBackgroundRefresh(currentDataThrough) {
  if (process.env.BREAKOUT_PULLBACK_AUTO_REFRESH === '0') return;
  if (process.env.NODE_ENV !== 'production' && process.env.BREAKOUT_PULLBACK_AUTO_REFRESH !== '1') return;
  // Rebuilding the 10-year OHLCV strategy tensor requires ~1.5-2.0 GiB of RAM.
  // On 2 GiB web instances (e.g. t3.small), skip in-process rebuilds unless
  // explicitly forced so API traffic never live-locks on page-fault thrashing.
  if (process.env.BREAKOUT_PULLBACK_AUTO_REFRESH !== '1' && os.totalmem() < MIN_AUTO_REFRESH_MEMORY_BYTES) {
    return;
  }
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
    refreshInFlight = refreshBreakoutPullbackFromCanonical({ factRoot: root, currentDataThrough })
      .catch(err => {
        console.warn('[breakout-pullback] background canonical refresh skipped:', err?.message || 'unknown');
      })
      .finally(() => {
        refreshInFlight = null;
      });
  } catch {
    // Non-blocking best-effort refresh; verified bundled artifact serves immediately.
  }
}

function highestHighAtCutoff(highHistory, entryPrice, cutoffIdx) {
  let hh = entryPrice;
  if (Array.isArray(highHistory)) {
    for (const item of highHistory) {
      if (Array.isArray(item) && item[0] <= cutoffIdx && item[1] > hh) {
        hh = item[1];
      }
    }
  }
  return hh;
}

function sliceYearlyReturns(curve, modeIds = ['flagship', 'balanced', 'spy', 'qqq']) {
  const years = [...new Set(curve.map(r => r.date.slice(0, 4)))].sort();
  return years.map((yr, idxY) => {
    const firstIdx = curve.findIndex(r => r.date.startsWith(`${yr}-`));
    let lastIdx = -1;
    for (let i = curve.length - 1; i >= firstIdx; i--) {
      if (curve[i].date.startsWith(`${yr}-`)) {
        lastIdx = i;
        break;
      }
    }
    const baseIdx = firstIdx > 0 ? firstIdx - 1 : 0;
    const partial =
      (idxY === 0 && curve[0].date > `${yr}-01-05`) ||
      (idxY === years.length - 1 && curve.at(-1).date < `${yr}-12-28`);
    const row = {
      year: Number(yr),
      label: partial ? `${yr}*` : yr,
      partial,
      from: curve[baseIdx].date,
      to: curve[lastIdx].date,
    };
    for (const k of modeIds) {
      const baseVal = firstIdx > 0 ? curve[baseIdx][k] : 1.0;
      row[k] = curve[lastIdx][k] / baseVal - 1.0;
    }
    return row;
  });
}

function reconstructModeStateAtCutoff(modeObj, curve, cutoffIdx) {
  const modeId = modeObj.id;
  const navAtCutoff = curve[cutoffIdx][modeId];
  const cashWeight = curve[cutoffIdx][`${modeId}CashWeight`] ?? 0;
  const openPositions = [];
  const openTickerSet = new Set();
  const trades = [];

  for (const lot of modeObj.lots) {
    if (lot.entryEvalIdx > cutoffIdx) continue;
    const stillOpen = lot.exitEvalIdx === null || lot.exitEvalIdx > cutoffIdx;
    if (stillOpen) {
      const offset = cutoffIdx - lot.entryEvalIdx;
      const markNorm = lot.eodMarksNorm[offset] ?? lot.allocNorm;
      const latestClose = lot.eodCloses[offset] ?? lot.entryPrice;
      const latestAtr = lot.eodAtrs[offset] ?? 0;
      const hh = highestHighAtCutoff(lot.highHistory, lot.entryPrice, cutoffIdx);
      const holdDays = cutoffIdx - lot.entryEvalIdx;
      const unrealizedNetReturn = (markNorm * 0.9995) / lot.allocNorm - 1.0;
      const weight = navAtCutoff > 0 ? markNorm / navAtCutoff : 0;

      const chandelierStopPrice =
        modeObj.parameters.chandelierAtrMultiple && latestAtr > 0
          ? round4(hh - modeObj.parameters.chandelierAtrMultiple * latestAtr)
          : null;
      const effectiveStopPrice =
        chandelierStopPrice !== null && lot.hardStopPrice !== null
          ? Math.max(lot.hardStopPrice, chandelierStopPrice)
          : (chandelierStopPrice ?? lot.hardStopPrice);

      openTickerSet.add(lot.ticker);
      openPositions.push({
        lotId: lot.lotId,
        ticker: lot.ticker,
        name: lot.name,
        isDelisted: lot.isDelisted,
        breakoutDate: lot.breakoutDate,
        breakoutClose: lot.breakoutClose,
        waitDays: lot.waitDays,
        entryDate: lot.entryDate,
        entryPrice: lot.entryPrice,
        latestClose,
        highestHigh: round4(hh),
        latestAtr14: latestAtr,
        weight,
        unrealizedNetReturn,
        holdingDays: holdDays,
        hardStopPrice: lot.hardStopPrice,
        chandelierStopPrice,
        targetPrice: lot.targetPrice,
        effectiveStopPrice: round4(effectiveStopPrice),
        remainingTimeStopDays:
          modeObj.parameters.timeStopDays !== null
            ? Math.max(0, modeObj.parameters.timeStopDays - holdDays)
            : null,
      });

      trades.push({
        lotId: lot.lotId,
        ticker: lot.ticker,
        name: lot.name,
        isDelisted: lot.isDelisted,
        breakoutDate: lot.breakoutDate,
        breakoutClose: lot.breakoutClose,
        dvolRankAtBreakout: lot.dvolRankAtBreakout,
        waitDays: lot.waitDays,
        entryDate: lot.entryDate,
        entryPrice: lot.entryPrice,
        exitDate: curve[cutoffIdx].date,
        exitPrice: latestClose,
        hardStopPrice: lot.hardStopPrice,
        targetPrice: lot.targetPrice,
        holdDays,
        netReturn: unrealizedNetReturn,
        exitReason: 'Open_Position',
        isOpen: true,
      });
    } else {
      trades.push({
        lotId: lot.lotId,
        ticker: lot.ticker,
        name: lot.name,
        isDelisted: lot.isDelisted,
        breakoutDate: lot.breakoutDate,
        breakoutClose: lot.breakoutClose,
        dvolRankAtBreakout: lot.dvolRankAtBreakout,
        waitDays: lot.waitDays,
        entryDate: lot.entryDate,
        entryPrice: lot.entryPrice,
        exitDate: lot.exitDate,
        exitPrice: lot.exitPrice,
        hardStopPrice: lot.hardStopPrice,
        targetPrice: lot.targetPrice,
        holdDays: lot.holdDays,
        netReturn: lot.netReturn,
        exitReason: lot.exitReason,
        isOpen: false,
      });
    }
  }

  openPositions.sort((a, b) => b.weight - a.weight || a.ticker.localeCompare(b.ticker));
  trades.sort((a, b) => b.entryDate.localeCompare(a.entryDate) || b.lotId.localeCompare(a.lotId));

  // Reconstruct active 15-session -5% pullback watchlist at cutoffIdx
  const pendingWatchlist = [];
  for (const ep of modeObj.episodes) {
    if (ep.breakoutEvalIdx > cutoffIdx) continue;
    const elapsed = cutoffIdx - ep.breakoutEvalIdx;
    if (elapsed >= 15) continue;
    if (ep.fillEvalIdx !== null && ep.fillEvalIdx <= cutoffIdx) continue;
    if (openTickerSet.has(ep.ticker)) continue;

    let peakClose = ep.breakoutClose;
    let latestClose = ep.breakoutClose;
    if (Array.isArray(ep.windowCloses)) {
      for (const pair of ep.windowCloses) {
        if (pair[0] <= cutoffIdx) {
          latestClose = pair[1];
          if (pair[1] > peakClose) peakClose = pair[1];
        }
      }
    }
    const limitBuyPrice = round4(peakClose * 0.95);
    const distanceToLimitPct = latestClose > 0 ? limitBuyPrice / latestClose - 1.0 : -0.05;
    const pullbackFromPeakPct = peakClose > 0 ? latestClose / peakClose - 1.0 : 0.0;
    pendingWatchlist.push({
      ticker: ep.ticker,
      name: ep.name,
      breakoutDate: ep.breakoutDate,
      breakoutClose: ep.breakoutClose,
      prev63High: ep.prev63High,
      peakClose: round4(peakClose),
      latestClose: round4(latestClose),
      limitBuyPrice,
      distanceToLimitPct,
      pullbackFromPeakPct,
      elapsedDays: elapsed,
      remainingWatchDays: 15 - elapsed,
      dvolRank: ep.dvolRank,
      dvol20: ep.dvol20,
    });
  }
  pendingWatchlist.sort(
    (a, b) => b.distanceToLimitPct - a.distanceToLimitPct || a.dvolRank - b.dvolRank,
  );

  const rets = trades.map(t => t.netReturn).filter(Number.isFinite);
  const wins = rets.filter(r => r > 0);
  const losses = rets.filter(r => r <= 0);
  const avgWin = wins.length ? sum(wins) / wins.length : null;
  const avgLoss = losses.length ? Math.abs(sum(losses) / losses.length) : null;

  return {
    metrics: withCalmar(strategyMetrics(curve.map(r => ({ date: r.date, value: r[modeId] })))),
    tradeSummary: {
      totalTrades: trades.length,
      closedTrades: trades.length - openPositions.length,
      openTrades: openPositions.length,
      winRate: rets.length ? wins.length / rets.length : null,
      averageWin: avgWin,
      averageLoss: avgLoss,
      payoffRatio: avgWin !== null && avgLoss !== null && avgLoss > 0 ? avgWin / avgLoss : null,
      avgHoldingDays: trades.length ? sum(trades.map(t => t.holdDays ?? 0)) / trades.length : null,
    },
    liveBook: {
      asOfDate: curve[cutoffIdx].date,
      maxSlots: modeObj.parameters.maxPositions,
      usedSlots: openPositions.length,
      freeSlots: Math.max(0, modeObj.parameters.maxPositions - openPositions.length),
      cashWeight,
      investedWeight: Math.max(0, 1 - cashWeight),
      openPositions,
      pendingWatchlist,
    },
    trades,
  };
}

export function loadBreakoutPullbackDashboard({
  file = null,
  asOf = null,
  mode = 'flagship',
  snapshotId = null,
} = {}) {
  if (asOf !== null && !isIsoDate(asOf)) fail('invalid_as_of', 400);
  if (!BREAKOUT_MODES.includes(mode)) fail('invalid_strategy_mode', 400);

  const activeFile = file ?? promotedRuntimeFile ?? defaultFile;
  const entry = readValidatedArtifact(activeFile);
  const { payload, id } = entry;
  if (!file) maybeScheduleBackgroundRefresh(payload.dataThrough);
  if (snapshotId && snapshotId !== id) fail('breakout_pullback_snapshot_changed', 409);

  const cutoff = asOf ?? payload.dataThrough;
  const sliceKey = `${asOf ?? 'latest'}:${cutoff}:${mode}`;
  if (entry.slices.has(sliceKey)) return entry.slices.get(sliceKey);
  const curve = payload.backtest.curve.filter(r => r.date <= cutoff);
  if (curve.length < 2) {
    return {
      version: payload.version,
      status: 'unavailable_before_first_observation',
      snapshotId: id,
      requestedAsOf: asOf,
      dataThrough: curve.at(-1)?.date ?? null,
      inceptionDate: payload.inceptionDate,
      mode,
      modeOrder: payload.modeOrder,
      modesSummary: {},
      yearlyReturns: [],
      empiricalProof: payload.empiricalProof,
      liveBook: {
        asOfDate: null,
        maxSlots: 10,
        usedSlots: 0,
        freeSlots: 10,
        cashWeight: 1,
        investedWeight: 0,
        openPositions: [],
        pendingWatchlist: [],
      },
      trades: [],
      backtest: {
        from: curve[0]?.date ?? null,
        to: curve.at(-1)?.date ?? null,
        observations: curve.length,
        benchmarks: {},
        curve,
      },
    };
  }

  const cutoffIdx = curve.length - 1;
  const modesSummary = {};
  for (const mId of BREAKOUT_MODES) {
    const mDef = payload.modes[mId];
    const mMetrics = withCalmar(strategyMetrics(curve.map(r => ({ date: r.date, value: r[mId] }))));
    modesSummary[mId] = {
      id: mId,
      badge: mDef.badge,
      name: mDef.name,
      subtitle: mDef.subtitle,
      parameters: mDef.parameters,
      blueprint: mDef.blueprint,
      avgExposure: mDef.avgExposure,
      episodeStats: mDef.episodeStats,
      metrics: mMetrics,
    };
  }

  const activeState = reconstructModeStateAtCutoff(payload.modes[mode], curve, cutoffIdx);
  const spyMetrics = withCalmar(strategyMetrics(curve.map(r => ({ date: r.date, value: r.spy }))));
  const qqqMetrics = withCalmar(strategyMetrics(curve.map(r => ({ date: r.date, value: r.qqq }))));

  const response = Object.freeze({
    version: payload.version,
    status: 'ready',
    snapshotId: id,
    requestedAsOf: asOf,
    dataThrough: curve[cutoffIdx].date,
    inceptionDate: payload.inceptionDate,
    lineage: payload.lineage,
    methodology: payload.methodology,
    mode,
    modeOrder: payload.modeOrder,
    modesSummary,
    activeMode: {
      ...modesSummary[mode],
      tradeSummary: activeState.tradeSummary,
    },
    yearlyReturns: sliceYearlyReturns(curve),
    empiricalProof: payload.empiricalProof,
    liveBook: activeState.liveBook,
    trades: activeState.trades,
    backtest: {
      from: curve[0].date,
      to: curve[cutoffIdx].date,
      observations: curve.length,
      benchmarks: {
        spy: { id: 'spy', ticker: 'SPY', priceType: 'total_return_adjusted_close', metrics: spyMetrics },
        qqq: { id: 'qqq', ticker: 'QQQ', priceType: 'total_return_adjusted_close', metrics: qqqMetrics },
      },
      curve,
    },
  });
  if (entry.slices.size >= 32) entry.slices.delete(entry.slices.keys().next().value);
  entry.slices.set(sliceKey, response);
  return response;
}

export function analyzeBreakoutPullbackRange({
  file = null,
  asOf = null,
  mode = 'flagship',
  snapshotId = null,
  start = null,
  end = null,
} = {}) {
  if (asOf !== null && !isIsoDate(asOf)) fail('invalid_as_of', 400);
  if (!BREAKOUT_MODES.includes(mode)) fail('invalid_strategy_mode', 400);
  if (!snapshotId || typeof start !== 'string' || typeof end !== 'string') {
    fail('invalid_analysis_range', 400);
  }

  const activeFile = file ?? promotedRuntimeFile ?? defaultFile;
  const { payload, id } = readValidatedArtifact(activeFile);
  if (snapshotId !== id) fail('breakout_pullback_snapshot_changed', 409);

  const cutoff = asOf ?? payload.dataThrough;
  const curve = payload.backtest.curve.filter(r => r.date <= cutoff);
  const first = curve.findIndex(r => r.date === start);
  const last = curve.findIndex(r => r.date === end);
  if (first < 0 || last <= first) fail('invalid_analysis_range', 400);

  const rows = curve.slice(first, last + 1);
  const origin = first === 0 ? 1.0 : rows[0][mode];
  const metrics = withCalmar(strategyMetrics(rows.map(r => ({ date: r.date, value: r[mode] / origin }))));
  const spyOrigin = first === 0 ? 1.0 : rows[0].spy;
  const qqqOrigin = first === 0 ? 1.0 : rows[0].qqq;
  const spyMetrics = withCalmar(strategyMetrics(rows.map(r => ({ date: r.date, value: r.spy / spyOrigin }))));
  const qqqMetrics = withCalmar(strategyMetrics(rows.map(r => ({ date: r.date, value: r.qqq / qqqOrigin }))));

  const modeObj = payload.modes[mode];
  const dayStart = first === 0 ? 0 : first + 1;

  const stockMap = new Map();
  const ensureStock = lot => {
    if (!stockMap.has(lot.ticker)) {
      stockMap.set(lot.ticker, {
        ticker: lot.ticker,
        name: lot.name,
        isDelisted: lot.isDelisted,
        grossContribution: 0,
        costContribution: 0,
        openAtStart: false,
        openAtEnd: false,
        openingMark: null,
        closingMark: null,
        lots: [],
      });
    }
    return stockMap.get(lot.ticker);
  };

  let buyRatio = 0;
  let sellRatio = 0;
  let buyNotionalNorm = 0;
  let sellNotionalNorm = 0;
  let executions = 0;

  const rangeLotRecords = [];

  for (const lot of modeObj.lots) {
    const eIn = lot.entryEvalIdx;
    const eOut = lot.exitEvalIdx;
    if (eIn > last) continue;
    if (eOut !== null && eOut < first) continue;
    // If a lot exited ON `first` (when `first > 0`), `start` is the post-exit closing mark, so it had zero exposure in (first, last].
    if (first > 0 && eOut === first) continue;

    const stock = ensureStock(lot);
    let lotGross = 0;
    let lotFee = 0;

    if (first > 0 && eIn <= first && (eOut === null || eOut > first)) {
      const openOffset = first - eIn;
      stock.openAtStart = true;
      stock.openingMark = {
        date: start,
        price: lot.eodCloses[openOffset] ?? lot.entryPrice,
        value: (lot.eodMarksNorm[openOffset] ?? lot.allocNorm) / origin,
      };
    }

    if (eIn <= last && (eOut === null || eOut > last)) {
      const closeOffset = last - eIn;
      stock.openAtEnd = true;
      stock.closingMark = {
        date: end,
        price: lot.eodCloses[closeOffset] ?? lot.entryPrice,
        value: (lot.eodMarksNorm[closeOffset] ?? lot.allocNorm) / origin,
      };
    }

    const activeFrom = Math.max(dayStart, eIn);
    const activeTo = eOut !== null ? Math.min(last, eOut) : last;

    for (let d = activeFrom; d <= activeTo; d++) {
      if (eIn === d && eOut === d) {
        const fee = lot.entryFeeNorm + lot.exitFeeNorm;
        const net = lot.proceedsNorm - lot.allocNorm;
        lotFee += fee;
        lotGross += net + fee;
        buyRatio += lot.allocNorm / lot.entryPreNavNorm;
        sellRatio += lot.grossExitNorm / lot.exitPreNavNorm;
        buyNotionalNorm += lot.allocNorm;
        sellNotionalNorm += lot.grossExitNorm;
        executions += 2;
      } else if (eIn === d) {
        const fee = lot.entryFeeNorm;
        const net = lot.eodMarksNorm[0] - lot.allocNorm;
        lotFee += fee;
        lotGross += net + fee;
        buyRatio += lot.allocNorm / lot.entryPreNavNorm;
        buyNotionalNorm += lot.allocNorm;
        executions += 1;
      } else if (eOut !== null && eOut === d) {
        const prevMark = lot.eodMarksNorm[eOut - eIn - 1];
        const fee = lot.exitFeeNorm;
        const net = lot.proceedsNorm - prevMark;
        lotFee += fee;
        lotGross += net + fee;
        sellRatio += lot.grossExitNorm / lot.exitPreNavNorm;
        sellNotionalNorm += lot.grossExitNorm;
        executions += 1;
      } else {
        const offset = d - eIn;
        const net = lot.eodMarksNorm[offset] - lot.eodMarksNorm[offset - 1];
        lotGross += net;
      }
    }

    const lotGrossScaled = lotGross / origin;
    const lotFeeScaled = lotFee / origin;
    const lotNetScaled = lotGrossScaled - lotFeeScaled;
    stock.grossContribution += lotGrossScaled;
    stock.costContribution += lotFeeScaled;

    const exitedInWindow = eOut !== null && eOut <= last;
    const effectiveExitDate = exitedInWindow ? lot.exitDate : end;
    const effectiveExitPrice = exitedInWindow
      ? lot.exitPrice
      : (lot.eodCloses[last - eIn] ?? lot.entryPrice);
    const effectiveHoldDays = (exitedInWindow ? eOut : last) - eIn;
    const effectiveLotReturn = exitedInWindow
      ? lot.netReturn
      : ((lot.eodMarksNorm[last - eIn] * 0.9995) / lot.allocNorm - 1.0);
    const effectiveReason = exitedInWindow ? lot.exitReason : 'Open_Position';

    const lotSummary = {
      lotId: lot.lotId,
      ticker: lot.ticker,
      name: lot.name,
      breakoutDate: lot.breakoutDate,
      breakoutClose: lot.breakoutClose,
      entryDate: lot.entryDate,
      entryPrice: lot.entryPrice,
      beforeRange: first > 0 && eIn <= first,
      exitDate: effectiveExitDate,
      exitPrice: effectiveExitPrice,
      openAtEnd: !exitedInWindow,
      holdDays: effectiveHoldDays,
      lotNetReturn: effectiveLotReturn,
      rangeNetContribution: lotNetScaled,
      exitReason: effectiveReason,
    };
    stock.lots.push(lotSummary);
    rangeLotRecords.push(lotSummary);
  }

  const holdings = [...stockMap.values()]
    .map(s => {
      const purchases = s.lots.map(l => ({
        date: l.entryDate,
        price: l.entryPrice,
        beforeRange: l.beforeRange,
      }));
      const sales = s.lots
        .filter(l => !l.openAtEnd)
        .map(l => ({
          date: l.exitDate,
          price: l.exitPrice,
          exitReason: l.exitReason,
        }));
      return {
        ...s,
        netContribution: s.grossContribution - s.costContribution,
        purchases,
        sales,
      };
    })
    .sort((a, b) => b.netContribution - a.netContribution || a.ticker.localeCompare(b.ticker));

  const totalNet = sum(holdings.map(h => h.netContribution));
  const totalGross = sum(holdings.map(h => h.grossContribution));
  const totalCosts = sum(holdings.map(h => h.costContribution));
  if (!near(totalNet, metrics.totalReturn, 1e-7)) {
    fail('breakout_analysis_attribution_mismatch');
  }

  const winners = holdings.filter(h => h.netContribution > 1e-12);
  const losers = holdings.filter(h => h.netContribution < -1e-12);
  const averageWin = winners.length ? sum(winners.map(h => h.netContribution)) / winners.length : null;
  const averageLoss = losers.length ? -sum(losers.map(h => h.netContribution)) / losers.length : null;

  // Lot-level trade stats inside the selected range
  const lotWins = rangeLotRecords.filter(l => l.rangeNetContribution > 1e-12);
  const lotLosses = rangeLotRecords.filter(l => l.rangeNetContribution < -1e-12);
  const lotAvgWin = lotWins.length ? sum(lotWins.map(l => l.rangeNetContribution)) / lotWins.length : null;
  const lotAvgLoss = lotLosses.length ? -sum(lotLosses.map(l => l.rangeNetContribution)) / lotLosses.length : null;
  const closedInWindow = rangeLotRecords.filter(l => !l.openAtEnd);
  const hardStops = closedInWindow.filter(l => l.exitReason === 'Hard_StopLoss').length;
  const profitExits = closedInWindow.filter(l =>
    ['Trailing_TakeProfit', 'Target_TakeProfit'].includes(l.exitReason),
  ).length;

  const bounds = [-Infinity, -0.1, -0.05, -0.01, -1e-12, 1e-12, 0.01, 0.05, 0.1, Infinity];
  const distribution = bounds.slice(0, -1).map((lower, i) => ({
    lower: Number.isFinite(lower) ? lower : null,
    upper: Number.isFinite(bounds[i + 1]) ? bounds[i + 1] : null,
    count: holdings.filter(r => r.netContribution >= lower && r.netContribution < bounds[i + 1]).length,
  }));

  const oneWay = (buyRatio + sellRatio) / 2;
  const returnIntervals = rows.length - 1;
  const turnover = {
    version: 'breakout-range-turnover-v1',
    basis: 'half_gross_notional_over_each_pretrade_nav',
    oneWay,
    twoWay: buyRatio + sellRatio,
    buyRatio,
    sellRatio,
    annualizedOneWay: returnIntervals > 0 ? (oneWay * 252) / returnIntervals : 0,
    annualizationSessions: 252,
    returnIntervals,
    buyNotional: buyNotionalNorm / origin,
    sellNotional: sellNotionalNorm / origin,
    executions,
    includesInitialEntry: first === 0,
  };

  return {
    version: BREAKOUT_ANALYSIS_VERSION,
    snapshotId: id,
    mode,
    start,
    end,
    observations: rows.length,
    illustrativeCapital: 100000,
    currency: 'USD',
    metrics,
    benchmarks: {
      spy: spyMetrics,
      qqq: qqqMetrics,
    },
    turnover,
    tradeStats: {
      population: 'unique_stock_range_pnl_including_open',
      stocks: holdings.length,
      wins: winners.length,
      losses: losers.length,
      flat: holdings.length - winners.length - losers.length,
      open: holdings.filter(h => h.openAtEnd).length,
      winRate: winners.length + losers.length ? winners.length / (winners.length + losers.length) : null,
      averageWin,
      averageLoss,
      payoffRatio: averageWin !== null && averageLoss !== null && averageLoss > 0 ? averageWin / averageLoss : null,
      payoffStatus: !winners.length ? 'no_winners' : !losers.length ? 'no_losers' : 'available',
      lotCount: rangeLotRecords.length,
      closedLotCount: closedInWindow.length,
      lotWins: lotWins.length,
      lotLosses: lotLosses.length,
      lotWinRate:
        lotWins.length + lotLosses.length
          ? lotWins.length / (lotWins.length + lotLosses.length)
          : null,
      lotPayoffRatio:
        lotAvgWin !== null && lotAvgLoss !== null && lotAvgLoss > 0 ? lotAvgWin / lotAvgLoss : null,
      avgHoldingDays: rangeLotRecords.length
        ? sum(rangeLotRecords.map(l => l.holdDays)) / rangeLotRecords.length
        : null,
      hardStopCount: hardStops,
      profitExitCount: profitExits,
      stopLossExitShare: closedInWindow.length ? hardStops / closedInWindow.length : null,
      profitExitShare: closedInWindow.length ? profitExits / closedInWindow.length : null,
    },
    distribution,
    best: winners[0] ?? null,
    worst: losers.at(-1) ?? null,
    topWinners: winners.slice(0, 3),
    topLosers: [...losers].reverse().slice(0, 3),
    holdings,
    trades: [...rangeLotRecords].sort((a, b) => b.rangeNetContribution - a.rangeNetContribution),
    reconciliation: {
      stockPnl: totalNet,
      grossPnl: totalGross,
      costs: totalCosts,
      portfolioReturn: metrics.totalReturn,
      difference: totalNet - metrics.totalReturn,
    },
    lineage: {
      portfolioSnapshotId: id,
      sourceSnapshotGeneration: payload.lineage?.sourceGeneration ?? null,
      allDailyNavReconciled: true,
      method: BREAKOUT_ANALYSIS_VERSION,
    },
  };
}
