import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

// Synthetic transport fixtures only; production research always comes from Fact OS.
class FundamentalApi extends ApiClient {
  FundamentalApi() : super(() => 'test');
  bool fail = false, detailFail = false, wrongDate = false;
  bool expired = false;
  Completer<Map<String, dynamic>>? pending;
  final delayedSearches = <String, Completer<Map<String, dynamic>>>{};
  Completer<Map<String, dynamic>>? pendingObservations;
  final calls = <String>[];
  var saved = false;

  Map<String, dynamic> row(String ticker) => {
    'ticker': ticker,
    'name': ticker == 'UBER' ? 'Uber Technologies' : '$ticker Facts Only',
    'period_end': '2026-06-30',
    'available_at': '2026-08-06',
    'metrics': {'revenueGrowth': .12, 'operatingMargin': .18, 'fcfMargin': .08},
    'primarySignal': {
      'id': 'slowing_growth_margin_up',
      'priority': 2.0,
      'summary': {
        'en': 'Growth slowed -2.3pp, but TTM operating margin improved +0.5pp.',
        'zh': '收入增速放缓 -2.3pp，但 TTM 经营利润率改善 +0.5pp。',
      },
      'question': {'en': 'Can operating leverage persist?', 'zh': '经营杠杆能否持续？'},
    },
  };

  Map<String, dynamic> response(String date) => {
    'version': 'fundamental-research-v2',
    'methodVersion': 'fact-os-business-change-2026-09-21',
    'asOf': date,
    'lens': 'slowing_growth_margin_up',
    'counts': {
      'growth_profit_sync': 2,
      'slowing_growth_margin_up': 2,
      'profit_cash_weakening': 1,
      'per_share_dilution': 1,
      'capital_return_pending': 1,
      'operating_pricing_divergence': 1,
    },
    'coverage': {
      'factCompanies': 5418,
      'withSignals': 4100,
      'latestAvailableAt': '2026-08-20',
    },
    'rankingBasis': {
      'en': 'Signal magnitude, evidence completeness and filing recency.',
      'zh': '按变化幅度、证据完整度和披露新近程度排序。',
    },
    'totalMatches': 2,
    'rows': [row('UBER'), row('FACT')],
  };

