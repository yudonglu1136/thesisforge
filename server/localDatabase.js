import fs from "node:fs";
import { readDatabaseTableSummariesFrom } from "./databaseTableSummaries.js";
import crypto from "node:crypto";
import path from "node:path";
import { auditPublicHoldingsProxyPayload } from "./backtestProxyAudit.js";
import { auditManager13fStrictReadyPayload } from "./backtestStrictAudit.js";
import { gurus } from "./gurus.js";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import {
  shouldInstallBundledValuationDashboard,
  shouldInstallBundledValuationTicker
} from "./bundledValuationSnapshotPolicy.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const bundledDataDir = path.join(__dirname, "data");
const bundledDbPath = path.join(bundledDataDir, "guru-analysis.sqlite");
const dbPath = process.env.SQLITE_DB_PATH || bundledDbPath;
const dataDir = path.dirname(dbPath);

fs.mkdirSync(dataDir, { recursive: true });

const db = new DatabaseSync(dbPath);
db.exec(`
  PRAGMA busy_timeout = 5000;
  -- Journal-mode negotiation also takes a lock; install the wait policy first.
  PRAGMA journal_mode = WAL;
  -- Reclaim an old large WAL allocation after a successful reset. This is not
  -- a cap on an active transaction or on frames pinned by a long reader.
  PRAGMA wal_autocheckpoint = 1000;
  PRAGMA journal_size_limit = 67108864;

  CREATE TABLE IF NOT EXISTS dashboard_snapshots (
    id TEXT PRIMARY KEY,
    generated_at TEXT NOT NULL,
    payload_json TEXT NOT NULL
  );

	  CREATE TABLE IF NOT EXISTS guru_snapshots (
	    guru_id TEXT PRIMARY KEY,
	    cik TEXT,
	    type TEXT,
	    generated_at TEXT NOT NULL,
	    payload_json TEXT NOT NULL
	  );

	  CREATE TABLE IF NOT EXISTS guru_exposure_snapshots (
	    guru_id TEXT PRIMARY KEY,
	    generated_at TEXT NOT NULL,
	    payload_json TEXT NOT NULL
	  );

	  CREATE TABLE IF NOT EXISTS guru_assets (
	    guru_id TEXT NOT NULL,
	    asset_type TEXT NOT NULL,
	    url TEXT NOT NULL,
	    local_path TEXT,
	    style TEXT,
	    prompt TEXT,
	    generated_at TEXT NOT NULL,
	    PRIMARY KEY (guru_id, asset_type)
	  );

  CREATE TABLE IF NOT EXISTS price_points (
    symbol TEXT NOT NULL,
    date TEXT NOT NULL,
    open REAL,
    high REAL,
    low REAL,
    close REAL NOT NULL,
    adjusted_close REAL,
    volume REAL,
    source TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (symbol, date)
  );

  CREATE TABLE IF NOT EXISTS price_repair_audits (
    audit_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    provider TEXT NOT NULL,
    reason TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    source_reference TEXT NOT NULL,
    operator TEXT NOT NULL,
    policy TEXT NOT NULL,
    affected_gurus_json TEXT NOT NULL,
    before_rows_json TEXT NOT NULL,
    rows_json TEXT NOT NULL,
    row_count INTEGER NOT NULL,
    symbols_json TEXT NOT NULL,
    dates_json TEXT NOT NULL,
    payload_sha256 TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS price_series_import_audits (
    audit_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    provider TEXT NOT NULL,
    reason TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    snapshot_state TEXT NOT NULL,
    source_reference TEXT NOT NULL,
    operator TEXT NOT NULL,
    policy TEXT NOT NULL,
    affected_gurus_json TEXT NOT NULL,
    symbol TEXT NOT NULL,
    interval_start TEXT NOT NULL,
    interval_end TEXT NOT NULL,
    before_rows_json TEXT NOT NULL,
    rows_json TEXT NOT NULL,
    row_count INTEGER NOT NULL,
    payload_sha256 TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS price_series_import_batch_audits (
    batch_audit_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    records_sha256 TEXT NOT NULL UNIQUE,
    release_id TEXT NOT NULL,
    source_volume_id TEXT NOT NULL,
    source_snapshot_id TEXT NOT NULL,
    encrypted_snapshot_id TEXT NOT NULL,
    operator TEXT NOT NULL,
    child_audit_ids_json TEXT NOT NULL,
    series_manifest_json TEXT NOT NULL,
    refresh_targets_json TEXT NOT NULL,
    expectations_json TEXT NOT NULL,
    group_count INTEGER NOT NULL,
    row_count INTEGER NOT NULL,
    imported_row_count INTEGER NOT NULL
  );

  -- The PRIMARY KEY already creates sqlite_autoindex_price_points_1 on
  -- (symbol, date). A second identical index wastes about 50 MB.

  CREATE TABLE IF NOT EXISTS guru_backtests (
    guru_id TEXT NOT NULL,
    years INTEGER NOT NULL,
    generated_at TEXT NOT NULL,
    start_date TEXT,
    end_date TEXT,
    payload_json TEXT NOT NULL,
    PRIMARY KEY (guru_id, years)
  );

  CREATE TABLE IF NOT EXISTS guru_backtest_proxies (
    guru_id TEXT NOT NULL,
    years INTEGER NOT NULL,
    generated_at TEXT NOT NULL,
    start_date TEXT,
    end_date TEXT,
    method_version TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    PRIMARY KEY (guru_id, years)
  );

  CREATE TABLE IF NOT EXISTS valuation_snapshots (
    id TEXT PRIMARY KEY,
    generated_at TEXT NOT NULL,
    payload_json TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS valuation_ticker_snapshots (
    ticker TEXT PRIMARY KEY,
    generated_at TEXT NOT NULL,
    payload_json TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS valuation_podcast_insights (
    id TEXT PRIMARY KEY,
    ticker TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    observed_at TEXT,
    channel TEXT,
    video_id TEXT,
    video_title TEXT,
    video_url TEXT,
    speaker TEXT,
    theme TEXT,
    stance TEXT,
    horizon TEXT,
    confidence REAL,
    relevance_score REAL,
    summary TEXT,
    summary_zh TEXT,
    evidence_excerpt TEXT,
    evidence_excerpt_zh TEXT,
    payload_json TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_valuation_podcast_insights_ticker_observed_at
    ON valuation_podcast_insights (ticker, observed_at DESC);

  CREATE TABLE IF NOT EXISTS portfolio_nav_points (
    account_id TEXT NOT NULL,
    date TEXT NOT NULL,
    nav REAL NOT NULL,
    cash REAL,
    source TEXT,
    source_date TEXT,
    payload_json TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (account_id, date)
  );

  CREATE INDEX IF NOT EXISTS idx_portfolio_nav_points_account_date
    ON portfolio_nav_points (account_id, date);

  CREATE TABLE IF NOT EXISTS ticker_assets (
    ticker TEXT PRIMARY KEY,
    company_name TEXT,
    logo_url TEXT,
    logo_domain TEXT,
    logo_source TEXT,
    payload_json TEXT,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS dividend_events (
    ticker TEXT NOT NULL,
    company_name TEXT,
    ex_date TEXT NOT NULL,
    pay_date TEXT,
    record_date TEXT,
    declaration_date TEXT,
    amount REAL,
    currency TEXT,
    status TEXT,
    source TEXT NOT NULL,
    source_label TEXT,
    logo_url TEXT,
    payload_json TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (ticker, ex_date, source)
  );

  CREATE INDEX IF NOT EXISTS idx_dividend_events_ticker_ex_date
    ON dividend_events (ticker, ex_date);

  CREATE TABLE IF NOT EXISTS background_job_runs (
    job_id TEXT PRIMARY KEY,
    started_at TEXT,
    finished_at TEXT,
    status TEXT,
    payload_json TEXT
  );

  CREATE TABLE IF NOT EXISTS cache_revisions (
    scope TEXT PRIMARY KEY,
    revision INTEGER NOT NULL DEFAULT 0
  );

  INSERT OR IGNORE INTO cache_revisions (scope, revision) VALUES
    ('dashboard_snapshots', 0),
    ('guru_snapshots', 0),
    ('guru_exposure_snapshots', 0),
    ('guru_assets', 0),
    ('guru_backtests', 0),
    ('guru_backtest_proxies', 0),
    ('valuation_snapshots', 0),
    ('valuation_ticker_snapshots', 0),
    ('valuation_podcast_insights', 0);

  CREATE TRIGGER IF NOT EXISTS dashboard_snapshots_revision_insert
  AFTER INSERT ON dashboard_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'dashboard_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS dashboard_snapshots_revision_update
  AFTER UPDATE ON dashboard_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'dashboard_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS dashboard_snapshots_revision_delete
  AFTER DELETE ON dashboard_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'dashboard_snapshots';
  END;

  CREATE TRIGGER IF NOT EXISTS guru_snapshots_revision_insert
  AFTER INSERT ON guru_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_snapshots_revision_update
  AFTER UPDATE ON guru_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_snapshots_revision_delete
  AFTER DELETE ON guru_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_snapshots';
  END;

  CREATE TRIGGER IF NOT EXISTS guru_exposure_snapshots_revision_insert
  AFTER INSERT ON guru_exposure_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_exposure_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_exposure_snapshots_revision_update
  AFTER UPDATE ON guru_exposure_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_exposure_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_exposure_snapshots_revision_delete
  AFTER DELETE ON guru_exposure_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_exposure_snapshots';
  END;

  CREATE TRIGGER IF NOT EXISTS guru_assets_revision_insert
  AFTER INSERT ON guru_assets BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_assets';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_assets_revision_update
  AFTER UPDATE ON guru_assets BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_assets';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_assets_revision_delete
  AFTER DELETE ON guru_assets BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_assets';
  END;

  CREATE TRIGGER IF NOT EXISTS guru_backtests_revision_insert
  AFTER INSERT ON guru_backtests BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_backtests';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_backtests_revision_update
  AFTER UPDATE ON guru_backtests BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_backtests';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_backtests_revision_delete
  AFTER DELETE ON guru_backtests BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_backtests';
  END;

  CREATE TRIGGER IF NOT EXISTS guru_backtest_proxies_revision_insert
  AFTER INSERT ON guru_backtest_proxies BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_backtest_proxies';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_backtest_proxies_revision_update
  AFTER UPDATE ON guru_backtest_proxies BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_backtest_proxies';
  END;
  CREATE TRIGGER IF NOT EXISTS guru_backtest_proxies_revision_delete
  AFTER DELETE ON guru_backtest_proxies BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'guru_backtest_proxies';
  END;

  CREATE TRIGGER IF NOT EXISTS valuation_snapshots_revision_insert
  AFTER INSERT ON valuation_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS valuation_snapshots_revision_update
  AFTER UPDATE ON valuation_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS valuation_snapshots_revision_delete
  AFTER DELETE ON valuation_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_snapshots';
  END;

  CREATE TRIGGER IF NOT EXISTS valuation_ticker_snapshots_revision_insert
  AFTER INSERT ON valuation_ticker_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_ticker_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS valuation_ticker_snapshots_revision_update
  AFTER UPDATE ON valuation_ticker_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_ticker_snapshots';
  END;
  CREATE TRIGGER IF NOT EXISTS valuation_ticker_snapshots_revision_delete
  AFTER DELETE ON valuation_ticker_snapshots BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_ticker_snapshots';
  END;

  CREATE TRIGGER IF NOT EXISTS valuation_podcast_insights_revision_insert
  AFTER INSERT ON valuation_podcast_insights BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_podcast_insights';
  END;
  CREATE TRIGGER IF NOT EXISTS valuation_podcast_insights_revision_update
  AFTER UPDATE ON valuation_podcast_insights BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_podcast_insights';
  END;
  CREATE TRIGGER IF NOT EXISTS valuation_podcast_insights_revision_delete
  AFTER DELETE ON valuation_podcast_insights BEGIN
    UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_podcast_insights';
  END;
`);

const pricePointColumns = new Set(
  db.prepare("PRAGMA table_info(price_points)").all().map((column) => column.name)
);
if (!pricePointColumns.has("adjusted_close")) {
  db.exec("ALTER TABLE price_points ADD COLUMN adjusted_close REAL");
}

const priceRepairAuditColumns = new Set(
  db.prepare("PRAGMA table_info(price_repair_audits)").all().map((column) => column.name)
);
const priceRepairAuditMigrations = [
  ["snapshot_id", "TEXT NOT NULL DEFAULT ''"],
  ["source_reference", "TEXT NOT NULL DEFAULT ''"],
  ["operator", "TEXT NOT NULL DEFAULT ''"],
  ["policy", "TEXT NOT NULL DEFAULT 'legacy_unspecified'"],
  ["affected_gurus_json", "TEXT NOT NULL DEFAULT '[]'"],
  ["before_rows_json", "TEXT NOT NULL DEFAULT '[]'"],
  ["rows_json", "TEXT NOT NULL DEFAULT '[]'"]
];
for (const [column, definition] of priceRepairAuditMigrations) {
  if (!priceRepairAuditColumns.has(column)) {
    db.exec(`ALTER TABLE price_repair_audits ADD COLUMN ${column} ${definition}`);
  }
}

const priceSeriesBatchAuditColumns = new Set(
  db.prepare("PRAGMA table_info(price_series_import_batch_audits)").all()
    .map((column) => column.name)
);
if (!priceSeriesBatchAuditColumns.has("imported_row_count")) {
  db.exec(`
    ALTER TABLE price_series_import_batch_audits
    ADD COLUMN imported_row_count INTEGER NOT NULL DEFAULT 0
  `);
}

const readCacheRevisionStatement = db.prepare(`
  SELECT revision
  FROM cache_revisions
  WHERE scope = ?
`);

function readCacheRevision(scope) {
  return Number(readCacheRevisionStatement.get(scope)?.revision) || 0;
}

const readGuruDashboardIdentityStatement = db.prepare(`
  SELECT generated_at
  FROM dashboard_snapshots
  WHERE id = 'latest'
`);

