import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { installHealthSummaryIndexes } from "../scripts/install-health-summary-indexes.mjs";

test("operator defaults to read-only inspection and refuses writes without the verified backup/identity gates", () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "health-index-operator-")));
  const database = path.join(dir, "existing.sqlite");
  try {
    const db = new DatabaseSync(database);
    db.exec("CREATE TABLE unrelated_private (encrypted BLOB); INSERT INTO unrelated_private VALUES (X'01020304')");
    db.close();
    const hash = () => crypto.createHash("sha256").update(fs.readFileSync(database)).digest("hex");
    const before = hash();
    const report = installHealthSummaryIndexes({ database });
    assert.equal(report.status, "read_only_health_index_inspection");
    assert.ok(report.indexes.every((index) => index.state === "missing"));
    assert.equal(report.applicationRowsMutated, false);
    assert.equal(hash(), before);
    assert.throws(() => installHealthSummaryIndexes({ database, execute: true }), /database_identity_changed|run_as_database_owner_not_root/);
    const stat = fs.statSync(database);
    assert.throws(() => installHealthSummaryIndexes({ database, execute: true, expectedInode: stat.ino, expectedDevice: stat.dev }),
      /fresh_verified_user_backup_required|run_as_database_owner_not_root/);
    assert.equal(hash(), before);
    assert.deepEqual(fs.readdirSync(dir), ["existing.sqlite"]);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("explicit fixture migration preserves private BLOBs and original schema while installing all four indexes", () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "health-index-approved-")));
  const database = path.join(dir, "existing.sqlite");
  try {
    const db = new DatabaseSync(database);
    db.exec(`
      PRAGMA journal_mode=WAL;
      CREATE TABLE price_points (symbol TEXT,date TEXT,updated_at TEXT);
      CREATE TABLE valuation_ticker_snapshots (generated_at TEXT,payload_json TEXT);
      CREATE TABLE unrelated_private (encrypted BLOB);
      INSERT INTO unrelated_private VALUES (X'01020304');
      INSERT INTO price_points VALUES ('TEST','2026-09-11','2026-09-12');
      INSERT INTO valuation_ticker_snapshots VALUES ('2026-09-12','{"latest":{"asOfDate":"2026-09-10"}}');
    `);
    db.close();
    const stat = fs.statSync(database);
    const generation = crypto.randomUUID();
    const options = { database, execute: true, expectedInode: stat.ino, expectedDevice: stat.dev,
      backupGeneration: generation, rollbackSnapshot: "snap-123456789abcdef01",
      backupReceipt: { status: "verified_off_host_user_backup", capturedAt: new Date().toISOString(), generation,
        remoteRestore: true, offHostRestore: true, credentialRecoveryEnvelopeVerified: true, productionDatabasesWritten: false } };
    if (process.getuid() === 0) {
      assert.throws(() => installHealthSummaryIndexes(options), /run_as_database_owner_not_root/);
      return;
    }
    const result = installHealthSummaryIndexes(options);
    assert.equal(result.status, "health_indexes_installed");
    assert.equal(result.created.length, 4);
    assert.equal(result.applicationRowsMutated, false);
    assert.equal(result.existingSchemaObjectsChanged, false);
    assert.ok(result.indexes.every((index) => index.state === "ready"));
    const reader = new DatabaseSync(database, { readOnly: true });
    assert.deepEqual([...reader.prepare("SELECT encrypted FROM unrelated_private").get().encrypted], [1, 2, 3, 4]);
    assert.equal(reader.prepare("SELECT COUNT(*) AS n FROM price_points").get().n, 1);
    reader.close();
    assert.deepEqual(installHealthSummaryIndexes(options).created, []);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
