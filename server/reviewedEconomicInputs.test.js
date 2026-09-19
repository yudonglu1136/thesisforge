import assert from "node:assert/strict";
import test from "node:test";
import { prepareReviewedEconomicRows, applyReviewedEquityClaims, auditReviewedEconomicInput, reviewedNonModelableReason } from "./reviewedEconomicInputs.js";

function fixture() {
  const source = { url: "https://www.sec.gov/Archives/edgar/data/1807794/fixture/report.htm",
    availableDate: "2026-09-02", periodEndDate: "2026-08-01", locator: "Cash-flow statement and claims notes", sha256: "a".repeat(64) };
  const flow = { cfoM: 90.231, capexM: 7.282, sbcM: 87.979, licensePaymentsM: 5.172, evidence: [source] };
  const node = { fiscalPeriod: "2027-Q1", periodEndDate: "2026-08-01", availableDate: "2026-09-02", currency: "USD",
    quarter: flow, ttm: { ...flow, cfoM: 500, capexM: 60, sbcM: 180, licensePaymentsM: 20 },
    otherEquityClaimsM: 310, claimsEvidence: [source], optionClaims: [] };
  const company = { ticker: "CRDO", cik: "0001807794", currency: "USD", reviewStatus: "reviewed", economicReview: { releaseBlockers: [] },
    economicInputReview: { status: "reviewed", cashFlowConvention: "reported_cfo_less_cash_capex_licenses_and_sbc", periods: [node] } };
  const row = { ticker: "CRDO", fiscalYear: 2027, fiscalQuarter: "Q1", periodEndDate: node.periodEndDate,
    financialAvailableAt: node.availableDate, asOfDate: node.availableDate, financialStatementCurrency: "USD",
    cfo_m: flow.cfoM, capex_m: flow.capexM, fcf_after_capex_m: 82.949, net_income_m: 68.44,
    shares_m: 187.768, pitTrailingTwelveMonths: { cfo_m: 500, capex_m: 60, fcf_after_capex_m: 440, net_income_m: 150 } };
  return { ticker: "CRDO", rows: [row], company, node, row };
}

test("economic cash correction preserves raw input and does not expense GAAP SBC twice", () => {
  const input = fixture(); const before = structuredClone(input);
  const [row] = prepareReviewedEconomicRows(input);
  assert.deepEqual(input, before);
  assert.ok(Math.abs(row.fcf_after_capex_m - (-10.202)) < 1e-8);
  assert.equal(row.reported_fcf_after_capex_m, 82.949);
  assert.equal(row.net_income_m, 68.44);
  assert.equal(row.pitTrailingTwelveMonths.fcf_after_capex_m, 240);
  assert.equal(row.pitTrailingTwelveMonths.net_income_m, 150);
});

test("unreviewed/missing/duplicate schedules and applying twice fail closed", () => {
  for (const mutate of [
    (input) => { input.company.reviewStatus = "unreviewed"; },
    (input) => { input.company.economicReview.releaseBlockers = ["claims_pending"]; },
    (input) => { input.company.economicInputReview.periods = []; },
    (input) => { input.company.economicInputReview.periods.push(input.node); },
    (input) => { input.rows.push(input.row); }
  ]) { const input = fixture(); mutate(input); assert.throws(() => prepareReviewedEconomicRows(input)); }
  const input = fixture(); const rows = prepareReviewedEconomicRows(input);
  assert.throws(() => prepareReviewedEconomicRows({ ...input, rows }), /twice/);
  assert.throws(() => prepareReviewedEconomicRows({ ...input, rows, company: null }), /untrusted/);
});

test("changed raw cash, future/foreign evidence and missing values cannot enter FCFE", () => {
  for (const mutate of [
    (input) => { input.row.cfo_m += 1; },
    (input) => { input.row.fcf_after_capex_m += 1; },
    (input) => { input.node.quarter.sbcM = null; },
    (input) => { input.node.quarter.licensePaymentsM = -1; },
    (input) => { input.node.quarter.evidence[0].availableDate = "2026-09-03"; },
    (input) => { input.node.quarter.evidence[0].url = "https://www.sec.gov/Archives/edgar/data/42/report.htm"; },
    (input) => { input.node.ttm.evidence = []; },
    (input) => { input.node.currency = "GBP"; },
    (input) => { input.node.otherEquityClaimsM = null; },
    (input) => { input.node.availableDate = "2026-02-30"; }
  ]) { const input = fixture(); mutate(input); assert.throws(() => prepareReviewedEconomicRows(input)); }
});

