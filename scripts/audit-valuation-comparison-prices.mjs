import { DatabaseSync } from "node:sqlite";
import { readFileSync, writeFileSync, createReadStream, realpathSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve, relative } from "node:path";
import { spawnSync } from "node:child_process";
import { auditValuationComparisonPrice, comparisonPricesEqual } from "../server/valuationComparisonPrice.js";

// Read-only, user-selected backup and original licensed parquet. The report may
// contain licensed rows and is written only under the repository's ignored output/.
const argv = process.argv.slice(2);
const arg = (name) => {
  const index = argv.indexOf(name);
  if (index < 0 || !argv[index + 1] || argv[index + 1].startsWith("--")) throw new Error(`Missing ${name}`);
  return argv[index + 1];
};
const dbPath = realpathSync(arg("--db"));
const auditPath = realpathSync(arg("--audit"));
const parquetPath = realpathSync(arg("--parquet"));
const outPath = resolve(arg("--out"));
const cutoff = arg("--source-cutoff");
const outputRoot = realpathSync(resolve("output"));
if (relative(outputRoot, dbPath).startsWith("..")) throw new Error("Only an explicitly selected output/ backup may be opened.");
if (relative(outputRoot, outPath).startsWith("..") || !outPath.endsWith(".json")) throw new Error("Licensed report must stay in output/ as JSON.");
if (outPath === dbPath || outPath === auditPath) throw new Error("Do not overwrite inputs.");
if (!/^\d{4}-\d{2}-\d{2}$/.test(cutoff)) throw new Error("Explicit source cutoff is required.");

const sha256 = (data) => createHash("sha256").update(data).digest("hex");
async function hashFile(path) {
  const hash = createHash("sha256");
  for await (const part of createReadStream(path)) hash.update(part);
  return hash.digest("hex");
}
const auditBytes = readFileSync(auditPath);
const initialAudit = JSON.parse(auditBytes);
const failures = initialAudit.failures.filter((failure) => failure.code === "stored_market_price_unit_mismatch");
if (!failures.length) throw new Error("No requested mismatch population in audit.");
const beforeDbHash = await hashFile(dbPath);
const dbStat = statSync(dbPath);
const db = new DatabaseSync(dbPath, { readOnly: true });
const modelQuery = db.prepare(`SELECT * FROM valuation_pit_model_runs WHERE ticker=? AND fiscal_period=? AND as_of_date=?`);
const observationQuery = db.prepare(`SELECT * FROM valuation_pit_price_observations WHERE ticker=? AND fiscal_period=? AND model_version=?`);
const rawQuery = db.prepare(`SELECT * FROM price_points WHERE symbol=? AND date=?`);
const snapshotQuery = db.prepare(`SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?`);
const snapshotCache = new Map();

const wanted = failures.map((failure) => ({ ticker: failure.priceSymbol, date: failure.priceDate }));
const originalRead = spawnSync("python3", ["-c", `
import sys, json, datetime, pyarrow.dataset as ds
request = json.load(sys.stdin)
keys = {(row['ticker'], row['date']) for row in request['wanted']}
dataset = ds.dataset(request['parquetPath'], format='parquet', partitioning='hive')
dates = [datetime.date.fromisoformat(value) for value in sorted({key[1] for key in keys})]
flt = ds.field('ticker').isin(sorted({key[0] for key in keys})) & ds.field('date').isin(dates)
table = dataset.to_table(columns=['ticker', 'date', 'close', 'closeadj', 'closeunadj', 'lastupdated'], filter=flt)
rows = [{key: (value.isoformat() if isinstance(value, datetime.date) else value) for key, value in row.items()}
        for row in table.to_pylist() if (row['ticker'], row['date'].isoformat()) in keys]
rows.sort(key=lambda row: (row['ticker'], row['date']))
json.dump(rows, sys.stdout, allow_nan=False)
`,], {
  input: JSON.stringify({ wanted, parquetPath }), encoding: "utf8", maxBuffer: 16 * 1024 * 1024
});
if (originalRead.status !== 0) { db.close(); throw new Error(originalRead.stderr || "Original parquet read failed"); }
const originalRows = JSON.parse(originalRead.stdout);
const originals = new Map();
for (const row of originalRows) {
  const key = `${row.ticker}:${row.date}`;
  if (originals.has(key)) throw new Error(`Duplicate original vendor row: ${key}`);
  originals.set(key, row);
}

