// Run under an OS network-denial sandbox. Tests the real local application
// adapters; broker/user databases are never opened. Models come from the bundled
// public model archive in a disposable SQLite fixture, not a private account.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { parseArgs } from "node:util";

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = path.resolve(process.env.FACT_OS_ROOT || path.join(project, "data/fact_os"));
const { values } = parseArgs({ options: { output: { type: "string" } } });
// Each run records new evidence; wx below never replaces a previous report.
const destination = values.output
  ? path.resolve(project, values.output)
  : path.join(root, "audit/consumer-offline-smoke.json");
const python = path.join(project, ".venv-fact-os/bin/python");
const temp = await fs.mkdtemp(path.join(os.tmpdir(), "fact-consumer-smoke-"));
process.env.FACT_OS_ENABLED = "1";
process.env.FACT_OS_ROOT = root;
process.env.FACT_OS_PYTHON = python;
process.env.SQLITE_DB_PATH = path.join(temp, "public-model-fixture.sqlite");
for (const name of ["GURU_BACKTESTS", "GURU_EXPOSURE_SNAPSHOTS", "DIVIDEND_CALENDAR", "PODCAST_INSIGHTS"]) {
  process.env[`SYNC_BUNDLED_${name}`] = "false";
}
let fetchAttempts = 0;
globalThis.fetch = () => { fetchAttempts += 1; throw new Error("Network disabled for the consumer smoke test"); };
const probe = spawnSync(python, ["-c", "import socket\ntry:\n socket.socket().connect(('127.0.0.1',9))\nexcept PermissionError:\n print('OS_NETWORK_DENIED')\nexcept Exception:\n print('NETWORK_NOT_PROVEN_DISABLED')"], {
  cwd: project, encoding: "utf8", env: { PATH: process.env.PATH || "/usr/bin:/bin" }
});
assert.equal(probe.stdout.trim(), "OS_NETWORK_DENIED", "Run this command under an OS network-denial sandbox; fetch interception alone is insufficient.");

const { loadPriceSeries } = await import("../server/marketData.js");
const { loadValuationTicker } = await import("../server/valuationClient.js");
const { readValuationTickerSnapshot } = await import("../server/localDatabase.js");
const { PRICE_TYPES } = await import("../server/factRepository.js");
const cutoff = new Date().toISOString().slice(0, 10);
const output = { generatedAt: new Date().toISOString(), cutoff,
  scope: "Local application adapters; no private portfolio data; archived published models not recomputed",
  network: { osDeniesParentAndPythonSockets: true, pythonProbe: probe.stdout.trim(), fetchAttempts: 0 },
  prices: [], valuations: [] };
for (const ticker of ["NVDA", "MSFT", "SPY", "QQQ", "SCHD", "KMLM"]) {
  const bases = ["NVDA", "MSFT"].includes(ticker) ? Object.values(PRICE_TYPES) : [PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE];
  for (const basis of bases) {
    const started = performance.now();
    const result = await loadPriceSeries(ticker, { start: "1900-01-01", end: cutoff, priceType: basis });
    assert.equal(result.status, "available", `${ticker}: ${result.error || result.message}`);
    assert.equal(result.source, "sharadar_fact_os");
    assert.ok(result.points.length > 0);
    assert.ok(result.points.every(point => point.date <= cutoff && point.priceType === basis && point.provenance?.source === "Sharadar"));
    const table = ["NVDA", "MSFT"].includes(ticker) ? "stocks" : "funds";
    assert.ok(result.points.every(point => point.provenance.table === table), "Official master must select the correct table");
    output.prices.push({ ticker, priceType: basis, table, source: result.source, rows: result.points.length,
      firstDate: result.points[0].date, lastDate: result.points.at(-1).date, latencyMs: Math.round(performance.now() - started) });
  }
}
for (const ticker of ["MSFT", "AVGO"]) {
  const archived = readValuationTickerSnapshot(ticker);
  const started = performance.now();
  const { ticker: result } = await loadValuationTicker(ticker);
  const facts = result.currentFinancials;
  assert.equal(facts.source, "Sharadar Local Fact OS");
  assert.equal(facts.status, "available");
  assert.equal(result.priceSource.status, "available");
  assert.equal(result.latest.publishedModelStatus, "archived_not_recomputed");
  assert.equal(result.latest.baseFairValue, archived.latest.baseFairValue, "Migration must not recalculate archived valuation");
  assert.equal(facts.trailingTwelveMonths.dimension, "ART");
  assert.equal(facts.trailingTwelveMonths.provenance.source, "Sharadar");
  assert.ok(facts.display.revenueM > 0);
  output.valuations.push({ ticker, source: facts.source, financialStatus: facts.status,
    priceSource: result.priceSource.source, priceType: result.priceSource.priceType,
    latestPriceDate: result.latest.latestPriceDate, quarterlyRows: result.financialHistory.quarterly.length,
    trailingRows: result.financialHistory.trailingTwelveMonths.length, dimension: facts.display.dimension,
    periodEnd: facts.display.periodEnd, availableAt: facts.display.availableAt, quarterlyPeriodEnd: facts.display.quarterlyPeriodEnd,
    currency: facts.display.currency, revenueM: facts.display.revenueM,
    revenueGrowth: facts.display.quarterlyRevenueGrowthRatio, cashFlowBasis: facts.display.cashFlowBasis,
    financialSourceTable: facts.trailingTwelveMonths.provenance.table,
    publishedModelStatus: result.latest.publishedModelStatus, archivedFairValueUnchanged: true,
    latencyMs: Math.round(performance.now() - started) });
}
assert.equal(fetchAttempts, 0);
output.network.fetchAttempts = fetchAttempts;
output.passed = true;
await fs.mkdir(path.dirname(destination), { recursive: true });
await fs.writeFile(destination, JSON.stringify(output, null, 2) + "\n", { flag: "wx" });
console.log(JSON.stringify({ destination, ...output }, null, 2));
