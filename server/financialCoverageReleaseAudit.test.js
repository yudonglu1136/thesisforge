import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {
  auditFinancialCoverageRelease,
  financialCoverageLedger,
  LEGACY_FINANCIAL_COVERAGE_POLICY
} from "./financialCoverageReleaseAudit.js";

function raw(ticker, dimension = "ARQ", period = "2025-Q4", availableAt = "2026-02-01", overrides = {}) {
  return { ticker, source_ticker: ticker, dimension, fiscal_period: period, available_at: availableAt, payload_json: JSON.stringify({ revenue_m: 100, net_income_m: 10, cfo_m: 12 }), ...overrides };
}

function coverageRow(ticker, rows, overrides = {}) {
  const selected = rows.filter((row) => row.ticker === ticker);
  const arq = selected.filter((row) => row.dimension === "ARQ").length;
  const art = selected.filter((row) => row.dimension === "ART").length;
  const available = selected.map((row) => row.available_at).sort();
  return { ticker, source_ticker: ticker === "RKLX" ? "RKLB" : ticker, status: ticker === "RKLX" ? "derived" : arq ? "covered" : "annual_only", arq_periods: arq, art_periods: art, first_available_at: available[0] || null, last_available_at: available.at(-1) || null, note: ticker === "RKLX" ? "Derived ETF; no issuer financial statement model." : null, ...overrides };
}

function disposition(ticker) {
  return { ticker, valuation_status: ticker === "RKLX" ? "not_applicable" : null, derived_instrument: ticker === "RKLX" ? 1 : null, source_ticker: ticker === "RKLX" ? "RKLB" : null };
}

function summary(rows) {
  const result = {};
  for (const row of rows) result[row.status] = (result[row.status] || 0) + 1;
  return result;
}

function fixture(overrides = {}) {
  const baselineTickers = ["AAA", "BA.L", "RKLX"];
  const requiredTickers = [...baselineTickers, "NEW"];
  const baselineFinancialRows = [raw("AAA"), raw("AAA", "ART"), raw("BA.L", "ART")];
  const financialRows = [...baselineFinancialRows, raw("NEW")];
  const coverage = requiredTickers.map((symbol) => coverageRow(symbol, financialRows));
  return {
    requiredTickers, baselineTickers, baselineFinancialRows, financialRows,
    ledger: financialCoverageLedger(coverage), declaredSummary: summary(coverage),
    snapshotDispositions: requiredTickers.map(disposition), baselineSnapshotDispositions: baselineTickers.map(disposition),
    modelCounts: new Map(requiredTickers.map((symbol) => [symbol, symbol === "RKLX" ? 0 : 1])),
    ...overrides
  };
}

function codes(result) { return result.failures.map((row) => row.code); }

function legacyFixture() {
  const symbols = [...Array.from({ length: 530 }, (_, index) => `OLD${index}`), "BA.L", "LSEG", "RKLX"];
  const financialRows = symbols.filter((symbol) => symbol !== "RKLX").map((symbol) => raw(symbol, ["BA.L", "LSEG"].includes(symbol) ? "ART" : "ARQ"));
  const coverage = symbols.map((symbol) => coverageRow(symbol, financialRows));
  return { requiredTickers: [...symbols, "NEW"], baselineTickers: symbols, baselineFinancialRows: null, financialRows: [...financialRows, raw("NEW")], ledger: financialCoverageLedger([...coverage, coverageRow("NEW", [raw("NEW")])]), declaredSummary: { annual_only: 2, covered: 531, derived: 1 }, snapshotDispositions: [...symbols, "NEW"].map(disposition), modelCounts: new Map([...symbols, "NEW"].map((symbol) => [symbol, symbol === "RKLX" ? 0 : 1])) };
}

function artBackedFixture() {
  const fixture = JSON.parse(fs.readFileSync(new URL("./fixtures/art-backed-quarterly-coverage.json", import.meta.url), "utf8"));
  const financialRows = fixture.rows.map(({ payload, ...row }) => ({ ...row, payload_json: JSON.stringify(payload) }));
  const tickers = ["DGE.L", "FER"];
  const coverage = tickers.map((symbol) => coverageRow(symbol, financialRows, { source_ticker: symbol === "DGE.L" ? "DEO" : "FER" }));
  return { requiredTickers: tickers, baselineTickers: tickers, financialRows, baselineFinancialRows: financialRows, ledger: financialCoverageLedger(coverage), declaredSummary: { covered: 2 }, snapshotDispositions: tickers.map(disposition), baselineSnapshotDispositions: tickers.map(disposition), modelCounts: new Map(tickers.map((symbol) => [symbol, 1])) };
}

