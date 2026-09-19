import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  filterLedgerAuditedPriceRepairPoints,
  readPriceSeriesFromDb,
  writePriceSeriesToDb
} from "./localDatabase.js";
import { yahooChartSymbol } from "./tickerAliases.js";
import {
  factOsEnabled,
  queryFacts,
  PRICE_TYPES,
  FactDataError
} from "./factRepository.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const priceCacheDir = process.env.PRICE_CACHE_DIR || path.join(__dirname, "cache", "prices");
const localPriceDir = path.resolve(__dirname, "..", "..", "market-intel-dashboard", "data", "raw", "market_structure", "prices");
const priceCacheTtlMs = 1000 * 60 * 60 * 6;
const yahooTransportMaxAttempts = Math.max(
  1,
  Math.min(4, Math.round(Number(process.env.YAHOO_TRANSPORT_MAX_ATTEMPTS) || 3))
);
const yahooTransportRetryBaseMs = Math.max(
  0,
  Math.min(2_000, Math.round(Number(process.env.YAHOO_TRANSPORT_RETRY_BASE_MS) || 250))
);
const yahooTransportRetryMaxMs = Math.max(
  yahooTransportRetryBaseMs,
  Math.min(5_000, Math.round(Number(process.env.YAHOO_TRANSPORT_RETRY_MAX_MS) || 2_000))
);
const yahooPrimaryChartHost = "query2.finance.yahoo.com";
const yahooAlternateChartHost = "query1.finance.yahoo.com";

function yahooSymbol(symbol) {
  return yahooChartSymbol(symbol);
}

function cacheKey(symbol, start, end) {
  return `${yahooSymbol(symbol)}-${start}-${end}.json`.replace(/[^A-Z0-9_.-]/gi, "_");
}

function dateMs(value) {
  const time = value ? new Date(value).getTime() : 0;
  return Number.isFinite(time) ? time : 0;
}

function rangeCovered(points, start, end) {
  if (!points.length) return false;
  const first = dateMs(points[0].date);
  const last = dateMs(points[points.length - 1].date);
  const startTime = dateMs(start);
  const endTime = dateMs(end);
  const tradingGapMs = 1000 * 60 * 60 * 24 * 7;
  return first <= startTime + tradingGapMs && last >= endTime - tradingGapMs;
}

function adjustedRangeCovered(points, start, end) {
  return rangeCovered(points, start, end) && observedAdjustedCloseCovered(points);
}

function missingExpectedInternalSessions(points, expectedTradingDates) {
  if (!points.length || !(expectedTradingDates || []).length) return [];
  const observedRows = points.filter((point) => point?.date);
  const observedDates = new Set(observedRows
    .filter((point) => Number.isFinite(point.adjustedClose) && point.adjustedClose > 0)
    .map((point) => point.date));
  const orderedObservedDates = observedRows.map((point) => point.date).sort();
  const firstObservedDate = orderedObservedDates[0];
  const lastObservedDate = orderedObservedDates.at(-1);
  return [...new Set((expectedTradingDates || [])
    .map((point) => typeof point === "string" ? point : point?.date)
    .filter((date) => date && date >= firstObservedDate && date <= lastObservedDate))]
    .filter((date) => !observedDates.has(date));
}

function mergeProviderPoints(primaryPoints, retryPoints) {
  const byDate = new Map();
  for (const point of [...(primaryPoints || []), ...(retryPoints || [])]) {
    if (point?.date) byDate.set(point.date, point);
  }
  return [...byDate.values()].sort((left, right) =>
    String(left.date).localeCompare(String(right.date))
  );
}

function expectedInternalSessionsCovered(points, expectedTradingDates) {
  return missingExpectedInternalSessions(points, expectedTradingDates).length === 0;
}

function observedAdjustedCloseCovered(points) {
  return points.length > 0 && points.every((point) =>
    Number.isFinite(point.adjustedClose) && point.adjustedClose > 0
  );
}

