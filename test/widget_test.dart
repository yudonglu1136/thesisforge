import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guru_analysis_terminal/main.dart';

class _FakeAdminApiClient extends ApiClient {
  _FakeAdminApiClient() : super(() => 'test-token');

  int deleteCalls = 0;
  int restoreCalls = 0;

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async {
    deleteCalls += 1;
    expect(path, '/api/portfolio/connection');
    return {
      'status': 'success',
      'recoverable': true,
      'undoUntil': '2099-01-01T00:15:00Z',
    };
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == '/api/portfolio/connection/restore') {
      restoreCalls += 1;
      expect(body, isEmpty);
      return {'ok': true, 'restored': true};
    }
    return <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/api/admin/system-health') {
      return {
        'status': 'success',
        'database': {'sizeBytes': 1024, 'updatedAt': '2026-08-30T10:00:00Z'},
        'service': {'uptimeSeconds': 3600, 'environment': 'test'},
        'auth': {'allowedOriginCount': 1, 'apiCorsConfigured': 'true'},
        'portfolio': {
          'summary': {'users': 1},
        },
        'jobs': <Map<String, dynamic>>[],
      };
    }
    if (path.startsWith('/api/admin/portfolio-users/')) {
      return {
        'user': {
          'name': 'Test User',
          'email': 'test@example.com',
          'connection': {
            'status': 'not_configured',
            'accounts': <Map<String, dynamic>>[],
          },
        },
        'portfolio': {
          'summary': {
            'totalValue': 0,
            'holdings': 0,
            'accounts': 0,
            'cash': 0,
            'dayPnl': 0,
            'dayPnlPct': 0,
            'unrealizedPnl': 0,
            'unrealizedPnlPct': 0,
            'topWeight': 0,
            'currency': 'USD',
          },
          'connection': {
            'configured': false,
            'registered': false,
            'status': 'not_configured',
            'accounts': <Map<String, dynamic>>[],
          },
          'accounts': <Map<String, dynamic>>[],
          'holdings': <Map<String, dynamic>>[],
          'sectors': <Map<String, dynamic>>[],
          'performance': <Map<String, dynamic>>[],
          'performanceStatus': {
            'real': false,
            'message':
                'No real portfolio NAV history was returned by the upstream source.',
          },
          'dividends': <Map<String, dynamic>>[],
          'dividendStatus': <String, dynamic>{},
          'analytics': <String, dynamic>{},
        },
      };
    }
    return <String, dynamic>{};
  }
}

class _PendingGuruBacktestRequest {
  _PendingGuruBacktestRequest(this.path);

  final String path;
  final Completer<Map<String, dynamic>> completer =
      Completer<Map<String, dynamic>>();
}

class _ControlledGuruApiClient extends ApiClient {
  _ControlledGuruApiClient() : super(() => 'test-token');

  final List<_PendingGuruBacktestRequest> backtestRequests = [];
  final List<_PendingGuruBacktestRequest> exposureRequests = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) {
    if (path.contains('/exposure?')) {
      final request = _PendingGuruBacktestRequest(path);
      exposureRequests.add(request);
      return request.completer.future;
    }
    if (path.contains('/backtest?')) {
      final request = _PendingGuruBacktestRequest(path);
      backtestRequests.add(request);
      return request.completer.future;
    }
    return Future<Map<String, dynamic>>.value(<String, dynamic>{});
  }
}

Map<String, dynamic> _guruBacktestPayload(
  String years, {
  String? methodYears,
  String status = 'ready',
  bool warming = false,
  bool fullAttribution = false,
  double endingValue = 140,
  String? methodReason,
  Map<String, dynamic>? proxy,
  Map<String, dynamic>? publicReplicability,
}) {
  final starts = <String, String>{
    '5': '2021-09-01',
    '10': '2016-09-01',
    'all': '2013-08-14',
  };
  return <String, dynamic>{
    'status': status,
    'publicReplicability': ?publicReplicability,
    if (status == 'proxy_ready')
      'proxy':
          proxy ??
          <String, dynamic>{
            'kind': 'public_holdings_proxy',
            'minimumSelectedBookCoverage': .82,
            'averageSelectedBookCoverage': .93,
            'maximumExcludedBookWeight': .18,
            'minimumIncludedPositions': 3,
            'disclosureCode': 'top60_priceable_public_long_proxy',
            'disclosure': 'Only priced public holdings are included.',
            'topExcludedHoldings': <Map<String, dynamic>>[
              <String, dynamic>{'ticker': 'MISS', 'issuer': 'Missing Co'},
            ],
          },
    'historyWarming': warming,
    'method': <String, dynamic>{
      'years': methodYears ?? years,
      'reason': ?methodReason,
    },
    'detail': <String, dynamic>{
      'attribution': fullAttribution ? 'full' : 'compact',
    },
    'window': <String, dynamic>{'start': starts[years], 'end': '2026-09-01'},
    'quarterContributions': fullAttribution
        ? <Map<String, dynamic>>[
            <String, dynamic>{
              'id': '2026-q2',
              'label': '2026 Q2',
              'contributions': <Map<String, dynamic>>[
                <String, dynamic>{
                  'ticker': 'TEST',
                  'issuer': 'Test Holding',
                  'contributionPct': 0.05,
                },
              ],
            },
          ]
        : <Map<String, dynamic>>[],
    'equity': <Map<String, dynamic>>[
      <String, dynamic>{
        'date': starts[years],
        'value': 100.0,
        'benchmark': 100.0,
      },
      <String, dynamic>{
        'date': '2024-09-01',
        'value': 115.0,
        'benchmark': 110.0,
      },
      <String, dynamic>{
        'date': '2025-09-01',
        'value': 125.0,
        'benchmark': 118.0,
      },
      <String, dynamic>{
        'date': '2026-09-01',
        'value': endingValue,
        'benchmark': 128.0,
      },
    ],
  };
}

Map<String, dynamic> _privateRolloverReplicability() => <String, dynamic>{
  'status': 'strict_unavailable',
  'code': 'reported_holding_private_before_execution',
  'minimumExecutionCoverage': .9,
  'syntheticPriceUsed': false,
  'proxyOnlyWhenSeparatelyLabelled': true,
  'reasonEn':
      'The 2026 Q2 filing includes JHG, which was no longer publicly tradable when the filing became actionable. Without a public execution price, that quarter cannot satisfy the 90% strict replication gate. No synthetic price is used; any displayed curve is a separately labeled public-sleeve proxy.',
  'reasonZh':
      '2026 年 Q2 申报包含 JHG，但该证券在申报可执行时已不再公开交易。由于不存在公开市场执行价，本季度无法满足 90% 严格复制门槛。系统不会虚构价格；如展示曲线，仅为单独标注的公开持仓代理。',
  'affectedQuarters': <Map<String, dynamic>>[
    <String, dynamic>{
      'reportDate': '2026-06-30',
      'quarterLabel': '2026 Q2',
      'executionDate': '2026-08-17',
      'coveragePct': .556337,
      'minimumExecutionCoverage': .9,
      'strictGateSatisfied': false,
      'holdings': <Map<String, dynamic>>[
        <String, dynamic>{
          'ticker': 'JHG',
          'issuer': 'Janus Henderson Group plc',
          'cusip': 'G4474Y214',
          'reportedBookWeight': .443663,
          'publicTradingStatus': 'private_before_execution',
          'syntheticPriceUsed': false,
        },
      ],
    },
  ],
};

Map<String, dynamic> _guruStateMachineManager({
  String id = 'state-machine-manager',
}) => <String, dynamic>{
  'id': id,
  'name': 'State Machine Manager',
  'chineseName': '状态机经理',
  'entityName': 'State Machine Capital',
  'type': 'manager13f',
  'thesisTag': 'Concentrated',
  'disclosureKind': '13F-HR',
  'simulationTag': <String, dynamic>{
    'label': '13F copy simulation',
    'tone': 'positive',
  },
  'summary': <String, dynamic>{
    'reported13fValue': 150,
    'commonLongValue': 150,
    'totalPositions': 2,
    'reportDate': '2026-06-30',
    'filingDate': '2026-08-14',
  },
  'holdings': <Map<String, dynamic>>[],
  'activity': <Map<String, dynamic>>[],
};

Map<String, dynamic> _guruExposurePayload() => <String, dynamic>{
  'status': 'live',
  'meta': <String, dynamic>{
    'requestedQuarters': 40,
    'returnedQuarters': 3,
    'storedRequestedQuarters': 40,
  },
  'cache': <String, dynamic>{'status': 'hit'},
  'history': <Map<String, dynamic>>[
    <String, dynamic>{
      'reportDate': '2025-12-31',
      'quarterLabel': '2025 Q4',
      'commonLongValue': 1000000000,
      'positionCount': 45,
      'top10Weight': .61,
      'turnoverProxy': .12,
      'topHoldings': <Map<String, dynamic>>[
        <String, dynamic>{
          'ticker': 'NVDA',
          'issuer': 'NVIDIA Corp',
          'cusip': '67066G104',
          'value': 180000000,
          'pctPortfolio': .18,
        },
        <String, dynamic>{
          'ticker': 'MSFT',
          'issuer': 'Microsoft Corp',
          'cusip': '594918104',
          'value': 120000000,
          'pctPortfolio': .12,
        },
      ],
    },
    <String, dynamic>{
      'reportDate': '2026-03-31',
      'quarterLabel': '2026 Q1',
      'commonLongValue': 1200000000,
      'positionCount': 47,
      'top10Weight': .64,
      'turnoverProxy': .16,
      'topHoldings': <Map<String, dynamic>>[
        <String, dynamic>{
          'ticker': 'NVDA',
          'issuer': 'NVIDIA Corp',
          'cusip': '67066G104',
          'value': 240000000,
          'pctPortfolio': .20,
        },
        <String, dynamic>{
          'ticker': 'MSFT',
          'issuer': 'Microsoft Corp',
          'cusip': '594918104',
          'value': 132000000,
          'pctPortfolio': .11,
        },
      ],
    },
    <String, dynamic>{
      'reportDate': '2026-06-30',
      'quarterLabel': '2026 Q2',
      'commonLongValue': 1500000000,
      'positionCount': 49,
      'top10Weight': .68,
      'turnoverProxy': .19,
      'topHoldings': <Map<String, dynamic>>[
        <String, dynamic>{
          'ticker': 'NVDA',
          'issuer': 'NVIDIA Corp',
          'cusip': '67066G104',
          'value': 330000000,
          'pctPortfolio': .22,
        },
        <String, dynamic>{
          'ticker': 'MSFT',
          'issuer': 'Microsoft Corp',
          'cusip': '594918104',
          'value': 180000000,
          'pctPortfolio': .12,
        },
      ],
    },
  ],
};

