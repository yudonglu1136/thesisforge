import { readFileSync } from "node:fs";

function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.values(value).forEach(deepFreeze);
    Object.freeze(value);
  }
  return value;
}

export const TBBB_ECONOMIC_EVIDENCE = deepFreeze(JSON.parse(readFileSync(
  new URL("./config/tbbb-economic-evidence.json", import.meta.url), "utf8"
)));

const evidence = TBBB_ECONOMIC_EVIDENCE;
const AVAILABILITY_KEYS = new Set([
  "datekey", "availabledate", "availableat", "financialavailableat",
  "sourceavailabledate", "sourceavailableat", "filingdate", "fileddate", "filedat"
]);

function blocked(reason, details = {}) {
  // Failed checks deliberately expose no current shares or usable cash-flow value.
  return { status: "blocked", evidenceId: evidence.evidenceId, reason, ...details };
}

function isDateOnly(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function periodGate({ asOfDate, periodEndDate } = {}) {
  if (!isDateOnly(asOfDate)) return blocked("invalid_as_of_date");
  if (!isDateOnly(periodEndDate) || periodEndDate !== evidence.periodEndDate) {
    return blocked("unsupported_period_end_date");
  }
  if (asOfDate < evidence.availableDate ||
      Object.values(evidence.sources).some((source) => source.availableDate > asOfDate)) {
    return blocked("official_source_not_available");
  }
  if (asOfDate > evidence.reviewedThroughDate) {
    return blocked("evidence_not_reviewed_through_as_of_date");
  }
  return null;
}

function sourceRef(sourceId, locator) {
  const source = evidence.sources[sourceId];
  return { sourceId, ...source, ...(locator ? { locator } : {}) };
}

function deriveTtm(metric) {
  const observations = evidence.financialPeriods.map((period) => {
    const valueK = period.values[metric];
    const coefficient = evidence.ttmFormula[period.id];
    if (!Number.isSafeInteger(valueK) || !Number.isInteger(coefficient)) {
      throw new Error(`Invalid TBBB public evidence for ${period.id}/${metric}`);
    }
    return {
      periodId: period.id, periodStartDate: period.periodStartDate,
      periodEndDate: period.periodEndDate, label: period.label,
      rawValue: valueK, rawUnit: "MXN_thousand", coefficient,
      row: evidence.financialMetrics[metric].label,
      ...sourceRef(period.sourceId)
    };
  });
  const valueK = observations.reduce((sum, row) => sum + row.rawValue * row.coefficient, 0);
  return {
    valueK, valueM: valueK / 1000, currency: "MXN", unit: "million",
    label: "analyst_calculation_from_reported_actuals",
    formula: "FY2025 + H1_2026 - H1_2025",
    observations
  };
}

function inputMillionToThousand(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const scaled = value * 1000;
  const integer = Math.round(scaled);
  // Accept floating-point noise, never different units or sub-thousand input rounding.
  return Number.isSafeInteger(integer) && Math.abs(scaled - integer) <= 1e-6 ? integer : null;
}

function checkRawRecord(rawSourceRecord, asOfDate) {
  let record;
  try {
    const parsed = typeof rawSourceRecord === "string" ? JSON.parse(rawSourceRecord) : rawSourceRecord;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || !Object.keys(parsed).length) {
      return { error: blocked("missing_or_invalid_raw_source_record") };
    }
    record = JSON.parse(JSON.stringify(parsed));
  } catch {
    return { error: blocked("missing_or_invalid_raw_source_record") };
  }
  for (const key of ["ticker", "symbol"]) {
    if (record[key] != null && String(record[key]).toUpperCase() !== evidence.issuer.ticker) {
      return { error: blocked("source_record_issuer_mismatch") };
    }
  }
  if (record.cik != null && String(record.cik).replace(/^0+/, "") !== evidence.issuer.cik) {
    return { error: blocked("source_record_issuer_mismatch") };
  }
  for (const key of ["periodEndDate", "reportperiod", "calendardate"]) {
    if (record[key] != null && record[key] !== evidence.periodEndDate) {
      return { error: blocked("source_record_period_mismatch") };
    }
  }
  let failure;
  function visit(value, path = "rawSourceRecord") {
    if (!value || typeof value !== "object" || failure) return;
    for (const [key, nested] of Object.entries(value)) {
      const normalizedKey = key.toLowerCase().replaceAll("_", "");
      if (AVAILABILITY_KEYS.has(normalizedKey) && nested != null) {
        const date = typeof nested === "string" ? nested.slice(0, 10) : "";
        if (!isDateOnly(date) || !Number.isFinite(Date.parse(nested))) {
          failure = blocked("invalid_source_record_availability_date", { field: `${path}.${key}` });
        } else if (date > asOfDate) {
          failure = blocked("source_record_not_available", { field: `${path}.${key}`, availableDate: date });
        }
      }
      if (!failure && typeof nested === "object") visit(nested, `${path}.${key}`);
    }
  }
  visit(record);
  return failure ? { error: failure } : { record };
}

