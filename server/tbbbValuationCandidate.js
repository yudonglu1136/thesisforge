import {
  TBBB_ECONOMIC_EVIDENCE,
  buildTbbbEconomicInputs,
  calculateTbbbIntrinsicExerciseDilution
} from "./tbbbEconomicInputs.js";

// This module has no persistence/publication path. A calculated scenario is not
// a released valuation, nor evidence that the analyst's assumptions are sound.
export const TBBB_CANDIDATE_MODEL_VERSION = "tbbb-explicit-fcfe-candidate-v1";
export const TBBB_FY2026_REVENUE_GUIDANCE = Object.freeze({
  label: "management_guidance", subject: "company_total", metric: "revenue_growth",
  fiscalYear: 2026, periodStartDate: "2026-01-01", periodEndDate: "2026-12-31",
  unit: "ratio", low: 0.29, high: 0.32, availableDate: "2026-03-11",
  url: "https://www.sec.gov/Archives/edgar/data/1978954/000119312526102363/tbbb_4q25_earnings_relea.htm",
  locator: "2026 guidance, p.12",
  quote: "total revenue is forecast to grow by 29% to 32%",
  limitation: "March_issued_range_not_asserted_reaffirmed_in_Q1_or_Q2"
});

const YEARS = Object.freeze([2027, 2028, 2029, 2030, 2031]);
const DAY_MS = 86400000;
const finite = (value) => typeof value === "number" && Number.isFinite(value);
const nonnegative = (value) => finite(value) && value >= 0;
const textValue = (value) => typeof value === "string" && value.trim().length > 0;
const clone = (value) => structuredClone(value);
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

function blocked(reason, details = {}) {
  return { status: "blocked", releaseReady: false, modelVersion: TBBB_CANDIDATE_MODEL_VERSION,
    reason, ...details };
}

function dateOnly(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function yearFraction(start, end) {
  return (Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / DAY_MS / 365;
}

function officialFxUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && (url.hostname === "ecb.europa.eu" ||
      url.hostname.endsWith(".ecb.europa.eu")) && !url.username && !url.password;
  } catch { return false; }
}

function validLineage(record, asOfDate) {
  let parsed;
  try { parsed = typeof record === "string" ? JSON.parse(record) : record; } catch { return false; }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || !Object.keys(parsed).length) return false;
  const visited = new Set();
  const availableKeys = new Set(["datekey", "availabledate", "availableat", "financialavailableat",
    "sourceavailabledate", "sourceavailableat", "filingdate", "fileddate", "filedat", "filed"]);
  function visit(value) {
    if (!value || typeof value !== "object") return true;
    if (visited.has(value)) return false;
    visited.add(value);
    for (const [key, item] of Object.entries(value)) {
      if (availableKeys.has(key.toLowerCase().replaceAll("_", "")) && item != null) {
        const date = typeof item === "string" ? item.slice(0, 10) : "";
        if (!dateOnly(date) || !Number.isFinite(Date.parse(item)) || date > asOfDate) return false;
      }
      if (item && typeof item === "object" && !visit(item)) return false;
    }
    return true;
  }
  return visit(parsed);
}

/** Independent equivalent of normalizedRevenueGrowthForRows: latest eight slots,
 * finite complete YoY observations, clamp [-100, 1000], 15%/85% trim, median.
 * Each percentage is recalculated from like-for-like current/prior revenue.
 * The caller still owns proving completeness of the supplied latest window.
 */
