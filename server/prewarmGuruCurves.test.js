import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  gurus,
  expectedGuruCurveRows,
  requiredGuruCurveWindowsFor
} from "./gurus.js";

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const prewarmScript = path.join(repoRoot, "scripts", "prewarm-guru-curves.mjs");
const generation = "a".repeat(64);
const strictMethodVersion = "strict-v1";
const proxyMethodVersion = "proxy-v1";
const securityMasterVersion = "security-v1";
const expectedManagerIds = gurus.filter((guru) =>
  guru.type === "manager13f" && !guru.disableSimulation
).map((guru) => guru.id);
const expectedManagerCount = expectedManagerIds.length;
const expectedCurveRows = expectedGuruCurveRows;
const expectedManagerIdsForYears = (years) => gurus.filter((guru) =>
  guru.type === "manager13f" && !guru.disableSimulation &&
  requiredGuruCurveWindowsFor(guru).includes(Number(years))
).map((guru) => guru.id);

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

function runPrewarm({
  port,
  output,
  marker,
  notBefore,
  refreshTimeoutMs,
  statusRequestTimeoutMs,
  idlePollIntervalMs
}) {
  const argumentsList = [
    prewarmScript,
    `--base-url=http://127.0.0.1:${port}`,
    "--windows=5,10",
    `--refresh-generation=${generation}`,
    `--not-before=${notBefore}`,
    `--strict-method-version=${strictMethodVersion}`,
    `--proxy-method-version=${proxyMethodVersion}`,
    `--security-master-version=${securityMasterVersion}`,
    `--output=${output}`,
    `--success-marker=${marker}`
  ];
  if (refreshTimeoutMs) argumentsList.push(`--refresh-timeout-ms=${refreshTimeoutMs}`);
  if (statusRequestTimeoutMs) {
    argumentsList.push(`--status-request-timeout-ms=${statusRequestTimeoutMs}`);
  }
  if (idlePollIntervalMs) {
    argumentsList.push(`--idle-poll-interval-ms=${idlePollIntervalMs}`);
  }
  const child = spawn(process.execPath, argumentsList, {
    cwd: repoRoot,
    env: { ...process.env, INTERNAL_CRON_SECRET: "test-secret" },
    stdio: ["ignore", "pipe", "pipe"]
  });
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  return new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({
      code,
      signal,
      stdout: Buffer.concat(stdout).toString("utf8"),
      stderr: Buffer.concat(stderr).toString("utf8")
    }));
  });
}

test("prewarm uses the explicit loopback client instead of fetch's hidden header timeout", () => {
  const source = fs.readFileSync(prewarmScript, "utf8");
  assert.match(source, /requestLoopbackJson/);
  assert.doesNotMatch(source, /\bfetch\s*\(/);
  assert.match(source, /DEFAULT_REFRESH_TIMEOUT_MS = 60 \* 60 \* 1000/);
});

test("prewarm rejects a deadline beyond its bounded 90-minute window", async () => {
  const result = await runPrewarm({
    port: 1, output: '', marker: '',
    notBefore: new Date().toISOString(), refreshTimeoutMs: 90 * 60 * 1000 + 1
  });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /integer from 1 to 5400000ms/);
});

function managerResults(years, refreshGeneration, generatedAt = new Date().toISOString()) {
  const managerIds = expectedManagerIdsForYears(years);
  return Array.from({ length: managerIds.length }, (_, index) => {
    const guruId = managerIds[index];
    const proxy = index >= 8 || (guruId === "renaissance-technologies" && years === 10);
    return {
      guruId,
      guruType: "manager13f",
      disabled: false,
      years,
      status: proxy ? "proxy_ready" : "ready",
      generatedAt,
      methodVersion: strictMethodVersion,
      securityMasterVersion,
      proxyMethodVersion: proxy ? proxyMethodVersion : "",
      proxySecurityMasterVersion: proxy ? securityMasterVersion : "",
      refreshGeneration
    };
  });
}