function returnBasis(points) {
  return observedAdjustedCloseCovered(points)
    ? "total_return_adjusted_close"
    : "unadjusted_close";
}

export function enforceAdjustedPriceRequirement(payload, {
  start,
  end,
  requireAdjusted = false,
  requireFullRange = false,
  expectedTradingDates = []
} = {}) {
  const points = payload?.points || [];
  const observedAdjustedPoints = points.filter((point) =>
    Number.isFinite(point?.adjustedClose) && point.adjustedClose > 0
  );
  const everyObservedPointAdjusted = observedAdjustedCloseCovered(points);
  const requiredRangeCovered = !requireFullRange || rangeCovered(points, start, end);
  const missingInternalSessions = missingExpectedInternalSessions(
    points,
    expectedTradingDates
  );
  if (
    !requireAdjusted ||
    (
      everyObservedPointAdjusted &&
      requiredRangeCovered &&
      missingInternalSessions.length === 0
    )
  ) {
    return payload;
  }
  const internalSessionGap = requiredRangeCovered &&
    missingInternalSessions.length > 0 &&
    observedAdjustedPoints.length > 0;
  return {
    ...payload,
    source: "unavailable",
    upstreamSource: payload?.source || "unavailable",
    returnBasis: "unavailable",
    points: [],
    // Keep canonical `points` fail-closed. The manager 13F engine explicitly
    // opts into these verified observations so its strict simulation can stop
    // on the missing active date while the proxy audits each holding interval
    // independently instead of discarding complete earlier intervals.
    ...(internalSessionGap ? { observedAdjustedPoints } : {}),
    failure: {
      code: internalSessionGap
        ? "expected_internal_session_gap"
        : "adjusted_close_unavailable",
      policy: internalSessionGap
        ? payload?.expectedInternalSessionRetry?.alternateHostAttempted
          ? "fail_closed_after_dual_host_provider_retry_without_unledgered_db_fill"
          : "fail_closed_after_single_provider_retry_without_unledgered_db_fill"
        : "fail_closed_without_unadjusted_close_fallback",
      requireFullRange,
      rangeCovered: rangeCovered(points, start, end),
      observedPointCount: points.length,
      adjustedPointCount: points.filter((point) =>
        Number.isFinite(point.adjustedClose) && point.adjustedClose > 0
      ).length,
      ...(internalSessionGap ? {
        providerAttempts: Number(payload?.providerAttempts) || 1,
        missingDates: missingInternalSessions,
        missingDateCount: missingInternalSessions.length
      } : {})
    }
  };
}

function unix(date) {
  return Math.floor(new Date(date).getTime() / 1000);
}

function isoDateFromUnix(seconds) {
  return new Date(seconds * 1000).toISOString().slice(0, 10);
}

async function readJson(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch {
    return null;
  }
}

async function writeJson(filePath, payload) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2));
}

async function loadLocalSeries(symbol, start, end) {
  const filePath = path.join(localPriceDir, `${String(symbol).toUpperCase()}.csv`);
  try {
    const raw = await fs.readFile(filePath, "utf8");
    const rows = raw.trim().split(/\r?\n/).slice(1);
    return rows
      .map((row) => {
        const [date, rowSymbol, open, high, low, close, volume] = row.split(",");
        return {
          date,
          symbol: rowSymbol || symbol,
          open: Number(open),
          high: Number(high),
          low: Number(low),
          close: Number(close),
          adjustedClose: null,
          volume: Number(volume)
        };
      })
      .filter((point) => point.date >= start && point.date <= end && Number.isFinite(point.close));
  } catch {
    return [];
  }
}

export function normalizeYahooChartPoints(result, symbol) {
  const timestamps = result?.timestamp || [];
  const quote = result?.indicators?.quote?.[0] || {};
  const adjusted = result?.indicators?.adjclose?.[0]?.adjclose || [];

  return timestamps
    .map((timestamp, index) => ({
      date: isoDateFromUnix(timestamp),
      symbol: String(symbol).toUpperCase(),
      open: quote.open?.[index] ?? null,
      high: quote.high?.[index] ?? null,
      low: quote.low?.[index] ?? null,
      close: quote.close?.[index] ?? null,
      adjustedClose: adjusted[index] ?? null,
      volume: quote.volume?.[index] ?? null
    }))
    .filter((point) => Number.isFinite(point.close));
}

