import { allocateAtClose, markPositions } from './backtestEngine.js';
import { strategyMetrics } from './strategyLab.js';
import { loadInvestorStyleDashboard } from './investorStyleDashboard.js';
import { queryFactsBatch, factGeneration, PRICE_TYPES } from './factRepository.js';
import { createHash } from 'node:crypto';

export const RULE_ANALYSIS_VERSION = 'rule-range-attribution-v1';
const tolerance = 1e-8;
const sum = rows => rows.reduce((a, b) => a + b, 0);
const fail = (message, status = 503) => { throw Object.assign(new Error(message), { status }); };
const add = (map, key, value) => map.set(key, (map.get(key) ?? 0) + value);
const near = (a, b) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= tolerance * Math.max(1, Math.abs(b));
const symbol = p => p.corporateActionResolution?.considerationType === 'stock'
  ? p.corporateActionResolution.successorTicker : p.ticker;
const cashClaim = p => p.corporateActionResolution?.considerationType === 'cash';
const mark = (p, date) => ({ date, price: p.endPrice, value: p.endValue,
  basis: cashClaim(p) ? 'cash_entitlement' : p.corporateActionResolution ? 'equivalent_source_adjusted_unit' : 'total_return_adjusted_close' });

// Reuse the production allocation/marking engine. Never infer a fill from a
// chart boundary or obtain prices from a new vendor. Each daily net NAV and
// recorded cost must reconcile before any attribution is returned.
export function buildRuleLedger(snapshot, priceMaps, { costBps = 25 } = {}) {
  const curve = snapshot.backtest.curve;
  if (curve.length < 2 || curve.some((r, i) => i && r.date <= curve[i - 1].date)) fail('invalid_rule_curve');
  const styles = snapshot.styles.map(style => {
    const recorded = new Map(style.trades.map(t => [t.date, t]));
    // The newest displayed selection can be unexecuted: its date is the last
    // closing mark of the previous return window, without a new entry cost.
    const rebalances = new Map(style.quarters.filter(q => recorded.has(q.executionDate)).map(q => [q.executionDate, q]));
    if (rebalances.size !== recorded.size) fail('rule_analysis_schedule_mismatch');
    const days = [], events = [], actionsSeen = new Set();
    let active, previousValues = new Map(), previousNav = 1;
    for (const row of curve) {
      const date = row.date, pnl = new Map(), fees = new Map();
      const marked = active ? markPositions(active, date, priceMaps) : { ok: true, values: [], portfolioValue: 1 };
      if (!marked.ok || marked.transitionPending?.length) fail(marked.failure?.code ?? 'unresolved_corporate_action');
      for (const p of marked.values) {
        add(pnl, p.ticker, p.endValue - previousValues.get(p.ticker));
        const action = p.corporateActionResolution;
        if (action && !actionsSeen.has(action.actionId ?? `${p.ticker}:${action.effectiveDate}`)) {
          actionsSeen.add(action.actionId ?? `${p.ticker}:${action.effectiveDate}`);
          events.push({ ticker: p.ticker, date, side: 'corporate_action', ...mark(p, date), action });
        }
      }
      let nav = marked.portfolioValue, closing = marked, trading = null;
      const q = rebalances.get(date);
      if (q) {
        const old = new Map(), target = new Map(q.positions.map(p => [p.ticker, nav * p.weight]));
        for (const p of marked.values) if (!cashClaim(p)) add(old, symbol(p), p.endValue);
        let totalFee = 0, turnover = 0;
        trading = { preTradeNav: nav, buyNotional: 0, sellNotional: 0, initialEntry: days.length === 0 };
        for (const ticker of new Set([...old.keys(), ...target.keys()])) {
          const delta = (target.get(ticker) ?? 0) - (old.get(ticker) ?? 0);
          if (Math.abs(delta) < 1e-13) continue;
          const fee = Math.abs(delta) * costBps / 10000;
          totalFee += fee; turnover += Math.abs(delta) / nav;
          trading[delta > 0 ? 'buyNotional' : 'sellNotional'] += Math.abs(delta);
          const price = priceMaps.get(ticker)?.get(date);
          if (!Number.isFinite(price) || price <= 0) fail('missing_execution_price');
          // Converted claims net against the successor's target. Reductions
          // remain attributed to their source sleeve; they are not fake sales
          // of the delisted security at a made-up historical quote.
          const sources = delta < 0 ? marked.values.filter(p => !cashClaim(p) && symbol(p) === ticker) : [];
          const slices = sources.length ? sources.map(p => ({ ticker: p.ticker, fraction: p.endValue / old.get(ticker) })) : [{ ticker, fraction: 1 }];
          for (const slice of slices) {
            add(fees, slice.ticker, fee * slice.fraction);
            events.push({ ticker: slice.ticker, tradedTicker: ticker, date, side: delta > 0 ? 'buy' : 'sell',
              price, basis: 'total_return_adjusted_close', notional: Math.abs(delta) * slice.fraction, cost: fee * slice.fraction });
          }
        }
        const receipt = recorded.get(date);
        if (!receipt || !near(receipt.turnover, turnover) || !near(receipt.costFraction, totalFee / nav)) {
          throw Object.assign(new Error('rule_analysis_cost_mismatch'), { status: 503,
            diagnostic: { strategy: style.id, date, recorded: receipt, computedTurnover: turnover, computedCostFraction: totalFee / nav } });
        }
        nav -= totalFee;
        const weights = q.positions.map(p => ({ ...p, corporateAction: (style.corporateActions ?? []).find(a => a.ticker === p.ticker && a.executionDate === date) }));
        active = allocateAtClose({ executionDate: date, weights, cashWeight: q.cashWeight }, nav, priceMaps, true);
        if (!active.ok) fail(active.failure.code);
        closing = markPositions(active, date, priceMaps);
        if (!closing.ok) fail(closing.failure.code);
      }
      if (!near(nav, row[style.id]) || !near(closing.portfolioValue, nav) ||
          !near(sum([...pnl.values()]) - sum([...fees.values()]), nav - previousNav)) fail('rule_analysis_nav_mismatch');
      days.push({ date, nav, pnl, fees, trading, positions: new Map(closing.values.map(p => [p.ticker, { ...mark(p, date), open: !cashClaim(p) }])) });
      previousNav = nav;
      previousValues = new Map(closing.values.map(p => [p.ticker, p.endValue]));
    }
    return { id: style.id, days, events };
  });
  return { version: RULE_ANALYSIS_VERSION, snapshotId: snapshot.snapshotId, styles };
}

