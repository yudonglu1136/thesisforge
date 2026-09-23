import { readPriceSeriesFromDb } from "./localDatabase.js";
import {
  factOsEnabled,
  queryFacts,
  queryFactsBatch,
  PRICE_TYPES,
  FactDataError
} from "./factRepository.js";

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

function factPriceSeries(normalized, priceType, rows) {
  const points = rows.map((point) => ({
    date: point.date,
    symbol: normalized,
    close: point.value,
    adjustedClose: priceType === PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE
      ? point.value : null,
    priceType,
    securityId: point.security_id,
    provenance: point.provenance
  }));
  return {
    symbol: normalized,
    source: "sharadar_fact_os",
    returnBasis: priceType === PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE
      ? "total_return_adjusted_close" : priceType.toLowerCase(),
    priceType,
    generatedAt: new Date().toISOString(),
    cache: "local-only",
    points,
    status: points.length ? "available" : "missing",
    message: points.length
      ? "Local Sharadar facts; refresh synchronizes separately."
      : "No local price coverage. No legacy price or provider request was substituted."
  };
}

function unavailableFactPriceSeries(symbol, priceType, error) {
  return {symbol, source: "sharadar_fact_os", priceType, status: "unavailable",
    points: [], error: error.code, message: error.message};
}

// Reuse the canonical repository's pinned-generation batch protocol. Keep
// history batches small: 10Y points carry per-observation provenance and must
// remain below the existing RPC memory/response limit. Missing securities are
// individual failures, never fabricated zero prices or a provider fallback.
export async function loadPriceSeriesBatch(requests) {
  if (!factOsEnabled()) {
    return Promise.all(requests.map(({symbol, ...options}) => loadPriceSeries(symbol, options)));
  }
  const normalized = requests.map(({symbol, ...options}) => ({
    symbol: String(symbol || "").trim().toUpperCase(), ...options
  }));
  if (normalized.some(r => !Object.values(PRICE_TYPES).includes(r.priceType))) {
    throw new FactDataError("explicit_price_basis_required",
      "Choose RAW_CLOSE, SPLIT_ADJUSTED_CLOSE or TOTAL_RETURN_ADJUSTED_CLOSE explicitly.");
  }
  const output = [];
  for (let offset = 0; offset < normalized.length; offset += 8) {
    const group = normalized.slice(offset, offset + 8);
    const nonempty = group.filter(r => r.symbol);
    let responses;
    try {
      responses = nonempty.length ? await queryFactsBatch(nonempty.map(r => ({
        method: "get_price_history", args: [r.symbol, r.start, r.end, r.priceType],
        kwargs: {dataset: "auto"}
      }))) : [];
    } catch (error) {
      if (!(error instanceof FactDataError)) throw error;
      responses = nonempty.map(() => ({ok: false, error}));
    }
    let index = 0;
    for (const r of group) {
      if (!r.symbol) { output.push({symbol: "", source: "missing", points: []}); continue; }
      const result = responses[index++];
      output.push(result.ok ? factPriceSeries(r.symbol, r.priceType, result.result)
        : unavailableFactPriceSeries(r.symbol, r.priceType, result.error));
    }
  }
  return output;
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
      return factPriceSeries(normalized, priceType, rows);
    } catch (error) {
      if (!(error instanceof FactDataError)) throw error;
      return unavailableFactPriceSeries(normalized, priceType, error);
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

  // A partial local range fails closed instead of silently changing vendors.
  // Released SQLite rows are rebuilt from Sharadar SEP/SFP, while Fact OS is
  // the canonical local reader.
  return enforceAdjustedPriceRequirement({
    symbol: normalized,
    source: "sharadar_sqlite",
    returnBasis: returnBasis(dbPoints),
    generatedAt: new Date().toISOString(),
    cache: dbPoints.length ? "sqlite-partial" : "sqlite-missing",
    status: "unavailable",
    points: [],
    failure: {
      code: dbPoints.length ? "local_range_incomplete" : "local_price_unavailable",
      policy: "fail_closed_without_network_or_legacy_provider_fallback",
      observedPointCount: dbPoints.length
    }
  }, { start, end, requireAdjusted, requireFullRange, expectedTradingDates });

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
