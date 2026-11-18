import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

Map<String, dynamic> _loadMilestone6StrategyFixtures() {
  final res = Process.runSync('node', [
    '-e',
    '''
Promise.all([
  import('./server/breakoutPullbackStrategy.js'),
  import('./server/qqqSchdRotationStrategy.js'),
]).then(([m, r]) => {
  const breakout = m.loadBreakoutPullbackDashboard({ asOf: '2026-11-17', mode: 'flagship' });
  const breakoutAttr = m.analyzeBreakoutPullbackRange({
    snapshotId: breakout.snapshotId,
    mode: 'flagship',
    start: breakout.backtest.from,
    end: breakout.backtest.to,
  });
  const rotation = r.loadQqqSchdRotationDashboard({ asOf: '2026-11-17', mode: 'm6', window: 'live_2011' });
  process.stdout.write(JSON.stringify({ breakout, breakoutAttr, rotation }));
});
''',
  ]);
  if (res.exitCode != 0) {
    throw StateError('Failed to load Milestone 6 fixtures: ${res.stderr}');
  }
  return jsonDecode(res.stdout as String) as Map<String, dynamic>;
}

final Map<String, dynamic> _m6Fixtures = _loadMilestone6StrategyFixtures();

class Milestone6StrategyApi extends ApiClient {
  Milestone6StrategyApi() : super(() => 'test-token');

