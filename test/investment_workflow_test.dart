import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class WorkflowTestApi extends ApiClient {
  WorkflowTestApi() : super(() => 'test');
  final calls = <(String, Map<String, dynamic>)>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.contains('/research/')) {
      return {
        'ticker': 'TEST',
        'name': 'Synthetic UI fixture',
        'currency': 'USD',
        'snapshot': {
          'id': 'fixture',
          'period': '2026-Q1',
          'availableAt': '2026-04-20',
          'price': {'value': 50, 'date': '2026-06-01', 'source': 'test'},
        },
        'templates': {
          for (final name in ['Base', 'Bear', 'Bull'])
            name: {
              'ke': .1,
              'g': .024698294551041777,
              'growth': [.1, .1, .1, .1, .1],
              'margin': [.2290987654321, .2, .2, .2, .2],
            },
        },
        'metrics': [],
        'history': [],
        'priceHistory': [],
        'provenance': [],
        'scenarios': [],
      };
    }
    return {
      'attention': [],
      'discovery': [
        {'ticker': 'TEST', 'revenueGrowth': .2},
      ],
      'decisions': [],
      'gurus': [],
      'portfolio': {
        'positions': [],
        'overlap': [],
        'shadow': {'issues': []},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add((path, body));
    if (path.endsWith('/scenarios')) {
      return {...body, 'id': 'saved-fixture', 'version': 1};
    }
    return {
      'result': {'fairValue': 30, 'forecast': []},
      'reverse': {'status': 'solved', 'value': .1},
      'sensitivity': [],
    };
  }
}

class DiscoveryFixtureApi extends WorkflowTestApi {
  final guru = {
    'id': 'test-manager',
    'name': 'Test manager',
    'entityName': 'Synthetic UI fixture',
    'avatar': '',
  };
  Map<String, dynamic> filing(
    String accession,
    String quarter,
    String date,
    double shares,
  ) => {
    'accessionNumber': accession,
    'quarterLabel': quarter,
    'reportDate': quarter == '2025 Q4' ? '2025-12-31' : '2026-03-31',
    'filingDate': date,
    'reported13fValue': 1250000000,
    'positionCount': 2,
    'topHoldings': [
      {
        'id': '123-COMMON',
        'ticker': 'TEST',
        'issuer': 'Synthetic holding',
        'shares': shares,
        'value': 100,
        'pctPortfolio': .2,
      },
    ],
    'largestChanges': [],
  };
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final latest = filing('new-filing', '2026 Q1', '2026-05-15', 200);
    if (path.contains('/guru-study')) {
      return {
        'asOf': Uri.parse(path).queryParameters['asOf'],
        'period': Uri.parse(path).queryParameters['period'],
        'rows': [],
        'unavailable': [],
        'range': null,
      };
    }
    if (path.contains('/strategy-lab')) {
      return {
        'version': 'strategy-lab-catalog-v1',
        'asOf': Uri.parse(path).queryParameters['asOf'],
        'managers': [
          {...guru, 'quarters': 2},
        ],
        'etfs': [],
        'saved': [],
      };
    }
    if (path.contains('/gurus/')) {
      return {
        'asOf': Uri.parse(path).queryParameters['asOf'],
        'guru': guru,
        'latest': latest,
        'history': [filing('old-filing', '2025 Q4', '2026-02-15', 100), latest],
      };
    }
    if (path.contains('/discover')) {
      return {
        'gurus': [
          {
            ...guru,
            'followed': false,
            'latest': {
              ...latest,
              'quarter': '2026 Q1',
              'availableAt': '2026-05-15',
            },
          },
        ],
        'discovery': [],
      };
    }
    final data = await super.getJson(path);
    if (!path.contains('/research/')) data['gurus'] = [guru];
    return data;
  }
}

