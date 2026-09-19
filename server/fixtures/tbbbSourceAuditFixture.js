import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { tbbbCurrentAuditFixture } from "./tbbbCurrentAuditFixture.js";
import { TBBB_CURRENT_MODEL_FILES } from "../tbbbCurrentSnapshot.js";

// Synthetic byte fixtures for mutation testing only. Actual-source replay is
// separately run by the CLI against the private frozen SEC/official bundle.
export function tbbbSourceAuditFixture() {
  const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
  const root = new URL("../../", import.meta.url), files = new Map();
  const names = ["server/config/tbbb-economic-evidence.json", "server/config/tbbb-underwriting-2026-09-05.json"];
  const configs = names.map((path) => JSON.parse(readFileSync(new URL(path, root))));
  const [economicEvidence] = configs;
  const allInput = tbbbCurrentAuditFixture();
  function bind(path, value) {
    const bytes = Buffer.from(value); files.set(path, bytes);
    return { path, byteLength: bytes.length, sha256: hash(bytes) };
  }
  const configBindings = names.map((path) => bind(fileURLToPath(new URL(path, root)), readFileSync(new URL(path, root))));
  const sources = new Map(configs.flatMap((c) => Object.values(c.sources)).map((s) => [s.url, s]));
  const fakeRows = economicEvidence.financialPeriods.flatMap((p) => Object.entries(p.values)
    .map(([metric, value]) => `${p.id} ${metric} ${value.toLocaleString("en-US")}`));
  for (const o of allInput.financialTrendEvidence.observations) for (const p of [o, o.comparator]) {
    fakeRows.push(`${p.periodEndDate} Total revenue ${Math.round(p.revenueM * 1000).toLocaleString("en-US")}`);
  }
  const documents = [...sources.values()].map((s, index) => ({ ...s,
    ...bind(`/synthetic-TBBB-doc-${index}`, `<html><table>${fakeRows.map((r) => `<tr><td>${r}</td></tr>`).join("")}</table></html>`),
    sourceAuthority: s.url.includes("www.sec.gov") ? "issuer_SEC" : "official_macro",
    submissionBinding: { accession: `test-${index}`, filed: s.availableDate, acceptedAt: `${s.availableDate}T20:30:00Z` } }));
  const documentMap = new Map(documents.map((d) => [d.url, d]));
  const binding = { schemaVersion: "tbbb-source-binding-v1", sourceCutoff: "2026-09-05", historicalApproval: false,
    documents, configBindings, submissionIndexBinding: bind("/synthetic-TBBB-index", JSON.stringify({ filings: { recent: {
      accessionNumber: documents.map((d) => d.submissionBinding.accession),
      filingDate: documents.map((d) => d.submissionBinding.filed),
      acceptanceDateTime: documents.map((d) => d.submissionBinding.acceptedAt)
    } } })) };
  const sourceBundleJson = JSON.stringify(binding);
  const financialFacts = economicEvidence.financialPeriods.flatMap((p) => Object.entries(p.values).map(([metric, value]) => {
    const source = economicEvidence.sources[p.sourceId], doc = documentMap.get(source.url);
    return { periodId: p.id, periodStartDate: p.periodStartDate, periodEndDate: p.periodEndDate,
      availableDate: source.availableDate, metric, value, unit: "MXN_thousand", url: source.url,
      sourceSha256: doc.sha256, sourceRow: `${p.id} ${metric} ${value.toLocaleString("en-US")}` };
  }));
  const review = { schemaVersion: "tbbb-current-source-fact-review-v1", sourceCutoff: "2026-09-05",
    historicalEconomicApproval: false, bindingSha256: hash(sourceBundleJson), financialFacts,
    sourcePassageChecks: documents.map((d, i) => ({ sourceId: `test${i}`, url: d.url, availableDate: d.availableDate, sourceSha256: d.sha256 })),
    macroObservations: [{ testOnly: 1 }, { testOnly: 2 }, { testOnly: 3 }] };
  const growthDoc = documentMap.get(economicEvidence.sources.q2release2026.url);
  review.growthFacts = allInput.financialTrendEvidence.observations.flatMap((o) => [["current", o], ["comparator", o.comparator]].map(([role, p]) => ({
    observationPeriod: o.periodEndDate, role, periodEndDate: p.periodEndDate, revenueM: p.revenueM,
    currency: "MXN", rawUnit: "MXN_thousand", rawValueK: Math.round(p.revenueM * 1000),
    sourceRow: `${p.periodEndDate} Total revenue ${Math.round(p.revenueM * 1000).toLocaleString("en-US")}`,
    sourceAvailableDate: growthDoc.availableDate, providerAvailableDate: p.availableDate,
    url: growthDoc.url, sourceSha256: growthDoc.sha256
  })));
  const sourceReviewJson = JSON.stringify(review);
  const input = Object.fromEntries(["economicInput", "financialTrendPct", "financialTrendEvidence", "growthPolicySettings", "fx"].map((k) => [k, allInput[k]]));
  const modelBindings = TBBB_CURRENT_MODEL_FILES.map((path) => ({ path, sha256: hash(readFileSync(new URL(path, root))) }));
  return { input, sourceBundleJson, sourceReviewJson, economicEvidence, binding, review, files,
    trust: { inputSha256: hash(JSON.stringify(input)), sourceBundleSha256: hash(sourceBundleJson), sourceReviewSha256: hash(sourceReviewJson),
      fullModelSignature: hash(JSON.stringify(modelBindings)) },
    readSource: (path) => { if (!files.has(path)) throw new Error("missing synthetic test source"); return files.get(path); } };
}
