import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

final testIncome = <String, dynamic>{
  'status': 'ready',
  'fromDate': '2026-01-01',
  'toDate': '2026-09-09',
  'grossReceived': 100,
  'reversals': -2,
  'byType': [
    {'id': 'dividends', 'category': 'dividends', 'amount': 60, 'weight': .6},
    {
      'id': 'bond_interest',
      'category': 'bond_interest',
      'amount': 30,
      'weight': .3,
    },
    {
      'id': 'cash_interest',
      'category': 'cash_interest',
      'amount': 10,
      'weight': .1,
    },
  ],
  'byInstrument': [
    {
      'id': 'div-AAA',
      'ticker': 'AAA',
      'category': 'dividends',
      'amount': 60,
      'weight': .6,
    },
    {
      'id': 'int-BOND',
      'ticker': 'BOND',
      'category': 'bond_interest',
      'amount': 30,
      'weight': .3,
    },
    {
      'id': 'int-CASH',
      'ticker': 'CASH',
      'category': 'cash_interest',
      'amount': 10,
      'weight': .1,
    },
  ],
};

Future<void> mount(
  WidgetTester t,
  Widget child, {
  Size size = const Size(900, 1000),
  AppLanguage lang = AppLanguage.en,
  double scale = 1,
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
              child: Padding(padding: const EdgeInsets.all(16), child: child),
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

Widget donut({bool hidden = false, Map<String, dynamic>? income}) =>
    PortfolioAllocationChart(
      palette: Palette(false),
      onHolding: (_) {},
      hideAmounts: hidden,
      group: {
        'currency': 'USD',
        'top5Weight': 1,
        'concentration': [
          {'ticker': 'AAA', 'weight': .8, 'value': 800},
          {'ticker': 'BBB', 'weight': .2, 'value': 200},
        ],
        'sectors': [
          {'name': 'Unclassified', 'weight': 1, 'value': 1000},
        ],
        'home': {
          'history': {'income': income ?? testIncome},
        },
      },
    );
String detail(WidgetTester t) => t
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('allocation-hover-detail')),
        matching: find.byType(Text),
      ),
    )
    .map((w) => w.data ?? '')
    .join(' ');

