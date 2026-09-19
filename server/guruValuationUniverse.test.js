import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  createGuruValuationUniverse,
  GURU_VALUATION_PROFILE_NAMES,
  loadGuruValuationUniverse
} from "./guruValuationUniverse.js";
import { valuationProfileNames } from "./importSecQuarterlyValuations.js";
import { sp500CompanyForTicker, sp500UniverseSummary } from "./sp500ValuationUniverse.js";

const fixturePath = fileURLToPath(new URL("./fixtures/guru-valuation-universe-reviewed.json", import.meta.url));
const fixture = () => JSON.parse(fs.readFileSync(fixturePath, "utf8"));

test("only reviewed Guru companies expose model profiles and identity metadata", () => {
  const universe = createGuruValuationUniverse(fixture());
  assert.deepEqual(universe.companyTickers(), ["REVIEW"]);
  assert.equal(universe.valuationProfile(" review.a "), "consumer_staples");
  assert.equal(universe.canonicalTicker("review.a"), "REVIEW");
  assert.equal(universe.companyForTicker("REVIEW").reportingCurrency, "MXN");
  assert.equal(universe.companyForTicker("PENDING"), null);
  assert.equal(universe.valuationProfile("PENDING"), null);
  assert.equal(universe.valuationProfile("UNRECOGNIZED"), null);
  assert.equal(universe.summary().unreviewedCompanyCount, 1);
  const copy = universe.companyForTicker("REVIEW");
  copy.identityEvidence[0].evidence = "modified";
  assert.notEqual(universe.companyForTicker("REVIEW").identityEvidence[0].evidence, "modified");
});

test("expected release set unions reviewed Guru issuers, S&P, and retained extras", () => {
  const universe = createGuruValuationUniverse(fixture());
  const expected = universe.expectedTickerSet(["EXTRA", "GOOG", "REVIEW.A", "REVIEW"]);
  assert.equal(expected.size, 502);
  assert.equal(expected.has("EXTRA"), true);
  assert.equal(expected.has("GOOGL"), true);
  assert.equal(expected.has("GOOG"), false);
  assert.equal(expected.has("REVIEW"), true);
  assert.equal(expected.has("REVIEW.A"), false);
  assert.equal(expected.has("PENDING"), false);
  assert.equal(sp500UniverseSummary().securityCount, 503);
  assert.equal(sp500UniverseSummary().companyCount, 500);
});

test("an empty Guru manifest preserves the index and tracked extras", () => {
  const universe = createGuruValuationUniverse({ schemaVersion: 1, asOf: "2026-09-05", companies: [] });
  assert.equal(universe.expectedTickerSet(["EXTRA"]).size, 501);
  assert.deepEqual(universe.companyTickers(), []);
});

test("reviewed companies require all identity, currency, and economic-review fields", () => {
  for (const field of [
    "ticker", "sourceTicker", "priceTicker", "name", "cik", "currency",
    "reportingCurrency", "valuationProfile", "profileRationale", "reviewStatus",
    "reviewedAt", "identityEvidence"
  ]) {
    const manifest = fixture();
    delete manifest.companies[0][field];
    assert.throws(() => createGuruValuationUniverse(manifest), /Invalid Guru valuation universe/, field);
  }
  for (const [field, value] of [
    ["ticker", "review"], ["sourceTicker", "REVIEW/USD"], ["priceTicker", ""],
    ["cik", "9999999"], ["cik", "0000000000"], ["currency", "GBX"],
    ["currency", "ZZZ"], ["reportingCurrency", "usd"],
    ["valuationProfile", "generic_company"], ["reviewStatus", "approved"],
    ["reviewedAt", "2026-02-30"], ["reviewedAt", "2026-09-06"],
    ["identityEvidence", []], ["aliases", "REVIEW.A"]
  ]) {
    const manifest = fixture();
    manifest.companies[0][field] = value;
    assert.throws(() => createGuruValuationUniverse(manifest), /Invalid Guru valuation universe/, `${field}=${value}`);
  }
});

