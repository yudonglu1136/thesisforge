const ALLOWED_STATES = new Set(["covered", "annual_only", "derived"]);
const DIMENSIONS = new Set(["ARQ", "ART"]);
const TICKER = /^[A-Z0-9][A-Z0-9.^-]{0,19}$/;

// This is an explicit existing instrument exception, not a general escape
// hatch for missing issuer financials or unreviewed Guru securities.
export const DERIVED_FINANCIAL_COVERAGE = Object.freeze({
  RKLX: Object.freeze({ sourceTicker: "RKLB", reason: "Derived ETF; no issuer financial statement model." })
});
export const LEGACY_FINANCIAL_COVERAGE_POLICY = Object.freeze({
  tickerCount: 533,
  annualOnlyTickers: Object.freeze(["BA.L", "LSEG"]),
  statusCounts: Object.freeze({ annual_only: 2, covered: 530, derived: 1 })
});

function ticker(value) { return String(value || "").trim().toUpperCase(); }
function object(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  if (typeof value !== "string") return {};
  try { return object(JSON.parse(value)); } catch { return {}; }
}
function validDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))) return false;
  return !Number.isNaN(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
}
function nonnegativeInteger(value) { return typeof value === "number" && Number.isInteger(value) && value >= 0; }
function finite(value) { return value != null && value !== "" && typeof value !== "boolean" && Number.isFinite(Number(value)); }
function sorted(values) { return [...values].sort(); }
function counts(rows) {
  const result = {};
  for (const row of rows) result[row.status] = (result[row.status] || 0) + 1;
  return Object.fromEntries(Object.entries(result).sort(([a], [b]) => a.localeCompare(b)));
}

/** Persist source declarations without inventing a review or source identity.
 * Unsupported states are retained so diagnostic imports can report blockers;
 * the release auditor independently rejects them.
 */
export function financialCoverageLedger(sourceRows) {
  const issuers = [...sourceRows].map((row) => ({
    ticker: ticker(row.ticker), sourceTicker: row.source_ticker == null ? null : ticker(row.source_ticker),
    status: String(row.status || ""),
    arqPeriods: row.arq_periods == null ? null : Number(row.arq_periods),
    artPeriods: row.art_periods == null ? null : Number(row.art_periods),
    firstAvailableAt: row.first_available_at || null, lastAvailableAt: row.last_available_at || null,
    note: row.note || null
  })).sort((a, b) => a.ticker.localeCompare(b.ticker));
  return { schemaVersion: 1, basis: "pit_financial_coverage", issuers };
}

function summarizeRawFinancials(rows, failures, label) {
  const byTicker = new Map();
  let rowCount = 0;
  for (const row of rows || []) {
    rowCount += 1;
    const symbol = ticker(row.ticker);
    const sourceTicker = ticker(row.source_ticker);
    const dimension = String(row.dimension || "");
    const period = String(row.fiscal_period || "");
    const availableAt = String(row.available_at || "");
    const payload = object(row.payload_json);
    if (!byTicker.has(symbol)) byTicker.set(symbol, {
      ticker: symbol, sourceTickers: new Set(), arqPeriods: 0, artPeriods: 0,
      arqCorePeriods: 0, artCorePeriods: 0, firstAvailableAt: null, lastAvailableAt: null, periods: new Map()
    });
    const item = byTicker.get(symbol);
    item.sourceTickers.add(sourceTicker);
    if (!TICKER.test(symbol) || !TICKER.test(sourceTicker)) failures.push({ code: `${label}_financial_raw_identity_invalid`, ticker: symbol, sourceTicker });
    if (!DIMENSIONS.has(dimension)) failures.push({ code: `${label}_financial_dimension_not_pit`, ticker: symbol, dimension, period });
    if (!/^20\d{2}-Q[1-4]$/.test(period) || !validDate(availableAt)) failures.push({ code: `${label}_financial_temporal_identity_invalid`, ticker: symbol, dimension, period, availableAt });
    const key = `${period}::${dimension}`;
    if (item.periods.has(key)) failures.push({ code: `${label}_financial_period_duplicate`, ticker: symbol, period, dimension });
    const hasCore = [payload.revenue_m, payload.net_income_m, payload.cfo_m].some(finite);
    const explicitTrailing = dimension === "ART" && payload.sourceDimension === "ART" && payload.sourceRecord?.metricsAreTrailingTwelveMonths === true;
    item.periods.set(key, { availableAt, sourceTicker, hasCore, explicitTrailing });
    if (dimension === "ARQ") item.arqPeriods += 1;
    if (dimension === "ART") item.artPeriods += 1;
    if (dimension === "ARQ" && hasCore) item.arqCorePeriods += 1;
    if (dimension === "ART" && hasCore) item.artCorePeriods += 1;
    if (validDate(availableAt)) {
      item.firstAvailableAt = !item.firstAvailableAt || availableAt < item.firstAvailableAt ? availableAt : item.firstAvailableAt;
      item.lastAvailableAt = !item.lastAvailableAt || availableAt > item.lastAvailableAt ? availableAt : item.lastAvailableAt;
    }
  }
  for (const item of byTicker.values()) {
    item.artBackedArqPeriods = [];
    item.unbackedArqPeriods = [];
    for (const [key, arq] of item.periods) {
      if (!key.endsWith("::ARQ") || arq.hasCore) continue;
      const period = key.slice(0, -5);
      const art = item.periods.get(`${period}::ART`);
      if (art?.hasCore && art.explicitTrailing && art.sourceTicker === arq.sourceTicker) item.artBackedArqPeriods.push({
        fiscalPeriod: period, sourceTicker: art.sourceTicker,
        arqAvailableAt: arq.availableAt, artAvailableAt: art.availableAt,
        basis: "same_period_explicit_trailing_art_core"
      });
      else item.unbackedArqPeriods.push(period);
    }
  }
  return { byTicker, rowCount };
}

