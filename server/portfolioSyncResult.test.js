import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { portfolioSyncResult } from "./portfolioSyncResult.js";

test("a verified fresh sync keeps the existing successful response contract", () => {
  const payload = { connection: { status: "linked" }, summary: { holdings: 2 }, freshness: { status: "fresh" } };
  const result = portfolioSyncResult(payload, new Date("2026-09-12T12:00:00Z"));
  assert.equal(result.status, "success");
  assert.deepEqual(result.response, { ok: true, syncedAt: "2026-09-12T12:00:00.000Z", connection: payload.connection, summary: payload.summary, portfolio: payload });
});
test("saved reports remain displayable but never claim a new successful sync", () => {
  for (const payload of [
    { freshness: { status: "stale", savedAt: "2026-09-10T12:00:00Z" }, connection: { status: "linked" } },
    { connection: { status: "stale_report" } },
    { freshness: { status: "stale" }, connection: { status: "error" } }
  ]) {
    const result = portfolioSyncResult(payload);
    assert.equal(result.status, "degraded");
    assert.equal(result.response.ok, false);
    assert.equal(result.response.portfolio, payload);
    assert.equal(Object.hasOwn(result.response, "syncedAt"), false);
  }
});
test("partial first reports remain visible without claiming complete synchronization", () => {
  const payload = { connection: { status: "linked_partial" }, holdings: [{ ticker: "SYNTHETIC" }] };
  const result = portfolioSyncResult(payload);
  assert.equal(result.status, "degraded");
  assert.equal(result.response.ok, false);
  assert.equal(result.response.portfolio, payload);
  assert.equal(Object.hasOwn(result.response, "syncedAt"), false);
});
test("failed connections without a saved report are failed, not success", () => {
  for (const payload of [
    { connection: { status: "error" } },
    { connection: { status: "configured" } },
    { source: { mode: "sample" } }
  ]) {
    const result = portfolioSyncResult(payload);
    assert.equal(result.status, "failed");
    assert.equal(result.response.ok, false);
    assert.equal(Object.hasOwn(result.response, "syncedAt"), false);
  }
});
test("the actual sync route derives both job status and response from the same result", () => {
  const source = fs.readFileSync(new URL("./index.js", import.meta.url), "utf8");
  const route = source.slice(source.indexOf('app.post("/api/portfolio/sync"'), source.indexOf('app.delete("/api/portfolio/connection"'));
  assert.match(route, /const result = portfolioSyncResult\(payload\)/);
  assert.match(route, /status: result\.status/);
  assert.match(route, /response\.json\(result\.response\)/);
  assert.doesNotMatch(route, /status: "success"|ok: true|syncedAt: new Date/);
});
