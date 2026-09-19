import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import { ValuationNotCoveredError } from "./valuationHttp.js";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "valuation-client-cache-test-"));
const databasePath = path.join(tempDir, "cache.sqlite");
fs.closeSync(fs.openSync(databasePath, "w"));
process.env.SQLITE_DB_PATH = databasePath;
process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
process.env.SYNC_BUNDLED_GURU_BACKTESTS = "false";
process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";
process.env.SYNC_BUNDLED_PODCAST_INSIGHTS = "false";
process.env.VALUATION_TICKER_CACHE_MAX_ENTRIES = "2";
process.env.FACT_OS_ENABLED = "0";

const {
  writeBackgroundJobRun,
  writeValuationSnapshot,
  writeValuationTickerSnapshot
} = await import("./localDatabase.js");
const {
  loadValuationDashboard,
  loadValuationTicker,
  valuationTickerCacheStats
} = await import("./valuationClient.js");

after(() => {
  fs.rmSync(tempDir, { recursive: true, force: true });
});

test("unpublished ticker remains missing without substituting a dashboard company", async () => {
  await assert.rejects(loadValuationTicker("CRDO"), (error) =>
    error instanceof ValuationNotCoveredError && error.ticker === "CRDO");
});

function tickerFixture(name, generatedAt) {
  return {
    generatedAt,
    ticker: "TEST",
    key: "test",
    name,
    sector: "Information services",
    currency: "USD",
    latest: { latestPrice: 90, baseFairValue: 105 },
    priceHistory: Array.from({ length: 200 }, (_, index) => ({
      date: new Date(Date.UTC(2025, 0, index + 1)).toISOString().slice(0, 10),
      close: 80 + index / 10
    })),
    history: [],
    dataQuality: {}
  };
}

test("valuation caches follow valuation row versions instead of whole-database mtime", async () => {
  writeValuationSnapshot({
    generatedAt: "2026-08-30T00:00:00.000Z",
    summary: { marker: "dashboard-v1" },
    tickers: []
  });
  writeValuationTickerSnapshot(
    "TEST",
    tickerFixture("Ticker v1", "2026-08-30T00:00:00.000Z")
  );

  const dashboardV1 = await loadValuationDashboard();
  const tickerV1 = await loadValuationTicker("test", { pricePoints: 900 });
  assert.strictEqual(await loadValuationDashboard(), dashboardV1);
  assert.strictEqual(await loadValuationTicker("TEST", { pricePoints: 900 }), tickerV1);

  writeBackgroundJobRun("unrelated-job", {
    startedAt: "2026-08-30T00:00:10.000Z",
    finishedAt: "2026-08-30T00:00:11.000Z",
    status: "success"
  });
  assert.strictEqual(
    await loadValuationDashboard(),
    dashboardV1,
    "unrelated table writes must not invalidate valuation dashboard cache"
  );
  assert.strictEqual(
    await loadValuationTicker("TEST", { pricePoints: 900 }),
    tickerV1,
    "unrelated table writes must not invalidate ticker cache"
  );

  writeValuationSnapshot({
    generatedAt: "2026-08-30T00:01:00.000Z",
    summary: { marker: "dashboard-v2" },
    tickers: []
  });
  writeValuationTickerSnapshot(
    "TEST",
    tickerFixture("Ticker v2", "2026-08-30T00:01:00.000Z")
  );

  const dashboardV2 = await loadValuationDashboard();
  const tickerV2 = await loadValuationTicker("TEST", { pricePoints: 900 });
  assert.notStrictEqual(dashboardV2, dashboardV1);
  assert.equal(dashboardV2.summary.marker, "dashboard-v2");
  assert.notStrictEqual(tickerV2, tickerV1);
  assert.equal(tickerV2.ticker.name, "Ticker v2");

  writeValuationSnapshot({
    generatedAt: "2026-08-30T00:01:00.000Z",
    summary: { marker: "dashboard-v3-same-timestamp" },
    tickers: []
  });
  writeValuationTickerSnapshot(
    "TEST",
    tickerFixture("Ticker v3 same timestamp", "2026-08-30T00:01:00.000Z")
  );

  const dashboardV3 = await loadValuationDashboard();
  const tickerV3 = await loadValuationTicker("TEST", { pricePoints: 900 });
  assert.notStrictEqual(
    dashboardV3,
    dashboardV2,
    "a persisted revision must invalidate same-generated_at dashboard writes"
  );
  assert.equal(dashboardV3.summary.marker, "dashboard-v3-same-timestamp");
  assert.notStrictEqual(
    tickerV3,
    tickerV2,
    "a persisted revision must invalidate same-generated_at ticker writes"
  );
  assert.equal(tickerV3.ticker.name, "Ticker v3 same timestamp");
});

test("ticker cache normalizes pricePoints and evicts least-recently-used entries", async () => {
  const points120 = await loadValuationTicker("TEST", { pricePoints: 120 });
  const normalizedHit = await loadValuationTicker("TEST", { pricePoints: 120.4 });
  assert.strictEqual(normalizedHit, points120, "equivalent rounded limits should share a cache key");

  await loadValuationTicker("TEST", { pricePoints: 121 });
  await loadValuationTicker("TEST", { pricePoints: 122 });
  const points120Reloaded = await loadValuationTicker("TEST", { pricePoints: 120 });
  assert.notStrictEqual(points120Reloaded, points120, "oldest entry should be evicted at the size bound");
  assert.equal(points120Reloaded.ticker.priceHistory.length, 120);
  assert.ok(valuationTickerCacheStats().entries <= valuationTickerCacheStats().maxEntries);
  assert.ok(valuationTickerCacheStats().bytes <= valuationTickerCacheStats().maxBytes);
});
