import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

// Synthetic test data only. The shipped page reads authenticated source data.
class StudyApi extends ApiClient {
  StudyApi() : super(() => 'test');
  bool fail = false, mismatch = false, omitFourth = false;
  int posts = 0;
  Completer<Map<String, dynamic>>? pending;
  final gurus = [
    for (final x in [
      ('bill-ackman', 'Bill Ackman'),
      ('li-lu', 'Li Lu'),
      ('third', 'Third Manager'),
      ('fourth', 'Fourth Manager'),
    ])
      {
        'id': x.$1,
        'name': x.$2,
        'entityName': 'Fixture Management',
        'followed': false,
        'capitalStructure': {
          'category': x.$1 == 'third'
              ? 'permanent'
              : x.$1 == 'fourth'
              ? 'owner_controlled'
              : x.$1 == 'bill-ackman'
              ? 'mixed'
              : 'external_client',
          'label': x.$1 == 'third'
              ? 'Permanent capital'
              : x.$1 == 'fourth'
              ? 'Owner / family capital'
              : x.$1 == 'bill-ackman'
              ? 'Mixed capital'
              : 'External / client capital',
          'labelZh': x.$1 == 'third'
              ? '永续资本'
              : x.$1 == 'fourth'
              ? '所有者 / 家族资本'
              : x.$1 == 'bill-ackman'
              ? '混合资本'
              : '外部 / 客户资本',
          'detail': 'Fixture capital structure.',
          'detailZh': '测试资本结构。',
        },
      },
  ];
  Map<String, dynamic> response(String date, String period) => {
    'asOf': date,
    'period': period,
    'range': {'start': '2023-01-01', 'end': date, 'years': 3.0},
    'benchmark': {'cagr': .17, 'sharpe': 1.0},
    'unavailable': [],
    'rows': [
      for (var i = 0; i < gurus.length; i++)
        if (!omitFourth || i != 3)
          {
            ...gurus[i],
            'basis': i == 3 ? 'proxy' : 'strict',
            'annualTurnover': .2 + i * .25,
            'cagr': (period == '1Y' ? .2 : .1) + i * .08,
            'sharpe': .6 + i * .3,
          },
    ],
  };
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final u = Uri.parse(path), date = u.queryParameters['asOf']!;
    if (path.contains('/guru-study')) {
      if (pending != null) return pending!.future;
      if (fail) throw StateError('fixture failure');
      return response(
        mismatch ? '2000-01-01' : date,
        u.queryParameters['period']!,
      );
    }
    if (path.contains('/backtest?')) {
      final id = u.pathSegments[u.pathSegments.length - 2];
      return {
        'status': 'ready',
        'guru': {'id': id},
        'method': {'years': 5, 'benchmark': 'SPY'},
        'window': {'start': '2023-01-03', 'end': date},
        'summary': {
          'totalReturn': .24,
          'cagr': .08,
          'sharpe': .7,
          'maxDrawdown': -.12,
          'benchmark': {'totalReturn': .2, 'cagr': .07},
        },
        'equity': [
          {'date': '2023-01-03', 'value': 1.0, 'benchmark': 1.0},
          {'date': date, 'value': 1.24, 'benchmark': 1.2},
        ],
      };
    }
    final id = u.pathSegments.last;
    return {
      'asOf': date,
      'guru': {'id': id},
      'history': [
        for (var i = 1; i <= 3; i++)
          {
            'accessionNumber': '$id-$i',
            'reportDate': '2025-0${i * 3}-30',
            'quarter': '2025 Q$i',
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    posts++;
    return {};
  }
}

Future<void> mount(
  WidgetTester t,
  StudyApi api, {
  double width = 1223,
  double scale = 1,
  AppLanguage lang = AppLanguage.en,
  void Function(String, String?)? explore,
  ValueChanged<Map<String, dynamic>>? selection,
  Map<String, dynamic> initialSelection = const {},
}) async {
  t.view.physicalSize = Size(width, 1100);
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
                child: GuruStudyPanel(
                  api: api,
                  palette: Palette(false),
                  asOf: '2026-08-28',
                  gurus: api.gurus,
                  onExplore: explore ?? (_, _) {},
                  onSelection: selection,
                  initialSelection: initialSelection,
                  onFollow: (g) => api.postJson('/api/investment/follows', g),
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

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  test(
    'filters preserve missing values and combine without changing metrics',
    () {
      final rows = List<Map<String, dynamic>>.from(
        StudyApi().response('2026-08-28', 'common')['rows'],
      );
      expect(filterGuruStudy(rows, maxTurnover: .5).length, 2);
      expect(filterGuruStudy(rows, minSharpe: 1).length, 2);
      expect(
        filterGuruStudy(rows, method: 'proxy', minSharpe: 1).single['id'],
        'fourth',
      );
      expect(
        filterGuruStudy([
          {...rows.first, 'sharpe': null},
        ], minSharpe: 0),
        isEmpty,
      );
      expect(filterGuruStudy(rows, query: 'fixture').length, 4);
      expect(filterGuruStudy(rows, followed: {'li-lu'}).single['id'], 'li-lu');
    },
  );
  test(
    'scatter domains include outliers, negatives, benchmark and share X',
    () {
      final rows = [
        {'annualTurnover': 2.5, 'cagr': -.3, 'sharpe': -.8},
        {'annualTurnover': .1, 'cagr': .7, 'sharpe': 2.1},
      ];
      final a = GuruScatterScale(rows, 'cagr', .2),
          b = GuruScatterScale(rows, 'sharpe', 3);
      expect(a.xMax, b.xMax);
      expect(a.xMax, greaterThanOrEqualTo(250));
      expect(a.yMin, lessThanOrEqualTo(-30));
      expect(b.yMax, greaterThanOrEqualTo(3));
    },
  );
  testWidgets(
    'two charts, actual metrics, selected manager and exact quarter route',
    (t) async {
      String? id, quarter;
      await mount(
        t,
        StudyApi(),
        explore: (a, b) {
          id = a;
          quarter = b;
        },
      );
      expect(find.byType(GuruStudyScatter), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('guru-directory-simulation-bill-ackman')),
        findsOneWidget,
      );
      expect(find.text('Portfolio vs SPY'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('study-point-sharpe-li-lu')));
      expect(
        find.byKey(const ValueKey('guru-directory-simulation-li-lu')),
        findsOneWidget,
      );
      expect(find.text("Study Li Lu's decisions"), findsOneWidget);
      await tap(t, find.text('2025 Q2').last);
      await tap(t, find.text('Explore quarterly holdings'));
      expect(id, 'li-lu');
      expect(quarter, 'li-lu-2');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('shortlist limit, removal, no silent strategy writes', (t) async {
    final api = StudyApi();
    Map<String, dynamic>? selection;
    await mount(t, api, selection: (v) => selection = v);
    await tap(t, find.byKey(const ValueKey('guru-directory-compare-third')));
    expect(selection!['shortlist'], hasLength(3));
    await tap(t, find.byKey(const ValueKey('study-point-cagr-fourth')));
    expect(selection!['shortlist'], hasLength(3));
    expect(selection!['inspecting'], 'fourth');
    expect(find.text("Study Fourth Manager's decisions"), findsOneWidget);
    expect(find.textContaining('Remove one to add'), findsNothing);
    await tap(t, find.byKey(const ValueKey('guru-directory-compare-fourth')));
    expect(find.textContaining('Remove one to add'), findsOneWidget);
    await tap(t, find.byTooltip('Remove Bill Ackman'));
    await tap(t, find.byKey(const ValueKey('guru-directory-compare-fourth')));
    expect(selection!['inspecting'], 'fourth');
    expect(selection!['shortlist'], ['li-lu', 'third', 'fourth']);
    expect(api.posts, 0);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'all portraits, bidirectional chart selection and direct holdings',
    (t) async {
      final api = StudyApi();
      String? opened;
      await mount(t, api, explore: (id, _) => opened = id);
      expect(find.text('4 / 4 managers'), findsOneWidget);
      for (final g in api.gurus) {
        expect(
          find.byKey(ValueKey('guru-directory-person-${g['id']}')),
          findsOneWidget,
        );
      }
      await tap(t, find.byKey(const ValueKey('guru-directory-person-fourth')));
      for (final chart in t.widgetList<GuruStudyScatter>(
        find.byType(GuruStudyScatter),
      )) {
        expect(chart.inspecting, 'fourth');
        expect(chart.shortlist, ['bill-ackman', 'li-lu']);
      }
      expect(find.text("Study Fourth Manager's decisions"), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('study-point-sharpe-third')));
      expect(find.text("Study Third Manager's decisions"), findsOneWidget);
      final selected = t.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('guru-directory-person-third')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(selected.properties.selected, true);
      await tap(t, find.byKey(const ValueKey('guru-directory-holdings-third')));
      expect(opened, 'third');
      expect(api.posts, 0);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'catalog-only manager remains visible and inspection survives period changes',
    (t) async {
      final api = StudyApi()..omitFourth = true;
      Map<String, dynamic>? selection;
      await mount(t, api, selection: (v) => selection = v);
      expect(find.text('4 / 4 managers'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('study-point-cagr-fourth')),
        findsNothing,
      );
      await tap(t, find.byKey(const ValueKey('guru-directory-person-fourth')));
      expect(
        find.text('Inspecting · no comparable chart point'),
        findsOneWidget,
      );
      expect(find.text("Study Fourth Manager's decisions"), findsOneWidget);
      await tap(t, find.text('1Y'));
      expect(selection!['inspecting'], 'fourth');
      expect(find.text('20.00%'), findsWidgets);
      expect(find.text("Study Fourth Manager's decisions"), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.enterText(find.byType(TextField).last, 'Fourth');
      await t.pumpAndSettle();
      expect(
        find.text('These managers have no comparable chart points.'),
        findsOneWidget,
      );
      expect(find.text('1 / 4 managers'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guru-directory-person-fourth')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'directory sort, shared filters, reset and restored independent inspection',
    (t) async {
      await mount(
        t,
        StudyApi(),
        initialSelection: {
          'shortlist': ['bill-ackman', 'li-lu', 'third'],
          'inspecting': 'fourth',
        },
      );
      expect(find.text("Study Fourth Manager's decisions"), findsOneWidget);
      await tap(t, find.text('Turnover: low to high'));
      await tap(t, find.text('CAGR: high to low').last);
      expect(
        t
            .getTopLeft(
              find.byKey(const ValueKey('guru-directory-person-fourth')),
            )
            .dy,
        lessThan(
          t
              .getTopLeft(
                find.byKey(const ValueKey('guru-directory-person-bill-ackman')),
              )
              .dy,
        ),
      );
      await t.enterText(find.byType(TextField).last, 'Li Lu');
      await t.pumpAndSettle();
      expect(find.text('1 / 4 managers'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guru-directory-person-fourth')),
        findsNothing,
      );
      for (final c in t.widgetList<GuruStudyScatter>(
        find.byType(GuruStudyScatter),
      )) {
        expect(c.rows.single['id'], 'li-lu');
      }
      await tap(t, find.text('Show all Gurus'));
      expect(find.text('4 / 4 managers'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('search and filter clear, no result state and period updates', (
    t,
  ) async {
    await mount(t, StudyApi());
    await t.enterText(find.byType(TextField).first, 'no match');
    await t.pumpAndSettle();
    expect(find.text('No managers match these filters.'), findsOneWidget);
    await tap(t, find.text('Clear filters'));
    expect(find.byType(GuruStudyScatter), findsNWidgets(2));
    await tap(t, find.text('1Y'));
    expect(find.text('Trailing 1 year'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('error and incorrect-cutoff responses cannot display charts', (
    t,
  ) async {
    final api = StudyApi()..fail = true;
    await mount(t, api);
    expect(find.byType(GuruStudyScatter), findsNothing);
    api.fail = false;
    api.mismatch = true;
    await tap(t, find.text('Retry comparison'));
    expect(find.byType(GuruStudyScatter), findsNothing);
    api.mismatch = false;
    await tap(t, find.text('Retry comparison'));
    expect(find.byType(GuruStudyScatter), findsNWidgets(2));
    expect(t.takeException(), isNull);
  });
  testWidgets('late period response cannot replace the newer comparison', (
    t,
  ) async {
    final api = StudyApi();
    await mount(t, api);
    final older = Completer<Map<String, dynamic>>();
    api.pending = older;
    await t.ensureVisible(find.text('1Y'));
    await t.tap(find.text('1Y'));
    await t.pump();
    expect(find.byType(GuruStudyScatter), findsNothing);
    api.pending = null;
    await tap(t, find.text('3Y'));
    expect(find.text('Trailing 3 years'), findsOneWidget);
    expect(find.byType(GuruStudyScatter), findsNWidgets(2));
    older.complete(api.response('2026-08-28', '1Y'));
    await t.pumpAndSettle();
    expect(find.text('Trailing 3 years'), findsOneWidget);
    expect(find.byType(GuruStudyScatter), findsNWidgets(2));
    expect(t.takeException(), isNull);
  });
  for (final width in [390.0, 1000.0, 1223.0]) {
    for (final lang in AppLanguage.values) {
      testWidgets('layout $width $lang and larger text', (t) async {
        await mount(
          t,
          StudyApi(),
          width: width,
          lang: lang,
          scale: width == 390 ? 1.5 : 1,
        );
        expect(t.takeException(), isNull);
        await tap(
          t,
          find.byKey(const ValueKey('guru-directory-person-fourth')),
        );
        expect(
          find.byKey(const ValueKey('guru-directory-holdings-fourth')),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
        await tap(
          t,
          find.text(lang == AppLanguage.en ? 'More filters' : '更多筛选'),
        );
        expect(t.takeException(), isNull);
        await tap(t, find.text(lang == AppLanguage.en ? 'Add a Guru' : '添加经理'));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  }
}