  Map<String, dynamic> detail(String ticker, String date) => {
    'version': 'fundamental-research-v2',
    'methodVersion': 'fact-os-business-change-2026-09-21',
    'ticker': ticker,
    'asOf': date,
    'economicTemplate': 'operating_company',
    'reportedBasis': 'ARQ latest visible revision',
    'restatedBasis': 'MRQ withheld from historical PIT',
    'company': {
      'ticker': ticker,
      'name': ticker == 'UBER' ? 'Uber Technologies' : '$ticker Facts Only',
      'period_end': '2026-06-30',
      'available_at': '2026-08-06',
      'metrics': {'revenueGrowth': .1217, 'operatingMargin': .1213},
    },
    'judgment': {
      'summary': {
        'en': 'Growth slowed -2.3pp, but TTM operating margin improved +0.5pp.',
        'zh': '收入增速放缓 -2.3pp，但 TTM 经营利润率改善 +0.5pp。',
      },
      'question': {
        'en': 'Can operating leverage persist if growth slows again?',
        'zh': '如果增速继续放缓，经营杠杆还能否持续？',
      },
    },
    'importantChanges': [
      for (final label in [
        'Revenue growth slowed',
        'Margin improved',
        'FCF remained positive',
      ])
        {
          'summary': {'en': label, 'zh': '证据：$label'},
        },
    ],
    'counterEvidence': {
      'severity': 'gap',
      'statement': {
        'en': 'Fact OS does not explain causality; the filing must be checked.',
        'zh': 'Fact OS 不解释因果，必须核对财报原文。',
      },
    },
    'trend': [
      for (var i = 0; i < 8; i++)
        {
          'periodEnd': '202${4 + i ~/ 4}-Q${i % 4 + 1}',
          'revenueGrowth': .16 - i * .006,
          'operatingMargin': .08 + i * .006,
        },
    ],
    'sections': [
      {
        'id': 'growth_profit',
        'title': {'en': 'How growth becomes profit', 'zh': '增长如何变成利润'},
        'rows': [
          {
            'id': 'revenueGrowth',
            'label': {'en': 'Quarterly revenue growth', 'zh': '单季度收入同比'},
            'value': .1217,
            'comparison': .1448,
            'formula': 'quarter revenue / same quarter prior year − 1',
            'status': 'available',
          },
        ],
      },
      {
        'id': 'history_peers',
        'title': {'en': 'Relative to history and peers', 'zh': '相对历史与同业'},
        'rows': [],
      },
    ],
    'valuation': {
      'valuationStatus': ticker == 'FACT' ? 'not_modeled' : 'available',
      'modelGap': .08,
      'price': {'value': 92.0, 'currency': 'USD', 'date': '2026-09-18'},
      'breakdown': ticker == 'FACT'
          ? null
          : {
              'modelVersion': 'fixture-v1',
              'availableAt': '2026-08-06',
              'period': '2026-Q2',
              'currency': 'USD',
              'formula': '50% earnings + 50% FCFE DCF; no market price input',
              'fairValue': 100.0,
              'weightedValue': 100.0,
              'priceExcludedFromFairValue': true,
              'components': [
                {
                  'key': 'normalized-earnings-power',
                  'label': 'Normalized earnings power',
                  'output': 110.0,
                  'weight': .5,
                  'description': 'Normalized income / shares × target P/E.',
                  'parameters': [
                    {
                      'key': 'normalizedNetIncome',
                      'label': 'Normalized net income',
                      'value': 1100.0,
                      'format': 'currency_m',
                    },
                    {
                      'key': 'targetPE',
                      'label': 'Target P / E',
                      'value': 10.0,
                      'format': 'multiple',
                    },
                  ],
                },
                {
                  'key': 'fcfe-dcf',
                  'label': 'Five-year FCFE DCF',
                  'output': 90.0,
                  'weight': .5,
                  'description': 'FCFE discounted to the valuation date.',
                  'parameters': [
                    {
                      'key': 'discountRate',
                      'label': 'Discount rate',
                      'value': .10,
                      'format': 'ratio_percent',
                    },
                    {
                      'key': 'terminalGrowth',
                      'label': 'Terminal growth',
                      'value': .025,
                      'format': 'ratio_percent',
                    },
                  ],
                },
              ],
            },
    },
    'sources': [
      {
        'fiscalPeriod': 'Q2',
        'periodEnd': '2026-06-30',
        'availableAt': '2026-08-06',
      },
    ],
    'researchGaps': [
      {'en': 'Trips are not in Fact OS.', 'zh': 'Fact OS 不包含 Trips。'},
    ],
  };

  Map<String, dynamic> institutional(String ticker, String date) => {
    'version': 'institutional-13f-insights-v5',
    'asOf': date,
    'reportDate': '2026-06-30',
    'previousReportDate': '2026-03-31',
    'availableAt': '2026-08-14',
    'ticker': ticker,
    'row': {
      'ticker': ticker,
      'holders': 42,
      'newPositions': 3,
      'increases': 12,
      'reductions': 8,
      'exits': 2,
    },
    'details': {
      'history': [
        for (var i = 0; i < 6; i++)
          {
            'reportDate': '202${5 + i ~/ 4}-${((i % 4) + 1) * 3}-30',
            'holders': 30 + i * 2,
            'institutionalSharesK': 100000 + i * 5000,
            'institutionalOwnershipPct': 60.0 + i,
            'shareBasisFactor': 1,
            'shareBasisDate': '2026-06-30',
          },
      ],
      'analysis': {
        'headlineKey': 'balanced_breadth_net_increase',
        'importantChanges': [
          {
            'investorId': 'fixture-capital',
            'name': 'Fixture Capital',
            'action': 'increased',
            'unitsChangeK': 1200.0,
            'previousWeight': .03,
            'currentWeight': .045,
            'reportedValueChangeM': 85.0,
            'continuity': 'increased_3_quarters',
          },
        ],
      },
    },
  };

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(path);
    final uri = Uri.parse(path);
    if (uri.path.endsWith('/fundamental-observations')) {
      if (pendingObservations != null) return pendingObservations!.future;
      return {
        'version': 'fundamental-observations-v1',
        'rows': saved
            ? [
                {'id': 'obs_1', 'ticker': uri.queryParameters['ticker']},
              ]
            : [],
      };
    }
    if (uri.path.contains('/fundamental-observations/') &&
        uri.path.endsWith('/review')) {
      return {
        'version': 'fundamental-observation-review-v1',
        'changed': true,
        'comparableMethod': true,
      };
    }
    final date = uri.queryParameters['asOf']!;
    if (uri.path.contains('/13f-insights/')) {
      return institutional(uri.pathSegments.last, date);
    }
    if (uri.path.endsWith('/fundamentals')) {
      if (expired) throw StateError('HTTP 401');
      if (fail) throw StateError('offline');
      final delayed = delayedSearches[uri.queryParameters['search']];
      if (delayed != null) return delayed.future;
      if (pending != null) return pending!.future;
      final result = response(wrongDate ? '2025-01-01' : date);
      result['lens'] = uri.queryParameters['lens'];
      result['sort'] = uri.queryParameters['sort'];
      final search = uri.queryParameters['search']?.toUpperCase();
      if (search != null && search.isNotEmpty) {
        result['rows'] = (result['rows'] as List)
            .where(
              (item) => (item as Map)['ticker'].toString().contains(search),
            )
            .toList();
        result['totalMatches'] = (result['rows'] as List).length;
      }
      return result;
    }
    if (detailFail) throw StateError('detail offline');
    return detail(uri.pathSegments.last, date);
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add(path);
    saved = true;
    return {'id': 'obs_1', 'ticker': body['ticker']};
  }
}

