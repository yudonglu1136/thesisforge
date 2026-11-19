import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class WorkflowTestApi extends ApiClient {
  WorkflowTestApi() : super(() => 'test');
  final calls = <(String, Map<String, dynamic>)>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.contains('/breakout-pullback/analysis')) {
      final q = Uri.parse(path).queryParameters;
      return {
        'version': 'breakout-pullback-attribution-v1',
        'snapshotId': q['snapshotId'] ?? 'fixture-breakout',
        'mode': q['mode'] ?? 'flagship',
        'start': q['start'] ?? '2026-01-02',
        'end': q['end'] ?? '2026-06-01',
        'observations': 3,
        'illustrativeCapital': 100000,
        'currency': 'USD',
        'metrics': {
          'endingValue': 1.18,
          'totalReturn': .18,
          'cagr': .2445,
          'annualizedVolatility': .2375,
          'sharpeZeroRf': 1.03,
          'maxDrawdown': -.06,
          'calmar': .82,
        },
        'benchmarks': {
          'spy': {'totalReturn': .07, 'cagr': .135, 'maxDrawdown': -.04},
          'qqq': {'totalReturn': .09, 'cagr': .193, 'maxDrawdown': -.05},
        },
        'reconciliation': {
          'stockPnl': .18,
          'grossPnl': .181,
          'costs': .001,
          'portfolioReturn': .18,
          'difference': 0.0,
        },
        'tradeStats': {
          'stocks': 2,
          'wins': 2,
          'losses': 0,
          'flat': 0,
          'open': 1,
          'winRate': 1.0,
          'payoffRatio': 2.5,
          'lotCount': 2,
          'closedLotCount': 1,
          'lotWinRate': 1.0,
          'lotPayoffRatio': 2.5,
          'avgHoldingDays': 38.0,
          'hardStopCount': 0,
          'profitExitCount': 1,
          'stopLossExitShare': 0.0,
          'profitExitShare': 1.0,
        },
        'turnover': {
          'version': 'breakout-range-turnover-v1',
          'oneWay': .35,
          'annualizedOneWay': .82,
          'executions': 3,
        },
        'distribution': [
          for (var i = 0; i < 9; i++)
            {
              'index': i,
              'count': i == 7 ? 2 : 0,
              'share': i == 7 ? 1.0 : 0.0,
            },
        ],
        'topWinners': [
          {
            'ticker': 'NVDA',
            'name': 'NVIDIA Corp',
            'isDelisted': false,
            'netContribution': .12,
            'grossContribution': .121,
            'costContribution': .001,
            'openAtStart': false,
            'openAtEnd': true,
            'lots': [],
          },
        ],
        'topLosers': [],
        'holdings': [
          {
            'ticker': 'NVDA',
            'name': 'NVIDIA Corp',
            'isDelisted': false,
            'netContribution': .12,
            'grossContribution': .121,
            'costContribution': .001,
            'openAtStart': false,
            'openAtEnd': true,
            'lots': [],
          },
        ],
        'trades': [],
      };
    }
    if (path.contains('/breakout-pullback')) {
      final reqMode = Uri.parse(path).queryParameters['mode'] ?? 'flagship';
      Map<String, dynamic> modeSummary(String id, double mult, double sharpe) => {
        'id': id,
        'badge': {'en': 'Champion', 'zh': '冠军版'},
        'name': {'en': 'Flagship', 'zh': '旗舰版'},
        'subtitle': {'en': 'Top 50', 'zh': 'Top 50'},
        'parameters': {'maxPositions': 10, 'timeStopDays': id == 'balanced' ? 180 : null},
        'blueprint': [
          {
            'step': 1,
            'title': {'en': 'Universe', 'zh': '样本池'},
            'summary': {'en': 'Top 50 Dollar Volume', 'zh': 'Top 50 成交额'},
          },
        ],
        'avgExposure': .84,
        'episodeStats': {'fillRate': .42},
        'metrics': {
          'endingValue': mult,
          'totalReturn': mult - 1,
          'cagr': .2445,
          'annualizedVolatility': .2375,
          'sharpeZeroRf': sharpe,
          'maxDrawdown': -.2989,
          'calmar': .82,
        },
      };
      final summaries = {
        'flagship': modeSummary('flagship', 8.91, 1.03),
        'balanced': modeSummary('balanced', 7.54, 1.12),
      };
      return {
        'version': 'breakout-pullback-dashboard-v1',
        'status': 'ready',
        'snapshotId': 'fixture-breakout',
        'requestedAsOf': Uri.parse(path).queryParameters['asOf'] ?? '2026-06-01',
        'dataThrough': '2026-06-01',
        'inceptionDate': '2016-11-10',
        'lineage': {'delistedStocksIncluded': 183},
        'methodology': {},
        'mode': reqMode,
        'modeOrder': ['flagship', 'balanced'],
        'modesSummary': summaries,
        'activeMode': {
          ...summaries[reqMode]!,
          'tradeSummary': {
            'totalTrades': 12,
            'closedTrades': 11,
            'openTrades': 1,
            'winRate': .434,
            'payoffRatio': 2.09,
            'avgHoldingDays': 38.4,
          },
        },
        'yearlyReturns': [
          {
            'year': 2026,
            'label': '2026*',
            'partial': true,
            'from': '2026-01-02',
            'to': '2026-06-01',
            'flagship': .18,
            'balanced': .15,
            'spy': .07,
            'qqq': .09,
          },
        ],
        'empiricalProof': {'totalConfigurationsTested': 6912},
        'liveBook': {
          'asOfDate': '2026-06-01',
          'maxSlots': 10,
          'usedSlots': 1,
          'freeSlots': 9,
          'cashWeight': .895,
          'investedWeight': .105,
          'openPositions': [
            {
              'lotId': 'NVDA-1',
              'ticker': 'NVDA',
              'name': 'NVIDIA Corp',
              'isDelisted': false,
              'breakoutDate': '2026-04-02',
              'breakoutClose': 126.5,
              'waitDays': 5,
              'entryDate': '2026-04-10',
              'entryPrice': 120.0,
              'latestClose': 138.0,
              'highestHigh': 140.0,
              'latestAtr14': 3.5,
              'weight': .105,
              'unrealizedNetReturn': .15,
              'holdingDays': 35,
              'hardStopPrice': 111.25,
              'chandelierStopPrice': 126.0,
              'targetPrice': null,
              'effectiveStopPrice': 126.0,
              'remainingTimeStopDays': null,
            },
          ],
          'pendingWatchlist': [
            {
              'ticker': 'AVGO',
              'name': 'Broadcom Inc',
              'breakoutDate': '2026-05-22',
              'breakoutClose': 178.0,
              'prev63High': 176.0,
              'peakClose': 180.0,
              'latestClose': 175.5,
              'limitBuyPrice': 171.0,
              'distanceToLimitPct': -.0256,
              'pullbackFromPeakPct': -.025,
              'elapsedDays': 6,
              'remainingWatchDays': 9,
              'dvolRank': 12,
              'dvol20': 3200000000,
            },
          ],
        },
        'trades': [
          {
            'lotId': 'ANET-1',
            'ticker': 'ANET',
            'name': 'Arista Networks',
            'isDelisted': false,
            'breakoutDate': '2026-01-12',
            'breakoutClose': 100.0,
            'dvolRankAtBreakout': 18,
            'waitDays': 5,
            'entryDate': '2026-01-20',
            'entryPrice': 95.0,
            'exitDate': '2026-04-02',
            'exitPrice': 118.0,
            'hardStopPrice': 88.0,
            'targetPrice': null,
            'holdDays': 50,
            'netReturn': .241,
            'exitReason': 'Trailing_TakeProfit',
            'isOpen': false,
          },
        ],
        'backtest': {
          'from': '2026-01-02',
          'to': '2026-06-01',
          'observations': 3,
          'benchmarks': {
            'spy': {'id': 'spy', 'ticker': 'SPY', 'metrics': {'endingValue': 1.07, 'cagr': .135}},
            'qqq': {'id': 'qqq', 'ticker': 'QQQ', 'metrics': {'endingValue': 1.09, 'cagr': .193}},
          },
          'curve': [
            {'date': '2026-01-02', 'flagship': 1.0, 'balanced': 1.0, 'spy': 1.0, 'qqq': 1.0, 'flagshipCashWeight': .2, 'balancedCashWeight': .2},
            {'date': '2026-03-16', 'flagship': 1.09, 'balanced': 1.07, 'spy': 1.03, 'qqq': 1.04, 'flagshipCashWeight': .1, 'balancedCashWeight': .2},
            {'date': '2026-06-01', 'flagship': 1.18, 'balanced': 1.15, 'spy': 1.07, 'qqq': 1.09, 'flagshipCashWeight': .2, 'balancedCashWeight': .2},
          ],
        },
      };
    }
    if (path.contains('/investor-styles')) {
      return {
        'version': 'investor-style-dashboard-v4',
        'snapshotId': 'fixture-styles',
        'requestedAsOf': '2026-06-01',
        'effectiveAsOf': '2026-06-01',
        'styles': [
          {
            'id': 'quality_rank',
            'metrics': {'endingValue': 5.10, 'cagr': .131, 'sharpeZeroRf': .94},
          },
          {
            'id': 'ackman',
            'metrics': {'endingValue': 4.10, 'cagr': .113, 'sharpeZeroRf': .79},
          },
        ],
      };
    }
    if (Uri.parse(path).path.endsWith('/dividends')) {
      return {
        'version': 'dividend-research-v1',
        'ticker': 'TEST',
        'asOf': '2026-06-01',
        'currency': 'USD',
        'status': 'paying',
        'hasCorporateFacts': true,
        'isReit': false,
        'summary': {
          'currentYield': .024,
          'forwardYield': .025,
          'ttmDps': 1.20,
          'annualizedDps': 1.24,
          'latestPrice': 50.0,
          'splitAdjustedPrice': 50.0,
          'frequency': 'quarterly',
          'frequencyPerYear': 4,
          'avgYield5y': .021,
          'highYield5y': .031,
          'lowYield5y': .016,
          'yieldVs5yAvgPct': .1428,
          'cagr3y': .082,
          'cagr5y': .075,
          'cagr10y': .091,
          'consecutiveYearsPaid': 10,
          'consecutiveYearsGrown': 9,
          'epsPayoutRatio': .32,
          'fcfPayoutRatio': .28,
          'safetyLevel': 'very_safe',
          'safetyBasis': 'fcf_payout',
          'latestExDate': '2026-05-10',
          'latestAmount': .31,
          'estimatedNextExDate': '2026-08-10',
        },
        'yieldHistory': [
          {'date': '2022-06-01', 'price': 36.0, 'ttmDps': .92, 'yield': .0255},
          {'date': '2023-06-01', 'price': 40.0, 'ttmDps': 1.00, 'yield': .0250},
          {'date': '2024-06-01', 'price': 45.0, 'ttmDps': 1.08, 'yield': .0240},
          {'date': '2025-06-01', 'price': 48.0, 'ttmDps': 1.14, 'yield': .0237},
          {'date': '2026-06-01', 'price': 50.0, 'ttmDps': 1.20, 'yield': .0240},
        ],
        'annualPayouts': [
          {
            'year': 2023,
            'label': '2023',
            'isPartialYear': false,
            'dps': 1.00,
            'payoutCount': 4,
            'yoyGrowth': .087,
            'eps': 3.10,
            'fcfPerShare': 3.60,
            'epsPayoutRatio': .32,
            'fcfPayoutRatio': .28,
          },
          {
            'year': 2024,
            'label': '2024',
            'isPartialYear': false,
            'dps': 1.08,
            'payoutCount': 4,
            'yoyGrowth': .080,
            'eps': 3.45,
            'fcfPerShare': 3.95,
            'epsPayoutRatio': .31,
            'fcfPayoutRatio': .27,
          },
          {
            'year': 2025,
            'label': '2025',
            'isPartialYear': false,
            'dps': 1.16,
            'payoutCount': 4,
            'yoyGrowth': .074,
            'eps': 3.80,
            'fcfPerShare': 4.30,
            'epsPayoutRatio': .30,
            'fcfPayoutRatio': .27,
          },
        ],
        'events': [
          {
            'exDate': '2026-05-10',
            'year': 2026,
            'month': 5,
            'amount': .31,
            'prevAmount': .29,
            'changePct': .069,
            'priceOnExDate': 49.5,
            'annualizedYieldOnExDate': .0251,
          },
          {
            'exDate': '2026-02-10',
            'year': 2026,
            'month': 2,
            'amount': .29,
            'prevAmount': .29,
            'changePct': 0.0,
            'priceOnExDate': 47.0,
            'annualizedYieldOnExDate': .0247,
          },
        ],
        'seasonality': [
          for (var m = 1; m <= 12; m++)
            {
              'month': m,
              'count3y': const {2, 5, 8, 11}.contains(m) ? 3 : 0,
              'active': const {2, 5, 8, 11}.contains(m),
              'latestExDate': const {2, 5, 8, 11}.contains(m) ? '2026-05-10' : null,
              'latestAmount': const {2, 5, 8, 11}.contains(m) ? .31 : null,
            },
        ],
      };
    }
    if (path.contains('/research/')) {
      return {
        'ticker': 'TEST',
        'name': 'Synthetic UI fixture',
        'currency': 'USD',
        'snapshot': {
          'id': 'fixture',
          'period': '2026-Q1',
          'availableAt': '2026-04-20',
          'price': {'value': 50, 'date': '2026-06-01', 'source': 'test'},
        },
        'templates': {
          for (final name in ['Base', 'Bear', 'Bull'])
            name: {
              'ke': .1,
              'g': .024698294551041777,
              'growth': [.1, .1, .1, .1, .1],
              'margin': [.2290987654321, .2, .2, .2, .2],
            },
        },
        'metrics': [],
        'history': [],
        'priceHistory': [],
        'provenance': [],
        'scenarios': [],
      };
    }
    return {
      'attention': [],
      'discovery': [
        {'ticker': 'TEST', 'revenueGrowth': .2},
      ],
      'decisions': [],
      'gurus': [],
      'portfolio': {
        'positions': [],
        'overlap': [],
        'shadow': {'issues': []},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add((path, body));
    if (path.endsWith('/scenarios')) {
      return {...body, 'id': 'saved-fixture', 'version': 1};
    }
    return {
      'result': {'fairValue': 30, 'forecast': []},
      'reverse': {'status': 'solved', 'value': .1},
      'sensitivity': [],
    };
  }
}

