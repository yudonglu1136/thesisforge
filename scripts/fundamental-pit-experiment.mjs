// Read-only quarterly replay of Discover's four-factor screen. No app state or
// source database is changed. This is retrospective research, not a live signal.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {InvestmentSource} from '../server/investmentSource.js';
import {buildFundamentals} from '../server/investmentFundamentals.js';
import {simulateDriftedPortfolio} from '../server/backtestEngine.js';
import {applyStrategyCosts, strategyMetrics} from '../server/strategyLab.js';
import {strategyComparisonPrices} from '../server/strategyLabSource.js';
import {signature} from '../server/investmentMath.js';

export const RULES = Object.freeze({
  growth: .15, operatingMargin: .10, fcfMargin: .05, roic: .15, qualityYears: 5,
  topN: 10, maxPremium: .30, costBps: 10,
  start: '2016-10-01', end: '2026-09-10',
  ranking: 'quarterly_revenue_yoy_desc_then_worst_5y_roic_desc_then_ticker',
  allocation: 'equal_weight_same_top10_survivors_no_refill_no_cash',
});
const day = 86400000;
const finite = v => typeof v === 'number' && Number.isFinite(v);
const positive = v => finite(v) && v > 0;
const meets = (v, limit) => finite(v) && v >= limit - 1e-10;

// Mirrors assessGrowthQuality / FundamentalRules in the existing Flutter UI.
export function assess(row, decisionDate, rules = RULES) {
  const q = row.quality ?? {}, years = (q.years ?? []).slice(0, rules.qualityYears);
  const m = row.metrics ?? {}, reasons = [];
  for (const [field, limit] of [['revenueGrowth', rules.growth],
    ['operatingMargin', rules.operatingMargin], ['fcfMargin', rules.fcfMargin]]) {
    if (!finite(m[field])) reasons.push(`${field}_missing`);
    else if (!meets(m[field], limit)) reasons.push(`${field}_below_threshold`);
  }
  let complete = q.status === 'available' && years.length === rules.qualityYears;
  for (const [i, y] of years.entries()) {
    const end = Date.parse(y.periodEnd), available = Date.parse(y.availableAt);
    if (!Number.isFinite(end) || !Number.isFinite(available) || end > available ||
      y.availableAt > decisionDate || !finite(y.roic) ||
      (!i && (Date.parse(decisionDate) - end) / day > 550)) complete = false;
    if (i) {
      const gap = (Date.parse(years[i - 1].periodEnd) - end) / day;
      if (years[i - 1].year !== y.year + 1 || gap < 300 || gap > 430) complete = false;
    }
  }
  if (!complete) reasons.push('quality_history_incomplete_or_stale');
  else if (!years.every(y => meets(y.roic, rules.roic))) reasons.push('roic_not_durable');
  if (!row.availableAt || row.availableAt > decisionDate || row.periodEnd > decisionDate)
    reasons.push('financial_not_public');
  // The existing operating-company cohort is supplied by buildFundamentals.
  // USD quoted securities only: no silent FX conversion or local/ADR substitution.
  if (row.price?.currency !== 'USD') reasons.push('non_usd_quote');
  return {passes: reasons.length === 0, reasons,
    worstRoic: complete ? Math.min(...years.map(y => y.roic)) : null, years};
}

export function screen(rows, decisionDate, rules = RULES) {
  const assessed = rows.map(row => ({...row, assessment: assess(row, decisionDate, rules)}));
  const eligible = assessed.filter(r => r.assessment.passes).sort((a, b) =>
    b.metrics.revenueGrowth - a.metrics.revenueGrowth ||
    b.assessment.worstRoic - a.assessment.worstRoic || a.ticker.localeCompare(b.ticker));
  return {assessed, eligible, selected: eligible.slice(0, rules.topN)};
}

export function valuationCheck(row, decisionDate, price, rules = RULES) {
  const v = row.valuation ?? {};
  if (!positive(v.fairValue)) return {status: 'no_model'};
  if (!v.date || v.date > decisionDate) return {status: 'model_not_public'};
  if ((Date.parse(decisionDate) - Date.parse(v.date)) / day > 550) return {status: 'stale_model'};
  if (v.currency !== 'USD' || row.price?.currency !== 'USD') return {status: 'currency_unverified'};
  if (!positive(price)) return {status: 'comparison_price_missing'};
  const premium = price / v.fairValue - 1;
  return {status: premium > rules.maxPremium + 1e-10 ? 'expensive' : 'eligible',
    price, priceDate: decisionDate, fairValue: v.fairValue, modelDate: v.date,
    premium, maxPremium: rules.maxPremium, modelVersion: row.source?.modelVersion,
    sourceHash: row.source?.hash};
}

