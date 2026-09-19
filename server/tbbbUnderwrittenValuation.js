import { readFileSync } from "node:fs";
import { buildTbbbEconomicInputs } from "./tbbbEconomicInputs.js";
import { recomputeTbbbFinancialTrend } from "./tbbbValuationCandidate.js";

function freeze(value) {
  if (value && typeof value === "object") {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}

// A dated, explicit analyst underwriting record, not silent model defaults.
export const TBBB_UNDERWRITING = freeze(JSON.parse(readFileSync(
  new URL("./config/tbbb-underwriting-2026-09-05.json", import.meta.url), "utf8"
)));

const C = TBBB_UNDERWRITING;
const sum = (values) => values.reduce((a, b) => a + b, 0);
const close = (a, b, tolerance = 1e-8) => Number.isFinite(a) && Math.abs(a - b) <= tolerance;
const days = (from, to) => (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000;
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
const fail = (reason) => ({ status: "blocked", releaseReady: false, reason, version: C.version });

export function deriveTbbbUnderwritingAnchors(economics) {
  if (economics?.status !== "ready" || economics.asOfDate !== C.asOfDate ||
      economics.periodEndDate !== C.periodEndDate || !economics.shareClaims ||
      !economics.cashFlowBridge || !economics.matchedInputs) return fail("audited_current_economic_bridge_required");
  const p = C.reported;
  const periods = Object.fromEntries(["fy2025", "fy2024", "h12026", "h12025"].map((id) => {
    const row = p[id];
    const wcM = sum(row.wcMovementsM);
    const afterTaxLeaseAndInterestCashProfitM = row.cfoM - wcM - row.leasePrincipalM - row.leaseInterestM - row.otherInterestM;
    return [id, { ...row, wcM, afterTaxLeaseAndInterestCashProfitM,
      operatingMargin: afterTaxLeaseAndInterestCashProfitM / row.revenueM }];
  }));
  const ttm = {};
  for (const key of ["revenueM", "wcM", "afterTaxLeaseAndInterestCashProfitM"]) {
    ttm[key] = periods.fy2025[key] + periods.h12026[key] - periods.h12025[key];
  }
  ttm.operatingMargin = ttm.afterTaxLeaseAndInterestCashProfitM / ttm.revenueM;
  const priorTtmRevenueM = p.fy2024.revenueM + p.h12025.revenueM - p.h12024.revenueM;
  const incrementalRevenueTtmM = ttm.revenueM - priorTtmRevenueM;
  const wcCoefficients = {
    ttm: ttm.wcM / incrementalRevenueTtmM,
    fy2025: periods.fy2025.wcM / (p.fy2025.revenueM - p.fy2024.revenueM)
  };
  const q1NoncashM = p.budget.q1DebtFinancedPpeM + sum(p.budget.q1EquipmentLeaseAdditionsM);
  const fy2025EconomicEquipmentInvestmentM = p.fy2025.cashPpeM + p.fy2025.noncashDebtPpeM + sum(p.fy2025.noncashEquipmentLeaseM);
  const cashFractions = {
    q12026: (p.budget.q1CashPpeM + p.budget.q1CashIntangiblesM) / (p.budget.q1DeploymentM + p.budget.q1CashIntangiblesM),
    fy2025: (p.fy2025.cashPpeM + p.fy2025.intangiblesM) / (fy2025EconomicEquipmentInvestmentM + p.fy2025.intangiblesM)
  };
  const h1 = p.h12026;
  const h1AfterDebtPrincipalM = h1.cfoM - h1.cashPpeM + h1.ppeDisposalsM - h1.intangiblesM -
    h1.leasePrincipalM - h1.leaseInterestM - h1.otherInterestM - h1.otherDebtPrincipalM;
  const h1ReserveIncreaseM = p.balanceSheet.cashJune2026M - p.balanceSheet.cashDecember2025M;
  const h1KnownCashNetBorrowingM = h1.netCreditLineCashM + h1.supplierFinanceProceedsM - h1.supplierFinanceRepaymentsM;
  const knownExerciseGross = sum(p.knownExercises.map((x) => x.grossOptions));
  const knownWithheld = sum(p.knownExercises.map((x) => x.withheldShares));
  const shareClaims = {
    juneReportedIssued: economics.shareClaims.allIssuedShares,
    juneReportedFixedConditionalClaims: economics.shareClaims.fixedClaims,
    juneMaximumClaims: economics.shareClaims.maximumFullyExercisedShares,
    knownExerciseGross, knownWithheld, knownNetIssued: knownExerciseGross - knownWithheld,
    knownAdjustedIssuedNotCompleteSeptemberCount: economics.shareClaims.allIssuedShares + knownExerciseGross - knownWithheld,
    knownAdjustedLegacyOptionsNotCompleteTrancheSchedule: 37640312 - knownExerciseGross,
    conservativeCurrentMaximumClaims: economics.shareClaims.maximumFullyExercisedShares - knownWithheld,
    hypotheticalFutureExerciseProceedsM: 0,
    currentOptionTimeValueSeparateReserveM: 0,
    timeValueTreatment: "one_full_share_per_option_is_a_claim_upper_bound_including_time_value_not_an_intrinsic_or_zero_time_value_estimate",
    events: p.knownExercises.map((event) => ({ ...event, source: C.sources[event.sourceId] }))
  };
  const anchors = {
    status: "ready", label: "calculated_from_dated_reported_actuals", periods, ttm,
    priorTtmRevenueM, incrementalRevenueTtmM, wcCoefficients,
    q1NoncashM, fy2025EconomicEquipmentInvestmentM, cashFractions,
    q1ReportedCashPpeToDeployment: p.budget.q1CashPpeM / p.budget.q1DeploymentM,
    cashFractionNormalization: "add_separately_reported_cash_intangibles_to_both_sides_to_match_inclusive_forward_budget_not_a_reported_ratio",
    otherDebtPrincipalRatio: economics.cashFlowBridge.otherDebtPrincipalNotIncludedM / ttm.revenueM,
    operatingCashReserveRatio: p.balanceSheet.cashJune2026M / ttm.revenueM,
    h1AfterDebtPrincipalM, h1ReserveIncreaseM, h1KnownCashNetBorrowingM,
    h1AfterDebtPrincipalAndCashBorrowingM: h1AfterDebtPrincipalM + h1KnownCashNetBorrowingM,
    h1AfterDebtPrincipalAndReserveM: h1AfterDebtPrincipalM + h1KnownCashNetBorrowingM - h1ReserveIncreaseM,
    shareClaims
  };
  // Do not allow a changed financial adapter to silently contaminate this dated forecast.
  if (!close(ttm.revenueM, economics.matchedInputs.sourceRevenue) ||
      !close(ttm.afterTaxLeaseAndInterestCashProfitM + ttm.wcM - economics.cashFlowBridge.netPpeCapexM -
        economics.cashFlowBridge.intangibleCapexM, economics.cashFlowBridge.economicCashFlowM) ||
      !close(p.budget.q1CashPpeM + q1NoncashM, p.budget.q1DeploymentM) ||
      shareClaims.conservativeCurrentMaximumClaims !== 172019688 ||
      !Number.isFinite(anchors.otherDebtPrincipalRatio)) return fail("underwriting_anchor_reconciliation_failed");
  return anchors;
}

/** A current-only, fully reproducible analyst baseline and anchored stresses.
 * Does not accept market price, write a database, publish a result, or attest an
 * independent release approval. A methodReady result is suitable for that audit.
 */
export function calculateTbbbUnderwrittenValuation(input = {}) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return fail("invalid_input");
  const scenario = C.scenarios[input.scenarioId];
  if (!scenario) return fail("explicit_reviewed_scenario_id_required");
  if (input.economicInput?.asOfDate !== C.asOfDate || input.economicInput?.periodEndDate !== C.periodEndDate) {
    return fail("underwriting_is_current_dated_only_not_a_historical_profile");
  }
  if (Object.values(C.sources).some((source) => source.availableDate > input.economicInput.asOfDate)) {
    return fail("underwriting_source_not_available");
  }
  const economics = buildTbbbEconomicInputs(input.economicInput);
  if (economics.status !== "ready") return economics;
  const anchors = deriveTbbbUnderwritingAnchors(economics);
  if (anchors.status !== "ready") return anchors;
  const trend = recomputeTbbbFinancialTrend({ ...input, asOfDate: C.asOfDate, periodEndDate: C.periodEndDate });
  if (trend.status !== "ready") return trend;
  const macro = C.reported.macro;
  const spot = macro.ecbMxnPerEur / macro.ecbUsdPerEur;
  if (input.fx?.baseCurrency !== "USD" || input.fx?.quoteCurrency !== "MXN" ||
      input.fx?.rateDate !== "2026-09-04" || input.fx?.availableDate !== "2026-09-04" ||
      !close(input.fx?.mxnPerUsd, spot)) return fail("dated_ecb_cross_not_reconciled");

  const policy = C.analystPolicies;
  const boundedGuidePct = clamp(scenario.rawGuideGrowth * 100, trend.baseGrowthPct - 15, trend.baseGrowthPct + 15);
  const blendedPct = trend.baseGrowthPct * (1 - policy.guideWeight) + boundedGuidePct * policy.guideWeight;
  const appliedGrowth = clamp(blendedPct, -20, input.growthPolicySettings.normalizedGrowthCapPct) / 100;
  const g = policy.terminalRevenueGrowth;
  const fy2026RevenueM = C.reported.fy2025.revenueM * (1 + appliedGrowth);
  const operatingMargin = scenario.operatingMarginAnchor === "ttm" ? anchors.ttm.operatingMargin :
    anchors.periods[scenario.operatingMarginAnchor].operatingMargin;
  const leaseServiceAnchor = scenario.operatingMarginAnchor === "ttm" ? {
    revenueM: anchors.ttm.revenueM, leasePrincipalM: economics.cashFlowBridge.leasePrincipalM,
    leaseInterestM: economics.cashFlowBridge.leaseInterestM, otherInterestM: economics.cashFlowBridge.otherDebtInterestM
  } : anchors.periods[scenario.operatingMarginAnchor];
  const serviceRatios = Object.fromEntries(["leasePrincipalM", "leaseInterestM", "otherInterestM"].map((key) =>
    [key, leaseServiceAnchor[key] / leaseServiceAnchor.revenueM]));
  const wcCoefficient = anchors.wcCoefficients[scenario.workingCapitalAnchor];
  const cashFraction = anchors.cashFractions[scenario.cashFinancingAnchor];
  const budget = C.reported.budget;
  const recurringCapitalM = budget.totalM - budget.newStoresM - budget.newDcsM;
  const recurringCapitalRatio = recurringCapitalM / fy2026RevenueM;
  const expansionCapitalCoefficient = (budget.newStoresM + budget.newDcsM) /
    (fy2026RevenueM - C.reported.fy2025.revenueM);
  const currentClaims = anchors.shareClaims.conservativeCurrentMaximumClaims;
  const annualNewAwardShares = C.reported.futureGrantAnchor.newOptions + C.reported.futureGrantAnchor.newRsus;
  const annualNewAwardRatio = annualNewAwardShares / currentClaims;
  const keep = 1 / (1 + annualNewAwardRatio);
  const riskFreeUsd = macro.tenYearTreasury - macro.usDefaultSpread;
  const keUsd = riskFreeUsd + policy.beta * macro.matureErp + macro.mexicoCrp + scenario.executionPremium;
  const currencyParityRatio = (1 + policy.inflationMxn) / (1 + policy.inflationUsd);
  const keMxn = (1 + keUsd) * currencyParityRatio - 1;
  const perClaimTerminalGrowth = (1 + g) * keep - 1;
  const stubYears = days(C.asOfDate, "2026-12-31") / 365;

  function annualCash(previousRevenueM, revenueM, previousCashReserveM) {
    const incrementalRevenueM = revenueM - previousRevenueM;
    const cashOperatingProfitM = revenueM * operatingMargin;
    const embeddedLeasePrincipalM = revenueM * serviceRatios.leasePrincipalM;
    const embeddedLeaseInterestM = revenueM * serviceRatios.leaseInterestM;
    const embeddedOtherDebtInterestM = revenueM * serviceRatios.otherInterestM;
    const operatingWorkingCapitalCashBenefitM = incrementalRevenueM * wcCoefficient;
    const recurringCapitalAllowanceM = revenueM * recurringCapitalRatio;
    const expansionCapitalM = Math.max(0, incrementalRevenueM) * expansionCapitalCoefficient;
    const capitalProgramM = recurringCapitalAllowanceM + expansionCapitalM;
    const cashCapitalExpenditureIncludingSoftwareM = capitalProgramM * cashFraction;
    const noncashEquipmentFinancingM = capitalProgramM - cashCapitalExpenditureIncludingSoftwareM;
    const otherDebtPrincipalM = revenueM * anchors.otherDebtPrincipalRatio;
    const endingOperatingCashReserveM = revenueM * anchors.operatingCashReserveRatio;
    const increaseInOperatingCashReserveM = endingOperatingCashReserveM - previousCashReserveM;
    const companyFcfeM = cashOperatingProfitM + operatingWorkingCapitalCashBenefitM -
      cashCapitalExpenditureIncludingSoftwareM - otherDebtPrincipalM - increaseInOperatingCashReserveM;
    return { revenueM, incrementalRevenueM, cashOperatingProfitM,
      cashOperatingProfitBeforeLeaseAndDebtInterestM: cashOperatingProfitM + embeddedLeasePrincipalM + embeddedLeaseInterestM + embeddedOtherDebtInterestM,
      embeddedLeasePrincipalM, embeddedLeaseInterestM, embeddedOtherDebtInterestM, operatingWorkingCapitalCashBenefitM,
      recurringCapitalAllowanceM, recurringCapitalLabel: "analyst_allowance_not_reported_maintenance_capex",
      expansionCapitalM, capitalProgramM, cashCapitalExpenditureIncludingSoftwareM,
      additionalIntangibleChargeM: 0, noncashEquipmentFinancingM,
      additionalLeaseServiceM: 0, leaseServiceTreatment: "all_lease_principal_and_interest_already_in_operating_margin",
      otherDebtPrincipalM, extraSupplierFinanceDeductionM: 0, cashNetBorrowingM: 0,
      endingOperatingCashReserveM, increaseInOperatingCashReserveM, companyFcfeM,
      companyFcfeMargin: companyFcfeM / revenueM };
  }

  const fy2026 = annualCash(C.reported.fy2025.revenueM, fy2026RevenueM, C.reported.balanceSheet.cashDecember2025M);
  // H1 actual borrowing is already in the June balance sheet. Preserve it in
  // BOTH the full-year forecast and the actual H1 comparator; only future cash
  // borrowing is assumed zero. Equity-offering proceeds are not FCFE income.
  fy2026.normalizedFcfeBeforeKnownCashBorrowingM = fy2026.companyFcfeM;
  fy2026.cashNetBorrowingM = anchors.h1KnownCashNetBorrowingM;
  fy2026.cashNetBorrowingTreatment = "reported_H1_net_credit_line_and_supplier_finance_cash_future_H2_zero_no_equity_issuance_credit";
  fy2026.companyFcfeM += anchors.h1KnownCashNetBorrowingM;
  fy2026.companyFcfeMargin = fy2026.companyFcfeM / fy2026.revenueM;
  const h2CompanyFcfeM = fy2026.companyFcfeM - anchors.h1AfterDebtPrincipalAndReserveM;
  const elapsedH2Days = days("2026-06-30", C.asOfDate);
  const remainingH2Days = days(C.asOfDate, "2026-12-31");
  const totalH2Days = elapsedH2Days + remainingH2Days;
  const estimatedPostJuneCashAtAsOfM = h2CompanyFcfeM * elapsedH2Days / totalH2Days;
  const remainingStubFcfeM = h2CompanyFcfeM * remainingH2Days / totalH2Days;
  // Attribute opening deposits and all remaining H2 cash economically in Dec26,
  // after the first future-award batch. USD deposits stay USD; MXN cash stays MXN.
  const usdDepositM = C.reported.balanceSheet.usdBankDepositsM;
  const cashAssetPvUsdM = usdDepositM * keep / (1 + keUsd) ** stubYears;
  const cashAssetPvMxnM = cashAssetPvUsdM * spot;
  const h2CashPvMxnM = h2CompanyFcfeM * keep / (1 + keMxn) ** stubYears;
  const depositValueMxnAtYearEndM = usdDepositM * spot * currencyParityRatio ** stubYears;
  let retainedFundingBalanceM = depositValueMxnAtYearEndM + h2CompanyFcfeM;
  const funding = [{ fiscalYear: 2026, retainedFundingBalanceM,
    label: "conditional_no_distributions_no_deposit_interest_funding_stress_check" }];
  const forecast = [];
  let previousRevenueM = fy2026RevenueM;
  let previousCashReserveM = fy2026.endingOperatingCashReserveM;
  for (let index = 0; index < 5; index += 1) {
    const fiscalYear = 2027 + index;
    const revenueGrowth = appliedGrowth + (g - appliedGrowth) * (index + 1) / policy.growthFadeYears;
    const row = annualCash(previousRevenueM, previousRevenueM * (1 + revenueGrowth), previousCashReserveM);
    const ownershipRetention = keep ** (index + 2);
    const attributableFcfeM = row.companyFcfeM * ownershipRetention;
    const timeYears = stubYears + index + 1;
    const pvMxnM = attributableFcfeM / (1 + keMxn) ** timeYears;
    const futureMxnPerUsd = spot * currencyParityRatio ** timeYears;
    const equivalentUsdPvM = attributableFcfeM / futureMxnPerUsd / (1 + keUsd) ** timeYears;
    forecast.push({ fiscalYear, label: "analyst_forecast_not_management_guidance", revenueGrowth, ...row,
      ownershipRetention, cumulativeFutureAwardBatches: index + 2,
      maximumFutureAwardAdjustedShares: currentClaims / ownershipRetention,
      futureAwardCashExpenseM: 0, attributableFcfeM, timeYears, pvMxnM, equivalentUsdPvM });
    retainedFundingBalanceM += row.companyFcfeM;
    funding.push({ fiscalYear, retainedFundingBalanceM });
    previousRevenueM = row.revenueM;
    previousCashReserveM = row.endingOperatingCashReserveM;
  }
  const last = forecast.at(-1);
  const terminalFcfeM = last.attributableFcfeM * (1 + perClaimTerminalGrowth);
  const terminalValueMxnM = terminalFcfeM / (keMxn - perClaimTerminalGrowth);
  const terminalPvMxnM = terminalValueMxnM / (1 + keMxn) ** last.timeYears;
  const explicitPvMxnM = sum(forecast.map((row) => row.pvMxnM));
  const operatingValueMxnM = h2CashPvMxnM + explicitPvMxnM + terminalPvMxnM;
  const equityValueMxnM = operatingValueMxnM + cashAssetPvMxnM;
  const terminalValueShare = terminalPvMxnM / operatingValueMxnM;
  const fundingDeficitM = Math.max(0, -Math.min(...funding.map((row) => row.retainedFundingBalanceM)));
  const checks = {
    allSourcesAvailable: true, actualCashBridgeReconciled: true, currentDateOnly: true,
    guidanceWeightWithinPolicy: policy.guideWeight <= 0.25,
    guidanceBoundWithin15pp: Math.abs(boundedGuidePct - trend.baseGrowthPct) <= 15,
    capitalBudgetReconciled: close(fy2026.capitalProgramM, budget.totalM),
    cashNoncashInvestmentReconciled: [fy2026, ...forecast].every((row) => close(
      row.capitalProgramM, row.cashCapitalExpenditureIncludingSoftwareM + row.noncashEquipmentFinancingM)),
    sourceCurrencyAndDiscountConsistent: forecast.every((row) => close(row.pvMxnM / spot, row.equivalentUsdPvM)),
    fiveExplicitForecastYears: forecast.length === 5,
    terminalCashPositive: terminalFcfeM > 0,
    terminalGrowthBounds: perClaimTerminalGrowth >= 0.01 && perClaimTerminalGrowth <= 0.04,
    discountBounds: keMxn >= 0.085 && keMxn <= 0.18,
    terminalSpreadAtLeast045: keMxn - perClaimTerminalGrowth >= 0.045,
    terminalValueShareAtMost080: terminalValueShare > 0 && terminalValueShare <= 0.8,
    noCashFundingDeficitUnderRetention: fundingDeficitM === 0,
    positiveEquityValue: equityValueMxnM > 0,
    noMarketPriceInput: true
  };
  const methodReady = Object.values(checks).every(Boolean);
  return {
    status: methodReady ? "underwritten_ready_for_independent_release_review" : "underwritten_stress_requires_qualification",
    methodReady, releaseReady: false,
    releaseApproval: "parent_must_complete_independent_model_source_and_integration_audit",
    version: C.version, asOfDate: C.asOfDate, periodEndDate: C.periodEndDate,
    scenarioId: input.scenarioId, scenario, security: economics.issuer,
    valuationLabel: "conditional_conservative_full_share_claim_FCFE_not_exact_option_fair_value",
    inputsAreActualOrExplicitDatedAnalystAssumptions: true,
    economicCashBridge: economics.cashFlowBridge, anchors,
    guidanceAudit: { financialTrend: trend, rawGuideGrowth: scenario.rawGuideGrowth,
      boundedGuidePct, appliedWeight: policy.guideWeight, appliedGrowth,
      fy2026RevenueM, revenueAmountLabel: "analyst_blend_translation_NOT_issuer_amount_guidance" },
    analystAssumptions: { ...policy, operatingMargin, serviceRatios, wcCoefficient, cashFraction,
      recurringCapitalRatio, expansionCapitalCoefficient, annualNewAwardShares, annualNewAwardRatio,
      ownershipRetentionPerBatch: keep, riskFreeUsd, keUsd, keMxn, currencyParityRatio,
      terminalCompanyRevenueGrowth: g, terminalPerCurrentClaimGrowth: perClaimTerminalGrowth },
    fy2026,
    stub: { elapsedH2Days, remainingH2Days, totalH2Days, estimatedPostJuneCashAtAsOfM,
      remainingStubFcfeM, h2CompanyFcfeM, paymentDate: "2026-12-31", timeYears: stubYears,
      ownershipRetention: keep, h2CashPvMxnM,
      allocationLabel: "uniform_H2_analyst_nowcast_and_December_economic_distribution_not_actual_interim_results" },
    cashAsset: { source: C.sources.h12026, usdDepositM, reportedPrecisionUsdM: 1,
      dateOfReportedBalance: "2026-06-30", cashAssetPvUsdM, cashAssetPvMxnM,
      treatment: "USD_deposit_retained_in_USD_until_Dec26_after_first_award_batch_no_interest_credit_operating_cash_reserved_separately" },
    forecast, terminal: { companyRevenueGrowth: g, perCurrentClaimGrowth: perClaimTerminalGrowth,
      terminalFcfeM, terminalValueMxnM, terminalPvMxnM, terminalValueShare },
    funding: { policy: "retain_all_cash_no_dividends_no_new_cash_borrowing_no_deposit_interest", schedule: funding,
      fundingDeficitM, limitation: "conditional_ratio_based_equipment_financing_and_service_not_a_complete_credit_facility_schedule" },
    value: { currency: "USD", equityValueMxnM, equityValueUsdM: equityValueMxnM / spot,
      shareClaimDenominator: currentClaims, shareClaimDenominatorLabel: "conditional_current_maximum_not_basic_shares",
      fairValueUsd: methodReady ? equityValueMxnM / spot / (currentClaims / 1e6) : null,
      conditionalMechanicalValueUsd: methodReady ? null : equityValueMxnM / spot / (currentClaims / 1e6),
      conditionalMechanicalValueTreatment: methodReady ? null : "not_a_publishable_target_requires_failed_checks_and_financing_resolution",
      unroundedModelOutputNotStatisticalPrecision: true, explicitPvMxnM, operatingValueMxnM },
    fx: { rateDate: "2026-09-04", mxnPerUsd: spot, sources: [C.sources.ecbMxn, C.sources.ecbUsd],
      forecastFxLabel: "analyst_inflation_parity_not_market_forward" },
    checks, failedChecks: Object.entries(checks).filter(([, passed]) => !passed).map(([key]) => key),
    sources: C.sources, limitations: C.limits
  };
}
