import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { registerInvestmentRoutes } from './investmentRoutes.js';
import { registerRetiredProductRoutes } from './retiredProductRoutes.js';

async function fixture(t) {
  const calls = [];
  const app = express();
  registerRetiredProductRoutes(app);
  app.use((request, _, next) => {
    if (request.headers['x-test-user']) request.user = { id: request.headers['x-test-user'] };
    next();
  });
  const aiInsights = Object.fromEntries(['overview', 'rankings', 'compare', 'company', 'methodology'].map(method => [method, (...args) => {
    calls.push({ method, args });
    return { method, args, snapshotId: 'synthetic-pinned-snapshot' };
  }]));
  registerInvestmentRoutes(app, {
    aiInsights,
    date(value) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(value ?? '') || value > '2026-09-22') {
        throw Object.assign(new Error('invalid_as_of'), { status: 400 });
      }
      return value;
    },
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return { calls, base: `http://127.0.0.1:${server.address().port}`, headers: { 'x-test-user': 'alice' } };
}

test('all AI Insights endpoints require authentication and preserve query snapshot context', async t => {
  const { base, calls, headers } = await fixture(t);
  const query = '?asOf=2026-09-22&quarter=2026Q2&window=8&snapshotId=pinned-artifact&tickers=CRDO,ALAB';
  for (const [path, method] of [
    ['', 'overview'], ['/rankings', 'rankings'], ['/compare', 'compare'],
    ['/companies/ALAB', 'company'], ['/methodology', 'methodology'],
  ]) {
    const url = `${base}/api/investment/ai-insights${path}${query}`;
    assert.equal((await fetch(url)).status, 401);
    const response = await fetch(url, { headers });
    assert.equal(response.status, 200);
    assert.match(response.headers.get('cache-control'), /private.*no-store/);
    const body = await response.json();
    assert.equal(body.method, method);
    if (method !== 'methodology') {
      const received = body.args.at(-1);
      assert.equal(received.asOf, '2026-09-22');
      assert.equal(received.quarter, '2026Q2');
      assert.equal(received.snapshotId, 'pinned-artifact');
    }
    if (method === 'company') assert.equal(body.args[0], 'ALAB');
  }
  assert.equal(calls.length, 5);
});

test('future cutoffs fail before calling the analytics engine and Value Flow is retired', async t => {
  const { base, calls, headers } = await fixture(t);
  assert.equal((await fetch(`${base}/api/investment/ai-insights?asOf=2099-01-01`, { headers })).status, 400);
  const retired = await fetch(`${base}/api/investment/value-flow`);
  assert.equal(retired.status, 410);
  assert.equal(retired.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await retired.json(), { error: 'module_retired' });
  assert.equal(calls.length, 0);
});
