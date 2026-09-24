// Allocation only: ranking inputs never include subsequent returns or price coverage.
export function qualityRankWeights(rows) {
  const ranks = new Set(), tickers = new Set();
  for (const row of rows) {
    if (!Number.isInteger(row.rank) || row.rank < 1 || !/^[A-Z0-9.-]+$/.test(row.ticker) ||
        ranks.has(row.rank) || tickers.has(row.ticker)) throw new Error('invalid_quality_rank');
    ranks.add(row.rank); tickers.add(row.ticker);
  }
  const selected = rows.filter(r => r.rank <= 10).sort((a, b) => a.rank - b.rank);
  const sum = selected.reduce((total, row) => total + Math.sqrt(11 - row.rank), 0);
  const positions = selected.map(row => ({ ...row, conviction: Math.sqrt(11 - row.rank),
    weight: Math.min(.15, Math.sqrt(11 - row.rank) / sum) }));
  return { positions, cashWeight: Math.max(0, 1 - positions.reduce((total, row) => total + row.weight, 0)) };
}
