import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { loadInvestorStyleDashboard, validateInvestorStyleDashboard } from './investorStyleDashboard.js';

test('universe is validated and may not relabel an all-market snapshot', () => {
  assert.throws(()=>loadInvestorStyleDashboard({universe:'../all'}),/invalid_rule_universe/);
  assert.throws(()=>loadInvestorStyleDashboard({universe:'nasdaq100',
    file:new URL('./config/investor-style-dashboard.json',import.meta.url)}),/universe_mismatch/);
  assert.equal(loadInvestorStyleDashboard().universe.id,'all');
});

test('three universe snapshots are independent, source-dated and reranked before gates', () => {
  const rows=['all','sp500','nasdaq100'].map(universe=>loadInvestorStyleDashboard({universe}));
  assert.equal(new Set(rows.map(r=>r.snapshotId)).size,3);
  assert.equal(rows[1].backtest.from,'2013-01-02');
  assert.equal(rows[2].backtest.from,'2020-01-02');
  assert.equal(rows[2].universe.basis,'sec_qqq_disclosed_holdings');
  for (const r of rows.slice(1)) {
    assert.throws(()=>loadInvestorStyleDashboard({universe:r.universe.id,snapshotId:rows[0].snapshotId}),/snapshot_changed/);
    for (const s of r.styles) for (const q of s.quarters) {
      assert.ok(q.positions.every(p=>p.universeMember));
      assert.ok(q.populationCount<=q.universeMembership.memberCount);
      if (r.universe.id==='nasdaq100') assert.ok(q.universeMembership.filed<q.signalDate);
    }
  }
  for (const index of [0,1]) {
    assert.notDeepEqual(rows[0].styles[index].quarters.at(-1).positions.map(p=>[p.ticker,p.score]),
      rows[1].styles[index].quarters.at(-1).positions.map(p=>[p.ticker,p.score]));
  }
  const early=loadInvestorStyleDashboard({universe:'nasdaq100',asOf:'2019-12-31'});
  assert.equal(early.status,'unavailable_before_first_observation');
  assert.deepEqual(early.backtest.curve,[]);
  const raw=JSON.parse(fs.readFileSync(new URL('./config/investor-style-nasdaq100.json',import.meta.url)));
  raw.styles[0].quarters[0].universeMembership.filed='2020-02-01';
  assert.throws(()=>validateInvestorStyleDashboard(raw),/invalid/);
});

test('historical cutoff truncates curves, holdings and metrics rather than echoing the date', () => {
  const out = loadInvestorStyleDashboard({ asOf: '2024-05-01' });
  assert.ok(out.backtest.curve.every(r => r.date <= '2024-05-01'));
  for (const style of out.styles) {
    assert.ok(style.quarters.every(q => q.executionDate <= '2024-05-01'));
    assert.equal(style.metrics.observations, out.backtest.curve.filter(r=>Number.isFinite(r[style.id])).length);
    assert.ok(style.metrics.to <= '2024-05-01');
  }
});

test('reviewed rule-portfolio snapshot has aligned curves, metrics and holdings changes', () => {
  const payload = loadInvestorStyleDashboard({ asOf: '2026-09-23' });
  assert.equal(payload.requestedAsOf, '2026-09-23');
  assert.equal(payload.backtest.from, '2013-01-02');
  assert.equal(payload.backtest.curve.length, 3450);
  assert.equal(payload.dataThrough, '2026-09-21');
  assert.deepEqual(payload.styles.map(row => row.id), ['quality_rank', 'ackman']);
  const owner = payload.styles.find(row => row.id === 'quality_rank');
  assert.equal(owner.review.status, 'experimental_proxy');
  assert.equal(owner.rule.methodId, 'quality-rank-sqrt-top10-v1');
  assert.equal(owner.rule.gates.revenueYoYGreaterThan, 0.08);
  assert.equal(owner.rule.targetCap, .15);
  for (const style of payload.styles) {
    assert.equal(style.metrics.costBps, 25);
    assert.equal(style.metrics.observations, payload.backtest.curve.filter(r=>Number.isFinite(r[style.id])).length);
    assert.equal(style.metrics.completedQuarters, style.id==='ackman'?53:54);
    assert.equal(style.quarters.length, 55);
    assert.equal(style.quarters.at(-1).mature, false);
    assert.equal(style.trades.at(-1).date, '2026-07-01');
    assert.equal(style.trades.length, 55);
    for (let index = 1; index < style.quarters.length; index++) {
      const previous = new Set(style.quarters[index - 1].tickers);
      const current = style.quarters[index];
      assert.deepEqual(current.entered, current.tickers.filter(ticker => !previous.has(ticker)));
      assert.deepEqual(current.retained, current.tickers.filter(ticker => previous.has(ticker)));
    }
  }
  assert.equal(payload.methodology.strictArchivedVintagePit, false);
  assert.equal(payload.lineage.sourceWrites, false);
});

