import test from "node:test";
import assert from "node:assert/strict";
import {
  TBBB_FY2026_REVENUE_GUIDANCE,
  recomputeTbbbFinancialTrend,
  calculateTbbbValuationCandidate,
  calculateTbbbFixedMarginScenarioRange,
  solveTbbbIntrinsicClaimPrice
} from "./tbbbValuationCandidate.js";

const dates = { asOfDate: "2026-09-05", periodEndDate: "2026-06-30" };
const referenceMargin = 577.455 / 91149.114;

// Deliberately synthetic analyst assumptions for arithmetic regression, NOT an
// investment recommendation, verified FX observation, or approved scenario.
function scenario(overrides = {}) {
  return {
    economicInput: {
      ...dates, sourceCurrency: "MXN", sourceRevenue: 91149.114,
      sourceCfo: 7011.837, sourceCapex: 3772.646,
      rawSourceRecord: { ticker: "TBBB", reportperiod: "2026-06-30", datekey: "2026-08-12",
        source: "public_evidence_arithmetic_test_fixture" }
    },
    scenarioId: "synthetic-arithmetic-fixture", assumptionDate: "2026-09-05",
    rationale: "Synthetic explicit assumptions for model arithmetic tests, not an approved value.",
    fy2026RevenueGrowth: 0.305, costOfEquity: 0.12, terminalGrowth: 0.03,
    guidanceApplicationPolicy: "hypothetical_full_weight_growth_translation_not_release",
    timingPolicy: "act_365_fiscal_year_end", marginPolicy: "hold_observed_bridge_margin",
    existingAwardPolicy: "all_current_awards_vest_no_duplicate_sbc_expense",
    futureGrantPolicy: "cash_equivalent_cost_in_lieu_of_dilution",
    optionPolicy: { mode: "grouped_intrinsic_plus_explicit_reserve", timeValueReserveUsdM: 0,
      rationale: "Explicit zero in synthetic test; does not establish zero economic time value." },
    equityAdjustment: { amountM: 0, rationale: "Explicit no incremental balance-sheet adjustment in fixture." },
    fx: { baseCurrency: "USD", quoteCurrency: "MXN", mxnPerUsd: 20,
      rateDate: "2026-09-04", availableDate: "2026-09-04",
      sourceUrl: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml",
      derivation: "Synthetic test numeric input, not an asserted actual ECB observation; caller verification required." },
    stub: { periodStartExclusive: "2026-09-05", paymentDate: "2026-12-31",
      economicCashFlowM: 100, additionalReinvestmentM: 10, netBorrowingM: -20,
      futureGrantCostM: 10, rationale: "Explicit post-asof synthetic stub, not all of FY2026 cash." },
    forecast: [0.20, 0.15, 0.12, 0.10, 0.08].map((revenueGrowth, index) => ({
      fiscalYear: 2027 + index, revenueGrowth, additionalReinvestmentMargin: 0.001,
      netBorrowingM: -40, futureGrantCostMargin: 0.002
    })),
    terminal: { additionalReinvestmentMargin: 0.001, netBorrowingMargin: 0,
      futureGrantCostMargin: 0.002, rationale: "Explicit constant net margins after FY2031." },
    ...overrides
  };
}

function boundedScenario(values = [11, 10, 9, 8, 7, 6, -20, 45], financialTrendPct = 8.5) {
  const periodEnds = ["2024-09-30", "2024-12-31", "2025-03-31", "2025-06-30",
    "2025-09-30", "2025-12-31", "2026-03-31", "2026-06-30"].slice(-values.length);
  function point(periodEndDate, revenueM) {
    const date = new Date(`${periodEndDate}T00:00:00Z`);
    const availableDate = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 2, 12))
      .toISOString().slice(0, 10);
    return { periodEndDate, availableDate, revenueM, scope: "company_total", currency: "MXN",
      unit: "million", sourceDimension: "ARQ",
      sourceRecord: { ticker: "TBBB", periodEndDate, datekey: availableDate,
        source: "synthetic_public_revenue_fixture_not_actual_company_values" } };
  }
  return scenario({
    guidanceApplicationPolicy: "pit_trend_bounded_blend", financialTrendPct, guidanceWeight: 0.25,
    growthPolicySettings: { normalizedGrowthCapPct: 45, minimumGrowthSampleCount: 4, fundamentalGrowthPriorPct: 5 },
    financialTrendEvidence: { asOfDate: "2026-09-05", unit: "percent", valuePct: financialTrendPct,
      method: "normalizedRevenueGrowthForRows", windowSize: 8,
      selection: "latest_up_to_8_complete_observations_in_latest_8_period_window",
      observations: values.map((valuePct, index) => {
        const periodEndDate = periodEnds[index];
        const priorEnd = `${Number(periodEndDate.slice(0, 4)) - 1}${periodEndDate.slice(4)}`;
        return { ...point(periodEndDate, 100 * (1 + valuePct / 100)), valuePct,
          comparator: point(priorEnd, 100) };
      }) }
  });
}

