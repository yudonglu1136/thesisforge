import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_portfolio_test.dart' as detail;
import 'investment_portfolio_home_test.dart' as home;
import 'investment_portfolio_privacy_test.dart' as privacy;

class LinkedModelHomeApi extends home.HomeApi {
  @override
  Map<String, dynamic> group(String currency) {
    final result = super.group(currency);
    result['positions'] = (result['positions'] as List).map((raw) {
      final row = Map<String, dynamic>.from(raw as Map);
      return row['ticker'] == 'AAA'
          ? {
              ...row,
              'model': {...asMap(row['model']), 'modelTicker': 'AAA.A'},
            }
          : row;
    }).toList();
    return result;
  }
}

// Synthetic fixtures are test-only. Nothing here is served by the local API.
void main() {
  setUp(() => portfolioPrivacyMode.value = false);
  tearDown(() => portfolioPrivacyMode.value = false);

  test(
    'valuation navigation follows explicit model link, never a guessed share class',
    () {
      final group = <String, dynamic>{
        'positions': [
          {
            'ticker': 'GOOG',
            'model': {'modelTicker': 'GOOGL'},
          },
          {'ticker': 'NVDA', 'model': {}},
        ],
      };
      expect(portfolioValuationTicker(group, 'GOOG'), 'GOOGL');
      expect(portfolioValuationTicker(group, 'NVDA'), 'NVDA');
      expect(portfolioValuationTicker(group, 'BRK.B'), 'BRK.B');
    },
  );

  test(
    'allocation keeps report weights, aggregates tail, excludes negative slices',
    () {
      final source = <Map<String, dynamic>>[
        {'ticker': 'A', 'weight': .35},
        {'ticker': 'B', 'weight': .25},
        {'ticker': 'C', 'weight': .20},
        {'ticker': 'D', 'weight': .10},
        {'ticker': 'E', 'weight': .04},
        {'ticker': 'F', 'weight': .03},
        {'ticker': 'G', 'weight': .03},
        {'ticker': 'SHORT', 'weight': -.1},
        {'ticker': 'BAD', 'weight': double.nan},
      ];
      final slices = portfolioAllocationSlices(source);
      expect(slices.length, 6);
      expect(slices.first, {'name': 'A', 'weight': .35});
      expect(slices.last['weight'], closeTo(.06, 1e-10));
      expect(slices.last['aggregate'], true);
      expect(source.length, 9);
      expect(
        portfolioAllocationSlices([
          {'ticker': 'BAD', 'weight': 1.4},
        ]),
        isEmpty,
      );
      final partial = portfolioAllocationSlices([
        {'ticker': 'A', 'weight': .4},
      ]);
      expect(partial.last, {
        'name': 'Unspecified',
        'weight': .6,
        'aggregate': true,
      });
      expect(portfolioAllocationSlices([]), isEmpty);
    },
  );

  testWidgets(
    'Portfolio overview has real NAV and P&L controls, not a simulated substitute',
    (t) async {
      await detail.mount(
        t,
        home.HomeApi()
          ..history = true
          ..pnlHistory = true,
      );
      expect(find.byKey(const ValueKey('actual-nav-chart')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('portfolio-allocation-donut')),
        findsOneWidget,
      );
      expect(find.text('Holdings & model structure'), findsOneWidget);
      expect(find.text('Model architecture'), findsOneWidget);
      await detail.tap(
        t,
        find.byKey(const ValueKey('history-metric-realized')),
      );
      expect(find.byKey(const ValueKey('realized-pnl-chart')), findsOneWidget);
      await detail.tap(
        t,
        find.byKey(const ValueKey('history-metric-cashAdjusted')),
      );
      expect(
        find.byKey(const ValueKey('cashAdjusted-pnl-chart')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'legend selection highlights a holding and opens exact valuation; sectors remain selectable',
    (t) async {
      final actions = <(String, String)>[];
      await detail.mount(
        t,
        home.HomeApi()..history = true,
        onCompany: (a, b) => actions.add((a, b)),
      );
      await detail.tap(t, find.byKey(const ValueKey('allocation-legend-AAA')));
      expect(find.text('Research AAA'), findsOneWidget);
      await detail.tap(t, find.text('Research AAA'));
      expect(actions, [('AAA', 'value')]);
      await detail.tap(t, find.text('Sectors'));
      expect(
        find.byKey(const ValueKey('allocation-legend-Unclassified')),
        findsOneWidget,
      );
      expect(find.text('Research AAA'), findsNothing);
      await detail.tap(t, find.text('Holdings').first);
      expect(
        find.byKey(const ValueKey('allocation-legend-AAA')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'new dashboard respects privacy in all history modes and currencies',
    (t) async {
      await detail.mount(t, privacy.PrivacyApi());
      await detail.tap(t, privacy.privacyToggle);
      for (final mode in ['realized', 'cashAdjusted', 'nav']) {
        await detail.tap(t, find.byKey(ValueKey('history-metric-$mode')));
        privacy.expectNoAmounts(t);
      }
      await detail.tap(t, find.text('EUR · 1 accounts'));
      privacy.expectNoAmounts(t);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'allocation keeps held share class but opens disclosed economic model',
    (t) async {
      final actions = <(String, String)>[];
      await detail.mount(
        t,
        LinkedModelHomeApi()..history = true,
        onCompany: (symbol, section) => actions.add((symbol, section)),
      );
      await detail.tap(t, find.byKey(const ValueKey('allocation-legend-AAA')));
      expect(
        find.textContaining('AAA uses the AAA.A economic per-share model.'),
        findsOneWidget,
      );
      await detail.tap(t, find.text('Research AAA'));
      expect(actions, [('AAA.A', 'value')]);
      expect(t.takeException(), isNull);
    },
  );

  for (final lang in AppLanguage.values) {
    testWidgets(
      'Portfolio visual dashboard fits 390px at 150% text in ${lang.name}',
      (t) async {
        await detail.mount(
          t,
          privacy.PrivacyApi(),
          size: const Size(390, 844),
          lang: lang,
          scale: 1.5,
        );
        expect(t.takeException(), isNull);
        await detail.tap(
          t,
          find.byKey(const ValueKey('allocation-legend-AAA')),
        );
        expect(t.takeException(), isNull);
        await detail.tap(
          t,
          find.text(lang == AppLanguage.en ? 'Sectors' : '行业'),
        );
        expect(t.takeException(), isNull);
        await detail.tap(t, privacy.privacyToggle);
        privacy.expectNoAmounts(t);
        expect(t.takeException(), isNull);
      },
    );
  }
}
