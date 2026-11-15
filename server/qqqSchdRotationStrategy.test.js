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
      if (value === undefined) return '2026-11-13';
      if (!/^\d{4}-\d{2}-\d{2}$/.test(value ?? '')) {
        throw Object.assign(new Error('invalid_as_of'), { status: 400 });
      }
      return value;
    },
    aiInsights: {},
  });
  return app;
}

test('qqq-schd-rotation route requires auth and serves verified M6, M4, M7 across Live 2011 and Full 27Y windows', async t => {
  const app = createTestApp();
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const base = `http://127.0.0.1:${server.address().port}/api/investment/qqq-schd-rotation`;
  assert.equal((await fetch(`${base}?asOf=2026-11-13`)).status, 401);

  const m6Res = await fetch(`${base}?asOf=2026-11-13&mode=m6&window=live_2011`, {
    headers: { 'x-test-user': 'alice' },
  });
  assert.equal(m6Res.status, 200);
  assert.match(m6Res.headers.get('cache-control'), /private.*max-age=300/);
  const m6Live = await m6Res.json();

  assert.equal(m6Live.version, 'qqq-schd-rotation-v1');
  assert.equal(m6Live.status, 'ready');
  assert.equal(m6Live.selectedMode, 'm6');
  assert.equal(m6Live.window, 'live_2011');
  assert.equal(m6Live.liveInceptionDate, '2011-10-20');
  assert.equal(m6Live.fullInceptionDate, '2000-01-03');
  assert.equal(m6Live.dataThrough, '2026-11-13');
  assert.equal(m6Live.backtest.curve.length, 3789);

  // Verified M6 Live ETF metrics (2011-10-20 to 2026-11-13)
  assert.ok(Math.abs(m6Live.mode.metrics.cagr - 0.205678) < 1e-4);
  assert.ok(Math.abs(m6Live.mode.metrics.endingMultiple - 16.7441) < 1e-3);
  assert.equal(m6Live.mode.metrics.sharpe, 1.015);
  assert.equal(m6Live.mode.metrics.sortino, 1.47);
  assert.ok(Math.abs(m6Live.mode.metrics.maxDrawdown - -0.285593) < 1e-4);
  assert.equal(m6Live.mode.metrics.ulcerIndex, 5.47);
  assert.equal(m6Live.mode.metrics.switchCount, 11);
  assert.ok(Math.abs(m6Live.mode.metrics.winRate5y - 0.9415) < 1e-3);
  assert.equal(m6Live.mode.switches.length, 11);
  assert.equal(m6Live.mode.allSwitches27y.length, 15);

  // Verified M4 and M7 Live summaries bundled in same payload
  assert.ok(Math.abs(m6Live.modesSummary.m4.metrics.cagr - 0.213887) < 1e-4);
  assert.ok(Math.abs(m6Live.modesSummary.m4.metrics.endingMultiple - 18.5465) < 1e-3);
  assert.equal(m6Live.modesSummary.m4.metrics.sharpe, 1.048);
  assert.equal(m6Live.modesSummary.m4.metrics.switchCount, 5);
  assert.ok(Math.abs(m6Live.modesSummary.m7.metrics.cagr - 0.199107) < 1e-4);
  assert.ok(Math.abs(m6Live.modesSummary.m7.metrics.endingMultiple - 15.4207) < 1e-3);
  assert.equal(m6Live.modesSummary.m7.metrics.sharpe, 0.97);

  // Live Radar as of 2026-11-13
  assert.equal(m6Live.liveRadar.asOfDate, '2026-11-13');
  assert.equal(m6Live.liveRadar.qqqClose, 679.89);
  assert.equal(m6Live.liveRadar.allocations.m6.qqqWeight, 0);
  assert.equal(m6Live.liveRadar.allocations.m6.schdWeight, 1);
  assert.equal(m6Live.liveRadar.allocations.m7.qqqWeight, 0.5);
  assert.equal(m6Live.canonicalComparison.length, 12);
  assert.equal(m6Live.regimeAttribution.length, 10);
  assert.equal(m6Live.taxSensitivity.length, 7);
  assert.equal(m6Live.robustnessGrid.cellCount, 25);

  // Full 27-year Dot-Com window (2000-01-03 to 2026-11-13)
  const fullRes = await fetch(`${base}?asOf=2026-11-13&mode=m6&window=full_2000`, {
    headers: { 'x-test-user': 'alice' },
  });
  assert.equal(fullRes.status, 200);
  const m6Full = await fullRes.json();
  assert.equal(m6Full.backtest.curve.length, 6758);
  assert.ok(Math.abs(m6Full.mode.metrics.cagr - 0.146313) < 1e-4);
  assert.ok(Math.abs(m6Full.mode.metrics.endingMultiple - 39.1691) < 1e-3);
  assert.equal(m6Full.mode.metrics.sharpe, 0.641);
  assert.ok(Math.abs(m6Full.mode.metrics.maxDrawdown - -0.534061) < 1e-4);
  assert.equal(m6Full.mode.switches.length, 15);

  // Validation and snapshot conflict checks
  assert.equal(
    (await fetch(`${base}?asOf=2026-11-13&mode=invalid`, { headers: { 'x-test-user': 'alice' } })).status,
    400,
  );
  assert.equal(
    (await fetch(`${base}?asOf=2026-11-13&window=invalid`, { headers: { 'x-test-user': 'alice' } })).status,
    400,
  );
  assert.equal(
    (await fetch(`${base}?asOf=2026-11-13&snapshotId=stale`, { headers: { 'x-test-user': 'alice' } })).status,
    409,
  );
});

