import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import { DatabaseSync } from "node:sqlite";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "guru-backtest-cache-test-"));
const databasePath = path.join(tempDir, "cache.sqlite");
fs.closeSync(fs.openSync(databasePath, "w"));
const securityMasterPath = path.join(tempDir, "empty-security-master.json");
const holdingManifestPath = path.join(tempDir, "empty-sec-manifest.json");
const emptyHoldingManifestRecords = {
  managers: [],
  filings: [],
  cusips: []
};
const emptyHoldingManifestRecordsSha256 = crypto.createHash("sha256")
  .update(stableJson(emptyHoldingManifestRecords))
  .digest("hex");
fs.writeFileSync(holdingManifestPath, JSON.stringify({
  schemaVersion: 1,
  generatedAt: "2026-09-02T17:30:00.000Z",
  sourcePolicy: "direct_official_sec_submissions_and_archive_documents_no_derived_cache",
  holdingSelectionPolicy: "top_60_common_long_shares_excluding_explicit_non_common_titles_by_reported_value_per_filing",
  recordsSha256: emptyHoldingManifestRecordsSha256,
  ...emptyHoldingManifestRecords
}));
const emptySecurityMasterRecords = {
  securities: [],
  unresolved: [],
  ambiguous: []
};
function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`
    ).join(",")}}`;
  }
  return JSON.stringify(value);
}
fs.writeFileSync(securityMasterPath, JSON.stringify({
  schemaVersion: 2,
  generatedAt: "2026-09-02T00:00:00.000Z",
  matchingPolicy: "test_empty_master",
  source: {
    identifierProvider: "OpenFIGI",
    holdingManifestPath,
    holdingManifestPolicy: "direct_official_sec_submissions_and_archive_documents_no_derived_cache",
    holdingSelectionPolicy: "top_60_common_long_shares_excluding_explicit_non_common_titles_by_reported_value_per_filing",
    holdingManifestRecordsSha256: emptyHoldingManifestRecordsSha256
  },
  selection: {
    observedCusips: 0,
    resolvedCusips: 0,
    unresolvedCusips: 0,
    ambiguousCusips: 0
  },
  recordsSha256: crypto.createHash("sha256")
    .update(stableJson(emptySecurityMasterRecords))
    .digest("hex"),
  ...emptySecurityMasterRecords
}));
process.env.SQLITE_DB_PATH = databasePath;
process.env.GURU_SECURITY_MASTER_PATH = securityMasterPath;
process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
process.env.SYNC_BUNDLED_GURU_BACKTESTS = "false";
process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";
process.env.SYNC_BUNDLED_PODCAST_INSIGHTS = "false";
process.env.BACKTEST_CACHE_TTL_HOURS = "0";
process.env.BACKTEST_STALE_BACKGROUND_REFRESH = "false";
// This suite exercises the retired SEC/Yahoo simulation adapter in isolation.
// Canonical Sharadar behavior is covered by factRepository/consumer tests.
process.env.FACT_OS_ENABLED = "0";

const { gurus } = await import("./gurus.js");
const { manager13fCorporateActionCatalogVersion } = await import(
  "./corporateActions.js"
);
const {
  readGuruBacktest,
  readGuruBacktestProxy,
  writeGuruBacktest,
  writeGuruBacktestProxy
} = await import("./localDatabase.js");
const {
  assertGuruBacktestRefreshSucceeded,
  buildPublicHoldingsProxyPayload,
  clearGuruBacktestAggregateCache,
  compactBacktestPayload,
  disclosureBacktestMethodVersion,
  exactKnownNonPublicProxyRefreshAllowed,
  expectedGuruBacktestStatus,
  isExtendedBacktestWindow,
  loadGuruBacktest,
  loadGuruBacktests,
  manager13fBacktestMethodVersion,
  manager13fProxyMethodVersion,
  manager13fSecurityMasterVersion,
  normalizeBacktestProxySetting,
  persistBacktestRefreshResult,
  publicBacktestRequestPolicy,
  refreshGuruBacktestCache,
  refreshScheduledGuruBacktestWindows,
  runGuruBacktestComputationAfterCurrent,
  runGuruBacktestComputationOnce,
  scheduledGuruBacktestWindows,
  selectManagerBacktestCache,
  staleBacktestBackgroundRefreshAllowed
} = await import("./backtest.js");

after(() => {
  fs.rmSync(tempDir, { recursive: true, force: true });
});

function fixture(guru, marker, generatedAt) {
  return {
    generatedAt,
    status: "ready",
    guru: {
      id: guru.id,
      name: guru.name,
      type: guru.type
    },
    window: {
      start: "2020-01-02",
      end: "2026-08-28"
    },
    method: guru.type === "manager13f"
      ? {
          version: manager13fBacktestMethodVersion,
          securityMasterVersion: manager13fSecurityMasterVersion,
          minimumExecutionCoverage: 0.9
        }
      : guru.type === "congress"
        ? { version: disclosureBacktestMethodVersion }
        : {},
    summary: { marker, averageCoverage: 1 },
    equity: [
      { date: "2020-01-02", value: 1, benchmark: 1 },
      { date: "2026-08-28", value: 2, benchmark: 1.8 }
    ],
    rebalances: guru.type === "manager13f"
      ? [{
          reportDate: "2026-06-30",
          executionDate: "2026-08-17",
          coveragePct: 1
        }]
      : [],
    dataQuality: guru.type === "manager13f"
      ? {
          minimumExecutionCoverage: 0.9,
          minimumObservedExecutionCoverage: 1
        }
      : {},
    quarterContributions: [{
      id: "2026-q2",
      label: "2026 Q2",
      contributions: [{ ticker: "TEST", issuer: "Test", contributionPct: 0.1 }]
    }]
  };
}

function proxyFixture(guru, marker, generatedAt, {
  proxyMethodVersion = manager13fProxyMethodVersion,
  securityMasterVersion = manager13fSecurityMasterVersion,
  strictFailureGeneratedAt = generatedAt
} = {}) {
  const payload = fixture(guru, marker, generatedAt);
  payload.status = "proxy_ready";
  payload.method = {
    version: manager13fBacktestMethodVersion,
    securityMasterVersion,
    variant: proxyMethodVersion
  };
  payload.proxy = {
    kind: "public_holdings_proxy",
    methodVersion: proxyMethodVersion,
    securityMasterVersion,
    strictFailureGeneratedAt,
    disclosureCode: "incomplete_selected_book_public_holdings_proxy",
    minimumSelectedBookCoverage: 0.4,
    averageSelectedBookCoverage: 0.4,
    maximumExcludedBookWeight: 0.6,
    minimumIncludedPositions: 2,
    topExcludedHoldings: []
  };
  payload.rebalances = [{
    reportDate: "2026-06-30",
    executionDate: "2026-08-17",
    selectedBookCoverage: 0.4,
    includedPositions: 2
  }];
  return payload;
}

function withMethodYears(payload, years) {
  payload.method = { ...(payload.method || {}), years };
  return payload;
}

