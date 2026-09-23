#!/usr/bin/env node

/**
 * Recompute the enabled manager-13F curves against an isolated SQLite snapshot.
 *
 * The coordinator never imports the application database module. It creates a
 * consistent, writable copy of the selected source database and launches a
 * worker with SQLITE_DB_PATH pointed only at that copy. Price cache writes are
 * likewise redirected below the temporary work directory. The source database
 * is therefore read-only for the entire acceptance run.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";
import {
  enabledManager13fGurus,
  manager13fPublicProxyAllowed,
  requiredGuruCurveWindows,
  requiredGuruCurveWindowsFor
} from "../server/gurus.js";

const scriptPath = fileURLToPath(import.meta.url);
const scriptsDir = path.dirname(scriptPath);
const repoRoot = path.dirname(scriptsDir);
const defaultSourceDatabase = path.join(repoRoot, "server", "data", "guru-analysis.sqlite");
const expectedManagerCount = enabledManager13fGurus.length;
const defaultWindows = requiredGuruCurveWindows;
const reportBaseName = "guru-curve-restoration-acceptance";

function optionValue(argv, index, name) {
  const value = argv[index];
  const prefix = `${name}=`;
  if (value.startsWith(prefix)) return { value: value.slice(prefix.length), consumed: 0 };
  if (value === name) {
    const following = argv[index + 1];
    if (!following || following.startsWith("--")) {
      throw new Error(`${name} requires a value`);
    }
    return { value: following, consumed: 1 };
  }
  return null;
}

export function parseCliArgs(argv = []) {
  const options = {
    db: defaultSourceDatabase,
    output: "",
    json: "",
    markdown: "",
    windows: defaultWindows.join(","),
    keepWorkDb: false,
    help: false,
    internalWorker: false,
    workDb: "",
    result: ""
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    if (argument === "--keep-work-db") {
      options.keepWorkDb = true;
      continue;
    }
    if (argument === "--internal-worker") {
      options.internalWorker = true;
      continue;
    }

    let parsed = optionValue(argv, index, "--db");
    if (parsed) {
      options.db = parsed.value;
      index += parsed.consumed;
      continue;
    }
    parsed = optionValue(argv, index, "--output");
    if (parsed) {
      options.output = parsed.value;
      index += parsed.consumed;
      continue;
    }
    parsed = optionValue(argv, index, "--json");
    if (parsed) {
      options.json = parsed.value;
      index += parsed.consumed;
      continue;
    }
    parsed = optionValue(argv, index, "--markdown");
    if (parsed) {
      options.markdown = parsed.value;
      index += parsed.consumed;
      continue;
    }
    parsed = optionValue(argv, index, "--windows");
    if (parsed) {
      options.windows = parsed.value;
      index += parsed.consumed;
      continue;
    }
    parsed = optionValue(argv, index, "--work-db");
    if (parsed) {
      options.workDb = parsed.value;
      index += parsed.consumed;
      continue;
    }
    parsed = optionValue(argv, index, "--result");
    if (parsed) {
      options.result = parsed.value;
      index += parsed.consumed;
      continue;
    }
    throw new Error(`Unknown argument: ${argument}`);
  }

  return options;
}

export function normalizeWindows(value = defaultWindows.join(",")) {
  const tokens = String(value || "").split(",").map((item) => item.trim());
  const parsed = tokens.map(Number);
  if (tokens.some((item) => !item) || parsed.some((years) => !Number.isInteger(years))) {
    throw new Error("--windows must contain 5, 10, or 5,10");
  }
  const windows = [...new Set(parsed)];
  if (!windows.length || windows.some((years) => !defaultWindows.includes(years))) {
    throw new Error("--windows must contain 5, 10, or 5,10");
  }
  return defaultWindows.filter((years) => windows.includes(years));
}

function timestampForPath(date = new Date()) {
  return date.toISOString().replace(/[:.]/g, "-");
}

export function resolveReportPaths(options = {}, now = new Date()) {
  const explicitJson = String(options.json || "").trim();
  const explicitMarkdown = String(options.markdown || "").trim();
  const output = String(options.output || "").trim();
  let jsonPath = explicitJson ? path.resolve(explicitJson) : "";
  let markdownPath = explicitMarkdown ? path.resolve(explicitMarkdown) : "";

  if (output) {
    const resolved = path.resolve(output);
    const extension = path.extname(resolved).toLowerCase();
    if (extension === ".json") {
      jsonPath ||= resolved;
      markdownPath ||= resolved.slice(0, -extension.length) + ".md";
    } else if (extension === ".md" || extension === ".markdown") {
      markdownPath ||= resolved;
      jsonPath ||= resolved.slice(0, -extension.length) + ".json";
    } else {
      jsonPath ||= path.join(resolved, `${reportBaseName}.json`);
      markdownPath ||= path.join(resolved, `${reportBaseName}.md`);
    }
  }

  if (!jsonPath && !markdownPath) {
    const outputDir = path.join(
      os.tmpdir(),
      "guru-curve-acceptance",
      timestampForPath(now)
    );
    jsonPath = path.join(outputDir, `${reportBaseName}.json`);
    markdownPath = path.join(outputDir, `${reportBaseName}.md`);
  } else if (!jsonPath) {
    const extension = path.extname(markdownPath);
    jsonPath = markdownPath.slice(0, -extension.length) + ".json";
  } else if (!markdownPath) {
    const extension = path.extname(jsonPath);
    markdownPath = jsonPath.slice(0, -extension.length) + ".md";
  }

  if (jsonPath === markdownPath) {
    throw new Error("JSON and Markdown outputs must use different paths");
  }
  return { jsonPath, markdownPath };
}

function atomicWrite(filePath, contents) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, contents);
  fs.renameSync(temporary, filePath);
}

function atomicWriteJson(filePath, payload) {
  atomicWrite(filePath, `${JSON.stringify(payload, null, 2)}\n`);
}

async function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(filePath)) hash.update(chunk);
  return hash.digest("hex");
}

export async function snapshotDatabase(sourcePath, destinationPath) {
  const resolvedSource = fs.realpathSync(path.resolve(sourcePath));
  const resolvedDestination = path.resolve(destinationPath);
  if (resolvedSource === resolvedDestination) {
    throw new Error("The isolated database path must differ from the source database");
  }
  const before = fs.statSync(resolvedSource);
  if (!before.isFile()) throw new Error(`Source database is not a file: ${resolvedSource}`);
  const sourceFileSha256 = await sha256File(resolvedSource);

  fs.mkdirSync(path.dirname(resolvedDestination), { recursive: true });
  let destinationCreated = false;
  try {
    // Reserve the destination without permitting an existing file to be
    // overwritten. SQLite accepts an existing empty file for VACUUM INTO.
    // VACUUM INTO reads through SQLite's transaction layer, so committed WAL
    // frames are included in one consistent snapshot without checkpointing or
    // otherwise mutating the live source database. This also works on Node 22,
    // whose initial node:sqlite DatabaseSync API did not expose serialize().
    const destinationFd = fs.openSync(resolvedDestination, "wx", 0o600);
    fs.closeSync(destinationFd);
    destinationCreated = true;

    const source = new DatabaseSync(resolvedSource, { readOnly: true });
    try {
      source.prepare("VACUUM INTO ?").run(resolvedDestination);
    } finally {
      source.close();
    }
    fs.chmodSync(resolvedDestination, 0o600);

    const copy = new DatabaseSync(resolvedDestination, { readOnly: true });
    let integrity;
    try {
      integrity = copy.prepare("PRAGMA integrity_check").get()?.integrity_check || "unknown";
    } finally {
      copy.close();
    }
    if (integrity !== "ok") {
      throw new Error(`Isolated database failed integrity_check: ${integrity}`);
    }
    const afterSnapshot = fs.statSync(resolvedSource);
    const sourceFileSha256AfterSnapshot = await sha256File(resolvedSource);
    const snapshot = fs.statSync(resolvedDestination);
    const snapshotSha256 = await sha256File(resolvedDestination);

    return {
      sourcePath: resolvedSource,
      sourceBytes: before.size,
      sourceModifiedAt: before.mtime.toISOString(),
      sourceFileSha256,
      sourceStableDuringSnapshot:
        before.size === afterSnapshot.size &&
        before.mtime.toISOString() === afterSnapshot.mtime.toISOString() &&
        sourceFileSha256 === sourceFileSha256AfterSnapshot,
      sourceFileSha256AfterSnapshot,
      snapshotBytes: snapshot.size,
      snapshotSha256,
      integrityCheck: integrity
    };
  } catch (error) {
    if (destinationCreated) fs.rmSync(resolvedDestination, { force: true });
    throw error;
  }
}

function finiteNumber(...values) {
  for (const value of values) {
    const number = Number(value);
    if (Number.isFinite(number)) return number;
  }
  return null;
}

function minimumFinite(values = []) {
  const finite = values.map(Number).filter(Number.isFinite);
  return finite.length ? Math.min(...finite) : null;
}

function strictMinimumCoverage(payload) {
  return finiteNumber(
    payload?.dataQuality?.minimumObservedExecutionCoverage,
    minimumFinite((payload?.dataQuality?.coverageFailures || []).map((row) => row?.coveragePct)),
    minimumFinite((payload?.rebalances || []).map((row) => row?.coveragePct))
  );
}

function failureDetails(strictPayload, returnedPayload, error) {
  const quality = strictPayload?.dataQuality || {};
  const code = String(
    quality.failure?.code ||
      quality.priceFailure?.code ||
      (quality.coverageFailures?.length ? "execution_coverage_below_minimum" : "") ||
      quality.proxyFailure?.code ||
      returnedPayload?.dataQuality?.failure?.code ||
      (error ? "computation_error" : "backtest_not_ready")
  );
  const reason = String(
    error?.message ||
      strictPayload?.method?.reason ||
      returnedPayload?.method?.reason ||
      quality.failure?.message ||
      quality.proxyFailure?.message ||
      code
  );
  return { code, reason };
}

function payloadWindow(payload) {
  const equity = Array.isArray(payload?.equity) ? payload.equity : [];
  return {
    start: payload?.window?.start || equity[0]?.date || null,
    end: payload?.window?.end || equity.at(-1)?.date || null
  };
}

function versionsMatch(payload, expected = {}, { proxy = false, years = null } = {}) {
  if (!payload) return false;
  if (expected.methodVersion && payload?.method?.version !== expected.methodVersion) return false;
  if (
    expected.securityMasterVersion &&
    payload?.method?.securityMasterVersion !== expected.securityMasterVersion
  ) return false;
  if (proxy && expected.proxyMethodVersion) {
    if (payload?.method?.variant !== expected.proxyMethodVersion) return false;
    if (payload?.proxy?.methodVersion !== expected.proxyMethodVersion) return false;
  }
  if (
    proxy &&
    expected.securityMasterVersion &&
    payload?.proxy?.securityMasterVersion !== expected.securityMasterVersion
  ) return false;
  if (years != null && Number(payload?.method?.years) !== Number(years)) return false;
  return true;
}

export function summarizeBacktestOutcome({
  guru,
  years,
  returnedPayload = null,
  strictPayload = null,
  proxyPayload = null,
  expected = {},
  thresholds = {},
  durationMs = 0,
  error = null
}) {
  const strictReady = strictPayload?.status === "ready" &&
    versionsMatch(strictPayload, expected, { years });
  const proxyAllowed = manager13fPublicProxyAllowed(guru.id, years);
  const linkedProxy = proxyAllowed &&
    proxyPayload?.status === "proxy_ready" &&
    versionsMatch(proxyPayload, expected, { proxy: true, years }) &&
    strictPayload?.status === "insufficient_data" &&
    proxyPayload?.proxy?.strictFailureGeneratedAt === strictPayload?.generatedAt;
  const candidateOutcome = strictReady
    ? "ready"
    : linkedProxy
      ? "proxy_ready"
      : "failure";
  const selectedPayload = strictReady ? strictPayload : linkedProxy ? proxyPayload : returnedPayload;
  const equity = Array.isArray(selectedPayload?.equity) ? selectedPayload.equity : [];
  const window = payloadWindow(selectedPayload);
  const observedStrictCoverage = strictMinimumCoverage(strictPayload);
  const proxyCoverage = finiteNumber(
    proxyPayload?.proxy?.minimumSelectedBookCoverage,
    proxyPayload?.dataQuality?.proxyMinimumSelectedBookCoverage
  );
  const proxyMinimumPositions = finiteNumber(proxyPayload?.proxy?.minimumIncludedPositions);
  const minimumCoverage = candidateOutcome === "proxy_ready"
    ? proxyCoverage
    : observedStrictCoverage;
  const violations = [];

  if (candidateOutcome !== "failure" && equity.length < 2) {
    violations.push("curve_has_fewer_than_two_points");
  }
  if (candidateOutcome !== "failure" && (!window.start || !window.end)) {
    violations.push("curve_window_missing");
  }
  if (
    candidateOutcome === "ready" &&
    Number.isFinite(Number(thresholds.minimumExecutionCoverage)) &&
    (!Number.isFinite(observedStrictCoverage) ||
      observedStrictCoverage + 1e-12 < Number(thresholds.minimumExecutionCoverage))
  ) {
    violations.push("strict_coverage_below_minimum");
  }
  if (
    candidateOutcome === "proxy_ready" &&
    Number.isFinite(Number(thresholds.minimumProxyCoverage)) &&
    (!Number.isFinite(proxyCoverage) ||
      proxyCoverage + 1e-12 < Number(thresholds.minimumProxyCoverage))
  ) {
    violations.push("proxy_coverage_below_minimum");
  }
  if (
    candidateOutcome === "proxy_ready" &&
    Number.isFinite(Number(thresholds.minimumProxyPositions)) &&
    (!Number.isFinite(proxyMinimumPositions) ||
      proxyMinimumPositions < Number(thresholds.minimumProxyPositions))
  ) {
    violations.push("proxy_positions_below_minimum");
  }

  const outcome = violations.length ? "failure" : candidateOutcome;
  const failure = failureDetails(strictPayload, returnedPayload, error);
  const compatibilityFailure = proxyPayload?.status === "proxy_ready" && !proxyAllowed
    ? {
        code: "public_proxy_not_allowed_for_manager_window",
        reason: "A public proxy is not allowed to satisfy this manager/window release contract."
      }
    : strictPayload?.status === "ready"
    ? {
        code: "strict_method_incompatible",
        reason: "The persisted strict curve does not match the requested window or current method/security-master versions."
      }
    : proxyPayload?.status === "proxy_ready" || returnedPayload?.status === "proxy_ready"
      ? {
          code: "proxy_incompatible_or_unlinked",
          reason: "The proxy curve is not compatible with the current method/security master or is not linked to the exact persisted strict failure."
        }
      : null;
  return {
    guruId: guru.id,
    guruName: guru.name,
    years,
    outcome,
    reportedOutcome: candidateOutcome,
    curveKind: outcome === "ready" ? "strict" : outcome === "proxy_ready" ? "proxy" : "none",
    displayable: outcome !== "failure" && equity.length >= 2,
    strictStatus: strictPayload?.status || "missing",
    proxyStatus: proxyPayload?.status || "missing",
    returnedStatus: returnedPayload?.status || (error ? "error" : "missing"),
    curvePoints: equity.length,
    startDate: window.start,
    endDate: window.end,
    minimumCoverage,
    strictMinimumCoverage: observedStrictCoverage,
    proxyMinimumCoverage: proxyCoverage,
    proxyMinimumPositions,
    strictFailureCode: proxyPayload?.dataQuality?.strictFailureCode || null,
    contractViolations: violations,
    failureCode: outcome === "failure"
      ? violations[0] || compatibilityFailure?.code || failure.code
      : null,
    failureReason: outcome === "failure"
      ? violations.length
        ? violations.join(", ")
        : compatibilityFailure?.reason || failure.reason
      : null,
    methodVersion: selectedPayload?.method?.version || strictPayload?.method?.version || null,
    securityMasterVersion:
      selectedPayload?.method?.securityMasterVersion ||
      strictPayload?.method?.securityMasterVersion ||
      null,
    proxyMethodVersion: proxyPayload?.proxy?.methodVersion || null,
    generatedAt: selectedPayload?.generatedAt || strictPayload?.generatedAt || null,
    durationMs: Math.max(0, Math.round(Number(durationMs) || 0))
  };
}

export function summarizeAcceptance(
  results,
  managerCount = expectedManagerCount,
  windows = defaultWindows
) {
  const byWindow = {};
  for (const years of windows) {
    const rows = results.filter((row) => row.years === years);
    byWindow[`${years}Y`] = {
      total: rows.length,
      strictReady: rows.filter((row) => row.outcome === "ready").length,
      proxyReady: rows.filter((row) => row.outcome === "proxy_ready").length,
      failure: rows.filter((row) => row.outcome === "failure").length,
      displayable: rows.filter((row) => row.displayable).length
    };
  }
  const requiredKeys = enabledManager13fGurus.flatMap(g =>
    requiredGuruCurveWindowsFor(g).filter(y => windows.includes(y)).map(y => `${g.id}:${y}`));
  const actualKeys = results.map(row => `${row.guruId}:${row.years}`);
  const expectedRows = requiredKeys.length;
  const failures = results.filter((row) => row.outcome === "failure").length;
  const displayable = results.filter((row) => row.displayable).length;
  return {
    expectedManagerCount,
    managerCount,
    expectedRows,
    actualRows: results.length,
    strictReady: results.filter((row) => row.outcome === "ready").length,
    proxyReady: results.filter((row) => row.outcome === "proxy_ready").length,
    failures,
    displayable,
    byWindow,
    pass:
      managerCount === expectedManagerCount &&
      results.length === expectedRows &&
      new Set(actualKeys).size === expectedRows &&
      requiredKeys.every(key => actualKeys.includes(key)) &&
      failures === 0 &&
      displayable === expectedRows
  };
}

function markdownCell(value) {
  return String(value ?? "—").replace(/\|/g, "\\|").replace(/\r?\n/g, " ");
}

function formatCoverage(value) {
  const number = Number(value);
  return Number.isFinite(number) ? `${(number * 100).toFixed(1)}%` : "—";
}

function formatDuration(milliseconds) {
  const value = Number(milliseconds);
  return Number.isFinite(value) ? `${(value / 1000).toFixed(1)}s` : "—";
}

export function renderMarkdownReport(report) {
  const windows = report.windows || defaultWindows;
  const summary = report.summary || summarizeAcceptance(
    report.results || [],
    report.managerCount,
    windows
  );
  const lines = [
    "# Guru Curve Restoration Acceptance",
    "",
    `- Verdict: **${summary.pass ? "PASS" : "FAIL"}**`,
    ...(report.fatalError ? [`- Fatal worker error: ${markdownCell(report.fatalError.message)}`] : []),
    `- Generated at: ${report.finishedAt || report.generatedAt || "—"}`,
    `- Enabled manager13f population: ${report.managerCount ?? "—"} (required: ${expectedManagerCount})`,
    `- Disabled manager13f profiles excluded: ${(report.disabledManagers || []).map((guru) => guru.name || guru.id).join(", ") || "none recorded"}`,
    `- Windows recomputed: ${windows.map((years) => `${years}Y`).join(", ")}`,
    `- Displayable curves: ${summary.displayable}/${summary.expectedRows}`,
    `- Strict ready: ${summary.strictReady}; proxy ready: ${summary.proxyReady}; failures: ${summary.failures}`,
    `- Source DB was opened read-only and computations wrote only to an isolated snapshot: ${report.isolation?.sourceOpenedReadOnly ? "yes" : "unknown"}`,
    `- Source snapshot SHA-256: ${report.sourceDatabase?.snapshotSha256 || "—"}`,
    `- Security-master version: ${report.engine?.securityMasterVersion || "—"}`,
    "",
    "## Window summary",
    "",
    "| Window | Managers | Strict ready | Proxy ready | Failure | Displayable |",
    "| --- | ---: | ---: | ---: | ---: | ---: |"
  ];
  for (const years of windows) {
    const row = summary.byWindow?.[`${years}Y`] || {};
    lines.push(
      `| ${years}Y | ${row.total || 0} | ${row.strictReady || 0} | ${row.proxyReady || 0} | ${row.failure || 0} | ${row.displayable || 0} |`
    );
  }
  lines.push(
    "",
    "## Manager-by-manager results",
    "",
    "| # | Manager | Window | Outcome | Points | Start | End | Min coverage | Proxy min positions | Failure | Duration |",
    "| ---: | --- | ---: | --- | ---: | --- | --- | ---: | ---: | --- | ---: |"
  );
  for (const [index, row] of (report.results || []).entries()) {
    const failure = row.failureCode
      ? `${row.failureCode}: ${row.failureReason || ""}`
      : "—";
    lines.push(
      `| ${index + 1} | ${markdownCell(row.guruName)} | ${row.years}Y | ${row.outcome} | ${row.curvePoints} | ${markdownCell(row.startDate)} | ${markdownCell(row.endDate)} | ${formatCoverage(row.minimumCoverage)} | ${row.proxyMinimumPositions ?? "—"} | ${markdownCell(failure)} | ${formatDuration(row.durationMs)} |`
    );
  }
  lines.push(
    "",
    "## Acceptance rules",
    "",
    `- Strict curves must use the current method/security-master versions, contain at least two points, and keep minimum selected-book execution coverage at or above ${formatCoverage(report.thresholds?.minimumExecutionCoverage)}.`,
    `- Proxy curves must be linked to the exact persisted strict failure, contain at least two points, retain at least ${formatCoverage(report.thresholds?.minimumProxyCoverage)} of the selected disclosed book in every quarter, and include at least ${report.thresholds?.minimumProxyPositions ?? "—"} priceable holdings per quarter.`,
    "- A proxy is displayable but remains separately labeled; it never counts as a strict-ready backtest.",
    "- The temporary SQLite copy and price cache are outside the repository. No holdings, price rows, provider cache, or paid-source data are included in these reports.",
    ""
  );
  return lines.join("\n");
}

function tableExists(database, name) {
  return Boolean(database.prepare(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
  ).get(name));
}

function clearBacktestRows(workDbPath, managerIds, windows) {
  const database = new DatabaseSync(workDbPath);
  try {
    for (const table of ["guru_backtests", "guru_backtest_proxies"]) {
      if (!tableExists(database, table)) continue;
      const statement = database.prepare(
        `DELETE FROM ${table} WHERE guru_id = ? AND years = ?`
      );
      for (const guruId of managerIds) {
        for (const years of windows) statement.run(guruId, years);
      }
    }
  } finally {
    database.close();
  }
}

async function runWorker({ workDb, result, windows: windowOption }) {
  if (process.env.GURU_CURVE_ACCEPTANCE_WORKER !== "1") {
    throw new Error("The internal worker may only be launched by the isolated coordinator");
  }
  const resolvedWorkDb = path.resolve(workDb);
  const resolvedResult = path.resolve(result);
  const windows = normalizeWindows(windowOption);
  process.env.SQLITE_DB_PATH = resolvedWorkDb;
  process.env.PRICE_CACHE_DIR = path.join(path.dirname(resolvedWorkDb), "price-cache");
  process.env.GURU_BACKTEST_AUTO_REFRESH = "false";
  process.env.BACKTEST_STALE_BACKGROUND_REFRESH = "false";

  const { enabledManager13fGurus: managers, gurus } = await import("../server/gurus.js");
  const disabledManagers = gurus.filter((guru) =>
    guru.type === "manager13f" && guru.disableSimulation
  );
  if (managers.length !== expectedManagerCount) {
    throw new Error(
      `Enabled manager13f population is ${managers.length}; expected ${expectedManagerCount}`
    );
  }
  clearBacktestRows(resolvedWorkDb, managers.map((guru) => guru.id), windows);

  const backtest = await import("../server/backtest.js");
  const database = await import("../server/localDatabase.js");
  const startedAt = new Date().toISOString();
  const report = {
    schemaVersion: 1,
    kind: "guru_curve_restoration_local_acceptance",
    startedAt,
    finishedAt: null,
    managerCount: managers.length,
    managerIds: managers.map((guru) => guru.id),
    disabledManagers: disabledManagers.map((guru) => ({
      id: guru.id,
      name: guru.name
    })),
    windows,
    engine: {
      methodVersion: backtest.manager13fBacktestMethodVersion,
      proxyMethodVersion: backtest.manager13fProxyMethodVersion,
      securityMasterVersion: backtest.manager13fSecurityMasterVersion
    },
    thresholds: {
      minimumExecutionCoverage: 0.9,
      minimumProxyCoverage: backtest.minProxyCoverage,
      minimumProxyPositions: backtest.minProxyPositions
    },
    results: [],
    summary: summarizeAcceptance([], managers.length, windows)
  };
  atomicWriteJson(resolvedResult, report);

  for (const guru of managers) {
    for (const years of windows) {
      if (!requiredGuruCurveWindowsFor(guru).includes(years)) continue;
      const itemStartedAt = Date.now();
      let returnedPayload = null;
      let error = null;
      console.log(`[curve-acceptance] ${guru.id} ${years}Y: recomputing`);
      try {
        returnedPayload = await backtest.loadGuruBacktest(guru.id, {
          refresh: true,
          computeFromDisclosures: true,
          years,
          detail: "full",
          persist: true,
          allowCold: true,
          shareComputation: false,
          preserveReadyOnFailure: false
        });
      } catch (caught) {
        error = caught instanceof Error ? caught : new Error(String(caught));
      }

      const strictPayload = database.readGuruBacktest(guru.id, years);
      const proxyPayload = database.readGuruBacktestProxy(guru.id, years);
      const row = summarizeBacktestOutcome({
        guru,
        years,
        returnedPayload,
        strictPayload,
        proxyPayload,
        expected: report.engine,
        thresholds: report.thresholds,
        durationMs: Date.now() - itemStartedAt,
        error
      });
      report.results.push(row);
      report.summary = summarizeAcceptance(report.results, managers.length, windows);
      atomicWriteJson(resolvedResult, report);
      console.log(
        `[curve-acceptance] ${guru.id} ${years}Y: ${row.outcome} ` +
        `(${row.curvePoints} points, min coverage ${formatCoverage(row.minimumCoverage)})`
      );
    }
  }

  report.finishedAt = new Date().toISOString();
  report.summary = summarizeAcceptance(report.results, managers.length, windows);
  atomicWriteJson(resolvedResult, report);
  return report.summary.pass ? 0 : 2;
}

function childExit(child) {
  return new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
}

function usage() {
  return `Usage:
  node scripts/audit-guru-curve-restoration.mjs [options]

Options:
  --db PATH             Source SQLite database (opened read-only; default: server/data/guru-analysis.sqlite)
  --output PATH         Output directory, .json path, or .md path
  --json PATH           Explicit JSON report path
  --markdown PATH       Explicit Markdown report path
  --windows 5,10        Windows to recompute (allowed: 5, 10, or 5,10; default: 5,10)
  --keep-work-db        Keep the isolated DB and price cache under the system temp directory
  --help                Show this help

The default run recomputes 5Y and 10Y for all ${expectedManagerCount} enabled manager13f profiles.
Reports default to the system temp directory. The source database is never
passed to application code and is never mutated.`;
}

async function runCoordinator(options) {
  const sourcePath = path.resolve(options.db || defaultSourceDatabase);
  const windows = normalizeWindows(options.windows);
  if (!fs.existsSync(sourcePath)) throw new Error(`Source database not found: ${sourcePath}`);
  const sourceRealPath = fs.realpathSync(sourcePath);
  const { jsonPath, markdownPath } = resolveReportPaths(options);
  const reportTargets = [jsonPath, markdownPath].map((target) =>
    fs.existsSync(target) ? fs.realpathSync(target) : path.resolve(target)
  );
  if (reportTargets.includes(sourceRealPath)) {
    throw new Error("A report path cannot overwrite the source database");
  }
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-curve-acceptance-work-"));
  const workDb = path.join(workDir, "guru-analysis.acceptance.sqlite");
  const workerResult = path.join(workDir, "worker-result.json");
  let sourceDatabase = null;
  let workerExit = { code: 1, signal: null };
  let report = null;

  try {
    console.log(`[curve-acceptance] creating read-only snapshot of ${sourcePath}`);
    sourceDatabase = await snapshotDatabase(sourceRealPath, workDb);
    console.log(`[curve-acceptance] isolated DB: ${workDb}`);
    const child = spawn(
      process.execPath,
      [
        scriptPath,
        "--internal-worker",
        `--work-db=${workDb}`,
        `--result=${workerResult}`,
        `--windows=${windows.join(",")}`
      ],
      {
        cwd: repoRoot,
        env: {
          ...process.env,
          GURU_CURVE_ACCEPTANCE_WORKER: "1",
          SQLITE_DB_PATH: workDb,
          PRICE_CACHE_DIR: path.join(workDir, "price-cache"),
          GURU_BACKTEST_AUTO_REFRESH: "false",
          BACKTEST_STALE_BACKGROUND_REFRESH: "false"
        },
        stdio: "inherit"
      }
    );
    workerExit = await childExit(child);
    report = fs.existsSync(workerResult)
      ? JSON.parse(fs.readFileSync(workerResult, "utf8"))
      : {
          schemaVersion: 1,
          kind: "guru_curve_restoration_local_acceptance",
          startedAt: null,
          finishedAt: new Date().toISOString(),
          managerCount: 0,
          windows,
          results: [],
          summary: summarizeAcceptance([], 0, windows)
        };

    const after = fs.statSync(sourceRealPath);
    const afterHash = await sha256File(sourceRealPath);
    report.finishedAt ||= new Date().toISOString();
    report.sourceDatabase = {
      ...sourceDatabase,
      sourceUnchangedDuringRun:
        sourceDatabase.sourceBytes === after.size &&
        sourceDatabase.sourceModifiedAt === after.mtime.toISOString() &&
        sourceDatabase.sourceFileSha256 === afterHash &&
        sourceDatabase.sourceStableDuringSnapshot,
      sourceFileSha256AfterRun: afterHash
    };
    report.isolation = {
      sourceOpenedReadOnly: true,
      applicationDatabaseWasSnapshot: true,
      priceCacheOutsideRepository: true,
      workDatabaseKept: Boolean(options.keepWorkDb),
      workDirectory: options.keepWorkDb ? workDir : null
    };
    report.worker = workerExit;
    report.summary = summarizeAcceptance(
      report.results || [],
      report.managerCount || 0,
      report.windows || windows
    );
    if (workerExit.code !== 0 && report.summary.pass) report.summary.pass = false;

    atomicWriteJson(jsonPath, report);
    atomicWrite(markdownPath, `${renderMarkdownReport(report)}\n`);
    console.log(`[curve-acceptance] JSON: ${jsonPath}`);
    console.log(`[curve-acceptance] Markdown: ${markdownPath}`);
    console.log(`[curve-acceptance] verdict: ${report.summary.pass ? "PASS" : "FAIL"}`);
    return report.summary.pass ? 0 : workerExit.code || 2;
  } finally {
    if (!options.keepWorkDb) {
      fs.rmSync(workDir, { recursive: true, force: true });
    } else {
      console.log(`[curve-acceptance] retained isolated work directory: ${workDir}`);
    }
  }
}

function isCommandLineEntry() {
  if (!process.argv[1]) return false;
  return import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
}

if (isCommandLineEntry()) {
  let options;
  try {
    options = parseCliArgs(process.argv.slice(2));
    if (options.help) {
      console.log(usage());
      process.exitCode = 0;
    } else if (options.internalWorker) {
      if (!options.workDb || !options.result) {
        throw new Error("Internal worker requires --work-db and --result");
      }
      process.exitCode = await runWorker(options);
    } else {
      process.exitCode = await runCoordinator(options);
    }
  } catch (error) {
    console.error(`[curve-acceptance] ${error.message}`);
    if (options?.internalWorker && options.result) {
      let failedWindows = defaultWindows;
      try {
        failedWindows = normalizeWindows(options.windows);
      } catch {
        // Retain the default shape while reporting the original parsing error.
      }
      const failedReport = {
        schemaVersion: 1,
        kind: "guru_curve_restoration_local_acceptance",
        startedAt: null,
        finishedAt: new Date().toISOString(),
        managerCount: 0,
        windows: failedWindows,
        fatalError: {
          code: "worker_initialization_failed",
          message: error.message
        },
        results: [],
        summary: summarizeAcceptance([], 0, failedWindows)
      };
      atomicWriteJson(path.resolve(options.result), failedReport);
    }
    process.exitCode = 1;
  }
}
