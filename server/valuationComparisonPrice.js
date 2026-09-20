/**
 * Comparison-only prices. Never pass this output into fair-value inputs.
 *
 * Sharadar close is split-adjusted, excluding cash dividends and spin-offs.
 * References: https://sharadar.com/docs/stocks and
 * https://blog.sharadar.com/2026/07/sharadar-stock-prices-fund-prices-and.html
 *
 * A price date is a trading date, not the vintage of retrospective adjustments.
 * These helpers do not rescale prices, infer splits from share counts, convert
 * .L quotes to pence, modify source data, or loosen numerical tolerances.
 */
export const VALUATION_COMPARISON_PRICE_VERSION = "source-field-basis-v1";

const SHARADAR_CLOSE = Object.freeze({
  provider: "sharadar", field: "close",
  basis: "split_adjusted_ex_cash_dividends_and_spinoffs",
  unit: "currency_per_share",
  documentationUrl: "https://sharadar.com/docs/stocks"
});
// Exact, reviewed source identifiers: no substring guesses or arbitrary
// `audited:*` acceptance. The repair builder maps close -> close, not closeadj.
const SOURCE_CONTRACTS = Object.freeze({
  "jansen-sharadar-sep-split-adjusted": SHARADAR_CLOSE,
  "sharadar-paid-api-split-adjusted": SHARADAR_CLOSE,
  "sharadar_fact_os_sep": SHARADAR_CLOSE,
  "sharadar_fact_os_sfp": SHARADAR_CLOSE,
  "audited:sharadar-paid-api": SHARADAR_CLOSE,
  "audited-series:sharadar-sep": SHARADAR_CLOSE
});
const STORAGE_PRIORITY = Object.freeze({
  original_vendor: 0, released_snapshot: 1, pit_observation: 2, raw_price_point: 3
});

export function valuationComparisonPriceContract(source) {
  return typeof source === "string" && Object.hasOwn(SOURCE_CONTRACTS, source)
    ? { source, ...SOURCE_CONTRACTS[source] } : null;
}

export function comparisonPricesEqual(actual, expected) {
  return Number.isFinite(actual) && Number.isFinite(expected)
    && Math.abs(actual - expected) <= 1e-7 * Math.max(1, Math.abs(actual), Math.abs(expected));
}

function validDate(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)
    && Number.isFinite(Date.parse(value))
    && new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;
}
function fail(reason, details = {}) {
  return { status: "blocked", reason, contractVersion: VALUATION_COMPARISON_PRICE_VERSION, ...details };
}
function sameSeries(left, right) {
  return left.provider === right.provider && left.field === right.field && left.basis === right.basis;
}
function scopeError(candidate, request) {
  if (candidate.kind !== "pit_observation") return null;
  for (const key of ["ticker", "fiscalPeriod", "modelVersion"]) {
    if (!request[key] || !candidate[key] || request[key] !== candidate[key]) return `pit_${key}_mismatch`;
  }
  return null;
}

/**
 * Resolve expected price WITHOUT receiving a model price. The declared source
 * comes from asOfPriceSource, corroborated by real rows, not from a snapshot's
 * mutable top-level priceSource. Every candidate must name its exact field,
 * unit, symbol, currency and storage kind. Caller must extract source fields;
 * never copy the model's numerical output into an evidence candidate.
 *
 * At least one actual row from the declared source is required. Equivalent
 * Sharadar ingestion paths corroborate but cannot manufacture that provenance.
 * Incompatible series are disclosed, not averaged or compared as the same price.
 */
