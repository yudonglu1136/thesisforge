import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_workflow_test.dart' as fixtures;

class ResearchApi extends fixtures.HomeFixtureApi {
  bool readOnly = true, wrongIdentity = false, noHistory = false, saved = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final uri = Uri.parse(path);
    if (uri.path.endsWith('/fundamentals')) {
      reads.add(path);
      Map<String, dynamic> statement(
        String year,
        double scale, {
        String dimension = 'ARY',
      }) => {
        'dimension': dimension,
        'reportperiod': '$year-12-31',
        'period_end': '$year-12-31',
        'date': '${int.parse(year) + 1}-02-01',
        'revenue': 1000 * scale,
        'cor': 600 * scale,
        'gp': 400 * scale,
        'rnd': 90 * scale,
        'sgna': 70 * scale,
        'opex': 160 * scale,
        'opinc': 240 * scale,
        'ebit': 230 * scale,
        'intexp': -12 * scale,
        'taxexp': 36 * scale,
        'netinc': 182 * scale,
        'netinccmn': 180 * scale,
        'shareswadil': 100,
        'cashneq': 210 * scale,
        'receivables': 130 * scale,
        'inventory': 45 * scale,
        'assetsc': 410 * scale,
        'ppnenet': 360 * scale,
        'assets': 1100 * scale,
        'payables': 85 * scale,
        'liabilitiesc': 260 * scale,
        'debt': 190 * scale,
        'liabilities': 610 * scale,
        'equity': 490 * scale,
        'workingcapital': 150 * scale,
        'invcap': 680 * scale,
        'ncfo': 260 * scale,
        'capex': -95 * scale,
        'fcf': 165 * scale,
        'ncfi': -120 * scale,
        'ncff': -60 * scale,
        'sbcomp': 25 * scale,
        'ncfcommon': -30 * scale,
        'ncfdebt': -12 * scale,
        'ncfdiv': -8 * scale,
        'depamor': 42 * scale,
        'ncf': 80 * scale,
      };
      return {
        'ticker': 'TEST',
        'reportedBasis':
            'ARQ/ARY latest revision visible by the requested as-of date',
        'annual': [
          statement('2025', 1.35),
          statement('2024', 1.2),
          statement('2023', 1.08),
          statement('2022', .96),
          statement('2021', .84),
        ],
        'quarterly': [
          statement('2026', .38, dimension: 'ARQ'),
          statement('2025', .36, dimension: 'ARQ'),
          statement('2025', .34, dimension: 'ARQ'),
          statement('2025', .32, dimension: 'ARQ'),
        ],
        'transportCoverage': {'mode': 'full_facts'},
      };
    }
    if (uri.path.endsWith('/institutions')) {
      reads.add(path);
      return {
        'version': 'institutional-13f-insights-v5',
        'asOf': uri.queryParameters['asOf'],
        'reportDate': '2026-03-31',
        'previousReportDate': '2025-12-31',
        'availableAt': '2026-05-15',
        'ticker': 'TEST',
        'row': {
          'ticker': 'TEST',
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
                'reportDate': '202${4 + i ~/ 4}-${((i % 4) + 1) * 3}-30',
                'holders': 30 + i * 2,
                'institutionalSharesK': 100000 + i * 5000,
                'institutionalOwnershipPct': 60.0 + i,
                'shareBasisFactor': 1,
                'shareBasisDate': '2026-03-31',
              },
          ],
          'analysis': {
            'headlineKey': 'balanced_breadth_net_increase',
            'evidence': {
              'breadth': {
                'adds': 15,
                'trims': 10,
                'netFilers': 5,
                'addsPct': .6,
              },
              'shares': {
                'netUnitsChangeK': 2500.0,
                'netChangePctPrior': 2.5,
                'netChangePctOutstanding': .8,
                'shareBasisDate': '2026-03-31',
              },
              'weights': {
                'importantChangesEvaluated': 1,
                'sharesUpWeightDown': 0,
              },
            },
            'importantChanges': [
              {
                'investorId': 'fixture-capital',
                'name': 'Fixture Capital',
                'action': 'increased',
                'unitsChangeK': 1200.0,
                'previousWeight': .03,
                'currentWeight': .045,
                'weightChangeBps': 150.0,
                'reportedValueChangeM': 85.0,
                'continuity': 'increased_3_quarters',
                'consecutiveDirectionQuarters': 3,
                'tags': ['shares_and_weight_up'],
                'trajectory': [
                  {
                    'reportDate': '2026-03-31',
                    'status': 'reported',
                    'unitsK': 5000.0,
                    'weight': .045,
                  },
                ],
              },
            ],
          },
        },
      };
    }
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
    d['publishedBreakdown'] = {
      'fairValue': 75,
      'weightedValue': 75,
      'availableAt': '2026-04-20',
      'period': '2026-Q1',
      'modelVersion': 'fixture-v1',
      'reconciliationStatus': 'reconciled',
      'postModelAdjustments': [],
      'components': [
        {
          'key': 'normalized-earnings',
          'label': 'Normalized earnings',
          'status': 'included',
          'output': 75,
          'weight': 1,
          'contribution': 75,
          'parameters': [
            {
              'key': 'normalizedNetIncome',
              'label': 'Normalized net income',
              'value': 7500,
            },
            {'key': 'sharesM', 'label': 'Diluted shares', 'value': 100},
          ],
          'steps': [
            {
              'label': 'Normalized EPS',
              'formula': 'normalizedNetIncome ÷ sharesM',
              'output': 75,
            },
          ],
        },
        {
          'key': 'fcfe-dcf',
          'label': 'FCFE DCF',
          'status': 'not_applicable',
          'output': null,
          'weight': 0,
          'contribution': 0,
          'exclusionReason': 'Stored snapshot did not produce this method.',
          'parameters': [],
          'steps': [],
        },
      ],
    };
    d['coverage'] = {'platformModel': 'available'};
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

