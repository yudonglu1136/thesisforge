import { allocateAtClose, markPositions } from './backtestEngine.js';
import { strategyMetrics } from './strategyLab.js';
import { loadInvestorStyleDashboard } from './investorStyleDashboard.js';
import { queryFacts, factGeneration, PRICE_TYPES } from './factRepository.js';
import { createHash } from 'node:crypto';
import { emptyRuleMetrics } from './rulePortfolioCoverage.js';
import { ruleTradeIntervals } from './ruleTradeIntervals.js';

export const RULE_ANALYSIS_VERSION = 'rule-range-attribution-v2';
const tolerance = 1e-8;
const sum = rows => rows.reduce((a, b) => a + b, 0);
const fail = (message, status = 503) => { throw Object.assign(new Error(message), { status }); };
const add = (map, key, value) => map.set(key, (map.get(key) ?? 0) + value);
const near = (a, b) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= tolerance * Math.max(1, Math.abs(b));
const symbol = p => ['stock','stock_and_cash'].includes(p.corporateActionResolution?.considerationType)
  ? p.corporateActionResolution.successorTicker : p.ticker;
const cashClaim = p => p.corporateActionResolution?.considerationType === 'cash';
const tradedValue = p => p.corporateActionResolution?.considerationType === 'stock_and_cash'
  ? p.units * p.corporateActionResolution.successorSharesPerShare * p.corporateActionResolution.successorPrice : p.endValue;
const mark = (p, date) => ({ date, price: p.endPrice, value: p.endValue,
  basis: cashClaim(p) ? 'cash_entitlement' : p.corporateActionResolution ? 'equivalent_source_adjusted_unit' : 'total_return_adjusted_close' });

