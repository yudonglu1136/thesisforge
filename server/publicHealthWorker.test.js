import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { once } from "node:events";
import { Worker } from "node:worker_threads";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import express from "express";
import { createSystemHealth } from "./systemHealthCore.js";
import { readDatabaseTableSummariesFrom } from "./databaseTableSummaries.js";
import { installDatabaseHealthIndexes } from "./databaseHealthIndexes.js";
import { createPublicHealthWorkerBuilder } from "./publicHealthWorkerRunner.js";
import { createPublicHealthService } from "./publicHealthService.js";
import { requireAuth } from "./auth/requireAuth.js";
import {
  enabledManager13fGurus,
  expectedGuruCurveRows,
  requiredGuruCurveWindows
} from "./gurus.js";

const identity = {
  backtestEndGraceDays: 12,
  manager13fBacktestMethodVersion: "fixture-current-strict",
  manager13fProxyMethodVersion: "fixture-current-proxy",
  manager13fSecurityMasterVersion: "fixture-security-master"
};
const options = { now: Date.parse("2026-09-12T00:00:00Z") };
const expectedRows = expectedGuruCurveRows;
const curveModule = (health) => health.modules.find((module) => module.id === "guru_backtests");
const sha = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");

test("worker returns identical full health semantics without initializing or changing SQLite", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "public-health-worker-"));
  const databasePath = path.join(dir, "existing.sqlite");
  try {
    const db = new DatabaseSync(databasePath);
    db.exec(`
      CREATE TABLE guru_backtests (guru_id TEXT, years INTEGER, generated_at TEXT, end_date TEXT, payload_json TEXT);
      CREATE TABLE guru_backtest_proxies (guru_id TEXT, years INTEGER, generated_at TEXT, end_date TEXT, payload_json TEXT);
      CREATE TABLE price_points (symbol TEXT, date TEXT, updated_at TEXT);
      CREATE TABLE valuation_ticker_snapshots (generated_at TEXT, payload_json TEXT);
      INSERT INTO price_points VALUES ('SPY', '2026-09-11', '2026-09-12');
      INSERT INTO valuation_ticker_snapshots VALUES ('2026-09-12', '{"latest":{"asOfDate":"2026-09-10"}}');
    `);
    db.prepare("INSERT INTO guru_backtests VALUES (?, 5, '2026-09-12', '2026-09-11', ?)")
      .run(enabledManager13fGurus[0].id, JSON.stringify({
        status: "ready", generatedAt: "2026-09-12", window: { end: "2026-09-11" },
        method: { version: identity.manager13fBacktestMethodVersion, securityMasterVersion: identity.manager13fSecurityMasterVersion, years: 5 }
      }));
    db.close();
    const beforeHash = sha(databasePath);
    const reader = new DatabaseSync(databasePath, { readOnly: true });
    const payload = (table, id, years) => {
      const row = reader.prepare(`SELECT payload_json FROM ${table} WHERE guru_id = ? AND years = ?`).get(id, years);
      return row ? JSON.parse(row.payload_json) : null;
    };
    const direct = createSystemHealth({
      ...identity,
      databaseInfo: () => ({ path: databasePath }),
      readDatabaseTableSummaries: () => readDatabaseTableSummariesFrom(reader),
      readGuruBacktest: (id, years) => payload("guru_backtests", id, years),
      readGuruBacktestProxy: (id, years) => payload("guru_backtest_proxies", id, years)
    }).buildPublicSystemHealth(options);
    reader.close();
    const builder = createPublicHealthWorkerBuilder({ databasePath, methodIdentity: identity });
    const result = await builder.buildHealth(options);
    assert.deepEqual(result, direct);
    assert.equal(curveModule(result).details.curveAvailability.expectedRows, expectedRows);
    assert.equal(curveModule(result).details.curveAvailability.failures[0].reason, "strict_declared_coverage_floor_mismatch");
    assert.equal(sha(databasePath), beforeHash);
    assert.deepEqual(fs.readdirSync(dir), ["existing.sqlite"]);
    // Installing only performance indexes must not alter any matrix outcome,
    // identity/freshness/quality gate, or public semantic field.
    const migration = new DatabaseSync(databasePath);
    installDatabaseHealthIndexes(migration);
    migration.close();
    const indexedHash = sha(databasePath);
    const indexedBuilder = createPublicHealthWorkerBuilder({ databasePath, methodIdentity: identity });
    const indexed = await indexedBuilder.buildHealth(options);
    // The real file's metadata changes with the intentional index migration.
    assert.deepEqual({ ...indexed, database: {} }, { ...direct, database: {}, modules: direct.modules.map((module) =>
      module.id === "database" ? indexed.modules.find((entry) => entry.id === "database") : module
    ) });
    assert.equal(sha(databasePath), indexedHash);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("missing database fails closed and is never created by the worker", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "public-health-missing-"));
  try {
    const databasePath = path.join(dir, "missing.sqlite");
    const builder = createPublicHealthWorkerBuilder({ databasePath, methodIdentity: identity });
    const result = await builder.buildHealth(options);
    assert.equal(result.ok, false);
    assert.equal(result.status, "failed");
    assert.equal(curveModule(result).details.curveAvailability.expectedRows, expectedRows);
    assert.equal(curveModule(result).details.verificationError, "health_audit_failed");
    assert.equal(JSON.stringify(result).includes(databasePath), false);
    assert.deepEqual(fs.readdirSync(dir), []);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("timeout keeps the single worker slot until actual exit and never queues audits", async () => {
  let calls = 0;
  const workers = [];
  const builder = createPublicHealthWorkerBuilder({
    databasePath: "/not-opened.sqlite", methodIdentity: identity, timeoutMs: 15,
    workerFactory: () => {
      calls += 1;
      const worker = new EventEmitter();
      worker.terminate = () => new Promise(() => {});
      workers.push(worker);
      return worker;
    }
  });
  const result = await builder.buildHealth(options);
  assert.equal(result.ok, false);
  assert.equal(curveModule(result).details.verificationError, "health_audit_timeout");
  const burst = await Promise.all(Array.from({ length: 12 }, () => builder.buildHealth(options)));
  assert.equal(calls, 1);
  assert.ok(burst.every((health) => curveModule(health).details.verificationError === "health_audit_busy"));
  workers[0].emit("exit", 1);
  const next = builder.buildHealth(options);
  workers[1].emit("error", new Error("private/path must not escape"));
  workers[1].emit("exit", 1);
  assert.equal((await next).ok, false);
  assert.equal(calls, 2);
});

test("eight health callers share one blocked audit while anonymous portfolio denial remains responsive", async () => {
  let calls = 0;
  let started;
  const ready = new Promise((resolve) => { started = resolve; });
  let worker;
  const builder = createPublicHealthWorkerBuilder({
    databasePath: "/not-opened.sqlite", methodIdentity: identity, timeoutMs: 1000,
    workerFactory: () => {
      calls += 1;
      worker = new Worker(`
        const { parentPort } = require('node:worker_threads');
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5000);
      `, { eval: true });
      worker.once("online", started);
      return worker;
    }
  });
  const service = createPublicHealthService({ buildHealth: builder.buildHealth });
  let completed = false;
  const pending = Promise.all(Array.from({ length: 8 }, () => service.read())).then((results) => {
    completed = true;
    return results;
  });
  const app = express();
  app.get("/api/portfolio", requireAuth, (_req, res) => res.json({ unexpected: true }));
  const server = app.listen(0, "127.0.0.1");
  try {
    await Promise.all([ready, once(server, "listening")]);
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/portfolio`);
    assert.equal(response.status, 401);
    await response.json();
    assert.equal(completed, false, "anonymous auth should not wait for the blocked worker");
    const results = await pending;
    assert.equal(calls, 1);
    assert.ok(results.every((health) => health === results[0] && health.ok === false));
    assert.equal(curveModule(results[0]).details.verificationError, "health_audit_timeout");
  } finally {
    await worker?.terminate();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

test("worker timeout replaces an expired healthy result with bounded failure caching", async () => {
  let time = 1000;
  let calls = 0;
  let worker;
  const builder = createPublicHealthWorkerBuilder({
    databasePath: "/not-opened.sqlite", methodIdentity: identity, timeoutMs: 10,
    workerFactory: () => {
      calls += 1;
      worker = new EventEmitter();
      worker.terminate = async () => { worker.emit("exit", 0); };
      return worker;
    }
  });
  const service = createPublicHealthService({
    buildHealth: builder.buildHealth,
    successTtlMs: 100, failureTtlMs: 50, now: () => time
  });
  const first = service.read();
  await Promise.resolve();
  worker.emit("message", { health: { ok: true, status: "healthy", modules: [] } });
  assert.equal((await first).ok, true);
  time = 1100;
  const failed = await service.read();
  assert.equal(failed.ok, false);
  time = 1149;
  assert.equal(await service.read(), failed);
  assert.equal(calls, 2);
});
