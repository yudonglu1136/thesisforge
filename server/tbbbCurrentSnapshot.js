import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { calculateTbbbUnderwrittenValuation } from "./tbbbUnderwrittenValuation.js";
import { auditTbbbSourceBindings, auditTbbbReviewedSourceFacts, auditTbbbUnderwrittenValuation } from "./tbbbUnderwrittenValuationAudit.js";
import { resolveValuationComparisonPrice, valuationComparisonPriceContract } from "./valuationComparisonPrice.js";

const root = new URL("../", import.meta.url);
const digest = (raw) => createHash("sha256").update(raw).digest("hex");
const clone = (value) => structuredClone(value);
const configNames = ["server/config/tbbb-economic-evidence.json", "server/config/tbbb-underwriting-2026-09-05.json"];
export const TBBB_CURRENT_MODEL_FILES = ["server/tbbbEconomicInputs.js", "server/tbbbValuationCandidate.js",
  "server/tbbbUnderwrittenValuation.js", "server/tbbbUnderwrittenValuationAudit.js", ...configNames];
const blocked = (reason, details) => ({ status: "blocked", releaseReady: false, reason, details });

function verifiedQuotedSecurityMetadata(evidence, priceDate) {
  const raw = evidence?.originalRecord;
  const dated = (date) => typeof date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(date)
    && new Date(date).toISOString().slice(0, 10) === date;
  return evidence?.source === "jansen-sharadar-tickers" && raw
    && evidence.originalRecordSha256 === digest(JSON.stringify(raw))
    && raw.table === "SEP" && raw.ticker === "TBBB" && raw.currency === "USD"
    && String(raw.permaticker) === "641173" && raw.cusips === "G0896C103"
    && raw.exchange === "NYSE"
    && /^https:\/\/www\.sec\.gov\/cgi-bin\/browse-edgar\?action=getcompany&CIK=0*1978954$/.test(raw.secfilings || "")
    && dated(raw.lastupdated) && raw.lastupdated <= "2026-09-05"
    && dated(raw.firstpricedate) && raw.firstpricedate <= priceDate;
}

/** Pure renderer/candidate adapter. Never opens a DB, publishes or changes the
 * default universe. Trust digests must come from the separately reviewed record,
 * not be calculated from untrusted request parameters by an API caller.
 */
