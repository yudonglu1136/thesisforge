import { loadInvestorStyleDashboard } from '../server/investorStyleDashboard.js';
import { createRuleAnalysisService } from '../server/rulePortfolioAnalysis.js';
import { EventEmitter } from 'node:events';
import { dataReleaseMiddleware } from '../server/dataReleaseContext.js';

// Read-only canonical replay; emits only aggregate diagnostics, never licensed
// price rows. Run on an installed API host as its actual runtime user as well.
async function verify() {
const snapshot = loadInvestorStyleDashboard();
const run = createRuleAnalysisService(), curve = snapshot.backtest.curve;
const windows = [[0, curve.length - 1], [Math.floor(curve.length / 2), curve.length - 1], [100, 200], [0, 1]];
const results = [];
for (const [first, last] of windows) {
  const t = performance.now();
  const result = await run({ snapshotId: snapshot.snapshotId, asOf: snapshot.dataThrough, start: curve[first].date, end: curve[last].date });
  results.push({ start: result.start, end: result.end, milliseconds: Math.round(performance.now() - t),
    bytes: Buffer.byteLength(JSON.stringify(result)), styles: result.styles.map(s => ({ id: s.id, metrics: s.metrics,
      stocks: s.tradeStats.stocks, winRate: s.tradeStats.winRate, payoffRatio: s.tradeStats.payoffRatio,
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
