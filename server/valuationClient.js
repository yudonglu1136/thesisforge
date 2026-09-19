import {
  databaseInfo,
  readValuationDashboardVersion,
  readValuationPodcastInsights,
  readValuationPodcastInsightsVersion,
  readValuationPodcastInsightSummary,
  readValuationSnapshot,
  readValuationTickerSnapshot,
  readValuationTickerSnapshotVersion
} from "./localDatabase.js";
import { applyAznValuationOverlay } from "./aznValuationOverlay.js";
import { applyLsegValuationOverlay } from "./lsegValuationOverlay.js";
import { factOsEnabled } from "./factRepository.js";
import {
  factGeneration,
  loadCanonicalValuationDashboard,
  loadCanonicalValuationDetail
} from "./valuationFacts.js";
import { normalizeTicker, valuationLookupKeysForSnapshot, valuationTickerCandidates } from "./tickerAliases.js";
import { ValuationNotCoveredError } from "./valuationHttp.js";

const dashboardCache = {
  version: null,
  payload: null
};
const tickerCache = new Map();
const tickerCacheMaxEntries = Math.max(
  1,
  Math.min(1024, Math.round(Number(process.env.VALUATION_TICKER_CACHE_MAX_ENTRIES) || 12))
);
const tickerCacheMaxBytes = Math.max(
  4 * 1024 * 1024,
  Math.min(
    128 * 1024 * 1024,
    Math.round(Number(process.env.VALUATION_TICKER_CACHE_MAX_BYTES) || 24 * 1024 * 1024)
  )
);
let tickerCacheBytes = 0;

function normalizePricePoints(value) {
  return Math.max(120, Math.min(5000, Math.round(Number(value) || 900)));
}

function readTickerCache(key, version) {
  const cached = tickerCache.get(key);
  if (!cached || cached.version !== version) {
    if (cached) removeTickerCacheEntry(key);
    return null;
  }
  tickerCache.delete(key);
  tickerCache.set(key, cached);
  return cached.payload;
}

function removeTickerCacheEntry(key) {
  const cached = tickerCache.get(key);
  if (!cached) return;
  tickerCacheBytes -= cached.bytes;
  tickerCache.delete(key);
}

function writeTickerCache(key, version, payload) {
  removeTickerCacheEntry(key);
  const bytes = Buffer.byteLength(JSON.stringify(payload));
  tickerCache.set(key, { version, payload, bytes });
  tickerCacheBytes += bytes;
  while (
    tickerCache.size > tickerCacheMaxEntries ||
    tickerCacheBytes > tickerCacheMaxBytes
  ) {
    removeTickerCacheEntry(tickerCache.keys().next().value);
  }
}

export function valuationTickerCacheStats() {
  return {
    entries: tickerCache.size,
    bytes: tickerCacheBytes,
    maxEntries: tickerCacheMaxEntries,
    maxBytes: tickerCacheMaxBytes
  };
}

function valuationDashboardVersion() {
  return readValuationDashboardVersion();
}

function sortTickers(tickers) {
  return [...(tickers || [])].sort((left, right) => {
    const leftUpside = Number(left.latest?.upsideToBase);
    const rightUpside = Number(right.latest?.upsideToBase);
    if (Number.isFinite(leftUpside) && Number.isFinite(rightUpside)) return rightUpside - leftUpside;
    return String(left.ticker || "").localeCompare(String(right.ticker || ""));
  });
}

function emptyPayload() {
  return {
    generatedAt: new Date().toISOString(),
    source: {
      label: "Local SQLite valuation database",
      localDatabase: databaseInfo().path,
      upstreamLabel: "Legacy fundamental-analysis stock modules"
    },
    summary: {
      tickerCount: 0,
      historyRows: 0,
      pricePointCount: 0,
      latestPriceDate: null,
      auditLayerCounts: emptyAuditLayerCounts(),
      message: "No valuation snapshot is available yet."
    },
    tickers: []
  };
}

const auditLayerNames = [
  "lineage",
  "release",
  "economicValidation",
  "marketCalibration"
];

function normalizedAuditStatus(value, fallback) {
  const status = String(value || "").trim().toLowerCase();
  return [
    "pass",
    "review",
    "fail",
    "verified",
    "not_verified",
    "not_validated",
    "guardrail_only",
    "not_run"
  ].includes(status) ? status : fallback;
}