export function readGuruDashboardVersion() {
  const dashboard = readGuruDashboardIdentityStatement.get();
  return [
    readCacheRevision("dashboard_snapshots"),
    dashboard?.generated_at || "missing",
    readCacheRevision("guru_snapshots"),
    readCacheRevision("guru_assets")
  ].join(":");
}

export function readGuruExposureVersion() {
  return String(readCacheRevision("guru_exposure_snapshots"));
}

function syncBundledValuationSnapshots() {
  if (process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS !== "true") return;
  if (dbPath === bundledDbPath || !fs.existsSync(bundledDbPath)) return;

  let bundledDb;
  try {
    bundledDb = new DatabaseSync(bundledDbPath, { readOnly: true });
    const dashboardRows = bundledDb.prepare(`
      SELECT id, generated_at, payload_json
      FROM valuation_snapshots
    `).all();
    const tickerRows = bundledDb.prepare(`
      SELECT ticker, generated_at, payload_json
      FROM valuation_ticker_snapshots
    `).all();
    if (!dashboardRows.length && !tickerRows.length) return;

    const writeDashboard = db.prepare(`
      INSERT INTO valuation_snapshots (id, generated_at, payload_json)
      VALUES (?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        generated_at = excluded.generated_at,
        payload_json = excluded.payload_json
      WHERE excluded.generated_at > valuation_snapshots.generated_at
    `);
    const writeTicker = db.prepare(`
      INSERT INTO valuation_ticker_snapshots (ticker, generated_at, payload_json)
      VALUES (?, ?, ?)
      ON CONFLICT(ticker) DO UPDATE SET
        generated_at = excluded.generated_at,
        payload_json = excluded.payload_json
      WHERE excluded.generated_at > valuation_ticker_snapshots.generated_at
    `);
    const currentDashboard = db.prepare(`
      SELECT generated_at, payload_json
      FROM valuation_snapshots
      WHERE id = ?
    `);
    const currentTicker = db.prepare(`
      SELECT generated_at
      FROM valuation_ticker_snapshots
      WHERE ticker = ?
    `);

    db.exec("BEGIN");
    try {
      let installedDashboardRows = 0;
      let installedTickerRows = 0;
      for (const row of dashboardRows) {
        if (!shouldInstallBundledValuationDashboard(row, currentDashboard.get(row.id))) continue;
        writeDashboard.run(row.id, row.generated_at, row.payload_json);
        installedDashboardRows += 1;
      }
      for (const row of tickerRows) {
        if (!shouldInstallBundledValuationTicker(row, currentTicker.get(row.ticker))) continue;
        writeTicker.run(row.ticker, row.generated_at, row.payload_json);
        installedTickerRows += 1;
      }
      db.exec("COMMIT");
      console.info(
        `[database] synced bundled valuation snapshots into ${dbPath}: ` +
        `${installedDashboardRows}/${dashboardRows.length} dashboard rows, ` +
        `${installedTickerRows}/${tickerRows.length} ticker rows installed`
      );
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  } catch (error) {
    console.warn(`[database] bundled valuation snapshot sync skipped: ${error.message}`);
  } finally {
    bundledDb?.close();
  }
}

function syncBundledGuruBacktests() {
  if (process.env.SYNC_BUNDLED_GURU_BACKTESTS !== "true") return;
  if (dbPath === bundledDbPath || !fs.existsSync(bundledDbPath)) return;

  let bundledDb;
  try {
    bundledDb = new DatabaseSync(bundledDbPath, { readOnly: true });
    const bundledSummary = bundledDb.prepare(`
      SELECT
        COUNT(*) AS count,
        MAX(generated_at) AS generated_at,
        MAX(end_date) AS end_date
      FROM guru_backtests
    `).get();
    if (!bundledSummary?.count) return;
    const bundledHasProxyTable = Boolean(bundledDb.prepare(`
      SELECT 1
      FROM sqlite_master
      WHERE type = 'table' AND name = 'guru_backtest_proxies'
    `).get());
    const bundledProxySummary = bundledHasProxyTable
      ? bundledDb.prepare(`
          SELECT
            COUNT(*) AS count,
            MAX(generated_at) AS generated_at,
            MAX(end_date) AS end_date,
            MIN(method_version) AS min_method_version,
            MAX(method_version) AS max_method_version
          FROM guru_backtest_proxies
        `).get()
      : {
          count: 0,
          generated_at: null,
          end_date: null,
          min_method_version: null,
          max_method_version: null
        };

    const currentSummary = db.prepare(`
      SELECT
        COUNT(*) AS count,
        MAX(generated_at) AS generated_at,
        MAX(end_date) AS end_date
      FROM guru_backtests
    `).get();
    const currentProxySummary = db.prepare(`
      SELECT
        COUNT(*) AS count,
        MAX(generated_at) AS generated_at,
        MAX(end_date) AS end_date,
        MIN(method_version) AS min_method_version,
        MAX(method_version) AS max_method_version
      FROM guru_backtest_proxies
    `).get();
    const rows = bundledDb.prepare(`
      SELECT guru_id, years, generated_at, start_date, end_date, payload_json
      FROM guru_backtests
    `).all();
    if (!rows.length) return;
    const proxyRows = bundledHasProxyTable
      ? bundledDb.prepare(`
          SELECT guru_id, years, generated_at, start_date, end_date, method_version, payload_json
          FROM guru_backtest_proxies
        `).all()
      : [];
    const currentRowsByKey = new Map(db.prepare(`
      SELECT guru_id, years, payload_json
      FROM guru_backtests
    `).all().map((row) => [`${row.guru_id}:${row.years}`, row]));
    const currentProxyRowsByKey = new Map(db.prepare(`
      SELECT guru_id, years, method_version, payload_json
      FROM guru_backtest_proxies
    `).all().map((row) => [`${row.guru_id}:${row.years}`, row]));
    const strictCompatibilityChanged = rows.some((row) =>
      guruBacktestCompatibilityIdentity(row) !== guruBacktestCompatibilityIdentity(
        currentRowsByKey.get(`${row.guru_id}:${row.years}`)
      )
    );
    const proxyCompatibilityChanged = proxyRows.some((row) =>
      guruBacktestProxyCompatibilityIdentity(row) !== guruBacktestProxyCompatibilityIdentity(
        currentProxyRowsByKey.get(`${row.guru_id}:${row.years}`)
      )
    );
    const shouldSync =
      Number(bundledSummary.count || 0) > Number(currentSummary?.count || 0) ||
      (bundledSummary.generated_at &&
        (!currentSummary?.generated_at || bundledSummary.generated_at > currentSummary.generated_at)) ||
      (bundledSummary.end_date &&
        (!currentSummary?.end_date || bundledSummary.end_date > currentSummary.end_date)) ||
      Number(bundledProxySummary.count || 0) > Number(currentProxySummary?.count || 0) ||
      (bundledProxySummary.generated_at &&
        (!currentProxySummary?.generated_at ||
          bundledProxySummary.generated_at > currentProxySummary.generated_at)) ||
      (bundledProxySummary.end_date &&
        (!currentProxySummary?.end_date || bundledProxySummary.end_date > currentProxySummary.end_date)) ||
      bundledProxySummary.min_method_version !== currentProxySummary?.min_method_version ||
      bundledProxySummary.max_method_version !== currentProxySummary?.max_method_version ||
      strictCompatibilityChanged ||
      proxyCompatibilityChanged;
    if (!shouldSync) return;

    const writeBacktest = db.prepare(`
      INSERT INTO guru_backtests (guru_id, years, generated_at, start_date, end_date, payload_json)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(guru_id, years) DO UPDATE SET
        generated_at = excluded.generated_at,
        start_date = excluded.start_date,
        end_date = excluded.end_date,
        payload_json = excluded.payload_json
      WHERE
        guru_backtests.generated_at IS NULL OR
        excluded.generated_at > guru_backtests.generated_at OR
        excluded.end_date > guru_backtests.end_date OR
        ? = 1
    `);
    const writeProxy = db.prepare(`
      INSERT INTO guru_backtest_proxies (
        guru_id, years, generated_at, start_date, end_date, method_version, payload_json
      )
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(guru_id, years) DO UPDATE SET
        generated_at = excluded.generated_at,
        start_date = excluded.start_date,
        end_date = excluded.end_date,
        method_version = excluded.method_version,
        payload_json = excluded.payload_json
      WHERE
        guru_backtest_proxies.generated_at IS NULL OR
        excluded.generated_at > guru_backtest_proxies.generated_at OR
        excluded.end_date > guru_backtest_proxies.end_date OR
        excluded.method_version != guru_backtest_proxies.method_version OR
        ? = 1
    `);

    db.exec("BEGIN");
    try {
      for (const row of rows) {
        writeBacktest.run(
          row.guru_id,
          row.years,
          row.generated_at,
          row.start_date,
          row.end_date,
          row.payload_json,
          Number(
            guruBacktestCompatibilityIdentity(row) !== guruBacktestCompatibilityIdentity(
              currentRowsByKey.get(`${row.guru_id}:${row.years}`)
            )
          )
        );
      }
      for (const row of proxyRows) {
        writeProxy.run(
          row.guru_id,
          row.years,
          row.generated_at,
          row.start_date,
          row.end_date,
          row.method_version,
          row.payload_json,
          Number(
            guruBacktestProxyCompatibilityIdentity(row) !==
              guruBacktestProxyCompatibilityIdentity(
                currentProxyRowsByKey.get(`${row.guru_id}:${row.years}`)
              )
          )
        );
      }
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
    console.info(
      `[database] synced bundled guru backtests into ${dbPath}: ` +
      `${rows.length} strict rows, ${proxyRows.length} proxy rows`
    );
  } catch (error) {
    console.warn(`[database] bundled guru backtest sync skipped: ${error.message}`);
  } finally {
    bundledDb?.close();
  }
}

function syncBundledDividendCalendar() {
  if (process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR !== "true") return;
  if (dbPath === bundledDbPath || !fs.existsSync(bundledDbPath)) return;

  let bundledDb;
  try {
    bundledDb = new DatabaseSync(bundledDbPath, { readOnly: true });
    const bundledSummary = bundledDb.prepare(`
      SELECT
        COUNT(*) AS count,
        MIN(ex_date) AS min_date,
        MAX(ex_date) AS max_date,
        MAX(updated_at) AS updated_at
      FROM dividend_events
    `).get();
    if (!bundledSummary?.count) return;

    const currentSummary = db.prepare(`
      SELECT
        COUNT(*) AS count,
        MIN(ex_date) AS min_date,
        MAX(ex_date) AS max_date,
        MAX(updated_at) AS updated_at
      FROM dividend_events
    `).get();
    const bundledCount = Number(bundledSummary.count) || 0;
    const currentCount = Number(currentSummary?.count) || 0;
    const shouldSync =
      bundledCount > currentCount ||
      (bundledSummary.min_date && (!currentSummary?.min_date || bundledSummary.min_date < currentSummary.min_date)) ||
      (bundledSummary.updated_at && (!currentSummary?.updated_at || bundledSummary.updated_at > currentSummary.updated_at));
    if (!shouldSync) return;

    const eventRows = bundledDb.prepare(`
      SELECT
        ticker,
        company_name,
        ex_date,
        pay_date,
        record_date,
        declaration_date,
        amount,
        currency,
        status,
        source,
        source_label,
        logo_url,
        payload_json,
        updated_at
      FROM dividend_events
    `).all();
    const assetRows = bundledDb.prepare(`
      SELECT ticker, company_name, logo_url, logo_domain, logo_source, payload_json, updated_at
      FROM ticker_assets
      WHERE ticker IN (SELECT DISTINCT ticker FROM dividend_events)
    `).all();
    const jobRows = bundledDb.prepare(`
      SELECT job_id, started_at, finished_at, status, payload_json
      FROM background_job_runs
      WHERE job_id = 'portfolio_dividend_calendar'
    `).all();
    if (!eventRows.length) return;

    const tickers = [...new Set(eventRows.map((row) => row.ticker).filter(Boolean))];
    const placeholders = tickers.map(() => "?").join(", ");
    const writeEvent = db.prepare(`
      INSERT INTO dividend_events (
        ticker,
        company_name,
        ex_date,
        pay_date,
        record_date,
        declaration_date,
        amount,
        currency,
        status,
        source,
        source_label,
        logo_url,
        payload_json,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(ticker, ex_date, source) DO UPDATE SET
        company_name = excluded.company_name,
        pay_date = excluded.pay_date,
        record_date = excluded.record_date,
        declaration_date = excluded.declaration_date,
        amount = excluded.amount,
        currency = excluded.currency,
        status = excluded.status,
        source_label = excluded.source_label,
        logo_url = excluded.logo_url,
        payload_json = excluded.payload_json,
        updated_at = excluded.updated_at
    `);
    const writeAsset = db.prepare(`
      INSERT INTO ticker_assets (
        ticker,
        company_name,
        logo_url,
        logo_domain,
        logo_source,
        payload_json,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(ticker) DO UPDATE SET
        company_name = excluded.company_name,
        logo_url = excluded.logo_url,
        logo_domain = excluded.logo_domain,
        logo_source = excluded.logo_source,
        payload_json = excluded.payload_json,
        updated_at = excluded.updated_at
    `);
    const writeJob = db.prepare(`
      INSERT INTO background_job_runs (job_id, started_at, finished_at, status, payload_json)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(job_id) DO UPDATE SET
        started_at = excluded.started_at,
        finished_at = excluded.finished_at,
        status = excluded.status,
        payload_json = excluded.payload_json
    `);

    db.exec("BEGIN");
    try {
      if (tickers.length && bundledSummary.min_date && bundledSummary.max_date) {
        db.prepare(`
          DELETE FROM dividend_events
          WHERE ticker IN (${placeholders})
            AND ex_date >= ?
            AND ex_date <= ?
        `).run(...tickers, bundledSummary.min_date, bundledSummary.max_date);
      }
      for (const row of assetRows) {
        writeAsset.run(
          row.ticker,
          row.company_name,
          row.logo_url,
          row.logo_domain,
          row.logo_source,
          row.payload_json,
          row.updated_at
        );
      }
      for (const row of eventRows) {
        writeEvent.run(
          row.ticker,
          row.company_name,
          row.ex_date,
          row.pay_date,
          row.record_date,
          row.declaration_date,
          row.amount,
          row.currency,
          row.status,
          row.source,
          row.source_label,
          row.logo_url,
          row.payload_json,
          row.updated_at
        );
      }
      for (const row of jobRows) {
        writeJob.run(row.job_id, row.started_at, row.finished_at, row.status, row.payload_json);
      }
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
    console.info(
      `[database] synced bundled dividend calendar into ${dbPath}: ` +
      `${eventRows.length} events, ${assetRows.length} assets`
    );
  } catch (error) {
    console.warn(`[database] bundled dividend calendar sync skipped: ${error.message}`);
  } finally {
    bundledDb?.close();
  }
}

function syncBundledPodcastInsights() {
  if (process.env.SYNC_BUNDLED_PODCAST_INSIGHTS !== "true") return;
  if (dbPath === bundledDbPath || !fs.existsSync(bundledDbPath)) return;

  let bundledDb;
  try {
    bundledDb = new DatabaseSync(bundledDbPath, { readOnly: true });
    const rows = bundledDb.prepare(`
      SELECT
        id,
        ticker,
        generated_at,
        observed_at,
        channel,
        video_id,
        video_title,
        video_url,
        speaker,
        theme,
        stance,
        horizon,
        confidence,
        relevance_score,
        summary,
        summary_zh,
        evidence_excerpt,
        evidence_excerpt_zh,
        payload_json
      FROM valuation_podcast_insights
    `).all();
    if (!rows.length) return;

    const jobRows = bundledDb.prepare(`
      SELECT job_id, started_at, finished_at, status, payload_json
      FROM background_job_runs
      WHERE job_id = 'valuation_podcast_insights'
    `).all();
    const writeInsight = db.prepare(`
      INSERT INTO valuation_podcast_insights (
        id,
        ticker,
        generated_at,
        observed_at,
        channel,
        video_id,
        video_title,
        video_url,
        speaker,
        theme,
        stance,
        horizon,
        confidence,
        relevance_score,
        summary,
        summary_zh,
        evidence_excerpt,
        evidence_excerpt_zh,
        payload_json
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        ticker = excluded.ticker,
        generated_at = excluded.generated_at,
        observed_at = excluded.observed_at,
        channel = excluded.channel,
        video_id = excluded.video_id,
        video_title = excluded.video_title,
        video_url = excluded.video_url,
        speaker = excluded.speaker,
        theme = excluded.theme,
        stance = excluded.stance,
        horizon = excluded.horizon,
        confidence = excluded.confidence,
        relevance_score = excluded.relevance_score,
        summary = excluded.summary,
        summary_zh = excluded.summary_zh,
        evidence_excerpt = excluded.evidence_excerpt,
        evidence_excerpt_zh = excluded.evidence_excerpt_zh,
        payload_json = excluded.payload_json
    `);
    const writeJob = db.prepare(`
      INSERT INTO background_job_runs (job_id, started_at, finished_at, status, payload_json)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(job_id) DO UPDATE SET
        started_at = excluded.started_at,
        finished_at = excluded.finished_at,
        status = excluded.status,
        payload_json = excluded.payload_json
    `);

    db.exec("BEGIN");
    try {
      db.prepare("DELETE FROM valuation_podcast_insights").run();
      for (const row of rows) {
        writeInsight.run(
          row.id,
          row.ticker,
          row.generated_at,
          row.observed_at,
          row.channel,
          row.video_id,
          row.video_title,
          row.video_url,
          row.speaker,
          row.theme,
          row.stance,
          row.horizon,
          row.confidence,
          row.relevance_score,
          row.summary,
          row.summary_zh,
          row.evidence_excerpt,
          row.evidence_excerpt_zh,
          row.payload_json
        );
      }
      for (const row of jobRows) {
        writeJob.run(row.job_id, row.started_at, row.finished_at, row.status, row.payload_json);
      }
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
    console.info(`[database] synced bundled podcast insights into ${dbPath}: ${rows.length} rows`);
  } catch (error) {
    console.warn(`[database] bundled podcast insight sync skipped: ${error.message}`);
  } finally {
    bundledDb?.close();
  }
}

syncBundledValuationSnapshots();
syncBundledGuruBacktests();
syncBundledDividendCalendar();
syncBundledPodcastInsights();

function parsePayload(value) {
  try {
    return value ? JSON.parse(value) : null;
  } catch {
    return null;
  }
}

function normalizedCacheIdentityPart(value) {
  return String(value || "").trim();
}

function guruBacktestCompatibilityIdentity(row) {
  if (!row) return "missing";
  const payload = parsePayload(row.payload_json);
  return JSON.stringify([
    normalizedCacheIdentityPart(payload?.method?.version),
    normalizedCacheIdentityPart(payload?.method?.securityMasterVersion)
  ]);
}

function guruBacktestProxyCompatibilityIdentity(row) {
  if (!row) return "missing";
  const payload = parsePayload(row.payload_json);
  return JSON.stringify([
    normalizedCacheIdentityPart(row.method_version),
    normalizedCacheIdentityPart(payload?.method?.version),
    normalizedCacheIdentityPart(payload?.method?.variant),
    normalizedCacheIdentityPart(payload?.method?.securityMasterVersion),
    normalizedCacheIdentityPart(payload?.proxy?.methodVersion),
    normalizedCacheIdentityPart(payload?.proxy?.securityMasterVersion)
  ]);
}

function normalizeTickerKey(value) {
  return String(value || "").trim().toUpperCase().replace(/[^A-Z0-9.-]/g, "");
}

export function databaseInfo() {
  return { path: dbPath };
}

export function readDashboardSnapshot() {
  const row = db.prepare("SELECT payload_json FROM dashboard_snapshots WHERE id = ?").get("latest");
  return parsePayload(row?.payload_json);
}

export function writeDashboardSnapshot(payload) {
  db.prepare(`
    INSERT INTO dashboard_snapshots (id, generated_at, payload_json)
    VALUES (?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      generated_at = excluded.generated_at,
      payload_json = excluded.payload_json
  `).run("latest", payload.generatedAt || new Date().toISOString(), JSON.stringify(payload));
}

export function readGuruSnapshot(guruId) {
  const row = db.prepare("SELECT payload_json FROM guru_snapshots WHERE guru_id = ?").get(guruId);
  return parsePayload(row?.payload_json);
}

export function writeGuruSnapshot(guruId, payload) {
  db.prepare(`
    INSERT INTO guru_snapshots (guru_id, cik, type, generated_at, payload_json)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(guru_id) DO UPDATE SET
      cik = excluded.cik,
      type = excluded.type,
      generated_at = excluded.generated_at,
      payload_json = excluded.payload_json
  `).run(
    guruId,
    payload.cik || "",
    payload.type || "",
    payload.generatedAt || new Date().toISOString(),
    JSON.stringify(payload)
  );
}

export function readGuruExposureSnapshot(guruId) {
  const row = db.prepare("SELECT payload_json FROM guru_exposure_snapshots WHERE guru_id = ?").get(guruId);
  return parsePayload(row?.payload_json);
}

export function writeGuruExposureSnapshot(guruId, payload) {
  db.prepare(`
    INSERT INTO guru_exposure_snapshots (guru_id, generated_at, payload_json)
    VALUES (?, ?, ?)
    ON CONFLICT(guru_id) DO UPDATE SET
      generated_at = excluded.generated_at,
      payload_json = excluded.payload_json
  `).run(guruId, payload.generatedAt || new Date().toISOString(), JSON.stringify(payload));
}

export function readGuruAssets() {
  return db.prepare(`
    SELECT guru_id, asset_type, url, local_path, style, prompt, generated_at
    FROM guru_assets
  `).all().map((row) => ({
    guruId: row.guru_id,
    assetType: row.asset_type,
    url: row.url,
    localPath: row.local_path || "",
    style: row.style || "",
    prompt: row.prompt || "",
    generatedAt: row.generated_at
  }));
}

export function readGuruAsset(guruId, assetType = "avatar") {
  const row = db.prepare(`
    SELECT guru_id, asset_type, url, local_path, style, prompt, generated_at
    FROM guru_assets
    WHERE guru_id = ? AND asset_type = ?
  `).get(guruId, assetType);
  if (!row) return null;
  return {
    guruId: row.guru_id,
    assetType: row.asset_type,
    url: row.url,
    localPath: row.local_path || "",
    style: row.style || "",
    prompt: row.prompt || "",
    generatedAt: row.generated_at
  };
}

export function writeGuruAsset(guruId, asset) {
  const normalizedGuruId = String(guruId || asset?.guruId || "").trim();
  const assetType = String(asset?.assetType || "avatar").trim() || "avatar";
  const url = String(asset?.url || "").trim();
  if (!normalizedGuruId || !url) return;
  db.prepare(`
    INSERT INTO guru_assets (
      guru_id,
      asset_type,
      url,
      local_path,
      style,
      prompt,
      generated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(guru_id, asset_type) DO UPDATE SET
      url = excluded.url,
      local_path = excluded.local_path,
      style = excluded.style,
      prompt = excluded.prompt,
      generated_at = excluded.generated_at
  `).run(
    normalizedGuruId,
    assetType,
    url,
    asset.localPath || "",
    asset.style || "",
    asset.prompt || "",
    asset.generatedAt || new Date().toISOString()
  );
}

export function readGuruBacktest(guruId, years = 5) {
  const row = db.prepare(`
    SELECT payload_json
    FROM guru_backtests
    WHERE guru_id = ? AND years = ?
  `).get(guruId, years);
  return parsePayload(row?.payload_json);
}

export function readGuruBacktestProxy(guruId, years = 5) {
  const row = db.prepare(`
    SELECT payload_json
    FROM guru_backtest_proxies
    WHERE guru_id = ? AND years = ?
  `).get(guruId, years);
  return parsePayload(row?.payload_json);
}

export function readGuruBacktestVersion(years = 5) {
  const revision = [
    readCacheRevision("guru_backtests"),
    readCacheRevision("guru_backtest_proxies")
  ].join(":");
  const strictRows = db.prepare(`
    SELECT
      guru_id,
      generated_at,
      start_date,
      end_date
    FROM guru_backtests
    WHERE years = ?
    ORDER BY guru_id ASC
  `).all(years);
  const proxyRows = db.prepare(`
    SELECT
      guru_id,
      generated_at,
      start_date,
      end_date,
      method_version
    FROM guru_backtest_proxies
    WHERE years = ?
    ORDER BY guru_id ASC
  `).all(years);
  if (!strictRows.length && !proxyRows.length) return `${revision}:empty`;
  return `${revision}:` + [
    ...strictRows.map((row) => ["strict", row.guru_id, row.generated_at, row.start_date || "", row.end_date || ""]),
    ...proxyRows.map((row) => ["proxy", row.guru_id, row.method_version, row.generated_at, row.start_date || "", row.end_date || ""])
  ].map((row) => row.join(":"))
    .join("|");
}

export function readValuationSnapshot() {
  const row = db.prepare("SELECT payload_json FROM valuation_snapshots WHERE id = ?").get("latest");
  return parsePayload(row?.payload_json);
}

export function readValuationSnapshotVersion() {
  const row = db.prepare(`
    SELECT generated_at
    FROM valuation_snapshots
    WHERE id = ?
  `).get("latest");
  if (!row) return null;
  return `${row.generated_at}:${readCacheRevision("valuation_snapshots")}`;
}

const readValuationDashboardVersionStatement = db.prepare(`
  SELECT
    (SELECT generated_at FROM valuation_snapshots WHERE id = 'latest') AS generated_at,
    (SELECT revision FROM cache_revisions WHERE scope = 'valuation_snapshots') AS snapshot_revision,
    (SELECT revision FROM cache_revisions WHERE scope = 'valuation_podcast_insights') AS podcast_revision
`);

export function readValuationDashboardVersion() {
  const row = readValuationDashboardVersionStatement.get();
  return [
    row?.generated_at || "missing",
    Number(row?.snapshot_revision) || 0,
    Number(row?.podcast_revision) || 0
  ].join(":");
}

export function writeValuationSnapshot(payload) {
  db.prepare(`
    INSERT INTO valuation_snapshots (id, generated_at, payload_json)
    VALUES (?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      generated_at = excluded.generated_at,
      payload_json = excluded.payload_json
  `).run("latest", payload.generatedAt || new Date().toISOString(), JSON.stringify(payload));
}

export function readValuationTickerSnapshot(ticker) {
  const normalized = String(ticker || "").trim().toUpperCase();
  if (!normalized) return null;
  const row = db.prepare("SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker = ?").get(normalized);
  return parsePayload(row?.payload_json);
}

export function readValuationTickerSnapshotVersion(ticker) {
  const normalized = String(ticker || "").trim().toUpperCase();
  if (!normalized) return null;
  const row = db.prepare(`
    SELECT generated_at
    FROM valuation_ticker_snapshots
    WHERE ticker = ?
  `).get(normalized);
  if (!row) return null;
  return `${row.generated_at}:${readCacheRevision("valuation_ticker_snapshots")}`;
}

export function readValuationPodcastInsightsVersion(tickers = []) {
  const normalizedTickers = [...new Set((tickers || [])
    .map((ticker) => String(ticker || "").trim().toUpperCase())
    .filter(Boolean))];
  const where = normalizedTickers.length
    ? `WHERE ticker IN (${normalizedTickers.map(() => "?").join(", ")})`
    : "";
  const row = db.prepare(`
    SELECT
      COUNT(*) AS row_count,
      MAX(generated_at) AS generated_at,
      MAX(observed_at) AS observed_at
    FROM valuation_podcast_insights
    ${where}
  `).get(...normalizedTickers);
  return [
    readCacheRevision("valuation_podcast_insights"),
    Number(row?.row_count) || 0,
    row?.generated_at || "",
    row?.observed_at || ""
  ].join(":");
}

export function writeValuationTickerSnapshot(ticker, payload) {
  const normalized = String(ticker || payload?.ticker || "").trim().toUpperCase();
  if (!normalized) return;
  db.prepare(`
    INSERT INTO valuation_ticker_snapshots (ticker, generated_at, payload_json)
    VALUES (?, ?, ?)
    ON CONFLICT(ticker) DO UPDATE SET
      generated_at = excluded.generated_at,
      payload_json = excluded.payload_json
  `).run(normalized, payload.generatedAt || new Date().toISOString(), JSON.stringify(payload));
}

function mapPodcastInsight(row) {
  return {
    id: row.id,
    ticker: row.ticker,
    generatedAt: row.generated_at,
    observedAt: row.observed_at || "",
    channel: row.channel || "",
    videoId: row.video_id || "",
    videoTitle: row.video_title || "",
    videoUrl: row.video_url || "",
    speaker: row.speaker || "",
    theme: row.theme || "",
    stance: row.stance || "",
    horizon: row.horizon || "",
    confidence: row.confidence,
    relevanceScore: row.relevance_score,
    summary: row.summary || "",
    summaryZh: row.summary_zh || "",
    evidenceExcerpt: row.evidence_excerpt || "",
    evidenceExcerptZh: row.evidence_excerpt_zh || "",
    payload: parsePayload(row.payload_json) || {}
  };
}

export function writeValuationPodcastInsights(insights = []) {
  if (!insights.length) return 0;
  const statement = db.prepare(`
    INSERT INTO valuation_podcast_insights (
      id,
      ticker,
      generated_at,
      observed_at,
      channel,
      video_id,
      video_title,
      video_url,
      speaker,
      theme,
      stance,
      horizon,
      confidence,
      relevance_score,
      summary,
      summary_zh,
      evidence_excerpt,
      evidence_excerpt_zh,
      payload_json
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      ticker = excluded.ticker,
      generated_at = excluded.generated_at,
      observed_at = excluded.observed_at,
      channel = excluded.channel,
      video_id = excluded.video_id,
      video_title = excluded.video_title,
      video_url = excluded.video_url,
      speaker = excluded.speaker,
      theme = excluded.theme,
      stance = excluded.stance,
      horizon = excluded.horizon,
      confidence = excluded.confidence,
      relevance_score = excluded.relevance_score,
      summary = excluded.summary,
      summary_zh = excluded.summary_zh,
      evidence_excerpt = excluded.evidence_excerpt,
      evidence_excerpt_zh = excluded.evidence_excerpt_zh,
      payload_json = excluded.payload_json
  `);
  const generatedAt = new Date().toISOString();
  let count = 0;
  db.exec("BEGIN");
  try {
    for (const insight of insights) {
      const ticker = normalizeTickerKey(insight.ticker);
      const id = String(insight.id || "").trim();
      if (!id || !ticker) continue;
      statement.run(
        id,
        ticker,
        String(insight.generatedAt || generatedAt),
        String(insight.observedAt || ""),
        String(insight.channel || ""),
        String(insight.videoId || ""),
        String(insight.videoTitle || ""),
        String(insight.videoUrl || ""),
        String(insight.speaker || ""),
        String(insight.theme || ""),
        String(insight.stance || ""),
        String(insight.horizon || ""),
        Number.isFinite(Number(insight.confidence)) ? Number(insight.confidence) : null,
        Number.isFinite(Number(insight.relevanceScore)) ? Number(insight.relevanceScore) : null,
        String(insight.summary || ""),
        String(insight.summaryZh || ""),
        String(insight.evidenceExcerpt || ""),
        String(insight.evidenceExcerptZh || ""),
        JSON.stringify(insight.payload || {})
      );
      count += 1;
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return count;
}

export function replaceValuationPodcastInsights(insights = []) {
  db.exec("BEGIN");
  try {
    db.prepare("DELETE FROM valuation_podcast_insights").run();
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return writeValuationPodcastInsights(insights);
}

export function readValuationPodcastInsights(ticker, limit = 12) {
  const normalized = normalizeTickerKey(ticker);
  if (!normalized) return [];
  const rowLimit = Math.max(1, Math.min(50, Number(limit) || 12));
  return db.prepare(`
    SELECT
      id,
      ticker,
      generated_at,
      observed_at,
      channel,
      video_id,
      video_title,
      video_url,
      speaker,
      theme,
      stance,
      horizon,
      confidence,
      relevance_score,
      summary,
      summary_zh,
      evidence_excerpt,
      evidence_excerpt_zh,
      payload_json
    FROM valuation_podcast_insights
    WHERE ticker = ?
    ORDER BY observed_at DESC, relevance_score DESC, generated_at DESC
    LIMIT ?
  `).all(normalized, rowLimit).map(mapPodcastInsight);
}

export function readValuationPodcastInsightSummary(limit = 500) {
  const rowLimit = Math.max(1, Math.min(5000, Number(limit) || 500));
  const summary = db.prepare(`
    SELECT
      COUNT(*) AS insight_count,
      COUNT(DISTINCT ticker) AS ticker_count,
      COUNT(DISTINCT channel) AS source_count,
      MAX(observed_at) AS latest_observed_at
    FROM valuation_podcast_insights
  `).get();
  const rows = db.prepare(`
    SELECT
      id,
      ticker,
      generated_at,
      observed_at,
      channel,
      video_id,
      video_title,
      video_url,
      speaker,
      theme,
      stance,
      horizon,
      confidence,
      relevance_score,
      summary,
      summary_zh,
      evidence_excerpt,
      evidence_excerpt_zh,
      payload_json
    FROM valuation_podcast_insights
    ORDER BY observed_at DESC, relevance_score DESC, generated_at DESC
    LIMIT ?
  `).all(rowLimit).map(mapPodcastInsight);
  const tickers = new Set();
  for (const row of rows) {
    if (row.ticker) tickers.add(row.ticker);
  }
  return {
    insightCount: Number(summary?.insight_count) || 0,
    tickerCount: Number(summary?.ticker_count) || 0,
    sourceCount: Number(summary?.source_count) || 0,
    latestObservedAt: summary?.latest_observed_at || "",
    topTickers: [...tickers].slice(0, 20),
    latest: rows.slice(0, 8)
  };
}

export function writeGuruBacktest(guruId, years, payload, {
  preserveReadyMethodVersion = "",
  preserveReadySecurityMasterVersion = ""
} = {}) {
  if (payload?.guru?.id !== guruId) {
    throw new Error("Guru backtest cache identity does not match its key.");
  }
  if (payload?.status === "proxy_ready") {
    throw new Error("Proxy curves must be written with writeGuruBacktestProxy.");
  }
  const configuredGuruType = gurus.find((guru) => guru.id === guruId)?.type || "";
  const configuredManager13f = configuredGuruType === "manager13f";
  if (payload?.status === "ready" && configuredManager13f) {
    const strictAudit = auditManager13fStrictReadyPayload(payload);
    if (!strictAudit.ok) {
      throw new Error(`Strict cache row failed its coverage audit: ${strictAudit.reason}.`);
    }
  }
  const normalizedMethodVersion = String(preserveReadyMethodVersion || "").trim();
  const normalizedSecurityMasterVersion = String(
    preserveReadySecurityMasterVersion || ""
  ).trim();
  const retained = payload?.status === "insufficient_data" &&
    payload?.method?.version === normalizedMethodVersion &&
    String(payload?.method?.securityMasterVersion || "").trim() ===
      normalizedSecurityMasterVersion
    ? readGuruBacktest(guruId, years)
    : null;
  const retainReadyCurve = Boolean(
    retained &&
    retained.guru?.id === guruId &&
    retained?.status === "ready" &&
    retained?.method?.version === normalizedMethodVersion &&
    String(retained?.method?.securityMasterVersion || "").trim() ===
      normalizedSecurityMasterVersion &&
    (!configuredManager13f || auditManager13fStrictReadyPayload(retained).ok) &&
    Array.isArray(retained?.equity) &&
    retained.equity.length >= 2
  );
  if (retainReadyCurve) {
    return {
      written: false,
      retainedReady: true,
      retainedGeneratedAt: retained.generatedAt || null,
      retainedWindow: retained.window || null,
      retainedMethodVersion: retained.method.version,
      retainedSecurityMasterVersion: retained.method.securityMasterVersion
    };
  }

  db.prepare(`
    INSERT INTO guru_backtests (guru_id, years, generated_at, start_date, end_date, payload_json)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(guru_id, years) DO UPDATE SET
      generated_at = excluded.generated_at,
      start_date = excluded.start_date,
      end_date = excluded.end_date,
      payload_json = excluded.payload_json
  `).run(
    guruId,
    years,
    payload.generatedAt || new Date().toISOString(),
    payload.window?.start || payload.startDate || "",
    payload.window?.end || payload.endDate || "",
    JSON.stringify(payload)
  );
  return {
    written: true,
    retainedReady: false
  };
}

export function writeGuruBacktestProxy(guruId, years, payload) {
  if (payload?.guru?.id !== guruId) {
    throw new Error("Guru backtest proxy cache identity does not match its key.");
  }
  if (payload?.status !== "proxy_ready") {
    throw new Error("Only proxy_ready payloads may be written to guru_backtest_proxies.");
  }
  const proxyMethodVersion = String(payload?.proxy?.methodVersion || "").trim();
  const methodVariant = String(payload?.method?.variant || "").trim();
  if (!proxyMethodVersion || proxyMethodVersion !== methodVariant) {
    throw new Error("Matching proxy method versions are required.");
  }
  const proxySecurityMasterVersion = String(
    payload?.proxy?.securityMasterVersion || ""
  ).trim();
  const methodSecurityMasterVersion = String(
    payload?.method?.securityMasterVersion || ""
  ).trim();
  if (!proxySecurityMasterVersion ||
      proxySecurityMasterVersion !== methodSecurityMasterVersion) {
    throw new Error("Matching proxy security-master versions are required.");
  }
  const strictFailureGeneratedAt = String(
    payload?.proxy?.strictFailureGeneratedAt || ""
  ).trim();
  const generatedAt = String(payload?.generatedAt || "").trim();
  if (!strictFailureGeneratedAt || strictFailureGeneratedAt !== generatedAt) {
    throw new Error("A proxy cache row must identify its strict failure generation.");
  }
  if (!Array.isArray(payload?.equity) || payload.equity.length < 2) {
    throw new Error("A proxy cache row requires a non-empty equity curve.");
  }
  const proxyAudit = auditPublicHoldingsProxyPayload(payload);
  if (!proxyAudit.ok) {
    throw new Error(`Proxy cache row failed its public coverage audit: ${proxyAudit.reason}.`);
  }
  db.prepare(`
    INSERT INTO guru_backtest_proxies (
      guru_id,
      years,
      generated_at,
      start_date,
      end_date,
      method_version,
      payload_json
    )
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(guru_id, years) DO UPDATE SET
      generated_at = excluded.generated_at,
      start_date = excluded.start_date,
      end_date = excluded.end_date,
      method_version = excluded.method_version,
      payload_json = excluded.payload_json
  `).run(
    guruId,
    years,
    generatedAt,
    payload.window?.start || "",
    payload.window?.end || "",
    proxyMethodVersion,
    JSON.stringify(payload)
  );
}

function atomicBacktestItemKey(item, label) {
  const guruId = String(item?.guruId || "").trim();
  const years = Number(item?.years);
  if (!guruId || !Number.isInteger(years) || years < 0 || years > 40) {
    throw new Error(`${label} requires a valid guru id and backtest window key.`);
  }
  return `${guruId}:${years}`;
}

function assertAtomicBacktestWindow(item, label) {
  const years = Number(item.years);
  const expectedMethodYears = years === 0 ? "all" : String(years);
  if (String(item?.payload?.method?.years) !== expectedMethodYears) {
    throw new Error(
      `${label} ${item.guruId}:${years} method.years does not match its cache key.`
    );
  }
  if (String(item?.payload?.guru?.id || "").trim() !== item.guruId) {
    throw new Error(`${label} ${item.guruId}:${years} payload guru id does not match.`);
  }
}

function assertAtomicProxyLinkage(strictItem, proxyItem) {
  if (!strictItem) {
    throw new Error(
      `Atomic proxy ${proxyItem.guruId}:${proxyItem.years} requires its strict failure in the same bundle.`
    );
  }
  const strictPayload = strictItem.payload;
  const proxyPayload = proxyItem.payload;
  if (strictPayload?.status !== "insufficient_data") {
    throw new Error("An atomic proxy must link to a strict insufficient_data artifact.");
  }
  if (!strictPayload?.generatedAt ||
      proxyPayload?.generatedAt !== strictPayload.generatedAt ||
      proxyPayload?.proxy?.strictFailureGeneratedAt !== strictPayload.generatedAt) {
    throw new Error("Atomic strict/proxy artifacts must share an exact generation link.");
  }
  if (proxyPayload?.method?.version !== strictPayload?.method?.version ||
      proxyPayload?.method?.securityMasterVersion !==
        strictPayload?.method?.securityMasterVersion ||
      String(proxyPayload?.method?.years) !== String(strictPayload?.method?.years)) {
    throw new Error("Atomic strict/proxy method identities must match.");
  }
}

function validateAtomicBacktestArtifacts(backtests, backtestProxies) {
  const strictByKey = new Map();
  for (const item of backtests) {
    const key = atomicBacktestItemKey(item, "Atomic strict backtest");
    if (strictByKey.has(key)) {
      throw new Error(`Duplicate atomic strict backtest: ${key}.`);
    }
    assertAtomicBacktestWindow(item, "Atomic strict backtest");
    strictByKey.set(key, item);
  }

  const proxyKeys = new Set();
  for (const item of backtestProxies) {
    const key = atomicBacktestItemKey(item, "Atomic proxy backtest");
    if (proxyKeys.has(key)) {
      throw new Error(`Duplicate atomic proxy backtest: ${key}.`);
    }
    proxyKeys.add(key);
    assertAtomicBacktestWindow(item, "Atomic proxy backtest");
    assertAtomicProxyLinkage(strictByKey.get(key), item);
  }
}

function exactAtomicGuruIds(value, label, { allowEmpty = false } = {}) {
  if (!Array.isArray(value) || (!allowEmpty && !value.length)) {
    throw new Error(`${label} must be a non-empty array.`);
  }
  const ids = value.map((id) => String(id || "").trim());
  if (ids.some((id) => !id) || new Set(ids).size !== ids.length) {
    throw new Error(`${label} must contain unique non-empty Guru ids.`);
  }
  return ids;
}

function sameOrderedIds(left, right) {
  return left.length === right.length &&
    left.every((id, index) => id === right[index]);
}

function normalizeAtomicExpectedState(value) {
  if (value === undefined || value === null) return null;
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Atomic expectedState must be an object.");
  }
  const dashboardVersion = String(value.dashboardVersion || "").trim();
  const exposureVersion = String(value.exposureVersion || "").trim();
  const curveVersions = value.curveVersions;
  if (!dashboardVersion || !exposureVersion || !curveVersions ||
      typeof curveVersions !== "object" ||
      Array.isArray(curveVersions) || !Object.keys(curveVersions).length) {
    throw new Error(
      "Atomic expectedState requires dashboard, exposure, and curve revision tokens."
    );
  }
  const normalizedCurveVersions = {};
  for (const [rawYears, rawVersion] of Object.entries(curveVersions)) {
    const years = Number(rawYears);
    const version = String(rawVersion || "").trim();
    if (!Number.isInteger(years) || years < 0 || years > 40 || !version) {
      throw new Error("Atomic expectedState contains an invalid curve revision token.");
    }
    normalizedCurveVersions[years] = version;
  }
  return {
    dashboardVersion,
    exposureVersion,
    curveVersions: normalizedCurveVersions,
    dashboardGuruIds: exactAtomicGuruIds(
      value.dashboardGuruIds,
      "Atomic expected dashboard Guru ids",
      { allowEmpty: true }
    ),
    exactCatalogIds: exactAtomicGuruIds(
      value.exactCatalogIds,
      "Atomic exact catalog Guru ids"
    )
  };
}

function assertAtomicExpectedState(expectedState, {
  dashboard,
  latestDashboard,
  guruSnapshots
}) {
  if (readGuruDashboardVersion() !== expectedState.dashboardVersion) {
    throw new Error("Atomic dashboard revision precondition changed before commit.");
  }
  if (readGuruExposureVersion() !== expectedState.exposureVersion) {
    throw new Error("Atomic exposure revision precondition changed before commit.");
  }
  for (const [years, version] of Object.entries(expectedState.curveVersions)) {
    if (readGuruBacktestVersion(Number(years)) !== version) {
      throw new Error(`${years}Y atomic curve revision precondition changed before commit.`);
    }
  }

  const currentIds = exactAtomicGuruIds(
    Array.isArray(latestDashboard?.gurus)
      ? latestDashboard.gurus.map((guru) => guru?.id)
      : [],
    "Current atomic dashboard Guru ids",
    { allowEmpty: true }
  );
  if (!sameOrderedIds(currentIds, expectedState.dashboardGuruIds)) {
    throw new Error("Atomic dashboard Guru identities changed before commit.");
  }
  const templateIds = exactAtomicGuruIds(
    Array.isArray(dashboard?.gurus) ? dashboard.gurus.map((guru) => guru?.id) : [],
    "Atomic dashboard template Guru ids"
  );
  if (!sameOrderedIds(templateIds, expectedState.exactCatalogIds)) {
    throw new Error("Atomic dashboard template does not match the exact catalog order.");
  }
  const stagedIds = exactAtomicGuruIds(
    guruSnapshots.map((item) => item?.guruId),
    "Atomic staged Guru ids",
    { allowEmpty: true }
  );
  const current = new Set(currentIds);
  if (stagedIds.some((id) => current.has(id))) {
    throw new Error("Atomic catalog bootstrap targets already exist in the current dashboard.");
  }
  const finalIds = new Set([...currentIds, ...stagedIds]);
  if (finalIds.size !== expectedState.exactCatalogIds.length ||
      expectedState.exactCatalogIds.some((id) => !finalIds.has(id))) {
    throw new Error("Atomic dashboard inputs do not cover the exact catalog.");
  }
}

export function writeGuru13fRefreshBundle({
  dashboard,
  guruSnapshots = [],
  exposureSnapshots = [],
  backtests = [],
  backtestProxies = [],
  expectedState
} = {}) {
  if (!dashboard || typeof dashboard !== "object") {
    throw new Error("A dashboard payload is required for an atomic 13F refresh commit.");
  }
  validateAtomicBacktestArtifacts(backtests, backtestProxies);
  const normalizedExpectedState = normalizeAtomicExpectedState(expectedState);

  db.exec("BEGIN IMMEDIATE");
  try {
    // Read the dashboard only after obtaining the write lock. A refresh can spend
    // tens of seconds staging SEC history, so the dashboard supplied by the
    // caller may be older than a different manager refresh that committed while
    // this job was working. Preserve every non-selected manager from the latest
    // committed dashboard and apply only this bundle's manager patches.
    const latestDashboard = readDashboardSnapshot();
    if (normalizedExpectedState) {
      assertAtomicExpectedState(normalizedExpectedState, {
        dashboard,
        latestDashboard,
        guruSnapshots
      });
    }
    const stagedGuruIds = new Set(guruSnapshots.map((item) => item.guruId));
    const templateGurus = Array.isArray(dashboard.gurus) ? dashboard.gurus : [];
    const latestGurus = Array.isArray(latestDashboard?.gurus)
      ? latestDashboard.gurus
      : [];
    const templateById = new Map(templateGurus.map((guru) => [guru.id, guru]));
    const latestById = new Map(latestGurus.map((guru) => [guru.id, guru]));
    const stagedById = new Map(
      guruSnapshots.map((item) => [
        item.guruId,
        templateById.get(item.guruId) || item.payload
      ])
    );
    const orderedIds = [];
    const seenIds = new Set();
    for (const guru of [...templateGurus, ...latestGurus]) {
      if (!guru?.id || seenIds.has(guru.id)) continue;
      seenIds.add(guru.id);
      orderedIds.push(guru.id);
    }
    for (const guruId of stagedGuruIds) {
      if (seenIds.has(guruId)) continue;
      seenIds.add(guruId);
      orderedIds.push(guruId);
    }

    for (const item of guruSnapshots) {
      writeGuruSnapshot(item.guruId, item.payload);
    }
    for (const item of exposureSnapshots) {
      writeGuruExposureSnapshot(item.guruId, item.payload);
    }
    for (const item of backtests) {
      writeGuruBacktest(item.guruId, item.years, item.payload);
    }
    for (const item of backtestProxies) {
      writeGuruBacktestProxy(item.guruId, item.years, item.payload);
      assertAtomicProxyLinkage(
        {
          guruId: item.guruId,
          years: item.years,
          payload: readGuruBacktest(item.guruId, item.years)
        },
        {
          guruId: item.guruId,
          years: item.years,
          payload: readGuruBacktestProxy(item.guruId, item.years)
        }
      );
    }
    const committedDashboard = {
      ...(normalizedExpectedState ? (latestDashboard || {}) : dashboard),
      ...(normalizedExpectedState ? dashboard : (latestDashboard || {})),
      generatedAt: new Date().toISOString(),
      gurus: (normalizedExpectedState?.exactCatalogIds || orderedIds)
        .map((guruId) => {
          if (normalizedExpectedState) return templateById.get(guruId);
          if (stagedGuruIds.has(guruId)) return stagedById.get(guruId);
          return latestById.get(guruId) || templateById.get(guruId);
        })
        .filter(Boolean)
    };
    writeDashboardSnapshot(committedDashboard);
    db.exec("COMMIT");
    return {
      gurus: guruSnapshots.length,
      exposures: exposureSnapshots.length,
      backtests: backtests.length,
      backtestProxies: backtestProxies.length,
      dashboardGeneratedAt: committedDashboard.generatedAt
    };
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // Preserve the original staging or commit error.
    }
    throw error;
  }
}

export function readPriceSeriesFromDb(symbol, start, end) {
  const normalized = String(symbol || "").trim().toUpperCase();
  if (!normalized) return [];

  return db.prepare(`
    SELECT symbol, date, open, high, low, close, adjusted_close, volume, source
    FROM price_points
    WHERE symbol = ? AND date >= ? AND date <= ?
    ORDER BY date ASC
  `).all(normalized, start, end).map((point) => ({
    symbol: point.symbol,
    date: point.date,
    open: point.open,
    high: point.high,
    low: point.low,
    close: point.close,
    adjustedClose: point.adjusted_close,
    volume: point.volume,
    source: point.source
  }));
}

const auditedPriceRepairPointStatement = db.prepare(`
  SELECT repaired.value AS audited_row_json,
    before_row.value AS before_row_json
  FROM price_repair_audits AS audit,
    json_each(audit.rows_json) AS repaired
  LEFT JOIN json_each(audit.before_rows_json) AS before_row
    ON json_extract(before_row.value, '$.symbol') = json_extract(repaired.value, '$.symbol')
    AND json_extract(before_row.value, '$.date') = json_extract(repaired.value, '$.date')
  WHERE audit.provider = ?
    AND json_extract(repaired.value, '$.symbol') = ?
    AND json_extract(repaired.value, '$.date') = ?
  ORDER BY audit.created_at DESC
  LIMIT 1
`);

const auditedPriceSeriesImportPointStatement = db.prepare(`
  SELECT imported.value AS audited_row_json,
    before_row.value AS before_row_json
  FROM price_series_import_audits AS audit,
    json_each(audit.rows_json) AS imported
  LEFT JOIN json_each(audit.before_rows_json) AS before_row
    ON json_extract(before_row.value, '$.symbol') = audit.symbol
    AND json_extract(before_row.value, '$.date') = json_extract(imported.value, '$.date')
  WHERE audit.provider = ?
    AND audit.symbol = ?
    AND json_extract(imported.value, '$.symbol') = ?
    AND json_extract(imported.value, '$.date') = ?
  ORDER BY audit.created_at DESC
  LIMIT 1
`);

function pricePointMatchesAuditedLedgerRow(point, ledgerRow) {
  if (!ledgerRow?.audited_row_json) return false;
  const audited = parsePayload(ledgerRow.audited_row_json);
  const before = parsePayload(ledgerRow.before_row_json) || {};
  if (!audited || typeof audited !== "object") return false;
  const expected = {};
  for (const field of ["open", "high", "low", "close", "adjustedClose", "volume"]) {
    expected[field] = before.action === "complete-null-fields" && before[field] != null
      ? before[field]
      : audited[field];
  }
  const numericMatches = (left, right) =>
    Number.isFinite(Number(left)) &&
    Number.isFinite(Number(right)) &&
    Math.abs(Number(left) - Number(right)) <=
      Math.max(1e-6, Math.abs(Number(right)) * 1e-6);
  return ["open", "high", "low", "close", "adjustedClose"].every((field) =>
    numericMatches(point?.[field], expected[field])
  ) && Number.isSafeInteger(Number(point?.volume)) &&
    Number(point.volume) === Number(expected.volume);
}

export function filterLedgerAuditedPriceRepairPoints(points = []) {
  return (points || []).filter((point) => {
    const source = String(point?.source || "");
    const symbol = String(point?.symbol || "").trim().toUpperCase();
    const date = String(point?.date || "").trim();
    if (!symbol || !date) return false;
    if (source.startsWith("audited:")) {
      const provider = source.slice("audited:".length);
      const ledgerRow = provider
        ? auditedPriceRepairPointStatement.get(provider, symbol, date)
        : null;
      return pricePointMatchesAuditedLedgerRow(point, ledgerRow);
    }
    if (source.startsWith("audited-series:")) {
      const provider = source.slice("audited-series:".length);
      const ledgerRow = provider
        ? auditedPriceSeriesImportPointStatement.get(provider, symbol, symbol, date)
        : null;
      return pricePointMatchesAuditedLedgerRow(point, ledgerRow);
    }
    return false;
  });
}

export function writePriceSeriesToDb(symbol, points, source = "unknown") {
  const normalized = String(symbol || "").trim().toUpperCase();
  if (!normalized || !points?.length) return;

  const statement = db.prepare(`
    INSERT INTO price_points (
      symbol, date, open, high, low, close, adjusted_close, volume, source, updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(symbol, date) DO UPDATE SET
      open = excluded.open,
      high = excluded.high,
      low = excluded.low,
      close = excluded.close,
      -- Keep adjusted-close provenance aligned with the incoming cache row.
      -- Audited repair writes use their separate ledger-backed transaction.
      adjusted_close = excluded.adjusted_close,
      volume = excluded.volume,
      source = excluded.source,
      updated_at = excluded.updated_at
  `);
  const updatedAt = new Date().toISOString();

  db.exec("BEGIN");
  try {
    for (const point of points) {
      if (!point.date || !Number.isFinite(point.close)) continue;
      statement.run(
        normalized,
        point.date,
        Number.isFinite(point.open) ? point.open : null,
        Number.isFinite(point.high) ? point.high : null,
        Number.isFinite(point.low) ? point.low : null,
        point.close,
        Number.isFinite(point.adjustedClose) ? point.adjustedClose : null,
        Number.isFinite(point.volume) ? point.volume : null,
        point.source || source,
        updatedAt
      );
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

const auditedPriceSymbolPattern = /^[A-Z0-9][A-Z0-9.-]{0,15}$/;
const auditedPriceDatePattern = /^\d{4}-\d{2}-\d{2}$/;

function normalizeAuditedPriceDate(value, index) {
  const date = String(value || "").trim();
  if (!auditedPriceDatePattern.test(date)) {
    throw new Error(`Price repair row ${index} has an invalid date.`);
  }
  const parsed = new Date(`${date}T00:00:00.000Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) {
    throw new Error(`Price repair row ${index} has an invalid calendar date.`);
  }
  return date;
}

function normalizeRequiredPositivePrice(value, field, index) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0 || number > 10_000_000) {
    throw new Error(`Price repair row ${index} has an invalid ${field}.`);
  }
  return number;
}

function normalizeAuditedPriceRepairRow(row, index) {
  if (!row || typeof row !== "object" || Array.isArray(row)) {
    throw new Error(`Price repair row ${index} must be an object.`);
  }
  const symbol = String(row.symbol || "").trim().toUpperCase();
  if (!auditedPriceSymbolPattern.test(symbol)) {
    throw new Error(`Price repair row ${index} has an invalid symbol.`);
  }
  const date = normalizeAuditedPriceDate(row.date, index);
  const open = normalizeRequiredPositivePrice(row.open, "open", index);
  const high = normalizeRequiredPositivePrice(row.high, "high", index);
  const low = normalizeRequiredPositivePrice(row.low, "low", index);
  const close = normalizeRequiredPositivePrice(row.close, "close", index);
  const adjustedClose = normalizeRequiredPositivePrice(
    row.adjustedClose,
    "adjustedClose",
    index
  );
  const volume = Number(row.volume);
  if (!Number.isSafeInteger(volume) || volume < 0 || volume > 100_000_000_000) {
    throw new Error(`Price repair row ${index} has an invalid volume.`);
  }
  if (high < low) {
    throw new Error(`Price repair row ${index} has a high below its low.`);
  }
  if (close < low || open < low) {
    throw new Error(`Price repair row ${index} has an open or close below its low.`);
  }
  if (close > high || open > high) {
    throw new Error(`Price repair row ${index} has an open or close above its high.`);
  }
  return { symbol, date, open, high, low, close, adjustedClose, volume };
}

export function writeAuditedPriceRepair(rows, {
  provider,
  reason,
  snapshotId,
  sourceReference,
  operator,
  affectedGuruIds = []
} = {}) {
  if (!Array.isArray(rows) || rows.length < 1 || rows.length > 100) {
    throw new Error("Price repair requires between 1 and 100 rows.");
  }
  const normalizedProvider = String(provider || "").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]{1,63}$/.test(normalizedProvider)) {
    throw new Error("Price repair provider is invalid.");
  }
  const normalizedReason = String(reason || "").trim();
  if (normalizedReason.length < 8 || normalizedReason.length > 240) {
    throw new Error("Price repair reason must contain between 8 and 240 characters.");
  }
  const normalizedSnapshotId = String(snapshotId || "").trim().toLowerCase();
  if (!/^snap-[a-f0-9]{8,32}$/.test(normalizedSnapshotId)) {
    throw new Error("Price repair requires the completed pre-write EBS snapshot id.");
  }
  const normalizedSourceReference = String(sourceReference || "").trim();
  if (normalizedSourceReference.length < 8 || normalizedSourceReference.length > 240) {
    throw new Error("Price repair source reference must contain between 8 and 240 characters.");
  }
  const normalizedOperator = String(operator || "").trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._:@/-]{2,79}$/.test(normalizedOperator)) {
    throw new Error("Price repair operator is invalid.");
  }
  const normalizedAffectedGuruIds = [...new Set(
    affectedGuruIds.map((guruId) => String(guruId || "").trim()).filter(Boolean)
  )].sort();
  if (!normalizedAffectedGuruIds.length || normalizedAffectedGuruIds.length > 5) {
    throw new Error("Price repair requires between one and five affected gurus.");
  }

  const normalizedRows = rows
    .map((row, index) => normalizeAuditedPriceRepairRow(row, index))
    .sort((left, right) =>
      left.symbol.localeCompare(right.symbol) || left.date.localeCompare(right.date)
    );
  const keys = normalizedRows.map((row) => `${row.symbol}:${row.date}`);
  if (new Set(keys).size !== keys.length) {
    throw new Error("Price repair contains duplicate symbol/date rows.");
  }
  const today = new Date().toISOString().slice(0, 10);
  const symbolExists = db.prepare("SELECT 1 FROM price_points WHERE symbol = ? LIMIT 1");
  const readExistingPrice = db.prepare(`
    SELECT symbol, date, open, high, low, close, adjusted_close, volume, source, updated_at
    FROM price_points
    WHERE symbol = ? AND date = ?
  `);
  const beforeRows = [];
  const actions = new Map();
  const numericMatches = (left, right) =>
    Math.abs(Number(left) - Number(right)) <= Math.max(1e-6, Math.abs(Number(right)) * 1e-6);
  for (const row of normalizedRows) {
    const weekday = new Date(`${row.date}T00:00:00.000Z`).getUTCDay();
    if (row.date > today || weekday === 0 || weekday === 6) {
      throw new Error(`Price repair date ${row.date} is not an eligible completed weekday.`);
    }
    if (row.symbol === "SPY") {
      throw new Error("The audited gap-fill route cannot modify the SPY benchmark.");
    }
    if (!symbolExists.get(row.symbol)) {
      throw new Error(`Price repair symbol ${row.symbol} has no existing price history.`);
    }
    if (!readExistingPrice.get("SPY", row.date)) {
      throw new Error(`Price repair date ${row.date} is not a stored SPY trading session.`);
    }
    const existing = readExistingPrice.get(row.symbol, row.date);
    const key = `${row.symbol}:${row.date}`;
    if (!existing) {
      actions.set(key, "insert");
      beforeRows.push({ symbol: row.symbol, date: row.date, action: "insert", existed: false });
      continue;
    }
    const existingValues = {
      open: existing.open,
      high: existing.high,
      low: existing.low,
      close: existing.close,
      adjustedClose: existing.adjusted_close,
      volume: existing.volume
    };
    const missingFields = Object.entries(existingValues)
      .filter(([, value]) => value === null || value === undefined)
      .map(([field]) => field);
    if (!missingFields.length) {
      throw new Error(`Price repair may not overwrite a complete row: ${row.symbol} ${row.date}.`);
    }
    for (const field of ["open", "high", "low", "close", "adjustedClose"]) {
      const value = existingValues[field];
      if (value !== null && value !== undefined && !numericMatches(value, row[field])) {
        throw new Error(
          `Price repair conflicts with existing ${field}: ${row.symbol} ${row.date}.`
        );
      }
    }
    actions.set(key, "complete-null-fields");
    beforeRows.push({
      symbol: row.symbol,
      date: row.date,
      action: "complete-null-fields",
      existed: true,
      source: existing.source || "",
      updatedAt: existing.updated_at || "",
      ...existingValues,
      missingFields
    });
  }

  const createdAt = new Date().toISOString();
  const source = `audited:${normalizedProvider}`;
  const policy = "insert_missing_or_complete_null_fields_verified_spy_session";
  const canonicalPayload = {
    provider: normalizedProvider,
    reason: normalizedReason,
    snapshotId: normalizedSnapshotId,
    sourceReference: normalizedSourceReference,
    operator: normalizedOperator,
    policy,
    affectedGuruIds: normalizedAffectedGuruIds,
    beforeRows,
    rows: normalizedRows
  };
  const payloadSha256 = crypto
    .createHash("sha256")
    .update(JSON.stringify(canonicalPayload))
    .digest("hex");
  const auditId = `price-repair-${crypto.randomUUID()}`;
  const symbols = [...new Set(normalizedRows.map((row) => row.symbol))];
  const dates = [...new Set(normalizedRows.map((row) => row.date))];
  const insertPrice = db.prepare(`
    INSERT INTO price_points (
      symbol, date, open, high, low, close, adjusted_close, volume, source, updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const completePrice = db.prepare(`
    UPDATE price_points
    SET open = COALESCE(open, ?),
      high = COALESCE(high, ?),
      low = COALESCE(low, ?),
      close = COALESCE(close, ?),
      adjusted_close = COALESCE(adjusted_close, ?),
      volume = COALESCE(volume, ?),
      source = ?,
      updated_at = ?
    WHERE symbol = ? AND date = ?
      AND (
        open IS NULL OR high IS NULL OR low IS NULL OR close IS NULL OR
        adjusted_close IS NULL OR volume IS NULL
      )
  `);
  const insertAudit = db.prepare(`
    INSERT INTO price_repair_audits (
      audit_id, created_at, provider, reason, snapshot_id, source_reference, operator,
      policy, affected_gurus_json, before_rows_json, rows_json, row_count, symbols_json,
      dates_json, payload_sha256
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  db.exec("BEGIN IMMEDIATE");
  try {
    for (const row of normalizedRows) {
      const action = actions.get(`${row.symbol}:${row.date}`);
      if (action === "insert") {
        insertPrice.run(
          row.symbol,
          row.date,
          row.open,
          row.high,
          row.low,
          row.close,
          row.adjustedClose,
          row.volume,
          source,
          createdAt
        );
      } else {
        const result = completePrice.run(
          row.open,
          row.high,
          row.low,
          row.close,
          row.adjustedClose,
          row.volume,
          source,
          createdAt,
          row.symbol,
          row.date
        );
        if (result.changes !== 1) {
          throw new Error(`Price repair lost its null-field guard: ${row.symbol} ${row.date}.`);
        }
      }
    }
    insertAudit.run(
      auditId,
      createdAt,
      normalizedProvider,
      normalizedReason,
      normalizedSnapshotId,
      normalizedSourceReference,
      normalizedOperator,
      policy,
      JSON.stringify(normalizedAffectedGuruIds),
      JSON.stringify(beforeRows),
      JSON.stringify(normalizedRows),
      normalizedRows.length,
      JSON.stringify(symbols),
      JSON.stringify(dates),
      payloadSha256
    );
    db.exec("COMMIT");
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // Preserve the original write or audit error.
    }
    throw error;
  }

  return {
    auditId,
    createdAt,
    provider: normalizedProvider,
    snapshotId: normalizedSnapshotId,
    sourceReference: normalizedSourceReference,
    operator: normalizedOperator,
    policy,
    affectedGuruIds: normalizedAffectedGuruIds,
    insertedRows: beforeRows.filter((row) => row.action === "insert").length,
    completedRows: beforeRows.filter((row) => row.action === "complete-null-fields").length,
    rowCount: normalizedRows.length,
    symbols,
    dates,
    payloadSha256
  };
}

export function readPriceRepairAudit(auditId) {
  const normalized = String(auditId || "").trim();
  if (!normalized) return null;
  const row = db.prepare(`
    SELECT audit_id, created_at, provider, reason, snapshot_id, source_reference,
      operator, policy, affected_gurus_json, before_rows_json, rows_json, row_count, symbols_json,
      dates_json, payload_sha256
    FROM price_repair_audits
    WHERE audit_id = ?
  `).get(normalized);
  if (!row) return null;
  return {
    auditId: row.audit_id,
    createdAt: row.created_at,
    provider: row.provider,
    reason: row.reason,
    snapshotId: row.snapshot_id,
    sourceReference: row.source_reference,
    operator: row.operator,
    policy: row.policy,
    affectedGuruIds: parsePayload(row.affected_gurus_json) || [],
    beforeRows: parsePayload(row.before_rows_json) || [],
    rows: parsePayload(row.rows_json) || [],
    rowCount: Number(row.row_count) || 0,
    symbols: parsePayload(row.symbols_json) || [],
    dates: parsePayload(row.dates_json) || [],
    payloadSha256: row.payload_sha256
  };
}

const auditedPriceSeriesImportMaxRows = 5000;

function normalizeAuditedPriceSeriesImportRow(row, index, symbol) {
  if (!row || typeof row !== "object" || Array.isArray(row)) {
    throw new Error(`Price-series import row ${index} must be an object.`);
  }
  const rowSymbol = String(row.symbol || symbol).trim().toUpperCase();
  if (rowSymbol !== symbol) {
    throw new Error(`Price-series import row ${index} does not match symbol ${symbol}.`);
  }
  const date = String(row.date || "").trim();
  if (!auditedPriceDatePattern.test(date)) {
    throw new Error(`Price-series import row ${index} has an invalid date.`);
  }
  const parsed = new Date(`${date}T00:00:00.000Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) {
    throw new Error(`Price-series import row ${index} has an invalid calendar date.`);
  }
  const values = {};
  for (const field of ["open", "high", "low", "close", "adjustedClose"]) {
    const value = Number(row[field]);
    if (!Number.isFinite(value) || value <= 0 || value > 10_000_000) {
      throw new Error(`Price-series import row ${index} has an invalid ${field}.`);
    }
    values[field] = value;
  }
  const volume = Number(row.volume);
  if (!Number.isSafeInteger(volume) || volume < 0 || volume > 100_000_000_000) {
    throw new Error(`Price-series import row ${index} has an invalid volume.`);
  }
  if (values.high < values.low) {
    throw new Error(`Price-series import row ${index} has a high below its low.`);
  }
  if (values.open < values.low || values.close < values.low) {
    throw new Error(`Price-series import row ${index} has an open or close below its low.`);
  }
  if (values.open > values.high || values.close > values.high) {
    throw new Error(`Price-series import row ${index} has an open or close above its high.`);
  }
  return { symbol, date, ...values, volume };
}

function writeAuditedPriceSeriesImportInternal(rows, {
  symbol,
  startDate,
  endDate,
  provider,
  reason,
  snapshotId,
  snapshotState,
  sourceReference,
  operator,
  affectedGuruIds = []
} = {}, { manageTransaction = true } = {}) {
  if (
    !Array.isArray(rows) ||
    rows.length < 1 ||
    rows.length > auditedPriceSeriesImportMaxRows
  ) {
    throw new Error(
      `Price-series import requires between 1 and ${auditedPriceSeriesImportMaxRows} rows.`
    );
  }
  const normalizedSymbol = String(symbol || "").trim().toUpperCase();
  if (!auditedPriceSymbolPattern.test(normalizedSymbol) || normalizedSymbol === "SPY") {
    throw new Error("Price-series import symbol is invalid or reserved.");
  }
  const normalizedStartDate = normalizeAuditedPriceDate(startDate, "interval start");
  const normalizedEndDate = normalizeAuditedPriceDate(endDate, "interval end");
  if (normalizedStartDate > normalizedEndDate) {
    throw new Error("Price-series import interval start must not follow its end.");
  }
  const today = new Date().toISOString().slice(0, 10);
  if (normalizedEndDate > today) {
    throw new Error("Price-series import interval may not extend into the future.");
  }
  const normalizedProvider = String(provider || "").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]{1,63}$/.test(normalizedProvider)) {
    throw new Error("Price-series import provider is invalid.");
  }
  const normalizedReason = String(reason || "").trim();
  if (normalizedReason.length < 8 || normalizedReason.length > 240) {
    throw new Error("Price-series import reason must contain between 8 and 240 characters.");
  }
  const normalizedSnapshotId = String(snapshotId || "").trim().toLowerCase();
  if (!/^snap-[a-f0-9]{8,32}$/.test(normalizedSnapshotId)) {
    throw new Error("Price-series import requires the pre-write EBS snapshot id.");
  }
  const normalizedSnapshotState = String(snapshotState || "").trim().toLowerCase();
  if (normalizedSnapshotState !== "completed") {
    throw new Error("Price-series import requires a completed pre-write EBS snapshot.");
  }
  const normalizedSourceReference = String(sourceReference || "").trim();
  if (normalizedSourceReference.length < 8 || normalizedSourceReference.length > 240) {
    throw new Error(
      "Price-series import source reference must contain between 8 and 240 characters."
    );
  }
  const normalizedOperator = String(operator || "").trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._:@/-]{2,79}$/.test(normalizedOperator)) {
    throw new Error("Price-series import operator is invalid.");
  }
  const normalizedAffectedGuruIds = [...new Set(
    affectedGuruIds.map((guruId) => String(guruId || "").trim()).filter(Boolean)
  )].sort();
  if (!normalizedAffectedGuruIds.length || normalizedAffectedGuruIds.length > 5) {
    throw new Error("Price-series import requires between one and five affected gurus.");
  }

  const normalizedRows = rows.map((row, index) =>
    normalizeAuditedPriceSeriesImportRow(row, index, normalizedSymbol)
  );
  for (let index = 0; index < normalizedRows.length; index += 1) {
    const row = normalizedRows[index];
    if (row.date < normalizedStartDate || row.date > normalizedEndDate) {
      throw new Error(`Price-series import row ${index} falls outside the requested interval.`);
    }
    const weekday = new Date(`${row.date}T00:00:00.000Z`).getUTCDay();
    if (row.date > today || weekday === 0 || weekday === 6) {
      throw new Error(`Price-series import date ${row.date} is not an eligible completed weekday.`);
    }
    if (index > 0 && normalizedRows[index - 1].date >= row.date) {
      throw new Error("Price-series import rows must be unique and strictly sorted by date.");
    }
  }

  const readExistingPrice = db.prepare(`
    SELECT symbol, date, open, high, low, close, adjusted_close, volume, source, updated_at
    FROM price_points
    WHERE symbol = ? AND date = ?
  `);
  const readSpyDates = db.prepare(`
    SELECT date
    FROM price_points
    WHERE symbol = 'SPY' AND date >= ? AND date <= ?
    ORDER BY date ASC
  `);
  const insertPrice = db.prepare(`
    INSERT INTO price_points (
      symbol, date, open, high, low, close, adjusted_close, volume, source, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const completePrice = db.prepare(`
    UPDATE price_points
    SET open = COALESCE(open, ?),
      high = COALESCE(high, ?),
      low = COALESCE(low, ?),
      close = COALESCE(close, ?),
      adjusted_close = COALESCE(adjusted_close, ?),
      volume = COALESCE(volume, ?),
      source = ?,
      updated_at = ?
    WHERE symbol = ? AND date = ?
      AND (
        open IS NULL OR high IS NULL OR low IS NULL OR close IS NULL OR
        adjusted_close IS NULL OR volume IS NULL
      )
  `);
  const insertAudit = db.prepare(`
    INSERT INTO price_series_import_audits (
      audit_id, created_at, provider, reason, snapshot_id, snapshot_state,
      source_reference, operator, policy, affected_gurus_json, symbol,
      interval_start, interval_end, before_rows_json, rows_json, row_count,
      payload_sha256
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const numericMatches = (left, right) =>
    Math.abs(Number(left) - Number(right)) <= Math.max(1e-6, Math.abs(Number(right)) * 1e-6);
  const createdAt = new Date().toISOString();
  const source = `audited-series:${normalizedProvider}`;
  const policy = "complete_spy_session_series_insert_missing_or_complete_null_fields";
  const auditId = `price-series-import-${crypto.randomUUID()}`;
  let beforeRows = [];
  let payloadSha256 = "";

  if (manageTransaction) db.exec("BEGIN IMMEDIATE");
  try {
    const spyDates = readSpyDates
      .all(normalizedStartDate, normalizedEndDate)
      .map((row) => row.date);
    if (!spyDates.length) {
      throw new Error("Price-series import interval contains no stored SPY sessions.");
    }
    const importedDates = normalizedRows.map((row) => row.date);
    const importedDateSet = new Set(importedDates);
    const spyDateSet = new Set(spyDates);
    const missingDates = spyDates.filter((date) => !importedDateSet.has(date));
    const extraDates = importedDates.filter((date) => !spyDateSet.has(date));
    if (missingDates.length || extraDates.length || importedDates.length !== spyDates.length) {
      const detail = [
        missingDates.length ? `missing ${missingDates.slice(0, 5).join(", ")}` : "",
        extraDates.length ? `not SPY sessions ${extraDates.slice(0, 5).join(", ")}` : ""
      ].filter(Boolean).join("; ");
      throw new Error(
        `Price-series import must cover every stored SPY session in the interval${
          detail ? ` (${detail})` : ""
        }.`
      );
    }

    const actions = new Map();
    beforeRows = [];
    for (const row of normalizedRows) {
      const existing = readExistingPrice.get(normalizedSymbol, row.date);
      const key = `${normalizedSymbol}:${row.date}`;
      if (!existing) {
        actions.set(key, "insert");
        beforeRows.push({
          symbol: normalizedSymbol,
          date: row.date,
          action: "insert",
          existed: false
        });
        continue;
      }
      const existingValues = {
        open: existing.open,
        high: existing.high,
        low: existing.low,
        close: existing.close,
        adjustedClose: existing.adjusted_close,
        volume: existing.volume
      };
      const missingFields = Object.entries(existingValues)
        .filter(([, value]) => value === null || value === undefined)
        .map(([field]) => field);
      if (!missingFields.length) {
        throw new Error(
          `Price-series import may not overwrite a complete row: ${normalizedSymbol} ${row.date}.`
        );
      }
      for (const field of ["open", "high", "low", "close", "adjustedClose"]) {
        const value = existingValues[field];
        if (value !== null && value !== undefined && !numericMatches(value, row[field])) {
          throw new Error(
            `Price-series import conflicts with existing ${field}: ${normalizedSymbol} ${row.date}.`
          );
        }
      }
      if (
        existingValues.volume !== null &&
        existingValues.volume !== undefined &&
        Number(existingValues.volume) !== row.volume
      ) {
        throw new Error(
          `Price-series import conflicts with existing volume: ${normalizedSymbol} ${row.date}.`
        );
      }
      actions.set(key, "complete-null-fields");
      beforeRows.push({
        symbol: normalizedSymbol,
        date: row.date,
        action: "complete-null-fields",
        existed: true,
        source: existing.source || "",
        updatedAt: existing.updated_at || "",
        ...existingValues,
        missingFields
      });
    }

    const canonicalPayload = {
      provider: normalizedProvider,
      reason: normalizedReason,
      snapshotId: normalizedSnapshotId,
      snapshotState: normalizedSnapshotState,
      sourceReference: normalizedSourceReference,
      operator: normalizedOperator,
      policy,
      affectedGuruIds: normalizedAffectedGuruIds,
      symbol: normalizedSymbol,
      startDate: normalizedStartDate,
      endDate: normalizedEndDate,
      beforeRows,
      rows: normalizedRows
    };
    payloadSha256 = crypto
      .createHash("sha256")
      .update(JSON.stringify(canonicalPayload))
      .digest("hex");

    for (const row of normalizedRows) {
      const action = actions.get(`${normalizedSymbol}:${row.date}`);
      if (action === "insert") {
        insertPrice.run(
          normalizedSymbol,
          row.date,
          row.open,
          row.high,
          row.low,
          row.close,
          row.adjustedClose,
          row.volume,
          source,
          createdAt
        );
      } else {
        const result = completePrice.run(
          row.open,
          row.high,
          row.low,
          row.close,
          row.adjustedClose,
          row.volume,
          source,
          createdAt,
          normalizedSymbol,
          row.date
        );
        if (result.changes !== 1) {
          throw new Error(
            `Price-series import lost its null-field guard: ${normalizedSymbol} ${row.date}.`
          );
        }
      }
    }
    insertAudit.run(
      auditId,
      createdAt,
      normalizedProvider,
      normalizedReason,
      normalizedSnapshotId,
      normalizedSnapshotState,
      normalizedSourceReference,
      normalizedOperator,
      policy,
      JSON.stringify(normalizedAffectedGuruIds),
      normalizedSymbol,
      normalizedStartDate,
      normalizedEndDate,
      JSON.stringify(beforeRows),
      JSON.stringify(normalizedRows),
      normalizedRows.length,
      payloadSha256
    );
    if (manageTransaction) db.exec("COMMIT");
  } catch (error) {
    if (manageTransaction) {
      try {
        db.exec("ROLLBACK");
      } catch {
        // Preserve the original validation, write, or audit error.
      }
    }
    throw error;
  }

  return {
    auditId,
    createdAt,
    provider: normalizedProvider,
    snapshotId: normalizedSnapshotId,
    snapshotState: normalizedSnapshotState,
    sourceReference: normalizedSourceReference,
    operator: normalizedOperator,
    policy,
    affectedGuruIds: normalizedAffectedGuruIds,
    symbol: normalizedSymbol,
    startDate: normalizedStartDate,
    endDate: normalizedEndDate,
    insertedRows: beforeRows.filter((row) => row.action === "insert").length,
    completedRows: beforeRows.filter((row) => row.action === "complete-null-fields").length,
    rowCount: normalizedRows.length,
    payloadSha256
  };
}

export function writeAuditedPriceSeriesImport(rows, options = {}) {
  return writeAuditedPriceSeriesImportInternal(rows, options);
}

export function writeAuditedPriceSeriesImportBatch(requests, {
  recordsSha256,
  releaseId,
  sourceVolumeId,
  sourceSnapshotId,
  encryptedSnapshotId,
  operator,
  seriesManifest = [],
  refreshTargets = [],
  expectations = {}
} = {}) {
  if (!Array.isArray(requests) || requests.length > 64) {
    throw new Error("Price-series import batch may contain at most 64 series groups.");
  }
  const totalRows = requests.reduce((sum, request) =>
    sum + (Array.isArray(request?.rows) ? request.rows.length : 0), 0);
  if (totalRows > 20_000) {
    throw new Error("Price-series import batch may contain at most 20,000 rows.");
  }
  const normalizedRecordsSha256 = String(recordsSha256 || "").trim().toLowerCase();
  const normalizedReleaseId = String(releaseId || "").trim();
  const normalizedSourceVolumeId = String(sourceVolumeId || "").trim().toLowerCase();
  const normalizedSourceSnapshotId = String(sourceSnapshotId || "").trim().toLowerCase();
  const normalizedEncryptedSnapshotId = String(encryptedSnapshotId || "").trim().toLowerCase();
  const normalizedOperator = String(operator || "").trim();
  if (!/^[a-f0-9]{64}$/.test(normalizedRecordsSha256) ||
      !/^guru-curves-[A-Za-z0-9._-]{8,80}$/.test(normalizedReleaseId) ||
      !/^vol-[a-f0-9]{8,32}$/.test(normalizedSourceVolumeId) ||
      !/^snap-[a-f0-9]{8,32}$/.test(normalizedSourceSnapshotId) ||
      !/^snap-[a-f0-9]{8,32}$/.test(normalizedEncryptedSnapshotId) ||
      !/^[A-Za-z0-9][A-Za-z0-9._:@/-]{2,79}$/.test(normalizedOperator)) {
    throw new Error("Price-series import batch has invalid release identity metadata.");
  }
  if (!Array.isArray(seriesManifest) || !seriesManifest.length || seriesManifest.length > 64 ||
      !Array.isArray(refreshTargets) || !refreshTargets.length ||
      !expectations || typeof expectations !== "object" || Array.isArray(expectations)) {
    throw new Error("Price-series import batch requires its complete manifest and expectations.");
  }
  const manifestRowCount = seriesManifest.reduce((sum, series) =>
    sum + Number(series?.rowCount || 0), 0);
  if (!Number.isSafeInteger(manifestRowCount) || manifestRowCount < 1 ||
      manifestRowCount > 20_000 || totalRows > manifestRowCount) {
    throw new Error("Price-series import batch manifest row count is invalid.");
  }

  db.exec("BEGIN IMMEDIATE");
  try {
    const existing = db.prepare(`
      SELECT batch_audit_id, release_id, source_volume_id, source_snapshot_id,
        encrypted_snapshot_id, operator, child_audit_ids_json, series_manifest_json,
        refresh_targets_json, expectations_json, group_count, row_count,
        imported_row_count
      FROM price_series_import_batch_audits
      WHERE records_sha256 = ?
    `).get(normalizedRecordsSha256);
    if (existing) {
      const sameIdentity = existing.release_id === normalizedReleaseId &&
        existing.source_volume_id === normalizedSourceVolumeId &&
        existing.source_snapshot_id === normalizedSourceSnapshotId &&
        existing.encrypted_snapshot_id === normalizedEncryptedSnapshotId &&
        existing.operator === normalizedOperator &&
        existing.series_manifest_json === JSON.stringify(seriesManifest) &&
        existing.refresh_targets_json === JSON.stringify(refreshTargets) &&
        existing.expectations_json === JSON.stringify(expectations) &&
        Number(existing.row_count) === manifestRowCount;
      if (!sameIdentity || requests.length) {
        throw new Error("Price-series import batch audit conflicts with this release attempt.");
      }
      db.exec("COMMIT");
      return {
        batchAuditId: existing.batch_audit_id,
        recordsSha256: normalizedRecordsSha256,
        audits: JSON.parse(existing.child_audit_ids_json).map((auditId) => ({ auditId })),
        groupCount: Number(existing.group_count) || 0,
        rowCount: Number(existing.row_count) || 0,
        importedRowCount: Number(existing.imported_row_count) || 0,
        replayed: true
      };
    }
    const results = requests.map(({ rows, ...options }) =>
      writeAuditedPriceSeriesImportInternal(rows, options, { manageTransaction: false })
    );
    const createdAt = new Date().toISOString();
    const batchAuditId = `price-series-batch-${crypto.randomUUID()}`;
    db.prepare(`
      INSERT INTO price_series_import_batch_audits (
        batch_audit_id, created_at, records_sha256, release_id, source_volume_id,
        source_snapshot_id, encrypted_snapshot_id, operator, child_audit_ids_json,
        series_manifest_json, refresh_targets_json, expectations_json, group_count, row_count,
        imported_row_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      batchAuditId,
      createdAt,
      normalizedRecordsSha256,
      normalizedReleaseId,
      normalizedSourceVolumeId,
      normalizedSourceSnapshotId,
      normalizedEncryptedSnapshotId,
      normalizedOperator,
      JSON.stringify(results.map((result) => result.auditId)),
      JSON.stringify(seriesManifest),
      JSON.stringify(refreshTargets),
      JSON.stringify(expectations),
      results.length,
      manifestRowCount,
      totalRows
    );
    db.exec("COMMIT");
    return {
      batchAuditId,
      recordsSha256: normalizedRecordsSha256,
      audits: results,
      groupCount: results.length,
      rowCount: manifestRowCount,
      importedRowCount: totalRows,
      replayed: false
    };
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // Preserve the original validation, write, or audit error.
    }
    throw error;
  }
}

export function readPriceSeriesImportBatchAudit(recordsSha256) {
  const normalized = String(recordsSha256 || "").trim().toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(normalized)) return null;
  const row = db.prepare(`
    SELECT *
    FROM price_series_import_batch_audits
    WHERE records_sha256 = ?
  `).get(normalized);
  if (!row) return null;
  return {
    batchAuditId: row.batch_audit_id,
    createdAt: row.created_at,
    recordsSha256: row.records_sha256,
    releaseId: row.release_id,
    sourceVolumeId: row.source_volume_id,
    sourceSnapshotId: row.source_snapshot_id,
    encryptedSnapshotId: row.encrypted_snapshot_id,
    operator: row.operator,
    childAuditIds: JSON.parse(row.child_audit_ids_json),
    seriesManifest: JSON.parse(row.series_manifest_json),
    refreshTargets: JSON.parse(row.refresh_targets_json),
    expectations: JSON.parse(row.expectations_json),
    groupCount: Number(row.group_count) || 0,
    rowCount: Number(row.row_count) || 0,
    importedRowCount: Number(row.imported_row_count) || 0
  };
}

export function readPriceSeriesImportAudit(auditId) {
  const normalized = String(auditId || "").trim();
  if (!normalized) return null;
  const row = db.prepare(`
    SELECT audit_id, created_at, provider, reason, snapshot_id, snapshot_state,
      source_reference, operator, policy, affected_gurus_json, symbol,
      interval_start, interval_end, before_rows_json, rows_json, row_count,
      payload_sha256
    FROM price_series_import_audits
    WHERE audit_id = ?
  `).get(normalized);
  if (!row) return null;
  return {
    auditId: row.audit_id,
    createdAt: row.created_at,
    provider: row.provider,
    reason: row.reason,
    snapshotId: row.snapshot_id,
    snapshotState: row.snapshot_state,
    sourceReference: row.source_reference,
    operator: row.operator,
    policy: row.policy,
    affectedGuruIds: parsePayload(row.affected_gurus_json) || [],
    symbol: row.symbol,
    startDate: row.interval_start,
    endDate: row.interval_end,
    beforeRows: parsePayload(row.before_rows_json) || [],
    rows: parsePayload(row.rows_json) || [],
    rowCount: Number(row.row_count) || 0,
    payloadSha256: row.payload_sha256
  };
}

export function writePortfolioNavPoint(point) {
  const accountId = String(point?.accountId || "portfolio").trim() || "portfolio";
  const date = String(point?.date || "").trim();
  const nav = Number(point?.nav);
  if (!date || !Number.isFinite(nav) || nav <= 0) return;

  db.prepare(`
    INSERT INTO portfolio_nav_points (
      account_id,
      date,
      nav,
      cash,
      source,
      source_date,
      payload_json,
      updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(account_id, date) DO UPDATE SET
      nav = excluded.nav,
      cash = excluded.cash,
      source = excluded.source,
      source_date = excluded.source_date,
      payload_json = excluded.payload_json,
      updated_at = excluded.updated_at
  `).run(
    accountId,
    date,
    nav,
    Number.isFinite(Number(point.cash)) ? Number(point.cash) : null,
    String(point.source || ""),
    String(point.sourceDate || ""),
    JSON.stringify(point.payload || {}),
    new Date().toISOString()
  );
}

export function readPortfolioNavPoints(accountId = "portfolio", limit = 5000) {
  const normalizedAccountId = String(accountId || "portfolio").trim() || "portfolio";
  const rowLimit = Math.max(1, Math.min(10000, Number(limit) || 5000));
  return db.prepare(`
    SELECT account_id, date, nav, cash, source, source_date, updated_at, payload_json
    FROM (
      SELECT account_id, date, nav, cash, source, source_date, updated_at, payload_json
      FROM portfolio_nav_points
      WHERE account_id = ?
      ORDER BY date DESC
      LIMIT ?
    )
    ORDER BY date ASC
  `).all(normalizedAccountId, rowLimit).map((row) => ({
    accountId: row.account_id,
    date: row.date,
    value: row.nav,
    nav: row.nav,
    cash: row.cash,
    source: row.source || "",
    sourceDate: row.source_date || "",
    updatedAt: row.updated_at,
    payload: parsePayload(row.payload_json) || {}
  }));
}

export function writeTickerAsset(ticker, asset = {}) {
  const normalized = normalizeTickerKey(ticker || asset.ticker);
  if (!normalized) return;
  db.prepare(`
    INSERT INTO ticker_assets (
      ticker,
      company_name,
      logo_url,
      logo_domain,
      logo_source,
      payload_json,
      updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(ticker) DO UPDATE SET
      company_name = excluded.company_name,
      logo_url = excluded.logo_url,
      logo_domain = excluded.logo_domain,
      logo_source = excluded.logo_source,
      payload_json = excluded.payload_json,
      updated_at = excluded.updated_at
  `).run(
    normalized,
    String(asset.companyName || asset.name || "").trim(),
    String(asset.logoUrl || "").trim(),
    String(asset.logoDomain || "").trim(),
    String(asset.logoSource || "").trim(),
    JSON.stringify(asset.payload || {}),
    asset.updatedAt || new Date().toISOString()
  );
}

export function readTickerAssets(tickers = []) {
  const normalizedTickers = [...new Set(tickers.map(normalizeTickerKey).filter(Boolean))];
  if (!normalizedTickers.length) return [];
  const placeholders = normalizedTickers.map(() => "?").join(", ");
  return db.prepare(`
    SELECT ticker, company_name, logo_url, logo_domain, logo_source, payload_json, updated_at
    FROM ticker_assets
    WHERE ticker IN (${placeholders})
    ORDER BY ticker ASC
  `).all(...normalizedTickers).map((row) => ({
    ticker: row.ticker,
    companyName: row.company_name || "",
    logoUrl: row.logo_url || "",
    logoDomain: row.logo_domain || "",
    logoSource: row.logo_source || "",
    updatedAt: row.updated_at,
    payload: parsePayload(row.payload_json) || {}
  }));
}

export function deleteDividendEventsForTickers(tickers = [], startDate, endDate) {
  const normalizedTickers = [...new Set(tickers.map(normalizeTickerKey).filter(Boolean))];
  if (!normalizedTickers.length || !startDate || !endDate) return 0;
  const placeholders = normalizedTickers.map(() => "?").join(", ");
  const result = db.prepare(`
    DELETE FROM dividend_events
    WHERE ticker IN (${placeholders})
      AND ex_date >= ?
      AND ex_date <= ?
  `).run(...normalizedTickers, startDate, endDate);
  return result.changes || 0;
}

export function writeDividendEvents(events = []) {
  if (!events.length) return 0;
  const statement = db.prepare(`
    INSERT INTO dividend_events (
      ticker,
      company_name,
      ex_date,
      pay_date,
      record_date,
      declaration_date,
      amount,
      currency,
      status,
      source,
      source_label,
      logo_url,
      payload_json,
      updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(ticker, ex_date, source) DO UPDATE SET
      company_name = excluded.company_name,
      pay_date = excluded.pay_date,
      record_date = excluded.record_date,
      declaration_date = excluded.declaration_date,
      amount = excluded.amount,
      currency = excluded.currency,
      status = excluded.status,
      source_label = excluded.source_label,
      logo_url = excluded.logo_url,
      payload_json = excluded.payload_json,
      updated_at = excluded.updated_at
  `);
  const updatedAt = new Date().toISOString();
  let count = 0;
  db.exec("BEGIN");
  try {
    for (const event of events) {
      const ticker = normalizeTickerKey(event.ticker);
      const exDate = String(event.exDate || event.date || "").trim();
      const source = String(event.source || "unknown").trim();
      if (!ticker || !exDate || !source) continue;
      statement.run(
        ticker,
        String(event.companyName || event.name || "").trim(),
        exDate,
        String(event.payDate || "").trim(),
        String(event.recordDate || "").trim(),
        String(event.declarationDate || "").trim(),
        Number.isFinite(Number(event.amount)) ? Number(event.amount) : null,
        String(event.currency || "USD").trim() || "USD",
        String(event.status || "estimated").trim(),
        source,
        String(event.sourceLabel || "").trim(),
        String(event.logoUrl || "").trim(),
        JSON.stringify(event.payload || {}),
        event.updatedAt || updatedAt
      );
      count += 1;
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return count;
}

export function readDividendEvents(tickers = [], startDate, endDate) {
  const normalizedTickers = [...new Set(tickers.map(normalizeTickerKey).filter(Boolean))];
  if (!normalizedTickers.length || !startDate || !endDate) return [];
  const placeholders = normalizedTickers.map(() => "?").join(", ");
  return db.prepare(`
    SELECT
      ticker,
      company_name,
      ex_date,
      pay_date,
      record_date,
      declaration_date,
      amount,
      currency,
      status,
      source,
      source_label,
      logo_url,
      payload_json,
      updated_at
    FROM dividend_events
    WHERE ticker IN (${placeholders})
      AND ex_date >= ?
      AND ex_date <= ?
    ORDER BY ex_date ASC, pay_date ASC, ticker ASC
  `).all(...normalizedTickers, startDate, endDate).map((row) => ({
    ticker: row.ticker,
    companyName: row.company_name || row.ticker,
    name: row.company_name || row.ticker,
    exDate: row.ex_date,
    payDate: row.pay_date || "",
    recordDate: row.record_date || "",
    declarationDate: row.declaration_date || "",
    date: row.ex_date,
    amount: row.amount,
    currency: row.currency || "USD",
    status: row.status || "",
    type: row.status === "paid"
      ? "Paid dividend"
      : row.status === "declared"
        ? "Declared dividend"
        : "Estimated dividend",
    source: row.source || "",
    sourceLabel: row.source_label || "",
    logoUrl: row.logo_url || "",
    updatedAt: row.updated_at,
    payload: parsePayload(row.payload_json) || {}
  }));
}

export function readBackgroundJobRun(jobId) {
  const normalized = String(jobId || "").trim();
  if (!normalized) return null;
  const row = db.prepare(`
    SELECT job_id, started_at, finished_at, status, payload_json
    FROM background_job_runs
    WHERE job_id = ?
  `).get(normalized);
  if (!row) return null;
  return {
    jobId: row.job_id,
    startedAt: row.started_at || "",
    finishedAt: row.finished_at || "",
    status: row.status || "",
    payload: parsePayload(row.payload_json) || {}
  };
}

export function readBackgroundJobRuns() {
  return db.prepare(`
    SELECT job_id, started_at, finished_at, status, payload_json
    FROM background_job_runs
    ORDER BY COALESCE(finished_at, started_at, '') DESC, job_id ASC
  `).all().map((row) => ({
    jobId: row.job_id,
    startedAt: row.started_at || "",
    finishedAt: row.finished_at || "",
    status: row.status || "",
    payload: parsePayload(row.payload_json) || {}
  }));
}

export function writeBackgroundJobRun(jobId, run = {}) {
  const normalized = String(jobId || "").trim();
  if (!normalized) return;
  db.prepare(`
    INSERT INTO background_job_runs (job_id, started_at, finished_at, status, payload_json)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(job_id) DO UPDATE SET
      started_at = excluded.started_at,
      finished_at = excluded.finished_at,
      status = excluded.status,
      payload_json = excluded.payload_json
  `).run(
    normalized,
    String(run.startedAt || "").trim(),
    String(run.finishedAt || "").trim(),
    String(run.status || "").trim(),
    JSON.stringify(run.payload || {})
  );
}

export function readDatabaseTableSummaries() {
  return readDatabaseTableSummariesFrom(db);
}
