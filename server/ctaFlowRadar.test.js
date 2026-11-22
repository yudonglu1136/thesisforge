import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import {
  CTA_FLOW_RADAR_VERSION,
  CTA_RADAR_ASSETS,
  CTA_RADAR_HORIZONS,
  loadCtaFlowRadarDashboard,
  loadCtaFlowRadarDashboardLive,
} from './ctaFlowRadar.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

test('loads canonical 2026-11-20 Rob Carver CTA Flow Radar for SPY and QQQ with exact validated numbers', () => {
  const dash = loadCtaFlowRadarDashboard({ asOf: '2026-11-20', asset: 'SPY', horizon: '10D' });
  assert.equal(dash.version, CTA_FLOW_RADAR_VERSION);
  assert.equal(dash.asOfDate, '2026-11-20');
  assert.equal(dash.selectedAsset, 'SPY');
  assert.equal(dash.selectedHorizon, '10D');
  assert.deepEqual(dash.availableAssets, [...CTA_RADAR_ASSETS]);
  assert.deepEqual(dash.availableHorizons, [...CTA_RADAR_HORIZONS]);
  assert.equal(dash.runtimeCheckpoint, undefined, 'internal runtimeCheckpoint must not leak to API payload');

  // PIT 13F CTA scale calibration (31 institutions, T+45 lag, $112.39B -> $673.42B)
  assert.equal(dash.pit13fScale.trackedInstitutionCount, 31);
  assert.equal(dash.pit13fScale.statutoryReportingLagDays, 45);
  assert.equal(dash.pit13fScale.q1_2014CtaTrendCoreB, 112.39);
  assert.equal(dash.pit13fScale.latestCtaTrendCoreB, 673.42);
  assert.equal(dash.pit13fScale.scaleGrowthMultiplier, 5.18);
  assert.ok(dash.pit13fScale.quarters.length >= 50);

  // SPY live 2026-11-20 state & signals
  const spy = dash.assets.SPY;
  assert.equal(spy.liveState.spotClose, 689.81);
  assert.equal(spy.liveState.vixClose, 35.89);
  assert.equal(spy.liveState.vixVix3mRatio, 1.16);
  assert.equal(spy.liveState.vixBackwardation, true);
  assert.equal(spy.liveState.fCarver, -10.56);
  assert.equal(spy.liveState.fSma, -20);
  assert.equal(spy.liveState.carverForecast12YrPercentile, 2.2);
  assert.equal(spy.liveState.marginalAsymmetry3Pct5d, 1.87);
  assert.equal(spy.liveState.marginalAsymmetry5Pct5d, 4.49);
  assert.equal(spy.liveState.zeroNetFlowBreakeven10dPct, 3.94);
  assert.equal(spy.liveState.zeroNetFlowBreakeven10dPx, 716.98);

  // SPY primary buy signal ACTIVE (11th historical trigger; 10/10 100% +63D OOS win rate, p=0.0041)
  const spyBuy = spy.signals.primaryExhaustionBuy;
  assert.equal(spyBuy.active, true);
  assert.equal(spyBuy.completedEpisodes, 10);
  assert.equal(spyBuy.triggerRank, 11);
  assert.equal(spyBuy.oosStats['63D'].winRatePct, 100);
  assert.equal(spyBuy.oosStats['63D'].meanRetPct, 12.13);
  assert.equal(spyBuy.oosStats['63D'].pValRet, 0.0041);

  // SPY VIX backwardation cliff guardrail (p=0.0021 vol surge, 59.1% continuation)
  const spyVix = spy.signals.vixBackwardationGuardrail;
  assert.equal(spyVix.vixInverted, true);
  assert.equal(spyVix.inverted10dDropGe2PctRate, 59.1);
  assert.equal(spyVix.inverted5dRvolPct, 22.83);
  assert.equal(spyVix.pValVol5d, 0.0021);

  // SPY 10D matrix contains interpolated $0B net-flow breakeven row ($716.98 / +3.94%)
  const spyBeRow = spy.matrix10d.find(r => r.isBreakevenRow);
  assert.ok(spyBeRow, 'SPY 10D matrix should include exact $0B breakeven row');
  assert.equal(spyBeRow.movePct, 3.94);
  assert.equal(spyBeRow.targetPrice, 716.98);
  assert.equal(spyBeRow.combinedFlowB, 0);

  // QQQ live 2026-11-20 state & 10D breakeven ($641.61 / +5.45%)
  const qqq = dash.assets.QQQ;
  assert.equal(qqq.liveState.spotClose, 608.45);
  assert.equal(qqq.liveState.fCarver, -12.2);
  assert.equal(qqq.liveState.carverForecast12YrPercentile, 1.7);
  assert.equal(qqq.liveState.zeroNetFlowBreakeven10dPct, 5.45);
  assert.equal(qqq.liveState.zeroNetFlowBreakeven10dPx, 641.61);
  assert.equal(qqq.signals.primaryExhaustionBuy.oosStats['5D'].winRatePct, 83.3);
  const qqqBeRow = qqq.matrix10d.find(r => r.isBreakevenRow);
  assert.ok(qqqBeRow, 'QQQ 10D matrix should include exact $0B breakeven row');
  assert.equal(qqqBeRow.movePct, 5.45);
  assert.equal(qqqBeRow.targetPrice, 641.61);

  // Out-of-sample endpoint R^2 & historical timeline (including 2022 slow-bear caveat + 2026-11 live)
  assert.equal(spy.empiricalScorecard.flowSurfaceEndpointR2, 0.7621);
  assert.equal(qqq.empiricalScorecard.flowSurfaceEndpointR2, 0.7833);
  assert.ok(spy.historicalTimeline.some(ep => ep.id === '2022_bear' && ep.verdict === 'CAVEAT'));
  assert.ok(spy.historicalTimeline.some(ep => ep.id === '2026_11_live' && ep.verdict === 'LIVE_ACTIVE'));

  // Signal Backtest & Dip-Entry Simulator (zero-lookahead 2014-2026, >=20D cooldown, close-to-close total return)
  assert.deepEqual(spy.signalBacktest, spy.signal_backtest);
  assert.deepEqual(spy.signalBacktest.regimeOrder, [
    'exhaustion_convexity',
    'quadrant2_combo',
    'vix_backwardation_lock',
  ]);
  const spyExh = spy.signalBacktest.regimes.exhaustion_convexity;
  assert.equal(spyExh.totalEpisodes, 11);
  assert.equal(spyExh.completedEpisodes10d, 10);
  assert.equal(spyExh.completedEpisodes20d, 10);
  assert.equal(spyExh.completedEpisodes60d, 10);
  assert.equal(spyExh.completedEpisodes120d, 10);
  assert.equal(spyExh.livePendingCount, 1);
  assert.equal(spyExh.activeToday, true);
  assert.equal(spyExh.postSignalDrawdown['20D'].medianDropPct, -2.76);
  assert.equal(spyExh.postSignalDrawdown['20D'].meanDropPct, -3.96);
  assert.equal(spyExh.postSignalDrawdown['20D'].worstDropPct, -16.73);
  assert.equal(spyExh.postSignalDrawdown['20D'].zeroFurtherDropCount, 2);
  assert.equal(spyExh.postSignalDrawdown['20D'].medianDaysToTrough, 2);
  assert.equal(spyExh.forwardHorizons['10D'].winRatePct, 80);
  assert.equal(spyExh.forwardHorizons['10D'].medianRetPct, 2.78);
  assert.equal(spyExh.forwardHorizons['20D'].winRatePct, 80);
  assert.equal(spyExh.forwardHorizons['20D'].medianRetPct, 4.18);
  assert.equal(spyExh.forwardHorizons['60D'].winRatePct, 100);
  assert.equal(spyExh.forwardHorizons['60D'].medianRetPct, 12.04);
  assert.equal(spyExh.forwardHorizons['60D'].meanRetPct, 12.29);
  assert.equal(spyExh.forwardHorizons['60D'].pValVsBaseline, 0.0036);
  assert.equal(spyExh.forwardHorizons['120D'].winRatePct, 90);
  assert.equal(spyExh.forwardHorizons['120D'].medianRetPct, 14.27);
  assert.equal(spyExh.dipEntryMatrix.length, 5);
  const spyDip2 = spyExh.dipEntryMatrix.find(m => m.id === 'dip_2pct');
  const spyDca = spyExh.dipEntryMatrix.find(m => m.id === 'dca_3tranche');
  assert.equal(spyDip2.fillRatePct, 50);
  assert.equal(spyDip2.missed60dMeanRetPct, 14.39);
  assert.equal(spyDca.fillRatePct, 100);
  assert.equal(spyDca.avgDeployedCapitalPct, 56.7);
  assert.equal(spyDca.postEntry20dMaeMedianPct, -1.2);
  assert.ok(Number.isFinite(spyDca.horizons['60D'].deployedMedianRetPct));
  const spyLiveEp = spyExh.episodes.at(-1);
  assert.equal(spyLiveEp.rank, 11);
  assert.equal(spyLiveEp.date, '2026-11-20');
  assert.equal(spyLiveEp.status, 'LIVE');
  assert.equal(spyLiveEp.ret10dPct, null);

  // SPY Quadrant 2 Combo (7/7 100% +60D & +120D win rate + 1 LIVE)
  const spyQ2 = spy.signalBacktest.regimes.quadrant2_combo;
  assert.equal(spyQ2.completedEpisodes60d, 7);
  assert.equal(spyQ2.completedEpisodes120d, 7);
  assert.equal(spyQ2.livePendingCount, 1);
  assert.equal(spyQ2.forwardHorizons['60D'].winRatePct, 100);
  assert.equal(spyQ2.forwardHorizons['120D'].winRatePct, 100);

  // QQQ Signal Backtest (10 completed exhaustion episodes; 4/4 Quadrant 2 with smallSampleCaveat)
  const qqqExh = qqq.signalBacktest.regimes.exhaustion_convexity;
  const qqqQ2 = qqq.signalBacktest.regimes.quadrant2_combo;
  assert.equal(qqqExh.completedEpisodes120d, 10);
  assert.equal(qqqExh.livePendingCount, 0);
  assert.equal(qqqQ2.completedEpisodes120d, 4);
  assert.equal(qqqQ2.smallSampleCaveat, true);
  assert.equal(qqqQ2.forwardHorizons['60D'].winRatePct, 100);
});