// Stock-level interval P&L, not a count of daily wins or a fabricated FIFO trade
// ledger. Open holdings are marked, and boundary marks remain separate from
// the actual simulated rebalance events. Values are per unit of starting NAV.
export function analyzeRuleRange(ledger, start, end) {
  const styles = ledger.styles.map(style => {
    const first = style.days.findIndex(r => r.date === start), last = style.days.findIndex(r => r.date === end);
    if (first < 0 || last <= first) fail('invalid_analysis_range', 400);
    const rows = style.days.slice(first, last + 1), origin = first === 0 ? 1 : rows[0].nav;
    const metrics = strategyMetrics(rows.map(r => ({ date: r.date, value: r.nav / origin })));
    // Match the P&L boundary: ordinary start dates are post-trade closing
    // marks. Only the full inception range includes its initial entry.
    const trades = rows.slice(first === 0 ? 0 : 1).flatMap(r => r.trading ? [r.trading] : []);
    const buyRatio = sum(trades.map(t => t.buyNotional / t.preTradeNav));
    const sellRatio = sum(trades.map(t => t.sellNotional / t.preTradeNav));
    const oneWay = (buyRatio + sellRatio) / 2;
    const turnover = { version: 'rule-range-turnover-v1',
      basis: 'half_gross_notional_over_each_pretrade_nav',
      oneWay, twoWay: buyRatio + sellRatio, buyRatio, sellRatio,
      annualizedOneWay: oneWay * 252 / (rows.length - 1), annualizationSessions: 252,
      returnIntervals: rows.length - 1,
      buyNotional: sum(trades.map(t => t.buyNotional)) / origin,
      sellNotional: sum(trades.map(t => t.sellNotional)) / origin,
      executions: trades.filter(t => t.buyNotional + t.sellNotional > 0).length,
      includesInitialEntry: trades.some(t => t.initialEntry),
    };
    const stocks = new Map();
    const get = ticker => {
      if (!stocks.has(ticker)) stocks.set(ticker, { ticker, grossContribution: 0, costContribution: 0 });
      return stocks.get(ticker);
    };
    for (const row of rows.slice(first === 0 ? 0 : 1)) {
      for (const [ticker, value] of row.pnl) if (value !== 0) get(ticker).grossContribution += value / origin;
      for (const [ticker, value] of row.fees) if (value !== 0) get(ticker).costContribution += value / origin;
    }
    // Include flat holdings in the disclosed denominator, but not in wins/losses.
    for (const row of rows) for (const [ticker, p] of row.positions) if (p.open) get(ticker);
    const holdings = [...stocks.values()].map(r => {
      const events = style.events.filter(e => e.ticker === r.ticker && e.date <= end);
      const opening = rows[0].positions.get(r.ticker), closing = rows.at(-1).positions.get(r.ticker);
      const seen = rows.flatMap(row => row.positions.has(r.ticker) ? [row.positions.get(r.ticker)] : []);
      return { ...r, netContribution: r.grossContribution - r.costContribution,
        openAtStart: first > 0 && !!opening?.open, openAtEnd: !!closing?.open,
        openingMark: opening ? { ...opening, value: opening.value / origin } : null,
        closingMark: closing ? { ...closing, value: closing.value / origin } : null,
        firstObserved: seen[0]?.date ?? null, lastObserved: seen.at(-1)?.date ?? null,
        purchases: events.filter(e => e.side === 'buy').map(e => ({ ...e, beforeRange: e.date < start })),
        sales: events.filter(e => e.side === 'sell' && e.date >= start),
        corporateActions: events.filter(e => e.side === 'corporate_action').map(e => ({ ...e.action, observedDate: e.date })),
      };
    }).sort((a, b) => b.netContribution - a.netContribution || a.ticker.localeCompare(b.ticker));
    const winners = holdings.filter(r => r.netContribution > 1e-12), losers = holdings.filter(r => r.netContribution < -1e-12);
    const averageWin = winners.length ? sum(winners.map(r => r.netContribution)) / winners.length : null;
    const averageLoss = losers.length ? -sum(losers.map(r => r.netContribution)) / losers.length : null;
    const net = sum(holdings.map(r => r.netContribution));
    if (!near(net, metrics.totalReturn)) fail('rule_analysis_attribution_mismatch');
    // Common fixed bins for both strategies; percentage points of starting NAV,
    // NOT individual stock returns (which would ignore sizing and rebalances).
    const bounds = [-Infinity, -.1, -.05, -.01, -1e-12, 1e-12, .01, .05, .1, Infinity];
    const distribution = bounds.slice(0, -1).map((lower, i) => ({ lower: Number.isFinite(lower) ? lower : null,
      upper: Number.isFinite(bounds[i + 1]) ? bounds[i + 1] : null,
      count: holdings.filter(r => r.netContribution >= lower && r.netContribution < bounds[i + 1]).length }));
    return { id: style.id, metrics, turnover, holdings, best: winners[0] ?? null, worst: losers.at(-1) ?? null, distribution,
      tradeStats: { population: 'unique_stock_range_pnl_including_open', stocks: holdings.length, wins: winners.length,
        losses: losers.length, flat: holdings.length - winners.length - losers.length,
        open: holdings.filter(r => r.openAtEnd).length, winRate: winners.length + losers.length ? winners.length / (winners.length + losers.length) : null,
        averageWin, averageLoss, payoffRatio: averageWin !== null && averageLoss !== null ? averageWin / averageLoss : null,
        payoffStatus: !winners.length ? 'no_winners' : !losers.length ? 'no_losers' : 'available' },
      reconciliation: { stockPnl: net, grossPnl: sum(holdings.map(r => r.grossContribution)),
        costs: sum(holdings.map(r => r.costContribution)), portfolioReturn: metrics.totalReturn, difference: net - metrics.totalReturn },
    };
  });
  return { version: ledger.version, snapshotId: ledger.snapshotId, start, end, priceBasis: 'total_return_adjusted_close',
    illustrativeCapital: 100000, currency: 'USD', styles };
}

