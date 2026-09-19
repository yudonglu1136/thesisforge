// Reproducible model-readiness experiment. These are explicitly unapproved
// analyst sensitivities, not platform fair values or investment recommendations.
import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { calculateTbbbValuationCandidate } from "../server/tbbbValuationCandidate.js";
import { normalizedRevenueGrowthForRows } from "../server/importSecQuarterlyValuations.js";

const [database, fxFile, output] = process.argv.slice(2);
if (!database || !fxFile || !output) throw new Error("Usage: node scripts/evaluate-tbbb-staged-scenarios.mjs <source.sqlite> <ecb-fx.json> <output.json>");
const asOfDate = "2026-09-05";
const db = new DatabaseSync(path.resolve(database), { readOnly: true });
let raw, guidance;
try {
  raw = db.prepare("SELECT * FROM pit_raw_financial_review WHERE ticker=? AND available_at<=? ORDER BY fiscal_period,dimension")
    .all("TBBB", asOfDate).map((row) => ({ ...row, raw: JSON.parse(row.payload_json) }));
  guidance = db.prepare("SELECT * FROM pit_guidance_events WHERE ticker=? AND metric_name=? AND observed_at=? AND quality_status='clear'")
    .all("TBBB", "revenue_guidance", "2026-03-11");
} finally { db.close(); }
if (!guidance.length || guidance.some((row) => row.growth_yoy !== 30.5 || row.amount != null || JSON.parse(row.payload_json).guidance_target_year !== 2026)) {
  throw new Error("Actual candidate must contain the verified percentage-only FY2026 issuer guide");
}
const quarters = raw.filter((row) => row.dimension === "ARQ");
const latest8 = quarters.slice(-8);
function observation(row) {
  return { periodEndDate: row.raw.reportperiod, availableDate: row.available_at,
    revenueM: row.raw.revenue / 1e6, scope: "company_total", currency: "MXN", unit: "million",
    sourceDimension: "ARQ", sourceRecord: { ticker: "TBBB", datekey: row.available_at,
      periodEndDate: row.raw.reportperiod, dataset: "Jansen Sharadar SF1 earliest ARQ", sourceFiscalPeriod: row.fiscal_period } };
}
const omittedGrowthSlots = [];
const observations = latest8.flatMap((row) => {
  const priorEnd = `${Number(row.raw.reportperiod.slice(0, 4)) - 1}${row.raw.reportperiod.slice(4)}`;
  const comparator = quarters.find((candidate) => candidate.raw.reportperiod === priorEnd);
  if (!Number.isFinite(row.raw.revenue) || !(row.raw.revenue > 0) ||
      !comparator || !Number.isFinite(comparator.raw.revenue) || !(comparator.raw.revenue > 0)) {
    omittedGrowthSlots.push({ fiscalPeriod: row.fiscal_period,
      reason: "missing_positive_like_for_like_revenue_in_latest_eight_period_window" });
    return [];
  }
  return [{ ...observation(row), valuePct: (row.raw.revenue / comparator.raw.revenue - 1) * 100,
    comparator: observation(comparator) }];
});
const financialTrendPct = normalizedRevenueGrowthForRows(observations.map((row) => ({ revenue_growth_pct: row.valuePct })), observations.length - 1, 8);
const art = raw.find((row) => row.dimension === "ART" && row.fiscal_period === "2026-Q2");
if (!art) throw new Error("Missing actual TBBB TTM input");
const rates = JSON.parse(fs.readFileSync(fxFile, "utf8")).rates;
const usd = rates.find((row) => row.currency === "USD" && row.rate_date === "2026-09-04");
const mxn = rates.find((row) => row.currency === "MXN" && row.rate_date === "2026-09-04");
if (!usd || !mxn) throw new Error("Missing dated official FX pair; no default rate is permitted");
const economicInput = { asOfDate, periodEndDate: "2026-06-30", sourceCurrency: "MXN",
  sourceRevenue: art.raw.revenue / 1e6, sourceCfo: art.raw.ncfo / 1e6,
  sourceCapex: -art.raw.capex / 1e6,
  rawSourceRecord: { ticker: "TBBB", datekey: art.available_at, reportperiod: art.raw.reportperiod,
    dimension: "ART", source: "Jansen Sharadar SF1 earliest PIT row" } };