test('qqq-schd-rotation historical asOf cutoff slices without future leakage and custom range analysis reconciles', async t => {
  const app = createTestApp();
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const port = server.address().port;
  const base = `http://127.0.0.1:${port}/api/investment/qqq-schd-rotation`;

  const histRes = await fetch(`${base}?asOf=2024-06-28&mode=m6&window=live_2011`, {
    headers: { 'x-test-user': 'alice' },
  });
  assert.equal(histRes.status, 200);
  const hist = await histRes.json();
  assert.equal(hist.dataThrough, '2024-06-28');
  assert.ok(hist.backtest.curve.every(r => r.date <= '2024-06-28'));
  assert.ok(hist.mode.switches.every(sw => sw.date <= '2024-06-28' && sw.nextSwitchDate <= '2024-06-28'));

  const earlyRes = await fetch(`${base}?asOf=2010-01-01&mode=m6&window=live_2011`, {
    headers: { 'x-test-user': 'alice' },
  });
  assert.equal(earlyRes.status, 200);
  assert.equal((await earlyRes.json()).status, 'unavailable_before_first_observation');

  const dash = await (await fetch(`${base}?asOf=2026-11-13`, { headers: { 'x-test-user': 'alice' } })).json();

  // 2022 Rate-Shock Tech Bear custom window (snaps weekend start 2021-11-19 to 2022-12-28)
  const bearRes = await fetch(
    `${base}/analysis?asOf=2026-11-13&mode=m6&window=live_2011&snapshotId=${dash.snapshotId}&start=2021-11-19&end=2022-12-28`,
    { headers: { 'x-test-user': 'alice' } },
  );
  assert.equal(bearRes.status, 200);
  const bear = await bearRes.json();
  assert.equal(bear.version, 'qqq-schd-range-attribution-v1');
  assert.equal(bear.start, '2021-11-19');
  assert.equal(bear.end, '2022-12-28');
  assert.ok(Math.abs(bear.metrics.totalReturn - -0.192) < 0.002);
  assert.ok(Math.abs(bear.benchmarks.qqq.totalReturn - -0.351) < 0.002);
  assert.ok(bear.comparison.excessReturnVsQqq > 0.15);
  assert.equal(bear.curve[0].m6, 1);
  assert.equal(bear.switchesInRange.length, 4);

  // Calendar weekend date snapping check (2022-01-01 -> 2022-01-03, 2022-12-31 -> 2022-12-30)
  const snapRes = await fetch(
    `${base}/analysis?asOf=2026-11-13&mode=m4&window=live_2011&snapshotId=${dash.snapshotId}&start=2022-01-01&end=2022-12-31`,
    { headers: { 'x-test-user': 'alice' } },
  );
  assert.equal(snapRes.status, 200);
  const snap = await snapRes.json();
  assert.equal(snap.start, '2022-01-03');
  assert.equal(snap.end, '2022-12-30');
});