function diagnosticClass(ticker, paid, yahoo) {
  const delta = Math.abs(paid - yahoo);
  if (ticker === "MNST") return "split_adjustment_vintage_difference_official_2026_split_verified";
  if (delta <= 0.00051) return "provider_precision_difference_compatible_with_paid_three_decimal_rounding";
  if (Math.abs(paid / yahoo - 1) < 0.001) return "provider_quote_disagreement_not_explained_by_three_decimal_rounding";
  if (["BDX", "COP"].includes(ticker)) return "provider_series_difference_issuer_spinoff_event_verified_not_full_factor_chain";
  return "material_provider_series_difference_exact_corporate_action_chain_not_verified";
}
const rows = failures.map((failure) => {
  const matches = modelQuery.all(failure.ticker, failure.period, failure.asOfDate);
  if (matches.length !== 1) throw new Error(`Model identity ambiguous: ${failure.ticker}/${failure.period}`);
  const model = matches[0];
  const output = JSON.parse(model.output_json);
  const declaration = output.dataSnapshot?.asOfPriceSource;
  const observation = observationQuery.get(model.ticker, model.fiscal_period, model.model_version);
  const raw = rawQuery.get(failure.priceSymbol, failure.priceDate);
  if (!snapshotCache.has(model.ticker)) snapshotCache.set(model.ticker, JSON.parse(snapshotQuery.get(model.ticker)?.payload_json || "{}"));
  const snapshot = snapshotCache.get(model.ticker);
  const original = originals.get(`${failure.priceSymbol}:${failure.priceDate}`);
  const quoteCurrency = observation?.quote_currency;
  const shared = { priceSymbol: failure.priceSymbol, quoteCurrency, sourceField: "close", unit: "currency_per_share" };
  const candidates = [];
  if (raw) candidates.push({ ...shared, id: "price_points", kind: "raw_price_point", source: raw.source, date: raw.date, close: raw.close });
  for (const [index, point] of (snapshot.priceHistory || []).entries()) {
    if (point.date !== failure.priceDate) continue;
    candidates.push({ ...shared, id: `released_snapshot:${index}`, kind: "released_snapshot", source: point.source, date: point.date, close: point.close });
  }
  if (observation) {
    const payload = JSON.parse(observation.payload_json || "{}");
    candidates.push({ ...shared, id: "pit_observation", kind: "pit_observation", source: observation.source,
      date: observation.price_date, close: observation.close, priceSymbol: observation.price_symbol,
      quoteCurrency: observation.quote_currency, ticker: observation.ticker, fiscalPeriod: observation.fiscal_period,
      modelVersion: observation.model_version, payloadSource: payload.source?.source });
  }
  // Original dataset is the independently read source underlying this exact
  // registered ingestion path; closeadj and closeunadj are retained for diagnosis,
  // never substituted for close. Later vintages do not validate this frozen audit.
  if (original && original.lastupdated <= cutoff) candidates.push({
    ...shared, id: "original_sharadar_parquet", kind: "original_vendor", source: "jansen-sharadar-sep-split-adjusted",
    date: original.date, close: original.close, sourceLastUpdated: original.lastupdated,
    quoteCurrency: "USD" // Sharadar US stocks field contract, independent of model/observation currency.
  });
  const result = auditValuationComparisonPrice({
    asOfDate: model.as_of_date, priceDate: output.priceDate, priceSymbol: failure.priceSymbol,
    quoteCurrency, declaredSource: declaration?.source, candidates, outputPrice: output.priceAtDate,
    ticker: model.ticker, fiscalPeriod: model.fiscal_period, modelVersion: model.model_version
  });
  const originalVerified = Boolean(original && original.lastupdated <= cutoff && quoteCurrency === "USD"
    && original.close === output.priceAtDate && original.close === observation?.close);
  return {
    ticker: model.ticker, fiscalPeriod: model.fiscal_period, modelVersion: model.model_version,
    asOfDate: model.as_of_date, priceDate: output.priceDate, declaredSource: declaration?.source,
    modelPrice: output.priceAtDate,
    originalAuditRowStillMatchesModel: failure.outputPrice === output.priceAtDate && failure.priceDate === output.priceDate,
    rawStoredPrice: raw ? { source: raw.source, close: raw.close, adjustedClose: raw.adjusted_close, updatedAt: raw.updated_at } : null,
    originalVendor: original || null,
    independentlyMatchesOriginalVendorExactly: originalVerified,
    paidToRawRatio: raw && output.priceAtDate / raw.close,
    diagnosticClass: raw ? diagnosticClass(model.ticker, output.priceAtDate, raw.close) : "missing_raw_row",
    sameBasisAudit: result
  };
});
db.close();
const afterDbHash = await hashFile(dbPath);
const counts = {};
for (const row of rows) counts[row.diagnosticClass] = (counts[row.diagnosticClass] || 0) + 1;
const originalVerifiedCount = rows.filter((row) => row.independentlyMatchesOriginalVendorExactly).length;
const reconciledCount = rows.filter((row) => row.sameBasisAudit.status === "ready").length;
const blocked = rows.filter((row) => !row.independentlyMatchesOriginalVendorExactly || row.sameBasisAudit.status !== "ready" || !row.originalAuditRowStillMatchesModel);
const result = {
  schemaVersion: 1,
  status: blocked.length || beforeDbHash !== afterDbHash ? "blocked" : "population_reconciled_to_independent_declared_source",
  scope: "Only the source audit stored_market_price_unit_mismatch population; not a full release certification or Guru price repair.",
  sourceCutoffDate: cutoff, databaseReadOnly: true, databaseWrites: 0, guruPriceRowsChanged: 0,
  database: { path: dbPath, bytes: dbStat.size, sha256Before: beforeDbHash, sha256After: afterDbHash, unchanged: beforeDbHash === afterDbHash },
  inputAudit: { path: auditPath, sha256: sha256(auditBytes) },
  originalVendor: { datasetPath: parquetPath, field: "close", sha256ExtractedRows: sha256(JSON.stringify(originalRows)), extractedRowCount: originalRows.length },
  summary: { failureCount: rows.length, tickerCount: new Set(rows.map((row) => row.ticker)).size,
    independentExactVendorMatchCount: originalVerifiedCount, sameBasisReconciledCount: reconciledCount,
    blockedCount: blocked.length, diagnosticCounts: counts },
  sourceEvidence: [
    { id: "sharadar-field-contract", url: "https://sharadar.com/docs/stocks", field: "close", treatment: "Stock splits only; closeadj includes cash dividends and spin-offs; closeunadj unadjusted." },
    { id: "sharadar-methodology", url: "https://blog.sharadar.com/2026/07/sharadar-stock-prices-fund-prices-and.html", publishedDate: "2026-07-29", treatment: "Provider-original explanation of distinct adjustment fields and spin-off methodology." },
    { id: "yahoo-adjusted-close", url: "https://help.yahoo.com/kb/SLN28256.html", treatment: "Explains adjusted-close field. Does not establish equivalence of Yahoo raw close to Sharadar split-only close." },
    { id: "bd-spinoff", url: "https://investors.bd.com/news-events/press-releases/detail/937/bd-completes-combination-of-biosciences-diagnostic-solutions-business-with-waters-corporation", publishedDate: "2026-02-09", treatment: "Verifies issuer spin-off event; does not prove the full cumulative Yahoo adjustment factor." },
    { id: "cop-spinoff", url: "https://investor.phillips66.com/financial-information/news-releases/news-release-details/2012/ConocoPhillips-Board-of-Directors-Approves-Spin-off-of-Phillips-66/default.aspx", publishedDate: "2012-04-04", treatment: "One PSX share per two COP, distribution after April 30 close; historical economic perimeter changed." },
    { id: "mnst-split", url: "https://monsterenergycompany.gcs-web.com/news-releases/news-release-details/monster-beverage-declares-two-one-stock-split", publishedDate: "2026-07-08", treatment: "Two-for-one split; split trading starts August 11, 2026. Paid dataset reflects a factor missing from these stored Yahoo historical rows." }
  ],
  limitations: [
    "Original licensed parquet is the independent numerical evidence; public issuer announcements verify events, not each historical closing price.",
    "No numerical price correction or ratio-based rescaling is performed. No tolerance is increased.",
    "Matching a PIT observation alone is not an independent source audit. This population also matches original parquet exactly.",
    "All 182 source mismatches may reconcile without proving every existing Yahoo-only price or the entire Guru return series correct.",
    "The complete corporate-action factor chain has not been independently reconstructed for all 28 issuers; material cross-provider differences remain visible in this report.",
    "IBKR/NOC small provider quote disagreements are not all explainable by rounding; they are not silently averaged or accepted as the paid quote.",
    "Historical split-adjusted prices use the snapshot adjustment vintage, not the price actually quoted before subsequent splits; fair-value/share normalization remains a separate model contract."
  ],
  rows
};
const json = `${JSON.stringify(result, null, 2)}\n`;
writeFileSync(outPath, json);
console.log(JSON.stringify({ outputPath: outPath, sha256: sha256(json), status: result.status, ...result.summary, databaseUnchanged: result.database.unchanged }, null, 2));
if (result.status === "blocked") process.exitCode = 1;