export function recomputeTbbbFinancialTrend({ financialTrendPct, financialTrendEvidence,
  growthPolicySettings, asOfDate, periodEndDate } = {}) {
  const evidence = financialTrendEvidence;
  const settings = growthPolicySettings;
  if (!finite(financialTrendPct) || !dateOnly(asOfDate) || !dateOnly(periodEndDate) ||
      !evidence || evidence.asOfDate !== asOfDate || evidence.unit !== "percent" ||
      evidence.method !== "normalizedRevenueGrowthForRows" || evidence.windowSize !== 8 ||
      evidence.selection !== "latest_up_to_8_complete_observations_in_latest_8_period_window" ||
      !finite(evidence.valuePct) || Math.abs(evidence.valuePct - financialTrendPct) > 1e-8 ||
      !Array.isArray(evidence.observations) || !evidence.observations.length || evidence.observations.length > 8) {
    return blocked("missing_or_invalid_dated_financial_trend_evidence");
  }
  if (!settings || !finite(settings.normalizedGrowthCapPct) || settings.normalizedGrowthCapPct < -20 ||
      !Number.isInteger(settings.minimumGrowthSampleCount) || settings.minimumGrowthSampleCount < 1 ||
      settings.minimumGrowthSampleCount > 8 || settings.fundamentalGrowthPriorPct !== 5) {
    return blocked("explicit_growth_profile_cap_sample_gate_and_prior_required");
  }
  if (evidence.observations.length < settings.minimumGrowthSampleCount) {
    return blocked("insufficient_complete_financial_growth_observations");
  }
  const validQuarterEnd = (date) => dateOnly(date) && /-(03-31|06-30|09-30|12-31)$/.test(date);
  const quarterIndex = (date) => Number(date.slice(0, 4)) * 4 + Number(date.slice(5, 7)) / 3;
  if (!validQuarterEnd(periodEndDate)) return blocked("invalid_financial_trend_window_end");
  const dimensionBasis = (dimension) => ({ ARQ: "quarter", ART: "TTM", official_quarter: "quarter" })[dimension];
  const pointValid = (row) => row && validQuarterEnd(row.periodEndDate) && dateOnly(row.availableDate) &&
    row.periodEndDate <= row.availableDate && row.availableDate <= asOfDate && row.scope === "company_total" &&
    row.currency === "MXN" && row.unit === "million" && dimensionBasis(row.sourceDimension) &&
    finite(row.revenueM) && row.revenueM > 0 && validLineage(row.sourceRecord, asOfDate);
  const observations = [];
  const seen = new Set();
  const revenueBases = new Set();
  let previousEnd = "";
  for (const row of evidence.observations) {
    if (!pointValid(row) || !pointValid(row.comparator) || !finite(row.valuePct) ||
        row.periodEndDate <= previousEnd || seen.has(row.periodEndDate) ||
        quarterIndex(periodEndDate) - quarterIndex(row.periodEndDate) < 0 ||
        quarterIndex(periodEndDate) - quarterIndex(row.periodEndDate) > 7 ||
        row.comparator.periodEndDate !== `${Number(row.periodEndDate.slice(0, 4)) - 1}${row.periodEndDate.slice(4)}` ||
        dimensionBasis(row.sourceDimension) !== dimensionBasis(row.comparator.sourceDimension)) {
      return blocked("invalid_noncomparable_duplicate_or_unavailable_growth_observation");
    }
    const recalculatedPct = (row.revenueM / row.comparator.revenueM - 1) * 100;
    if (Math.abs(recalculatedPct - row.valuePct) > 1e-7) return blocked("growth_observation_not_reconciled_to_revenue");
    observations.push({ ...clone(row), recalculatedPct, winsorizedPct: clamp(recalculatedPct, -100, 1000) });
    seen.add(row.periodEndDate);
    revenueBases.add(dimensionBasis(row.sourceDimension));
    previousEnd = row.periodEndDate;
  }
  if (previousEnd !== periodEndDate || revenueBases.size !== 1) {
    return blocked("financial_trend_not_current_or_mixes_quarter_and_TTM_growth");
  }
  const sorted = observations.map((row) => row.winsorizedPct).sort((a, b) => a - b);
  const trimStart = Math.floor(sorted.length * 0.15);
  const trimEnd = Math.max(trimStart + 1, Math.ceil(sorted.length * 0.85));
  const trimmed = sorted.slice(trimStart, trimEnd);
  const middle = Math.floor(trimmed.length / 2);
  const medianPct = trimmed.length % 2 ? trimmed[middle] : (trimmed[middle - 1] + trimmed[middle]) / 2;
  if (Math.abs(financialTrendPct - medianPct) > 1e-7) return blocked("financial_trend_not_reconciled_to_independent_median");
  const evidenceWeight = clamp((observations.length - settings.minimumGrowthSampleCount + 1) / 4, 0.25, 1);
  const baseGrowthPct = settings.fundamentalGrowthPriorPct * (1 - evidenceWeight) + medianPct * evidenceWeight;
  return { status: "ready", label: "independently_recalculated_from_caller_PIT_revenue_evidence",
    financialTrendPct: medianPct, sampleCount: observations.length, windowSize: 8,
    winsorizationBoundsPct: [-100, 1000], sortedWinsorizedPct: sorted, trimStart, trimEnd,
    trimmedPct: trimmed, fundamentalGrowthEvidenceWeight: evidenceWeight, baseGrowthPct,
    profileSettings: clone(settings), observations,
    limitation: "caller_must_prove_latest_window_completeness_and_earliest_available_source_selection" };
}

