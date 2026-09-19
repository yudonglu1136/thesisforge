import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

const syncVariables = [
  "SYNC_BUNDLED_VALUATION_SNAPSHOTS",
  "SYNC_BUNDLED_GURU_BACKTESTS",
  "SYNC_BUNDLED_DIVIDEND_CALENDAR",
  "SYNC_BUNDLED_PODCAST_INSIGHTS"
];

const fixtureTimestamp = "2026-09-01T00:00:00.000Z";

function strictBacktestPayload({
  marker = "bundled-strict",
  methodVersion = "manager13f-drifted-total-return-v9",
  securityMasterVersion = "openfigi-sec-v2-current"
} = {}) {
  return {
    status: "ready",
    marker,
    guru: { type: "manager13f" },
    method: { version: methodVersion, securityMasterVersion }
  };
}

function proxyBacktestPayload({
  marker = "bundled-proxy",
  strictMethodVersion = "manager13f-drifted-total-return-v9",
  methodVersion = "manager13f-public-holdings-proxy-v1",
  securityMasterVersion = "openfigi-sec-v2-current"
} = {}) {
  return {
    status: "proxy_ready",
    marker,
    guru: { type: "manager13f" },
    method: {
      version: strictMethodVersion,
      variant: methodVersion,
      securityMasterVersion
    },
    proxy: { methodVersion, securityMasterVersion }
  };
}

