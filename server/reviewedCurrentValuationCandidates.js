import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { buildTbbbCurrentSnapshotCandidate } from "./tbbbCurrentSnapshot.js";
import { buildSpotCurrentSnapshot } from "./spotCurrentSnapshot.js";

const sha = (value) => createHash("sha256").update(typeof value === "string" || Buffer.isBuffer(value) ? value : JSON.stringify(value)).digest("hex");
function pinned(path, expected, read) {
  const raw = read(path);
  if (!/^[a-f0-9]{64}$/.test(expected || "") || sha(raw) !== expected) throw new Error(`Unpinned reviewed current source: ${path}`);
  return raw.toString();
}

/** Additive-rebuild input loader, not a database writer or release bypass.
 * Each explicit manifest entry is re-rendered from original source evidence and
 * separately pinned inputs. Do not approve old financial periods with this path.
 */
export function loadReviewedCurrentValuationCandidates({ manifestJson, expectedManifestSha256, read = readFileSync } = {}) {
  if (sha(manifestJson) !== expectedManifestSha256) throw new Error("Current candidate manifest is not independently pinned");
  const manifest = JSON.parse(manifestJson);
  if (manifest.schemaVersion !== 1 || manifest.scope !== "current_only_additive_candidates_not_release" ||
    manifest.historicalApproval !== false || !Array.isArray(manifest.entries) || !manifest.entries.length) throw new Error("Wrong current-candidate manifest contract");
  const seen = new Set(), candidates = [];
  for (const entry of manifest.entries) {
    if (seen.has(entry.ticker) || !["TBBB", "SPOT"].includes(entry.ticker)) throw new Error("Duplicate or unsupported current-only issuer");
    seen.add(entry.ticker);
    let candidate;
    if (entry.ticker === "SPOT") {
      candidate = buildSpotCurrentSnapshot({ inputJson: pinned(entry.inputPath, entry.inputSha256, read),
        sourceBundleJson: pinned(entry.sourceBundlePath, entry.sourceBundleSha256, read),
        trust: { inputSha256: entry.inputSha256, sourceBundleSha256: entry.sourceBundleSha256, modelSignature: entry.modelSignature }, readSource: read });
    } else {
      const reviewedRaw = pinned(entry.reviewedCandidatePath, entry.reviewedCandidateSha256, read);
      const reviewed = JSON.parse(reviewedRaw);
      const inputSourceRaw = pinned(entry.inputSourcePath, entry.inputSourceSha256, read);
      if (reviewed.inputSource !== entry.inputSourcePath || reviewed.currentCandidate?.sourceAndArithmeticReady !== true ||
        reviewed.sourceFactAudit?.status !== "pass") throw new Error("TBBB original candidate/source is not reviewed");
      const sourceReviewJson = pinned(entry.sourceReviewPath, entry.sourceReviewSha256, read);
      const sourceBundleJson = pinned(entry.sourceBundlePath, entry.sourceBundleSha256, read);
      const comparisonJson = pinned(entry.comparisonPath, entry.comparisonFileSha256, read);
      const comparisonPrice = JSON.parse(comparisonJson);
      if (sha(comparisonPrice) !== entry.comparisonCanonicalSha256) throw new Error("Original comparison canonical digest mismatch");
      if (reviewed.sourceReviewBinding?.path !== entry.sourceReviewPath || reviewed.sourceReviewBinding.sha256 !== entry.sourceReviewSha256 ||
          reviewed.sourceReviewBinding.sourceBundleSha256 !== entry.sourceBundleSha256 || reviewed.fullModelSignature !== entry.modelSignature) throw new Error("TBBB independent review chain mismatch");
      candidate = buildTbbbCurrentSnapshotCandidate({ input: JSON.parse(inputSourceRaw).scenarios[0].input,
        sourceReviewJson, sourceBundleJson, comparisonPrice,
        trust: { inputSha256: reviewed.inputSha256, sourceReviewSha256: entry.sourceReviewSha256, sourceBundleSha256: entry.sourceBundleSha256,
          fullModelSignature: entry.modelSignature, comparisonPriceSha256: entry.comparisonCanonicalSha256 }, readSource: read });
    }
    if (candidate.status !== "current_only_snapshot_candidate" || candidate.releaseReady !== false ||
      candidate.snapshot.ticker !== entry.ticker || candidate.snapshot.history.length !== 1 || candidate.snapshot.dataQuality.historicalCurveAuthorized !== false) {
      throw new Error(`Current-only independent source/model replay failed for ${entry.ticker}: ${JSON.stringify(candidate)}`);
    }
    // The manifest binds normal snapshot content, not a caller's self-reported
    // ready flag. Persist this verified object into both full rebuilds before QA.
    if (sha(candidate.snapshot) !== entry.expectedSnapshotSha256 || sha(candidate.modelRuns) !== entry.expectedModelRunsSha256) throw new Error(`Current snapshot/model rows changed for ${entry.ticker}`);
    candidates.push({ ticker: entry.ticker, ...candidate, currentSourceBinding: { manifestSha256: expectedManifestSha256,
      sourceBundleSha256: entry.sourceBundleSha256, modelSignature: entry.modelSignature,
      expectedSnapshotSha256: entry.expectedSnapshotSha256, expectedModelRunsSha256: entry.expectedModelRunsSha256 } });
  }
  return { status: "independent_current_candidates_checked_not_full_release", manifestSha256: expectedManifestSha256, candidates,
    historicalApproval: false, releaseAuthorized: false };
}

