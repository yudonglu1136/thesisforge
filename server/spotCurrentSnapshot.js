import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { buildGuruCurrentEconomicValuation } from "./guruCurrentEconomicValuation.js";
import { auditGuruCurrentEconomicValuation } from "./guruCurrentEconomicValuationAudit.js";
import { auditSpotCurrentSource } from "./spotCurrentSourceAudit.js";
import { resolveValuationComparisonPrice } from "./valuationComparisonPrice.js";

const hash = (raw) => createHash("sha256").update(raw).digest("hex");
export const SPOT_CURRENT_MODEL_FILES = ["server/guruCurrentEconomicValuation.js", "server/guruCurrentEconomicValuationAudit.js",
  "server/spotCurrentSourceAudit.js", "server/spotCurrentSnapshot.js", "server/config/guru-current-economic-evidence.json"];
export function spotCurrentModelSignature() {
  return hash(JSON.stringify(SPOT_CURRENT_MODEL_FILES.map((path) => ({ path, sha256: hash(readFileSync(new URL(`../${path}`, import.meta.url))) }))));
}
const blocked = (reason, details) => ({ status: "blocked", releaseReady: false, reason, details });

/** Pure dated normal-snapshot adapter. No DB, network, generic-history approval
 * or production publication. Trust digests come from independent release review.
 */
