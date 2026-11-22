import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class CopycatPlaybookFixtureApi extends ApiClient {
  CopycatPlaybookFixtureApi() : super(() => 'test');

  static Map<String, dynamic>? _cachedArtifact;
  static Map<String, dynamic> get artifact => _cachedArtifact ??=
      jsonDecode(
            File(
              'server/config/guru-copycat-playbook-dashboard.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  final calls = <String>[];
  bool fail = false;

  Map<String, dynamic> dashboardResponse(Uri uri) {
    final raw = artifact;
    final qp = uri.queryParameters;
    final cutoff = qp['asOf'] ?? '2026-11-22';
    final schemeParam = qp['scheme'] ?? 'qqq80_exqqq_monopoly';
    final normalizedWeightMode = qp['weightMode'] == 'equal'
        ? 'equal'
        : 'conviction';

    final rawSchemes = List<dynamic>.from(raw['schemes'] as List? ?? []);
    final schemeIds = rawSchemes
        .map((s) => (s as Map)['id'].toString())
        .toList();
    final schemeId = schemeIds.contains(schemeParam)
        ? schemeParam
        : 'qqq80_exqqq_monopoly';

    final snapsByScheme = Map<String, dynamic>.from(
      raw['snapshotsByScheme'] as Map? ?? {},
    );
    final snapKey = normalizedWeightMode == 'equal' &&
            snapsByScheme['${schemeId}_equal'] is List
        ? '${schemeId}_equal'
        : schemeId;
    final rawSnaps = List<dynamic>.from(snapsByScheme[snapKey] as List? ?? [])
        .map((s) => Map<String, dynamic>.from(s as Map))
        .where((s) => (s['filedAt']?.toString() ?? '').compareTo(cutoff) <= 0)
        .toList();

    if (rawSnaps.isEmpty) {
      return {
        'version': raw['version'],
        'asOf': cutoff,
        'status': 'pre_history',
        'selectedSchemeId': schemeId,
        'weightMode': normalizedWeightMode,
        'schemes': <dynamic>[],
        'snapshotTimeline': <dynamic>[],
        'activeSnapshot': null,
        'latestBlotterSnapshot': null,
        'masterBlueprint16': <dynamic>[],
        'guruExitsAndSlashes': <dynamic>[],
        'q1HfDumpRadar': <dynamic>[],
        'guruRoster': <dynamic>[],
        'positionCountSensitivity': <dynamic>[],
        'antiPatterns': <dynamic>[],
      };
    }

    final requestedQuarter = qp['quarter'] ?? '';
    Map<String, dynamic>? activeSnapshot;
    if (requestedQuarter.isNotEmpty) {
      for (final s in rawSnaps) {
        if (s['quarterDate'] == requestedQuarter ||
            s['quarter'] == requestedQuarter) {
          activeSnapshot = jsonDecode(jsonEncode(s)) as Map<String, dynamic>;
          break;
        }
      }
    }
    activeSnapshot ??=
        jsonDecode(jsonEncode(rawSnaps.last)) as Map<String, dynamic>;
    final latestBlotterSnapshot =
        jsonDecode(jsonEncode(rawSnaps.last)) as Map<String, dynamic>;

    final schemes = rawSchemes.map((item) {
      final sc = jsonDecode(jsonEncode(item)) as Map<String, dynamic>;
      final hasEq = sc['equalWeightVariant'] != null;
      final useEq = hasEq && normalizedWeightMode == 'equal';
      return {
        ...sc,
        'activeWeightMode': hasEq ? normalizedWeightMode : 'default',
        'metrics': useEq ? sc['equalWeightVariant'] : sc['metrics'],
        if (hasEq) 'convictionVariant': sc['metrics'],
      };
    }).toList();

    final timeline = rawSnaps.map((s) {
      final copy = Map<String, dynamic>.from(s);
      final holdings = copy.remove('holdings') as List? ?? const [];
      return {...copy, 'holdingsCount': holdings.length};
    }).toList();

    final dailyCurves = raw['dailyCurves'] as Map<String, dynamic>?;
    Map<String, dynamic>? slicedDailyCurve;
    if (dailyCurves != null) {
      final dcDates = List<String>.from(dailyCurves['dates'] as List? ?? []);
      final dcSeries = Map<String, dynamic>.from(
        dailyCurves['series'] as Map? ?? {},
      );
      final eqKey = '${schemeId}_equal';
      final seriesKey =
          normalizedWeightMode == 'equal' && dcSeries[eqKey] is List
          ? eqKey
          : schemeId;
      final sNav = List<dynamic>.from(dcSeries[seriesKey] as List? ?? []);
      final spyNav = List<dynamic>.from(dcSeries['SPY'] as List? ?? []);
      final qqqNav = List<dynamic>.from(dcSeries['QQQ'] as List? ?? []);
      var endIdx = -1;
      for (var i = 0; i < dcDates.length; i++) {
        if (dcDates[i].compareTo(cutoff) <= 0) {
          endIdx = i;
        } else {
          break;
        }
      }
      if (endIdx >= 1 &&
          sNav.length > endIdx &&
          spyNav.length > endIdx &&
          qqqNav.length > endIdx) {
        final end = endIdx + 1;
        slicedDailyCurve = {
          'startDate': dcDates.first,
          'endDate': dcDates[endIdx],
          'tradingDays': end,
          'dates': dcDates.sublist(0, end),
          'schemeNav': sNav.sublist(0, end),
          'spyNav': spyNav.sublist(0, end),
          'qqqNav': qqqNav.sublist(0, end),
        };
      }
    }

    return {
      'version': raw['version'],
      'generatedAt': raw['generatedAt'],
      'factGeneration': raw['factGeneration'],
      'asOf': cutoff,
      'latestQuarter': latestBlotterSnapshot['quarter'],
      'latestQuarterDate': latestBlotterSnapshot['quarterDate'],
      'latestFiledDate': latestBlotterSnapshot['filedAt'],
      'latestPriceDate': raw['latestPriceDate'],
      'selectedSchemeId': schemeId,
      'weightMode': normalizedWeightMode,
      'selectedQuarterDate': activeSnapshot['quarterDate'],
      'rebalanceSchedule': raw['rebalanceSchedule'],
      'backtestWindow': raw['backtestWindow'],
      'benchmarks': raw['benchmarks'],
      'dailyCurve': slicedDailyCurve,
      'schemes': schemes,
      'positionCountSensitivity': raw['positionCountSensitivity'] ?? [],
      'antiPatterns': raw['antiPatterns'] ?? [],
      'latestBlotterSnapshot': latestBlotterSnapshot,
      'masterBlueprint16': raw['masterBlueprint16'] ?? [],
      'guruExitsAndSlashes': raw['guruExitsAndSlashes'] ?? [],
      'q1HfDumpRadar': raw['q1HfDumpRadar'] ?? [],
      'guruRoster': raw['guruRoster'] ?? [],
      'snapshotTimeline': timeline,
      'activeSnapshot': activeSnapshot,
    };
  }

  Map<String, dynamic> snapshotResponse(Uri uri) {
    final full = dashboardResponse(uri);
    return {
      'asOf': uri.queryParameters['asOf'] ?? '2026-11-22',
      'schemeId': full['selectedSchemeId'],
      'snapshot': full['activeSnapshot'],
    };
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(path);
    if (fail) throw StateError('copycat network error');
    final uri = Uri.parse(path);
    if (uri.path.endsWith('/guru-copycat-playbook/snapshot')) {
      return snapshotResponse(uri);
    }
    if (uri.path.endsWith('/guru-copycat-playbook')) {
      return dashboardResponse(uri);
    }
    if (uri.path.contains('/13f-insights')) {
      return {'quarter': '2026-Q3', 'quarters': ['2026-Q3'], 'stocks': []};
    }
    if (uri.path.contains('/home')) {
      return {'attention': [], 'watchlist': []};
    }
    if (uri.path.contains('/gurus/')) {
      return {
        'guru': {
          'id': 'chris-hohn',
          'displayName': 'Chris Hohn',
          'firm': 'TCI Fund Management',
        },
        'filings': [],
        'holdings': [],
      };
    }
    return {};
  }
}

Future<void> mountCopycatPanel(
  WidgetTester tester,
  CopycatPlaybookFixtureApi api, {
  Size size = const Size(1440, 1200),
  AppLanguage language = AppLanguage.en,
  Map<String, dynamic> initialSelection = const {},
  ValueChanged<String>? onCompany,
  ValueChanged<String>? onExploreGuru,
  ValueChanged<Map<String, dynamic>>? onSelection,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: LanguageScope(
        language: language,
        child: Scaffold(
          backgroundColor: const Color(0xFF06090F),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: GuruCopycatPlaybookPanel(
              api: api,
              palette: Palette(false),
              asOf: '2026-11-22',
              initialSelection: initialSelection,
              onSelection: onSelection,
              onCompany: onCompany ?? (_) {},
              onExploreGuru: onExploreGuru ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Discover replaces Fundamentals tab with Copycat Playbook right after Guru and redirects legacy fundamentals URL',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = CopycatPlaybookFixtureApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'discover',
              initialTicker: '',
              initialAsOf: '2026-11-22',
              initialQuery: const {'discoverTab': 'fundamentals'},
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Fundamentals'), findsNothing);
      expect(find.text('Copycat Playbook'), findsWidgets);
      expect(
        find.byKey(const ValueKey('guru-copycat-playbook-root')),
        findsOneWidget,
      );
      expect(
        api.calls.any((c) => c.contains('/api/investment/guru-copycat-playbook')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'defaults to 80% QQQ + 20% Ex-QQQ Monopoly flagship, toggles Top-8 Equal-Weight, removes hf4_smart_flow, and switches all 5 schemes',
    (tester) async {
      final api = CopycatPlaybookFixtureApi();
      final endDate =
          ((CopycatPlaybookFixtureApi.artifact['dailyCurves']
                      as Map<String, dynamic>)['endDate'] ??
                  '2026-11-20')
              .toString();
      Map<String, dynamic> latestSelection = {};
      await mountCopycatPanel(
        tester,
        api,
        initialSelection: const {'scheme': 'hf4_smart_flow'},
        onSelection: (s) => latestSelection = s,
      );

      // hf4_smart_flow is completely removed and falls back to qqq80_exqqq_monopoly
      expect(
        find.byKey(const ValueKey('copycat-scheme-hf4_smart_flow')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('copycat-scheme-qqq80_exqqq_monopoly')),
        findsOneWidget,
      );
      expect(find.textContaining('NAV Through $endDate'), findsWidgets);
      expect(find.textContaining('vs QQQ'), findsWidgets);
      expect(
        find.byKey(const ValueKey('copycat-blotter-ticker-V')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('copycat-blotter-ticker-TSM')),
        findsNothing,
      );

      // Toggle flagship to Top-8 Equal-Weight (adds TSM, PGR, TDG)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-weight-equal')),
      );
      expect(latestSelection['weightMode'], 'equal');
      expect(
        find.byKey(const ValueKey('copycat-blotter-ticker-TSM')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('copycat-blotter-ticker-PGR')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('copycat-blotter-ticker-TDG')),
        findsOneWidget,
      );

      // Switch across remaining 4 schemes cleanly
      for (final sid in [
        'barbell_70_30',
        'monopoly_compounders',
        'pre2014_legends',
        'new_adds_catalyst',
      ]) {
        await tapVisible(tester, find.byKey(ValueKey('copycat-scheme-$sid')));
        expect(latestSelection['scheme'], sid);
      }

      // Toggle Drawdown chart mode & Log/Linear toggle
      await tapVisible(tester, find.byKey(const ValueKey('copycat-chart-dd')));
      await tapVisible(tester, find.byKey(const ValueKey('copycat-chart-nav')));
      await tapVisible(tester, find.byKey(const ValueKey('copycat-chart-log')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switches all 4 current-quarter blotter tabs, exposes NBIS HF Dump conflict, and navigates to Company Research on ticker click',
    (tester) async {
      final api = CopycatPlaybookFixtureApi();
      final openedTickers = <String>[];
      await mountCopycatPanel(
        tester,
        api,
        onCompany: openedTickers.add,
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-blotter-filter-discount')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-blotter-filter-all')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-blotter-ticker-GE')),
      );
      expect(openedTickers, contains('GE'));

      // Tab 2: 16-Stock Master Blueprint
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-blotter-tab-blueprint16')),
      );
      expect(find.textContaining('42%'), findsWidgets);
      expect(find.text('SPGI'), findsWidgets);
      expect(find.text('AMZN'), findsWidgets);

      // Tab 3: Q3 Exits & >50% Slashes
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-blotter-tab-exits')),
      );
      expect(tester.takeException(), isNull);

      // Tab 4: Q1 HF Dump Minefield Radar (RDDT, RVMD, NBIS conflict warning)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-blotter-tab-q1dump')),
      );
      expect(find.text('RDDT'), findsWidgets);
      expect(find.text('NBIS'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'filters & sorts 16 tracked gurus, inspects Top-12 holdings drawer, and launches Guru Dossier',
    (tester) async {
      final api = CopycatPlaybookFixtureApi();
      final openedGurus = <String>[];
      await mountCopycatPanel(
        tester,
        api,
        onExploreGuru: openedGurus.add,
      );

      expect(
        find.byKey(const ValueKey('copycat-guru-drawer-TCIFUN')),
        findsOneWidget,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-open-dossier-TCIFUN')),
      );
      expect(openedGurus, ['chris-hohn']);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-guru-bucket-L2_CATALYST')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-guru-DUQUES')),
      );
      expect(
        find.byKey(const ValueKey('copycat-guru-drawer-DUQUES')),
        findsOneWidget,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-guru-bucket-all')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-guru-sort-cagr')),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explores 51-quarter historical rebalance snapshots (2014 Q1 – 2026 Q3) with Entered/Exited diff & attribution',
    (tester) async {
      final api = CopycatPlaybookFixtureApi();
      await mountCopycatPanel(tester, api);

      await tapVisible(tester, find.byKey(const ValueKey('copycat-snap-prev')));
      expect(
        api.calls.any(
          (c) =>
              c.contains('/guru-copycat-playbook/snapshot') &&
              c.contains('quarter=2026-06-30'),
        ),
        isTrue,
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-snap-tile-2022-06-30')),
      );
      expect(find.textContaining('2022 Q2'), findsWidgets);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('copycat-snap-tile-2014-03-31')),
      );
      expect(find.textContaining('2014 Q1'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  for (final lang in AppLanguage.values) {
    for (final viewport in const [
      Size(1440, 900),
      Size(768, 1024),
      Size(390, 844),
    ]) {
      testWidgets(
        'renders zero overflow across $viewport in $lang',
        (tester) async {
          final api = CopycatPlaybookFixtureApi();
          await mountCopycatPanel(
            tester,
            api,
            size: viewport,
            language: lang,
          );
          expect(
            find.byKey(const ValueKey('guru-copycat-playbook-root')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