test("a transient failed refresh retains a ready curve from the current method", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const ready = fixture(ackman, "ready-before-transient-failure", "2026-09-02T00:00:00.000Z");
  writeGuruBacktest(ackman.id, 7, ready);

  const failed = {
    generatedAt: "2026-09-02T01:00:00.000Z",
    status: "insufficient_data",
    guru: ready.guru,
    window: ready.window,
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      reason: "A provider response omitted an internal trading session."
    },
    dataQuality: {
      failure: {
        code: "expected_internal_session_gap",
        missingDates: ["2026-08-28"]
      }
    },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const refreshResult = persistBacktestRefreshResult(
    ackman.id,
    7,
    failed,
    manager13fBacktestMethodVersion
  );

  assert.equal(refreshResult.status, "insufficient_data");
  assert.equal(refreshResult.cache?.retainedReady, true);
  assert.equal(refreshResult.cache?.status, "refresh-failed-ready-retained");
  assert.deepEqual(refreshResult.dataQuality?.readyCacheRetention, {
    retained: true,
    reason: "transient_refresh_failed",
    generatedAt: ready.generatedAt,
    window: ready.window,
    methodVersion: manager13fBacktestMethodVersion,
    securityMasterVersion: manager13fSecurityMasterVersion
  });
  assert.throws(
    () => assertGuruBacktestRefreshSucceeded(ackman, refreshResult),
    /readyCacheRetention.*retained.*true/
  );

  const retained = readGuruBacktest(ackman.id, 7);
  assert.equal(retained.status, "ready");
  assert.equal(retained.summary.marker, "ready-before-transient-failure");
  assert.equal(retained.equity.length, 2);

  const replacement = fixture(
    ackman,
    "ready-after-successful-refresh",
    "2026-09-02T02:00:00.000Z"
  );
  persistBacktestRefreshResult(
    ackman.id,
    7,
    replacement,
    manager13fBacktestMethodVersion
  );
  assert.equal(
    readGuruBacktest(ackman.id, 7).summary.marker,
    "ready-after-successful-refresh"
  );
});

test("a transient congress refresh failure retains its current ready curve", () => {
  const congress = gurus.find((guru) => guru.type === "congress");
  assert.ok(congress);
  const ready = fixture(
    congress,
    "congress-ready-before-transient-failure",
    "2026-09-02T00:00:00.000Z"
  );
  writeGuruBacktest(congress.id, 45, ready);

  const failed = {
    generatedAt: "2026-09-02T01:00:00.000Z",
    status: "insufficient_data",
    guru: ready.guru,
    window: ready.window,
    method: {
      version: disclosureBacktestMethodVersion,
      reason: "A disclosure refresh was temporarily unavailable."
    },
    dataQuality: { failure: { code: "provider_unavailable" } },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const refreshResult = persistBacktestRefreshResult(
    congress.id,
    45,
    failed,
    disclosureBacktestMethodVersion
  );

  assert.equal(refreshResult.cache?.retainedReady, true);
  assert.equal(
    readGuruBacktest(congress.id, 45).summary.marker,
    "congress-ready-before-transient-failure"
  );
});

test("a failed refresh never retains a corrupt current-method strict row", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const ready = fixture(ackman, "corrupt-before-refresh", "2026-09-02T00:00:00.000Z");
  writeGuruBacktest(ackman.id, 44, ready);

  const corrupt = structuredClone(ready);
  delete corrupt.guru.type;
  corrupt.rebalances[0].coveragePct = 0.2;
  corrupt.dataQuality.minimumObservedExecutionCoverage = 0.2;
  corrupt.summary.averageCoverage = 0.2;
  const rawDatabase = new DatabaseSync(databasePath);
  try {
    rawDatabase.prepare(`
      UPDATE guru_backtests
      SET payload_json = ?
      WHERE guru_id = ? AND years = ?
    `).run(JSON.stringify(corrupt), ackman.id, 44);
  } finally {
    rawDatabase.close();
  }

  const failed = {
    generatedAt: "2026-09-02T01:00:00.000Z",
    status: "insufficient_data",
    guru: ready.guru,
    window: ready.window,
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      reason: "The refreshed strict curve failed coverage."
    },
    dataQuality: { failure: { code: "execution_coverage_below_minimum" } },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const refreshResult = persistBacktestRefreshResult(
    ackman.id,
    44,
    failed,
    manager13fBacktestMethodVersion
  );

  assert.equal(refreshResult.cache?.retainedReady, undefined);
  assert.equal(readGuruBacktest(ackman.id, 44).status, "insufficient_data");
});

test("an incompatible ready curve is not retained across a method change", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const oldReady = fixture(ackman, "old-method", "2026-09-02T00:00:00.000Z");
  oldReady.method.version = "manager13f-drifted-total-return-v5";
  writeGuruBacktest(ackman.id, 8, oldReady);

  const failed = {
    generatedAt: "2026-09-02T01:00:00.000Z",
    status: "insufficient_data",
    guru: oldReady.guru,
    window: oldReady.window,
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      reason: "The current method could not produce an audited curve."
    },
    dataQuality: {
      failure: { code: "expected_internal_session_gap" }
    },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const refreshResult = persistBacktestRefreshResult(
    ackman.id,
    8,
    failed,
    manager13fBacktestMethodVersion
  );

  assert.equal(refreshResult.cache?.retainedReady, undefined);
  assert.equal(readGuruBacktest(ackman.id, 8).status, "insufficient_data");
  assert.equal(
    readGuruBacktest(ackman.id, 8).method.version,
    manager13fBacktestMethodVersion
  );
});

test("a ready curve from an older security master is not retained", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const oldReady = fixture(
    ackman,
    "old-security-master",
    "2026-09-02T00:00:00.000Z"
  );
  oldReady.method.securityMasterVersion = "openfigi-sec-v2-old-records";
  writeGuruBacktest(ackman.id, 38, oldReady);

  const failed = {
    generatedAt: "2026-09-02T01:00:00.000Z",
    status: "insufficient_data",
    guru: oldReady.guru,
    window: oldReady.window,
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      reason: "The current security master could not produce a strict curve."
    },
    dataQuality: { failure: { code: "execution_coverage_below_minimum" } },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const refreshResult = persistBacktestRefreshResult(
    ackman.id,
    38,
    failed,
    manager13fBacktestMethodVersion
  );

  assert.equal(refreshResult.cache?.retainedReady, undefined);
  assert.equal(readGuruBacktest(ackman.id, 38).status, "insufficient_data");
  assert.equal(
    readGuruBacktest(ackman.id, 38).method.securityMasterVersion,
    manager13fSecurityMasterVersion
  );
});

test("a mutation-following failed refresh invalidates the pre-mutation ready curve", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const ready = fixture(ackman, "pre-mutation", "2026-09-02T00:00:00.000Z");
  writeGuruBacktest(ackman.id, 9, ready);

  const failed = {
    generatedAt: "2026-09-02T01:00:00.000Z",
    status: "insufficient_data",
    guru: ready.guru,
    window: ready.window,
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      reason: "The audited price-repair generation still failed coverage."
    },
    dataQuality: {
      failure: { code: "missing_active_price" }
    },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const refreshResult = persistBacktestRefreshResult(
    ackman.id,
    9,
    failed,
    manager13fBacktestMethodVersion,
    { preserveReady: false }
  );

  assert.equal(refreshResult.cache?.retainedReady, undefined);
  const stored = readGuruBacktest(ackman.id, 9);
  assert.equal(stored.status, "insufficient_data");
  assert.equal(stored.dataQuality.failure.code, "missing_active_price");
  assert.equal(stored.summary.marker, undefined);
});