export function buildSpotCurrentSnapshot({ inputJson, sourceBundleJson, trust, readSource = readFileSync } = {}) {
  try {
    if (!trust || hash(inputJson) !== trust.inputSha256 || spotCurrentModelSignature() !== trust.modelSignature) return blocked("reviewed_input_or_model_digest_mismatch");
    const saved = JSON.parse(inputJson);
    if (saved.asOfDate !== "2026-09-05" || saved.historicalApproval !== false || saved.input?.ticker !== "SPOT") return blocked("wrong_current_scope");
    const sourceAudit = auditSpotCurrentSource({ bundleJson: sourceBundleJson, expectedBundleSha256: trust.sourceBundleSha256, read: readSource });
    if (sourceAudit.status !== "pass") return blocked("independent_original_source_audit_failed", sourceAudit);
    // Never pass the comparison quote into either model calculation.
    const model = buildGuruCurrentEconomicValuation(saved.input);
    const modelAudit = auditGuruCurrentEconomicValuation(model);
    if (!modelAudit.ok) return blocked("independent_current_model_audit_failed", { model, modelAudit });
    const q = saved.quote, raw = q?.originalRecord, meta = q?.quotedSecurityMetadata;
    if (!raw || raw.ticker !== "SPOT" || raw.date !== "2026-09-04" || q.source !== "sharadar-paid-api-split-adjusted" ||
      q.priceSymbol !== "SPOT" || q.quoteCurrency !== "USD" || q.comparisonOnly !== true ||
      meta?.table !== "SEP" || meta.ticker !== "SPOT" || meta.currency !== "USD" || !/(?:^| )L8681T102(?: |$)/.test(meta.cusips || "") ||
      String(meta.permaticker) !== "120226" || meta.exchange !== "NYSE" ||
      !/CIK=0*1639920$/.test(meta.secfilings || "") || !/^\d{4}-\d{2}-\d{2}$/.test(meta.lastupdated || "") ||
      !/^\d{4}-\d{2}-\d{2}$/.test(meta.firstpricedate || "") ||
      meta.lastupdated > "2026-09-05" || meta.firstpricedate > raw.date) return blocked("original_paid_quote_identity_currency_or_date_mismatch");
    const quoteAudit = resolveValuationComparisonPrice({ asOfDate: "2026-09-05", priceDate: raw.date, priceSymbol: "SPOT", quoteCurrency: "USD",
      declaredSource: q.source, candidates: [{ id: "spot-paid-original-20260904", kind: "original_vendor", date: raw.date, priceSymbol: "SPOT",
        quoteCurrency: "USD", close: raw.close, source: q.source, sourceField: "close", unit: "currency_per_share", originalRecord: raw }] });
    if (quoteAudit.status !== "ready") return blocked("exact_paid_comparison_failed", quoteAudit);
    const price = quoteAudit.expectedPrice, fair = model.fairValue;
    const details = { currentOnly: true, historicalCurveAuthorized: false, financialDate: model.periodEndDate,
      sourceBundleSha256: trust.sourceBundleSha256, inputSha256: trust.inputSha256, fullModelSignature: trust.modelSignature,
      economics: structuredClone(model.economics), guidanceAudit: sourceAudit.guidanceReview,
      analystAssumptions: model.assumptionRationale };
    const row = { id: "spot-current-2026-09-05", asOfDate: "2026-09-05", fiscalPeriod: "2026-Q2", fiscalYear: 2026, fiscalQuarter: "Q2",
      periodEndDate: "2026-06-30", financialAvailableAt: "2026-08-04", fairValue: fair, currency: "USD",
      priceAtDate: price, priceDate: raw.date, upsideDownside: fair / price - 1, targetPrice3Y: null, expectedReturn3Y: null,
      sourceType: "spot_current_parent_economic_fcfe", method: "Current-only parent-economic FCFE / Cost of Equity",
      dataSnapshot: { ...details, trailingTwelveMonths: structuredClone(saved.input.financial),
        valuationSemantics: { currentOnly: true, historicalCurveAuthorized: false, discountRateType: "cost_of_equity",
          cashFlowConvention: "parent_FCFE_after_lease_principal_and_cash_equivalent_SBC", priceExcludedFromFairValue: true,
          expectedPriceRole: "comparison_only", modelInputPolicy: "dated_paid_PIT_plus_official_source_bridge_and_explicit_analyst_scenarios" },
        comparisonPriceSource: { source: q.source, priceSymbol: "SPOT", priceDate: raw.date, close: price, quoteCurrency: "USD",
          payload: { originalRecord: structuredClone(raw), quotedSecurityMetadata: structuredClone(meta), inputSha256: trust.inputSha256 } },
        reviewedCurrentScenario: { ...details, scenarios: structuredClone(model.scenarios) } } };
    const warningPairs = [
      ["Current-only model dated September 5, 2026, using financials through June 30 and the September 4 comparison quote. One valuation point; no approved historical curve.", "仅为2026年9月5日的当前模型，财务截至6月30日、比较股价截至9月4日。只有一个估值点，未批准历史曲线。"],
      ["Recurring SBC and lease principal are deducted once. The EUR 9m capex difference is a conservative analyst reconciliation reserve, not verified extra spending.", "经常性SBC与租赁本金各扣除一次；900万欧元资本开支差额是分析师保守核对准备，不是已确认的额外支出。"],
      ["Five-year FCFE growth, discount rate and terminal growth are analyst assumptions. Official Q3 revenue and operating-income guidance are disclosed separately and are not mislabeled as annual FCFE guidance.", "五年FCFE增长、折现率及永续增长率是分析师假设；官方Q3收入及营业利润指引单独披露，不冒充全年FCFE指引。"],
      ["Shares include a conservative full-share claim for exercisable options without exercise proceeds. Scenario ranges are not statistical confidence intervals or promised returns.", "股数包括可行权期权全部兑现的保守索偿，不计行权收入；情景范围不是统计置信区间或收益承诺。"],
    ];
    const snapshot = { ticker: "SPOT", key: "SPOT", cik: "1639920", name: "Spotify Technology S.A.", currency: "USD",
      sector: "Communication Services", industry: "Music and audio streaming", modelType: "Current-only parent-economic FCFE DCF",
      valuationProfile: "issuer_specific_current_only", generatedAt: "2026-09-06T00:00:00.000Z",
      latest: { latestPrice: price, latestPriceDate: raw.date, latestPriceSource: q.source, baseFairValue: fair,
        valuationAnchorDate: "2026-09-05", valuationAnchorPrice: price, upsideToBase: fair / price - 1,
        targetPrice3Y: null, expectedReturn3Y: null, fairValueSource: "Source-reviewed current-only parent-economic FCFE",
        fairValueInputPolicy: "Paid PIT and official-source cash/claims bridge; explicit analyst assumptions; quote comparison only" },
      history: [row], priceHistory: [{ date: raw.date, close: price, source: q.source }], currentScenarioDetails: details,
      scenarios: model.scenarios.map((s) => ({ scenario: s.name, scenarioId: s.name, fairValue: s.fairValue, currentPrice: price,
        upsideDownside: s.fairValue / price - 1, targetPrice3Y: null, expectedReturn3Y: null, statisticalConfidenceInterval: false,
        status: "conditional_scenario", details: structuredClone(s) })),
      warnings: warningPairs.map(([en]) => en), warningTranslations: warningPairs.map(([en, zh]) => ({ en, zh })),
      methodCards: [{ key: "spot-current-fcfe", label: "Current-only parent-economic FCFE", value: fair, format: "currency",
        description: "EUR FCFE discounted with EUR cost of equity, translated once into USD per current claim." }],
      dataQuality: { valuationStatus: "current_scenario_candidate", currentOnly: true, historicalCurveAuthorized: false, valuationCoverageKind: "current_only",
        hasQuarterlyValuationRuns: false, pitValuationRows: 1, pricePoints: 1, hasLivePriceSeries: false, priceDisplayMode: "as-of-price-anchors",
        financialCurrency: "EUR", quoteCurrency: "USD", releaseReady: false, sourceAudit, independentScenarioAudit: modelAudit,
        modelInputAudit: { status: "current_scope_source_and_arithmetic_verified_release_pending", passesNoPriceAnchorAudit: true,
          priceUsage: "comparison-only", historicalCurveAuthorized: false } } };
    return { status: "current_only_snapshot_candidate", sourceAndArithmeticReady: true, releaseReady: false, snapshot, valuationRows: [row],
      modelRuns: [{ ticker: "SPOT", fiscalPeriod: "2026-Q2", asOfDate: "2026-09-05", financialAvailableAt: "2026-08-04",
        guidanceMaxObservedAt: "2026-08-04", modelVersion: model.modelVersion, input: structuredClone(saved.input), output: row,
        priceObservation: row.dataSnapshot.comparisonPriceSource }], audit: { sourceAudit, modelAudit, quoteAudit },
      releaseBoundary: "Requires full additive release checks, bilingual research enrichment and normal production verification; no historical approval." };
  } catch (error) { return blocked("invalid_current_inputs", error.message); }
}
