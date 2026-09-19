import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { buildTbbbCurrentSnapshotCandidate as build } from "./tbbbCurrentSnapshot.js";
import { auditTbbbReviewedSourceFacts } from "./tbbbUnderwrittenValuationAudit.js";
import { tbbbSourceAuditFixture } from "./fixtures/tbbbSourceAuditFixture.js";

const hash = (raw) => createHash("sha256").update(raw).digest("hex");
const quote = (close) => {
  const originalRecord = { ticker: "TBBB", date: "2026-09-04", close, currency: "USD" };
  return { priceSymbol: "TBBB", priceDate: "2026-09-04", quoteCurrency: "USD", declaredSource: "sharadar-paid-api-split-adjusted",
    candidates: [{ id: "test-original", date: "2026-09-04", priceSymbol: "TBBB", quoteCurrency: "USD", close,
      source: "sharadar-paid-api-split-adjusted", sourceField: "close", unit: "currency_per_share", kind: "original_vendor",
      originalRecord, originalRecordSha256: hash(JSON.stringify(originalRecord)) }] };
};
const withQuote = (fixture, price) => ({ ...fixture, comparisonPrice: price,
  trust: { ...fixture.trust, comparisonPriceSha256: hash(JSON.stringify(price)) } });

function rawPaidQuoteWithoutCurrency() {
  const q = quote(20);
  delete q.candidates[0].originalRecord.currency;
  q.candidates[0].originalRecordSha256 = hash(JSON.stringify(q.candidates[0].originalRecord));
  const originalRecord = { table: "SEP", ticker: "TBBB", currency: "USD", permaticker: "641173",
    cusips: "G0896C103", exchange: "NYSE", firstpricedate: "2024-02-09", lastupdated: "2026-08-19",
    secfilings: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=0001978954" };
  q.quotedSecurityMetadata = { source: "jansen-sharadar-tickers", originalRecord,
    originalRecordSha256: hash(JSON.stringify(originalRecord)) };
  return q;
}

test("original daily-price bytes omit currency; exact SEP identity resolves it without changing raw quote", () => {
  const q = rawPaidQuoteWithoutCurrency();
  const result = build(withQuote(tbbbSourceAuditFixture(), q));
  assert.equal(result.status, "current_only_snapshot_candidate");
  const saved = result.modelRuns[0].priceObservation.payload;
  assert.deepEqual(saved.originalVendorEvidence[0].originalRecord, q.candidates[0].originalRecord);
  assert.equal(Object.hasOwn(saved.originalVendorEvidence[0].originalRecord, "currency"), false);
  assert.deepEqual(saved.quotedSecurityMetadata, q.quotedSecurityMetadata);
});

test("quote currency cannot be supplied by future/SF1/wrong-CUSIP/unbound security metadata", () => {
  for (const change of [
    (q) => { delete q.quotedSecurityMetadata; },
    (q) => { q.quotedSecurityMetadata.originalRecord.table = "SF1"; },
    (q) => { q.quotedSecurityMetadata.originalRecord.currency = "MXN"; },
    (q) => { q.quotedSecurityMetadata.originalRecord.ticker = "WMT"; },
    (q) => { q.quotedSecurityMetadata.originalRecord.cusips = "WRONG"; },
    (q) => { q.quotedSecurityMetadata.originalRecord.lastupdated = "2026-09-06"; },
    (q) => { q.quotedSecurityMetadata.originalRecord.firstpricedate = "2026-09-06"; },
    (q) => { q.quotedSecurityMetadata.originalRecord.secfilings = "https://example.test"; },
  ]) {
    const q = rawPaidQuoteWithoutCurrency(); change(q);
    if (q.quotedSecurityMetadata) q.quotedSecurityMetadata.originalRecordSha256 = hash(JSON.stringify(q.quotedSecurityMetadata.originalRecord));
    assert.equal(build(withQuote(tbbbSourceAuditFixture(), q)).status, "blocked");
  }
  const q = rawPaidQuoteWithoutCurrency(); q.quotedSecurityMetadata.originalRecordSha256 = "0".repeat(64);
  assert.equal(build(withQuote(tbbbSourceAuditFixture(), q)).status, "blocked");
});

test("typed normal snapshot contains one current node and no forecast years in history", () => {
  const result = build(tbbbSourceAuditFixture());
  assert.equal(result.status, "current_only_snapshot_candidate", JSON.stringify(result));
  const snapshot = result.snapshot;
  assert.equal(snapshot.ticker, "TBBB");
  assert.equal(snapshot.history.length, 1);
  assert.equal(snapshot.history[0].asOfDate, "2026-09-05");
  assert.equal(snapshot.history[0].fiscalPeriod, "2026-Q2");
  assert.equal(snapshot.dataQuality.historicalCurveAuthorized, false);
  assert.equal(snapshot.dataQuality.currentOnly, true);
  assert.equal(snapshot.dataQuality.releaseReady, false);
  assert.equal(result.releaseReady, false);
  assert.equal(snapshot.latest.targetPrice3Y, null);
  assert.equal(snapshot.latest.latestPrice, null);
  assert.equal(snapshot.scenarios[0].details.forecast.length, 5);
  assert.equal(result.modelRuns.length, 1);
  assert.equal(result.valuationRows.length, 1);
});

test("price metamorphism changes comparison fields only, not model inputs, fair values or future cash flows", () => {
  const f = tbbbSourceAuditFixture();
  const a = build(withQuote(f, quote(20)));
  const b = build(withQuote(f, quote(40)));
  assert.equal(a.status, "current_only_snapshot_candidate");
  assert.equal(b.status, "current_only_snapshot_candidate");
  assert.equal(a.snapshot.latest.baseFairValue, b.snapshot.latest.baseFairValue);
  assert.notEqual(a.snapshot.latest.upsideToBase, b.snapshot.latest.upsideToBase);
  assert.deepEqual(a.modelRuns[0].input, b.modelRuns[0].input);
  assert.deepEqual(a.snapshot.currentScenarioDetails, b.snapshot.currentScenarioDetails);
  for (let i = 0; i < 3; i++) assert.deepEqual(a.snapshot.scenarios[i].details, b.snapshot.scenarios[i].details);
  assert.equal(a.snapshot.latest.latestPrice, 20);
  assert.equal(b.snapshot.latest.latestPrice, 40);
});

test("downside null and bilingual financing/dilution cautions survive normal rendering", () => {
  const r = build(tbbbSourceAuditFixture()).snapshot;
  const downside = r.scenarios.find((x) => x.scenarioId === "downside");
  assert.equal(downside.fairValue, null);
  assert.ok(downside.fundingDeficitMxnM > 3800);
  assert.equal(downside.statisticalConfidenceInterval, false);
  assert.equal(downside.upsideDownside, null);
  assert.ok(r.warningTranslations.every((w) => w.en && w.zh));
  assert.match(r.warnings.join(" "), /not exact option fair value/);
  assert.match(r.warnings.join(" "), /not statistical confidence bounds/);
});

test("missing/truncated/changed reviewed digests cannot enter normal snapshot", () => {
  for (const field of ["inputSha256", "sourceBundleSha256", "sourceReviewSha256", "fullModelSignature"]) {
    const f = tbbbSourceAuditFixture(); f.trust[field] = "0".repeat(64);
    assert.equal(build(f).status, "blocked");
  }
  const f = tbbbSourceAuditFixture(); f.input.economicInput.sourceCfo += .1;
  assert.equal(build(f).status, "blocked");
});

test("changed source bytes, even with unchanged reviewed manifest, fail the source gate", () => {
  const f = tbbbSourceAuditFixture();
  f.files.set(f.binding.documents[0].path, Buffer.from("replaced issuer document"));
  assert.equal(build(f).status, "blocked");
});

test("source row review is not accepted solely because a caller sets its hash to match", () => {
  const f = tbbbSourceAuditFixture();
  f.review.financialFacts[0].sourceRow = "a fabricated revenue row 78,152,943";
  f.sourceReviewJson = JSON.stringify(f.review);
  f.trust.sourceReviewSha256 = hash(f.sourceReviewJson);
  assert.equal(build(f).status, "blocked");
});

test("paid comparison source/date/currency/record are required; no substitute ticker", () => {
  for (const change of [
    (q) => { q.priceSymbol = "WMT"; }, (q) => { q.quoteCurrency = "MXN"; },
    (q) => { q.priceDate = "2026-09-06"; }, (q) => { q.declaredSource = "arbitrary-paid-provider"; },
    (q) => { q.candidates[0].originalRecord.close += .01; }, (q) => { q.candidates[0].close = null; },
    (q) => { q.candidates[0].sourceField = "closeadj"; },
    (q) => { q.candidates[0].kind = "released_snapshot"; },
    (q) => { q.candidates[0].originalRecord.currency = "MXN"; },
    (q) => { q.candidates.push({ ...q.candidates[0], id: "conflicting-same-series", close: 20.1 }); }
  ]) { const q = quote(20); change(q); assert.equal(build(withQuote(tbbbSourceAuditFixture(), q)).status, "blocked"); }
});

test("price evidence needs a separately pinned digest even when source contract and fields are valid", () => {
  const f = tbbbSourceAuditFixture();
  assert.equal(build({ ...f, comparisonPrice: quote(20) }).status, "blocked");
  const request = withQuote(f, quote(20)); request.trust.comparisonPriceSha256 = "0".repeat(64);
  assert.equal(build(request).status, "blocked");
});

test("upside uses normal snapshot ratio units: ten percent is 0.10, not 10", () => {
  const f = tbbbSourceAuditFixture();
  const fair = build(f).snapshot.latest.baseFairValue;
  const s = build(withQuote(f, quote(fair / 1.1))).snapshot;
  for (const value of [s.latest.upsideToBase, s.history[0].upsideDownside, s.scenarios[0].upsideDownside]) {
    assert.ok(Math.abs(value - .1) < 1e-12);
  }
});

test("adapter is deterministic, does not mutate caller data, and never grants historical approval", () => {
  const f = tbbbSourceAuditFixture(), inputBefore = structuredClone(f.input);
  const a = build(f), b = build(f);
  assert.deepEqual(a, b); assert.deepEqual(f.input, inputBefore);
  assert.equal(a.snapshot.history[0].dataSnapshot.valuationSemantics.historicalCurveAuthorized, false);
});

test("independent source facts require exact value/unit/period/URL/sha/raw row and complete uniqueness", () => {
  for (const change of [
    (r) => { r.financialFacts[0].value *= 1000; },
    (r) => { r.financialFacts[0].unit = "USD_million"; },
    (r) => { r.financialFacts[0].periodEndDate = "2026-06-30"; },
    (r) => { r.financialFacts[0].availableDate = "2026-09-06"; },
    (r) => { r.financialFacts[0].sourceSha256 = "0".repeat(64); },
    (r) => { r.financialFacts[0].url = "https://example.com"; },
    (r) => { r.financialFacts[0].sourceRow = "fabricated original row"; },
    (r) => { r.financialFacts[0] = r.financialFacts[1]; },
    (r) => { r.financialFacts.pop(); }
  ]) {
    const f = tbbbSourceAuditFixture(); change(f.review);
    assert.equal(auditTbbbReviewedSourceFacts(f.review, f.binding, f.economicEvidence, { read: f.readSource, input: f.input }).status, "fail");
  }
});
