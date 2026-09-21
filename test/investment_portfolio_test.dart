import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

// Isolated synthetic fixtures. Never installed in a running preview or API.
class PortfolioApi extends ApiClient {
  PortfolioApi() : super(() => 'fixture');
  bool fail = false, preview = false, wrong = false, partial = false;
  Completer<Map<String, dynamic>>? pending;
  final reads = <String>[];
  Map<String, dynamic> result(String asOf) => {
    'version': 'portfolio-research-v1',
    'asOf': wrong ? '1999-01-01' : asOf,
    'status': preview
        ? 'preview_account'
        : partial
        ? 'partial_accounts'
        : 'ready',
    'groups': preview ? [] : [group('USD'), group('EUR')],
  };
  Map<String, dynamic> group(String c) => {
    'currency': c,
    'accountCount': 1,
    'reportDates': ['2026-08-27'],
    'netValue': 3000,
    'cash': 500,
    'unpriced': 0,
    'top5Weight': 1,
    'shortValue': 0,
    'otherValue': 0,
    'reconciliation': 0,
    'coverage': {'count': 1, 'total': 2, 'weight': .4},
    'valuation': {
      'delta': 200,
      'netImpact': .2 / 3,
      'coveredMark': 1000,
      'coveredModel': 1200,
      'gap': .2,
      'markedRemainderValue': 3200,
    },
    'concentration': [
      {'ticker': 'AAA', 'weight': .4},
      {'ticker': 'BBB', 'weight': .6},
    ],
    'sectors': [
      {'name': 'Unclassified', 'weight': 1},
    ],
    'stress': [
      {'move': -.2, 'pnl': -500, 'netImpact': -1 / 6},
    ],
    'positions': [
      {
        'ticker': 'AAA',
        'name': 'Synthetic fixture only',
        'kind': 'equity',
        'value': 1000,
        'currency': c,
        'quantity': 10,
        'price': 100,
        'netWeight': 1 / 3,
        'modelGap': .2,
        'modelValue': 1200,
        'contribution': .2 / 3,
        'modelStatus': 'covered',
        'model': {
          'fairValue': 120,
          'currency': c,
          'date': '2026-07-20',
          'modelRoute': 'operating_company',
          'formula': '60% normalized earnings + 40% FCFE DCF',
        },
      },
      {
        'ticker': 'BBB',
        'name': 'Missing model fixture',
        'kind': 'equity',
        'value': 1500,
        'currency': c,
        'quantity': 30,
        'price': 50,
        'netWeight': .5,
        'modelStatus': 'no_model',
      },
    ],
    'comparisons': [
      for (final id in ['manager-a', 'manager-b'])
        {
          'guruId': id,
          'name': id == 'manager-a' ? 'Fixture Manager A' : 'Fixture Manager B',
          'avatar': '',
          'reportDate': '2026-06-30',
          'availableAt': '2026-08-14',
          'accession': 'fixture-accession',
          'complete': id == 'manager-a',
          'sharedCount': 1,
          'sharedUserWeight': .4,
          'overlap': id == 'manager-a' ? .3 : null,
          'differences': [
            {
              'ticker': 'AAA',
              'userWeight': .4,
              'guruWeight': id == 'manager-a' ? .3 : null,
              'difference': id == 'manager-a' ? .1 : null,
            },
          ],
        },
    ],
  };
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    reads.add(path);
    if (fail) throw StateError('offline');
    if (pending != null) {
      final p = pending!;
      pending = null;
      return p.future;
    }
    return result(Uri.parse(path).queryParameters['asOf']!);
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) => throw StateError('Portfolio read must not write');
}

