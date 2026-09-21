import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_workflow_test.dart' as fixtures;

class ResearchApi extends fixtures.HomeFixtureApi {
  bool readOnly = true, wrongIdentity = false, noHistory = false, saved = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.contains('/companies?')) {
      reads.add(path);
      return {
        'asOf': '2026-06-01',
        'companies': [
          {
            'ticker': 'TEST',
            'name': 'Test fixture',
            'availableAt': '2026-04-20',
            'coverage': 'stored_model',
          },
          {
            'ticker': 'ISRG',
            'name': 'Intuitive Surgical',
            'availableAt': '2026-04-20',
            'coverage': 'stored_model',
          },
        ],
      };
    }
    final d = await super.getJson(path);
    if (path.contains('/home')) {
      d['watches'] = saved
          ? [
              {'ticker': 'TEST', 'id': 'watch-test'},
            ]
          : [];
    }
    if (!path.contains('/research/')) return d;
    if (wrongIdentity) d['ticker'] = 'WRONG';
    if (readOnly) d['templates'] = null;
    d['published'] = {
      'fairValue': 75,
      'dcf': 40,
      'formula': 'Synthetic blended model',
    };
    (d['snapshot'] as Map)['price'] = {
      'value': 50,
      'date': '2026-06-01',
      'source': 'fixture',
      'currency': 'USD',
    };
    d['metrics'] = [
      {
        'key': 'fcfMargin',
        'value': .2,
        'previous': .25,
        'change': -.05,
        'period': '2026-Q1',
        'availableAt': '2026-04-20',
        'source': 'Synthetic fixture',
        'historicalPercentile': .25,
        'sampleCount': 4,
      },
    ];
    d['history'] = noHistory
        ? []
        : [
            for (final (date, value) in [
              ('2024-04-20', 50),
              ('2025-04-20', 60),
              ('2026-04-20', 75),
            ])
              {
                'period': date.substring(0, 4),
                'availableAt': date,
                'publishedFairValue': value,
                'metrics': {'revenueGrowth': .2, 'fcfMargin': .2},
                'publishedFormula': 'fixture',
                'source': {'modelVersion': 'v1'},
              },
          ];
    if (noHistory) d['priceHistory'] = [];
    d['guidance'] = {
      'evidence': [
        {
          'excerpt': 'Synthetic management statement for testing only.',
          'speaker': 'Fixture CFO',
          'observedAt': '2026-04-20',
          'url': 'https://example.com/fixture',
        },
      ],
    };
    return d;
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path.endsWith('/watches')) saved = true;
    return super.postJson(path, body);
  }
}

