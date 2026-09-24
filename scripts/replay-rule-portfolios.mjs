import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { applyStrategyCosts, strategyMetrics } from '../server/strategyLab.js';
import { qualityRankWeights } from '../server/rulePortfolioWeights.js';
import { validateInvestorStyleDashboard } from '../server/investorStyleDashboard.js';

const [input, output, engineRevision] = process.argv.slice(2);
if (!input || !output) throw new Error('Usage: node scripts/replay-rule-portfolios.mjs INPUT_DIR OUTPUT_JSON [ENGINE_COMMIT_SHA]');
// An explicit immutable revision isolates an offline replay from another task's
// unfinished engine edits without modifying or checking out that task's files.
if (engineRevision && !/^[a-f0-9]{40}$/.test(engineRevision)) throw new Error('invalid_engine_revision');
const engineSource = engineRevision
  ? execFileSync('git', ['show', `${engineRevision}:server/backtestEngine.js`], {
    cwd: fileURLToPath(new URL('..', import.meta.url)), encoding: 'utf8', maxBuffer: 1024 * 1024,
  })
  : fs.readFileSync(new URL('../server/backtestEngine.js', import.meta.url), 'utf8');
const { simulateDriftedPortfolio } = engineRevision
  ? await import(`data:text/javascript;base64,${Buffer.from(engineSource).toString('base64')}`)
  : await import('../server/backtestEngine.js');
