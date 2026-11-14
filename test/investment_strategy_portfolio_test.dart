import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

Map<String, dynamic> _loadRealBreakoutFixtures() {
  final res = Process.runSync('node', [
    '-e',
    '''
import('./server/breakoutPullbackStrategy.js').then(m => {
  const dashFlagship = m.loadBreakoutPullbackDashboard({ asOf: '2026-11-10', mode: 'flagship' });
  const dashBalanced = m.loadBreakoutPullbackDashboard({ asOf: '2026-11-10', mode: 'balanced' });
  const attrFlagship = m.analyzeBreakoutPullbackRange({
    snapshotId: dashFlagship.snapshotId,
    mode: 'flagship',
    start: dashFlagship.backtest.from,
    end: dashFlagship.backtest.to,
  });
  const attrBalanced = m.analyzeBreakoutPullbackRange({
    snapshotId: dashBalanced.snapshotId,
    mode: 'balanced',
    start: dashBalanced.backtest.from,
    end: dashBalanced.backtest.to,
  });
  process.stdout.write(JSON.stringify({ dashFlagship, dashBalanced, attrFlagship, attrBalanced }));
});
''',
  ]);
  if (res.exitCode != 0) {
    throw StateError('Failed to load real breakout fixtures: ${res.stderr}');
  }
  return jsonDecode(res.stdout as String) as Map<String, dynamic>;
}

final Map<String, dynamic> _realBreakoutBundle = _loadRealBreakoutFixtures();

class _StrategyPortfolioTestApi extends ApiClient {
  _StrategyPortfolioTestApi() : super(() => 'test-token');

  final requestedPaths = <String>[];

