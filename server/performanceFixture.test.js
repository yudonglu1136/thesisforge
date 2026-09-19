import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import test, { after } from "node:test";
import { gurus } from "./gurus.js";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-performance-fixture-test-"));
const source = path.join(tempDir, "source.sqlite");
const outputOne = path.join(tempDir, "fixture-one.sqlite");
const outputTwo = path.join(tempDir, "fixture-two.sqlite");
const asOf = "2026-09-01";
// The fixture intentionally captures the retired simulation adapter contract.
process.env.FACT_OS_ENABLED = "0";

after(() => {
  fs.rmSync(tempDir, { recursive: true, force: true });
});

function hash(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function createSource() {
  const database = new DatabaseSync(source);
  database.exec(`
    CREATE TABLE guru_snapshots (
      guru_id TEXT PRIMARY KEY,
      cik TEXT,
      type TEXT,
      generated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL
    );
    CREATE TABLE guru_backtests (
      guru_id TEXT NOT NULL,
      years INTEGER NOT NULL,
      generated_at TEXT NOT NULL,
      start_date TEXT,
      end_date TEXT,
      payload_json TEXT NOT NULL,
      PRIMARY KEY (guru_id, years)
    );
    CREATE TABLE price_points (
      symbol TEXT NOT NULL,
      date TEXT NOT NULL,
      close REAL NOT NULL,
      source TEXT,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (symbol, date)
    );
  `);
  const insertGuru = database.prepare(`
    INSERT INTO guru_snapshots (guru_id, cik, type, generated_at, payload_json)
    VALUES (?, ?, ?, ?, ?)
  `);
  const insertLegacy = database.prepare(`
    INSERT INTO guru_backtests (guru_id, years, generated_at, start_date, end_date, payload_json)
    VALUES (?, 0, ?, ?, ?, ?)
  `);
  for (const guru of gurus.filter((row) => row.type === "manager13f" || row.type === "congress")) {
    insertGuru.run(
      guru.id,
      guru.cik || "",
      guru.type,
      "2026-08-31T00:00:00.000Z",
      JSON.stringify(guru)
    );
    insertLegacy.run(
      guru.id,
      "2026-08-31T00:00:00.000Z",
      "2020-01-01",
      "2026-08-31",
      JSON.stringify({ status: "ready", legacyToken: `must-not-survive:${guru.id}` })
    );
  }
  database.close();
}

function build(output) {
  const result = spawnSync(process.execPath, [
    "scripts/build-performance-fixture.mjs",
    "--source", source,
    "--output", output,
    "--as-of", asOf
  ], {
    cwd: path.resolve("."),
    encoding: "utf8"
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
}

test("performance fixture is deterministic, source-safe, and never relabels legacy results", () => {
  createSource();
  const sourceHash = hash(source);
  const first = build(outputOne);
  const second = build(outputTwo);

  assert.equal(hash(source), sourceHash);
  assert.equal(first.source.sha256Before, sourceHash);
  assert.equal(first.source.sha256After, sourceHash);
  assert.equal(first.source.mutationDetected, false);
  assert.equal(first.output.sha256, second.output.sha256);
  assert.equal(hash(outputOne), hash(outputTwo));
  assert.equal(first.backtests.legacyResultPromoted, false);
  assert.equal(first.backtests.resultFabricated, false);
  assert.equal(first.prices.adjustedCloseValuesSeeded, 0);
  assert.equal(first.prices.status, "not_seeded");

  const sourceDatabase = new DatabaseSync(source, { readOnly: true });
  const sourceColumns = sourceDatabase.prepare("PRAGMA table_info(price_points)").all();
  assert.equal(sourceColumns.some((column) => column.name === "adjusted_close"), false);
  sourceDatabase.close();

  const fixture = new DatabaseSync(outputOne, { readOnly: true });
  const fixtureColumns = fixture.prepare("PRAGMA table_info(price_points)").all();
  assert.equal(fixtureColumns.some((column) => column.name === "adjusted_close"), true);
  const rows = fixture.prepare("SELECT guru_id, payload_json FROM guru_backtests WHERE years = 0").all();
  assert.equal(rows.length, first.backtests.total);
  for (const row of rows) {
    const payload = JSON.parse(row.payload_json);
    assert.equal(payload.status, "insufficient_data");
    assert.equal(payload.dataQuality.networkAllowed, false);
    assert.equal(payload.dataQuality.failurePolicy, "fail_closed");
    assert.equal(payload.dataQuality.legacyResultPromoted, false);
    assert.equal(payload.dataQuality.resultFabricated, false);
    assert.equal(payload.window.end, asOf);
    assert.match(payload.method.reason, /No legacy result was promoted, converted, or relabeled/);
    assert.equal(JSON.stringify(payload).includes("must-not-survive"), false);
  }
  fixture.close();
});

test("aggregate all-years route resolves entirely from the offline fixture", async () => {
  process.env.SQLITE_DB_PATH = outputOne;
  process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
  process.env.SYNC_BUNDLED_GURU_BACKTESTS = "false";
  process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";
  process.env.SYNC_BUNDLED_PODCAST_INSIGHTS = "false";
  process.env.BACKTEST_CACHE_TTL_HOURS = "0";
  process.env.BACKTEST_STALE_BACKGROUND_REFRESH = "false";

  let networkCalls = 0;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    networkCalls += 1;
    throw new Error("network access is forbidden in the performance fixture test");
  };
  try {
    const { loadGuruBacktests, manager13fBacktestMethodVersion } = await import("./backtest.js");
    const payload = await loadGuruBacktests({ years: "all", detail: "compact" });
    assert.equal(networkCalls, 0);
    assert.ok(payload.backtests.length > 0);
    for (const backtest of payload.backtests) {
      if (backtest.status === "unsupported") continue;
      assert.equal(backtest.status, "insufficient_data");
      assert.equal(backtest.dataQuality?.networkAllowed, false);
      if (backtest.guru?.type === "manager13f") {
        assert.equal(backtest.method?.version, manager13fBacktestMethodVersion);
      }
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});
