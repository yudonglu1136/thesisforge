import { parentPort, workerData } from "node:worker_threads";
import { DatabaseSync } from "node:sqlite";
import { createSystemHealth } from "./systemHealthCore.js";
import { readDatabaseTableSummariesFrom } from "./databaseTableSummaries.js";
import { releaseRoot, withActiveDataRelease } from "./dataReleaseContext.js";

// Do not import localDatabase/systemHealth/backtest here: their legacy runtime
// initializers create schemas and may install bundled snapshots. This worker
// opens only the already-existing production database, strictly read-only.
const { databasePath, methodIdentity, options } = workerData;
let db;
try {
  db = new DatabaseSync(databasePath, { readOnly: true });
  db.exec("PRAGMA query_only = ON; PRAGMA busy_timeout = 250; PRAGMA cache_size = -8192; PRAGMA mmap_size = 0; BEGIN;");
  const readPayload = (table, guruId, years) => {
    const row = db.prepare(`SELECT payload_json FROM ${table} WHERE guru_id = ? AND years = ?`)
      .get(guruId, years);
    if (!row?.payload_json) return null;
    try { return JSON.parse(row.payload_json); } catch { return null; }
  };
  const health = createSystemHealth({
    ...methodIdentity,
    databaseInfo: () => ({ path: databasePath }),
    readDatabaseTableSummaries: () => withActiveDataRelease(() => {
      const factOsRoot = releaseRoot("canonical", process.env.FACT_OS_ROOT || null);
      return readDatabaseTableSummariesFrom(db, { factOsRoot });
    }),
    readGuruBacktest: (id, years) => readPayload("guru_backtests", id, years),
    readGuruBacktestProxy: (id, years) => readPayload("guru_backtest_proxies", id, years)
  });
  parentPort.postMessage({ health: health.buildPublicSystemHealth(options) });
} catch {
  // Never disclose production paths, statements or stored payloads publicly.
  parentPort.postMessage({ error: "health_audit_failed" });
} finally {
  if (db) db.close();
  parentPort.close();
}