// Reuse the production allocation/marking engine. Never infer a fill from a
// chart boundary or obtain prices from a new vendor. Each daily net NAV and
// recorded cost must reconcile before any attribution is returned.
export function buildRuleLedger(snapshot, priceMaps, { costBps = 25 } = {}) {
  const curve = snapshot.backtest.curve;
  if (!curve.length || curve.some((r, i) => i && r.date <= curve[i - 1].date)) fail('invalid_rule_curve');
  const styles = snapshot.styles.map(style => {
    if (style.coverage) {
      const segments=style.coverage.segments.map(segment=>{
        const partial={...style,quarters:style.quarters.filter(q=>q.executionDate>=segment.from && q.executionDate<=segment.to),
          trades:style.trades.filter(t=>t.date>=segment.from && t.date<=segment.to)};
        delete partial.coverage;
        return {...buildRuleLedger({...snapshot,styles:[partial],backtest:{curve:curve.filter(r=>r.date>=segment.from && r.date<=segment.to)}},priceMaps,{costBps}).styles[0],...segment};
      });
      return {id:style.id,segments,coverage:style.coverage};
    }
    const recorded = new Map(style.trades.map(t => [t.date, t]));
    // The newest displayed selection can be unexecuted: its date is the last
    // closing mark of the previous return window, without a new entry cost.
    const rebalances = new Map(style.quarters.filter(q => recorded.has(q.executionDate)).map(q => [q.executionDate, q]));
    if (rebalances.size !== recorded.size) fail('rule_analysis_schedule_mismatch');
    const days = [], events = [], actionsSeen = new Set();
    // Do not invent broker lots across an exchange or cash entitlement. These
    // retain the existing audited action attribution, explicitly unpaired.
    const unpairedTickers = new Set((style.corporateActions ?? []).flatMap(a => [a.ticker, a.successorTicker].filter(Boolean)));
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
        const eventStart = events.length;
        const old = new Map(), target = new Map(q.positions.map(p => [p.ticker, nav * p.weight]));
        for (const p of marked.values) if (!cashClaim(p)) add(old, symbol(p), tradedValue(p));
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
          const slices = sources.length ? sources.map(p => ({ ticker: p.ticker, fraction: tradedValue(p) / old.get(ticker) })) : [{ ticker, fraction: 1 }];
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
        const before = new Map(marked.values.map(p => [p.ticker, p]));
        const after = new Map(closing.values.map(p => [p.ticker, p]));
        const targets = new Map(events.slice(eventStart).map(e => [e.ticker, e]));
        const corrected = events.slice(eventStart).filter(e => unpairedTickers.has(e.ticker));
        for (const ticker of new Set([...before.keys(), ...after.keys()])) {
          if (unpairedTickers.has(ticker)) continue;
          const price = priceMaps.get(ticker)?.get(date);
          if (!Number.isFinite(price) || price <= 0) fail('missing_execution_price');
          const quantityBefore = (before.get(ticker)?.endValue ?? 0) / price;
          const quantityAfter = (after.get(ticker)?.endValue ?? 0) / price;
          const delta = quantityAfter - quantityBefore;
          const cost = fees.get(ticker) ?? 0;
          if (Math.abs(delta) < 1e-15 && !cost) continue;
          const targetEvent = targets.get(ticker);
          corrected.push({ ticker, tradedTicker: ticker, date,
            side: Math.abs(delta) < 1e-15 ? 'fee' : delta > 0 ? 'buy' : 'sell',
            price, basis: 'total_return_adjusted_close', quantity: Math.abs(delta), quantityBefore, quantityAfter,
            notional: Math.abs(delta) * price, cost,
            preCostTargetNotional: targetEvent?.notional ?? 0,
            costBasis: 'historical_pre_cost_target_turnover',
            quantityBasis: 'post_cost_simulated_position',
            reason: targetEvent ? 'rebalance' : 'cost_reallocation' });
        }
        events.splice(eventStart, events.length - eventStart, ...corrected);
      }
      if (!near(nav, row[style.id]) || !near(closing.portfolioValue, nav) ||
          !near(sum([...pnl.values()]) - sum([...fees.values()]), nav - previousNav)) fail('rule_analysis_nav_mismatch');
      days.push({ date, nav, pnl, fees, trading, positions: new Map(closing.values.map(p => [p.ticker, { ...mark(p, date), open: !cashClaim(p) }])) });
      previousNav = nav;
      previousValues = new Map(closing.values.map(p => [p.ticker, p.endValue]));
    }
    return { id: style.id, days, events, unpairedTickers: [...unpairedTickers] };
  });
  return { version: RULE_ANALYSIS_VERSION, snapshotId: snapshot.snapshotId, styles };
}