function ledgerRows(ledger, failures, label) {
  if (!ledger || ledger.schemaVersion !== 1 || ledger.basis !== "pit_financial_coverage" || !Array.isArray(ledger.issuers)) {
    failures.push({ code: `${label}_financial_coverage_ledger_missing_or_invalid` });
    return [];
  }
  return ledger.issuers;
}

function inspectIssuerLedger(rows, raw, required, failures, label) {
  const byTicker = new Map();
  for (const row of rows) {
    const symbol = ticker(row?.ticker);
    if (byTicker.has(symbol)) failures.push({ code: `${label}_financial_coverage_duplicate_ticker`, ticker: symbol });
    byTicker.set(symbol, row);
    if (!TICKER.test(symbol) || row.ticker !== symbol) failures.push({ code: `${label}_financial_coverage_ticker_invalid`, ticker: row.ticker });
    if (!required.has(symbol)) failures.push({ code: `${label}_financial_coverage_unexpected_ticker`, ticker: symbol });
    if (!ALLOWED_STATES.has(row.status)) failures.push({ code: `${label}_financial_coverage_state_invalid`, ticker: symbol, status: row.status });
    if (!nonnegativeInteger(row.arqPeriods) || !nonnegativeInteger(row.artPeriods)) failures.push({ code: `${label}_financial_coverage_count_invalid`, ticker: symbol });
    const financials = raw.byTicker.get(symbol);
    if (row.status === "derived") {
      const exception = DERIVED_FINANCIAL_COVERAGE[symbol];
      if (!exception || row.sourceTicker !== exception.sourceTicker || !String(row.note || "").trim()) failures.push({ code: `${label}_unapproved_derived_financial_coverage`, ticker: symbol, sourceTicker: row.sourceTicker });
      if (financials || row.arqPeriods !== 0 || row.artPeriods !== 0 || row.firstAvailableAt != null || row.lastAvailableAt != null) failures.push({ code: `${label}_derived_financial_coverage_has_issuer_rows`, ticker: symbol });
      continue;
    }
    if (DERIVED_FINANCIAL_COVERAGE[symbol]) failures.push({ code: `${label}_derived_instrument_misclassified`, ticker: symbol, status: row.status });
    if (!financials) {
      failures.push({ code: `${label}_financial_coverage_without_raw_rows`, ticker: symbol, status: row.status });
      continue;
    }
    if (!TICKER.test(String(row.sourceTicker || "")) || financials.sourceTickers.size !== 1 || !financials.sourceTickers.has(row.sourceTicker)) failures.push({ code: `${label}_financial_source_ticker_mismatch`, ticker: symbol, declared: row.sourceTicker, raw: sorted(financials.sourceTickers) });
    for (const field of ["arqPeriods", "artPeriods", "firstAvailableAt", "lastAvailableAt"]) if (row[field] !== financials[field]) failures.push({ code: `${label}_financial_coverage_raw_mismatch`, ticker: symbol, field, declared: row[field], raw: financials[field] });
    // Some foreign issuers supply ARQ balance/share metadata and place the
    // actual financial flows in same-period ART rows. This is the existing
    // per-period model fallback, never permission to annualize ART again.
    if (row.status === "covered" && !(financials.arqCorePeriods > 0 || financials.artBackedArqPeriods.length > 0)) failures.push({ code: `${label}_covered_issuer_without_periodic_core_basis`, ticker: symbol });
    if (row.status === "annual_only" && (financials.arqPeriods !== 0 || !(financials.artCorePeriods > 0))) failures.push({ code: `${label}_annual_only_dimension_mismatch`, ticker: symbol });
  }
  for (const symbol of required) if (!byTicker.has(symbol)) failures.push({ code: `${label}_financial_coverage_missing_ticker`, ticker: symbol });
  for (const symbol of raw.byTicker.keys()) if (!required.has(symbol) || !byTicker.has(symbol)) failures.push({ code: `${label}_unlisted_raw_financial_ticker`, ticker: symbol });
  return byTicker;
}

