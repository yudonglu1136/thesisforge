import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_guru_study_test.dart' as study;

// Fixtures exercise the view contract; no example values ship in the product.
class HoldingsApi extends study.StudyApi {
  final paths = <String>[];
  bool badDate = false;
  Completer<Map<String, dynamic>>? delayedHoldings;
  List<Map<String, dynamic>> get holdings => [
    for (var i = 0; i < 7; i++)
      {
        'ticker': i == 0 ? 'GOOGL' : 'STK$i',
        'name': 'Fixture Company $i',
        'managerCount': 7 - i,
        'adds': 1,
        'trims': 1,
        'price': {'value': 100, 'currency': 'USD', 'date': '2026-08-28'},
        'valuation': {'fairValue': 80, 'currency': 'USD', 'date': '2026-07-01'},
        'modelGap': -.2,
        'managers': [
          {
            'guruId': 'bill-ackman',
            'name': 'Bill Ackman',
            'weight': i == 0 ? .2 : .05,
            'action': 'increased',
            'previousShares': 100,
            'changeShares': 20,
            'reportDate': '2026-06-30',
            'availableAt': '2026-08-14',
            'accession': 'bill-q2',
          },
          if (i == 0)
            {
              'guruId': 'li-lu',
              'name': 'Li Lu',
              'weight': 0,
              'action': 'sold_out',
              'previousShares': 50,
              'changeShares': -50,
              'accession': 'li-q2',
            },
        ],
      },
  ];
  Map<String, dynamic> book(String date, String q) => {
    'asOf': badDate ? '2000-01-01' : date,
    'reportDate': q,
    'quarters': ['2026-06-30', '2026-03-31'],
    'coverage': {'scope': 'full_current_books', 'reportedManagers': 3},
    'rows': holdings,
  };
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    final u = Uri.parse(path);
    if (u.path.endsWith('/guru-holdings')) {
      if (delayedHoldings != null) return delayedHoldings!.future;
      if (this.fail) throw StateError('fixture');
      return book(
        u.queryParameters['asOf']!,
        u.queryParameters['quarter'] ?? '2026-06-30',
      );
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
                        initialSelection: const {
                          'selected': ['bill-ackman', 'li-lu', 'third'],
                        },
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
  test(
    'combined filters use selected manager weights and real change ratios',
    () {
      final rows = HoldingsApi().holdings;
      expect(
        filterGuruMatrix(rows, {'bill-ackman'}, concentrated: true).length,
        1,
      );
      expect(filterGuruMatrix(rows, {'li-lu'}, concentrated: true), isEmpty);
      expect(filterGuruMatrix(rows, {'third'}), isEmpty);
      expect(
        filterGuruMatrix(rows, {'bill-ackman'}, query: 'stk2').single['ticker'],
        'STK2',
      );
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
    'quarter selector, portrait and unknown cell route exact filing',
    (t) async {
      final api = HoldingsApi();
      final opened = <String?>[];
      await mount(t, api, explore: (id, filing) => opened.add(filing));
      await study.tap(
        t,
        find.byKey(const ValueKey('matrix-quarter-2026-06-30')),
      );
      await study.tap(t, find.text('2026 Q1 (2026-03-31)').last);
      expect(api.paths.any((p) => p.contains('quarter=2026-03-31')), isTrue);
      await study.tap(
        t,
        find.byKey(const ValueKey('matrix-portrait-bill-ackman')),
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
      expect(find.byKey(const ValueKey('matrix-stock-STK1')), findsNothing);
      expect(saved?['concentrated'], true);
      expect(saved?['mode'], 'change');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('capital structure filter is conservative and persisted', (
    t,
  ) async {
    final api = HoldingsApi();
    Map<String, dynamic>? saved;
    await mount(t, api, selection: (value) => saved = value);
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
    });
  }

  testWidgets('English and Chinese views localize fixed copy', (t) async {
    await mount(t, HoldingsApi());
    final strings = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join();
    expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(strings), isFalse);
    await mount(t, HoldingsApi(), lang: AppLanguage.zh);
    expect(find.text('持仓权重'), findsOneWidget);
    expect(find.text('共识持仓 = 多位 Guru 共同持有'), findsOneWidget);
    expect(find.text('该季度全部已披露 Guru'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('consensus explains overlap, weight and global count scope', (
    t,
  ) async {
    await mount(t, HoldingsApi());
    expect(find.text('Consensus = shared holdings'), findsOneWidget);
    expect(find.text('Consensus'), findsOneWidget);
    expect(find.text('All reporting Gurus · this quarter'), findsOneWidget);
    expect(
      find.textContaining(
        'Overlap is not unanimous conviction or a buy signal',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Consensus counts cover all reporting Gurus, not just those selected',
      ),
      findsOneWidget,
    );
    await study.tap(t, find.bySemanticsLabel('How to read consensus holdings'));
    expect(
      find.textContaining('not a combined portfolio or total fund assets'),
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

  testWidgets('composed desk retains both charts shortlist and all profiles', (
    t,
  ) async {
    final api = HoldingsApi();
    await mount(t, api, desk: true);
    expect(find.byType(GuruHoldingsMatrix), findsOneWidget);
    expect(find.byType(GuruStudyPanel), findsOneWidget);
    expect(find.text('Turnover vs annualized return'), findsOneWidget);
    expect(find.text('Turnover vs Sharpe'), findsOneWidget);
    expect(find.text('All Gurus'), findsOneWidget);
    expect(find.text('Consensus'), findsOneWidget);
    await study.tap(t, find.byKey(const ValueKey('matrix-study-link')));
    expect(api.posts, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'chart and directory selection still sync without replacing matrix filters',
    (t) async {
      Map<String, dynamic>? saved;
      await mount(t, HoldingsApi(), desk: true, selection: (v) => saved = v);
      await study.tap(t, find.byKey(const ValueKey('matrix-concentrated')));
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
    'selection, stock pagination and empty state never synthesize positions',
    (t) async {
      await mount(t, HoldingsApi());
      await study.tap(t, find.byTooltip('Next stocks'));
      expect(find.byKey(const ValueKey('matrix-stock-STK6')), findsOneWidget);
      await study.tap(t, find.byTooltip('Previous stocks'));
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsOneWidget);
      await study.tap(t, find.text('Clear', skipOffstage: false));
      expect(find.text('Choose Gurus to compare'), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsNothing);
      await study.tap(t, find.text('Select all'));
      expect(find.byKey(const ValueKey('matrix-stock-GOOGL')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
