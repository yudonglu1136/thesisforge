import test from "node:test";
import assert from "node:assert/strict";
import {
  TBBB_ECONOMIC_EVIDENCE,
  buildTbbbEconomicInputs,
  calculateTbbbIntrinsicExerciseDilution
} from "./tbbbEconomicInputs.js";

const dates = { asOfDate: "2026-09-05", periodEndDate: "2026-06-30" };

function sourceInput(overrides = {}) {
  return {
    ...dates,
    sourceCurrency: "MXN",
    sourceRevenue: 91_149.114,
    sourceCfo: 7_011.837,
    sourceCapex: 3_772.646,
    rawSourceRecord: {
      ticker: "TBBB", dimension: "ART", calendardate: "2026-06-30",
      datekey: "2026-08-12", source: "test_source_lineage"
    },
    ...overrides
  };
}

function close(actual, expected, tolerance = 1e-9) {
  assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected}`);
}

function assertBlocked(input, reason) {
  const result = buildTbbbEconomicInputs(input);
  assert.equal(result.status, "blocked");
  assert.equal(result.reason, reason);
  assert.equal(result.cashFlowBridge, undefined);
  assert.equal(result.shareClaims, undefined);
}

test("TBBB official FY plus H1 less comparative H1 reproduces the ART cash bridge", () => {
  const result = buildTbbbEconomicInputs(sourceInput());
  assert.equal(result.status, "ready");
  assert.equal(result.periodType, "TTM");
  assert.equal(result.periodStartDate, "2025-07-01");
  const cash = result.cashFlowBridge;
  // Independently extracted from FY2025 F-9 and Q2 2026 release p.17.
  assert.equal(cash.cfoM, 7011.837);
  assert.equal(cash.grossPpeCapexM, 3772.283);
  assert.equal(cash.ppeDisposalsM, -0.363);
  assert.equal(cash.netPpeCapexM, 3772.646);
  assert.equal(cash.cfoMinusNetPpeM, 3239.191);
  assert.equal(cash.leasePrincipalM, 885.754);
  assert.equal(cash.leaseInterestM, 1637.335);
  assert.equal(cash.otherDebtInterestM, 110.792);
  assert.equal(cash.afterLeaseAndDebtInterestM, 605.310);
  assert.equal(cash.intangibleCapexM, 27.855);
  assert.equal(cash.economicCashFlowM, 577.455);
  assert.equal(cash.normalizedFcfeM, null);
  assert.equal(result.fairValue, undefined);
  assert.equal(result.growth, undefined);
});

test("supplier financing and existing SBC are not deducted a second time", () => {
  const result = buildTbbbEconomicInputs(sourceInput());
  assert.equal(result.cashFlowBridge.supplierFinanceNetSupportM, 488.718);
  assert.equal(result.cashFlowBridge.supplierFinanceDeductedAgainM, 0);
  assert.equal(result.cashFlowBridge.reportedTtmSbcM, 3801.322);
  assert.equal(result.cashFlowBridge.sbcDeductedM, 0);
  assert.equal(result.cashFlowBridge.otherDebtPrincipalNotIncludedM, 208.210);
  assert.equal(result.cashFlowBridge.noncashFinancedEquipmentTtmM, null);
  assert.equal(result.existingAwardExpense.includedInCashFlowBridge, false);
  assert.deepEqual(result.existingAwardExpense.values, { 2026: 2379, 2027: 881, 2028: 215, 2029: 50 });
  assert.equal(result.existingAwardExpense.futureGrantsForecast, null);
  assert.ok(result.warnings.includes("future_grants_not_forecast"));
});

test("all metric observations retain official URL, availability and correct fiscal scope", () => {
  const result = buildTbbbEconomicInputs(sourceInput());
  for (const metric of Object.values(result.provenance.financialMetrics)) {
    assert.equal(metric.observations.length, 3);
    for (const observation of metric.observations) {
      assert.match(observation.url, /^https:\/\/www\.sec\.gov\/Archives\/edgar\/data\/1978954\//);
      assert.ok(observation.availableDate <= result.asOfDate);
      assert.equal(observation.rawUnit, "MXN_thousand");
      assert.ok(Number.isSafeInteger(observation.rawValue));
      assert.ok(observation.row);
    }
    const comparator = metric.observations.find((row) => row.periodId === "h12025");
    assert.equal(comparator.availableDate, "2026-08-12");
    assert.equal(comparator.periodEndDate, "2025-06-30");
    assert.equal(comparator.coefficient, -1);
  }
  assert.equal(result.availabilityPrecision, "date_only_no_intraday_claim");
});

test("official annual capital budget is retained separately from cash PPE and maintenance assumptions", () => {
  const result = buildTbbbEconomicInputs(sourceInput());
  const budget = result.capitalInvestmentBudget;
  assert.equal(budget.targetFiscalYear, 2026);
  assert.equal(budget.source.availableDate, "2026-05-27");
  assert.match(budget.source.url, /241914\/tbbb-ex99_2\.htm$/);
  assert.equal(budget.currency, "MXN");
  assert.equal(budget.unit, "million");
  assert.equal(budget.totalM, 5250);
  assert.equal(budget.newStoresM, 3555);
  assert.equal(budget.newDistributionCentersM, 490);
  assert.equal(budget.newDistributionCenterCount, 4);
  assert.equal(budget.remainingUnclassifiedM,
    budget.totalM - budget.newStoresM - budget.newDistributionCentersM);
  assert.equal(budget.remainingLabel, "analyst_difference_not_maintenance_capex");
  assert.equal(budget.q1DeploymentM, 1089.705);
  assert.equal(budget.q1CashPpeM, 706.574);
  assert.equal(budget.fullYearCashOnlyCapexM, null);
  assert.equal(budget.includedInCashFlowBridge, false);
  assert.equal(budget.modelConsumption, "not_applied_requires_cash_noncash_reconciliation");
  assert.equal(result.cashFlowBridge.economicCashFlowM, 577.455);
  assert.equal(result.cashFlowBridge.normalizedFcfeM, null);
});

test("a previous node cannot consume Q2 sources or the current-share count", () => {
  assertBlocked(sourceInput({ asOfDate: "2026-08-11" }), "official_source_not_available");
  assertBlocked(sourceInput({ periodEndDate: "2026-03-31" }), "unsupported_period_end_date");
  assertBlocked(sourceInput({ asOfDate: "2027-01-01" }), "evidence_not_reviewed_through_as_of_date");
  assertBlocked(sourceInput({ asOfDate: "2026-02-30" }), "invalid_as_of_date");
  assertBlocked(sourceInput({ asOfDate: "2026-08-12T10:00:00Z" }), "invalid_as_of_date");
  assert.equal(buildTbbbEconomicInputs(sourceInput({ asOfDate: "2026-08-12" })).status, "ready");
});

test("local source availability and identity also fail closed", () => {
  assertBlocked(sourceInput({
    rawSourceRecord: { ticker: "TBBB", ttm: { datekey: "2026-09-06" } }
  }), "source_record_not_available");
  assertBlocked(sourceInput({
    rawSourceRecord: { ticker: "TBBB", available_at: "not-a-date" }
  }), "invalid_source_record_availability_date");
  assertBlocked(sourceInput({ rawSourceRecord: { ticker: "OTHER" } }), "source_record_issuer_mismatch");
  assertBlocked(sourceInput({ rawSourceRecord: { cik: "1001" } }), "source_record_issuer_mismatch");
  assertBlocked(sourceInput({ rawSourceRecord: { reportperiod: "2026-03-31" } }), "source_record_period_mismatch");
});

test("currency, units, missing values, actual-versus-TTM and capex definition must match", () => {
  assertBlocked(sourceInput({ sourceCurrency: "USD" }), "source_currency_mismatch");
  for (const value of [null, undefined, NaN, Infinity, "7011.837", 7_011_837, 4_285.393, 7011.838, 7011.8371]) {
    assertBlocked(sourceInput({ sourceCfo: value }), "source_amount_not_reconciled");
  }
  assertBlocked(sourceInput({ sourceRevenue: 26_037.292 }), "source_amount_not_reconciled");
  assertBlocked(sourceInput({ sourceCapex: 3772.283 }), "source_amount_not_reconciled");
  assertBlocked(sourceInput({ sourceCapex: 3800.501 }), "source_amount_not_reconciled");
});

test("missing/malformed lineage blocks, JSON lineage works and caller objects stay unchanged", () => {
  for (const rawSourceRecord of [null, undefined, {}, [], "bad JSON"]) {
    assertBlocked(sourceInput({ rawSourceRecord }), "missing_or_invalid_raw_source_record");
  }
  const original = sourceInput();
  const copy = structuredClone(original);
  const result = buildTbbbEconomicInputs(original);
  result.provenance.rawSourceRecord.datekey = "2099-01-01";
  assert.deepEqual(original, copy);
  assert.equal(buildTbbbEconomicInputs(sourceInput({
    rawSourceRecord: JSON.stringify(copy.rawSourceRecord)
  })).status, "ready");
  assert.equal(buildTbbbEconomicInputs(null).status, "blocked");
});

test("reported aggregate claim counts reconcile without an ADR ratio or public-float substitution", () => {
  const result = buildTbbbEconomicInputs(sourceInput());
  const claims = result.shareClaims;
  assert.equal(result.issuer.securityFactor, 1);
  assert.equal(claims.allIssuedShares, 121_187_774);
  assert.equal(claims.allIssuedSharesM, 121.187774);
  assert.equal(claims.fixedClaims, 130_323_391);
  assert.equal(claims.fixedClaimsM, 130.323391);
  assert.equal(claims.maximumFullyExercisedShares, 172_046_203);
  assert.deepEqual(claims.options.map((row) => [row.count, row.weightedAverageStrikeUsd]), [
    [37_640_312, 5.73], [4_082_500, 32.91]
  ]);
  for (const row of [...claims.options, ...claims.conditionalAwards]) {
    assert.equal(row.availableDate, "2026-08-12");
    assert.equal(row.periodEndDate, "2026-06-30");
    assert.match(row.url, /346965/);
  }
});

test("bridge and share observations do not depend on a caller's market price", () => {
  const low = buildTbbbEconomicInputs(sourceInput({ marketPriceUsd: 1 }));
  const high = buildTbbbEconomicInputs(sourceInput({ marketPriceUsd: 1000 }));
  assert.deepEqual(low, high);
});

test("intrinsic helper exercises strictly above a pool strike using model valuation price", () => {
  const atLegacy = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: 5.73 });
  assert.equal(atLegacy.status, "ready");
  assert.equal(atLegacy.issuedOptionShares, 0);
  assert.equal(atLegacy.estimatedGrossExerciseCashUsdM, 0);
  assert.equal(atLegacy.treasuryEquivalentShareClaimsM, 130.323391);
  const between = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: 20 });
  assert.equal(between.issuedOptionShares, 37_640_312);
  assert.equal(between.optionPools[1].exercised, false);
  close(between.estimatedGrossExerciseCashUsdM, 215.67898776);
  const atPost = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: 32.91 });
  assert.equal(atPost.issuedOptionShares, 37_640_312);
  assert.equal(atPost.optionPools[1].netDilutiveSharesM, 0);
  const above = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: 40 });
  assert.equal(above.issuedOptionShares, 41_722_812);
  assert.equal(above.grossShareClaimsM, 172.046203);
  close(above.estimatedGrossExerciseCashUsdM, 350.03406276);
  close(above.treasuryEquivalentShareClaimsM, 163.295351431);
  assert.equal(above.exerciseCashAddedToCurrentCashM, 0);
  assert.ok(above.warnings.includes("intrinsic_only_excludes_option_time_value"));
});

test("intrinsic shares are continuous through strikes and satisfy the exercise-cash identity", () => {
  for (const price of [1, 5.73, 5.730001, 20, 32.91, 32.910001, 40, 100]) {
    const result = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: price });
    close(result.treasuryEquivalentShareClaimsM,
      result.grossShareClaimsM - result.estimatedGrossExerciseCashUsdM / price);
    assert.ok(result.treasuryEquivalentShareClaimsM >= 130.323391);
    assert.ok(result.treasuryEquivalentShareClaimsM <= 172.046203);
  }
  for (const strike of [5.73, 32.91]) {
    const below = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: strike - 1e-8 });
    const above = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: strike + 1e-8 });
    close(below.treasuryEquivalentShareClaimsM, above.treasuryEquivalentShareClaimsM, 1e-6);
  }
});

test("helper cannot use stale periods, missing valuation price or substitute market price", () => {
  for (const valuationPriceUsd of [undefined, null, "35", -1, 0, NaN, Infinity]) {
    assert.equal(calculateTbbbIntrinsicExerciseDilution({
      ...dates, valuationPriceUsd, marketPriceUsd: 35
    }).status, "blocked");
  }
  assert.equal(calculateTbbbIntrinsicExerciseDilution({
    ...dates, asOfDate: "2026-08-11", valuationPriceUsd: 35
  }).reason, "official_source_not_available");
  assert.equal(calculateTbbbIntrinsicExerciseDilution({
    ...dates, periodEndDate: "2025-12-31", valuationPriceUsd: 35
  }).reason, "unsupported_period_end_date");
  const lowMarket = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: 20, marketPriceUsd: 1 });
  const highMarket = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: 20, marketPriceUsd: 1000 });
  assert.deepEqual(lowMarket, highMarket);
});

test("published US$35 net-share illustration stays reference-only because strikes are rounded", () => {
  const result = calculateTbbbIntrinsicExerciseDilution({ ...dates, valuationPriceUsd: 35 });
  close(result.treasuryEquivalentShareClaimsM, 162.04522977828573);
  assert.notEqual(result.treasuryEquivalentShareClaimsM, 162.047684);
  assert.ok(Object.isFrozen(TBBB_ECONOMIC_EVIDENCE.shareClaims.options));
  assert.ok(result.warnings.includes("rounded_strikes_produce_approximate_exercise_cash"));
});
