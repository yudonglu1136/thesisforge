import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { valuationMarketPriceSymbol } from "../server/tickerAliases.js";
import { valuationComparisonPriceContract, comparisonPricesEqual, mergeValuationComparisonHistory } from "../server/valuationComparisonPrice.js";

export function inventoryComparisonConflicts(db) {
  const query = db.prepare("SELECT * FROM price_points WHERE symbol=? AND close>0 ORDER BY date DESC LIMIT 10000");
  const conflicts = [], unverified = [], invalid = [], mergeFailures = [];
  let snapshotPoints = 0, rawPoints = 0, snapshots = 0;
  for (const { ticker, payload_json } of db.prepare("SELECT ticker,payload_json FROM valuation_ticker_snapshots ORDER BY ticker").iterate()) {
    const snapshot = JSON.parse(payload_json), symbol = valuationMarketPriceSymbol(ticker);
    snapshots++;
    const raw = query.all(symbol);
    try {
      mergeValuationComparisonHistory({ existing: snapshot.priceHistory || [], incremental: raw,
        priceSymbol: symbol, quoteCurrency: snapshot.currency, allowYahooClose: true });
    } catch (error) { mergeFailures.push({ ticker, reason: error.message }); }
    const byDate = new Map();
    for (const [kind, rows] of [["released_snapshot", snapshot.priceHistory || []], ["raw_price_point", raw]]) {
      for (const [index, row] of rows.entries()) {
        if (kind === "released_snapshot") snapshotPoints++; else rawPoints++;
        const contract = valuationComparisonPriceContract(row.source);
        if (!contract) { unverified.push({ ticker, symbol, kind, date: row.date, source: row.source }); continue; }
        if (!(Number.isFinite(row.close) && row.close > 0) || !/^\d{4}-\d{2}-\d{2}$/.test(row.date || "") || !Number.isFinite(Date.parse(row.date))) {
          invalid.push({ ticker, symbol, kind, date: row.date }); continue;
        }
        if (!byDate.has(row.date)) byDate.set(row.date, []);
        byDate.get(row.date).push({ point: { kind, index, ...row }, contract });
      }
    }
    for (const [date, rows] of byDate) {
      const preferred = rows.some((row) => row.contract.provider === "sharadar") ? "sharadar" : "yahoo";
      for (let i = 0; i < rows.length; i++) for (let j = i + 1; j < rows.length; j++) {
        const a = rows[i], b = rows[j];
        if (a.contract.provider === b.contract.provider && a.contract.field === b.contract.field && a.contract.basis === b.contract.basis && !comparisonPricesEqual(a.point.close, b.point.close)) {
          conflicts.push({ ticker, priceSymbol: symbol, quoteCurrency: snapshot.currency, date,
            provider: a.contract.provider, importBlocking: a.contract.provider === preferred, left: a.point, right: b.point });
        }
      }
    }
  }
  return { readOnly: true, rawSelection: "Exact importer close>0, latest 10000 per price symbol; non-positive raw points excluded without mutation",
    summary: { snapshots, snapshotPoints, rawPoints, conflicts: conflicts.length,
      blocking: conflicts.filter((c) => c.importBlocking).length, tickers: new Set(conflicts.map((c) => c.ticker)).size,
      byProvider: Object.fromEntries(["sharadar", "yahoo"].map((p) => [p, conflicts.filter((c) => c.provider === p).length])),
      unverified: unverified.length, invalid: invalid.length, actualMergeFailures: mergeFailures.length }, conflicts, unverified, invalid, mergeFailures };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const [source, output] = process.argv.slice(2);
  if (!source || !output || fs.existsSync(output)) throw new Error("Explicit source and NEW report required");
  const db = new DatabaseSync(path.resolve(source), { readOnly: true });
  try {
    const result = { source: path.resolve(source), ...inventoryComparisonConflicts(db) };
    fs.writeFileSync(output, JSON.stringify(result, null, 2) + "\n", { flag: "wx" });
    console.log(JSON.stringify({ output, ...result.summary }, null, 2));
  } finally { db.close(); }
}
