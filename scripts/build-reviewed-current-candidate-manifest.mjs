import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve, dirname } from "node:path";
import { loadReviewedCurrentValuationCandidates, auditStoredReviewedCurrentCandidate } from "../server/reviewedCurrentValuationCandidates.js";

const names = ["--spot-snapshot", "--spot-sha256", "--spot-input", "--spot-sources", "--tbbb-snapshot", "--tbbb-sha256", "--tbbb-reviewed", "--tbbb-comparison", "--output"];
const args = process.argv.slice(2), o = {};
for (let i = 0; i < args.length; i += 2) {
  if (!names.includes(args[i]) || !args[i + 1] || o[args[i]]) throw new Error("Explicit separately reviewed snapshot digests/paths and new output required");
  o[args[i]] = args[i + 1];
}
for (const name of names) if (!o[name]) throw new Error(`Missing ${name}`);
const sha = (raw) => createHash("sha256").update(typeof raw === "string" || Buffer.isBuffer(raw) ? raw : JSON.stringify(raw)).digest("hex");
function snapshot(name) {
  const raw = readFileSync(o[`--${name}-snapshot`]);
  if (sha(raw) !== o[`--${name}-sha256`]) throw new Error(`${name} snapshot differs from independent review`);
  return JSON.parse(raw);
}
const output = resolve(o["--output"]);
if (existsSync(output)) throw new Error("Immutable manifest exists");
const spot = snapshot("spot"), tbbb = snapshot("tbbb");
const reviewedRaw = readFileSync(o["--tbbb-reviewed"]), reviewed = JSON.parse(reviewedRaw);
const reviewRaw = readFileSync(reviewed.sourceReviewBinding.path), review = JSON.parse(reviewRaw);
const comparisonRaw = readFileSync(o["--tbbb-comparison"]);
const manifest = { schemaVersion: 1, scope: "current_only_additive_candidates_not_release", historicalApproval: false, entries: [
  { ticker: "SPOT", inputPath: resolve(o["--spot-input"]), inputSha256: spot.snapshot.currentScenarioDetails.inputSha256,
    sourceBundlePath: resolve(o["--spot-sources"]), sourceBundleSha256: spot.snapshot.currentScenarioDetails.sourceBundleSha256,
    modelSignature: spot.snapshot.currentScenarioDetails.fullModelSignature,
    expectedSnapshotSha256: sha(spot.snapshot), expectedModelRunsSha256: sha(spot.modelRuns) },
  { ticker: "TBBB", reviewedCandidatePath: resolve(o["--tbbb-reviewed"]), reviewedCandidateSha256: sha(reviewedRaw),
    inputSourcePath: reviewed.inputSource, inputSourceSha256: sha(readFileSync(reviewed.inputSource)),
    sourceReviewPath: reviewed.sourceReviewBinding.path, sourceReviewSha256: reviewed.sourceReviewBinding.sha256,
    sourceBundlePath: review.bindingPath, sourceBundleSha256: reviewed.sourceReviewBinding.sourceBundleSha256,
    modelSignature: reviewed.fullModelSignature, comparisonPath: resolve(o["--tbbb-comparison"]), comparisonFileSha256: sha(comparisonRaw),
    comparisonCanonicalSha256: sha(JSON.parse(comparisonRaw)), expectedSnapshotSha256: sha(tbbb.snapshot), expectedModelRunsSha256: sha(tbbb.modelRuns) }
] };
const raw = JSON.stringify(manifest, null, 2) + "\n";
const checked = loadReviewedCurrentValuationCandidates({ manifestJson: raw, expectedManifestSha256: sha(raw) });
for (const candidate of checked.candidates) {
  const audit = auditStoredReviewedCurrentCandidate({ expected: candidate, snapshot: candidate.snapshot, modelRuns: candidate.modelRuns });
  if (audit.status !== "pass") throw new Error(JSON.stringify(audit));
}
mkdirSync(dirname(output), { recursive: true }); writeFileSync(output, raw, { flag: "wx" });
console.log(JSON.stringify({ output, sha256: sha(raw), tickers: checked.candidates.map((c) => c.ticker), status: checked.status, releaseAuthorized: false }));
