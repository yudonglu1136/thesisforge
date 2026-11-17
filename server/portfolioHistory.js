import crypto from 'node:crypto';
import {brokerIncome, brokerExpiredShortCalls, portfolioIncome, portfolioPassiveIncome} from './portfolioIncome.js';

const number = v => v == null || v === '' || typeof v === 'boolean' ? null : Number.isFinite(Number(v)) ? Number(v) : null;
const date = v => {
  const s = String(v ?? '').split(';')[0].replace(/^(\d{4})(\d{2})(\d{2})$/, '$1-$2-$3');
  return /^\d{4}-\d{2}-\d{2}$/.test(s) && Number.isFinite(Date.parse(s)) && new Date(s).toISOString().slice(0, 10) === s ? s : null;
};
const hash = v => crypto.createHash('sha256').update(v).digest('hex');
const cashTypes = new Set(['Deposits/Withdrawals', 'Internal Cash Transfer', 'Internal Cash Transfers']);
const incomeTypes = new Set(['Dividends', 'Payment In Lieu Of Dividends', 'Withholding Tax', 'Other Fees',
  'Broker Interest Paid', 'Broker Interest Received', 'Bond Interest Paid', 'Bond Interest Received',
  'Commission Adjustments', 'Sales Tax', 'Transaction Fees', 'Advisor Fees']);

// Retain the full report period, including explicit empty sections. Missing
// sections are not zero. Trade-level MTM is NOT an open-position daily MTM.
export function brokerStatementHistory(statement, currency, rows) {
  const fromDate = date(statement.fromDate), toDate = date(statement.toDate);
  const trades = rows(statement, 'Trade'), cash = rows(statement, 'CashTransaction');
  const validPeriod = fromDate && toDate && fromDate <= toDate;
  const fx = r => number(r.fxRateToBase) ?? (r.currency === currency ? 1 : null);
  const realized = trades.map(r => ({eventKey: hash(String(r.tradeID ?? '')), date: date(r.tradeDate),
    ticker: String(r.symbol ?? ''), name: String(r.description ?? r.symbol ?? ''),
    assetCategory: String(r.assetCategory ?? ''), pnl: number(r.fifoPnlRealized) !== null && fx(r) > 0 ? number(r.fifoPnlRealized) * fx(r) : null}));
  const tradeStatus = !rows(statement, 'Trades').length ? 'trades_section_missing' :
    !validPeriod || trades.some((r, i) => !r.tradeID || !realized[i].date || realized[i].date < fromDate || realized[i].date > toDate || realized[i].pnl === null) ||
    new Set(realized.map(r => r.eventKey)).size !== realized.length ? 'trade_rows_need_review' : 'ready';
  const cashFlows = cash.filter(r => cashTypes.has(r.type)).map((r, i) => ({
    eventKey: hash(JSON.stringify([i, r.dateTime, r.type, r.amount, r.currency])),
    date: date(r.dateTime), type: r.type, amount: number(r.amount) !== null && fx(r) > 0 ? number(r.amount) * fx(r) : null,
  }));
  const cashStatus = !rows(statement, 'CashTransactions').length ? 'cash_section_missing' :
    !validPeriod || cash.some(r => !cashTypes.has(r.type) && !incomeTypes.has(r.type)) ||
    cashFlows.some(r => !r.date || r.date < fromDate || r.date > toDate || r.amount === null) ? 'cash_rows_need_review' : 'ready';
  return {fromDate, toDate, tradeStatus, cashStatus,
    ...brokerIncome(statement, currency, rows),
    ...brokerExpiredShortCalls(statement, currency, rows),
    realized: tradeStatus === 'ready' ? realized : [],
    cashFlows: cashStatus === 'ready' ? cashFlows : [],
    // This adapter does not reconcile asset transfers, corporate actions or
    // broker TWR. Cash-adjusted NAV is explicitly an estimate, never audited P&L.
    performanceBasis: 'reported_fifo_realized_and_cash_adjusted_nav_estimate'};
}

export function portfolioHistory(accounts, nav) {
  const histories = accounts.map(a => a.historyEvidence);
  const covered = histories.length && histories.every(h => h?.fromDate && h?.toDate);
  const fromDate = covered ? histories.map(h => h.fromDate).sort().at(-1) : null;
  const toDate = covered ? histories.map(h => h.toDate).sort()[0] : null;
  const realizedReady = covered && fromDate <= toDate && histories.every(h => h.tradeStatus === 'ready');
  const realizedEvents = realizedReady ? histories.flatMap(h => h.realized).filter(r => r.date >= fromDate && r.date <= toDate) : [];
  const byDate = new Map(), byInstrument = new Map();
  for (const r of realizedEvents) {
    byDate.set(r.date, (byDate.get(r.date) ?? 0) + r.pnl);
    const key = `${r.ticker}:${r.assetCategory}`;
    byInstrument.set(key, {...r, pnl: (byInstrument.get(key)?.pnl ?? 0) + r.pnl});
  }
  // Include trade dates even when a broker NAV observation is absent.
  const realizedDates = [...new Set([...nav.map(r => r.date), ...byDate.keys(), fromDate, toDate])]
    .filter(d => d && d >= fromDate && d <= toDate).sort();
  let cumulative = 0;
  const realizedRows = realizedReady ? realizedDates.map(d => ({date: d, pnl: byDate.get(d) ?? 0, cumulativePnl: cumulative += byDate.get(d) ?? 0})) : [];
  const eligibleNav = nav.filter(r => r.date >= fromDate && r.date <= toDate);
  const cashReady = covered && eligibleNav.length >= 2 && histories.every(h => h.cashStatus === 'ready');
  const flows = cashReady ? histories.flatMap(h => h.cashFlows) : [];
  let estimate = 0;
  const cashAdjustedRows = cashReady ? eligibleNav.map((r, i) => {
    const previous = eligibleNav[i - 1];
    const netFlow = previous ? flows.filter(f => f.date > previous.date && f.date <= r.date).reduce((n, f) => n + f.amount, 0) : 0;
    const navChange = previous ? r.nav - previous.nav : 0;
    const pnl = navChange - netFlow;
    return {date: r.date, previousDate: previous?.date ?? null, pnl, cumulativePnl: estimate += pnl, netFlow, navChange};
  }) : [];
  return {
    income: portfolioIncome(accounts),
    passiveIncome: portfolioPassiveIncome(accounts),
    realized: {status: realizedReady ? 'ready' : 'trade_history_required', fromDate, toDate,
      total: realizedReady ? cumulative : null, tradeCount: realizedEvents.length, rows: realizedRows,
      byInstrument: [...byInstrument.values()].map(({eventKey, ...r}) => r).sort((a, b) => b.pnl - a.pnl),
      basis: 'broker_fifo_realized_pnl_converted_at_report_trade_fx_not_total_return'},
    cashAdjusted: {status: cashReady ? 'estimate' : 'cash_history_required',
      fromDate: cashAdjustedRows[0]?.date ?? null, toDate: cashAdjustedRows.at(-1)?.date ?? null,
      total: cashReady ? estimate : null, rows: cashAdjustedRows,
      basis: 'nav_change_less_reported_cash_transfers_not_verified_total_pnl',
      limitations: ['Security transfers and broker TWR are not reconciled. Do not interpret this estimate as verified investment performance.',
        'Each change covers the interval since the previous reported NAV; no missing observations are forward-filled.']},
  };
}
