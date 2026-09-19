import crypto from "node:crypto";
import { guruValuationCompanyForTicker } from "./guruValuationUniverse.js";

const convention = "reported_cfo_less_cash_capex_licenses_and_sbc";
const number = (value) => typeof value === "number" && Number.isFinite(value);
const same = (a, b) => number(a) && number(b) && Math.abs(a - b) <= 1e-6;
const date = (value) => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
  Number.isFinite(Date.parse(`${value}T00:00:00Z`)) && new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}
const digest = (value) => crypto.createHash("sha256").update(canonical(value)).digest("hex");
const requireValue = (valid, message) => { if (!valid) throw new Error(`Reviewed economic inputs: ${message}`); };

function evidence(rows, company, node, name) {
  requireValue(Array.isArray(rows) && rows.length > 0, `${name}: missing primary evidence`);
  for (const source of rows) {
    let official = false;
    try {
      const url = new URL(source.url);
      official = url.protocol === "https:" && url.hostname === "www.sec.gov" &&
        !url.username && !url.password && url.pathname.includes(`/data/${Number(company.cik)}/`);
    } catch { /* Fail below, without echoing a supplied URL. */ }
    requireValue(official && source.locator && /^[a-f0-9]{64}$/.test(source.sha256 || ""), `${name}: invalid source identity/hash/locator`);
    requireValue(date(source.availableDate) && source.availableDate <= node.availableDate &&
      date(source.periodEndDate) && source.periodEndDate <= node.periodEndDate &&
      source.periodEndDate <= source.availableDate, `${name}: invalid or future source date`);
  }
}

function flowBridge(input, raw, company, node, name) {
  requireValue(input && raw, `${node.fiscalPeriod}/${name}: missing cash-flow schedule`);
  for (const key of ["cfoM", "capexM", "sbcM", "licensePaymentsM"]) {
    requireValue(number(input[key]) && (key === "cfoM" || input[key] >= 0), `${name}: invalid ${key}; missing is not zero`);
  }
  requireValue(same(input.cfoM, raw.cfo_m) && same(input.capexM, raw.capex_m), `${node.fiscalPeriod}/${name}: reported cash flow changed; re-review required`);
  const reportedFcfM = input.cfoM - input.capexM;
  requireValue(raw.fcf_after_capex_m == null || same(raw.fcf_after_capex_m, reportedFcfM), `${name}: direct FCF does not reconcile to CFO less cash capex`);
  evidence(input.evidence, company, node, name);
  return {
    ...structuredClone(input), reportedFcfM,
    economicFcfeM: reportedFcfM - input.licensePaymentsM - input.sbcM,
    convention,
    sbcTreatment: "recurring_expense_proxy_no_second_award_dilution",
    licenseTreatment: "operating_reinvestment_paid_in_financing_not_funded_debt_repayment",
    netIncomeTreatment: "gaap_sbc_not_expensed_twice_separate_warrant_bridge_if_applicable"
  };
}

function optionClaims(node, company) {
  requireValue(Array.isArray(node.optionClaims), `${node.fiscalPeriod}: existing option/warrant claims not reviewed`);
  const ids = new Set();
  for (const claim of node.optionClaims) {
    requireValue(claim.id && !ids.has(claim.id) && number(claim.countM) && claim.countM >= 0 &&
      number(claim.strike) && claim.strike >= 0 && claim.currency === node.currency &&
      ["vested_employee_option", "outstanding_employee_option_with_unrecognized_compensation_credit", "vested_customer_warrant"].includes(claim.basis), "unreviewed, duplicate or unsupported option claim");
    ids.add(claim.id);
    if (claim.basis === "outstanding_employee_option_with_unrecognized_compensation_credit") {
      const bounds = claim.compensationCreditRangeM;
      requireValue(number(claim.unrecognizedCompensationCostM) && claim.unrecognizedCompensationCostM >= 0 &&
        ["reported", "analyst_straight_line_estimate"].includes(claim.compensationCreditBasis) &&
        bounds && number(bounds.low) && number(bounds.high) && bounds.low >= 0 &&
        bounds.low <= claim.unrecognizedCompensationCostM && bounds.high >= claim.unrecognizedCompensationCostM &&
        (claim.compensationCreditBasis !== "analyst_straight_line_estimate" ||
          typeof claim.estimateRationale === "string" && claim.estimateRationale.length > 20),
      "outstanding employee options require a dated unrecognized-service-cost credit and explicit bounds");
    }
    if (claim.basis === "vested_customer_warrant") {
      requireValue(node.warrantNormalization, "customer warrants require a noncash contra-revenue bridge");
    }
    evidence(claim.evidence, company, node, "option/warrant claims");
  }
  return structuredClone(node.optionClaims);
}

