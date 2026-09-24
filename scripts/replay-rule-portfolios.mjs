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
    if (!q.nextExecutionDate) continue;
    const weights = q.positions.map(p => {
      if (!prices.get(p.ticker)?.has(q.executionDate)) throw new Error(`missing_entry_price:${id}:${p.ticker}:${q.executionDate}`);
      const matches = packet.actions.filter(a => a.ticker === p.ticker && String(a.permaticker) === p.permaticker &&
        a.status === 'verified_research_accounting' && a.corporateAction.legalSourceVerified === true &&
        a.corporateAction.effectiveDate > q.executionDate && a.corporateAction.effectiveDate <= q.nextExecutionDate);
      if (matches.length > 1) throw new Error('ambiguous_action');
      const action = matches[0]?.corporateAction ?? q.actions?.find(a => a.ticker === p.ticker && a.permaticker === p.permaticker);
      return { ticker: p.ticker, permaticker: p.permaticker, weight: p.weight,
        ...(action ? { corporateAction: action } : {}) };
    });
    schedule.push({ reportDate: q.quarter, signalDate: q.signalDate, executionDate: q.executionDate,
      nextExecutionDate: q.nextExecutionDate, weights, targetWeights: weights, cashWeight: q.cashWeight,
      ...(weights.length ? {} : { cashReason: 'strategy_rules' }) });
  }
  const endDate = schedule.at(-1).nextExecutionDate;
  const gross = simulateDriftedPortfolio({ rebalances: schedule, tradingDates: dates, priceMaps: prices,
    benchmarkSymbol: 'SPY', endDate, allowExplicitCash: true });
  if (!gross.ok || gross.equity.at(-1).date !== endDate) throw new Error(`replay_failed:${id}:${JSON.stringify(gross.failure ?? gross.error)}`);
  const net = applyStrategyCosts(gross, schedule, 25);
  const compounded = gross.quarterContributions.reduce((nav, q, i) => nav * (1 + q.portfolioReturn) * (1 - net.trades[i].costFraction), 1);
  if (Math.abs(compounded - net.equity.at(-1).value) > 1e-9) throw new Error('quarterly_daily_reconciliation_failed');
  for (const q of quarters) delete q.actions; // only execution receipts below expose applied actions
  curves[id] = net.equity.map((r, i) => ({ ...r, benchmark:gross.equity[i].benchmark }));
  const years = (Date.parse(endDate) - Date.parse(net.equity[0].date)) / (86400000 * 365.25);
  styles.push({ id, quarters, trades: net.trades,
    rule: { methodId: id === 'quality_rank' ? 'quality-rank-sqrt-top10-v1' : 'ackman-quality-improvement-proxy-v1',
      targetCap: id === 'quality_rank' ? .15 : .05, targetCount: id === 'quality_rank' ? 10 : 20,
      rebalance: 'quarterly_next_spy_session_close', scoreBeforeGates: true,
      tieBreaks: id === 'quality_rank' ? ['lower_beta', 'ticker'] : ['ticker'],
      gates: id === 'quality_rank' ? { revenueYoYGreaterThan: .08, operatingMarginAtLeast: .10, fcfMarginAtLeast: .05,
        minAnnualPretaxCapitalReturnAtLeast: .10, legacyPretaxReturnAboveAssumedWacc: true } : {
        positiveRevenueFcfEbitdaEv: true, netDebtToEbitdaMax: 3 },
    },
    review: { status: 'experimental_proxy', decision: 'research_use_only' },
    metrics: { ...strategyMetrics(net.equity), observations: net.equity.length, costBps: 25,
      completedQuarters: schedule.length, annualizedGrossTradedNotional: net.trades.reduce((v,t)=>v+t.turnover,0)/years },
    reconciliation: { quarterlyDailyError: compounded - net.equity.at(-1).value, ...gross.reconciliation },
    corporateActions: schedule.flatMap(q => q.weights.filter(p => p.corporateAction).map(p => ({
      ticker: p.ticker, executionDate: q.executionDate, ...p.corporateAction }))),
  });
}
const rows = curves.quality_rank;
if (rows.length !== curves.ackman.length || rows.some((r,i) => r.date !== curves.ackman[i].date ||
    Math.abs(r.benchmark - curves.ackman[i].benchmark) > 1e-9)) throw new Error('unaligned_comparison');
const payload = { version: 'investor-style-dashboard-v3', dataThrough: rows.at(-1).date,
  backtest: { from: rows[0].date, to: rows.at(-1).date, observations: rows.length, costBps: 25,
    curve: rows.map((r,i) => ({ date:r.date, quality_rank:r.value, ackman:curves.ackman[i].value, spy:r.benchmark })) },
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
