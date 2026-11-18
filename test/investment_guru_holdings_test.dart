import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_guru_study_test.dart' as study;

// Fixtures exercise the view contract; no example values ship in the product.
class HoldingsApi extends study.StudyApi {
  final paths = <String>[];
  bool badDate = false;
  bool partialQuarter = false;
  Completer<Map<String, dynamic>>? delayedHoldings;

  List<Map<String, dynamic>> get holdings => [
    for (var i = 0; i < 7; i++)
      {
        'ticker': i == 0 ? 'GOOGL' : 'STK$i',
        'name': 'Fixture Company $i',
        'managerCount': 7 - i,
        'adds': i == 1 ? 2 : 1,
        'trims': i == 2 ? 2 : (i == 0 ? 1 : 0),
        'price': {'value': 100, 'currency': 'USD', 'date': '2026-08-28'},
        'valuation': {'fairValue': 80, 'currency': 'USD', 'date': '2026-07-01'},
        'modelGap': -.2,
        'managers': [
          {
            'guruId': 'bill-ackman',
            'name': 'Bill Ackman',
            'shares': i == 2 ? 80 : 120,
            'weight': i == 0 ? .2 : (i == 1 ? .14 : .05),
            'action': i == 2 ? 'reduced' : 'increased',
            'previousShares': 100,
            'changeShares': i == 2 ? -20 : 20,
            'reportDate': '2026-06-30',
            'availableAt': '2026-08-14',
            'accession': 'bill-q2',
          },
          if (i == 0 || i == 2)
            {
              'guruId': 'li-lu',
              'name': 'Li Lu',
              'shares': 0,
              'weight': 0,
              'previousWeight': .06,
              'action': 'sold_out',
              'previousShares': 50,
              'changeShares': -50,
              'accession': 'li-q2',
            },
          if (i == 1)
            {
              'guruId': 'third',
              'name': 'Third Manager',
              'shares': 100,
              'weight': .12,
              'action': 'new',
              'previousShares': 0,
              'changeShares': 100,
              'reportDate': '2026-06-30',
              'availableAt': '2026-08-14',
              'accession': 'third-q2',
            },
        ],
      },
  ];

  List<Map<String, dynamic>> get partialQ3Holdings => [
    {
      'ticker': 'LRCX',
      'name': 'Lam Research Corp',
      'managerCount': 1,
      'adds': 1,
      'trims': 0,
      'managers': [
        {
          'guruId': 'third',
          'name': 'Third Manager',
          'shares': 200,
          'weight': .14,
          'action': 'increased',
          'previousShares': 150,
          'changeShares': 50,
          'reportDate': '2026-09-30',
          'availableAt': '2026-11-13',
          'accession': 'third-q3',
        },
      ],
    },
    {
      'ticker': 'AMZN',
      'name': 'Amazon.Com',
      'managerCount': 1,
      'adds': 0,
      'trims': 1,
      'managers': [
        {
          'guruId': 'third',
          'name': 'Third Manager',
          'shares': 80,
          'weight': .18,
          'action': 'reduced',
          'previousShares': 100,
          'changeShares': -20,
          'reportDate': '2026-09-30',
          'availableAt': '2026-11-13',
          'accession': 'third-q3',
        },
      ],
    },
  ];

