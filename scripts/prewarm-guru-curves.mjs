#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import {
  enabledManager13fGurus,
  expectedGuruCurveRows,
  manager13fPublicProxyAllowed,
  requiredGuruCurveWindows,
  requiredGuruCurveWindowsFor
} from "../server/gurus.js";
import { requestLoopbackJson } from "./loopback-http-json.mjs";

// The audited 30-manager population took 30.5 minutes for 5Y and 38.5 for
// 10Y on 2026-09-23. Keep a finite whole-window deadline without aborting a
// valid sequential refresh before its observed duration. Quality gates and
// current-generation attestation remain unchanged.
const DEFAULT_REFRESH_TIMEOUT_MS = 60 * 60 * 1000;
const MAX_REFRESH_TIMEOUT_MS = 90 * 60 * 1000;
const DEFAULT_STATUS_REQUEST_TIMEOUT_MS = 10_000;
const DEFAULT_IDLE_POLL_INTERVAL_MS = 5_000;
const REQUIRED_WINDOWS = requiredGuruCurveWindows;
const EXPECTED_MANAGER_IDS = Object.freeze(enabledManager13fGurus.map((guru) => guru.id));
const EXPECTED_MANAGER_COUNT = EXPECTED_MANAGER_IDS.length;
const EXPECTED_CURVE_ROWS = expectedGuruCurveRows;
const expectedManagerIdsForYears = (years) => enabledManager13fGurus
  .filter((guru) => requiredGuruCurveWindowsFor(guru).includes(Number(years)))
  .map((guru) => guru.id);
const RETRYABLE_STATUS_ERROR_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "EPIPE",
  "ETIMEDOUT"
]);

function parseArgs(argv) {
  const options = {};
  for (const argument of argv) {
    const match = /^--([a-z-]+)=(.*)$/.exec(argument);
    if (!match) throw new Error(`Invalid argument: ${argument}`);
    options[match[1]] = match[2];
  }
  return options;
}

function loopbackBaseUrl(value) {
  const url = new URL(value || "http://127.0.0.1:8080");
  if (url.protocol !== "http:" || !["127.0.0.1", "[::1]", "::1"].includes(url.hostname)) {
    throw new Error("Guru prewarm may connect only to a loopback HTTP origin.");
  }
  url.pathname = "/";
  url.search = "";
  return url;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function refreshTimeoutMs(value) {
  const parsed = Number(value || DEFAULT_REFRESH_TIMEOUT_MS);
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > MAX_REFRESH_TIMEOUT_MS) {
    throw new Error(
      `Guru prewarm refresh timeout must be an integer from 1 to ${MAX_REFRESH_TIMEOUT_MS}ms.`
    );
  }
  return parsed;
}

function boundedPositiveInteger(value, fallback, maximum, label) {
  const parsed = Number(value || fallback);
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > maximum) {
    throw new Error(`${label} must be an integer from 1 to ${maximum}ms.`);
  }
  return parsed;
}

function isRetryableStatusTransportError(error) {
  return RETRYABLE_STATUS_ERROR_CODES.has(String(error?.code || "").toUpperCase());
}

