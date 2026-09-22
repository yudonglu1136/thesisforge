import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class _NavigationApi extends ApiClient {
  _NavigationApi() : super(() => 'synthetic-test-token');
  final requests = <String>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    requests.add(path);
    // Explicit empty data exercises the real loading -> empty path.
    return {
      'asOf': '2026-09-22',
      'selectedQuarter': '2026Q2',
      'availableQuarters': ['2026Q2'],
      'snapshotId': 'fixture',
      'context': {
        'asOf': '2026-09-22',
        'selectedQuarter': '2026Q2',
        'window': 8,
        'snapshotId': 'fixture',
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
}