test("strict and proxy rows coexist, and a strict ready curve always wins public reads", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const strict = withMethodYears(
    fixture(ackman, "strict-wins", "2026-09-02T00:00:00.000Z"),
    31
  );
  const proxy = withMethodYears(
    proxyFixture(ackman, "proxy-remains-separate", "2026-09-02T01:00:00.000Z"),
    31
  );
  writeGuruBacktest(ackman.id, 31, strict);
  writeGuruBacktestProxy(ackman.id, 31, proxy);

  assert.equal(readGuruBacktest(ackman.id, 31).summary.marker, "strict-wins");
  assert.equal(readGuruBacktestProxy(ackman.id, 31).summary.marker, "proxy-remains-separate");
  assert.equal(selectManagerBacktestCache(strict, proxy).kind, "strict");

  const publicPayload = await loadGuruBacktest(ackman.id, {
    years: 31,
    allowCold: false
  });
  assert.equal(publicPayload.status, "ready");
  assert.equal(publicPayload.summary.marker, "strict-wins");
});

test("the strict cache rejects and ignores proxy payloads", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const proxy = proxyFixture(ackman, "wrong-table", "2026-09-02T00:00:00.000Z");
  assert.throws(
    () => writeGuruBacktest(ackman.id, 36, proxy),
    /Proxy curves must be written with writeGuruBacktestProxy/
  );
  assert.equal(selectManagerBacktestCache(proxy, null).kind, "miss");
});

test("manager cache selection rejects a payload whose declared years do not match the requested key", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const strict = fixture(ackman, "wrong-window", "2026-09-02T00:00:00.000Z");
  strict.method.years = 5;
  assert.equal(selectManagerBacktestCache(strict, null, 10).kind, "miss");
  assert.equal(selectManagerBacktestCache(strict, null, 5).kind, "strict");

  const strictFailure = {
    ...strict,
    status: "insufficient_data",
    equity: []
  };
  const proxy = proxyFixture(
    ackman,
    "wrong-proxy-window",
    strictFailure.generatedAt,
    { strictFailureGeneratedAt: strictFailure.generatedAt }
  );
  proxy.method.years = 5;
  assert.equal(selectManagerBacktestCache(strictFailure, proxy, 10).kind, "miss");
  assert.equal(selectManagerBacktestCache(strictFailure, proxy, 5).kind, "proxy");
});

test("a strict ready row must re-pass the current 90% coverage audit", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const corrupt = fixture(
    ackman,
    "corrupt-strict-coverage",
    "2026-09-02T00:00:00.000Z"
  );
  corrupt.rebalances[0].coveragePct = 0.2;
  corrupt.dataQuality.minimumObservedExecutionCoverage = 0.2;
  corrupt.summary.averageCoverage = 0.2;
  corrupt.guru.type = "congress";

  assert.throws(
    () => writeGuruBacktest(ackman.id, 43, corrupt),
    /Strict cache row failed its coverage audit: strict_rebalance_coverage_below_minimum/
  );
  assert.equal(selectManagerBacktestCache(corrupt, null).kind, "miss");
});

test("a persisted proxy must re-pass the public coverage and position floors", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const strictFailure = {
    ...fixture(ackman, "strict-failure", "2026-09-02T00:00:00.000Z"),
    status: "insufficient_data",
    equity: []
  };
  const corruptCoverage = proxyFixture(
    ackman,
    "corrupt-coverage",
    strictFailure.generatedAt
  );
  corruptCoverage.proxy.minimumSelectedBookCoverage = 0.01;
  corruptCoverage.rebalances[0].selectedBookCoverage = 0.01;
  assert.throws(
    () => writeGuruBacktestProxy(ackman.id, 40, corruptCoverage),
    /failed its public coverage audit: proxy_summary_coverage_below_minimum/
  );
  assert.equal(selectManagerBacktestCache(strictFailure, corruptCoverage).kind, "strict");

  const corruptPositions = proxyFixture(
    ackman,
    "corrupt-positions",
    strictFailure.generatedAt
  );
  corruptPositions.proxy.minimumIncludedPositions = 1;
  corruptPositions.rebalances[0].includedPositions = 1;
  assert.throws(
    () => writeGuruBacktestProxy(ackman.id, 41, corruptPositions),
    /failed its public coverage audit: proxy_summary_positions_below_minimum/
  );
  assert.equal(selectManagerBacktestCache(strictFailure, corruptPositions).kind, "strict");

  const inflatedDisclosure = proxyFixture(
    ackman,
    "inflated-disclosure",
    strictFailure.generatedAt
  );
  inflatedDisclosure.proxy.minimumSelectedBookCoverage = 0.9;
  assert.throws(
    () => writeGuruBacktestProxy(ackman.id, 42, inflatedDisclosure),
    /failed its public coverage audit: proxy_summary_minimum_coverage_mismatch/
  );
  assert.equal(selectManagerBacktestCache(strictFailure, inflatedDisclosure).kind, "strict");
});

test("a refresh downgrade can store a proxy without replacing a retained strict curve", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const strict = withMethodYears(
    fixture(ackman, "strict-before-downgrade", "2026-09-02T00:00:00.000Z"),
    32
  );
  writeGuruBacktest(ackman.id, 32, strict);
  const failed = {
    generatedAt: "2026-09-02T01:00:00.000Z",
    status: "insufficient_data",
    guru: strict.guru,
    window: strict.window,
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years: 32
    },
    dataQuality: { failure: { code: "missing_active_price" } },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const refreshResult = persistBacktestRefreshResult(
    ackman.id,
    32,
    failed,
    manager13fBacktestMethodVersion
  );
  assert.equal(refreshResult.cache.retainedReady, true);
  writeGuruBacktestProxy(
    ackman.id,
    32,
    withMethodYears(
      proxyFixture(ackman, "proxy-after-downgrade", "2026-09-02T01:00:00.000Z"),
      32
    )
  );

  const publicPayload = await loadGuruBacktest(ackman.id, {
    years: 32,
    allowCold: false
  });
  assert.equal(publicPayload.status, "ready");
  assert.equal(publicPayload.summary.marker, "strict-before-downgrade");
  assert.equal(readGuruBacktestProxy(ackman.id, 32).summary.marker, "proxy-after-downgrade");
});

test("a compatible proxy is public only when no compatible strict ready curve exists", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const strictFailure = {
    generatedAt: "2026-09-02T00:00:00.000Z",
    status: "insufficient_data",
    guru: { id: ackman.id, name: ackman.name, type: ackman.type },
    window: { start: "2021-01-01", end: "2026-08-28" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years: 33
    },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const proxy = proxyFixture(
    ackman,
    "proxy-public",
    strictFailure.generatedAt,
    { strictFailureGeneratedAt: strictFailure.generatedAt }
  );
  proxy.method.years = 33;
  writeGuruBacktest(ackman.id, 33, strictFailure);
  writeGuruBacktestProxy(ackman.id, 33, proxy);

  assert.equal(selectManagerBacktestCache(strictFailure, proxy).kind, "proxy");
  const publicPayload = await loadGuruBacktest(ackman.id, {
    years: 33,
    allowCold: false
  });
  assert.equal(publicPayload.status, "proxy_ready");
  assert.equal(publicPayload.summary.marker, "proxy-public");
});