  late final Map<String, dynamic> _rawStylesAll =
      jsonDecode(
            File('server/config/investor-style-dashboard.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  Map<String, dynamic> _buildStyleAnalysis(Uri uri) {
    final q = uri.queryParameters;
    final stock = {
      'ticker': 'ANET',
      'netContribution': .08,
      'grossContribution': .081,
      'costContribution': .001,
      'openAtStart': true,
      'openAtEnd': true,
      'openingMark': {'date': q['start'], 'price': 20.0},
      'closingMark': {'date': q['end'], 'price': 42.0},
      'purchases': [
        {'date': '2023-01-03', 'price': 15.0, 'beforeRange': true},
      ],
      'sales': [],
      'corporateActions': [],
    };
    return {
      'version': 'rule-range-attribution-v1',
      'snapshotId': q['snapshotId'] ?? 'test-styles-snapshot',
      'universe': q['universe'] ?? 'all',
      'start': q['start'] ?? '2013-01-02',
      'end': q['end'] ?? '2026-09-24',
      'styles': [
        for (final id in ['quality_rank', 'ackman'])
          {
            'id': id,
            'tradeStats': {
              'wins': 14,
              'losses': 4,
              'flat': 0,
              'open': 3,
              'winRate': .778,
              'payoffRatio': 2.2,
            },
            'holdings': [stock],
            'best': stock,
            'worst': null,
            'reconciliation': {'difference': 0.0},
            'turnover': {
              'version': 'rule-range-turnover-v1',
              'oneWay': 1.25,
              'annualizedOneWay': .32,
              'executions': 12,
            },
            'distribution': [
              for (var i = 0; i < 9; i++) {'count': i == 6 ? 5 : 1},
            ],
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    requestedPaths.add(path);
    final uri = Uri.parse(path);
    if (path.contains('/api/investment/breakout-pullback/analysis')) {
      final mode = uri.queryParameters['mode'] ?? 'flagship';
      return Map<String, dynamic>.from(
        _realBreakoutBundle[mode == 'balanced' ? 'attrBalanced' : 'attrFlagship']
            as Map,
      );
    }
    if (path.contains('/api/investment/breakout-pullback')) {
      final mode = uri.queryParameters['mode'] ?? 'flagship';
      return Map<String, dynamic>.from(
        _realBreakoutBundle[mode == 'balanced' ? 'dashBalanced' : 'dashFlagship']
            as Map,
      );
    }
    if (path.contains('/api/investment/investor-styles/analysis')) {
      return _buildStyleAnalysis(uri);
    }
    if (path.contains('/api/investment/investor-styles')) {
      return {
        ..._rawStylesAll,
        'snapshotId': 'test-styles-snapshot',
      };
    }
    if (path.contains('/api/investment/strategy-lab')) {
      return {
        'version': 'strategy-lab-catalog-v1',
        'asOf': uri.queryParameters['asOf'] ?? '2026-11-10',
        'managers': [],
        'etfs': [],
        'saved': [],
      };
    }
    return {};
  }
}

Future<void> _mountWorkspace(
  WidgetTester tester,
  _StrategyPortfolioTestApi api, {
  Size size = const Size(1280, 900),
  AppLanguage language = AppLanguage.en,
  ValueChanged<String>? onCompany,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: language,
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: StrategyWorkspacePanel(
                api: api,
                palette: Palette(false),
                asOf: '2026-11-10',
                onCompany: onCompany ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in [AppLanguage.en, AppLanguage.zh]) {
    for (final size in [const Size(1280, 900), const Size(390, 844)]) {
      testWidgets(
        'Strategy Portfolio is default tab and renders without overflow ($language, $size)',
        (tester) async {
          final api = _StrategyPortfolioTestApi();
          await _mountWorkspace(tester, api, size: size, language: language);

          expect(tester.takeException(), isNull);
          expect(
            tester
                .widget<ChoiceChip>(
                  find.byKey(const ValueKey('strategy-styles-tab')),
                )
                .selected,
            isTrue,
          );
          expect(
            api.requestedPaths.any((p) => p.contains('/strategy-lab')),
            isFalse,
          );
          expect(
            find.byKey(const ValueKey('portfolio-card-breakout_pullback')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('portfolio-card-quality_rank')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('portfolio-card-ackman')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('breakout-mode-flagship')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('breakout-mode-balanced')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('rule-universe-all')),
            findsNothing,
          );
          expect(find.textContaining('8.91x'), findsWidgets);
        },
      );
    }
  }

  testWidgets(
    'Breakout Dual Mode Switch updates KPIs, range attribution, holdings/watchlist/trades, and replay dialog',
    (tester) async {
      final api = _StrategyPortfolioTestApi();
      String? openedTicker;
      await _mountWorkspace(
        tester,
        api,
        size: const Size(1280, 960),
        language: AppLanguage.zh,
        onCompany: (t) => openedTicker = t,
      );

      expect(find.textContaining('8.91x'), findsWidgets);
      expect(
        api.requestedPaths.any(
          (p) =>
              p.contains('/breakout-pullback/analysis') &&
              p.contains('mode=flagship'),
        ),
        isTrue,
      );

      // Switch to balanced (7.54x, Sharpe 1.12)
      final balancedBtn = find.byKey(const ValueKey('breakout-mode-balanced'));
      await tester.ensureVisible(balancedBtn);
      await tester.tap(balancedBtn);
      await tester.pumpAndSettle();

      expect(
        api.requestedPaths.any(
          (p) =>
              p.contains('/breakout-pullback/analysis') &&
              p.contains('mode=balanced'),
        ),
        isTrue,
      );
      expect(find.textContaining('7.54x'), findsWidgets);
      expect(tester.takeException(), isNull);

      // Switch Module 04 sub-tabs: Watchlist -> Trades
      final watchlistTab = find.byKey(
        const ValueKey('breakout-book-tab-watchlist'),
      );
      await tester.ensureVisible(watchlistTab);
      await tester.tap(watchlistTab);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final tradesTab = find.byKey(const ValueKey('breakout-book-tab-trades'));
      await tester.ensureVisible(tradesTab);
      await tester.tap(tradesTab);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Open Trade Replay dialog on the first recent trade
      final replayButtons = find.byIcon(Icons.chevron_right);
      expect(replayButtons, findsWidgets);
      await tester.ensureVisible(replayButtons.first);
      await tester.tap(replayButtons.first);
      await tester.pumpAndSettle();

      expect(find.text('1. 63 日新高突破日'), findsOneWidget);
      final openResearchBtn = find.widgetWithText(FilledButton, '研究公司');
      expect(openResearchBtn, findsOneWidget);
      await tester.tap(openResearchBtn);
      await tester.pumpAndSettle();
      expect(openedTicker, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Switching Strategy Portfolio cards isolates Quality Four-Factor and Compounder Quality without mixing controls',
    (tester) async {
      final api = _StrategyPortfolioTestApi();
      await _mountWorkspace(
        tester,
        api,
        size: const Size(1280, 960),
        language: AppLanguage.en,
      );

      // Tap Card 2: Quality Four-Factor Rank
      final qualityCard = find.byKey(
        const ValueKey('portfolio-card-quality_rank'),
      );
      await tester.ensureVisible(qualityCard);
      await tester.tap(qualityCard);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('breakout-mode-flagship')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('rule-universe-all')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('style-quality_rank')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('style-ackman')), findsNothing);
      expect(tester.takeException(), isNull);

      // Tap Card 3: Compounder Quality (Ackman Style)
      final ackmanCard = find.byKey(const ValueKey('portfolio-card-ackman'));
      await tester.ensureVisible(ackmanCard);
      await tester.tap(ackmanCard);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('style-ackman')), findsOneWidget);
      expect(find.byKey(const ValueKey('style-quality_rank')), findsNothing);
      expect(tester.takeException(), isNull);

      // Tap Strategy builder tab -> mounts StrategyLabPanel cleanly
      final builderTab = find.byKey(const ValueKey('strategy-builder-tab'));
      await tester.ensureVisible(builderTab);
      await tester.tap(builderTab);
      await tester.pumpAndSettle();
      expect(
        api.requestedPaths.any((p) => p.contains('/strategy-lab')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
