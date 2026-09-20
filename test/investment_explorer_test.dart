import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_opportunities_test.dart' as opportunities;
import 'investment_fundamentals_test.dart' as fundamentals;

Map<String, dynamic> qualityFixture() => {
  'status': 'available',
  'asOf': '2026-06-01',
  'source': 'Synthetic quality fixture',
  'years': [
    for (var y = 2025; y >= 2016; y--)
      <String, dynamic>{
        'year': y,
        'periodEnd': '$y-12-31',
        'availableAt': '${y + 1}-02-15',
        'roic': .2,
        'fcfMargin': .1,
        'cashConversion': 1.0,
        'operatingMargin': .25,
      },
  ],
};

Map<String, dynamic> trendFixture() => {
  'eligible': true,
  'status': 'evaluated',
  'upCount': 7,
  'transitions': 7,
  'totalChange': .28,
  'maxDrawdown': 0.0,
  'maxAbsStep': .04,
  'stepVolatility': .01,
  'gainConcentration': .18,
  'policy': {
    'upTolerance': .0025,
    'minTotalChange': .1,
    'maxDrawdown': .1,
    'maxAbsStep': .2,
    'maxGainConcentration': .4,
    'maxAgeDays': 180,
  },
  'points': [
    for (var i = 0; i < 8; i++)
      {
        'period': '${2024 + (i + 1) ~/ 4}-Q${(i + 1) % 4 + 1}',
        'date': DateTime(
          2024,
          8 + 3 * i,
          15,
        ).toIso8601String().substring(0, 10),
        'fairValue': 25.0 + i,
        'currency': 'USD',
      },
  ],
};

List<Map<String, dynamic>> sampleRows() => [
  {
    'ticker': 'TEST',
    'quality': qualityFixture(),
    'name': 'Example Semiconductor',
    'managerCount': 4,
    'newPositions': 1,
    'increases': 2,
    'reductions': 1,
    'exits': 1,
    'adds': 3,
    'trims': 2,
    'modelGap': .2,
    'valuationStatus': 'available',
    'valuation': {
      'trend': trendFixture(),
      'revenueGrowth': .3,
      'change': .1,
      'date': '2026-05-15',
      'modelRoute': 'operating_company',
    },
    'managers': [
      {
        'guruId': 'test-manager',
        'name': 'Test manager',
        'shares': 20,
        'action': 'increased',
      },
      {
        'guruId': 'new-manager',
        'name': 'New manager',
        'shares': 8,
        'action': 'new',
      },
      {
        'guruId': 'reduce-manager',
        'name': 'Reduce manager',
        'shares': 6,
        'action': 'reduced',
      },
      {
        'guruId': 'exit-manager',
        'name': 'Exit manager',
        'shares': 0,
        'action': 'sold_out',
      },
    ],
  },
  {
    'ticker': 'ISRG',
    'quality': qualityFixture(),
    'name': 'Intuitive Surgical fixture',
    'managerCount': 2,
    'newPositions': 1,
    'increases': 1,
    'reductions': 0,
    'exits': 0,
    'adds': 2,
    'trims': 0,
    'modelGap': -.1,
    'valuationStatus': 'available',
    'valuation': {
      'revenueGrowth': .15,
      'change': -.1,
      'date': '2026-05-15',
      'modelRoute': 'operating_company',
    },
    'managers': [
      {'guruId': 'second-manager', 'name': 'Second manager', 'shares': 10},
    ],
  },
  {
    'ticker': 'NVDA',
    'name': 'Missing fixture',
    'managerCount': 1,
    'newPositions': 0,
    'increases': 0,
    'reductions': 1,
    'exits': 0,
    'adds': 0,
    'trims': 1,
    'modelGap': null,
    'valuationStatus': 'not_modeled',
    'valuation': null,
    'managers': [],
  },
];

class ExplorerApi extends opportunities.OpportunityApi {
  bool listFails = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.contains('/fundamentals?')) {
      return fundamentals.FundamentalApi().response(
        Uri.parse(path).queryParameters['asOf']!,
      );
    }
    if (path.startsWith('/api/investment/opportunities?') && listFails) {
      throw StateError('fixture outage');
    }
    final result = await super.getJson(path);
    if (path.startsWith('/api/investment/opportunities?')) {
      result['rows'] = sampleRows();
    }
    if (path.contains('/discover?')) {
      result['discovery'] = [
        {
          'ticker': 'TEST',
          'period': '2026-Q1',
          'availableAt': '2026-05-15',
          'revenueGrowth': .3,
        },
      ];
    }
    return result;
  }
}

