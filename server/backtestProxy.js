import { resolveTrailingCommonPriceEnd } from "./backtestEngine.js";
import {
  minimumPublicHoldingsProxyCoverage,
  minimumPublicHoldingsProxyPositions,
  normalizedProxyCoverageFloor,
  normalizedProxyPositionFloor
} from "./backtestProxyAudit.js";

function finitePositive(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0;
}

function holdingPriceSymbol(holding) {
  return String(holding?.priceSymbol || holding?.ticker || "")
    .trim()
    .toUpperCase();
}

function holdingHasAuditedValue(holding, date, priceMaps) {
  const action = holding?.corporateAction;
  const effectiveDate = String(action?.effectiveDate || "");
  const cashConversionDate = String(
    action?.publicTradingEndExclusive || effectiveDate
  );
  if (action?.considerationType === "cash" &&
      cashConversionDate && date >= cashConversionDate) {
    return finitePositive(action?.terminalCashEntitlementPerShare);
  }
  if (effectiveDate && date >= effectiveDate) {
    if (["stock", "stock_and_cash"].includes(action?.considerationType)) {
      if (action?.considerationType === "stock_and_cash" &&
          !finitePositive(action?.terminalCashEntitlementPerShare)) {
        return false;
      }
      const firstTradingDate = String(
        action?.successorFirstTradingDate || effectiveDate
      );
      if (date < firstTradingDate) return true;
      const successorTicker = String(action?.successorTicker || "")
        .trim()
        .toUpperCase();
      return finitePositive(priceMaps?.get(successorTicker)?.get(date));
    }
  }
  return finitePositive(priceMaps?.get(holdingPriceSymbol(holding))?.get(date));
}