test("Renaissance public reads reject a 5Y proxy while retaining its audited 10Y proxy", async () => {
  const renaissance = gurus.find((guru) => guru.id === "renaissance-technologies");
  const strictFailure = (years, generatedAt) => ({
    generatedAt,
    status: "insufficient_data",
    guru: {
      id: renaissance.id,
      name: renaissance.name,
      type: renaissance.type
    },
    window: { start: "2016-09-01", end: "2026-08-28" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years
    },
    summary: { marker: `renaissance-strict-failure-${years}y` },
    equity: [],
    rebalances: [],
    quarterContributions: []
  });

  for (const years of [5, 10]) {
    const generatedAt = `2026-09-02T0${years === 5 ? 5 : 6}:00:00.000Z`;
    const strict = strictFailure(years, generatedAt);
    const proxy = withMethodYears(proxyFixture(
      renaissance,
      `renaissance-proxy-${years}y`,
      generatedAt,
      { strictFailureGeneratedAt: generatedAt }
    ), years);
    writeGuruBacktest(renaissance.id, years, strict);
    writeGuruBacktestProxy(renaissance.id, years, proxy);
  }

  const fiveYear = await loadGuruBacktest(renaissance.id, {
    years: 5,
    allowCold: false
  });
  assert.equal(fiveYear.status, "insufficient_data");
  assert.equal(fiveYear.summary.marker, "renaissance-strict-failure-5y");

  const tenYear = await loadGuruBacktest(renaissance.id, {
    years: 10,
    allowCold: false
  });
  assert.equal(tenYear.status, "proxy_ready");
  assert.equal(tenYear.summary.marker, "renaissance-proxy-10y");
});

test("an incompatible proxy method is ignored and cannot mask a strict failure", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const strictFailure = {
    generatedAt: "2026-09-02T00:00:00.000Z",
    status: "insufficient_data",
    guru: { id: ackman.id, name: ackman.name, type: ackman.type },
    window: { start: "2021-01-01", end: "2026-08-28" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years: 34
    },
    summary: { marker: "strict-failure" },
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const oldProxy = proxyFixture(
    ackman,
    "old-proxy",
    strictFailure.generatedAt,
    {
      proxyMethodVersion: "manager13f-public-holdings-proxy-v0",
      strictFailureGeneratedAt: strictFailure.generatedAt
    }
  );
  oldProxy.method.years = 34;
  writeGuruBacktest(ackman.id, 34, strictFailure);
  writeGuruBacktestProxy(ackman.id, 34, oldProxy);

  assert.equal(selectManagerBacktestCache(strictFailure, oldProxy).kind, "strict");
  const publicPayload = await loadGuruBacktest(ackman.id, {
    years: 34,
    allowCold: false
  });
  assert.equal(publicPayload.status, "insufficient_data");
  assert.equal(publicPayload.summary.marker, "strict-failure");
});

test("a proxy from an older security master cannot mask a strict failure", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const strictFailure = {
    generatedAt: "2026-09-02T00:30:00.000Z",
    status: "insufficient_data",
    guru: { id: ackman.id, name: ackman.name, type: ackman.type },
    window: { start: "2021-01-01", end: "2026-08-28" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years: 39
    },
    summary: { marker: "current-master-strict-failure" },
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const oldMasterProxy = proxyFixture(
    ackman,
    "old-master-proxy",
    strictFailure.generatedAt,
    {
      securityMasterVersion: "openfigi-sec-v2-old-records",
      strictFailureGeneratedAt: strictFailure.generatedAt
    }
  );
  oldMasterProxy.method.years = 39;
  writeGuruBacktest(ackman.id, 39, strictFailure);
  writeGuruBacktestProxy(ackman.id, 39, oldMasterProxy);

  assert.equal(selectManagerBacktestCache(strictFailure, oldMasterProxy).kind, "strict");
  const publicPayload = await loadGuruBacktest(ackman.id, {
    years: 39,
    allowCold: false
  });
  assert.equal(publicPayload.status, "insufficient_data");
  assert.equal(publicPayload.summary.marker, "current-master-strict-failure");
});

test("an old proxy generation cannot mask a newer strict failure", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const strictFailure = {
    generatedAt: "2026-09-02T02:00:00.000Z",
    status: "insufficient_data",
    guru: { id: ackman.id, name: ackman.name, type: ackman.type },
    window: { start: "2021-01-01", end: "2026-08-28" },
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      years: 35
    },
    summary: { marker: "new-strict-failure" },
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  const staleProxy = proxyFixture(
    ackman,
    "stale-proxy",
    "2026-09-02T00:00:00.000Z",
    { strictFailureGeneratedAt: "2026-09-02T00:00:00.000Z" }
  );
  staleProxy.method.years = 35;
  writeGuruBacktest(ackman.id, 35, strictFailure);
  writeGuruBacktestProxy(ackman.id, 35, staleProxy);

  assert.equal(selectManagerBacktestCache(strictFailure, staleProxy).kind, "strict");
  const publicPayload = await loadGuruBacktest(ackman.id, {
    years: 35,
    allowCold: false
  });
  assert.equal(publicPayload.status, "insufficient_data");
  assert.equal(publicPayload.summary.marker, "new-strict-failure");
});

test("active-price proxy payload exposes compact stable selected-book metadata", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const dates = ["2024-01-02", "2024-01-03", "2024-01-04"];
  const priceMaps = new Map([
    ["SPY", new Map(dates.map((date, index) => [date, 100 + index]))],
    ["AAA", new Map(dates.map((date, index) => [date, 50 + index]))],
    ["BBB", new Map(dates.map((date, index) => [date, 70 + index]))]
  ]);
  const result = buildPublicHoldingsProxyPayload({
    guru: ackman,
    window: { methodYears: 5 },
    start: dates[0],
    end: dates.at(-1),
    history: [{}, {}],
    backtestHistory: [{}, {}],
    excludedFilings: [],
    reportingCiks: [ackman.cik],
    duplicateAccessions: [],
    blockedReportDates: [],
    executionExclusions: [],
    universe: ["AAA", "BBB"],
    rebalances: [{
      reportDate: "2023-12-31",
      filingDate: "2024-01-01",
      executionDate: dates[0],
      selectedValue: 100,
      selectedPositions: 3,
      pricedPositions: 2,
      coveragePct: 0.45,
      cashWeight: 0.55,
      unpricedPositions: [{ issuer: "Private asset", weight: 0.55, value: 55 }],
      weights: [
        { ticker: "AAA", issuer: "Alpha", value: 30, weight: 0.3 },
        { ticker: "BBB", issuer: "Beta", value: 15, weight: 0.15 }
      ]
    }],
    tradingDates: dates,
    priceMaps,
    strictFailureCode: "missing_active_price",
    strictFailure: {
      code: "missing_active_price",
      date: dates[1],
      tickers: ["GAP"],
      missingWeight: 0.1,
      oversizedDiagnostic: "must-not-leak"
    }
  });

  assert.equal(result.failure, null);
  assert.equal(result.payload.status, "proxy_ready");
  assert.equal(
    result.payload.proxy.disclosureCode,
    "incomplete_selected_book_public_holdings_proxy"
  );
  assert.ok(Math.abs(result.payload.proxy.minimumSelectedBookCoverage - 0.45) < 1e-12);
  assert.equal(result.payload.proxy.minimumIncludedPositions, 2);
  assert.deepEqual(result.payload.proxy.topExcludedHoldings, [{
    ticker: null,
    issuer: "Private asset",
    maxExcludedBookWeight: 0.55
  }]);
  assert.equal(result.payload.proxy.disclosure, undefined);
  assert.equal(result.payload.dataQuality.priceSeries, undefined);
  assert.deepEqual(result.payload.dataQuality.strictFailure, {
    code: "missing_active_price",
    date: dates[1],
    tickers: ["GAP"],
    missingWeight: 0.1
  });
});

