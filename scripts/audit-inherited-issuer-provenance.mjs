#!/usr/bin/env node
// Read-only provenance binding. Never updates source review/coverage statuses.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import vm from "node:vm";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { profileSettings } from "../server/importSecQuarterlyValuations.js";

const dynamic = new Set(["generatedAt", "runCreatedAt", "fetchedAt"]);
export function canonicalize(value, omitDynamic = false) {
  if (Array.isArray(value)) return value.map((x) => canonicalize(x, omitDynamic));
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value).filter(([k]) => !omitDynamic || !dynamic.has(k))
    .sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonicalize(v, omitDynamic)]));
}
const canon = (x, omit = false) => JSON.stringify(canonicalize(x, omit));
const sha = (x) => crypto.createHash("sha256").update(x).digest("hex");
const hash = () => crypto.createHash("sha256");
const read = (p) => fs.readFileSync(p, "utf8");
const git = (repo, args) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });

export function extractLiteral(source, name) {
  const start = source.indexOf(`const ${name} = {`);
  if (start < 0) throw new Error(`Missing explicit ${name}`);
  const body = source.slice(start + `const ${name} = `.length);
  const end = body.indexOf("\n};");
  if (end < 0) throw new Error(`Unterminated explicit ${name}`);
  return vm.runInNewContext(`(${body.slice(0, end + 2)})`, Object.create(null), { timeout: 1000 });
}

export function assessIssuer({ ledger, baseline, originalSettings, currentSettings }) {
  const reasons = [];
  if (!baseline) reasons.push("missing_baseline_models");
  else {
    if (baseline.nodeCount !== ledger.nodeCount) reasons.push("ledger_node_count_mismatch");
    if (baseline.firstPeriod !== ledger.firstPeriod || baseline.latestPeriod !== ledger.latestPeriod || baseline.latestAsOfDate !== ledger.latestAsOfDate) reasons.push("ledger_period_or_date_mismatch");
    if (Math.round(baseline.latestFairValue * 100) / 100 !== ledger.latestFairValue) reasons.push("ledger_latest_value_mismatch_at_declared_2dp_precision");
    if (baseline.profiles.length !== 1 || baseline.profiles[0] !== ledger.profile) reasons.push("ledger_profile_mismatch");
  }
  if (!["pass", "watch"].includes(ledger.status) || ledger.blockerCount !== 0) reasons.push("prior_ledger_not_pass_or_explained_watch");
  if (!originalSettings || originalSettings.profile !== ledger.profile) reasons.push("original_git_profile_not_bound");
  if (!currentSettings || currentSettings.profile !== ledger.profile) reasons.push("current_profile_selection_changed");
  if (originalSettings && currentSettings && canon(originalSettings) !== canon(currentSettings)) reasons.push("current_profile_parameters_changed");
  return { profileInheritanceEligible: reasons.length === 0, reasons,
    inheritedScope: "previously_audited_profile_selection_and_profile_parameters_only",
    newFinancialInputApprovalInherited: false, newGuidanceApprovalInherited: false,
    newFxApprovalInherited: false, newModelOutputsApprovalInherited: false, releaseAuthorized: false };
}

