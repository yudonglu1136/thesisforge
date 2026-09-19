import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { createHash } from "node:crypto";
import { buildTbbbCurrentSnapshotCandidate } from "../server/tbbbCurrentSnapshot.js";

const args = process.argv.slice(2), options = {};
for (let i = 0; i < args.length; i += 2) {
  if (!["--candidate", "--candidate-sha256", "--output", "--comparison-price", "--comparison-price-sha256"].includes(args[i]) || !args[i + 1]) {
    throw new Error("Usage: --candidate reviewed.json --candidate-sha256 EXPECTED --output NEW.json [--comparison-price paid-evidence.json --comparison-price-sha256 REVIEWED_CANONICAL_SHA]");
  }
  if (options[args[i]]) throw new Error("Duplicate option");
  options[args[i]] = args[i + 1];
}
for (const key of ["--candidate", "--candidate-sha256", "--output"]) if (!options[key]) throw new Error(`Missing ${key}`);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const candidateRaw = readFileSync(resolve(options["--candidate"]));
if (hash(candidateRaw) !== options["--candidate-sha256"]) throw new Error("Candidate digest differs from explicitly reviewed record");
const candidate = JSON.parse(candidateRaw);
if (!candidate.currentCandidate?.sourceAndArithmeticReady || !candidate.sourceReviewBinding ||
    candidate.sourceFactAudit?.status !== "pass" || candidate.independentAudits?.some((r) => r.status !== "pass")) {
  throw new Error("Candidate is not independently source/arithmetic audited");
}
const outputPath = resolve(options["--output"]);
if (existsSync(outputPath)) throw new Error("Immutable snapshot output exists");
const saved = JSON.parse(readFileSync(candidate.inputSource));
const input = saved.scenarios[0].input;
const sourceReviewJson = readFileSync(candidate.sourceReviewBinding.path, "utf8");
const review = JSON.parse(sourceReviewJson);
const sourceBundleJson = readFileSync(review.bindingPath, "utf8");
if (Boolean(options["--comparison-price"]) !== Boolean(options["--comparison-price-sha256"])) throw new Error("Comparison evidence and separately reviewed canonical digest must be supplied together");
const result = buildTbbbCurrentSnapshotCandidate({ input, sourceReviewJson, sourceBundleJson,
  trust: { inputSha256: candidate.inputSha256, sourceBundleSha256: candidate.sourceReviewBinding.sourceBundleSha256,
    sourceReviewSha256: candidate.sourceReviewBinding.sha256, fullModelSignature: candidate.fullModelSignature,
    comparisonPriceSha256: options["--comparison-price-sha256"] || null },
  comparisonPrice: options["--comparison-price"] ? JSON.parse(readFileSync(resolve(options["--comparison-price"]))) : null });
if (result.status === "blocked") throw new Error(JSON.stringify(result));
const resultWithBinding = { ...result, reviewedCandidateSha256: hash(candidateRaw),
  adapterSha256: hash(readFileSync(new URL("../server/tbbbCurrentSnapshot.js", import.meta.url))) };
mkdirSync(dirname(outputPath), { recursive: true });
const raw = JSON.stringify(resultWithBinding, null, 2)+"\n";
writeFileSync(outputPath, raw, { flag: "wx" });
console.log(JSON.stringify({ outputPath, sha256: hash(raw), ticker: "TBBB", historyRows: result.snapshot.history.length,
  fairValueUsd: result.snapshot.latest.baseFairValue, sourceAndArithmeticReady: true,
  releaseReady: false, historicalCurveAuthorized: false }));