test("proxy construction fails before simulation for Renaissance's strict-only 5Y window", () => {
  const renaissance = gurus.find((guru) => guru.id === "renaissance-technologies");
  const result = buildPublicHoldingsProxyPayload({
    guru: renaissance,
    window: { methodYears: 5 }
  });

  assert.equal(result.payload, null);
  assert.equal(result.model, null);
  assert.deepEqual(result.failure, {
    code: "public_proxy_not_allowed_for_manager_window",
    guruId: renaissance.id,
    years: 5
  });
});

test("public cold policy uses the same normalized window as the backtest engine", () => {
  assert.equal(isExtendedBacktestWindow(5), false);
  assert.equal(isExtendedBacktestWindow(9.49), false);
  assert.equal(isExtendedBacktestWindow(9.5), true);
  assert.equal(isExtendedBacktestWindow(9.6), true);
  assert.equal(isExtendedBacktestWindow(10), true);
  assert.equal(isExtendedBacktestWindow("all"), true);
  assert.equal(isExtendedBacktestWindow("max"), true);
  assert.equal(isExtendedBacktestWindow("not-a-window"), false);
  assert.deepEqual(publicBacktestRequestPolicy(5, true), {
    allowCold: true,
    refresh: true
  });
  assert.deepEqual(publicBacktestRequestPolicy(9.6, true), {
    allowCold: false,
    refresh: false
  });
  assert.deepEqual(publicBacktestRequestPolicy("all", true), {
    allowCold: false,
    refresh: false
  });
  assert.equal(staleBacktestBackgroundRefreshAllowed(5), true);
  assert.equal(staleBacktestBackgroundRefreshAllowed(10), true);
  assert.equal(staleBacktestBackgroundRefreshAllowed("all"), false);
  assert.equal(staleBacktestBackgroundRefreshAllowed("max"), false);
});

test("proxy env settings fail safely to finite floors", () => {
  assert.equal(normalizeBacktestProxySetting("invalid", 0.3, 0.3, 0.9), 0.3);
  assert.equal(normalizeBacktestProxySetting(Number.NaN, 2, 2, 60, { round: true }), 2);
  assert.equal(normalizeBacktestProxySetting(0.1, 0.3, 0.3, 0.9), 0.3);
  assert.equal(normalizeBacktestProxySetting(100, 2, 2, 60, { round: true }), 60);
});

test("same manager and window share one expensive computation", async () => {
  let builds = 0;
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const build = async () => {
    builds += 1;
    await gate;
    return { marker: "shared" };
  };
  const pending = Array.from(
    { length: 20 },
    () => runGuruBacktestComputationOnce("manager:10:persist", build)
  );
  await Promise.resolve();
  assert.equal(builds, 1);
  release();
  const results = await Promise.all(pending);
  assert.equal(builds, 1);
  assert.ok(results.every((result) => result === results[0]));
});

test("a mutation-following refresh waits for the old generation and recomputes once", async () => {
  let releaseOld;
  let oldBuilds = 0;
  let freshBuilds = 0;
  const oldGate = new Promise((resolve) => {
    releaseOld = resolve;
  });
  const key = "manager:5:repair-generation";
  const old = runGuruBacktestComputationOnce(key, async () => {
    oldBuilds += 1;
    await oldGate;
    return { generation: "pre-repair" };
  });
  await Promise.resolve();

  const buildFresh = async () => {
    freshBuilds += 1;
    return { generation: "post-repair" };
  };
  const fresh = runGuruBacktestComputationAfterCurrent(
    key,
    "price-repair-one",
    buildFresh
  );
  const duplicateFresh = runGuruBacktestComputationAfterCurrent(
    key,
    "price-repair-one",
    buildFresh
  );
  const secondFresh = runGuruBacktestComputationAfterCurrent(
    key,
    "price-repair-two",
    async () => {
      freshBuilds += 1;
      return { generation: "post-second-repair" };
    }
  );
  await Promise.resolve();
  assert.equal(oldBuilds, 1);
  assert.equal(freshBuilds, 0);

  releaseOld();
  assert.deepEqual(await old, { generation: "pre-repair" });
  assert.deepEqual(await fresh, { generation: "post-repair" });
  assert.deepEqual(await duplicateFresh, { generation: "post-repair" });
  assert.deepEqual(await secondFresh, { generation: "post-second-repair" });
  assert.equal(freshBuilds, 2);
});

test("re-compacting a shared result preserves full equity sampling lineage", () => {
  const payload = {
    status: "ready",
    equity: Array.from({ length: 10 }, (_, index) => ({
      date: `2026-01-${String(index + 1).padStart(2, "0")}`,
      value: 1 + index / 10,
      benchmark: 1 + index / 20
    })),
    rebalances: [],
    quarterContributions: []
  };
  const once = compactBacktestPayload(payload, { maxPoints: 5 });
  const twice = compactBacktestPayload(once, { maxPoints: 5 });
  assert.equal(once.equitySampling.sampled, true);
  assert.equal(once.equitySampling.sourcePoints, 10);
  assert.equal(once.equitySampling.returnedPoints, 5);
  assert.equal(twice.equitySampling.sampled, true);
  assert.equal(twice.equitySampling.sourcePoints, 10);
  assert.equal(twice.equitySampling.returnedPoints, 5);
});

test("public extended-history reads reject cold or incompatible caches without recomputing", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const old = fixture(ackman, "old-v5", "2026-08-30T00:00:00.000Z");
  old.method.version = "manager13f-drifted-total-return-v5";
  old.method.years = "all";
  writeGuruBacktest(ackman.id, 0, old);

  const payload = await loadGuruBacktest(ackman.id, {
    years: "all",
    allowCold: false
  });

  assert.equal(payload.status, "not_ready");
  assert.equal(payload.method?.version, manager13fBacktestMethodVersion);
  assert.equal(payload.method?.years, "all");
  assert.match(payload.method?.reason || "", /not pre-warmed.*failed closed/i);
  assert.notEqual(payload.summary?.marker, "old-v5");

  const tenYear = await loadGuruBacktest(ackman.id, {
    years: 10,
    allowCold: false
  });
  assert.equal(tenYear.status, "not_ready");
  assert.equal(tenYear.method?.version, manager13fBacktestMethodVersion);
  assert.equal(tenYear.method?.years, 10);
  assert.match(tenYear.method?.reason || "", /not pre-warmed.*failed closed/i);

  const congress = gurus.find((guru) => guru.type === "congress" && !guru.disableSimulation);
  const oldCongress = fixture(congress, "old-disclosure-method", "2026-08-30T00:00:00.000Z");
  delete oldCongress.method.version;
  oldCongress.method.years = 10;
  writeGuruBacktest(congress.id, 10, oldCongress);
  const congressTenYear = await loadGuruBacktest(congress.id, {
    years: 10,
    allowCold: false
  });
  assert.equal(congressTenYear.status, "not_ready");
  assert.equal(congressTenYear.method?.version, disclosureBacktestMethodVersion);
  assert.equal(congressTenYear.method?.years, 10);
  assert.match(congressTenYear.method?.reason || "", /not pre-warmed.*failed closed/i);
});