  Map<String, dynamic> book(String date, String? requestedQuarter) {
    if (partialQuarter) {
      final q = requestedQuarter ?? '2026-09-30';
      final isQ3 = q == '2026-09-30';
      return {
        'asOf': badDate ? '2000-01-01' : date,
        'reportDate': q,
        'quarters': ['2026-09-30', '2026-06-30'],
        'quarterCounts': {'2026-09-30': 1, '2026-06-30': 3},
        'reportedGuruIds': isQ3
            ? ['third']
            : ['bill-ackman', 'li-lu', 'third'],
        'coverage': {
          'scope': 'full_current_books',
          'eligibleManagers': 3,
          'reportedManagers': isQ3 ? 1 : 3,
        },
        'gurus': gurus,
        'rows': isQ3 ? partialQ3Holdings : holdings,
      };
    }
    final q = requestedQuarter ?? '2026-06-30';
    return {
      'asOf': badDate ? '2000-01-01' : date,
      'reportDate': q,
      'quarters': ['2026-06-30', '2026-03-31'],
      'quarterCounts': {'2026-06-30': 3, '2026-03-31': 3},
      'reportedGuruIds': ['bill-ackman', 'li-lu', 'third'],
      'coverage': {
        'scope': 'full_current_books',
        'eligibleManagers': 3,
        'reportedManagers': 3,
      },
      'gurus': gurus,
      'rows': holdings,
    };
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    final u = Uri.parse(path);
    if (u.path.endsWith('/guru-holdings')) {
      if (delayedHoldings != null) return delayedHoldings!.future;
      if (this.fail) throw StateError('fixture');
      return book(u.queryParameters['asOf']!, u.queryParameters['quarter']);
    }
    if (u.path.contains('/opportunities/')) {
      return {
        'ticker': u.pathSegments.last,
        'asOf': u.queryParameters['asOf'],
        'price': {'value': 100, 'currency': 'USD', 'date': '2026-08-28'},
        'valuation': {'fairValue': 80, 'currency': 'USD', 'date': '2026-07-01'},
        'modelGap': -.2,
        'events': <Map<String, dynamic>>[],
      };
    }
    if (u.path.contains('/gurus/')) {
      return {
        'asOf': u.queryParameters['asOf'],
        'history': [
          {'reportDate': '2026-09-30', 'accessionNumber': 'exact-q3'},
          {'reportDate': '2026-06-30', 'accessionNumber': 'exact-q2'},
          {'reportDate': '2026-03-31', 'accessionNumber': 'exact-q1'},
        ],
      };
    }
    return super.getJson(path);
  }
}

