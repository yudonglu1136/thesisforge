import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

// Synthetic test-only data, never loaded into the local preview/source DB.
class StrategyApi extends ApiClient {
  StrategyApi() : super(() => 'fixture');
  final posts = <Map<String, dynamic>>[];
  String failureCode = '';
  bool fail = false, wrong = false, blocked = false;
  bool historyBoundary = false;
  Map<String, dynamic>? failureOverride;
  Completer<Map<String, dynamic>>? pending;
  Map<String, dynamic> response(Map<String, dynamic> rules) => {
    'version': 'guru-valuation-cta-v1',
    'rules': {...rules, 'costBps': (rules['costBps'] as num).toInt()},
    'status': blocked ? 'blocked' : 'ready',
    'ruleHash': 'test-fixture-fingerprint',
    'failure':
        failureOverride ??
        (historyBoundary
            ? {
                'code': 'manager_history_unavailable',
                'guruId': 'bill-ackman',
                'date': '2021-08-30',
                'firstStoredPublicDate': '2022-02-14',
              }
            : blocked
            ? {
                'code': 'cta_history_missing',
                'ticker': 'KMLM',
                'date': '2026-08-01',
              }
            : null),
    'results': {
      for (final name in ['guru', 'filtered', 'blend', 'spy'])
        name: blocked && name == 'blend'
            ? {'status': 'blocked'}
            : {
                'status': 'ready',
                'equity': [
                  for (var i = 0; i < 25; i++)
                    {
                      'date': '2026-08-${(i + 1).toString().padLeft(2, '0')}',
                      'value': .999 + i * (name == 'blend' ? .005 : .002),
                    },
                ],
              },
    },
    'ledger': [event(rules)],
    'holdingSnapshots': blocked
        ? []
        : [
            for (final i in [0, 1])
              {
                'date': i == 0 ? '2026-08-01' : '2026-08-14',
                'decisionDate': i == 0 ? '2026-07-31' : '2026-08-13',
                'nextRebalanceDate': i == 0 ? '2026-08-14' : null,
                'throughDate': i == 0 ? '2026-08-14' : '2026-08-28',
                'cashWeight': 0,
                'stockWeight': 1 - (rules['ctaWeight'] as num),
                'ctaWeight': rules['ctaWeight'],
                'leverage': 1.0,
                'borrowedWeight': 0,
                'positions': [
                  {
                    'ticker': i == 0 ? 'AAA' : 'CCC',
                    'issuer': 'Fixture company',
                    'kind': 'stock',
                    'weight': 1 - (rules['ctaWeight'] as num),
                    'managers': ['bill-ackman'],
                  },
                  if ((rules['ctaWeight'] as num) > 0)
                    {
                      'ticker': rules['cta'],
                      'kind': 'cta',
                      'weight': rules['ctaWeight'],
                      'managers': [],
                    },
                ],
                'managerExclusions': [
                  {
                    'guruId': 'warren-buffett',
                    'code': 'manager_history_unavailable',
                    'firstStoredPublicDate': '2026-08-15',
                  },
                ],
                'exclusions': [
                  if (i == 0)
                    {'ticker': 'BBB', 'status': 'no_model', 'targetWeight': 0}
                  else
                    {
                      'ticker': 'DDD',
                      'status': 'expensive',
                      'targetWeight': 0,
                      'price': 135,
                      'fairValue': 100,
                      'premium': .35,
                      'priceDate': '2026-08-13',
                      'modelDate': '2026-07-20',
                    },
                ],
                'filings': event(rules)['filings'],
              },
          ],
    'summary': {
      'minModelCoverage': .5,
      'latest': event(rules),
      'rebalances': 1,
    },
  };
  Map<String, dynamic> event(Map<String, dynamic> rules) => {
    'executionDate': '2026-08-01',
    'decisionDate': '2026-07-31',
    'cashWeight': rules['excludedAllocation'] == 'fully_invested'
        ? 0
        : (1 - (rules['ctaWeight'] as num)) / 2,
    'ctaWeight': rules['ctaWeight'],
    'filings': [
      {
        'guruId': 'bill-ackman',
        'reportDate': '2026-06-30',
        'publicDate': '2026-07-30',
      },
    ],
    'holdings': [
      {
        'ticker': 'AAA',
        'targetWeight':
            (1 - (rules['ctaWeight'] as num)) /
            (rules['excludedAllocation'] == 'fully_invested' ? 1 : 2),
        'status': 'included',
        'price': 100,
        'fairValue': 110,
        'premium': -1 / 11,
        'modelDate': '2026-07-20',
      },
      {'ticker': 'BBB', 'targetWeight': 0, 'status': 'no_model'},
    ],
  };
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (fail) throw StateError('offline');
    return {
      'version': 'strategy-lab-catalog-v1',
      'asOf': Uri.parse(path).queryParameters['asOf'],
      'storage': {'cutoff': '2026-08-28'},
      'managers': [
        {
          'id': 'bill-ackman',
          'name': 'Fixture Manager',
          'quarters': 20,
          'avatar': '',
        },
        {
          'id': 'warren-buffett',
          'name': 'Second Manager',
          'quarters': 60,
          'avatar': '',
        },
      ],
      'etfs': [
        for (final s in ['KMLM', 'DBMF'])
          {
            'ticker': s,
            'available': true,
            'first': '2020-12-02',
            'last': '2026-08-28',
          },
      ],
      'saved': [],
    };
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    posts.add({'path': path, ...body});
    if (failureCode.isNotEmpty) {
      throw ApiRequestException(
        statusCode: 422,
        message: failureCode,
        code: failureCode,
      );
    }
    if (fail) throw StateError('offline');
    if (path.endsWith('strategy-rules')) {
      return {'id': 'fixture-version', 'name': body['name'], 'rules': body};
    }
    if (pending != null) return pending!.future;
    return response({...body, if (wrong) 'asOf': '1999-01-01'});
  }
}