test('snapshot validation fails closed on missing values and misaligned observations', () => {
  const valid = loadInvestorStyleDashboard();
  assert.throws(() => validateInvestorStyleDashboard({ ...valid, version: 'wrong' }), /investor_style_snapshot_invalid/);
  const broken = structuredClone(valid);
  broken.backtest.curve[4].spy = null;
  assert.throws(() => validateInvestorStyleDashboard(broken), /investor_style_snapshot_invalid/);
  const misleading = structuredClone(valid);
  delete misleading.styles.find(row => row.id === 'quality_rank').review;
  assert.throws(() => validateInvestorStyleDashboard(misleading), /investor_style_snapshot_invalid/);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'investor-style-'));
  const file = path.join(dir, 'missing.json');
  assert.throws(() => loadInvestorStyleDashboard({ file }), /investor_style_snapshot_unavailable/);
  fs.rmdirSync(dir);
});

test('score contributions, allocation and source periods reconcile for every selected position', () => {
  const out = loadInvestorStyleDashboard({asOf:'2026-09-24'});
  for(const s of out.styles) for(const q of s.quarters) {
    assert.ok(Math.abs(q.positions.reduce((v,p)=>v+p.weight,0)+q.cashWeight-1)<1e-12);
    for(const p of q.positions) {
      assert.ok(Math.abs(p.inputs.reduce((v,i)=>v+i.percentile*i.weight,0)-p.score)<1e-12);
      assert.ok(Object.values(p.sourceDates).every(d=>d<=q.quarter));
    }
  }
  assert.equal(out.styles[0].quarters.at(-1).positions[0].ticker,'FICO');
  assert.ok(Math.abs(out.styles[0].quarters.at(-1).positions[0].weight-.14074410303990587)<1e-12);
});

test('invalid dates, stale snapshots, corruption and absent early history are explicit', () => {
  assert.throws(()=>loadInvestorStyleDashboard({asOf:'2026-02-30'}),/invalid_as_of/);
  assert.throws(()=>loadInvestorStyleDashboard({snapshotId:'old'}),/snapshot_changed/);
  const old=loadInvestorStyleDashboard({asOf:'2012-01-01'});
  assert.equal(old.status,'unavailable_before_first_observation');
  assert.equal(old.backtest.curve.length,0);
  assert.ok(old.styles.every(s=>s.quarters.length===0 && s.corporateActions.length===0));
  for(const corrupt of [p=>p.styles[0].quarters[0].positions[0].weight=.9,
    p=>p.styles[0].quarters[0].positions[0].inputs[0].contribution=9,
    p=>p.styles[0].quarters[0].positions[0].sourceDates.ttm='2099-01-01',
    p=>p.styles[0].quarters[0].positions[0].sourcePeriods.ttm='2099-01-01',
    p=>p.styles[0].quarters[0].positions[0].inputs[0].percentile=-1,
    p=>p.styles[0].metrics.totalReturn=9]) {
    const p=loadInvestorStyleDashboard();corrupt(p);
    assert.throws(()=>validateInvestorStyleDashboard(p),/snapshot_invalid/);
  }
});

test('late independent requests and mutated caller objects do not poison the cached snapshot', () => {
  const a=loadInvestorStyleDashboard({asOf:'2024-05-01'}), b=loadInvestorStyleDashboard({asOf:'2026-09-23'});
  assert.equal(a.snapshotId,b.snapshotId);
  a.styles[0].quarters[0].positions[0].score=99;
  assert.notEqual(loadInvestorStyleDashboard().styles[0].quarters[0].positions[0].score,99);
  assert.ok(a.styles.every(s=>s.corporateActions.every(c=>c.effectiveDate<='2024-05-01')));
  assert.equal(a.styles[0].reconciliation,null);
  assert.equal(b.styles[0].metrics.observations,3450);
});

test('2013 and 2014 are actual daily history, while the declared CVR gap is never compounded', () => {
  for (const year of [2013,2014]) {
    const p=loadInvestorStyleDashboard({asOf:`${year}-12-31`});
    assert.equal(p.status,'ready');
    assert.ok(p.backtest.curve.filter(r=>r.date.startsWith(`${year}-`)).length>=250);
    for(const s of p.styles) assert.ok(Number.isFinite(s.metrics.totalReturn));
    assert.ok(p.backtest.curve.every(r=>r.quality_rank>0 && r.ackman>0));
  }
  const p=loadInvestorStyleDashboard();
  assert.equal(p.styles[1].metrics.totalReturn,null);
  assert.equal(p.styles[1].metrics.annualizedGrossTradedNotional,null);
  assert.equal(p.backtest.curve.find(r=>r.date==='2019-11-20').ackman,null);
  for(const mutate of [x=>x.backtest.curve.find(r=>r.date==='2019-11-20').ackman=1,
    x=>x.backtest.curve.find(r=>r.date==='2014-01-02').ackman=null,
    x=>x.styles[1].coverage.gaps=[], x=>x.styles[1].coverage.segments[1].from='2019-11-20',
    x=>x.styles[1].metrics.totalReturn=1]) {
    const bad=structuredClone(p); mutate(bad);
    assert.throws(()=>validateInvestorStyleDashboard(bad),/snapshot_invalid/);
  }
});
