import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { separateOriginalRevenueOccurrences } from "./guidanceOccurrenceAudit.js";
import { inspectStoredGuidanceLineage } from "./verifyPitValuationRelease.js";

const quote = "We expect Q3 sales to grow 40% sequentially. For the full year, we expect sales to decline in the mid to high single digits.";
const positions = [...quote.matchAll(/\bsales\b/g)].map(match => match.index);
function row(index, nested = {}) {
  return { metric_name: "revenue_guidance", value_text: quote, payload_json: JSON.stringify({
    payload_json: { metric_name: "revenue_guidance", evidence_excerpt: quote,
      source_file: "source-artifact://synthetic-call.txt", metric_position: positions[index], ...nested }
  }) };
}

test("one paragraph's quarter and annual revenue occurrences are not duplicate events", () => {
  assert.equal(separateOriginalRevenueOccurrences([row(0), row(1)]), true);
});

test("same occurrence, missing or forged offsets and changed source text cannot evade duplicate detection", () => {
  for (const other of [row(0), row(1, { metric_position: undefined }), row(1, { metric_position: positions[1] + 1 }),
    row(1, { evidence_excerpt: "Different original" }), row(1, { source_file: "" }),
    row(1, { metric_name: "free_cash_flow_guidance" }), row(1, { source_file: "another-call.txt" })]) {
    assert.equal(separateOriginalRevenueOccurrences([row(0), other]), false);
  }
  assert.equal(separateOriginalRevenueOccurrences([row(0), row(1), row(1)]), false);
});

test("unreviewed metric families and missing original evidence remain conservative", () => {
  assert.equal(separateOriginalRevenueOccurrences([row(0), { ...row(1), value_text: "Other quote" }]), false);
  assert.equal(separateOriginalRevenueOccurrences([row(0), row(1)].map(value => ({ ...value, metric_name: "eps_guidance" }))), false);
  assert.equal(separateOriginalRevenueOccurrences([row(0), { ...row(1), payload_json: "broken" }]), false);
});

test("release lineage retains every source row, distinguishes occurrences, and still flags a real empty duplicate", t => {
  const db = new DatabaseSync(":memory:");
  t.after(() => db.close());
  db.exec(`CREATE TABLE valuation_pit_guidance(source_id TEXT,source_database TEXT,ticker TEXT,fiscal_period TEXT,
    observed_at TEXT,metric_name TEXT,value_text TEXT,amount REAL,growth_yoy REAL,growth_qoq REAL,margin_pct REAL,payload_json TEXT)`);
  const insert = db.prepare("INSERT INTO valuation_pit_guidance VALUES(?,?,?,?,?,?,?,?,?,?,?,?)");
  for (let index = 0; index < 2; index++) {
    const original = JSON.parse(row(index).payload_json).payload_json;
    const value = index === 0 ? 40 : null;
    insert.run(String(index), "downloaded_online_earnings_transcript", "SYNTH", "Q22026", "2026-08-01",
      "revenue_guidance", quote, null, null, value, null, JSON.stringify({ amount: null, growth_yoy: null,
        growth_qoq: value, margin_pct: null, payload_json: { ...original, guidance_subject: "company_total", extraction_version: "v1" } }));
  }
  const separate = inspectStoredGuidanceLineage(db, "v1");
  assert.deepEqual(separate.failures, []);
  assert.equal(separate.separateOriginalOccurrenceGroups, 1);
  assert.equal(separate.rowsAudited, 2);
  const duplicate = JSON.parse(db.prepare("SELECT payload_json FROM valuation_pit_guidance WHERE source_id='1'").get().payload_json);
  duplicate.payload_json.metric_position = positions[0];
  db.prepare("UPDATE valuation_pit_guidance SET payload_json=? WHERE source_id='1'").run(JSON.stringify(duplicate));
  const blocked = inspectStoredGuidanceLineage(db, "v1");
  assert.equal(blocked.emptyDuplicates, 1);
  assert.ok(blocked.failures.some(f => f.code === "empty_duplicate_guidance_event"));
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM valuation_pit_guidance").get().n, 2);
});