// Stock-level interval P&L, not a count of daily wins or a fabricated FIFO trade
// ledger. Open holdings are marked, and boundary marks remain separate from
// the actual simulated rebalance events. Values are per unit of starting NAV.
export function analyzeRuleRange(ledger, start, end) {
  const styles = ledger.styles.map(style => {
    if (style.segments) {
      const segment=style.segments.find(s=>s.from<=start && s.to>=end);
      if (!segment) return {id:style.id,status:'coverage_gap',coverage:style.coverage,
        metrics:emptyRuleMetrics(),turnover:null,tradeStats:null,holdings:[],distribution:[],best:null,worst:null};
      return {...analyzeRuleRange({...ledger,styles:[segment]},start,end).styles[0],status:'available',segment:{from:segment.from,to:segment.to}};
    }
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
      const lotAnalysis = ruleTradeIntervals({ events: events.filter(e => e.side !== 'corporate_action'), start, end,
        opening, closing, inception: first === 0, origin, gross: r.grossContribution, costs: r.costContribution,
        supported: !(style.unpairedTickers ?? []).includes(r.ticker) });
      const scaledEvent = e => ({ ...e, notional: e.notional / origin, cost: e.cost / origin,
        ...(e.quantity == null ? {} : { quantity: e.quantity / origin, quantityBefore: e.quantityBefore / origin,
          quantityAfter: e.quantityAfter / origin, preCostTargetNotional: e.preCostTargetNotional / origin }) });
      return { ...r, netContribution: r.grossContribution - r.costContribution,
        lotAnalysis,
        openAtStart: first > 0 && !!opening?.open, openAtEnd: !!closing?.open,
        openingMark: opening ? { ...opening, value: opening.value / origin } : null,
        closingMark: closing ? { ...closing, value: closing.value / origin } : null,
        firstObserved: seen[0]?.date ?? null, lastObserved: seen.at(-1)?.date ?? null,
        purchases: events.filter(e => e.side === 'buy').map(e => ({ ...scaledEvent(e), beforeRange: first > 0 && e.date <= start })),
        sales: events.filter(e => e.side === 'sell' && (first === 0 ? e.date >= start : e.date > start)).map(scaledEvent),
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

export async function canonicalRulePrices(snapshot, { query = queryFacts } = {}) {
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
    if (['stock','stock_and_cash'].includes(a.considerationType) && a.effectiveDate <= end) {
      const old = spans.get(a.successorTicker);
      if (old) include(a.successorTicker, old.identity, a.effectiveDate, end);
      else include(a.successorTicker, a.successorTicker, a.effectiveDate, end);
    }
  }
  const entries = [...spans], maps = new Map();
  // One pinned batch, not hundreds of full Parquet scans and repeated daily
  // provenance payloads. Full facts remain addressable by generation/table/key.
  const response = await query('get_price_histories', [entries.map(([, s]) =>
    ({ ticker: s.identity, start: s.start, end: s.end })), PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE]);
  if (response.version !== 'canonical-price-histories-v1' || !response.generation ||
      JSON.stringify(response.columns) !== JSON.stringify(['date', 'value', 'source_ticker']) ||
      response.series?.length !== entries.length) fail('rule_analysis_prices_unavailable');
  for (const [j, r] of response.series.entries()) {
    const [ticker, span] = entries[j], map = new Map();
    if (r.requested !== span.identity || r.currency !== 'USD' || r.price_type !== PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE ||
        r.start !== span.start || r.end !== span.end ||
        (span.identity.startsWith('sharadar:') && r.security_id !== span.identity)) fail('rule_analysis_identity_conflict');
    for (const [date, value, sourceTicker] of r.points) {
      if (date < span.start || date > span.end || !Number.isFinite(value) || value <= 0 ||
          !r.aliases.includes(sourceTicker) || map.has(date)) fail('rule_analysis_identity_conflict');
      map.set(date, value);
    }
    maps.set(ticker, map);
  }
  return maps;
}

export function createRuleAnalysisService({ load = loadInvestorStyleDashboard, generation = factGeneration, prices = canonicalRulePrices } = {}) {
  let cache;
  return async ({ asOf, snapshotId, start, end, universe='all' }) => {
    if (!snapshotId || typeof start !== 'string' || typeof end !== 'string') fail('invalid_analysis_range', 400);
    const snapshot = load({ asOf, snapshotId, universe });
    if (snapshot.snapshotId !== snapshotId) fail('investor_style_snapshot_changed', 409);
    if (!snapshot.backtest.curve.some(r => r.date === start) || !snapshot.backtest.curve.some(r => r.date === end) || start >= end) fail('invalid_analysis_range', 400);
    const g = await generation(), key = `${universe}:${snapshotId}:${asOf}:${g}`;
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
    return { ...analyzeRuleRange(ledger, start, end), universe, lineage: {
      portfolioSnapshotId: snapshotId, sourceSnapshotGeneration: snapshot.lineage?.sourceGeneration ?? null,
      readerFingerprint: createHash('sha256').update(g).digest('hex'), allDailyNavReconciled: true,
      adjustmentBasis: 'vendor_current_adjustment_factors', method: RULE_ANALYSIS_VERSION,
    } };
  };
}