Future<void> mount(
  WidgetTester t,
  HoldingsApi api, {
  double width = 1487,
  double scale = 1,
  bool desk = false,
  String date = '2026-08-28',
  AppLanguage lang = AppLanguage.en,
  void Function(String, String?)? explore,
  ValueChanged<String>? company,
  ValueChanged<Map<String, dynamic>>? selection,
  Map<String, dynamic> initialSelection = const {
    'selected': ['bill-ackman', 'li-lu', 'third'],
  },
}) async {
  t.view.physicalSize = Size(width, 1058);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: lang,
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: desk
                    ? GuruDiscoveryDesk(
                        api: api,
                        palette: Palette(false),
                        asOf: date,
                        gurus: api.gurus,
                        onExplore: explore ?? (_, _) {},
                        onCompany: company ?? (_) {},
                        onFollow: (_) async {},
                        onSelection: selection,
                      )
                    : GuruHoldingsMatrix(
                        api: api,
                        palette: Palette(false),
                        asOf: date,
                        gurus: api.gurus,
                        initialSelection: initialSelection,
                        onExplore: explore ?? (_, _) {},
                        onCompany: company ?? (_) {},
                        onStudy: () {},
                        onSelection: selection,
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'default scope renders partial Q3 disclosures without empty screen and switches to full Q2',
    (t) async {
      final api = HoldingsApi()..partialQuarter = true;
      await mount(t, api, desk: true, date: '2026-11-17');
      await t.pump(const Duration(milliseconds: 220));
      await t.pumpAndSettle();
      // Even though Bill Ackman & Li Lu have not filed Q3, Third Manager's Q3
      // disclosures render immediately in Concentrated Rankings.
      expect(find.text('No disclosed holdings match.'), findsNothing);
      expect(find.byKey(const ValueKey('matrix-stock-AMZN')), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-LRCX')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guru-switch-full-quarter')),
        findsOneWidget,
      );

      // Switch to Net Buying -> only LRCX (Net +1), not AMZN (Net -1)
      await study.tap(t, find.byKey(const ValueKey('guru-tab-net-adds')));
      expect(find.byKey(const ValueKey('matrix-stock-LRCX')), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-AMZN')), findsNothing);

      // Switch to Net Selling -> only AMZN (Net -1), not LRCX
      await study.tap(t, find.byKey(const ValueKey('guru-tab-net-trims')));
      expect(find.byKey(const ValueKey('matrix-stock-AMZN')), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-LRCX')), findsNothing);

      // One-click switch to full Q2 (3/3 Gurus)
      await study.tap(t, find.byKey(const ValueKey('guru-switch-full-quarter')));
      expect(api.paths.any((p) => p.contains('quarter=2026-06-30')), isTrue);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'concentrated, net buying and net selling leaderboards rank and filter accurately',
    (t) async {
      final api = HoldingsApi();
      await mount(
        t,
        api,
        initialSelection: const {},
        lang: AppLanguage.zh,
      );
      expect(find.text('集中仓位排行'), findsWidgets);
      expect(find.text('加仓排行（净加）'), findsWidgets);
      expect(find.text('净减仓排行'), findsWidgets);

      // STK1 has Bill Ackman (14%) + Third Manager (12%) = 26% sumWeight (#1)
      expect(find.byKey(const ValueKey('matrix-stock-STK1')), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsOneWidget);

      // Filter >= 2 Gurus -> only STK1 has 2 active holders
      await study.tap(t, find.byKey(const ValueKey('guru-multi-holder')));
      expect(find.byKey(const ValueKey('matrix-stock-STK1')), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsNothing);
      await study.tap(t, find.byKey(const ValueKey('guru-multi-holder')));

      // Net Buying (净加仓): GOOGL is 1 add / 1 exit (net 0) and STK2 is 2 trims (net -2),
      // so neither appears; STK1 is 2 adds / 0 trims (净 +2 位) -> #1!
      await study.tap(t, find.byKey(const ValueKey('guru-tab-net-adds')));
      expect(find.byKey(const ValueKey('matrix-stock-STK1')), findsOneWidget);
      expect(find.text('净 +2 位'), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsNothing);
      expect(find.byKey(const ValueKey('matrix-stock-STK2')), findsNothing);

      // Net Selling (净减仓): only STK2 has 2 trims / 0 adds (净 -2 位)
      await study.tap(t, find.byKey(const ValueKey('guru-tab-net-trims')));
      expect(find.byKey(const ValueKey('matrix-stock-STK2')), findsOneWidget);
      expect(find.text('净 -2 位'), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-STK1')), findsNothing);
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('restored company preview reloads at the current cutoff', (
    t,
  ) async {
    final api = HoldingsApi();
    const restored = {
      'selected': ['bill-ackman', 'li-lu', 'third'],
      'ticker': 'GOOGL',
      'quarter': '2026-06-30',
    };
    await mount(t, api, initialSelection: restored);
    await t.pump(const Duration(milliseconds: 220));
    await t.pumpAndSettle();
    expect(
      api.paths.where((p) => p.contains('/opportunities/GOOGL?')).toList(),
      ['/api/investment/opportunities/GOOGL?asOf=2026-08-28'],
    );
    expect(find.text('USD 100.00'), findsOneWidget);
    await mount(t, api, initialSelection: restored, date: '2026-08-29');
    await t.pump(const Duration(milliseconds: 220));
    await t.pumpAndSettle();
    expect(
      api.paths.where((p) => p.contains('/opportunities/GOOGL?')).toList(),
      [
        '/api/investment/opportunities/GOOGL?asOf=2026-08-28',
        '/api/investment/opportunities/GOOGL?asOf=2026-08-29',
      ],
    );
    await study.tap(t, find.text('Quarterly change'));
    expect(
      api.paths.where((p) => p.contains('/opportunities/GOOGL?')).length,
      2,
    );
    expect(api.posts, 0);
    expect(t.takeException(), isNull);
  });

  test(
    'combined filters use selected manager weights, net flow, and real change ratios',
    () {
      final rows = HoldingsApi().holdings;
      expect(
        filterGuruMatrix(rows, {'bill-ackman'}, concentrated: true).length,
        2,
      );
      expect(filterGuruMatrix(rows, {'li-lu'}, concentrated: true), isEmpty);
      expect(filterGuruMatrix(rows, {'third'}).single['ticker'], 'STK1');
      expect(
        filterGuruMatrix(rows, {'bill-ackman'}, query: 'stk2').single['ticker'],
        'STK2',
      );
      final allIds = {'bill-ackman', 'li-lu', 'third'};
      final netBuys = filterGuruMatrix(rows, allIds, board: 'net_adds');
      expect(netBuys.first['ticker'], 'STK1');
      expect(netBuys.any((r) => r['ticker'] == 'GOOGL'), isFalse);
      expect(netBuys.any((r) => r['ticker'] == 'STK2'), isFalse);
      final netSells = filterGuruMatrix(rows, allIds, board: 'net_trims');
      expect(netSells.map((r) => r['ticker']).toList(), ['STK2']);
      expect(
        guruShareChange({'previousShares': 100, 'changeShares': -100}),
        -1,
      );
      expect(
        guruShareChange({'previousShares': 0, 'changeShares': 100}),
        isNull,
      );
      expect(guruShareChange({'previousShares': 100}), isNull);
      expect(guruShareChange({'previousShares': 100, 'changeShares': 0}), 0);
    },
  );

  testWidgets(
    'matrix keeps unknown separate from exits and routes selected company',
    (t) async {
      final api = HoldingsApi();
      String? company;
      await mount(t, api, company: (s) => company = s);
      expect(find.text('View filing'), findsWidgets);
      expect(find.text('Exited'), findsWidgets);
      expect(find.text('20.00%'), findsWidgets);
      await study.tap(t, find.byKey(const ValueKey('matrix-stock-STK1')));
      await study.tap(t, find.byKey(const ValueKey('matrix-research')));
      expect(company, 'STK1');
      expect(api.posts, 0);
      expect(api.paths.any((p) => p.contains('/guru-holdings?')), isTrue);
      expect(api.paths.any((p) => p.contains('/opportunities/GOOGL?')), isTrue);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'quarter selector, header portrait and unknown cell route exact filing',
    (t) async {
      final api = HoldingsApi();
      final opened = <String?>[];
      await mount(t, api, explore: (id, filing) => opened.add(filing));
      await study.tap(
        t,
        find.byKey(const ValueKey('matrix-quarter-2026-06-30')),
      );
      await study.tap(t, find.textContaining('2026 Q1 (2026-03-31)').last);
      expect(api.paths.any((p) => p.contains('quarter=2026-03-31')), isTrue);
      await study.tap(
        t,
        find.byKey(const ValueKey('matrix-header-portrait-bill-ackman')),
      );
      expect(opened.last, 'exact-q1');
      await study.tap(t, find.byKey(const ValueKey('matrix-cell-GOOGL-third')));
      expect(opened.last, 'exact-q1');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'weight and quarterly change controls plus concentration are live',
    (t) async {
      final api = HoldingsApi();
      Map<String, dynamic>? saved;
      await mount(t, api, selection: (s) => saved = s);
      await study.tap(t, find.text('Quarterly change'));
      expect(find.text('+20.00%'), findsWidgets);
      await study.tap(t, find.byKey(const ValueKey('matrix-concentrated')));
      expect(find.byKey(const ValueKey('matrix-stock-STK3')), findsNothing);
      expect(saved?['concentrated'], true);
      expect(saved?['mode'], 'change');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('capital structure filter scopes active Gurus and is persisted', (
    t,
  ) async {
    final api = HoldingsApi();
    Map<String, dynamic>? saved;
    await mount(t, api, selection: (value) => saved = value);
    await study.tap(t, find.byKey(const ValueKey('guru-filter-toggle')));
    await study.tap(t, find.text('All structures'));
    await study.tap(t, find.text('Permanent capital').last);
    expect(find.byKey(const ValueKey('matrix-portrait-third')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('matrix-portrait-bill-ackman')),
      findsNothing,
    );
    expect(saved?['capitalFilter'], 'permanent');
    expect(t.takeException(), isNull);
  });

  for (final size in [(390.0, 1.0), (1280.0, 1.0), (390.0, 1.5)]) {
    testWidgets('responsive layout ${size.$1} scale ${size.$2}', (t) async {
      await mount(t, HoldingsApi(), width: size.$1, scale: size.$2);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('English and Chinese views localize fixed copy', (t) async {
    await mount(t, HoldingsApi(), initialSelection: const {});
    final strings = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join();
    expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(strings), isFalse);
    await mount(
      t,
      HoldingsApi(),
      initialSelection: const {},
      lang: AppLanguage.zh,
    );
    expect(find.text('投资大师集中持仓与净调仓排行'), findsOneWidget);
    expect(find.text('集中仓位排行'), findsWidgets);
    expect(find.text('加仓排行（净加）'), findsWidgets);
    expect(find.text('净减仓排行'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('methodology tooltip explains book weights and delayed 13F scope', (
    t,
  ) async {
    await mount(t, HoldingsApi(), initialSelection: const {});
    expect(find.text('Guru conviction & net flow rankings'), findsOneWidget);
    expect(
      find.textContaining('Book weights reflect reported Form 13F common-long'),
      findsOneWidget,
    );
    await study.tap(t, find.bySemanticsLabel('How to read consensus holdings'));
    expect(
      find.textContaining('not total fund assets'),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('mismatched source date blocks rows and offers retry', (t) async {
    final api = HoldingsApi()..badDate = true;
    await mount(t, api);
    expect(find.text('Could not load this quarter.'), findsOneWidget);
    expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsNothing);
    api.badDate = false;
    await study.tap(t, find.text('Retry disclosures'));
    expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsOneWidget);
  });

  testWidgets('composed desk retains leaderboards, lazy study and all profiles', (
    t,
  ) async {
    final api = HoldingsApi();
    await mount(t, api, desk: true);
    expect(find.byType(GuruHoldingsMatrix), findsOneWidget);
    expect(find.byType(GuruStudyPanel), findsNothing);
    expect(find.text('Load comparison'), findsOneWidget);
    expect(api.paths.where((path) => path.contains('/guru-study')), isEmpty);
    expect(find.text('Concentrated Rankings'), findsOneWidget);
    expect(find.text('Net Buying'), findsOneWidget);
    expect(find.text('Net Selling'), findsOneWidget);
    await study.tap(t, find.byKey(const ValueKey('matrix-study-link')));
    expect(find.byType(GuruStudyPanel), findsOneWidget);
    expect(find.text('Turnover vs annualized return'), findsOneWidget);
    expect(find.text('Turnover vs Sharpe'), findsOneWidget);
    expect(api.paths.any((path) => path.contains('/guru-study')), isTrue);
    expect(api.posts, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'chart and directory selection still sync without replacing ranking filters',
    (t) async {
      Map<String, dynamic>? saved;
      await mount(t, HoldingsApi(), desk: true, selection: (v) => saved = v);
      await study.tap(t, find.byKey(const ValueKey('matrix-concentrated')));
      await study.tap(t, find.byKey(const ValueKey('matrix-study-link')));
      await study.tap(t, find.byKey(const ValueKey('study-point-cagr-third')));
      expect(saved?['inspecting'], 'third');
      expect((saved?['holdings'] as Map?)?['concentrated'], true);
      expect(find.text("Study Third Manager's decisions"), findsOneWidget);
      await study.tap(
        t,
        find.byKey(const ValueKey('guru-directory-person-li-lu')),
      );
      expect(saved?['inspecting'], 'li-lu');
      expect((saved?['holdings'] as Map?)?['concentrated'], true);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'selection drawer, stock pagination and empty state never synthesize positions',
    (t) async {
      await mount(t, HoldingsApi());
      await study.tap(t, find.byTooltip('Next stocks'));
      expect(find.byKey(const ValueKey('matrix-stock-STK6')), findsOneWidget);
      await study.tap(t, find.byTooltip('Previous stocks'));
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsOneWidget);
      await study.tap(t, find.byKey(const ValueKey('guru-filter-toggle')));
      await study.tap(t, find.text('Clear'));
      expect(find.text('Choose Gurus to compare'), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsNothing);
      await study.tap(t, find.text('Select all'));
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