test("unaffected issuers are a byte-preserving no-op", () => {
  const input = fixture(); assert.equal(prepareReviewedEconomicRows({ ...input, company: null }), input.rows);
});

function sampleModel() { return { fairValue: 100, targetPrice3Y: 130, methodOutputs: [], scoreInputs: {}, formula: "weighted model" }; }

test("other equity claims deducted once, without repeating net debt or changing growth", () => {
  const input = fixture(); const [row] = prepareReviewedEconomicRows(input);
  const model = sampleModel(); const output = applyReviewedEquityClaims(model, row.reviewedEconomicInput, 187.768);
  assert.ok(Math.abs(output.fairValue - (100 - 310 / 187.768)) < 1e-8);
  assert.equal(output.targetPrice3Y / output.fairValue, 1.3);
  assert.deepEqual(model, sampleModel());
  assert.throws(() => applyReviewedEquityClaims(output, row.reviewedEconomicInput, 187.768), /twice/);
  assert.equal(applyReviewedEquityClaims({ ...model, fairValue: 1 }, row.reviewedEconomicInput, 187.768), null);
});

test("independent economic audit rejects altered bridge, missing marker and omitted/double claims", () => {
  const input = fixture(); const [row] = prepareReviewedEconomicRows(input);
  const model = applyReviewedEquityClaims(sampleModel(), row.reviewedEconomicInput, 187.768);
  const args = { ticker: "CRDO", fiscalPeriod: "2027-Q1", marker: row.reviewedEconomicInput,
    financial: row, trailing: row.pitTrailingTwelveMonths, sharesM: 187.768,
    fairValue: model.fairValue, reconstructedBeforeClaims: 100, asOfDate: row.asOfDate, company: input.company };
  assert.deepEqual(auditReviewedEconomicInput(args).failures, []);
  for (const mutate of [
    (args) => { args.marker.ttm.economicFcfeM += 1; },
    (args) => { args.marker = null; },
    (args) => { args.financial.reported_fcf_after_capex_m = null; },
    (args) => { args.trailing.fcf_after_capex_m = 440; },
    (args) => { args.fairValue = 100; },
    (args) => { args.fairValue = 100 - 620 / 187.768; },
    (args) => { args.asOfDate = "2026-09-01"; },
    (args) => { args.company = null; }
  ]) { const changed = structuredClone(args); mutate(changed); assert.ok(auditReviewedEconomicInput(changed).failures.length); }
});

test("vested option intrinsic claims include exercise proceeds without market-price inputs", () => {
  const input = fixture();
  input.node.optionClaims = [{ id: "exercisable", countM: 1.7, strike: 2.34, currency: "USD",
    basis: "vested_employee_option", evidence: input.node.claimsEvidence }];
  const [row] = prepareReviewedEconomicRows(input);
  const result = applyReviewedEquityClaims(sampleModel(), row.reviewedEconomicInput, 187.768);
  const expected = (100 * 187.768 - 310 + 1.7 * 2.34) / (187.768 + 1.7);
  assert.ok(Math.abs(result.fairValue - expected) < 1e-10);
  assert.deepEqual(auditReviewedEconomicInput({ ticker: "CRDO", fiscalPeriod: "2027-Q1", marker: row.reviewedEconomicInput,
    financial: row, trailing: row.pitTrailingTwelveMonths, sharesM: 187.768, fairValue: result.fairValue,
    reconstructedBeforeClaims: 100, asOfDate: row.asOfDate, company: input.company }).failures, []);
  input.node.optionClaims[0].strike = 200;
  const [outOfMoney] = prepareReviewedEconomicRows(input);
  assert.ok(Math.abs(applyReviewedEquityClaims(sampleModel(), outOfMoney.reviewedEconomicInput, 187.768).fairValue - (100 - 310 / 187.768)) < 1e-10);
});

