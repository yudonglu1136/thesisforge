import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_explorer_test.dart' as explorer;

class SectorApi extends explorer.ExplorerApi {
  final requests = <String>[];
  final allRequests = <String>[];
  final delayed = <Completer<Map<String, dynamic>>>[];
  bool failSector = false, hold = false, missingAmounts = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    allRequests.add(path);
    if (!path.startsWith('/api/investment/13f-sectors/')) {
      return super.getJson(path);
    }
    requests.add(path);
    if (failSector) throw StateError('unavailable');
    if (hold) {
      final request = Completer<Map<String, dynamic>>();
      delayed.add(request);
      return request.future;
    }
    final params = Uri.parse(path).queryParameters;
    return response(params['view'] ?? 'stocks')
      ..['offset'] = int.parse(params['offset'] ?? '0');
  }

  Map<String, dynamic> response(String view) => {
    'offset': 0,
    'total': 41,
    'view': view,
    'summary': {
      'addProxyM': 40,
      'trimProxyM': 15,
      'netProxyM': 25,
      'stocks': 60,
      'managers': 100,
      'positions': 1000,
      'pricedPositions': 990,
      'priorPricePositions': 1,
      'unpricedPositions': 10,
      'currentValueM': 900,
      'previousValueM': 800,
      'reportedValueChangeM': 100,
    },
    'rows': [
      {
        'ticker': 'MSFT',
        'name': view == 'managers' ? 'Active Capital' : 'Microsoft',
        'investorId': 'ACTIVE',
        'industry': 'Software',
        'rank': 3,
        'addProxyM': missingAmounts ? null : 20,
        'trimProxyM': missingAmounts ? null : 5,
        'netProxyM': missingAmounts ? null : 15,
        'currentValueM': 500,
        'previousWeight': .2,
        'currentWeight': .3,
        'addingPositions': 20,
        'reducingPositions': 10,
        'newPositions': 2,
        'exitedPositions': 3,
        'positions': 40,
        'pricedPositions': 36,
        'unpricedPositions': 4,
        'inconsistentPositions': 2,
      },
    ],
  };
}

void main() {
  for (final language in AppLanguage.values) {
    for (final width in [1280.0, 390.0]) {
      testWidgets('sector card opens lazy detail $language $width', (
        tester,
      ) async {
        final api = SectorApi();
        await explorer.mountExplorer(
          tester,
          api,
          language: language,
          size: Size(width, 900),
        );
        await explorer.tapKey(tester, '13f-scope-active');
        expect(api.requests, isEmpty);
        await explorer.tapKey(tester, '13f-sector-Technology');
        expect(find.byType(ActiveSectorDialog), findsOneWidget);
        expect(api.requests.length, 1);
        expect(
          Uri.parse(api.requests.last).queryParameters['quarter'],
          '2026-03-31',
        );
        expect(find.byKey(const ValueKey('sector-row-MSFT')), findsOneWidget);
        final dialog = find.byType(ActiveSectorDialog);
        expect(
          find.descendant(of: dialog, matching: find.byType(StockLogo)),
          findsOneWidget,
        );
        await explorer.tapKey(tester, 'sector-detail-MSFT');
        expect(find.textContaining('36 / 40'), findsOneWidget);
        expect(api.requests.length, 1, reason: 'Details reuse the pinned row');
        await explorer.tapKey(tester, 'sector-detail-MSFT');
        expect(find.textContaining('36 / 40'), findsNothing);
        await explorer.tapKey(tester, 'sector-tab-managers');
        expect(find.textContaining('Active Capital'), findsOneWidget);
        expect(
          find.descendant(of: dialog, matching: find.byType(StockLogo)),
          findsNothing,
          reason: 'A manager must not inherit a stock identity',
        );
        await explorer.tapKey(tester, 'sector-direction-reducing');
        expect(
          Uri.parse(api.requests.last).queryParameters['direction'],
          'reducing',
        );
        await explorer.tapKey(tester, 'sector-close');
        expect(find.byType(ActiveSectorDialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('sector filters and paging keep source context and fixed rank', (
    tester,
  ) async {
    final api = SectorApi();
    await explorer.mountExplorer(tester, api);
    await explorer.tapKey(tester, '13f-scope-active');
    await explorer.tapKey(tester, '13f-sector-Technology');
    final pinned = Uri.parse(api.requests.single).queryParameters;
    await explorer.tapKey(tester, 'sector-next');
    expect(Uri.parse(api.requests.last).queryParameters['offset'], '20');
    await explorer.tapKey(tester, 'sector-direction-adding');
    final filtered = Uri.parse(api.requests.last).queryParameters;
    expect(filtered['offset'], '0');
    for (final key in ['asOf', 'quarter', 'generation', 'limit']) {
      expect(filtered[key], pinned[key], reason: '$key stays pinned');
    }
    expect(find.text('#3'), findsOneWidget);
    await explorer.tapKey(tester, 'sector-methodology');
    expect(find.textContaining('990 / 1,000'), findsOneWidget);
    expect(find.textContaining('not causal attribution'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('missing amounts stay missing with visible coverage warning', (
    tester,
  ) async {
    final api = SectorApi()..missingAmounts = true;
    await explorer.mountExplorer(tester, api, size: const Size(390, 844));
    await explorer.tapKey(tester, '13f-scope-active');
    await explorer.tapKey(tester, '13f-sector-Technology');
    final row = find.byKey(const ValueKey('sector-row-MSFT'));
    expect(
      find.descendant(of: row, matching: find.text('—')),
      findsNWidgets(3),
    );
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('partial coverage'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('\$0.0M')),
      findsNothing,
    );
    await explorer.tapKey(tester, 'sector-detail-MSFT');
    expect(find.text('Missing inputs are excluded, not zero.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'industry drilldown preserves industry and stock research opens',
    (tester) async {
      final api = SectorApi();
      await explorer.mountExplorer(tester, api);
      await explorer.tapKey(tester, '13f-scope-active');
      await explorer.tapKey(tester, '13f-sector-Technology');
      await explorer.tapKey(tester, 'sector-tab-industries');
      await explorer.tapKey(tester, 'sector-open-Software');
      final params = Uri.parse(api.requests.last).queryParameters;
      expect(params['view'], 'stocks');
      expect(params['industry'], 'Software');
      await explorer.tapKey(tester, 'sector-open-MSFT');
      expect(find.byType(ActiveSectorDialog), findsNothing);
      expect(api.allRequests.any((path) => path.contains('MSFT')), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('sector error never substitutes leaders; retry works', (
    tester,
  ) async {
    final api = SectorApi()..failSector = true;
    await explorer.mountExplorer(tester, api);
    await explorer.tapKey(tester, '13f-scope-active');
    await explorer.tapKey(tester, '13f-sector-Technology');
    expect(find.textContaining('No substitute sample'), findsOneWidget);
    api.failSector = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sector-row-MSFT')), findsOneWidget);
  });
  testWidgets('out-of-order sector responses cannot replace newer view', (
    tester,
  ) async {
    final api = SectorApi();
    await explorer.mountExplorer(tester, api);
    await explorer.tapKey(tester, '13f-scope-active');
    await explorer.tapKey(tester, '13f-sector-Technology');
    api.hold = true;
    await tester.ensureVisible(
      find.byKey(const ValueKey('sector-tab-industries')),
    );
    await tester.tap(find.byKey(const ValueKey('sector-tab-industries')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sector-tab-managers')));
    await tester.pump();
    api.delayed[1].complete(api.response('managers'));
    await tester.pumpAndSettle();
    api.delayed[0].complete(api.response('industries'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Active Capital'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
