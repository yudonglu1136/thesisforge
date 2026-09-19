import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { auditGuidanceCoverageRelease } from "../server/guidanceCoverageReleaseAudit.js";

const [sourcePath, outputPath] = process.argv.slice(2);
if (!sourcePath || !outputPath) throw new Error("Usage: node scripts/audit-staged-guru-guidance.mjs <candidate-source.sqlite> <audit.json>");
const db = new DatabaseSync(path.resolve(sourcePath), { readOnly: true });
try {
  const coverage = db.prepare("SELECT ticker,status FROM pit_guidance_coverage ORDER BY ticker").all();
  const hasIssuerReview = db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='pit_issuer_review'").get();
  const expected = (hasIssuerReview
    ? db.prepare("SELECT ticker FROM pit_issuer_review ORDER BY ticker").all()
    : db.prepare("SELECT ticker FROM pit_financial_coverage WHERE status IN ('covered','annual_only') ORDER BY ticker").all()
  ).map((row) => row.ticker);
  const declaredCoverage = {};
  for (const { status } of coverage) declaredCoverage[status] = (declaredCoverage[status] || 0) + 1;
  const { rejectedEventKeys, ...evidenceAudit } = auditGuidanceCoverageRelease({
    rows: db.prepare("SELECT * FROM pit_guidance_events ORDER BY ticker,fiscal_period,observed_at,id").iterate(),
    financialRows: db.prepare("SELECT ticker,available_at,payload_json FROM pit_financial_periods ORDER BY ticker,available_at DESC").iterate(),
    modelRuns: [], requiredTickers: expected, coverageRows: coverage,
    noQuantifiedTickers: coverage.filter((row) => row.status === "no_quantified_official_guidance").map((row) => row.ticker),
    declaredCoverage,
  });
  const incomplete = coverage.filter((row) => !["covered", "covered_official_filing", "no_quantified_official_guidance"].includes(row.status));
  const missingCoverage = expected.filter((ticker) => !coverage.some((row) => row.ticker === ticker));
  const failureCounts = {};
  for (const { code } of evidenceAudit.failures) failureCounts[code] = (failureCounts[code] || 0) + 1;
  const result = {
    schemaVersion: 1,
    status: incomplete.length || missingCoverage.length || evidenceAudit.failures.length ? "blocked" : "evidence_checks_pass_model_not_audited",
    scope: "staged_source_guidance_only_not_a_release_verification",
    modelConsumptionAudited: false,
    caveat: "No model runs exist in this source-only stage. Evidence checks cannot prove model consumption or authorize release.",
    expectedIssuers: expected.length, declaredCoverage, incomplete, missingCoverage, failureCounts,
    ...evidenceAudit,
  };
  fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(result, null, 2) + "\n");
  console.log(JSON.stringify({ status: result.status, expectedIssuers: expected.length,
    rawStats: result.rawStats, usableEvents: result.usableEvents, researchEvents: result.researchEvents,
    incompleteIssuers: incomplete.length, missingCoverage: missingCoverage.length, failureCounts,
    modelConsumptionAudited: false }, null, 2));
  if (result.status === "blocked") process.exitCode = 2;
} finally {
  db.close();
}