export function buildTbbbCurrentSnapshotCandidate({ input: supplied, sourceBundleJson, sourceReviewJson,
  trust, comparisonPrice = null, readSource = readFileSync } = {}) {
  try {
    const input = Object.fromEntries(["economicInput", "financialTrendPct", "financialTrendEvidence", "growthPolicySettings", "fx"]
      .map((key) => [key, clone(supplied?.[key])]));
    if (!trust || trust.inputSha256 !== digest(JSON.stringify(input)) ||
      trust.sourceBundleSha256 !== digest(sourceBundleJson) || trust.sourceReviewSha256 !== digest(sourceReviewJson)) {
      return blocked("reviewed_input_or_source_digest_mismatch");
    }
    const modelBindings = TBBB_CURRENT_MODEL_FILES.map((path) => ({ path, sha256: digest(readFileSync(new URL(path, root))) }));
    if (trust.fullModelSignature !== digest(JSON.stringify(modelBindings))) return blocked("model_code_differs_from_independent_review");
    const binding = JSON.parse(sourceBundleJson), sourceReview = JSON.parse(sourceReviewJson);
    if (sourceReview.bindingSha256 !== trust.sourceBundleSha256) return blocked("source_fact_review_wrong_bundle");
    const configs = configNames.map((name) => {
      const path = fileURLToPath(new URL(name, root)), raw = readFileSync(path);
      if (!binding.configBindings.some((c) => c.path === path && c.sha256 === digest(raw))) throw new Error("unbound_model_config");
      return JSON.parse(raw);
    });
    const [economicEvidence, underwriting] = configs;
    const sourceAudit = auditTbbbSourceBindings(binding, { read: readSource });
    const factAudit = auditTbbbReviewedSourceFacts(sourceReview, binding, economicEvidence, { read: readSource, input });
    if (sourceAudit.status !== "pass" || factAudit.status !== "pass") return blocked("independent_source_audit_failed", { sourceAudit, factAudit });
    // The comparison quote is intentionally not passed into any model or audit.
    const calculations = ["base", "downside", "upside"].map((scenarioId) => calculateTbbbUnderwrittenValuation({ ...input, scenarioId }));
    const audits = calculations.map((result) => auditTbbbUnderwrittenValuation({ input: { ...input, scenarioId: result.scenarioId },
      result, economicEvidence, underwriting }));
    if (audits.some((a) => a.status !== "pass") || !calculations[0].methodReady || !calculations[2].methodReady) {
      return blocked("independent_current_model_audit_failed", audits);
    }
    let quote = null;
    let comparisonAudit = null;
    if (comparisonPrice !== null) {
      const p = comparisonPrice;
      if (trust.comparisonPriceSha256 !== digest(JSON.stringify(p))) return blocked("comparison_evidence_not_bound_to_reviewed_digest");
      if (p.priceSymbol !== "TBBB" || p.quoteCurrency !== "USD" ||
        valuationComparisonPriceContract(p.declaredSource)?.provider !== "sharadar") return blocked("paid_comparison_source_or_security_mismatch");
      comparisonAudit = resolveValuationComparisonPrice({ ...p, asOfDate: "2026-09-05",
        ticker: "TBBB", fiscalPeriod: "2026-Q2", modelVersion: underwriting.version });
      if (comparisonAudit.status !== "ready" || comparisonAudit.selectedEvidenceKind !== "original_vendor") {
        return blocked("exact_paid_comparison_resolution_failed", comparisonAudit);
      }
      // Fixed registered source field = close, not self-reported rawClose or an
      // arbitrary provider label. Caller separately pins the entire request SHA.
      const originals = comparisonAudit.evidence.filter((e) => e.kind === "original_vendor");
      for (const evidence of originals) {
        const raw = evidence.originalRecord;
        // The actual paid daily-price endpoint has no currency field. Keep
        // its raw record unchanged; bind quote currency to the original SEP
        // security metadata, never SF1's MXN reporting currency.
        const currencyVerified = raw?.currency === "USD" || (raw?.currency == null
          && verifiedQuotedSecurityMetadata(p.quotedSecurityMetadata, p.priceDate));
        if (!raw || raw.ticker !== "TBBB" || raw.date !== p.priceDate || !currencyVerified ||
          raw.close !== evidence.close || evidence.originalRecordSha256 !== digest(JSON.stringify(raw))) {
          return blocked("original_paid_record_close_date_currency_not_reconciled");
        }
      }
      quote = { priceSymbol: "TBBB", priceDate: p.priceDate, close: comparisonAudit.expectedPrice,
        quoteCurrency: "USD", source: p.declaredSource,
        payload: { priceEvidenceSha256: trust.comparisonPriceSha256, contractVersion: comparisonAudit.contractVersion,
          sourceContract: clone(comparisonAudit.sourceContract), originalVendorEvidence: clone(originals),
          quotedSecurityMetadata: clone(p.quotedSecurityMetadata ?? null) } };
    }
    const [base, downside, upside] = calculations;
    const fair = base.value.fairValueUsd;
    const warningPairs = [
      ["Current-only scenario as of September 5, 2026. One valuation point; historical valuations are not approved.", "仅为2026年9月5日的当前情景；只有一个估值点，未批准历史估值曲线。"],
      ["All share classes, conditional awards and options are counted at a conservative full-share upper claim, with no exercise proceeds. This is not exact option fair value or a guaranteed price floor.", "各类股份、条件奖励及期权采用全部兑现的保守股权索偿上限，不计行权收入；并非期权精确公允价值或保证底价。"],
      ["Lease principal and interest are already deducted. Existing and future awards are charged through ownership dilution once, not deducted again as cash SBC.", "租赁本金及利息已扣除；现有与未来奖励通过股权稀释计算一次，不再重复扣除现金SBC。"],
      ["The downside path requires MXN 3,825.03m of additional funding; no downside target is displayed. Scenarios are not statistical confidence bounds.", "下行情景需额外融资约38.25亿墨西哥比索，因此不显示下行目标价；情景不是统计置信区间。"],
      ["FY2026 revenue guidance was issued in March; its weighted use is not a claim of Q2 reaffirmation. Investment financing, working-capital scalability and future awards remain explicit analyst assumptions.", "2026年收入指引发布于3月，加权采用不代表Q2再次确认；投资融资、营运资本可持续性与未来奖励均为明确的分析师假设。"]
    ];
    const sourceType = "tbbb_current_underwritten_fcfe_scenario";
    const details = { cashFlowBridge: clone(base.economicCashBridge), shareClaims: clone(base.anchors.shareClaims),
      guidanceAudit: clone(base.guidanceAudit), analystAssumptions: clone(base.analystAssumptions),
      fx: clone(base.fx), sourceBundleSha256: trust.sourceBundleSha256, sourceReviewSha256: trust.sourceReviewSha256,
      inputSha256: trust.inputSha256, fullModelSignature: trust.fullModelSignature,
      financialDate: "2026-06-30", currentOnly: true, historicalCurveAuthorized: false };
    const row = {
      id: "tbbb-current-2026-09-05", asOfDate: "2026-09-05", financialAvailableAt: "2026-08-12",
      fiscalYear: 2026, fiscalQuarter: "Q2", fiscalPeriod: "2026-Q2", periodEndDate: "2026-06-30",
      fairValue: fair, currency: "USD", sourceType,
      priceAtDate: quote?.close ?? null, priceDate: quote?.priceDate ?? null,
      // Normal terminal snapshot contract stores ratios (0.10 means 10%),
      // matching buildValuationRows/updateTickerSnapshot and Flutter formatters.
      upsideDownside: quote ? fair / quote.close - 1 : null,
      targetPrice3Y: null, expectedReturn3Y: null,
      method: "Current-only conservative full-share-claim FCFE",
      dataSnapshot: { sourceType, ...details,
        trailingTwelveMonths: { revenue_m: input.economicInput.sourceRevenue, cfo_m: input.economicInput.sourceCfo,
          capex_m: input.economicInput.sourceCapex, currency: "MXN", unit: "million",
          fcf_after_capex_m: input.economicInput.sourceCfo - input.economicInput.sourceCapex,
          economic_cash_bridge_m: base.economicCashBridge.economicCashFlowM,
          note: "Raw TTM CFO-minus-PPE is not normalized FCFE; separate economic bridge includes leases, interest and software." },
        valuationSemantics: { sourceType, currentOnly: true, historicalCurveAuthorized: false,
          priceExcludedFromFairValue: true, cashFlowConvention: "parent_common_FCFE_after_all_lease_service",
          discountRateType: "cost_of_equity", fairValueFormula: "PV of MXN FCFE plus separate USD deposits, divided by maximum current claims; future dilution once",
          expectedPriceRole: "comparison_only", modelInputPolicy: "source_reviewed_current_inputs_plus_explicit_analyst_scenarios" },
        financialSource: { record: clone(input.economicInput.rawSourceRecord), sourceBundleSha256: trust.sourceBundleSha256 },
        comparisonPriceSource: quote,
        reviewedCurrentScenario: { ...details, forecast: clone(base.forecast), terminal: clone(base.terminal), funding: clone(base.funding) }
      }
    };
    const scenarios = calculations.map((r) => ({ scenario: r.scenario.label, scenarioId: r.scenarioId,
      fairValue: r.value.fairValueUsd, currentPrice: quote?.close ?? null,
      upsideDownside: quote && r.value.fairValueUsd !== null ? r.value.fairValueUsd / quote.close - 1 : null,
      targetPrice3Y: null, expectedReturn3Y: null, status: r.methodReady ? "conditional_scenario" : "funding_gap_no_target",
      statisticalConfidenceInterval: false, fundingDeficitMxnM: r.funding.fundingDeficitM,
      details: clone(r) }));
    const snapshot = {
      ticker: "TBBB", key: "TBBB", cik: "1978954", name: "BBB Foods Inc.", currency: "USD",
      sector: "Consumer Staples", industry: "Grocery retail", modelType: "Current-only underwritten FCFE scenario",
      generatedAt: "2026-09-06T00:00:00.000Z", valuationProfile: "issuer_specific_current_only",
      latest: { latestPrice: quote?.close ?? null, latestPriceDate: quote?.priceDate ?? null,
        latestPriceSource: quote?.source ?? null, baseFairValue: fair,
        valuationAnchorDate: "2026-09-05", valuationAnchorPrice: quote?.close ?? null,
        fairValueSource: "Source-reviewed TBBB current-only conservative scenario",
        fairValueInputPolicy: "dated reported financials and explicit analyst assumptions; quote comparison only",
        upsideToBase: quote ? fair / quote.close - 1 : null, targetPrice3Y: null, expectedReturn3Y: null },
      history: [row], priceHistory: quote ? [{ date: quote.priceDate, close: quote.close, source: quote.source }] : [],
      scenarios, currentScenarioDetails: details,
      warnings: warningPairs.map(([en]) => en), warningTranslations: warningPairs.map(([en, zh]) => ({ en, zh })),
      methodCards: [{ key: "tbbb-current-scenario", label: "Current-only FCFE scenario", value: fair, format: "currency",
        description: "Conservative full-share claims; explicit cash investment and financing assumptions; not an approved historical curve." },
      { key: "tbbb-current-coverage", label: "Historical valuation coverage", value: 1, format: "number",
        description: "One independently checked current snapshot; forecast years are not historical chart points." }],
      dataQuality: { valuationStatus: "current_scenario_candidate", currentOnly: true, historicalCurveAuthorized: false,
        valuationCoverageKind: "current_only", hasQuarterlyValuationRuns: false, pitValuationRows: 1,
        pricePoints: quote ? 1 : 0, hasLivePriceSeries: false, priceDisplayMode: "as-of-price-anchors",
        financialCurrency: "MXN", quoteCurrency: "USD", releaseReady: false,
        sourceAudit, sourceFactAudit: factAudit, independentScenarioAudits: audits,
        modelInputAudit: { status: "current_scope_arithmetic_verified_release_pending", passesNoPriceAnchorAudit: true,
          priceUsage: "comparison-only", historicalCurveAuthorized: false },
        fullModelSignature: trust.fullModelSignature, sourceBundleSha256: trust.sourceBundleSha256 }
    };
    return { status: "current_only_snapshot_candidate", releaseReady: false, snapshot,
      valuationRows: [row], modelRuns: [{ ticker: "TBBB", fiscalPeriod: "2026-Q2", asOfDate: "2026-09-05",
        financialAvailableAt: "2026-08-12", guidanceMaxObservedAt: "2026-03-11", input: clone(input), output: row,
      priceObservation: quote }], audit: { sourceAudit, factAudit, scenarios: audits, comparisonPrice: comparisonAudit },
      releaseBoundary: "No default universe, DB/API write, historical approval or production authorization is issued by this adapter." };
  } catch (error) { return blocked("invalid_current_snapshot_inputs", error.message); }
}
