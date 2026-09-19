import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve, dirname } from "node:path";
import { calculateTbbbUnderwrittenValuation } from "../server/tbbbUnderwrittenValuation.js";
import { auditTbbbSourceBindings, auditTbbbUnderwrittenValuation, auditTbbbReviewedSourceFacts } from "../server/tbbbUnderwrittenValuationAudit.js";

// Pure saved-JSON replay. No database/client/network import or publication path.
const args = process.argv.slice(2);
const values = {};
for (let i = 0; i < args.length; i += 2) {
  if (!["--input", "--output", "--bindings", "--source-review"].includes(args[i]) || !args[i + 1] || args[i + 1].startsWith("--")) {
    throw new Error("Usage: --input saved.json --output NEW.json [--bindings binding.json --source-review facts.json]");
  }
  if (values[args[i]]) throw new Error("Duplicate argument");
  values[args[i]] = args[i + 1];
}
const sourcePath = resolve(values["--input"] || "output/guru-valuation-expansion-2026-09-05/tbbb-unapproved-scenarios.json");
const outputPath = resolve(values["--output"] || "output/guru-valuation-expansion-2026-09-05/tbbb-underwritten-scenarios.json");
if (existsSync(outputPath)) throw new Error("Immutable output exists; choose a new --output path");
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const source = JSON.parse(readFileSync(sourcePath, "utf8"));
const first = source.scenarios?.[0]?.input;
if (!first) throw new Error("Missing saved PIT input; no fabricated fallback");
const input = {
  economicInput: first.economicInput,
  financialTrendPct: first.financialTrendPct,
  financialTrendEvidence: first.financialTrendEvidence,
  growthPolicySettings: first.growthPolicySettings,
  fx: first.fx
};
const scenarios = ["base", "downside", "upside"].map((scenarioId) =>
  calculateTbbbUnderwrittenValuation({ ...input, scenarioId }));
if (scenarios.some((scenario) => scenario.status === "blocked")) throw new Error(JSON.stringify(scenarios));
const modelPaths = ["server/tbbbEconomicInputs.js", "server/tbbbValuationCandidate.js", "server/tbbbUnderwrittenValuation.js",
  "server/tbbbUnderwrittenValuationAudit.js", "server/config/tbbb-economic-evidence.json", "server/config/tbbb-underwriting-2026-09-05.json"];
const modelBindings = modelPaths.map((path) => ({ path, sha256: digest(readFileSync(resolve(path))) }));
const economics = JSON.parse(readFileSync(resolve("server/config/tbbb-economic-evidence.json")));
const underwriting = JSON.parse(readFileSync(resolve("server/config/tbbb-underwriting-2026-09-05.json")));
const independentAudits = scenarios.map((result) => ({ scenarioId: result.scenarioId,
  ...auditTbbbUnderwrittenValuation({ input: { ...input, scenarioId: result.scenarioId }, result,
    economicEvidence: economics, underwriting }) }));
if (independentAudits.some((a) => a.status !== "pass")) throw new Error(JSON.stringify(independentAudits));
let sourceAudit = null;
let sourceReviewBinding = null;
let sourceFactAudit = null;
if (Boolean(values["--bindings"]) !== Boolean(values["--source-review"])) throw new Error("Source bundle and fact review must be supplied together");
if (values["--bindings"]) {
  const bindingPath = resolve(values["--bindings"]);
  const bindingRaw = readFileSync(bindingPath);
  const binding = JSON.parse(bindingRaw);
  sourceAudit = auditTbbbSourceBindings(binding);
  if (sourceAudit.status !== "pass") throw new Error(JSON.stringify(sourceAudit));
  const reviewPath = resolve(values["--source-review"]);
  const reviewRaw = readFileSync(reviewPath);
  const review = JSON.parse(reviewRaw);
  if (review.bindingSha256 !== digest(bindingRaw) || resolve(review.bindingPath) !== bindingPath ||
      review.sourceCutoff !== "2026-09-05" || review.historicalEconomicApproval !== false ||
      review.financialFacts?.length !== 36 || review.sourcePassageChecks?.length < 19 ||
      review.macroObservations?.length !== 3) throw new Error("Dated source fact review does not bind complete bundle");
  for (const configPath of modelPaths.filter((path) => path.endsWith(".json"))) {
    const bound = binding.configBindings.find((x) => x.path === resolve(configPath));
    if (bound?.sha256 !== digest(readFileSync(resolve(configPath)))) throw new Error("Source-reviewed config differs from model config");
  }
  sourceFactAudit = auditTbbbReviewedSourceFacts(review, binding, economics, { input });
  if (sourceFactAudit.status !== "pass") throw new Error(JSON.stringify(sourceFactAudit));
  sourceReviewBinding = { path: reviewPath, sha256: digest(reviewRaw), sourceBundleSha256: digest(bindingRaw),
    scope: "current_source_fact_review_not_approval_of_all_historical_periods" };
}
const result = {
  status: "underwritten_baseline_and_anchored_stresses_for_independent_review",
  newValuationsPublished: 0,
  databaseAccess: false,
  copiedPriorHypotheticalAssumptions: false,
  inputSource: sourcePath,
  inputSha256: createHash("sha256").update(JSON.stringify(input)).digest("hex"),
  omittedGrowthSlots: source.omittedGrowthSlots,
  modelBindings, fullModelSignature: digest(JSON.stringify(modelBindings)),
  independentAudits, sourceAudit, sourceFactAudit, sourceReviewBinding,
  currentCandidate: {
    ticker: "TBBB", cik: "1978954", quoteCurrency: "USD", financialCurrency: "MXN",
    asOfDate: "2026-09-05", periodEndDate: "2026-06-30",
    mode: "current_only_underwritten_scenarios", historicalCurveAuthorized: false,
    baseFairValueUsd: scenarios[0].value.fairValueUsd,
    label: "Conservative full-share-claim FCFE scenario; not exact option fair value",
    sourceAndArithmeticReady: sourceAudit?.status === "pass",
    releaseReady: false,
    remainingReleaseStep: "Independent parent judgment and current-only platform integration; no automatic historical profile approval",
    downsideQualification: { fairValueUsd: null, fundingDeficitMxnM: scenarios[1].funding.fundingDeficitM,
      reason: "The stressed path needs additional financing; mechanical value is not a publishable target" }
  }, scenarios
};
const json = `${JSON.stringify(result, null, 2)}\n`;
mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, json, { flag: "wx" });
console.log(JSON.stringify({ outputPath, sha256: createHash("sha256").update(json).digest("hex"),
  scenarios: scenarios.map((r) => ({ scenarioId: r.scenarioId, methodReady: r.methodReady,
    fairValueUsd: r.value.fairValueUsd, fundingDeficitM: r.funding.fundingDeficitM, failedChecks: r.failedChecks })) }, null, 2));