test("identity evidence must preserve a source, original evidence, and usable HTTPS URL", () => {
  for (const update of [
    { source: "" }, { evidence: "" }, { url: "not a URL" },
    { url: "http://example.test/issuer" }, { url: "https://user:password@example.test/issuer" },
    { url: "https://127.0.0.1/issuer" }
  ]) {
    const manifest = fixture();
    Object.assign(manifest.companies[0].identityEvidence[0], update);
    assert.throws(() => createGuruValuationUniverse(manifest), /identity evidence/);
  }
});

test("duplicate and conflicting issuer, source, price and alias identities fail closed", () => {
  for (const change of [
    (row) => { row.ticker = "REVIEW"; },
    (row) => { row.cik = "0099999999"; },
    (row) => { row.sourceTicker = "REVIEW"; },
    (row) => { row.priceTicker = "REVIEW"; },
    (row) => { row.aliases = ["REVIEW.A"]; }
  ]) {
    const manifest = fixture();
    const second = {
      ...structuredClone(manifest.companies[0]),
      ticker: "SECOND", sourceTicker: "SECOND", priceTicker: "SECOND", cik: "0099999998", aliases: []
    };
    change(second);
    manifest.companies.push(second);
    assert.throws(() => createGuruValuationUniverse(manifest), /duplicate|conflict/);
  }
  const pendingAliasConflict = fixture();
  pendingAliasConflict.companies[0].aliases.push("PENDING");
  assert.throws(() => createGuruValuationUniverse(pendingAliasConflict), /conflict/);
});

test("Guru additions cannot override an existing S&P identity or share-class alias", () => {
  for (const change of [
    (row) => { row.ticker = "AAPL"; },
    (row) => { row.aliases = ["GOOG"]; },
    (row) => { row.sourceTicker = "MSFT"; },
    (row) => { row.priceTicker = "NVDA"; },
    (row) => { row.cik = sp500CompanyForTicker("AAPL").cik; }
  ]) {
    const manifest = fixture();
    change(manifest.companies[0]);
    assert.throws(() => createGuruValuationUniverse(manifest), /S&P/);
  }
});

test("manifest schema and dates are explicit and optional source hashes are validated", () => {
  for (const update of [
    { schemaVersion: 2 }, { asOf: "2026-02-30" }, { companies: {} },
    { securityMasterRecordsSha256: "unverified" }
  ]) {
    assert.throws(() => createGuruValuationUniverse({ ...fixture(), ...update }), /Invalid Guru valuation universe/);
  }
  const universe = loadGuruValuationUniverse(fixturePath);
  assert.match(universe.summary().manifestSha256, /^[a-f0-9]{64}$/);
  assert.throws(() => loadGuruValuationUniverse(`${fixturePath}.missing`), /ENOENT/);
});

test("the reviewed-profile allowlist matches the actual implemented economic models", () => {
  assert.deepEqual([...GURU_VALUATION_PROFILE_NAMES].sort(), valuationProfileNames());
});

test("the model resolver consumes a reviewed Guru profile without enabling pending companies", () => {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const script = `
    import assert from "node:assert/strict";
    import { hasExplicitValuationProfile, profileSettings } from "./server/importSecQuarterlyValuations.js";
    import { guruValuationExpectedTickerSet } from "./server/guruValuationUniverse.js";
    assert.equal(profileSettings("REVIEW").profile, "consumer_staples");
    assert.equal(profileSettings("REVIEW.A").profile, "consumer_staples");
    assert.equal(profileSettings("NVDA").profile, "semiconductor_growth");
    assert.equal(hasExplicitValuationProfile("PENDING"), false);
    assert.throws(() => profileSettings("PENDING"), /Missing explicit valuation profile/);
    assert.equal(guruValuationExpectedTickerSet([]).has("REVIEW"), true);
    assert.equal(guruValuationExpectedTickerSet([]).has("PENDING"), false);
  `;
  execFileSync(process.execPath, ["--input-type=module", "-e", script], {
    cwd: root,
    env: { ...process.env, GURU_VALUATION_UNIVERSE_PATH: fixturePath },
    encoding: "utf8"
  });
});
