import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { buildSpotCurrentSnapshot, spotCurrentModelSignature } from "./spotCurrentSnapshot.js";
import { exactStatementRow, auditSpotCurrentSource } from "./spotCurrentSourceAudit.js";

const hash = (raw) => createHash("sha256").update(raw).digest("hex");
const configRaw = readFileSync(new URL("./config/guru-current-economic-evidence.json", import.meta.url));
const c = JSON.parse(configRaw).companies.SPOT;
const table = (rows) => `<table>${rows.map(([label, ...values]) => `<tr><td>${label}</td>${values.map((v) => `<td>${v}</td>`).join("")}</tr>`).join("")}</table>`;
function fixture() {
  // Synthetic source fixtures exercise the mechanism; real source bytes are
  // separately replayed by the immutable offline candidate command.
  const files = new Map();
  const sources = { ...c.sources, q32026_guidance: { availableDate: "2026-08-04",
    url: "https://www.sec.gov/Archives/edgar/data/1639920/000114036126031044/ef20078867_ex99-1.htm" } };
  const documents = [], recent = { accessionNumber: [], filingDate: [], acceptanceDateTime: [], form: [] };
  for (const [sourceId, s] of Object.entries(sources)) {
    const short = s.url.split("/").at(-2), accession = `${short.slice(0, 10)}-${short.slice(10, 12)}-${short.slice(12)}`;
    const acceptedAt = `${s.availableDate}T08:00:00Z`, form = sourceId === "fy2025" ? "20-F" : "6-K";
    recent.accessionNumber.push(accession); recent.filingDate.push(s.availableDate); recent.acceptanceDateTime.push(acceptedAt); recent.form.push(form);
    let html = "<p>Consolidated statement of cash flows (in € millions)</p>";
    if (["fy2025", "h12026"].includes(sourceId)) {
      const p = sourceId === "fy2025" ? c.periods.fy2025 : c.periods.h12026;
      const prior = sourceId === "fy2025" ? { cfoM: 2301, cashPpeM: 17, leasePrincipalM: 69, sbcM: 267, managementCapexM: 17, restrictedCashReleaseM: 1 } : c.periods.h12025;
      html += table([["cfoM", "Net cash flows from operating activities", 1], ["cashPpeM", "Purchases of property and equipment", -1],
        ["leasePrincipalM", "Payments of lease liabilities", -1], ["sbcM", "Share-based compensation expense", 1],
        ["managementCapexM", "Capital expenditures", -1], ["restrictedCashReleaseM", "Change in restricted cash", 1]]
        .map(([key, label, sign]) => [label, 17, sign * p[key], sign * prior[key], ...(sourceId === "fy2025" ? [0] : [])]));
    }
    if (sourceId === "fy2025") html += "<p>209,485,215 ordinary shares; 3,652,688 treasury.</p>";
    if (sourceId === "h12026") html += "<p>As of June 30, 2026 and December 31, 2025, the Company had 210,241,268 and 209,485,215 ordinary shares issued and fully paid, respectively, with 4,657,063 and 3,652,688 ordinary shares held as treasury shares. Other awards 4,496,814 and 1,456,016. Exchangeable Notes 15, 19 — 1,458</p>" + table([["Exercisable at June 30, 2026", 2789877, 171.61]]);
    if (sourceId === "q12026") html += "<p>As of March 31, 2026 and December 31, 2025, the Company had 209,741,268 and 209,485,215 ordinary shares issued and fully paid, respectively, with 4,121,207 and 3,652,688 ordinary shares held as treasury shares.</p>";
    if (sourceId === "q32026_guidance") html = "Outlook for Q3'26 Spotify expectations for Q3 2026 as of August 4, 2026. Total Revenue €5.0 billion. Operating Income €670 million. Webcast Information";
    const raw = Buffer.from(html), path = `/virtual/${sourceId}.html`;
    files.set(path, raw); documents.push({ sourceId, ...s, path, sha256: hash(raw), byteLength: raw.length,
      submissionBinding: { accession, filed: s.availableDate, acceptedAt, form } });
  }
  const sub = Buffer.from(JSON.stringify({ filings: { recent } })); files.set("/virtual/submission.json", sub);
  const bundle = { ticker: "SPOT", asOfDate: "2026-09-05", historicalApproval: false,
    configBinding: { sha256: hash(configRaw) }, submissionIndexBinding: { path: "/virtual/submission.json", sha256: hash(sub) }, documents };
  const fx = { sourceCurrency: "EUR", targetCurrency: "USD", sourceRateDate: "2026-08-04", targetRateDate: "2026-08-04",
    sourceUnitsPerEur: 1, targetUnitsPerEur: 1.1515, conversionRate: 1.1515, sourceUrl: "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?format=csvdata" };
  const saved = { asOfDate: "2026-09-05", historicalApproval: false, input: { ticker: "SPOT", asOfDate: "2026-09-05",
    financial: { ticker: "SPOT", sourceDimension: "ART", periodEndDate: "2026-06-30", asOfDate: "2026-08-04", financialStatementCurrency: "USD", sourceFinancialStatementCurrency: "EUR",
      revenue_m: 20857.1195, cfo_m: 3842.5555, capex_m: 80.605, fcf_after_capex_m: 3761.9505, shares_m: 205.788241,
      sourceRecord: { sourceTicker: "SPOT", dimension: "ART", reportperiod: "2026-06-30", datekey: "2026-08-04", sourceCurrency: "EUR", modelCurrency: "USD", currencyScale: 1.1515,
        appliedShareFactor: 1, sharefactor: 1, rawShareCounts: { sharesbas: 205788241 }, fxConversion: fx } },
    fxRecords: [{ currency: "USD", rate_date: "2026-09-04", units_per_eur: 1.1622, source_url: "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?format=csvdata" }] },
    quote: { source: "sharadar-paid-api-split-adjusted", priceSymbol: "SPOT", quoteCurrency: "USD", comparisonOnly: true,
      originalRecord: { ticker: "SPOT", date: "2026-09-04", close: 250 }, quotedSecurityMetadata: { table: "SEP", ticker: "SPOT", currency: "USD",
        permaticker: 120226, exchange: "NYSE", cusips: "L8681T102", secfilings: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=0001639920", firstpricedate: "2018-04-03", lastupdated: "2026-08-19" } } };
  const args = () => { const inputJson = JSON.stringify(saved), sourceBundleJson = JSON.stringify(bundle); return { inputJson, sourceBundleJson,
    trust: { inputSha256: hash(inputJson), sourceBundleSha256: hash(sourceBundleJson), modelSignature: spotCurrentModelSignature() }, readSource: (path) => files.get(path) }; };
  return { saved, bundle, files, args };
}

test("statement owner, accounting signs and note columns are retained", () => {
  assert.deepEqual(exactStatementRow(table([["Cash PPE", 11, "( 61 )", "(17)", "(6)"]]), "Cash PPE", 3), [-61, -17, -6]);
  assert.throws(() => exactStatementRow(table([["Wrong owner", 61, 17, 6]]), "Cash PPE", 3));
  assert.throws(() => exactStatementRow(table([["Cash PPE", 61, 17], ["Cash PPE", 62, 17]]), "Cash PPE", 2));
});
test("one normal current point, explicit guidance scope, bilingual cautions and no invented 3Y target", () => {
  const result = buildSpotCurrentSnapshot(fixture().args());
  assert.equal(result.status, "current_only_snapshot_candidate", JSON.stringify(result));
  assert.equal(result.snapshot.history.length, 1); assert.equal(result.snapshot.latest.targetPrice3Y, null);
  assert.equal(result.releaseReady, false); assert.equal(result.snapshot.dataQuality.historicalCurveAuthorized, false);
  assert.equal(result.audit.sourceAudit.guidanceReview.scope, "quarter");
  assert.equal(result.audit.sourceAudit.guidanceReview.includedInParentFcfeInputs, false);
  assert.ok(result.snapshot.warningTranslations.every((w) => w.en && w.zh));
});
test("comparison-price change alters gap only, never fair value, input or FCFE", () => {
  const f = fixture(), before = buildSpotCurrentSnapshot(f.args()); f.saved.quote.originalRecord.close = 300;
  const after = buildSpotCurrentSnapshot(f.args());
  assert.equal(before.snapshot.latest.baseFairValue, after.snapshot.latest.baseFairValue);
  assert.deepEqual(before.modelRuns[0].input, after.modelRuns[0].input);
  assert.notEqual(before.snapshot.latest.upsideToBase, after.snapshot.latest.upsideToBase);
  assert.equal(after.snapshot.latest.upsideToBase, after.snapshot.latest.baseFairValue / 300 - 1);
});
test("mutated source bytes fail even when the source bundle is unchanged", () => {
  const f = fixture(); f.files.set("/virtual/h12026.html", Buffer.from("altered"));
  assert.equal(buildSpotCurrentSnapshot(f.args()).reason, "independent_original_source_audit_failed");
});
test("repinning altered statement amounts does not hide a broken original cash bridge", () => {
  const f = fixture(), d = f.bundle.documents.find((d) => d.sourceId === "h12026");
  const raw = Buffer.from(f.files.get(d.path).toString().replace(">1652<", ">1653<"));
  f.files.set(d.path, raw); d.sha256 = hash(raw); d.byteLength = raw.length;
  const result = buildSpotCurrentSnapshot(f.args());
  assert.equal(result.reason, "independent_original_source_audit_failed");
});
for (const [name, mutate] of [
  ["wrong source currency", (f) => { f.saved.input.financial.sourceFinancialStatementCurrency = "USD"; }],
  ["historical relabel", (f) => { f.saved.asOfDate = "2026-08-04"; }],
  ["wrong share-class quote", (f) => { f.saved.quote.quotedSecurityMetadata.cusips = "000000000"; }],
  ["missing quote date provenance", (f) => { delete f.saved.quote.quotedSecurityMetadata.firstpricedate; }],
  ["future metadata", (f) => { f.saved.quote.quotedSecurityMetadata.lastupdated = "2026-09-06"; }],
  ["wrong source publication date", (f) => { f.bundle.documents[0].availableDate = "2026-02-11"; }],
]) test(`rejects ${name}`, () => { const f = fixture(); mutate(f); assert.equal(buildSpotCurrentSnapshot(f.args()).status, "blocked"); });
test("missing external trust and model changes cannot self-authorize", () => {
  const f = fixture(), a = f.args(); delete a.trust.inputSha256;
  assert.equal(buildSpotCurrentSnapshot(a).status, "blocked");
  a.trust = { ...f.args().trust, modelSignature: "0".repeat(64) };
  assert.equal(buildSpotCurrentSnapshot(a).status, "blocked");
});
