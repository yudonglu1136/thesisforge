import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-dashboard-cache-test-"));
const databasePath = path.join(tempDir, "cache.sqlite");
process.env.SQLITE_DB_PATH = databasePath;
process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
process.env.SYNC_BUNDLED_GURU_BACKTESTS = "false";
process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";
process.env.SYNC_BUNDLED_PODCAST_INSIGHTS = "false";
// This suite validates the legacy SQLite snapshot cache, not the canonical
// Sharadar-backed Guru adapter covered by the Fact OS consumer tests.
process.env.FACT_OS_ENABLED = "0";

const { gurus } = await import("./gurus.js");
const {
  readDashboardSnapshot,
  readGuruDashboardVersion,
  readGuruExposureSnapshot,
  readGuruSnapshot,
  writeDashboardSnapshot,
  writeGuruAsset,
  writeGuru13fRefreshBundle,
  writeGuruExposureSnapshot,
  writeGuruSnapshot
} = await import("./localDatabase.js");
const {
  clearGuruDashboardMemoryCache,
  loadGuruDashboard,
  loadGuruExposureHistory
} = await import("./secClient.js");

after(() => {
  fs.rmSync(tempDir, { recursive: true, force: true });
});

function dashboard(marker, generatedAt) {
  return {
    generatedAt,
    marker,
    source: { label: "Guru dashboard cache test" },
    gurus: gurus.map((guru) => ({
      id: guru.id,
      name: guru.name,
      type: guru.type,
      cik: guru.cik || "",
      status: "live",
      holdings: [],
      activity: [],
      transactions: []
    }))
  };
}

test("Guru dashboard reuses one derived payload and preserves response semantics", async () => {
  writeDashboardSnapshot(dashboard("v1", new Date().toISOString()));

  const first = await loadGuruDashboard();
  const hit = await loadGuruDashboard();
  assert.strictEqual(hit, first, "a version-stable hit must reuse the exact payload object");
  assert.ok(!first.gurus.some(g => ['john-stamas','chamath-palihapitiya','nick-sleep-qais-zakaria'].includes(g.id)));
  assert.ok(readDashboardSnapshot().gurus.some(g => g.id === 'john-stamas'), 'retirement must not erase the archive');
  assert.equal(
    first.gurus.find((guru) => guru.id === gurus[0].id)?.avatarUrl,
    `/guru-avatars/${gurus[0].id}.png`,
    "configured gurus must receive the canonical static avatar when guru_assets is empty"
  );

  const serialized = JSON.stringify(first);
  clearGuruDashboardMemoryCache();
  const rebuilt = await loadGuruDashboard();
  assert.notStrictEqual(rebuilt, first);
  assert.equal(JSON.stringify(rebuilt), serialized, "caching must not change JSON semantics");

  clearGuruDashboardMemoryCache();
  const concurrent = await Promise.all(
    Array.from({ length: 20 }, () => loadGuruDashboard())
  );
  for (const payload of concurrent.slice(1)) assert.strictEqual(payload, concurrent[0]);
});

test("dashboard, Guru snapshot, and avatar writes invalidate the version-keyed cache", async () => {
  writeDashboardSnapshot(dashboard("v1", new Date().toISOString()));
  const firstVersion = readGuruDashboardVersion();
  const first = await loadGuruDashboard();

  writeDashboardSnapshot(dashboard("v2", new Date().toISOString()));
  const secondVersion = readGuruDashboardVersion();
  const second = await loadGuruDashboard();
  assert.notEqual(secondVersion, firstVersion);
  assert.notStrictEqual(second, first);
  assert.equal(second.marker, "v2");

  const selected = gurus[0];
  const beforeGuruWrite = readGuruDashboardVersion();
  writeGuruSnapshot(selected.id, {
    id: selected.id,
    type: selected.type,
    cik: selected.cik || "",
    generatedAt: new Date().toISOString()
  });
  const afterGuruWrite = readGuruDashboardVersion();
  const afterGuruSnapshot = await loadGuruDashboard();
  assert.notEqual(afterGuruWrite, beforeGuruWrite);
  assert.notStrictEqual(afterGuruSnapshot, second);

  const beforeAssetWrite = readGuruDashboardVersion();
  writeGuruAsset(selected.id, {
    assetType: "avatar",
    url: "/guru-avatars/cache-test.webp",
    generatedAt: new Date().toISOString()
  });
  const afterAssetWrite = readGuruDashboardVersion();
  const afterAsset = await loadGuruDashboard();
  assert.notEqual(afterAssetWrite, beforeAssetWrite);
  assert.notStrictEqual(afterAsset, afterGuruSnapshot);
  assert.equal(
    afterAsset.gurus.find((guru) => guru.id === selected.id)?.avatarUrl,
    "/guru-avatars/cache-test.webp"
  );
});