test("unvested awards/customer warrants cannot masquerade as reviewed vested employee options", () => {
  for (const basis of ["unvested_employee_option", "customer_warrant"]) {
    const input = fixture();
    input.node.optionClaims = [{ id: "claim", countM: 1, strike: 1, currency: "USD", basis, evidence: input.node.claimsEvidence }];
    assert.throws(() => prepareReviewedEconomicRows(input), /unsupported option claim/);
  }
});

test("outstanding option claims credit remaining service cost once and disclose sensitivity", () => {
  const input = fixture();
  input.node.optionClaims = [{ id: "outstanding-options", countM: 2, strike: 3, currency: "USD",
    basis: "outstanding_employee_option_with_unrecognized_compensation_credit",
    unrecognizedCompensationCostM: 4, compensationCreditBasis: "analyst_straight_line_estimate",
    compensationCreditRangeM: { low: 0, high: 6 },
    estimateRationale: "Straight-line rollforward from the dated annual grant-service schedule; no new grants assumed.",
    evidence: input.node.claimsEvidence }];
  const [row] = prepareReviewedEconomicRows(input);
  const result = applyReviewedEquityClaims(sampleModel(), row.reviewedEconomicInput, 187.768);
  assert.ok(Math.abs(result.fairValue - (100 * 187.768 - 310 + 2 * 3 + 4) / (187.768 + 2)) < 1e-10);
  const bounds = result.scoreInputs.optionCompensationCreditSensitivity;
  assert.ok(bounds.lowCreditFairValue < result.fairValue);
  assert.ok(bounds.highCreditFairValue > result.fairValue);
  for (const mutation of [
    (node) => { node.optionClaims[0].unrecognizedCompensationCostM = null; },
    (node) => { node.optionClaims[0].compensationCreditRangeM.high = 1; },
    (node) => { node.optionClaims[0].estimateRationale = ""; }
  ]) { const changed = structuredClone(input); mutation(changed.node); assert.throws(() => prepareReviewedEconomicRows(changed)); }
});

function withWarrants() {
  const input = fixture();
  for (const data of [input.row, input.row.pitTrailingTwelveMonths]) {
    Object.assign(data, { revenue_m: 100, gross_profit_m: 60, operating_income_m: 20, net_income_m: 10 });
  }
  input.node.warrantNormalization = { quarterContraRevenueM: 2, ttmContraRevenueM: 5,
    taxRate: 0.21, taxRateBasis: "analyst_marginal_tax_rate_not_reported",
    quarterReportedOperatingFinancials: { revenue_m: 100, gross_profit_m: 60, operating_income_m: 20, net_income_m: 10 },
    ttmReportedOperatingFinancials: { revenue_m: 100, gross_profit_m: 60, operating_income_m: 20, net_income_m: 10 },
    evidence: input.node.claimsEvidence };
  input.node.optionClaims = [{ id: "customer-vested", countM: 1, strike: 10.74,
    currency: "USD", basis: "vested_customer_warrant", evidence: input.node.claimsEvidence }];
  return input;
}

test("customer warrants normalize noncash operating charges before deducting existing claims", () => {
  const input = withWarrants(); const before = structuredClone(input);
  const [row] = prepareReviewedEconomicRows(input);
  assert.deepEqual(input, before);
  assert.equal(row.revenue_m, 102);
  assert.equal(row.net_income_m, 11.58);
  assert.equal(row.pitTrailingTwelveMonths.net_income_m, 13.95);
  assert.equal(row.cfo_m, input.row.cfo_m);
  assert.equal(row.reported_operating_financials.net_income_m, 10);
  assert.equal(row.revenue_growth_pct, null);
  const model = applyReviewedEquityClaims(sampleModel(), row.reviewedEconomicInput, 187.768);
  const args = { ticker: "CRDO", fiscalPeriod: "2027-Q1", marker: row.reviewedEconomicInput,
    financial: row, trailing: row.pitTrailingTwelveMonths, sharesM: 187.768,
    fairValue: model.fairValue, reconstructedBeforeClaims: 100, asOfDate: row.asOfDate, company: input.company };
  assert.deepEqual(auditReviewedEconomicInput(args).failures, []);
  args.financial.net_income_m += 1;
  args.financial.reported_operating_financials.net_income_m += 1;
  assert.ok(auditReviewedEconomicInput(args).failures.length);
});