test("public congress extended history can serve a stale cached curve", async () => {
  const congress = gurus.find((guru) => guru.type === "congress" && !guru.disableSimulation);
  const stale = fixture(congress, "congress-stale", "2026-08-01T00:00:00.000Z");
  stale.method.years = 10;
  writeGuruBacktest(congress.id, 10, stale);

  const originalTtl = process.env.BACKTEST_CACHE_TTL_HOURS;
  const originalBackgroundRefresh = process.env.BACKTEST_STALE_BACKGROUND_REFRESH;
  const originalNow = Date.now;
  try {
    process.env.BACKTEST_CACHE_TTL_HOURS = "20";
    process.env.BACKTEST_STALE_BACKGROUND_REFRESH = "false";
    Date.now = () => new Date("2026-09-02T00:00:00.000Z").getTime();
    const payload = await loadGuruBacktest(congress.id, {
      years: 10,
      allowCold: false
    });
    assert.equal(payload.status, "ready");
    assert.equal(payload.summary?.marker, "congress-stale");
    assert.equal(payload.cache?.status, "sqlite-stale");
    assert.equal(payload.cache?.stale, true);
    assert.equal(payload.historyWarming, false);
  } finally {
    process.env.BACKTEST_CACHE_TTL_HOURS = originalTtl;
    if (originalBackgroundRefresh == null) {
      delete process.env.BACKTEST_STALE_BACKGROUND_REFRESH;
    } else {
      process.env.BACKTEST_STALE_BACKGROUND_REFRESH = originalBackgroundRefresh;
    }
    Date.now = originalNow;
  }
});

test("a stale All cache is served without claiming a background refresh", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const stale = fixture(ackman, "all-stale", "2026-08-01T00:00:00.000Z");
  stale.method.years = "all";
  stale.historyWarming = true;
  writeGuruBacktest(ackman.id, 0, stale);

  const originalTtl = process.env.BACKTEST_CACHE_TTL_HOURS;
  const originalNow = Date.now;
  try {
    process.env.BACKTEST_CACHE_TTL_HOURS = "20";
    Date.now = () => new Date("2026-09-02T00:00:00.000Z").getTime();
    const payload = await loadGuruBacktest(ackman.id, {
      years: "all",
      allowCold: false
    });
    assert.equal(payload.status, "ready");
    assert.equal(payload.summary?.marker, "all-stale");
    assert.equal(payload.cache?.status, "sqlite-stale");
    assert.equal(payload.cache?.stale, true);
    assert.equal(payload.historyWarming, false);
  } finally {
    process.env.BACKTEST_CACHE_TTL_HOURS = originalTtl;
    Date.now = originalNow;
  }
});

test("aggregate backtests cache by window/detail and invalidate on data or refresh version", async () => {
  const supported = gurus.filter((guru) => guru.type === "manager13f" || guru.type === "congress");
  for (const guru of supported) {
    writeGuruBacktest(
      guru.id,
      0,
      withMethodYears(fixture(guru, "v1", "2026-08-30T00:00:00.000Z"), "all")
    );
  }

  const compact = await loadGuruBacktests({ years: "all", detail: "compact" });
  const compactHit = await loadGuruBacktests({ years: "max", detail: "compact" });
  assert.strictEqual(compactHit, compact, "normalized all/max windows should share a cache entry");

  const full = await loadGuruBacktests({ years: "all", detail: "full" });
  const attributionHit = await loadGuruBacktests({ years: "all", detail: "attribution" });
  assert.notStrictEqual(full, compact, "full and compact responses must use separate cache entries");
  assert.strictEqual(attributionHit, full, "full/attribution aliases should share a cache entry");

  const changedGuru = supported.find((guru) => guru.type === "manager13f" && !guru.disableSimulation);
  writeGuruBacktest(
    changedGuru.id,
    0,
    withMethodYears(fixture(changedGuru, "v2", "2026-08-30T00:01:00.000Z"), "all")
  );
  const afterDataChange = await loadGuruBacktests({ years: "all", detail: "compact" });
  assert.notStrictEqual(afterDataChange, compact, "row version change must invalidate the aggregate");
  assert.equal(
    afterDataChange.backtests.find((row) => row.guru?.id === changedGuru.id)?.summary?.marker,
    "v2"
  );

  const cachedAfterDataChange = await loadGuruBacktests({ years: "all", detail: "compact" });
  assert.strictEqual(cachedAfterDataChange, afterDataChange);

  const originalTypes = supported.map((guru) => [guru, guru.type]);
  try {
    for (const [guru] of originalTypes) guru.type = "test-disabled";
    await refreshGuruBacktestCache({ reason: "cache-invalidation-test" });
  } finally {
    for (const [guru, type] of originalTypes) guru.type = type;
  }

  const afterRefresh = await loadGuruBacktests({ years: "all", detail: "compact" });
  assert.notStrictEqual(afterRefresh, cachedAfterDataChange, "refresh completion must clear aggregates");
});

test("aggregate cache cannot outlive the freshness of its individual backtests", async () => {
  const originalNow = Date.now;
  const originalTtl = process.env.BACKTEST_CACHE_TTL_HOURS;
  const originalTypes = gurus.map((guru) => [guru, guru.type]);
  try {
    for (const [guru] of originalTypes) {
      if (guru.type === "congress") guru.type = "test-disabled";
    }
    const supported = gurus.filter((guru) => guru.type === "manager13f");
    process.env.BACKTEST_CACHE_TTL_HOURS = "20";
    Date.now = () => new Date("2026-08-30T01:00:00.000Z").getTime();
    for (const guru of supported) {
      writeGuruBacktest(
        guru.id,
        0,
        withMethodYears(fixture(guru, "ttl", "2026-08-30T00:00:00.000Z"), "all")
      );
    }
    clearGuruBacktestAggregateCache();

    const initial = await loadGuruBacktests({ years: "all", detail: "compact" });
    const initialHit = await loadGuruBacktests({ years: "all", detail: "compact" });
    assert.strictEqual(initialHit, initial);

    Date.now = () => new Date("2026-08-31T22:00:00.000Z").getTime();
    const expired = await loadGuruBacktests({ years: "all", detail: "compact" });
    const expiredAgain = await loadGuruBacktests({ years: "all", detail: "compact" });
    assert.notStrictEqual(expired, initial, "expired individual rows must evict the aggregate");
    assert.strictEqual(
      expiredAgain,
      expired,
      "stale rows may share a short-lived aggregate without losing stale metadata"
    );
    assert.ok(
      expired.backtests.some((row) => row.cache?.stale === true),
      "expired manager rows must retain their stale marker"
    );
    Date.now = () => new Date("2026-08-31T22:00:31.000Z").getTime();
    const staleAggregateExpired = await loadGuruBacktests({ years: "all", detail: "compact" });
    assert.notStrictEqual(
      staleAggregateExpired,
      expired,
      "stale aggregates must expire on the bounded retry interval"
    );
  } finally {
    for (const [guru, type] of originalTypes) guru.type = type;
    Date.now = originalNow;
    process.env.BACKTEST_CACHE_TTL_HOURS = originalTtl;
    clearGuruBacktestAggregateCache();
  }
});