  final List<String> getPaths = <String>[];
  final List<Map<String, dynamic>> postCalls = <Map<String, dynamic>>[];
  late final Map<String, dynamic> _rawStyles =
      jsonDecode(
            File('server/config/investor-style-dashboard.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    getPaths.add(path);
    final uri = Uri.parse(path);
    if (uri.path == '/api/investment/breakout-pullback') {
      return jsonDecode(jsonEncode(_m6Fixtures['breakout']))
          as Map<String, dynamic>;
    }
    if (uri.path == '/api/investment/breakout-pullback/analysis') {
      return jsonDecode(jsonEncode(_m6Fixtures['breakoutAttr']))
          as Map<String, dynamic>;
    }
    if (uri.path == '/api/investment/qqq-schd-rotation') {
      return jsonDecode(jsonEncode(_m6Fixtures['rotation']))
          as Map<String, dynamic>;
    }
    if (uri.path == '/api/investment/investor-styles') {
      return jsonDecode(jsonEncode(_rawStyles)) as Map<String, dynamic>;
    }
    if (uri.path == '/api/investment/investor-styles/analysis') {
      return {
        'version': 'rule-range-attribution-v1',
        'snapshotId': uri.queryParameters['snapshotId'] ?? 'snap',
        'universe': 'all',
        'start': '2016-01-04',
        'end': '2026-09-24',
        'styles': [
          for (final id in ['quality_rank', 'ackman'])
            {
              'id': id,
              'tradeStats': {'wins': 10, 'losses': 4, 'winRate': 0.714},
              'bands': <Map<String, dynamic>>[],
              'topWinners': <Map<String, dynamic>>[],
              'topLosers': <Map<String, dynamic>>[],
            },
        ],
      };
    }
    if (uri.path == '/api/investment/hedge') {
      return {
        'status': 'ready',
        'date': '2026-11-17',
        'latest': '2026-11-17',
        'spot': 500,
        'dates': ['2026-11-17'],
        'saved': <Map<String, dynamic>>[],
        'expiries': [
          {'expiry': '2026-12-18', 'puts': 2, 'calls': 1},
        ],
        'chain': [
          {
            'ticker': 'put-480',
            'expiry': '2026-12-18',
            'type': 'put',
            'strike': 480,
            'close': 6.5,
          },
          {
            'ticker': 'put-450',
            'expiry': '2026-12-18',
            'type': 'put',
            'strike': 450,
            'close': 2.5,
          },
          {
            'ticker': 'call-525',
            'expiry': '2026-12-18',
            'type': 'call',
            'strike': 525,
            'close': 5.0,
          },
        ],
      };
    }
    if (uri.path == '/api/investment/strategy-lab') {
      return {
        'version': 'strategy-lab-catalog-v1',
        'asOf': uri.queryParameters['asOf'],
        'storage': {'cutoff': '2026-11-17'},
        'managers': [
          {
            'id': 'bill-ackman',
            'name': 'Bill Ackman',
            'quarters': 24,
            'avatar': '',
          },
        ],
        'etfs': [
          {
            'ticker': 'KMLM',
            'available': true,
            'first': '2020-12-02',
            'last': '2026-11-17',
          },
        ],
        'saved': [
          for (var i = 1; i <= 8; i++)
            {
              'id': 'saved-$i',
              'name': 'Saved Strategy #$i',
              'asOf': '2026-11-17',
              'rules': {
                'asOf': '2026-11-17',
                'start': '2023-11-17',
                'end': '2026-11-17',
                'managers': ['bill-ackman'],
                'topN': 5,
                'valuationEnabled': true,
                'maxPremium': 0.3,
                'excludedAllocation': 'fully_invested',
                'cta': 'KMLM',
                'ctaWeight': 0.3,
                'costBps': 10,
              },
            },
        ],
      };
    }
    throw StateError('Unexpected GET path: $path');
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    postCalls.add({'path': path, ...body});
    if (path == '/api/investment/strategy-rules/archive') {
      return {'targetId': body['targetId'], 'archivedAt': '2026-11-17T00:00:00Z'};
    }
    return {'status': 'ready', 'results': <Map<String, dynamic>>[]};
  }
}

void main() {
  testWidgets(
    'StrategyWorkspacePanel mounts top live strips, research-compliant rotation wording, lazy Options Hedge Lab tab, and expandable/archivable saved strategies',
    (t) async {
      final api = Milestone6StrategyApi();
      t.view.physicalSize = const Size(1440, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: LanguageScope(
            language: AppLanguage.en,
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: StrategyWorkspacePanel(
                    api: api,
                    palette: Palette(false),
                    asOf: '2026-11-17',
                    onCompany: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      // 1. Hedge & Builder endpoints are NOT called until their tabs are clicked
      expect(
        api.getPaths.where((p) => p.startsWith('/api/investment/hedge')),
        isEmpty,
      );
      expect(
        api.getPaths.where((p) => p.startsWith('/api/investment/strategy-lab')),
        isEmpty,
      );

      // 2. Breakout Pullback renders above-the-fold live strip + jump buttons
      expect(find.byKey(const ValueKey('breakout-top-live-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('breakout-jump-holdings')), findsOneWidget);
      expect(find.byKey(const ValueKey('breakout-jump-watchlist')), findsOneWidget);

      // 3. Switch to QQQ ⇄ SCHD Rotation -> renders top live strip & compliant wording
      await t.tap(find.byKey(const ValueKey('portfolio-card-qqq_schd_rotation')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rotation-top-live-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('rotation-jump-radar')), findsOneWidget);
      expect(find.textContaining('MODEL TARGET STATE (RESEARCH)'), findsOneWidget);

      // 4. Switch to Quality Top 10 -> renders top model basket strip
      await t.tap(find.byKey(const ValueKey('portfolio-card-quality_rank')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('rule-top-live-strip-quality_rank')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('rule-jump-holdings')), findsOneWidget);

      // 5. Switch to Options Hedge Lab tab -> lazy-loads HedgeLabPanel cleanly
      expect(find.byKey(const ValueKey('strategy-hedge-tab')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('strategy-hedge-tab')));
      await t.pumpAndSettle();
      expect(
        api.getPaths.where((p) => p.startsWith('/api/investment/hedge')),
        isNotEmpty,
      );
      expect(find.textContaining('Protective Put'), findsWidgets);

      // 6. Switch to Strategy Builder tab -> shows 6 recent saved strategies + 'Show all (8)' toggle + delete action
      await t.tap(find.byKey(const ValueKey('strategy-builder-tab')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('saved-strategies-toggle-all')),
        findsOneWidget,
      );
      expect(find.text('Saved Strategy #8'), findsOneWidget);
      expect(find.text('Saved Strategy #1'), findsNothing);

      await t.tap(find.byKey(const ValueKey('saved-strategies-toggle-all')));
      await t.pumpAndSettle();
      expect(find.text('Saved Strategy #1'), findsOneWidget);

      // Delete Saved Strategy #8 via InputChip delete button
      final chip8 = t.widget<InputChip>(
        find.byKey(const ValueKey('saved-strategy-saved-8')),
      );
      chip8.onDeleted!();
      await t.pumpAndSettle();
      expect(find.text('Saved Strategy #8'), findsNothing);
      expect(
        api.postCalls.any(
          (c) =>
              c['path'] == '/api/investment/strategy-rules/archive' &&
              c['targetId'] == 'saved-8',
        ),
        isTrue,
      );
    },
  );
}