function healthPayload(overrides = {}) {
  return {
    modules: [{
      id: "guru_backtests",
      details: {
        curveAvailability: {
          ok: true,
          managerCount: expectedManagerCount,
          windows: [5, 10],
          expectedRows: expectedCurveRows,
          displayable: expectedCurveRows,
          failures: [],
          methodVersion: strictMethodVersion,
          proxyMethodVersion,
          securityMasterVersion,
          ...overrides
        }
      }
    }]
  };
}

test("prewarm writes its success marker only after both windows cover every configured manager", async (context) => {
  const requestedGenerations = [];
  const requestedPopulations = [];
  const server = await listen(http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    response.setHeader("content-type", "application/json");
    if (url.pathname === "/api/health") {
      response.end(JSON.stringify(healthPayload()));
      return;
    }
    if (url.pathname === "/api/internal/backtests/status") {
      response.end(JSON.stringify({ running: false }));
      return;
    }
    if (url.pathname === "/api/internal/backtests/refresh") {
      const refreshGeneration = url.searchParams.get("refreshGeneration");
      const years = Number(url.searchParams.get("years"));
      requestedGenerations.push(refreshGeneration);
      requestedPopulations.push(url.searchParams.get("population"));
      response.end(JSON.stringify({
        startedAt: new Date().toISOString(),
        finishedAt: new Date().toISOString(),
        ok: 8,
        failed: 10,
        proxyAvailable: 10,
        errors: [],
        refreshGeneration,
        results: managerResults(years, refreshGeneration)
      }));
      return;
    }
    response.statusCode = 404;
    response.end("{}");
  }));
  context.after(() => server.close());
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-test-"));
  context.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const output = path.join(tempDir, "report.json");
  const marker = path.join(tempDir, "done.json");
  const result = await runPrewarm({
    port: server.address().port,
    output,
    marker,
    refreshTimeoutMs: 40 * 60 * 1000,
    notBefore: new Date(Date.now() - 1000).toISOString()
  });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.deepEqual(requestedGenerations, [`${generation}:5`, `${generation}:10`]);
  assert.deepEqual(requestedPopulations, ["enabled-manager13f", "enabled-manager13f"]);
  const report = JSON.parse(fs.readFileSync(output, "utf8"));
  assert.equal(report.pass, true);
  assert.equal(report.refreshTimeoutMs, 40 * 60 * 1000);
  assert.equal(report.kind, "guru_curve_production_prewarm");
  assert.equal(report.schemaVersion, 1);
  assert.equal(report.refreshGeneration, generation);
  assert.deepEqual(report.expectations, {
    strictMethodVersion,
    proxyMethodVersion,
    securityMasterVersion,
    expectedDisplayableRows: expectedCurveRows
  });
  assert.equal(report.refreshes.length, expectedCurveRows);
  assert.deepEqual(
    report.refreshes.map((row) => `${row.guruId}:${row.years}`),
    [5, 10].flatMap((years) =>
      expectedManagerIdsForYears(years).map((guruId) => `${guruId}:${years}`)
    )
  );
  assert.equal(
    report.refreshes.find((row) =>
      row.guruId === "renaissance-technologies" && row.years === 5
    )?.actualStatus,
    "ready"
  );
  assert.equal(
    report.refreshes.find((row) =>
      row.guruId === "renaissance-technologies" && row.years === 10
    )?.actualStatus,
    "proxy_ready"
  );
  assert.ok(report.refreshes.every((row) =>
    row.pass === true && row.actualStatus === row.expectedStatus &&
    row.methodVersion === strictMethodVersion &&
    row.securityMasterVersion === securityMasterVersion &&
    row.refreshGeneration === `${generation}:${row.years}` &&
    (row.expectedStatus === "proxy_ready"
      ? row.proxyMethodVersion === proxyMethodVersion &&
        row.proxySecurityMasterVersion === securityMasterVersion
      : row.proxyMethodVersion === "" && row.proxySecurityMasterVersion === "")
  ));
  assert.equal(JSON.parse(fs.readFileSync(marker, "utf8")).displayable, expectedCurveRows);
});