function shareClaims() {
  const claims = evidence.shareClaims;
  const source = sourceRef(claims.sourceId, claims.locator);
  const dated = { ...source, periodEndDate: claims.periodEndDate, observedUnit: "shares" };
  const issuedTotal = Object.values(claims.issuedByClass).reduce((sum, count) => sum + count, 0);
  if (issuedTotal !== claims.issuedTotal) throw new Error("TBBB issued shares do not reconcile");
  const conditionalAwards = claims.conditionalAwards.map((award) => ({
    ...award, sharesM: award.shares / 1e6, ...dated
  }));
  const options = claims.options.map((option) => ({
    ...option, count: option.shares, sharesM: option.shares / 1e6,
    strikeCurrency: "USD", strikeLabel: "issuer_reported_rounded_weighted_average", ...dated
  }));
  const fixedClaims = issuedTotal + conditionalAwards.reduce((sum, row) => sum + row.shares, 0);
  const maximumClaims = fixedClaims + options.reduce((sum, row) => sum + row.count, 0);
  return {
    periodEndDate: claims.periodEndDate,
    label: "reported_claims_with_analyst_conditional_aggregation",
    allIssuedShares: issuedTotal, allIssuedSharesM: issuedTotal / 1e6,
    basicSharesM: issuedTotal / 1e6,
    basicSharesBasis: "period_end_all_classes_not_weighted_average_eps_or_public_float",
    issuedByClass: { ...claims.issuedByClass },
    issuedShareSource: { ...dated, label: "reported_actual" },
    conditionalAwards, options,
    fixedClaims, fixedClaimsM: fixedClaims / 1e6,
    fixedClaimsLabel: "analyst_sum_issued_plus_vesting_and_delivery_conditional_nonoption_awards",
    maximumFullyExercisedShares: maximumClaims,
    maximumFullyExercisedSharesM: maximumClaims / 1e6,
    maximumClaimsLabel: "conditional_full_vesting_delivery_and_exercise_scenario_not_current_shares",
    includesExistingAwardClaims: true,
    futureGrantsForecast: null
  };
}

/**
 * Public-source bridge for the one reviewed TBBB TTM period. Inputs are nominal
 * MXN millions, capex is PPE purchases net of disposals (not gross PPE or CFO).
 * Date-only availability never attests that a filing was public intraday.
 * A ready bridge is not a normalized FCFE forecast or a valuation.
 */