Future<void> _pumpGuruStateMachine(
  WidgetTester tester,
  _ControlledGuruApiClient api, {
  int initialModule = 0,
  Map<String, dynamic>? guru,
  AppLanguage language = AppLanguage.en,
  Size viewportSize = const Size(1000, 1200),
}) async {
  tester.view.physicalSize = viewportSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    LanguageScope(
      language: language,
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: GuruWorkspace(
              guru: guru ?? _guruStateMachineManager(),
              api: api,
              palette: Palette(false),
              initialModule: initialModule,
              initialTicker: '',
              initialQuarterId: '',
              onModuleChanged: (_) {},
              onTickerChanged: (_) {},
              onQuarterChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _flushGuruState(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

ValuationRow _valuationRow(
  double upside, {
  bool hasModel = true,
  String ticker = 'TEST',
}) => ValuationRow(
  ticker: ticker,
  name: '$ticker Co',
  sector: 'Software',
  currency: 'USD',
  latestPrice: hasModel ? 100 : 0,
  fairValue: hasModel ? 100 * (1 + upside) : 0,
  upside: upside,
  targetPrice3Y: 120,
  expectedReturn3Y: .06,
  latestPriceDate: '2026-08-30',
  coverageKind: 'model',
  lineageStatus: 'pass',
  releaseStatus: 'verified',
  economicValidationStatus: 'not_validated',
  marketCalibrationStatus: 'guardrail_only',
  consensusStatus: 'watch',
  consensusUpside: null,
);

List<Map<String, dynamic>> _marketLensTestGurus() => [
  {
    'id': 'manager-a',
    'name': 'Manager A',
    'type': 'manager13f',
    'summary': {
      'reportDate': '2026-06-30',
      'filingDate': '2026-08-14',
      'commonLongValue': 100,
      'previousCommonLongValue': 90,
    },
    'holdings': [
      {'ticker': 'AAA', 'issuer': 'Alpha Inc', 'value': 40},
      {'ticker': 'BBB', 'issuer': 'Beta Inc', 'value': 60},
    ],
    'activity': [
      {
        'ticker': 'AAA',
        'issuer': 'Alpha Inc',
        'action': 'increased',
        'value': 40,
        'previousValue': 20,
        'changeShares': 10,
      },
    ],
  },
  {
    'id': 'manager-b',
    'name': 'Manager B',
    'type': 'manager13f',
    'summary': {
      'reportDate': '2026-06-30',
      'filingDate': '2026-08-13',
      'commonLongValue': 200,
      'previousCommonLongValue': 180,
    },
    'holdings': [
      {'ticker': 'AAA', 'issuer': 'Alpha Inc', 'value': 50},
      {'ticker': 'CCC', 'issuer': 'Gamma Inc', 'value': 150},
    ],
    'activity': [
      {
        'ticker': 'AAA',
        'issuer': 'Alpha Inc',
        'action': 'new',
        'value': 50,
        'previousValue': 0,
        'changeShares': 25,
      },
    ],
  },
];

List<Map<String, dynamic>> _privateMarketLensTestGurus() => [
  {
    'id': 'nelson-peltz',
    'name': 'Nelson Peltz',
    'chineseName': '纳尔逊·佩尔茨',
    'type': 'manager13f',
    'summary': {
      'reportDate': '2026-06-30',
      'filingDate': '2026-08-14',
      'commonLongValue': 100,
      'previousCommonLongValue': 90,
    },
    'holdings': [
      {
        'ticker': 'JHG',
        'issuer': 'Janus Henderson Group plc',
        'value': 44,
        'publicTradingStatus': 'private_after_reported_quarter',
        'publicReplicable': false,
        'publicTrading': {
          'publicTradingStatus': 'private_after_reported_quarter',
          'publicReplicable': false,
          'reasonEn':
              'This reported holding rolled into a private interest after quarter-end. Public trading ended before the 13F became actionable.',
          'reasonZh': '该申报持仓在季度末后转为非公开权益。其公开交易在 13F 可执行前已经结束。',
        },
      },
    ],
    'activity': [
      {
        'ticker': 'JHG',
        'issuer': 'Janus Henderson Group plc',
        'action': 'increased',
        'value': 44,
        'previousValue': 20,
        'changeShares': 10,
        'publicTradingStatus': 'private_after_reported_quarter',
        'publicReplicable': false,
        'publicTrading': {
          'publicTradingStatus': 'private_after_reported_quarter',
          'publicReplicable': false,
          'reasonEn':
              'This reported holding rolled into a private interest after quarter-end. Public trading ended before the 13F became actionable.',
          'reasonZh': '该申报持仓在季度末后转为非公开权益。其公开交易在 13F 可执行前已经结束。',
        },
      },
    ],
  },
];

void main() {
  test('portfolio recovery countdown rounds up and expires safely', () {
    final now = DateTime.utc(2026, 9, 1, 12);
    expect(
      portfolioRecoveryMinutesRemaining('2026-09-01T12:14:01Z', now: now),
      15,
    );
    expect(
      portfolioRecoveryMinutesRemaining('2026-09-01T12:00:01Z', now: now),
      1,
    );
    expect(
      portfolioRecoveryMinutesRemaining('2026-09-01T12:00:00Z', now: now),
      0,
    );
    expect(portfolioRecoveryMinutesRemaining('invalid', now: now), 0);
  });

  test('retired local login returns open Discover without obsolete state', () {
    expect(retiredModuleReturnPath('/ontology/'), '/?view=discover&lang=en');
    expect(
      retiredModuleReturnPath('/ontology/?view=market#latest'),
      '/?view=discover&lang=en',
    );
    expect(retiredModuleReturnPath('https://example.com/ontology/'), isNull);
    expect(retiredModuleReturnPath('//example.com/ontology/'), isNull);
    expect(retiredModuleReturnPath('/ontology-admin'), isNull);
    expect(retiredModuleReturnPath('/ontology/?lang=%FF'), isNull);
    expect(retiredModuleReturnPath('/dbmf'), '/?view=discover&lang=en');
    expect(
      retiredModuleReturnPath('/dbmf/?view=market#latest'),
      '/?view=discover&lang=en',
    );
    for (final value in <String?>[
      null,
      '',
      '/portfolio',
      '/dbmfund',
      '/research/isrg/',
    ]) {
      expect(retiredModuleReturnPath(value), isNull);
    }
  });

  test('retired routes use Discover with a safe legacy-flag fallback', () {
    final destination = investmentWorkflowEnabled ? 'discover' : 'guru';
    for (final mode in ['dbmf', 'ontology', ' ONTOLOGY ']) {
      expect(normalizeRouteMode(mode), destination);
    }
    for (final path in [
      '/dbmf',
      '/dbmf/history',
      '/ontology',
      '/ontology/',
      '/ontology/index.html',
    ]) {
      expect(normalizeRouteMode(null, path: path), destination);
      expect(normalizeRouteMode('market', path: path), destination);
    }
    expect(normalizeRouteMode('valuation', path: '/'), 'valuation');
  });

  test('market lens navigation clears filters that can hide its manager', () {
    final target = guruTradeNavigationTarget(' manager-b ', 'aaa');

    expect(target, isNotNull);
    expect(target!.guruId, 'manager-b');
    expect(target.ticker, 'AAA');
    expect(target.search, isEmpty);
    expect(target.filter, 'all');
    expect(guruTradeNavigationTarget('', 'AAA'), isNull);
    expect(guruTradeNavigationTarget('manager-b', ''), isNull);
  });

  testWidgets('guru search controller reflects a programmatic reset', (
    WidgetTester tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String search = '';
    String filter = '';

    await tester.pumpWidget(
      LanguageScope(
        language: AppLanguage.en,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: GuruUniversePanel(
                gurus: _marketLensTestGurus(),
                selectedGuruId: 'manager-a',
                searchController: controller,
                filter: 'all',
                palette: Palette(false),
                onSearch: (value) => search = value,
                onFilter: (value) => filter = value,
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final field = find.byKey(const ValueKey('guru-universe-search'));
    await tester.enterText(field, 'Ackman');
    expect(search, 'Ackman');
    expect(tester.widget<TextField>(field).controller!.text, 'Ackman');

    controller.clear();
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);

    await tester.tap(find.byKey(const ValueKey('guru-universe-firms')));
    expect(filter, 'manager13f');

    await tester.tap(find.byKey(const ValueKey('guru-universe-gurus')));
    expect(filter, 'all');
  });

  test('loads guru data only when the guru route first needs it', () {
    expect(shouldLoadGuruDashboard('valuation', null), isFalse);
    expect(shouldLoadGuruDashboard('portfolio', null), isFalse);
    expect(shouldLoadGuruDashboard('guru', null), isTrue);
    expect(
      shouldLoadGuruDashboard('guru', <String, dynamic>{'gurus': []}),
      isFalse,
    );
  });

  test(
    'module truth headers use economic as-of dates and computed staleness',
    () {
      final now = DateTime.utc(2026, 9, 1, 12);
      final valuation = moduleHeaderState(
        mode: 'valuation',
        payload: {
          'generatedAt': '2026-09-01T11:00:00Z',
          'summary': {'latestPriceDate': '2026-08-29'},
          'source': {'label': 'Valuation DB'},
        },
        loading: false,
        now: now,
      );
      expect(valuation.asOf, '2026-08-29');
      expect(valuation.status, 'stale');

      final currentValuation = moduleHeaderState(
        mode: 'valuation',
        payload: {
          'generatedAt': '2026-08-27T00:00:00Z',
          'summary': {'latestPriceDate': '2026-08-30'},
        },
        loading: false,
        now: now,
      );
      expect(currentValuation.status, 'cached');

      final stale = moduleHeaderState(
        mode: 'valuation',
        payload: {
          'generatedAt': '2026-08-27T00:00:00Z',
          'summary': {'latestPriceDate': '2026-08-26'},
        },
        loading: false,
        now: now,
      );
      expect(stale.status, 'stale');

      final guru = moduleHeaderState(
        mode: 'guru',
        payload: {
          'generatedAt': '2026-09-01T08:00:00Z',
          'gurus': [
            {
              'summary': {
                'reportDate': '2026-06-30',
                'filingDate': '2026-08-14',
              },
            },
          ],
        },
        loading: false,
        now: now,
      );
      expect(guru.asOf, '2026-08-14');
      expect(guru.status, 'cached');

      final sample = moduleHeaderState(
        mode: 'portfolio',
        payload: {
          'source': {'mode': 'sample', 'label': 'Portfolio module sample'},
        },
        loading: false,
        now: now,
      );
      expect(sample.status, 'sample');
      expect(toolbarDateLabel('', AppLanguage.en), 'As-of unavailable');

      final liveWithoutEconomicAsOf = moduleHeaderState(
        mode: 'portfolio',
        payload: {
          'generatedAt': '2026-09-01T11:59:00Z',
          'source': {'mode': 'live', 'label': 'Yodlee Core APIs'},
        },
        loading: false,
        now: now,
      );
      expect(liveWithoutEconomicAsOf.asOf, isEmpty);
      expect(liveWithoutEconomicAsOf.status, 'cached');

      final liveWithUpstreamAsOf = moduleHeaderState(
        mode: 'portfolio',
        payload: {
          'generatedAt': '2026-09-01T11:59:00Z',
          'source': {
            'mode': 'multi_account_live',
            'label': 'IBKR Third-Party Reports / Yodlee',
            'toDate': '2026-08-31',
          },
        },
        loading: false,
        now: now,
      );
      expect(liveWithUpstreamAsOf.asOf, '2026-08-31');
      expect(liveWithUpstreamAsOf.status, 'live');
    },
  );

  test('valuation buckets use one consistent five-percent boundary', () {
    expect(valuationBucketForRow(_valuationRow(.05)), 'undervalued');
    expect(valuationBucketForRow(_valuationRow(.049)), 'fair');
    expect(valuationBucketForRow(_valuationRow(-.049)), 'fair');
    expect(valuationBucketForRow(_valuationRow(-.05)), 'expensive');
    expect(valuationBucketForRow(_valuationRow(0, hasModel: false)), 'missing');
  });

  test('valuation filtering reconciles selection to visible results', () {
    final visible = [
      _valuationRow(.2, ticker: 'AAA'),
      _valuationRow(.1, ticker: 'BBB'),
    ];

    expect(reconciledValuationTicker(visible, 'BBB'), 'BBB');
    expect(reconciledValuationTicker(visible, 'HIDDEN'), 'AAA');
    expect(reconciledValuationTicker(const <ValuationRow>[], 'AAA'), '');
  });

  test('valuation audit layers stay independent in dashboard rows', () {
    final rows = valuationRowsFromTickers([
      {
        'ticker': 'TEST',
        'latest': {
          'latestPrice': 100,
          'baseFairValue': 120,
          'upsideToBase': .2,
        },
        'dataQuality': {
          'auditLayers': {
            'lineage': {'status': 'pass'},
            'release': {'status': 'verified'},
            'economicValidation': {'status': 'not_validated'},
            'marketCalibration': {'status': 'guardrail_only'},
          },
        },
      },
    ]);
    expect(rows.single.lineageStatus, 'pass');
    expect(rows.single.releaseStatus, 'verified');
    expect(rows.single.economicValidationStatus, 'not_validated');
    expect(rows.single.marketCalibrationStatus, 'guardrail_only');
  });

  test('valuation default is neutral instead of highest model upside', () {
    Map<String, dynamic> ticker(
      String symbol,
      double fairValue, {
      String lineage = 'pass',
    }) => {
      'ticker': symbol,
      'latest': {'latestPrice': 100, 'baseFairValue': fairValue},
      'dataQuality': {
        'auditLayers': {
          'lineage': {'status': lineage},
        },
      },
    };

    final dashboard = {
      'tickers': [ticker('ZZZ', 500), ticker('BBB', 110), ticker('AAA', 105)],
    };
    expect(defaultValuationTicker(dashboard), 'AAA');
    expect(defaultValuationTicker(dashboard, preferred: 'ZZZ'), 'ZZZ');
    expect(
      defaultValuationTicker({...dashboard, 'featuredTicker': 'BBB'}),
      'BBB',
    );
  });

  test('reported 13F totals keep common longs and options separate', () {
    final guru = <String, dynamic>{
      'summary': {'reported13fValue': 150},
      'holdings': [
        {'value': 100, 'putCall': ''},
        {'value': 30, 'putCall': 'CALL'},
        {'value': 20, 'putCall': 'PUT'},
      ],
    };
    expect(reported13fTableValue(guru), 150);
    expect(reported13fCommonLongValue(guru), 100);
    expect(reported13fOptionsValue(guru), 50);
    expect(
      reported13fActionLabel('new', AppLanguage.en),
      'Reported new position',
    );
    expect(
      reported13fActionLabel('reduced', AppLanguage.en),
      'Reported reduction',
    );
    expect(
      guruDisplayStatus({
        'status': 'live',
        'dataStatus': {'status': 'local-db'},
      }),
      'cached',
    );
  });

  testWidgets(
    'compact guru header discloses common-long and options ownership',
    (WidgetTester tester) async {
      final guru = <String, dynamic>{
        'name': 'Test Manager',
        'entityName': 'Test Capital',
        'type': 'manager13f',
        'thesisTag': 'Concentrated',
        'disclosureKind': '13F filing',
        'simulationTag': {'label': '13F copy simulation'},
        'summary': {
          'reported13fValue': 150,
          'totalPositions': 3,
          'reportDate': '2026-06-30',
          'filingDate': '2026-08-14',
        },
        'holdings': [
          {'value': 100, 'putCall': ''},
          {'value': 30, 'putCall': 'CALL'},
          {'value': 20, 'putCall': 'PUT'},
        ],
      };

      await tester.pumpWidget(
        LanguageScope(
          language: AppLanguage.en,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: SizedBox(
                width: 1000,
                child: GuruWorkspaceHeader(guru: guru, palette: Palette(false)),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Reported 13F value'), findsOneWidget);
      expect(find.text(r'Long $100 · Opt $50'), findsOneWidget);
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip).first).message,
        r'Common-long $100 · Options $50',
      );
    },
  );

  testWidgets('simulation range reset names the audited five-year window', (
    WidgetTester tester,
  ) async {
    var reset = false;
    await tester.pumpWidget(
      LanguageScope(
        language: AppLanguage.en,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SimulationRangeBar(
              palette: Palette(false),
              range: const RangeValues(20, 100),
              maxIndex: 100,
              selectedStart: '2025/09/01',
              selectedEnd: '2026/09/01',
              fullStart: '2021/09/01',
              fullEnd: '2026/09/01',
              resetLabel: 'Full 5Y',
              resetTooltip: 'Reset to the full audited 5Y window',
              onChanged: (_) {},
              onReset: () => reset = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Full 5Y'), findsOneWidget);
    expect(find.text('All'), findsNothing);
    await tester.tap(find.text('Full 5Y'));
    expect(reset, isTrue);
  });

  testWidgets('guru desktop keeps the equity curve in the first viewport', (
    WidgetTester tester,
  ) async {
    const contentViewportHeight =
        644.0; // 720px minus 66px header and 10px content top padding.
    final requestedWindows = <String>[];
    tester.view.physicalSize = const Size(690, contentViewportHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final guru = <String, dynamic>{
      'id': 'test-manager',
      'name': 'Test Manager',
      'entityName': 'Test Capital',
      'type': 'manager13f',
      'thesisTag': 'Concentrated',
      'disclosureKind': '13F filing',
      'simulationTag': {'label': '13F copy simulation'},
      'summary': {
        'reported13fValue': 150,
        'commonLongValue': 150,
        'totalPositions': 2,
        'reportDate': '2026-06-30',
        'filingDate': '2026-08-14',
      },
      'holdings': <Map<String, dynamic>>[],
    };
    final payload = <String, dynamic>{
      'status': 'ready',
      'summary': <String, dynamic>{
        'totalReturn': .41,
        'maxDrawdown': -.55,
        'excessTotalReturn': .13,
        'benchmark': <String, dynamic>{'totalReturn': .28},
      },
      'equitySampling': <String, dynamic>{
        'sampled': true,
        'returnedPoints': 4,
        'sourcePoints': 1200,
      },
      'equity': [
        {'date': '2021-01-03', 'value': 100.0, 'benchmark': 100.0},
        {'date': '2022-01-03', 'value': 104.0, 'benchmark': 102.0},
        {'date': '2023-01-03', 'value': 100.0, 'benchmark': 100.0},
        {'date': '2024-01-03', 'value': 112.0, 'benchmark': 108.0},
        {'date': '2025-01-03', 'value': 125.0, 'benchmark': 116.0},
        {'date': '2026-01-03', 'value': 141.0, 'benchmark': 128.0},
      ],
    };

    await tester.pumpWidget(
      LanguageScope(
        language: AppLanguage.en,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  GuruWorkspaceHeader(guru: guru, palette: Palette(false)),
                  const SizedBox(height: 14),
                  GuruModuleTabs(
                    selected: 0,
                    onChanged: (_) {},
                    palette: Palette(false),
                  ),
                  const SizedBox(height: 14),
                  GuruSimulationModule(
                    payload: payload,
                    loading: false,
                    error: null,
                    guru: guru,
                    palette: Palette(false),
                    loadedWindow: '5',
                    requestedWindow: null,
                    windowError: null,
                    onWindowRequested: requestedWindows.add,
                    onRetry: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final chart = find.byKey(const ValueKey('guru-simulation-equity-chart'));
    final range = find.byKey(const ValueKey('guru-simulation-range-bar'));
    expect(chart, findsOneWidget);
    expect(range, findsOneWidget);
    expect(tester.getSize(chart).height, 120);
    expect(tester.getTopLeft(range).dy, lessThan(tester.getTopLeft(chart).dy));
    expect(
      tester.getBottomLeft(chart).dy,
      lessThanOrEqualTo(contentViewportHeight),
    );
    expect(find.text('-55.0%'), findsOneWidget);
    expect(find.text('MDD'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('guru-simulation-proxy-notice')),
      findsNothing,
    );
    expect(find.text('Simulation: Portfolio vs SPY'), findsOneWidget);

    await tester.tap(find.text('1Y'));
    await tester.pump();
    var selectedChart = tester.widget<EquityChart>(
      find.descendant(of: chart, matching: find.byType(EquityChart)),
    );
    expect(selectedChart.equity, hasLength(2));

    await tester.tap(find.text('3Y'));
    await tester.pump();
    selectedChart = tester.widget<EquityChart>(
      find.descendant(of: chart, matching: find.byType(EquityChart)),
    );
    expect(selectedChart.equity, hasLength(4));

    await tester.tap(find.text('5Y'));
    await tester.pump();
    selectedChart = tester.widget<EquityChart>(
      find.descendant(of: chart, matching: find.byType(EquityChart)),
    );
    expect(selectedChart.equity, hasLength(6));

    await tester.tap(find.text('10Y'));
    await tester.tap(find.text('All'));
    expect(requestedWindows, ['10', 'all']);

    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    slider.onChanged!(const RangeValues(1, 3));
    await tester.pump();
    selectedChart = tester.widget<EquityChart>(
      find.descendant(of: chart, matching: find.byType(EquityChart)),
    );
    expect(selectedChart.equity, hasLength(3));
    expect(number(selectedChart.equity.first['value']), 1);
    expect(number(selectedChart.equity.first['benchmark']), 1);
    expect(find.text('MDD≈'), findsOneWidget);
    expect(
      find.textContaining('selected-range MDD is approximate'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Renaissance strict curve visibly discloses manager-level 13F and Medallion limitation',
    (WidgetTester tester) async {
      const contentViewportHeight = 644.0;
      final api = _ControlledGuruApiClient();
      final guru = <String, dynamic>{
        ..._guruStateMachineManager(id: 'renaissance-technologies'),
        'name': 'Renaissance Technologies',
        'chineseName': '文艺复兴科技',
        'simulationTag': <String, dynamic>{
          'label': '13F copy simulation',
          'tone': 'simulatable',
          'description':
              'Audited manager-level public 13F model: the strict 5Y curve keeps uncovered weight in cash and requires 90% execution coverage; the extended 10Y public-sleeve proxy, when needed, renormalizes only fully priceable Top-60 holdings. This is not the Medallion Fund portfolio.',
        },
      };
      await _pumpGuruStateMachine(
        tester,
        api,
        guru: guru,
        viewportSize: const Size(690, contentViewportHeight),
      );
      api.backtestRequests.single.completer.complete(_guruBacktestPayload('5'));
      await _flushGuruState(tester);

      expect(
        find.text('MANAGER-LEVEL PUBLIC 13F · NOT MEDALLION'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message ?? '').contains(
                'This is not the Medallion Fund portfolio.',
              ),
        ),
        findsOneWidget,
      );
      expect(find.text('Renaissance 13F'), findsOneWidget);
      final chart = find.byKey(const ValueKey('guru-simulation-equity-chart'));
      expect(chart, findsOneWidget);
      expect(
        tester.getBottomLeft(chart).dy,
        lessThanOrEqualTo(contentViewportHeight),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Renaissance proxy curve keeps the manager-level limitation visible in Chinese',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      final guru = <String, dynamic>{
        ..._guruStateMachineManager(id: 'renaissance-technologies'),
        'name': 'Renaissance Technologies',
        'chineseName': '文艺复兴科技',
        'simulationTag': <String, dynamic>{
          'label': '13F copy simulation',
          'tone': 'simulatable',
          'description':
              'Audited manager-level public 13F model: the strict 5Y curve keeps uncovered weight in cash and requires 90% execution coverage; the extended 10Y public-sleeve proxy, when needed, renormalizes only fully priceable Top-60 holdings. This is not the Medallion Fund portfolio.',
        },
      };
      await _pumpGuruStateMachine(
        tester,
        api,
        guru: guru,
        language: AppLanguage.zh,
        viewportSize: const Size(390, 844),
      );
      api.backtestRequests.single.completer.complete(
        _guruBacktestPayload('5', status: 'proxy_ready'),
      );
      await _flushGuruState(tester);

      expect(find.text('管理人级公开 13F · 非 MEDALLION'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message ?? '').contains('这不是 Medallion Fund 持仓。'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('guru-simulation-proxy-notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('guru-simulation-equity-chart')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'proxy-ready history shows the curve, range, coverage and disclosure',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);

      api.backtestRequests.single.completer.complete(
        _guruBacktestPayload('5', status: 'proxy_ready'),
      );
      await _flushGuruState(tester);

      expect(find.text('Public sleeve proxy vs SPY'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guru-simulation-proxy-notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('guru-simulation-range-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('guru-simulation-equity-chart')),
        findsOneWidget,
      );
      expect(
        find.textContaining('82.0% min Top-60 priceable weight'),
        findsOneWidget,
      );
      expect(find.textContaining('3+ holdings'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('guru-proxy-disclosure-expander')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Average Top-60 priceable weight 93.0%', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('Maximum excluded weight 18.0%', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Largest excluded holdings: MISS'), findsOneWidget);
      expect(
        find.textContaining(
          'This is not a strict coverage-audited fund return.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'private-before-execution quarter shows a truthful strict-unavailable state',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);

      api.backtestRequests.single.completer.complete(
        _guruBacktestPayload(
          '5',
          status: 'insufficient_data',
          methodReason: 'Execution coverage is incomplete.',
          publicReplicability: _privateRolloverReplicability(),
        ),
      );
      await _flushGuruState(tester);

      expect(
        find.byKey(const ValueKey('guru-strict-replication-unavailable')),
        findsOneWidget,
      );
      expect(find.text('Strict replay unavailable'), findsOneWidget);
      expect(
        find.text('2026 Q2 · JHG · 44.4% of selected book'),
        findsOneWidget,
      );
      expect(
        find.textContaining('cannot satisfy the 90% strict replication gate'),
        findsOneWidget,
      );
      expect(find.textContaining('No synthetic price is used'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guru-simulation-equity-chart')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'private rollover reason is fully localized when only a proxy is displayable',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(
        tester,
        api,
        language: AppLanguage.zh,
        viewportSize: const Size(390, 844),
      );

      api.backtestRequests.single.completer.complete(
        _guruBacktestPayload(
          '5',
          status: 'proxy_ready',
          publicReplicability: _privateRolloverReplicability(),
        ),
      );
      await _flushGuruState(tester);

      expect(find.text('严格复制不可用 · 2026 Q2 JHG 已转为私有'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guru-simulation-equity-chart')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('guru-proxy-disclosure-expander')),
      );
      await tester.tap(
        find.byKey(const ValueKey('guru-proxy-disclosure-expander')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('无法满足 90% 严格复制门槛'), findsOneWidget);
      expect(find.textContaining('系统不会虚构价格'), findsOneWidget);
      expect(find.textContaining('cannot satisfy the 90%'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'proxy curve fits the real 1280x720 three-column slot and mobile stays overflow-safe',
    (WidgetTester tester) async {
      final desktopApi = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(
        tester,
        desktopApi,
        // At a 1280x720 shell, the 66px terminal header, 10px content inset,
        // 270px universe rail and 280px right rail leave this workspace slot.
        viewportSize: const Size(690, 644),
      );
      desktopApi.backtestRequests.single.completer.complete(
        _guruBacktestPayload('5', status: 'proxy_ready'),
      );
      await _flushGuruState(tester);

      final desktopChart = find.byKey(
        const ValueKey('guru-simulation-equity-chart'),
      );
      final desktopNotice = find.byKey(
        const ValueKey('guru-simulation-proxy-notice'),
      );
      expect(desktopChart, findsOneWidget);
      expect(desktopNotice, findsOneWidget);
      expect(tester.getBottomLeft(desktopChart).dy, lessThanOrEqualTo(644));
      expect(
        tester.getTopLeft(desktopChart).dy,
        lessThan(tester.getTopLeft(desktopNotice).dy),
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final mobileApi = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(
        tester,
        mobileApi,
        viewportSize: const Size(390, 844),
      );
      mobileApi.backtestRequests.single.completer.complete(
        _guruBacktestPayload('5', status: 'proxy_ready'),
      );
      await _flushGuruState(tester);

      final mobileChart = find.byKey(
        const ValueKey('guru-simulation-equity-chart'),
      );
      expect(mobileChart, findsOneWidget);
      expect(tester.getSize(mobileChart).width, greaterThan(320));
      expect(find.text('1Y'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-window proxy response cannot downgrade a strict ready curve',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);
      api.backtestRequests.single.completer.complete(
        _guruBacktestPayload('5', endingValue: 140),
      );
      await _flushGuruState(tester);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      expect(api.backtestRequests, hasLength(2));
      api.backtestRequests[1].completer.complete(
        _guruBacktestPayload(
          '5',
          status: 'proxy_ready',
          endingValue: 220,
          methodReason:
              'The strict selected-book curve failed its execution-coverage gate; a separately labeled fully priceable public-sleeve proxy is available.',
        ),
      );
      await _flushGuruState(tester);

      expect(find.text('Simulation: Portfolio vs SPY'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guru-simulation-proxy-notice')),
        findsNothing,
      );
      expect(
        find.textContaining('strict audited curve was kept'),
        findsOneWidget,
      );
      final chart = tester.widget<EquityChart>(find.byType(EquityChart));
      expect(number(chart.equity.last['value']), closeTo(1.4, 0.000001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-window proxy fallback never leaks its backend reason in Chinese',
    (WidgetTester tester) async {
      const backendReason =
          'The strict selected-book curve failed its execution-coverage gate; a separately labeled fully priceable public-sleeve proxy is available.';
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api, language: AppLanguage.zh);
      api.backtestRequests.single.completer.complete(_guruBacktestPayload('5'));
      await _flushGuruState(tester);

      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      api.backtestRequests[1].completer.complete(
        _guruBacktestPayload(
          '5',
          status: 'proxy_ready',
          endingValue: 220,
          methodReason: backendReason,
        ),
      );
      await _flushGuruState(tester);

      expect(find.text('模拟：组合与 SPY 对比'), findsOneWidget);
      expect(find.textContaining('已保留严格审计曲线'), findsOneWidget);
      expect(find.textContaining(backendReason), findsNothing);
      expect(
        find.byKey(const ValueKey('guru-simulation-proxy-notice')),
        findsNothing,
      );
      final chart = tester.widget<EquityChart>(find.byType(EquityChart));
      expect(number(chart.equity.last['value']), closeTo(1.4, 0.000001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('proxy-ready history has explicit Chinese labeling', (
    WidgetTester tester,
  ) async {
    final api = _ControlledGuruApiClient();
    await _pumpGuruStateMachine(tester, api, language: AppLanguage.zh);
    api.backtestRequests.single.completer.complete(
      _guruBacktestPayload('5', status: 'proxy_ready'),
    );
    await _flushGuruState(tester);

    expect(find.text('公开持仓代理 vs SPY'), findsOneWidget);
    expect(find.textContaining('Top-60 可定价权重最低 82.0%'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('guru-proxy-disclosure-expander')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('不是经过严格覆盖审计'), findsOneWidget);
    expect(find.textContaining('Only priced public holdings'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'explicit window selection may replace strict ready with that window proxy',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);
      api.backtestRequests.single.completer.complete(_guruBacktestPayload('5'));
      await _flushGuruState(tester);

      await tester.tap(find.text('10Y'));
      await tester.pump();
      api.backtestRequests[1].completer.complete(
        _guruBacktestPayload('10', status: 'proxy_ready', endingValue: 180),
      );
      await _flushGuruState(tester);

      expect(find.text('Full 10Y'), findsOneWidget);
      expect(find.text('Public sleeve proxy vs SPY'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guru-simulation-proxy-notice')),
        findsOneWidget,
      );
      final chart = tester.widget<EquityChart>(find.byType(EquityChart));
      expect(number(chart.equity.last['value']), closeTo(1.8, 0.000001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('proxy-ready history supports full quarterly attribution', (
    WidgetTester tester,
  ) async {
    final api = _ControlledGuruApiClient();
    await _pumpGuruStateMachine(tester, api);
    api.backtestRequests.single.completer.complete(
      _guruBacktestPayload('5', status: 'proxy_ready'),
    );
    await _flushGuruState(tester);

    await tester.tap(find.text('Quarterly Contribution').first);
    await tester.pump();
    expect(api.backtestRequests, hasLength(2));
    expect(api.backtestRequests[1].path, contains('detail=full'));
    api.backtestRequests[1].completer.complete(
      _guruBacktestPayload('5', status: 'proxy_ready', fullAttribution: true),
    );
    await _flushGuruState(tester);

    expect(find.text('TEST'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('guru-quarterly-proxy-notice')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a same-window warmup refresh preserves a custom date range', (
    WidgetTester tester,
  ) async {
    final guru = _guruStateMachineManager();
    var payload = _guruBacktestPayload('5');
    payload['equity'] = <Map<String, dynamic>>[
      {'date': '2021-09-01', 'value': 100.0, 'benchmark': 100.0},
      {'date': '2022-09-01', 'value': 106.0, 'benchmark': 103.0},
      {'date': '2023-09-01', 'value': 112.0, 'benchmark': 107.0},
      {'date': '2024-09-01', 'value': 118.0, 'benchmark': 111.0},
      {'date': '2025-09-01', 'value': 126.0, 'benchmark': 118.0},
      {'date': '2025-12-01', 'value': 132.0, 'benchmark': 122.0},
      {'date': '2026-09-01', 'value': 140.0, 'benchmark': 128.0},
    ];
    late StateSetter updateHost;

    Widget host() => LanguageScope(
      language: AppLanguage.en,
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              updateHost = setState;
              return GuruSimulationModule(
                payload: payload,
                loading: false,
                error: null,
                guru: guru,
                palette: Palette(false),
                loadedWindow: '5',
                requestedWindow: null,
                windowError: null,
                onWindowRequested: (_) {},
                onRetry: () {},
              );
            },
          ),
        ),
      ),
    );

    await tester.pumpWidget(host());
    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    slider.onChanged!(const RangeValues(2, 5));
    await tester.pump();
    var chart = tester.widget<EquityChart>(find.byType(EquityChart));
    expect(text(chart.equity.first['date']), '2023-09-01');

    final refreshed = _guruBacktestPayload('5');
    refreshed['equity'] = <Map<String, dynamic>>[
      {'date': '2021-09-01', 'value': 100.0, 'benchmark': 100.0},
      {'date': '2021-12-01', 'value': 103.0, 'benchmark': 101.0},
      {'date': '2022-09-01', 'value': 107.0, 'benchmark': 104.0},
      {'date': '2023-09-01', 'value': 114.0, 'benchmark': 108.0},
      {'date': '2024-09-01', 'value': 121.0, 'benchmark': 113.0},
      {'date': '2025-09-01', 'value': 130.0, 'benchmark': 120.0},
      {'date': '2026-09-01', 'value': 142.0, 'benchmark': 129.0},
    ];
    updateHost(() => payload = refreshed);
    await tester.pump();

    chart = tester.widget<EquityChart>(find.byType(EquityChart));
    expect(text(chart.equity.first['date']), '2023-09-01');
    expect(chart.equity, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an explicit 10Y request outranks the pending 5Y warmup poll', (
    WidgetTester tester,
  ) async {
    final api = _ControlledGuruApiClient();
    await _pumpGuruStateMachine(tester, api);

    expect(api.backtestRequests, hasLength(1));
    expect(api.backtestRequests.single.path, contains('years=5'));
    api.backtestRequests[0].completer.complete(
      _guruBacktestPayload('5', warming: true),
    );
    await _flushGuruState(tester);
    expect(find.text('Full 5Y'), findsOneWidget);

    await tester.tap(find.text('10Y'));
    await tester.pump();
    expect(api.backtestRequests, hasLength(2));
    expect(api.backtestRequests[1].path, contains('years=10'));

    // The old 5Y warming timer fires while 10Y is still in flight. It must
    // not start a newer 5Y request that can supersede the user's choice.
    await tester.pump(const Duration(seconds: 6));
    expect(api.backtestRequests, hasLength(2));

    api.backtestRequests[1].completer.complete(
      _guruBacktestPayload('10', endingValue: 180),
    );
    await _flushGuruState(tester);

    expect(find.text('Full 10Y'), findsOneWidget);
    final chart = tester.widget<EquityChart>(find.byType(EquityChart));
    expect(number(chart.equity.last['value']), closeTo(1.8, 0.000001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('quarterly mode makes one full-attribution request per guru', (
    WidgetTester tester,
  ) async {
    final api = _ControlledGuruApiClient();
    await _pumpGuruStateMachine(
      tester,
      api,
      initialModule: 2,
      guru: _guruStateMachineManager(id: 'manager-one'),
    );
    expect(api.backtestRequests, hasLength(1));
    expect(api.backtestRequests[0].path, contains('/manager-one/backtest?'));
    expect(api.backtestRequests[0].path, contains('detail=full'));
    api.backtestRequests[0].completer.complete(
      _guruBacktestPayload('5', fullAttribution: true),
    );
    await _flushGuruState(tester);

    await _pumpGuruStateMachine(
      tester,
      api,
      initialModule: 2,
      guru: _guruStateMachineManager(id: 'manager-two'),
    );
    expect(api.backtestRequests, hasLength(2));
    expect(api.backtestRequests[1].path, contains('/manager-two/backtest?'));
    expect(api.backtestRequests[1].path, contains('detail=full'));
    api.backtestRequests[1].completer.complete(
      _guruBacktestPayload('5', fullAttribution: true),
    );
    await _flushGuruState(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quarterly mode surfaces a failed full-attribution request', (
    WidgetTester tester,
  ) async {
    final api = _ControlledGuruApiClient();
    await _pumpGuruStateMachine(tester, api);
    api.backtestRequests[0].completer.complete(_guruBacktestPayload('5'));
    await _flushGuruState(tester);

    await tester.tap(find.text('Quarterly Contribution').first);
    await tester.pump();
    expect(api.backtestRequests, hasLength(2));
    expect(api.backtestRequests[1].path, contains('detail=full'));
    api.backtestRequests[1].completer.completeError(
      StateError('full attribution failed'),
    );
    await _flushGuruState(tester);

    expect(find.textContaining('full attribution failed'), findsOneWidget);
    expect(find.text('No quarterly attribution available.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid refresh taps start only one backtest request', (
    WidgetTester tester,
  ) async {
    final api = _ControlledGuruApiClient();
    await _pumpGuruStateMachine(tester, api);
    api.backtestRequests[0].completer.complete(_guruBacktestPayload('5'));
    await _flushGuruState(tester);

    final refresh = find.byTooltip('Refresh');
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    await tester.tap(refresh);
    expect(api.backtestRequests, hasLength(2));
    expect(api.backtestRequests[1].path, contains('refresh=1'));
    api.backtestRequests[1].completer.complete(_guruBacktestPayload('5'));
    await _flushGuruState(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a mismatched ready window keeps the previous audited curve and reports the error',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);

      api.backtestRequests[0].completer.complete(
        _guruBacktestPayload('5', endingValue: 140),
      );
      await _flushGuruState(tester);

      await tester.tap(find.text('All'));
      await tester.pump();
      expect(api.backtestRequests, hasLength(2));
      expect(api.backtestRequests[1].path, contains('years=all'));

      api.backtestRequests[1].completer.complete(
        _guruBacktestPayload('all', methodYears: '5', endingValue: 250),
      );
      await _flushGuruState(tester);

      expect(find.text('Full 5Y'), findsOneWidget);
      expect(find.textContaining('Backtest window mismatch'), findsOneWidget);
      final chart = tester.widget<EquityChart>(find.byType(EquityChart));
      expect(number(chart.equity.last['value']), closeTo(1.4, 0.000001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selecting the loaded window cancels an in-flight longer request',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);

      api.backtestRequests[0].completer.complete(_guruBacktestPayload('5'));
      await _flushGuruState(tester);
      await tester.tap(find.text('10Y'));
      await tester.pump();
      api.backtestRequests[1].completer.complete(
        _guruBacktestPayload('10', endingValue: 180),
      );
      await _flushGuruState(tester);
      expect(find.text('Full 10Y'), findsOneWidget);

      await tester.tap(find.text('All'));
      await tester.pump();
      expect(api.backtestRequests, hasLength(3));
      expect(api.backtestRequests[2].path, contains('years=all'));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // A different unloaded server window is disabled while All is pending;
      // only the already-loaded 10Y button remains available as cancellation.
      await tester.tap(find.text('5Y'));
      await tester.pump();
      expect(api.backtestRequests, hasLength(3));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // 10Y is already loaded, so selecting it is a cancellation intent and
      // must not make a redundant network request.
      await tester.tap(find.text('10Y'));
      await tester.pump();
      expect(api.backtestRequests, hasLength(3));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      api.backtestRequests[2].completer.complete(
        _guruBacktestPayload('all', endingValue: 260),
      );
      await _flushGuruState(tester);

      expect(find.text('Full 10Y'), findsOneWidget);
      final chart = tester.widget<EquityChart>(find.byType(EquityChart));
      expect(number(chart.equity.last['value']), closeTo(1.8, 0.000001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quarterly attribution waits for the selected server window to finish',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);

      api.backtestRequests[0].completer.complete(_guruBacktestPayload('5'));
      await _flushGuruState(tester);
      await tester.tap(find.text('10Y'));
      await tester.pump();
      expect(api.backtestRequests, hasLength(2));

      await tester.tap(find.text('Quarterly Contribution').first);
      await tester.pump();
      expect(
        api.backtestRequests,
        hasLength(2),
        reason: 'tab changes must not supersede the pending 10Y request',
      );

      api.backtestRequests[1].completer.complete(
        _guruBacktestPayload('10', endingValue: 180),
      );
      await _flushGuruState(tester);
      expect(api.backtestRequests, hasLength(3));
      expect(api.backtestRequests[2].path, contains('years=10'));
      expect(api.backtestRequests[2].path, contains('detail=full'));

      api.backtestRequests[2].completer.complete(
        _guruBacktestPayload('10', fullAttribution: true, endingValue: 180),
      );
      await _flushGuruState(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quarterly attribution falls back to the loaded window after a long-window failure',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);

      api.backtestRequests[0].completer.complete(_guruBacktestPayload('5'));
      await _flushGuruState(tester);
      await tester.tap(find.text('10Y'));
      await tester.pump();
      await tester.tap(find.text('Quarterly Contribution').first);
      await tester.pump();
      expect(api.backtestRequests, hasLength(2));

      api.backtestRequests[1].completer.complete(<String, dynamic>{
        'status': 'not_ready',
        'method': <String, dynamic>{
          'years': 10,
          'reason': '10Y history is not pre-warmed.',
        },
      });
      await _flushGuruState(tester);
      expect(api.backtestRequests, hasLength(3));
      expect(api.backtestRequests[2].path, contains('years=5'));
      expect(api.backtestRequests[2].path, contains('detail=full'));

      api.backtestRequests[2].completer.complete(
        _guruBacktestPayload('5', fullAttribution: true),
      );
      await _flushGuruState(tester);
      expect(find.text('TEST'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed long window resumes polling a warming ready curve', (
    WidgetTester tester,
  ) async {
    final api = _ControlledGuruApiClient();
    await _pumpGuruStateMachine(tester, api);

    api.backtestRequests[0].completer.complete(
      _guruBacktestPayload('5', warming: true),
    );
    await _flushGuruState(tester);
    await tester.tap(find.text('All'));
    await tester.pump();
    api.backtestRequests[1].completer.complete(<String, dynamic>{
      'status': 'not_ready',
      'method': <String, dynamic>{
        'years': 'all',
        'reason': 'Full history is not pre-warmed.',
      },
    });
    await _flushGuruState(tester);
    expect(find.text('Full 5Y'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    expect(api.backtestRequests, hasLength(3));
    expect(api.backtestRequests[2].path, contains('years=5'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'position history is lazy-loaded and supports quarter and stock inspection',
    (WidgetTester tester) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(tester, api);
      expect(api.exposureRequests, isEmpty);
      api.backtestRequests.single.completer.complete(_guruBacktestPayload('5'));
      await _flushGuruState(tester);

      await tester.tap(find.text('Position History'));
      await tester.pump();
      expect(api.exposureRequests, hasLength(1));
      expect(
        api.exposureRequests.single.path,
        '/api/gurus/state-machine-manager/exposure?limit=40',
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      api.exposureRequests.single.completer.complete(_guruExposurePayload());
      await _flushGuruState(tester);
      expect(
        find.byKey(const ValueKey('guru-position-history-module')),
        findsOneWidget,
      );
      expect(
        find.text('State Machine Manager Position History'),
        findsOneWidget,
      );
      expect(find.text('3 quarters'), findsOneWidget);
      expect(find.text('NVDA position trajectory'), findsOneWidget);
      expect(find.text('2026 Q2 Top holdings'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('guru-position-history-quarter-2025-12-31')),
      );
      await tester.pump();
      expect(find.text('2025 Q4 Top holdings'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('guru-position-history-holding-MSFT')),
      );
      await tester.pump();
      expect(find.text('MSFT position trajectory'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('position history exposes an error retry with a forced refresh', (
    WidgetTester tester,
  ) async {
    final api = _ControlledGuruApiClient();
    await _pumpGuruStateMachine(tester, api, initialModule: 3);
    expect(api.backtestRequests, hasLength(1));
    expect(api.exposureRequests, hasLength(1));
    api.backtestRequests.single.completer.complete(_guruBacktestPayload('5'));
    api.exposureRequests.single.completer.completeError(
      StateError('exposure unavailable'),
    );
    await _flushGuruState(tester);

    expect(find.textContaining('exposure unavailable'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('guru-position-history-retry')));
    await tester.pump();
    expect(api.exposureRequests, hasLength(2));
    expect(api.exposureRequests.last.path, contains('limit=40&refresh=1'));

    api.exposureRequests.last.completer.complete(_guruExposurePayload());
    await _flushGuruState(tester);
    expect(find.text('NVDA position trajectory'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'latest holdings remain visible when backtest fails and disclose truncation',
    (WidgetTester tester) async {
      final holdings = <Map<String, dynamic>>[
        for (var index = 0; index < 20; index += 1)
          <String, dynamic>{
            'ticker': 'T$index',
            'issuer': 'Test Holding $index',
            'value': (20 - index) * 1000000,
          },
      ];
      final baseGuru = _guruStateMachineManager();
      final guru = <String, dynamic>{
        ...baseGuru,
        'summary': <String, dynamic>{
          ...asMap(baseGuru['summary']),
          'totalPositions': 125,
          'totalValue': 250000000,
        },
        'holdings': holdings,
      };
      await tester.pumpWidget(
        LanguageScope(
          language: AppLanguage.en,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: GuruSimulationModule(
                  payload: <String, dynamic>{
                    'status': 'not_ready',
                    'method': <String, dynamic>{
                      'reason': 'Execution coverage is incomplete.',
                    },
                  },
                  loading: false,
                  error: null,
                  guru: guru,
                  palette: Palette(false),
                  loadedWindow: '5',
                  requestedWindow: null,
                  windowError: null,
                  onWindowRequested: (_) {},
                  onRetry: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Execution coverage is incomplete.'), findsOneWidget);
      expect(find.text('Latest holdings'), findsOneWidget);
      expect(find.text('Top 18 of 125'), findsOneWidget);
      expect(find.text('All'), findsNothing);
      expect(
        find.textContaining('only the top 20 by reported value'),
        findsOneWidget,
      );
      final showTop = find.text('Show top 20');
      await tester.ensureVisible(showTop);
      await tester.tap(showTop);
      await tester.pump();
      expect(find.text('Top 20 of 125'), findsOneWidget);
      expect(find.text('Collapse'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'guru names use chineseName throughout Chinese list and detail UI',
    (WidgetTester tester) async {
      final guru = _guruStateMachineManager();
      expect(guruDisplayName(guru, AppLanguage.zh), '状态机经理');
      expect(guruDisplayName(guru, AppLanguage.en), 'State Machine Manager');
      expect(
        guruDisplayName(<String, dynamic>{'name': 'Fallback'}, AppLanguage.zh),
        'Fallback',
      );

      await tester.pumpWidget(
        LanguageScope(
          language: AppLanguage.zh,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: Column(
                children: [
                  GuruListTile(
                    guru: guru,
                    active: true,
                    palette: Palette(false),
                    onTap: () {},
                  ),
                  GuruWorkspaceHeader(guru: guru, palette: Palette(false)),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('状态机经理'), findsNWidgets(2));
      expect(find.text('State Machine Manager'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('position history is overflow-safe at desktop and mobile sizes', (
    WidgetTester tester,
  ) async {
    Future<void> verifySize(Size size) async {
      final api = _ControlledGuruApiClient();
      await _pumpGuruStateMachine(
        tester,
        api,
        initialModule: 3,
        viewportSize: size,
      );
      api.backtestRequests.single.completer.complete(_guruBacktestPayload('5'));
      api.exposureRequests.single.completer.complete(_guruExposurePayload());
      await _flushGuruState(tester);
      expect(
        find.byKey(const ValueKey('guru-position-history-module')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    await verifySize(const Size(1280, 720));
    await verifySize(const Size(390, 844));
  });

  test('position history route names round-trip', () {
    expect(guruModuleIndex('positions'), 3);
    expect(guruModuleIndex('exposure'), 3);
    expect(guruModuleRouteName(3), 'positions');
  });

  test(
    'quarterly market lens selects widest-covered quarter and breaks ties by recency',
    () {
      Map<String, dynamic> manager(
        String id,
        String reportDate, {
        bool excluded = false,
      }) => <String, dynamic>{
        'id': id,
        'name': id,
        'type': 'manager13f',
        'excludeFromHeatmap': excluded,
        'summary': <String, dynamic>{'reportDate': reportDate},
      };

      final mostCovered = <Map<String, dynamic>>[
        manager('q1-a', '2026-03-31'),
        manager('q1-b', '2026-03-31'),
        manager('q1-c', '2026-03-31'),
        manager('q2-a', '2026-06-30'),
        manager('q2-b', '2026-06-30'),
        manager('excluded-newer', '2026-09-30', excluded: true),
        <String, dynamic>{
          'id': 'insider-newer',
          'name': 'Insider',
          'type': 'insider',
          'summary': <String, dynamic>{'reportDate': '2026-12-31'},
        },
      ];

      expect(defaultGuruDisclosureQuarter(mostCovered), '2026/Q1');
      expect(
        defaultGuruDisclosureQuarter(<Map<String, dynamic>>[
          ...mostCovered.where((guru) => guru['id'] != 'q1-c'),
        ]),
        '2026/Q2',
      );
      final missingQuarter = <Map<String, dynamic>>[
        manager('missing-a', ''),
        manager('missing-b', ''),
      ];
      expect(defaultGuruDisclosureQuarter(missingQuarter), '-');
      expect(guruDisclosureQuarterCoverage(missingQuarter, '-'), 0);
    },
  );

  test(
    'quarterly exposures exclude stale filings, dedupe managers, and rank breadth before weight',
    () {
      Map<String, dynamic> holding(
        String ticker,
        double value,
        double weight,
      ) => <String, dynamic>{
        'ticker': ticker,
        'issuer': '$ticker issuer',
        'value': value,
        'pctCommonLong': weight,
      };

      Map<String, dynamic> manager(
        String id,
        String reportDate,
        List<Map<String, dynamic>> holdings,
      ) => <String, dynamic>{
        'id': id,
        'name': 'Manager $id',
        'type': 'manager13f',
        'summary': <String, dynamic>{
          'reportDate': reportDate,
          'filingDate': '2026-08-14',
        },
        'holdings': holdings,
        'activity': <Map<String, dynamic>>[],
      };

      final rows = buildExposures(<Map<String, dynamic>>[
        manager('A', '2026-06-30', <Map<String, dynamic>>[
          holding('WIDE', 1, .01),
          holding('HEAVY', 20, .20),
          holding('HEAVY', 20, .20),
          holding('MONEY', 1000, .10),
        ]),
        manager('B', '2026-06-30', <Map<String, dynamic>>[
          holding('WIDE', 1, .01),
          holding('HEAVY', 40, .40),
          holding('MONEY', 1000, .10),
        ]),
        manager('C', '2026-06-30', <Map<String, dynamic>>[
          holding('WIDE', 1, .01),
        ]),
        manager('OLD', '2026-03-31', <Map<String, dynamic>>[
          holding('STALE', 1000000, .99),
        ]),
      ], reportQuarter: '2026/Q2');

      expect(rows.map((row) => row.ticker), <String>['WIDE', 'HEAVY', 'MONEY']);
      expect(rows.any((row) => row.ticker == 'STALE'), isFalse);

      final heavy = rows.firstWhere((row) => row.ticker == 'HEAVY');
      expect(heavy.guruCount, 2);
      expect(heavy.positions, hasLength(2));
      expect(heavy.value, 80);
      expect(heavy.medianWeight, closeTo(.4, 1e-12));
      expect(
        heavy.positions
            .firstWhere((position) => position.guruId == 'A')
            .currentValue,
        40,
      );

      final money = rows.firstWhere((row) => row.ticker == 'MONEY');
      expect(heavy.medianWeight, greaterThan(money.medianWeight));
      expect(heavy.value, lessThan(money.value));
    },
  );

  test(
    'quarterly activity excludes stale filings and collapses duplicate manager ticker rows',
    () {
      Map<String, dynamic> activity(
        String ticker,
        String action,
        double value,
        double previousValue,
      ) => <String, dynamic>{
        'ticker': ticker,
        'issuer': '$ticker issuer',
        'action': action,
        'value': value,
        'previousValue': previousValue,
      };

      Map<String, dynamic> manager(
        String id,
        String reportDate,
        List<Map<String, dynamic>> activityRows,
      ) => <String, dynamic>{
        'id': id,
        'name': 'Manager $id',
        'type': 'manager13f',
        'summary': <String, dynamic>{
          'reportDate': reportDate,
          'filingDate': '2026-08-14',
        },
        'holdings': <Map<String, dynamic>>[],
        'activity': activityRows,
      };

      final gurus = <Map<String, dynamic>>[
        manager('A', '2026-06-30', <Map<String, dynamic>>[
          activity('AAA', 'new', 10, 0),
          activity('AAA', 'increased', 20, 5),
          activity('TRIM', 'reduced', 10, 20),
          activity('TRIM', 'reduced', 8, 12),
          activity('MONEY', 'new', 1000, 0),
        ]),
        manager('B', '2026-06-30', <Map<String, dynamic>>[
          activity('AAA', 'increased', 30, 10),
          activity('TRIM', 'sold_out', 0, 30),
        ]),
        manager('OLD', '2026-03-31', <Map<String, dynamic>>[
          activity('STALEA', 'new', 1000000, 0),
          activity('STALET', 'sold_out', 0, 1000000),
        ]),
      ];

      final adds = buildActivityRankItems(
        gurus,
        positive: true,
        reportQuarter: '2026/Q2',
      );
      expect(adds.map((row) => row.ticker), <String>['AAA', 'MONEY']);
      expect(adds.any((row) => row.ticker == 'STALEA'), isFalse);

      final aaa = adds.firstWhere((row) => row.ticker == 'AAA');
      expect(aaa.guruCount, 2);
      expect(aaa.positions, hasLength(2));
      expect(aaa.amount, 45);
      expect(aaa.newCount, 1);
      expect(aaa.increasedCount, 1);

      final trims = buildActivityRankItems(
        gurus,
        positive: false,
        reportQuarter: '2026/Q2',
      );
      expect(trims.map((row) => row.ticker), <String>['TRIM']);
      expect(trims.single.guruCount, 2);
      expect(trims.single.positions, hasLength(2));
      expect(trims.single.amount, 44);
      expect(trims.single.reducedCount, 1);
      expect(trims.single.soldOutCount, 1);
    },
  );

  test(
    'quarterly activity never substitutes full positions for inverse value moves',
    () {
      Map<String, dynamic> activity(
        String ticker,
        String action,
        double value,
        double previousValue,
      ) => <String, dynamic>{
        'ticker': ticker,
        'issuer': '$ticker issuer',
        'action': action,
        'value': value,
        'previousValue': previousValue,
      };

      final guru = <String, dynamic>{
        'id': 'A',
        'name': 'Manager A',
        'type': 'manager13f',
        'summary': <String, dynamic>{
          'reportDate': '2026-06-30',
          'filingDate': '2026-08-14',
        },
        'holdings': <Map<String, dynamic>>[],
        'activity': <Map<String, dynamic>>[
          activity('BADADD', 'increased', 80, 100),
          activity('BADTRIM', 'reduced', 120, 100),
        ],
      };

      final adds = buildActivityRankItems(
        [guru],
        positive: true,
        reportQuarter: '2026/Q2',
      );
      final trims = buildActivityRankItems(
        [guru],
        positive: false,
        reportQuarter: '2026/Q2',
      );

      expect(adds.single.ticker, 'BADADD');
      expect(adds.single.amount, 0);
      expect(adds.single.amountReliable, isFalse);
      expect(trims.single.ticker, 'BADTRIM');
      expect(trims.single.amount, 0);
      expect(trims.single.amountReliable, isFalse);
      expect(
        activityRankAmount(
          activity('BADADD', 'increased', 80, 100),
          positive: true,
        ),
        isNull,
      );
      expect(
        activityRankAmount(
          activity('BADTRIM', 'reduced', 120, 100),
          positive: false,
        ),
        isNull,
      );
      expect(
        activityRankSubtitle(adds.single, AppLanguage.en),
        contains('reported 2026/Q2'),
      );
      expect(
        activityRankSubtitle(adds.single, AppLanguage.en),
        isNot(contains('latest')),
      );
    },
  );

  testWidgets('quarterly deck controls meet the compact touch target', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gurus = _marketLensTestGurus();
    final crowdedExposures = List<ExposureItem>.generate(
      16,
      (index) => ExposureItem(
        ticker: 'T$index',
        value: 1000 - index.toDouble(),
        guruNames: const {'Manager A', 'Manager B'},
        positions: const [],
      ),
    );
    await tester.pumpWidget(
      LanguageScope(
        language: AppLanguage.en,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: GuruRightRail(
                  gurus: gurus,
                  signals: const [],
                  exposures: crowdedExposures,
                  activeGuruId: 'manager-a',
                  palette: Palette(false),
                  onSelectGuru: (_) {},
                  onOpenGuruTrade: (_, _) {},
                  onOpenValuation: (_) {},
                  deckHeight: 860,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final expand = find.byKey(const ValueKey('quarterly-market-lens-expand'));
    expect(expand, findsOneWidget);
    expect(tester.getSize(expand), const Size(44, 44));
    expect(find.text('T15'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('T15'),
      240,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('crowded-holdings-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('T15'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final language in AppLanguage.values) {
    for (final view in [0, 1, 2]) {
      testWidgets(
        'quarterly market lens synchronizes manager avatars in view $view (${language.name})',
        (tester) async {
          tester.view.physicalSize = language == AppLanguage.en
              ? const Size(1280, 720)
              : const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final gurus = _marketLensTestGurus();
          gurus.first['avatarUrl'] =
              '/guru-avatars/manager-a.png?source=catalog';
          if (view == 2) {
            for (final guru in gurus) {
              (guru['activity'] as List).first['action'] = 'reduced';
            }
          }
          await tester.pumpWidget(
            LanguageScope(
              language: language,
              child: MaterialApp(
                home: Scaffold(
                  body: QuarterlyMarketLensDialog(
                    gurus: gurus,
                    palette: Palette(false),
                    initialView: view,
                    initialTicker: 'AAA',
                    onOpenGuruTrade: (_, _) {},
                    onOpenValuation: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final guru in gurus) {
            final avatarFinder = find.byKey(
              ValueKey('market-lens-avatar-${guru['id']}'),
            );
            await tester.scrollUntilVisible(
              avatarFinder,
              160,
              scrollable: find.descendant(
                of: find.byKey(
                  const ValueKey('quarterly-market-lens-detail-scroll'),
                ),
                matching: find.byType(Scrollable),
              ),
            );
            final avatar = tester.widget<GuruAvatar>(avatarFinder);
            expect(avatar.guru['id'], guru['id']);
            expect(avatar.guru['name'], guruDisplayName(guru, language));
            expect(avatar.size, 34);
            final expectedUrl =
                guru['avatarUrl'] ?? '/guru-avatars/${guru['id']}.png';
            expect(avatar.guru['avatarUrl'], expectedUrl);
            final image = tester.widget<Image>(
              find.descendant(of: avatarFinder, matching: find.byType(Image)),
            );
            expect(
              (image.image as NetworkImage).url,
              versionedGuruAvatarUrl(expectedUrl),
            );
            expect(
              find.descendant(
                of: avatarFinder,
                matching: find.byIcon(Icons.account_balance_outlined),
              ),
              findsNothing,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'quarterly market lens opens manager evidence and valuation action on desktop',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String openedTicker = '';
      await tester.pumpWidget(
        LanguageScope(
          language: AppLanguage.en,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showQuarterlyMarketLens(
                      context: context,
                      gurus: _marketLensTestGurus(),
                      palette: Palette(false),
                      initialView: 0,
                      initialTicker: 'AAA',
                      onOpenGuruTrade: (_, _) {},
                      onOpenValuation: (ticker) => openedTicker = ticker,
                    ),
                    child: const Text('Open lens'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open lens'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('quarterly-market-lens-dialog')),
        findsOneWidget,
      );
      expect(
        find.text('From ranking to manager-level evidence'),
        findsOneWidget,
      );
      expect(find.text('2/2'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Manager-level evidence'),
        180,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('quarterly-market-lens-detail-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Manager-level evidence'), findsOneWidget);
      expect(find.textContaining('not confirmed trades'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const ValueKey('quarterly-market-lens-valuation')),
      );
      await tester.pumpAndSettle();
      expect(openedTicker, 'AAA');
    },
  );

  test('market lens preserves private holdings but blocks public actions', () {
    final exposures = buildExposures(
      _privateMarketLensTestGurus(),
      reportQuarter: '2026/Q2',
    );
    final adds = buildActivityRankItems(
      _privateMarketLensTestGurus(),
      positive: true,
      reportQuarter: '2026/Q2',
    );

    expect(exposures.single.ticker, 'JHG');
    expect(exposures.single.hasNonPublicPosition, isTrue);
    expect(exposures.single.positions.single.publicReplicable, isFalse);
    expect(
      exposures.single.positions.single.publicTradingStatus,
      'private_after_reported_quarter',
    );
    expect(adds.single.positions.single.isPubliclyTradable, isFalse);
    expect(
      adds.single.positions.single.publicTradingReason(AppLanguage.en),
      contains('Public trading ended'),
    );
  });

  testWidgets(
    'private reported security stays visible with valuation and trade disabled',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String openedGuru = '';
      String openedTicker = '';

      await tester.pumpWidget(
        LanguageScope(
          language: AppLanguage.en,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showQuarterlyMarketLens(
                      context: context,
                      gurus: _privateMarketLensTestGurus(),
                      palette: Palette(false),
                      initialView: 0,
                      initialTicker: 'JHG',
                      onOpenGuruTrade: (guru, ticker) {
                        openedGuru = guru;
                        openedTicker = ticker;
                      },
                      onOpenValuation: (ticker) => openedTicker = ticker,
                    ),
                    child: const Text('Open lens'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open lens'));
      await tester.pumpAndSettle();
      expect(find.text('Private · no public valuation'), findsOneWidget);
      expect(find.text('Private'), findsOneWidget);
      expect(find.textContaining('Public trading ended'), findsWidgets);

      final valuationButton = tester.widget<FilledButton>(
        find.byKey(const ValueKey('quarterly-market-lens-valuation')),
      );
      expect(valuationButton.onPressed, isNull);
      await tester.tap(
        find.byKey(
          const ValueKey('quarterly-market-lens-manager-nelson-peltz-JHG'),
        ),
      );
      await tester.pumpAndSettle();
      expect(openedGuru, isEmpty);
      expect(openedTicker, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unchanged crowded holding stays evidence-only instead of opening a wrong trade',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String openedGuru = '';
      String openedTicker = '';

      await tester.pumpWidget(
        LanguageScope(
          language: AppLanguage.en,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showQuarterlyMarketLens(
                      context: context,
                      gurus: _marketLensTestGurus(),
                      palette: Palette(false),
                      initialView: 0,
                      initialTicker: 'BBB',
                      onOpenGuruTrade: (guru, ticker) {
                        openedGuru = guru;
                        openedTicker = ticker;
                      },
                      onOpenValuation: (_) {},
                    ),
                    child: const Text('Open lens'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open lens'));
      await tester.pumpAndSettle();
      final managerRow = find.byKey(
        const ValueKey('quarterly-market-lens-manager-manager-a-BBB'),
      );
      await tester.scrollUntilVisible(
        managerRow,
        180,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('quarterly-market-lens-detail-scroll')),
          matching: find.byType(Scrollable),
        ),
      );

      expect(find.text('Reported holding'), findsOneWidget);
      await tester.tap(managerRow);
      await tester.pumpAndSettle();
      expect(openedGuru, isEmpty);
      expect(openedTicker, isEmpty);
      expect(
        find.byKey(const ValueKey('quarterly-market-lens-dialog')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('quarterly market lens uses a list-to-detail flow on mobile', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String openedGuru = '';
    String openedTradeTicker = '';

    await tester.pumpWidget(
      LanguageScope(
        language: AppLanguage.en,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showQuarterlyMarketLens(
                    context: context,
                    gurus: _marketLensTestGurus(),
                    palette: Palette(false),
                    initialView: 1,
                    initialTicker: '',
                    onOpenGuruTrade: (guru, ticker) {
                      openedGuru = guru;
                      openedTradeTicker = ticker;
                    },
                    onOpenValuation: (_) {},
                  ),
                  child: const Text('Open lens'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open lens'));
    await tester.pumpAndSettle();
    expect(find.text('Full reported-add ranking'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quarterly-market-lens-back')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('quarterly-market-lens-row-AAA')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quarterly-market-lens-back')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Manager-level evidence'),
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('quarterly-market-lens-detail-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('Manager-level evidence'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('quarterly-market-lens-back')));
    await tester.pumpAndSettle();
    expect(find.text('Full reported-add ranking'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('quarterly-market-lens-row-AAA')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Manager A'),
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('quarterly-market-lens-detail-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('Manager A'));
    await tester.pumpAndSettle();
    expect(openedGuru, 'manager-a');
    expect(openedTradeTicker, 'AAA');
  });

  test('uses summary valuation data before full research is opened', () {
    expect(
      valuationTickerDetailPath('isrg'),
      '/api/valuation/ISRG?pricePoints=300&detail=summary',
    );
    expect(
      valuationTickerDetailPath('lseg.l', fullResearch: true),
      '/api/valuation/LSEG.L?pricePoints=900&detail=full',
    );
  });

  test('valuation chart removes the long price-only lead-in', () {
    final visible = valuationChartWindow(
      [
        {'asOfDate': '2015-01-15', 'fairValue': null, 'currentPrice': 5},
        {'asOfDate': '2020-01-15', 'fairValue': 24, 'currentPrice': 20},
        {'asOfDate': '2020-04-15', 'fairValue': 27, 'currentPrice': 23},
      ],
      [
        {'date': '2010-01-04', 'close': 2},
        {'date': '2019-12-01', 'close': 18},
        {'date': '2019-12-20', 'close': 19},
        {'date': '2020-01-15', 'close': 20},
        {'date': '2020-04-15', 'close': 23},
      ],
    );

    expect(visible.pricePoints.map((row) => row['date']), [
      '2020-01-15',
      '2020-04-15',
    ]);
    expect(visible.valuationPoints.map((row) => row['asOfDate']), [
      '2020-01-15',
      '2020-04-15',
    ]);
  });

  test('valuation chart preserves price history when no model exists', () {
    final visible = valuationChartWindow(
      const [
        {'asOfDate': '2020-01-15', 'fairValue': null, 'currentPrice': 20},
      ],
      [
        {'date': '2010-01-04', 'close': 2},
        {'date': '2020-01-15', 'close': 20},
      ],
    );

    expect(visible.pricePoints.length, 2);
    expect(visible.pricePoints.first['date'], '2010-01-04');
    expect(visible.valuationPoints.length, 1);
  });

  test('valuation chart preserves price history for one model estimate', () {
    final visible = valuationChartWindow(
      const [
        {'asOfDate': '2020-01-15', 'fairValue': 24, 'currentPrice': 20},
      ],
      const [
        {'date': '2010-01-04', 'close': 2},
        {'date': '2020-01-15', 'close': 20},
      ],
    );

    expect(visible.pricePoints.length, 2);
    expect(visible.pricePoints.first['date'], '2010-01-04');
  });

  test('valuation chart does not empty a non-overlapping price series', () {
    final visible = valuationChartWindow(
      const [
        {'asOfDate': '2020-01-15', 'fairValue': 24},
        {'asOfDate': '2020-04-15', 'fairValue': 27},
      ],
      const [
        {'date': '2010-01-04', 'close': 2},
        {'date': '2010-02-04', 'close': 3},
      ],
    );

    expect(visible.pricePoints.length, 2);
    expect(visible.pricePoints.last['date'], '2010-02-04');
  });

  test('valuation chart ignores invalid prices and deduplicates dates', () {
    final visible = valuationChartWindow(
      const [
        {'asOfDate': '2020-01-15', 'fairValue': 24},
        {'asOfDate': '2020-04-15', 'fairValue': 27},
      ],
      const [
        {'date': 'not-a-date', 'close': 100},
        {'date': '2020-01-15', 'close': 0},
        {'date': '2020-01-15', 'close': 20},
        {'date': '2020-01-15', 'close': 21},
        {'date': '2020-04-15', 'close': 23},
      ],
    );

    expect(visible.pricePoints.length, 2);
    expect(visible.pricePoints.first['close'], 21);
  });

  test('defaults first visits to English and respects explicit Chinese', () {
    for (final input in <String?>[null, '', 'en', 'en-US', 'fr']) {
      expect(parseAppLanguage(input), AppLanguage.en);
    }
    for (final input in ['zh', 'zh-CN', ' ZH ']) {
      expect(parseAppLanguage(input), AppLanguage.zh);
    }
    expect(appLanguageCode(AppLanguage.en), 'en');
    expect(appLanguageCode(AppLanguage.zh), 'zh');
  });

  test(
    'retired login returns retain language without forwarding other state',
    () {
      expect(
        retiredModuleReturnPath('/ontology/', fallbackLanguage: AppLanguage.zh),
        '/?view=discover&lang=zh',
      );
      expect(
        retiredModuleReturnPath(
          '/ontology/?view=market&lang=en&returnTo=%2F%3Fvaluation%3DISRG#latest',
          fallbackLanguage: AppLanguage.zh,
        ),
        '/?view=discover&lang=en',
      );
      expect(
        retiredModuleReturnPath('/dbmf/history?lang=zh-CN'),
        '/?view=discover&lang=zh',
      );
      expect(
        retiredModuleReturnPath('/?view=ontology&lang=zh'),
        '/?view=discover&lang=zh',
      );
      expect(
        retiredModuleReturnPath('/?mode=dbmf&lang=en'),
        '/?view=discover&lang=en',
      );
    },
  );

  test('localizes shared and dynamic UI labels', () {
    expect(localizeUiText(AppLanguage.zh, 'Dividend calendar'), '股息日历');
    expect(localizeUiText(AppLanguage.en, '股息日历'), 'Dividend calendar');
    expect(localizeUiText(AppLanguage.zh, '18 events'), '18 个事件');
    expect(localizeUiText(AppLanguage.zh, '\$12.3K model P/L'), '\$12.3K 模型盈亏');
    expect(localizeUiText(AppLanguage.zh, 'FV coverage 92.0%'), '估值覆盖率 92.0%');
    expect(
      localizeUiText(
        AppLanguage.zh,
        'API request timed out after 95s. Please retry.',
      ),
      'API 请求在 95 秒后超时，请重试。',
    );
    expect(localizeUiText(AppLanguage.zh, 'API 503'), 'API 请求失败（状态码 503）');
    expect(localizeUiText(AppLanguage.zh, 'not_configured'), '未配置');
    expect(localizeUiText(AppLanguage.en, 'not_configured'), 'Not configured');
    expect(localizeUiText(AppLanguage.zh, 'Communication Services'), '通信服务');
    expect(localizeUiText(AppLanguage.en, '通信服务'), 'Communication Services');
    expect(localizeUiText(AppLanguage.zh, '1 accounts'), '1 个账户');
    expect(localizeUiText(AppLanguage.en, '1 accounts'), '1 account');
    expect(
      localizeUiText(
        AppLanguage.zh,
        'At least one filing falls below the minimum adjusted-close execution coverage; the backtest fails closed instead of renormalizing the covered subset.',
      ),
      '至少一个申报季度的复权收盘价执行覆盖率低于最低要求；为避免对有价格的持仓重新归一化并夸大结果，回测已按严格规则停止。',
    );
    expect(
      localizeUiText(
        AppLanguage.zh,
        'Multiple disclosure events resolve to the same execution date; the backtest fails closed instead of applying ambiguous same-close rebalance order.',
      ),
      '多个披露事件落在同一执行日；因无法确定同一收盘价下的调仓顺序，回测已按严格规则停止。',
    );
    expect(
      localizeUiText(
        AppLanguage.zh,
        'The requested extended-history backtest is not pre-warmed under the current audit method. The request failed closed without starting a cold synchronous computation.',
      ),
      '所选扩展历史尚未按当前审计方法预热。系统已严格停止请求，且没有启动同步冷计算。',
    );
    expect(
      localizeUiText(
        AppLanguage.zh,
        'Jansen Sharadar as-reported PIT financials + event-visible management guidance',
      ),
      'Jansen Sharadar 原始披露口径的 PIT 财务数据 + 当时可见的管理层指引',
    );
    expect(
      dividendWindowTitle(DateTime(2026, 8), AppLanguage.zh),
      '2026 年 8 月',
    );
    expect(dividendWindowTitle(DateTime(2026, 8), AppLanguage.en), 'Aug 2026');
  });

  test('builds explicit audited backtest window paths', () {
    expect(
      guruBacktestPath('bill-ackman'),
      '/api/gurus/bill-ackman/backtest?years=5',
    );
    expect(
      guruBacktestPath('bill-ackman', years: '10'),
      '/api/gurus/bill-ackman/backtest?years=10',
    );
    expect(
      guruBacktestPath('bill-ackman', years: 'ALL'),
      '/api/gurus/bill-ackman/backtest?years=all',
    );
    expect(
      guruBacktestPath('bill-ackman', fullAttribution: true),
      '/api/gurus/bill-ackman/backtest?years=5&detail=full',
    );
    expect(
      guruBacktestPath('bill-ackman', fullAttribution: true, refresh: true),
      '/api/gurus/bill-ackman/backtest?years=5&detail=full&refresh=1',
    );
    expect(
      () => guruBacktestPath('bill-ackman', years: '7'),
      throwsArgumentError,
    );
  });

  testWidgets(
    'renders first-visit auth shell in English with public case access',
    (WidgetTester tester) async {
      await tester.pumpWidget(const GuruTerminalApp());

      await tester.pump();

      expect(find.text('Research Terminal'), findsOneWidget);
      expect(find.text('GURU INTELLIGENCE'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Chinese'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Explore the ISRG case — no sign-in'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('explore-public-isrg-case')),
            )
            .onPressed,
        isNotNull,
      );
      expect(find.text('研究终端'), findsNothing);
    },
  );

  testWidgets('switches the auth shell completely to English', (
    WidgetTester tester,
  ) async {
    var language = AppLanguage.zh;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          home: LanguageScope(
            language: language,
            child: LoginScreen(
              authConfigured: true,
              localBypassEnabled: true,
              language: language,
              onLanguage: (value) => setState(() => language = value),
              onGoogle: () {},
              onLocal: () {},
              onRetry: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('查看 ISRG 英文案例 · 免登录'), findsOneWidget);
    await tester.tap(find.text('EN'));
    await tester.pump();

    expect(find.text('Research Terminal'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Enter Local Workspace'), findsOneWidget);
    expect(find.text('Chinese'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Explore the ISRG case — no sign-in'), findsOneWidget);
    expect(find.text('研究终端'), findsNothing);
  });

  testWidgets('auth shell fits a 390px mobile viewport without overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: LoginScreen(
            authConfigured: true,
            localBypassEnabled: false,
            language: AppLanguage.en,
            onLanguage: (_) {},
            onGoogle: () {},
            onLocal: () {},
            onRetry: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final background = tester.getRect(
      find.byKey(const ValueKey('login-background')),
    );
    final panel = tester.getRect(find.byKey(const ValueKey('login-panel')));
    expect(background, const Rect.fromLTWH(0, 0, 390, 844));
    final decoration =
        tester
                .widget<Container>(
                  find.byKey(const ValueKey('login-background')),
                )
                .decoration
            as BoxDecoration;
    expect(decoration.color, Colors.black);
    expect(decoration.gradient, isNull);
    expect(find.image(const AssetImage(thesisForgeMarkAsset)), findsOneWidget);
    expect(panel.left, greaterThanOrEqualTo(16));
    expect(panel.right, lessThanOrEqualTo(374));
    expect(panel.center.dy, closeTo(422, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('auth shell fills and centers a desktop viewport', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: LoginScreen(
            authConfigured: true,
            localBypassEnabled: false,
            language: AppLanguage.en,
            onLanguage: (_) {},
            onGoogle: () {},
            onLocal: () {},
            onRetry: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final background = tester.getRect(
      find.byKey(const ValueKey('login-background')),
    );
    final panel = tester.getRect(find.byKey(const ValueKey('login-panel')));
    expect(background, const Rect.fromLTWH(0, 0, 1280, 900));
    expect(panel.center.dx, closeTo(640, 1));
    expect(panel.center.dy, closeTo(450, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('auth shell keeps error actions scrollable on a short viewport', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: LoginScreen(
            authConfigured: false,
            localBypassEnabled: true,
            authMessage: 'Supabase auth did not initialize.',
            language: AppLanguage.en,
            onLanguage: (_) {},
            onGoogle: () {},
            onLocal: () {},
            onRetry: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Retry auth initialization').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('auth initialization error offers an in-page retry', (
    WidgetTester tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: LoginScreen(
            authConfigured: false,
            localBypassEnabled: false,
            authMessage: 'Supabase auth did not initialize.',
            language: AppLanguage.en,
            onLanguage: (_) {},
            onGoogle: () {},
            onLocal: () {},
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('Retry auth initialization'), findsOneWidget);
    await tester.tap(find.text('Retry auth initialization'));
    expect(retried, isTrue);
  });

  testWidgets(
    'representative data widgets contain no Chinese in English mode',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final palette = Palette(false);
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    DividendEmptyMonthNotice(
                      monthStart: DateTime(2026, 8),
                      nextMonth: DateTime(2026, 9),
                      palette: palette,
                      onJumpToNext: () {},
                    ),
                    ValuationWatchlistHeader(palette: palette),
                    PortfolioAnalyticsMetricCard(
                      label: 'Past 1Y Volatility',
                      value: '18.0%',
                      sub: 'current-weight backsolve',
                      icon: Icons.show_chart,
                      palette: palette,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final visibleText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .join('\n');
      expect(RegExp(r'[\u3400-\u9fff]').hasMatch(visibleText), isFalse);
      expect(find.text('Aug 2026 has no dividend events.'), findsOneWidget);
      expect(find.text('COMPANY'), findsOneWidget);
      expect(find.text('current-weight backsolve'), findsOneWidget);
    },
  );

  testWidgets('sample portfolio is unmistakably marked as non-account data', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: Scaffold(
            body: SingleChildScrollView(
              child: PortfolioDashboard(
                data: {
                  'source': {
                    'mode': 'sample',
                    'label': 'Portfolio module sample',
                  },
                  'summary': {
                    'totalValue': 100000,
                    'accounts': 1,
                    'holdings': 0,
                    'cash': 100000,
                    'dayPnl': 0,
                    'dayPnlPct': 0,
                    'unrealizedPnl': 0,
                    'unrealizedPnlPct': 0,
                    'topWeight': 0,
                    'currency': 'USD',
                  },
                  'connection': {
                    'configured': false,
                    'registered': false,
                    'status': 'not_configured',
                  },
                  'accounts': [
                    {'status': 'sample'},
                  ],
                  'holdings': <Map<String, dynamic>>[],
                  'sectors': <Map<String, dynamic>>[],
                  'performance': <Map<String, dynamic>>[],
                  'performanceStatus': {
                    'real': false,
                    'message': 'Sample data has no real NAV history.',
                  },
                  'dividends': <Map<String, dynamic>>[],
                  'dividendStatus': <String, dynamic>{},
                  'analytics': <String, dynamic>{},
                },
                api: _FakeAdminApiClient(),
                palette: Palette(false),
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Sample portfolio — not an account'), findsOneWidget);
    expect(
      find.textContaining('SAMPLE DATA · NOT A REAL ACCOUNT'),
      findsWidgets,
    );
    expect(find.text('Net liquidation'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnect all requires explicit confirmation', (
    WidgetTester tester,
  ) async {
    final api = _FakeAdminApiClient();
    var refreshCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: Scaffold(
            body: PortfolioConnectionStatusPanel(
              connection: const {
                'status': 'linked',
                'configured': true,
                'accounts': <Map<String, dynamic>>[],
              },
              api: api,
              palette: Palette(false),
              onRefresh: () async {
                refreshCalls += 1;
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Disconnect all'));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect all portfolio connections?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Disconnect safely'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.deleteCalls, 0);
    expect(refreshCalls, 0);

    await tester.tap(find.text('Disconnect all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect safely'));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, 1);
    expect(refreshCalls, 1);
    expect(
      find.textContaining('Disconnected. Restore eligibility expires'),
      findsOneWidget,
    );
  });

  testWidgets('disconnected portfolio offers time-bounded undo', (
    WidgetTester tester,
  ) async {
    final api = _FakeAdminApiClient();
    var refreshCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: Scaffold(
            body: SingleChildScrollView(
              child: PortfolioConnectionPanel(
                connection: const {
                  'status': 'disconnected_recoverable',
                  'configured': false,
                  'recoverable': true,
                  'undoUntil': '2099-01-01T00:15:00Z',
                },
                api: api,
                palette: Palette(false),
                onConnected: () async {
                  refreshCalls += 1;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Undo disconnect'), findsOneWidget);
    expect(find.textContaining('encrypted credentials'), findsOneWidget);

    await tester.ensureVisible(find.text('Undo disconnect'));
    await tester.tap(find.text('Undo disconnect'));
    await tester.pumpAndSettle();

    expect(api.restoreCalls, 1);
    expect(refreshCalls, 1);
    expect(
      find.text('Connection restored from encrypted recovery.'),
      findsOneWidget,
    );
  });

  testWidgets('admin portfolio surfaces contain no Chinese in English mode', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final palette = Palette(false);
    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: Scaffold(
            body: SingleChildScrollView(
              child: AdminPortfolioDashboard(
                data: {
                  'summary': {
                    'users': 1,
                    'linked': 0,
                    'accounts': 0,
                    'latestNav': 0,
                    'errors': 0,
                  },
                  'users': [
                    {
                      'userHash': 'abc123',
                      'email': 'test@example.com',
                      'name': 'Test User',
                      'connection': {
                        'status': 'not_configured',
                        'accountCount': 0,
                      },
                      'nav': {'latestValue': 0},
                    },
                  ],
                },
                api: _FakeAdminApiClient(),
                palette: palette,
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .join('\n');
    expect(RegExp(r'[\u3400-\u9fff]').hasMatch(visibleText), isFalse);
    expect(find.text('Portfolio admin console'), findsOneWidget);
    expect(find.text('System Health'), findsOneWidget);
    expect(find.text('Users & last sign-in'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile header keeps an always-visible language switch', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var language = AppLanguage.en;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          home: LanguageScope(
            language: language,
            child: Scaffold(
              body: TerminalHeader(
                mode: 'valuation',
                userName: 'Test User',
                moduleState: const ModuleHeaderState(
                  status: 'cached',
                  source: 'Local SQLite database',
                  asOf: '2026-08-30T10:00:00Z',
                ),
                colorBlind: false,
                language: language,
                showAdmin: true,
                onMode: (_) {},
                onRefresh: () {},
                onColorBlind: (_) {},
                onLanguage: (value) => setState(() => language = value),
                onLogout: () {},
                palette: Palette(false),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ZH'), findsOneWidget);
    await tester.tap(find.text('ZH'));
    await tester.pumpAndSettle();
    expect(language, AppLanguage.zh);
    expect(find.text('EN'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('terminal header is overflow-safe at 390, 768, and 1024px', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final width in <double>[390, 768, 1024]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: Scaffold(
              body: TerminalHeader(
                mode: 'valuation',
                userName: 'Test User',
                moduleState: const ModuleHeaderState(
                  status: 'stale',
                  source: 'Local SQLite valuation database',
                  asOf: '2026-08-27T10:00:00Z',
                ),
                colorBlind: false,
                language: AppLanguage.en,
                showAdmin: true,
                onMode: (_) {},
                onRefresh: () {},
                onColorBlind: (_) {},
                onLanguage: (_) {},
                onLogout: () {},
                palette: Palette(false),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $width');
      expect(tester.getSize(find.byTooltip('Refresh')).height, 44);
      expect(find.text('ZH'), findsOneWidget);
    }
  });
}
