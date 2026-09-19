import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { auditTbbbUnderwrittenValuation, auditTbbbSourceBindings } from "./tbbbUnderwrittenValuationAudit.js";
import { calculateTbbbUnderwrittenValuation } from "./tbbbUnderwrittenValuation.js";
import { tbbbCurrentAuditFixture } from "./fixtures/tbbbCurrentAuditFixture.js";

const E = JSON.parse(readFileSync(new URL("./config/tbbb-economic-evidence.json", import.meta.url)));
const C = JSON.parse(readFileSync(new URL("./config/tbbb-underwriting-2026-09-05.json", import.meta.url)));
function sample(scenarioId = "base") {
  const input = { ...tbbbCurrentAuditFixture(), scenarioId };
  return { input, result: calculateTbbbUnderwrittenValuation(input), economicEvidence: structuredClone(E), underwriting: structuredClone(C) };
}

test("independent module has no import of either model or adapter", () => {
  const source = readFileSync(new URL("./tbbbUnderwrittenValuationAudit.js", import.meta.url), "utf8");
  assert.doesNotMatch(source, /from ["']\.\/(tbbbUnderwrittenValuation|tbbbEconomicInputs|tbbbValuationCandidate)\.js/);
});
for (const id of ["base", "downside", "upside"]) test(`independent exact-current ${id} cash/claims/FX/timing replay`, () => {
  const s = sample(id), audit = auditTbbbUnderwrittenValuation(s);
  assert.equal(audit.status, "pass", JSON.stringify(audit.failures));
  assert.equal(audit.recomputed.methodReady, id !== "downside");
  if (id === "downside") {
    assert.equal(audit.recomputed.fairValueUsd, null);
    assert.ok(Math.abs(audit.recomputed.fundingDeficitM - 3825.02936863673) < 1e-7);
  }
});

const corruptions = {
  "wrong historical node": (s) => { s.result.periodEndDate = "2026-03-31"; },
  "model self approval": (s) => { s.result.releaseReady = true; },
  "future source": (s) => { s.underwriting.sources.fy2025.availableDate = "2026-09-06"; },
  "thousand-million raw CFO": (s) => { s.input.economicInput.sourceCfo *= 1000; },
  "USD-MXN reversal": (s) => { s.input.fx.mxnPerUsd = 1 / s.input.fx.mxnPerUsd; },
  "share-class omitted": (s) => { s.result.value.shareClaimDenominator -= E.shareClaims.issuedByClass.C; },
  "market-priced dilution reference used": (s) => { s.result.value.shareClaimDenominator = 162047684; },
  "SBC expensed again": (s) => { s.result.economicCashBridge.sbcDeductedM = 3801.322; },
  "supplier financing gross deduction": (s) => { s.result.economicCashBridge.supplierFinanceDeductedAgainM = 7545.481; },
  "leases charged twice": (s) => { s.result.forecast[2].additionalLeaseServiceM = 100; },
  "software charged twice": (s) => { s.result.forecast[2].additionalIntangibleChargeM = 27.855; },
  "grant cash expense plus dilution": (s) => { s.result.forecast[3].futureAwardCashExpenseM = 200; },
  "terminal extra year": (s) => { s.result.terminal.terminalPvMxnM /= 1 + s.result.analystAssumptions.keMxn; },
  "lease net-debt duplicate": (s) => { s.result.value.equityValueMxnM -= 11730.444; },
  "deposit double count": (s) => { s.result.cashAsset.cashAssetPvMxnM *= 2; },
  "stub ignored": (s) => { s.result.stub.timeYears = 0; },
  "false positive self-checks": (s) => { s.result.value.fairValueUsd += 2; s.result.checks = { everythingPerfect: true }; },
  "funding stress target exposed": (s) => { Object.assign(s, sample("downside")); s.result.value.fairValueUsd = .37; },
};
for (const [label, corrupt] of Object.entries(corruptions)) test(`rejects ${label}`, () => {
  const s = sample(); corrupt(s);
  assert.equal(auditTbbbUnderwrittenValuation(s).status, "fail");
});

test("self-reported model checks are not the evidence for passing independent arithmetic", () => {
  const s = sample(); delete s.result.checks;
  assert.equal(auditTbbbUnderwrittenValuation(s).status, "pass");
});
test("changing a supplied market quote cannot change the calculated or independently checked value", () => {
  const a = sample(); const original = a.result.value.fairValueUsd;
  a.input.marketPrice = 99999999; a.input.sharePrice = .01;
  a.result = calculateTbbbUnderwrittenValuation(a.input);
  assert.equal(a.result.value.fairValueUsd, original);
  assert.equal(auditTbbbUnderwrittenValuation(a).status, "pass");
});

function sourceFixture() {
  const files = new Map();
  function file(path, text) {
    const raw = Buffer.from(text); files.set(path, raw);
    return { path, byteLength: raw.length, sha256: createHash("sha256").update(raw).digest("hex") };
  }
  const documents = Array.from({ length: 19 }, (_, i) => ({ ...file(`/doc${i}`, `original issuer source ${i}`),
    url: `https://www.sec.gov/Archives/edgar/data/1978954/acc${i}/test.htm`, availableDate: "2026-08-12",
    sourceAuthority: "issuer_SEC", submissionBinding: { accession: `acc-${i}`, filed: "2026-08-12", acceptedAt: "2026-08-12T20:00:00Z" } }));
  const configBindings = [file("/config", JSON.stringify({ sources: Object.fromEntries(documents.map((d, i) => [i, {url:d.url}])) }))];
  const submissionIndexBinding = file("/submissions", JSON.stringify({ filings: { recent: {
    accessionNumber: documents.map((d) => d.submissionBinding.accession),
    filingDate: documents.map((d) => d.submissionBinding.filed),
    acceptanceDateTime: documents.map((d) => d.submissionBinding.acceptedAt)
  } } }));
  return { binding: { schemaVersion: "tbbb-source-binding-v1", sourceCutoff: "2026-09-05",
    historicalApproval: false, documents, configBindings, submissionIndexBinding }, files,
    read: (path) => { if (!files.has(path)) throw new Error("missing"); return files.get(path); } };
}
test("source byte binding succeeds and catches post-review source tampering", () => {
  const f = sourceFixture(); assert.equal(auditTbbbSourceBindings(f.binding, f).status, "pass");
  f.files.set("/doc1", Buffer.from("modified document"));
  assert.equal(auditTbbbSourceBindings(f.binding, f).status, "fail");
});
test("source SEC filing date, issuer identity, completeness and source cutoff are independently required", () => {
  for (const mutate of [
    (b) => { b.documents[0].submissionBinding.filed = "2026-09-06"; },
    (b) => { b.documents[0].availableDate = "2026-09-06"; },
    (b) => { b.documents[0].url = "https://www.sec.gov/Archives/edgar/data/1/wrong.htm"; },
    (b) => { b.documents.pop(); },
    (b) => { b.historicalApproval = true; }
  ]) { const f = sourceFixture(); mutate(f.binding); assert.equal(auditTbbbSourceBindings(f.binding, f).status, "fail"); }
});