test("source ledger serializes every issuer without inventing a review or missing identity", () => {
  const ledger = financialCoverageLedger([{ ticker: "b", source_ticker: null, status: "external_required", arq_periods: 0, art_periods: 0 }, { ticker: "a", source_ticker: "A.SRC", status: "covered", arq_periods: 2, art_periods: 3, first_available_at: "2020-01-01", last_available_at: "2026-08-31", note: "source note" }]);
  assert.equal(ledger.schemaVersion, 1);
  assert.equal(ledger.basis, "pit_financial_coverage");
  assert.deepEqual(ledger.issuers.map((row) => row.ticker), ["A", "B"]);
  assert.equal(ledger.issuers[1].sourceTicker, null);
  assert.equal(ledger.issuers[1].status, "external_required");
  assert.equal("reviewed" in ledger.issuers[0], false);
});

test("an additive reviewed issuer passes without changing retained issuer coverage", () => {
  const result = auditFinancialCoverageRelease(fixture());
  assert.deepEqual(result.failures, []);
  assert.deepEqual(result.addedTickers, ["NEW"]);
  assert.deepEqual(result.statusCounts, { annual_only: 1, covered: 2, derived: 1 });
  assert.equal(result.baselineEvidenceMode, "independent_raw_dimensions_no_review_inferred");
  assert.equal(result.retainedPeriodChecks, 3);
});

test("a complete persisted baseline ledger is independently reconciled rather than trusted", () => {
  const data = fixture();
  data.baselineLedger = financialCoverageLedger(data.baselineTickers.map((symbol) => coverageRow(symbol, data.baselineFinancialRows)));
  assert.deepEqual(auditFinancialCoverageRelease(data).failures, []);
  data.baselineLedger.issuers.find((row) => row.ticker === "AAA").arqPeriods = 200;
  assert.ok(codes(auditFinancialCoverageRelease(data)).includes("baseline_financial_coverage_raw_mismatch"));
});

test("matching aggregate counts cannot conceal swapping a required issuer for an extra", () => {
  const data = fixture();
  data.ledger.issuers.find((row) => row.ticker === "NEW").ticker = "OTHER";
  const result = auditFinancialCoverageRelease(data);
  assert.ok(codes(result).includes("candidate_financial_coverage_missing_ticker"));
  assert.ok(codes(result).includes("candidate_financial_coverage_unexpected_ticker"));
  assert.ok(codes(result).includes("candidate_unlisted_raw_financial_ticker"));
});

test("missing, duplicate and invalid-state ledger entries each block the release", () => {
  assert.ok(codes(auditFinancialCoverageRelease(fixture({ ledger: null }))).includes("candidate_financial_coverage_ledger_missing_or_invalid"));
  const duplicate = fixture();
  duplicate.ledger.issuers.push({ ...duplicate.ledger.issuers[0] });
  assert.ok(codes(auditFinancialCoverageRelease(duplicate)).includes("candidate_financial_coverage_duplicate_ticker"));
  const invalid = fixture();
  invalid.ledger.issuers.find((row) => row.ticker === "NEW").status = "external_required";
  assert.ok(codes(auditFinancialCoverageRelease(invalid)).includes("candidate_financial_coverage_state_invalid"));
});

test("every declared covered issuer needs its own raw financial rows", () => {
  const data = fixture();
  data.financialRows = data.financialRows.filter((row) => row.ticker !== "NEW");
  assert.ok(codes(auditFinancialCoverageRelease(data)).includes("candidate_financial_coverage_without_raw_rows"));
});

test("source ticker, ARQ/ART counts and date extents reconcile per issuer", () => {
  for (const [field, value, expected] of [
    ["sourceTicker", "OTHER", "candidate_financial_source_ticker_mismatch"],
    ["arqPeriods", 99, "candidate_financial_coverage_raw_mismatch"],
    ["artPeriods", 99, "candidate_financial_coverage_raw_mismatch"],
    ["firstAvailableAt", "2020-01-01", "candidate_financial_coverage_raw_mismatch"],
    ["lastAvailableAt", "2026-09-05", "candidate_financial_coverage_raw_mismatch"]
  ]) {
    const data = fixture();
    data.ledger.issuers.find((row) => row.ticker === "NEW")[field] = value;
    assert.ok(codes(auditFinancialCoverageRelease(data)).includes(expected), field);
  }
});

