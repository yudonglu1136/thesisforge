import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { strategyMetrics } from './strategyLab.js';
import { qualityRankWeights } from './rulePortfolioWeights.js';
import { ruleSegments, ruleRangeCovered, emptyRuleMetrics } from './rulePortfolioCoverage.js';

const defaultFile = new URL('./config/investor-style-dashboard.json', import.meta.url);
const universeFiles = { all:defaultFile, sp500:new URL('./config/investor-style-sp500.json',import.meta.url),
  nasdaq100:new URL('./config/investor-style-nasdaq100.json',import.meta.url) };
export const ruleUniverses = Object.freeze([
  {id:'all',status:'ready',basis:'eligible_us_common_stocks'},
  {id:'sp500',status:'ready',basis:'historical_effective_membership_current_vintage'},
  {id:'nasdaq100',status:'ready',basis:'sec_qqq_disclosed_holdings'},
]);

function fail(code, status = 503) {
  throw Object.assign(new Error(code), { status });
}

const date = value => /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') && Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString().slice(0, 10) === value;
const near = (a, b) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) < 1e-9;
const invalid = () => fail('investor_style_snapshot_invalid');

export function validateInvestorStyleDashboard(payload) {
  if (!['investor-style-dashboard-v3','investor-style-dashboard-v4'].includes(payload?.version)) invalid();
  const styles = Array.isArray(payload.styles) ? payload.styles : [];
  const curve = Array.isArray(payload.backtest?.curve) ? payload.backtest.curve : [];
  const ids = styles.map(row => row.id);
  const universe=payload.universe?.id ?? 'all';
  if (!['all','sp500','nasdaq100'].includes(universe)) invalid();
  if (universe==='sp500' && (payload.universe.version!=='rule-universe-v1' ||
      payload.universe.basis!=='historical_effective_membership_current_vintage' ||
      payload.universe.currentConstituentsBackfilled!==false)) invalid();
  if (universe==='nasdaq100' && (payload.universe.version!=='rule-universe-v1' ||
      payload.universe.basis!=='sec_qqq_disclosed_holdings' ||
      payload.universe.currentConstituentsBackfilled!==false)) invalid();
  if (ids.join(',') !== 'quality_rank,ackman' || curve.length < 2 ||
      !/^[a-f0-9]{64}$/.test(payload.lineage?.sourceGeneration) || payload.lineage.sourceWrites !== false ||
      payload.methodology?.strictArchivedVintagePit !== false) {
    fail('investor_style_snapshot_invalid');
  }
  for (const row of styles) {
    if (!Array.isArray(row.quarters) || !row.quarters.length ||
        row.metrics?.observations !== curve.filter(r=>Number.isFinite(r[row.id])).length ||
        row.review?.status !== 'experimental_proxy' || !Array.isArray(row.trades)) {
      fail('investor_style_snapshot_invalid');
    }
    if (payload.version==='investor-style-dashboard-v4') {
      const segments=ruleSegments(row,curve), gaps=row.coverage?.gaps;
      if (!Array.isArray(gaps) || !segments.length || segments[0].from!==curve[0].date || segments.at(-1).to!==curve.at(-1).date) invalid();
      for (const [i,s] of segments.entries()) {
        if (!date(s.from)||!date(s.to)||s.from>=s.to || (i && s.from<=segments[i-1].to) ||
            !curve.some(r=>r.date===s.from)||!curve.some(r=>r.date===s.to) ||
            !row.trades.some(t=>t.date===s.from)) invalid();
      }
      for (const g of gaps) if (!date(g.from)||!date(g.to)||g.from>g.to||!g.reason||!g.sourceUrl) invalid();
      for (const r of curve) {
        const covered=segments.filter(s=>s.from<=r.date && s.to>=r.date).length;
        const gap=gaps.filter(g=>g.from<=r.date && g.to>=r.date).length;
        if (covered+gap!==1 || (gap && r[row.id]!==null) || (covered && !(r[row.id]>0))) invalid();
      }
    }
    const computed = ruleRangeCovered(row,curve,curve[0].date,curve.at(-1).date)
      ? strategyMetrics(curve.map(r => ({ date: r.date, value: r[row.id] }))) : emptyRuleMetrics();
    if (!computed) invalid();
    for (const k of ['totalReturn', 'cagr', 'maxDrawdown', 'volatility', 'sharpeZeroRf']) {
      if (computed[k] === null ? row.metrics[k] !== null : !near(computed[k], row.metrics[k])) invalid();
    }
    for (const [i, q] of row.quarters.entries()) {
      if (universe==='sp500') {
        const m=q.universeMembership;
        if (m?.id!==universe || !date(m.snapshotDate) || m.snapshotDate>q.signalDate ||
            m.effectiveThrough!==q.signalDate || !(m.memberCount>=400 && m.memberCount<=550) ||
            !/^[a-f0-9]{64}$/.test(m.fingerprint) || q.positions.some(p=>p.universeMember!==true)) invalid();
      }
      if (universe==='nasdaq100') {
        const m=q.universeMembership;
        if (m?.id!==universe || !date(m.snapshotDate) || !date(m.filed) ||
            m.snapshotDate>m.filed || m.filed>=q.signalDate || m.effectiveThrough!==q.signalDate ||
            !(m.memberCount>=95 && m.memberCount<=115) ||
            !/^[a-f0-9]{64}$/.test(m.fingerprint) || !/^[a-f0-9]{64}$/.test(m.sourceSha256) ||
            !/^https:\/\/www\.sec\.gov\/Archives\/edgar\/data\/1067839\//.test(m.sourceUrl) ||
            q.positions.some(p=>p.universeMember!==true)) invalid();
      }
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
        !['quality_rank', 'ackman', 'spy'].every(key =>
          (payload.version==='investor-style-dashboard-v4' && key!=='spy' && row[key]===null) ||
          (Number.isFinite(row[key]) && row[key] > 0))) {
      fail('investor_style_snapshot_invalid');
    }
  }
  return payload;
}

