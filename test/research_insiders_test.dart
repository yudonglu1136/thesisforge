import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

Map<String, dynamic> fixture([String owner = 'Sample Director']) => {
  'ticker': 'PLTR',
  'start': '2026-04-01',
  'sourceAsOf': '2026-09-21',
  'snapshotId': 'pinned',
  'methodVersion': 'reported-insider-activity-v1',
  'total': 6,
  'summary': {
    'purchases': {'value': 200, 'lines': 1, 'complete': true},
    'sales': {'value': null, 'lines': 1, 'complete': false, 'unpriced': 1},
    'excludedLines': 1,
  },
  'months': [
    for (var m = 4; m <= 9; m++)
      {
        'month': '2026-0$m',
        'purchases': {'value': m == 9 ? 200 : 0},
        'sales': {'value': null},
      },
  ],
  'rows': [
    for (var i = 0; i < 5; i++)
      {
        'id': '$owner-$i',
        'ticker': 'PLTR',
        'ownername': owner,
        'isdirector': 'Y',
        'date': '2026-09-17',
        'transactiondate': '2026-09-15',
        'formtype': '4',
        'rownum': i,
        'kind': 'sale',
        'transactioncode': 'S',
        'securityadcode': 'ND',
        'shares': -100,
        'valueUsd': null,
        'priceUsd': null,
        'holdingsAfter': 1000,
        'securitytitle': 'ClA',
      },
  ],
};

class InsiderApi extends ApiClient {
  InsiderApi() : super(() => 'fixture');
  final paths = <String>[];
  final pending = <String, Completer<Map<String, dynamic>>>{};
  bool fail = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    if (fail) throw Exception('unavailable');
    final day = Uri.parse(path).queryParameters['asOf'];
    return pending[day]?.future ?? fixture();
  }
}

Future<void> mount(
  WidgetTester tester,
  InsiderApi api, {
  bool zh = false,
  double width = 1200,
  String asOf = '2026-09-22',
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: zh ? AppLanguage.zh : AppLanguage.en,
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ResearchInsidersPanel(
                api: api,
                palette: Palette(false),
                ticker: 'PLTR',
                asOf: asOf,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final zh in [false, true]) {
    testWidgets(
      'insiders desktop and 390px ${zh ? 'ZH' : 'EN'} show evidence without overflow',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = InsiderApi();
        await mount(tester, api, zh: zh, width: 390);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(zh ? '内部人交易' : 'Insider trades'), findsOneWidget);
        // Transaction identifiers remain visible without a freshly cached icon font.
        expect(find.text('S'), findsNWidgets(5));
        expect(
          find.textContaining(zh ? '仅部分合计' : 'partial total'),
          findsOneWidget,
        );
        final row = find.byKey(const ValueKey('insider-row-Sample Director-0'));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(find.textContaining(zh ? '申报编号' : 'accession'), findsOneWidget);
        await tester.tap(find.text(zh ? '关闭' : 'Close'));
        await tester.pumpAndSettle();
        await mount(tester, api, zh: zh, width: 1280);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'window, filter and pagination preserve cutoff and pin snapshot',
    (tester) async {
      final api = InsiderApi();
      await mount(tester, api);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('insider-window-12')));
      await tester.pumpAndSettle();
      expect(Uri.parse(api.paths.last).queryParameters['months'], '12');
      await tester.tap(find.byKey(const ValueKey('insider-filter-purchase')));
      await tester.pumpAndSettle();
      expect(Uri.parse(api.paths.last).queryParameters['kind'], 'purchase');
      final next = find.byKey(const ValueKey('insider-next'));
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pumpAndSettle();
      final q = Uri.parse(api.paths.last).queryParameters;
      expect(q['offset'], '5');
      expect(q['snapshotId'], 'pinned');
      expect(q['asOf'], '2026-09-22');
    },
  );
  testWidgets(
    'slow previous cutoff cannot overwrite current context; retry works',
    (tester) async {
      final api = InsiderApi();
      api.pending['2026-09-22'] = Completer();
      await mount(tester, api);
      await mount(tester, api, asOf: '2026-09-23');
      await tester.pumpAndSettle();
      api.pending['2026-09-22']!.complete(fixture('Stale future-forbidden'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Stale future-forbidden'), findsNothing);
      api.fail = true;
      await mount(tester, api, asOf: '2026-09-24');
      await tester.pumpAndSettle();
      expect(find.text('Retry filings'), findsOneWidget);
      expect(find.text('Sample Director'), findsNothing);
      api.fail = false;
      await tester.tap(find.text('Retry filings'));
      await tester.pumpAndSettle();
      expect(find.text('Sample Director'), findsNWidgets(5));
    },
  );
}