function atomicWriteJson(filePath, payload) {
  if (!filePath) return;
  fs.mkdirSync(path.dirname(path.resolve(filePath)), { recursive: true });
  const temporary = `${path.resolve(filePath)}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, path.resolve(filePath));
}

async function waitForApi(baseUrl, secret, attempts = 90) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await requestLoopbackJson(new URL("api/internal/backtests/status", baseUrl), {
        headers: { authorization: `Bearer ${secret}` },
        timeoutMs: 10_000
      });
      if (response.status >= 200 && response.status < 600) return;
    } catch {
      // Elastic Beanstalk can still be switching the application process.
    }
    await delay(2000);
  }
  throw new Error("Local Guru API did not become reachable before prewarm timeout.");
}

async function waitForBulkRefreshIdle(baseUrl, secret, {
  timeoutMs,
  statusRequestTimeoutMs,
  pollIntervalMs
}) {
  const deadline = Date.now() + timeoutMs;
  let lastTransportError = null;
  while (Date.now() < deadline) {
    const remainingMs = Math.max(1, deadline - Date.now());
    try {
      const response = await requestLoopbackJson(
        new URL("api/internal/backtests/status", baseUrl),
        {
          headers: { authorization: `Bearer ${secret}` },
          timeoutMs: Math.min(statusRequestTimeoutMs, remainingMs)
        }
      );
      if (!response.ok) {
        throw new Error(`Guru refresh status returned HTTP ${response.status}.`);
      }
      if (!response.body.running) return;
      lastTransportError = null;
    } catch (error) {
      if (!isRetryableStatusTransportError(error)) throw error;
      lastTransportError = error;
    }

    const delayMs = Math.min(pollIntervalMs, Math.max(0, deadline - Date.now()));
    if (delayMs > 0) await delay(delayMs);
  }
  const suffix = lastTransportError
    ? ` Last transport error: ${lastTransportError.code}.`
    : "";
  throw new Error(
    `An older Guru bulk refresh did not finish within ${timeoutMs}ms.${suffix}`
  );
}

function validIsoDate(value) {
  const time = Date.parse(value || "");
  return Number.isFinite(time) ? new Date(time).toISOString() : "";
}

function curveAvailability(health) {
  return (health?.modules || []).find((module) => module?.id === "guru_backtests")
    ?.details?.curveAvailability || null;
}

function hasExactAttestedCurveMatrix(report) {
  const expectedKeys = new Set(
    REQUIRED_WINDOWS.flatMap((years) =>
      expectedManagerIdsForYears(years).map((guruId) => `${guruId}:${years}`)
    )
  );
  const actualKeys = new Set(
    report.refreshes.map((row) => `${row.guruId}:${Number(row.years)}`)
  );
  const reportedWindows = report.windows
    .map((item) => Number(item.years))
    .sort((left, right) => left - right);
  return report.refreshes.length === EXPECTED_CURVE_ROWS &&
    actualKeys.size === expectedKeys.size &&
    [...expectedKeys].every((key) => actualKeys.has(key)) &&
    reportedWindows.length === REQUIRED_WINDOWS.length &&
    REQUIRED_WINDOWS.every((years, index) => years === reportedWindows[index]);
}

function hasExactCurveAvailability(availability, {
  strictMethodVersion,
  proxyMethodVersion,
  securityMasterVersion
}) {
  const reportedWindows = Array.isArray(availability?.windows)
    ? availability.windows.map(Number).sort((left, right) => left - right)
    : [];
  return availability?.ok === true &&
    Number(availability?.managerCount) === EXPECTED_MANAGER_COUNT &&
    reportedWindows.length === REQUIRED_WINDOWS.length &&
    REQUIRED_WINDOWS.every((years, index) => years === reportedWindows[index]) &&
    Number(availability?.expectedRows) === EXPECTED_CURVE_ROWS &&
    Number(availability?.displayable) === EXPECTED_CURVE_ROWS &&
    Array.isArray(availability?.failures) &&
    availability.failures.length === 0 &&
    availability?.methodVersion === strictMethodVersion &&
    availability?.proxyMethodVersion === proxyMethodVersion &&
    availability?.securityMasterVersion === securityMasterVersion;
}

function auditWindowResults(body, {
  years,
  refreshGeneration,
  notBefore,
  startedAt,
  finishedAt,
  strictMethodVersion,
  proxyMethodVersion,
  securityMasterVersion
}) {
  if (body?.refreshGeneration !== refreshGeneration || !Array.isArray(body?.results)) {
    throw new Error(`Guru ${years}Y prewarm response lacks its exact refresh generation results.`);
  }
  const managers = body.results.filter((row) =>
    row?.guruType === "manager13f" && row?.disabled !== true
  );
  const expectedManagerIds = expectedManagerIdsForYears(years);
  const expectedManagerCount = expectedManagerIds.length;
  const identities = new Set(managers.map((row) => row.guruId));
  const exactPopulation = expectedManagerIds.every((guruId) => identities.has(guruId));
  if (managers.length !== expectedManagerCount ||
      identities.size !== expectedManagerCount ||
      !exactPopulation) {
    throw new Error(
      `Guru ${years}Y prewarm returned ${managers.length}/${expectedManagerCount} unique manager results.`
    );
  }
  const disallowedProxy = managers.find((row) =>
    row.status === "proxy_ready" &&
    !manager13fPublicProxyAllowed(row.guruId, years)
  );
  if (disallowedProxy) {
    const managerLabel = disallowedProxy.guruId === "renaissance-technologies"
      ? "Renaissance"
      : disallowedProxy.guruId;
    throw new Error(
      `${managerLabel} ${years}Y prewarm requires strict status=ready; ` +
      "proxy_ready is not allowed for this manager/window."
    );
  }
  const failures = managers.filter((row) => {
    const generatedAt = validIsoDate(row.generatedAt);
    const common = Number(row.years) === years &&
      row.refreshGeneration === refreshGeneration &&
      generatedAt && Date.parse(generatedAt) >= Date.parse(notBefore) &&
      Date.parse(generatedAt) >= Date.parse(startedAt) &&
      Date.parse(generatedAt) <= Date.parse(finishedAt) + 5_000 &&
      row.methodVersion === strictMethodVersion &&
      row.securityMasterVersion === securityMasterVersion;
    if (!common || !["ready", "proxy_ready"].includes(row.status)) return true;
    if (row.status === "proxy_ready") {
      return row.proxyMethodVersion !== proxyMethodVersion ||
        row.proxySecurityMasterVersion !== securityMasterVersion;
    }
    return Boolean(row.proxyMethodVersion || row.proxySecurityMasterVersion);
  });
  if (failures.length) {
    throw new Error(
      `Guru ${years}Y prewarm failed current-generation validation for ` +
      `${failures.length}/${expectedManagerCount} managers.`
    );
  }
  const order = new Map(expectedManagerIds.map((guruId, index) => [guruId, index]));
  const refreshes = managers
    .map((row) => ({
      guruId: row.guruId,
      guruType: row.guruType,
      disabled: Boolean(row.disabled),
      years,
      expectedStatus: row.status,
      actualStatus: row.status,
      generatedAt: validIsoDate(row.generatedAt),
      methodVersion: row.methodVersion,
      securityMasterVersion: row.securityMasterVersion,
      proxyMethodVersion: row.proxyMethodVersion || "",
      proxySecurityMasterVersion: row.proxySecurityMasterVersion || "",
      refreshGeneration,
      pass: true
    }))
    .sort((left, right) => order.get(left.guruId) - order.get(right.guruId));
  return {
    managerCount: managers.length,
    ready: managers.filter((row) => row.status === "ready").length,
    proxyReady: managers.filter((row) => row.status === "proxy_ready").length,
    refreshes
  };
}

const options = parseArgs(process.argv.slice(2));
const baseUrl = loopbackBaseUrl(options["base-url"]);
const refreshRequestTimeoutMs = refreshTimeoutMs(
  options["refresh-timeout-ms"] || process.env.GURU_PREWARM_REFRESH_TIMEOUT_MS
);
const statusRequestTimeoutMs = boundedPositiveInteger(
  options["status-request-timeout-ms"] || process.env.GURU_PREWARM_STATUS_REQUEST_TIMEOUT_MS,
  DEFAULT_STATUS_REQUEST_TIMEOUT_MS,
  DEFAULT_STATUS_REQUEST_TIMEOUT_MS,
  "Guru prewarm status request timeout"
);
const idlePollIntervalMs = boundedPositiveInteger(
  options["idle-poll-interval-ms"] || process.env.GURU_PREWARM_IDLE_POLL_INTERVAL_MS,
  DEFAULT_IDLE_POLL_INTERVAL_MS,
  DEFAULT_IDLE_POLL_INTERVAL_MS,
  "Guru prewarm idle poll interval"
);
const secret = String(process.env.INTERNAL_CRON_SECRET || process.env.CRON_SECRET || "");
if (!secret) throw new Error("Guru prewarm requires INTERNAL_CRON_SECRET in process memory.");
const refreshGeneration = String(options["refresh-generation"] || "").trim().toLowerCase();
if (!/^[a-f0-9]{64}$/.test(refreshGeneration)) {
  throw new Error(
    "Guru prewarm requires an immutable 64-hex release SHA-256 as refresh generation."
  );
}
const notBefore = validIsoDate(options["not-before"]);
if (!notBefore) throw new Error("Guru prewarm requires a valid release not-before timestamp.");
const strictMethodVersion = String(options["strict-method-version"] || "").trim();
const proxyMethodVersion = String(options["proxy-method-version"] || "").trim();
const securityMasterVersion = String(options["security-master-version"] || "").trim();
if (!strictMethodVersion || !proxyMethodVersion || !securityMasterVersion) {
  throw new Error("Guru prewarm requires strict, proxy, and security-master release identities.");
}
const windows = String(options.windows || "5,10")
  .split(",")
  .map((value) => Number(value.trim()));
if (!windows.length || windows.some((years) => ![5, 10].includes(years)) ||
    new Set(windows).size !== windows.length) {
  throw new Error("Guru prewarm windows must be the unique values 5 and/or 10.");
}

const report = {
  schemaVersion: 1,
  kind: "guru_curve_production_prewarm",
  refreshGeneration,
  startedAt: new Date().toISOString(),
  finishedAt: null,
  refreshTimeoutMs: refreshRequestTimeoutMs,
  expectations: {
    strictMethodVersion,
    proxyMethodVersion,
    securityMasterVersion,
    expectedDisplayableRows: EXPECTED_CURVE_ROWS
  },
  windows: [],
  refreshes: [],
  healthHttpStatus: null,
  curveAvailability: null,
  pass: false
};
await waitForApi(baseUrl, secret);
for (const years of windows) {
  await waitForBulkRefreshIdle(baseUrl, secret, {
    timeoutMs: refreshRequestTimeoutMs,
    statusRequestTimeoutMs,
    pollIntervalMs: idlePollIntervalMs
  });
  const url = new URL("api/internal/backtests/refresh", baseUrl);
  url.searchParams.set("years", String(years));
  url.searchParams.set("detail", "compact");
  url.searchParams.set("population", "enabled-manager13f");
  const generation = `${refreshGeneration}:${years}`;
  url.searchParams.set("refreshGeneration", generation);
  console.log(JSON.stringify({
    status: "window-started",
    years,
    refreshGeneration: generation,
    timeoutMs: refreshRequestTimeoutMs
  }));
  const response = await requestLoopbackJson(url, {
    method: "POST",
    headers: { authorization: `Bearer ${secret}` },
    timeoutMs: refreshRequestTimeoutMs
  });
  const body = response.body;
  if (!response.ok || body.alreadyRunning) {
    throw new Error(
      `Guru ${years}Y prewarm did not execute (HTTP ${response.status}, alreadyRunning=${Boolean(body.alreadyRunning)}).`
    );
  }
  const startedAt = validIsoDate(body.startedAt);
  const finishedAt = validIsoDate(body.finishedAt);
  if (!startedAt || !finishedAt || Date.parse(startedAt) < Date.parse(notBefore)) {
    throw new Error(`Guru ${years}Y prewarm is not bound to the requested release generation.`);
  }
  const resultAudit = auditWindowResults(body, {
    years,
    refreshGeneration: generation,
    notBefore,
    startedAt,
    finishedAt,
    strictMethodVersion,
    proxyMethodVersion,
    securityMasterVersion
  });
  const item = {
    years,
    httpStatus: response.status,
    startedAt,
    finishedAt,
    ok: Number(body?.ok || 0),
    failed: Number(body?.failed || 0),
    proxyAvailable: Number(body?.proxyAvailable || 0),
    alreadyRunning: Boolean(body?.alreadyRunning),
    errorCount: Array.isArray(body?.errors) ? body.errors.length : 0,
    managerCount: resultAudit.managerCount,
    ready: resultAudit.ready,
    proxyReady: resultAudit.proxyReady
  };
  report.windows.push(item);
  report.refreshes.push(...resultAudit.refreshes);
  console.log(JSON.stringify({ status: "window-finished", ...item }));
}

const healthResponse = await requestLoopbackJson(new URL("api/health", baseUrl), {
  timeoutMs: 30_000
});
const health = healthResponse.body;
report.healthHttpStatus = healthResponse.status;
report.curveAvailability = curveAvailability(health);
report.pass = Boolean(
  healthResponse.ok &&
  hasExactAttestedCurveMatrix(report) &&
  hasExactCurveAvailability(report.curveAvailability, {
    strictMethodVersion,
    proxyMethodVersion,
    securityMasterVersion
  })
);
report.finishedAt = new Date().toISOString();
atomicWriteJson(options.output, report);
console.log(JSON.stringify({
  status: report.pass ? "pass" : "fail",
  displayable: Number(report.curveAvailability?.displayable || 0),
  expectedRows: Number(report.curveAvailability?.expectedRows || 0),
  failures: Number(report.curveAvailability?.failures?.length || 0)
}));
if (!report.pass) {
  process.exitCode = 2;
} else if (options["success-marker"]) {
  atomicWriteJson(options["success-marker"], {
    status: "complete",
    recordsSha256: refreshGeneration,
    completedAt: report.finishedAt,
    displayable: report.curveAvailability.displayable,
    expectedRows: report.curveAvailability.expectedRows
  });
}