function resolveGuidanceGrowth(input, economics) {
  const rawGrowth = input.fy2026RevenueGrowth;
  if (input.guidanceApplicationPolicy === "hypothetical_full_weight_growth_translation_not_release") {
    return { status: "ready", appliedGrowth: rawGrowth,
      audit: { route: input.guidanceApplicationPolicy, rawGrowth, rawGrowthPct: rawGrowth * 100,
        financialTrend: null, boundedGrowth: null, appliedWeight: 1, appliedGrowth: rawGrowth,
        releaseMaximumWeight: 0.25, releaseFinancialTrendBand: 0.15,
        compliesWithReleaseGrowthPolicy: false,
        reason: "hypothetical_full_weight_translation_only_requires_PIT_trend_bounding_and_weighting_before_release" } };
  }
  if (input.guidanceApplicationPolicy !== "pit_trend_bounded_blend") {
    return blocked("explicit_nonrelease_guidance_translation_policy_required");
  }
  if (!finite(input.guidanceWeight) || input.guidanceWeight < 0 || input.guidanceWeight > 0.25) {
    return blocked("explicit_guidance_weight_must_be_between_zero_and_025");
  }
  const trend = recomputeTbbbFinancialTrend({
    financialTrendPct: input.financialTrendPct, financialTrendEvidence: input.financialTrendEvidence,
    growthPolicySettings: input.growthPolicySettings,
    asOfDate: economics.asOfDate, periodEndDate: economics.periodEndDate
  });
  if (trend.status !== "ready") return trend;
  const boundedGrowthPct = clamp(rawGrowth * 100, trend.baseGrowthPct - 15, trend.baseGrowthPct + 15);
  const beforeProfileCapPct = trend.baseGrowthPct * (1 - input.guidanceWeight) + boundedGrowthPct * input.guidanceWeight;
  const appliedGrowthPct = clamp(beforeProfileCapPct, -20, input.growthPolicySettings.normalizedGrowthCapPct);
  return { status: "ready", appliedGrowth: appliedGrowthPct / 100,
    audit: { route: input.guidanceApplicationPolicy, rawGrowth, rawGrowthPct: rawGrowth * 100,
      financialTrend: trend.financialTrendPct / 100, financialTrendPct: trend.financialTrendPct,
      baseGrowthPct: trend.baseGrowthPct, boundedGrowth: boundedGrowthPct / 100, boundedGrowthPct,
      appliedWeight: input.guidanceWeight, beforeProfileCapPct, appliedGrowthPct,
      appliedGrowth: appliedGrowthPct / 100, profileFloorPct: -20,
      profileCapPct: input.growthPolicySettings.normalizedGrowthCapPct,
      releaseMaximumWeight: 0.25, releaseFinancialTrendBand: 0.15,
      compliesWithReleaseGrowthPolicy: true,
      complianceScope: "independent_revenue_tieout_normalization_ramp_bounding_weight_and_profile_cap_only",
      guidanceTreatment: input.guidanceWeight === 0 ? "explicit_zero_weight_research_only" : "bounded_weighted_growth",
      exclusionReason: input.guidanceWeight === 0 ? "caller_selected_zero_weight" : null,
      independentTrendAudit: trend } };
}