/**
 * Keep the four different meanings of "audit" separate. A lineage pass proves
 * input provenance and declared price-exclusion policy; it does not prove that
 * the economic model predicts returns or is calibrated to the market.
 */
export function valuationAuditLayers(dataQuality = {}) {
  const explicitLayers = dataQuality.auditLayers || {};
  const inputAudit = dataQuality.modelInputAudit || {};
  const releaseAudit = dataQuality.pitReleaseAudit || dataQuality.releaseAudit ||
    explicitLayers.release || {};
  const economicValidation = dataQuality.economicValidation ||
    explicitLayers.economicValidation || {};
  const marketCalibration = dataQuality.marketCalibration ||
    explicitLayers.marketCalibration || {};
  const unifiedAudit = dataQuality.unifiedValuationAudit || {};
  const consensusCheck = unifiedAudit.externalConsensusCheck || {};
  const evidenceRows = Number(
    inputAudit.financialOrGuidanceEvidenceRows ?? inputAudit.valuationRows ?? 0
  );
  const releaseStatus = normalizedAuditStatus(
    releaseAudit.status === "pass" ? "verified" : releaseAudit.status,
    "not_verified"
  );
  const economicStatus = normalizedAuditStatus(
    economicValidation.status,
    "not_validated"
  );
  const explicitCalibrationStatus = normalizedAuditStatus(
    marketCalibration.status,
    ""
  );
  const marketStatus = explicitCalibrationStatus ||
    (consensusCheck.status ? "guardrail_only" : "not_run");

  return {
    lineage: {
      status: normalizedAuditStatus(
        explicitLayers.lineage?.status || inputAudit.status,
        "not_run"
      ),
      scope: "point-in-time input lineage and arithmetic policy",
      evidenceRows: Number.isFinite(evidenceRows) ? evidenceRows : 0,
      sourceGrade: inputAudit.sourceGrade || explicitLayers.lineage?.sourceGrade || null,
      declaredPriceUse: inputAudit.passesNoPriceAnchorAudit === true
        ? "comparison-only"
        : "unverified",
      priceAnchorSignals: Number(inputAudit.methodPriceAnchorSignalCount || 0)
    },
    release: {
      status: releaseStatus,
      scope: "strict reproducible release verification",
      releaseId: releaseAudit.releaseId || null,
      modelSignature: releaseAudit.modelSignature || null,
      snapshotSignature: releaseAudit.snapshotSignature || null
    },
    economicValidation: {
      status: economicStatus,
      scope: "walk-forward forecast error and forward-return validation",
      sampleSize: Number(economicValidation.sampleSize || 0),
      asOf: economicValidation.asOf || null
    },
    marketCalibration: {
      status: marketStatus,
      scope: marketStatus === "guardrail_only"
        ? "external consensus comparison guardrail only"
        : "out-of-sample market calibration",
      sampleSize: Number(marketCalibration.sampleSize || 0),
      asOf: marketCalibration.asOf || null,
      guardrailStatus: consensusCheck.status || null
    }
  };
}

function withValuationAuditLayers(ticker = {}) {
  return {
    ...ticker,
    dataQuality: {
      ...(ticker.dataQuality || {}),
      auditLayers: valuationAuditLayers(ticker.dataQuality || {})
    }
  };
}

function emptyAuditLayerCounts() {
  return Object.fromEntries(
    auditLayerNames.map((name) => [name, {
      pass: 0,
      review: 0,
      fail: 0,
      guardrailOnly: 0,
      unavailable: 0
    }])
  );
}

export function summarizeValuationAuditLayers(tickers = []) {
  const counts = emptyAuditLayerCounts();
  for (const ticker of tickers) {
    const layers = ticker?.dataQuality?.auditLayers || {};
    for (const name of auditLayerNames) {
      const status = String(layers[name]?.status || "").toLowerCase();
      const bucket = ["pass", "verified"].includes(status)
        ? "pass"
        : status === "review"
          ? "review"
          : status === "fail"
            ? "fail"
            : status === "guardrail_only"
              ? "guardrailOnly"
            : "unavailable";
      counts[name][bucket] += 1;
    }
  }
  return counts;
}