export function buildTbbbEconomicInputs(input = {}) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return blocked("invalid_input");
  const gate = periodGate(input);
  if (gate) return gate;
  if (input.sourceCurrency !== "MXN") return blocked("source_currency_mismatch");
  const raw = checkRawRecord(input.rawSourceRecord, input.asOfDate);
  if (raw.error) return raw.error;

  const ttm = Object.fromEntries(Object.keys(evidence.financialMetrics).map((metric) => [metric, deriveTtm(metric)]));
  const netPpeK = ttm.ppePurchases.valueK - ttm.ppeDisposals.valueK;
  const expected = { sourceRevenue: ttm.revenue.valueK, sourceCfo: ttm.cfo.valueK, sourceCapex: netPpeK };
  for (const [metric, expectedK] of Object.entries(expected)) {
    if (inputMillionToThousand(input[metric]) !== expectedK) {
      return blocked("source_amount_not_reconciled", { metric, expectedM: expectedK / 1000 });
    }
  }
  const deductionKeys = ["leasePrincipal", "leaseInterest", "otherDebtInterest", "intangibleCapex"];
  const deductionK = deductionKeys.reduce((sum, metric) => sum + ttm[metric].valueK, 0);
  const economicCashFlowK = ttm.cfo.valueK - netPpeK - deductionK;
  const claims = shareClaims();

  return {
    status: "ready", evidenceId: evidence.evidenceId,
    asOfDate: input.asOfDate, periodEndDate: input.periodEndDate,
    periodStartDate: evidence.periodStartDate, periodType: "TTM",
    availableDate: evidence.availableDate,
    availabilityPrecision: evidence.availabilityPrecision,
    sourceCurrency: "MXN", sourceUnit: "million",
    issuer: { ...evidence.issuer, source: sourceRef(evidence.issuer.sourceId) },
    matchedInputs: {
      sourceRevenue: input.sourceRevenue, sourceCfo: input.sourceCfo, sourceCapex: input.sourceCapex,
      label: "caller_inputs_reconciled_to_public_actuals"
    },
    cashFlowBridge: {
      label: "analyst_calculation_from_reported_cash_flows",
      currency: "MXN", unit: "million",
      cfoM: ttm.cfo.valueM, grossPpeCapexM: ttm.ppePurchases.valueM,
      ppeDisposalsM: ttm.ppeDisposals.valueM, netPpeCapexM: netPpeK / 1000,
      cfoMinusNetPpeM: (ttm.cfo.valueK - netPpeK) / 1000,
      leasePrincipalM: ttm.leasePrincipal.valueM,
      leaseInterestM: ttm.leaseInterest.valueM,
      otherDebtInterestM: ttm.otherDebtInterest.valueM,
      intangibleCapexM: ttm.intangibleCapex.valueM,
      afterLeaseAndDebtInterestM: (economicCashFlowK + ttm.intangibleCapex.valueK) / 1000,
      economicCashFlowM: economicCashFlowK / 1000,
      formula: "CFO - net_PPE_capex - lease_principal - lease_interest - other_debt_cash_interest - intangible_capex",
      deductions: deductionKeys.map((metric) => ({ metric, ...ttm[metric] })),
      supplierFinanceNetSupportM: (ttm.supplierFinanceInflow.valueK - ttm.supplierFinanceRepayment.valueK) / 1000,
      supplierFinanceDeductedAgainM: 0,
      supplierFinanceTreatment: { ...evidence.supplierFinancePolicy, ...sourceRef(evidence.supplierFinancePolicy.sourceId, evidence.supplierFinancePolicy.locator) },
      reportedTtmSbcM: ttm.sbc.valueM,
      sbcDeductedM: 0,
      sbcTreatment: "existing_award_claims_separate_no_duplicate_expense_deduction",
      normalizedFcfeM: null,
      modelReadiness: "cash_reconciled_requires_award_claims_and_reinvestment_schedule",
      otherDebtPrincipalNotIncludedM: ttm.otherDebtPrincipal.valueM,
      noncashFinancedEquipmentTtmM: null
    },
    shareClaims: claims,
    capitalInvestmentBudget: {
      ...structuredClone(evidence.capitalInvestmentBudget),
      source: sourceRef(evidence.capitalInvestmentBudget.sourceId),
      modelConsumption: "not_applied_requires_cash_noncash_reconciliation"
    },
    existingAwardExpense: {
      ...structuredClone(evidence.existingAwardExpense),
      source: sourceRef(evidence.existingAwardExpense.sourceId, evidence.existingAwardExpense.locator),
      mappingTreatment: "reference_only_existing_claims_not_additional_cashflow_deduction"
    },
    provenance: { financialMetrics: ttm, rawSourceRecord: raw.record },
    assumptions: [
      "Cash bridge excludes incremental financing support and has no growth forecast.",
      "Existing equity awards require a separate claim valuation; projected expense is not also deducted.",
      "Unvested and delayed-delivery awards are included only as conditional claims."
    ],
    warnings: [...evidence.limitations]
  };
}

