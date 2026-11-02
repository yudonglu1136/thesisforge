import test from 'node:test';
import assert from 'node:assert/strict';
import { projectAdminHealth } from './adminHealthProjection.js';

test('admin uses public economic freshness without hiding curve or price failures', () => {
  const input = { jobs: [{id:'guru_snapshots',status:'failed'}, {id:'valuation_database',status:'failed'}, {id:'guru_backtest_refresh',status:'success'}, {id:'portfolio_sync',status:'unknown'}] };
  const result = projectAdminHealth(input, {generatedAt:'2026-10-07', status:'failed', modules:[
    {id:'guru_data',state:'healthy',freshness:{latestAt:'2026-08-27'}},
    {id:'valuation',state:'healthy'},
    {id:'guru_backtests',state:'failed',message:'Stale curves'},
    {id:'market_prices',state:'failed',message:'Stale prices'},
  ]});
  assert.equal(result.jobs.find(j=>j.id==='guru_snapshots').status,'success');
  assert.equal(result.jobs.find(j=>j.id==='valuation_database').status,'success');
  assert.equal(result.jobs.find(j=>j.id==='guru_backtest_refresh').status,'failed');
  assert.equal(result.jobs.find(j=>j.id==='portfolio_sync').status,'unknown');
  assert.equal(result.jobs.find(j=>j.id==='market_prices').status,'failed');
  assert.equal(result.ok,false);
  assert.equal(input.jobs[0].status,'failed');
});

test('missing verification never upgrades legacy status to healthy', () => {
  const result=projectAdminHealth({status:'failed',ok:false,jobs:[{id:'guru_snapshots',status:'failed'}]}, null);
  assert.equal(result.status,'failed');
  assert.equal(result.jobs[0].status,'failed');
});

test('API reachability is independent of failed datasets and preserves source/run dates', () => {
  const result=projectAdminHealth({generatedAt:'2026-11-02',database:{status:'success'},jobs:[
    {id:'guru_snapshots',status:'failed',finishedAt:'2026-09-12'},
  ]},{status:'failed',generatedAt:'2026-11-02',modules:[
    {id:'guru_data',state:'healthy',freshness:{sourceAsOf:'2026-08-27',observedAt:'2026-09-12'}},
    {id:'market_prices',state:'failed'},
  ]});
  assert.equal(result.service.status,'success');
  assert.equal(result.status,'failed');
  assert.equal(result.jobs[0].sourceAsOf,'2026-08-27');
  assert.equal(result.jobs[0].finishedAt,'2026-09-12');
  assert.equal(result.jobs[0].lastRunStatus,'failed');
  assert.equal(result.jobs[1].label,'Guru market prices');
});