function warrantNormalization(node, company) {
  const bridge = node.warrantNormalization;
  if (!bridge) return null;
  for (const key of ["quarterContraRevenueM", "ttmContraRevenueM"]) {
    requireValue(number(bridge[key]) && bridge[key] >= 0, "missing/negative customer-warrant contra-revenue");
  }
  requireValue(number(bridge.taxRate) && bridge.taxRate >= 0 && bridge.taxRate <= 0.5 &&
    bridge.taxRateBasis === "analyst_marginal_tax_rate_not_reported", "invalid or unlabeled warrant tax assumption");
  for (const [key, amount] of [["quarterReportedOperatingFinancials", bridge.quarterContraRevenueM],
    ["ttmReportedOperatingFinancials", bridge.ttmContraRevenueM]]) {
    requireValue(bridge[key] && normalizedOperatingKeys.every((field) => number(bridge[key][field]) ||
      amount === 0 && bridge[key][field] === null), "warrant bridge requires exact reviewed reported operating inputs");
  }
  evidence(bridge.evidence, company, node, "customer-warrant contra-revenue");
  return structuredClone(bridge);
}

const normalizedOperatingKeys = ["revenue_m", "gross_profit_m", "operating_income_m", "net_income_m"];
function normalizeWarrantOperatingInputs(row, amount, taxRate, expectedReported) {
  const originals = {};
  for (const key of normalizedOperatingKeys) {
    requireValue(number(row[key]) || amount === 0, `missing reported ${key} for customer-warrant normalization`);
    requireValue(same(row[key], expectedReported[key]) || row[key] == null && expectedReported[key] === null,
      `reported ${key} changed; re-review customer-warrant bridge`);
    originals[key] = row[key] ?? null;
    if (number(row[key])) row[key] += amount * (key === "net_income_m" ? 1 - taxRate : 1);
  }
  row.reported_operating_financials = originals;
  for (const [marginKey, valueKey] of [["gross_margin_pct", "gross_profit_m"], ["operating_margin_pct", "operating_income_m"]]) {
    if (number(row[valueKey]) && row.revenue_m > 0) row[marginKey] = row[valueKey] / row.revenue_m * 100;
  }
}

function balanceNormalization(node, company) {
  const bridge = node.balanceNormalization;
  if (!bridge) return null;
  for (const key of ["cashEquivalentsM", "unrestrictedShortTermInvestmentsM", "fundedDebtM", "operatingLeaseCurrentM", "operatingLeaseNoncurrentM"]) {
    requireValue(number(bridge[key]) && bridge[key] >= 0, `invalid or unreviewed ${key}`);
  }
  for (const key of ["reportedCashM", "reportedDebtM"]) {
    requireValue(number(bridge[key]) || bridge[key] === null, `missing reported balance ${key}`);
  }
  requireValue(typeof bridge.fundedDebtBasis === "string" && bridge.fundedDebtBasis.length > 20 &&
    typeof bridge.investmentAvailabilityBasis === "string" && bridge.investmentAvailabilityBasis.length > 20,
  "cash/debt classification requires an explicit dated review");
  evidence(bridge.evidence, company, node, "cash, investments and debt classification");
  return structuredClone(bridge);
}