function close(actual, expected, tolerance = 1e-9) {
  assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected}`);
}

function assertBlocked(input, reason) {
  const result = calculateTbbbValuationCandidate(input);
  assert.equal(result.status, "blocked");
  assert.equal(result.releaseReady, false);
  assert.equal(result.reason, reason);
  assert.equal(result.perShareUsd, undefined);
  assert.equal(result.forecast, undefined);
}

test("five fiscal-year cash flows, explicit stub and Gordon terminal independently recalculate", () => {
  const input = scenario();
  const result = calculateTbbbValuationCandidate(input);
  assert.equal(result.status, "candidate");
  assert.equal(result.releaseReady, false);
  assert.equal(result.referenceCashBridge.economicCashFlowM, 577.455);
  close(result.referenceCashBridge.referenceMargin, referenceMargin);
  assert.equal(result.forecast.length, 5);
  assert.equal(result.stub.fcfeM, 60);
  close(result.stub.discountYears, 117 / 365);
  close(result.forecast[0].discountYears, 482 / 365);
  let revenue = 78152.943 * 1.305;
  let expectedPv = 60 / (1.12 ** (117 / 365));
  for (let index = 0; index < 5; index += 1) {
    const expected = input.forecast[index];
    const actual = result.forecast[index];
    revenue *= 1 + expected.revenueGrowth;
    const cash = revenue * (577.455 / 91149.114 - 0.001 - 0.002) - 40;
    const years = (Date.parse(`${2027 + index}-12-31T00:00:00Z`) -
      Date.parse("2026-09-05T00:00:00Z")) / 86400000 / 365;
    close(actual.revenueM, revenue);
    close(actual.fcfeM, cash);
    close(actual.presentValueM, cash / 1.12 ** years);
    expectedPv += cash / 1.12 ** years;
  }
  const terminalCash = revenue * 1.03 * (577.455 / 91149.114 - 0.001 - 0.002);
  const terminalPv = terminalCash / 0.09 / 1.12 ** result.forecast[4].discountYears;
  expectedPv += terminalPv;
  close(result.terminal.fcfeM, terminalCash);
  close(result.terminal.presentValueM, terminalPv);
  close(result.valuationBridge.totalEquityValueM, expectedPv);
  close(result.valuationBridge.equityForIntrinsicClaimAllocationUsdM, expectedPv / 20);
  close(result.perShareUsd, expectedPv / 20 / 130.323391);
  assert.equal(result.claims.dilution.issuedOptionShares, 0);
});

test("only annual group FY2026 revenue growth is guidance; midpoint and every later input are assumptions", () => {
  const result = calculateTbbbValuationCandidate(scenario());
  assert.equal(TBBB_FY2026_REVENUE_GUIDANCE.low, 0.29);
  assert.equal(TBBB_FY2026_REVENUE_GUIDANCE.high, 0.32);
  assert.equal(result.guidanceUse.subject, "company_total");
  assert.equal(result.guidanceUse.availableDate, "2026-03-11");
  assert.match(result.guidanceUse.url, /000119312526102363/);
  assert.match(result.guidanceUse.selectedGrowthLabel, /analyst/);
  assert.equal(result.guidanceUse.derivedRevenueLabel, "derived_hypothetical_only_NOT_management_monetary_guidance");
  assert.equal(result.guidanceUse.usedAsReleasedAmountGuidance, false);
  assert.equal(result.guidanceUse.growthPolicyAudit.compliesWithReleaseGrowthPolicy, false);
  assert.equal(result.guidanceUse.growthPolicyAudit.appliedWeight, 1);
  assert.equal(result.guidanceUse.growthPolicyAudit.releaseMaximumWeight, 0.25);
  assert.equal(result.guidanceUse.growthPolicyAudit.releaseFinancialTrendBand, 0.15);
  assert.equal(result.guidanceUse.growthPolicyAudit.financialTrend, null);
  assert.ok(result.releaseBlockers.includes("full_weight_growth_translation_does_not_satisfy_release_growth_policy"));
  close(result.guidanceUse.derivedFy2026RevenueM, 101989.590615);
  assert.ok(result.guidanceUse.notGuided.includes("FCFE"));
  assert.ok(result.guidanceUse.notGuided.includes("2027_2031_reinvestment_and_cash_financing_schedule"));
  assert.equal(result.capitalInvestmentGuidance.totalM, 5250);
  assert.equal(result.capitalInvestmentGuidance.targetFiscalYear, 2026);
  assert.equal(result.capitalInvestmentGuidance.fullYearCashOnlyCapexM, null);
  assert.equal(result.capitalInvestmentGuidance.modelConsumption, "not_applied_requires_cash_noncash_reconciliation");
  assert.ok(result.forecast.every((row) => row.label === "analyst_scenario"));
  for (const growth of [0.28999, 0.32001, null, undefined]) {
    assertBlocked(scenario({ fy2026RevenueGrowth: growth }), "growth_selection_outside_FY2026_guidance");
  }
  for (const growth of [0.29, 0.32]) {
    assert.equal(calculateTbbbValuationCandidate(scenario({ fy2026RevenueGrowth: growth })).status, "candidate");
  }
});

test("no financial, margin, reinvestment, future grant, Ke/g/FX, timing, or claim defaults", () => {
  const required = {
    economicInput: "invalid_as_of_date", costOfEquity: "invalid_explicit_Ke_or_terminal_growth",
    terminalGrowth: "invalid_explicit_Ke_or_terminal_growth", fx: "missing_or_invalid_dated_official_FX_input",
    stub: "explicit_post_asof_2026_stub_required", forecast: "exactly_five_explicit_FY2027_to_FY2031_rows_required",
    terminal: "explicit_terminal_margin_schedule_required", marginPolicy: "explicit_margin_policy_required",
    futureGrantPolicy: "explicit_future_grant_cash_equivalent_policy_required",
    existingAwardPolicy: "explicit_existing_award_policy_required",
    guidanceApplicationPolicy: "explicit_nonrelease_guidance_translation_policy_required",
    optionPolicy: "explicit_option_time_value_policy_required",
    equityAdjustment: "explicit_incremental_equity_adjustment_required",
    timingPolicy: "explicit_timing_policy_required"
  };
  for (const [field, reason] of Object.entries(required)) {
    const input = scenario();
    delete input[field];
    assertBlocked(input, reason);
  }
  for (const field of ["revenueGrowth", "additionalReinvestmentMargin", "netBorrowingM", "futureGrantCostMargin"]) {
    const input = scenario();
    delete input.forecast[2][field];
    assertBlocked(input, "invalid_or_missing_annual_assumption");
  }
  for (const field of ["additionalReinvestmentMargin", "netBorrowingMargin", "futureGrantCostMargin"]) {
    const input = scenario();
    delete input.terminal[field];
    assertBlocked(input, "explicit_terminal_margin_schedule_required");
  }
});

test("the economic adapter is re-run; fabricated ready objects, unit errors and future shares fail closed", () => {
  assertBlocked(scenario({ economicInput: { status: "ready", fairValue: 99 } }), "invalid_as_of_date");
  for (const [field, value, reason] of [
    ["sourceCfo", 7011.838, "source_amount_not_reconciled"],
    ["sourceCurrency", "USD", "source_currency_mismatch"],
    ["asOfDate", "2026-08-11", "official_source_not_available"],
    ["asOfDate", "2026-09-06", "evidence_not_reviewed_through_as_of_date"],
    ["periodEndDate", "2026-03-31", "unsupported_period_end_date"]
  ]) {
    const input = scenario();
    input.economicInput[field] = value;
    assertBlocked(input, reason);
  }
  const laterRecord = scenario();
  laterRecord.economicInput.rawSourceRecord.datekey = "2026-09-06";
  assertBlocked(laterRecord, "source_record_not_available");
});

test("dated assumptions and official FX source metadata cannot look ahead or invert the pair", () => {
  assertBlocked(scenario({ assumptionDate: "2026-09-06" }), "missing_or_future_analyst_assumption_metadata");
  for (const patch of [
    { mxnPerUsd: 0 }, { mxnPerUsd: NaN }, { mxnPerUsd: "20" },
    { baseCurrency: "MXN", quoteCurrency: "USD" },
    { availableDate: "2026-09-06" }, { rateDate: "2026-09-05", availableDate: "2026-09-04" },
    { rateDate: "2026-02-30" }, { sourceUrl: "https://ecb.europa.eu.example.com/rates" },
    { sourceUrl: "" }, { derivation: "" }
  ]) {
    const input = scenario();
    Object.assign(input.fx, patch);
    assertBlocked(input, "missing_or_invalid_dated_official_FX_input");
  }
  assert.ok(calculateTbbbValuationCandidate(scenario()).releaseBlockers.includes(
    "caller_supplied_official_FX_value_not_independently_verified"));
});

test("calendar scope and terminal assumptions cannot silently borrow current-year or last-year values", () => {
  const firstIsCurrentYear = scenario();
  firstIsCurrentYear.forecast[0].fiscalYear = 2026;
  assertBlocked(firstIsCurrentYear, "invalid_or_missing_annual_assumption");
  const fullYearStub = scenario();
  fullYearStub.stub.periodStartExclusive = "2026-01-01";
  assertBlocked(fullYearStub, "explicit_post_asof_2026_stub_required");
  for (const patch of [
    { costOfEquity: 0 }, { costOfEquity: NaN }, { terminalGrowth: 0.12 },
    { terminalGrowth: 0.13 }, { terminalGrowth: -1 }, { terminalGrowth: undefined }
  ]) assertBlocked(scenario(patch), "invalid_explicit_Ke_or_terminal_growth");
  const explicit = scenario({ marginPolicy: "explicit_margins" });
  assertBlocked(explicit, "invalid_or_missing_annual_assumption");
  explicit.forecast.forEach((row, index) => { row.economicCashFlowMargin = 0.01 + index * 0.001; });
  assertBlocked(explicit, "explicit_terminal_margin_schedule_required");
  explicit.terminal.economicCashFlowMargin = 0.017;
  const result = calculateTbbbValuationCandidate(explicit);
  assert.equal(result.status, "candidate");
  assert.equal(result.terminal.economicCashFlowMargin, 0.017);
  assert.notEqual(result.terminal.economicCashFlowMargin, result.forecast.at(-1).economicCashFlowMargin);
});

test("existing awards are claims once; new grants are explicit cash-equivalent costs once", () => {
  const result = calculateTbbbValuationCandidate(scenario());
  assert.equal(result.shareClaims.allIssuedSharesM, 121.187774);
  assert.equal(result.shareClaims.fixedClaimsM, 130.323391);
  assert.equal(result.valuationBridge.existingSbcExpenseDeductedAgainM, 0);
  assert.equal(result.valuationBridge.futureGrantDilutionAlsoApplied, false);
  assert.equal(result.valuationBridge.conditionalExerciseCashAddedToCurrentEquityM, 0);
  assert.equal(result.valuationBridge.automaticNetDebtDeductionM, 0);
  assert.ok(result.forecast.every((row) => row.futureGrantCostM > 0));
  assert.ok(!result.warnings.includes("future_grants_not_forecast"));
  const noNewGrants = scenario();
  noNewGrants.stub.futureGrantCostM = 0;
  noNewGrants.forecast.forEach((row) => { row.futureGrantCostMargin = 0; });
  noNewGrants.terminal.futureGrantCostMargin = 0;
  assert.ok(calculateTbbbValuationCandidate(noNewGrants).perShareUsd > result.perShareUsd);
  assertBlocked(scenario({ futureGrantPolicy: "zero_if_missing" }),
    "explicit_future_grant_cash_equivalent_policy_required");
});

test("negative annual cash is kept; a negative equity scenario never gets a fabricated positive floor", () => {
  const loss = scenario();
  loss.forecast[0].netBorrowingM = -1000;
  const lossResult = calculateTbbbValuationCandidate(loss);
  assert.equal(lossResult.status, "candidate");
  assert.ok(lossResult.forecast[0].fcfeM < 0);
  const allNegative = scenario();
  allNegative.forecast.forEach((row) => { row.futureGrantCostMargin = 0.02; });
  allNegative.terminal.futureGrantCostMargin = 0.02;
  const result = calculateTbbbValuationCandidate(allNegative);
  assert.equal(result.status, "candidate");
  assert.equal(result.valuationStatus, "nonpositive_equity_scenario");
  assert.ok(result.valuationBridge.equityForIntrinsicClaimAllocationUsdM < 0);
  assert.equal(result.perShareUsd, null);
  assert.equal(result.claims, null);
});

test("self-consistent intrinsic pricing satisfies all three piecewise claim regions without a market price", () => {
  for (const expectedPrice of [0.1, 5.729, 5.73, 5.731, 20, 32.909, 32.91, 32.911, 100]) {
    const equityValueUsdM = expectedPrice * 130.323391 +
      37.640312 * Math.max(expectedPrice - 5.73, 0) +
      4.082500 * Math.max(expectedPrice - 32.91, 0);
    const result = solveTbbbIntrinsicClaimPrice({ ...dates, equityValueUsdM });
    assert.equal(result.status, "candidate");
    close(result.priceUsd, expectedPrice);
    close(result.identityResidualUsdM, 0);
    close(result.priceUsd * result.dilution.grossShareClaimsM,
      equityValueUsdM + result.dilution.estimatedGrossExerciseCashUsdM);
    assert.ok(result.warnings.includes("intrinsic_only_excludes_option_time_value"));
    assert.ok(result.warnings.includes("rounded_strikes_produce_approximate_exercise_cash"));
  }
  assert.equal(solveTbbbIntrinsicClaimPrice({ ...dates, equityValueUsdM: 0 }).status, "blocked");
  assert.equal(solveTbbbIntrinsicClaimPrice({ ...dates, equityValueUsdM: -1 }).status, "blocked");
  assert.equal(solveTbbbIntrinsicClaimPrice({ ...dates, asOfDate: "2026-05-01", equityValueUsdM: 1 }).reason,
    "official_source_not_available");
});

test("a positive adjustment cannot conceal an unsustainable nonpositive terminal cash flow", () => {
  const input = scenario();
  input.terminal.futureGrantCostMargin = 0.02;
  input.equityAdjustment.amountM = 1_000_000;
  const result = calculateTbbbValuationCandidate(input);
  assert.ok(result.valuationBridge.equityForIntrinsicClaimAllocationUsdM > 0);
  assert.ok(result.terminal.fcfeM < 0);
  assert.equal(result.valuationStatus, "nonpositive_terminal_FCFE_scenario");
  assert.equal(result.perShareUsd, null);
  assert.equal(result.claims, null);
});

test("option reserve is explicit and independently subtracts from the equity available for intrinsic claims", () => {
  const base = calculateTbbbValuationCandidate(scenario());
  const input = scenario();
  input.optionPolicy.timeValueReserveUsdM = 10;
  const reserve = calculateTbbbValuationCandidate(input);
  close(base.valuationBridge.equityForIntrinsicClaimAllocationUsdM -
    reserve.valuationBridge.equityForIntrinsicClaimAllocationUsdM, 10);
  assert.ok(reserve.perShareUsd < base.perShareUsd);
  delete input.optionPolicy.timeValueReserveUsdM;
  assertBlocked(input, "explicit_option_time_value_policy_required");
});

test("market price and caller objects never enter calculation or mutate", () => {
  const input = scenario();
  const original = structuredClone(input);
  const base = calculateTbbbValuationCandidate(input);
  assert.deepEqual(calculateTbbbValuationCandidate({ ...input, marketPriceUsd: 0.01 }), base);
  assert.deepEqual(calculateTbbbValuationCandidate({ ...input, marketPriceUsd: 10000 }), base);
  assert.deepEqual(input, original);
  base.forecast[0].revenueGrowth = 900;
  base.provenance.economicInputs.rawSourceRecord.ticker = "CHANGED";
  assert.deepEqual(input, original);
});

test("fixed-margin range is the range of supplied complete scenarios, not justified valuation bounds", () => {
  const low = scenario({ scenarioId: "conditional-low", fy2026RevenueGrowth: 0.29, costOfEquity: 0.14 });
  const high = scenario({ scenarioId: "conditional-high", fy2026RevenueGrowth: 0.32, costOfEquity: 0.10 });
  const range = calculateTbbbFixedMarginScenarioRange([low, high]);
  assert.equal(range.status, "candidate");
  assert.equal(range.releaseReady, false);
  close(range.minimumPerShareUsd, calculateTbbbValuationCandidate(low).perShareUsd);
  close(range.maximumPerShareUsd, calculateTbbbValuationCandidate(high).perShareUsd);
  assert.match(range.label, /not_reasonable_value_bounds/);
  assert.match(range.warning, /No finite economically justified bounds/);
  assert.equal(calculateTbbbFixedMarginScenarioRange([low]).status, "blocked");
  assert.equal(calculateTbbbFixedMarginScenarioRange([low, low]).reason,
    "scenario_range_requires_same_dates_and_unique_scenario_ids");
  const missing = scenario({ scenarioId: "missing", costOfEquity: undefined });
  assert.equal(calculateTbbbFixedMarginScenarioRange([low, missing]).reason,
    "scenario_range_contains_blocked_input");
  const negative = scenario({ scenarioId: "negative" });
  negative.terminal.futureGrantCostMargin = 0.02;
  const mixed = calculateTbbbFixedMarginScenarioRange([low, negative]);
  assert.equal(mixed.hasNonpositiveScenario, true);
  assert.equal(mixed.minimumPerShareUsd, null);
  assert.equal(mixed.maximumPerShareUsd, null);
});

test("Ke approaching g makes fixed-margin value unbounded; revenue guidance cannot supply a price ceiling", () => {
  const near = scenario({ scenarioId: "near", costOfEquity: 0.0301 });
  const nearer = scenario({ scenarioId: "nearer", costOfEquity: 0.030001 });
  const a = calculateTbbbValuationCandidate(near);
  const b = calculateTbbbValuationCandidate(nearer);
  assert.ok(b.perShareUsd > a.perShareUsd * 90);
  assert.ok(b.valuationBridge.terminalValueShare > 0.999);
  assert.equal(b.releaseReady, false);
});

test("nonfinite computed cash is rejected, not serialized into a purported value", () => {
  const input = scenario();
  input.forecast.forEach((row) => { row.revenueGrowth = Number.MAX_VALUE; });
  assertBlocked(input, "nonfinite_scenario_calculation");
});

test("policy-compatible path independently reproduces the existing eight-period normalization fixture", () => {
  const input = boundedScenario();
  const result = calculateTbbbValuationCandidate(input);
  assert.equal(result.status, "candidate");
  const audit = result.guidanceUse.growthPolicyAudit;
  // Existing importSecQuarterlyValuations.test.js fixture expects 8.5%, without
  // importing the large importer or opening any database in this test.
  close(audit.financialTrendPct, 8.5);
  close(audit.baseGrowthPct, 8.5);
  close(audit.rawGrowthPct, 30.5);
  close(audit.boundedGrowthPct, 23.5);
  assert.equal(audit.appliedWeight, 0.25);
  close(audit.appliedGrowthPct, 12.25);
  close(result.guidanceUse.derivedFy2026RevenueM, 78152.943 * 1.1225);
  assert.equal(audit.compliesWithReleaseGrowthPolicy, true);
  assert.equal(audit.independentTrendAudit.sampleCount, 8);
  assert.equal(audit.independentTrendAudit.trimStart, 1);
  assert.equal(audit.independentTrendAudit.trimEnd, 7);
  assert.ok(!result.releaseBlockers.includes("full_weight_growth_translation_does_not_satisfy_release_growth_policy"));
  assert.ok(result.releaseBlockers.includes("financial_trend_window_completeness_and_source_selection_require_independent_audit"));
  assert.equal(result.releaseReady, false);
});

test("trend numbers must reconcile both to the underlying revenue and the independent median", () => {
  const input = boundedScenario();
  input.financialTrendPct = 100;
  input.financialTrendEvidence.valuePct = 100;
  assertBlocked(input, "financial_trend_not_reconciled_to_independent_median");
  const changedRevenue = boundedScenario();
  changedRevenue.financialTrendEvidence.observations[0].revenueM += 1;
  assertBlocked(changedRevenue, "growth_observation_not_reconciled_to_revenue");
  const changedPct = boundedScenario();
  changedPct.financialTrendEvidence.observations[0].valuePct += 1;
  assertBlocked(changedPct, "growth_observation_not_reconciled_to_revenue");
});

test("trend evidence rejects duplicates, unavailable comparators, segment scope, units and mixed quarter/TTM", () => {
  for (const mutate of [
    (rows) => { rows[1] = structuredClone(rows[0]); },
    (rows) => { rows[0].comparator.availableDate = "2026-09-06"; },
    (rows) => { rows[0].scope = "segment"; },
    (rows) => { rows[0].unit = "thousand"; },
    (rows) => { rows[0].currency = "USD"; },
    (rows) => { rows[0].sourceDimension = "ART"; },
    (rows) => { rows[0].sourceRecord.datekey = "2026-09-06"; },
    (rows) => { rows[0].sourceRecord.availableAt = "invalid"; },
    (rows) => { rows[0].comparator.sourceRecord.filed = "2026-09-06"; },
    (rows) => { rows[0].comparator.revenueM = 0; },
    (rows) => { rows[0].comparator.periodEndDate = "2023-06-30"; }
  ]) {
    const input = boundedScenario();
    mutate(input.financialTrendEvidence.observations);
    assertBlocked(input, "invalid_noncomparable_duplicate_or_unavailable_growth_observation");
  }
  const mixed = boundedScenario();
  mixed.financialTrendEvidence.observations[0].sourceDimension = "ART";
  mixed.financialTrendEvidence.observations[0].comparator.sourceDimension = "ART";
  assertBlocked(mixed, "financial_trend_not_current_or_mixes_quarter_and_TTM_growth");
  const oldWindow = boundedScenario();
  oldWindow.financialTrendEvidence.observations.pop();
  assertBlocked(oldWindow, "financial_trend_not_current_or_mixes_quarter_and_TTM_growth");
});

test("guidance policy weights, financial sample requirements and cap remain explicit", () => {
  for (const weight of [undefined, null, -0.001, 0.25001, NaN]) {
    const input = boundedScenario();
    input.guidanceWeight = weight;
    assertBlocked(input, "explicit_guidance_weight_must_be_between_zero_and_025");
  }
  for (const field of ["normalizedGrowthCapPct", "minimumGrowthSampleCount", "fundamentalGrowthPriorPct"]) {
    const input = boundedScenario();
    delete input.growthPolicySettings[field];
    assertBlocked(input, "explicit_growth_profile_cap_sample_gate_and_prior_required");
  }
  assertBlocked(boundedScenario([20, 20, 20], 20), "insufficient_complete_financial_growth_observations");
  const capped = boundedScenario([60, 60, 60, 60, 60, 60, 60, 60], 60);
  capped.growthPolicySettings.normalizedGrowthCapPct = 40;
  const audit = calculateTbbbValuationCandidate(capped).guidanceUse.growthPolicyAudit;
  close(audit.boundedGrowthPct, 45);
  close(audit.beforeProfileCapPct, 56.25);
  close(audit.appliedGrowthPct, 40);
  const zeroWeight = boundedScenario();
  zeroWeight.guidanceWeight = 0;
  const zero = calculateTbbbValuationCandidate(zeroWeight).guidanceUse.growthPolicyAudit;
  close(zero.appliedGrowthPct, 8.5);
  assert.equal(zero.exclusionReason, "caller_selected_zero_weight");
});

test("sparse complete observations retain the existing evidence-ramp calculation without inventing data", () => {
  const input = boundedScenario([24, 24, 24, 24, 24, 24], 24);
  const audit = calculateTbbbValuationCandidate(input).guidanceUse.growthPolicyAudit;
  close(audit.financialTrendPct, 24);
  close(audit.independentTrendAudit.fundamentalGrowthEvidenceWeight, 0.75);
  close(audit.baseGrowthPct, 19.25);
  close(audit.appliedGrowthPct, 22.0625);
  assert.equal(audit.independentTrendAudit.observations.length, 6);
});

test("valid triple-digit growth is winsorized, retained and normalized, never discarded for a default", () => {
  const input = boundedScenario([1100, 1100, 1100, 1100, 1100, 1100, 1100, 1100], 1000);
  const trend = recomputeTbbbFinancialTrend({ ...input, ...dates });
  assert.equal(trend.status, "ready");
  assert.equal(trend.sampleCount, 8);
  close(trend.financialTrendPct, 1000);
  assert.ok(trend.observations.every((row) => row.recalculatedPct === 1100 && row.winsorizedPct === 1000));
});