function validateScenario(input, economics) {
  if (!input || typeof input !== "object") return blocked("missing_scenario");
  if (!textValue(input.scenarioId) || !textValue(input.rationale) ||
      !dateOnly(input.assumptionDate) || input.assumptionDate > economics.asOfDate) {
    return blocked("missing_or_future_analyst_assumption_metadata");
  }
  const guidance = TBBB_FY2026_REVENUE_GUIDANCE;
  if (guidance.availableDate > economics.asOfDate) return blocked("guidance_not_available");
  if (!finite(input.fy2026RevenueGrowth) || input.fy2026RevenueGrowth < guidance.low ||
      input.fy2026RevenueGrowth > guidance.high) return blocked("growth_selection_outside_FY2026_guidance");
  if (!["hypothetical_full_weight_growth_translation_not_release", "pit_trend_bounded_blend"]
    .includes(input.guidanceApplicationPolicy)) {
    return blocked("explicit_nonrelease_guidance_translation_policy_required");
  }
  if (input.timingPolicy !== "act_365_fiscal_year_end") return blocked("explicit_timing_policy_required");
  if (!(finite(input.costOfEquity) && input.costOfEquity > 0) ||
      !(finite(input.terminalGrowth) && input.terminalGrowth > -1 &&
        input.terminalGrowth < input.costOfEquity)) return blocked("invalid_explicit_Ke_or_terminal_growth");
  if (!["explicit_margins", "hold_observed_bridge_margin"].includes(input.marginPolicy)) {
    return blocked("explicit_margin_policy_required");
  }
  if (input.existingAwardPolicy !== "all_current_awards_vest_no_duplicate_sbc_expense") {
    return blocked("explicit_existing_award_policy_required");
  }
  // Future grants use one economic cost, never both cost and modeled dilution.
  // A pure future-share-issuance path needs a separate ownership model.
  if (input.futureGrantPolicy !== "cash_equivalent_cost_in_lieu_of_dilution") {
    return blocked("explicit_future_grant_cash_equivalent_policy_required");
  }
  if (input.optionPolicy?.mode !== "grouped_intrinsic_plus_explicit_reserve" ||
      !nonnegative(input.optionPolicy.timeValueReserveUsdM) ||
      !textValue(input.optionPolicy.rationale)) return blocked("explicit_option_time_value_policy_required");
  if (!finite(input.equityAdjustment?.amountM) || !textValue(input.equityAdjustment?.rationale)) {
    return blocked("explicit_incremental_equity_adjustment_required");
  }
  const fx = input.fx;
  if (!fx || fx.baseCurrency !== "USD" || fx.quoteCurrency !== "MXN" ||
      !finite(fx.mxnPerUsd) || fx.mxnPerUsd <= 0 || !dateOnly(fx.rateDate) ||
      !dateOnly(fx.availableDate) || fx.rateDate > fx.availableDate ||
      fx.availableDate > economics.asOfDate || !officialFxUrl(fx.sourceUrl) ||
      !textValue(fx.derivation)) return blocked("missing_or_invalid_dated_official_FX_input");
  const stub = input.stub;
  if (!stub || stub.periodStartExclusive !== economics.asOfDate ||
      stub.paymentDate !== "2026-12-31" || !finite(stub.economicCashFlowM) ||
      !nonnegative(stub.additionalReinvestmentM) || !finite(stub.netBorrowingM) ||
      !nonnegative(stub.futureGrantCostM) || !textValue(stub.rationale)) {
    return blocked("explicit_post_asof_2026_stub_required");
  }
  if (!Array.isArray(input.forecast) || input.forecast.length !== YEARS.length) {
    return blocked("exactly_five_explicit_FY2027_to_FY2031_rows_required");
  }
  const marginIsValid = (row) => input.marginPolicy === "explicit_margins"
    ? finite(row.economicCashFlowMargin)
    : row.economicCashFlowMargin === undefined;
  for (const [index, row] of input.forecast.entries()) {
    if (!row || row.fiscalYear !== YEARS[index] || !finite(row.revenueGrowth) ||
        row.revenueGrowth <= -1 || !marginIsValid(row) ||
        !nonnegative(row.additionalReinvestmentMargin) || !finite(row.netBorrowingM) ||
        !nonnegative(row.futureGrantCostMargin)) {
      return blocked("invalid_or_missing_annual_assumption", { fiscalYear: YEARS[index] });
    }
  }
  const terminal = input.terminal;
  if (!terminal || !marginIsValid(terminal) || !nonnegative(terminal.additionalReinvestmentMargin) ||
      !finite(terminal.netBorrowingMargin) || !nonnegative(terminal.futureGrantCostMargin) ||
      !textValue(terminal.rationale)) return blocked("explicit_terminal_margin_schedule_required");
  return null;
}