test("prewarm rejects a Renaissance 5Y proxy even when aggregate health is green", async (context) => {
  const server = await listen(http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    response.setHeader("content-type", "application/json");
    if (url.pathname === "/api/health") {
      response.end(JSON.stringify(healthPayload()));
      return;
    }
    if (url.pathname === "/api/internal/backtests/status") {
      response.end(JSON.stringify({ running: false }));
      return;
    }
    if (url.pathname === "/api/internal/backtests/refresh") {
      const refreshGeneration = url.searchParams.get("refreshGeneration");
      const years = Number(url.searchParams.get("years"));
      const results = managerResults(years, refreshGeneration);
      if (years === 5) {
        const renaissance = results.find((row) =>
          row.guruId === "renaissance-technologies"
        );
        renaissance.status = "proxy_ready";
        renaissance.proxyMethodVersion = proxyMethodVersion;
        renaissance.proxySecurityMasterVersion = securityMasterVersion;
      }
      response.end(JSON.stringify({
        startedAt: new Date().toISOString(),
        finishedAt: new Date().toISOString(),
        refreshGeneration,
        results
      }));
      return;
    }
    response.statusCode = 404;
    response.end("{}");
  }));
  context.after(() => server.close());
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-renaissance-test-"));
  context.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const output = path.join(tempDir, "report.json");
  const marker = path.join(tempDir, "done.json");
  const result = await runPrewarm({
    port: server.address().port,
    output,
    marker,
    notBefore: new Date(Date.now() - 1000).toISOString()
  });

  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /Renaissance 5Y prewarm requires strict status=ready/i);
  assert.equal(fs.existsSync(output), false);
  assert.equal(fs.existsSync(marker), false);
});

test("prewarm retries a transient idle-status response timeout within the refresh deadline", async (context) => {
  let statusRequests = 0;
  let refreshRequests = 0;
  const server = await listen(http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    response.setHeader("content-type", "application/json");
    if (url.pathname === "/api/health") {
      response.end(JSON.stringify(healthPayload()));
      return;
    }
    if (url.pathname === "/api/internal/backtests/status") {
      statusRequests += 1;
      if (statusRequests === 2) {
        setTimeout(() => response.end(JSON.stringify({ running: false })), 100);
        return;
      }
      response.end(JSON.stringify({ running: false }));
      return;
    }
    if (url.pathname === "/api/internal/backtests/refresh") {
      refreshRequests += 1;
      const refreshGeneration = url.searchParams.get("refreshGeneration");
      const years = Number(url.searchParams.get("years"));
      response.end(JSON.stringify({
        startedAt: new Date().toISOString(),
        finishedAt: new Date().toISOString(),
        refreshGeneration,
        results: managerResults(years, refreshGeneration)
      }));
      return;
    }
    response.statusCode = 404;
    response.end("{}");
  }));
  context.after(() => server.close());
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-idle-retry-test-"));
  context.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const marker = path.join(tempDir, "done.json");
  const result = await runPrewarm({
    port: server.address().port,
    output: path.join(tempDir, "report.json"),
    marker,
    notBefore: new Date(Date.now() - 1000).toISOString(),
    refreshTimeoutMs: 300,
    statusRequestTimeoutMs: 20,
    idlePollIntervalMs: 5
  });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.ok(statusRequests >= 4, `expected retry plus window checks, received ${statusRequests}`);
  assert.equal(refreshRequests, 2);
  assert.equal(JSON.parse(fs.readFileSync(marker, "utf8")).displayable, expectedCurveRows);
});

