import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { auditReviewedShareCount } from "./reviewedShareCountAudit.js";
import { createGuruValuationUniverse, GURU_VALUATION_PROFILE_NAMES } from "./guruValuationUniverse.js";

const manifestPath = fileURLToPath(new URL("./config/guru-valuation-reviewed-batch.json", import.meta.url));
const root = path.dirname(path.dirname(manifestPath));
const repo = path.resolve(root, "..");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const company = (ticker) => structuredClone(manifest.companies.find((row) => row.ticker === ticker));

function correctedFixture(ticker) {
  const reviewedCompany = company(ticker);
  const correction = reviewedCompany.inputCorrections[0];
  const rows = correction.dimensions.map((dimension) => ({
    ticker, fiscal_period: correction.fiscalPeriod, dimension,
    available_at: correction.expectedRecordAvailableDate,
    report_period: correction.periodEndDate, currency: correction.currency,
    payload_json: JSON.stringify({
      ticker, asOfDate: correction.expectedRecordAvailableDate,
      periodEndDate: correction.periodEndDate, financialStatementCurrency: correction.currency,
      sourceDimension: dimension, shares_m: correction.expectedOriginalValue,
      sourceRecord: {
        rawShareCounts: { sharesbas: correction.expectedOriginalValue * 1e6 },
        dimension, sourceTicker: ticker, reportperiod: correction.periodEndDate,
        datekey: correction.expectedRecordAvailableDate, modelCurrency: correction.currency,
        currency: correction.currency, appliedShareFactor: 1, sharefactor: 1,
        shareCountPolicy: "Period-end basic shares are the equity-value denominator."
      },
      sources: { shares_m: {
        dataset: "Jansen Sharadar SF1 as-reported", tag: "sharesbas",
        filed: correction.expectedRecordAvailableDate, end: correction.periodEndDate
      } }
    })
  }));
  const python = [
    "import json,sys",
    "sys.path.insert(0,'scripts')",
    "from guru_reviewed_input_corrections import apply_reviewed_input_corrections",
    "x=json.load(sys.stdin)",
    "print(json.dumps(apply_reviewed_input_corrections(x['company'], x['rows'])))"
  ].join("\n");
  const result = JSON.parse(execFileSync("python3", ["-c", python], {
    cwd: repo, encoding: "utf8", input: JSON.stringify({ company: reviewedCompany, rows })
  }));
  const payload = JSON.parse(result.at(-1).payload_json);
  return {
    ticker, fiscalPeriod: correction.fiscalPeriod, reviewedCompany,
    sourceRecord: payload.sourceRecord, financialShareSource: payload.sources.shares_m,
    scoreSharesM: payload.shares_m, financialSharesM: payload.shares_m,
    trailingSharesM: payload.shares_m, asOfDate: correction.expectedRecordAvailableDate
  };
}

test("bounded review covers sixteen explicit issuers but approves only three", () => {
  assert.deepEqual(manifest.companies.map((row) => row.ticker).sort(),
    ["ALK", "CBRS", "CPA", "CROX", "ELF", "EQNR", "IOT", "POWL", "QNT", "SFIX", "SOFI", "SPOT", "TFX", "UPST", "USFD", "WIX"]);
  const universe = createGuruValuationUniverse(manifest);
  assert.deepEqual(universe.companyTickers(), ["CROX", "POWL", "SOFI"]);
  assert.equal(universe.summary().unreviewedCompanyCount, 13);
  assert.equal(universe.valuationProfile("POWL"), "industrial_growth");
  assert.equal(universe.valuationProfile("CROX"), "consumer_cyclical");
  assert.equal(universe.valuationProfile("SOFI"), "bank");
  for (const row of manifest.companies) {
    assert.equal(row.identityReviewStatus, "reviewed");
    assert.equal(row.security.ordinarySharesPerQuotedSecurity, 1);
    assert.equal(row.currency, "USD");
    assert.equal(row.reportingCurrency, row.ticker === "SPOT" ? "EUR" : "USD");
    assert.ok(row.identityEvidence.some((item) => item.availableDate <= manifest.financialCutoff));
    assert.ok(row.identityEvidence.every((item) => item.url.startsWith("https://") && item.locator && item.evidence));
    assert.ok(row.economicReview.nextAction && row.economicReview.cashFlowBasis);
    if (row.reviewStatus === "reviewed") {
      assert.deepEqual(row.economicReview.releaseBlockers, []);
      assert.ok(GURU_VALUATION_PROFILE_NAMES.includes(row.valuationProfile));
    } else {
      assert.ok(row.economicReview.releaseBlockers.length > 0);
      assert.equal(universe.companyForTicker(row.ticker), null);
    }
  }
});

test("IPO/Up-C claims and foreign cash-flow issues are not silently activated", () => {
  assert.equal(company("CBRS").reviewDisposition, "requires_special_model");
  assert.equal(company("QNT").security.type, "class_a_common_stock_up_c");
  assert.ok(company("QNT").economicReview.releaseBlockers.includes("up_c_claims_and_parent_attribution"));
  assert.equal(company("SPOT").security.type, "ordinary_share");
  assert.equal(company("EQNR").security.type, "american_depositary_share");
  assert.equal(company("CPA").security.type, "class_a_common_share");
  assert.ok(company("SPOT").economicReview.releaseBlockers.includes("historical_period_specific_economic_reconciliation_not_completed"));
  assert.equal(company("SPOT").currentModelReview.genericHistoryApproved, false);
  assert.equal(company("SPOT").currentModelReview.asOfDate, "2026-09-05");
});