Future<void> mount(
  WidgetTester t,
  ResearchApi api, {
  Size size = const Size(1487, 1058),
  AppLanguage lang = AppLanguage.en,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: LanguageScope(
        language: lang,
        child: InvestmentWorkspace(
          api: api,
          palette: Palette(false),
          initialPage: 'research',
          initialTicker: 'TEST',
          initialAsOf: '2026-06-01',
          onLanguage: (_) {},
          onLegacy: () {},
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  test('research route resolves exact candidate only on Research', () {
    expect(researchEntryTicker('research', '', ' nvda '), 'NVDA');
    expect(researchEntryTicker('research', 'ISRG', 'NVDA'), 'ISRG');
    expect(researchEntryTicker('discover', '', 'NVDA'), '');
    expect(researchEntryTicker('research', '', null), '');
  });
  test(
    'dated curve filtering excludes invalid and future rows without mutating input',
    () {
      final rows = [
        {'date': '2027-01-01'},
        {'date': '2025-01-01'},
        {'date': '2026-01-01'},
        {'date': 'invalid'},
      ];
      expect(
        researchDatedRows(rows, 'date', '2026-06-01', from: '2025-06-01'),
        [
          {'date': '2026-01-01'},
        ],
      );
      expect(rows.first['date'], '2027-01-01');
    },
  );
  test(
    'model changes require matching formula/version and positive denominator',
    () {
      final before = {
        'publishedFairValue': 50,
        'publishedFormula': 'fixture',
        'source': {'modelVersion': 'v1'},
      };
      final after = {...before, 'publishedFairValue': 40};
      expect(researchValueChange(after, before), closeTo(-.2, 1e-12));
      expect(
        researchValueChange({
          ...after,
          'publishedFormula': 'different',
        }, before),
        isNull,
      );
      expect(
        researchValueChange({
          ...after,
          'source': {'modelVersion': 'v2'},
        }, before),
        isNull,
      );
      expect(
        researchValueChange(after, {...before, 'publishedFairValue': 0}),
        isNull,
      );
      expect(researchValueChange(after, null), isNull);
    },
  );
  for (final lang in AppLanguage.values) {
    for (final size in [
      const Size(1487, 1058),
      const Size(1024, 768),
      const Size(390, 844),
    ]) {
      testWidgets('research overview/model/financials/decision $lang $size', (
        t,
      ) async {
        await mount(t, ResearchApi(), size: size, lang: lang);
        expect(t.takeException(), isNull);
        expect(find.byType(ValuationTrendChart), findsOneWidget);
        expect(
          find.text(lang == AppLanguage.en ? 'Set my assumptions' : '设定我的假设'),
          findsNothing,
        );
        for (final tab in ['value', 'financials', 'records']) {
          await t.tap(find.byKey(ValueKey('research-tab-$tab')));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
        }
        expect(
          find.text(
            lang == AppLanguage.en
                ? 'Save a falsifiable research record'
                : '保存可证伪的研究记录',
          ),
          findsOneWidget,
        );
        expect(find.widgetWithText(ChoiceChip, 'Invest'), findsNothing);
      });
    }
  }
  testWidgets('switch company requests exact symbol and retains cutoff', (
    t,
  ) async {
    final api = ResearchApi();
    await mount(t, api);
    await t.tap(find.text('Switch company'));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const ValueKey('company-search-input')),
      'Intuitive',
    );
    await t.pumpAndSettle();
    await t.tap(find.text('ISRG'));
    await t.pumpAndSettle();
    expect(
      api.reads.lastWhere((p) => p.contains('/research/')),
      '/api/investment/research/ISRG?asOf=2026-06-01',
    );
    expect(find.text('ISRG'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('wrong company response never displays a substitute chart', (
    t,
  ) async {
    await mount(t, ResearchApi()..wrongIdentity = true);
    expect(find.byType(ValuationTrendChart), findsNothing);
    expect(find.textContaining('No substitute is shown'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'no history displays an honest empty state and never a fabricated chart',
    (t) async {
      await mount(t, ResearchApi()..noHistory = true);
      expect(find.byType(ValuationTrendChart), findsNothing);
      expect(
        find.text('Not enough observations in this range. Try All.'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'range controls filter real dates and selected report loads only its model ledger',
    (t) async {
      final api = ResearchApi();
      await mount(t, api);
      final reads = api.reads.length;
      await t.ensureVisible(find.widgetWithText(ChoiceChip, '1Y'));
      await t.tap(find.widgetWithText(ChoiceChip, '1Y'));
      await t.pumpAndSettle();
      expect(find.byType(ValuationTrendChart), findsNothing);
      expect(
        find.text('Not enough observations in this range. Try All.'),
        findsOneWidget,
      );
      await t.tap(find.widgetWithText(ChoiceChip, 'All'));
      await t.pumpAndSettle();
      expect(
        t
            .widget<ValuationTrendChart>(find.byType(ValuationTrendChart))
            .history
            .length,
        3,
      );
      await t.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await t.tap(find.byType(DropdownButtonFormField<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('2025 · 2025-04-20').last);
      await t.pumpAndSettle();
      expect(find.text(r'Value $60.00'), findsOneWidget);
      expect(
        t
            .widget<ValuationTrendChart>(find.byType(ValuationTrendChart))
            .selectedQuarterKey,
        '-2025-04-20',
      );
      expect(api.reads.length, reads + 1);
      expect(api.reads.last, contains('/published-model?asOf=2025-04-20'));
      expect(api.calls, isEmpty);
    },
  );
  testWidgets(
    'watch freezes research ticker/date, never creates a trade or scenario',
    (t) async {
      final api = ResearchApi();
      await mount(t, api);
      await t.tap(find.text('Save to watch'));
      await t.pumpAndSettle();
      final call = api.calls.single;
      expect(call.$1, '/api/investment/watches');
      expect(call.$2['ticker'], 'TEST');
      expect(call.$2['asOf'], '2026-06-01');
      expect(call.$2['origin'], 'value');
      expect(find.text('Saved to watch'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('chart slider filters observations and resets with a preset', (
    t,
  ) async {
    await mount(t, ResearchApi());
    var slider = t.widget<RangeSlider>(find.byType(RangeSlider));
    expect(slider.min, 0);
    expect(slider.max, 1);
    expect(slider.semanticFormatterCallback!(1), '2026-06-01');
    slider.onChanged!(const RangeValues(.1, .8));
    await t.pumpAndSettle();
    slider = t.widget<RangeSlider>(find.byType(RangeSlider));
    expect(slider.values.end, closeTo(.8, .001));
    expect(find.byType(ValuationTrendChart), findsNothing);
    expect(
      find.text('Not enough observations in this range. Try All.'),
      findsOneWidget,
    );
    await t.ensureVisible(find.widgetWithText(ChoiceChip, 'All'));
    await t.tap(find.widgetWithText(ChoiceChip, 'All'));
    await t.pumpAndSettle();
    expect(
      t.widget<RangeSlider>(find.byType(RangeSlider)).values,
      const RangeValues(0, 1),
    );
    expect(t.takeException(), isNull);
  });
  test(
    'report identity includes fiscal period even when disclosure dates coincide',
    () {
      expect(
        researchReportKey({'period': '2026-Q1', 'availableAt': '2026-06-01'}),
        isNot(
          researchReportKey({'period': '2026-Q2', 'availableAt': '2026-06-01'}),
        ),
      );
    },
  );
  testWidgets(
    'editable scenario still uses existing audited controls and unsaved-change guard',
    (t) async {
      final api = ResearchApi()..readOnly = false;
      await mount(t, api);
      await t.tap(find.byKey(const ValueKey('research-tab-value')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('My DCF'));
      await t.tap(find.text('My DCF'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.widgetWithText(TextButton, 'Bear'));
      await t.tap(find.widgetWithText(TextButton, 'Bear'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Switch company'));
      await t.tap(find.text('Switch company'));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('company-search-input')),
        'ISRG',
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Intuitive Surgical'));
      await t.pumpAndSettle();
      expect(find.text('Leave this unsaved scenario?'), findsOneWidget);
      await t.tap(find.text('Keep editing'));
      await t.pumpAndSettle();
      expect(find.text('Your scenario'), findsOneWidget);
      expect(api.reads.where((p) => p.contains('/research/ISRG')), isEmpty);
      final before = api.reads.where((p) => p.contains('/research/')).length;
      await t.ensureVisible(find.text('Switch company'));
      await t.tap(find.text('Switch company'));
      await t.pumpAndSettle();
      await t.tap(find.text('Test fixture'));
      await t.pumpAndSettle();
      expect(find.text('Leave this unsaved scenario?'), findsNothing);
      expect(find.text('Your scenario'), findsOneWidget);
      expect(api.reads.where((p) => p.contains('/research/')).length, before);
      expect(t.takeException(), isNull);
    },
  );
}
