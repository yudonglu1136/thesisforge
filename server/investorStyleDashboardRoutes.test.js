import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { registerInvestmentRoutes } from './investmentRoutes.js';

test('investor-style dashboard route is authenticated and returns the reviewed snapshot', async t => {
  const app = express();
  app.use((request, _, next) => {
    if (request.headers['x-test-user']) request.user = { id: request.headers['x-test-user'] };
    next();
  });
  registerInvestmentRoutes(app, {
    date(value) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(value ?? '')) throw Object.assign(new Error('invalid_as_of'), { status: 400 });
      return value;
    },
    aiInsights: {},
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/investment/investor-styles?asOf=2026-09-23`;
  assert.equal((await fetch(base)).status, 401);
  const response = await fetch(base, { headers: { 'x-test-user': 'alice' } });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('cache-control'), /private.*max-age=300/);
  const body = await response.json();
  assert.equal(body.version, 'investor-style-dashboard-v4');
  assert.equal(body.requestedAsOf, '2026-09-23');
  assert.equal(body.backtest.curve.length, 3450);
  assert.equal(body.backtest.from, '2013-01-02');
  assert.equal(body.backtest.to, '2026-09-21');
  assert.deepEqual(body.styles.map(row => row.id), ['quality_rank', 'ackman']);
  const historicResponse = await fetch(
    base.replace('2026-09-23','2024-05-01'),
    { headers: { 'x-test-user': 'alice' } },
  );
  assert.equal(historicResponse.status, 200);
  const historic = await historicResponse.json();
  assert.ok(historic.backtest.curve.every(r=>r.date<='2024-05-01'));
  assert.equal(historic.snapshotId,body.snapshotId);
  assert.equal((await fetch(base+'&snapshotId=stale',{headers:{'x-test-user':'alice'}})).status,409);
});

test('range analysis requires auth, forwards pinned range and never caches failures', async t => {
  const app = express(), calls = [];
  app.use((req, _, next) => { if (req.headers['x-test-user']) req.user = { id: 'alice' }; next(); });
  registerInvestmentRoutes(app, { aiInsights: {}, date: value => value,
    ruleAnalysis: async args => {
      calls.push(args);
      if (args.snapshotId === 'stale') throw Object.assign(new Error('investor_style_snapshot_changed'), { status: 409 });
      return { version: 'rule-range-attribution-v1', ...args };
    } });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/investment/investor-styles/analysis?asOf=2026-09-24&snapshotId=verified&start=2024-01-02&end=2025-01-02`;
  assert.equal((await fetch(base)).status, 401); assert.equal(calls.length, 0);
  const response = await fetch(base, { headers: { 'x-test-user': 'alice' } });
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'private, no-store');
  assert.deepEqual(calls[0], { asOf: '2026-09-24', snapshotId: 'verified', start: '2024-01-02', end: '2025-01-02' });
  const nasdaq = await fetch(base + '&universe=nasdaq100', { headers: { 'x-test-user': 'alice' } });
  assert.equal(nasdaq.status, 200);
  assert.equal(calls[1].universe, 'nasdaq100');
  assert.equal((await nasdaq.json()).universe, 'nasdaq100');
  const stale = await fetch(base.replace('snapshotId=verified', 'snapshotId=stale'), { headers: { 'x-test-user': 'alice' } });
  assert.equal(stale.status, 409); assert.equal(stale.headers.get('cache-control'), 'private, no-store');
});