/**
 * Solve P * fixed claims + sum(option count * max(P - strike, 0)) = equity PV.
 * All money is USD millions and share counts are millions; no market price is
 * accepted. The grouped rounded-strike approximation is NOT a full option model.
 */
export function solveTbbbIntrinsicClaimPrice({ asOfDate, periodEndDate, equityValueUsdM } = {}) {
  if (!finite(equityValueUsdM) || equityValueUsdM <= 0) return blocked("nonpositive_equity_value");
  // The adapter's independent date gate stops historical use of current claims.
  const gate = calculateTbbbIntrinsicExerciseDilution({ asOfDate, periodEndDate, valuationPriceUsd: 1 });
  if (gate.status !== "ready") return blocked(gate.reason);
  const fixedClaimsM = gate.fixedClaimsM;
  const pools = [...gate.optionPools].sort((a, b) => a.weightedAverageStrikeUsd - b.weightedAverageStrikeUsd);
  let sharesM = fixedClaimsM;
  let exerciseCashUsdM = 0;
  let priceUsd = equityValueUsdM / sharesM;
  for (const pool of pools) {
    if (priceUsd <= pool.weightedAverageStrikeUsd) break;
    sharesM += pool.sharesM;
    exerciseCashUsdM += pool.sharesM * pool.weightedAverageStrikeUsd;
    priceUsd = (equityValueUsdM + exerciseCashUsdM) / sharesM;
  }
  const dilution = calculateTbbbIntrinsicExerciseDilution({
    asOfDate, periodEndDate, valuationPriceUsd: priceUsd
  });
  if (dilution.status !== "ready") return blocked(dilution.reason);
  const identityResidualUsdM = priceUsd * fixedClaimsM +
    dilution.aggregateIntrinsicOptionClaimsUsdM - equityValueUsdM;
  if (!Number.isFinite(priceUsd) || Math.abs(identityResidualUsdM) >
      1e-10 * Math.max(1, equityValueUsdM)) return blocked("intrinsic_claim_identity_failed");
  return { status: "candidate", releaseReady: false,
    label: "self_consistent_grouped_intrinsic_candidate_not_option_fair_value",
    priceUsd, equityValueUsdM, fixedClaimsM, identityResidualUsdM,
    formula: "P * fixed_claims_M + sum(option_shares_M * max(P - strike_USD, 0)) = equity_PV_USD_M",
    dilution, warnings: [...dilution.warnings] };
}

/**
 * Complete five-year FCFE scenario; all forecast policies are caller assumptions.
 *
 * economicInput: raw arguments for buildTbbbEconomicInputs(), not a ready-looking
 * object: this function rechecks dated public numbers and claims internally.
 * Forecast years are FY2027-31; a separately specified after-asOf FY2026 stub
 * prevents discounting already-earned 2026 cash as future cash. Revenue guidance
 * anchors FY2026 revenue ONLY. All later growth/margins/reinvestment/borrowing,
 * future grant costs, terminal margins, Ke/g, stub and FX are explicit inputs.
 *
 * The economicCashFlowMargin starts AFTER cash PPE/intangibles, lease principal,
 * lease interest and debt interest. additionalReinvestmentMargin is incremental
 * to that base (including any normalization of financed equipment). netBorrowingM
 * means net debt financing not already in CFO, including its principal service;
 * never deduct gross supplier-finance repayments already recognized in CFO.
 *
 * Future grants are charged once via cash-equivalent costs. Current issued and
 * conditional claims are valued separately, so existing-award expense is NOT
 * deducted again. No net-debt automatic subtraction, buyback add-on, or dividends
 * add-on exists. equityAdjustment must be an explicit incremental economic claim.
 */
