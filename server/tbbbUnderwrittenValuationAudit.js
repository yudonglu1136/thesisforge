import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

// Deliberately does not import either TBBB valuation implementation. The caller
// supplies frozen, source-reviewed configs and original saved inputs separately.
const total = (xs) => xs.reduce((a, b) => a + b, 0);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const dayCount = (a, b) => (Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000;
const near = (a, b) => typeof a === "number" && Number.isFinite(a) && Math.abs(a - b) <= 1e-7;
const clamp = (x, a, b) => Math.min(b, Math.max(a, x));

export function auditTbbbSourceBindings(binding, { read = readFileSync } = {}) {
  const failures = [];
  const check = (ok, code) => { if (!ok) failures.push(code); };
  check(binding?.schemaVersion === "tbbb-source-binding-v1", "source_binding_schema");
  check(binding?.sourceCutoff === "2026-09-05" && binding?.historicalApproval === false, "source_binding_scope");
  const files = [...(binding?.configBindings || []), binding?.submissionIndexBinding, ...(binding?.documents || [])];
  check(files.length >= 20, "complete_source_bundle_required");
  for (const file of files) {
    if (!file?.path || !/^[a-f0-9]{64}$/.test(file.sha256 || "")) { failures.push("source_file_binding_missing"); continue; }
    try {
      const raw = read(file.path);
      check(hash(raw) === file.sha256 && raw.length === file.byteLength, `source_bytes_changed:${file.path}`);
    } catch { failures.push(`source_bytes_unavailable:${file.path}`); }
  }
  const urls = new Set();
  let submissionRows;
  try { submissionRows = JSON.parse(read(binding.submissionIndexBinding.path)).filings.recent; }
  catch { failures.push("SEC_submission_index_not_parseable"); }
  for (const document of binding?.documents || []) {
    check(!urls.has(document.url), `duplicate_source:${document.url}`); urls.add(document.url);
    check(/^\d{4}-\d{2}-\d{2}$/.test(document.availableDate) && document.availableDate <= binding.sourceCutoff,
      `source_after_cutoff:${document.url}`);
    if (document.sourceAuthority === "issuer_SEC") {
      check(/^https:\/\/www.sec.gov\/Archives\/edgar\/data\/1978954\//.test(document.url), "wrong_issuer_source");
      const index = submissionRows?.accessionNumber?.indexOf(document.submissionBinding?.accession) ?? -1;
      // SEC after-hours acceptance may precede its next-business-day filing
      // date. Bind both exact index fields; do not force their UTC dates equal.
      check(document.submissionBinding?.filed === document.availableDate &&
        index >= 0 && submissionRows.filingDate[index] === document.availableDate &&
        submissionRows.acceptanceDateTime[index] === document.submissionBinding?.acceptedAt &&
        Number.isFinite(Date.parse(document.submissionBinding?.acceptedAt)) &&
        document.submissionBinding.acceptedAt.slice(0, 10) <= binding.sourceCutoff,
      `SEC_filing_date_unbound:${document.url}`);
    }
  }
  for (const configFile of binding?.configBindings || []) {
    try {
      const config = JSON.parse(read(configFile.path));
      for (const source of Object.values(config.sources)) check(urls.has(source.url), `configured_source_missing:${source.url}`);
    } catch { failures.push("unreadable_source_config"); }
  }
  return { status: failures.length ? "fail" : "pass", failures,
    scope: "immutable_source_bytes_and_dated_identity_binding_not_automatic_economic_approval" };
}

export function auditTbbbReviewedSourceFacts(review, binding, economicEvidence, { read = readFileSync, input } = {}) {
  const failures = [];
  const check = (ok, code) => { if (!ok) failures.push(code); };
  const docs = new Map((binding?.documents || []).map((d) => [d.url, d]));
  const textCache = new Map();
  const visible = (doc) => {
    if (!textCache.has(doc.url)) {
      const bytes = read(doc.path);
      if (hash(bytes) !== doc.sha256) throw new Error("source_changed");
      const text = bytes.toString("utf8").replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, " ")
        .replace(/<[^>]*>/g, " ").replace(/&#x([\da-f]+);/gi, (_, code) => String.fromCodePoint(parseInt(code, 16)))
        .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
        .replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&quot;/gi, '"').replace(/\s+/g, " ").trim();
      textCache.set(doc.url, text);
    }
    return textCache.get(doc.url);
  };
  try {
    check(review?.schemaVersion === "tbbb-current-source-fact-review-v1" &&
      review.sourceCutoff === "2026-09-05" && review.historicalEconomicApproval === false, "fact_review_scope");
    const facts = review.financialFacts || [];
    check(facts.length === 36, "36_exact_cash_observations_required");
    const seen = new Set();
    for (const period of economicEvidence.financialPeriods) {
      const source = economicEvidence.sources[period.sourceId];
      const doc = docs.get(source.url);
      for (const [metric, value] of Object.entries(period.values)) {
        const rows = facts.filter((f) => f.periodId === period.id && f.metric === metric);
        check(rows.length === 1, `missing_duplicate_fact:${period.id}.${metric}`);
        const row = rows[0]; if (!row || !doc) continue;
        seen.add(`${period.id}.${metric}`);
        check(row.value === value && row.unit === "MXN_thousand" && row.periodStartDate === period.periodStartDate &&
          row.periodEndDate === period.periodEndDate && row.availableDate === source.availableDate &&
          row.url === source.url && row.sourceSha256 === doc.sha256, `source_fact_identity:${period.id}.${metric}`);
        check(typeof row.sourceRow === "string" && row.sourceRow.length > 10 && visible(doc).includes(row.sourceRow),
          `source_row_not_in_bound_document:${period.id}.${metric}`);
        check(row.sourceRow.includes(value.toLocaleString("en-US", { useGrouping: true })),
          `source_row_value_missing:${period.id}.${metric}`);
      }
    }
    check(seen.size === 36, "incomplete_source_fact_schedule");
    for (const passage of review.sourcePassageChecks || []) {
      const doc = docs.get(passage.url);
      check(doc && passage.sourceSha256 === doc.sha256 && passage.availableDate === doc.availableDate,
        `passage_source_unbound:${passage.sourceId}`);
    }
    check(review.sourcePassageChecks?.length >= 19 && review.macroObservations?.length === 3, "claims_guidance_macro_review_missing");
    const observations = input?.financialTrendEvidence?.observations || [];
    const growthFacts = review.growthFacts || [];
    check(observations.length > 0 && growthFacts.length === observations.length * 2, "complete_official_growth_revenue_corroboration_required");
    for (const observation of observations) for (const [role, point] of [["current", observation], ["comparator", observation.comparator]]) {
      const rows = growthFacts.filter((f) => f.observationPeriod === observation.periodEndDate && f.role === role);
      const fact = rows[0], doc = docs.get(fact?.url);
      check(rows.length === 1 && doc, `missing_growth_source:${observation.periodEndDate}.${role}`);
      if (!fact || !doc) continue;
      check(fact.periodEndDate === point.periodEndDate && fact.currency === "MXN" && fact.rawUnit === "MXN_thousand" &&
        near(fact.rawValueK / 1000, point.revenueM) && fact.revenueM === point.revenueM &&
        fact.sourceSha256 === doc.sha256 && fact.sourceAvailableDate === doc.availableDate &&
        fact.sourceAvailableDate <= review.sourceCutoff && fact.providerAvailableDate === point.availableDate,
      `growth_source_value_date_currency:${observation.periodEndDate}.${role}`);
      check(typeof fact.sourceRow === "string" && visible(doc).includes(fact.sourceRow) &&
        fact.sourceRow.includes(fact.rawValueK.toLocaleString("en-US")), `growth_row_not_in_source:${observation.periodEndDate}.${role}`);
    }
  } catch (error) { failures.push(`malformed_source_fact_review:${error.message}`); }
  return { status: failures.length ? "fail" : "pass", failures,
    scope: "exact_current_cash_observations_and_source_provenance_not_historical_or_analyst_forecast_approval" };
}

export function auditTbbbUnderwrittenValuation({ input, result: r, economicEvidence: E, underwriting: C }) {
  const failures = [];
  const check = (ok, code) => { if (!ok) failures.push(code); };
  const eq = (actual, expected, field) => check(near(actual, expected), `mismatch:${field}`);
  try {
    check(r.asOfDate === "2026-09-05" && r.periodEndDate === "2026-06-30" &&
      input.economicInput.asOfDate === r.asOfDate && input.economicInput.periodEndDate === r.periodEndDate,
    "current_only_scope");
    check(r.releaseReady === false, "model_cannot_self_approve_release");
    check(C.asOfDate === r.asOfDate && C.periodEndDate === r.periodEndDate &&
      E.periodEndDate === r.periodEndDate && E.reviewedThroughDate === r.asOfDate, "config_scope");
    check(input.economicInput.sourceCurrency === "MXN" && r.value.currency === "USD" &&
      E.issuer.cik === "1978954" && E.issuer.securityFactor === 1, "issuer_currency_and_security_basis");
    check(Object.values(C.sources).every((s) => s.availableDate <= r.asOfDate), "underwriting_source_future");
    const P = C.reported;
    const policy = C.analystPolicies;
    const scenario = C.scenarios[input.scenarioId];
    check(input.scenarioId === r.scenarioId && Boolean(scenario), "scenario_identity");

    const ttm = Object.fromEntries(Object.keys(E.financialMetrics).map((key) => [key,
      total(E.financialPeriods.map((p) => p.values[key] * E.ttmFormula[p.id])) / 1000]));
    const netCapex = ttm.ppePurchases - ttm.ppeDisposals;
    const economicCash = ttm.cfo - netCapex - ttm.intangibleCapex - ttm.leasePrincipal - ttm.leaseInterest - ttm.otherDebtInterest;
    eq(input.economicInput.sourceRevenue, ttm.revenue, "raw_TTM_revenue");
    eq(input.economicInput.sourceCfo, ttm.cfo, "raw_TTM_CFO");
    eq(input.economicInput.sourceCapex, netCapex, "raw_TTM_net_PPE");
    for (const [field, expected] of Object.entries({ cfoM: ttm.cfo, netPpeCapexM: netCapex,
      leasePrincipalM: ttm.leasePrincipal, leaseInterestM: ttm.leaseInterest, otherDebtInterestM: ttm.otherDebtInterest,
      intangibleCapexM: ttm.intangibleCapex, economicCashFlowM: economicCash,
      reportedTtmSbcM: ttm.sbc, sbcDeductedM: 0, supplierFinanceDeductedAgainM: 0 })) eq(r.economicCashBridge[field], expected, field);

    const issued = total(Object.values(E.shareClaims.issuedByClass));
    const fixed = issued + total(E.shareClaims.conditionalAwards.map((a) => a.shares));
    const maximum = fixed + total(E.shareClaims.options.map((a) => a.shares));
    const withheld = total(P.knownExercises.map((x) => x.withheldShares));
    const claims = maximum - withheld;
    eq(r.value.shareClaimDenominator, claims, "all_classes_awards_options_less_known_withholding");
    eq(r.anchors.shareClaims.conservativeCurrentMaximumClaims, claims, "maximum_claim_rollforward");
    eq(r.anchors.shareClaims.hypotheticalFutureExerciseProceedsM, 0, "no_unreceived_option_cash");
    const newAwards = P.futureGrantAnchor.newOptions + P.futureGrantAnchor.newRsus;
    const keep = claims / (claims + newAwards);
    eq(r.analystAssumptions.ownershipRetentionPerBatch, keep, "future_award_cost_once");

    const wc = (id) => total(P[id].wcMovementsM);
    const profit = (id) => P[id].cfoM - wc(id) - P[id].leasePrincipalM - P[id].leaseInterestM - P[id].otherInterestM;
    const ttmWc = wc("fy2025") + wc("h12026") - wc("h12025");
    const ttmProfit = profit("fy2025") + profit("h12026") - profit("h12025");
    const priorRevenue = P.fy2024.revenueM + P.h12025.revenueM - P.h12024.revenueM;
    const opMargin = scenario.operatingMarginAnchor === "ttm" ? ttmProfit / ttm.revenue :
      profit(scenario.operatingMarginAnchor) / P[scenario.operatingMarginAnchor].revenueM;
    const wcCoefficient = scenario.workingCapitalAnchor === "ttm" ? ttmWc / (ttm.revenue - priorRevenue) :
      wc("fy2025") / (P.fy2025.revenueM - P.fy2024.revenueM);
    const B = P.budget;
    const cashFraction = scenario.cashFinancingAnchor === "q12026" ?
      (B.q1CashPpeM + B.q1CashIntangiblesM) / (B.q1DeploymentM + B.q1CashIntangiblesM) :
      (P.fy2025.cashPpeM + P.fy2025.intangiblesM) /
      (P.fy2025.cashPpeM + P.fy2025.intangiblesM + P.fy2025.noncashDebtPpeM + total(P.fy2025.noncashEquipmentLeaseM));
    eq(r.anchors.ttm.wcM, ttmWc, "TTM_operating_working_capital");
    eq(r.anchors.ttm.afterTaxLeaseAndInterestCashProfitM, ttmProfit, "TTM_cash_profit_after_all_service");
    eq(r.analystAssumptions.operatingMargin, opMargin, "cash_profit_margin");
    eq(r.analystAssumptions.wcCoefficient, wcCoefficient, "incremental_revenue_WC_coefficient");
    eq(r.analystAssumptions.cashFraction, cashFraction, "cash_noncash_budget_fraction");

    const observations = input.financialTrendEvidence.observations;
    const yoy = observations.map((o) => {
      check(o.currency === "MXN" && o.comparator.currency === "MXN" && o.unit === "million" &&
        o.comparator.unit === "million" && o.availableDate <= r.asOfDate && o.comparator.availableDate <= r.asOfDate,
      `growth_source_currency_date:${o.periodEndDate}`);
      const value = (o.revenueM / o.comparator.revenueM - 1) * 100;
      eq(o.valuePct, value, `growth_comparison:${o.periodEndDate}`);
      return clamp(value, -100, 1000);
    }).sort((a, b) => a - b);
    check(new Set(observations.map((o) => o.periodEndDate)).size === observations.length, "duplicate_growth_periods");
    const trimmed = yoy.slice(Math.floor(yoy.length * 0.15), Math.ceil(yoy.length * 0.85));
    const median = trimmed.length % 2 ? trimmed[Math.floor(trimmed.length / 2)] :
      (trimmed[trimmed.length / 2 - 1] + trimmed[trimmed.length / 2]) / 2;
    eq(input.financialTrendPct, median, "independent_growth_median");
    const weight = clamp((yoy.length - input.growthPolicySettings.minimumGrowthSampleCount + 1) / 4, .25, 1);
    const baseGrowth = 5 * (1 - weight) + median * weight;
    const guide = clamp(scenario.rawGuideGrowth * 100, baseGrowth - 15, baseGrowth + 15);
    const growth = clamp(baseGrowth * (1 - policy.guideWeight) + guide * policy.guideWeight,
      -20, input.growthPolicySettings.normalizedGrowthCapPct) / 100;
    check(policy.guideWeight <= .25 && scenario.rawGuideGrowth >= .29 && scenario.rawGuideGrowth <= .32,
      "management_guidance_range_and_weight");
    eq(r.guidanceAudit.appliedGrowth, growth, "bounded_growth");
    const revenue2026 = P.fy2025.revenueM * (1 + growth);
    const recurringRatio = (B.totalM - B.newStoresM - B.newDcsM) / revenue2026;
    const expansionRatio = (B.newStoresM + B.newDcsM) / (revenue2026 - P.fy2025.revenueM);
    const reserveRatio = P.balanceSheet.cashJune2026M / ttm.revenue;
    const principalRatio = ttm.otherDebtPrincipal / ttm.revenue;
    const mxnPerUsd = P.macro.ecbMxnPerEur / P.macro.ecbUsdPerEur;
    const parity = (1 + policy.inflationMxn) / (1 + policy.inflationUsd);
    const keUsd = P.macro.tenYearTreasury - P.macro.usDefaultSpread + policy.beta * P.macro.matureErp +
      P.macro.mexicoCrp + scenario.executionPremium;
    const keMxn = (1 + keUsd) * parity - 1;
    eq(input.fx.mxnPerUsd, mxnPerUsd, "ECB_cross");
    eq(r.analystAssumptions.keUsd, keUsd, "USD_Ke_components");
    eq(r.analystAssumptions.keMxn, keMxn, "nominal_currency_Ke_parity");
    const stub = dayCount(r.asOfDate, "2026-12-31") / 365;
    eq(r.stub.timeYears, stub, "ACT365_stub");

    function cash(prior, revenue, priorReserve) {
      const capital = revenue * recurringRatio + Math.max(0, revenue - prior) * expansionRatio;
      const reserve = revenue * reserveRatio;
      const fcfe = revenue * opMargin + (revenue - prior) * wcCoefficient - capital * cashFraction -
        revenue * principalRatio - (reserve - priorReserve);
      return { fcfe, capital, reserve };
    }
    const H = P.h12026;
    const h1Borrowing = H.netCreditLineCashM + H.supplierFinanceProceedsM - H.supplierFinanceRepaymentsM;
    const h1 = H.cfoM - H.cashPpeM + H.ppeDisposalsM - H.intangiblesM - H.leasePrincipalM -
      H.leaseInterestM - H.otherInterestM - H.otherDebtPrincipalM + h1Borrowing -
      (P.balanceSheet.cashJune2026M - P.balanceSheet.cashDecember2025M);
    const fy2026 = cash(P.fy2025.revenueM, revenue2026, P.balanceSheet.cashDecember2025M);
    const h2 = fy2026.fcfe + h1Borrowing - h1;
    eq(r.anchors.h1AfterDebtPrincipalAndReserveM, h1, "actual_H1_FCFE_and_reserve");
    eq(r.fy2026.companyFcfeM, fy2026.fcfe + h1Borrowing, "FY26_net_borrowing_once");
    eq(r.fy2026.capitalProgramM, B.totalM, "FY26_total_capital_budget");
    eq(r.stub.h2CompanyFcfeM, h2, "H2_not_full_year_or_remaining_stub_only");
    const cashPv = P.balanceSheet.usdBankDepositsM * keep / (1 + keUsd) ** stub * mxnPerUsd;
    const h2Pv = h2 * keep / (1 + keMxn) ** stub;
    eq(r.cashAsset.cashAssetPvMxnM, cashPv, "USD_deposits_once_and_first_award");
    eq(r.stub.h2CashPvMxnM, h2Pv, "H2_cash_present_value");
    let revenue = revenue2026;
    let reserve = fy2026.reserve;
    let explicitPv = 0;
    let lastFcfe;
    let funding = P.balanceSheet.usdBankDepositsM * mxnPerUsd * parity ** stub + h2;
    let minimumFunding = funding;
    eq(r.funding.schedule[0].retainedFundingBalanceM, funding, "funding_2026");
    check(r.forecast.length === 5, "five_forecast_years");
    for (let i = 0; i < 5; i++) {
      const row = r.forecast[i];
      const nextRevenue = revenue * (1 + growth + (policy.terminalRevenueGrowth - growth) * (i + 1) / 5);
      const next = cash(revenue, nextRevenue, reserve);
      const attributed = next.fcfe * keep ** (i + 2);
      const time = stub + i + 1;
      const pv = attributed / (1 + keMxn) ** time;
      check(row.fiscalYear === 2027 + i, `forecast_year:${i}`);
      for (const [key, value] of Object.entries({ revenueM: nextRevenue, companyFcfeM: next.fcfe,
        capitalProgramM: next.capital, cashCapitalExpenditureIncludingSoftwareM: next.capital * cashFraction,
        noncashEquipmentFinancingM: next.capital * (1 - cashFraction), endingOperatingCashReserveM: next.reserve,
        attributableFcfeM: attributed, ownershipRetention: keep ** (i + 2), pvMxnM: pv, timeYears: time,
        futureAwardCashExpenseM: 0, additionalIntangibleChargeM: 0, additionalLeaseServiceM: 0,
        extraSupplierFinanceDeductionM: 0, cashNetBorrowingM: 0 })) eq(row[key], value, `${row.fiscalYear}.${key}`);
      eq(row.equivalentUsdPvM, pv / mxnPerUsd, `currency_invariance:${row.fiscalYear}`);
      funding += next.fcfe; minimumFunding = Math.min(minimumFunding, funding);
      eq(r.funding.schedule[i + 1].retainedFundingBalanceM, funding, `funding_${row.fiscalYear}`);
      explicitPv += pv; lastFcfe = attributed; revenue = nextRevenue; reserve = next.reserve;
    }
    const gPerClaim = (1 + policy.terminalRevenueGrowth) * keep - 1;
    const terminalPv = lastFcfe * (1 + gPerClaim) / (keMxn - gPerClaim) / (1 + keMxn) ** (stub + 5);
    const operatingValue = h2Pv + explicitPv + terminalPv;
    const equity = operatingValue + cashPv;
    const terminalShare = terminalPv / operatingValue;
    const deficit = Math.max(0, -minimumFunding);
    const mechanicalPrice = equity / mxnPerUsd / (claims / 1e6);
    eq(r.terminal.perCurrentClaimGrowth, gPerClaim, "terminal_continued_dilution");
    eq(r.terminal.terminalPvMxnM, terminalPv, "Gordon_2032_cash_discount_2031");
    eq(r.terminal.terminalValueShare, terminalShare, "terminal_share");
    eq(r.value.explicitPvMxnM, explicitPv, "explicit_PV");
    eq(r.value.equityValueMxnM, equity, "FCFE_no_extra_debt_or_lease_deduction");
    eq(r.funding.fundingDeficitM, deficit, "retained_funding_deficit");
    const ready = deficit === 0 && terminalShare > 0 && terminalShare <= .8 && equity > 0 &&
      gPerClaim >= .01 && gPerClaim <= .04 && keMxn >= .085 && keMxn <= .18 && keMxn - gPerClaim >= .045;
    check(r.methodReady === ready, "independent_method_readiness");
    if (ready) eq(r.value.fairValueUsd, mechanicalPrice, "USD_value_per_maximum_claim");
    else { check(r.value.fairValueUsd === null, "failed_stress_must_not_publish_target");
      eq(r.value.conditionalMechanicalValueUsd, mechanicalPrice, "quarantined_stress_mechanics"); }
    return { status: failures.length ? "fail" : "pass", failures,
      scope: "independent_current_only_arithmetic_and_accounting_convention_audit_not_release_approval",
      recomputed: { economicCashM: economicCash, claims, growth, keUsd, keMxn, mxnPerUsd,
        equityMxnM: equity, methodReady: ready, fairValueUsd: ready ? mechanicalPrice : null,
        mechanicalPriceWhenNotPublishable: ready ? null : mechanicalPrice, terminalShare, fundingDeficitM: deficit } };
  } catch (error) { return { status: "fail", failures: [...failures, `missing_or_malformed_audit_inputs:${error.message}`] }; }
}
