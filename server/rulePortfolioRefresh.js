import { simulateDriftedPortfolio } from './backtestEngine.js';
import { applyStrategyCosts, strategyMetrics } from './strategyLab.js';
import { buildRuleLedger } from './rulePortfolioAnalysis.js';
import { validateInvestorStyleDashboard } from './investorStyleDashboard.js';

// Extend the last selected quarter through observed sessions. A return window
// need not be a completed quarter. Never invent the next quarter's selection.
export function refreshRuleSnapshot(source, priceMaps, end) {
  validateInvestorStyleDashboard(source);
  const dates = [...(priceMaps.get('SPY')?.keys() ?? [])].filter(d => d <= end).sort();
  if (dates.at(-1) !== end || end <= source.backtest.from) throw new Error('unobserved_refresh_end');
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
    const gross = simulateDriftedPortfolio({ rebalances: schedule, tradingDates: dates,
      priceMaps, benchmarkSymbol: 'SPY', endDate: end, allowExplicitCash: true });
    if (!gross.ok || gross.equity.at(-1)?.date !== end) throw new Error(`refresh_price_or_action_gap:${JSON.stringify(gross.failure)}`);
    const net = applyStrategyCosts(gross, schedule, 25);
    curves[style.id] = net.equity.map((r,i) => ({ ...r, benchmark: gross.equity[i].benchmark }));
    const years = (Date.parse(end) - Date.parse(net.equity[0].date)) / (86400000 * 365.25);
    style.trades = net.trades;
    style.metrics = { ...strategyMetrics(net.equity), observations: net.equity.length,
      costBps: 25, completedQuarters: style.quarters.filter(r => r.nextExecutionDate && r.nextExecutionDate <= end).length,
      annualizedGrossTradedNotional: net.trades.reduce((n,r) => n + r.turnover, 0) / years };
    style.quarters.forEach(r => { r.mature = !!r.nextExecutionDate && r.nextExecutionDate <= end; });
    const compounded = gross.quarterContributions.reduce((v,r,i) => v * (1+r.portfolioReturn) * (1-net.trades[i].costFraction), 1);
    if (Math.abs(compounded-net.equity.at(-1).value)>1e-9) throw new Error('refresh_quarterly_reconciliation_failed');
    style.reconciliation = { ...gross.reconciliation, quarterlyDailyError: compounded-net.equity.at(-1).value };
  }
  const a=curves.quality_rank,b=curves.ackman;
  if (a.length !== b.length || a.some((r,i) => r.date !== b[i].date || Math.abs(r.benchmark-b[i].benchmark)>1e-9)) throw new Error('refresh_unaligned_curves');
  result.backtest = { ...source.backtest, from:a[0].date, to:end, observations:a.length,
    curve:a.map((r,i)=>({date:r.date,quality_rank:r.value,ackman:b[i].value,spy:r.benchmark})) };
  result.dataThrough = end;
  // Previously observed history is immutable except an old terminal mark that
  // now has its first actual rebalance cost when the partial quarter executes.
  const original = new Map(source.backtest.curve.map(r=>[r.date,r]));
  for (const r of result.backtest.curve) if (r.date < source.dataThrough && original.has(r.date)) {
    for (const id of ['quality_rank','ackman','spy']) if (Math.abs(r[id]-original.get(r.date)[id])>1e-8) throw new Error('refresh_changed_historical_nav');
  }
  validateInvestorStyleDashboard(result);
  buildRuleLedger(result,priceMaps); // Every net daily mark, turnover and fee.
  return result;
}