/**
 * Conditional grouped intrinsic-exercise scenario, using only a model's USD
 * valuation price. It is not an exact tranche valuation: published average
 * strikes are rounded, and time value, vesting risk and future grants are absent.
 * No market price, FX conversion, forecast growth or target value is fetched.
 */
export function calculateTbbbIntrinsicExerciseDilution(input = {}) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return blocked("invalid_input");
  const gate = periodGate(input);
  if (gate) return gate;
  if (typeof input.valuationPriceUsd !== "number" || !Number.isFinite(input.valuationPriceUsd) || input.valuationPriceUsd <= 0) {
    return blocked("invalid_valuation_price_usd");
  }
  const claims = shareClaims();
  const price = input.valuationPriceUsd;
  const optionPools = claims.options.map((option) => {
    const exercised = price > option.weightedAverageStrikeUsd;
    const issuedShares = exercised ? option.count : 0;
    const exerciseCashUsd = issuedShares * option.weightedAverageStrikeUsd;
    const intrinsicClaimsUsd = option.count * Math.max(price - option.weightedAverageStrikeUsd, 0);
    return {
      ...option, exercised, issuedShares,
      estimatedExerciseCashUsdM: exerciseCashUsd / 1e6,
      intrinsicClaimsUsdM: intrinsicClaimsUsd / 1e6,
      netDilutiveSharesM: intrinsicClaimsUsd / price / 1e6
    };
  });
  const grossShares = optionPools.reduce((sum, row) => sum + row.issuedShares, 0);
  const exerciseCashM = optionPools.reduce((sum, row) => sum + row.estimatedExerciseCashUsdM, 0);
  const netDilutiveSharesM = optionPools.reduce((sum, row) => sum + row.netDilutiveSharesM, 0);
  return {
    status: "ready", evidenceId: evidence.evidenceId,
    asOfDate: input.asOfDate, periodEndDate: input.periodEndDate,
    availableDate: evidence.availableDate,
    label: "analyst_conditional_grouped_intrinsic_exercise_assumption",
    valuationPriceUsd: price, priceBasis: "caller_model_valuation_price_not_market_price",
    fixedClaimsM: claims.fixedClaimsM,
    issuedOptionShares: grossShares,
    grossShareClaimsM: (claims.fixedClaims + grossShares) / 1e6,
    estimatedGrossExerciseCashUsdM: exerciseCashM,
    exerciseCashAddedToCurrentCashM: 0,
    netDilutiveSharesM,
    treasuryEquivalentShareClaimsM: claims.fixedClaimsM + netDilutiveSharesM,
    aggregateIntrinsicOptionClaimsUsdM: optionPools.reduce((sum, row) => sum + row.intrinsicClaimsUsdM, 0),
    optionPools,
    warnings: [
      "weighted_average_strikes_not_per_tranche_exercise_decisions",
      "rounded_strikes_produce_approximate_exercise_cash",
      "intrinsic_only_excludes_option_time_value",
      "all_included_awards_assumed_to_vest_and_deliver",
      "exercise_cash_is_conditional_not_current_cash",
      "future_grants_not_forecast"
    ]
  };
}