function normalizeBalances(row, bridge) {
  requireValue((same(row.cash_m, bridge.reportedCashM) || row.cash_m == null && bridge.reportedCashM === null) &&
    (same(row.debt_m, bridge.reportedDebtM) || row.debt_m == null && bridge.reportedDebtM === null),
  "raw cash/debt changed; re-review balance classification");
  row.reported_balance_financials = { cash_m: row.cash_m ?? null, debt_m: row.debt_m ?? null };
  row.cash_m = bridge.cashEquivalentsM + bridge.unrestrictedShortTermInvestmentsM;
  row.debt_m = bridge.fundedDebtM;
}

export function reviewedNonModelableReason({ ticker, fiscalPeriod, availableDate, periodEndDate, currency,
  company = guruValuationCompanyForTicker(ticker) }) {
  const nodes = company?.economicInputReview?.periods?.filter((node) => node.fiscalPeriod === fiscalPeriod) || [];
  if (!nodes.some((node) => node.status === "non_modelable")) return null;
  requireValue(company.reviewStatus === "reviewed" && !company.economicReview?.releaseBlockers?.length &&
    company.economicInputReview.status === "reviewed" && nodes.length === 1, "nonmodelable period lacks trusted unique review");
  const node = nodes[0];
  requireValue(node.reason === "pre_ipo_registration_statement_no_public_quoted_security" &&
    date(company.publicTradingStartedAt) && date(node.availableDate) && date(node.periodEndDate) &&
    node.availableDate < company.publicTradingStartedAt && node.periodEndDate <= node.availableDate &&
    availableDate === node.availableDate && periodEndDate === node.periodEndDate && currency === node.currency &&
    currency === company.currency, "invalid pre-IPO exclusion identity/date/currency");
  evidence(node.evidence, company, node, "pre-IPO registration statement");
  return node.reason;
}