function createBundledFixture(file, {
  strict = strictBacktestPayload(),
  proxy = proxyBacktestPayload()
} = {}) {
  const database = new DatabaseSync(file);
  database.exec(`
    CREATE TABLE valuation_snapshots (
      id TEXT PRIMARY KEY, generated_at TEXT NOT NULL, payload_json TEXT NOT NULL
    );
    CREATE TABLE valuation_ticker_snapshots (
      ticker TEXT PRIMARY KEY, generated_at TEXT NOT NULL, payload_json TEXT NOT NULL
    );
    CREATE TABLE guru_backtests (
      guru_id TEXT NOT NULL, years INTEGER NOT NULL, generated_at TEXT NOT NULL,
      start_date TEXT, end_date TEXT, payload_json TEXT NOT NULL,
      PRIMARY KEY (guru_id, years)
    );
    CREATE TABLE guru_backtest_proxies (
      guru_id TEXT NOT NULL, years INTEGER NOT NULL, generated_at TEXT NOT NULL,
      start_date TEXT, end_date TEXT, method_version TEXT NOT NULL,
      payload_json TEXT NOT NULL, PRIMARY KEY (guru_id, years)
    );
    CREATE TABLE dividend_events (
      ticker TEXT NOT NULL, company_name TEXT, ex_date TEXT NOT NULL, pay_date TEXT,
      record_date TEXT, declaration_date TEXT, amount REAL, currency TEXT, status TEXT,
      source TEXT NOT NULL, source_label TEXT, logo_url TEXT, payload_json TEXT,
      updated_at TEXT NOT NULL, PRIMARY KEY (ticker, ex_date, source)
    );
    CREATE TABLE ticker_assets (
      ticker TEXT PRIMARY KEY, company_name TEXT, logo_url TEXT, logo_domain TEXT,
      logo_source TEXT, payload_json TEXT, updated_at TEXT NOT NULL
    );
    CREATE TABLE valuation_podcast_insights (
      id TEXT PRIMARY KEY, ticker TEXT NOT NULL, generated_at TEXT NOT NULL,
      observed_at TEXT, channel TEXT, video_id TEXT, video_title TEXT, video_url TEXT,
      speaker TEXT, theme TEXT, stance TEXT, horizon TEXT, confidence REAL,
      relevance_score REAL, summary TEXT, summary_zh TEXT, evidence_excerpt TEXT,
      evidence_excerpt_zh TEXT, payload_json TEXT
    );
    CREATE TABLE background_job_runs (
      job_id TEXT PRIMARY KEY, started_at TEXT, finished_at TEXT, status TEXT,
      payload_json TEXT
    );
  `);
  database.prepare(
    "INSERT INTO valuation_snapshots VALUES (?, ?, ?)"
  ).run("latest", fixtureTimestamp, JSON.stringify({ tickers: [{ ticker: "TEST" }] }));
  database.prepare(
    "INSERT INTO valuation_ticker_snapshots VALUES (?, ?, ?)"
  ).run("TEST", fixtureTimestamp, JSON.stringify({ ticker: "TEST" }));
  database.prepare(
    "INSERT INTO guru_backtests VALUES (?, ?, ?, ?, ?, ?)"
  ).run("test-guru", 0, fixtureTimestamp, "2020-01-01", "2026-08-31", JSON.stringify(strict));
  database.prepare(
    "INSERT INTO guru_backtest_proxies VALUES (?, ?, ?, ?, ?, ?, ?)"
  ).run(
    "proxy-guru",
    5,
    fixtureTimestamp,
    "2021-01-01",
    "2026-08-31",
    proxy.proxy.methodVersion,
    JSON.stringify(proxy)
  );
  database.prepare(
    "INSERT INTO dividend_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  ).run(
    "TEST",
    "Test Corp",
    "2026-09-15",
    "2026-09-30",
    "2026-09-16",
    "2026-09-01",
    1,
    "USD",
    "confirmed",
    "fixture",
    "Fixture",
    "",
    "{}",
    fixtureTimestamp
  );
  database.prepare(
    "INSERT INTO ticker_assets VALUES (?, ?, ?, ?, ?, ?, ?)"
  ).run("TEST", "Test Corp", "", "", "fixture", "{}", fixtureTimestamp);
  database.prepare(
    "INSERT INTO valuation_podcast_insights VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  ).run(
    "insight-1",
    "TEST",
    fixtureTimestamp,
    fixtureTimestamp,
    "Fixture",
    "video-1",
    "Fixture video",
    "https://example.com/video",
    "Analyst",
    "valuation",
    "neutral",
    "long-term",
    0.8,
    0.9,
    "Fixture summary",
    "",
    "Fixture evidence",
    "",
    "{}"
  );
  const writeJob = database.prepare(
    "INSERT INTO background_job_runs VALUES (?, ?, ?, ?, ?)"
  );
  writeJob.run(
    "portfolio_dividend_calendar",
    fixtureTimestamp,
    fixtureTimestamp,
    "success",
    "{}"
  );
  writeJob.run(
    "valuation_podcast_insights",
    fixtureTimestamp,
    fixtureTimestamp,
    "success",
    "{}"
  );
  database.close();
}

function createPreExistingDatabase(file) {
  const database = new DatabaseSync(file);
  database.exec("CREATE TABLE custom_sentinel (value TEXT PRIMARY KEY)");
  database.prepare("INSERT INTO custom_sentinel VALUES (?)").run("preserve-me");
  database.close();
}

function prepareServerFixture(directory, bundledOptions) {
  const serverDirectory = path.join(directory, "server");
  const dataDirectory = path.join(serverDirectory, "data");
  fs.mkdirSync(dataDirectory, { recursive: true });
  fs.writeFileSync(path.join(directory, "package.json"), JSON.stringify({ type: "module" }));
  fs.copyFileSync(path.resolve("server/localDatabase.js"), path.join(serverDirectory, "localDatabase.js"));
  fs.copyFileSync(path.resolve("server/databaseTableSummaries.js"), path.join(serverDirectory, "databaseTableSummaries.js"));
  fs.copyFileSync(path.resolve("server/databaseHealthIndexes.js"), path.join(serverDirectory, "databaseHealthIndexes.js"));
  fs.copyFileSync(path.resolve("server/gurus.js"), path.join(serverDirectory, "gurus.js"));
  fs.copyFileSync(
    path.resolve("server/backtestProxyAudit.js"),
    path.join(serverDirectory, "backtestProxyAudit.js")
  );
  fs.copyFileSync(
    path.resolve("server/backtestStrictAudit.js"),
    path.join(serverDirectory, "backtestStrictAudit.js")
  );
  fs.copyFileSync(
    path.resolve("server/bundledValuationSnapshotPolicy.js"),
    path.join(serverDirectory, "bundledValuationSnapshotPolicy.js")
  );
  createBundledFixture(
    path.join(dataDirectory, "guru-analysis.sqlite"),
    bundledOptions
  );
  return path.join(serverDirectory, "localDatabase.js");
}

