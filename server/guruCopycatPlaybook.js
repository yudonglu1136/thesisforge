import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const GURU_COPYCAT_PLAYBOOK_VERSION = 'guru-copycat-playbook-v1';
export const GURU_COPYCAT_SCHEME_IDS = Object.freeze([
  'barbell_70_30',
  'monopoly_compounders',
  'pre2014_legends',
  'new_adds_catalyst',
  'hf4_smart_flow',
]);

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultFile = path.resolve(projectRoot, 'server/config/guru-copycat-playbook-dashboard.json');

let cachedArtifact = null;

function fail(code, status = 503) {
  throw Object.assign(new Error(code), { status });
}

const isIsoDate = value =>
  /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') &&
  Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;

const r2 = v => (Number.isFinite(v) ? Math.round(v * 100) / 100 : null);

function readArtifact(file = defaultFile) {
  const resolved = path.resolve(file);
  let stat;
  try {
    stat = fs.statSync(resolved);
  } catch {
    fail('guru_copycat_playbook_unavailable', 503);
  }
  const cacheKey = `${resolved}:${stat.mtimeMs}:${stat.size}`;
  if (cachedArtifact?.key === cacheKey) return cachedArtifact;

  let raw;
  let parsed;
  try {
    raw = fs.readFileSync(resolved, 'utf8');
    parsed = JSON.parse(raw);
  } catch {
    fail('guru_copycat_playbook_corrupt', 503);
  }
  if (parsed?.version !== GURU_COPYCAT_PLAYBOOK_VERSION || !Array.isArray(parsed?.schemes)) {
    fail('guru_copycat_playbook_version_mismatch', 503);
  }
  const snapshotId = createHash('sha256').update(raw).digest('hex').slice(0, 16);
  cachedArtifact = { key: cacheKey, snapshotId, data: parsed };
  return cachedArtifact;
}

function normalizeQuarterKey(rawQuarter, availableSnapshots) {
  if (!availableSnapshots.length) return null;
  if (!rawQuarter) return availableSnapshots[availableSnapshots.length - 1].quarterDate;
  const q = String(rawQuarter).trim();
  const direct = availableSnapshots.find(
    s =>
      s.quarterDate === q ||
      s.quarter.toLowerCase() === q.toLowerCase() ||
      s.quarter.replace(/\s+/g, '').toLowerCase() === q.replace(/\s+/g, '').toLowerCase(),
  );
  return direct ? direct.quarterDate : availableSnapshots[availableSnapshots.length - 1].quarterDate;
}

function lookupFreshQuotes(source, asOf, latestPriceDate, tickers) {
  if (!source?.db || typeof source.db.prepare !== 'function' || asOf < latestPriceDate || !tickers.length) {
    return new Map();
  }
  try {
    const unique = [...new Set(tickers.filter(Boolean))];
    if (!unique.length) return new Map();
    const placeholders = unique.map(() => '?').join(',');
    const rows = source.db
      .prepare(
        `SELECT ticker, price, as_of_date
         FROM investment_current_quotes
         WHERE ticker IN (${placeholders})
           AND price > 0
           AND substr(as_of_date, 1, 10) <= ?`,
      )
      .all(...unique, asOf);
    const out = new Map();
    for (const row of rows) {
      const dt = String(row.as_of_date ?? '').slice(0, 10);
      if (dt >= latestPriceDate && Number.isFinite(Number(row.price)) && Number(row.price) > 0) {
        out.set(String(row.ticker), { price: Number(row.price), date: dt });
      }
    }
    return out;
  } catch {
    return new Map();
  }
}

function applyQuoteOverlay(row, quoteMap, costKey = 'estGuruCost', priceKey = 'latestPrice', vsKey = 'vsGuruCostPct') {
  const tk = row?.ticker;
  const q = tk ? quoteMap.get(tk) : null;
  if (!q) return row;
  const cost = Number(row[costKey]);
  const nextVs = Number.isFinite(cost) && cost > 0 ? r2((q.price / cost - 1) * 100) : row[vsKey];
  return {
    ...row,
    [priceKey]: r2(q.price),
    ...(vsKey ? { [vsKey]: nextVs } : {}),
  };
}