test("concurrent aggregate misses share one in-flight build", async () => {
  const supported = gurus.filter((guru) => guru.type === "manager13f" || guru.type === "congress");
  for (const guru of supported) {
    writeGuruBacktest(
      guru.id,
      0,
      withMethodYears(fixture(guru, "single-flight", "2026-08-30T03:00:00.000Z"), "all")
    );
  }
  clearGuruBacktestAggregateCache();

  const results = await Promise.all(Array.from(
    { length: 20 },
    () => loadGuruBacktests({ years: "all", detail: "compact" })
  ));
  for (const result of results.slice(1)) {
    assert.strictEqual(result, results[0]);
  }
});

test("strict refresh stays failed while the atomic layer recognizes only the exact Peltz/JHG pair", () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const peltz = gurus.find((guru) => guru.id === "nelson-peltz");
  const renaissance = gurus.find((guru) => guru.id === "renaissance-technologies");

  assert.equal(expectedGuruBacktestStatus(ackman), "ready");
  assert.equal(expectedGuruBacktestStatus(renaissance), "ready");
  assert.doesNotThrow(() => assertGuruBacktestRefreshSucceeded(ackman, { status: "ready" }));
  assert.throws(() =>
    assertGuruBacktestRefreshSucceeded(ackman, {
      status: "proxy_ready",
      proxy: { kind: "public_holdings_proxy" }
    }), /bill-ackman refresh backtest status is proxy_ready; expected ready/i
  );
  assert.doesNotThrow(() =>
    assertGuruBacktestRefreshSucceeded(renaissance, { status: "ready" })
  );
  assert.throws(
    () => assertGuruBacktestRefreshSucceeded(ackman, {
      status: "insufficient_data",
      method: { reason: "Adjusted-close coverage is below the required threshold." }
    }),
    /bill-ackman refresh backtest status is insufficient_data; expected ready.*Adjusted-close coverage/i
  );
  assert.throws(
    () => assertGuruBacktestRefreshSucceeded(renaissance, { status: "unsupported" }),
    /renaissance-technologies refresh backtest status is unsupported; expected ready/i
  );

  const exactPeltzProxy = proxyFixture(
    peltz,
    "private-rollover-public-sleeve",
    "2026-09-03T00:00:00.000Z"
  );
  exactPeltzProxy.method.years = 5;
  exactPeltzProxy.method.corporateActionCatalogVersion =
    manager13fCorporateActionCatalogVersion;
  exactPeltzProxy.dataQuality = {
    strictBacktestStatus: "insufficient_data",
    strictFailureCode: "execution_coverage_below_minimum",
    strictFailingRebalances: 1,
    strictMinimumExecutionCoverage: 0.9
  };
  exactPeltzProxy.publicReplicability = {
    status: "strict_unavailable",
    code: "reported_holding_private_before_execution",
    guruId: "nelson-peltz",
    minimumExecutionCoverage: 0.9,
    syntheticPriceUsed: false,
    proxyOnlyWhenSeparatelyLabelled: true,
    affectedQuarters: [{
      reportDate: "2026-06-30",
      quarterLabel: "2026 Q2",
      executionDate: "2026-08-17",
      coveragePct: 0.55,
      minimumExecutionCoverage: 0.9,
      strictGateSatisfied: false,
      holdings: [{
        code: "reported_security_private_before_execution",
        ticker: "JHG",
        issuer: "Janus Henderson Group plc",
        cusip: "G4474Y214",
        reportedBookWeight: 0.45,
        publicTradingStatus: "private_before_execution",
        syntheticPriceUsed: false
      }]
    }]
  };
  exactPeltzProxy.rebalances[0].unpricedPositions = [{
    ticker: "JHG",
    issuer: "Janus Henderson Group plc",
    cusip: "G4474Y214",
    reportedBookWeight: 0.45,
    reason: "reported_security_private_before_execution"
  }];
  const exactPeltzStrict = {
    generatedAt: exactPeltzProxy.generatedAt,
    status: "insufficient_data",
    guru: exactPeltzProxy.guru,
    window: exactPeltzProxy.window,
    method: {
      version: manager13fBacktestMethodVersion,
      securityMasterVersion: manager13fSecurityMasterVersion,
      corporateActionCatalogVersion: manager13fCorporateActionCatalogVersion,
      years: 5,
      minimumExecutionCoverage: 0.9,
      reason: "Strict execution coverage is below the required threshold."
    },
    publicReplicability: structuredClone(exactPeltzProxy.publicReplicability),
    dataQuality: {
      failurePolicy: "fail_closed",
      coverageFailures: [{
        reportDate: "2026-06-30",
        executionDate: "2026-08-17",
        coveragePct: 0.55,
        unpricedPositions: [{
          ticker: "JHG",
          issuer: "Janus Henderson Group plc",
          cusip: "G4474Y214",
          reason: "reported_security_private_before_execution",
          executionLimitation: {
            code: "reported_security_private_before_execution",
            reportDate: "2026-06-30",
            ticker: "JHG",
            cusip: "G4474Y214",
            publicTradingStatus: "private_before_execution",
            syntheticPriceUsed: false
          }
        }]
      }]
    },
    summary: {},
    equity: [],
    rebalances: [],
    quarterContributions: []
  };
  assert.equal(
    exactKnownNonPublicProxyRefreshAllowed(
      peltz,
      exactPeltzStrict,
      exactPeltzProxy
    ),
    true
  );
  assert.equal(
    exactKnownNonPublicProxyRefreshAllowed(
      peltz,
      exactPeltzStrict,
      compactBacktestPayload(exactPeltzProxy)
    ),
    true
  );
  assert.throws(() =>
    assertGuruBacktestRefreshSucceeded(peltz, exactPeltzProxy),
    /status is proxy_ready; expected ready/i
  );
  assert.equal(
    exactKnownNonPublicProxyRefreshAllowed(
      ackman,
      exactPeltzStrict,
      exactPeltzProxy
    ),
    false
  );
  assert.equal(
    exactKnownNonPublicProxyRefreshAllowed(peltz, exactPeltzStrict, {
      ...exactPeltzProxy,
      proxy: {
        ...exactPeltzProxy.proxy,
        strictFailureGeneratedAt: "2026-09-02T00:00:00.000Z"
      }
    }),
    false
  );
  assert.equal(
    exactKnownNonPublicProxyRefreshAllowed(peltz, exactPeltzStrict, {
      ...exactPeltzProxy,
      publicReplicability: {
        ...exactPeltzProxy.publicReplicability,
        syntheticPriceUsed: true
      }
    }),
    false
  );
});

test("cache refresh counts insufficient_data as failed instead of ok", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const originalTypes = gurus.map((guru) => [guru, guru.type]);
  try {
    for (const [guru] of originalTypes) {
      if (guru !== ackman) guru.type = "test-disabled";
    }
    const result = await refreshGuruBacktestCache({
      years: 5,
      reason: "status-gate-test",
      backtestLoader: async () => ({
        status: "insufficient_data",
        method: { reason: "Execution coverage is below 90%." }
      })
    });

    assert.equal(result.ok, 0);
    assert.equal(result.failed, 1);
    assert.equal(result.proxyAvailable, 0);
    assert.equal(result.errors[0]?.guru, "bill-ackman");
    assert.match(result.errors[0]?.message || "", /insufficient_data; expected ready/i);
  } finally {
    for (const [guru, type] of originalTypes) guru.type = type;
  }
});