test("empty ARQ placeholders and non-PIT dimensions do not establish coverage", () => {
  const empty = fixture();
  empty.financialRows = empty.financialRows.map((row) => row.ticker === "NEW" ? { ...row, payload_json: "{}" } : row);
  assert.ok(codes(auditFinancialCoverageRelease(empty)).includes("candidate_covered_issuer_without_periodic_core_basis"));
  const restated = fixture();
  restated.financialRows = restated.financialRows.map((row) => row.ticker === "NEW" ? { ...row, dimension: "MRQ" } : row);
  assert.ok(codes(auditFinancialCoverageRelease(restated)).includes("candidate_financial_dimension_not_pit"));
});

test("actual DGE.L and FER ARQ metadata may use explicitly trailing same-period ART core", () => {
  const result = auditFinancialCoverageRelease(artBackedFixture());
  assert.deepEqual(result.failures, []);
  for (const issuer of result.issuerReconciliation) {
    assert.equal(issuer.rawArqCorePeriods, 0);
    assert.equal(issuer.rawArtCorePeriods, 1);
    assert.equal(issuer.financialCoreBasis, "arq_metadata_with_same_period_art_core");
    assert.equal(issuer.artBackedArqPeriods[0].basis, "same_period_explicit_trailing_art_core");
  }
  assert.equal(result.issuerReconciliation.find((row) => row.ticker === "DGE.L").sourceTicker, "DEO");
});

test("ART backing cannot borrow another period, omit TTM semantics, or pass empty flows", () => {
  for (const mode of ["wrong_period", "missing_ttm_flag", "empty_core"]) {
    const data = artBackedFixture();
    data.financialRows = data.financialRows.map((row) => {
      if (row.dimension !== "ART") return row;
      const payload = JSON.parse(row.payload_json);
      if (mode === "missing_ttm_flag") delete payload.sourceRecord.metricsAreTrailingTwelveMonths;
      if (mode === "empty_core") for (const field of ["revenue_m", "net_income_m", "cfo_m"]) payload[field] = null;
      return { ...row, fiscal_period: mode === "wrong_period" ? "2020-Q4" : row.fiscal_period, payload_json: JSON.stringify(payload) };
    });
    assert.ok(codes(auditFinancialCoverageRelease(data)).includes("candidate_covered_issuer_without_periodic_core_basis"), mode);
  }
});

test("unbacked empty source periods remain explicit modelability-audit work, not invented core", () => {
  const data = artBackedFixture();
  data.financialRows = [...data.financialRows, raw("FER", "ARQ", "2023-Q2", "2023-08-01", { payload_json: JSON.stringify({ revenue_m: null, cfo_m: null, net_income_m: null }) })];
  const coverage = data.requiredTickers.map((symbol) => coverageRow(symbol, data.financialRows, { source_ticker: symbol === "DGE.L" ? "DEO" : "FER" }));
  data.ledger = financialCoverageLedger(coverage);
  const result = auditFinancialCoverageRelease(data);
  assert.deepEqual(result.failures, []);
  assert.deepEqual(result.issuerReconciliation.find((row) => row.ticker === "FER").unbackedArqPeriodsRequiringModelabilityAudit, ["2023-Q2"]);
});

test("annual-only state requires ART-only rows, not an arbitrary alternate label", () => {
  const data = fixture();
  data.ledger.issuers.find((row) => row.ticker === "NEW").status = "annual_only";
  assert.ok(codes(auditFinancialCoverageRelease(data)).includes("candidate_annual_only_dimension_mismatch"));
});

test("only the explicit RKLX to RKLB instrument is allowed to be derived", () => {
  const data = fixture();
  data.ledger.issuers = data.ledger.issuers.map((row) => row.ticker === "NEW" ? { ...row, status: "derived", arqPeriods: 0, artPeriods: 0, firstAvailableAt: null, lastAvailableAt: null, note: "No data" } : row);
  data.financialRows = data.financialRows.filter((row) => row.ticker !== "NEW");
  data.snapshotDispositions = data.snapshotDispositions.map((row) => row.ticker === "NEW" ? { ...row, valuation_status: "not_applicable", derived_instrument: 1, source_ticker: "NEW" } : row);
  data.modelCounts.set("NEW", 0);
  assert.ok(codes(auditFinancialCoverageRelease(data)).includes("candidate_unapproved_derived_financial_coverage"));
});

test("RKLX exception still demands no issuer financial/model rows and explicit snapshot evidence", () => {
  for (const kind of ["raw", "model", "identity", "snapshot"]) {
    const data = fixture();
    if (kind === "raw") data.financialRows.push(raw("RKLX"));
    if (kind === "model") data.modelCounts.set("RKLX", 1);
    if (kind === "identity") data.ledger.issuers.find((row) => row.ticker === "RKLX").sourceTicker = "OTHER";
    if (kind === "snapshot") data.snapshotDispositions.find((row) => row.ticker === "RKLX").derived_instrument = null;
    assert.ok(auditFinancialCoverageRelease(data).failures.length > 0, kind);
  }
});