export async function canonicalRulePrices(snapshot) {
  const spans = new Map(), end = snapshot.backtest.curve.at(-1).date;
  function include(ticker, identity, start, stop) {
    const old = spans.get(ticker);
    if (old && old.identity !== identity) fail('rule_analysis_identity_conflict');
    spans.set(ticker, { identity, start: old && old.start < start ? old.start : start, end: old && old.end > stop ? old.end : stop });
  }
  for (const style of snapshot.styles) for (const q of style.quarters) {
    if (q.executionDate > end || !style.trades.some(t => t.date === q.executionDate)) continue;
    for (const p of q.positions) include(p.ticker, `sharadar:security:${p.permaticker}`, q.executionDate, q.nextExecutionDate && q.nextExecutionDate < end ? q.nextExecutionDate : end);
  }
  // Resolve successor identity using the same canonical repository. A ticker
  // alias is never substituted by company name or by a display/logo mapping.
  for (const style of snapshot.styles) for (const a of style.corporateActions ?? []) {
    if (a.considerationType === 'stock' && a.effectiveDate <= end) {
      const old = spans.get(a.successorTicker);
      if (old) include(a.successorTicker, old.identity, a.effectiveDate, end);
      else include(a.successorTicker, a.successorTicker, a.effectiveDate, end);
    }
  }
  const entries = [...spans], maps = new Map();
  // Bound RPC payloads: full provenance stays inside Fact OS, not on the wire
  // to the browser. The outer service also guards a generation change.
  for (let i = 0; i < entries.length; i += 12) {
    const group = entries.slice(i, i + 12);
    const responses = await queryFactsBatch(group.map(([, s]) => ({ method: 'get_price_history',
      args: [s.identity, s.start, s.end, PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE] })));
    responses.forEach((response, j) => {
      if (!response.ok) fail('rule_analysis_prices_unavailable');
      const [ticker, span] = group[j], map = new Map();
      for (const r of response.result) {
        if (r.currency !== 'USD' || r.price_type !== PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE ||
            (span.identity.startsWith('sharadar:') && r.security_id !== span.identity) || map.has(r.date)) fail('rule_analysis_identity_conflict');
        map.set(r.date, r.value);
      }
      maps.set(ticker, map);
    });
  }
  return maps;
}