function seedExistingGuruCaches(file, { strict, proxy }) {
  const database = new DatabaseSync(file);
  try {
    database.prepare(
      "INSERT INTO guru_backtests VALUES (?, ?, ?, ?, ?, ?)"
    ).run(
      "test-guru",
      0,
      fixtureTimestamp,
      "2020-01-01",
      "2026-08-31",
      JSON.stringify(strict)
    );
    database.prepare(
      "INSERT INTO guru_backtest_proxies VALUES (?, ?, ?, ?, ?, ?, ?)"
    ).run(
      "proxy-guru",
      5,
      fixtureTimestamp,
      "2021-01-01",
      "2026-08-31",
      proxy.proxy.methodVersion,
      JSON.stringify(proxy)
    );
  } finally {
    database.close();
  }
}

function readGuruCachePayloads(file) {
  const database = new DatabaseSync(file, { readOnly: true });
  try {
    return {
      strict: JSON.parse(database.prepare(`
        SELECT payload_json FROM guru_backtests WHERE guru_id = ? AND years = ?
      `).get("test-guru", 0).payload_json),
      proxy: JSON.parse(database.prepare(`
        SELECT payload_json FROM guru_backtest_proxies WHERE guru_id = ? AND years = ?
      `).get("proxy-guru", 5).payload_json)
    };
  } finally {
    database.close();
  }
}