Future<void> mount(
  WidgetTester t,
  PortfolioApi api, {
  Size size = const Size(1280, 950),
  AppLanguage lang = AppLanguage.en,
  double scale = 1,
  String date = '2026-08-28',
  void Function(String, String)? onCompany,
  void Function(String, String)? onGuru,
}) async {
  t.view.physicalSize = size;
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
              child: PortfolioResearchPanel(
                api: api,
                palette: Palette(false),
                asOf: date,
                onCompany: onCompany ?? (_, _) {},
                onGuru: onGuru ?? (_, _) {},
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
  testWidgets(
    'portfolio summary displays aggregate metrics, not decision positions',
    (t) async {
      final api = PortfolioApi();
      await mount(t, api);
      expect(find.text('Your portfolio. The whole picture.'), findsOneWidget);
      expect(find.textContaining('USD 3,000'), findsOneWidget);
      expect(find.text('40.0%'), findsWidgets);
      expect(find.text('Holdings & model structure'), findsOneWidget);
      expect(find.text('Model architecture'), findsOneWidget);
      expect(find.text('Current → model'), findsOneWidget);
      expect(api.reads.single, contains('/portfolio-analysis?asOf=2026-08-28'));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('development preview never falls back to sample holdings', (
    t,
  ) async {
    await mount(t, PortfolioApi()..preview = true);
    expect(
      find.text('This preview is not your online account.'),
      findsOneWidget,
    );
    expect(find.text('USD 3,000'), findsNothing);
    expect(find.text('AAA'), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'currency selector changes all report amounts without FX guessing',
    (t) async {
      await mount(t, PortfolioApi());
      await tap(t, find.text('EUR · 1 accounts'));
      expect(find.textContaining('EUR 3,000'), findsOneWidget);
      expect(find.textContaining('USD 3,000'), findsNothing);
    },
  );
  testWidgets('holdings search and valuation drill-down retain exact ticker', (
    t,
  ) async {
    final actions = <(String, String)>[];
    await mount(t, PortfolioApi(), onCompany: (a, b) => actions.add((a, b)));
    await tap(t, find.text('Holdings & value'));
    expect(find.text('No model at cutoff'), findsWidgets);
    await t.enterText(find.byType(TextField), 'AAA');
    await t.pumpAndSettle();
    expect(find.text('BBB'), findsNothing);
    await tap(t, find.text('Valuation →'));
    expect(actions, [('AAA', 'value')]);
    expect(t.takeException(), isNull);
  });
  testWidgets('Guru selection changes overlap and opens exact filing', (
    t,
  ) async {
    final actions = <(String, String)>[];
    await mount(t, PortfolioApi(), onGuru: (a, b) => actions.add((a, b)));
    await tap(t, find.text('Compare with Gurus'));
    expect(find.text('30.0%'), findsNWidgets(2));
    await tap(t, find.byType(DropdownButtonFormField<String>));
    await tap(t, find.text('Fixture Manager B').last);
    expect(
      find.text('Historical extract only · full-book overlap unavailable'),
      findsOneWidget,
    );
    expect(find.text('30.0%'), findsNothing);
    await tap(t, find.text('Open manager’s quarterly holdings →'));
    expect(actions, [('manager-b', 'fixture-accession')]);
    expect(t.takeException(), isNull);
  });
  testWidgets('offline state retries without showing stale values', (t) async {
    final api = PortfolioApi()..fail = true;
    await mount(t, api);
    expect(find.text('Portfolio could not be loaded'), findsOneWidget);
    api.fail = false;
    await tap(t, find.text('Try again'));
    expect(find.textContaining('USD 3,000'), findsOneWidget);
    expect(api.reads.length, 2);
  });
  testWidgets('wrong cutoff response is rejected', (t) async {
    await mount(t, PortfolioApi()..wrong = true);
    expect(find.text('Portfolio could not be loaded'), findsOneWidget);
    expect(find.textContaining('USD 3,000'), findsNothing);
  });
  testWidgets('partial account coverage has a visible warning', (t) async {
    await mount(t, PortfolioApi()..partial = true);
    expect(
      find.text(
        'Some accounts did not load · analysis covers returned accounts only',
      ),
      findsOneWidget,
    );
  });
  for (final lang in [AppLanguage.en, AppLanguage.zh]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('mobile ${lang.name} at $scale text scale all tabs fit', (
        t,
      ) async {
        await mount(
          t,
          PortfolioApi(),
          size: const Size(390, 844),
          lang: lang,
          scale: scale,
        );
        expect(t.takeException(), isNull);
        await tap(
          t,
          find.text(lang == AppLanguage.en ? 'Holdings & value' : '持仓与估值'),
        );
        expect(t.takeException(), isNull);
        await tap(
          t,
          find.text(lang == AppLanguage.en ? 'Compare with Gurus' : '对比大佬'),
        );
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets('old response cannot overwrite a new cutoff', (t) async {
    final api = PortfolioApi();
    final pending = Completer<Map<String, dynamic>>();
    api.pending = pending;
    // A pending linear indicator needs bounded pumps, not pumpAndSettle.
    t.view.physicalSize = const Size(1280, 950);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    Widget build(String date) => MaterialApp(
      home: LanguageScope(
        language: AppLanguage.en,
        child: Scaffold(
          body: SingleChildScrollView(
            child: PortfolioResearchPanel(
              api: api,
              palette: Palette(false),
              asOf: date,
              onCompany: (_, _) {},
              onGuru: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await t.pumpWidget(build('2026-08-28'));
    await t.pump();
    await t.pumpWidget(build('2026-08-27'));
    await t.pumpAndSettle();
    pending.complete(api.result('2026-08-28'));
    await t.pumpAndSettle();
    expect(find.textContaining('Research cutoff: 2026-08-27'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