function maskSnapshotForCutoff(snap, asOf, quoteMap) {
  const exitIso = /^\d{4}-\d{2}-\d{2}$/.test(String(snap.exitDate ?? '').slice(0, 10))
    ? String(snap.exitDate).slice(0, 10)
    : null;
  const exitRealized = Boolean(exitIso && exitIso <= asOf && !snap.isLive);
  const holdings = (snap.holdings ?? []).map(h => {
    const overlaid = snap.quarterDate === '2026-09-30' ? applyQuoteOverlay(h, quoteMap) : h;
    if (exitRealized) return overlaid;
    return {
      ...overlaid,
      exitPrice: null,
      realizedRetPct: null,
      contribBps: null,
    };
  });
  return {
    ...snap,
    isLive: !exitRealized,
    portRetPct: exitRealized ? snap.portRetPct : null,
    spyRetPct: exitRealized ? snap.spyRetPct : null,
    qqqRetPct: exitRealized ? snap.qqqRetPct : null,
    excessSpyPct: exitRealized ? snap.excessSpyPct : null,
    beatSpy: exitRealized ? snap.beatSpy : null,
    holdings,
  };
}

function toCompactTimelineEntry(snap) {
  const { holdings, ...meta } = snap;
  return {
    ...meta,
    holdingsCount: Array.isArray(holdings) ? holdings.length : 0,
  };
}

