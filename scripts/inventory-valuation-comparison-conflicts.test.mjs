import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { inventoryComparisonConflicts } from "./inventory-valuation-comparison-conflicts.mjs";

function fixture(history, raw, ticker = "ABNB", symbol = ticker) {
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT); CREATE TABLE price_points(symbol TEXT,date TEXT,close REAL,source TEXT)");
  db.prepare("INSERT INTO valuation_ticker_snapshots VALUES(?,?)").run(ticker, JSON.stringify({ currency: "USD", priceHistory: history }));
  for (const point of raw) db.prepare("INSERT INTO price_points VALUES(?,?,?,?)").run(symbol, point.date, point.close, point.source);
  try { return inventoryComparisonConflicts(db); } finally { db.close(); }
}
const point = (close, source = "yahoo", date = "2026-08-28") => ({ date, close, source });

test("Yahoo disagreement is a blocking same-series conflict", () => {
  const result = fixture([point(189.4149932861328)], [point(189.42999267578125)]);
  assert.equal(result.summary.blocking, 1);
  assert.equal(result.summary.actualMergeFailures, 1);
  assert.equal(result.conflicts[0].provider, "yahoo");
});
test("native paid provider does not claim Yahoo equivalence", () => {
  const result = fixture([point(189.43, "sharadar-paid-api-split-adjusted")], [point(189.42999267578125)]);
  assert.equal(result.summary.conflicts, 0);
  assert.equal(result.summary.actualMergeFailures, 0);
});
test("paid same-series disagreement still blocks with unchanged tolerance", () => {
  const result = fixture([point(189.43, "sharadar-paid-api-split-adjusted")], [point(189.5, "jansen-sharadar-sep-split-adjusted")]);
  assert.equal(result.summary.blocking, 1);
  assert.equal(result.summary.actualMergeFailures, 1);
  assert.equal(result.conflicts[0].provider, "sharadar");
});
test("nonpositive raw prices are excluded exactly as importer does", () => {
  const result = fixture([point(100)], [point(0), point(-1)]);
  assert.equal(result.summary.rawPoints, 0);
  assert.equal(result.summary.invalid, 0);
  assert.equal(result.summary.actualMergeFailures, 0);
});
test("unknown provider and impossible calendar date remain hard blockers", () => {
  const unknown = fixture([point(100, "arbitrary-audited")], []);
  assert.equal(unknown.summary.unverified, 1);
  assert.equal(unknown.summary.actualMergeFailures, 1);
  const invalid = fixture([point(100, "yahoo", "2026-02-30")], []);
  assert.equal(invalid.summary.actualMergeFailures, 1);
});
