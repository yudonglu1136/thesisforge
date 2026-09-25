import test from 'node:test';
import assert from 'node:assert/strict';
import { buildRuleLedger, analyzeRuleRange, createRuleAnalysisService, canonicalRulePrices,
  serializeRuleLedger,hydrateRuleLedger } from './rulePortfolioAnalysis.js';

const dates = ['2024-01-02', '2024-01-03', '2024-01-04', '2024-01-05'];
const prices = new Map([
  ['AAA', new Map(dates.map((d, i) => [d, [100, 110, 120, 100][i]]))],
  ['BBB', new Map(dates.map((d, i) => [d, [100, 90, 80, 90][i]]))],
]);
function fixture() {
  const style = { id: 'quality_rank', quarters: [
    { executionDate: dates[0], positions: [{ ticker: 'AAA', weight: .5 }, { ticker: 'BBB', weight: .5 }], cashWeight: 0 },
    { executionDate: dates[2], positions: [{ ticker: 'AAA', weight: 1 }], cashWeight: 0 },
  ], corporateActions: [], trades: [
    { date: dates[0], turnover: 1, costFraction: .0025 },
    { date: dates[2], turnover: .8, costFraction: .002 },
  ] };
  const values = [.9975, .9975, .995505, .995505 * 100 / 120];
  return { snapshotId: 'fixture', styles: [style, { ...style, id: 'ackman' }],
    backtest: { curve: dates.map((date, i) => ({ date, quality_rank: values[i], ackman: values[i] })) } };
}
const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} != ${b}`);

test('versioned public ledger round-trips maps without changing range statistics',()=>{
  const ledger=buildRuleLedger(fixture(),prices);
  const restored=hydrateRuleLedger(JSON.parse(JSON.stringify(serializeRuleLedger(ledger))));
  assert.deepEqual(analyzeRuleRange(restored,dates[0],dates.at(-1)),
    analyzeRuleRange(ledger,dates[0],dates.at(-1)));
});

test('post-cost execution quantities conserve inventory and FIFO intervals reconcile for both strategies', () => {
  const ledger = buildRuleLedger(fixture(), prices);
  for (const style of ledger.styles) {
    const inventory = new Map();
    for (const e of style.events) {
      if (!['buy', 'sell'].includes(e.side)) continue;
      const before = inventory.get(e.ticker) ?? 0;
      close(e.quantityBefore, before);
      const after = before + (e.side === 'buy' ? e.quantity : -e.quantity);
      assert.ok(after >= -1e-12);
      close(e.quantityAfter, after);
      close(e.notional, e.quantity * e.price);
      inventory.set(e.ticker, after);
      const mark = style.days.find(d => d.date === e.date).positions.get(e.ticker);
      close(after, mark ? mark.value / mark.price : 0);
    }
  }
  for (const style of analyzeRuleRange(ledger, dates[0], dates[3]).styles) {
    for (const h of style.holdings) {
      assert.equal(h.lotAnalysis.status, 'available');
      assert.equal(h.lotAnalysis.method, 'fifo-post-cost-v1');
      close(sum(h.lotAnalysis.intervals.map(r => r.grossContribution)), h.grossContribution);
      close(sum(h.lotAnalysis.intervals.map(r => r.costContribution)), h.costContribution);
      close(sum(h.lotAnalysis.intervals.map(r => r.netContribution)), h.netContribution);
      close(h.lotAnalysis.reconciliation.difference, 0);
    }
    const b = style.holdings.find(h => h.ticker === 'BBB');
    assert.equal(b.lotAnalysis.intervals[0].status, 'closed');
    assert.equal(b.lotAnalysis.intervals[0].buyDate, dates[0]);
    assert.equal(b.lotAnalysis.intervals[0].exitDate, dates[2]);
    close(b.lotAnalysis.intervals[0].quantity, .49875 / 100);
  }
});

test('FIFO uses a selected opening mark, excludes opening trades/fees and preserves original buy context', () => {
  const ledger = buildRuleLedger(fixture(), prices);
  const r = analyzeRuleRange(ledger, dates[1], dates[2]).styles[0];
  for (const h of r.holdings) {
    close(sum(h.lotAnalysis.intervals.map(r => r.netContribution)), h.netContribution);
    const carried = h.lotAnalysis.intervals.find(r => r.carriedIn);
    assert.equal(carried.buyDate, dates[0]);
    assert.equal(carried.entryDate, dates[1]);
    assert.equal(carried.buyPrice, 100);
    assert.equal(carried.entryPrice, h.ticker === 'AAA' ? 110 : 90);
    close(carried.entryCost, 0);
  }
  const after = analyzeRuleRange(ledger, dates[2], dates[3]).styles[0].holdings[0];
  assert.ok(after.lotAnalysis.intervals.every(r => r.status === 'open' && r.carriedIn));
  assert.ok(after.lotAnalysis.intervals.every(r => r.costContribution === 0));
  close(sum(after.lotAnalysis.intervals.map(r => r.netContribution)), after.netContribution);
});

test('canonical range prices use one compact pinned batch and reject identity or date drift', async () => {
  const snapshot = fixture();
  for (const style of snapshot.styles) for (const q of style.quarters) for (const p of q.positions) {
    p.permaticker = p.ticker === 'AAA' ? 1 : 2;
  }
  let calls = 0, response;
  const query = async (method, [spans, basis]) => {
    calls++;
    assert.equal(method, 'get_price_histories'); assert.equal(basis, 'TOTAL_RETURN_ADJUSTED_CLOSE');
    assert.equal(spans.length, 2);
    response = {version:'canonical-price-histories-v1', generation:'immutable-generation', columns:['date','value','source_ticker'],
      series:spans.map(s=>({...s, requested:s.ticker, security_id:s.ticker, aliases:['AAA'],
        currency:'USD',price_type:basis,points:[[s.start,100,'AAA']]}))};
    return response;
  };
  const maps = await canonicalRulePrices(snapshot, {query});
  assert.equal(calls, 1); assert.equal(maps.get('AAA').get(dates[0]),100);
  for (const mutate of [r=>r.series[0].security_id='different', r=>r.series[0].currency='GBP',
    r=>r.series[0].points.push(r.series[0].points[0]), r=>r.series[0].points[0][1]=0,
    r=>r.series[0].points[0][0]='2012-01-01', r=>r.series[0].points[0][2]='WRONG',
    r=>r.series[0].start='2012-01-01', r=>r.generation=null]) {
    const changed=structuredClone(response); mutate(changed);
    await assert.rejects(canonicalRulePrices(snapshot,{query:async()=>changed}), /rule_analysis_(identity_conflict|prices_unavailable)/);
  }
});

test('range turnover reconciles real simulated buys and sells at each pre-cost NAV', () => {
  const ledger = buildRuleLedger(fixture(), prices);
  for (const s of analyzeRuleRange(ledger, dates[0], dates[3]).styles) {
    assert.equal(s.turnover.version, 'rule-range-turnover-v1');
    close(s.turnover.buyRatio, 1.4); // entry 100%, then add 40%
    close(s.turnover.sellRatio, .4);
    close(s.turnover.twoWay, 1.8);
    close(s.turnover.oneWay, .9);
    close(s.turnover.annualizedOneWay, .9 * 252 / 3);
    close(s.turnover.buyNotional, 1 + .399);
    close(s.turnover.sellNotional, .399);
    assert.equal(s.turnover.executions, 2);
    assert.equal(s.turnover.includesInitialEntry, true);
  }
  const clipped = analyzeRuleRange(ledger, dates[1], dates[2]).styles[0].turnover;
  close(clipped.oneWay, .4);
  close(clipped.annualizedOneWay, .4 * 252);
  assert.equal(clipped.executions, 1);
  assert.equal(clipped.includesInitialEntry, false);
  // Starting at that day's post-trade closing mark excludes its trading,
  // exactly like the return and fee interval. No rebalance means measured 0.
  const after = analyzeRuleRange(ledger, dates[2], dates[3]).styles[0].turnover;
  close(after.oneWay, 0); close(after.annualizedOneWay, 0);
  assert.equal(after.executions, 0);
});

test('full-range attribution includes entry fees and ties to every published net NAV', () => {
  const ledger = buildRuleLedger(fixture(), prices);
  const result = analyzeRuleRange(ledger, dates[0], dates[3]);
  assert.equal(result.styles.length, 2);
  for (const s of result.styles) {
    close(s.metrics.totalReturn, .995505 * 100 / 120 - 1);
    close(s.reconciliation.stockPnl, s.metrics.totalReturn);
    close(s.reconciliation.difference, 0);
    assert.equal(s.holdings.length, 2);
    assert.equal(s.distribution.reduce((n, b) => n + b.count, 0), 2);
    assert.equal(s.tradeStats.wins, 0);
    assert.equal(s.tradeStats.losses, 2);
    assert.equal(s.tradeStats.payoffRatio, null);
    assert.equal(s.tradeStats.payoffStatus, 'no_winners');
    assert.equal(s.holdings.find(r => r.ticker === 'AAA').openAtEnd, true);
    assert.equal(s.holdings.find(r => r.ticker === 'BBB').openAtEnd, false);
  }
});

test('range clips marks, not trades; costs at the opening mark are excluded', () => {
  const result = analyzeRuleRange(buildRuleLedger(fixture(), prices), dates[1], dates[2]).styles[0];
  close(result.metrics.totalReturn, -.002);
  const winner = result.best, loser = result.worst;
  assert.equal(winner.ticker, 'AAA'); assert.equal(loser.ticker, 'BBB');
  close(winner.netContribution, .05 - .001);
  close(loser.netContribution, -.05 - .001);
  close(result.tradeStats.winRate, .5); close(result.tradeStats.payoffRatio, .049 / .051);
  assert.equal(winner.openingMark.date, dates[1]);
  assert.equal(winner.openingMark.price, 110);
  assert.equal(winner.purchases[0].date, dates[0]);
  assert.equal(winner.purchases[0].price, 100);
  assert.equal(winner.sales.length, 0); // boundary mark must never become a fake sale
  assert.equal(loser.sales[0].date, dates[2]); assert.equal(loser.sales[0].price, 80);
  assert.equal(result.metrics.observations, 2);
});

test('missing prices, duplicate dates, invalid range and incompatible snapshot fail closed', () => {
  const missing = new Map(prices); missing.set('AAA', new Map([[dates[0], 100]]));
  assert.throws(() => buildRuleLedger(fixture(), missing), /missing_active_price/);
  const bad = fixture(); bad.backtest.curve[2].quality_rank += .01;
  assert.throws(() => buildRuleLedger(bad, prices), /rule_analysis_nav_mismatch/);
  const duplicate = fixture(); duplicate.backtest.curve[1].date = dates[0];
  assert.throws(() => buildRuleLedger(duplicate, prices), /invalid_rule_curve/);
  const ledger = buildRuleLedger(fixture(), prices);
  for (const [start, end] of [[dates[1], dates[1]], ['2023-12-31', dates[3]], [dates[3], dates[0]]]) {
    assert.throws(() => analyzeRuleRange(ledger, start, end), /invalid_analysis_range/);
  }
});

test('displayed but unexecuted latest selection is not charged or treated as a buy', () => {
  const f = fixture();
  f.styles.forEach(s => s.quarters.push({ executionDate: dates[3], positions: [{ ticker: 'BBB', weight: 1 }], cashWeight: 0 }));
  const r = analyzeRuleRange(buildRuleLedger(f, prices), dates[0], dates[3]).styles[0];
  assert.equal(r.holdings.find(h => h.ticker === 'BBB').purchases.length, 1);
  assert.equal(r.holdings.find(h => h.ticker === 'AAA').openAtEnd, true);
});

test('sample volatility, Sharpe and drawdown use unsampled daily net NAV', () => {
  const r = analyzeRuleRange(buildRuleLedger(fixture(), prices), dates[0], dates[3]).styles[0];
  const returns = [0, -.002, 100 / 120 - 1];
  const mean = sum(returns) / 3, variance = sum(returns.map(v => (v - mean) ** 2)) / 2;
  close(r.metrics.volatility, Math.sqrt(variance * 252));
  close(r.metrics.sharpeZeroRf, mean / Math.sqrt(variance) * Math.sqrt(252));
  close(r.metrics.maxDrawdown, .995505 * 100 / 120 - 1);
  const oneReturn = analyzeRuleRange(buildRuleLedger(fixture(), prices), dates[0], dates[1]).styles[0];
  assert.equal(oneReturn.metrics.volatility, null); assert.equal(oneReturn.metrics.sharpeZeroRf, null);
});
const sum = values => values.reduce((a, b) => a + b, 0);

test('disconnected history is individually replayable; missing marks cannot become zero returns', () => {
  const f=fixture();
  f.styles=[{id:'ackman',quarters:[f.styles[0].quarters[0], {executionDate:dates[2],positions:[{ticker:'AAA',weight:1}],cashWeight:0}],
    trades:[{date:dates[0],turnover:1,costFraction:.0025},{date:dates[2],turnover:1,costFraction:.0025}],
    coverage:{segments:[{from:dates[0],to:dates[0]},{from:dates[2],to:dates[3]}],gaps:[{from:dates[1],to:dates[1]}]}}];
  f.backtest.curve=dates.map((date,i)=>({date,ackman:[.9975,null,.9975,.9975*100/120][i]}));
  const ledger=buildRuleLedger(f,prices);
  const missing=analyzeRuleRange(ledger,dates[0],dates[3]).styles[0];
  assert.equal(missing.status,'coverage_gap');
  assert.equal(missing.metrics.totalReturn,null); assert.equal(missing.turnover,null);
  assert.deepEqual(missing.distribution,[]);
  const later=analyzeRuleRange(ledger,dates[2],dates[3]).styles[0];
  close(later.metrics.totalReturn,.9975*100/120-1);
  assert.equal(later.turnover.includesInitialEntry,true); close(later.turnover.oneWay,.5);
  close(later.reconciliation.difference,0);
  const absent=new Map(prices); absent.set('AAA',new Map([[dates[0],100]]));
  assert.throws(()=>buildRuleLedger(f,absent),/missing_execution_price/);
});

test('mixed merger cash is not sold; successor purchase costs and P&L independently reconcile', () => {
  const f=fixture();
  f.styles=[{id:'quality_rank',quarters:[
    {executionDate:dates[0],positions:[{ticker:'AAA',weight:1}],cashWeight:0},
    {executionDate:dates[2],positions:[{ticker:'BBB',weight:1}],cashWeight:0}],
    trades:[{date:dates[0],turnover:1,costFraction:.0025},{date:dates[2],turnover:.25,costFraction:.000625}],
    corporateActions:[{ticker:'AAA',executionDate:dates[0],effectiveDate:dates[1],considerationType:'stock_and_cash',
      successorTicker:'BBB',successorSharesPerShare:1,terminalCashEntitlementPerShare:25}]}];
  const nav=.9975*(1-.000625);
  f.backtest.curve=dates.map((date,i)=>({date,quality_rank:[.9975,.9975,nav,nav*80/75][i]}));
  const maps=new Map([['AAA',new Map([[dates[0],100]])],['BBB',new Map([[dates[1],75],[dates[2],75],[dates[3],80]])]]);
  const out=analyzeRuleRange(buildRuleLedger(f,maps),dates[0],dates[3]).styles[0];
  close(out.turnover.sellRatio,0); close(out.turnover.buyRatio,1.25);
  close(out.reconciliation.difference,0);
  assert.equal(out.holdings.flatMap(h=>h.sales).length,0);
  close(out.holdings.find(h=>h.ticker==='BBB').purchases[0].notional,.9975*.25);
});

test('stock conversion retains its exact successor claim and does not fabricate turnover', () => {
  const f = fixture();
  f.styles = [{ id: 'quality_rank', quarters: [
    { executionDate: dates[0], positions: [{ ticker: 'AAA', weight: 1 }], cashWeight: 0 },
    { executionDate: dates[2], positions: [{ ticker: 'BBB', weight: 1 }], cashWeight: 0 },
  ], trades: [{ date: dates[0], turnover: 1, costFraction: 0 }, { date: dates[2], turnover: 0, costFraction: 0 }],
  corporateActions: [{ ticker: 'AAA', executionDate: dates[0], actionId: 'verified-exchange', effectiveDate: dates[1], considerationType: 'stock', successorTicker: 'BBB', successorSharesPerShare: 2 }] }];
  f.backtest.curve = dates.map((date, i) => ({ date, quality_rank: [1, 1.1, 1.2, 1.3][i] }));
  const maps = new Map([['AAA', new Map([[dates[0], 100]])], ['BBB', new Map(dates.slice(1).map((d, i) => [d, 55 + i * 5]))]]);
  const r = analyzeRuleRange(buildRuleLedger(f, maps, { costBps: 0 }), dates[0], dates[3]).styles[0];
  close(r.reconciliation.stockPnl, .3);
  assert.equal(r.holdings.flatMap(h => h.sales).length, 0);
  assert.equal(r.holdings.flatMap(h => h.purchases).length, 1);
  assert.equal(r.tradeStats.payoffStatus, 'no_losers'); assert.equal(r.tradeStats.payoffRatio, null);
  close(r.turnover.oneWay, .5); // Entry only; the exchange is not trading.
  close(analyzeRuleRange(buildRuleLedger(f, maps, { costBps: 0 }), dates[1], dates[3]).styles[0].turnover.oneWay, 0);
});

test('as-of response cannot include later executions; changing generation during read fails', async () => {
  let generation = 'a';
  const service = createRuleAnalysisService({ load: () => fixture(), generation: async () => generation,
    prices: async () => { generation = 'b'; return prices; } });
  await assert.rejects(service({ asOf: dates[3], snapshotId: 'fixture', start: dates[0], end: dates[3] }), /generation_changed/);
  const early = analyzeRuleRange(buildRuleLedger(fixture(), prices), dates[0], dates[1]);
  assert.ok(early.styles.every(s => s.holdings.every(h => [...h.purchases, ...h.sales].every(e => e.date <= dates[1]))));
});

test('cash acquisition is settlement, not a sale; zero variance Sharpe is unavailable', () => {
  const f = fixture();
  f.backtest.curve = dates.map((date, i) => ({ date, quality_rank: i ? 1.1 : 1 }));
  f.styles = [{ id: 'quality_rank', quarters: [{ executionDate: dates[0], positions: [{ ticker: 'AAA', weight: 1 }], cashWeight: 0 }],
    trades: [{ date: dates[0], turnover: 1, costFraction: 0 }],
    corporateActions: [{ ticker: 'AAA', executionDate: dates[0], effectiveDate: dates[1], considerationType: 'cash', terminalCashEntitlementPerShare: 110 }] }];
  const ledger = buildRuleLedger(f, new Map([['AAA', new Map([[dates[0], 100]])]]), { costBps: 0 });
  const full = analyzeRuleRange(ledger, dates[0], dates[3]).styles[0];
  close(full.metrics.totalReturn, .1);
  assert.equal(full.best.sales.length, 0); assert.equal(full.best.openAtEnd, false);
  assert.equal(full.best.corporateActions[0].considerationType, 'cash');
  const flat = analyzeRuleRange(ledger, dates[1], dates[3]).styles[0];
  assert.equal(flat.metrics.sharpeZeroRf, null); assert.equal(flat.tradeStats.winRate, null);
});

test('concurrent reads share immutable replay; generation changes invalidate it; failures retry', async () => {
  let generation = 'a', reads = 0, broken = false;
  const service = createRuleAnalysisService({ load: () => fixture(), generation: async () => generation,
    prices: async () => { reads++; if (broken) throw new Error('unavailable'); return prices; } });
  const args = { asOf: dates[3], snapshotId: 'fixture', start: dates[0], end: dates[3] };
  const [a, b] = await Promise.all([service(args), service(args)]);
  assert.equal(reads, 1); assert.deepEqual(a, b);
  generation = 'b'; broken = true;
  await assert.rejects(service(args), /unavailable/);
  broken = false; await service(args); assert.equal(reads, 3);
});