// Only an independently reviewed issuer manifest can authorize an adjustment.
// Raw financial tables stay untouched; callers use these copied rows for the
// model AND its rolling cash-flow history so a raw-SBC add-back cannot leak back
// into a cycle-normalized DCF. This does not authorize issuer activation.
export function prepareReviewedEconomicRows({ ticker, rows,
  company = guruValuationCompanyForTicker(ticker) }) {
  const review = company?.economicInputReview;
  const claimed = rows.some((row) => row.reviewedEconomicInput || row.pitTrailingTwelveMonths?.reviewedEconomicInput);
  if (!review) {
    requireValue(!claimed, `${ticker}: untrusted economic adjustment marker`);
    return rows;
  }
  requireValue(company.ticker === ticker && company.reviewStatus === "reviewed" &&
    !company.economicReview?.releaseBlockers?.length && review.status === "reviewed" &&
    review.cashFlowConvention === convention && Array.isArray(review.periods), `${ticker}: issuer economic review incomplete`);
  requireValue(!claimed, `${ticker}: refusing to apply an economic adjustment twice`);
  const periods = new Map();
  for (const node of review.periods) {
    requireValue(!periods.has(node.fiscalPeriod), `${ticker}: duplicate reviewed period`);
    periods.set(node.fiscalPeriod, node);
  }
  const seen = new Set();
  const result = rows.map((original) => {
    const fiscalPeriod = `${original.fiscalYear}-${original.fiscalQuarter}`;
    requireValue(!seen.has(fiscalPeriod), `${ticker}: duplicated source period`);
    seen.add(fiscalPeriod);
    const node = periods.get(fiscalPeriod);
    requireValue(node, `${ticker}/${fiscalPeriod}: missing exact-period economic review`);
    requireValue(date(node.availableDate) && date(node.periodEndDate) &&
      node.periodEndDate <= node.availableDate && original.periodEndDate === node.periodEndDate &&
      String(original.financialAvailableAt || original.asOfDate).slice(0, 10) === node.availableDate &&
      original.asOfDate >= node.availableDate && node.currency === company.currency &&
      original.financialStatementCurrency === node.currency, `${ticker}/${fiscalPeriod}: date/currency mismatch`);
    const nonModelableReason = reviewedNonModelableReason({ ticker, fiscalPeriod, availableDate: node.availableDate,
      periodEndDate: node.periodEndDate, currency: node.currency, company });
    if (nonModelableReason) return { ...structuredClone(original), reviewedNonModelableReason: nonModelableReason };
    requireValue(number(node.otherEquityClaimsM) && node.otherEquityClaimsM >= 0,
      `${ticker}/${fiscalPeriod}: missing or invalid outstanding claims`);
    evidence(node.claimsEvidence, company, node, "claims");
    const base = flowBridge(node.quarter, original, company, node, "quarter");
    const trailing = flowBridge(node.ttm, original.pitTrailingTwelveMonths, company, node, "ttm");
    const row = structuredClone(original);
    const marker = { schemaVersion: 1, fiscalPeriod, availableDate: node.availableDate,
      periodEndDate: node.periodEndDate, reviewSha256: digest(node),
      otherEquityClaimsM: node.otherEquityClaimsM, claimsEvidence: structuredClone(node.claimsEvidence),
      optionClaims: optionClaims(node, company),
      quarter: base, ttm: trailing, warrantNormalization: warrantNormalization(node, company),
      balanceNormalization: balanceNormalization(node, company) };
    row.reported_fcf_after_capex_m = base.reportedFcfM;
    row.fcf_after_capex_m = base.economicFcfeM;
    row.reviewedEconomicInput = marker;
    row.pitTrailingTwelveMonths.reported_fcf_after_capex_m = trailing.reportedFcfM;
    row.pitTrailingTwelveMonths.fcf_after_capex_m = trailing.economicFcfeM;
    row.pitTrailingTwelveMonths.reviewedEconomicInput = marker;
    if (marker.balanceNormalization) {
      normalizeBalances(row, marker.balanceNormalization);
      normalizeBalances(row.pitTrailingTwelveMonths, marker.balanceNormalization);
    }
    if (marker.warrantNormalization) {
      normalizeWarrantOperatingInputs(row, marker.warrantNormalization.quarterContraRevenueM, marker.warrantNormalization.taxRate,
        marker.warrantNormalization.quarterReportedOperatingFinancials);
      normalizeWarrantOperatingInputs(row.pitTrailingTwelveMonths, marker.warrantNormalization.ttmContraRevenueM, marker.warrantNormalization.taxRate,
        marker.warrantNormalization.ttmReportedOperatingFinancials);
    }
    return row;
  });
  const byPeriod = new Map(result.map((row) => [`${row.fiscalYear}-${row.fiscalQuarter}`, row]));
  for (const row of result) {
    if (!row.reviewedEconomicInput?.warrantNormalization) continue;
    const prior = byPeriod.get(`${row.fiscalYear - 1}-${row.fiscalQuarter}`);
    row.reported_revenue_growth_pct = row.revenue_growth_pct ?? null;
    // Do not combine an adjusted current numerator with a reported prior base.
    row.revenue_growth_pct = prior?.reviewedEconomicInput?.warrantNormalization && prior.revenue_m > 0
      ? (row.revenue_m / prior.revenue_m - 1) * 100 : null;
  }
  return result;
}

function optionIntrinsicM(item, price, bound = null) {
  let credit = item.basis === "outstanding_employee_option_with_unrecognized_compensation_credit"
    ? item.unrecognizedCompensationCostM : 0;
  if (bound && item.compensationCreditRangeM) credit = item.compensationCreditRangeM[bound];
  // The credit is assumed proceeds in a treasury-stock approximation, not cash
  // received by the company. It avoids charging the same future service cost
  // through both recurring SBC and the full outstanding option claim.
  return Math.max(item.countM * (price - item.strike) - credit, 0);
}

function solveCommonValue(equityPoolM, sharesM, claims, bound = null) {
  if (!(equityPoolM > 0)) return null;
  let low = 0;
  let high = equityPoolM / sharesM;
  for (let iteration = 0; iteration < 90; iteration += 1) {
    const price = (low + high) / 2;
    const total = sharesM * price + claims.reduce((sum, item) => sum + optionIntrinsicM(item, price, bound), 0);
    if (total > equityPoolM) high = price; else low = price;
  }
  return (low + high) / 2;
}