void main() {
  testWidgets(
    'YTD uses the data year and previous year-end NAV; P&L rebases separately',
    (t) async {
      await mount(
        t,
        PortfolioAccountValueChart(
          palette: Palette(false),
          currency: 'USD',
          hideAmounts: true,
          rows: const [
            {'date': '2023-12-29', 'nav': 1000},
            {'date': '2024-01-02', 'nav': 1050},
            {'date': '2024-02-29', 'nav': 1300},
          ],
          history: const {
            'realized': {
              'rows': [
                {'date': '2023-12-29', 'cumulativePnl': 50, 'pnl': 50},
                {'date': '2024-01-02', 'cumulativePnl': 80, 'pnl': 30},
                {'date': '2024-02-29', 'cumulativePnl': 100, 'pnl': 20},
              ],
            },
          },
        ),
      );
      await tap(t, find.byKey(const ValueKey('history-range-YTD')));
      expect(find.text('YTD 2024 · through 2024-02-29'), findsOneWidget);
      expect(find.text('2024-02-29 · +30.00%'), findsOneWidget);
      expect(find.textContaining('Partial history:'), findsNothing);
      await tap(t, find.byKey(const ValueKey('history-metric-realized')));
      expect(find.text('2024-02-29 · +5.00%'), findsOneWidget);
      expect(find.textContaining('USD 50'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'YTD without a year-end baseline explicitly shows partial available history',
    (t) async {
      await mount(
        t,
        PortfolioAccountValueChart(
          palette: Palette(false),
          currency: 'USD',
          rows: const [
            {'date': '2026-03-01', 'nav': 1000},
            {'date': '2026-09-01', 'nav': 1100},
          ],
        ),
      );
      await tap(t, find.byKey(const ValueKey('history-range-YTD')));
      expect(
        find.textContaining('Partial history: no year-end baseline.'),
        findsOneWidget,
      );
      expect(find.text('2026-09-01 · USD 1,100'), findsOneWidget);
    },
  );
  testWidgets(
    'Income changes the actual slices to dividend/bond/cash receipts with dated provenance',
    (t) async {
      await mount(t, donut());
      expect(
        find.byKey(const ValueKey('allocation-legend-AAA')),
        findsOneWidget,
      );
      await tap(t, find.byKey(const ValueKey('allocation-income')));
      expect(find.byKey(const ValueKey('allocation-legend-AAA')), findsNothing);
      expect(
        find.byKey(const ValueKey('allocation-legend-bond_interest')),
        findsOneWidget,
      );
      expect(
        find.text('Report period · 2026-01-01 → 2026-09-09'),
        findsOneWidget,
      );
      await tap(
        t,
        find.byKey(const ValueKey('allocation-legend-bond_interest')),
      );
      expect(detail(t), contains('Bond interest · 30.0% · USD 30'));
      await tap(t, find.text('Income sources'));
      expect(
        find.byKey(const ValueKey('allocation-legend-int-BOND')),
        findsOneWidget,
      );
      await tap(t, find.byKey(const ValueKey('allocation-legend-int-BOND')));
      expect(detail(t), contains('BOND · Bond interest · 30.0% · USD 30'));
      await tap(t, find.byKey(const ValueKey('allocation-position')));
      expect(
        find.byKey(const ValueKey('allocation-legend-AAA')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('all four allocation controls stay on one horizontal rail', (
    t,
  ) async {
    await mount(t, donut(), size: const Size(900, 1000));
    final keys = [
      const ValueKey('allocation-position'),
      const ValueKey('allocation-income'),
      const ValueKey('allocation-breakdown-primary'),
      const ValueKey('allocation-breakdown-secondary'),
    ];
    final tops = keys
        .map((key) => t.getTopLeft(find.byKey(key)).dy)
        .toList(growable: false);
    expect(tops.toSet().length, 1);
    expect(find.text('Dividends & interest'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  for (final hidden in [false, true]) {
    testWidgets(
      'donut hover updates slice/readout, mouse exit restores pinned selection; privacy=$hidden',
      (t) async {
        await mount(t, donut(hidden: hidden));
        await tap(t, find.byKey(const ValueKey('allocation-income')));
        await tap(
          t,
          find.byKey(const ValueKey('allocation-legend-bond_interest')),
        );
        final pointer = await t.createGesture(kind: PointerDeviceKind.mouse);
        await pointer.addPointer(location: Offset.zero);
        final ring = find.byKey(const ValueKey('portfolio-allocation-donut'));
        final size = t.getSize(ring).width;
        await pointer.moveTo(
          t.getCenter(ring) +
              Offset((size / 2 - 14) * .707, -(size / 2 - 14) * .707),
        );
        await t.pumpAndSettle();
        expect(detail(t), contains('Dividends · 60.0%'));
        expect(detail(t).contains('USD 60'), !hidden);
        await pointer.moveTo(const Offset(5, 5));
        await t.pumpAndSettle();
        expect(detail(t), contains('Bond interest · 30.0%'));
        if (hidden) {
          expect(
            t
                .widgetList<Text>(find.byType(Text))
                .any((w) => (w.data ?? '').contains('USD')),
            false,
          );
          expect(
            t
                .widgetList<Tooltip>(find.byType(Tooltip))
                .any((w) => (w.message ?? '').contains('USD')),
            false,
          );
        }
        await pointer.removePointer();
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'missing and zero income states never substitute holding weights',
    (t) async {
      await mount(t, donut(income: {}));
      await tap(t, find.byKey(const ValueKey('allocation-income')));
      expect(
        find.textContaining('Income history is not available.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('portfolio-allocation-donut')),
        findsNothing,
      );
      await mount(
        t,
        donut(
          income: {
            'status': 'ready',
            'grossReceived': 0,
            'byType': [],
            'byInstrument': [],
          },
        ),
      );
      expect(
        find.text('No positive income receipts in this report period.'),
        findsOneWidget,
      );
    },
  );
  for (final lang in AppLanguage.values) {
    testWidgets('income and source modes fit mobile 150% text ${lang.name}', (
      t,
    ) async {
      await mount(
        t,
        donut(hidden: true),
        size: const Size(390, 844),
        lang: lang,
        scale: 1.5,
      );
      await tap(t, find.byKey(const ValueKey('allocation-income')));
      await tap(
        t,
        find.byKey(const ValueKey('allocation-legend-bond_interest')),
      );
      expect(t.takeException(), isNull);
      await tap(
        t,
        find.text(lang == AppLanguage.en ? 'Income sources' : '收入来源'),
      );
      expect(t.takeException(), isNull);
    });
  }
}