test("customer warrants cannot enter without an exact source and explicit tax bridge", () => {
  for (const mutation of [
    (input) => { delete input.node.warrantNormalization; },
    (input) => { input.node.warrantNormalization.ttmContraRevenueM = null; },
    (input) => { input.node.warrantNormalization.taxRateBasis = "reported"; },
    (input) => { input.row.revenue_m += 1; },
    (input) => { input.node.warrantNormalization.quarterReportedOperatingFinancials = null; }
  ]) { const input = withWarrants(); mutation(input); assert.throws(() => prepareReviewedEconomicRows(input)); }
});

test("a pre-IPO source remains preserved but cannot be emitted as public-security valuation", () => {
  const input = fixture();
  input.company.publicTradingStartedAt = "2022-01-27";
  const node = { fiscalPeriod: "2021-Q4", periodEndDate: "2021-04-30", availableDate: "2022-01-03",
    currency: "USD", status: "non_modelable", reason: "pre_ipo_registration_statement_no_public_quoted_security",
    evidence: [{ ...input.node.claimsEvidence[0], availableDate: "2022-01-03", periodEndDate: "2021-04-30" }] };
  input.company.economicInputReview.periods = [node];
  input.rows = [{ ...input.row, fiscalYear: 2021, fiscalQuarter: "Q4", periodEndDate: node.periodEndDate,
    financialAvailableAt: node.availableDate, asOfDate: node.availableDate }];
  const [row] = prepareReviewedEconomicRows(input);
  assert.equal(row.reviewedNonModelableReason, node.reason);
  assert.equal(row.fcf_after_capex_m, input.row.fcf_after_capex_m);
  const args = { ticker: "CRDO", fiscalPeriod: node.fiscalPeriod, availableDate: node.availableDate,
    periodEndDate: node.periodEndDate, currency: "USD", company: input.company };
  assert.equal(reviewedNonModelableReason(args), node.reason);
  input.company.publicTradingStartedAt = "2022-01-01";
  assert.throws(() => reviewedNonModelableReason(args), /pre-IPO/);
});

test("funded-debt bridge excludes operating leases already charged in CFO and includes reviewed unrestricted investments", () => {
  const input = fixture();
  for (const data of [input.row, input.row.pitTrailingTwelveMonths]) Object.assign(data, { cash_m: 100, debt_m: 20 });
  input.node.balanceNormalization = { reportedCashM: 100, reportedDebtM: 20,
    cashEquivalentsM: 100, unrestrictedShortTermInvestmentsM: 30, fundedDebtM: 0,
    operatingLeaseCurrentM: 5, operatingLeaseNoncurrentM: 20,
    fundedDebtBasis: "The original debt field is an operating lease balance; no outstanding funded borrowings disclosed.",
    investmentAvailabilityBasis: "Dated investment note identifies unrestricted short-term government securities.", evidence: input.node.claimsEvidence };
  const [row] = prepareReviewedEconomicRows(input);
  assert.equal(row.cash_m, 130);
  assert.equal(row.debt_m, 0);
  assert.deepEqual(row.reported_balance_financials, { cash_m: 100, debt_m: 20 });
  const model = applyReviewedEquityClaims(sampleModel(), row.reviewedEconomicInput, 187.768);
  const args = { ticker: "CRDO", fiscalPeriod: "2027-Q1", marker: row.reviewedEconomicInput,
    financial: row, trailing: row.pitTrailingTwelveMonths, sharesM: 187.768,
    fairValue: model.fairValue, reconstructedBeforeClaims: 100, asOfDate: row.asOfDate, company: input.company };
  assert.deepEqual(auditReviewedEconomicInput(args).failures, []);
  args.financial.debt_m = 20;
  assert.ok(auditReviewedEconomicInput(args).failures.length);
  input.node.balanceNormalization.fundedDebtM = null;
  assert.throws(() => prepareReviewedEconomicRows(input));
});