test("normal issuer cannot bypass coverage by declaring not-applicable in its snapshot", () => {
  const data = fixture();
  data.snapshotDispositions.find((row) => row.ticker === "NEW").valuation_status = "not_applicable";
  assert.ok(codes(auditFinancialCoverageRelease(data)).includes("candidate_financial_snapshot_disposition_mismatch"));
});

test("quarterly coverage cannot regress to annual-only even if another issuer offsets the counts", () => {
  const data = fixture();
  data.financialRows = data.financialRows.filter((row) => !(row.ticker === "AAA" && row.dimension === "ARQ"));
  data.financialRows.push(raw("BA.L"));
  const source = data.requiredTickers.map((symbol) => coverageRow(symbol, data.financialRows));
  data.ledger = financialCoverageLedger(source);
  data.declaredSummary = summary(source);
  const result = auditFinancialCoverageRelease(data);
  assert.deepEqual(result.statusCounts, { annual_only: 1, covered: 2, derived: 1 });
  assert.ok(codes(result).includes("retained_financial_coverage_regressed"));
  assert.ok(codes(result).includes("retained_financial_period_missing"));
});

test("every historical baseline period and dimension must remain present", () => {
  const data = fixture();
  data.financialRows = data.financialRows.filter((row) => !(row.ticker === "AAA" && row.dimension === "ART"));
  const source = data.requiredTickers.map((symbol) => coverageRow(symbol, data.financialRows));
  data.ledger = financialCoverageLedger(source);
  data.declaredSummary = summary(source);
  const result = auditFinancialCoverageRelease(data);
  assert.ok(codes(result).includes("retained_financial_period_missing"));
  assert.equal(result.failures.find((row) => row.code === "retained_financial_period_missing").periodDimension, "2025-Q4::ART");
});

test("baseline source identity and first-visible period dates cannot silently regress", () => {
  for (const field of ["source_ticker", "available_at"]) {
    const data = fixture();
    data.financialRows = data.financialRows.map((row) => row.ticker === "AAA" ? { ...row, [field]: field === "source_ticker" ? "OTHER" : "2026-03-01" } : row);
    const source = data.requiredTickers.map((symbol) => coverageRow(symbol, data.financialRows, symbol === "AAA" && field === "source_ticker" ? { source_ticker: "OTHER" } : {}));
    data.ledger = financialCoverageLedger(source);
    data.declaredSummary = summary(source);
    assert.ok(codes(auditFinancialCoverageRelease(data)).includes("retained_financial_period_lineage_regressed"), field);
  }
});

test("older baseline missing a ledger is inferred from raw dimensions, never from the new declaration", () => {
  const data = fixture();
  data.baselineFinancialRows = data.baselineFinancialRows.filter((row) => row.ticker !== "AAA");
  assert.ok(codes(auditFinancialCoverageRelease(data)).includes("baseline_financial_coverage_without_raw_rows"));
});

test("a legacy database without raw evidence must match the explicit 533-company policy", () => {
  const data = legacyFixture();
  assert.equal(data.baselineTickers.length, LEGACY_FINANCIAL_COVERAGE_POLICY.tickerCount);
  const result = auditFinancialCoverageRelease(data);
  assert.deepEqual(result.failures, []);
  assert.equal(result.baselineEvidenceMode, "legacy_533_contract_no_historical_review_claim");
  const invalid = auditFinancialCoverageRelease({ ...data, baselineTickers: data.baselineTickers.filter((symbol) => symbol !== "OLD0") });
  assert.ok(codes(invalid).includes("legacy_baseline_financial_coverage_unverifiable"));
});

test("legacy total counts cannot swap annual-only status onto a formerly quarterly issuer", () => {
  const data = legacyFixture();
  data.financialRows = data.financialRows.map((row) => row.ticker === "OLD0" ? { ...row, dimension: "ART" } : row.ticker === "BA.L" ? { ...row, dimension: "ARQ" } : row);
  const source = data.requiredTickers.map((symbol) => coverageRow(symbol, data.financialRows));
  data.ledger = financialCoverageLedger(source);
  data.declaredSummary = summary(source);
  const result = auditFinancialCoverageRelease(data);
  assert.deepEqual(result.statusCounts, { annual_only: 2, covered: 531, derived: 1 });
  assert.ok(result.failures.some((row) => row.code === "retained_financial_coverage_regressed" && row.ticker === "OLD0"));
});