Future<void> mountExplorer(
  WidgetTester tester,
  ExplorerApi api, {
  Size size = const Size(1487, 1058),
  AppLanguage language = AppLanguage.en,
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
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'steady value excludes one-off jump and unknown history; ranks stability instead of latest gain',
    () {
      Map<String, dynamic> row(
        String ticker,
        double revision,
        Map<String, dynamic>? trend,
      ) => {
        'ticker': ticker,
        'valuation': {'change': revision, 'trend': trend},
      };
      final rows = [
        row('JUMP', .9, {...trendFixture(), 'eligible': false}),
        row('MISSING', .8, null),
        row('VOLATILE', .15, {...trendFixture(), 'stepVolatility': .08}),
        row('STEADY', .01, {...trendFixture(), 'stepVolatility': .005}),
        row('DIP', .2, {...trendFixture(), 'upCount': 6, 'maxDrawdown': .05}),
      ];
      expect(
        filterDiscoverCandidates(
          rows,
          collection: 'revision',
          sort: 'revision',
        ).map((r) => r['ticker']),
        ['STEADY', 'VOLATILE', 'DIP'],
      );
      expect(rows.first['ticker'], 'JUMP');
    },
  );

  testWidgets(
    'quarter chart selects exact observations and exposes dated table',
    (tester) async {
      await mountExplorer(tester, ExplorerApi());
      await tapKey(tester, 'discover-collection-revision');
      expect(find.byType(SteadyValueChart), findsOneWidget);
      await tapKey(tester, 'value-quarter-0');
      expect(find.textContaining(r'2024-Q2 · $25.00'), findsOneWidget);
      await tapKey(tester, 'value-quarter-table');
      expect(find.text(r'$25.00'), findsOneWidget);
      await tapKey(tester, 'steady-value-rules');
      expect(
        find.textContaining('not validated return predictors'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'growth collection excludes non-operating and unclassified economic routes',
    () {
      final rows = sampleRows();
      (rows[0]['valuation'] as Map)['modelRoute'] = 'financial';
      (rows[1]['valuation'] as Map).remove('modelRoute');
      expect(filterDiscoverCandidates(rows, collection: 'growth'), isEmpty);
      expect(filterDiscoverCandidates(rows), hasLength(3));
    },
  );
  test(
    'discovery rules are explicit, inclusive at boundaries and null-safe',
    () {
      final rows = sampleRows();
      expect(
        filterDiscoverCandidates(
          rows,
          collection: 'adds',
        ).map((r) => r['ticker']),
        ['TEST', 'ISRG'],
      );
      expect(
        filterDiscoverCandidates(
          rows,
          collection: 'new',
          sort: 'newPositions',
        ).map((r) => r['ticker']),
        ['ISRG', 'TEST'],
      );
      expect(
        filterDiscoverCandidates(
          rows,
          collection: 'increased',
        ).map((r) => r['ticker']),
        ['TEST', 'ISRG'],
      );
      expect(
        filterDiscoverCandidates(
          rows,
          collection: 'reduced',
        ).map((r) => r['ticker']),
        ['TEST', 'NVDA'],
      );
      expect(
        filterDiscoverCandidates(rows, collection: 'exited').single['ticker'],
        'TEST',
      );
      expect(filterDiscoverCandidates(rows, collection: 'growth').length, 2);
      expect(
        filterDiscoverCandidates(rows, collection: 'revision').single['ticker'],
        'TEST',
      );
      expect(
        filterDiscoverCandidates(rows, collection: 'debate').single['ticker'],
        'TEST',
      );
      expect(
        filterDiscoverCandidates(rows, coverage: 'missing').single['ticker'],
        'NVDA',
      );
    },
  );
  test(
    'manager, search, coverage and collection intersect without mutating source',
    () {
      final rows = sampleRows();
      expect(
        filterDiscoverCandidates(
          rows,
          manager: 'second-manager',
          query: ' intuitive ',
          collection: 'adds',
          coverage: 'modelled',
        ).single['ticker'],
        'ISRG',
      );
      expect(filterDiscoverCandidates(rows, manager: 'unknown'), isEmpty);
      expect(
        filterDiscoverCandidates(
          rows,
          collection: 'growth',
          coverage: 'missing',
        ),
        isEmpty,
      );
      filterDiscoverCandidates(rows, sort: 'growth');
      expect(rows.last['ticker'], 'NVDA');
    },
  );
  test(
    'sort places unknown last, preserves negatives and breaks ties by ticker',
    () {
      final rows = sampleRows();
      expect(
        filterDiscoverCandidates(rows, sort: 'gap').map((r) => r['ticker']),
        ['TEST', 'ISRG', 'NVDA'],
      );
      rows[1]['managerCount'] = 4;
      expect(filterDiscoverCandidates(rows).first['ticker'], 'ISRG');
    },
  );
  for (final size in [
    const Size(1487, 1058),
    const Size(1280, 720),
    const Size(390, 844),
  ]) {
    for (final language in [AppLanguage.en, AppLanguage.zh]) {
      testWidgets('Discover populated layout $size $language', (tester) async {
        await mountExplorer(
          tester,
          ExplorerApi(),
          size: size,
          language: language,
        );
        expect(
          find.byKey(const ValueKey('discover-collection-adds')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('discover-candidate-TEST')),
        );
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'discover-candidate-TEST');
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('quarterly activity cards rank four distinct 13F actions', (
    tester,
  ) async {
    await mountExplorer(tester, ExplorerApi());
    for (final id in ['new', 'increased', 'reduced', 'exited']) {
      expect(find.byKey(ValueKey('discover-collection-$id')), findsOneWidget);
    }
    await tapKey(tester, 'discover-collection-exited');
    expect(
      find.byKey(const ValueKey('discover-candidate-TEST')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('discover-candidate-ISRG')), findsNothing);
    expect(
      find.text('Which institutions reported exiting this position?'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'collection, search and reset are functional and retain input focus',
    (tester) async {
      await mountExplorer(tester, ExplorerApi());
      await tapKey(tester, 'discover-collection-growth');
      expect(
        find.byKey(const ValueKey('discover-candidate-NVDA')),
        findsNothing,
      );
      final input = find.byKey(const ValueKey('discover-search'));
      await tester.ensureVisible(input);
      await tester.enterText(input, 'intuitive');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('discover-candidate-ISRG')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('discover-candidate-TEST')),
        findsNothing,
      );
      await tester.enterText(input, 'no-such-company');
      await tester.pumpAndSettle();
      expect(find.text('No matches for this combination.'), findsOneWidget);
      await tapKey(tester, 'discover-reset');
      expect(
        find.byKey(const ValueKey('discover-candidate-NVDA')),
        findsOneWidget,
      );
      expect(tester.widget<TextFormField>(input).controller!.text, '');
    },
  );
  testWidgets(
    'valuation round trip returns to Discover and retains collection',
    (tester) async {
      await mountExplorer(tester, ExplorerApi());
      await tapKey(tester, 'discover-collection-growth');
      final action = find.text('Test my assumptions');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      final back = find.text('Back to candidates');
      await tester.ensureVisible(back);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.text('Quarterly institutional moves'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('discover-candidate-NVDA')),
        findsNothing,
      );
      expect(find.text('Growing businesses'), findsNWidgets(2));
    },
  );
  testWidgets('list failure has a recoverable retry', (tester) async {
    final api = ExplorerApi()..listFails = true;
    await mountExplorer(tester, api);
    expect(
      find.text('Could not load the dated opportunity list.'),
      findsOneWidget,
    );
    api.listFails = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('discover-candidate-TEST')),
      findsOneWidget,
    );
  });
  testWidgets('manager and model-coverage dropdowns filter the actual rows', (
    tester,
  ) async {
    await mountExplorer(tester, ExplorerApi());
    await tapKey(tester, 'discover-coverage-all');
    await tester.tap(find.text('Coverage gaps').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('discover-candidate-NVDA')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('discover-candidate-TEST')), findsNothing);
    await tapKey(tester, 'discover-reset');
    await tapKey(tester, 'discover-manager-');
    await tester.tap(find.text('Second manager').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('discover-candidate-ISRG')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('discover-candidate-TEST')), findsNothing);
  });
  testWidgets(
    'fundamentals workbench replaces the revenue-only screen and resets search',
    (tester) async {
      await mountExplorer(tester, ExplorerApi());
      await tester.tap(find.text('Fundamentals'));
      await tester.pumpAndSettle();
      expect(find.text('Strong businesses. Your shortlist.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('fundamental-search')),
        'absent',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reset filters'));
      await tester.tap(find.text('Reset filters'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fund-row-ACC')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('fundamental-search')))
            .controller!
            .text,
        '',
      );
    },
  );
}
