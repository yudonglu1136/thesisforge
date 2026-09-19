import test from "node:test";
import assert from "node:assert/strict";
import { calculateTbbbUnderwrittenValuation as calculate, TBBB_UNDERWRITING } from "./tbbbUnderwrittenValuation.js";

const approx = (actual, expected, tolerance = 1e-8) => assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected}`);

function fixture() {
  const data = [
    ["2024-12-31",16346.618,12315.604,"2025-04-10","2024-04-26"],
    ["2025-03-31",17131.788,12684.248,"2025-05-07","2024-05-23"],
    ["2025-06-30",18769.679,13574.347,"2025-08-11","2024-08-21"],
    ["2025-09-30",20278.992,14833.806,"2025-11-19","2024-11-25"],
    ["2025-12-31",21972.484,16346.618,"2026-03-11","2025-04-10"],
    ["2026-03-31",22860.346,17131.788,"2026-05-06","2025-05-07"],
    ["2026-06-30",26037.292,18769.679,"2026-08-12","2025-08-11"]
  ];
  const point = (periodEndDate, revenueM, availableDate) => ({ periodEndDate, revenueM, availableDate,
    scope: "company_total", currency: "MXN", unit: "million", sourceDimension: "ARQ",
    sourceRecord: { ticker: "TBBB", periodEndDate, datekey: availableDate, dataset: "dated_test_fixture" } });
  const observations = data.map(([end, revenue, prior, available, priorAvailable]) => ({
    ...point(end, revenue, available), valuePct: (revenue / prior - 1) * 100,
    comparator: point(`${Number(end.slice(0,4)) - 1}${end.slice(4)}`, prior, priorAvailable)
  }));
  return { scenarioId: "base",
    economicInput: { asOfDate: "2026-09-05", periodEndDate: "2026-06-30", sourceCurrency: "MXN",
      sourceRevenue: 91149.114, sourceCfo: 7011.837, sourceCapex: 3772.646,
      rawSourceRecord: { ticker: "TBBB", datekey: "2026-08-12", reportperiod: "2026-06-30", dimension: "ART" } },
    financialTrendPct: 35.06348977093479,
    financialTrendEvidence: { asOfDate: "2026-09-05", unit: "percent", valuePct: 35.06348977093479,
      method: "normalizedRevenueGrowthForRows", windowSize: 8,
      selection: "latest_up_to_8_complete_observations_in_latest_8_period_window", observations },
    growthPolicySettings: { normalizedGrowthCapPct: 45, minimumGrowthSampleCount: 4, fundamentalGrowthPriorPct: 5 },
    fx: { baseCurrency: "USD", quoteCurrency: "MXN", rateDate: "2026-09-04", availableDate: "2026-09-04", mxnPerUsd: 19.6401 / 1.1622 }
  };
}

test("base is actually computable, with grounded budget and conservative current claims", () => {
  const r = calculate(fixture());
  assert.equal(r.methodReady, true);
  assert.equal(r.releaseReady, false); // independent release approval is not self-issued
  assert.deepEqual(r.failedChecks, []);
  approx(r.economicCashBridge.economicCashFlowM, 577.455);
  approx(r.anchors.ttm.wcM, 2525.655);
  approx(r.anchors.ttm.afterTaxLeaseAndInterestCashProfitM, 1852.301);
  approx(r.anchors.priorTtmRevenueM, 67081.891);
  approx(r.anchors.q1NoncashM, 383.131);
  approx(r.anchors.h1AfterDebtPrincipalM, 1117.570);
  approx(r.anchors.h1KnownCashNetBorrowingM, -629.615);
  approx(r.anchors.h1AfterDebtPrincipalAndCashBorrowingM, 487.955);
  approx(r.anchors.h1AfterDebtPrincipalAndReserveM, -65.922);
  assert.equal(r.value.shareClaimDenominator, 172019688);
  assert.equal(r.anchors.shareClaims.knownExerciseGross, 294951);
  assert.equal(r.anchors.shareClaims.knownWithheld, 26515);
  approx(r.fy2026.capitalProgramM, 5250);
  approx(r.fy2026.cashCapitalExpenditureIncludingSoftwareM, 3416.088546519791);
  approx(r.fy2026.noncashEquipmentFinancingM, 1833.911453480209);
  approx(r.value.fairValueUsd, 5.552744352097404);
});

test("FCFE subtracts every financed-category payment once, not cash capex twice", () => {
  const r = calculate(fixture());
  for (const row of [r.fy2026, ...r.forecast]) {
    approx(row.cashOperatingProfitBeforeLeaseAndDebtInterestM - row.embeddedLeasePrincipalM -
      row.embeddedLeaseInterestM - row.embeddedOtherDebtInterestM, row.cashOperatingProfitM);
    approx(row.companyFcfeM, row.cashOperatingProfitM + row.operatingWorkingCapitalCashBenefitM -
      row.cashCapitalExpenditureIncludingSoftwareM - row.otherDebtPrincipalM - row.increaseInOperatingCashReserveM + row.cashNetBorrowingM);
    assert.equal(row.additionalLeaseServiceM, 0);
    assert.equal(row.extraSupplierFinanceDeductionM, 0);
    assert.equal(row.additionalIntangibleChargeM, 0); // included in prospective capital program
  }
  r.forecast.forEach((row) => assert.equal(row.cashNetBorrowingM, 0));
  approx(r.fy2026.cashNetBorrowingM, -629.615);
  // The FY2026 reserve begins with actual FY2025 cash, not an invented equal historical margin.
  approx(r.fy2026.increaseInOperatingCashReserveM, r.fy2026.endingOperatingCashReserveM - 1427.248);
  approx(r.stub.h2CompanyFcfeM, r.fy2026.companyFcfeM + 65.922);
  approx(r.stub.h2CompanyFcfeM, r.stub.estimatedPostJuneCashAtAsOfM + r.stub.remainingStubFcfeM);
});

test("actual PIT median, guide band and maximum 25% weight are independently recalculated", () => {
  const r = calculate(fixture());
  approx(r.guidanceAudit.appliedGrowth, 0.3392261732820109);
  assert.equal(r.guidanceAudit.appliedWeight, 0.25);
  assert.match(r.guidanceAudit.revenueAmountLabel, /NOT_issuer_amount_guidance/);
  for (const mutate of [
    (x) => { x.financialTrendEvidence.observations[0].revenueM += 10; },
    (x) => { x.financialTrendEvidence.observations.push(x.financialTrendEvidence.observations[6]); },
    (x) => { x.financialTrendEvidence.observations[6].availableDate = "2026-09-06"; },
    (x) => { x.financialTrendEvidence.observations[0].comparator.scope = "segment"; },
    (x) => { x.financialTrendPct = 39; }
  ]) { const x = fixture(); mutate(x); assert.equal(calculate(x).status, "blocked"); }
});

test("no market-price dilution, hidden strike pricing, or duplicate existing SBC charge", () => {
  const x = fixture();
  const original = calculate(x);
  x.marketPriceUsd = 500;
  x.optionPolicy = { timeValueReserveUsdM: 5000 };
  const other = calculate(x);
  assert.deepEqual(original, other);
  assert.equal(original.anchors.shareClaims.hypotheticalFutureExerciseProceedsM, 0);
  const keep = 1 / (1 + 3401000 / 172019688);
  approx(original.stub.ownershipRetention, keep); // full upcoming December batch, not a 117/365 fraction
  original.forecast.forEach((row, index) => {
    approx(row.ownershipRetention, keep ** (index + 2));
    approx(row.attributableFcfeM, row.companyFcfeM * keep ** (index + 2));
    assert.equal(row.futureAwardCashExpenseM, 0);
  });
  approx(original.terminal.perCurrentClaimGrowth, 1.03 * keep - 1);
});

test("nominal MXN discounting equals USD FX-parity discounting, including the USD asset", () => {
  const r = calculate(fixture());
  approx(r.analystAssumptions.keUsd, 0.1224);
  approx(r.analystAssumptions.keMxn, 0.13340392156862757);
  for (const row of r.forecast) approx(row.pvMxnM / r.fx.mxnPerUsd, row.equivalentUsdPvM);
  const a = r.analystAssumptions;
  const assetMxnAtPayout = 236 * r.fx.mxnPerUsd * a.currencyParityRatio ** r.stub.timeYears;
  approx(assetMxnAtPayout * a.ownershipRetentionPerBatch / (1 + a.keMxn) ** r.stub.timeYears, r.cashAsset.cashAssetPvMxnM);
  // June USD deposits are not a fixed MXN4128.611m asset in September.
  assert.notEqual(r.cashAsset.cashAssetPvMxnM, 4128.611);
  // Directly sum 500 post-2031 company cash flows and fresh award dilution;
  // independently verify the closed-form terminal without calling its formula.
  const last = r.forecast.at(-1);
  let cash = last.companyFcfeM;
  let ownership = last.ownershipRetention;
  let terminalSumAt2031M = 0;
  for (let year = 1; year <= 500; year += 1) {
    cash *= 1.03;
    ownership *= a.ownershipRetentionPerBatch;
    terminalSumAt2031M += cash * ownership / (1 + a.keMxn) ** year;
  }
  approx(terminalSumAt2031M, r.terminal.terminalValueMxnM);
});

test("downside financing failure is exposed and cannot masquerade as a publishable target", () => {
  const r = calculate({ ...fixture(), scenarioId: "downside" });
  assert.equal(r.methodReady, false);
  assert.equal(r.value.fairValueUsd, null);
  assert.ok(r.value.conditionalMechanicalValueUsd > 0);
  approx(r.funding.fundingDeficitM, 3825.02936863673);
  assert.ok(r.failedChecks.includes("noCashFundingDeficitUnderRetention"));
  assert.ok(r.failedChecks.includes("terminalValueShareAtMost080"));
  const up = calculate({ ...fixture(), scenarioId: "upside" });
  assert.equal(up.methodReady, true);
  approx(up.value.fairValueUsd, 7.852097547618369);
});

test("only the reviewed current date, period, amounts and ECB observation are accepted", () => {
  for (const mutate of [
    (x) => { x.economicInput.asOfDate = "2026-09-04"; },
    (x) => { x.economicInput.asOfDate = "2026-09-06"; },
    (x) => { x.economicInput.periodEndDate = "2026-03-31"; },
    (x) => { x.economicInput.sourceCfo += 0.001; },
    (x) => { x.economicInput.sourceCurrency = "USD"; },
    (x) => { x.economicInput.rawSourceRecord.datekey = "2026-09-06"; },
    (x) => { x.fx.mxnPerUsd = 20; },
    (x) => { x.fx.availableDate = "2026-09-06"; },
    (x) => { delete x.scenarioId; }
  ]) { const x = fixture(); mutate(x); assert.equal(calculate(x).status, "blocked"); }
  assert.ok(Object.isFrozen(TBBB_UNDERWRITING));
  assert.ok(Object.isFrozen(TBBB_UNDERWRITING.reported));
  assert.equal(calculate(null).status, "blocked");
  const input = fixture();
  const before = structuredClone(input);
  calculate(input);
  assert.deepEqual(input, before);
});
