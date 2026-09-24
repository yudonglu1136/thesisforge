const dayMs = 24 * 60 * 60 * 1000;
const reconciliationTolerance = 1e-10;

function finitePositive(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function dateOnly(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  const isoMatch = raw.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (isoMatch) return `${isoMatch[1]}-${isoMatch[2]}-${isoMatch[3]}`;
  const compactMatch = raw.match(/^(\d{4})(\d{2})(\d{2})/);
  if (compactMatch) return `${compactMatch[1]}-${compactMatch[2]}-${compactMatch[3]}`;
  const parsed = new Date(raw);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString().slice(0, 10) : "";
}

function quarterLabel(reportDate) {
  const parsed = new Date(reportDate);
  if (Number.isNaN(parsed.getTime())) return reportDate || "Quarter";
  return `${parsed.getUTCFullYear()} Q${Math.floor(parsed.getUTCMonth() / 3) + 1}`;
}

export function adjustedClosePriceMap(points) {
  return new Map((points || [])
    .filter((point) => point?.date && finitePositive(point.adjustedClose) != null)
    .map((point) => [point.date, Number(point.adjustedClose)]));
}

export function nextTradingSessionAfter(tradingDates, publicTimestamp) {
  const publicDate = dateOnly(publicTimestamp);
  if (!publicDate) return null;
  return (tradingDates || [])
    .map((point) => typeof point === "string" ? point : point?.date)
    .find((date) => String(date || "") > publicDate) || null;
}

export function filingExecutionDecision(snapshot, tradingDates) {
  const acceptanceDateTime = snapshot?.acceptanceDateTime || snapshot?.filing?.acceptanceDateTime || "";
  const filingDate = snapshot?.filingDate || snapshot?.filing?.filingDate || "";
  const publicTimestamp = acceptanceDateTime || filingDate;
  const publicDate = dateOnly(publicTimestamp);
  const executionDate = nextTradingSessionAfter(tradingDates, publicTimestamp);
  const usedLegacyFilingDateFallback = !acceptanceDateTime && Boolean(filingDate);

  return {
    executionDate,
    publicTimestamp: publicTimestamp || null,
    publicDate: publicDate || null,
    acceptanceDateTime: acceptanceDateTime || null,
    executionTimestampSource: acceptanceDateTime
      ? "sec_acceptance_datetime"
      : usedLegacyFilingDateFallback
        ? "legacy_filing_date"
        : "missing",
    usedLegacyFilingDateFallback,
    policy: "first_trading_session_strictly_after_public_date_close",
    reason: executionDate
      ? null
      : publicDate
        ? "No later trading session is available in the requested price window."
        : "Neither SEC acceptance timestamp nor filing date is available."
  };
}

function normalizedWeights(rebalance) {
  const byTicker = new Map();
  for (const holding of rebalance?.weights || []) {
    const ticker = String(holding?.ticker || "").trim().toUpperCase();
    const priceSymbol = String(holding?.priceSymbol || ticker).trim().toUpperCase();
    const weight = Number(holding?.weight);
    if (!ticker || !priceSymbol || !Number.isFinite(weight) || weight <= 0) continue;
    const key = `${ticker}\u0000${priceSymbol}`;
    const current = byTicker.get(key);
    byTicker.set(key, current
      ? {
          ...current,
          value: Number(current.value || 0) + Number(holding.value || 0),
          weight: current.weight + weight
        }
      : {
          ...holding,
          ticker,
          ...(priceSymbol !== ticker ? { priceSymbol } : {}),
          weight
        });
  }
  return [...byTicker.values()];
}

function holdingPriceSymbol(holding) {
  return String(holding?.priceSymbol || holding?.ticker || "")
    .trim()
    .toUpperCase();
}

function latestMapDateOnOrBefore(priceMap, endDate) {
  return [...(priceMap?.keys?.() || [])]
    .filter((date) => date && (!endDate || date <= endDate))
    .sort()
    .at(-1) || null;
}

export function resolveTrailingCommonPriceEnd({
  rebalances,
  tradingDates,
  priceMaps,
  benchmarkSymbol = "SPY",
  requestedEnd = null,
  maxLagDays = 7
}) {
  const marketDates = [...new Set((tradingDates || [])
    .map((point) => typeof point === "string" ? point : point?.date)
    .filter((date) => date && (!requestedEnd || date <= requestedEnd)))]
    .sort();
  const requestedMarketEnd = marketDates.at(-1) || requestedEnd || null;
  const orderedRebalances = [...(rebalances || [])]
    .filter((rebalance) =>
      rebalance?.executionDate &&
      (!requestedMarketEnd || rebalance.executionDate <= requestedMarketEnd)
    )
    .sort((left, right) => String(left.executionDate).localeCompare(String(right.executionDate)));
  const latestRebalance = orderedRebalances.at(-1);
  const activeTickers = normalizedWeights(latestRebalance).map(holdingPriceSymbol);
  const base = {
    requestedEnd: requestedEnd || null,
    requestedMarketEnd,
    effectiveEnd: requestedMarketEnd,
    adjusted: false,
    lagDays: 0,
    maxLagDays,
    latestRebalanceDate: latestRebalance?.executionDate || null,
    activeTickers
  };
  if (!requestedMarketEnd || !latestRebalance || !activeTickers.length) {
    return { ...base, reason: "no_active_rebalance" };
  }

  const requiredTickers = [benchmarkSymbol, ...activeTickers];
  const latestDates = requiredTickers.map((ticker) => ({
    ticker,
    date: latestMapDateOnOrBefore(priceMaps?.get(ticker), requestedMarketEnd)
  }));
  if (latestDates.some((row) => !row.date)) {
    return { ...base, reason: "active_series_missing", latestDates };
  }
  const benchmarkLatestDate = latestDates[0]?.date;
  if (benchmarkLatestDate !== requestedMarketEnd) {
    return { ...base, reason: "benchmark_end_missing", latestDates };
  }
  const staleActiveRows = latestDates.slice(1)
    .filter((row) => row.date < requestedMarketEnd);
  if (!staleActiveRows.length) {
    return {
      ...base,
      reason: "requested_market_end_covered",
      latestDates,
      staleActiveTickers: []
    };
  }
  const staleDates = [...new Set(staleActiveRows.map((row) => row.date))];
  const observedLagDays = Math.max(...staleDates.map((date) =>
    Math.max(
      0,
      Math.round((new Date(requestedMarketEnd).getTime() - new Date(date).getTime()) / dayMs)
    )
  ));
  if (staleActiveRows.length < 2 || staleDates.length !== 1) {
    return {
      ...base,
      lagDays: observedLagDays,
      reason: staleActiveRows.length < 2
        ? "insufficient_common_lag_evidence"
        : "mixed_trailing_dates",
      latestDates,
      staleActiveTickers: staleActiveRows.map((row) => row.ticker)
    };
  }
  const commonCeiling = staleDates[0];
  const effectiveEnd = marketDates.filter((date) => date <= commonCeiling).at(-1) || null;
  if (!effectiveEnd || effectiveEnd < latestRebalance.executionDate) {
    return {
      ...base,
      reason: "common_end_precedes_latest_rebalance",
      latestDates,
      staleActiveTickers: staleActiveRows.map((row) => row.ticker)
    };
  }
  const lagDays = Math.max(
    0,
    Math.round((new Date(requestedMarketEnd).getTime() - new Date(effectiveEnd).getTime()) / dayMs)
  );
  if (lagDays > Math.max(0, Number(maxLagDays) || 0)) {
    return {
      ...base,
      lagDays,
      reason: "common_end_exceeds_max_lag",
      latestDates,
      staleActiveTickers: staleActiveRows.map((row) => row.ticker)
    };
  }
  return {
    ...base,
    effectiveEnd,
    adjusted: effectiveEnd < requestedMarketEnd,
    lagDays,
    reason: effectiveEnd < requestedMarketEnd
      ? "bounded_trailing_vendor_lag"
      : "requested_market_end_covered",
    latestDates,
    staleActiveTickers: staleActiveRows.map((row) => row.ticker)
  };
}

export function allocateAtClose(rebalance, portfolioValue, priceMaps, allowExplicitCash = false) {
  const weights = normalizedWeights(rebalance);
  const weightSum = weights.reduce((sum, holding) => sum + holding.weight, 0);
  const explicitCashWeight = Number(rebalance?.cashWeight);
  const auditedCashOnly = !weights.length &&
    Number.isFinite(explicitCashWeight) &&
    Math.abs(explicitCashWeight - 1) <= reconciliationTolerance &&
    Array.isArray(rebalance?.corporateActionResolutions) &&
    rebalance.corporateActionResolutions.some((resolution) =>
      resolution?.considerationType === "cash" &&
      resolution?.timing === "before_modeled_execution"
    );
  const explicitStrategyCash = allowExplicitCash && weights.length === 0 &&
    explicitCashWeight === 1 && rebalance.cashReason === 'strategy_rules';
  if ((!weights.length && !auditedCashOnly && !explicitStrategyCash) || weightSum > 1 + reconciliationTolerance) {
    return {
      ok: false,
      failure: {
        code: weights.length ? "invalid_weight_sum" : "empty_rebalance",
        date: rebalance?.executionDate || null,
        weightSum
      }
    };
  }

  const missing = [];
  const positions = [];
  for (const holding of weights) {
    const priceSymbol = holdingPriceSymbol(holding);
    const startPrice = finitePositive(priceMaps.get(priceSymbol)?.get(rebalance.executionDate));
    if (startPrice == null) {
      missing.push({
        ticker: holding.ticker,
        ...(priceSymbol !== holding.ticker ? { priceSymbol } : {}),
        weight: holding.weight
      });
      continue;
    }
    const startValue = portfolioValue * holding.weight;
    positions.push({
      ticker: holding.ticker,
      ...(priceSymbol !== holding.ticker ? { priceSymbol } : {}),
      ...(holding.priceSymbolAudit
        ? { priceSymbolAudit: holding.priceSymbolAudit }
        : {}),
      issuer: holding.issuer,
      sector: holding.sector || null,
      industry: holding.industry || null,
      disclosedValue: holding.value,
      weight: holding.weight,
      ...(holding.corporateAction ? {
        corporateAction: { ...holding.corporateAction }
      } : {}),
      ...(holding.corporateActionResolution ? {
        corporateActionResolution: { ...holding.corporateActionResolution }
      } : {}),
      ...(holding.reportedBookWeight != null &&
        Number.isFinite(Number(holding.reportedBookWeight))
        ? { reportedBookWeight: Number(holding.reportedBookWeight) }
        : {}),
      ...(holding.proxyWeight != null && Number.isFinite(Number(holding.proxyWeight))
        ? { proxyWeight: Number(holding.proxyWeight) }
        : {}),
      startValue,
      startPrice,
      units: startValue / startPrice
    });
  }

  if (missing.length) {
    return {
      ok: false,
      failure: {
        code: "missing_execution_price",
        date: rebalance.executionDate,
        tickers: missing.map((row) => row.ticker),
        missingWeight: missing.reduce((sum, row) => sum + row.weight, 0)
      }
    };
  }

  const cashWeight = Number.isFinite(explicitCashWeight)
    ? explicitCashWeight
    : Math.max(0, 1 - weightSum);
  if (cashWeight < -reconciliationTolerance || Math.abs(weightSum + cashWeight - 1) > reconciliationTolerance) {
    return {
      ok: false,
      failure: {
        code: "invalid_cash_weight",
        date: rebalance.executionDate,
        weightSum,
        cashWeight
      }
    };
  }

  return {
    ok: true,
    rebalance,
    positions,
    startPortfolioValue: portfolioValue,
    cashValue: portfolioValue * Math.max(0, cashWeight),
    cashWeight: Math.max(0, cashWeight),
    weightSum,
    startDate: rebalance.executionDate
  };
}

export function markPositions(active, date, priceMaps) {
  const missing = [];
  const transitionPending = [];
  const values = [];
  for (const position of active.positions) {
    const action = position.corporateAction;
    const actionEffective = String(action?.effectiveDate || "");
    const cashConversionDate = String(
      action?.publicTradingEndExclusive || actionEffective
    );
    const privateTransitionDate = String(
      action?.publicTradingEndExclusive || actionEffective
    );
    if (
      ["private_equity", "private_equity_rollover"].includes(
        String(action?.considerationType || "")
      ) &&
      privateTransitionDate &&
      date >= privateTransitionDate
    ) {
      missing.push({
        ticker: position.ticker,
        weight: position.weight,
        reason: "private_rollover_not_publicly_replicable",
        publicTradingStatus: "private_after_reported_quarter",
        publicTradingEndExclusive: privateTransitionDate,
        actionId: action?.actionId || null,
        syntheticPriceUsed: false
      });
      continue;
    }
    if (
      action?.considerationType === "cash" &&
      cashConversionDate &&
      date >= cashConversionDate
    ) {
      const terminalCashEntitlementPerShare = finitePositive(
        action.terminalCashEntitlementPerShare
      );
      if (terminalCashEntitlementPerShare == null) {
        missing.push({
          ticker: position.ticker,
          weight: position.weight,
          reason: "invalid_terminal_cash_entitlement"
        });
        continue;
      }
      values.push({
        ...position,
        endPrice: terminalCashEntitlementPerShare,
        endValue: position.units * terminalCashEntitlementPerShare,
        corporateActionResolution: {
          ...action,
          timing: "while_position_active",
          settledOnOrBefore: date
        }
      });
      continue;
    }
    if (actionEffective && date >= actionEffective) {
      if (["stock", "stock_and_cash"].includes(action?.considerationType)) {
        const successorTicker = String(action?.successorTicker || "")
          .trim()
          .toUpperCase();
        const successorSharesPerShare = finitePositive(
          action?.successorSharesPerShare
        );
        const cashEntitlementPerShare = action?.considerationType === "stock_and_cash"
          ? finitePositive(action?.terminalCashEntitlementPerShare)
          : 0;
        const successorFirstTradingDate = String(
          action?.successorFirstTradingDate || actionEffective
        );
        if (date < successorFirstTradingDate) {
          transitionPending.push({
            ticker: position.ticker,
            successorTicker,
            effectiveDate: actionEffective,
            successorFirstTradingDate,
            actionId: action.actionId || null
          });
          continue;
        }
        const successorPrice = finitePositive(
          priceMaps.get(successorTicker)?.get(date)
        );
        if (!successorTicker || successorSharesPerShare == null || successorPrice == null ||
          cashEntitlementPerShare == null) {
          missing.push({
            ticker: position.ticker,
            successorTicker: successorTicker || null,
            weight: position.weight,
            reason: "missing_stock_conversion_successor_price"
          });
          continue;
        }
        const equivalentSourceSharePrice =
          successorPrice * successorSharesPerShare + cashEntitlementPerShare;
        values.push({
          ...position,
          endPrice: equivalentSourceSharePrice,
          endValue: position.units * equivalentSourceSharePrice,
          corporateActionResolution: {
            ...action,
            timing: "while_position_active",
            successorPrice,
            settledOnOrBefore: date
          }
        });
        continue;
      }
    }
    const priceSymbol = holdingPriceSymbol(position);
    const price = finitePositive(priceMaps.get(priceSymbol)?.get(date));
    if (price == null) {
      missing.push({
        ticker: position.ticker,
        ...(priceSymbol !== position.ticker ? { priceSymbol } : {}),
        weight: position.weight
      });
      continue;
    }
    values.push({ ...position, endPrice: price, endValue: position.units * price });
  }
  if (missing.length) {
    return {
      ok: false,
      failure: {
        code: "missing_active_price",
        date,
        tickers: missing.map((row) => row.ticker),
        missingWeight: missing.reduce((sum, row) => sum + row.weight, 0),
        details: missing
      }
    };
  }
  if (transitionPending.length) {
    return {
      ok: true,
      transitionPending,
      portfolioValue: null,
      values: []
    };
  }
  return {
    ok: true,
    values,
    portfolioValue: active.cashValue + values.reduce((sum, row) => sum + row.endValue, 0)
  };
}

function finishInterval(active, marked, endDate, benchmarkPrice, nextExecutionDate) {
  const startPortfolioValue = active.startPortfolioValue;
  const endPortfolioValue = marked.portfolioValue;
  const contributions = marked.values.map((position) => ({
    ticker: position.ticker,
    ...(position.priceSymbol ? { priceSymbol: position.priceSymbol } : {}),
    ...(position.priceSymbolAudit
      ? { priceSymbolAudit: position.priceSymbolAudit }
      : {}),
    issuer: position.issuer,
    sector: position.sector,
    industry: position.industry,
    value: position.disclosedValue,
    weight: position.weight,
    ...(position.corporateActionResolution ? {
      corporateActionResolution: position.corporateActionResolution
    } : {}),
    ...(Number.isFinite(position.reportedBookWeight)
      ? { reportedBookWeight: position.reportedBookWeight }
      : {}),
    ...(Number.isFinite(position.proxyWeight)
      ? { proxyWeight: position.proxyWeight }
      : {}),
    endingWeight: endPortfolioValue > 0 ? position.endValue / endPortfolioValue : 0,
    startPrice: position.startPrice,
    endPrice: position.endPrice,
    returnPct: position.endPrice / position.startPrice - 1,
    contributionPct: (position.endValue - position.startValue) / startPortfolioValue
  }));
  const ranked = [...contributions].sort((left, right) => right.contributionPct - left.contributionPct);
  const aggregateByClassification = (field) => {
    const grouped = new Map();
    for (const contribution of contributions) {
      const label = contribution[field] || "Unclassified";
      const current = grouped.get(label) || {
        label,
        weight: 0,
        endingWeight: 0,
        contributionPct: 0,
        positions: 0
      };
      current.weight += contribution.weight;
      current.endingWeight += contribution.endingWeight;
      current.contributionPct += contribution.contributionPct;
      current.positions += 1;
      grouped.set(label, current);
    }
    return [...grouped.values()].sort((left, right) =>
      right.contributionPct - left.contributionPct || left.label.localeCompare(right.label)
    );
  };
  const sectorContributions = aggregateByClassification("sector");
  const industryContributions = aggregateByClassification("industry");
  const portfolioReturn = endPortfolioValue / startPortfolioValue - 1;
  const contributionReturn = contributions.reduce((sum, row) => sum + row.contributionPct, 0);
  const sectorContributionReturn = sectorContributions.reduce((sum, row) => sum + row.contributionPct, 0);
  const industryContributionReturn = industryContributions.reduce((sum, row) => sum + row.contributionPct, 0);
  const benchmarkReturn = benchmarkPrice / active.startBenchmarkPrice - 1;

  return {
    id: `${active.rebalance.reportDate || active.rebalance.filingDate}-${active.startDate}`,
    label: quarterLabel(active.rebalance.reportDate),
    reportDate: active.rebalance.reportDate,
    filingDate: active.rebalance.filingDate,
    acceptanceDateTime: active.rebalance.acceptanceDateTime || null,
    executionDate: active.startDate,
    executionTimestampSource: active.rebalance.executionTimestampSource || null,
    usedLegacyFilingDateFallback: Boolean(active.rebalance.usedLegacyFilingDateFallback),
    endDate,
    nextExecutionDate: nextExecutionDate || null,
    days: Math.max(0, Math.round((new Date(endDate).getTime() - new Date(active.startDate).getTime()) / dayMs)),
    coveragePct: active.rebalance.coveragePct,
    pricedPositions: active.rebalance.pricedPositions,
    selectedPositions: active.rebalance.selectedPositions,
    cashWeight: active.cashWeight,
    portfolioReturn,
    benchmarkReturn,
    coveredWeight: active.weightSum,
    contributionReturn,
    attributionReconciliation: contributionReturn - portfolioReturn,
    sectorContributionReturn,
    sectorAttributionReconciliation: sectorContributionReturn - portfolioReturn,
    industryContributionReturn,
    industryAttributionReconciliation: industryContributionReturn - portfolioReturn,
    contributions: ranked,
    sectorContributions,
    industryContributions,
    topContributors: ranked.slice(0, 8),
    topDetractors: ranked.slice(-8).reverse()
  };
}

function simulationFailure(failure, partial) {
  return {
    ok: false,
    status: "incomplete_price_coverage",
    failure: {
      ...failure,
      policy: "fail_closed_without_zero_return_or_forward_fill",
      lastCompleteDate: partial.equity.at(-1)?.date || null
    },
    ...partial
  };
}

/**
 * Simulate close-to-close holdings. Target weights are converted to units only
 * at disclosure events; between events, position weights drift with prices.
 * The same interval state produces both the daily equity curve and security
 * contributions, so attribution must reconcile to the headline return.
 */
export function simulateDriftedPortfolio({
  rebalances,
  tradingDates,
  priceMaps,
  benchmarkSymbol = "SPY",
  endDate = null,
  allowExplicitCash = false
}) {
  const orderedRebalances = [...(rebalances || [])]
    .filter((rebalance) => rebalance?.executionDate)
    .sort((left, right) => String(left.executionDate).localeCompare(String(right.executionDate)));
  if (!orderedRebalances.length) {
    return simulationFailure({ code: "no_rebalances", date: null }, {
      equity: [], portfolioReturns: [], benchmarkReturns: [], coverage: [], quarterContributions: []
    });
  }
  const duplicateExecutionDate = orderedRebalances.find((rebalance, index) =>
    index > 0 && rebalance.executionDate === orderedRebalances[index - 1].executionDate
  )?.executionDate;
  if (duplicateExecutionDate) {
    return simulationFailure({
      code: "duplicate_execution_date",
      date: duplicateExecutionDate
    }, {
      equity: [], portfolioReturns: [], benchmarkReturns: [], coverage: [], quarterContributions: []
    });
  }

  const firstDate = orderedRebalances[0].executionDate;
  const dates = [...new Set((tradingDates || [])
    .map((point) => typeof point === "string" ? point : point?.date)
    .filter((date) => date && date >= firstDate && (!endDate || date <= endDate)))]
    .sort();
  const benchmarkMap = priceMaps.get(benchmarkSymbol);
  const firstBenchmarkPrice = finitePositive(benchmarkMap?.get(firstDate));
  if (!dates.length || firstBenchmarkPrice == null) {
    return simulationFailure({ code: "missing_benchmark_start_price", date: firstDate }, {
      equity: [], portfolioReturns: [], benchmarkReturns: [], coverage: [], quarterContributions: []
    });
  }

  let portfolioValue = 1;
  let benchmarkValue = 1;
  let priorBenchmarkPrice = firstBenchmarkPrice;
  let rebalanceIndex = 0;
  let active = allocateAtClose(orderedRebalances[0], portfolioValue, priceMaps, allowExplicitCash);
  if (!active.ok) {
    return simulationFailure(active.failure, {
      equity: [], portfolioReturns: [], benchmarkReturns: [], coverage: [], quarterContributions: []
    });
  }
  active.startBenchmarkPrice = firstBenchmarkPrice;

  const equity = [{ date: firstDate, value: portfolioValue, benchmark: benchmarkValue }];
  const portfolioReturns = [];
  const benchmarkReturns = [];
  const coverage = [];
  const quarterContributions = [];
  const corporateActionTransitionSessions = [];

  for (const date of dates.slice(1)) {
    const benchmarkPrice = finitePositive(benchmarkMap?.get(date));
    if (benchmarkPrice == null) {
      return simulationFailure({ code: "missing_benchmark_price", date }, {
        equity, portfolioReturns, benchmarkReturns, coverage, quarterContributions
      });
    }
    const marked = markPositions(active, date, priceMaps);
    if (!marked.ok) {
      return simulationFailure(marked.failure, {
        equity, portfolioReturns, benchmarkReturns, coverage, quarterContributions
      });
    }
    if (marked.transitionPending?.length) {
      corporateActionTransitionSessions.push({
        date,
        actions: marked.transitionPending
      });
      continue;
    }

    const dailyPortfolioReturn = marked.portfolioValue / portfolioValue - 1;
    const dailyBenchmarkReturn = benchmarkPrice / priorBenchmarkPrice - 1;
    portfolioValue = marked.portfolioValue;
    benchmarkValue *= 1 + dailyBenchmarkReturn;
    priorBenchmarkPrice = benchmarkPrice;
    portfolioReturns.push(dailyPortfolioReturn);
    benchmarkReturns.push(dailyBenchmarkReturn);
    coverage.push(active.rebalance.coveragePct ?? active.weightSum);
    equity.push({ date, value: portfolioValue, benchmark: benchmarkValue });

    while (
      rebalanceIndex + 1 < orderedRebalances.length &&
      orderedRebalances[rebalanceIndex + 1].executionDate <= date
    ) {
      const nextRebalance = orderedRebalances[rebalanceIndex + 1];
      quarterContributions.push(
        finishInterval(active, marked, date, benchmarkPrice, nextRebalance.executionDate)
      );
      rebalanceIndex += 1;
      active = allocateAtClose(nextRebalance, portfolioValue, priceMaps, allowExplicitCash);
      if (!active.ok) {
        return simulationFailure(active.failure, {
          equity, portfolioReturns, benchmarkReturns, coverage, quarterContributions
        });
      }
      active.startBenchmarkPrice = benchmarkPrice;
    }
  }

  const finalDate = equity.at(-1)?.date || firstDate;
  const finalBenchmarkPrice = finitePositive(benchmarkMap?.get(finalDate));
  const finalMarked = markPositions(active, finalDate, priceMaps);
  if (!finalMarked.ok || finalMarked.transitionPending?.length || finalBenchmarkPrice == null) {
    return simulationFailure(finalMarked.failure || {
      code: finalMarked.transitionPending?.length
        ? "corporate_action_transition_unresolved"
        : "missing_benchmark_price",
      date: finalDate,
      actions: finalMarked.transitionPending || []
    }, {
      equity,
      portfolioReturns,
      benchmarkReturns,
      coverage,
      quarterContributions,
      corporateActionTransitionSessions
    });
  }
  quarterContributions.push(
    finishInterval(active, finalMarked, finalDate, finalBenchmarkPrice, null)
  );

  const headlineTotalReturn = equity.at(-1).value / equity[0].value - 1;
  const attributionTotalReturn = quarterContributions.reduce(
    (growth, quarter) => growth * (1 + quarter.portfolioReturn),
    1
  ) - 1;
  const reconciliationDifference = attributionTotalReturn - headlineTotalReturn;

  return {
    ok: Math.abs(reconciliationDifference) <= reconciliationTolerance &&
      quarterContributions.every((quarter) =>
        Math.abs(quarter.attributionReconciliation) <= reconciliationTolerance &&
        Math.abs(quarter.sectorAttributionReconciliation) <= reconciliationTolerance &&
        Math.abs(quarter.industryAttributionReconciliation) <= reconciliationTolerance
      ),
    status: "ready",
    equity,
    portfolioReturns,
    benchmarkReturns,
    coverage,
    quarterContributions,
    corporateActionTransitionSessions,
    reconciliation: {
      headlineTotalReturn,
      attributionTotalReturn,
      difference: reconciliationDifference,
      tolerance: reconciliationTolerance
    }
  };
}