class DiscoveryFixtureApi extends WorkflowTestApi {
  final guru = {
    'id': 'test-manager',
    'name': 'Test manager',
    'entityName': 'Synthetic UI fixture',
    'avatar': '',
  };
  Map<String, dynamic> filing(
    String accession,
    String quarter,
    String date,
    double shares,
  ) => {
    'accessionNumber': accession,
    'quarterLabel': quarter,
    'reportDate': quarter == '2025 Q4' ? '2025-12-31' : '2026-03-31',
    'filingDate': date,
    'reported13fValue': 1250000000,
    'positionCount': 2,
    'topHoldings': [
      {
        'id': '123-COMMON',
        'ticker': 'TEST',
        'issuer': 'Synthetic holding',
        'shares': shares,
        'value': 100,
        'pctPortfolio': .2,
      },
    ],
    'largestChanges': [],
  };
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final latest = filing('new-filing', '2026 Q1', '2026-05-15', 200);
    if (path.contains('/guru-study')) {
      return {
        'asOf': Uri.parse(path).queryParameters['asOf'],
        'period': Uri.parse(path).queryParameters['period'],
        'rows': [
          {
            ...guru,
            'basis': 'reported_13f_long_only',
            'annualTurnover': .18,
            'cagr': .12,
            'sharpe': 1.1,
          },
        ],
        'unavailable': [],
        'range': null,
      };
    }
    if (path.contains('/strategy-lab')) {
      return {
        'version': 'strategy-lab-catalog-v1',
        'asOf': Uri.parse(path).queryParameters['asOf'],
        'managers': [
          {...guru, 'quarters': 2},
        ],
        'etfs': [],
        'saved': [],
      };
    }
    if (path.contains('/gurus/')) {
      return {
        'asOf': Uri.parse(path).queryParameters['asOf'],
        'guru': guru,
        'latest': latest,
        'history': [filing('old-filing', '2025 Q4', '2026-02-15', 100), latest],
      };
    }
    if (path.contains('/discover')) {
      return {
        'gurus': [
          {
            ...guru,
            'followed': false,
            'latest': {
              ...latest,
              'quarter': '2026 Q1',
              'availableAt': '2026-05-15',
            },
          },
        ],
        'discovery': [],
      };
    }
    final data = await super.getJson(path);
    if (!path.contains('/research/')) data['gurus'] = [guru];
    return data;
  }
}