function compactDataQuality(dataQuality = {}) {
  const inputAudit = dataQuality.modelInputAudit || {};
  const unifiedAudit = dataQuality.unifiedValuationAudit || {};
  const consensus = unifiedAudit.externalConsensus || {};
  const consensusCheck = unifiedAudit.externalConsensusCheck || {};
  return {
    valuationCoverageKind: dataQuality.valuationCoverageKind,
    currentOnly: dataQuality.currentOnly,
    historicalCurveAuthorized: dataQuality.historicalCurveAuthorized,
    releaseReady: dataQuality.releaseReady,
    coverageKind: dataQuality.coverageKind,
    pricePoints: dataQuality.pricePoints,
    hasLivePriceSeries: dataQuality.hasLivePriceSeries,
    fairValueSource: dataQuality.fairValueSource,
    auditLayers: dataQuality.auditLayers || valuationAuditLayers(dataQuality),
    modelInputAudit: {
      status: inputAudit.status,
      valuationRows: inputAudit.valuationRows,
      sourceGrade: inputAudit.sourceGrade,
      passesNoPriceAnchorAudit: inputAudit.passesNoPriceAnchorAudit
    },
    unifiedValuationAudit: {
      status: unifiedAudit.status,
      externalConsensus: {
        currency: consensus.currency,
        currentPrice: consensus.currentPrice,
        impliedUpside: consensus.impliedUpside,
        targetPrice: consensus.targetPrice,
        source: consensus.source
      },
      externalConsensusCheck: {
        status: consensusCheck.status,
        message: consensusCheck.message
      }
    }
  };
}

function compactTickerForDashboard(ticker = {}) {
  return {
    generatedAt: ticker.generatedAt,
    ticker: ticker.ticker,
    key: ticker.key,
    name: ticker.name,
    companyName: ticker.companyName,
    sector: ticker.sector,
    currency: ticker.currency,
    description: ticker.description,
    modelType: ticker.modelType,
    latest: ticker.latest,
    scenarios: Array.isArray(ticker.scenarios) ? ticker.scenarios.slice(0, 3) : [],
    dataQuality: compactDataQuality(ticker.dataQuality || {}),
    order: ticker.order
  };
}

function sampleSeries(rows, maxPoints) {
  if (!Array.isArray(rows)) return [];
  const limit = Number(maxPoints);
  if (!Number.isFinite(limit) || limit <= 0 || rows.length <= limit) return rows;
  if (limit <= 2) return [rows[0], rows.at(-1)].filter(Boolean);
  const result = [];
  const step = (rows.length - 1) / (limit - 1);
  let previousIndex = -1;
  for (let point = 0; point < limit; point += 1) {
    const index = Math.min(rows.length - 1, Math.round(point * step));
    if (index !== previousIndex) {
      result.push(rows[index]);
      previousIndex = index;
    }
  }
  return result;
}

export function valuationDetailLevel(value) {
  return String(value || "").trim().toLowerCase() === "summary" ? "summary" : "full";
}

function compactSummaryHistoryRow(row = {}) {
  const semantics = row.dataSnapshot?.valuationSemantics || {};
  const scoreInputs = semantics.scoreInputs || {};
  return {
    periodId: row.periodId,
    label: row.label,
    asOfDate: row.asOfDate,
    fiscalYear: row.fiscalYear,
    fiscalQuarter: row.fiscalQuarter,
    currentPrice: row.currentPrice,
    fairValue: row.fairValue,
    upsideDownside: row.upsideDownside,
    targetPrice3Y: row.targetPrice3Y,
    expectedReturn3Y: row.expectedReturn3Y,
    priceDate: row.priceDate,
    priceAtDate: row.priceAtDate,
    dataSnapshot: {
      valuationSemantics: {
        scoreInputs: {
          revenueGuidanceM: scoreInputs.revenueGuidanceM,
          valuationRevenue: scoreInputs.valuationRevenue,
          fcfGuidanceM: scoreInputs.fcfGuidanceM,
          valuationFreeCashFlow: scoreInputs.valuationFreeCashFlow,
          ttmFreeCashFlow: scoreInputs.ttmFreeCashFlow
        }
      }
    }
  };
}

function compactTickerSummary(ticker = {}) {
  const dataQuality = ticker.dataQuality || {};
  return {
    generatedAt: ticker.generatedAt,
    ticker: ticker.ticker,
    key: ticker.key,
    name: ticker.name,
    companyName: ticker.companyName,
    sector: ticker.sector,
    currency: ticker.currency,
    description: ticker.description,
    modelType: ticker.modelType,
    latest: ticker.latest,
    priceHistory: ticker.priceHistory || [],
    history: (ticker.history || []).map(compactSummaryHistoryRow),
    ...compactCurrentScenario(ticker),
    dataQuality: {
      ...compactDataQuality(dataQuality),
      pricePointsAvailable: dataQuality.pricePointsAvailable,
      pricePointsReturned: dataQuality.pricePointsReturned,
      priceHistorySampling: dataQuality.priceHistorySampling
    }
  };
}

