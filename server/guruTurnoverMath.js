import assert from 'node:assert/strict';

const sum = a => a.reduce((s, x) => s + x, 0);
const mean = a => sum(a) / a.length;
const yearsBetween = (a, b) => (Date.parse(b) - Date.parse(a)) / 86400000 / 365.25;
const sd = a => Math.sqrt(sum(a.map(x => (x - mean(a)) ** 2)) / (a.length - 1));
const finite = x => typeof x === 'number' && Number.isFinite(x);
const near = (a, b, label, tolerance = 1e-8) => assert(Math.abs(a - b) <= tolerance, `${label}: ${a} vs ${b}`);
const cash = '__CASH__';

export function performance(equity, field = 'value', rf = 0) {
  assert(equity.length > 2);
  const returns = equity.slice(1).map((e, i) => e[field] / equity[i][field] - 1);
  assert(returns.every(finite));
  const sigma = sd(returns), riskFreeDaily = (1 + rf) ** (1 / 252) - 1;
  let peak = equity[0][field], maxDrawdown = 0;
  for (const e of equity) { peak = Math.max(peak, e[field]); maxDrawdown = Math.min(maxDrawdown, e[field] / peak - 1); }
  return { cagr: (equity.at(-1)[field] / equity[0][field]) ** (1 / yearsBetween(equity[0].date, equity.at(-1).date)) - 1, sharpe: sigma ? (mean(returns) - riskFreeDaily) / sigma * Math.sqrt(252) : null, volatility: sigma * Math.sqrt(252), maxDrawdown, observations: equity.length };
}
// The end map describes economic assets after price drift and audited corporate
// actions, not old nominal tickers: forced cash/stock conversions are not trades.
export function weights(q, ending = false) {
  const m = new Map(); let total = 0;
  for (const c of q.contributions) {
    const w = ending ? c.endingWeight : c.weight;
    assert(finite(w) && w >= -1e-10, 'Invalid contribution weight');
    let key = c.ticker;
    if (ending && c.corporateActionResolution?.timing === 'while_position_active') {
      const action = c.corporateActionResolution;
      if (action.considerationType === 'cash') key = cash;
      else if (action.considerationType === 'stock') key = action.successorTicker;
      else if (action.considerationType === 'stock_and_cash') {
        const stockFrac = (action.successorPrice * action.successorSharesPerShare) / c.endPrice;
        assert(finite(stockFrac) && stockFrac >= 0 && stockFrac <= 1, 'Invalid mixed consideration fraction');
        assert(action.successorTicker, 'Missing successor identity');
        m.set(action.successorTicker, (m.get(action.successorTicker) ?? 0) + w * stockFrac);
        m.set(cash, (m.get(cash) ?? 0) + w * (1 - stockFrac));
        total += w;
        continue;
      }
    }
    assert(key, 'Missing security identity');
    m.set(key, (m.get(key) ?? 0) + w); total += w;
  }
  assert(total <= 1 + 1e-8, 'Weights exceed NAV');
  if (!ending) near(total + q.cashWeight, 1, 'Complete starting book');
  m.set(cash, (m.get(cash) ?? 0) + Math.max(0, 1 - total));
  near(sum([...m.values()]), 1, 'Weight reconciliation');
  return m;
}
export function turnover(before, after) {
  const names = [...new Set([...before.keys(), ...after.keys()])];
  const changes = names.map(k => ({ k, delta: (after.get(k) ?? 0) - (before.get(k) ?? 0) }));
  const buy = sum(changes.filter(c => c.k !== cash && c.delta > 0).map(c => c.delta));
  const sell = -sum(changes.filter(c => c.k !== cash && c.delta < 0).map(c => c.delta));
  return { oneWay: .5 * sum(changes.map(c => Math.abs(c.delta))), securityMin: Math.min(buy, sell), twoWayTraded: buy + sell, buy, sell };
}
export function auditPayload(p) {
  assert(p.equity.length > 2 && p.quarterContributions.length > 1);
  assert.equal(p.equity[0].date, p.window.start);
  assert.equal(p.equity.at(-1).date, p.window.end);
  p.equity.forEach((e, i) => { assert(e.value > 0 && finite(e.value) && e.benchmark > 0 && finite(e.benchmark)); if (i) assert(e.date > p.equity[i - 1].date); });
  const recalculated = performance(p.equity);
  near(recalculated.cagr, p.summary.cagr, 'Stored CAGR');
  near(recalculated.sharpe, p.summary.sharpe, 'Stored Sharpe', 1e-7);
  near(p.dataQuality.attributionReconciliation.difference, 0, 'Total attribution');
  const dates = new Map(p.equity.map(e => [e.date, e]));
  const trades = [];
  for (let i = 0; i < p.quarterContributions.length; i++) {
    const q = p.quarterContributions[i], prev = p.quarterContributions[i - 1];
    // SEC administrative filingDate may be Monday for a Friday acceptance.
    // Match the engine's acceptance-time precedence, using filingDate only
    // for genuinely legacy records without the public acceptance timestamp.
    const publicDate = q.acceptanceDateTime?.slice(0, 10) || q.filingDate;
    assert(publicDate && q.executionDate > publicDate, 'Pre-disclosure execution');
    near(q.attributionReconciliation, 0, 'Quarter attribution');
    near(dates.get(q.endDate).value / dates.get(q.executionDate).value - 1, q.portfolioReturn, 'Quarter vs daily equity');
    weights(q); weights(q, true);
    if (prev) {
      assert.equal(prev.endDate, q.executionDate); assert.equal(prev.nextExecutionDate, q.executionDate);
      trades.push({ date: q.executionDate, reportDate: q.reportDate, ...turnover(weights(prev, true), weights(q)) });
    }
  }
  return trades;
}
export function measure(entry, start, end, commonDates = null) {
  const equity = entry.p.equity.filter(e => e.date >= start && e.date <= end && (!commonDates || commonDates.has(e.date)));
  assert.equal(equity[0].date, start); assert.equal(equity.at(-1).date, end);
  const trades = entry.trades.filter(t => t.date > start && t.date <= end);
  const elapsedYears = yearsBetween(start, end), b = performance(equity, 'benchmark');
  return { id: entry.g.id, name: entry.g.name, basis: entry.p.status === 'ready' ? 'strict' : 'proxy', start, end, years: elapsedYears, ...performance(equity), sharpeRf4: performance(equity, 'value', .04).sharpe, benchmarkCagr: b.cagr, benchmarkSharpe: b.sharpe, annualTurnover: sum(trades.map(t => t.oneWay)) / elapsedYears, annualSecurityMinTurnover: sum(trades.map(t => t.securityMin)) / elapsedYears, annualTwoWayTraded: sum(trades.map(t => t.twoWayTraded)) / elapsedYears, rebalanceCount: trades.length, latestRebalanceTurnover: trades.at(-1)?.oneWay ?? null, averagePositions: entry.p.summary.averagePositions, minimumCoverage: Math.min(...entry.p.rebalances.map(r => r.coveragePct)), averageSelectedFractionOfCommonBook: mean(entry.p.rebalances.filter(r => r.commonLongValue > 0).map(r => r.selectedValue / r.commonLongValue)), sourceGeneratedAt: entry.p.generatedAt };
}