class HomeFixtureApi extends DiscoveryFixtureApi {
  final reads = <String>[];
  bool failExample = false;
  Completer<void>? heldIsrg;
  bool withAlerts = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.contains('/research/ISRG') && heldIsrg != null) {
      await heldIsrg!.future;
    }
    reads.add(path);
    if (failExample && path.contains('/research/')) {
      throw StateError('fixture_unavailable');
    }
    final data = await super.getJson(path);
    if (path.contains('/home')) {
      data['decisions'] = [
        {
          'ticker': 'SAVED',
          'action': 'Watch',
          'decisionDate': '2026-06-01',
          'decisionId': 'saved',
        },
      ];
    }
    if (withAlerts && path.contains('/home')) {
      data['attention'] = [
        {'ticker': 'ALERT1', 'decisionId': 'one', 'status': 'data_unavailable'},
        {'ticker': 'ALERT2', 'decisionId': 'two', 'status': 'data_unavailable'},
      ];
    }
    if (Uri.parse(path).path.endsWith('/dividends')) {
      return {
        'version': 'dividend-research-v1',
        'ticker': 'TEST',
        'asOf': '2026-06-01',
        'currency': 'USD',
        'status': 'paying',
        'hasCorporateFacts': true,
        'isReit': false,
        'summary': {
          'currentYield': .024,
          'forwardYield': .025,
          'ttmDps': 1.20,
          'annualizedDps': 1.24,
          'latestPrice': 50.0,
          'splitAdjustedPrice': 50.0,
          'frequency': 'quarterly',
          'frequencyPerYear': 4,
          'avgYield5y': .021,
          'highYield5y': .031,
          'lowYield5y': .016,
          'yieldVs5yAvgPct': .1428,
          'cagr3y': .082,
          'cagr5y': .075,
          'cagr10y': .091,
          'consecutiveYearsPaid': 10,
          'consecutiveYearsGrown': 9,
          'epsPayoutRatio': .32,
          'fcfPayoutRatio': .28,
          'safetyLevel': 'very_safe',
          'safetyBasis': 'fcf_payout',
          'latestExDate': '2026-05-10',
          'latestAmount': .31,
          'estimatedNextExDate': '2026-08-10',
        },
        'yieldHistory': [
          {'date': '2022-06-01', 'price': 36.0, 'ttmDps': .92, 'yield': .0255},
          {'date': '2023-06-01', 'price': 40.0, 'ttmDps': 1.00, 'yield': .0250},
          {'date': '2024-06-01', 'price': 45.0, 'ttmDps': 1.08, 'yield': .0240},
          {'date': '2025-06-01', 'price': 48.0, 'ttmDps': 1.14, 'yield': .0237},
          {'date': '2026-06-01', 'price': 50.0, 'ttmDps': 1.20, 'yield': .0240},
        ],
        'annualPayouts': [
          {
            'year': 2023,
            'label': '2023',
            'isPartialYear': false,
            'dps': 1.00,
            'payoutCount': 4,
            'yoyGrowth': .087,
            'eps': 3.10,
            'fcfPerShare': 3.60,
            'epsPayoutRatio': .32,
            'fcfPayoutRatio': .28,
          },
          {
            'year': 2024,
            'label': '2024',
            'isPartialYear': false,
            'dps': 1.08,
            'payoutCount': 4,
            'yoyGrowth': .080,
            'eps': 3.45,
            'fcfPerShare': 3.95,
            'epsPayoutRatio': .31,
            'fcfPayoutRatio': .27,
          },
          {
            'year': 2025,
            'label': '2025',
            'isPartialYear': false,
            'dps': 1.16,
            'payoutCount': 4,
            'yoyGrowth': .074,
            'eps': 3.80,
            'fcfPerShare': 4.30,
            'epsPayoutRatio': .30,
            'fcfPayoutRatio': .27,
          },
        ],
        'events': [
          {
            'exDate': '2026-05-10',
            'year': 2026,
            'month': 5,
            'amount': .31,
            'prevAmount': .29,
            'changePct': .069,
            'priceOnExDate': 49.5,
            'annualizedYieldOnExDate': .0251,
          },
          {
            'exDate': '2026-02-10',
            'year': 2026,
            'month': 2,
            'amount': .29,
            'prevAmount': .29,
            'changePct': 0.0,
            'priceOnExDate': 47.0,
            'annualizedYieldOnExDate': .0247,
          },
        ],
        'seasonality': [
          for (var m = 1; m <= 12; m++)
            {
              'month': m,
              'count3y': const {2, 5, 8, 11}.contains(m) ? 3 : 0,
              'active': const {2, 5, 8, 11}.contains(m),
              'latestExDate': const {2, 5, 8, 11}.contains(m) ? '2026-05-10' : null,
              'latestAmount': const {2, 5, 8, 11}.contains(m) ? .31 : null,
            },
        ],
      };
    }
    if (path.contains('/research/') && !Uri.parse(path).path.endsWith('/dividends')) {
      data['ticker'] = Uri.parse(path).pathSegments.last;
      data['name'] = 'Synthetic home example';
      data['published'] = {'fairValue': 30};
      data['history'] = [
        {'availableAt': '2025-01-15', 'publishedFairValue': 24},
        {'availableAt': '2026-04-20', 'publishedFairValue': 30},
      ];
      data['priceHistory'] = [
        {'date': '2025-01-15', 'close': 40},
        {'date': '2026-06-01', 'close': 50},
      ];
    }
    if (path.contains('/discover')) {
      final latest = (data['gurus'] as List).first['latest'] as Map;
      latest['accession'] = 'new-filing';
      (latest['topHoldings'] as List).add({
        'id': 'OPTION-PUT',
        'ticker': 'OPTION',
        'pctPortfolio': .8,
      });
    }
    return data;
  }
}