Future<void> mount(
  WidgetTester t,
  StrategyApi api, {
  Size size = const Size(1320, 1000),
  double scale = 1,
  AppLanguage language = AppLanguage.en,
  String date = '2026-08-28',
  ValueChanged<String>? open,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: language,
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              child: StrategyLabPanel(
                api: api,
                palette: Palette(false),
                asOf: date,
                onCompany: open ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String label) async {
  final f = find.text(label).last;
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> choose(WidgetTester t, {bool two = false}) async {
  await tap(t, 'Choose Gurus');
  await tap(t, 'Fixture Manager');
  if (two) await tap(t, 'Second Manager');
  await tap(t, 'Done (${two ? 2 : 1})');
}

void main() {
  test('source gaps are distinct from a valid all-expensive selection', () {
    expect(
      strategyFailureHasSourceGap({
        'code': 'no_eligible_stocks',
        'exclusions': [
          {'status': 'expensive'},
        ],
      }),
      false,
    );
    expect(
      strategyFailureHasSourceGap({
        'code': 'no_eligible_stocks',
        'exclusions': [
          {'status': 'no_model'},
        ],
      }),
      true,
    );
    expect(
      strategyFailureHasSourceGap({
        'code': 'no_eligible_stocks',
        'managerExclusions': [
          {'code': 'original_filing_missing'},
        ],
      }),
      true,
    );
  });
  testWidgets(
    'zero eligible stock failure shows exclusions, opens evidence and never auto-loosens rules',
    (t) async {
      final api = StrategyApi()
        ..blocked = true
        ..failureOverride = {
          'code': 'no_eligible_stocks',
          'date': '2021-09-10',
          'decisionDate': '2021-09-09',
          'exclusions': [
            {
              'ticker': 'LOW',
              'status': 'expensive',
              'price': 200,
              'fairValue': 100,
              'premium': 1,
              'modelDate': '2021-08-15',
            },
            {'ticker': 'QSR', 'status': 'no_model'},
          ],
        };
      String? opened;
      await mount(t, api, open: (value) => opened = value);
      await choose(t);
      await tap(t, 'Run backtest');
      expect(find.text('Required source data is incomplete'), findsOneWidget);
      expect(find.text('QSR · No model'), findsOneWidget);
      expect(find.textContaining('Decision data: 2021-09-09'), findsOneWidget);
      expect(
        find.textContaining('LOW: price \$200.00 / model \$100.00'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Fully invested eligible subset'),
        findsNothing,
      );
      await tap(t, 'LOW · Above limit');
      expect(opened, 'LOW');
      expect(api.posts.length, 1);
      expect(api.posts.single['maxPremium'], .3);
    },
  );
  testWidgets(
    'a Guru mix exposes Top N on its card, rather than hiding the selection depth',
    (t) async {
      final api = StrategyApi();
      await mount(t, api);
      await tap(t, 'Configure mix');
      await tap(t, 'Guru only');
      await tap(t, 'Fixture Manager');
      await tap(t, 'Top 3');
      await tap(t, 'Apply mix');
      expect(find.textContaining('Guru Top 3 per manager'), findsOneWidget);
      await tap(t, 'Run backtest');
      expect(api.posts.single['topN'], 3);
      expect(asMap(api.posts.single['equityMix'])['weights']['guru'], 1);
    },
  );
  testWidgets(
    'stale database and ETF errors identify exact dates without rewriting rules',
    (t) async {
      final api = StrategyApi()
        ..failureCode = 'strategy_database_cutoff_exceeded';
      await mount(t, api, date: '2026-09-10');
      // An explicit requested end is never silently shortened, even though the
      // initial untouched range now stops at the verified market-data cutoff.
      await tap(t, '2021-08-28 → 2026-08-28');
      final picker = find.byType(DateRangePickerDialog);
      Navigator.of(t.element(picker)).pop(
        DateTimeRange(start: DateTime(2021, 9, 10), end: DateTime(2026, 9, 10)),
      );
      await t.pumpAndSettle();
      await choose(t);
      await tap(t, 'Run backtest');
      expect(find.textContaining('updated through 2026-08-28'), findsOneWidget);
      expect(api.posts.last['end'], '2026-09-10');
      api.failureCode = 'strategy_etf_cutoff_exceeded';
      await tap(t, 'Run backtest');
      expect(
        find.textContaining('KMLM prices stop at 2026-08-28'),
        findsOneWidget,
      );
      expect(
        find.textContaining('test has not been shortened'),
        findsOneWidget,
      );
      expect(api.posts.last['end'], '2026-09-10');
    },
  );
  test(
    'rule equality accepts JSON integer/double but rejects altered values',
    () {
      expect(strategyRuleValueEqual(10, 10.0), isTrue);
      expect(strategyRuleValueEqual(['a', 10], ['a', 10.0]), isTrue);
      expect(strategyRuleValueEqual(.15, .3), isFalse);
      expect(strategyRuleValueEqual(['a'], ['a', 'b']), isFalse);
    },
  );
  test(
    'range metrics reproduce return, drawdown and retain entry costs only for full range',
    () {
      final rows = <Map<String, dynamic>>[
        {'date': '2025-01-01', 'value': .999},
        {'date': '2025-07-01', 'value': 1.2},
        {'date': '2026-01-01', 'value': .9},
      ];
      final full = strategyRangeMetrics(rows, includeEntry: true);
      expect(full['totalReturn'], closeTo(-.1, 1e-10));
      expect(full['maxDrawdown'], closeTo(-.25, 1e-10));
      expect(
        strategyRangeMetrics(rows.sublist(1))['totalReturn'],
        closeTo(-.25, 1e-10),
      );
      expect(strategyRangeMetrics([]), isEmpty);
    },
  );
  testWidgets('initial choices are explicit; no automatic run or save', (
    t,
  ) async {
    final api = StrategyApi();
    await mount(t, api);
    expect(find.text('Your portfolio. Your rules.'), findsOneWidget);
    expect(api.posts, isEmpty);
    expect(
      t
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Run backtest'),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(GuruAvatar), findsNothing);
  });
  testWidgets(
    'manager avatars, Top 10, 15% filter and DBMF 50% become API rules',
    (t) async {
      final api = StrategyApi();
      await mount(t, api);
      await choose(t, two: true);
      await tap(t, 'Configure mix');
      await tap(t, 'Top 10');
      await tap(t, 'Apply mix');
      await tap(t, '15%');
      await tap(t, 'DBMF');
      await tap(t, '50%');
      await tap(t, 'Run backtest');
      final r = api.posts.single;
      expect(r['managers'], ['bill-ackman', 'warren-buffett']);
      expect(r['topN'], 10);
      expect(r['maxPremium'], .15);
      expect(r['cta'], 'DBMF');
      expect(r['ctaWeight'], .5);
      expect(find.text('Portfolio backtest'), findsOneWidget);
      expect(
        find.text('Rules changed — run again to update results.'),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'filter off and no CTA are supported; changes do not relabel old results',
    (t) async {
      final api = StrategyApi();
      await mount(t, api);
      await choose(t);
      await tap(t, 'Run backtest');
      await tap(t, 'No CTA');
      expect(
        find.text('Rules changed — run again to update results.'),
        findsOneWidget,
      );
      await t.ensureVisible(find.byType(SwitchListTile));
      t.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(false);
      await t.pumpAndSettle();
      await tap(t, 'Run backtest');
      expect(api.posts.last['ctaWeight'], 0);
      expect(api.posts.last['valuationEnabled'], isFalse);
      expect(
        find.text('Rules changed — run again to update results.'),
        findsNothing,
      );
    },
  );
  testWidgets(
    'rebalancing audit shows redistribution reasons and opens exact security valuation',
    (t) async {
      String? opened;
      final api = StrategyApi();
      await mount(t, api, open: (s) => opened = s);
      await choose(t);
      await tap(t, 'Run backtest');
      await tap(t, 'Rebalance audit');
      expect(find.text('No model · redistributed'), findsOneWidget);
      await tap(t, 'Open valuation →');
      expect(opened, 'BBB');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'full investment is the default; snapshots page backward and forward without running or saving',
    (t) async {
      String? opened;
      final api = StrategyApi();
      await mount(t, api, open: (s) => opened = s);
      await choose(t);
      await tap(t, 'Run backtest');
      expect(api.posts.last['excludedAllocation'], 'fully_invested');
      expect(find.text('Historical snapshot'), findsOneWidget);
      expect(find.text('1 held · 1 filtered'), findsOneWidget);
      await tap(t, 'View holdings & filters');
      expect(find.text('CCC'), findsOneWidget);
      expect(find.text('DDD'), findsOneWidget);
      expect(find.text('35.0% premium > 30.0% allowed'), findsOneWidget);
      expect(find.text('USD 135.00'), findsOneWidget);
      expect(find.text('Fixture Manager'), findsNWidgets(2));
      expect(find.text('70.0%'), findsWidgets);
      expect(find.textContaining('Cash 0.0%'), findsOneWidget);
      await t.ensureVisible(find.byTooltip('Previous snapshot'));
      await t.tap(find.byTooltip('Previous snapshot'));
      await t.pumpAndSettle();
      expect(find.text('AAA'), findsOneWidget);
      expect(find.text('CCC'), findsNothing);
      expect(
        t
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Previous snapshot',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('DDD'), findsNothing);
      expect(find.text('No usable model at the time'), findsOneWidget);
      expect(
        find.textContaining('First public filing 2026-08-15'),
        findsOneWidget,
      );
      await tap(t, 'Open company research →');
      expect(opened, 'AAA');
      await t.ensureVisible(find.byTooltip('Next snapshot'));
      await t.tap(find.byTooltip('Next snapshot'));
      await t.pumpAndSettle();
      expect(find.text('CCC'), findsOneWidget);
      expect(api.posts.length, 1);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'blocked runs cannot present target snapshots as held positions',
    (t) async {
      final api = StrategyApi()..blocked = true;
      await mount(t, api);
      await choose(t);
      await tap(t, 'Run backtest');
      await tap(t, 'Holdings & filters');
      expect(find.text('No completed holdings history yet'), findsOneWidget);
      expect(find.byTooltip('Previous snapshot'), findsNothing);
    },
  );
  testWidgets(
    'snapshot date selector works directly from performance and keeps the completed run threshold',
    (t) async {
      final api = StrategyApi();
      await mount(t, api);
      await choose(t);
      await tap(t, 'Run backtest');
      await tap(t, '15%');
      await tap(t, 'View holdings & filters');
      expect(find.text('35.0% premium > 30.0% allowed'), findsOneWidget);
      expect(find.textContaining('Showing the previous run.'), findsOneWidget);
      await tap(t, 'Performance');
      final datePicker = find.byKey(const ValueKey('snapshot-1'));
      t.widget<DropdownButtonFormField<int>>(datePicker).onChanged!(0);
      await t.pumpAndSettle();
      expect(find.text('AAA'), findsOneWidget);
      expect(find.text('BBB'), findsOneWidget);
      expect(find.text('CCC'), findsNothing);
      expect(find.text('DDD'), findsNothing);
      expect(find.text('Filtered stocks · 1'), findsOneWidget);
      expect(api.posts.length, 1);
      expect(t.takeException(), isNull);
    },
  );
  for (final language in AppLanguage.values) {
    testWidgets(
      'snapshot holdings and reasons stay readable on mobile at 150% text in ${language.name}',
      (t) async {
        final api = StrategyApi();
        final data = api.response({
          'cta': 'KMLM',
          'ctaWeight': .3,
          'costBps': 10,
        });
        final linked = (data['holdingSnapshots'] as List).last['positions'][0];
        linked['modelTicker'] = 'GOOGL';
        linked['valuationLink'] = {'basis': 'equal_per_share_economic_rights'};
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: LanguageScope(
              language: language,
              child: Scaffold(
                body: MediaQuery(
                  data: const MediaQueryData(
                    textScaler: TextScaler.linear(1.5),
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: StrategySnapshotInspector(
                        event: asList(data['holdingSnapshots']).last,
                        rules: {
                          'valuationEnabled': true,
                          'maxPremium': .3,
                          'excludedAllocation': 'fully_invested',
                        },
                        managers: const [
                          {'id': 'bill-ackman', 'name': 'Fixture Manager'},
                          {'id': 'warren-buffett', 'name': 'Second Manager'},
                        ],
                        palette: Palette(false),
                        asOf: '2026-08-28',
                        onCompany: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(
          find.textContaining(
            language == AppLanguage.en ? 'Company model: GOOGL' : '公司模型：GOOGL',
          ),
          findsOneWidget,
        );
        expect(find.text('DDD'), findsOneWidget);
        await t.ensureVisible(find.text('DDD'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'CTA data failure preserves stock comparisons with explicit warning',
    (t) async {
      final api = StrategyApi()..blocked = true;
      await mount(t, api);
      await choose(t);
      await tap(t, 'Run backtest');
      expect(find.text('This configuration needs data review'), findsOneWidget);
      expect(find.text('Portfolio backtest'), findsOneWidget);
      expect(
        find.text('Some periods have low valuation coverage'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'history boundary identifies first disclosure and does not recommend reducing Top N',
    (t) async {
      final api = StrategyApi()
        ..blocked = true
        ..historyBoundary = true;
      await mount(t, api);
      await choose(t);
      await tap(t, 'Run backtest');
      expect(
        find.text('The requested start precedes available filings'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'The first stored filing was public on 2022-02-14.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Reduce Top N or use a later start'),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('wrong-cutoff response cannot replace current model result', (
    t,
  ) async {
    final api = StrategyApi();
    await mount(t, api);
    await choose(t);
    await tap(t, 'Run backtest');
    api.wrong = true;
    await tap(t, '15%');
    await tap(t, 'Run backtest');
    expect(find.text('Portfolio backtest'), findsOneWidget);
    final plot = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is StrategyCurvePainter,
    );
    expect(t.getSize(plot).width, greaterThan(600));
    expect(
      find.textContaining('The backtest did not complete.'),
      findsOneWidget,
    );
    expect(
      find.text('Rules changed — run again to update results.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'save only persists on explicit confirmation; ordinary run remains unsaved',
    (t) async {
      final api = StrategyApi();
      await mount(t, api);
      await choose(t);
      await tap(t, 'Save rules');
      expect(api.posts, isEmpty);
      await tap(t, 'Cancel');
      expect(api.posts, isEmpty);
      await tap(t, 'Save rules');
      await tap(t, 'Save');
      expect(api.posts.single['path'], '/api/investment/strategy-rules');
      expect(
        find.textContaining('Private rule version saved.'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'chart range control and drawdown are functional and resettable',
    (t) async {
      final api = StrategyApi();
      await mount(t, api);
      await choose(t);
      await tap(t, 'Run backtest');
      await tap(t, 'Drawdown');
      expect(find.byType(RangeSlider), findsOneWidget);
      t.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(
        const RangeValues(.5, 1),
      );
      await t.pumpAndSettle();
      expect(find.text('2026-08-13 → 2026-08-25'), findsOneWidget);
      await tap(t, 'Full range');
      expect(find.text('2026-08-01 → 2026-08-25'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  for (final language in [AppLanguage.en, AppLanguage.zh]) {
    testWidgets(
      'mobile ${language.name} 150% text scale: controls and chart do not overflow',
      (t) async {
        final api = StrategyApi();
        await mount(
          t,
          api,
          size: const Size(390, 844),
          scale: 1.5,
          language: language,
        );
        expect(t.takeException(), isNull);
        final stateFinder = find.byType(StrategyLabPanel);
        // Use visible controls for interaction; no test fixture injection into state.
        await tap(t, language == AppLanguage.en ? 'Choose Gurus' : '选择大佬');
        await tap(t, 'Fixture Manager');
        await tap(t, language == AppLanguage.en ? 'Done (1)' : '完成（1）');
        expect(
          find.descendant(of: stateFinder, matching: find.byType(GuruAvatar)),
          findsOneWidget,
        );
        await tap(t, language == AppLanguage.en ? 'Run backtest' : '运行回测');
        expect(t.takeException(), isNull);
        await tap(t, language == AppLanguage.en ? 'Rebalance audit' : '调仓审计');
        expect(t.takeException(), isNull);
        await tap(
          t,
          language == AppLanguage.en ? 'Holdings & filters' : '持仓与过滤原因',
        );
        expect(t.takeException(), isNull);
        await t.ensureVisible(find.text('DDD'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('offline catalog is actionable and never starts a backtest', (
    t,
  ) async {
    final api = StrategyApi()..fail = true;
    await mount(t, api);
    expect(find.text('Retry loading'), findsOneWidget);
    expect(api.posts, isEmpty);
    api.fail = false;
    await tap(t, 'Retry loading');
    expect(find.text('Choose Gurus'), findsOneWidget);
  });
}
