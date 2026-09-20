import fs from "node:fs";
import os from "node:os";
import { auditPublicHoldingsProxyPayload } from "./backtestProxyAudit.js";
import { auditManager13fStrictReadyPayload } from "./backtestStrictAudit.js";
import {
  enabledManager13fGurus,
  expectedGuruCurveRows,
  manager13fPublicProxyAllowed,
  requiredGuruCurveWindows
} from "./gurus.js";

// The same health calculations serve both the API/admin adapter and the
// read-only worker. This module must never import a database initializer.
export function createSystemHealth({
  databaseInfo,
  readBackgroundJobRuns,
  readDatabaseTableSummaries,
  readGuruBacktest,
  readGuruBacktestProxy,
  readValuationPodcastInsightSummary,
  backtestEndGraceDays,
  guruBacktestRefreshStatus,
  manager13fBacktestMethodVersion,
  manager13fProxyMethodVersion,
  manager13fSecurityMasterVersion,
  listAdminPortfolioUsers
} = {}) {
  const HOUR_MS = 60 * 60 * 1000;
  const DAY_HOURS = 24;
  const FUTURE_TOLERANCE_HOURS = 5 / 60;
  const GURU_CURVE_FAILURE_DETAIL_LIMIT = 5;

  const guruCurveFailureDateFields = Object.freeze([
    "date",
    "reportDate",
    "executionDate"
  ]);

  const guruCurveFailureNumericFields = Object.freeze([
    "coveragePct",
    "minimumCoverage",
    "minimumExecutionCoverage",
    "selectedBookCoverage",
    "minimumSelectedBookCoverage",
    "averageSelectedBookCoverage",
    "maximumExcludedBookWeight",
    "includedPositions",
    "minimumPositions",
    "minimumIncludedPositions",
    "selectedPositions",
    "pricedPositions",
    "unpricedPositions"
  ]);

  const requiredPublicTables = [
    "dashboard_snapshots",
    "guru_snapshots",
    "guru_exposure_snapshots",
    "guru_assets",
    "guru_backtests",
    "guru_backtest_proxies",
    "valuation_snapshots",
    "valuation_ticker_snapshots",
    "valuation_podcast_insights",
    "price_points",
    "portfolio_nav_points",
    "ticker_assets",
    "dividend_events",
    "background_job_runs"
  ];

  const publicDataModules = [
    {
      id: "guru_data",
      label: "Guru dashboard data",
      tables: ["guru_snapshots"],
      cadence: "quarterly_regulatory",
      freshnessBasis: "source_as_of",
      warningHours: 100 * DAY_HOURS,
      failedHours: 130 * DAY_HOURS
    },
    {
      id: "guru_backtests",
      label: "Guru simulation / backtests",
      tables: ["guru_backtests", "guru_backtest_proxies"],
      cadence: "quarterly_filing_event",
      freshnessBasis: "source_as_of",
      warningHours: 100 * DAY_HOURS,
      failedHours: 130 * DAY_HOURS
    },
    {
      id: "valuation",
      label: "Valuation models",
      tables: ["valuation_ticker_snapshots"],
      cadence: "quarterly_company_event",
      freshnessBasis: "source_as_of",
      warningHours: 45 * DAY_HOURS,
      failedHours: 120 * DAY_HOURS
    },
    {
      id: "market_prices",
      label: "Market prices",
      tables: ["price_points"],
      cadence: "market_daily",
      freshnessBasis: "source_as_of",
      warningHours: 5 * DAY_HOURS,
      failedHours: 12 * DAY_HOURS
    }
  ];

  function isoOrEmpty(value) {
    let normalized = String(value || "").trim();
    if (
      /^\d{4}-\d{2}-\d{2}T/.test(normalized) &&
      !/(?:Z|[+-]\d{2}:?\d{2})$/i.test(normalized)
    ) {
      normalized = `${normalized}Z`;
    }
    const time = normalized ? new Date(normalized).getTime() : 0;
    return Number.isFinite(time) && time > 0 ? new Date(time).toISOString() : "";
  }

  function hoursSince(value, now = Date.now()) {
    const normalized = isoOrEmpty(value);
    const time = normalized ? new Date(normalized).getTime() : 0;
    if (!Number.isFinite(time) || time <= 0) return null;
    return (now - time) / HOUR_MS;
  }

  function statusForAge(value, warningHours, failedHours, now = Date.now()) {
    const age = hoursSince(value, now);
    if (age === null) return "unknown";
    if (age < -FUTURE_TOLERANCE_HOURS) return "unknown";
    if (age > failedHours) return "failed";
    if (age > warningHours) return "warning";
    return "success";
  }

  function severity(status) {
    return {
      failed: 4,
      error: 4,
      warning: 3,
      unknown: 2,
      running: 1,
      success: 0,
      ok: 0
    }[status] ?? 2;
  }

  function summarizeStatus(statuses) {
    const worst = statuses
      .filter(Boolean)
      .sort((left, right) => severity(right) - severity(left))[0];
    return worst || "unknown";
  }

  function safeRead(label, fallback, reader) {
    try {
      return reader();
    } catch (error) {
      if (Array.isArray(fallback)) return fallback;
      return {
        ...fallback,
        status: "failed",
        message: `${label} unavailable: ${error.message}`
      };
    }
  }

  function databaseHealth() {
    const info = databaseInfo();
    try {
      const stats = fs.statSync(info.path);
      const exists = stats.isFile();
      return {
        path: info.path,
        exists,
        sizeBytes: stats.size,
        updatedAt: stats.mtime.toISOString(),
        status: exists && stats.size > 0 ? "success" : "failed",
        ...(exists && stats.size > 0 ? {} : { message: "Database file is missing or empty." })
      };
    } catch (error) {
      return {
        path: info.path,
        exists: false,
        sizeBytes: 0,
        updatedAt: "",
        status: "failed",
        message: error.message
      };
    }
  }

  function jobFromRun({
    id,
    label,
    run,
    fallbackLatestAt = "",
    warningHours = 30,
    failedHours = 96,
    detail = {}
  }) {
    const status = String(run?.status || "").trim();
    const finishedAt = isoOrEmpty(run?.finishedAt) || isoOrEmpty(fallbackLatestAt);
    const startedAt = isoOrEmpty(run?.startedAt);
    const payload = run?.payload || {};
    const runningAge = hoursSince(startedAt);
    const normalizedStatus = status === "running"
      ? runningAge !== null && runningAge > 6 ? "warning" : "running"
      : status === "failed" || status === "error"
        ? "failed"
        : status === "success" || status === "ok"
          ? statusForAge(finishedAt, warningHours, failedHours)
          : statusForAge(finishedAt, warningHours, failedHours);
    const message = payload.error ||
      payload.message ||
      (status === "running" && normalizedStatus === "warning"
        ? "Run started but no completion was recorded."
        : "") ||
      (normalizedStatus === "unknown"
        ? "No recorded run yet."
        : normalizedStatus === "warning"
          ? "Latest run is getting stale."
          : "");
    return {
      id,
      label,
      status: normalizedStatus,
      startedAt,
      finishedAt,
      message,
      details: {
        ...detail,
        ...payload
      }
    };
  }

  function tableByName(tables, name) {
    return tables.find((table) => table.table === name) || {};
  }

  function latestTimestamp(values) {
    return values
      .map(isoOrEmpty)
      .filter(Boolean)
      .sort()
      .at(-1) || "";
  }

  function earliestTimestamp(values) {
    return values
      .map(isoOrEmpty)
      .filter(Boolean)
      .sort()
      .at(0) || "";
  }

  function roundedHours(value) {
    return value === null ? null : Math.round(value * 100) / 100;
  }

  function sanitizedFailureCode(value) {
    const code = String(value || "").trim();
    return /^[a-z0-9][a-z0-9_.:-]{0,95}$/i.test(code) ? code : "";
  }

  function sanitizedFailureDate(value) {
    const raw = String(value || "").trim();
    if (!/^\d{4}-\d{2}-\d{2}(?:T.*)?$/.test(raw)) return "";
    const date = isoOrEmpty(raw);
    return date ? date.slice(0, 10) : "";
  }

  function compactGuruCurveFailureDetail(value, fallbackCode = "") {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const detail = {};
    const code = sanitizedFailureCode(value.code) || sanitizedFailureCode(fallbackCode);
    if (code) detail.code = code;
    for (const field of guruCurveFailureDateFields) {
      const date = sanitizedFailureDate(value[field]);
      if (date) detail[field] = date;
    }
    for (const field of guruCurveFailureNumericFields) {
      if (value[field] === null || value[field] === undefined || value[field] === "") continue;
      const numeric = Number(value[field]);
      if (Number.isFinite(numeric)) detail[field] = numeric;
    }
    return Object.keys(detail).length ? detail : null;
  }

  function compactGuruCurveFailureGroup(candidates) {
    const seen = new Set();
    const details = [];
    for (const { value, fallbackCode } of candidates) {
      const detail = compactGuruCurveFailureDetail(value, fallbackCode);
      if (!detail) continue;
      const signature = JSON.stringify(detail);
      if (seen.has(signature)) continue;
      seen.add(signature);
      details.push(detail);
    }
    if (!details.length) return null;
    const visibleDetails = details.slice(0, GURU_CURVE_FAILURE_DETAIL_LIMIT);
    const codes = [...new Set(details.map((detail) => detail.code).filter(Boolean))];
    const visibleCodes = codes.slice(0, GURU_CURVE_FAILURE_DETAIL_LIMIT);
    return {
      codes: visibleCodes,
      details: visibleDetails,
      omittedDetails: Math.max(0, details.length - visibleDetails.length),
      ...(codes.length > visibleCodes.length
        ? { omittedCodes: codes.length - visibleCodes.length }
        : {})
    };
  }

  function compactStoredGuruCurveFailureSummary(strict) {
    if (!strict || typeof strict !== "object" || Array.isArray(strict)) {
      return {
        strict: {
          status: "missing",
          codes: ["strict_missing"],
          details: [],
          omittedDetails: 0
        }
      };
    }
    const dataQuality = strict.dataQuality && typeof strict.dataQuality === "object"
      ? strict.dataQuality
      : {};
    const strictGroup = compactGuruCurveFailureGroup([
      { value: dataQuality.failure, fallbackCode: "strict_backtest_failed" },
      { value: dataQuality.priceFailure, fallbackCode: "strict_price_failure" },
      ...(Array.isArray(dataQuality.coverageFailures)
        ? dataQuality.coverageFailures.map((value) => ({
            value,
            fallbackCode: "execution_coverage_below_minimum"
          }))
        : [])
    ]);
    const proxyGroup = compactGuruCurveFailureGroup([
      { value: dataQuality.proxyFailure, fallbackCode: "proxy_backtest_failed" }
    ]);
    const status = sanitizedFailureCode(strict.status) || "unknown";
    const fallbackStrictGroup = strictGroup || (status !== "ready"
      ? {
          codes: [`strict_${status}`],
          details: [],
          omittedDetails: 0
        }
      : {
          codes: [],
          details: [],
          omittedDetails: 0
        });
    return {
      strict: {
        status,
        ...fallbackStrictGroup
      },
      ...(proxyGroup ? { proxy: proxyGroup } : {})
    };
  }

  function publicStateForAge(value, warningHours, failedHours, now) {
    return {
      success: "healthy",
      warning: "stale",
      failed: "failed",
      unknown: "unknown"
    }[statusForAge(value, warningHours, failedHours, now)] || "unknown";
  }

  function publicStateSeverity(state) {
    return {
      failed: 4,
      stale: 3,
      unknown: 2,
      healthy: 0
    }[state] ?? 2;
  }

  function publicOverallState(states) {
    return states
      .filter(Boolean)
      .sort((left, right) => publicStateSeverity(right) - publicStateSeverity(left))[0] || "unknown";
  }

  function tableModuleHealth(spec, tables, now) {
    const rows = spec.tables.map((table) => tables.find((entry) => entry.table === table));
    const missingTables = spec.tables.filter((table, index) => !rows[index]);
    const failedTables = rows
      .filter((row) => row && !["ok", "success"].includes(row.status))
      .map((row) => row.table);
    const rowCount = rows.reduce((sum, row) => sum + Number(row?.rowCount || 0), 0);
    const observedAt = latestTimestamp(rows.map((row) => row?.latestAt));
    const sourceAsOf = latestTimestamp(rows.map((row) => row?.sourceAt));
    const referenceAt = spec.freshnessBasis === "source_as_of" ? sourceAsOf : observedAt;
    const ageHours = hoursSince(referenceAt, now);
    const state = missingTables.length || failedTables.length || rowCount <= 0
      ? "failed"
      : publicStateForAge(referenceAt, spec.warningHours, spec.failedHours, now);
    const message = missingTables.length
      ? `Missing table${missingTables.length === 1 ? "" : "s"}: ${missingTables.join(", ")}`
      : failedTables.length
        ? `Unreadable table${failedTables.length === 1 ? "" : "s"}: ${failedTables.join(", ")}`
        : rowCount <= 0
          ? "No persisted rows are available."
          : state === "failed"
            ? "Economic source data is beyond the failure cadence threshold."
            : state === "stale"
              ? "Economic source data is beyond the warning cadence threshold."
              : state === "unknown"
                ? "Persisted data has no usable economic source date."
                : "";
    return {
      id: spec.id,
      label: spec.label,
      state,
      message,
      freshness: {
        basis: spec.freshnessBasis,
        cadence: spec.cadence,
        sourceAsOf,
        observedAt,
        latestAt: referenceAt,
        ageHours: roundedHours(ageHours),
        warningHours: spec.warningHours,
        failedHours: spec.failedHours
      },
      details: {
        tables: spec.tables,
        rowCount,
        missingTables,
        failedTables
      }
    };
  }

  const guruCurveRefreshIntervalHours = Math.max(
    1,
    Number(process.env.BACKTEST_AUTO_REFRESH_INTERVAL_HOURS || 24)
  );
  const guruCurveHealthMaxGeneratedAgeHours = Math.max(
    guruCurveRefreshIntervalHours + 12,
    Number(
      process.env.GURU_CURVE_HEALTH_MAX_GENERATED_AGE_HOURS ||
      guruCurveRefreshIntervalHours + 24
    )
  );
  const guruCurveHealthEndGraceDays = Math.max(
    1,
    backtestEndGraceDays
  );

  function guruCurveFreshness(payload, now) {
    const generatedAt = isoOrEmpty(payload?.generatedAt);
    const endDate = isoOrEmpty(payload?.window?.end || payload?.endDate);
    const generatedAgeHours = hoursSince(generatedAt, now);
    const endAgeHours = hoursSince(endDate, now);
    const generatedAtReady = generatedAgeHours !== null &&
      generatedAgeHours >= -FUTURE_TOLERANCE_HOURS &&
      generatedAgeHours <= guruCurveHealthMaxGeneratedAgeHours;
    const endDateReady = endAgeHours !== null &&
      endAgeHours >= -FUTURE_TOLERANCE_HOURS &&
      endAgeHours <= guruCurveHealthEndGraceDays * DAY_HOURS;
    return {
      ok: generatedAtReady && endDateReady,
      generatedAt,
      endDate,
      generatedAgeHours: roundedHours(generatedAgeHours),
      endAgeHours: roundedHours(endAgeHours),
      maxGeneratedAgeHours: guruCurveHealthMaxGeneratedAgeHours,
      maxEndAgeHours: guruCurveHealthEndGraceDays * DAY_HOURS
    };
  }

  function backtestIdentityMatches(payload, years, { proxy = false } = {}) {
    if (payload?.method?.version !== manager13fBacktestMethodVersion ||
        payload?.method?.securityMasterVersion !== manager13fSecurityMasterVersion ||
        Number(payload?.method?.years) !== years) {
      return false;
    }
    if (!proxy) return true;
    return payload?.method?.variant === manager13fProxyMethodVersion &&
      payload?.proxy?.methodVersion === manager13fProxyMethodVersion &&
      payload?.proxy?.securityMasterVersion === manager13fSecurityMasterVersion;
  }

  function summarizeGuruCurveAvailability({
    managers = enabledManager13fGurus,
    windows = requiredGuruCurveWindows,
    readStrict = readGuruBacktest,
    readProxy = readGuruBacktestProxy,
    now = Date.now()
  } = {}) {
    const results = [];
    for (const guru of managers) {
      for (const years of windows) {
        const strict = readStrict(guru.id, years);
        const proxy = readProxy(guru.id, years);
        const strictAudit = strict?.status === "ready"
          ? auditManager13fStrictReadyPayload(strict)
          : { ok: false, reason: `strict_${strict?.status || "missing"}` };
        const strictFreshness = guruCurveFreshness(strict, now);
        const strictReady = strict?.status === "ready" &&
          backtestIdentityMatches(strict, years) &&
          strictFreshness.ok &&
          strictAudit.ok;
        const proxyAudit = proxy?.status === "proxy_ready"
          ? auditPublicHoldingsProxyPayload(proxy)
          : { ok: false, reason: `proxy_${proxy?.status || "missing"}` };
        const proxyFreshness = guruCurveFreshness(proxy, now);
        const proxyAllowed = manager13fPublicProxyAllowed(guru.id, years);
        const proxyReady = !strictReady &&
          proxyAllowed &&
          strict?.status === "insufficient_data" &&
          backtestIdentityMatches(strict, years) &&
          strictFreshness.ok &&
          proxy?.status === "proxy_ready" &&
          backtestIdentityMatches(proxy, years, { proxy: true }) &&
          proxyFreshness.ok &&
          proxy?.proxy?.strictFailureGeneratedAt === strict?.generatedAt &&
          Array.isArray(proxy?.equity) && proxy.equity.length >= 2 &&
          proxyAudit.ok;
        const outcome = strictReady ? "ready" : proxyReady ? "proxy_ready" : "failure";
        results.push({
          guruId: guru.id,
          guruName: guru.name,
          years,
          outcome,
          reason: outcome === "failure"
            ? strict && !backtestIdentityMatches(strict, years)
              ? "strict_method_or_security_master_incompatible"
              : strict && !strictFreshness.ok
                ? "strict_curve_stale"
              : strict?.status === "ready" && !strictAudit.ok
                ? strictAudit.reason
                : proxy?.status === "proxy_ready" && !proxyAllowed
                  ? "public_proxy_not_allowed_for_manager_window"
                : proxy?.status === "proxy_ready" && !backtestIdentityMatches(proxy, years, { proxy: true })
                  ? "proxy_method_or_security_master_incompatible"
                  : proxy?.status === "proxy_ready" && !proxyFreshness.ok
                    ? "proxy_curve_stale"
                  : proxy?.status === "proxy_ready" && !proxyAudit.ok
                    ? proxyAudit.reason
                    : proxy?.status === "proxy_ready" &&
                        proxy?.proxy?.strictFailureGeneratedAt !== strict?.generatedAt
                      ? "proxy_not_linked_to_current_strict_failure"
                      : "no_current_displayable_curve"
            : null,
          strictFreshness,
          ...(proxy?.status === "proxy_ready" ? { proxyFreshness } : {}),
          ...(outcome === "failure"
            ? { failureSummary: compactStoredGuruCurveFailureSummary(strict) }
            : {})
        });
      }
    }
    const expectedRows = managers.length * windows.length;
    const displayable = results.filter((row) => row.outcome !== "failure").length;
    const byWindow = Object.fromEntries(windows.map((years) => {
      const rows = results.filter((row) => row.years === years);
      return [`${years}Y`, {
        expected: managers.length,
        strictReady: rows.filter((row) => row.outcome === "ready").length,
        proxyReady: rows.filter((row) => row.outcome === "proxy_ready").length,
        failures: rows.filter((row) => row.outcome === "failure").length,
        displayable: rows.filter((row) => row.outcome !== "failure").length
      }];
    }));
    return {
      ok: managers.length === enabledManager13fGurus.length &&
        results.length === expectedRows &&
        displayable === expectedRows,
      expectedManagers: enabledManager13fGurus.length,
      managerCount: managers.length,
      windows: [...windows],
      expectedRows,
      displayable,
      strictReady: results.filter((row) => row.outcome === "ready").length,
      proxyReady: results.filter((row) => row.outcome === "proxy_ready").length,
      failures: results.filter((row) => row.outcome === "failure"),
      byWindow,
      methodVersion: manager13fBacktestMethodVersion,
      proxyMethodVersion: manager13fProxyMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      readiness: {
        refreshIntervalHours: guruCurveRefreshIntervalHours,
        maxGeneratedAgeHours: guruCurveHealthMaxGeneratedAgeHours,
        maxEndAgeHours: guruCurveHealthEndGraceDays * DAY_HOURS
      }
    };
  }

  function guruBacktestModuleHealth(spec, tables, curveAvailability, now) {
    const module = tableModuleHealth(spec, tables, now);
    if (curveAvailability?.ok) {
      return {
        ...module,
        details: { ...module.details, curveAvailability }
      };
    }
    const displayable = Number(curveAvailability?.displayable || 0);
    const expected = Number(curveAvailability?.expectedRows || expectedGuruCurveRows);
    return {
      ...module,
      state: "failed",
      message: `Only ${displayable}/${expected} required 5Y/10Y manager curves are current and displayable.`,
      details: { ...module.details, curveAvailability }
    };
  }

  function buildPublicSystemHealth({
    database: databaseOverride,
    tables: tablesOverride,
    guruCurves: guruCurvesOverride,
    now = Date.now()
  } = {}) {
    const rawDatabase = databaseOverride || databaseHealth();
    const tables = tablesOverride || safeRead("database tables", [], () => readDatabaseTableSummaries());
    const tableRows = Array.isArray(tables) ? tables : [];
    const tableNames = new Set(tableRows.map((table) => table.table));
    const missingTables = requiredPublicTables.filter((table) => !tableNames.has(table));
    const failedTables = tableRows
      .filter((table) => !["ok", "success"].includes(table.status))
      .map((table) => table.table);
    const databaseState = rawDatabase.exists && Number(rawDatabase.sizeBytes || 0) > 0 &&
      !missingTables.length && !failedTables.length
      ? "healthy"
      : "failed";
    const databaseModule = {
      id: "database",
      label: "SQLite database",
      state: databaseState,
      message: databaseState === "healthy"
        ? ""
        : !rawDatabase.exists || Number(rawDatabase.sizeBytes || 0) <= 0
          ? "Database file is missing or empty."
          : missingTables.length
            ? `Missing table${missingTables.length === 1 ? "" : "s"}: ${missingTables.join(", ")}`
            : `Unreadable table${failedTables.length === 1 ? "" : "s"}: ${failedTables.join(", ")}`,
      freshness: {
        latestAt: isoOrEmpty(rawDatabase.updatedAt),
        ageHours: roundedHours(hoursSince(rawDatabase.updatedAt, now)),
        warningHours: null,
        failedHours: null
      },
      details: {
        sizeBytes: Number(rawDatabase.sizeBytes || 0),
        requiredTableCount: requiredPublicTables.length,
        discoveredTableCount: tableRows.length,
        missingTables,
        failedTables
      }
    };
    const guruCurves = guruCurvesOverride || safeRead(
      "Guru curve availability",
      { ok: false, expectedRows: expectedGuruCurveRows, displayable: 0, failures: [] },
      () => summarizeGuruCurveAvailability({ now })
    );
    const modules = [
      databaseModule,
      ...publicDataModules.map((spec) => spec.id === "guru_backtests"
        ? guruBacktestModuleHealth(spec, tableRows, guruCurves, now)
        : tableModuleHealth(spec, tableRows, now))
    ];
    const status = publicOverallState(modules.map((module) => module.state));
    const { path: _path, ...publicDatabase } = rawDatabase;

    return {
      generatedAt: new Date(now).toISOString(),
      ok: !["failed", "unknown"].includes(status),
      degraded: status === "stale",
      status,
      service: "thesisforge-api",
      database: {
        ...publicDatabase,
        state: databaseState,
        missingTables,
        failedTables
      },
      modules
    };
  }

  function portfolioSummary() {
    return safeRead("portfolio registry", {
      users: [],
      summary: {
        users: 0,
        linked: 0,
        accounts: 0,
        errors: 0,
        latestNav: 0
      }
    }, () => {
      const payload = listAdminPortfolioUsers();
      return {
        users: Array.isArray(payload.users) ? payload.users.slice(0, 12) : [],
        summary: payload.summary || {}
      };
    });
  }

  function buildAdminSystemHealth({ allowedOrigins = [], adminEmails = [] } = {}) {
    const database = databaseHealth();
    const tables = safeRead("database tables", [], () => readDatabaseTableSummaries());
    const runs = safeRead("job runs", [], () => readBackgroundJobRuns());
    const runById = new Map((Array.isArray(runs) ? runs : []).map((run) => [run.jobId, run]));
    const backtestStatus = safeRead("backtest status", {}, () => guruBacktestRefreshStatus());
    const podcastSummary = safeRead("podcast summary", {}, () => readValuationPodcastInsightSummary(25));
    const portfolio = portfolioSummary();

    const backtestTable = tableByName(tables, "guru_backtests");
    const valuationTable = tableByName(tables, "valuation_ticker_snapshots");
    const guruTable = tableByName(tables, "guru_snapshots");
    const dividendTable = tableByName(tables, "dividend_events");
    const navTable = tableByName(tables, "portfolio_nav_points");
    const podcastTable = tableByName(tables, "valuation_podcast_insights");

    const backtestRun =
      runById.get("guru_backtest_refresh") ||
      (backtestStatus.startedAt || backtestStatus.finishedAt
        ? {
            jobId: "guru_backtest_refresh",
            startedAt: backtestStatus.startedAt,
            finishedAt: backtestStatus.finishedAt,
            status: backtestStatus.running
              ? "running"
              : Number(backtestStatus.failed || 0) > 0
                ? "failed"
                : "success",
            payload: backtestStatus
          }
        : null);

    const jobs = [
      jobFromRun({
        id: "guru_snapshots",
        label: "Guru dashboard data",
        run: null,
        fallbackLatestAt: guruTable.latestAt,
        warningHours: 48,
        failedHours: 168,
        detail: { rows: guruTable.rowCount }
      }),
      jobFromRun({
        id: "guru_backtest_refresh",
        label: "Guru simulation / backtests",
        run: backtestRun,
        fallbackLatestAt: backtestTable.latestAt,
        warningHours: 36,
        failedHours: 120,
        detail: {
          rows: backtestTable.rowCount,
          latestBacktestEndDate: backtestTable.maxDate
        }
      }),
      jobFromRun({
        id: "valuation_database",
        label: "Valuation models",
        run: null,
        fallbackLatestAt: valuationTable.latestAt,
        warningHours: 72,
        failedHours: 240,
        detail: { tickerRows: valuationTable.rowCount }
      }),
      jobFromRun({
        id: "valuation_podcast_insights",
        label: "Podcast / YouTube insights",
        run: runById.get("valuation_podcast_insights"),
        fallbackLatestAt: podcastTable.latestAt,
        warningHours: 72,
        failedHours: 240,
        detail: {
          rows: podcastTable.rowCount,
          observedThrough: podcastTable.maxDate,
          tickers: podcastSummary.tickerCount || 0,
          sources: podcastSummary.sourceCount || 0
        }
      }),
      jobFromRun({
        id: "portfolio_sync",
        label: "User portfolio sync",
        run: runById.get("portfolio_sync"),
        fallbackLatestAt: navTable.latestAt,
        warningHours: 24,
        failedHours: 96,
        detail: portfolio.summary
      }),
      jobFromRun({
        id: "portfolio_nav_capture",
        label: "Portfolio NAV recorder",
        run: runById.get("portfolio_nav_capture"),
        fallbackLatestAt: navTable.latestAt,
        warningHours: 36,
        failedHours: 120,
        detail: {
          rows: navTable.rowCount,
          latestNavDate: navTable.maxDate
        }
      }),
      jobFromRun({
        id: "portfolio_dividend_calendar",
        label: "Dividend calendar",
        run: runById.get("portfolio_dividend_calendar"),
        fallbackLatestAt: dividendTable.latestAt,
        warningHours: 168,
        failedHours: 336,
        detail: {
          rows: dividendTable.rowCount,
          minExDate: dividendTable.minDate,
          maxExDate: dividendTable.maxDate
        }
      })
    ];

    const status = summarizeStatus([
      database.status,
      ...jobs.map((job) => job.status)
    ]);

    return {
      generatedAt: new Date().toISOString(),
      ok: status !== "failed" && status !== "error",
      status,
      service: {
        name: "thesisforge-api",
        runtime: "node",
        nodeVersion: process.version,
        pid: process.pid,
        uptimeSeconds: Math.round(process.uptime()),
        host: os.hostname(),
        environment: process.env.NODE_ENV || "development",
        port: Number(process.env.PORT || 8787)
      },
      deployment: {
        frontend: "Vercel",
        backend: "AWS Elastic Beanstalk",
        apiProxy: "/api/* -> AWS backend"
      },
      database,
      auth: {
        adminEmails,
        adminEmailCount: adminEmails.length,
        allowedOrigins,
        allowedOriginCount: allowedOrigins.length,
        supabaseUrlConfigured: Boolean(process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL),
        apiCorsConfigured: allowedOrigins.some((origin) => origin.includes("thesisforge.tech"))
      },
      portfolio,
      jobs,
      tables,
      recentRuns: Array.isArray(runs) ? runs.slice(0, 12) : []
    };
  }

  return { statusForAge, summarizeGuruCurveAvailability, buildPublicSystemHealth, buildAdminSystemHealth };
}
