import { inspectDatabaseHealthIndexes, valuationHealthSourceDate } from "./databaseHealthIndexes.js";

const tableSummarySpecs = [
  { table: "dashboard_snapshots", label: "Guru dashboard", latest: "generated_at" },
  {
    table: "guru_snapshots",
    label: "Guru snapshots",
    latest: "generated_at",
    sourceDate: `COALESCE(
      NULLIF(json_extract(payload_json, '$.latestFiling.filingDate'), ''),
      NULLIF(json_extract(payload_json, '$.summary.filingDate'), '')
    )`
  },
  { table: "guru_exposure_snapshots", label: "Guru exposure snapshots", latest: "generated_at" },
  { table: "guru_assets", label: "Guru avatars", latest: "generated_at" },
  {
    table: "guru_backtests",
    label: "Guru backtests",
    latest: "generated_at",
    sourceDate: "end_date",
    maxDate: "end_date"
  },
  {
    table: "guru_backtest_proxies",
    label: "Guru public-holdings proxies",
    latest: "generated_at",
    sourceDate: "end_date",
    maxDate: "end_date"
  },
  { table: "valuation_snapshots", label: "Valuation dashboard", latest: "generated_at" },
  {
    table: "valuation_ticker_snapshots",
    label: "Valuation tickers",
    latest: "generated_at",
    sourceDate: valuationHealthSourceDate
  },
  { table: "valuation_podcast_insights", label: "Podcast insights", latest: "generated_at", maxDate: "observed_at" },
  {
    table: "price_points",
    label: "Market prices",
    latest: "updated_at",
    sourceDate: "date",
    maxDate: "date"
  },
  { table: "portfolio_nav_points", label: "Local NAV history", latest: "updated_at", maxDate: "date" },
  { table: "ticker_assets", label: "Ticker logos", latest: "updated_at" },
  { table: "dividend_events", label: "Dividend calendar", latest: "updated_at", minDate: "ex_date", maxDate: "ex_date" },
  { table: "background_job_runs", label: "Background jobs", latest: "finished_at" }
];

export function readDatabaseTableSummariesFrom(db) {
  // A combined COUNT/MAX aggregate forces scans of large JSON blobs and every
  // price row. Independent scalar aggregates can use SQLite's exact MIN/MAX
  // index seeks. No cached counts/dates, sampling, or weaker freshness checks.
  // Older databases keep their existing query until the operator installs the
  // optional indexes; request handling never creates or changes a schema.
  let indexedTables;
  try {
    const indexes = inspectDatabaseHealthIndexes(db);
    indexedTables = new Set(["valuation_ticker_snapshots", "price_points"].filter((table) =>
      indexes.filter((index) => index.table === table).every((index) => index.state === "ready")
    ));
  } catch { indexedTables = new Set(); }
  return tableSummarySpecs.map((spec) => {
    const selects = [
      "COUNT(*) AS row_count",
      spec.latest ? `MAX(${spec.latest}) AS latest_at` : "NULL AS latest_at",
      spec.sourceDate ? `MAX(${spec.sourceDate}) AS source_at` : "NULL AS source_at",
      spec.minDate ? `MIN(${spec.minDate}) AS min_date` : "NULL AS min_date",
      spec.maxDate ? `MAX(${spec.maxDate}) AS max_date` : "NULL AS max_date"
    ];
    try {
      const sql = indexedTables.has(spec.table)
        ? `SELECT ${selects.map((select) => {
          const [expression, alias] = select.split(/ AS /);
          return expression === "NULL" ? select : `(SELECT ${expression} FROM ${spec.table}) AS ${alias}`;
        }).join(", ")}`
        : `SELECT ${selects.join(", ")} FROM ${spec.table}`;
      const row = db.prepare(sql).get();
      return {
        table: spec.table,
        label: spec.label,
        rowCount: Number(row?.row_count) || 0,
        latestAt: row?.latest_at || "",
        sourceAt: row?.source_at || "",
        minDate: row?.min_date || "",
        maxDate: row?.max_date || "",
        status: "ok"
      };
    } catch (error) {
      return {
        table: spec.table,
        label: spec.label,
        rowCount: 0,
        latestAt: "",
        sourceAt: "",
        minDate: "",
        maxDate: "",
        status: "error",
        message: error.message
      };
    }
  });
}