test("cache refresh counts proxy_ready as a failed strict refresh", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const originalTypes = gurus.map((guru) => [guru, guru.type]);
  try {
    for (const [guru] of originalTypes) {
      if (guru !== ackman) guru.type = "test-disabled";
    }
    const result = await refreshGuruBacktestCache({
      years: 5,
      reason: "proxy-is-not-strict-test",
      backtestLoader: async () => proxyFixture(
        ackman,
        "proxy-is-public-only",
        "2026-09-02T00:00:00.000Z"
      )
    });

    assert.equal(result.ok, 0);
    assert.equal(result.failed, 1);
    assert.equal(result.proxyAvailable, 1);
    assert.equal(result.errors[0]?.guru, "bill-ackman");
    assert.match(result.errors[0]?.message || "", /proxy_ready; expected ready/i);
  } finally {
    for (const [guru, type] of originalTypes) guru.type = type;
  }
});

test("production prewarm population refreshes only enabled manager13f profiles", async () => {
  const enabledManagerIds = gurus.filter((guru) =>
    guru.type === "manager13f" && !guru.disableSimulation
  ).map((guru) => guru.id);
  const scopedCalls = [];
  const scoped = await refreshGuruBacktestCache({
    years: 5,
    reason: "production-prewarm-population-test",
    population: "enabled-manager13f",
    backtestLoader: async (guruId) => {
      scopedCalls.push(guruId);
      const guru = gurus.find((item) => item.id === guruId);
      return withMethodYears(
        fixture(guru, "enabled-manager13f", "2026-09-03T00:00:00.000Z"),
        5
      );
    }
  });

  assert.deepEqual(scopedCalls, enabledManagerIds);
  assert.equal(scoped.population, "enabled-manager13f");
  assert.equal(scoped.ok, enabledManagerIds.length);
  assert.equal(scoped.failed, 0);
  assert.equal(scopedCalls.includes("nancy-pelosi"), false);
  assert.equal(scopedCalls.includes("renaissance-technologies"), true);
  assert.equal(scopedCalls.includes("nick-sleep-qais-zakaria"), false);
});

test("default bulk refresh retains congress and disabled-manager behavior", async () => {
  const supportedGurus = gurus.filter((guru) =>
    guru.type === "manager13f" || guru.type === "congress"
  );
  const defaultCalls = [];
  const result = await refreshGuruBacktestCache({
    years: 5,
    reason: "default-population-compatibility-test",
    backtestLoader: async (guruId) => {
      defaultCalls.push(guruId);
      const guru = gurus.find((item) => item.id === guruId);
      const payload = withMethodYears(
        fixture(guru, "all-supported", "2026-09-03T00:00:00.000Z"),
        5
      );
      if (guru.disableSimulation) payload.status = "unsupported";
      return payload;
    }
  });

  assert.deepEqual(defaultCalls, supportedGurus.map((guru) => guru.id));
  assert.equal(result.population, "all-supported");
  assert.equal(result.ok, supportedGurus.length);
  assert.equal(result.failed, 0);
  assert.equal(defaultCalls.includes("nancy-pelosi"), true);
  assert.equal(defaultCalls.includes("renaissance-technologies"), true);
  assert.equal(defaultCalls.includes("nick-sleep-qais-zakaria"), true);
});

test("bulk refresh rejects an unknown population before loading any guru", async () => {
  let calls = 0;
  await assert.rejects(
    refreshGuruBacktestCache({
      population: "managers-ish",
      backtestLoader: async () => {
        calls += 1;
        return { status: "ready" };
      }
    }),
    /Backtest refresh population is invalid/
  );
  assert.equal(calls, 0);
});

test("a mutation generation waits for an older bulk refresh and then recomputes", async () => {
  const ackman = gurus.find((guru) => guru.id === "bill-ackman");
  const originalTypes = gurus.map((guru) => [guru, guru.type]);
  let releaseFirst;
  let signalFirst;
  const firstStarted = new Promise((resolve) => {
    signalFirst = resolve;
  });
  const holdFirst = new Promise((resolve) => {
    releaseFirst = resolve;
  });
  const calls = [];
  try {
    for (const [guru] of originalTypes) {
      if (guru !== ackman) guru.type = "test-disabled";
    }
    const loader = async (_guruId, options) => {
      calls.push(options);
      if (calls.length === 1) {
        signalFirst();
        await holdFirst;
      }
      return { status: "ready" };
    };
    const older = refreshGuruBacktestCache({
      years: 5,
      reason: "pre-mutation-refresh",
      backtestLoader: loader
    });
    await firstStarted;
    const repaired = refreshGuruBacktestCache({
      years: 5,
      reason: "post-mutation-refresh",
      refreshGeneration: "repair-generation-1234",
      backtestLoader: loader
    });
    releaseFirst();
    await Promise.all([older, repaired]);

    assert.equal(calls.length, 2);
    assert.equal(calls[0].refreshGeneration, undefined);
    assert.equal(calls[1].refreshGeneration, "repair-generation-1234");
  } finally {
    for (const [guru, type] of originalTypes) guru.type = type;
  }
});

test("scheduled refresh warms both the 5Y and 10Y public curve windows sequentially", async () => {
  const calls = [];
  let active = 0;
  let maximumConcurrency = 0;
  const results = await refreshScheduledGuruBacktestWindows({
    reason: "daily",
    refresh: async (options) => {
      active += 1;
      maximumConcurrency = Math.max(maximumConcurrency, active);
      calls.push(options);
      await Promise.resolve();
      active -= 1;
      return { years: options.years };
    }
  });

  assert.deepEqual(scheduledGuruBacktestWindows, [5, 10]);
  assert.deepEqual(calls, [
    { years: 5, detail: "compact", reason: "daily-5y" },
    { years: 10, detail: "compact", reason: "daily-10y" }
  ]);
  assert.deepEqual(results, [{ years: 5 }, { years: 10 }]);
  assert.equal(maximumConcurrency, 1);
});

test("scheduled refresh status preserves a 5Y failure when 10Y succeeds", async () => {
  await refreshScheduledGuruBacktestWindows({
    reason: "daily",
    refresh: async ({ years }) => years === 5
      ? {
          ok: 17,
          failed: 1,
          proxyAvailable: 1,
          errors: [{ guru: "manager-one", message: "5Y failed" }]
        }
      : {
          ok: 18,
          failed: 0,
          proxyAvailable: 0,
          errors: []
        }
  });

  const status = (await import("./backtest.js")).guruBacktestRefreshStatus();
  assert.equal(status.running, false);
  assert.equal(status.ok, 35);
  assert.equal(status.failed, 1);
  assert.equal(status.proxyAvailable, 1);
  assert.deepEqual(status.windows, [
    { years: 5, status: "failed", ok: 17, failed: 1, proxyAvailable: 1 },
    { years: 10, status: "success", ok: 18, failed: 0, proxyAvailable: 0 }
  ]);
  assert.deepEqual(status.errors, [{
    guru: "manager-one",
    message: "5Y failed",
    years: 5
  }]);
});
