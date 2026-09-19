#!/usr/bin/env node
// Copy-only binding of already audited profile choices. Fresh financial,
// guidance, currency, claims and full output release gates remain mandatory.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import { audit } from "./audit-inherited-issuer-provenance.mjs";

export function inheritedReviewUpdates(report, sourceStates) {
  if (report.status !== "profile_provenance_verified_new_release_review_required" ||
      report.releaseAuthorized !== false || report.discrepancies.length ||
      report.issuers.length !== report.summary.retainedModeledTickers ||
      report.summary.profileInheritanceEligible !== report.summary.retainedModeledTickers ||
      report.summary.newInputOrOutputApprovalsInherited !== 0) {
    throw new Error("Unverified or expanded inheritance scope");
  }
  const seen = new Set();
  return report.issuers.map((issuer) => {
    const prior = sourceStates.filter((row) => row.ticker === issuer.ticker);
    if (seen.has(issuer.ticker) || !issuer.profileInheritanceEligible || prior.length !== 1 ||
        prior[0].status !== "inherited_release_review_pending" ||
        issuer.newFinancialInputApprovalInherited || issuer.newGuidanceApprovalInherited ||
        issuer.newFxApprovalInherited || issuer.newModelOutputsApprovalInherited || issuer.releaseAuthorized) {
      throw new Error(`Cannot bind prior profile for ${issuer.ticker}`);
    }
    seen.add(issuer.ticker);
    return { ticker: issuer.ticker, status: "reviewed", reason: JSON.stringify({
      scope: "existing_issuer_prior_audited_profile_selection_and_parameters_only",
      profile: issuer.profile, priorStatus: issuer.priorStatus,
      originalGitCommit: report.originalRelease.gitCommit,
      originalSettingsSha256: issuer.originalGitSettingsSha256,
      originalFullModelSignature: issuer.baselineBinding.modelSignature,
      sourceAndOutputApprovalInherited: false, releaseAuthorized: false,
      required: "New financial/currency/FX/guidance and full deterministic model/release audits still required."
    }) };
  });
}

function protectedSignatures(database) {
  const signatures = {};
  for (const { name } of database.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all()) {
    if (["pit_issuer_review", "pit_source_metadata"].includes(name)) continue;
    const quoted = '"' + name.replaceAll('"', '""') + '"';
    const fields = database.prepare(`PRAGMA table_info(${quoted})`).all();
    const keys = fields.filter((row) => row.pk).sort((a, b) => a.pk - b.pk);
    const order = (keys.length ? keys : fields).map((row) => '"' + row.name.replaceAll('"', '""') + '"').join(",");
    const digest = crypto.createHash("sha256"); let count = 0;
    for (const row of database.prepare(`SELECT * FROM ${quoted} ORDER BY ${order}`).iterate()) {
      digest.update(JSON.stringify(row) + "\n"); count++;
    }
    signatures[name] = { count, sha256: digest.digest("hex") };
  }
  return signatures;
}

function main() {
  const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) =>
    value.startsWith("--") ? [...pairs, [value.slice(2), all[index + 1]]] : pairs, []));
  for (const key of ["baseline", "source", "ledger", "git-commit", "expected-model-signature", "output", "report"]) {
    if (!args[key]) throw new Error(`Missing --${key}`);
  }
  const output = path.resolve(args.output), reportPath = path.resolve(args.report);
  if (fs.existsSync(output) || fs.existsSync(reportPath) || output === reportPath) throw new Error("Use new, distinct output/report paths");
  const source = new DatabaseSync(path.resolve(args.source), { readOnly: true });
  try {
    const report = audit({ repo: path.resolve(args.repo || "."), baselinePath: path.resolve(args.baseline),
      sourcePath: path.resolve(args.source), ledgerPath: path.resolve(args.ledger), commit: args["git-commit"],
      expectedModelSignature: args["expected-model-signature"], priorAuditPath: args["prior-audit"] });
    const updates = inheritedReviewUpdates(report, source.prepare("SELECT ticker,status,reason FROM pit_issuer_review ORDER BY ticker").all());
    const preserved = protectedSignatures(source);
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.closeSync(fs.openSync(output, "wx", 0o600));
    source.prepare("VACUUM INTO ?").run(output);
    const target = new DatabaseSync(output);
    try {
      target.exec("BEGIN IMMEDIATE");
      for (const row of updates) {
        const result = target.prepare("UPDATE pit_issuer_review SET status=?,reason=? WHERE ticker=? AND status='inherited_release_review_pending'")
          .run(row.status, row.reason, row.ticker);
        if (result.changes !== 1) throw new Error("Issuer source review changed during copy");
      }
      const binding = { schemaVersion: 1, scope: "profile_only_no_new_input_or_model_approval", releaseAuthorized: false,
        originalRelease: report.originalRelease, summary: report.summary,
        completeReportSha256: crypto.createHash("sha256").update(JSON.stringify(report)).digest("hex") };
      target.prepare("INSERT INTO pit_source_metadata(key,value) VALUES('inherited_issuer_profile_review',?)").run(JSON.stringify(binding));
      if (JSON.stringify(protectedSignatures(target)) !== JSON.stringify(preserved)) throw new Error("Protected source tables changed");
      if (target.prepare("PRAGMA integrity_check").get().integrity_check !== "ok") throw new Error("Candidate integrity check failed");
      target.exec("COMMIT");
    } finally { target.close(); }
    fs.mkdirSync(path.dirname(reportPath), { recursive: true });
    fs.writeFileSync(reportPath, JSON.stringify({ ...report, application: {
      source: path.resolve(args.source), output, issuerProfileReviewRows: updates.length,
      otherTablesChanged: false, protectedTableSignatures: preserved, releaseAuthorized: false } }, null, 2) + "\n", { flag: "wx", mode: 0o600 });
    console.log(JSON.stringify({ output, report: reportPath, inheritedProfiles: updates.length, newSourceOrModelApprovals: 0, releaseAuthorized: false }));
  } finally { source.close(); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main();