function reportedBookWeight(holding) {
  const value = Number(holding?.reportedBookWeight ?? holding?.weight);
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function orderedTradingDates(tradingDates, start, end) {
  return [...new Set((tradingDates || [])
    .map((point) => typeof point === "string" ? point : point?.date)
    .filter((date) => date && date >= start && (!end || date <= end)))]
    .sort();
}

function earlierDate(left, right) {
  if (!left) return right || null;
  if (!right) return left;
  return left < right ? left : right;
}

function normalizedExcludedPosition(row, reason = null) {
  const weight = reportedBookWeight(row);
  return {
    ticker: row?.ticker || null,
    issuer: row?.issuer || row?.ticker || "Unknown issuer",
    cusip: row?.cusip || null,
    value: Number(row?.value || 0),
    // Keep the old field for existing audit readers while making the economic
    // denominator explicit for proxy consumers.
    weight,
    reportedBookWeight: weight,
    reason: reason || row?.reason || "unavailable_for_public_holdings_proxy"
  };
}

function mergeExcludedPositions(rebalance, excluded) {
  const rows = new Map();
  for (const row of rebalance.unpricedPositions || []) {
    const normalized = normalizedExcludedPosition(row);
    const key = `${normalized.cusip || ""}:${normalized.ticker || ""}:${normalized.issuer}`;
    rows.set(key, normalized);
  }
  for (const holding of excluded) {
    const normalized = normalizedExcludedPosition(
      holding,
      "incomplete_active_adjusted_price_history"
    );
    const key = `${normalized.cusip || ""}:${normalized.ticker || ""}:${normalized.issuer}`;
    rows.set(key, normalized);
  }
  return [...rows.values()].sort((left, right) =>
    right.reportedBookWeight - left.reportedBookWeight
  );
}

function aggregateTopExcludedHoldings(rebalances, limit = 8) {
  const rows = new Map();
  for (const rebalance of rebalances) {
    for (const holding of rebalance.unpricedPositions || []) {
      const key = `${holding.cusip || ""}:${holding.ticker || ""}:${holding.issuer || ""}`;
      const excludedWeight = reportedBookWeight(holding);
      const current = rows.get(key);
      if (!current || excludedWeight > current.maxExcludedBookWeight) {
        rows.set(key, {
          ticker: holding.ticker || null,
          issuer: holding.issuer || holding.ticker || "Unknown issuer",
          maxExcludedBookWeight: excludedWeight
        });
      }
    }
  }
  return [...rows.values()]
    .sort((left, right) =>
      right.maxExcludedBookWeight - left.maxExcludedBookWeight ||
      String(left.ticker || left.issuer).localeCompare(String(right.ticker || right.issuer))
    )
    .slice(0, limit);
}

function consolidateEligibleHoldings(holdings) {
  const byTicker = new Map();
  for (const holding of holdings) {
    const ticker = String(holding?.ticker || "").trim().toUpperCase();
    const priceSymbol = holdingPriceSymbol(holding);
    if (!ticker) continue;
    const key = `${ticker}\u0000${priceSymbol}`;
    const current = byTicker.get(key);
    const bookWeight = reportedBookWeight(holding);
    byTicker.set(key, current
      ? {
          ...current,
          value: Number(current.value || 0) + Number(holding.value || 0),
          reportedBookWeight: current.reportedBookWeight + bookWeight,
          weight: current.reportedBookWeight + bookWeight
        }
      : {
          ...holding,
          ticker,
          ...(priceSymbol !== ticker ? { priceSymbol } : {}),
          reportedBookWeight: bookWeight,
          weight: bookWeight
        });
  }
  return [...byTicker.values()];
}

/**
 * Build a deliberately separate public-holdings proxy. The strict backtest
 * keeps its 90% gate and cash treatment. This helper is used only after that
 * model fails, and only when the UI discloses the selected-book sleeve
 * coverage. Every quarter must retain at least two fully priced names and 30%
 * of the selected common-long book; callers may raise, but not lower, either
 * floor.
 */
export function buildPublicHoldingsProxy({
  rebalances,
  tradingDates,
  priceMaps,
  endDate,
  minimumCoverage = minimumPublicHoldingsProxyCoverage,
  minimumPositions = minimumPublicHoldingsProxyPositions
}) {
  const coverageFloor = normalizedProxyCoverageFloor(minimumCoverage);
  const positionFloor = normalizedProxyPositionFloor(minimumPositions);
  const ordered = [...(rebalances || [])]
    .filter((rebalance) =>
      rebalance?.executionDate && (!endDate || rebalance.executionDate <= endDate)
    )
    .sort((left, right) => String(left.executionDate).localeCompare(String(right.executionDate)));
  if (!ordered.length) {
    return { ok: false, failure: { code: "proxy_no_rebalances" }, rebalances: [] };
  }

  const proxyRebalances = [];
  for (let index = 0; index < ordered.length; index += 1) {
    const rebalance = ordered[index];
    const intervalEnd = earlierDate(ordered[index + 1]?.executionDate, endDate);
    const requiredDates = orderedTradingDates(
      tradingDates,
      rebalance.executionDate,
      intervalEnd
    );
    const eligible = [];
    const excluded = [];
    for (const holding of rebalance.weights || []) {
      const complete = requiredDates.length > 0 && requiredDates.every((date) =>
        holdingHasAuditedValue(holding, date, priceMaps)
      );
      (complete ? eligible : excluded).push(holding);
    }
    const consolidatedEligible = consolidateEligibleHoldings(eligible);
    const selectedBookCoverage = consolidatedEligible.reduce(
      (sum, holding) => sum + reportedBookWeight(holding),
      0
    );
    const excludedPositions = mergeExcludedPositions(rebalance, excluded);
    if (consolidatedEligible.length < positionFloor) {
      return {
        ok: false,
        failure: {
          code: "proxy_included_positions_below_minimum",
          reportDate: rebalance.reportDate || null,
          executionDate: rebalance.executionDate,
          includedPositions: consolidatedEligible.length,
          minimumPositions: positionFloor,
          selectedBookCoverage
        },
        rebalances: []
      };
    }
    if (selectedBookCoverage + 1e-12 < coverageFloor) {
      return {
        ok: false,
        failure: {
          code: "proxy_coverage_below_minimum",
          reportDate: rebalance.reportDate || null,
          executionDate: rebalance.executionDate,
          coveragePct: selectedBookCoverage,
          minimumCoverage: coverageFloor,
          includedPositions: consolidatedEligible.length,
          // The positions are delayed public 13F disclosures. Persisting only
          // the largest exclusions makes a failed sleeve diagnosable without
          // dumping the full portfolio or any provider price observations.
          topExcludedHoldings: excludedPositions.slice(0, 8).map((holding) => ({
            ticker: holding.ticker,
            issuer: holding.issuer,
            cusip: holding.cusip,
            reportedBookWeight: holding.reportedBookWeight,
            reason: holding.reason
          }))
        },
        rebalances: []
      };
    }
    const weights = consolidatedEligible.map((holding) => {
      const originalWeight = reportedBookWeight(holding);
      const proxyWeight = originalWeight / selectedBookCoverage;
      return {
        ...holding,
        reportedBookWeight: originalWeight,
        proxyWeight,
        // simulateDriftedPortfolio consumes `weight`; the two named fields
        // prevent this normalized weight from being mistaken for book weight.
        weight: proxyWeight
      };
    });
    const unpricedPositions = excludedPositions;
    proxyRebalances.push({
      ...rebalance,
      weights,
      cashWeight: 0,
      coveragePct: selectedBookCoverage,
      reportedCoveragePct: selectedBookCoverage,
      selectedBookCoverage,
      excludedWeightPct: Math.max(0, 1 - selectedBookCoverage),
      proxyNormalizationFactor: 1 / selectedBookCoverage,
      pricedValue: Number(rebalance.selectedValue || 0) * selectedBookCoverage,
      pricedPositions: weights.length,
      includedPositions: weights.length,
      unpricedPositions,
      topHoldings: weights.slice(0, 8).map((holding) => ({
        ticker: holding.ticker,
        issuer: holding.issuer,
        value: holding.value,
        weight: holding.proxyWeight,
        reportedBookWeight: holding.reportedBookWeight,
        proxyWeight: holding.proxyWeight
      }))
    });
  }

  const coverages = proxyRebalances.map((rebalance) => rebalance.selectedBookCoverage);
  const includedCounts = proxyRebalances.map((rebalance) => rebalance.includedPositions);
  const minimumSelectedBookCoverage = Math.min(...coverages);
  const averageSelectedBookCoverage = coverages.reduce((sum, value) => sum + value, 0) /
    coverages.length;
  const maximumExcludedBookWeight = Math.max(...coverages.map((value) => 1 - value));
  const minimumIncludedPositions = Math.min(...includedCounts);
  return {
    ok: true,
    rebalances: proxyRebalances,
    minimumSelectedBookCoverage,
    averageSelectedBookCoverage,
    maximumExcludedBookWeight,
    minimumIncludedPositions,
    topExcludedHoldings: aggregateTopExcludedHoldings(proxyRebalances),
    minimumProxyCoverage: coverageFloor,
    minimumProxyPositions: positionFloor,
    // Transitional aliases for existing clients. New code should use the
    // selected-book names above.
    minimumReportedCoverage: minimumSelectedBookCoverage,
    averageReportedCoverage: averageSelectedBookCoverage,
    excludedWeightMax: maximumExcludedBookWeight
  };
}

/**
 * Resolve the already-audited bounded common trailing cutoff before checking
 * whether a sleeve is complete. This prevents two holdings sharing a valid
 * one-day vendor lag from being discarded merely because the requested SPY end
 * is later.
 */
export function buildTrailingAwarePublicHoldingsProxy({
  rebalances,
  tradingDates,
  priceMaps,
  benchmarkSymbol = "SPY",
  requestedEnd,
  maxLagDays = 7,
  minimumCoverage = minimumPublicHoldingsProxyCoverage,
  minimumPositions = minimumPublicHoldingsProxyPositions
}) {
  const trailingPriceEnd = resolveTrailingCommonPriceEnd({
    rebalances,
    tradingDates,
    priceMaps,
    benchmarkSymbol,
    requestedEnd,
    maxLagDays
  });
  const effectiveEnd = trailingPriceEnd.effectiveEnd || requestedEnd;
  const proxy = buildPublicHoldingsProxy({
    rebalances,
    tradingDates,
    priceMaps,
    endDate: effectiveEnd,
    minimumCoverage,
    minimumPositions
  });
  return {
    ...proxy,
    effectiveEnd,
    trailingPriceEnd
  };
}
