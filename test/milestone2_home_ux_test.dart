import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class _Milestone2HomeApi extends ApiClient {
  _Milestone2HomeApi() : super(() => 'test-token');

  int syncCalls = 0;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/api/investment/home')) {
      return {
        'watches': [
          {'ticker': 'AMZN', 'asOf': '2026-11-18'},
        ],
        'decisions': [],
        'attention': [
          {
            'decisionId': 'dec-1',
            'ticker': 'MSFT',
            'period': '2026-Q2',
            'status': 'review_required',
            'triggers': [
              {
                'status': 'review_required',
                'rule': {
                  'metric': 'revenueGrowth',
                  'operator': 'lt',
                  'threshold': 0.15,
                },
              },
            ],
            'guruChanges': [],
          },
        ],
      };
    }
    if (path.startsWith('/api/investment/portfolio-analysis')) {
      return {
        'version': 'portfolio-research-v1',
        'asOf': '2026-11-18',
        'status': 'unconfigured',
        'groups': const [],
        'connection': {'configured': false},
      };
    }
    if (path.startsWith('/api/investment/research/')) {
      final symbol = path.contains('/AMZN') ? 'AMZN' : 'NVDA';
      return {
        'ticker': symbol,
        'name': symbol == 'AMZN' ? 'Amazon.com, Inc.' : 'NVIDIA Corporation',
        'currency': 'USD',
        'asOf': '2026-11-18',
        'hasPlatformModel': true,
        'snapshot': {
          'quarter': '2026-Q2',
          'availableAt': '2026-08-27',
          'fairValue': 250.0,
          'priceComparison': {'marketPrice': 220.0, 'priceDate': '2026-11-17'},
          'methods': [],
          'reconciliation': {'steps': []},
        },
        'financials': {'annual': [], 'quarterly': []},
        'researchRecords': [],
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path.contains('/sync')) syncCalls++;
    return {};
  }
}

void main() {
  testWidgets(
    'Unconnected Home shows Quickstart launchpad, disables Sync now, surfaces review alerts & watchlist, and 1-click opens NVDA valuation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _Milestone2HomeApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'home',
              initialTicker: '',
              initialAsOf: '2026-11-18',
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Triggered review alert is surfaced right at top of Home
      expect(find.text('1 saved decisions need a review'), findsOneWidget);

      // 2. Quickstart launchpad and Watchlist briefing are rendered
      expect(
        find.byKey(const ValueKey('home-quickstart-launchpad')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-research-briefing')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-watch-AMZN')), findsOneWidget);

      // 3. Sync now is disabled when 0 accounts are connected (no error-producing POST)
      final syncBtn = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('home-sync-now')),
      );
      expect(syncBtn.onPressed, isNull);
      expect(api.syncCalls, 0);

      // 4. One-click NVDA chip opens Research Cockpit directly
      await tester.tap(find.byKey(const ValueKey('quickstart-ticker-NVDA')));
      await tester.pumpAndSettle();
      expect(find.text('NVIDIA Corporation'), findsWidgets);
    },
  );
}
