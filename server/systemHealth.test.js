import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "system-health-test-"));
process.env.SQLITE_DB_PATH = path.join(temporaryDirectory, "health.sqlite");
process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
process.env.SYNC_BUNDLED_GURU_BACKTESTS = "false";
process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";
process.env.SYNC_BUNDLED_PODCAST_INSIGHTS = "false";

const {
  buildPublicSystemHealth,
  statusForAge,
  summarizeGuruCurveAvailability
} = await import("./systemHealth.js");
const {
  manager13fBacktestMethodVersion,
  manager13fProxyMethodVersion,
  manager13fSecurityMasterVersion
} = await import("./backtest.js");
const {
  gurus,
  expectedGuruCurveRows,
  requiredGuruCurveWindowsFor
} = await import("./gurus.js");

const expectedManagerCount = gurus.filter((guru) =>
  guru.type === "manager13f" && !guru.disableSimulation
).length;
const requiredCurveWindows = Object.freeze([5, 10]);
const expectedCurveRows = expectedManagerCount * requiredCurveWindows.length;
const finalFixtureManagerId = `manager-${expectedManagerCount}`;

after(() => fs.rmSync(temporaryDirectory, { recursive: true, force: true }));

const requiredTables = [
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

const now = Date.parse("2026-09-01T12:00:00.000Z");

function healthyFixture() {
  const latestAt = new Date(now - 60 * 60 * 1000).toISOString();
  const proxyReadyPerWindow = Math.min(3, expectedManagerCount);
  const strictReadyPerWindow = expectedManagerCount - proxyReadyPerWindow;
  return {
    database: {
      path: "/private/health.sqlite",
      exists: true,
      sizeBytes: 1024,
      updatedAt: latestAt,
      status: "success"
    },
    tables: requiredTables.map((table) => ({
      table,
      rowCount: 1,
      latestAt,
      sourceAt: latestAt,
      status: "ok"
    })),
    guruCurves: {
      ok: true,
      expectedManagers: expectedManagerCount,
      managerCount: expectedManagerCount,
      expectedRows: expectedCurveRows,
      displayable: expectedCurveRows,
      strictReady: strictReadyPerWindow * requiredCurveWindows.length,
      proxyReady: proxyReadyPerWindow * requiredCurveWindows.length,
      failures: [],
      byWindow: {
        "5Y": {
          expected: expectedManagerCount,
          strictReady: strictReadyPerWindow,
          proxyReady: proxyReadyPerWindow,
          failures: 0,
          displayable: expectedManagerCount
        },
        "10Y": {
          expected: expectedManagerCount,
          strictReady: strictReadyPerWindow,
          proxyReady: proxyReadyPerWindow,
          failures: 0,
          displayable: expectedManagerCount
        }
      }
    },
    now
  };
}

test("freshness status escalates past failedHours", () => {
  const old = new Date(now - 97 * 60 * 60 * 1000).toISOString();
  assert.equal(statusForAge(old, 24, 96, now), "failed");
});

test("freshness fails closed for a materially future source date", () => {
  const future = new Date(now + 60 * 60 * 1000).toISOString();
  assert.equal(statusForAge(future, 24, 96, now), "unknown");
});

test("public health is green only when every required module is current", () => {
  const health = buildPublicSystemHealth(healthyFixture());
  assert.equal(health.ok, true);
  assert.equal(health.status, "healthy");
  assert.equal(health.modules.every((module) => module.state === "healthy"), true);
  assert.equal("path" in health.database, false);
});

test("public health fails when only one manager has a displayable curve", () => {
  const fixture = healthyFixture();
  fixture.guruCurves = {
    ...fixture.guruCurves,
    ok: false,
    displayable: 2,
    strictReady: 2,
    proxyReady: 0,
    failures: [{ guruId: "stanley-druckenmiller", years: 5, outcome: "failure" }]
  };
  const health = buildPublicSystemHealth(fixture);
  const module = health.modules.find((entry) => entry.id === "guru_backtests");
  assert.equal(health.ok, false);
  assert.equal(module.state, "failed");
  assert.match(module.message, new RegExp(`2/${expectedCurveRows}`));
  assert.equal(module.details.curveAvailability.failures.length, 1);
});

test("Guru curve failures expose only compact strict and proxy diagnostics from the stored strict payload", () => {
  const strict = {
    generatedAt: "2026-09-01T11:00:00.000Z",
    status: "insufficient_data",
    window: { start: "2021-09-02", end: "2026-08-31" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years: 5
    },
    dataQuality: {
      failure: {
        code: "missing_active_price",
        date: "2026-08-20",
        tickers: ["PRIVATE-TICKER"],
        cusips: ["000000000"],
        holdings: [{ ticker: "PRIVATE-HOLDING" }],
        apiToken: "private-token"
      },
      coverageFailures: [{
        reportDate: "2026-06-30",
        executionDate: "2026-08-17",
        coveragePct: 0.82,
        selectedPositions: 10,
        pricedPositions: 8,
        unpricedPositions: 2,
        tickers: ["PRIVATE-COVERAGE-TICKER"]
      }],
      proxyFailure: {
        code: "proxy_included_positions_below_minimum",
        reportDate: "2026-06-30",
        executionDate: "2026-08-17",
        selectedBookCoverage: 0.41,
        includedPositions: 1,
        minimumPositions: 2,
        excludedTickers: ["PRIVATE-EXCLUDED-TICKER"],
        secret: "private-secret"
      }
    }
  };
  const summary = summarizeGuruCurveAvailability({
    managers: [{ id: "manager-1", name: "Manager 1" }],
    windows: [5],
    readStrict: () => strict,
    readProxy: () => ({
      status: "insufficient_data",
      dataQuality: {
        failure: { code: "must_not_come_from_proxy_payload", tickers: ["PROXY-TICKER"] }
      }
    }),
    now
  });
  assert.deepEqual(summary.failures[0].failureSummary, {
    strict: {
      status: "insufficient_data",
      codes: ["missing_active_price", "execution_coverage_below_minimum"],
      details: [{
        code: "missing_active_price",
        date: "2026-08-20"
      }, {
        code: "execution_coverage_below_minimum",
        reportDate: "2026-06-30",
        executionDate: "2026-08-17",
        coveragePct: 0.82,
        selectedPositions: 10,
        pricedPositions: 8,
        unpricedPositions: 2
      }],
      omittedDetails: 0
    },
    proxy: {
      codes: ["proxy_included_positions_below_minimum"],
      details: [{
        code: "proxy_included_positions_below_minimum",
        reportDate: "2026-06-30",
        executionDate: "2026-08-17",
        selectedBookCoverage: 0.41,
        includedPositions: 1,
        minimumPositions: 2
      }],
      omittedDetails: 0
    }
  });
  const serialized = JSON.stringify(summary.failures[0].failureSummary);
  for (const forbidden of [
    "PRIVATE-TICKER",
    "000000000",
    "PRIVATE-HOLDING",
    "private-token",
    "PRIVATE-COVERAGE-TICKER",
    "PRIVATE-EXCLUDED-TICKER",
    "private-secret",
    "must_not_come_from_proxy_payload",
    "PROXY-TICKER"
  ]) {
    assert.equal(serialized.includes(forbidden), false);
  }
});

test("Guru curve failure diagnostics are bounded and sanitize malformed codes and dates", () => {
  const coverageFailures = Array.from({ length: 8 }, (_, index) => ({
    code: index === 0 ? "token=do-not-copy" : `coverage_failure_${index}`,
    reportDate: index === 0 ? "not-a-date-private-value" : `2026-0${index + 1}-28`,
    executionDate: `2026-0${index + 1}-29`,
    coveragePct: 0.8,
    includedPositions: 8
  }));
  const summary = summarizeGuruCurveAvailability({
    managers: [{ id: "manager-1", name: "Manager 1" }],
    windows: [5],
    readStrict: () => ({
      generatedAt: "2026-09-01T11:00:00.000Z",
      status: "insufficient_data",
      window: { start: "2021-09-02", end: "2026-08-31" },
      method: {
        version: manager13fBacktestMethodVersion,
        securityMasterVersion: manager13fSecurityMasterVersion,
        years: 5
      },
      dataQuality: { coverageFailures }
    }),
    readProxy: () => null,
    now
  });
  const failureSummary = summary.failures[0].failureSummary;
  assert.equal(failureSummary.strict.details.length, 5);
  assert.equal(failureSummary.strict.omittedDetails, 3);
  assert.equal(failureSummary.strict.codes.length, 5);
  assert.equal(failureSummary.strict.omittedCodes, 3);
  assert.equal(failureSummary.strict.details[0].code, "execution_coverage_below_minimum");
  assert.equal("reportDate" in failureSummary.strict.details[0], false);
  assert.equal(
    JSON.stringify(failureSummary).includes("not-a-date-private-value"),
    false
  );
});

test("Guru curve health re-audits every configured manager across 5Y and 10Y using current identities", () => {
  const managers = Array.from({ length: expectedManagerCount }, (_, index) => ({
    id: `manager-${index + 1}`,
    name: `Manager ${index + 1}`
  }));
  const strictPayload = (guruId, years) => ({
    generatedAt: "2026-09-01T11:00:00.000Z",
    status: "ready",
    window: { start: "2021-09-02", end: "2026-08-31" },
    method: {
      version: guruId === finalFixtureManagerId && years === 10
        ? "obsolete-method"
        : manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years,
      minimumExecutionCoverage: 0.9
    },
    dataQuality: {
      minimumExecutionCoverage: 0.9,
      minimumObservedExecutionCoverage: 0.95
    },
    summary: { averageCoverage: 0.97 },
    rebalances: [{ coveragePct: 0.95 }],
    equity: [{ date: "2021-09-02", value: 1 }, { date: "2026-09-01", value: 1.2 }]
  });
  const failed = summarizeGuruCurveAvailability({
    managers,
    readStrict: strictPayload,
    readProxy: () => null,
    now
  });
  assert.equal(failed.ok, false);
  assert.equal(failed.displayable, expectedCurveRows - 1);
  assert.equal(failed.failures.length, 1);
  assert.equal(failed.failures[0].reason, "strict_method_or_security_master_incompatible");
  assert.equal(failed.methodVersion, manager13fBacktestMethodVersion);
  assert.equal(failed.proxyMethodVersion, manager13fProxyMethodVersion);
  assert.equal(failed.securityMasterVersion, manager13fSecurityMasterVersion);

  const healthy = summarizeGuruCurveAvailability({
    managers,
    readStrict: (guruId, years) => ({
      ...strictPayload(guruId, years),
      method: {
        ...strictPayload(guruId, years).method,
        version: manager13fBacktestMethodVersion
      }
    }),
    readProxy: () => null,
    now
  });
  assert.equal(healthy.ok, true);
  assert.equal(healthy.displayable, expectedCurveRows);
  assert.equal(healthy.failures.length, 0);
});

test("a current proxy cannot make health green when its linked strict failure has an obsolete identity", () => {
  const managers = Array.from({ length: expectedManagerCount }, (_, index) => ({
    id: `manager-${index + 1}`,
    name: `Manager ${index + 1}`
  }));
  const generatedAt = "2026-09-01T11:00:00.000Z";
  const strict = (guruId, years) => ({
    generatedAt,
    status: "insufficient_data",
    window: { start: "2021-09-02", end: "2026-08-31" },
    method: {
      version: guruId === finalFixtureManagerId && years === 10
        ? "obsolete-method"
        : manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years
    }
  });
  const proxy = (_guruId, years) => ({
    generatedAt,
    status: "proxy_ready",
    window: { start: "2021-09-02", end: "2026-08-31" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      variant: manager13fProxyMethodVersion,
      years
    },
    proxy: {
      methodVersion: manager13fProxyMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      strictFailureGeneratedAt: generatedAt,
      minimumProxyCoverage: 0.3,
      minimumProxyPositions: 2,
      minimumSelectedBookCoverage: 0.4,
      averageSelectedBookCoverage: 0.4,
      maximumExcludedBookWeight: 0.6,
      minimumIncludedPositions: 2
    },
    rebalances: [{ selectedBookCoverage: 0.4, includedPositions: 2 }],
    equity: [{ date: "2021-09-02", value: 1 }, { date: "2026-09-01", value: 1.2 }]
  });
  const summary = summarizeGuruCurveAvailability({
    managers,
    readStrict: strict,
    readProxy: proxy,
    now
  });
  assert.equal(summary.ok, false);
  assert.equal(summary.displayable, expectedCurveRows - 1);
  assert.deepEqual(summary.failures.map((row) => [row.guruId, row.years, row.reason]), [[
    finalFixtureManagerId,
    10,
    "strict_method_or_security_master_incompatible"
  ]]);
});

test("Guru curve health rejects only Renaissance's 5Y public proxy policy exception", () => {
  const managers = gurus.filter((guru) =>
    guru.type === "manager13f" && !guru.disableSimulation
  );
  const generatedAt = "2026-09-01T11:00:00.000Z";
  const strict = (guruId, years) => ({
    generatedAt,
    status: "insufficient_data",
    guru: { id: guruId, type: "manager13f" },
    window: { start: "2021-09-02", end: "2026-08-31" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years
    },
    equity: []
  });
  const proxy = (guruId, years) => ({
    generatedAt,
    status: "proxy_ready",
    guru: { id: guruId, type: "manager13f" },
    window: { start: "2021-09-02", end: "2026-08-31" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      variant: manager13fProxyMethodVersion,
      years
    },
    proxy: {
      methodVersion: manager13fProxyMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      strictFailureGeneratedAt: generatedAt,
      minimumProxyCoverage: 0.3,
      minimumProxyPositions: 2,
      minimumSelectedBookCoverage: 0.4,
      averageSelectedBookCoverage: 0.4,
      maximumExcludedBookWeight: 0.6,
      minimumIncludedPositions: 2
    },
    rebalances: [{ selectedBookCoverage: 0.4, includedPositions: 2 }],
    equity: [{ date: "2021-09-02", value: 1 }, { date: "2026-08-31", value: 1.2 }]
  });

  const summary = summarizeGuruCurveAvailability({
    managers,
    windows: [5, 10],
    readStrict: strict,
    readProxy: proxy,
    now
  });

  assert.equal(summary.ok, false);
  assert.equal(summary.expectedRows, expectedGuruCurveRows);
  assert.equal(summary.displayable, expectedGuruCurveRows - 1);
  assert.equal(summary.proxyReady, expectedGuruCurveRows - 1);
  assert.equal(summary.byWindow["5Y"].proxyReady, expectedManagerCount - 1);
  assert.equal(
    summary.byWindow["10Y"].proxyReady,
    managers.filter((guru) => requiredGuruCurveWindowsFor(guru).includes(10)).length
  );
  assert.deepEqual(summary.failures.map((row) => [
    row.guruId,
    row.years,
    row.reason
  ]), [[
    "renaissance-technologies",
    5,
    "public_proxy_not_allowed_for_manager_window"
  ]]);
});

test("all but one stale curve cannot pass the production health gate", () => {
    const managers = Array.from({ length: expectedManagerCount }, (_, index) => ({
      id: `manager-${index + 1}`,
      name: `Manager ${index + 1}`
    }));
    const staleGeneratedAt = new Date(now - 49 * 60 * 60 * 1000).toISOString();
    const freshGeneratedAt = new Date(now - 60 * 60 * 1000).toISOString();
    const strict = (guruId, years) => ({
      generatedAt: guruId === finalFixtureManagerId && years === 10
        ? freshGeneratedAt
        : staleGeneratedAt,
      status: "ready",
      window: {
        start: "2021-09-02",
        end: new Date(now - 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
      },
      method: {
        version: manager13fBacktestMethodVersion,
        securityMasterVersion: manager13fSecurityMasterVersion,
        years,
        minimumExecutionCoverage: 0.9
      },
      dataQuality: {
        minimumExecutionCoverage: 0.9,
        minimumObservedExecutionCoverage: 0.95
      },
      summary: { averageCoverage: 0.97 },
      rebalances: [{ coveragePct: 0.95 }],
      equity: [{ date: "2021-09-02", value: 1 }, { date: "2026-08-31", value: 1.2 }]
    });
    const summary = summarizeGuruCurveAvailability({
      managers,
      readStrict: strict,
      readProxy: () => null,
      now
    });
    assert.equal(summary.ok, false);
    assert.equal(summary.displayable, 1);
    assert.equal(summary.failures.length, expectedCurveRows - 1);
    assert.equal(summary.failures.every((row) => row.reason === "strict_curve_stale"), true);
    assert.equal(summary.readiness.refreshIntervalHours, 24);
    assert.equal(summary.readiness.maxGeneratedAgeHours, 48);
});

test("the health readiness window remains green between the 20h serving TTL and 24h scheduler", () => {
  const managers = Array.from({ length: expectedManagerCount }, (_, index) => ({
    id: `manager-${index + 1}`,
    name: `Manager ${index + 1}`
  }));
  const strict = (_guruId, years) => ({
    generatedAt: new Date(now - 21 * 60 * 60 * 1000).toISOString(),
    status: "ready",
    window: { start: "2021-09-02", end: "2026-08-31" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years,
      minimumExecutionCoverage: 0.9
    },
    dataQuality: {
      minimumExecutionCoverage: 0.9,
      minimumObservedExecutionCoverage: 0.95
    },
    summary: { averageCoverage: 0.97 },
    rebalances: [{ coveragePct: 0.95 }],
    equity: [{ date: "2021-09-02", value: 1 }, { date: "2026-08-31", value: 1.2 }]
  });
  const summary = summarizeGuruCurveAvailability({
    managers,
    readStrict: strict,
    readProxy: () => null,
    now
  });
  assert.equal(summary.ok, true);
  assert.equal(summary.displayable, expectedCurveRows);
});

test("a valid seven-day shared vendor lag remains inside the curve freshness contract", () => {
  const managers = Array.from({ length: expectedManagerCount }, (_, index) => ({
    id: `manager-${index + 1}`,
    name: `Manager ${index + 1}`
  }));
  const payloadAtEndAge = (endAgeDays) => (_guruId, years) => ({
    generatedAt: new Date(now - 60 * 60 * 1000).toISOString(),
    status: "ready",
    window: {
      start: "2021-09-02",
      end: new Date(now - endAgeDays * 24 * 60 * 60 * 1000).toISOString()
    },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years,
      minimumExecutionCoverage: 0.9
    },
    dataQuality: {
      minimumExecutionCoverage: 0.9,
      minimumObservedExecutionCoverage: 0.95
    },
    summary: { averageCoverage: 0.97 },
    rebalances: [{ coveragePct: 0.95 }],
    equity: [
      { date: "2021-09-02", value: 1 },
      { date: "2026-08-20", value: 1.2 }
    ]
  });

  const withinBound = summarizeGuruCurveAvailability({
    managers,
    readStrict: payloadAtEndAge(12),
    readProxy: () => null,
    now
  });
  assert.equal(withinBound.ok, true);
  assert.equal(withinBound.displayable, expectedCurveRows);
  assert.equal(withinBound.readiness.maxEndAgeHours, 12 * 24);

  const beyondBound = summarizeGuruCurveAvailability({
    managers,
    readStrict: payloadAtEndAge(12 + 1 / 24),
    readProxy: () => null,
    now
  });
  assert.equal(beyondBound.ok, false);
  assert.equal(beyondBound.displayable, 0);
  assert.equal(beyondBound.failures.every((row) => row.reason === "strict_curve_stale"), true);
});

test("public health fails closed for a missing database or table", () => {
  const missingDatabase = healthyFixture();
  missingDatabase.database.exists = false;
  missingDatabase.database.sizeBytes = 0;
  const databaseHealth = buildPublicSystemHealth(missingDatabase);
  assert.equal(databaseHealth.ok, false);
  assert.equal(databaseHealth.status, "failed");
  assert.equal(databaseHealth.modules.find((module) => module.id === "database").state, "failed");

  const missingTable = healthyFixture();
  missingTable.tables = missingTable.tables.filter(
    (table) => table.table !== "valuation_ticker_snapshots"
  );
  const tableHealth = buildPublicSystemHealth(missingTable);
  assert.equal(tableHealth.ok, false);
  assert.equal(tableHealth.database.missingTables.includes("valuation_ticker_snapshots"), true);
  assert.equal(tableHealth.modules.find((module) => module.id === "valuation").state, "failed");
});

test("public health uses valuation source-as-of cadence instead of export time", () => {
  const fixture = healthyFixture();
  const valuation = fixture.tables.find((table) => table.table === "valuation_ticker_snapshots");
  valuation.latestAt = new Date(now - 2 * 60 * 60 * 1000).toISOString();
  valuation.sourceAt = new Date(now - 46 * 24 * 60 * 60 * 1000).toISOString();
  const health = buildPublicSystemHealth(fixture);
  const module = health.modules.find((entry) => entry.id === "valuation");
  assert.equal(health.ok, true);
  assert.equal(health.degraded, true);
  assert.equal(health.status, "stale");
  assert.equal(module.state, "stale");
  assert.equal(module.freshness.ageHours, 46 * 24);
  assert.equal(module.freshness.warningHours, 45 * 24);
  assert.equal(module.freshness.failedHours, 120 * 24);
  assert.equal(module.freshness.sourceAsOf, valuation.sourceAt);
  assert.equal(module.freshness.observedAt, valuation.latestAt);
  assert.equal(module.freshness.basis, "source_as_of");
  assert.equal(module.freshness.cadence, "quarterly_company_event");
});

test("stale is explicit but serviceable while unknown and failed remain fail-closed", () => {
  const staleFixture = healthyFixture();
  staleFixture.tables.find((table) => table.table === "valuation_ticker_snapshots").sourceAt =
    new Date(now - 46 * 24 * 60 * 60 * 1000).toISOString();
  const stale = buildPublicSystemHealth(staleFixture);
  assert.equal(stale.status, "stale");
  assert.equal(stale.ok, true);
  assert.equal(stale.degraded, true);

  const unknownFixture = healthyFixture();
  unknownFixture.tables.find((table) => table.table === "valuation_ticker_snapshots").sourceAt = "";
  const unknown = buildPublicSystemHealth(unknownFixture);
  assert.equal(unknown.status, "unknown");
  assert.equal(unknown.ok, false);
  assert.equal(unknown.degraded, false);

  const failedFixture = healthyFixture();
  failedFixture.tables.find((table) => table.table === "valuation_ticker_snapshots").sourceAt =
    new Date(now - 121 * 24 * 60 * 60 * 1000).toISOString();
  const failed = buildPublicSystemHealth(failedFixture);
  assert.equal(failed.status, "failed");
  assert.equal(failed.ok, false);
  assert.equal(failed.degraded, false);
});

test("market-price cadence includes a weekend and holiday buffer", () => {
  const healthyFixtureWithWeekend = healthyFixture();
  const prices = healthyFixtureWithWeekend.tables.find((table) => table.table === "price_points");
  prices.sourceAt = new Date(now - 4 * 24 * 60 * 60 * 1000).toISOString();
  let health = buildPublicSystemHealth(healthyFixtureWithWeekend);
  let module = health.modules.find((entry) => entry.id === "market_prices");
  assert.equal(module.state, "healthy");
  assert.equal(module.freshness.warningHours, 5 * 24);
  assert.equal(module.freshness.failedHours, 12 * 24);

  prices.sourceAt = new Date(now - 6 * 24 * 60 * 60 * 1000).toISOString();
  health = buildPublicSystemHealth(healthyFixtureWithWeekend);
  module = health.modules.find((entry) => entry.id === "market_prices");
  assert.equal(module.state, "stale");
  assert.equal(health.ok, true);
});

test("quarterly Guru data remains healthy inside its filing cadence", () => {
  const fixture = healthyFixture();
  const guru = fixture.tables.find((table) => table.table === "guru_snapshots");
  guru.sourceAt = new Date(now - 90 * 24 * 60 * 60 * 1000).toISOString();
  let health = buildPublicSystemHealth(fixture);
  assert.equal(health.modules.find((entry) => entry.id === "guru_data").state, "healthy");

  guru.sourceAt = new Date(now - 101 * 24 * 60 * 60 * 1000).toISOString();
  health = buildPublicSystemHealth(fixture);
  assert.equal(health.modules.find((entry) => entry.id === "guru_data").state, "stale");

  guru.sourceAt = new Date(now - 131 * 24 * 60 * 60 * 1000).toISOString();
  health = buildPublicSystemHealth(fixture);
  assert.equal(health.modules.find((entry) => entry.id === "guru_data").state, "failed");
});

test("current-product health has no retired-module requirement or response field", () => {
  const fixture = healthyFixture();
  const health = buildPublicSystemHealth(fixture);
  assert.equal(health.ok, true);
  assert.equal(Object.hasOwn(health, 'ontology'), false);
  assert.deepEqual(health.modules.map(module=>module.id),['database','guru_data','guru_backtests','valuation','market_prices']);
});

test("a stale retired-module caller argument is ignored, not presented as a healthy module", () => {
  const fixture = healthyFixture();
  Object.defineProperty(fixture,'ontology',{get(){assert.fail('Retired module read');}});
  const health = buildPublicSystemHealth(fixture);
  assert.equal(health.ok,true);
  assert.equal(health.modules.some(module=>module.id==='ontology'),false);
});

test("removing the retired module does not weaken Guru and valuation readiness", () => {
  const fixture=healthyFixture();
  fixture.guruCurves={...fixture.guruCurves,ok:false,displayable:0};
  fixture.tables.find(row=>row.table==='valuation_ticker_snapshots').sourceAt='2000-01-01T00:00:00Z';
  const health=buildPublicSystemHealth(fixture);
  assert.equal(health.ok,false);
  assert.equal(health.modules.find(module=>module.id==='guru_backtests').state,'failed');
  assert.equal(health.modules.find(module=>module.id==='valuation').state,'failed');
});