/** Strict verifier hook after the normal full-universe rebuild/enrichment.
 * Enrichment may add transcript/Q&A fields; it may not alter the economics,
 * temporal scope, claims, quote, or substitute forecast years for history.
 */
export function auditStoredReviewedCurrentCandidate({ expected, snapshot, modelRuns } = {}) {
  const failures = [];
  const fail = (code) => failures.push({ ticker: expected?.ticker, code });
  if (!expected?.currentSourceBinding || !expected.snapshot || expected.releaseReady !== false) return { status: "fail", failures: [{ code: "missing_fresh_independent_current_replay" }] };
  const es = expected.snapshot;
  if (!snapshot || snapshot.ticker !== expected.ticker || snapshot.currency !== es.currency || snapshot.cik !== es.cik ||
      snapshot.dataQuality?.historicalCurveAuthorized !== false || snapshot.dataQuality?.currentOnly !== true ||
      snapshot.dataQuality?.valuationCoverageKind !== "current_only") fail("current_scope_or_security_changed");
  if (!Array.isArray(snapshot?.history) || snapshot.history.length !== 1 || !Array.isArray(modelRuns) || modelRuns.length !== 1) fail("current_only_history_or_run_count");
  const actual = snapshot?.history?.[0], e = es.history[0], run = modelRuns?.[0];
  for (const key of ["asOfDate", "fiscalPeriod", "periodEndDate", "financialAvailableAt", "fairValue", "currency", "priceAtDate", "priceDate", "upsideDownside", "targetPrice3Y", "expectedReturn3Y", "sourceType", "method"]) {
    if (actual?.[key] !== e[key]) fail(`current_history_changed:${key}`);
    if (run?.output?.[key] !== expected.modelRuns[0].output[key]) fail(`current_run_output_changed:${key}`);
  }
  for (const key of ["baseFairValue", "latestPrice", "latestPriceDate", "latestPriceSource", "upsideToBase", "targetPrice3Y", "expectedReturn3Y", "valuationAnchorDate"]) {
    if (snapshot?.latest?.[key] !== es.latest[key]) fail(`current_latest_changed:${key}`);
  }
  if (sha(snapshot?.scenarios ?? null) !== sha(es.scenarios) || sha(snapshot?.currentScenarioDetails ?? null) !== sha(es.currentScenarioDetails)) fail("current_scenarios_or_claims_changed");
  if (sha(actual?.dataSnapshot?.reviewedCurrentScenario ?? null) !== sha(e.dataSnapshot.reviewedCurrentScenario)) fail("current_source_economics_changed");
  for (const [key, value] of Object.entries(e.dataSnapshot)) {
    if (sha(actual?.dataSnapshot?.[key] ?? null) !== sha(value)) fail(`current_data_snapshot_changed:${key}`);
    if (sha(run?.output?.dataSnapshot?.[key] ?? null) !== sha(value)) fail(`current_run_data_snapshot_changed:${key}`);
  }
  if (sha(run?.input ?? null) !== sha(expected.modelRuns[0].input)) fail("current_model_input_changed");
  if (run?.asOfDate !== expected.modelRuns[0].asOfDate || run?.fiscalPeriod !== expected.modelRuns[0].fiscalPeriod ||
      run?.financialAvailableAt !== expected.modelRuns[0].financialAvailableAt ||
      run?.ticker !== expected.ticker || sha(run?.output?.dataSnapshot?.reviewedCurrentScenario ?? null) !== sha(e.dataSnapshot.reviewedCurrentScenario)) fail("current_model_run_scope_or_output_changed");
  return { status: failures.length ? "fail" : "pass", failures, ticker: expected.ticker,
    scope: "exact_current_only_candidate; existing_full_release_gates_still_required", historicalApproval: false, releaseAuthorized: false };
}