test('steps historical asOf cutoffs without lookahead and extends dynamically on new live closes', async () => {
  // 1) Historical cutoff replay before Nov 19-20 crash (e.g. 2026-11-10)
  const preCrash = loadCtaFlowRadarDashboard({ asOf: '2026-11-10', asset: 'QQQ', horizon: '5D' });
  assert.equal(preCrash.asOfDate, '2026-11-10');
  assert.equal(preCrash.selectedAsset, 'QQQ');
  assert.equal(preCrash.selectedHorizon, '5D');
  assert.ok(preCrash.assets.SPY.liveState.spotClose > 720, 'Nov 10 SPY was above $720 prior to selloff');
  assert.ok(preCrash.assets.SPY.liveState.fCarver > -5, 'Nov 10 SPY was not yet at -10 exhaustion');
  assert.equal(preCrash.assets.SPY.signals.primaryExhaustionBuy.active, false);

  // 1b) Historical cutoff right after 2025-04-04 tariff shock (2025-04-08): 2025-04-04 is LIVE, zero future leakage
  const apr2025 = loadCtaFlowRadarDashboard({ asOf: '2025-04-08', asset: 'SPY', horizon: '10D' });
  const aprExh = apr2025.assets.SPY.signalBacktest.regimes.exhaustion_convexity;
  assert.equal(aprExh.episodes.at(-1).date, '2025-04-04');
  assert.equal(aprExh.episodes.at(-1).status, 'LIVE');
  assert.equal(aprExh.episodes.at(-1).ret10dPct, null);
  assert.equal(aprExh.completedEpisodes120d, 8);
  assert.ok(!aprExh.episodes.some(e => e.date > '2025-04-08'));

  // 2) Live runtime forward extension onto synthetic Monday 2026-11-23 rebound (+2.5%)
  const liveExtended = await loadCtaFlowRadarDashboardLive({
    asOf: '2026-11-23',
    asset: 'SPY',
    horizon: '10D',
    fetchLiveBars: async () => [
      {
        date: '2026-11-20',
        spyClose: 689.81,
        spyAdjClose: 689.81,
        qqqClose: 608.45,
        qqqAdjClose: 608.45,
        vixClose: 35.89,
        vix3mClose: 30.94,
      },
      {
        date: '2026-11-23',
        spyClose: 707.06,
        spyAdjClose: 707.06,
        qqqClose: 626.7,
        qqqAdjClose: 626.7,
        vixClose: 27.4,
        vix3mClose: 28.5,
      },
    ],
  });
  assert.equal(liveExtended.liveExtended, true);
  assert.equal(liveExtended.asOfDate, '2026-11-23');
  assert.equal(liveExtended.assets.SPY.liveState.spotClose, 707.06);
  assert.equal(liveExtended.assets.QQQ.liveState.spotClose, 626.7);
  assert.equal(liveExtended.assets.SPY.liveState.vixBackwardation, false);
  assert.ok(liveExtended.assets.SPY.liveState.fCarver > -10.56, 'Rebound lifts Carver composite forecast');
  assert.equal(liveExtended.assets.SPY.recentTrajectory.at(-1).date, '2026-11-23');
  const extLiveEp = liveExtended.assets.SPY.signalBacktest.regimes.exhaustion_convexity.episodes.at(-1);
  assert.equal(extLiveEp.date, '2026-11-20');
  assert.equal(extLiveEp.status, 'LIVE');
  assert.equal(extLiveEp.daysElapsed, 1);
  assert.equal(extLiveEp.liveRunningRetPct, 2.5);
});

