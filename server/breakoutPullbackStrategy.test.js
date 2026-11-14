import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { registerInvestmentRoutes } from './investmentRoutes.js';

function createTestApp() {
  const app = express();
  app.use((req, _, next) => {
    if (req.headers['x-test-user']) req.user = { id: req.headers['x-test-user'] };
    next();
  });
  registerInvestmentRoutes(app, {
    date(value) {
      if (value === undefined) return '2026-11-10';
      if (!/^\d{4}-\d{2}-\d{2}$/.test(value ?? '')) {
        throw Object.assign(new Error('invalid_as_of'), { status: 400 });
      }
      return value;
    },
    aiInsights: {},
  });
  return app;
}

test('breakout-pullback route requires auth and serves verified flagship and balanced modes', async t => {
  const app = createTestApp();
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const base = `http://127.0.0.1:${server.address().port}/api/investment/breakout-pullback`;
  assert.equal((await fetch(`${base}?asOf=2026-11-10`)).status, 401);

  const flagRes = await fetch(`${base}?asOf=2026-11-10&mode=flagship`, {
    headers: { 'x-test-user': 'alice' },
  });
  assert.equal(flagRes.status, 200);
  assert.match(flagRes.headers.get('cache-control'), /private.*max-age=300/);
  const flagship = await flagRes.json();

  assert.equal(flagship.version, 'hot-breakout-pullback-v1');
  assert.equal(flagship.status, 'ready');
  assert.equal(flagship.mode, 'flagship');
  assert.equal(flagship.inceptionDate, '2016-11-10');
  assert.equal(flagship.dataThrough, '2026-11-10');
  assert.equal(flagship.backtest.curve.length, 2513);
  assert.ok(Math.abs(flagship.modesSummary.flagship.metrics.endingValue - 8.905892) < 1e-4);
  assert.ok(Math.abs(flagship.modesSummary.balanced.metrics.endingValue - 7.538891) < 1e-4);
  assert.equal(flagship.activeMode.blueprint.length, 5);
  assert.equal(flagship.activeMode.tradeSummary.totalTrades, 618);
  assert.ok(flagship.yearlyReturns.length >= 11);
  assert.ok(Array.isArray(flagship.liveBook.openPositions));
  assert.ok(Array.isArray(flagship.liveBook.pendingWatchlist));
  assert.ok(flagship.liveBook.pendingWatchlist.length > 0);
  for (const item of flagship.liveBook.pendingWatchlist) {
    assert.ok(item.limitBuyPrice > 0);
    assert.ok(item.remainingWatchDays >= 1 && item.remainingWatchDays <= 15);
  }
  // Ensure internal daily mark arrays are never leaked in the HTTP payload
  assert.equal(flagship.trades[0].eodMarksNorm, undefined);

  const balRes = await fetch(`${base}?asOf=2026-11-10&mode=balanced`, {
    headers: { 'x-test-user': 'alice' },
  });
  assert.equal(balRes.status, 200);
  const balanced = await balRes.json();
  assert.equal(balanced.mode, 'balanced');
  assert.equal(balanced.snapshotId, flagship.snapshotId);
  assert.equal(balanced.activeMode.tradeSummary.totalTrades, 449);
  const y2022 = balanced.yearlyReturns.find(r => r.year === 2022);
  assert.ok(y2022 && Math.abs(y2022.balanced - -0.035512) < 1e-4);

  // Validation and snapshot conflict checks
  assert.equal(
    (await fetch(`${base}?asOf=2026-11-10&mode=unknown`, { headers: { 'x-test-user': 'alice' } })).status,
    400,
  );
  assert.equal(
    (await fetch(`${base}?asOf=bad-date`, { headers: { 'x-test-user': 'alice' } })).status,
    400,
  );
  assert.equal(
    (await fetch(`${base}?asOf=2026-11-10&snapshotId=stale`, { headers: { 'x-test-user': 'alice' } })).status,
    409,
  );
});

test('breakout-pullback slices historical asOf without leaking future dates or exits', async t => {
  const app = createTestApp();
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const base = `http://127.0.0.1:${server.address().port}/api/investment/breakout-pullback`;
  const histRes = await fetch(`${base}?asOf=2024-06-28&mode=flagship`, {
    headers: { 'x-test-user': 'alice' },
  });
  assert.equal(histRes.status, 200);
  const hist = await histRes.json();
  assert.equal(hist.status, 'ready');
  assert.equal(hist.dataThrough, '2024-06-28');
  assert.ok(hist.backtest.curve.every(r => r.date <= '2024-06-28'));
  assert.ok(hist.trades.every(tr => tr.entryDate <= '2024-06-28' && tr.exitDate <= '2024-06-28'));
  assert.ok(hist.liveBook.pendingWatchlist.every(w => w.breakoutDate <= '2024-06-28'));

  const earlyRes = await fetch(`${base}?asOf=2016-01-01&mode=flagship`, {
    headers: { 'x-test-user': 'alice' },
  });
  assert.equal(earlyRes.status, 200);
  assert.equal((await earlyRes.json()).status, 'unavailable_before_first_observation');
});

test('breakout-pullback range analysis reconciles stock P&L to daily NAV across arbitrary windows', async t => {
  const app = createTestApp();
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const port = server.address().port;
  const dashUrl = `http://127.0.0.1:${port}/api/investment/breakout-pullback?asOf=2026-11-10`;
  const analysisUrl = `http://127.0.0.1:${port}/api/investment/breakout-pullback/analysis`;

  assert.equal((await fetch(`${analysisUrl}?asOf=2026-11-10`)).status, 401);

  const dash = await (await fetch(dashUrl, { headers: { 'x-test-user': 'alice' } })).json();
  const snap = dash.snapshotId;

  const windows = [
    ['2016-11-10', '2026-11-10'],
    ['2021-12-31', '2022-12-30'],
    ['2020-03-23', '2021-11-19'],
    ['2023-01-03', '2026-11-10'],
  ];

  for (const mode of ['flagship', 'balanced']) {
    for (const [start, end] of windows) {
      const t0 = performance.now();
      const res = await fetch(
        `${analysisUrl}?asOf=2026-11-10&mode=${mode}&snapshotId=${snap}&start=${start}&end=${end}`,
        { headers: { 'x-test-user': 'alice' } },
      );
      const elapsedMs = performance.now() - t0;
      assert.equal(res.status, 200);
      assert.equal(res.headers.get('cache-control'), 'private, no-store');
      assert.ok(elapsedMs < 150, `Expected fast range attribution (<150ms), took ${elapsedMs.toFixed(1)}ms`);

      const body = await res.json();
      assert.equal(body.version, 'breakout-range-attribution-v1');
      assert.equal(body.mode, mode);
      assert.equal(body.snapshotId, snap);
      assert.equal(body.distribution.length, 9);
      const binSum = body.distribution.reduce((acc, b) => acc + b.count, 0);
      assert.equal(binSum, body.tradeStats.stocks);
      assert.ok(Math.abs(body.reconciliation.difference) < 1e-8);
      assert.ok(body.topWinners.length <= 3);
      assert.ok(body.topLosers.length <= 3);
    }
  }

  assert.equal(
    (
      await fetch(
        `${analysisUrl}?asOf=2026-11-10&mode=flagship&snapshotId=stale&start=2020-03-23&end=2021-11-19`,
        { headers: { 'x-test-user': 'alice' } },
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await fetch(
        `${analysisUrl}?asOf=2026-11-10&mode=flagship&snapshotId=${snap}&start=2024-01-02&end=2023-01-03`,
        { headers: { 'x-test-user': 'alice' } },
      )
    ).status,
    400,
  );
});