export function quarterlySchedule(dates, rules = RULES) {
  const all = [...new Set(dates)].sort(), result = [];
  for (let i = 1; i < all.length; i++) {
    const date = all[i], prev = all[i - 1];
    if (date < rules.start || date > rules.end) continue;
    const quarter = d => `${d.slice(0, 4)}-${Math.floor((Number(d.slice(5, 7)) - 1) / 3)}`;
    if (quarter(date) !== quarter(prev)) result.push({executionDate: date, decisionDate: prev});
  }
  return result;
}

function compact(row) {
  return {ticker: row.ticker, name: row.name, period: row.period, periodEnd: row.periodEnd,
    availableAt: row.availableAt, metrics: row.metrics, source: row.source,
    worstRoic: row.assessment.worstRoic, annualQuality: row.assessment.years,
    valuation: row.valuation, reasons: row.assessment.reasons};
}

export async function experiment({dbPath, outputDir, rules = RULES}) {
  fs.mkdirSync(outputDir, {recursive: true});
  // Lock the rules before any return calculation. Subsequent reruns are explicit.
  fs.writeFileSync(path.join(outputDir, 'rules.json'), JSON.stringify(rules, null, 2));
  const source = new InvestmentSource(dbPath);
  try {
    const db = source.db, prices = new Map(), priceEvidence = {}, comparisons = new Map();
    const rawQuery = db.prepare('SELECT date,close,adjusted_close,source FROM price_points WHERE symbol=? AND date>=? AND date<=? ORDER BY date');
    const historyStart = `${Number(rules.start.slice(0, 4)) - 1}-01-01`;
    function loadPrices(ticker) {
      if (prices.has(ticker)) return;
      const raw = rawQuery.all(ticker, historyStart, rules.end);
      prices.set(ticker, new Map(raw.filter(r => positive(r.adjusted_close)).map(r => [r.date, r.adjusted_close])));
      priceEvidence[ticker] = {rows: raw.length, hash: signature(raw), first: raw[0]?.date, last: raw.at(-1)?.date,
        sources: [...new Set(raw.map(r => r.source))], field: 'adjusted_close'};
      const snap = db.prepare(`SELECT json_extract(payload_json,'$.currency') currency,
        json_extract(payload_json,'$.priceSource') priceSource,
        json_extract(payload_json,'$.priceHistory') history FROM valuation_ticker_snapshots WHERE ticker=?`).get(ticker);
      const compared = strategyComparisonPrices({...snap, priceHistory: JSON.parse(snap?.history ?? '[]')}, raw, rules.end);
      comparisons.set(ticker, compared);
      priceEvidence[ticker].comparisonAudit = compared.audits;
    }
    loadPrices('SPY');
    const dates = rawQuery.all('SPY', historyStart, rules.end).map(r => r.date);
    if (dates.at(-1) !== rules.end) throw Error(`Benchmark ends ${dates.at(-1)}, not requested ${rules.end}`);
    const schedule = quarterlySchedule(dates, rules), snapshots = [];
    for (const event of schedule) {
      const panel = buildFundamentals(source, event.decisionDate);
      const selected = screen(panel.companies, event.decisionDate, rules);
      for (const row of selected.selected) loadPrices(row.ticker);
      const top = selected.selected.map((row, i) => ({...compact(row), rank: i + 1,
        valuationDecision: valuationCheck(row, event.decisionDate,
          comparisons.get(row.ticker)?.points.get(event.decisionDate), rules)}));
      const retained = top.filter(r => r.valuationDecision.status === 'eligible');
      const snapshot = {...event, coverage: panel.coverage, eligibleCount: selected.eligible.length,
        top, unfiltered: top.map(r => ({ticker: r.ticker, weight: 1 / top.length})),
        filtered: retained.map(r => ({ticker: r.ticker, weight: 1 / retained.length})),
        exclusions: top.filter(r => r.valuationDecision.status !== 'eligible'),
        candidates: selected.assessed.map(compact)};
      snapshots.push(snapshot);
      console.log(JSON.stringify({date: event.executionDate, eligible: selected.eligible.length,
        top: top.map(r => r.ticker), kept: retained.length,
        excluded: snapshot.exclusions.map(r => `${r.ticker}:${r.valuationDecision.status}`)}));
    }
    // Save the complete selection ledger before running any NAV calculation.
    fs.writeFileSync(path.join(outputDir, 'snapshots.json'), JSON.stringify(snapshots));
    const result = {version: 'fundamental-pit-experiment-v1', rules, rulesHash: signature(rules),
      source: {dbPath, quality: db.prepare('SELECT * FROM investment_quality_metadata').all(),
        universe: 'Current database operating-company coverage; not historical full-market membership',
        model: 'Retrospective PIT replay of current stored model versions; not contemporaneously archived forecasts',
        priceEvidence}, snapshots, variants: {}};
    for (const key of ['unfiltered', 'filtered']) {
      const empty = snapshots.find(s => !s[key].length);
      if (empty) {
        result.variants[key] = {status: 'blocked', failure: {code: 'no_eligible_stocks_no_cash_allowed', date: empty.executionDate}};
        continue;
      }
      const rebalances = snapshots.map(s => ({executionDate: s.executionDate, reportDate: s.decisionDate,
        coveragePct: 1, cashWeight: 0, weights: s[key].map(h => ({...h, priceSymbol: h.ticker, assetKind: 'stock'}))}));
      const simulated = simulateDriftedPortfolio({rebalances, tradingDates: dates, priceMaps: prices, endDate: rules.end});
      if (!simulated.ok) {
        result.variants[key] = {status: 'blocked', failure: simulated.failure, partialEnd: simulated.equity.at(-1)?.date};
        continue;
      }
      const net = applyStrategyCosts(simulated, rebalances, rules.costBps);
      const equity = net.equity.map((r, i) => ({...r, spy: simulated.equity[i].benchmark * (1 - rules.costBps / 10000)}));
      const years = (Date.parse(equity.at(-1).date) - Date.parse(equity[0].date)) / day / 365.25;
      result.variants[key] = {status: 'ready', equity, metrics: strategyMetrics(equity),
        grossMetrics: strategyMetrics(equity, 'gross'), spyMetrics: strategyMetrics(equity, 'spy'),
        annualOneWayTurnover: net.trades.slice(1).reduce((sum, t) => sum + t.turnover / 2, 0) / years,
        trades: net.trades, costDrag: net.costDrag, reconciliation: simulated.reconciliation,
        intervals: simulated.quarterContributions};
    }
    result.selectionHash = signature(snapshots);
    fs.writeFileSync(path.join(outputDir, 'result.json'), JSON.stringify(result));
    const ready = Object.values(result.variants).find(v => v.status === 'ready');
    if (ready) {
      const other = result.variants.filtered.status === 'ready' ? new Map(result.variants.filtered.equity.map(r => [r.date, r.value])) : new Map();
      const base = result.variants.unfiltered.status === 'ready' ? new Map(result.variants.unfiltered.equity.map(r => [r.date, r.value])) : new Map();
      fs.writeFileSync(path.join(outputDir, 'equity.csv'), 'date,top10_net,valuation_filtered_net,spy_net\n' +
        ready.equity.map(r => [r.date, base.get(r.date) ?? '', other.get(r.date) ?? '', r.spy].join(',')).join('\n') + '\n');
    }
    console.log(JSON.stringify({outputDir, variants: Object.fromEntries(Object.entries(result.variants).map(([k, v]) =>
      [k, {status: v.status, failure: v.failure, metrics: v.metrics, spy: v.spyMetrics, annualOneWayTurnover: v.annualOneWayTurnover}]))}, null, 2));
    return result;
  } finally { source.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const args = Object.fromEntries(process.argv.slice(2).map(v => v.replace(/^--/, '').split('=')));
  await experiment({dbPath: args.db ?? '/Users/yudonglu/Documents/investment-market-reviewed-20260911/runtime.sqlite',
    outputDir: path.resolve(args.output ?? 'output/fundamental-pit-top10-20260911')});
}
