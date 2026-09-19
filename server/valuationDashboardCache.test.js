import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "valuation-dashboard-cache-test-"));
process.env.SQLITE_DB_PATH = path.join(tempDir, "cache.sqlite");
process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
process.env.SYNC_BUNDLED_GURU_BACKTESTS = "false";
process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";
process.env.SYNC_BUNDLED_PODCAST_INSIGHTS = "false";
process.env.FACT_OS_ENABLED = "0";

const {
  readValuationDashboardVersion,
  writeValuationPodcastInsights,
  writeValuationSnapshot
} = await import("./localDatabase.js");
const { loadValuationDashboard } = await import("./valuationClient.js");

after(() => {
  fs.rmSync(tempDir, { recursive: true, force: true });
});

function snapshot(marker) {
  return {
    generatedAt: new Date().toISOString(),
    marker,
    source: { label: "Valuation cache test" },
    summary: { tickerCount: 1 },
    tickers: [{
      ticker: "TEST",
      name: "Test Company",
      latest: { upsideToBase: 0.1 },
      dataQuality: {}
    }]
  };
}

test("valuation dashboard reuses one response object until its stable version changes", async () => {
  writeValuationSnapshot(snapshot("v1"));
  const initialVersion = readValuationDashboardVersion();
  const first = await loadValuationDashboard();
  const hit = await loadValuationDashboard();
  assert.strictEqual(hit, first);

  writeValuationSnapshot(snapshot("v2"));
  const snapshotVersion = readValuationDashboardVersion();
  const afterSnapshot = await loadValuationDashboard();
  assert.notEqual(snapshotVersion, initialVersion);
  assert.notStrictEqual(afterSnapshot, first);
  assert.equal(afterSnapshot.marker, "v2");

  writeValuationPodcastInsights([{
    id: "cache-test-insight",
    ticker: "TEST",
    observedAt: "2026-09-01T00:00:00.000Z",
    summary: "Version invalidation test"
  }]);
  const podcastVersion = readValuationDashboardVersion();
  const afterPodcast = await loadValuationDashboard();
  assert.notEqual(podcastVersion, snapshotVersion);
  assert.notStrictEqual(afterPodcast, afterSnapshot);
  assert.equal(afterPodcast.podcastInsights.insightCount, 1);

  const concurrent = await Promise.all(
    Array.from({ length: 20 }, () => loadValuationDashboard())
  );
  for (const payload of concurrent.slice(1)) assert.strictEqual(payload, concurrent[0]);
});