export function applyReviewedEquityClaims(model, marker, sharesM) {
  if (!marker || !model) return model;
  requireValue(number(sharesM) && sharesM > 0 && number(marker.otherEquityClaimsM) && marker.otherEquityClaimsM >= 0,
    "invalid equity-claims denominator");
  requireValue(!model.scoreInputs?.reviewedEconomicInput, "refusing to deduct equity claims twice");
  requireValue(model.scoreInputs?.fcfGuidanceM == null,
    "issuer FCF guidance needs its own economic bridge before replacing adjusted FCFE");
  const fixedClaimsPerShare = marker.otherEquityClaimsM / sharesM;
  const equityPoolM = model.fairValue * sharesM - marker.otherEquityClaimsM;
  const claims = marker.optionClaims;
  requireValue(Array.isArray(claims), "missing reviewed vested-option claims");
  // Solve intrinsic/if-converted claims at MODEL value, never observed price:
  // common shares * P + sum(options * max(P - strike, 0)) = equity pool.
  const fairValue = solveCommonValue(equityPoolM, sharesM, claims);
  // Negative equity remains unmodeled, never clamped to a tiny positive price.
  if (!(fairValue > 0)) return null;
  const optionClaimPerShare = claims.reduce((sum, item) => sum + optionIntrinsicM(item, fairValue), 0) / sharesM;
  const growthFactor = model.targetPrice3Y / model.fairValue;
  return {
    ...model, fairValue, targetPrice3Y: fairValue * growthFactor,
    scoreInputs: { ...model.scoreInputs, reviewedEconomicInput: structuredClone(marker),
      fairValueBeforeOtherClaims: model.fairValue, otherEquityClaimsPerShare: fixedClaimsPerShare,
      vestedOptionClaimsPerShare: optionClaimPerShare,
      optionCompensationCreditSensitivity: {
        lowCreditFairValue: solveCommonValue(equityPoolM, sharesM, claims, "low"),
        highCreditFairValue: solveCommonValue(equityPoolM, sharesM, claims, "high")
      },
      optionValuationConvention: "model_value_intrinsic_if_converted_not_black_scholes" },
    methodOutputs: [...model.methodOutputs, {
      key: "other-equity-claims", label: "Other outstanding equity claims", value: -fixedClaimsPerShare,
      format: "currency", description: "Dated acquisition/other common-equity claims deducted once after the valuation blend. Net debt and recurring SBC are not deducted again here."
    }, {
      key: "vested-option-claims", label: "Option and warrant claims", value: -optionClaimPerShare,
      format: "currency", description: "Intrinsic/if-converted claims at model value, with exercise proceeds and reviewed unrecognized-service-cost credits. Credits are assumed proceeds, not cash. Customer-warrant contra-revenue is normalized first; option time value is excluded."
    }, {
      key: "economic-fcfe-bridge", label: "Economic cash-flow bridge", value: marker.ttm.economicFcfeM,
      format: "millions", description: "Reported CFO less cash capex, financing-classified operating license payments and recurring SBC. Reported GAAP inputs are preserved separately from any customer-warrant operating normalization."
    }],
    formula: `${model.formula}; less dated other claims; solve common-share value with vested-option intrinsic claims once`
  };
}