test("prewarm fails immediately when idle-status returns non-2xx", async (context) => {
  let statusRequests = 0;
  let refreshRequests = 0;
  const server = await listen(http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    response.setHeader("content-type", "application/json");
    if (url.pathname === "/api/internal/backtests/status") {
      statusRequests += 1;
      response.statusCode = statusRequests === 1 ? 200 : 503;
      response.end(JSON.stringify({ running: false }));
      return;
    }
    if (url.pathname === "/api/internal/backtests/refresh") refreshRequests += 1;
    response.statusCode = 404;
    response.end("{}");
  }));
  context.after(() => server.close());
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-idle-http-test-"));
  context.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const result = await runPrewarm({
    port: server.address().port,
    output: path.join(tempDir, "report.json"),
    marker: path.join(tempDir, "done.json"),
    notBefore: new Date(Date.now() - 1000).toISOString(),
    refreshTimeoutMs: 300,
    statusRequestTimeoutMs: 20,
    idlePollIntervalMs: 5
  });

  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /Guru refresh status returned HTTP 503/);
  assert.equal(statusRequests, 2);
  assert.equal(refreshRequests, 0);
});

test("prewarm bounds idle-status retries by the refresh timeout", async (context) => {
  let statusRequests = 0;
  let refreshRequests = 0;
  const server = await listen(http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    if (url.pathname === "/api/internal/backtests/status") {
      statusRequests += 1;
      if (statusRequests === 1) {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ running: false }));
      }
      return;
    }
    if (url.pathname === "/api/internal/backtests/refresh") refreshRequests += 1;
    response.statusCode = 404;
    response.end("{}");
  }));
  context.after(() => server.close());
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-idle-deadline-test-"));
  context.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const startedAt = Date.now();
  const result = await runPrewarm({
    port: server.address().port,
    output: path.join(tempDir, "report.json"),
    marker: path.join(tempDir, "done.json"),
    notBefore: new Date(Date.now() - 1000).toISOString(),
    refreshTimeoutMs: 80,
    statusRequestTimeoutMs: 20,
    idlePollIntervalMs: 5
  });
  const elapsedMs = Date.now() - startedAt;

  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /did not finish within 80ms/);
  assert.match(result.stderr, /Last transport error: ETIMEDOUT/);
  assert.ok(statusRequests >= 3, `expected multiple bounded retries, received ${statusRequests}`);
  assert.equal(refreshRequests, 0);
  assert.ok(elapsedMs < 1000, `deadline exceeded test budget: ${elapsedMs}ms`);
});

test("old green health cannot hide a missing current-generation manager result", async (context) => {
  const server = await listen(http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    response.setHeader("content-type", "application/json");
    if (url.pathname === "/api/health") {
      response.end(JSON.stringify(healthPayload()));
    } else if (url.pathname === "/api/internal/backtests/status") {
      response.end(JSON.stringify({ running: false }));
    } else if (url.pathname === "/api/internal/backtests/refresh") {
      const refreshGeneration = url.searchParams.get("refreshGeneration");
      const years = Number(url.searchParams.get("years"));
      response.end(JSON.stringify({
        startedAt: new Date().toISOString(),
        finishedAt: new Date().toISOString(),
        refreshGeneration,
        results: managerResults(years, refreshGeneration).slice(0, expectedManagerCount - 1)
      }));
    } else {
      response.statusCode = 404;
      response.end("{}");
    }
  }));
  context.after(() => server.close());
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-incomplete-test-"));
  context.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const marker = path.join(tempDir, "done.json");
  const result = await runPrewarm({
    port: server.address().port,
    output: path.join(tempDir, "report.json"),
    marker,
    notBefore: new Date(Date.now() - 1000).toISOString()
  });

  assert.notEqual(result.code, 0);
  assert.equal(fs.existsSync(marker), false);
  assert.match(
    result.stderr,
    new RegExp(`${expectedManagerCount - 1}/${expectedManagerCount} unique manager results`)
  );
});

