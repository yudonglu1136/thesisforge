import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { loadReviewedCurrentValuationCandidates, auditStoredReviewedCurrentCandidate } from "./reviewedCurrentValuationCandidates.js";
const sha = (raw) => createHash("sha256").update(raw).digest("hex");
function fixture() {
  const data = { marker: "fixed economic forecast" };
  const row = { asOfDate: "2026-09-05", fiscalPeriod: "2026-Q2", periodEndDate: "2026-06-30", financialAvailableAt: "2026-08-04",
    fairValue: 100, currency: "USD", priceAtDate: 80, priceDate: "2026-09-04", upsideDownside: 0.25, targetPrice3Y: null,
    expectedReturn3Y: null, sourceType: "current", method: "current", dataSnapshot: { reviewedCurrentScenario: data } };
  const snapshot = { ticker: "SPOT", cik: "1639920", currency: "USD", history: [row], latest: { baseFairValue: 100, latestPrice: 80,
    latestPriceDate: "2026-09-04", latestPriceSource: "paid", upsideToBase: 0.25, targetPrice3Y: null, expectedReturn3Y: null, valuationAnchorDate: "2026-09-05" },
    currentScenarioDetails: data, scenarios: [{ name: "base", fairValue: 100 }],
    dataQuality: { historicalCurveAuthorized: false, currentOnly: true, valuationCoverageKind: "current_only" } };
  const modelRuns = [{ ticker: "SPOT", asOfDate: "2026-09-05", fiscalPeriod: "2026-Q2", input: { fixed: 1 }, output: row }];
  return { expected: { ticker: "SPOT", releaseReady: false, currentSourceBinding: { independentlyChecked: true }, snapshot: structuredClone(snapshot), modelRuns: structuredClone(modelRuns) }, snapshot, modelRuns };
}
test("current-row verifier permits additive Q&A enrichment, never grants release", () => {
  const f = fixture(); f.snapshot.history[0].transcriptQa = [{ question: "Q", answer: "A", questionZh: "问", answerZh: "答" }];
  const r = auditStoredReviewedCurrentCandidate(f); assert.equal(r.status, "pass"); assert.equal(r.releaseAuthorized, false);
});
for (const [name, mutate] of [
  ["fake historical curve", (f) => f.snapshot.history.push({ ...f.snapshot.history[0], asOfDate: "2025-01-01" })],
  ["snapshot fair value change", (f) => { f.snapshot.latest.baseFairValue = 99; }],
  ["per-share claim change", (f) => { f.snapshot.currentScenarioDetails.marker = "different"; }],
  ["quote change", (f) => { f.snapshot.history[0].priceAtDate = 81; }],
  ["forecast promoted to historical", (f) => { f.snapshot.dataQuality.historicalCurveAuthorized = true; }],
  ["input changed", (f) => { f.modelRuns[0].input.fixed = 2; }],
  ["run-only fair value changed", (f) => { f.modelRuns[0].output = { ...f.modelRuns[0].output, fairValue: 99 }; }],
  ["second current model row", (f) => { f.modelRuns.push(f.modelRuns[0]); }],
]) test(`strict current hook rejects ${name}`, () => { const f = fixture(); mutate(f); assert.equal(auditStoredReviewedCurrentCandidate(f).status, "fail"); });
test("manifest requires external exact digest and explicit supported scope", () => {
  const raw = JSON.stringify({ schemaVersion: 1, scope: "current_only_additive_candidates_not_release", historicalApproval: false, entries: [{ ticker: "IOT" }] });
  assert.throws(() => loadReviewedCurrentValuationCandidates({ manifestJson: raw, expectedManifestSha256: "0".repeat(64) }));
  assert.throws(() => loadReviewedCurrentValuationCandidates({ manifestJson: raw, expectedManifestSha256: sha(raw) }), /unsupported/);
});