function buildSlicedDailyCurve(dailyCurves, seriesKey, cutoff) {
  const dates = Array.isArray(dailyCurves?.dates) ? dailyCurves.dates : [];
  const series = dailyCurves?.series ?? {};
  const schemeRaw = Array.isArray(series[seriesKey]) ? series[seriesKey] : [];
  const spyRaw = Array.isArray(series.SPY) ? series.SPY : [];
  const qqqRaw = Array.isArray(series.QQQ) ? series.QQQ : [];
  const n = Math.min(dates.length, schemeRaw.length, spyRaw.length, qqqRaw.length);
  if (n < 2) return null;

  // Binary search for last index with dates[idx] <= cutoff (strict PIT)
  let lo = 0;
  let hi = n - 1;
  let endIdx = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (String(dates[mid]) <= cutoff) {
      endIdx = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (endIdx < 1) return null;

  const end = endIdx + 1;
  const slicedDates = dates.slice(0, end);
  return {
    startDate: slicedDates[0],
    endDate: slicedDates[slicedDates.length - 1],
    tradingDays: slicedDates.length,
    dates: slicedDates,
    schemeNav: schemeRaw.slice(0, end),
    spyNav: spyRaw.slice(0, end),
    qqqNav: qqqRaw.slice(0, end),
  };
}

export function loadGuruCopycatPlaybookDashboard({
  asOf,
  scheme = null,
  weightMode = 'conviction',
  quarter = null,
  source = null,
  file = defaultFile,
} = {}) {
  const cutoff = isIsoDate(asOf) ? asOf : new Date().toISOString().slice(0, 10);
  const { snapshotId, data } = readArtifact(file);

  const schemeId = GURU_COPYCAT_SCHEME_IDS.includes(scheme)
    ? scheme
    : data.defaultSchemeId || 'barbell_70_30';
  const normalizedWeightMode = weightMode === 'equal' ? 'equal' : 'conviction';

  const rawSnaps = data.snapshotsByScheme?.[schemeId] ?? [];
  const visibleRawSnaps = rawSnaps.filter(s => String(s.filedAt ?? '') <= cutoff);
  if (!visibleRawSnaps.length) {
    return {
      version: GURU_COPYCAT_PLAYBOOK_VERSION,
      snapshotId,
      asOf: cutoff,
      status: 'pre_history',
      selectedSchemeId: schemeId,
      weightMode: normalizedWeightMode,
      dailyCurve: null,
      schemes: [],
      snapshotTimeline: [],
      activeSnapshot: null,
      latestBlotterSnapshot: null,
      masterBlueprint16: [],
      guruExitsAndSlashes: [],
      q1HfDumpRadar: [],
      guruRoster: [],
      positionCountSensitivity: [],
      antiPatterns: [],
    };
  }

  const isLatestWindowVisible = cutoff >= String(data.latestFiledDate || '2026-11-16');

  // Collect live tickers for optional quote refresh
  const liveTickers = [];
  if (isLatestWindowVisible && source) {
    for (const r of data.masterBlueprint16 ?? []) liveTickers.push(r.ticker);
    for (const r of data.q1HfDumpRadar ?? []) liveTickers.push(r.ticker);
    for (const r of data.guruExitsAndSlashes ?? []) liveTickers.push(r.ticker);
    for (const g of data.guruRoster ?? []) {
      for (const h of g.top12Holdings ?? []) liveTickers.push(h.ticker);
    }
    const lastSnap = visibleRawSnaps[visibleRawSnaps.length - 1];
    for (const h of lastSnap?.holdings ?? []) liveTickers.push(h.ticker);
  }
  const quoteMap = lookupFreshQuotes(source, cutoff, String(data.latestPriceDate || '2026-11-18'), liveTickers);

  const maskedSnaps = visibleRawSnaps.map(s => maskSnapshotForCutoff(s, cutoff, quoteMap));
  const targetQuarterDate = normalizeQuarterKey(quarter, maskedSnaps);
  const activeSnapshot =
    maskedSnaps.find(s => s.quarterDate === targetQuarterDate) ?? maskedSnaps[maskedSnaps.length - 1];
  const latestBlotterSnapshot = maskedSnaps[maskedSnaps.length - 1];

  // Slice curves by PIT cutoff so historical replay never shows future T+45 bars
  const maxRealizedQd = [...maskedSnaps]
    .reverse()
    .find(s => !s.isLive && s.portRetPct !== null)?.quarterDate ?? '2014-03-31';

  const sliceMetrics = m => {
    if (!m) return null;
    if (cutoff >= '2026-08-18') return m;
    return {
      ...m,
      curve: (m.curve ?? []).filter(pt => pt.quarterDate <= maxRealizedQd),
      annualReturns: (m.annualReturns ?? []).filter(yr => yr.year <= cutoff.slice(0, 4)),
    };
  };

  const schemes = (data.schemes ?? []).map(sc => {
    const useEq = sc.id === 'monopoly_compounders' && normalizedWeightMode === 'equal' && sc.equalWeightVariant;
    return {
      ...sc,
      activeWeightMode: sc.id === 'monopoly_compounders' ? normalizedWeightMode : 'default',
      metrics: sliceMetrics(useEq ? sc.equalWeightVariant : sc.metrics),
      convictionVariant: sc.id === 'monopoly_compounders' ? sliceMetrics(sc.metrics) : undefined,
      equalWeightVariant: sc.equalWeightVariant ? sliceMetrics(sc.equalWeightVariant) : undefined,
    };
  });

  const masterBlueprint16 = isLatestWindowVisible
    ? (data.masterBlueprint16 ?? []).map(r => applyQuoteOverlay(r, quoteMap))
    : [];
  const guruExitsAndSlashes = isLatestWindowVisible
    ? (data.guruExitsAndSlashes ?? []).map(r =>
        applyQuoteOverlay(r, quoteMap, 'q3AvgPrice', 'latestPrice', 'vsQ3CostPct'),
      )
    : [];
  const q1HfDumpRadar = isLatestWindowVisible
    ? (data.q1HfDumpRadar ?? []).map(r =>
        applyQuoteOverlay(r, quoteMap, 'q3AvgPrice', 'latestPrice', 'postQ3ReturnPct'),
      )
    : [];
  const guruRoster = isLatestWindowVisible
    ? (data.guruRoster ?? []).map(g => ({
        ...g,
        top12Holdings: (g.top12Holdings ?? []).map(h => applyQuoteOverlay(h, quoteMap)),
      }))
    : (data.guruRoster ?? []).map(g => ({
        ...g,
        latestQuarter: latestBlotterSnapshot.quarter,
        latestQuarterDate: latestBlotterSnapshot.quarterDate,
        filedAt: latestBlotterSnapshot.filedAt,
        top12Holdings: [],
      }));

  const dailySeriesKey =
    schemeId === 'monopoly_compounders' && normalizedWeightMode === 'equal'
      ? 'monopoly_compounders_equal'
      : schemeId;
  const dailyCurve = buildSlicedDailyCurve(data.dailyCurves, dailySeriesKey, cutoff);

  return {
    version: GURU_COPYCAT_PLAYBOOK_VERSION,
    snapshotId,
    generatedAt: data.generatedAt,
    factGeneration: data.factGeneration,
    asOf: cutoff,
    latestQuarter: latestBlotterSnapshot.quarter,
    latestQuarterDate: latestBlotterSnapshot.quarterDate,
    latestFiledDate: latestBlotterSnapshot.filedAt,
    latestPriceDate: data.latestPriceDate,
    selectedSchemeId: schemeId,
    weightMode: normalizedWeightMode,
    selectedQuarterDate: activeSnapshot.quarterDate,
    rebalanceSchedule: data.rebalanceSchedule,
    backtestWindow: data.backtestWindow,
    benchmarks: {
      SPY: sliceMetrics(data.benchmarks?.SPY),
      QQQ: sliceMetrics(data.benchmarks?.QQQ),
    },
    dailyCurve,
    schemes,
    positionCountSensitivity: data.positionCountSensitivity ?? [],
    antiPatterns: data.antiPatterns ?? [],
    latestBlotterSnapshot,
    masterBlueprint16,
    guruExitsAndSlashes,
    q1HfDumpRadar,
    guruRoster,
    snapshotTimeline: maskedSnaps.map(toCompactTimelineEntry),
    activeSnapshot,
  };
}

export function loadGuruCopycatPlaybookSnapshot({
  asOf,
  scheme = null,
  quarter = null,
  source = null,
  file = defaultFile,
} = {}) {
  const cutoff = isIsoDate(asOf) ? asOf : new Date().toISOString().slice(0, 10);
  const { snapshotId, data } = readArtifact(file);
  const schemeId = GURU_COPYCAT_SCHEME_IDS.includes(scheme)
    ? scheme
    : data.defaultSchemeId || 'barbell_70_30';
  const rawSnaps = (data.snapshotsByScheme?.[schemeId] ?? []).filter(
    s => String(s.filedAt ?? '') <= cutoff,
  );
  if (!rawSnaps.length) fail('guru_copycat_snapshot_not_found', 404);
  const targetQuarterDate = normalizeQuarterKey(quarter, rawSnaps);
  const found = rawSnaps.find(s => s.quarterDate === targetQuarterDate) ?? rawSnaps[rawSnaps.length - 1];
  const quoteMap =
    found.quarterDate === '2026-09-30' && source
      ? lookupFreshQuotes(
          source,
          cutoff,
          String(data.latestPriceDate || '2026-11-18'),
          (found.holdings ?? []).map(h => h.ticker),
        )
      : new Map();
  return {
    version: GURU_COPYCAT_PLAYBOOK_VERSION,
    snapshotId,
    asOf: cutoff,
    schemeId,
    snapshot: maskSnapshotForCutoff(found, cutoff, quoteMap),
  };
}