export function calculateTbbbValuationCandidate(input = {}) {
  if (!input || typeof input !== "object") return blocked("missing_scenario");
  const economics = buildTbbbEconomicInputs(input.economicInput);
  if (economics.status !== "ready") return blocked(economics.reason, { failedStage: "economic_input" });
  const failure = validateScenario(input, economics);
  if (failure) return failure;
  const growth = resolveGuidanceGrowth(input, economics);
  if (growth.status !== "ready") return growth;
  const referenceMargin = economics.cashFlowBridge.economicCashFlowM / economics.matchedInputs.sourceRevenue;
  const selectedMargin = (row) => input.marginPolicy === "hold_observed_bridge_margin"
    ? referenceMargin : row.economicCashFlowMargin;
  const fy2025 = TBBB_ECONOMIC_EVIDENCE.financialPeriods.find((row) => row.id === "fy2025");
  const fy2025RevenueM = fy2025.values.revenue / 1000;
  const fy2026RevenueM = fy2025RevenueM * (1 + growth.appliedGrowth);
  let revenueM = fy2026RevenueM;
  const forecast = input.forecast.map((row) => {
    revenueM *= 1 + row.revenueGrowth;
    const economicCashFlowMargin = selectedMargin(row);
    const economicCashFlowM = revenueM * economicCashFlowMargin;
    const additionalReinvestmentM = revenueM * row.additionalReinvestmentMargin;
    const futureGrantCostM = revenueM * row.futureGrantCostMargin;
    const fcfeM = economicCashFlowM - additionalReinvestmentM + row.netBorrowingM - futureGrantCostM;
    const paymentDate = `${row.fiscalYear}-12-31`;
    const discountYears = yearFraction(economics.asOfDate, paymentDate);
    const discountFactor = (1 + input.costOfEquity) ** -discountYears;
    return { ...clone(row), label: "analyst_scenario", revenueM,
      economicCashFlowMargin, economicCashFlowM, additionalReinvestmentM, futureGrantCostM,
      fcfeM, paymentDate, discountYears, discountFactor, presentValueM: fcfeM * discountFactor };
  });
  const stub = clone(input.stub);
  stub.label = "analyst_post_asof_stub_not_FY2026_guidance";
  stub.fcfeM = stub.economicCashFlowM - stub.additionalReinvestmentM +
    stub.netBorrowingM - stub.futureGrantCostM;
  stub.discountYears = yearFraction(economics.asOfDate, stub.paymentDate);
  stub.discountFactor = (1 + input.costOfEquity) ** -stub.discountYears;
  stub.presentValueM = stub.fcfeM * stub.discountFactor;
  const last = forecast.at(-1);
  const terminalRevenueM = last.revenueM * (1 + input.terminalGrowth);
  const terminalMargin = selectedMargin(input.terminal);
  const terminalFcfeMargin = terminalMargin - input.terminal.additionalReinvestmentMargin +
    input.terminal.netBorrowingMargin - input.terminal.futureGrantCostMargin;
  const terminalFcfeM = terminalRevenueM * terminalFcfeMargin;
  const terminalValueM = terminalFcfeM / (input.costOfEquity - input.terminalGrowth);
  const terminalPresentValueM = terminalValueM * last.discountFactor;
  const forecastPresentValueM = forecast.reduce((sum, row) => sum + row.presentValueM, 0);
  const cashFlowPresentValueM = stub.presentValueM + forecastPresentValueM + terminalPresentValueM;
  const totalEquityValueM = cashFlowPresentValueM + input.equityAdjustment.amountM;
  const beforeReserveUsdM = totalEquityValueM / input.fx.mxnPerUsd;
  const equityValueUsdM = beforeReserveUsdM - input.optionPolicy.timeValueReserveUsdM;
  if (![referenceMargin, fy2026RevenueM, terminalFcfeM, terminalValueM,
    terminalPresentValueM, forecastPresentValueM, totalEquityValueM, equityValueUsdM,
    ...forecast.flatMap((row) => [row.revenueM, row.fcfeM, row.presentValueM])].every(finite)) {
    return blocked("nonfinite_scenario_calculation");
  }
  // A perpetually nonpositive terminal FCFE is not a sustainable going-concern
  // Gordon claim, even if an arbitrary positive equity adjustment masks it.
  const claims = equityValueUsdM > 0 && terminalFcfeM > 0 ? solveTbbbIntrinsicClaimPrice({
    asOfDate: economics.asOfDate, periodEndDate: economics.periodEndDate, equityValueUsdM
  }) : null;
  if (claims && claims.status !== "candidate") return claims;
  const releaseBlockers = [
    "analyst_assumptions_not_independently_audited",
    "noncash_financed_equipment_and_reinvestment_schedule_requires_review",
    "rounded_pool_strikes_and_option_time_value_not_fully_verified",
    "caller_supplied_official_FX_value_not_independently_verified",
    ...(growth.audit.compliesWithReleaseGrowthPolicy
      ? ["financial_trend_window_completeness_and_source_selection_require_independent_audit"]
      : ["full_weight_growth_translation_does_not_satisfy_release_growth_policy"]),
    "current_share_claims_no_later_than_reviewed_2026_09_05_not_historical_replay",
    "no_production_profile_or_release_gate_integration"
  ];
  return {
    status: "candidate", releaseReady: false, modelVersion: TBBB_CANDIDATE_MODEL_VERSION,
    scenarioId: input.scenarioId, asOfDate: economics.asOfDate, periodEndDate: economics.periodEndDate,
    valuationStatus: equityValueUsdM <= 0 ? "nonpositive_equity_scenario" :
      terminalFcfeM <= 0 ? "nonpositive_terminal_FCFE_scenario" : "positive_conditional_scenario",
    perShareUsd: claims?.priceUsd ?? null,
    method: "five_explicit_FY2027_2031_FCFE_plus_post_asof_2026_stub_and_terminal_current_claims",
    currency: "MXN", unit: "million", quotedCurrency: "USD",
    guidanceUse: {
      ...TBBB_FY2026_REVENUE_GUIDANCE, selectedGrowth: input.fy2026RevenueGrowth,
      selectedGrowthLabel: "analyst_selected_point_within_management_range",
      appliedGrowth: growth.appliedGrowth,
      fy2025ActualRevenueM: fy2025RevenueM,
      fy2025ActualSource: clone(TBBB_ECONOMIC_EVIDENCE.sources[fy2025.sourceId]),
      derivedFy2026RevenueM: fy2026RevenueM,
      derivedRevenueLabel: "derived_hypothetical_only_NOT_management_monetary_guidance",
      usedAsReleasedAmountGuidance: false,
      formula: "FY2025 actual revenue * (1 + explicitly selected guidance-policy applied growth)",
      growthPolicyAudit: growth.audit,
      notGuided: ["2027_2031_growth", "FCFE", "EBITDA_margin", "2027_2031_reinvestment_and_cash_financing_schedule", "future_grants", "terminal_growth"]
    },
    capitalInvestmentGuidance: clone(economics.capitalInvestmentBudget),
    referenceCashBridge: { ...clone(economics.cashFlowBridge), referenceMargin,
      marginLabel: "analyst_ratio_TTM_intermediate_cash_bridge_to_TTM_revenue_not_normalized_FCFE" },
    stub, forecast,
    terminal: { ...clone(input.terminal), label: "analyst_scenario", fiscalYear: 2032,
      growth: input.terminalGrowth, revenueM: terminalRevenueM,
      economicCashFlowMargin: terminalMargin, fcfeMargin: terminalFcfeMargin,
      fcfeM: terminalFcfeM, valueAt2031YearEndM: terminalValueM,
      discountFactor: last.discountFactor, presentValueM: terminalPresentValueM,
      formula: "FY2032 FCFE / (Ke - g), constant terminal margins and g thereafter" },
    valuationBridge: { stubPresentValueM: stub.presentValueM, forecastPresentValueM,
      terminalPresentValueM, cashFlowPresentValueM,
      explicitIncrementalEquityAdjustmentM: input.equityAdjustment.amountM,
      totalEquityValueM, fxMxnPerUsd: input.fx.mxnPerUsd,
      equityBeforeOptionTimeValueReserveUsdM: beforeReserveUsdM,
      optionTimeValueReserveUsdM: input.optionPolicy.timeValueReserveUsdM,
      equityForIntrinsicClaimAllocationUsdM: equityValueUsdM,
      terminalValueShare: cashFlowPresentValueM > 0 ? terminalPresentValueM / cashFlowPresentValueM : null,
      existingSbcExpenseDeductedAgainM: 0, futureGrantDilutionAlsoApplied: false,
      conditionalExerciseCashAddedToCurrentEquityM: 0, automaticNetDebtDeductionM: 0 },
    claims, shareClaims: clone(economics.shareClaims),
    analystAssumptions: { label: "caller_explicit_analyst_scenario_not_management_guidance",
      assumptionDate: input.assumptionDate, rationale: input.rationale,
      costOfEquity: input.costOfEquity, terminalGrowth: input.terminalGrowth,
      timingPolicy: input.timingPolicy, marginPolicy: input.marginPolicy,
      guidanceApplicationPolicy: input.guidanceApplicationPolicy,
      existingAwardPolicy: input.existingAwardPolicy, futureGrantPolicy: input.futureGrantPolicy,
      optionPolicy: clone(input.optionPolicy), equityAdjustment: clone(input.equityAdjustment),
      fx: clone(input.fx) },
    provenance: { evidenceId: economics.evidenceId,
      economicInputs: clone(economics.provenance), availabilityPrecision: economics.availabilityPrecision },
    releaseBlockers,
    warnings: [...new Set([...economics.warnings.filter((warning) => warning !== "future_grants_not_forecast"),
      ...(claims?.warnings ?? []).filter((warning) => warning !== "future_grants_not_forecast"),
      "future_grants_are_explicit_analyst_cash_equivalent_estimates_not_issuer_guidance",
      "explicit_zero_reserve_does_not_establish_zero_option_time_value",
      "growth_guidance_is_not_FCFE_or_margin_guidance",
      "constant_FX_projection_is_an_explicit_scenario_not_an_FX_forecast",
      ...(input.marginPolicy === "hold_observed_bridge_margin"
        ? ["mechanical_fixed_intermediate_margin_not_established_sustainable_FCFE"] : []),
      ...releaseBlockers])]
  };
}