class ReverseResearchApi extends ResearchApi {
  ReverseResearchApi() {
    readOnly = false;
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!path.contains('/calculate')) return super.postJson(path, body);
    final forecast = [
      for (var year = 1; year <= 5; year++)
        {
          'year': year,
          'growth': .12,
          'revenueM': 1000 * (1 + .12 * year),
          'fcfeMargin': .2,
          'fcfeM': 200 * (1 + .12 * year),
          'pvM': 180 * (1 + .08 * year),
        },
    ];
    final scenario = {
      'fairValue': 50,
      'forecast': forecast,
      'explicitPvM': 1100,
      'terminalValueM': 3600,
      'terminalPvM': 2200,
      'terminalShare': .6667,
      'equityValueM': 3300,
    };
    return {
      'result': {...scenario, 'fairValue': 30},
      'reverse': {
        'status': 'solved',
        'variable': 'growth',
        'value': .12,
        'price': 50,
        'targetReturn': .10,
        'residual': 0,
        'fixed': 'All FCFE margins, Ke and g fixed.',
        'scenario': scenario,
        'diagnostics': {
          'converged': true,
          'rootCount': 1,
          'verifiedForwardValue': 50,
        },
      },
      'sensitivity': [],
    };
  }
}

Future<void> mount(
  WidgetTester t,
  ResearchApi api, {
  Size size = const Size(1487, 1058),
  AppLanguage lang = AppLanguage.en,
  String? initialSection,
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
          initialQuery: initialSection == null
              ? null
              : {
                  'view': 'research',
                  'valuation': 'TEST',
                  'asOf': '2026-06-01',
                  'section': initialSection,
                },
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
        expect(find.byType(ValuationTrendChart), findsNothing);
        expect(
          find.byKey(const ValueKey('research-financial-chart')),
          findsOneWidget,
        );
        expect(
          find.text(lang == AppLanguage.en ? 'What changed?' : '什么变了？'),
          findsNothing,
        );
        expect(
          find.text(
            lang == AppLanguage.en
                ? 'What the model is worth — and why'
                : '模型值多少，以及怎么算出来',
          ),
          findsOneWidget,
        );
        expect(find.text('Normalized earnings'), findsWidgets);
        for (final key in ['income', 'balance', 'cash']) {
          expect(
            find.byKey(ValueKey('research-statement-$key')),
            findsOneWidget,
          );
        }
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
  testWidgets('statement rows redraw the comparison chart', (t) async {
    await mount(t, ResearchApi());
    await t.ensureVisible(
      find.byKey(const ValueKey('research-statement-balance')),
    );
    await t.tap(find.byKey(const ValueKey('research-statement-balance')));
    await t.pumpAndSettle();
    expect(find.text('Receivables'), findsOneWidget);
    await t.tap(
      find.byKey(const ValueKey('research-financial-row-receivables')),
    );
    await t.pumpAndSettle();
    expect(find.text('Receivables'), findsNWidgets(2));
    expect(t.takeException(), isNull);
  });
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
      api.reads.lastWhere(
        (p) => p.contains('/research/') && !p.contains('/fundamentals'),
      ),
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
  testWidgets(
    'reverse DCF reuses the full forecast grid and highlights one solved path',
    (t) async {
      await mount(t, ReverseResearchApi());
      await t.tap(find.byKey(const ValueKey('research-tab-value')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Reverse DCF'));
      await t.tap(find.text('Reverse DCF'));
      await t.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('reverse-forecast-grid')),
        findsOneWidget,
      );
      expect(find.text('5-year price-implied path'), findsOneWidget);
      expect(find.text('Actual TTM'), findsOneWidget);
      expect(find.text('Model year 5'), findsOneWidget);
      expect(find.textContaining('12'), findsWidgets);
      expect(
        find.byKey(const ValueKey('reverse-solved-value')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reverse-same-engine-notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('forecast-Year 1 growth %')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'institutional research reuses 13F charts and behavior analysis',
    (t) async {
      final api = ResearchApi();
      await mount(t, api);
      await t.tap(find.byKey(const ValueKey('research-tab-institutions')));
      await t.pumpAndSettle();

      expect(
        api.reads.where((path) => path.contains('/research/TEST/institutions')),
        hasLength(1),
      );
      expect(
        find.byKey(const ValueKey('13f-holders-history-chart')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('13f-ownership-history-chart')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('research-13f-evidence-breadth')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('research-13f-changes-worth-researching')),
        findsOneWidget,
      );
      expect(find.text('Fixture Capital'), findsOneWidget);
      expect(find.text('Quarter'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('institutional research deep link loads its lazy 13F payload', (
    t,
  ) async {
    final api = ResearchApi();
    await mount(t, api, initialSection: 'institutions');

    expect(
      api.reads.where((path) => path.contains('/research/TEST/institutions')),
      hasLength(1),
    );
    expect(
      find.byKey(const ValueKey('13f-holders-history-chart')),
      findsOneWidget,
    );
    expect(find.text('No covered 13F security record'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
