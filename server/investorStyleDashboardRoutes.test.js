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
  assert.equal(body.version, 'investor-style-dashboard-v3');
  assert.equal(body.requestedAsOf, '2026-09-23');
  assert.equal(body.backtest.curve.length, 876);
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