export function modelBindings(db) {
  const global = hash(), rawGlobal = hash();
  const tickers = new Map();
  let rows = 0;
  for (const row of db.prepare("SELECT ticker,fiscal_period,model_version,as_of_date,financial_available_at,guidance_max_observed_at,input_json,output_json,generated_at FROM valuation_pit_model_runs ORDER BY ticker,fiscal_period,model_version").iterate()) {
    const input = JSON.parse(row.input_json), output = JSON.parse(row.output_json);
    const normalized = { ticker: row.ticker, fiscal_period: row.fiscal_period, model_version: row.model_version,
      as_of_date: row.as_of_date, financial_available_at: row.financial_available_at, guidance_max_observed_at: row.guidance_max_observed_at,
      input_json: canon(input, true), output_json: canon(output, true) };
    const line = JSON.stringify(normalized) + "\n";
    global.update(line); rawGlobal.update(JSON.stringify(row) + "\n"); rows++;
    let issuer = tickers.get(row.ticker);
    if (!issuer) tickers.set(row.ticker, issuer = { nodeCount: 0, firstPeriod: row.fiscal_period, latestPeriod: null,
      profiles: new Set(), modelVersions: new Set(), modelHash: hash(), nodes: [] });
    issuer.nodeCount++; issuer.modelHash.update(line);
    issuer.profiles.add(input.valuationSemantics?.scoreInputs?.profile || output.dataSnapshot?.valuationSemantics?.scoreInputs?.profile || null);
    issuer.modelVersions.add(row.model_version);
    issuer.latestPeriod = row.fiscal_period; issuer.latestAsOfDate = row.as_of_date; issuer.latestFairValue = output.fairValue;
    issuer.nodes.push({ fiscalPeriod: row.fiscal_period, asOfDate: row.as_of_date, financialAvailableAt: row.financial_available_at,
      fullModelNodeSha256: sha(line), rawInputSha256: sha(row.input_json), rawOutputSha256: sha(row.output_json) });
  }
  return { modelSignature: global.digest("hex"), rawFullModelRowsSha256: rawGlobal.digest("hex"), rows,
    tickers: new Map([...tickers].map(([ticker, x]) => [ticker, { ...x, modelHash: undefined,
      modelSignature: x.modelHash.digest("hex"), profiles: [...x.profiles].sort(), modelVersions: [...x.modelVersions].sort() }])) };
}

function financialBindings(db, table) {
  const byTicker = new Map();
  for (const row of db.prepare(`SELECT ticker,source_ticker,fiscal_period,fiscal_year,fiscal_quarter,dimension,available_at,report_period,currency,payload_json FROM ${table} ORDER BY ticker,fiscal_period,dimension`).iterate()) {
    const payload = JSON.parse(row.payload_json);
    let item = byTicker.get(row.ticker);
    if (!item) byTicker.set(row.ticker, item = { count: 0, evidenceHash: hash(), numbersHash: hash() });
    item.count++;
    item.evidenceHash.update(canon({ ...row, payload_json: payload }) + "\n");
    const numeric = Object.fromEntries(Object.entries(payload).filter(([key]) => key.endsWith("_m") || ["ticker", "periodEndDate", "asOfDate", "sourceDimension", "financialStatementCurrency"].includes(key)));
    item.numbersHash.update(canon({ ticker: row.ticker, fiscalPeriod: row.fiscal_period, dimension: row.dimension, numeric }) + "\n");
  }
  return new Map([...byTicker].map(([k, x]) => [k, { count: x.count, evidenceSha256: x.evidenceHash.digest("hex"), numericSha256: x.numbersHash.digest("hex") }]));
}

function guidanceBindings(db, baseline) {
  const byTicker = new Map();
  const sql = baseline ? "SELECT ticker,source_id AS id,payload_json FROM valuation_pit_guidance ORDER BY ticker,source_id"
    : "SELECT ticker,id,payload_json FROM pit_guidance_events ORDER BY ticker,id";
  for (const row of db.prepare(sql).iterate()) {
    let item = byTicker.get(row.ticker);
    if (!item) byTicker.set(row.ticker, item = { count: 0, hash: hash() });
    let event = JSON.parse(row.payload_json);
    if (baseline) {
      let nested = event.payload_json;
      if (typeof nested === "string") nested = JSON.parse(nested);
      event = { ...(nested || {}), ...Object.fromEntries(Object.entries(event).filter(([k]) => k !== "payload_json")) };
    }
    item.count++; item.hash.update(canon({ id: row.id, event }) + "\n");
  }
  return new Map([...byTicker].map(([k, x]) => [k, { count: x.count, evidenceSha256: x.hash.digest("hex") }]));
}