function compactCurrentScenario(ticker) {
  if (ticker.dataQuality?.currentOnly !== true && ticker.dataQuality?.valuationCoverageKind !== "current_only") return {};
  const details = ticker.currentScenarioDetails || {};
  const assumptions = details.analystAssumptions || {};
  return {
    // These are essential truth-state disclosures, not full research detail.
    // The summary route must not turn a current-only model into a blank card
    // or strip the warning that no historical valuation curve is approved.
    scenarios: (ticker.scenarios || []).slice(0, 3).map((row) => ({
      scenarioId: row.scenarioId, scenario: row.scenario, fairValue: row.fairValue,
      currentPrice: row.currentPrice, upsideDownside: row.upsideDownside,
      status: row.status, statisticalConfidenceInterval: row.statisticalConfidenceInterval,
      fundingDeficitMxnM: row.fundingDeficitMxnM
    })),
    currentScenarioDetails: {
      currentOnly: true, historicalCurveAuthorized: details.historicalCurveAuthorized,
      financialDate: details.financialDate,
      analystAssumptions: { keMxn: assumptions.keMxn, terminalPerCurrentClaimGrowth: assumptions.terminalPerCurrentClaimGrowth },
      fx: { mxnPerUsd: details.fx?.mxnPerUsd }
    },
    warningTranslations: (ticker.warningTranslations || []).map(({ en, zh }) => ({ en, zh }))
  };
}

export function compactTickerDetail(ticker, { pricePoints = 900, detail = "full" } = {}) {
  const maxPricePoints = normalizePricePoints(pricePoints);
  const priceHistory = Array.isArray(ticker?.priceHistory) ? ticker.priceHistory : [];
  const sampledTicker = priceHistory.length <= maxPricePoints
    ? ticker
    : {
        ...ticker,
        priceHistory: sampleSeries(priceHistory, maxPricePoints),
        dataQuality: {
          ...(ticker.dataQuality || {}),
          pricePointsAvailable: priceHistory.length,
          pricePointsReturned: maxPricePoints,
          priceHistorySampling: "uniform-date-sampling"
        }
      };
  return valuationDetailLevel(detail) === "summary"
    ? compactTickerSummary(sampledTicker)
    : sampledTicker;
}

function attachPodcastInsights(ticker, requestedTicker) {
  const lookupKeys = [
    ticker?.ticker,
    ticker?.key,
    requestedTicker
  ].filter(Boolean);
  let insights = [];
  for (const key of lookupKeys) {
    insights = readValuationPodcastInsights(key, 12);
    if (insights.length) break;
  }
  return {
    ...ticker,
    podcastInsights: insights
  };
}

export async function loadValuationDashboard() {
  const version = `${valuationDashboardVersion()}:${factOsEnabled() ? factGeneration() : "legacy"}`;
  if (dashboardCache.payload && dashboardCache.version === version) {
    return dashboardCache.payload;
  }

  const snapshot = readValuationSnapshot();
  if (!snapshot) {
    return {
      ...emptyPayload(),
      cache: { status: "missing", source: "sqlite" }
    };
  }

  const archivedTickers = (snapshot.tickers || [])
    .map(applyAznValuationOverlay)
    .map(applyLsegValuationOverlay);
  const canonicalTickers = factOsEnabled()
    ? await loadCanonicalValuationDashboard(archivedTickers)
    : archivedTickers;
  const tickers = sortTickers(
    canonicalTickers
      .map(withValuationAuditLayers)
      .map(compactTickerForDashboard)
  );
  const latestPriceDates = tickers
    .map((ticker) => String(ticker.latest?.latestPriceDate || ""))
    .filter(Boolean)
    .sort();
  const canonicalLatestPriceDate = latestPriceDates.at(-1) || null;
  const canonicalPositiveUpsideCount = tickers.filter((ticker) => {
    const value = ticker.latest?.upsideToBase;
    return value !== null && value !== undefined && Number.isFinite(Number(value)) && Number(value) >= 0;
  }).length;
  const canonicalNegativeUpsideCount = tickers.filter((ticker) => {
    const value = ticker.latest?.upsideToBase;
    return value !== null && value !== undefined && Number.isFinite(Number(value)) && Number(value) < 0;
  }).length;

  const payload = {
    ...snapshot,
    source: {
      ...(snapshot.source || {}),
      label: "Local SQLite valuation database",
      localDatabase: databaseInfo().path
    },
    summary: {
      ...(snapshot.summary || {}),
      livePriceTickerCount: latestPriceDates.length,
      latestPriceDate: canonicalLatestPriceDate,
      positiveUpsideCount: canonicalPositiveUpsideCount,
      negativeUpsideCount: canonicalNegativeUpsideCount,
      auditLayerCounts: summarizeValuationAuditLayers(tickers)
    },
    podcastInsights: readValuationPodcastInsightSummary(),
    tickers,
    cache: { status: "local-db", source: "sqlite" }
  };
  dashboardCache.version = version;
  dashboardCache.payload = payload;
  return payload;
}