function yahooRetryAfterMs(response) {
  const raw = String(response?.headers?.get?.("retry-after") || "").trim();
  if (!raw) return null;
  const seconds = Number(raw);
  if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1_000;
  const retryAt = Date.parse(raw);
  return Number.isFinite(retryAt) ? Math.max(0, retryAt - Date.now()) : null;
}

function yahooTransportError(message, { status = null, retryAfterMs = null } = {}) {
  const error = new Error(message);
  error.status = status != null && Number.isFinite(Number(status)) ? Number(status) : null;
  error.retryAfterMs = retryAfterMs != null && Number.isFinite(Number(retryAfterMs))
    ? Number(retryAfterMs)
    : null;
  return error;
}

function yahooTransportErrorIsRetryable(error) {
  const status = Number(error?.status);
  if (!Number.isFinite(status) || status <= 0) return true;
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

function wait(milliseconds) {
  return milliseconds > 0
    ? new Promise((resolve) => setTimeout(resolve, milliseconds))
    : Promise.resolve();
}

async function fetchYahooSeriesOnce(symbol, start, end, {
  hostname = yahooPrimaryChartHost
} = {}) {
  const encoded = encodeURIComponent(yahooSymbol(symbol));
  const url = `https://${hostname}/v8/finance/chart/${encoded}?period1=${unix(start)}&period2=${unix(end) + 86400}&interval=1d`;
  const response = await fetch(url, {
    headers: {
      "User-Agent": "Mozilla/5.0 guru-analysis-dashboard/0.1",
      "Accept": "application/json"
    }
  });

  if (!response.ok) {
    throw yahooTransportError(`Yahoo chart failed ${response.status} for ${symbol}`, {
      status: response.status,
      retryAfterMs: yahooRetryAfterMs(response)
    });
  }

  const json = await response.json();
  return normalizeYahooChartPoints(json.chart?.result?.[0], symbol);
}

async function fetchYahooSeries(symbol, start, end, {
  hostname = yahooPrimaryChartHost,
  onAttempt = null
} = {}) {
  let lastError = null;
  for (let attempt = 1; attempt <= yahooTransportMaxAttempts; attempt += 1) {
    if (typeof onAttempt === "function") onAttempt({ hostname, attempt });
    try {
      return await fetchYahooSeriesOnce(symbol, start, end, { hostname });
    } catch (error) {
      lastError = error;
      if (
        attempt >= yahooTransportMaxAttempts ||
        !yahooTransportErrorIsRetryable(error)
      ) {
        throw error;
      }
      const exponentialDelay = yahooTransportRetryBaseMs * (2 ** (attempt - 1));
      const requestedDelay = error?.retryAfterMs != null &&
          Number.isFinite(Number(error.retryAfterMs))
        ? Number(error.retryAfterMs)
        : exponentialDelay;
      await wait(Math.min(yahooTransportRetryMaxMs, Math.max(0, requestedDelay)));
    }
  }
  throw lastError || new Error(`Yahoo chart failed for ${symbol}`);
}

export async function loadPriceSeries(symbol, {
  start,
  end,
  priceType,
  force = false,
  requireAdjusted = false,
  requireFullRange = false,
  expectedTradingDates = []
}) {
  if (factOsEnabled() && !Object.values(PRICE_TYPES).includes(priceType)) {
    throw new FactDataError(
      "explicit_price_basis_required",
      "Choose RAW_CLOSE, SPLIT_ADJUSTED_CLOSE or TOTAL_RETURN_ADJUSTED_CLOSE explicitly."
    );
  }
  const normalized = String(symbol || "").trim().toUpperCase();
  if (!normalized) return { symbol: "", source: "missing", points: [] };

  if (factOsEnabled()) {
    try {
      const rows = await queryFacts(
        "get_price_history",
        [normalized, start, end, priceType],
        { dataset: "auto" }
      );
      const points = rows.map((point) => ({
        date: point.date,
        symbol: normalized,
        close: point.value,
        adjustedClose: priceType === PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE
          ? point.value
          : null,
        priceType,
        securityId: point.security_id,
        provenance: point.provenance
      }));
      return {
        symbol: normalized,
        source: "sharadar_fact_os",
        returnBasis: priceType === PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE
          ? "total_return_adjusted_close"
          : priceType.toLowerCase(),
        priceType,
        generatedAt: new Date().toISOString(),
        cache: "local-only",
        points,
        status: points.length ? "available" : "missing",
        message: points.length
          ? "Local Sharadar facts; refresh synchronizes separately."
          : "No local price coverage. No legacy price or provider request was substituted."
      };
    } catch (error) {
      if (!(error instanceof FactDataError)) throw error;
      return {
        symbol: normalized,
        source: "sharadar_fact_os",
        priceType,
        status: "unavailable",
        points: [],
        error: error.code,
        message: error.message
      };
    }
  }

  const dbPoints = readPriceSeriesFromDb(normalized, start, end);
  const dbUsable = requireAdjusted
    // SQLite rows have no request-range provenance. A fully adjusted but
    // truncated subset or an internal expected-session gap must be refreshed
    // before the active-holding engine decides whether a shorter IPO/delisting
    // history or a genuine trading halt is legitimate.
    ? adjustedRangeCovered(dbPoints, start, end) &&
      expectedInternalSessionsCovered(dbPoints, expectedTradingDates)
    : rangeCovered(dbPoints, start, end);
  if (dbUsable) {
    return {
      symbol: normalized,
      source: "sqlite",
      returnBasis: returnBasis(dbPoints),
      generatedAt: new Date().toISOString(),
      cache: "sqlite-hit",
      points: dbPoints
    };
  }

  const cacheFile = path.join(priceCacheDir, cacheKey(normalized, start, end));
  const cached = force ? null : await readJson(cacheFile);
  const cachedPoints = cached?.points || [];
  const cachedUsable = requireAdjusted
    ? requireFullRange
      ? adjustedRangeCovered(cachedPoints, start, end) &&
        expectedInternalSessionsCovered(cachedPoints, expectedTradingDates)
      : observedAdjustedCloseCovered(cachedPoints) &&
        expectedInternalSessionsCovered(cachedPoints, expectedTradingDates)
    : true;
  if (
    cached &&
    Date.now() - new Date(cached.generatedAt).getTime() < priceCacheTtlMs &&
    cachedUsable
  ) {
    writePriceSeriesToDb(normalized, cached.points || [], cached.source || "json-cache");
    return {
      ...cached,
      returnBasis: returnBasis(cached.points || []),
      cache: "hit"
    };
  }

  let source = "yahoo";
  let points = [];
  let providerAttempts = 0;
  const providerHosts = [];
  let expectedInternalSessionRetry = null;
  let providerFailure = null;
  const recordProviderAttempt = ({ hostname } = {}) => {
    providerAttempts += 1;
    if (hostname && !providerHosts.includes(hostname)) providerHosts.push(hostname);
  };

  try {
    points = await fetchYahooSeries(normalized, start, end, {
      onAttempt: recordProviderAttempt
    });
    const firstMissingDates = requireAdjusted
      ? missingExpectedInternalSessions(points, expectedTradingDates)
      : [];
    if (firstMissingDates.length) {
      let alternateHostError = null;
      try {
        const allowedDates = new Set(firstMissingDates);
        const alternatePoints = await fetchYahooSeries(
          normalized,
          firstMissingDates[0],
          firstMissingDates.at(-1),
          {
            hostname: yahooAlternateChartHost,
            onAttempt: recordProviderAttempt
          }
        );
        // The alternate host may return neighboring sessions for a bounded
        // request. It may only fill dates the primary response did not already
        // supply with an adjusted observation; primary rows never get replaced.
        points = mergeProviderPoints(
          points,
          alternatePoints.filter((point) => allowedDates.has(point.date))
        );
      } catch (error) {
        alternateHostError = String(
          error?.message || error || "Alternate Yahoo host retry failed."
        );
      }
      expectedInternalSessionRetry = {
        attempted: true,
        initialMissingDates: firstMissingDates,
        remainingMissingDates: missingExpectedInternalSessions(
          points,
          expectedTradingDates
        ),
        alternateHostAttempted: true,
        alternateHost: yahooAlternateChartHost,
        ...(alternateHostError ? { alternateHostError } : {})
      };
    }
  } catch (error) {
    providerFailure = {
      code: "yahoo_transport_unavailable",
      status: error?.status != null && Number.isFinite(Number(error.status))
        ? Number(error.status)
        : null,
      retryable: yahooTransportErrorIsRetryable(error),
      attempts: providerAttempts,
      message: String(error?.message || error || "Yahoo transport failed.").slice(0, 240)
    };
    points = await loadLocalSeries(normalized, start, end);
    source = points.length ? "local-csv" : "unavailable";
  }

  const payload = {
    symbol: normalized,
    source,
    returnBasis: returnBasis(points),
    generatedAt: new Date().toISOString(),
    providerAttempts,
    ...(providerHosts.length ? { providerHosts } : {}),
    ...(expectedInternalSessionRetry ? { expectedInternalSessionRetry } : {}),
    ...(providerFailure ? { providerFailure } : {}),
    points
  };
  let responsePayload = payload;
  if (
    requireAdjusted &&
    source !== "unavailable" &&
    points.length &&
    observedAdjustedCloseCovered(points)
  ) {
    const freshDates = new Set(points.map((point) => point.date).filter(Boolean));
    const storedPoints = readPriceSeriesFromDb(normalized, start, end);
    const auditedSupplements = filterLedgerAuditedPriceRepairPoints(
      storedPoints.filter((point) => !freshDates.has(point.date))
    );
    const auditedSupplementKeys = new Set(
      auditedSupplements.map((point) => `${point.symbol}:${point.date}`)
    );
    const mergedPoints = mergeProviderPoints(
      storedPoints.filter((point) =>
        auditedSupplementKeys.has(`${point.symbol}:${point.date}`)
      ),
      points
    );
    const mergedUsable = observedAdjustedCloseCovered(mergedPoints) &&
      expectedInternalSessionsCovered(mergedPoints, expectedTradingDates) &&
      (!requireFullRange || adjustedRangeCovered(mergedPoints, start, end));
    if (mergedUsable) {
      responsePayload = {
        ...payload,
        source: `${source}+sqlite-merged`,
        returnBasis: returnBasis(mergedPoints),
        cache: "refreshed-merged",
        points: mergedPoints
      };
    }
  }
  const enforcedPayload = enforceAdjustedPriceRequirement(responsePayload, {
    start,
    end,
    requireAdjusted,
    requireFullRange,
    expectedTradingDates
  });
  // Persist only the exact payload that passed the caller's adjusted-close
  // contract. Writing fresh rows before this audit can complete a truncated
  // SQLite range while inheriting an older adjusted close on an overlapping
  // date, allowing a second identical call to publish a curve the first call
  // correctly rejected.
  if (!enforcedPayload.failure && enforcedPayload.points?.length) {
    writePriceSeriesToDb(normalized, enforcedPayload.points, source);
  }
  await writeJson(cacheFile, enforcedPayload);
  return enforcedPayload;
}

export function nearestPoint(points, date) {
  if (!points?.length || !date) return null;
  const target = new Date(date).getTime();
  let best = points[0];
  let bestDistance = Math.abs(new Date(best.date).getTime() - target);

  for (const point of points) {
    const distance = Math.abs(new Date(point.date).getTime() - target);
    if (distance < bestDistance) {
      best = point;
      bestDistance = distance;
    }
  }

  return best;
}