function inspectDispositions(dispositions, ledger, failures, label, { modelCounts = null } = {}) {
  const seen = new Set();
  for (const row of dispositions || []) {
    const symbol = ticker(row.ticker);
    if (seen.has(symbol)) failures.push({ code: `${label}_snapshot_disposition_duplicate`, ticker: symbol });
    seen.add(symbol);
    const item = ledger.get(symbol);
    if (!item) failures.push({ code: `${label}_snapshot_disposition_unlisted`, ticker: symbol });
    const notApplicable = row.valuation_status === "not_applicable";
    if (notApplicable !== (item?.status === "derived")) failures.push({ code: `${label}_financial_snapshot_disposition_mismatch`, ticker: symbol, status: item?.status, valuationStatus: row.valuation_status });
    if (item?.status === "derived" && (!(row.derived_instrument === true || row.derived_instrument === 1) || ticker(row.source_ticker) !== item.sourceTicker)) failures.push({ code: `${label}_derived_snapshot_evidence_missing`, ticker: symbol });
    if (modelCounts) {
      const count = Number(modelCounts.get(symbol) || 0);
      if (item?.status === "derived" ? count !== 0 : !(count > 0)) failures.push({ code: `${label}_financial_model_presence_mismatch`, ticker: symbol, status: item?.status, modelRows: count });
    }
  }
  for (const symbol of ledger.keys()) if (!seen.has(symbol)) failures.push({ code: `${label}_financial_snapshot_missing`, ticker: symbol });
}

