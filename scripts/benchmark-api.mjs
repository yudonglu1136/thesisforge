#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { brotliDecompressSync, gunzipSync } from "node:zlib";
import { performance } from "node:perf_hooks";

const MIN_SAMPLES = 60;
const REQUIRED_CONCURRENCY = 20;
const REQUEST_TIMEOUT_MS = 120_000;
const REQUIRED_ROUTES = [
  "/api/valuation",
  "/api/valuation/LSEG?pricePoints=300&detail=summary",
  "/api/valuation/LSEG?pricePoints=900",
  "/api/gurus",
  "/api/backtests?years=all&detail=compact"
];

function argument(name, fallback = "") {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

function integerArgument(name, fallback) {
  const value = Number.parseInt(argument(name), 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function percentile(sorted, value) {
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * value))];
}

function timingStats(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return {
    meanMs: values.reduce((sum, value) => sum + value, 0) / values.length,
    p50Ms: percentile(sorted, 0.5),
    p95Ms: percentile(sorted, 0.95),
    p99Ms: percentile(sorted, 0.99),
    minMs: sorted[0],
    maxMs: sorted.at(-1)
  };
}

const volatileSemanticKeys = new Set([
  "cache",
  "generatedAt",
  "historyWarming",
  "localDatabase"
]);

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.keys(value)
      .filter((key) => !volatileSemanticKeys.has(key))
      .sort()
      .map((key) => [key, canonicalize(value[key])])
  );
}

function semanticHash(body) {
  const parsed = JSON.parse(body.toString("utf8"));
  return crypto.createHash("sha256").update(JSON.stringify(canonicalize(parsed))).digest("hex");
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function apiRequest(port, route, {
  encoding = "gzip, br",
  etag = "",
  timeoutMs = REQUEST_TIMEOUT_MS
} = {}) {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const call = http.request({
      host: "127.0.0.1",
      port,
      path: route,
      headers: {
        authorization: "Bearer local-dev-token",
        "accept-encoding": encoding,
        ...(etag ? { "if-none-match": etag } : {})
      }
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode,
        durationMs: performance.now() - started,
        headers: response.headers,
        body: Buffer.concat(chunks)
      }));
    });
    call.on("error", reject);
    call.setTimeout(timeoutMs, () => {
      call.destroy(new Error(`${route} exceeded the ${timeoutMs}ms request timeout`));
    });
    call.end();
  });
}

async function waitUntilReady(port, child, timeoutMs = 20_000) {
  const started = performance.now();
  while (performance.now() - started < timeoutMs) {
    if (child.exitCode !== null) throw new Error(`Benchmark server exited with ${child.exitCode}`);
    try {
      const response = await apiRequest(port, "/api/health", { encoding: "identity" });
      if ([200, 503].includes(response.status)) {
        const payload = JSON.parse(response.body.toString("utf8"));
        if (payload?.service === "thesisforge-api") return performance.now() - started;
      }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
  throw new Error(`Benchmark server was not ready after ${timeoutMs}ms`);
}

async function benchmarkRoute(port, route, { samples, concurrency }) {
  const cold = await apiRequest(port, route);
  if (cold.status !== 200) throw new Error(`${route} cold request returned ${cold.status}`);

  for (let index = 0; index < 5; index += 1) await apiRequest(port, route);
  const encoded = await apiRequest(port, route);
  if (encoded.status !== 200) throw new Error(`${route} encoded request returned ${encoded.status}`);
  const identity = await apiRequest(port, route, { encoding: "identity" });
  if (identity.status !== 200) throw new Error(`${route} identity request returned ${identity.status}`);
  const decoded = encoded.headers["content-encoding"] === "gzip"
    ? gunzipSync(encoded.body)
    : encoded.headers["content-encoding"] === "br"
      ? brotliDecompressSync(encoded.body)
      : encoded.body;
  if (semanticHash(decoded) !== semanticHash(identity.body)) {
    throw new Error(`${route} encoded response changed JSON semantics`);
  }

  const sequential = [];
  for (let index = 0; index < samples; index += 1) {
    sequential.push(await apiRequest(port, route));
  }

  const concurrentRows = [];
  const concurrentStarted = performance.now();
  for (let offset = 0; offset < samples; offset += concurrency) {
    concurrentRows.push(...await Promise.all(
      Array.from({ length: Math.min(concurrency, samples - offset) }, () => apiRequest(port, route))
    ));
  }
  const concurrentElapsedMs = performance.now() - concurrentStarted;
  const failed = [...sequential, ...concurrentRows].filter((row) => row.status !== 200);
  if (failed.length) throw new Error(`${route} produced ${failed.length} failed requests`);

  const etag = sequential.at(-1).headers.etag || "";
  const conditional = etag ? await apiRequest(port, route, { etag }) : null;
  return {
    route,
    coldMs: cold.durationMs,
    status: cold.status,
    contentEncoding: encoded.headers["content-encoding"] || "identity",
    vary: encoded.headers.vary || "",
    identityBytes: identity.body.length,
    encodedBytes: encoded.body.length,
    reductionPct: identity.body.length
      ? (1 - encoded.body.length / identity.body.length) * 100
      : 0,
    semanticSha256: semanticHash(identity.body),
    conditionalStatus: conditional?.status || null,
    sequential: {
      requests: sequential.length,
      ...timingStats(sequential.map((row) => row.durationMs))
    },
    concurrent: {
      concurrency,
      requests: concurrentRows.length,
      rps: concurrentRows.length / (concurrentElapsedMs / 1000),
      ...timingStats(concurrentRows.map((row) => row.durationMs))
    }
  };
}

function processRssBytes(pid) {
  try {
    const rssKb = Number(execFileSync("ps", ["-o", "rss=", "-p", String(pid)], { encoding: "utf8" }).trim());
    return Number.isFinite(rssKb) ? rssKb * 1024 : null;
  } catch {
    return null;
  }
}

function hashFile(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash("sha256");
    const stream = fs.createReadStream(file);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

function sourceFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name))
    .flatMap((entry) => {
      const location = path.join(directory, entry.name);
      if (entry.isDirectory()) return sourceFiles(location);
      return entry.isFile() && /\.(?:js|mjs)$/.test(entry.name) ? [location] : [];
    });
}

