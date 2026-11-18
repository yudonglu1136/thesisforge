import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class _NavigationApi extends ApiClient {
  _NavigationApi({
    this.defaultQuarter = '2026Q2',
    this.availableQuarters = const ['2026Q2'],
  }) : super(() => 'synthetic-test-token');
  final String defaultQuarter;
  final List<String> availableQuarters;
  final requests = <String>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    requests.add(path);
    final uri = Uri.parse(path);
    final selected = uri.queryParameters['quarter'] ?? defaultQuarter;
    // Explicit empty data exercises the real loading -> empty path.
    return {
      'asOf': uri.queryParameters['asOf'] ?? '2026-09-22',
      'selectedQuarter': selected,
      'availableQuarters': availableQuarters,
      'snapshotId': 'fixture-$selected',
      'context': {
        'asOf': uri.queryParameters['asOf'] ?? '2026-09-22',
        'quarter': selected,
        'selectedQuarter': selected,
        'availableQuarters': availableQuarters,
        'window': 8,
        'snapshotId': 'fixture-$selected',
      },
      'summary': {},
      'series': [],
      'companies': [],
      'sectors': [],
      'insights': [],
      'capexComposition': [],
      'rankings': {},
    };
  }
}

void main() {
  for (final entry in ['aiinsights', 'valueflow']) {
    testWidgets(
      '$entry opens AI Insights without fetching unrelated discovery data',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = _NavigationApi();
        await tester.pumpWidget(
          MaterialApp(
            home: LanguageScope(
              language: AppLanguage.en,
              child: InvestmentWorkspace(
                api: api,
                palette: Palette(false),
                initialPage: 'discover',
                initialTicker: '',
                initialAsOf: '2026-09-22',
                initialQuery: {'discoverTab': entry, 'ai_quarter': '2026Q2'},
                onLanguage: (_) {},
                onLegacy: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AiInsightsPanel), findsOneWidget);
        expect(find.text('Value Flow'), findsNothing);
        expect(api.requests, isNotEmpty);
        expect(
          api.requests.every(
            (path) => path.startsWith('/api/investment/ai-insights'),
          ),
          isTrue,
          reason: api.requests.join('\n'),
        );
        expect(api.requests.first, contains('quarter=2026Q2'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'legacy auto-persisted ai_snapshotId URL drops stale 2026Q2 pin and opens 2026Q3',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _NavigationApi(
        defaultQuarter: '2026Q3',
        availableQuarters: const ['2026Q3', '2026Q2'],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'discover',
              initialTicker: '',
              initialAsOf: '2026-11-17',
              initialQuery: const {
                'discoverTab': 'aiinsights',
                'ai_quarter': '2026Q2',
                'ai_snapshotId': 'legacy-auto-snapshot-2026Q2',
              },
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final uri = Uri.parse(api.requests.single);
      expect(uri.queryParameters.containsKey('quarter'), isFalse);
      expect(uri.queryParameters.containsKey('snapshotId'), isFalse);
      expect(find.text('2026Q3 · Latest'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-jump-latest-quarter')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicitly pinned historical quarter shows one-click jump chip to 2026Q3',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _NavigationApi(
        defaultQuarter: '2026Q3',
        availableQuarters: const ['2026Q3', '2026Q2'],
      );
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
                'discoverTab': 'aiinsights',
                'ai_quarter': '2026Q2',
                'ai_quarter_pinned': '1',
              },
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(Uri.parse(api.requests.single).queryParameters['quarter'], '2026Q2');
      final jump = find.byKey(const ValueKey('ai-jump-latest-quarter'));
      expect(jump, findsOneWidget);
      expect(find.text('Latest: 2026Q3'), findsOneWidget);
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(Uri.parse(api.requests.last).queryParameters['quarter'], '2026Q3');
      expect(find.byKey(const ValueKey('ai-jump-latest-quarter')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