function importLocalDatabase(modulePath, databasePath, optIn) {
  const environment = { ...process.env, NODE_ENV: "test", SQLITE_DB_PATH: databasePath };
  for (const name of syncVariables) {
    if (optIn) environment[name] = "true";
    else delete environment[name];
  }
  const result = spawnSync(process.execPath, [modulePath], {
    cwd: path.dirname(path.dirname(modulePath)),
    env: environment,
    encoding: "utf8"
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

function datasetCounts(file) {
  const database = new DatabaseSync(file, { readOnly: true });
  try {
    const hasSentinel = Boolean(database.prepare(`
      SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'custom_sentinel'
    `).get());
    return {
      valuationDashboard: Number(database.prepare("SELECT COUNT(*) AS count FROM valuation_snapshots").get().count),
      valuationTickers: Number(database.prepare("SELECT COUNT(*) AS count FROM valuation_ticker_snapshots").get().count),
      backtests: Number(database.prepare("SELECT COUNT(*) AS count FROM guru_backtests").get().count),
      backtestProxies: Number(database.prepare("SELECT COUNT(*) AS count FROM guru_backtest_proxies").get().count),
      dividends: Number(database.prepare("SELECT COUNT(*) AS count FROM dividend_events").get().count),
      podcasts: Number(database.prepare("SELECT COUNT(*) AS count FROM valuation_podcast_insights").get().count),
      sentinel: hasSentinel
        ? database.prepare("SELECT value FROM custom_sentinel").get()?.value
        : null
    };
  } finally {
    database.close();
  }
}

test("custom databases never receive bundled datasets without explicit opt-in", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "local-database-sync-test-"));
  try {
    const modulePath = prepareServerFixture(directory);
    const defaultDatabase = path.join(directory, "custom-default.sqlite");
    createPreExistingDatabase(defaultDatabase);
    importLocalDatabase(modulePath, defaultDatabase, false);
    assert.deepEqual(datasetCounts(defaultDatabase), {
      valuationDashboard: 0,
      valuationTickers: 0,
      backtests: 0,
      backtestProxies: 0,
      dividends: 0,
      podcasts: 0,
      sentinel: "preserve-me"
    });

    const newDatabase = path.join(directory, "custom-new.sqlite");
    importLocalDatabase(modulePath, newDatabase, false);
    assert.deepEqual(datasetCounts(newDatabase), {
      valuationDashboard: 0,
      valuationTickers: 0,
      backtests: 0,
      backtestProxies: 0,
      dividends: 0,
      podcasts: 0,
      sentinel: null
    });

    const optedInDatabase = path.join(directory, "custom-opted-in.sqlite");
    createPreExistingDatabase(optedInDatabase);
    importLocalDatabase(modulePath, optedInDatabase, true);
    assert.deepEqual(datasetCounts(optedInDatabase), {
      valuationDashboard: 1,
      valuationTickers: 1,
      backtests: 1,
      backtestProxies: 1,
      dividends: 1,
      podcasts: 1,
      sentinel: "preserve-me"
    });
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

for (const strictDifference of [
  {
    label: "method",
    existing: { methodVersion: "manager13f-drifted-total-return-v6" }
  },
  {
    label: "security master",
    existing: { securityMasterVersion: "openfigi-sec-v2-old" }
  }
]) {
  test(`bundled sync replaces a same-date strict row when its ${strictDifference.label} changed`, () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "local-database-strict-compat-"));
    try {
      const bundledStrict = strictBacktestPayload({ marker: "bundled-strict" });
      const bundledProxy = proxyBacktestPayload({ marker: "bundled-proxy" });
      const modulePath = prepareServerFixture(directory, {
        strict: bundledStrict,
        proxy: bundledProxy
      });
      const databasePath = path.join(directory, "custom.sqlite");
      importLocalDatabase(modulePath, databasePath, false);
      seedExistingGuruCaches(databasePath, {
        strict: strictBacktestPayload({
          marker: "existing-strict",
          ...strictDifference.existing
        }),
        proxy: proxyBacktestPayload({ marker: "existing-proxy" })
      });

      importLocalDatabase(modulePath, databasePath, true);

      const payloads = readGuruCachePayloads(databasePath);
      assert.equal(payloads.strict.marker, "bundled-strict");
      assert.equal(payloads.strict.method.version, bundledStrict.method.version);
      assert.equal(
        payloads.strict.method.securityMasterVersion,
        bundledStrict.method.securityMasterVersion
      );
      assert.equal(payloads.proxy.marker, "existing-proxy");
    } finally {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });
}

test("bundled sync replaces a same-date proxy row when its security master changed", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "local-database-proxy-compat-"));
  try {
    const bundledStrict = strictBacktestPayload({ marker: "bundled-strict" });
    const bundledProxy = proxyBacktestPayload({ marker: "bundled-proxy" });
    const modulePath = prepareServerFixture(directory, {
      strict: bundledStrict,
      proxy: bundledProxy
    });
    const databasePath = path.join(directory, "custom.sqlite");
    importLocalDatabase(modulePath, databasePath, false);
    seedExistingGuruCaches(databasePath, {
      strict: strictBacktestPayload({ marker: "existing-strict" }),
      proxy: proxyBacktestPayload({
        marker: "existing-proxy",
        securityMasterVersion: "openfigi-sec-v2-old"
      })
    });

    importLocalDatabase(modulePath, databasePath, true);

    const payloads = readGuruCachePayloads(databasePath);
    assert.equal(payloads.strict.marker, "existing-strict");
    assert.equal(payloads.proxy.marker, "bundled-proxy");
    assert.equal(
      payloads.proxy.proxy.securityMasterVersion,
      bundledProxy.proxy.securityMasterVersion
    );
    assert.equal(
      payloads.proxy.method.securityMasterVersion,
      bundledProxy.method.securityMasterVersion
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