test('validates invalid query parameters and serves GET /api/investment/cta-flow-radar cleanly', async t => {
  assert.throws(() => loadCtaFlowRadarDashboard({ asset: 'INVALID' }), /invalid_cta_asset/);
  assert.throws(() => loadCtaFlowRadarDashboard({ horizon: '99D' }), /invalid_cta_horizon/);
  assert.throws(() => loadCtaFlowRadarDashboard({ asOf: '2010-01-01' }), /cta_radar_before_coverage/);
  assert.throws(() => loadCtaFlowRadarDashboard({ asOf: 'bad-date' }), /invalid_as_of_date/);

  const app = express();
  app.use((req, _res, next) => {
    req.user = { id: '11111111-1111-4111-8111-111111111111' };
    next();
  });
  const fakeService = {
    source: { canonicalMarket: false },
    date: v => v || '2026-11-20',
  };
  registerInvestmentRoutes(app, fakeService);
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const base = `http://127.0.0.1:${server.address().port}/api/investment/cta-flow-radar`;
  const r = await fetch(`${base}?asset=QQQ&horizon=5D&asOf=2026-11-20`);
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(body.asOfDate, '2026-11-20');
  assert.equal(body.selectedAsset, 'QQQ');
  assert.equal(body.selectedHorizon, '5D');
  assert.equal(body.assets.SPY.liveState.spotClose, 689.81);
  assert.equal(body.assets.QQQ.liveState.spotClose, 608.45);
});