export function createRuleAnalysisService({ load = loadInvestorStyleDashboard, generation = factGeneration, prices = canonicalRulePrices } = {}) {
  let cache;
  return async ({ asOf, snapshotId, start, end }) => {
    if (!snapshotId || typeof start !== 'string' || typeof end !== 'string') fail('invalid_analysis_range', 400);
    const snapshot = load({ asOf, snapshotId });
    if (snapshot.snapshotId !== snapshotId) fail('investor_style_snapshot_changed', 409);
    if (!snapshot.backtest.curve.some(r => r.date === start) || !snapshot.backtest.curve.some(r => r.date === end) || start >= end) fail('invalid_analysis_range', 400);
    const g = await generation(), key = `${snapshotId}:${asOf}:${g}`;
    if (!cache || cache.key !== key) {
      const promise = (async () => {
        const maps = await prices(snapshot);
        if (await generation() !== g) fail('rule_analysis_generation_changed', 409);
        return buildRuleLedger(snapshot, maps);
      })();
      cache = { key, promise };
      promise.catch(() => { if (cache?.promise === promise) cache = null; });
    }
    const ledger = await cache.promise;
    if (await generation() !== g) fail('rule_analysis_generation_changed', 409);
    return { ...analyzeRuleRange(ledger, start, end), lineage: {
      portfolioSnapshotId: snapshotId, sourceSnapshotGeneration: snapshot.lineage?.sourceGeneration ?? null,
      readerFingerprint: createHash('sha256').update(g).digest('hex'), allDailyNavReconciled: true,
      adjustmentBasis: 'vendor_current_adjustment_factors', method: RULE_ANALYSIS_VERSION,
    } };
  };
}
