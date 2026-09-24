import { loadInvestorStyleDashboard } from '../server/investorStyleDashboard.js';
import { createRuleAnalysisService } from '../server/rulePortfolioAnalysis.js';
import { EventEmitter } from 'node:events';
import { dataReleaseMiddleware } from '../server/dataReleaseContext.js';
import assert from 'node:assert/strict';

// Read-only canonical replay; emits only aggregate diagnostics, never licensed
// price rows. Run on an installed API host as its actual runtime user as well.
async function verify() {
const snapshot = loadInvestorStyleDashboard();
const run = createRuleAnalysisService(), curve = snapshot.backtest.curve;
const windows = [[0, curve.length - 1], [Math.floor(curve.length / 2), curve.length - 1], [100, 200], [0, 1]];
for (const year of [2013, 2014]) {
  const first=curve.findIndex(r=>r.date.startsWith(`${year}-`));
  const last=curve.findLastIndex(r=>r.date.startsWith(`${year}-`));
  assert.ok(first>=0 && last>first, `missing required ${year} history`);
  windows.push([first,last]);
}
const results = [];
for (const [first, last] of windows) {
  const t = performance.now();
  const result = await run({ snapshotId: snapshot.snapshotId, asOf: snapshot.dataThrough, start: curve[first].date, end: curve[last].date });
  for (const style of result.styles) {
    const source=snapshot.styles.find(s => s.id === style.id);
    const segment=source.coverage?.segments.find(s=>s.from<=result.start && s.to>=result.end);
    if (source.coverage && !segment) {
      assert.equal(style.status,'coverage_gap');
      assert.equal(style.metrics.totalReturn,null); assert.equal(style.turnover,null);
      assert.deepEqual(style.distribution,[]);
      continue;
    }
    assert.notEqual(style.status,'coverage_gap');
    const receipts = source.trades.filter(t =>
      (first === 0 || segment?.from===result.start ? t.date >= result.start : t.date > result.start) && t.date <= result.end);
    const expected = receipts.reduce((sum, t) => sum + t.turnover / 2, 0);
    assert.ok(Math.abs(style.turnover.oneWay - expected) < 1e-9, `${style.id}: turnover receipt mismatch`);
    assert.ok(Math.abs(style.turnover.annualizedOneWay - expected * 252 / (last - first)) < 1e-9);
    assert.equal(style.distribution.reduce((sum, bin) => sum + bin.count, 0), style.tradeStats.stocks);
  }
  results.push({ start: result.start, end: result.end, milliseconds: Math.round(performance.now() - t),
    bytes: Buffer.byteLength(JSON.stringify(result)), styles: result.styles.map(s => ({ id: s.id, metrics: s.metrics,
      status:s.status??'available', stocks: s.tradeStats?.stocks, winRate: s.tradeStats?.winRate, payoffRatio: s.tradeStats?.payoffRatio,
      turnover: s.turnover, distribution: s.distribution,
      best: s.best?.ticker, worst: s.worst?.ticker, reconciliation: s.reconciliation })) });
}
console.log(JSON.stringify({ status: 'pass', snapshotId: snapshot.snapshotId, method: 'rule-range-attribution-v1',
  observedThrough: snapshot.dataThrough, results }, null, 2));
}

// Pin the installed publication just as an API request does. Merely inheriting
// environment variables omits the production request-scoped canonical root.
await new Promise((resolve, reject) => {
  const response = new EventEmitter();
  response.setHeader = () => {};
  response.status = () => response;
  response.json = body => reject(new Error(body.error));
  dataReleaseMiddleware({}, response, () => {
    verify().then(resolve, reject).finally(() => response.emit('finish'));
  });
});
