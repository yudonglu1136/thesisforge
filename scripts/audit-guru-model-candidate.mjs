import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { auditGuidanceCoverageRelease } from "../server/guidanceCoverageReleaseAudit.js";
import {
  inspectModels, inspectReleasePathLeaks, inspectStoredGuidanceLineage, inspectStoredIndependentGuidanceAmounts,
  inspectStoredPlusMinusGuidance, inspectTranscriptQaSnapshots, modelSignature, snapshotSignature
} from "../server/verifyPitValuationRelease.js";
import { inspectUnmodeledFinancialPeriods } from "../server/valuationCoverageAudit.js";
import { inspectValuationTemporalContinuity } from "../server/valuationTemporalAudit.js";

const [databasePath, outputPath] = process.argv.slice(2);
if (!databasePath || !outputPath) throw new Error("Usage: node scripts/audit-guru-model-candidate.mjs <candidate.sqlite> <report.json>");
const guruManifestPath = path.resolve(process.env.GURU_VALUATION_UNIVERSE_PATH || "server/config/guru-valuation-universe.json");
const hashFile = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const auditCodeFiles = ["server/importSecQuarterlyValuations.js", "server/verifyPitValuationRelease.js",
  "server/guidanceCoverageReleaseAudit.js", "server/guidanceEvidenceAudit.js",
  "server/guidancePerShareEvidenceAudit.js", "server/guidanceOccurrenceAudit.js",
  "server/eventGuidanceCurrencyEvidenceAudit.js"];
const auditInputs = { guruManifestPath, guruManifestSha256: hashFile(guruManifestPath),
  codeHashes: Object.fromEntries(auditCodeFiles.map(file => [file, hashFile(file)])) };
const db = new DatabaseSync(path.resolve(databasePath), { readOnly: true });
try {
  if (db.prepare("PRAGMA integrity_check").get().integrity_check !== "ok") throw new Error("Candidate integrity failed");
  const metadata = Object.fromEntries(db.prepare("SELECT key,value FROM valuation_pit_source_metadata").all().map(r => [r.key, r.value]));
  const requiredTickers = db.prepare("SELECT DISTINCT ticker FROM valuation_pit_financials ORDER BY ticker").all().map(r => r.ticker);
  const guidance = auditGuidanceCoverageRelease({
    rows: db.prepare("SELECT * FROM valuation_pit_guidance ORDER BY ticker,fiscal_period,observed_at,source_database,source_id").iterate(),
    financialRows: db.prepare("SELECT ticker,available_at,currency,payload_json FROM valuation_pit_financials ORDER BY ticker,available_at DESC").iterate(),
    modelRuns: db.prepare("SELECT ticker,fiscal_period,as_of_date,input_json FROM valuation_pit_model_runs ORDER BY ticker,fiscal_period").iterate(),
    requiredTickers,
    noQuantifiedTickers: JSON.parse(metadata.guidance_no_quantified_tickers || "[]"),
    declaredCoverage: JSON.parse(metadata.guidance_coverage_summary || "{}")
  });
  const { rejectedEventKeys, ...guidanceReport } = guidance;
  const checks = {
    guidance: guidanceReport,
    plusMinus: inspectStoredPlusMinusGuidance(db, rejectedEventKeys),
    independentAmounts: inspectStoredIndependentGuidanceAmounts(db, rejectedEventKeys),
    guidanceLineage: inspectStoredGuidanceLineage(db, metadata.guidance_extraction_version || ""),
    releasePaths: inspectReleasePathLeaks(db),
    models: inspectModels(db),
    transcriptQa: inspectTranscriptQaSnapshots(db),
    unmodeled: inspectUnmodeledFinancialPeriods(db)
  };
  checks.temporal = inspectValuationTemporalContinuity(db, { unmodeledAudit: checks.unmodeled });
  const failures = Object.entries(checks).flatMap(([check, result]) =>
    (result.failures || result.unexpected || result.blockers || []).map(finding => ({ check, ...finding })));
  const failureCounts = {};
  for (const finding of failures) {
    const key = `${finding.check}:${finding.code || finding.reason || "unspecified"}`;
    failureCounts[key] = (failureCounts[key] || 0) + 1;
  }
  const report = {
    schemaVersion: 1,
    status: failures.length ? "blocked" : "model_checks_pass_full_release_pending",
    scope: "read_only_model_candidate_diagnostic_not_a_release_authorization",
    auditInputs,
    tickers: requiredTickers, modelVersion: metadata.model_version,
    modelSignature: modelSignature(db), snapshotSignature: snapshotSignature(db),
    failureCounts, failures, checks
  };
  fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify({ status: report.status, tickers: requiredTickers.length,
    modelRows: checks.models.rows, failureCounts }, null, 2));
  if (failures.length) process.exitCode = 2;
} finally {
  db.close();
}
