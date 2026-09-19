import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { assessIssuer, extractLiteral, modelBindings } from "./audit-inherited-issuer-provenance.mjs";

function fixture() {
  return { ledger: { nodeCount: 2, firstPeriod: "2025-Q1", latestPeriod: "2025-Q2", latestAsOfDate: "2025-08-01",
    latestFairValue: 12.35, profile: "software", status: "watch", blockerCount: 0 },
    baseline: { nodeCount: 2, firstPeriod: "2025-Q1", latestPeriod: "2025-Q2", latestAsOfDate: "2025-08-01",
      latestFairValue: 12.345678, profiles: ["software"] },
    originalSettings: { profile: "software", range: [1, 2] }, currentSettings: { profile: "software", range: [1, 2] } };
}

test("unchanged explained-watch profile can be inherited but no new input/output approval follows", () => {
  const result = assessIssuer(fixture());
  assert.equal(result.profileInheritanceEligible, true);
  for (const key of ["newFinancialInputApprovalInherited", "newGuidanceApprovalInherited", "newFxApprovalInherited", "newModelOutputsApprovalInherited", "releaseAuthorized"]) assert.equal(result[key], false);
});

test("profile changes, parameter changes, original mismatch and missing models require review", () => {
  const changes = [
    (x) => { x.currentSettings.profile = "different"; },
    (x) => { x.currentSettings.range[1] = 3; },
    (x) => { x.originalSettings.profile = "different"; },
    (x) => { x.baseline = null; },
    (x) => { x.baseline.profiles.push("different"); },
    (x) => { x.ledger.blockerCount = 1; },
    (x) => { x.ledger.status = "blocked"; },
  ];
  for (const change of changes) {
    const x = fixture(); change(x);
    assert.equal(assessIssuer(x).profileInheritanceEligible, false, change.toString());
  }
});

test("counts, periods, dates and ledger precision must match, not just ticker/profile", () => {
  for (const [key, value] of [["nodeCount", 1], ["firstPeriod", "2025-Q2"], ["latestPeriod", "2025-Q3"], ["latestAsOfDate", "2025-08-02"], ["latestFairValue", 12.34]]) {
    const x = fixture(); x.baseline[key] = value;
    assert.equal(assessIssuer(x).profileInheritanceEligible, false);
  }
});

test("profile literals must exist explicitly; missing names never fall back", () => {
  assert.deepEqual(JSON.parse(JSON.stringify(extractLiteral("const SETTINGS = {a: {value: 1}}\n};".replace("}}\n", "}\n"), "SETTINGS"))), { a: { value: 1 } });
  assert.throws(() => extractLiteral("const OTHER = {};", "SETTINGS"), /Missing/);
});

function dbFixture() {
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE TABLE valuation_pit_model_runs(ticker,fiscal_period,model_version,as_of_date,financial_available_at,guidance_max_observed_at,input_json,output_json,generated_at)");
  const input = { valuationSemantics: { scoreInputs: { profile: "software", earnings: 10 } } };
  db.prepare("INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?,?,?,?,?,?)").run("TEST", "2025-Q1", "v1", "2025-05-01", "2025-05-01", null,
    JSON.stringify(input), JSON.stringify({ fairValue: 20, runCreatedAt: "2025-05-02" }), "2025-05-02");
  return db;
}

test("complete model binding covers all inputs/outputs, not only latest value", () => {
  const db = dbFixture();
  try {
    const first = modelBindings(db);
    const input = JSON.parse(db.prepare("SELECT input_json FROM valuation_pit_model_runs").get().input_json);
    input.valuationSemantics.scoreInputs.earnings = 11;
    db.prepare("UPDATE valuation_pit_model_runs SET input_json=?").run(JSON.stringify(input));
    const second = modelBindings(db);
    assert.notEqual(first.modelSignature, second.modelSignature);
    assert.notEqual(first.tickers.get("TEST").modelSignature, second.tickers.get("TEST").modelSignature);
    assert.equal(first.tickers.get("TEST").latestFairValue, second.tickers.get("TEST").latestFairValue);
  } finally { db.close(); }
});

test("dynamic run timestamp only is omitted from semantic signature but retained in raw full signature", () => {
  const db = dbFixture();
  try {
    const first = modelBindings(db);
    db.prepare("UPDATE valuation_pit_model_runs SET output_json=?,generated_at=?").run(JSON.stringify({ fairValue: 20, runCreatedAt: "2025-05-03" }), "2025-05-03");
    const second = modelBindings(db);
    assert.equal(first.modelSignature, second.modelSignature);
    assert.notEqual(first.rawFullModelRowsSha256, second.rawFullModelRowsSha256);
  } finally { db.close(); }
});
