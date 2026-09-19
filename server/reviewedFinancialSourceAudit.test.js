import assert from "node:assert/strict";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { auditReviewedFinancialSource } from "./reviewedFinancialSourceAudit.js";

const repo = fileURLToPath(new URL("../", import.meta.url));
function fixture() {
  const base = { ticker: "CRDO", asOfDate: "2022-03-10", periodEndDate: "2022-01-31", sourceDimension: "ART",
    financialStatementCurrency: "USD", cfo_m: null, capex_m: null, fcf_after_capex_m: null, revenue_m: null,
    sourceRecord: { dimension: "ART", sourceTicker: "CRDO", reportperiod: "2022-01-31", datekey: "2022-03-10",
      modelCurrency: "USD", currency: "USD", currencyScale: 1, appliedShareFactor: 1 },
    sources: { cfo_m: { dataset: "synthetic original provider", tag: "ncfo" }, capex_m: { tag: "capex" } } };
  const json = JSON.stringify(base);
  const rawHash = crypto.createHash("sha256").update(json).digest("hex");
  const reviewedCompany = { ticker: "CRDO", cik: "0001807794", currency: "USD", reviewStatus: "reviewed",
    reviewedAt: "2026-09-06", economicReview: { releaseBlockers: [] }, inputCorrections: [] };
  for (const [field, value] of [["cfo_m", -10], ["capex_m", 2], ["fcf_after_capex_m", -12], ["revenue_m", 20]]) {
    const url = "https://www.sec.gov/Archives/edgar/data/1807794/fixture/filing.htm";
    reviewedCompany.inputCorrections.push({ id: `synthetic-${field}`, fiscalPeriod: "2022-Q3", field, value,
      unit: "million_reporting_currency", currency: "USD", dimensions: ["ART"], expectedOriginalValue: null,
      periodEndDate: "2022-01-31", sourceAvailableDate: "2022-03-10", expectedRecordAvailableDate: "2022-03-10",
      sourceUrl: url, sourceLocator: "Synthetic original SEC statement exact line", reason: "Synthetic missing ART reconstruction",
      sourcePrecisionM: 0.001, precisionPolicy: "USD thousands; exact arithmetic, no widened tolerance",
      expectedOriginalPayloadSha256ByDimension: { ART: rawHash },
      sourceComponents: [{ url, sha256: "a".repeat(64), locator: "Synthetic monetary fact", valueM: value,
        multiplier: 1, currency: "USD", availableDate: "2022-03-10", periodEndDate: "2022-01-31" }] });
  }
  const rows = [{ ticker: "CRDO", fiscal_period: "2022-Q3", dimension: "ART", available_at: "2022-03-10",
    report_period: "2022-01-31", currency: "USD", payload_json: json }];
  const script = "import sys,json;sys.path.insert(0,'scripts');from guru_reviewed_input_corrections import apply_reviewed_input_corrections;x=json.load(sys.stdin);print(json.dumps(apply_reviewed_input_corrections(x['company'],x['rows'])))";
  const corrected = JSON.parse(execFileSync("python3", ["-c", script], { cwd: repo, encoding: "utf8", input: JSON.stringify({ company: reviewedCompany, rows }) }));
  const financial = JSON.parse(corrected[0].payload_json);
  return { ticker: "CRDO", fiscalPeriod: "2022-Q3", asOfDate: "2022-03-10", reviewedCompany,
    financial, sourceRecord: financial.sourceRecord, financialSources: financial.sources };
}

test("actual Python output independently reconstructs raw null fields and exact approved values", () => {
  const result = auditReviewedFinancialSource(fixture());
  assert.equal(result.applies, true);
  assert.equal(result.correctionCount, 4);
  assert.deepEqual(result.failures, []);
});

test("economic reported originals are checked against trusted values, not trusted merely for being marked original", () => {
  const x = fixture();
  x.financial.reported_fcf_after_capex_m = -12;
  x.financial.fcf_after_capex_m = -17;
  x.financial.reported_operating_financials = { revenue_m: 20 };
  x.financial.revenue_m = 21;
  assert.equal(auditReviewedFinancialSource(x).ok, true);
  x.financial.reported_operating_financials.revenue_m = 21;
  assert.equal(auditReviewedFinancialSource(x).ok, false);
});

test("self-consistent falsified original payload/hash cannot replace approved raw input", () => {
  const x = fixture();
  const saved = x.sourceRecord.reviewedOriginalFinancialPayload;
  const raw = JSON.parse(saved.json);
  raw.cfo_m = 0;
  saved.json = JSON.stringify(raw);
  saved.sha256 = crypto.createHash("sha256").update(saved.json).digest("hex");
  x.sourceRecord.reviewedInputCorrections[0].originalValue = 0;
  assert.equal(auditReviewedFinancialSource(x).ok, false);
});

test("removal, forgery, changed values and future dates fail the independent audit", () => {
  const changes = [
    (x) => { delete x.sourceRecord.reviewedInputCorrections; },
    (x) => { delete x.sourceRecord.reviewedOriginalFinancialPayload; },
    (x) => { x.sourceRecord.reviewedInputCorrections[0].correctionSha256 = "a".repeat(64); },
    (x) => { x.sourceRecord.reviewedInputCorrections[0].originalSource = { tag: "wrong" }; },
    (x) => { x.sourceRecord.reviewedInputCorrections.push(x.sourceRecord.reviewedInputCorrections[0]); },
    (x) => { x.sourceRecord.dimension = "ARQ"; },
    (x) => { x.sourceRecord.currency = "EUR"; },
    (x) => { x.sourceRecord.currencyScale = 2; },
    (x) => { x.sourceRecord.sourceTicker = "NVDA"; },
    (x) => { x.asOfDate = "2022-03-09"; },
    (x) => { x.financial.cfo_m += .001; },
    (x) => { x.financialSources.capex_m.precisionM = 1; },
    (x) => { x.financialSources.capex_m.sourceComponents[0].locator = "wrong"; },
    (x) => { x.reviewedCompany.reviewStatus = "unreviewed"; },
    (x) => { x.reviewedCompany.economicReview.releaseBlockers.push("pending"); },
  ];
  for (const change of changes) {
    const x = fixture(); change(x);
    assert.equal(auditReviewedFinancialSource(x).ok, false, change.toString());
  }
});

test("invalid trusted component arithmetic, CIK, dates and currencies are independently checked", () => {
  for (const [key, value] of [["valueM", -9.999], ["currency", "EUR"], ["availableDate", "2023-01-01"],
    ["sha256", "bad"], ["url", "https://www.sec.gov/Archives/edgar/data/1/wrong.htm"]]) {
    const x = fixture();
    x.reviewedCompany.inputCorrections[0].sourceComponents[0][key] = value;
    assert.equal(auditReviewedFinancialSource(x).ok, false);
  }
});

test("unrelated issuers or uncorrected dimensions are not rejected", () => {
  assert.deepEqual(auditReviewedFinancialSource({ ticker: "OTHER", fiscalPeriod: "2022-Q3", reviewedCompany: null }), { applies: false, ok: true, failures: [] });
  const x = fixture();
  x.sourceRecord = { dimension: "ARQ" };
  assert.deepEqual(auditReviewedFinancialSource(x), { applies: false, ok: true, failures: [] });
});