class BriefFixtureApi extends HomeFixtureApi {
  String mode = 'normal';
  bool failBrief = false;
  Completer<void>? heldJuneBrief;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final delayed =
        path.contains('/gurus/') &&
        path.endsWith('2026-06-01') &&
        heldJuneBrief != null;
    if (delayed) await heldJuneBrief!.future;
    if (failBrief && path.contains('/gurus/')) {
      throw StateError('brief_unavailable');
    }
    final data = await super.getJson(path);
    if (path.contains('/gurus/')) {
      final history = data['history'] as List;
      if (mode == 'missing_previous') history.first['topHoldings'] = [];
      if (mode == 'different_claim') {
        history.first['topHoldings'][0]['id'] = 'OTHER-COMMON';
      }
      if (mode == 'wrong_manager') {
        data['guru'] = {...guru, 'id': 'different-manager'};
      }
      if (delayed) history.last['topHoldings'][0]['shares'] = 999;
    }
    return data;
  }
}

class DeskFixtureApi extends HomeFixtureApi {
  bool wrongResearch = false;
  bool notCovered = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (notCovered && path.contains('/research/')) {
      throw const ApiRequestException(
        statusCode: 422,
        message: 'no_pit_research_at_date',
        code: 'no_pit_research_at_date',
      );
    }
    final data = await super.getJson(path);
    if (path.contains('/research/') && wrongResearch) data['ticker'] = 'WRONG';
    final other = {
      'id': 'gavin-baker',
      'name': 'Gavin Baker',
      'entityName': 'Synthetic alternate manager',
    };
    if (path.contains('/discover')) (data['gurus'] as List).add(other);
    if (path.contains('/gurus/')) {
      if (path.contains('/gavin-baker')) {
        data['guru'] = other;
        for (final f in [...data['history'] as List, data['latest']]) {
          f['topHoldings'] = [
            {
              'id': 'ALAB-COMMON',
              'ticker': 'ALAB',
              'issuer': 'Synthetic alternate stock',
              'shares': 500,
              'pctPortfolio': .3,
            },
          ];
        }
      } else {
        for (final f in [...data['history'] as List, data['latest']]) {
          final rows = f['topHoldings'] as List;
          if (rows.length > 1) continue;
          for (final ticker in ['ISRG', 'NVDA']) {
            rows.add({
              'id': '$ticker-COMMON',
              'ticker': ticker,
              'issuer': 'Synthetic $ticker holding',
              'shares': f['accessionNumber'] == 'old-filing' ? 50 : 150,
              'pctPortfolio': .1,
              'value': 500,
            });
          }
          rows.add({
            'id': 'OPTION-PUT',
            'ticker': 'OPTION',
            'pctPortfolio': .8,
          });
          f['filing'] = {'secUrl': 'https://www.sec.gov/Archives/test-fixture'};
        }
      }
    }
    return data;
  }
}

