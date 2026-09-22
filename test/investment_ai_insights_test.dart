import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

// Synthetic financial examples are isolated to tests.
class AiInsightsFixtureApi extends ApiClient {
  AiInsightsFixtureApi() : super(() => 'test');
  final calls = <String>[];
  bool fail = false, wrongComparisonSnapshot = false, empty = false;
  final pending = <String, Completer<Map<String, dynamic>>>{};

  Map<String, dynamic> metric(double amount) => {
    'amount': amount,
    'yoy': .2,
    'qoq': -.05,
    'coverage': {
      'expected': 4,
      'disclosed': 3,
      'yoyComparable': 2,
      'qoqComparable': 3,
    },
    'breakdown': {'big4': amount * .9, 'neocloud': amount * .1},
    'yoyComparison': {
      'contributions': [
        {'ticker': 'CRDO', 'delta': 20e6, 'contribution': .2},
      ],
    },
    'qoqComparison': {
      'contributions': [
        {'ticker': 'CRDO', 'delta': -5e6, 'contribution': -.05},
      ],
    },
  };
  Map<String, dynamic> row(
    String ticker, {
    double? yoy = .2,
    String group = 'hardware',
  }) => {
    'ticker': ticker,
    'name': '$ticker test company',
    'group': group,
    'sector': 'interconnect',
    'sectorLabel': {'en': 'Interconnect', 'zh': '互连'},
    'quarter': '2026Q2',
    'reportperiod': '2026-06-30',
    'datekey': '2026-08-01',
    'revenue': yoy == null ? null : 100e6,
    'revenueYoY': yoy,
    'revenueQoQ': yoy == null ? null : -.05,
    'yoyAcceleration': yoy == null ? null : .01,
    'ttmOperatingMargin': -.1,
    'ttmFcfMargin': -.2,
    'sbcRatio': .12,
    'growthScore': yoy == null ? null : 70,
    'qualityScore': yoy == null ? null : 55,
    'compositeScore': yoy == null ? null : 62.5,
    'rank': {'growth': 9, 'quality': 12, 'composite': 11},
    'status': yoy == null ? 'missing' : 'ready',
    'scoreBreakdown': {
      'growth': [
        {
          'metric': 'revenueYoY',
          'raw': yoy,
          'weight': .4,
          'percentile': 80,
          'contribution': 32,
        },
      ],
      'quality': [],
    },
  };
  Map<String, dynamic> response(String date, {String quarter = '2026Q2'}) => {
    'context': {
      'snapshotId': 'snapshot-$date',
      'asOf': date,
      'quarter': quarter,
      'availableQuarters': ['2026Q2', '2026Q1'],
      'methodologyVersion': 'test-v1',
      'universeVersion': 'test-basket',
    },
    'summary': {
      'capex': metric(150e9),
      'hardware': metric(80e9),
      'software': metric(20e9),
    },
    'series': [
      for (final q in ['2026Q1', '2026Q2'])
        {
          'quarter': q,
          'capex': metric(150e9),
          'hardware': metric(80e9),
          'software': metric(20e9),
        },
    ],
    'companies': [
      row('CRDO'),
      row('ALAB', yoy: .5),
      row('MISS', yoy: null),
      row('PLTR', group: 'software'),
    ],
    'capexComposition': [
      {
        'ticker': 'MSFT',
        'name': 'Microsoft fixture',
        'capexGroup': 'big4',
        'amount': -1e9,
        'yoy': null,
        'qoq': -.1,
        'reportperiod': '2026-06-30',
        'datekey': '2026-08-01',
        'status': 'net_disposal_inflow',
      },
    ],
    'sectors': [
      {
        'id': 'interconnect',
        'label': {'en': 'Interconnect', 'zh': '互连'},
        'group': 'hardware',
        'series': [
          for (final q in ['2026Q1', '2026Q2'])
            {'quarter': q, 'yoy': .2, 'qoq': -.05},
        ],
      },
    ],
  };
  Map<String, dynamic> detail(String ticker) => {
    'company': row(ticker),
    'history': [
      for (final q in ['2026Q1', '2026Q2']) {...row(ticker), 'quarter': q},
    ],
    'evidence': [
      {
        'metric': 'revenue',
        'value': 100e6,
        'unit': 'USD',
        'reportperiod': '2026-06-30',
        'datekey': '2026-08-01',
        'sourceRevisionId': 'synthetic',
        'source': 'TEST ONLY',
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(path);
    if (fail) throw StateError('offline');
    final uri = Uri.parse(path), date = uri.queryParameters['asOf']!;
    if (pending.containsKey(date)) return pending[date]!.future;
    final base = response(
      date,
      quarter: uri.queryParameters['quarter'] ?? '2026Q2',
    );
    if (empty) {
      return {
        'context': base['context'],
        'summary': const {},
        'series': const [],
        'companies': const [],
        'sectors': const [],
        'rankings': const {},
      };
    }
    if (uri.path.endsWith('/compare')) {
      return {
        'context': {
          ...base['context'] as Map<String, dynamic>,
          if (wrongComparisonSnapshot) 'snapshotId': 'different',
        },
        'companies': [
          for (final ticker in uri.queryParameters['tickers']!.split(','))
            detail(ticker),
        ],
      };
    }
    if (uri.path.contains('/companies/')) {
      return {'context': base['context'], ...detail(uri.pathSegments.last)};
    }
    return base;
  }
}

Future<void> mountAi(
  WidgetTester tester,
  AiInsightsFixtureApi api, {
  double width = 1400,
  double scale = 1,
  String date = '2026-09-22',
  AppLanguage language = AppLanguage.en,
  Map<String, dynamic> selection = const {},
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: language,
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              child: AiInsightsPanel(
                api: api,
                palette: Palette(false),
                asOf: date,
                initialSelection: selection,
                onCompany: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> tapAi(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'raw sorting preserves loss/negative values, null-last and peer rank',
    () {
      final api = AiInsightsFixtureApi();
      final rows = [
        api.row('NULL', yoy: null),
        api.row('NEG', yoy: -.3),
        api.row('POS', yoy: .1),
        api.row('SOFT', group: 'software'),
      ];
      final sorted = filterAiInsightsCompanies(
        rows,
        group: 'hardware',
        sort: 'revenueYoY',
      );
      expect(sorted.map((r) => r['ticker']), ['POS', 'NEG', 'NULL']);
      expect(sorted.first['rank'], {
        'growth': 9,
        'quality': 12,
        'composite': 11,
      });
      expect(
        filterAiInsightsCompanies(
          rows,
          query: 'neg',
        ).single['ttmOperatingMargin'],
        -.1,
      );
      expect(aiInsightsAmount(-1e9), '−\$1.0B');
      expect(aiInsightsPercent(null), '—');
      expect(aiInsightsPercent(-.2), '-20.0%');
    },
  );

  testWidgets(
    'overview shows disclosure and comparison coverage and loads only once',
    (tester) async {
      final api = AiInsightsFixtureApi();
      await mountAi(tester, api);
      expect(find.text('AI Insights'), findsOneWidget);
      expect(
        find.text('3/4 reported · paired YoY 2 / QoQ 3'),
        findsNWidgets(3),
      );
      expect(find.text('Information available by'), findsNothing);
      expect(find.text('Company research list'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-open-research')), findsOneWidget);
      expect(api.calls.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sparse snapshot without any comparison lists renders empty states',
    (tester) async {
      final api = AiInsightsFixtureApi()..empty = true;
      await mountAi(tester, api);
      await tester.pumpAndSettle();
      await tapAi(tester, find.text('Market context & detailed trends'));
      expect(
        find.text('No disclosed capital investment in this window'),
        findsOneWidget,
      );
      expect(find.text('No comparable pairs available.'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('earlier global cutoff clears only a future quarter selection', (
    tester,
  ) async {
    final api = AiInsightsFixtureApi();
    await mountAi(tester, api, selection: {'quarter': '2026Q2'});
    await mountAi(tester, api, date: '2024-09-01');
    expect(
      Uri.parse(api.calls.last).queryParameters.containsKey('quarter'),
      isFalse,
    );
    expect(
      Uri.parse(api.calls.last).queryParameters.containsKey('snapshotId'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'raw revenue filtering does not fetch or recompute rank universe',
    (tester) async {
      final api = AiInsightsFixtureApi();
      await mountAi(
        tester,
        api,
        selection: {'tab': 'companies', 'sort': 'revenueYoY'},
      );
      await tester.enterText(find.byType(TextField), 'CRDO');
      await tester.pumpAndSettle();
      expect(find.text('CRDO'), findsNWidgets(2));
      expect(find.text('ALAB'), findsNothing);
      expect(
        find.text('1 companies · peer ranks stay fixed when filtering'),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Peer rank 9 · tap company for score inputs'),
        findsOneWidget,
      );
      expect(api.calls.length, 1);
    },
  );

  testWidgets('comparison is snapshot pinned and rejects a mixed generation', (
    tester,
  ) async {
    final api = AiInsightsFixtureApi()..wrongComparisonSnapshot = true;
    await mountAi(tester, api, selection: {'tab': 'compare'});
    await tester.pumpAndSettle();
    final request = Uri.parse(api.calls.last);
    expect(request.path.endsWith('/compare'), isTrue);
    expect(request.queryParameters['snapshotId'], 'snapshot-2026-09-22');
    expect(request.queryParameters['tickers'], 'CRDO,ALAB');
    expect(find.text('Reload analysis'), findsOneWidget);
    expect(find.text('Revenue momentum'), findsNothing);
  });

  testWidgets(
    'a restored snapshot is pinned, refresh deliberately loads latest',
    (tester) async {
      final api = AiInsightsFixtureApi();
      await mountAi(
        tester,
        api,
        selection: {
          'snapshotId': 'snapshot-2026-09-22',
          'quarter': '2026Q2',
          'window': 12,
        },
      );
      expect(
        Uri.parse(api.calls.single).queryParameters['snapshotId'],
        'snapshot-2026-09-22',
      );
      expect(Uri.parse(api.calls.single).queryParameters['window'], '12');
      await tapAi(tester, find.byTooltip('Refresh analysis'));
      expect(
        Uri.parse(api.calls.last).queryParameters.containsKey('snapshotId'),
        isFalse,
      );
    },
  );

  testWidgets('old cutoff response cannot replace the new cutoff snapshot', (
    tester,
  ) async {
    final api = AiInsightsFixtureApi();
    api.pending['2026-08-01'] = Completer<Map<String, dynamic>>();
    await mountAi(tester, api, date: '2026-08-01');
    await mountAi(tester, api, date: '2026-09-22');
    api.pending['2026-08-01']!.complete(api.response('2026-08-01'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2026-09-22'), findsWidgets);
    expect(find.text('2026-08-01'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile Chinese overview and companies retain bounded layouts', (
    tester,
  ) async {
    final api = AiInsightsFixtureApi();
    await mountAi(
      tester,
      api,
      width: 390,
      scale: 1.35,
      language: AppLanguage.zh,
    );
    await tester.pumpAndSettle();
    expect(find.text('信息截止日'), findsNothing);
    expect(find.text('公司研究榜单'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tapAi(tester, find.widgetWithText(ChoiceChip, '公司排名'));
    expect(find.text('比较 AI 建设背后的公司'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('company details show raw score inputs and source evidence', (
    tester,
  ) async {
    final api = AiInsightsFixtureApi();
    await mountAi(tester, api, selection: {'tab': 'companies'});
    await tapAi(tester, find.text('CRDO'));
    expect(find.text('How the scores are built'), findsOneWidget);
    expect(find.text('40.0%'), findsOneWidget);
    expect(find.text('TEST ONLY'), findsOneWidget);
    expect(
      Uri.parse(api.calls.last).queryParameters['snapshotId'],
      'snapshot-2026-09-22',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('English standalone report is available even from Chinese UI', (
    tester,
  ) async {
    final api = AiInsightsFixtureApi();
    await mountAi(tester, api, language: AppLanguage.zh);
    await tapAi(tester, find.byTooltip('导出分析'));
    await tapAi(tester, find.text('英文长图 · PNG'));
    expect(find.text('THESISFORGE / DISCOVER'), findsOneWidget);
    expect(find.text('Hardware: growth and earnings quality'), findsOneWidget);
    expect(find.text('Software: growth and earnings quality'), findsOneWidget);
    expect(find.text('保存 PNG'), findsOneWidget);
    expect(api.calls.length, 1);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1280.0, 390.0]) {
    testWidgets(
      'PNG preview fits ${width.toInt()}px viewport without reducing capture resolution',
      (tester) async {
        final api = AiInsightsFixtureApi();
        await mountAi(tester, api, width: width);
        tester.view.physicalSize = Size(width, 720);
        await tester.pumpAndSettle();
        await tapAi(tester, find.byTooltip('Export analysis'));
        await tapAi(tester, find.text('English report · PNG'));
        final viewport = tester.getRect(
          find.byKey(const ValueKey('ai-insights-export-preview')),
        );
        final boundaryFinder = find
            .ancestor(
              of: find.text('THESISFORGE / DISCOVER'),
              matching: find.byType(RepaintBoundary),
            )
            .first;
        final boundary = tester.renderObject<RenderBox>(boundaryFinder);
        expect(boundary.size.width, 1280);
        final visualLeft = boundary.localToGlobal(Offset.zero).dx;
        final visualRight = boundary
            .localToGlobal(Offset(boundary.size.width, 0))
            .dx;
        expect(visualLeft, greaterThanOrEqualTo(viewport.left - .1));
        expect(visualRight, lessThanOrEqualTo(viewport.right + .1));
        expect(visualRight - visualLeft, closeTo(viewport.width, .1));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