/** Pure, independently testable per-issuer coverage reconciliation. */
export function auditFinancialCoverageRelease({
  requiredTickers, ledger, financialRows, snapshotDispositions, modelCounts,
  declaredSummary, baselineTickers, baselineLedger = null, baselineFinancialRows = null,
  baselineSnapshotDispositions = []
}) {
  const failures = [];
  const required = new Set([...requiredTickers].map(ticker));
  const retained = new Set([...baselineTickers].map(ticker));
  const rows = ledgerRows(ledger, failures, "candidate");
  const raw = summarizeRawFinancials(financialRows, failures, "candidate");
  const current = inspectIssuerLedger(rows, raw, required, failures, "candidate");
  inspectDispositions(snapshotDispositions, current, failures, "candidate", { modelCounts });
  const statusCounts = counts(rows);
  const summary = Object.fromEntries(Object.entries(declaredSummary || {}).sort(([a], [b]) => a.localeCompare(b)));
  if (JSON.stringify(summary) !== JSON.stringify(statusCounts)) failures.push({ code: "candidate_financial_coverage_summary_mismatch", declared: summary, ledger: statusCounts });

  let baselineEvidenceMode;
  let previous;
  let baselineRaw = null;
  if (baselineFinancialRows !== null) {
    baselineRaw = summarizeRawFinancials(baselineFinancialRows, failures, "baseline");
    let previousRows;
    if (baselineLedger) {
      baselineEvidenceMode = "persisted_ledger_reconciled_to_raw_dimensions";
      previousRows = ledgerRows(baselineLedger, failures, "baseline");
    } else {
      baselineEvidenceMode = "independent_raw_dimensions_no_review_inferred";
      previousRows = [...retained].map((symbol) => {
        const financials = baselineRaw.byTicker.get(symbol);
        const exception = DERIVED_FINANCIAL_COVERAGE[symbol];
        if (!financials && exception) return { ticker: symbol, sourceTicker: exception.sourceTicker, status: "derived", arqPeriods: 0, artPeriods: 0, firstAvailableAt: null, lastAvailableAt: null, note: exception.reason };
        return {
          ticker: symbol, sourceTicker: financials?.sourceTickers.size === 1 ? [...financials.sourceTickers][0] : null,
          status: financials?.arqPeriods > 0 ? "covered" : financials?.artPeriods > 0 ? "annual_only" : "unverifiable",
          arqPeriods: financials?.arqPeriods ?? 0, artPeriods: financials?.artPeriods ?? 0,
          firstAvailableAt: financials?.firstAvailableAt ?? null, lastAvailableAt: financials?.lastAvailableAt ?? null, note: null
        };
      });
    }
    previous = inspectIssuerLedger(previousRows, baselineRaw, retained, failures, "baseline");
    inspectDispositions(baselineSnapshotDispositions, previous, failures, "baseline");
  } else {
    // The pre-ledger/pre-PIT database cannot supply invented review records.
    // Preserve the explicit old 533-issuer policy as a minimum, by ticker, not
    // merely its 530+2+1 total. Any different legacy population needs evidence.
    baselineEvidenceMode = "legacy_533_contract_no_historical_review_claim";
    const expectedSpecials = [...LEGACY_FINANCIAL_COVERAGE_POLICY.annualOnlyTickers, ...Object.keys(DERIVED_FINANCIAL_COVERAGE)];
    if (baselineLedger || retained.size !== LEGACY_FINANCIAL_COVERAGE_POLICY.tickerCount || expectedSpecials.some((symbol) => !retained.has(symbol))) failures.push({ code: "legacy_baseline_financial_coverage_unverifiable", baselineTickers: retained.size, requiredSpecials: expectedSpecials });
    previous = new Map([...retained].map((symbol) => [symbol, {
      ticker: symbol,
      status: DERIVED_FINANCIAL_COVERAGE[symbol] ? "derived" : LEGACY_FINANCIAL_COVERAGE_POLICY.annualOnlyTickers.includes(symbol) ? "annual_only" : "covered"
    }]));
    if (JSON.stringify(counts(previous.values())) !== JSON.stringify(LEGACY_FINANCIAL_COVERAGE_POLICY.statusCounts)) failures.push({ code: "legacy_baseline_financial_coverage_guard_failed", counts: counts(previous.values()) });
  }

  let retainedPeriodChecks = 0;
  for (const symbol of retained) {
    const before = previous.get(symbol);
    const after = current.get(symbol);
    if (!required.has(symbol) || !after) { failures.push({ code: "retained_financial_issuer_missing", ticker: symbol }); continue; }
    const regressed = before?.status === "covered" && after.status !== "covered" ||
      before?.status === "annual_only" && !["annual_only", "covered"].includes(after.status) ||
      before?.status === "derived" && after.status !== "derived";
    if (regressed) failures.push({ code: "retained_financial_coverage_regressed", ticker: symbol, before: before.status, after: after.status });
    if (before?.sourceTicker && before.sourceTicker !== after.sourceTicker) failures.push({ code: "retained_financial_source_identity_changed", ticker: symbol, before: before.sourceTicker, after: after.sourceTicker });
    const previousRaw = baselineRaw?.byTicker.get(symbol);
    const currentRaw = raw.byTicker.get(symbol);
    if (!previousRaw) continue;
    for (const [key, previousPeriod] of previousRaw.periods) {
      retainedPeriodChecks += 1;
      const currentPeriod = currentRaw?.periods.get(key);
      if (!currentPeriod) failures.push({ code: "retained_financial_period_missing", ticker: symbol, periodDimension: key });
      else if (currentPeriod.sourceTicker !== previousPeriod.sourceTicker || currentPeriod.availableAt > previousPeriod.availableAt) failures.push({ code: "retained_financial_period_lineage_regressed", ticker: symbol, periodDimension: key, before: previousPeriod, after: currentPeriod });
    }
    if (currentRaw && (currentRaw.firstAvailableAt > previousRaw.firstAvailableAt || currentRaw.lastAvailableAt < previousRaw.lastAvailableAt)) failures.push({ code: "retained_financial_date_coverage_regressed", ticker: symbol, before: [previousRaw.firstAvailableAt, previousRaw.lastAvailableAt], after: [currentRaw.firstAvailableAt, currentRaw.lastAvailableAt] });
  }
  return {
    requiredTickers: sorted(required), retainedTickers: sorted(retained), addedTickers: sorted([...required].filter((symbol) => !retained.has(symbol))),
    statusCounts, rawFinancialRows: raw.rowCount, rawFinancialTickers: raw.byTicker.size,
    baselineEvidenceMode, retainedPeriodChecks,
    derivedExceptions: rows.filter((row) => row.status === "derived"),
    issuerReconciliation: rows.map((row) => {
      const financials = raw.byTicker.get(row.ticker);
      return {
        ...row, rawArqCorePeriods: financials?.arqCorePeriods || 0, rawArtCorePeriods: financials?.artCorePeriods || 0,
        financialCoreBasis: row.status === "derived" ? "explicit_derived_not_applicable" : row.status === "annual_only" ? "art_only_trailing_core" : financials?.arqCorePeriods > 0 ? "quarterly_arq_core" : "arq_metadata_with_same_period_art_core",
        artBackedArqPeriods: financials?.artBackedArqPeriods || [],
        // These are preserved, not declared modelable here. The mandatory
        // unmodeled-period audit must account for each absent model node.
        unbackedArqPeriodsRequiringModelabilityAudit: financials?.unbackedArqPeriods || []
      };
    }),
    failures
  };
}