Future<void> mount(
  WidgetTester t,
  FundamentalApi api, {
  double width = 1450,
  AppLanguage language = AppLanguage.en,
  String date = '2026-09-21',
  void Function(String, String)? onCompany,
  Map<String, dynamic> selection = const {},
  bool settle = true,
}) async {
  t.view.physicalSize = Size(width, 1300);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: language,
        child: Scaffold(
          body: SingleChildScrollView(
            child: FundamentalsPanel(
              api: api,
              palette: Palette(false),
              asOf: date,
              onCompany: onCompany ?? (_, _) {},
              initialSelection: selection,
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder finder) async {
  await t.ensureVisible(finder);
  await t.tap(finder);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('authentication recovery reloads the selected company evidence', (
    t,
  ) async {
    final api = FundamentalApi();
    await mount(t, api);
    api.expired = true;
    await t.enterText(find.byKey(const ValueKey('fundamental-search')), 'UBER');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('fund-row-UBER')), findsNothing);
    expect(
      find.text(
        'Your session has expired. Sign in again to load company financials.',
      ),
      findsOneWidget,
    );
    api.expired = false;
    await tap(t, find.text('Try again'));
    expect(find.text('OPERATING JUDGMENT'), findsOneWidget);
  });

  testWidgets('a cutoff change never displays the previous cutoff as current', (
    t,
  ) async {
    final api = FundamentalApi();
    await mount(t, api);
    api.pending = Completer<Map<String, dynamic>>();
    await mount(t, api, date: '2025-09-21', settle: false);
    expect(find.byKey(const ValueKey('fund-row-UBER')), findsNothing);
    expect(find.text('OPERATING JUDGMENT'), findsNothing);
    api.pending!.complete(api.response('2025-09-21'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
    expect(
      api.calls.any((x) => x.contains('/fundamentals/UBER?asOf=2025-09-21')),
      isTrue,
    );
  });

  testWidgets('old journal responses cannot overwrite a new research context', (
    t,
  ) async {
    final api = FundamentalApi();
    final oldJournal = Completer<Map<String, dynamic>>();
    api.pendingObservations = oldJournal;
    await mount(t, api);
    api.pendingObservations = null;
    await mount(t, api, date: '2025-09-21');
    oldJournal.complete({
      'rows': [
        {'id': 'stale-observation', 'ticker': 'UBER'},
      ],
    });
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('fund-review-observation')), findsNothing);
  });

  testWidgets('returning to a saved company tab restores valuation context', (
    t,
  ) async {
    await mount(
      t,
      FundamentalApi(),
      selection: {'ticker': 'UBER', 'detailTab': 'valuation'},
    );
    expect(find.text('Published valuation, fully explained'), findsOneWidget);
    expect(find.text('OPERATING JUDGMENT'), findsNothing);
  });

  testWidgets('refresh retains verified rows and the selected company', (
    t,
  ) async {
    final api = FundamentalApi();
    await mount(t, api);
    final detailReads = api.calls
        .where((x) => x.contains('/fundamentals/UBER?'))
        .length;
    api.pending = Completer<Map<String, dynamic>>();
    await t.enterText(find.byKey(const ValueKey('fundamental-search')), 'UBER');
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
    expect(find.text('OPERATING JUDGMENT'), findsOneWidget);
    expect(find.text('Updating results…'), findsOneWidget);
    api.pending!.complete({
      ...api.response('2026-09-21'),
      'lens': 'all',
      'rows': [api.row('UBER')],
    });
    await t.pumpAndSettle();
    expect(
      api.calls.where((x) => x.contains('/fundamentals/UBER?')).length,
      detailReads,
    );
    expect(find.text('Updating results…'), findsNothing);
  });

  testWidgets(
    'refresh failure preserves results with an explicit stale-query notice',
    (t) async {
      final api = FundamentalApi();
      await mount(t, api);
      api.fail = true;
      await t.enterText(
        find.byKey(const ValueKey('fundamental-search')),
        'MSFT',
      );
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
      expect(
        find.text('Results could not refresh. Showing your previous results.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('typing invalidates an older request before the debounce fires', (
    t,
  ) async {
    final api = FundamentalApi();
    await mount(t, api);
    api.delayedSearches['A'] = Completer<Map<String, dynamic>>();
    api.delayedSearches['AB'] = Completer<Map<String, dynamic>>();
    await t.enterText(find.byKey(const ValueKey('fundamental-search')), 'A');
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const ValueKey('fundamental-search')), 'AB');
    api.delayedSearches['A']!.complete({
      ...api.response('2026-09-21'),
      'rows': [api.row('STALE')],
    });
    await t.pump();
    expect(find.byKey(const ValueKey('fund-row-STALE')), findsNothing);
    expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
    await t.pump(const Duration(milliseconds: 300));
    api.delayedSearches['AB']!.complete({
      ...api.response('2026-09-21'),
      'rows': [api.row('AB')],
    });
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('fund-row-AB')), findsOneWidget);
  });

  testWidgets(
    'browse starts without a forced lens and keeps filters collapsed',
    (t) async {
      final api = FundamentalApi();
      await mount(t, api);
      final request = Uri.parse(
        api.calls.firstWhere(
          (x) => Uri.parse(x).path.endsWith('/fundamentals'),
        ),
      );
      expect(request.queryParameters['lens'], 'all');
      expect(request.queryParameters['sort'], 'recent');
      expect(request.queryParameters['limit'], '30');
      expect(find.byKey(const ValueKey('fund-filter-growth')), findsNothing);
      await tap(t, find.byKey(const ValueKey('fundamental-sort')));
      await tap(t, find.text('Revenue growth').last);
      expect(api.calls.any((x) => x.contains('sort=growth')), isTrue);
      expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
    },
  );

  testWidgets(
    'failed list preserves query and exposes independent company research',
    (t) async {
      final api = FundamentalApi()..fail = true;
      String? opened;
      await mount(
        t,
        api,
        selection: {'query': 'UBER'},
        onCompany: (ticker, section) => opened = '$ticker:$section',
      );
      expect(
        find.text('Financial data is temporarily unavailable.'),
        findsOneWidget,
      );
      await tap(t, find.text('Open in Research'));
      expect(opened, 'UBER:financials');
      api.fail = false;
      await tap(t, find.text('Try again'));
      expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
    },
  );

  testWidgets(
    'UBER path shows judgment, three changes, gap, chart and lineage',
    (t) async {
      await mount(t, FundamentalApi());
      expect(find.text('Find your next company to research.'), findsOneWidget);
      expect(find.byKey(const ValueKey('fund-filter-growth')), findsNothing);
      expect(find.byType(StockLogo), findsWidgets);
      expect(find.textContaining('Growth slowed -2.3pp'), findsWidgets);
      await tap(
        t,
        find.byKey(const ValueKey('fundamental-evidence-expansion')),
      );
      expect(find.text('Revenue growth slowed'), findsOneWidget);
      expect(find.text('Margin improved'), findsOneWidget);
      expect(find.text('FCF remained positive'), findsOneWidget);
      expect(find.text('Explanation gap'), findsOneWidget);
      await tap(t, find.text('Financials'));
      expect(find.text('Growth and operating conversion'), findsOneWidget);
      await tap(t, find.text('Business'));
      await tap(t, find.text('View sources'));
      expect(find.text('Reported fact lineage'), findsOneWidget);
      expect(find.textContaining('Sharadar SF1 ARQ'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'three evidence cards are directly adjustable and sent to the full-universe query',
    (t) async {
      final api = FundamentalApi();
      await mount(t, api);
      await tap(t, find.byKey(const ValueKey('fundamental-advanced')));
      final dropdown = find.descendant(
        of: find.byKey(const ValueKey('fund-filter-growth')),
        matching: find.byType(DropdownButton<double?>),
      );
      await t.tap(dropdown);
      await t.pumpAndSettle();
      await t.tap(find.text('10%').last);
      await t.pumpAndSettle();
      expect(
        api.calls.any((path) => path.contains('minRevenueGrowth=0.1')),
        true,
      );
      expect(
        find.byKey(const ValueKey('fundamental-clear-thresholds')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'valuation tab explains model components, weights, inputs and final result',
    (t) async {
      await mount(t, FundamentalApi());
      await tap(t, find.text('Valuation'));
      expect(find.text('Published valuation, fully explained'), findsOneWidget);
      expect(find.text('Normalized earnings power'), findsOneWidget);
      expect(find.text('Five-year FCFE DCF'), findsOneWidget);
      expect(find.text('Target P / E'), findsOneWidget);
      expect(find.text('Discount rate'), findsOneWidget);
      expect(find.text('Weighted component result'), findsOneWidget);
      expect(find.text('Price excluded'), findsOneWidget);
    },
  );

  testWidgets(
    '13F tab is lazy and shows histories plus changes worth researching',
    (t) async {
      final api = FundamentalApi();
      await mount(t, api);
      expect(
        api.calls.where((path) => path.contains('/13f-insights/')),
        isEmpty,
      );
      await tap(t, find.text('13F insights'));
      expect(
        api.calls.where((path) => path.contains('/13f-insights/')).length,
        1,
      );
      expect(find.text('Institution count history'), findsOneWidget);
      expect(find.text('Institutional ownership history'), findsOneWidget);
      expect(find.text('Changes worth researching'), findsOneWidget);
      expect(find.text('Fixture Capital'), findsOneWidget);
    },
  );

  testWidgets(
    'fact-only company is searchable and valuation remains optional',
    (t) async {
      final api = FundamentalApi();
      String? opened;
      await mount(
        t,
        api,
        onCompany: (ticker, section) => opened = '$ticker:$section',
      );
      await t.enterText(
        find.byKey(const ValueKey('fundamental-search')),
        'FACT',
      );
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fund-row-FACT')), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('fund-row-FACT')));
      expect(find.text('No valuation model'), findsOneWidget);
      expect(api.calls.any((path) => path.contains('search=FACT')), true);
      await tap(t, find.byKey(const ValueKey('fund-open-research')));
      expect(opened, 'FACT:financials');
    },
  );

  testWidgets('observation is saved with evidence and can be reviewed later', (
    t,
  ) async {
    final api = FundamentalApi();
    await mount(t, api);
    await tap(t, find.byKey(const ValueKey('fund-save-observation')));
    expect(
      find.byKey(const ValueKey('fund-review-observation')),
      findsOneWidget,
    );
    await tap(t, find.byKey(const ValueKey('fund-review-observation')));
    expect(find.text('Observation review'), findsOneWidget);
    expect(find.textContaining('New facts'), findsOneWidget);
  });

  for (final language in AppLanguage.values) {
    testWidgets('390px research flow is usable in $language', (t) async {
      await mount(t, FundamentalApi(), width: 390, language: language);
      await tap(t, find.byKey(const ValueKey('fund-row-UBER')));
      expect(
        find.text(language == AppLanguage.en ? 'OPERATING JUDGMENT' : '经营判断'),
        findsOneWidget,
      );
      await tap(
        t,
        find.text(language == AppLanguage.en ? 'Back to companies' : '返回公司列表'),
      );
      expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('cutoff mismatch and failures fail closed then retry', (t) async {
    final api = FundamentalApi()..wrongDate = true;
    await mount(t, api);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byKey(const ValueKey('fund-row-UBER')), findsNothing);
    api.wrongDate = false;
    await tap(t, find.text('Try again'));
    expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
  });
}