const caches=new Map();
export function loadInvestorStyleDashboard({ file = null, asOf = null, snapshotId = null, universe='all' } = {}) {
  if (asOf !== null && !date(asOf)) fail('invalid_as_of', 400);
  const option=ruleUniverses.find(r=>r.id===universe);
  if (!option) fail('invalid_rule_universe',400);
  if (option.status!=='ready') {
    if (snapshotId) fail('investor_style_snapshot_changed',409);
    return {status:'universe_unavailable',universe:option,universeOptions:ruleUniverses,
      requestedAsOf:asOf,snapshotId:null,styles:[],backtest:{curve:[]}};
  }
  file ??= universeFiles[universe];
  let payload, id;
  try {
    const stat = fs.statSync(file), key = `${file}:${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
    let cached=caches.get(String(file));
    if (cached?.key !== key) {
      const source = fs.readFileSync(file, 'utf8');
      payload = validateInvestorStyleDashboard(JSON.parse(source));
      id = createHash('sha256').update(source).digest('hex');
      cached = { key, payload, id };
      caches.set(String(file),cached);
    }
    ({ payload, id } = cached);
  } catch (error) {
    if (error.status) throw error;
    fail('investor_style_snapshot_unavailable');
  }
  if ((payload.universe?.id ?? 'all')!==universe) fail('investor_style_universe_mismatch',409);
  if (snapshotId && snapshotId !== id) fail('investor_style_snapshot_changed', 409);
  const cutoff = asOf ?? payload.dataThrough;
  const curve = payload.backtest.curve.filter(r => r.date <= cutoff);
  const years = curve.length > 1 ? (Date.parse(curve.at(-1).date) - Date.parse(curve[0].date)) / (86400000 * 365.25) : 0;
  const styles = payload.styles.map(style => {
    const full=curve.length>=2 && ruleRangeCovered(style,curve,curve[0].date,curve.at(-1).date);
    const coverage=style.coverage ? {
      segments:style.coverage.segments.filter(s=>s.from<=cutoff).map(s=>({...s,to:s.to<cutoff?s.to:curve.at(-1)?.date})),
      gaps:style.coverage.gaps.filter(g=>g.from<=cutoff).map(g=>({...g,to:g.to<cutoff?g.to:cutoff})),
    } : undefined;
    const quarters = style.quarters.filter(q => q.executionDate <= cutoff).map(q => ({ ...q,
      mature: !!q.nextExecutionDate && q.nextExecutionDate <= (curve.at(-1)?.date ?? '') && !!ruleRangeCovered(style,curve,q.executionDate,q.nextExecutionDate),
    }));
    const trades = style.trades.filter(t => t.date <= (curve.at(-1)?.date ?? ''));
    return { ...style, trades, quarters, ...(coverage?{coverage}:{}),
      corporateActions: (style.corporateActions ?? []).filter(a => a.effectiveDate <= cutoff),
      reconciliation: curve.length === payload.backtest.curve.length ? style.reconciliation : null,
      metrics: { ...(full?strategyMetrics(curve.map(r => ({ date: r.date, value: r[style.id] }))):emptyRuleMetrics()),
      status:full?'available':'incomplete_history',
      costBps: 25, observations: curve.filter(r=>Number.isFinite(r[style.id])).length, from: curve[0]?.date ?? null, to: curve.at(-1)?.date ?? null,
      completedQuarters: quarters.filter(q => q.mature).length,
      annualizedGrossTradedNotional: full && years > 0 ? trades.reduce((v, t) => v + t.turnover, 0) / years : null,
    } };
  });
  return structuredClone({ ...payload, snapshotId: id, requestedAsOf: asOf,
    universe:payload.universe ?? option,universeOptions:ruleUniverses,
    status: curve.length >= 2 ? 'ready' : 'unavailable_before_first_observation',
    dataThrough: curve.at(-1)?.date ?? null, styles,
    backtest: { ...payload.backtest, curve, observations: curve.length, from: curve[0]?.date ?? null,
      to: curve.at(-1)?.date ?? null, benchmark: { id: 'spy', metrics: strategyMetrics(curve.map(r => ({ date: r.date, value: r.spy }))) } },
  });
}