Future<void> mountHome(
  WidgetTester tester,
  Size size,
  AppLanguage language,
  WorkflowTestApi api, {
  bool managers = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: LanguageScope(
        language: language,
        child: InvestmentWorkspace(
          api: api,
          palette: Palette(false),
          initialPage: 'home',
          initialTicker: '',
          initialAsOf: '2026-06-01',
          initialQuery: const {'workspace': 'research'},
          onLanguage: (_) {},
          onLegacy: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (managers) {
    await tester.ensureVisible(
      find.text(language == AppLanguage.en ? 'Managers' : '按经理研究'),
    );
    await tester.tap(
      find.text(language == AppLanguage.en ? 'Managers' : '按经理研究'),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> mountDiscovery(
  WidgetTester tester,
  Size size,
  AppLanguage language,
  WorkflowTestApi api,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: LanguageScope(
        language: language,
        child: InvestmentWorkspace(
          api: api,
          palette: Palette(false),
          initialPage: 'discover',
          initialTicker: '',
          initialAsOf: '2026-06-01',
          onLanguage: (_) {},
          onLegacy: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final guruTabLabel = language == AppLanguage.en ? 'Guru' : '大师持仓';
  await tester.ensureVisible(find.text(guruTabLabel));
  await tester.tap(find.text(guruTabLabel));
  await tester.pumpAndSettle();
}

Future<WorkflowTestApi> mountResearch(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1487, 1058);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = WorkflowTestApi();
  await tester.pumpWidget(
    MaterialApp(
      home: LanguageScope(
        language: AppLanguage.en,
        child: InvestmentWorkspace(
          api: api,
          palette: Palette(false),
          initialPage: 'research',
          initialTicker: 'TEST',
          initialAsOf: '2026-06-01',
          onLanguage: (_) {},
          onLegacy: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets(
    'desk shows the selected claim and actual adjacent disclosed shares',
    (tester) async {
      final api = BriefFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      expect(find.text(r'$30.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-detail-position')));
      await tester.pumpAndSettle();
      expect(find.text('100'), findsOneWidget);
      expect(find.text('200'), findsOneWidget);
      expect(
        find.textContaining('Corporate actions are not verified'),
        findsOneWidget,
      );
      expect(api.calls, isEmpty);
    },
  );
  for (final mode in ['missing_previous', 'different_claim']) {
    testWidgets('desk missing or different claim is not zero: $mode', (
      tester,
    ) async {
      final api = BriefFixtureApi()..mode = mode;
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.tap(find.byKey(const ValueKey('home-detail-position')));
      await tester.pumpAndSettle();
      expect(find.text('200'), findsOneWidget);
      expect(find.text('100'), findsNothing);
      expect(find.text('Not in extract'), findsOneWidget);
      expect(
        find.textContaining('not zero or a confirmed new position'),
        findsOneWidget,
      );
      expect(api.calls, isEmpty);
    });
  }
  testWidgets('desk rejects another manager identity', (tester) async {
    final api = BriefFixtureApi()..mode = 'wrong_manager';
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    expect(find.text('Retry disclosures'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-holding-TEST')), findsNothing);
    expect(find.byType(ValuationTrendChart), findsNothing);
  });
  testWidgets('desk failure retry restores the requested holding', (
    tester,
  ) async {
    final api = BriefFixtureApi()..failBrief = true;
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    expect(find.byType(ValuationTrendChart), findsNothing);
    api.failBrief = false;
    await tester.tap(find.text('Retry disclosures'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-holding-TEST')), findsOneWidget);
    expect(find.text('Open TEST valuation'), findsOneWidget);
    expect(api.calls, isEmpty);
  });
  testWidgets('desk late filing response cannot replace a newer cutoff', (
    tester,
  ) async {
    final api = BriefFixtureApi();
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    api.heldJuneBrief = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('home-investor-test-manager')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ValuationTrendChart), findsNothing);
    await tester.ensureVisible(find.text('As of 2026-06-01'));
    await tester.tap(find.text('As of 2026-06-01'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(
      find.widgetWithText(TextField, 'YYYY-MM-DD'),
      '2026-08-28',
    );
    await tester.tap(find.text('Apply date'));
    await tester.pumpAndSettle();
    api.heldJuneBrief!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-detail-position')));
    await tester.pumpAndSettle();
    expect(find.text('999'), findsNothing);
    expect(find.text('200'), findsOneWidget);
    expect(
      api.reads,
      contains('/api/investment/gurus/test-manager?asOf=2026-08-28'),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('desk alerts retain every review and its missing data state', (
    tester,
  ) async {
    final api = HomeFixtureApi()..withAlerts = true;
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    await tester.tap(find.text('2 saved decisions need a review'));
    await tester.pumpAndSettle();
    expect(find.text('ALERT1 · '), findsOneWidget);
    expect(find.text('ALERT2 · '), findsOneWidget);
    expect(
      find.text('Data unavailable — no rule conclusion'),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'desk switches ticker and rejects a late previous stock response',
    (tester) async {
      final api = DeskFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      api.heldIsrg = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('home-holding-ISRG')));
      await tester.pump();
      expect(find.text(r'$30.00'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-holding-NVDA')));
      await tester.pumpAndSettle();
      expect(find.text('Open NVDA valuation'), findsOneWidget);
      api.heldIsrg!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open NVDA valuation'), findsOneWidget);
      expect(find.text('Open ISRG valuation'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desk cutoff reload uses the selected disclosed stock not an example',
    (tester) async {
      final api = HomeFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.ensureVisible(find.text('As of 2026-06-01'));
      await tester.tap(find.text('As of 2026-06-01'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'YYYY-MM-DD'),
        '2026-08-28',
      );
      await tester.tap(find.text('Apply date'));
      await tester.pumpAndSettle();
      expect(api.reads, contains('/api/investment/discover?asOf=2026-08-28'));
      expect(
        api.reads,
        contains('/api/investment/research/TEST?asOf=2026-08-28'),
      );
      expect(api.reads.any((p) => p.contains('/research/MSFT')), isFalse);
      expect(api.calls, isEmpty);
    },
  );
  for (final language in AppLanguage.values) {
    for (final size in [
      const Size(1487, 1058),
      const Size(1280, 720),
      const Size(390, 844),
    ]) {
      testWidgets(
        'connected desk real entry tasks and valuation $language $size',
        (tester) async {
          final api = HomeFixtureApi();
          await mountHome(tester, size, language, api);
          expect(
            find.text(language == AppLanguage.en ? 'Research desk' : '研究工作台'),
            findsOneWidget,
          );
          if (size.width < 1200) {
            await tester.tap(
              find.widgetWithText(
                ChoiceChip,
                language == AppLanguage.en ? 'Holdings' : '持仓',
              ),
            );
            await tester.pumpAndSettle();
          }
          expect(
            find.byKey(const ValueKey('home-holding-TEST')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('home-holding-OPTION')),
            findsNothing,
          );
          expect(find.text('20.00%'), findsOneWidget);
          if (size.width < 1200) {
            await tester.ensureVisible(
              find.widgetWithText(
                ChoiceChip,
                language == AppLanguage.en ? 'Research' : '研究',
              ),
            );
            await tester.tap(
              find.widgetWithText(
                ChoiceChip,
                language == AppLanguage.en ? 'Research' : '研究',
              ),
            );
            await tester.pumpAndSettle();
          }
          expect(find.text(r'$30.00'), findsOneWidget);
          expect(find.text(r'$50.00'), findsOneWidget);
          expect(
            find.text(
              language == AppLanguage.en
                  ? 'SAVED · Watch · 2026-06-01'
                  : 'SAVED · 观察 · 2026-06-01',
            ),
            findsOneWidget,
          );
          expect(api.calls, isEmpty);
          final valuation = find.text(
            language == AppLanguage.en ? 'Open TEST valuation' : '打开 TEST 估值',
          );
          await tester.ensureVisible(valuation);
          await tester.tap(valuation);
          await tester.pumpAndSettle();
          expect(
            find.text(
              language == AppLanguage.en
                  ? 'Discover / Test manager / 2026-03-31'
                  : '发现 / Test manager / 2026-03-31',
            ),
            findsOneWidget,
          );
          expect(
            api.reads
                .where(
                  (p) =>
                      p.contains('/research/TEST') &&
                      !p.contains('/fundamentals') &&
                      !p.contains('/dividends'),
                )
                .length,
            2,
          );
          expect(
            find.byKey(const ValueKey('research-tab-value')),
            findsNothing,
          );
          expect(
            find.text(
              language == AppLanguage.en ? 'Financial statements' : '财务报表',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'desk quarterly history retains exact manager filing and ticker',
    (tester) async {
      final api = HomeFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.tap(find.text('View quarterly history'));
      await tester.pumpAndSettle();
      final research = find.text('Research TEST');
      await tester.ensureVisible(research);
      await tester.tap(research);
      await tester.pumpAndSettle();
      expect(find.text('Discover / Test manager / 2026-03-31'), findsOneWidget);
      expect(find.text('Filed 2026-05-15'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desk research failure removes old chart and retry keeps identity',
    (tester) async {
      final api = DeskFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      api.failExample = true;
      await tester.tap(find.byKey(const ValueKey('home-holding-ISRG')));
      await tester.pumpAndSettle();
      expect(find.byType(ValuationTrendChart), findsNothing);
      expect(find.text(r'$30.00'), findsNothing);
      expect(
        find.textContaining('Research is unavailable for ISRG'),
        findsOneWidget,
      );
      api.failExample = false;
      await tester.tap(find.text('Retry research'));
      await tester.pumpAndSettle();
      expect(find.text('Open ISRG valuation'), findsOneWidget);
      expect(find.byType(ValuationTrendChart), findsOneWidget);
      expect(api.calls, isEmpty);
    },
  );
  testWidgets(
    'desk blank search does not open a default and direct search is explicit',
    (tester) async {
      final api = HomeFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.tap(find.byTooltip('Search desk'));
      await tester.pumpAndSettle();
      expect(api.reads.where((p) => p.contains('/research/')).length, 1);
      await tester.enterText(
        find.byKey(const ValueKey('home-company-search')),
        'ISRG',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open company research: ISRG'));
      await tester.pumpAndSettle();
      expect(api.reads.any((p) => p.contains('/research/ISRG')), isTrue);
      expect(find.text('Direct company research'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desk quarter keeps exact claim and excludes future filing positions',
    (tester) async {
      final api = DeskFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.tap(find.byKey(const ValueKey('home-holding-ISRG')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-quarter-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2025 Q4 · 2026-02-15 · filing'));
      await tester.pumpAndSettle();
      expect(find.text('Open ISRG valuation'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-detail-position')));
      await tester.pumpAndSettle();
      expect(find.text('50'), findsOneWidget);
      expect(find.text('150'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Weight'));
      await tester.pumpAndSettle();
      expect(find.text('10.00%'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('desk filing dialog exposes exact accession and source', (
    tester,
  ) async {
    final api = DeskFixtureApi();
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    await tester.ensureVisible(find.text('View filing'));
    await tester.tap(find.text('View filing'));
    await tester.pumpAndSettle();
    expect(find.text('2026 Q1 · new-filing'), findsOneWidget);
    expect(
      find.text('https://www.sec.gov/Archives/test-fixture'),
      findsOneWidget,
    );
    expect(find.text('Open SEC filing'), findsOneWidget);
    expect(api.calls, isEmpty);
  });
  testWidgets(
    'desk confirmed missing PIT keeps filing and history without misleading retry',
    (tester) async {
      final api = DeskFixtureApi()..notCovered = true;
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      expect(
        find.textContaining('No PIT research is available for TEST'),
        findsOneWidget,
      );
      expect(find.text('Retry research'), findsNothing);
      expect(find.text('View filing'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-detail-position')));
      await tester.pumpAndSettle();
      expect(find.text('200'), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
      await tester.tap(find.text('View filing'));
      await tester.pumpAndSettle();
      expect(find.text('Open SEC filing'), findsOneWidget);
    },
  );
  testWidgets(
    'desk mismatched research ticker never creates a substituted valuation',
    (tester) async {
      final api = DeskFixtureApi()..wrongResearch = true;
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      expect(find.byType(ValuationTrendChart), findsNothing);
      expect(
        find.textContaining('Research is unavailable for TEST'),
        findsOneWidget,
      );
      expect(find.text('Open TEST valuation'), findsNothing);
    },
  );
  testWidgets(
    'desk switching managers clears prior stock and ignores late response',
    (tester) async {
      final api = DeskFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      api.heldIsrg = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('home-holding-ISRG')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('home-investor-gavin-baker')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-holding-ISRG')), findsNothing);
      expect(find.text('Open ALAB valuation'), findsOneWidget);
      api.heldIsrg!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open ALAB valuation'), findsOneWidget);
      expect(find.text('Open ISRG valuation'), findsNothing);
    },
  );
  testWidgets('desk search selects a disclosed holding inside the workbench', (
    tester,
  ) async {
    final api = DeskFixtureApi();
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    await tester.enterText(
      find.byKey(const ValueKey('home-company-search')),
      'NVDA',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'NVDA'));
    await tester.pumpAndSettle();
    expect(find.text('Open NVDA valuation'), findsOneWidget);
    expect(find.text('Research desk'), findsOneWidget);
    expect(api.calls, isEmpty);
  });
  for (final language in AppLanguage.values) {
    for (final size in [const Size(1487, 1058), const Size(390, 844)]) {
      testWidgets('populated Guru selection and trajectory $language $size', (
        tester,
      ) async {
        await mountDiscovery(tester, size, language, DiscoveryFixtureApi());
        final loadStudy = find.byKey(const ValueKey('load-guru-study'));
        await tester.ensureVisible(loadStudy);
        await tester.tap(loadStudy);
        await tester.pumpAndSettle();
        final compare = find.byKey(
          const ValueKey('guru-directory-compare-test-manager'),
        );
        await tester.ensureVisible(compare);
        await tester.tap(compare);
        await tester.pumpAndSettle();
        final select = find.byKey(
          const ValueKey('guru-study-select-test-manager'),
        );
        await tester.ensureVisible(select);
        await tester.tap(select);
        await tester.pumpAndSettle();
        final explore = find.text(
          language == AppLanguage.en ? 'Explore quarterly holdings' : '查看季度持仓',
        );
        await tester.ensureVisible(explore);
        await tester.tap(explore);
        await tester.pumpAndSettle();
        expect(find.text('Test manager'), findsOneWidget);
        expect(
          find.text(
            language == AppLanguage.en ? 'Reported 13F value' : '13F 信息表价值',
          ),
          findsOneWidget,
        );
        final research = find.text(
          language == AppLanguage.en ? 'Research TEST' : '研究 TEST',
        );
        await tester.ensureVisible(research);
        await tester.tap(research);
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == AppLanguage.en
                ? 'Discover / Test manager / 2026-03-31'
                : '发现 / Test manager / 2026-03-31',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            language == AppLanguage.en ? 'Filed 2026-05-15' : '披露 2026-05-15',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'research records do not imply a trade, position or monitoring rule',
    (tester) async {
      await mountResearch(tester);
      await tester.tap(find.byKey(const ValueKey('research-tab-records')));
      await tester.pumpAndSettle();
      for (final a in ['Watch', 'Pass', 'Invest']) {
        expect(find.widgetWithText(ChoiceChip, a), findsNothing);
      }
      expect(find.widgetWithText(TextField, 'Research units'), findsNothing);
      expect(
        find.widgetWithText(TextField, 'Target portfolio weight %'),
        findsNothing,
      );
      expect(
        find.widgetWithText(TextField, 'Research question'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save research record'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('unsaved research note requires explicit leave and can be kept', (
    tester,
  ) async {
    await mountResearch(tester);
    await tester.tap(find.byKey(const ValueKey('research-tab-records')));
    await tester.pumpAndSettle();
    final qField = find.widgetWithText(TextField, 'Research question');
    await tester.ensureVisible(qField);
    await tester.enterText(qField, 'Is dividend FCF coverage expanding?');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Leave unsaved research note?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(qField).controller!.text,
      'Is dividend FCF coverage expanding?',
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('Guru strategy requires an explicit manager selection', (
    tester,
  ) async {
    await mountDiscovery(
      tester,
      const Size(1487, 1058),
      AppLanguage.en,
      DiscoveryFixtureApi(),
    );
    await tester.tap(find.text('Strategies'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('strategy-builder-tab')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Run backtest'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Choose Gurus'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test manager'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done (1)'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Run backtest'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'changing cutoff from Research updates active cutoff cleanly',
    (tester) async {
      await mountResearch(tester);
      await tester.tap(find.text('As of 2026-06-01'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'YYYY-MM-DD'),
        '2026-08-28',
      );
      await tester.tap(find.text('Apply date'));
      await tester.pumpAndSettle();
      expect(find.text('As of 2026-08-28'), findsOneWidget);
      expect(find.byKey(const ValueKey('research-tab-value')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final language in AppLanguage.values) {
    for (final size in [
      const Size(1487, 1058),
      const Size(1280, 720),
      const Size(1024, 768),
      const Size(390, 844),
    ]) {
      for (final page in [
        'home',
        'research',
        'discover',
        'book',
        'strategies',
      ]) {
        testWidgets(
          'workflow $page $language $size remains usable without overflow',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              MaterialApp(
                home: LanguageScope(
                  language: language,
                  child: InvestmentWorkspace(
                    api: WorkflowTestApi(),
                    palette: Palette(false),
                    initialPage: page,
                    initialTicker: page == 'research' ? 'TEST' : '',
                    initialAsOf: '2026-06-01',
                    onLanguage: (_) {},
                    onLegacy: () {},
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('ThesisForge'), findsOneWidget);
            if (page == 'research') {
              expect(
                find.byKey(const ValueKey('research-tab-value')),
                findsNothing,
              );
              await tester.tap(
                find.byKey(const ValueKey('research-tab-dividends')),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(
                find.byKey(const ValueKey('research-dividend-scorecard')),
                findsOneWidget,
              );
              expect(
                find.byKey(const ValueKey('research-dividend-yield-chart')),
                findsOneWidget,
              );
            }
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  testWidgets('date edit cancel is explicit and navigation preserves Research statements', (
    tester,
  ) async {
    await mountResearch(tester);
    await tester.tap(find.text('As of 2026-06-01'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'YYYY-MM-DD'),
      '2026-08-28',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('As of 2026-06-01'), findsOneWidget);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Research'));
    await tester.pumpAndSettle();
    expect(find.text('TEST'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