test("an already-running response cannot reuse an old green health state", async (context) => {
  const server = await listen(http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    response.setHeader("content-type", "application/json");
    if (url.pathname === "/api/health") {
      response.end(JSON.stringify(healthPayload()));
    } else if (url.pathname === "/api/internal/backtests/status") {
      response.end(JSON.stringify({ running: false }));
    } else if (url.pathname === "/api/internal/backtests/refresh") {
      response.end(JSON.stringify({ alreadyRunning: true }));
    } else {
      response.statusCode = 404;
      response.end("{}");
    }
  }));
  context.after(() => server.close());
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-old-green-test-"));
  context.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const marker = path.join(tempDir, "done.json");
  const result = await runPrewarm({
    port: server.address().port,
    output: path.join(tempDir, "report.json"),
    marker,
    notBefore: new Date(Date.now() - 1000).toISOString()
  });

  assert.notEqual(result.code, 0);
  assert.equal(fs.existsSync(marker), false);
  assert.match(result.stderr, /alreadyRunning=true/);
});

test("HTTP 503 health cannot write a marker even when every Guru curve is available", async (context) => {
  const server = await listen(http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    response.setHeader("content-type", "application/json");
    if (url.pathname === "/api/health") {
      response.statusCode = 503;
      response.end(JSON.stringify(healthPayload()));
    } else if (url.pathname === "/api/internal/backtests/status") {
      response.end(JSON.stringify({ running: false }));
    } else if (url.pathname === "/api/internal/backtests/refresh") {
      const refreshGeneration = url.searchParams.get("refreshGeneration");
      const years = Number(url.searchParams.get("years"));
      response.end(JSON.stringify({
        startedAt: new Date().toISOString(),
        finishedAt: new Date().toISOString(),
        refreshGeneration,
        results: managerResults(years, refreshGeneration)
      }));
    } else {
      response.statusCode = 404;
      response.end("{}");
    }
  }));
  context.after(() => server.close());
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-health-503-test-"));
  context.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const output = path.join(tempDir, "report.json");
  const marker = path.join(tempDir, "done.json");
  const result = await runPrewarm({
    port: server.address().port,
    output,
    marker,
    notBefore: new Date(Date.now() - 1000).toISOString()
  });

  assert.equal(result.code, 2);
  assert.equal(fs.existsSync(marker), false);
  assert.equal(JSON.parse(fs.readFileSync(output, "utf8")).healthHttpStatus, 503);
});

test("prewarm marker requires exact health topology and release identities", async (context) => {
  const cases = [
    ["manager count", { managerCount: expectedManagerCount + 1 }],
    ["windows", { windows: [5] }],
    ["strict method", { methodVersion: "stale-strict" }],
    ["proxy method", { proxyMethodVersion: "stale-proxy" }],
    ["security master", { securityMasterVersion: "stale-security" }],
    ["failures shape", { failures: null }],
    ["nonempty failures", { failures: [{ guruId: expectedManagerIds[0], years: 5 }] }]
  ];

  for (const [name, overrides] of cases) {
    await context.test(name, async (subtest) => {
      const server = await listen(http.createServer((request, response) => {
        const url = new URL(request.url, "http://127.0.0.1");
        response.setHeader("content-type", "application/json");
        if (url.pathname === "/api/health") {
          response.end(JSON.stringify(healthPayload(overrides)));
        } else if (url.pathname === "/api/internal/backtests/status") {
          response.end(JSON.stringify({ running: false }));
        } else if (url.pathname === "/api/internal/backtests/refresh") {
          const refreshGeneration = url.searchParams.get("refreshGeneration");
          const years = Number(url.searchParams.get("years"));
          response.end(JSON.stringify({
            startedAt: new Date().toISOString(),
            finishedAt: new Date().toISOString(),
            refreshGeneration,
            results: managerResults(years, refreshGeneration)
          }));
        } else {
          response.statusCode = 404;
          response.end("{}");
        }
      }));
      subtest.after(() => server.close());
      const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-prewarm-health-identity-test-"));
      subtest.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
      const output = path.join(tempDir, "report.json");
      const marker = path.join(tempDir, "done.json");
      const result = await runPrewarm({
        port: server.address().port,
        output,
        marker,
        notBefore: new Date(Date.now() - 1000).toISOString()
      });

      assert.equal(result.code, 2, result.stderr || result.stdout);
      assert.equal(fs.existsSync(marker), false);
      assert.equal(JSON.parse(fs.readFileSync(output, "utf8")).pass, false);
    });
  }
});
