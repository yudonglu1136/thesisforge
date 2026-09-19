import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const sandbox = await fs.mkdtemp(path.join(os.tmpdir(), "fact-consumers-test-"));
process.env.SQLITE_DB_PATH = path.join(sandbox, "legacy.sqlite");
process.env.FACT_OS_ENABLED = "1";
process.env.FACT_OS_ROOT = path.join(sandbox, "missing-facts");
process.env.FACT_OS_PYTHON = path.join(sandbox, "not-installed-python");
globalThis.fetch = () => { throw new Error("Network must not be called by canonical readers"); };

const { factOsEnabled, queryFacts, canonicalListingRequest } = await import("./factRepository.js");
const { loadPriceSeries } = await import("./marketData.js");
const { mapFactHolding, mapFactChange, canCompareReportingEntities } = await import("./factGuruAdapter.js");
const { loadDividendCalendarForTickers, refreshDividendCalendarForTickers } = await import("./dividendClient.js");
const { loadGuruBacktest } = await import("./backtest.js");
const { loadGuruDashboard, loadGuruExposureHistory } = await import("./secClient.js");
const { writePriceSeriesToDb } = await import("./localDatabase.js");
const { __portfolioTestInternals } = await import("./portfolioClient.js");

test("canonical mode is explicit and missing runtime never requests provider", async () => {
  assert.equal(factOsEnabled(), true);
  await assert.rejects(queryFacts("get_price", ["MSFT", "2026-09-10", "RAW_CLOSE"]), { code: "local_runtime_unavailable" });
});

test("all prices require explicit basis, and stale SQLite cannot mask absent canonical data", async () => {
  await assert.rejects(loadPriceSeries("MSFT", { start: "2026-09-01", end: "2026-09-10" }), { code: "explicit_price_basis_required" });
  writePriceSeriesToDb("MSFT", [{ date: "2026-09-01", close: 123 }, { date: "2026-09-10", close: 456 }], "yahoo");
  const result = await loadPriceSeries("MSFT", { start: "2026-09-01", end: "2026-09-10", priceType: "RAW_CLOSE" });
  assert.deepEqual(result.points, []);
  assert.equal(result.source, "sharadar_fact_os");
  assert.equal(result.status, "unavailable");
});

test("portfolio canonical reads never strip a foreign listing or infer an ADR from the company name", () => {
  const symbols = __portfolioTestInternals.portfolioPriceSymbols;
  assert.deepEqual(symbols({ ticker: "AZN.L", currency: "USD" }), ["AZN.L"]);
  assert.deepEqual(symbols({ ticker: "LSEG.L", currency: "GBP" }), []);
  assert.deepEqual(symbols({ ticker: "AZN", currency: "GBP" }), []);
  assert.deepEqual(symbols({ ticker: "AZN", currency: "USD", name: "AstraZeneca" }), ["AZN"]);
  assert.deepEqual(symbols({ ticker: "MSFT", currency: "GBP", quoteCurrency: "USD" }), ["MSFT"]);
  assert.equal(canonicalListingRequest({ ticker: "MSFT", baseCurrency: "GBP", currency: "USD" }).unavailable, null);
});

test("portfolio overlay cache separates users, source mode and canonical generations", async () => {
  const keyFor = __portfolioTestInternals.portfolioCacheKey;
  const first = keyFor({ id: "synthetic-user-a" });
  assert.notEqual(first, keyFor({ id: "synthetic-user-b" }));
  const manifestDir = path.join(process.env.FACT_OS_ROOT, "manifests");
  await fs.mkdir(manifestDir, { recursive: true });
  const manifest = path.join(manifestDir, "catalog.json");
  await fs.writeFile(manifest, JSON.stringify({ version: 1, datasets: {} }));
  const second = keyFor({ id: "synthetic-user-a" });
  assert.notEqual(first, second);
  await fs.writeFile(manifest, JSON.stringify({ version: 1, datasets: {}, testGeneration: "next" }));
  assert.notEqual(second, keyFor({ id: "synthetic-user-a" }));
  assert.equal(__portfolioTestInternals.portfolioAnalyticsPriceSource(), "Sharadar Local Fact OS (total-return-adjusted)");
  try {
    process.env.FACT_OS_ENABLED = "0";
    assert.notEqual(second, keyFor({ id: "synthetic-user-a" }));
    assert.equal(__portfolioTestInternals.portfolioAnalyticsPriceSource(), "local SQLite price_points");
  } finally { process.env.FACT_OS_ENABLED = "1"; }
});

