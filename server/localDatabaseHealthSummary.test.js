import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "health-summary-test-"));
process.env.SQLITE_DB_PATH = path.join(temporaryDirectory, "health-summary.sqlite");
process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
process.env.SYNC_BUNDLED_GURU_BACKTESTS = "false";
process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";
process.env.SYNC_BUNDLED_PODCAST_INSIGHTS = "false";

const {
  readDatabaseTableSummaries,
  writeGuruBacktest,
  writeGuruSnapshot,
  writePriceSeriesToDb,
  writeValuationTickerSnapshot
} = await import("./localDatabase.js");

after(() => fs.rmSync(temporaryDirectory, { recursive: true, force: true }));

test("table summaries keep economic source dates separate from generated timestamps", () => {
  const generatedAt = "2026-09-01T10:00:00.000Z";
  writeGuruSnapshot("manager", {
    generatedAt,
    latestFiling: { filingDate: "2026-08-14" },
    summary: { filingDate: "2026-08-13" }
  });
  writeGuruBacktest("manager", 5, {
    guru: {id: "manager"},
    generatedAt,
    window: { start: "2021-08-31", end: "2026-08-28" }
  });
  writeValuationTickerSnapshot("TEST", {
    generatedAt,
    history: [
      { asOfDate: "2026-05-01" },
      { asOfDate: "2026-08-27" }
    ]
  });
  writePriceSeriesToDb("TEST", [
    { date: "2026-08-28", close: 100 }
  ], "test");

  const summaries = new Map(
    readDatabaseTableSummaries().map((summary) => [summary.table, summary])
  );
  assert.equal(summaries.get("guru_snapshots").latestAt, generatedAt);
  assert.equal(summaries.get("guru_snapshots").sourceAt, "2026-08-14");
  assert.equal(summaries.get("guru_backtests").sourceAt, "2026-08-28");
  assert.equal(summaries.get("valuation_ticker_snapshots").sourceAt, "2026-08-27");
  assert.equal(summaries.get("price_points").sourceAt, "2026-08-28");
});