test("exposure views honor the requested limit without shrinking the stored history", async () => {
  const guruId = "gavin-baker";
  const history = Array.from({ length: 40 }, (_, index) => ({
    quarterLabel: `Q${index + 1}`,
    reportDate: `2026-${String((index % 12) + 1).padStart(2, "0")}-01`
  }));
  writeGuruExposureSnapshot(guruId, {
    generatedAt: new Date().toISOString(),
    status: "live",
    history,
    latest: history.at(-1),
    meta: { requestedQuarters: 40, returnedQuarters: 40 }
  });

  const compact = await loadGuruExposureHistory(guruId, { limit: 4 });
  assert.equal(compact.history.length, 4);
  assert.equal(compact.history[0].quarterLabel, "Q37");
  assert.equal(compact.latest.quarterLabel, "Q40");
  assert.equal(compact.meta.requestedQuarters, 4);
  assert.equal(compact.meta.returnedQuarters, 4);
  assert.equal(compact.meta.storedRequestedQuarters, 40);

  const stored = readGuruExposureSnapshot(guruId);
  assert.equal(stored.history.length, 40);
  assert.equal(stored.meta.requestedQuarters, 40);
});

test("an invalid staged 13F bundle rolls back every database surface", () => {
  const guruId = "atomic-refresh-test";
  const beforeDashboard = readDashboardSnapshot();
  const circularExposure = { generatedAt: new Date().toISOString(), history: [] };
  circularExposure.self = circularExposure;

  assert.throws(
    () =>
      writeGuru13fRefreshBundle({
        dashboard: dashboard("should-not-commit", new Date().toISOString()),
        guruSnapshots: [
          {
            guruId,
            payload: {
              id: guruId,
              type: "manager13f",
              cik: "0000000000",
              generatedAt: new Date().toISOString()
            }
          }
        ],
        exposureSnapshots: [{ guruId, payload: circularExposure }]
      }),
    /circular/i
  );

  assert.equal(readGuruSnapshot(guruId), null);
  assert.equal(readDashboardSnapshot()?.marker, beforeDashboard?.marker);
});

test("an atomic 13F bundle preserves another manager committed after staging", () => {
  const firstGuru = gurus[0];
  const secondGuru = gurus[1];
  const stagedDashboard = dashboard("staged-before-concurrent-write", "2026-09-01T00:00:00.000Z");
  const latestDashboard = dashboard("newer-dashboard", "2026-09-01T00:00:01.000Z");
  latestDashboard.gurus = latestDashboard.gurus.map((guru) =>
    guru.id === firstGuru.id ? { ...guru, concurrentMarker: "keep-me" } : guru
  );
  writeDashboardSnapshot(latestDashboard);

  stagedDashboard.gurus = stagedDashboard.gurus.map((guru) =>
    guru.id === secondGuru.id ? { ...guru, refreshMarker: "apply-me" } : guru
  );
  writeGuru13fRefreshBundle({
    dashboard: stagedDashboard,
    guruSnapshots: [
      {
        guruId: secondGuru.id,
        payload: stagedDashboard.gurus.find((guru) => guru.id === secondGuru.id)
      }
    ]
  });

  const committed = readDashboardSnapshot();
  assert.equal(committed.marker, "newer-dashboard");
  assert.equal(
    committed.gurus.find((guru) => guru.id === firstGuru.id)?.concurrentMarker,
    "keep-me"
  );
  assert.equal(
    committed.gurus.find((guru) => guru.id === secondGuru.id)?.refreshMarker,
    "apply-me"
  );
});