export function resolveValuationComparisonPrice(request = {}) {
  const { asOfDate, priceDate, priceSymbol, quoteCurrency, declaredSource, candidates } = request;
  if (!validDate(asOfDate) || !validDate(priceDate)) return fail("invalid_price_date");
  if (priceDate > asOfDate) return fail("future_price_date");
  if (typeof priceSymbol !== "string" || !priceSymbol.trim()) return fail("missing_price_symbol");
  if (!/^[A-Z]{3}$/.test(quoteCurrency || "") || quoteCurrency === "GBX") return fail("invalid_quote_currency");
  const declaredContract = valuationComparisonPriceContract(declaredSource);
  if (!declaredContract) return fail("unverified_declared_price_source", { declaredSource });
  if (!Array.isArray(candidates)) return fail("missing_price_evidence");
  const excluded = [];
  const eligible = [];
  for (const candidate of candidates) {
    if (!candidate || candidate.date !== priceDate || candidate.priceSymbol !== priceSymbol) continue;
    const id = String(candidate.id || "");
    const contract = valuationComparisonPriceContract(candidate.source);
    const reason = !contract ? "unverified_candidate_source"
      : !sameSeries(contract, declaredContract) ? "different_provider_field_or_adjustment_basis"
      : scopeError(candidate, request);
    if (reason) {
      excluded.push({ id, source: candidate.source ?? null, reason, basis: contract?.basis ?? null });
      continue;
    }
    if (!Object.hasOwn(STORAGE_PRIORITY, candidate.kind)) return fail("unverified_price_storage_kind", { id });
    if (candidate.sourceField !== contract.field) return fail("price_source_field_mismatch", { id });
    if (candidate.unit !== contract.unit) return fail("price_unit_mismatch", { id });
    if (candidate.quoteCurrency !== quoteCurrency) return fail("price_currency_mismatch", { id });
    if (!(Number.isFinite(candidate.close) && candidate.close > 0)) return fail("invalid_source_price", { id });
    if (candidate.payloadSource && candidate.payloadSource !== candidate.source) return fail("price_payload_source_mismatch", { id });
    eligible.push({ ...candidate, contract });
  }
  if (!eligible.some((candidate) => candidate.source === declaredSource)) {
    return fail("declared_price_source_unreconciled", { declaredSource, excluded });
  }
  eligible.sort((a, b) => STORAGE_PRIORITY[a.kind] - STORAGE_PRIORITY[b.kind]
    || String(a.id || "").localeCompare(String(b.id || "")));
  const selected = eligible[0];
  // Compare all pairs, not only the preferred row: otherwise three values could
  // straddle the fixed tolerance while disagreeing with one another.
  for (let i = 0; i < eligible.length; i += 1) {
    for (let j = i + 1; j < eligible.length; j += 1) {
      if (!comparisonPricesEqual(eligible[i].close, eligible[j].close)) {
        return fail("same_series_price_conflict", {
          conflictingEvidence: [eligible[i], eligible[j]], excluded
        });
      }
    }
  }
  return {
    status: "ready", contractVersion: VALUATION_COMPARISON_PRICE_VERSION,
    priceSymbol, priceDate, quoteCurrency, expectedPrice: selected.close,
    declaredSource, selectedEvidenceId: selected.id, selectedEvidenceKind: selected.kind,
    sourceContract: declaredContract,
    evidence: eligible.map(({ contract, ...candidate }) => candidate), excluded,
    comparisonOnly: true, priceExcludedFromFairValue: true,
    warning: null
  };
}

export function auditValuationComparisonPrice({ outputPrice, ...request } = {}) {
  const expected = resolveValuationComparisonPrice(request);
  if (expected.status !== "ready") return expected;
  if (!(Number.isFinite(outputPrice) && outputPrice > 0)) return fail("invalid_output_price", { expected });
  if (!comparisonPricesEqual(outputPrice, expected.expectedPrice)) {
    return fail("stored_market_price_unit_mismatch", { outputPrice, expectedPrice: expected.expectedPrice, expected });
  }
  return { ...expected, outputPrice, audited: true };
}

/**
 * New-import selection requires an explicit Sharadar series policy and maximum
 * price age. Unsupported providers fail closed.
 */