class HomeFixtureApi extends DiscoveryFixtureApi {
  final reads = <String>[];
  bool failExample = false;
  Completer<void>? heldIsrg;
  bool withAlerts = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.contains('/research/ISRG') && heldIsrg != null) {
      await heldIsrg!.future;
    }
    reads.add(path);
    if (failExample && path.contains('/research/')) {
      throw StateError('fixture_unavailable');
    }
    final data = await super.getJson(path);
    if (path.contains('/home')) {
      data['decisions'] = [
        {
          'ticker': 'SAVED',
          'action': 'Watch',
          'decisionDate': '2026-06-01',
          'decisionId': 'saved',
        },
      ];
    }
    if (withAlerts && path.contains('/home')) {
      data['attention'] = [
        {'ticker': 'ALERT1', 'decisionId': 'one', 'status': 'data_unavailable'},
        {'ticker': 'ALERT2', 'decisionId': 'two', 'status': 'data_unavailable'},
      ];
    }
    if (path.contains('/research/')) {
      data['ticker'] = Uri.parse(path).pathSegments.last;
      data['name'] = 'Synthetic home example';
      data['published'] = {'fairValue': 30};
      data['history'] = [
        {'availableAt': '2025-01-15', 'publishedFairValue': 24},
        {'availableAt': '2026-04-20', 'publishedFairValue': 30},
      ];
      data['priceHistory'] = [
        {'date': '2025-01-15', 'close': 40},
        {'date': '2026-06-01', 'close': 50},
      ];
    }
    if (path.contains('/discover')) {
      final latest = (data['gurus'] as List).first['latest'] as Map;
      latest['accession'] = 'new-filing';
      (latest['topHoldings'] as List).add({
        'id': 'OPTION-PUT',
        'ticker': 'OPTION',
        'pctPortfolio': .8,
      });
    }
    return data;
  }
}

class BriefFixtureApi extends HomeFixtureApi {
  String mode = 'normal';
  bool failBrief = false;
  Completer<void>? heldJuneBrief;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final delayed =
        path.contains('/gurus/') &&
        path.endsWith('2026-06-01') &&
        heldJuneBrief != null;
    if (delayed) await heldJuneBrief!.future;
    if (failBrief && path.contains('/gurus/')) {
      throw StateError('brief_unavailable');
    }
    final data = await super.getJson(path);
    if (path.contains('/gurus/')) {
      final history = data['history'] as List;
      if (mode == 'missing_previous') history.first['topHoldings'] = [];
      if (mode == 'different_claim') {
        history.first['topHoldings'][0]['id'] = 'OTHER-COMMON';
      }
      if (mode == 'wrong_manager') {
        data['guru'] = {...guru, 'id': 'different-manager'};
      }
      if (delayed) history.last['topHoldings'][0]['shares'] = 999;
    }
    return data;
  }
}

class DeskFixtureApi extends HomeFixtureApi {
  bool wrongResearch = false;
  bool notCovered = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (notCovered && path.contains('/research/')) {
      throw const ApiRequestException(
        statusCode: 422,
        message: 'no_pit_research_at_date',
        code: 'no_pit_research_at_date',
      );
    }
    final data = await super.getJson(path);
    if (path.contains('/research/') && wrongResearch) data['ticker'] = 'WRONG';
    final other = {
      'id': 'gavin-baker',
      'name': 'Gavin Baker',
      'entityName': 'Synthetic alternate manager',
    };
    if (path.contains('/discover')) (data['gurus'] as List).add(other);
    if (path.contains('/gurus/')) {
      if (path.contains('/gavin-baker')) {
        data['guru'] = other;
        for (final f in [...data['history'] as List, data['latest']]) {
          f['topHoldings'] = [
            {
              'id': 'ALAB-COMMON',
              'ticker': 'ALAB',
              'issuer': 'Synthetic alternate stock',
              'shares': 500,
              'pctPortfolio': .3,
            },
          ];
        }
      } else {
        for (final f in [...data['history'] as List, data['latest']]) {
          final rows = f['topHoldings'] as List;
          if (rows.length > 1) continue;
          for (final ticker in ['ISRG', 'NVDA']) {
            rows.add({
              'id': '$ticker-COMMON',
              'ticker': ticker,
              'issuer': 'Synthetic $ticker holding',
              'shares': f['accessionNumber'] == 'old-filing' ? 50 : 150,
              'pctPortfolio': .1,
              'value': 500,
            });
          }
          rows.add({
            'id': 'OPTION-PUT',
            'ticker': 'OPTION',
            'pctPortfolio': .8,
          });
          f['filing'] = {'secUrl': 'https://www.sec.gov/Archives/test-fixture'};
        }
      }
    }
    return data;
  }
}