test("portfolio valuation projection retains archived model and quote provenance", () => {
  const row = { ticker: "MSFT", currency: "USD", latest: { latestPrice: 10, latestPriceSource: "Sharadar Local Fact OS", baseFairValue: 12,
    publishedModelStatus: "archived_not_recomputed", modelInputPolicy: "Recorded model inputs are archived." } };
  const overlay = __portfolioTestInternals.buildValuationOverlay({ ticker: "MSFT", price: 9 }, row);
  assert.equal(overlay.priceSource, "Sharadar Local Fact OS");
  assert.equal(overlay.publishedModelStatus, "archived_not_recomputed");
  assert.equal(overlay.modelInputPolicy, "Recorded model inputs are archived.");
  assert.equal(overlay.fairValue, 12);
  assert.equal(overlay.latestPrice, 10);
  const missing = __portfolioTestInternals.buildValuationOverlay({ ticker: "MSFT", price: 9 }, { ...row, latest: { ...row.latest, latestPrice: null } });
  assert.equal(missing.priceSource, "broker_reported_mark");
  assert.equal(missing.latestPrice, 9);
});

test("foreign-currency dividends are explicitly missing, never substituted with US ADR dividends", async () => {
  const result = await loadDividendCalendarForTickers([{ ticker: "AZN", currency: "GBP", name: "AstraZeneca" }]);
  assert.deepEqual(result.events, []);
  assert.deepEqual(result.status.unavailable, [{ ticker: "AZN", reason: "unverified_quote_currency" }]);
  const exact = await loadDividendCalendarForTickers(["AZN.L"]);
  assert.equal(exact.status.unavailable[0].ticker, "AZN.L");
});

test("holdings preserve reported units, security type, book weights, and null missing values", () => {
  const row = mapFactHolding({ ticker: "MSFT", security_type: "CALL", units: 5000, value_usd: 250000, rank: 2 }, 1000000);
  assert.equal(row.shares, 5000);
  assert.equal(row.value, 250000);
  assert.equal(row.pctPortfolio, 0.25);
  assert.equal(row.putCall, "CALL");
  assert.equal(mapFactHolding({ ticker: "X", security_type: "SHR", value_usd: null }, 100).pctPortfolio, null);
});

test("quarter changes do not invent filing dates or trade events", () => {
  const row = mapFactChange({ ticker: "MSFT", security_type: "SHR", change: "INCREASED", percentage_change: 25,
    current_units: 125, previous_units: 100, unit_change: 25, current_value_usd: 500, previous_value_usd: 350, quarter: "2026-06-30" }, 1000);
  assert.equal(row.action, "increased");
  assert.equal(row.changePct, 0.25);
  assert.equal(row.filingDate, null);
  assert.equal(row.reportDate, "2026-06-30");
});

test("reporting-entity transition is not classified as new Guru purchases", () => {
  const current = { rows: [{ investor_id: "PERSQ1" }] };
  assert.equal(canCompareReportingEntities(current, { rows: [{ investor_id: "PERSQU" }, { investor_id: "PERSQ1" }] }), false);
  assert.equal(canCompareReportingEntities(current, { rows: [{ investor_id: "PERSQU" }] }), false);
  assert.equal(canCompareReportingEntities(current, { rows: [{ investor_id: "PERSQ1" }] }), true);
});

test("dividend refresh is a local read; no forecast/provider substitution on missing data", async () => {
  for (const read of [loadDividendCalendarForTickers, refreshDividendCalendarForTickers]) {
    const result = await read(["MSFT"], { startDate: "2026-01-01", endDate: "2026-09-10" });
    assert.deepEqual(result.events, []);
    assert.equal(result.status.unavailable.length, 1);
    assert.equal(result.status.source, "sharadar_fact_os");
  }
});

test("SF3 historical replay fails closed before legacy cache or providers are considered", async () => {
  const result = await loadGuruBacktest("bill-ackman", { years: 5 });
  assert.equal(result.status, "pit_unavailable");
  assert.deepEqual(result.series, []);
  assert.equal(result.source, "sharadar_fact_os");
});

test("Guru dashboard and exposure do not reuse bundled SEC snapshots when canonical runtime is missing", async () => {
  const dashboard = await loadGuruDashboard({ forceRefresh: true });
  assert.ok(dashboard.gurus.length > 0);
  assert.equal(dashboard.cache.source, "sharadar_fact_os");
  assert.ok(dashboard.gurus.every((g) => g.holdings.length === 0));
  assert.ok(dashboard.gurus.every((g) => g.simulationTag.tone !== "simulatable"));
  const manager = dashboard.gurus.find((g) => g.type === "manager13f");
  assert.equal(manager.simulationTag.label, "Disclosure timing unavailable");
  assert.match(manager.simulationTag.description, /actual filing availability dates/);
  const exposure = await loadGuruExposureHistory("bill-ackman", { forceRefresh: true });
  assert.deepEqual(exposure.history, []);
  assert.equal(exposure.source.label, "Sharadar local Fact OS");
});
