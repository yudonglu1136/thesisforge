// Existing audited ticker aliases are consumed here, never copied into another
// security master. Ambiguous mappings are not guessed.
export function observationAliases(source) {
  if(!source.publicFactsDb)return new Map();
  if(!source.db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='valuation_pit_financials'").get())return new Map();
  const rows=source.db.prepare(`SELECT ticker,MIN(source_ticker) sourceTicker
    FROM valuation_pit_financials WHERE source_ticker IS NOT NULL
    GROUP BY ticker HAVING COUNT(DISTINCT source_ticker)=1`).all();
  return new Map(rows.map(row=>[row.ticker,row.sourceTicker]));
}