function runtimeSourceHash(project) {
  const files = [
    ...sourceFiles(path.join(project, "server")),
    path.join(project, "scripts", "benchmark-api.mjs"),
    path.join(project, "package.json"),
    path.join(project, "package-lock.json")
  ].filter((file) => fs.existsSync(file));
  const hash = crypto.createHash("sha256");
  for (const file of files.sort()) {
    hash.update(path.relative(project, file));
    hash.update("\0");
    hash.update(fs.readFileSync(file));
    hash.update("\0");
  }
  return hash.digest("hex");
}

const project = path.resolve(argument("project", process.cwd()));
const database = path.resolve(argument("database", path.join(project, "server/data/guru-analysis.sqlite")));
if (process.argv.includes("--ontology")) throw new Error("--ontology is retired; benchmark the active API with --database only");
const output = argument("output");
const label = argument("label", "unlabeled");
const samples = integerArgument("samples", MIN_SAMPLES);
const concurrency = integerArgument("concurrency", REQUIRED_CONCURRENCY);
if (samples < MIN_SAMPLES) {
  throw new Error(`--samples must be at least ${MIN_SAMPLES}`);
}
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "guru-api-benchmark-"));
const benchmarkDatabase = path.join(temporaryDirectory, "guru-analysis.sqlite");
fs.copyFileSync(database, benchmarkDatabase);
const inputIdentity = {
  databaseBytes: fs.statSync(benchmarkDatabase).size,
  databaseSha256: await hashFile(benchmarkDatabase)
};
const sourceSha256 = runtimeSourceHash(project);
const commit = execFileSync("git", ["rev-parse", "HEAD"], {
  cwd: project,
  encoding: "utf8"
}).trim();
const workingTreeDirty = execFileSync("git", ["status", "--porcelain"], {
  cwd: project,
  encoding: "utf8"
}).trim().length > 0;

const port = await freePort();
const logs = [];
const child = spawn(process.execPath, ["server/index.js"], {
  cwd: project,
  env: {
    ...process.env,
    NODE_ENV: "development",
    PORT: String(port),
    API_AUTH_DEV_BYPASS: "true",
    PORTFOLIO_NAV_AUTO_CAPTURE: "false",
    DIVIDEND_CALENDAR_AUTO_REFRESH: "false",
    GURU_BACKTEST_AUTO_REFRESH: "false",
    BACKTEST_STALE_BACKGROUND_REFRESH: "false",
    BACKTEST_CACHE_TTL_HOURS: "0",
    SEC_REQUEST_TIMEOUT_MS: "5000",
    PUBLIC_REQUEST_TIMEOUT_MS: "5000",
    SYNC_BUNDLED_VALUATION_SNAPSHOTS: "false",
    SYNC_BUNDLED_GURU_BACKTESTS: "false",
    SYNC_BUNDLED_DIVIDEND_CALENDAR: "false",
    SYNC_BUNDLED_PODCAST_INSIGHTS: "false",
    SQLITE_DB_PATH: benchmarkDatabase
  },
  stdio: ["ignore", "pipe", "pipe"]
});
child.stdout.on("data", (chunk) => logs.push(chunk.toString()));
child.stderr.on("data", (chunk) => logs.push(chunk.toString()));

try {
  const startupReadyMs = await waitUntilReady(port, child);
  const results = [];
  for (const route of REQUIRED_ROUTES) {
    process.stderr.write(`[benchmark] starting ${route}\n`);
    results.push(await benchmarkRoute(port, route, { samples, concurrency }));
    process.stderr.write(`[benchmark] completed ${route}\n`);
  }
  if (runtimeSourceHash(project) !== sourceSha256) {
    throw new Error("Runtime source files changed during the benchmark run");
  }
  const report = {
    schemaVersion: 3,
    label,
    generatedAt: new Date().toISOString(),
    commit,
    workingTreeDirty,
    sourceSha256,
    runtime: { node: process.version, platform: `${os.platform()} ${os.release()}`, arch: os.arch() },
    inputs: {
      ...inputIdentity,
      samples,
      concurrency
    },
    process: {
      startupReadyMs,
      rssBytes: processRssBytes(child.pid)
    },
    routes: results
  };
  const serialized = `${JSON.stringify(report, null, 2)}\n`;
  if (output) {
    const outputPath = path.resolve(output);
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, serialized);
  }
  process.stdout.write(serialized);
} catch (error) {
  process.stderr.write(`${error.stack || error.message}\n${logs.join("").slice(-4000)}`);
  process.exitCode = 1;
} finally {
  child.kill("SIGTERM");
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}