Future<void> mountHome(
  WidgetTester tester,
  Size size,
  AppLanguage language,
  WorkflowTestApi api, {
  bool managers = true,
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
          initialPage: 'home',
          initialTicker: '',
          initialAsOf: '2026-06-01',
          onLanguage: (_) {},
          onLegacy: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Home is now account-first; the existing research desk remains an explicit
  // secondary entry, and all its original interaction coverage stays intact.
  await tester.ensureVisible(
    find.byKey(const ValueKey('open-home-research-desk')),
  );
  await tester.tap(find.byKey(const ValueKey('open-home-research-desk')));
  await tester.pumpAndSettle();
  if (managers) {
    await tester.ensureVisible(
      find.text(language == AppLanguage.en ? 'Managers' : '按经理研究'),
    );
    await tester.tap(
      find.text(language == AppLanguage.en ? 'Managers' : '按经理研究'),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> mountDiscovery(
  WidgetTester tester,
  Size size,
  AppLanguage language,
  WorkflowTestApi api,
) async {
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
  await tester.ensureVisible(find.text('Guru'));
  await tester.tap(find.text('Guru'));
  await tester.pumpAndSettle();
}

Future<WorkflowTestApi> mountResearch(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1487, 1058);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = WorkflowTestApi();
  await tester.pumpWidget(
    MaterialApp(
      home: LanguageScope(
        language: AppLanguage.en,
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
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('research-tab-value')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('My DCF'));
  await tester.tap(find.text('My DCF'));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets(
    'desk shows the selected claim and actual adjacent disclosed shares',
    (tester) async {
      final api = BriefFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      expect(find.text(r'$30.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-detail-position')));
      await tester.pumpAndSettle();
      expect(find.text('100'), findsOneWidget);
      expect(find.text('200'), findsOneWidget);
      expect(
        find.textContaining('Corporate actions are not verified'),
        findsOneWidget,
      );
      expect(api.calls, isEmpty);
    },
  );
  for (final mode in ['missing_previous', 'different_claim']) {
    testWidgets('desk missing or different claim is not zero: $mode', (
      tester,
    ) async {
      final api = BriefFixtureApi()..mode = mode;
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.tap(find.byKey(const ValueKey('home-detail-position')));
      await tester.pumpAndSettle();
      expect(find.text('200'), findsOneWidget);
      expect(find.text('100'), findsNothing);
      expect(find.text('Not in extract'), findsOneWidget);
      expect(
        find.textContaining('not zero or a confirmed new position'),
        findsOneWidget,
      );
      expect(api.calls, isEmpty);
    });
  }
  testWidgets('desk rejects another manager identity', (tester) async {
    final api = BriefFixtureApi()..mode = 'wrong_manager';
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    expect(find.text('Retry disclosures'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-holding-TEST')), findsNothing);
    expect(find.byType(ValuationTrendChart), findsNothing);
  });
  testWidgets('desk failure retry restores the requested holding', (
    tester,
  ) async {
    final api = BriefFixtureApi()..failBrief = true;
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    expect(find.byType(ValuationTrendChart), findsNothing);
    api.failBrief = false;
    await tester.tap(find.text('Retry disclosures'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-holding-TEST')), findsOneWidget);
    expect(find.text('Open TEST valuation'), findsOneWidget);
    expect(api.calls, isEmpty);
  });
  testWidgets('desk late filing response cannot replace a newer cutoff', (
    tester,
  ) async {
    final api = BriefFixtureApi();
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    api.heldJuneBrief = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('home-investor-test-manager')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ValuationTrendChart), findsNothing);
    await tester.ensureVisible(find.text('As of 2026-06-01'));
    await tester.tap(find.text('As of 2026-06-01'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(
      find.widgetWithText(TextField, 'YYYY-MM-DD'),
      '2026-08-28',
    );
    await tester.tap(find.text('Apply date'));
    await tester.pumpAndSettle();
    api.heldJuneBrief!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-detail-position')));
    await tester.pumpAndSettle();
    expect(find.text('999'), findsNothing);
    expect(find.text('200'), findsOneWidget);
    expect(
      api.reads,
      contains('/api/investment/gurus/test-manager?asOf=2026-08-28'),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('desk alerts retain every review and its missing data state', (
    tester,
  ) async {
    final api = HomeFixtureApi()..withAlerts = true;
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    await tester.tap(find.text('2 saved decisions need a review'));
    await tester.pumpAndSettle();
    expect(find.text('ALERT1 · '), findsOneWidget);
    expect(find.text('ALERT2 · '), findsOneWidget);
    expect(
      find.text('Data unavailable — no rule conclusion'),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'desk switches ticker and rejects a late previous stock response',
    (tester) async {
      final api = DeskFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      api.heldIsrg = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('home-holding-ISRG')));
      await tester.pump();
      expect(find.text(r'$30.00'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-holding-NVDA')));
      await tester.pumpAndSettle();
      expect(find.text('Open NVDA valuation'), findsOneWidget);
      api.heldIsrg!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open NVDA valuation'), findsOneWidget);
      expect(find.text('Open ISRG valuation'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desk cutoff reload uses the selected disclosed stock not an example',
    (tester) async {
      final api = HomeFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.ensureVisible(find.text('As of 2026-06-01'));
      await tester.tap(find.text('As of 2026-06-01'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'YYYY-MM-DD'),
        '2026-08-28',
      );
      await tester.tap(find.text('Apply date'));
      await tester.pumpAndSettle();
      expect(api.reads, contains('/api/investment/discover?asOf=2026-08-28'));
      expect(
        api.reads,
        contains('/api/investment/research/TEST?asOf=2026-08-28'),
      );
      expect(api.reads.any((p) => p.contains('/research/MSFT')), isFalse);
      expect(api.calls, isEmpty);
    },
  );
  for (final language in AppLanguage.values) {
    for (final size in [
      const Size(1487, 1058),
      const Size(1280, 720),
      const Size(390, 844),
    ]) {
      testWidgets(
        'connected desk real entry tasks and valuation $language $size',
        (tester) async {
          final api = HomeFixtureApi();
          await mountHome(tester, size, language, api);
          expect(
            find.text(language == AppLanguage.en ? 'Research desk' : '研究工作台'),
            findsOneWidget,
          );
          if (size.width < 1200) {
            await tester.tap(
              find.widgetWithText(
                ChoiceChip,
                language == AppLanguage.en ? 'Holdings' : '持仓',
              ),
            );
            await tester.pumpAndSettle();
          }
          expect(
            find.byKey(const ValueKey('home-holding-TEST')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('home-holding-OPTION')),
            findsNothing,
          );
          expect(find.text('20.00%'), findsOneWidget);
          if (size.width < 1200) {
            await tester.ensureVisible(
              find.widgetWithText(
                ChoiceChip,
                language == AppLanguage.en ? 'Research' : '研究',
              ),
            );
            await tester.tap(
              find.widgetWithText(
                ChoiceChip,
                language == AppLanguage.en ? 'Research' : '研究',
              ),
            );
            await tester.pumpAndSettle();
          }
          expect(find.text(r'$30.00'), findsOneWidget);
          expect(find.text(r'$50.00'), findsOneWidget);
          expect(
            find.text(
              language == AppLanguage.en
                  ? 'SAVED · Watch · 2026-06-01'
                  : 'SAVED · 观察 · 2026-06-01',
            ),
            findsOneWidget,
          );
          expect(api.calls, isEmpty);
          final valuation = find.text(
            language == AppLanguage.en ? 'Open TEST valuation' : '打开 TEST 估值',
          );
          await tester.ensureVisible(valuation);
          await tester.tap(valuation);
          await tester.pumpAndSettle();
          expect(
            find.text('Discover / Test manager / 2026-03-31'),
            findsOneWidget,
          );
          expect(
            api.reads.where((p) => p.contains('/research/TEST')).length,
            2,
          );
          expect(
            find.text(
              language == AppLanguage.en
                  ? 'Your assumptions. Your valuation.'
                  : '你的假设，你的估值。',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'desk quarterly history retains exact manager filing and ticker',
    (tester) async {
      final api = HomeFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.tap(find.text('View quarterly history'));
      await tester.pumpAndSettle();
      final research = find.text('Research TEST');
      await tester.ensureVisible(research);
      await tester.tap(research);
      await tester.pumpAndSettle();
      expect(find.text('Discover / Test manager / 2026-03-31'), findsOneWidget);
      expect(find.text('Filed 2026-05-15'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desk research failure removes old chart and retry keeps identity',
    (tester) async {
      final api = DeskFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      api.failExample = true;
      await tester.tap(find.byKey(const ValueKey('home-holding-ISRG')));
      await tester.pumpAndSettle();
      expect(find.byType(ValuationTrendChart), findsNothing);
      expect(find.text(r'$30.00'), findsNothing);
      expect(
        find.textContaining('Research is unavailable for ISRG'),
        findsOneWidget,
      );
      api.failExample = false;
      await tester.tap(find.text('Retry research'));
      await tester.pumpAndSettle();
      expect(find.text('Open ISRG valuation'), findsOneWidget);
      expect(find.byType(ValuationTrendChart), findsOneWidget);
      expect(api.calls, isEmpty);
    },
  );
  testWidgets(
    'desk blank search does not open a default and direct search is explicit',
    (tester) async {
      final api = HomeFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.tap(find.byTooltip('Search desk'));
      await tester.pumpAndSettle();
      expect(api.reads.where((p) => p.contains('/research/')).length, 1);
      await tester.enterText(
        find.byKey(const ValueKey('home-company-search')),
        'ISRG',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open company research: ISRG'));
      await tester.pumpAndSettle();
      expect(api.reads.any((p) => p.contains('/research/ISRG')), isTrue);
      expect(find.text('Direct company research'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desk quarter keeps exact claim and excludes future filing positions',
    (tester) async {
      final api = DeskFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      await tester.tap(find.byKey(const ValueKey('home-holding-ISRG')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-quarter-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2025 Q4 · 2026-02-15 · filing'));
      await tester.pumpAndSettle();
      expect(find.text('Open ISRG valuation'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-detail-position')));
      await tester.pumpAndSettle();
      expect(find.text('50'), findsOneWidget);
      expect(find.text('150'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Weight'));
      await tester.pumpAndSettle();
      expect(find.text('10.00%'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('desk filing dialog exposes exact accession and source', (
    tester,
  ) async {
    final api = DeskFixtureApi();
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    await tester.ensureVisible(find.text('View filing'));
    await tester.tap(find.text('View filing'));
    await tester.pumpAndSettle();
    expect(find.text('2026 Q1 · new-filing'), findsOneWidget);
    expect(
      find.text('https://www.sec.gov/Archives/test-fixture'),
      findsOneWidget,
    );
    expect(find.text('Open SEC filing'), findsOneWidget);
    expect(api.calls, isEmpty);
  });
  testWidgets(
    'desk confirmed missing PIT keeps filing and history without misleading retry',
    (tester) async {
      final api = DeskFixtureApi()..notCovered = true;
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      expect(
        find.textContaining('No PIT research is available for TEST'),
        findsOneWidget,
      );
      expect(find.text('Retry research'), findsNothing);
      expect(find.text('View filing'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-detail-position')));
      await tester.pumpAndSettle();
      expect(find.text('200'), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
      await tester.tap(find.text('View filing'));
      await tester.pumpAndSettle();
      expect(find.text('Open SEC filing'), findsOneWidget);
    },
  );
  testWidgets(
    'desk mismatched research ticker never creates a substituted valuation',
    (tester) async {
      final api = DeskFixtureApi()..wrongResearch = true;
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      expect(find.byType(ValuationTrendChart), findsNothing);
      expect(
        find.textContaining('Research is unavailable for TEST'),
        findsOneWidget,
      );
      expect(find.text('Open TEST valuation'), findsNothing);
    },
  );
  testWidgets(
    'desk switching managers clears prior stock and ignores late response',
    (tester) async {
      final api = DeskFixtureApi();
      await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
      api.heldIsrg = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('home-holding-ISRG')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('home-investor-gavin-baker')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-holding-ISRG')), findsNothing);
      expect(find.text('Open ALAB valuation'), findsOneWidget);
      api.heldIsrg!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open ALAB valuation'), findsOneWidget);
      expect(find.text('Open ISRG valuation'), findsNothing);
    },
  );
  testWidgets('desk search selects a disclosed holding inside the workbench', (
    tester,
  ) async {
    final api = DeskFixtureApi();
    await mountHome(tester, const Size(1487, 1058), AppLanguage.en, api);
    await tester.enterText(
      find.byKey(const ValueKey('home-company-search')),
      'NVDA',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'NVDA'));
    await tester.pumpAndSettle();
    expect(find.text('Open NVDA valuation'), findsOneWidget);
    expect(find.text('Research desk'), findsOneWidget);
    expect(api.calls, isEmpty);
  });
  for (final language in AppLanguage.values) {
    for (final size in [const Size(1487, 1058), const Size(390, 844)]) {
      testWidgets('populated Guru selection and trajectory $language $size', (
        tester,
      ) async {
        await mountDiscovery(tester, size, language, DiscoveryFixtureApi());
        final add = find.text(
          language == AppLanguage.en ? 'Add a Guru' : '添加经理',
        );
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Test manager'));
        await tester.pumpAndSettle();
        final explore = find.text(
          language == AppLanguage.en ? 'Explore quarterly holdings' : '查看季度持仓',
        );
        await tester.ensureVisible(explore);
        await tester.tap(explore);
        await tester.pumpAndSettle();
        expect(find.text('Test manager'), findsOneWidget);
        expect(
          find.text(
            language == AppLanguage.en ? 'Reported 13F value' : '13F 信息表价值',
          ),
          findsOneWidget,
        );
        final research = find.text(
          language == AppLanguage.en ? 'Research TEST' : '研究 TEST',
        );
        await tester.ensureVisible(research);
        await tester.tap(research);
        await tester.pumpAndSettle();
        expect(
          find.text('Discover / Test manager / 2026-03-31'),
          findsOneWidget,
        );
        expect(
          find.text(
            language == AppLanguage.en ? 'Filed 2026-05-15' : '披露 2026-05-15',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'research records do not imply a trade, position or monitoring rule',
    (tester) async {
      await mountResearch(tester);
      await tester.tap(find.text('Research records'));
      await tester.pumpAndSettle();
      for (final a in ['Watch', 'Pass', 'Invest']) {
        expect(find.widgetWithText(ChoiceChip, a), findsNothing);
      }
      expect(find.widgetWithText(TextField, 'Research units'), findsNothing);
      expect(
        find.widgetWithText(TextField, 'Target portfolio weight %'),
        findsNothing,
      );
      expect(
        find.widgetWithText(TextField, 'Research question'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save research record'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('unsaved assumptions require explicit leave and can be kept', (
    tester,
  ) async {
    await mountResearch(tester);
    await tester.enterText(
      find.byKey(const ValueKey('compact-Cost of equity (Ke)')),
      '11',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this unsaved scenario?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Your scenario'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('compact-Cost of equity (Ke)')),
          )
          .controller!
          .text,
      '11',
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('Guru strategy requires an explicit manager selection', (
    tester,
  ) async {
    await mountDiscovery(
      tester,
      const Size(1487, 1058),
      AppLanguage.en,
      DiscoveryFixtureApi(),
    );
    await tester.tap(find.text('Strategies'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Run backtest'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Choose Gurus'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test manager'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done (1)'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Run backtest'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'changing cutoff from the Home research desk invalidates cached research',
    (tester) async {
      await mountResearch(tester);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('open-home-research-desk')),
      );
      await tester.tap(find.byKey(const ValueKey('open-home-research-desk')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('As of 2026-06-01'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'YYYY-MM-DD'),
        '2026-08-28',
      );
      await tester.tap(find.text('Apply date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Research'));
      await tester.pumpAndSettle();
      expect(find.text('As of 2026-08-28'), findsOneWidget);
      expect(find.text('Research a company'), findsOneWidget);
      expect(find.text('Your scenario'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final language in AppLanguage.values) {
    for (final size in [
      const Size(1487, 1058),
      const Size(1280, 720),
      const Size(1024, 768),
      const Size(390, 844),
    ]) {
      for (final page in [
        'home',
        'research',
        'discover',
        'book',
        'strategies',
      ]) {
        testWidgets(
          'workflow $page $language $size remains usable without overflow',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              MaterialApp(
                home: LanguageScope(
                  language: language,
                  child: InvestmentWorkspace(
                    api: WorkflowTestApi(),
                    palette: Palette(false),
                    initialPage: page,
                    initialTicker: page == 'research' ? 'TEST' : '',
                    initialAsOf: '2026-06-01',
                    onLanguage: (_) {},
                    onLegacy: () {},
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('ThesisForge'), findsOneWidget);
            if (page == 'research') {
              await tester.tap(
                find.byKey(const ValueKey('research-tab-value')),
              );
              await tester.pumpAndSettle();
              await tester.ensureVisible(
                find.text(language == AppLanguage.en ? 'My DCF' : '我的 DCF'),
              );
              await tester.tap(
                find.text(language == AppLanguage.en ? 'My DCF' : '我的 DCF'),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(
                find.text(
                  language == AppLanguage.en ? 'Your scenario' : '你的情景',
                ),
                findsOneWidget,
              );
            }
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  testWidgets('compact percentages preserve exact untouched assumptions', (
    tester,
  ) async {
    final api = await mountResearch(tester);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('compact-Terminal growth (g)')),
          )
          .controller!
          .text,
      '2.47',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('forecast-Year 1 FCFE margin %')),
          )
          .controller!
          .text,
      '22.91',
    );
    await tester.enterText(
      find.byKey(const ValueKey('compact-Cost of equity (Ke)')),
      '11',
    );
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    final a = api.calls.last.$2['assumptions'] as Map;
    expect(a['ke'], .11);
    expect(a['g'], .024698294551041777);
    expect(a['margin'][0], .2290987654321);
    expect(a['margin'][1], .2);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'detailed forecast stays accessible and only edited year changes',
    (tester) async {
      final api = await mountResearch(tester);
      await tester.ensureVisible(find.text('Inspect inputs'));
      await tester.tap(find.text('Inspect inputs'));
      await tester.pumpAndSettle();
      final year3 = find.byKey(const ValueKey('forecast-Year 3 growth %'));
      await tester.ensureVisible(year3);
      await tester.enterText(year3, '12.5');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(api.calls.last.$2['assumptions']['growth'], [
        .1,
        .1,
        .125,
        .1,
        .1,
      ]);
      expect(api.calls.last.$2['assumptions']['g'], .024698294551041777);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('save requires ownership confirmation and cancel never writes', (
    tester,
  ) async {
    final api = await mountResearch(tester);
    await tester.ensureVisible(find.text('Save scenario'));
    await tester.tap(find.text('Save scenario'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save version'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.$1.contains('/scenarios')), isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('date edit is explicit and navigation preserves workspace', (
    tester,
  ) async {
    await mountResearch(tester);
    await tester.tap(find.text('As of 2026-06-01'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'YYYY-MM-DD'),
      '2026-08-28',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('As of 2026-06-01'), findsOneWidget);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Research'));
    await tester.pumpAndSettle();
    expect(find.text('Your scenario'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
