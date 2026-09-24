import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { strategyMetrics } from './strategyLab.js';
import { qualityRankWeights } from './rulePortfolioWeights.js';

const defaultFile = new URL('./config/investor-style-dashboard.json', import.meta.url);

function fail(code, status = 503) {
  throw Object.assign(new Error(code), { status });
}

const date = value => /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') && Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;
const near = (a, b) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) < 1e-9;
const invalid = () => fail('investor_style_snapshot_invalid');

export function validateInvestorStyleDashboard(payload) {
  if (payload?.version !== 'investor-style-dashboard-v3') invalid();
  const styles = Array.isArray(payload.styles) ? payload.styles : [];
  const curve = Array.isArray(payload.backtest?.curve) ? payload.backtest.curve : [];
  const ids = styles.map(row => row.id);
  if (ids.join(',') !== 'quality_rank,ackman' || curve.length < 2 ||
      !/^[a-f0-9]{64}$/.test(payload.lineage?.sourceGeneration) || payload.lineage.sourceWrites !== false ||
      payload.methodology?.strictArchivedVintagePit !== false) {
    fail('investor_style_snapshot_invalid');
  }
  for (const row of styles) {
    if (!Array.isArray(row.quarters) || !row.quarters.length ||
        row.metrics?.observations !== curve.length ||
        row.review?.status !== 'experimental_proxy' || !Array.isArray(row.trades)) {
      fail('investor_style_snapshot_invalid');
    }
    const computed = strategyMetrics(curve.map(r => ({ date: r.date, value: r[row.id] })));
    if (!computed) invalid();
    for (const k of ['totalReturn', 'cagr', 'maxDrawdown', 'volatility', 'sharpeZeroRf']) {
      if (computed[k] === null ? row.metrics[k] !== null : !near(computed[k], row.metrics[k])) invalid();
    }
    for (const [i, q] of row.quarters.entries()) {
      if (!date(q.quarter) || !date(q.signalDate) || !date(q.executionDate) || q.signalDate > q.quarter ||
          q.executionDate <= q.signalDate || (i && q.executionDate <= row.quarters[i - 1].executionDate) ||
          !Array.isArray(q.positions) || q.positions.length > (row.id === 'quality_rank' ? 10 : 20) ||
          new Set(q.positions.map(p => p.ticker)).size !== q.positions.length) invalid();
      if (!near(q.positions.reduce((n, p) => n + p.weight, 0) + q.cashWeight, 1) || q.cashWeight < -1e-9) invalid();
      for (const p of q.positions) {
        if (!/^[A-Z0-9.-]+$/.test(p.ticker) || !p.permaticker || !Number.isInteger(p.rank) || p.rank < 1 ||
            !Number.isFinite(p.weight) || p.weight <= 0 || p.weight > (row.id === 'quality_rank' ? .15 : .05) + 1e-9 ||
            !Number.isFinite(p.score) || !Array.isArray(p.inputs) || !p.inputs.length ||
            !near(p.inputs.reduce((v, r) => v + r.contribution, 0), p.score)) invalid();
        for (const evidence of [p.sourceDates, p.sourcePeriods]) {
          if (!evidence || typeof evidence !== 'object' || !Object.keys(evidence).length ||
              !Object.values(evidence).every(d => date(d) && d <= q.signalDate)) invalid();
        }
        if (!near(p.inputs.reduce((v, r) => v + r.weight, 0), 1)) invalid();
        for (const input of p.inputs) {
          if (![input.value, input.percentile, input.weight, input.contribution].every(Number.isFinite) ||
              input.percentile < 0 || input.percentile > 1 || input.weight < 0 || input.weight > 1 ||
              !near(input.percentile * input.weight, input.contribution)) invalid();
        }
      }
      if (row.id === 'quality_rank') {
        const expected = qualityRankWeights(q.positions);
        if (!near(expected.cashWeight, q.cashWeight) || expected.positions.some(p =>
          !near(p.weight, q.positions.find(r => r.ticker === p.ticker).weight))) invalid();
      }
    }
  }
  for (let index = 0; index < curve.length; index++) {
    const row = curve[index];
    if (!date(row.date) ||
        (index && row.date <= curve[index - 1].date) ||
        !['quality_rank', 'ackman', 'spy'].every(key => Number.isFinite(row[key]) && row[key] > 0)) {
      fail('investor_style_snapshot_invalid');
    }
  }
  return payload;
}

let cached;
export function loadInvestorStyleDashboard({ file = defaultFile, asOf = null, snapshotId = null } = {}) {
  if (asOf !== null && !date(asOf)) fail('invalid_as_of', 400);
  let payload, id;
  try {
    const stat = fs.statSync(file), key = `${file}:${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
    if (cached?.key !== key) {
      const source = fs.readFileSync(file, 'utf8');
      payload = validateInvestorStyleDashboard(JSON.parse(source));
      id = createHash('sha256').update(source).digest('hex');
      cached = { key, payload, id };
    }
    ({ payload, id } = cached);
  } catch (error) {
    if (error.status) throw error;
    fail('investor_style_snapshot_unavailable');
  }
  if (snapshotId && snapshotId !== id) fail('investor_style_snapshot_changed', 409);
  const cutoff = asOf ?? payload.dataThrough;
  const curve = payload.backtest.curve.filter(r => r.date <= cutoff);
  const years = curve.length > 1 ? (Date.parse(curve.at(-1).date) - Date.parse(curve[0].date)) / (86400000 * 365.25) : 0;
  const styles = payload.styles.map(style => {
    const quarters = style.quarters.filter(q => q.executionDate <= cutoff).map(q => ({ ...q,
      mature: !!q.nextExecutionDate && q.nextExecutionDate <= (curve.at(-1)?.date ?? ''),
    }));
    const trades = style.trades.filter(t => t.date <= (curve.at(-1)?.date ?? ''));
    return { ...style, trades, quarters,
      corporateActions: (style.corporateActions ?? []).filter(a => a.effectiveDate <= cutoff),
      reconciliation: curve.length === payload.backtest.curve.length ? style.reconciliation : null,
      metrics: { ...strategyMetrics(curve.map(r => ({ date: r.date, value: r[style.id] }))),
      costBps: 25, observations: curve.length, from: curve[0]?.date ?? null, to: curve.at(-1)?.date ?? null,
      completedQuarters: quarters.filter(q => q.mature).length,
      annualizedGrossTradedNotional: years > 0 ? trades.reduce((v, t) => v + t.turnover, 0) / years : null,
    } };
  });
  return structuredClone({ ...payload, snapshotId: id, requestedAsOf: asOf,
    status: curve.length >= 2 ? 'ready' : 'unavailable_before_first_observation',
    dataThrough: curve.at(-1)?.date ?? null, styles,
    backtest: { ...payload.backtest, curve, observations: curve.length, from: curve[0]?.date ?? null,
      to: curve.at(-1)?.date ?? null, benchmark: { id: 'spy', metrics: strategyMetrics(curve.map(r => ({ date: r.date, value: r.spy }))) } },
  });
}