export async function loadValuationTicker(ticker, options = {}) {
  const normalized = normalizeTicker(ticker);
  const pricePoints = normalizePricePoints(options.pricePoints);
  const detail = valuationDetailLevel(options.detail);
  const factVersion = factOsEnabled() ? factGeneration() : "legacy";
  const cacheKey = `${normalized}:${detail}:${pricePoints}:${factVersion}`;
  const candidates = valuationTickerCandidates(normalized);
  const podcastVersion = detail === "full"
    ? readValuationPodcastInsightsVersion(candidates)
    : "podcast-omitted";
  let snapshotVersion = null;
  let resolvedTicker = normalized;
  for (const candidate of candidates) {
    snapshotVersion = readValuationTickerSnapshotVersion(candidate);
    if (snapshotVersion) {
      resolvedTicker = candidate;
      break;
    }
  }

  if (snapshotVersion) {
    const version = `ticker:${resolvedTicker}:${snapshotVersion}:${podcastVersion}:${factVersion}`;
    const cached = readTickerCache(cacheKey, version);
    if (cached) return cached;

    const tickerSnapshot = readValuationTickerSnapshot(resolvedTicker);
    if (tickerSnapshot) {
      const archivedTicker = applyLsegValuationOverlay(applyAznValuationOverlay(tickerSnapshot));
      const canonicalTicker = factOsEnabled()
        ? await loadCanonicalValuationDetail(archivedTicker)
        : archivedTicker;
      const compactedTicker = compactTickerDetail(
        withValuationAuditLayers(canonicalTicker), {
        pricePoints,
        detail
      });
      const resolvedPayloadTicker = detail === "full"
        ? attachPodcastInsights(compactedTicker, resolvedTicker)
        : compactedTicker;
      const payload = {
        generatedAt: resolvedPayloadTicker.generatedAt || new Date().toISOString(),
        source: {
          label: "Local SQLite valuation database",
          localDatabase: databaseInfo().path,
          upstreamLabel: "Legacy fundamental-analysis stock modules"
        },
        ticker: resolvedPayloadTicker,
        ...(detail === "summary" ? { detail } : {}),
        cache: { status: "local-db", source: "sqlite" }
      };
      writeTickerCache(cacheKey, version, payload);
      if (resolvedTicker !== normalized) {
        writeTickerCache(`${resolvedTicker}:${detail}:${pricePoints}`, version, payload);
      }
      return payload;
    }
  }

  const dashboardVersion = valuationDashboardVersion();
  const fallbackVersion = `dashboard:${dashboardVersion}`;
  const cached = readTickerCache(cacheKey, fallbackVersion);
  if (cached) return cached;

  const dashboard = await loadValuationDashboard();
  const fromDashboard = (dashboard.tickers || []).find((item) => {
    const itemKeys = valuationLookupKeysForSnapshot(item);
    return candidates.some((candidate) => itemKeys.includes(candidate));
  });
  if (!fromDashboard) {
    throw new ValuationNotCoveredError(normalized);
  }
  const payload = {
    generatedAt: dashboard.generatedAt,
    source: dashboard.source,
    ticker: detail === "full"
      ? attachPodcastInsights(fromDashboard, normalized)
      : compactTickerDetail(fromDashboard, { pricePoints, detail }),
    ...(detail === "summary" ? { detail } : {}),
    cache: dashboard.cache
  };
  writeTickerCache(cacheKey, fallbackVersion, payload);
  return payload;
}