test("independent JS audit accepts actual Python correction output and hashes", () => {
  for (const ticker of ["CROX", "SOFI"]) {
    const result = auditReviewedShareCount(correctedFixture(ticker));
    assert.equal(result.applies, true);
    assert.deepEqual(result.failures, []);
    assert.equal(result.ok, true);
  }
});

test("unapproved or wrong-period payload overrides fail even with self-consistent provenance", () => {
  for (const update of [
    { reviewedCompany: null }, { reviewedCompany: { ...company("CROX"), reviewStatus: "unreviewed" } },
    { fiscalPeriod: "2026-Q1" }, { ticker: "ANOTHER" }
  ]) {
    const result = auditReviewedShareCount({ ...correctedFixture("CROX"), ...update });
    assert.equal(result.ok, false);
    assert.ok(result.failures.length);
  }
});

test("removing lineage cannot evade a correction mandated by the approved manifest", () => {
  const input = correctedFixture("CROX");
  delete input.sourceRecord.reviewedInputCorrections;
  input.sourceRecord.shareCountBasis = "sharesbas";
  input.scoreSharesM = 47.945075;
  assert.equal(auditReviewedShareCount(input).ok, false);
});

test("independent review rejects forged originals, hashes, factors, dates and currency", () => {
  const changes = [
    (x) => { x.sourceRecord.rawShareCounts.sharesbas += 1000; },
    (x) => { x.sourceRecord.appliedShareFactor = 0.5; },
    (x) => { x.sourceRecord.sharefactor = 3; },
    (x) => { x.sourceRecord.reviewedInputCorrections[0].value = 48.1; },
    (x) => { x.sourceRecord.reviewedInputCorrections[0].correctionSha256 = "a".repeat(64); },
    (x) => { x.sourceRecord.reviewedInputCorrections[0].originalValue = 48; },
    (x) => { x.sourceRecord.reviewedInputCorrections.push(x.sourceRecord.reviewedInputCorrections[0]); },
    (x) => { x.sourceRecord.reportperiod = "2026-03-31"; },
    (x) => { x.sourceRecord.datekey = "2026-07-29"; },
    (x) => { x.sourceRecord.currency = "MXN"; },
    (x) => { x.sourceRecord.dimension = "MRQ"; },
    (x) => { x.sourceRecord.sourceTicker = "CROX.L"; },
    (x) => { x.asOfDate = "2026-07-29"; },
    (x) => { x.asOfDate = "2026-99-99"; },
    (x) => { x.financialShareSource.url = "https://example.com/claim"; },
    (x) => { x.financialShareSource.precisionShares = 1; },
    (x) => { x.financialSharesM = 47.945075; },
    (x) => { x.scoreSharesM = 47.945075; },
    (x) => { x.trailingSharesM = 47.945075; }
  ];
  const base = correctedFixture("CROX");
  for (const change of changes) {
    const input = structuredClone(base);
    change(input);
    assert.equal(auditReviewedShareCount(input).ok, false, change.toString());
  }
});

test("uncorrected unrelated issuers continue through the original raw-share audit", () => {
  assert.deepEqual(auditReviewedShareCount({ ticker: "POWL", fiscalPeriod: "2026-Q3", reviewedCompany: company("POWL") }),
    { applies: false, ok: true, failures: [] });
  assert.deepEqual(auditReviewedShareCount({ ticker: "AAPL", fiscalPeriod: "2026-Q2", reviewedCompany: null }),
    { applies: false, ok: true, failures: [] });
});

test("SOFI financial route excludes arbitrary loan cash and stock-market prices", () => {
  const source = `
    import assert from 'node:assert/strict';
    import {buildValuationRows, profileSettings} from './server/importSecQuarterlyValuations.js';
    assert.equal(profileSettings('SOFI').profile, 'bank');
    const build = (cash, price) => buildValuationRows({
      ticker:'SOFI',trinityTicker:'SOFI',snapshot:{ticker:'SOFI',name:'SoFi',currency:'USD',priceHistory:[{date:'2026-08-06',close:price,source:'synthetic'}]},
      companyModel:{ticker:'SOFI',company:'SoFi'},factsUrl:'https://www.sec.gov/',
      quarterlyRows:Array.from({length:8},(_,i)=>({fiscalYear:2024+Math.floor(i/4),fiscalQuarter:'Q'+(i%4+1),
        label:'fixture',asOfDate:(2024+Math.floor(i/4))+'-'+String((i%4)*3+2).padStart(2,'0')+'-15',
        revenue_m:1000,revenue_growth_pct:10,operating_income_m:200,net_income_m:150,cfo_m:cash,
        capex_m:50,shares_m:1290.312404,equity_m:11076.227,cash_m:100000,debt_m:90000,sources:{}})),
      youtubeByPeriod:new Map(),financialSource:{sourceName:'synthetic',modelVersion:'fixture'}
    }).at(-1);
    const a=build(-100000,1), b=build(100000,1000);
    assert.ok(a.fairValue>0);assert.equal(a.fairValue,b.fairValue);
    assert.equal(a.dataSnapshot.valuationSemantics.scoreInputs.modelRoute,'financial_institution');
    assert.equal(a.methodOutputs.some(row=>row.key==='fcfe-dcf'),false);
  `;
  execFileSync(process.execPath, ["--input-type=module", "-e", source], {
    cwd: repo, encoding: "utf8", env: { ...process.env, GURU_VALUATION_UNIVERSE_PATH: manifestPath }
  });
});
