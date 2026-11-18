import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class _Milestone3DiscoverApi extends ApiClient {
  _Milestone3DiscoverApi() : super(() => 'test-token');

  final followsPosted = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/api/investment/home')) {
      return {'watches': [], 'decisions': [], 'attention': [], 'follows': []};
    }
    if (path.startsWith('/api/investment/gurus/warren-buffett')) {
      return {
        'guru': {
          'id': 'warren-buffett',
          'name': 'Warren Buffett',
          'entity': 'Berkshire Hathaway',
          'followed': false,
        },
        'styleProfile': {
          'concentrationTier': 'concentrated',
          'turnoverTier': 'low_turnover',
          'avgQuarterlyTurnover': 0.04,
          'latestTop5Weight': 0.72,
        },
        'latest': {
          'accessionNumber': '0000950123-26-008001',
          'reportDate': '2026-06-30',
          'filingDate': '2026-08-14',
          'status': 'ready',
          'reportedValueUsd': 280000000000,
          'holdingsCount': 29,
          'top5Weight': 0.72,
          'topHoldings': [
            {
              'ticker': 'AAPL',
              'issuer': 'Apple Inc.',
              'weight': 0.28,
              'valueUsd': 78400000000,
              'shares': 300000000,
              'action': 'unchanged',
            },
          ],
          'operations': {'adds': [], 'trims': []},
          'sectorMix': [],
        },
        'history': [
          {
            'accessionNumber': '0000950123-26-008001',
            'reportDate': '2026-06-30',
            'filingDate': '2026-08-14',
            'status': 'ready',
            'reportedValueUsd': 280000000000,
            'holdingsCount': 29,
            'topHoldings': [
              {
                'ticker': 'AAPL',
                'issuer': 'Apple Inc.',
                'weight': 0.28,
                'valueUsd': 78400000000,
                'shares': 300000000,
                'action': 'unchanged',
              },
            ],
          },
        ],
        'backtest': {
          'status': 'ready',
          'defaultWindow': '5Y',
          'windows': {
            '5Y': {
              'startDate': '2021-11-16',
              'endDate': '2026-09-18',
              'summary': {
                'totalReturn': 0.66,
                'benchmarkReturn': 0.73,
                'cagr': 0.11,
                'benchmarkCagr': 0.12,
                'excessCagr': -0.01,
                'sharpe': 0.67,
                'maxDrawdown': -0.23,
              },
              'attribution': {
                'quarterlyWinRate': 0.55,
                'topCreators': [],
                'topDetractors': [],
                'quarters': [],
              },
              'curve': [
                {'date': '2021-11-16', 'guru': 0.0, 'spy': 0.0},
                {'date': '2026-09-18', 'guru': 0.66, 'spy': 0.73},
              ],
            },
          },
        },
      };
    }
    if (path.startsWith('/api/investment/guru-holdings')) {
      return {
        'asOf': '2026-11-18',
        'quarters': [
          {
            'quarter': '2026 Q2',
            'reportDate': '2026-06-30',
            'filedCount': 30,
            'totalGurus': 30,
          },
        ],
        'selectedQuarter': '2026-06-30',
        'gurus': [
          {
            'id': 'warren-buffett',
            'name': 'Warren Buffett',
            'structure': 'permanent',
            'filedInQuarter': true,
          },
        ],
        'rows': [
          {
            'ticker': 'AAPL',
            'name': 'Apple Inc.',
            'holdersCount': 1,
            'sumWeight': 0.28,
            'maxWeight': 0.28,
            'netAdds': 0,
            'netTrims': 0,
            'gurus': {
              'warren-buffett': {
                'weight': 0.28,
                'shares': 300000000,
                'action': 'unchanged',
              },
            },
          },
        ],
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == '/api/investment/follows') {
      followsPosted.add(body);
      return {'ok': true};
    }
    return {};
  }
}

void main() {
  testWidgets(
    'GuruResearchDossier opened from Guru tab exposes working Follow toggle and Backtest/Holdings section jump anchors',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _Milestone3DiscoverApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'discover',
              initialTicker: '',
              initialAsOf: '2026-11-18',
              initialQuery: const {
                'view': 'discover',
                'discoverTab': 'managers',
                'guru': 'warren-buffett',
              },
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Dead "Open full backtest terminal" button is gone; active anchors & Follow are present
      expect(find.text('Open full backtest terminal'), findsNothing);
      expect(find.byKey(const ValueKey('dossier-jump-backtest')), findsOneWidget);
      expect(find.byKey(const ValueKey('dossier-jump-holdings')), findsOneWidget);
      expect(find.byKey(const ValueKey('dossier-follow-button')), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);

      // Jump to holdings scrolls smoothly without errors
      await tester.tap(find.byKey(const ValueKey('dossier-jump-holdings')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Follow button posts to /api/investment/follows and updates label to Following
      await tester.ensureVisible(
        find.byKey(const ValueKey('dossier-follow-button')),
      );
      await tester.tap(find.byKey(const ValueKey('dossier-follow-button')));
      await tester.pumpAndSettle();

      expect(api.followsPosted.length, 1);
      expect(api.followsPosted.first['guruId'], 'warren-buffett');
      expect(api.followsPosted.first['followed'], true);
      expect(find.text('Following'), findsOneWidget);
    },
  );
}
