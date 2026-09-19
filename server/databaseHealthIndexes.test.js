import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { databaseHealthIndexes, inspectDatabaseHealthIndexes, installDatabaseHealthIndexes } from "./databaseHealthIndexes.js";
import { readDatabaseTableSummariesFrom } from "./databaseTableSummaries.js";

function fixture() {
  const db = new DatabaseSync(":memory:");
  db.exec(`
    CREATE TABLE valuation_ticker_snapshots (ticker TEXT PRIMARY KEY, generated_at TEXT, payload_json TEXT);
    CREATE TABLE price_points (symbol TEXT, date TEXT, updated_at TEXT, close REAL, PRIMARY KEY (symbol,date));
    CREATE TABLE unrelated_private (id TEXT PRIMARY KEY, encrypted BLOB);
    INSERT INTO unrelated_private VALUES ('test-only', X'0102030405');
  `);
  const insert = db.prepare("INSERT INTO valuation_ticker_snapshots VALUES (?, ?, ?)");
  [
    ["A", "2026-09-12", { history: [{ asOfDate: "2026-09-11" }, { asOfDate: "2026-08-01" }], latest: { asOfDate: "2026-09-10" } }],
    ["B", "2026-09-11", { history: [], latest: { asOfDate: "2026-09-09" } }],
    ["C", "2026-09-10", { history: [{ asOfDate: "" }], latest: { asOfDate: "2026-09-08" } }],
    ["D", null, { history: [{ asOfDate: null }], latest: { asOfDate: "" } }],
    ["E", "", {}]
  ].forEach(([ticker, generatedAt, payload]) => insert.run(ticker, generatedAt, JSON.stringify(payload)));
  db.exec(`
    INSERT INTO price_points VALUES ('A','2026-09-10','2026-09-11',1);
    INSERT INTO price_points VALUES ('B','2026-09-11','2026-09-10',2);
    INSERT INTO price_points VALUES ('C',NULL,NULL,3);
  `);
  return db;
}
const storedRows = (db) => ["valuation_ticker_snapshots", "price_points", "unrelated_private"].map((table) =>
  db.prepare(`SELECT * FROM ${table} ORDER BY rowid`).all());

test("health indexing is additive, atomic, idempotent and preserves exact summaries and all stored rows", () => {
  const db = fixture();
  try {
    const rows = storedRows(db);
    const schema = db.prepare("SELECT * FROM sqlite_schema ORDER BY name").all();
    const before = readDatabaseTableSummariesFrom(db);
    assert.ok(inspectDatabaseHealthIndexes(db).every((entry) => entry.state === "missing"));
    assert.equal(installDatabaseHealthIndexes(db).created.length, 4);
    assert.deepEqual(readDatabaseTableSummariesFrom(db), before);
    assert.deepEqual(storedRows(db), rows);
    assert.deepEqual(db.prepare("SELECT * FROM sqlite_schema WHERE name NOT LIKE 'tf_health_v1_%' ORDER BY name").all(), schema);
    assert.ok(inspectDatabaseHealthIndexes(db).every((entry) => entry.state === "ready"));
    assert.deepEqual(installDatabaseHealthIndexes(db).created, []);
    assert.equal(before.find((row) => row.table === "valuation_ticker_snapshots").sourceAt, "2026-09-09");
  } finally { db.close(); }
});

test("indexed summaries reflect inserts, corrections, deletions and empty tables without a stale cache", () => {
  const db = fixture();
  try {
    installDatabaseHealthIndexes(db);
    db.exec(`
      INSERT INTO price_points VALUES ('NEW','2030-01-01','2030-01-02',10);
      UPDATE valuation_ticker_snapshots SET payload_json='{"latest":{"asOfDate":"2030-01-03"}}' WHERE ticker='A';
    `);
    let rows = readDatabaseTableSummariesFrom(db);
    assert.equal(rows.find((row) => row.table === "price_points").sourceAt, "2030-01-01");
    assert.equal(rows.find((row) => row.table === "valuation_ticker_snapshots").sourceAt, "2030-01-03");
    db.exec("DELETE FROM price_points; DELETE FROM valuation_ticker_snapshots;");
    rows = readDatabaseTableSummariesFrom(db);
    for (const table of ["price_points", "valuation_ticker_snapshots"]) {
      assert.equal(rows.find((row) => row.table === table).rowCount, 0);
      assert.equal(rows.find((row) => row.table === table).sourceAt, "");
    }
    for (const spec of databaseHealthIndexes) db.exec(`DROP INDEX ${spec.name}`);
    assert.deepEqual(readDatabaseTableSummariesFrom(db), rows);
  } finally { db.close(); }
});

test("malformed JSON or missing source schema aborts the entire migration, leaving data unchanged", () => {
  for (const malformed of [true, false]) {
    const db = fixture();
    try {
      if (malformed) db.exec("UPDATE valuation_ticker_snapshots SET payload_json='{' WHERE ticker='A'");
      else db.exec("DROP TABLE price_points");
      const before = db.prepare("SELECT * FROM sqlite_schema ORDER BY name").all();
      assert.throws(() => installDatabaseHealthIndexes(db));
      assert.deepEqual(db.prepare("SELECT * FROM sqlite_schema ORDER BY name").all(), before);
      assert.ok(inspectDatabaseHealthIndexes(db).every((entry) => entry.state === "missing"));
      if (malformed) assert.equal(readDatabaseTableSummariesFrom(db).find((row) => row.table === "valuation_ticker_snapshots").status, "error");
    } finally { db.close(); }
  }
});

test("incompatible index names are never overwritten and runtime retains legacy query semantics", () => {
  const db = fixture();
  try {
    const before = readDatabaseTableSummariesFrom(db);
    db.exec(`CREATE INDEX ${databaseHealthIndexes[0].name} ON price_points (symbol)`);
    assert.throws(() => installDatabaseHealthIndexes(db), /incompatible definition/);
    assert.deepEqual(readDatabaseTableSummariesFrom(db), before);
    assert.equal(inspectDatabaseHealthIndexes(db)[0].state, "incompatible");
  } finally { db.close(); }
});

test("large-table summaries use covering indexes / exact MAX seeks instead of scanning JSON payloads", () => {
  const db = fixture();
  try {
    installDatabaseHealthIndexes(db);
    const queries = [];
    const instrumented = { prepare(sql) { queries.push(sql); return db.prepare(sql); } };
    readDatabaseTableSummariesFrom(instrumented);
    for (const table of ["price_points", "valuation_ticker_snapshots"]) {
      const sql = queries.find((query) => query.startsWith("SELECT (SELECT COUNT(*)") && query.includes(`FROM ${table}`));
      assert.ok(sql);
      const plan = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all().map((row) => row.detail);
      assert.ok(plan.some((detail) => detail.includes(`SCAN ${table} USING COVERING INDEX`)));
      assert.ok(plan.filter((detail) => detail.includes(`SEARCH ${table} USING COVERING INDEX`)).length >= 2);
      assert.equal(plan.some((detail) => detail === `SCAN ${table}`), false);
    }
  } finally { db.close(); }
});