export function selectValuationComparisonPrice(request = {}) {
  const { candidates, asOfDate, priceSymbol, quoteCurrency, policy, maxAgeCalendarDays } = request;
  if (!validDate(asOfDate)) return fail("invalid_price_date");
  if (!Number.isInteger(maxAgeCalendarDays) || maxAgeCalendarDays < 0) return fail("missing_explicit_maximum_price_age");
  if (policy?.mode !== "prefer_sharadar_split_only") return fail("missing_explicit_price_policy");
  const explicitContract = policy.mode === "declared_provider_close"
    ? valuationComparisonPriceContract(policy.source) : null;
  if (policy.mode === "declared_provider_close" && !explicitContract) return fail("unverified_declared_price_source");
  const eligible = (Array.isArray(candidates) ? candidates : []).filter((candidate) => {
    const contract = valuationComparisonPriceContract(candidate?.source);
    return contract && candidate.priceSymbol === priceSymbol && validDate(candidate.date)
      && candidate.date <= asOfDate && !scopeError(candidate, request)
      && (explicitContract ? sameSeries(contract, explicitContract) : contract.provider === "sharadar");
  });
  if (!eligible.length) return fail("no_price_for_explicit_policy");
  const priceDate = eligible.map((candidate) => candidate.date).sort().at(-1);
  const ageCalendarDays = Math.round((Date.parse(asOfDate) - Date.parse(priceDate)) / 86_400_000);
  if (ageCalendarDays > maxAgeCalendarDays) return fail("stale_comparison_price", { priceDate, ageCalendarDays });
  const preferred = eligible.filter((candidate) => candidate.date === priceDate)
    .sort((a, b) => (STORAGE_PRIORITY[a.kind] ?? 99) - (STORAGE_PRIORITY[b.kind] ?? 99)
      || String(a.source).localeCompare(String(b.source)) || String(a.id || "").localeCompare(String(b.id || "")))[0];
  const resolved = resolveValuationComparisonPrice({
    ...request, priceDate, priceSymbol, quoteCurrency,
    declaredSource: policy.mode === "declared_provider_close" ? policy.source : preferred.source
  });
  return resolved.status === "ready" ? { ...resolved, selectionPolicy: { ...policy }, ageCalendarDays } : resolved;
}

/** Preserve point-level provenance when combining a released comparison
 * history with raw storage. An unrelated provider cannot overwrite a paid
 * split-only observation just because its row was read last. This is not a
 * total-return series and must never be used for Guru backtest returns.
 */
export function mergeValuationComparisonHistory({ existing = [], incremental = [], priceSymbol, quoteCurrency } = {}) {
  const byDate = new Map();
  for (const [kind, points] of [["released_snapshot", existing], ["raw_price_point", incremental]]) {
    for (const [index, point] of points.entries()) {
      if (!validDate(point?.date) || !(Number.isFinite(point?.close) && point.close > 0)) {
        throw new Error(`Invalid comparison-price observation: ${priceSymbol}/${point?.date}`);
      }
      const candidate = { ...point, priceSymbol, quoteCurrency, sourceField: "close", unit: "currency_per_share", kind, id: `${kind}:${index}` };
      if (!valuationComparisonPriceContract(candidate.source)) throw new Error(`Unverified comparison-price source: ${priceSymbol}/${candidate.source}`);
      if (!byDate.has(point.date)) byDate.set(point.date, []);
      byDate.get(point.date).push(candidate);
    }
  }
  return [...byDate.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([date, candidates]) => {
    const hasPaid = candidates.some((point) => valuationComparisonPriceContract(point.source).provider === "sharadar");
    if (!hasPaid) throw new Error(`No paid comparison-price source: ${priceSymbol}/${date}`);
    const resolved = selectValuationComparisonPrice({
      asOfDate: date, priceSymbol, quoteCurrency, candidates, maxAgeCalendarDays: 0,
      policy: { mode: "prefer_sharadar_split_only" }
    });
    if (resolved.status !== "ready") throw new Error(`Comparison-price merge blocked: ${priceSymbol}/${date}/${resolved.reason}`);
    const selected = candidates.find((point) => point.id === resolved.selectedEvidenceId);
    const { kind, id, priceSymbol: _symbol, quoteCurrency: _currency, sourceField, unit, ...point } = selected;
    return point;
  });
}