/** Range of caller-supplied fixed-bridge-margin scenarios, NOT economic bounds. */
export function calculateTbbbFixedMarginScenarioRange(inputs) {
  if (!Array.isArray(inputs) || inputs.length < 2) return blocked("at_least_two_explicit_scenarios_required");
  if (inputs.some((input) => input?.marginPolicy !== "hold_observed_bridge_margin")) {
    return blocked("fixed_margin_range_requires_explicit_fixed_margin_policy");
  }
  const scenarios = inputs.map(calculateTbbbValuationCandidate);
  const failedIndex = scenarios.findIndex((result) => result.status !== "candidate");
  if (failedIndex !== -1) return blocked("scenario_range_contains_blocked_input", {
    failedIndex, scenarioFailure: scenarios[failedIndex].reason
  });
  if (new Set(scenarios.map((row) => `${row.asOfDate}/${row.periodEndDate}`)).size !== 1 ||
      new Set(scenarios.map((row) => row.scenarioId)).size !== scenarios.length) {
    return blocked("scenario_range_requires_same_dates_and_unique_scenario_ids");
  }
  const hasNonpositiveScenario = scenarios.some((row) => row.perShareUsd === null);
  return { status: "candidate", releaseReady: false,
    label: "conditional_range_of_supplied_scenarios_not_reasonable_value_bounds",
    minimumPerShareUsd: hasNonpositiveScenario ? null : Math.min(...scenarios.map((row) => row.perShareUsd)),
    maximumPerShareUsd: hasNonpositiveScenario ? null : Math.max(...scenarios.map((row) => row.perShareUsd)),
    hasNonpositiveScenario, scenarios,
    warning: "No finite economically justified bounds follow from revenue guidance and the historical cash margin alone; Ke/g/FX/reinvestment/financing/grants remain analyst choices." };
}