export function audit({ repo, baselinePath, sourcePath, ledgerPath, commit, expectedModelSignature, priorAuditPath }) {
  if (!/^[a-f0-9]{40}$/.test(commit) || !/^[a-f0-9]{64}$/.test(expectedModelSignature)) throw new Error("Explicit full Git commit and baseline model signature are required");
  git(repo, ["merge-base", "--is-ancestor", commit, "HEAD"]);
  const relativeLedger = path.relative(repo, ledgerPath);
  if (relativeLedger.startsWith("..")) throw new Error("Ledger must be a tracked repository artifact");
  const ledgerBytes = fs.readFileSync(ledgerPath), gitLedger = git(repo, ["show", `${commit}:${relativeLedger}`]);
  if (sha(ledgerBytes) !== sha(gitLedger)) throw new Error("Current ledger bytes do not match explicit original commit");
  const ledger = JSON.parse(gitLedger);
  if (ledger.status !== "pass" || ledger.summary.blockerCount !== 0 || ledger.blockers.length) throw new Error("Original ledger did not pass");
  const originalCode = git(repo, ["show", `${commit}:server/importSecQuarterlyValuations.js`]);
  const originalProfiles = extractLiteral(originalCode, "VALUATION_PROFILES"), originalParameters = extractLiteral(originalCode, "PROFILE_SETTINGS");
  const originalUniverseBytes = git(repo, ["show", `${commit}:server/config/sp500-valuation-universe.json`]);
  const originalUniverse = JSON.parse(originalUniverseBytes).companies;
  const universeProfile = new Map();
  for (const company of originalUniverse) for (const alias of [company.ticker, ...(company.aliases || [])]) universeProfile.set(alias, company.valuationProfile);
  const baseline = new DatabaseSync(baselinePath, { readOnly: true }), source = new DatabaseSync(sourcePath, { readOnly: true });
  try {
    baseline.exec("BEGIN"); source.exec("BEGIN");
    const bindings = modelBindings(baseline);
    if (bindings.modelSignature !== expectedModelSignature) throw new Error("Full baseline model signature changed; provenance cannot be inherited");
    const priorAudit = priorAuditPath ? JSON.parse(read(priorAuditPath)) : null;
    if (priorAudit && priorAudit.modelSignature !== bindings.modelSignature) throw new Error("Prior current-rule diagnostic does not refer to this complete baseline");
    const baselineFinancial = financialBindings(baseline, "valuation_pit_financials"), sourceFinancial = financialBindings(source, "pit_financial_periods");
    const baselineGuidance = guidanceBindings(baseline, true), sourceGuidance = guidanceBindings(source, false);
    const sourceStates = new Map(source.prepare("SELECT ticker,status,reason FROM pit_issuer_review").all().map((x) => [x.ticker, x]));
    const records = [], discrepancies = [];
    for (const record of ledger.tickers) {
      if (!record.nodeCount && record.status === "not_applicable") continue;
      const stored = bindings.tickers.get(record.ticker);
      const oldProfile = originalProfiles[record.ticker] || universeProfile.get(record.ticker);
      const originalSettings = oldProfile ? { profile: oldProfile, ...originalParameters[oldProfile] } : null;
      let currentSettings = null;
      try { currentSettings = profileSettings(record.ticker); } catch { /* Report explicitly. */ }
      const assessed = assessIssuer({ ledger: record, baseline: stored, originalSettings, currentSettings });
      if (!assessed.profileInheritanceEligible) discrepancies.push({ ticker: record.ticker, ledgerProfile: record.profile,
        originalGitProfile: oldProfile, currentProfile: currentSettings?.profile || null, reasons: assessed.reasons });
      const bf = baselineFinancial.get(record.ticker), sf = sourceFinancial.get(record.ticker);
      const bg = baselineGuidance.get(record.ticker), sg = sourceGuidance.get(record.ticker);
      records.push({ ticker: record.ticker, ...assessed, profile: record.profile, priorStatus: record.status,
        originalGitSettingsSha256: originalSettings ? sha(canon(originalSettings)) : null,
        currentSettingsSha256: currentSettings ? sha(canon(currentSettings)) : null,
        ledgerBinding: { nodeCount: record.nodeCount, firstPeriod: record.firstPeriod, latestPeriod: record.latestPeriod,
          latestAsOfDate: record.latestAsOfDate, latestFairValue: record.latestFairValue, fairValuePrecision: "2 decimal places",
          watchCount: record.watchCount, flags: record.flags, ledgerEntrySha256: sha(canon(record)) },
        baselineBinding: stored, pendingSourceReview: sourceStates.get(record.ticker) || null,
        sourceChange: { baselineFinancial: bf, candidateFinancial: sf,
          financialAmountsUnchanged: Boolean(bf && sf && bf.numericSha256 === sf.numericSha256),
          financialEvidenceUnchanged: Boolean(bf && sf && bf.evidenceSha256 === sf.evidenceSha256),
          baselineGuidance: bg || { count: 0 }, candidateGuidance: sg || { count: 0 },
          guidanceEvidenceUnchanged: Boolean(bg && sg && bg.evidenceSha256 === sg.evidenceSha256),
          reviewDisposition: "Fresh dated financial, FX/currency, guidance-semantic, model-output and release checks remain mandatory even when source bytes are unchanged." } });
    }
    const summary = { ledgerTickerCount: ledger.tickers.length, retainedModeledTickers: records.length, baselineModelRows: bindings.rows,
      profileInheritanceEligible: records.filter((x) => x.profileInheritanceEligible).length, profileNewJudgmentRequired: discrepancies.length,
      unchangedFinancialAmounts: records.filter((x) => x.sourceChange.financialAmountsUnchanged).length,
      changedFinancialEvidence: records.filter((x) => !x.sourceChange.financialEvidenceUnchanged).length,
      changedGuidanceEvidence: records.filter((x) => !x.sourceChange.guidanceEvidenceUnchanged).length,
      newInputOrOutputApprovalsInherited: 0 };
    if (summary.retainedModeledTickers !== ledger.summary.modeledTickerCount || bindings.rows !== ledger.summary.modelNodeCount || bindings.tickers.size !== records.length) throw new Error("Full-universe ledger/model count mismatch");
    return { schemaVersion: 1, status: discrepancies.length ? "profile_inheritance_discrepancies" : "profile_provenance_verified_new_release_review_required",
      scope: "read_only_prior_release_profile_provenance_not_new_source_or_model_approval", releaseAuthorized: false, summary,
      originalRelease: { gitCommit: commit, ledgerPath: relativeLedger, ledgerSha256: sha(ledgerBytes), ledgerGeneratedAt: ledger.generatedAt,
        ledgerModelVersion: ledger.database.modelVersion, importSecCodeSha256: sha(originalCode), sp500UniverseSha256: sha(originalUniverseBytes),
        completeBaselineModelSignature: bindings.modelSignature, rawFullModelRowsSha256: bindings.rawFullModelRowsSha256 },
      currentImplementation: { headCommit: git(repo, ["rev-parse", "HEAD"]).trim(),
        importSecCodeSha256: sha(read(path.join(repo, "server/importSecQuarterlyValuations.js"))),
        implementationChanged: sha(originalCode) !== sha(read(path.join(repo, "server/importSecQuarterlyValuations.js"))),
        policy: "Unchanged profile parameters do not approve changed shared importer/economic logic; full two-run output validation remains required." },
      priorCurrentRuleDiagnostic: priorAudit ? { modelSignature: priorAudit.modelSignature, status: priorAudit.status,
        failureCounts: priorAudit.failureCounts, policy: "These failures remain open; the historical ledger pass is not reused as their approval." } : null,
      sourceProvenance: Object.fromEntries(source.prepare("SELECT key,value FROM pit_source_metadata WHERE key IN ('source_fingerprint','additive_rebuild_provenance')").all().map((r) => [r.key, r.value])),
      discrepancies, issuers: records };
  } finally { baseline.close(); source.close(); }
}

function main() {
  const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, i, list) => value.startsWith("--") ? [...pairs, [value.slice(2), list[i + 1]]] : pairs, []));
  for (const key of ["baseline", "source", "ledger", "git-commit", "expected-model-signature", "out"]) if (!args[key]) throw new Error(`Missing --${key}`);
  if (fs.existsSync(args.out)) throw new Error("Never overwrite an existing provenance report");
  const report = audit({ repo: path.resolve(args.repo || "."), baselinePath: path.resolve(args.baseline), sourcePath: path.resolve(args.source),
    ledgerPath: path.resolve(args.ledger), commit: args["git-commit"], expectedModelSignature: args["expected-model-signature"], priorAuditPath: args["prior-audit"] });
  fs.mkdirSync(path.dirname(path.resolve(args.out)), { recursive: true, mode: 0o700 });
  fs.writeFileSync(args.out, JSON.stringify(report, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  console.log(JSON.stringify({ status: report.status, ...report.summary, discrepancies: report.discrepancies, report: args.out }));
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main();
