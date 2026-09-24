import { simulateDriftedPortfolio } from './backtestEngine.js';
import { applyStrategyCosts, strategyMetrics } from './strategyLab.js';
import { buildRuleLedger } from './rulePortfolioAnalysis.js';
import { validateInvestorStyleDashboard } from './investorStyleDashboard.js';
import { ruleSegments, emptyRuleMetrics } from './rulePortfolioCoverage.js';

// Extend the last selected quarter through observed sessions. A return window
// need not be a completed quarter. Never invent the next quarter's selection.
export function refreshRuleSnapshot(source, priceMaps, end) {
  validateInvestorStyleDashboard(source);
  const dates = [...(priceMaps.get('SPY')?.keys() ?? [])].filter(d => d <= end).sort();
  if (dates.at(-1) !== end || end < source.dataThrough || end <= source.backtest.from) throw new Error('unobserved_refresh_end');
  const result = structuredClone(source), curves = {};
  delete result.snapshotId; delete result.requestedAsOf; delete result.status;
  for (const style of result.styles) {
    const latest = style.quarters.at(-1), q = new Date(`${latest.quarter}T00:00:00Z`);
    const nextQuarterEnd = new Date(Date.UTC(q.getUTCFullYear(), q.getUTCMonth() + 4, 0)).toISOString().slice(0,10);
    if (end > nextQuarterEnd) throw new Error('new_quarter_selection_required');
    const schedule = style.quarters.filter(r => r.executionDate < end).map(r => ({
      reportDate: r.quarter, signalDate: r.signalDate, executionDate: r.executionDate,
      nextExecutionDate: r.nextExecutionDate, cashWeight: r.cashWeight,
      targetWeights: r.positions,
      weights: r.positions.map(p => ({ ...p, corporateAction: style.corporateActions.find(a =>
        a.ticker === p.ticker && a.executionDate === r.executionDate) })),
      ...(r.positions.length ? {} : { cashReason: 'strategy_rules' }),
    }));
    const segments = ruleSegments(style, source.backtest.curve).map((s,i,list) =>
      ({ ...s, to: i === list.length-1 ? end : s.to }));
    const results = segments.map(segment => {
      const rebalances = schedule.filter(r => r.executionDate >= segment.from && r.executionDate < segment.to);
      const gross = simulateDriftedPortfolio({ rebalances,
        tradingDates: dates.filter(d => d >= segment.from && d <= segment.to),
        priceMaps, benchmarkSymbol: 'SPY', endDate: segment.to, allowExplicitCash: true });
      if (!gross.ok || gross.equity.at(-1)?.date !== segment.to) throw new Error(`refresh_price_or_action_gap:${JSON.stringify(gross.failure)}`);
      const net = applyStrategyCosts(gross, rebalances, 25);
      const compounded = gross.quarterContributions.reduce((v,r,i) => v * (1+r.portfolioReturn) * (1-net.trades[i].costFraction), 1);
      if (Math.abs(compounded-net.equity.at(-1).value)>1e-9) throw new Error('refresh_quarterly_reconciliation_failed');
      return { segment, gross, net, compounded };
    });
    curves[style.id] = results.flatMap(r => r.net.equity);
    const full = results.length === 1, years = (Date.parse(end) - Date.parse(segments[0].from)) / (86400000 * 365.25);
    if (style.coverage) style.coverage.segments = segments;
    style.trades = results.flatMap(r => r.net.trades);
    style.quarters.forEach(r => { r.mature = !!r.nextExecutionDate &&
      segments.some(s => s.from <= r.executionDate && s.to >= r.nextExecutionDate); });
    style.metrics = { ...(full ? strategyMetrics(curves[style.id]) : emptyRuleMetrics()), observations: curves[style.id].length,
      costBps: 25, completedQuarters: style.quarters.filter(r => r.mature).length,
      annualizedGrossTradedNotional: full ? style.trades.reduce((n,r) => n+r.turnover,0)/years : null };
    style.reconciliation = { segments:results.map(r => ({...r.segment,...r.gross.reconciliation,
      quarterlyDailyError:r.compounded-r.net.equity.at(-1).value})) };
  }
  const observed = dates.filter(d => d >= source.backtest.from);
  const byStyle = Object.fromEntries(Object.entries(curves).map(([id,rows]) => [id,new Map(rows.map(r => [r.date,r.value]))]));
  const spy = priceMaps.get('SPY'), base = spy.get(observed[0]);
  result.backtest = { ...source.backtest, to:end, observations:observed.length,
    curve:observed.map(date => ({date,quality_rank:byStyle.quality_rank.get(date)??null,
      ackman:byStyle.ackman.get(date)??null,spy:spy.get(date)/base})) };
  result.dataThrough = end;
  // Previously observed history is immutable except an old terminal mark that
  // now has its first actual rebalance cost when the partial quarter executes.
  const original = new Map(source.backtest.curve.map(r=>[r.date,r]));
  for (const r of result.backtest.curve) if (r.date < source.dataThrough && original.has(r.date)) {
    for (const id of ['quality_rank','ackman','spy']) {
      const previous = original.get(r.date)[id];
      if ((r[id]===null)!==(previous===null) || (r[id]!==null && Math.abs(r[id]-previous)>1e-8)) throw new Error('refresh_changed_historical_nav');
    }
  }
  validateInvestorStyleDashboard(result);
  buildRuleLedger(result,priceMaps); // Every net daily mark, turnover and fee.
  return result;
}
