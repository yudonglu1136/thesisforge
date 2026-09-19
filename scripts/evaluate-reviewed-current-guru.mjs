import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { buildGuruCurrentEconomicValuation } from "../server/guruCurrentEconomicValuation.js";
import { auditGuruCurrentEconomicValuation } from "../server/guruCurrentEconomicValuationAudit.js";

const [sourcePath, fxPath] = process.argv.slice(2);
if (!sourcePath || !fxPath) throw new Error("Usage: node scripts/evaluate-reviewed-current-guru.mjs <candidate-source.sqlite> <current-ecb-reference-fx.json>");
const db = new DatabaseSync(sourcePath, { readOnly: true });
try {
  const fxRecords = JSON.parse(readFileSync(fxPath, "utf8")).rates;
  for (const ticker of ["IOT", "SPOT"]) {
    const row = db.prepare("SELECT payload_json FROM pit_financial_periods WHERE ticker=? AND dimension='ART' ORDER BY available_at DESC LIMIT 1").get(ticker);
    if (!row) throw new Error(`${ticker}: no ART input`);
    const result = buildGuruCurrentEconomicValuation({ ticker, asOfDate: "2026-09-05", financial: JSON.parse(row.payload_json), fxRecords });
    const audit = auditGuruCurrentEconomicValuation(result);
    console.log(JSON.stringify({ result, audit }));
    if (!audit.ok) process.exitCode = 2;
  }
} finally { db.close(); }