const sha = data => createHash('sha256').update(data).digest('hex');
const raw = fs.readFileSync(path.join(input, 'inputs.json'));
const packet = JSON.parse(raw);
const priceSource = fs.readFileSync(path.join(input, 'prices.csv'), 'utf8');
if (sha(priceSource) !== packet.lineage.priceSha256) throw new Error('price_fingerprint_mismatch');
const prices = new Map();
for (const line of priceSource.trim().split('\n').slice(1)) {
  const [ticker, date, value] = line.split(',');
  if (!Number.isFinite(+value) || +value <= 0) throw new Error('invalid_observed_price');
  if (!prices.has(ticker)) prices.set(ticker, new Map());
  if (prices.get(ticker).has(date)) throw new Error('duplicate_observed_price');
  prices.get(ticker).set(date, +value);
}
const dates = [...prices.get('SPY').keys()].sort();
const curves = {}, styles = [];
for (const [id, quarters] of Object.entries(packet.schedules)) {
  const schedule = [];
  for (const [i, q] of quarters.entries()) {
    const allocation = id === 'quality_rank' ? qualityRankWeights(q.positions) : {
      positions: q.positions.map(p => ({ ...p, weight: .05 })), cashWeight: 1 - q.positions.length * .05,
    };
    const previous = quarters[i - 1]?.positions ?? [];
    q.positions = allocation.positions.map(p => ({ ...p,
      previousTargetWeight: previous.find(r => r.ticker === p.ticker)?.weight ?? 0,
      action: previous.some(r => r.ticker === p.ticker) ? 'rebalance' : 'new',
    }));
    q.cashWeight = allocation.cashWeight;
    q.tickers = q.positions.map(p => p.ticker);
    q.selectedCount = q.positions.length;
    q.entered = q.tickers.filter(t => !previous.some(p => p.ticker === t));
    q.retained = q.tickers.filter(t => previous.some(p => p.ticker === t));
    q.exited = previous.filter(p => !q.tickers.includes(p.ticker)).map(p => p.ticker);
    q.exits = previous.filter(p => !q.tickers.includes(p.ticker)).map(p => ({ ticker: p.ticker, previousTargetWeight: p.weight, weight: 0 }));
    q.mature = !!q.nextExecutionDate;
    const weights = q.positions.map(p => {
      if (!prices.get(p.ticker)?.has(q.executionDate)) throw new Error(`missing_entry_price:${id}:${p.ticker}:${q.executionDate}`);
      const matches = packet.actions.filter(a => a.ticker === p.ticker && String(a.permaticker) === p.permaticker &&
        a.status === 'verified_research_accounting' && a.corporateAction.legalSourceVerified === true &&
        a.corporateAction.effectiveDate > q.executionDate && a.corporateAction.effectiveDate <= (q.nextExecutionDate ?? dates.at(-1)));
      if (matches.length > 1) throw new Error('ambiguous_action');
      const action = matches[0]?.corporateAction ?? q.actions?.find(a => a.ticker === p.ticker && a.permaticker === p.permaticker);
      return { ticker: p.ticker, permaticker: p.permaticker, weight: p.weight,
        ...(action ? { corporateAction: action } : {}) };
    });
    schedule.push({ reportDate: q.quarter, signalDate: q.signalDate, executionDate: q.executionDate,
      nextExecutionDate: q.nextExecutionDate, weights, targetWeights: weights, cashWeight: q.cashWeight,
      ...(weights.length ? {} : { cashReason: 'strategy_rules' }) });
  }
  const endDate = dates.at(-1);
  // Explicit coverage exception, never outcome-based removal or stitching.
  // CELG included an unpriced BMYRT right. The first segment ends before the
  // entitlement; the later segment is an independent inception at a scheduled
  // rebalance. No return, turnover or risk statistic may cross this gap.
  const unpricedRight = schedule.some(q=>q.executionDate<'2019-11-20' && q.nextExecutionDate>='2019-11-20' && q.weights.some(p=>p.ticker==='CELG'));
  const coverage = id === 'ackman' && unpricedRight ? {
    segments: [{from:dates[0],to:'2019-11-19'}, {from:'2020-01-02',to:endDate}],
    gaps: [{from:'2019-11-20',to:'2020-01-01',reason:'unpriced_celg_cvr',ticker:'CELG',
      missingSecurity:'BMYRT',sourceUrl:'https://www.sec.gov/Archives/edgar/data/816284/000110465919065939/tm1923405d1_8k.htm'}],
  } : {segments:[{from:dates[0],to:endDate}],gaps:[]};
  for (const q of quarters) q.mature = !!q.nextExecutionDate && coverage.segments.some(s=>s.from<=q.executionDate && s.to>=q.nextExecutionDate);
  const results = coverage.segments.map(segment => {
  const rebalances=schedule.filter(q=>q.executionDate>=segment.from && q.executionDate<segment.to);
  const gross = simulateDriftedPortfolio({ rebalances, tradingDates: dates.filter(d=>d>=segment.from && d<=segment.to), priceMaps: prices,
    benchmarkSymbol: 'SPY', endDate:segment.to, allowExplicitCash: true });
  if (!gross.ok || gross.equity.at(-1).date !== segment.to) throw new Error(`replay_failed:${id}:${JSON.stringify(gross.failure ?? gross.error)}`);
  const net = applyStrategyCosts(gross, rebalances, 25);
  const compounded = gross.quarterContributions.reduce((nav, q, i) => nav * (1 + q.portfolioReturn) * (1 - net.trades[i].costFraction), 1);
  if (Math.abs(compounded - net.equity.at(-1).value) > 1e-9) throw new Error('quarterly_daily_reconciliation_failed');
  for (const q of quarters) delete q.actions; // only execution receipts below expose applied actions
  return {segment,gross,net,compounded};
  });
  curves[id] = results.flatMap(({net}) => net.equity);
  const full = results.length===1 ? results[0] : null;
  const trades=results.flatMap(r=>r.net.trades);
  const years = (Date.parse(endDate) - Date.parse(dates[0])) / (86400000 * 365.25);
  styles.push({ id, quarters, trades, coverage,
    rule: { methodId: id === 'quality_rank' ? 'quality-rank-sqrt-top10-v1' : 'ackman-quality-improvement-proxy-v1',
      targetCap: id === 'quality_rank' ? .15 : .05, targetCount: id === 'quality_rank' ? 10 : 20,
      rebalance: 'quarterly_next_spy_session_close', scoreBeforeGates: true,
      tieBreaks: id === 'quality_rank' ? ['lower_beta', 'ticker'] : ['ticker'],
      gates: id === 'quality_rank' ? { revenueYoYGreaterThan: .08, operatingMarginAtLeast: .10, fcfMarginAtLeast: .05,
        minAnnualPretaxCapitalReturnAtLeast: .10, legacyPretaxReturnAboveAssumedWacc: true } : {
        positiveRevenueFcfEbitdaEv: true, netDebtToEbitdaMax: 3 },
    },
    review: { status: 'experimental_proxy', decision: 'research_use_only' },
    metrics: { ...(full ? strategyMetrics(full.net.equity) : {totalReturn:null,cagr:null,maxDrawdown:null,volatility:null,sharpeZeroRf:null}),
      observations: curves[id].length, costBps: 25,
      completedQuarters: quarters.filter(q=>q.mature).length,
      annualizedGrossTradedNotional: full ? trades.reduce((v,t)=>v+t.turnover,0)/years : null },
    reconciliation: { segments: results.map(r=>({...r.segment,quarterlyDailyError:r.compounded-r.net.equity.at(-1).value,...r.gross.reconciliation})) },
    corporateActions: schedule.flatMap(q => q.weights.filter(p => p.corporateAction).map(p => ({
      ticker: p.ticker, executionDate: q.executionDate, ...p.corporateAction }))),
  });
}
const rows = curves.quality_rank;
const ackman=new Map(curves.ackman.map(r=>[r.date,r.value]));
const benchmark=prices.get('SPY'), benchmarkStart=benchmark.get(rows[0].date);
const payload = { version: 'investor-style-dashboard-v4', dataThrough: rows.at(-1).date,
  backtest: { from: rows[0].date, to: rows.at(-1).date, observations: rows.length, costBps: 25,
    curve: rows.map(r => ({ date:r.date, quality_rank:r.value, ackman:ackman.get(r.date)??null, spy:benchmark.get(r.date)/benchmarkStart })) },
  styles, methodology: { strictArchivedVintagePit:false, priceBasis:'adjusted_total_return_close',
    cashRate:0, transactionCostBpsEachSide:25, benchmarkCosts:0, entryCostIncluded:true,
    terminalLiquidation:false, riskFreeRate:0, classification:'exploratory_research_rules_not_actual_fund_returns' },
  lineage: { ...packet.lineage, inputSha256:sha(raw), replayBuilderSha256:sha(fs.readFileSync(fileURLToPath(import.meta.url))),
    engineSha256:sha(engineSource), engineRevision:engineRevision ?? null,
    costEngineSha256:sha(fs.readFileSync(new URL('../server/strategyLab.js',import.meta.url))) },
};
validateInvestorStyleDashboard(payload);
// Validate fully before replacing this small derived snapshot; never write facts or user records.
const bytes = JSON.stringify(payload) + '\n';
const temporary = `${output}.${process.pid}.tmp`;
fs.writeFileSync(temporary, bytes, { flag:'wx' });
fs.renameSync(temporary, output);
console.log(JSON.stringify({ status:'ready', snapshotId:sha(bytes), observations:rows.length,
  metrics:styles.map(s=>({id:s.id,...s.metrics})), bytes:Buffer.byteLength(bytes), sourceWrites:false },null,2));