const referenceMargin = 577.455 / (art.raw.revenue / 1e6);
const common = {
  economicInput, assumptionDate: asOfDate, fy2026RevenueGrowth: 0.305,
  guidanceApplicationPolicy: "pit_trend_bounded_blend", financialTrendPct, guidanceWeight: 0.25,
  growthPolicySettings: { normalizedGrowthCapPct: 45, minimumGrowthSampleCount: 4, fundamentalGrowthPriorPct: 5 },
  financialTrendEvidence: { asOfDate, unit: "percent", valuePct: financialTrendPct,
    method: "normalizedRevenueGrowthForRows", windowSize: 8,
    selection: "latest_up_to_8_complete_observations_in_latest_8_period_window", observations },
  timingPolicy: "act_365_fiscal_year_end", marginPolicy: "explicit_margins",
  existingAwardPolicy: "all_current_awards_vest_no_duplicate_sbc_expense",
  futureGrantPolicy: "cash_equivalent_cost_in_lieu_of_dilution",
  equityAdjustment: { amountM: 0, rationale: "No incremental excess-cash asset or second debt/NCI deduction; purely a conditional FCFE experiment." },
  fx: { baseCurrency: "USD", quoteCurrency: "MXN", mxnPerUsd: mxn.units_per_eur / usd.units_per_eur,
    rateDate: mxn.rate_date, availableDate: mxn.rate_date, sourceUrl: mxn.source_url,
    derivation: "ECB MXN per EUR / USD per EUR, 2026-09-04. Constant future FX is an analyst scenario assumption." },
};
const definitions = [
  { id: "observed-margin-mechanical", margins: Array(5).fill(referenceMargin), ke: 0.14, g: 0.02, grantMargin: 0.002, reserve: 25 },
  { id: "margin-normalization-hypothesis", margins: [0.008, 0.010, 0.012, 0.013, 0.014], ke: 0.12, g: 0.03, grantMargin: 0.002, reserve: 25 },
  { id: "higher-future-award-cost-stress", margins: Array(5).fill(referenceMargin), ke: 0.14, g: 0.02, grantMargin: 0.005, reserve: 25 },
];
const inputs = definitions.map((definition) => ({
  ...common, scenarioId: definition.id,
  rationale: "Unapproved analyst sensitivity to margin, future grants and discounting. Not management guidance, not a justified fair-value range.",
  costOfEquity: definition.ke, terminalGrowth: definition.g,
  optionPolicy: { mode: "grouped_intrinsic_plus_explicit_reserve", timeValueReserveUsdM: definition.reserve,
    rationale: "USD25m is an explicit sensitivity reserve only, not a priced or audited option-time-value estimate." },
  stub: { periodStartExclusive: asOfDate, paymentDate: "2026-12-31",
    economicCashFlowM: 577.455 * 117 / 365, additionalReinvestmentM: 0, netBorrowingM: 0,
    futureGrantCostM: art.raw.revenue / 1e6 * 117 / 365 * definition.grantMargin,
    rationale: "Mechanical 117-day pro rata of trailing cash and grant-cost assumption, not an issuer remaining-year cash forecast." },
  forecast: [0.20, 0.15, 0.12, 0.10, 0.08].map((revenueGrowth, index) => ({
    fiscalYear: 2027 + index, revenueGrowth, economicCashFlowMargin: definition.margins[index],
    additionalReinvestmentMargin: 0, netBorrowingM: 0, futureGrantCostMargin: definition.grantMargin,
  })),
  terminal: { economicCashFlowMargin: definition.margins.at(-1), additionalReinvestmentMargin: 0,
    netBorrowingMargin: 0, futureGrantCostMargin: definition.grantMargin,
    rationale: "Constant terminal cash margin and nominal FX. Neither reinvestment sufficiency nor future award cost has been established." },
}));
const scenarios = inputs.map((input) => ({ input, result: calculateTbbbValuationCandidate(input) }));
const result = { status: "unapproved_scenario_experiment_not_a_platform_valuation", releaseReady: false,
  asOfDate, financialTrendPct, omittedGrowthSlots, guidanceSourceIds: guidance.map((row) => row.id),
  economicAssumptionsReviewed: false, newValuationsPublished: 0, scenarios };
fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
fs.writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
console.log(JSON.stringify({ status: result.status, financialTrendPct,
  scenarios: scenarios.map(({ input, result }) => ({ scenarioId: input.scenarioId,
    status: result.status, reason: result.reason, perShareUsd: result.perShareUsd,
    releaseReady: result.releaseReady, growthPolicy: result.guidanceUse?.growthPolicyAudit })) }, null, 2));
if (scenarios.some(({ result }) => result.status !== "candidate")) process.exitCode = 2;