// The release checker reconstructs from the trusted manifest, not the stored
// model's assertion that its own adjustment passed. Checks the raw/economic
// bridge as well as the final weighted-equity subtraction.
export function auditReviewedEconomicInput({ ticker, fiscalPeriod, marker, financial, trailing,
  sharesM, fairValue, reconstructedBeforeClaims, asOfDate,
  company = guruValuationCompanyForTicker(ticker) }) {
  const review = company?.economicInputReview;
  if (!review && !marker) return { applies: false, failures: [], claimsPerShare: 0 };
  const failures = [];
  const fail = (detail) => failures.push({ ticker, period: fiscalPeriod, code: "unverified_economic_cash_claims_bridge", detail });
  const nodes = review?.periods?.filter((node) => node.fiscalPeriod === fiscalPeriod) || [];
  if (review?.status !== "reviewed" || company?.reviewStatus !== "reviewed" ||
      company?.economicReview?.releaseBlockers?.length || review?.cashFlowConvention !== convention || nodes.length !== 1 || !marker) {
    fail("Missing unique trusted issuer/period review");
    return { applies: true, failures, claimsPerShare: null };
  }
  const node = nodes[0];
  try {
    evidence(node.claimsEvidence, company, node, "claims");
    const options = optionClaims(node, company);
    const warrants = warrantNormalization(node, company);
    const balances = balanceNormalization(node, company);
    const quarter = flowBridge(node.quarter, { cfo_m: financial?.cfo_m, capex_m: financial?.capex_m }, company, node, "quarter");
    const ttm = flowBridge(node.ttm, { cfo_m: trailing?.cfo_m, capex_m: trailing?.capex_m }, company, node, "ttm");
    if (marker.reviewSha256 !== digest(node) || marker.fiscalPeriod !== fiscalPeriod ||
        canonical(marker.quarter) !== canonical(quarter) || canonical(marker.ttm) !== canonical(ttm) ||
        marker.availableDate !== node.availableDate || marker.periodEndDate !== node.periodEndDate ||
        canonical(marker.claimsEvidence) !== canonical(node.claimsEvidence) ||
        canonical(marker.optionClaims) !== canonical(options) ||
        canonical(marker.warrantNormalization) !== canonical(warrants) ||
        canonical(marker.balanceNormalization) !== canonical(balances) ||
        !same(marker.otherEquityClaimsM, node.otherEquityClaimsM) ||
        !date(String(asOfDate).slice(0, 10)) || asOfDate < node.availableDate) fail("Stored bridge differs from approved dated inputs");
    if (!same(financial?.fcf_after_capex_m, quarter.economicFcfeM) ||
        !same(trailing?.fcf_after_capex_m, ttm.economicFcfeM) ||
        !same(financial?.reported_fcf_after_capex_m, quarter.reportedFcfM) ||
        !same(trailing?.reported_fcf_after_capex_m, ttm.reportedFcfM)) fail("Model cash flow or preserved reported FCF does not reconcile");
    if (warrants) {
      for (const [data, amount, reported] of [[financial, warrants.quarterContraRevenueM, warrants.quarterReportedOperatingFinancials],
        [trailing, warrants.ttmContraRevenueM, warrants.ttmReportedOperatingFinancials]]) {
        for (const key of normalizedOperatingKeys) {
          const original = data?.reported_operating_financials?.[key];
          if (!(original === null && reported[key] === null) && !same(original, reported[key])) {
            fail(`Preserved GAAP input differs from approved source: ${key}`);
          }
          const expected = number(original) ? original + amount * (key === "net_income_m" ? 1 - warrants.taxRate : 1) : null;
          if (!(expected == null && data?.[key] == null && amount === 0) && !same(data?.[key], expected)) {
            fail(`Customer-warrant normalization does not reconcile: ${key}`);
          }
        }
      }
    }
    if (balances) {
      for (const data of [financial, trailing]) {
        const originals = data?.reported_balance_financials;
        for (const [key, expected] of [["cash_m", balances.reportedCashM], ["debt_m", balances.reportedDebtM]]) {
          if (!(originals?.[key] === null && expected === null) && !same(originals?.[key], expected)) fail("Reported cash/debt does not match dated source review");
        }
        if (!same(data?.cash_m, balances.cashEquivalentsM + balances.unrestrictedShortTermInvestmentsM) ||
          !same(data?.debt_m, balances.fundedDebtM)) fail("Economic cash/funded-debt classification differs from approved bridge");
      }
    }
  } catch (error) { fail(error.message); }
  const claimsPerShare = number(sharesM) && sharesM > 0 && number(node.otherEquityClaimsM) &&
    Array.isArray(node.optionClaims) && number(fairValue)
    ? (node.otherEquityClaimsM + node.optionClaims.reduce((sum, item) => sum + optionIntrinsicM(item, fairValue), 0)) / sharesM : null;
  if (claimsPerShare == null || !same(fairValue, reconstructedBeforeClaims - claimsPerShare)) fail("Equity claims were not deducted exactly once");
  return { applies: true, failures, claimsPerShare };
}
