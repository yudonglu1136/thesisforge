// Replay the already-frozen quarterly screen with full, local SEP prices.
// Never use future price availability to re-rank or discard selected stocks.
import fs from 'node:fs';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {simulateDriftedPortfolio} from '../server/backtestEngine.js';
import {applyStrategyCosts, strategyMetrics} from '../server/strategyLab.js';
import {valuationCheck} from './fundamental-pit-experiment.mjs';
import {signature} from '../server/investmentMath.js';

const dir = path.resolve(process.argv[2] ?? 'output/fundamental-pit-top10-20260911');
const option = name => process.argv.slice(3).find(arg => arg.startsWith(`--${name}=`))?.split('=').slice(1).join('=');
const outputDir = path.resolve(option('output') ?? dir);
const premiumOverride = option('premium');
if (premiumOverride != null && (!Number.isFinite(Number(premiumOverride)) || Number(premiumOverride) < 0))
  throw Error('Premium must be a nonnegative finite decimal');
fs.mkdirSync(outputDir, {recursive: true});
const seed = JSON.parse(fs.readFileSync(path.join(dir, 'result.json')));
const vendor = JSON.parse(fs.readFileSync(path.join(dir, 'sep-prices.json')));
if (vendor.selectionHash !== seed.selectionHash) throw Error('Price export is bound to a different selection ledger');
const requestedEnd = seed.rules.end;
// Optional explicitly refreshed full-history source. Keep original decision
// quotes on their model/share basis; replace entire return series, never splice
// Yahoo adjusted levels onto SEP. A retired security's complete local history
// remains usable for its actual past holding dates, not as a fresh current quote.
const refreshFile = option('prices-db');
let refreshed = null;
if (refreshFile) {
  const archive = new DatabaseSync(path.resolve(refreshFile), {readOnly:true});
  try {
    const prices = new Map(), sources = {}, missing = [];
    for (const [ticker, original] of Object.entries(vendor.series)) {
      const series = archive.prepare('SELECT * FROM series WHERE symbol=?').get(ticker);
      const fresh = archive.prepare('SELECT date,adjusted_close FROM prices WHERE symbol=? AND date<=? ORDER BY date').all(ticker,requestedEnd);
      if (fresh.length >= original.length * .9) {
        prices.set(ticker,new Map(fresh.map(p=>[p.date,p.adjusted_close])));
        sources[ticker]={provider:'yahoo',sourceHash:series.source_sha256,first:series.first_date,last:series.last_date,
          policy:'entire refreshed adjusted-close series; no cross-provider level splice'};
      } else {
        prices.set(ticker,new Map(original.map(p=>[p[0],p[2]])));
        sources[ticker]={provider:'sharadar_local_archive',first:original[0][0],last:original.at(-1)[0],
          reason:'New provider lacks complete historical security series; retain complete existing source'};
        missing.push(ticker);
      }
    }
    const spy = archive.prepare("SELECT date,adjusted_close price FROM prices WHERE symbol='SPY' AND date>=? AND date<=? ORDER BY date").all('2016-09-30',requestedEnd);
    if (spy.at(-1)?.date!==requestedEnd)throw Error('Refreshed benchmark does not reach requested end');
    refreshed={prices,sources,spy,missing,source:path.resolve(refreshFile),cutoff:requestedEnd,hash:signature(sources)};
  } finally {archive.close();}
}
// A global vendor snapshot cutoff, not a future intersection of winning stocks.
const effectiveEnd = refreshed?.cutoff ?? Object.values(vendor.series).map(rows => rows.at(-1)?.[0]).sort().at(-1);
const rules = {...seed.rules, requestedEnd, end: effectiveEnd,
  ...(premiumOverride == null ? {} : {maxPremium: Number(premiumOverride)})};
const db = new DatabaseSync(seed.source.dbPath, {readOnly: true});
try {
  const spyRows = refreshed?.spy ?? db.prepare('SELECT date,adjusted_close price FROM price_points WHERE symbol=? AND date>=? AND date<=? ORDER BY date')
    .all('SPY', '2016-09-30', effectiveEnd);
  const prices = refreshed?.prices ?? new Map(Object.entries(vendor.series).map(([ticker, rows]) => [ticker, new Map(rows.map(r => [r[0], r[2]]))]));
  const closes = new Map(Object.entries(vendor.series).map(([ticker, rows]) => [ticker, new Map(rows.map(r => [r[0], r[1]]))]));
  prices.set('SPY', new Map(spyRows.map(r => [r.date, r.price])));
  const snapshots = seed.snapshots.filter(s => s.executionDate <= effectiveEnd).map(s => {
    const check = row => ({...row, valuationDecision: valuationCheck({...row, price: {currency: 'USD'}},
      s.decisionDate, closes.get(row.ticker)?.get(s.decisionDate), rules)});
    const top = s.top.map(check);
    const fullPool = s.candidates.filter(r => r.reasons.length === 0).map(check).sort((a, b) =>
      b.metrics.revenueGrowth - a.metrics.revenueGrowth || b.worstRoic - a.worstRoic || a.ticker.localeCompare(b.ticker));
    const sameTop = top.filter(r => r.valuationDecision.status === 'eligible');
    const priorFilter = fullPool.filter(r => r.valuationDecision.status === 'eligible').slice(0, rules.topN);
    const weights = rows => rows.map(r => ({ticker: r.ticker, weight: 1 / rows.length}));
    return {...s, top, unfiltered: weights(top), filtered: weights(sameTop),
      // A separately named alternative. Not silently substituted for same-Top-10 filtering.
      filterBeforeRanking: weights(priorFilter), refillDetails: priorFilter,
      allEligibleValuations: fullPool, exclusions: top.filter(r => r.valuationDecision.status !== 'eligible')};
  });
  const result = {version: 'fundamental-pit-full-price-replay-v1', rules, snapshots,
    source: {dbPath: seed.source.dbPath, selectionHash: seed.selectionHash, vendorHash: vendor.hash,
      prices: refreshed?.source ?? vendor.source, fields: vendor.fields,
      refreshedPrices:refreshed?{hash:refreshed.hash,series:refreshed.sources,retainedHistoricalSources:refreshed.missing,
        decisionQuotePolicy:'Frozen SEP quotes retain the original historical model/share basis'}:null,
      effectiveEndReason: refreshed?'requested_end_verified_against_refreshed_daily_prices':'global_local_vendor_snapshot_cutoff',
      universe: seed.source.universe, model: seed.source.model}, variants: {}, validation: {}};
  const priceGaps = [];
  for (const [i, s] of snapshots.entries()) {
    const end = snapshots[i + 1]?.executionDate ?? effectiveEnd;
    for (const h of [...s.unfiltered, ...s.filterBeforeRanking]) {
      for (const d of spyRows.map(r => r.date).filter(d => d >= s.executionDate && d <= end)) {
        if (!(prices.get(h.ticker)?.get(d) > 0)) priceGaps.push({ticker: h.ticker, date: d, executionDate: s.executionDate});
      }
    }
  }
  result.validation.priceGaps = priceGaps;
  for (const key of ['unfiltered', 'filtered', 'filterBeforeRanking']) {
    const empty = snapshots.filter(s => !s[key].length);
    if (empty.length) {
      result.variants[key] = {status: 'blocked', failure: 'no_eligible_stocks_no_cash_allowed', dates: empty.map(s => s.executionDate)};
      continue;
    }
    const rebalances = snapshots.map(s => ({executionDate: s.executionDate, reportDate: s.decisionDate,
      coveragePct: 1, cashWeight: 0, weights: s[key].map(h => ({...h, priceSymbol: h.ticker, assetKind: 'stock'}))}));
    const gross = simulateDriftedPortfolio({rebalances, tradingDates: spyRows.map(r => r.date), priceMaps: prices, endDate: effectiveEnd});
    if (!gross.ok) {result.variants[key] = {status: 'blocked', failure: gross.failure}; continue;}
    const net = applyStrategyCosts(gross, rebalances, rules.costBps);
    const equity = net.equity.map((r, i) => ({...r, spy: gross.equity[i].benchmark * (1 - rules.costBps / 10000)}));
    const years = (Date.parse(equity.at(-1).date) - Date.parse(equity[0].date)) / 86400000 / 365.25;
    // Independent unit-ledger calculation: no shared portfolio/cost helper.
    const schedule = new Map(rebalances.map(r => [r.executionDate, r.weights]));
    let units = new Map(), maxDifference = 0;
    for (const [i, r] of equity.entries()) {
      let nav = i === 0 ? 1 : [...units].reduce((sum, [t, u]) => sum + u * prices.get(t).get(r.date), 0);
      const target = schedule.get(r.date);
      if (target) {
        const oldWeights = new Map([...units].map(([t, u]) => [t, u * prices.get(t).get(r.date) / nav]));
        const desired = new Map(target.map(h => [h.ticker, h.weight]));
        let traded = 0;
        for (const t of new Set([...desired.keys(), ...oldWeights.keys()]))
          traded += Math.abs((desired.get(t) ?? 0) - (oldWeights.get(t) ?? 0));
        nav *= 1 - traded * rules.costBps / 10000;
        units = new Map(target.map(h => [h.ticker, nav * h.weight / prices.get(h.ticker).get(r.date)]));
      }
      maxDifference = Math.max(maxDifference, Math.abs(nav - r.value));
    }
    if (maxDifference > 1e-9) throw Error(`Independent ledger mismatch: ${key} ${maxDifference}`);
    const annual = [];
    let anchor = 1;
    for (const year of [...new Set(equity.map(r => r.date.slice(0, 4)))]) {
      const part = equity.filter(r => r.date.startsWith(year)), last = part.at(-1).value;
      annual.push({year, end: part.at(-1).date, return: last / anchor - 1}); anchor = last;
    }
    result.variants[key] = {status: 'ready', equity, metrics: strategyMetrics(equity),
      grossMetrics: strategyMetrics(equity, 'gross'), spyMetrics: strategyMetrics(equity, 'spy'),
      annualOneWayTurnover: net.trades.slice(1).reduce((sum, t) => sum + t.turnover / 2, 0) / years,
      annual, trades: net.trades, reconciliation: gross.reconciliation, independentLedgerMaxDifference: maxDifference,
      intervals: gross.quarterContributions};
  }
  result.validation.allSourcesBeforeDecision = snapshots.every(s => s.top.every(r =>
    r.availableAt <= s.decisionDate && r.annualQuality.every(y => y.availableAt <= s.decisionDate)));
  result.validation.zeroCashTargets = snapshots.every(s => ['unfiltered', 'filtered', 'filterBeforeRanking'].every(k =>
    !s[k].length || Math.abs(s[k].reduce((sum, h) => sum + h.weight, 0) - 1) < 1e-12));
  result.validation.selectedCounts = Object.fromEntries(['unfiltered', 'filtered', 'filterBeforeRanking'].map(k =>
    [k, {min: Math.min(...snapshots.map(s => s[k].length)), max: Math.max(...snapshots.map(s => s[k].length)),
      mean: snapshots.reduce((sum, s) => sum + s[k].length, 0) / snapshots.length}]));
  // Hash the persisted JSON representation (engine annotations may be undefined).
  result.validation.replayHash = signature(JSON.parse(JSON.stringify({rules, snapshots, variants: result.variants})));
  fs.writeFileSync(path.join(outputDir, 'full-price-result.json'), JSON.stringify(result));
  const baseline = result.variants.unfiltered, comparison = result.variants.filterBeforeRanking;
  if (baseline.status === 'ready') {
    const compare = new Map((comparison.equity ?? []).map(r => [r.date, r.value]));
    const sameTop = new Map((result.variants.filtered.equity ?? []).map(r => [r.date, r.value]));
    fs.writeFileSync(path.join(outputDir, 'equity.csv'), 'date,top10_net,filter_before_ranking_net,spy_net,same_top10_filtered_net\n' +
      baseline.equity.map(r => [r.date, r.value, compare.get(r.date) ?? '', r.spy, sameTop.get(r.date) ?? ''].join(',')).join('\n') + '\n');
  }
  console.log(JSON.stringify({period: [snapshots[0].executionDate, effectiveEnd], requestedEnd,
    quarters: snapshots.length, validation: result.validation,
    variants: Object.fromEntries(Object.entries(result.variants).map(([k, v]) => [k,
      {status: v.status, failure: v.failure, dates: v.dates, metrics: v.metrics, spy: v.spyMetrics, turnover: v.annualOneWayTurnover}]))}, null, 2));
} finally {db.close();}
