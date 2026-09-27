import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_fundamentals_test.dart' as facts;

// The four-card explorer is retired. Test its evidence responsibilities through
// the actual facts-first workspace. Classification gates remain unit-tested.
void main() {
  test('manager sides remain exclusive, sorted, null-safe and immutable', () {
    final rows = [
      {'name': 'B', 'action': 'new', 'weight': null},
      {'name': 'A', 'action': 'increased', 'weight': .2},
      {'name': 'C', 'action': 'sold_out', 'weight': 0},
      {'name': 'D', 'action': 'mixed_claims', 'weight': .5},
    ];
    expect(discoverManagerSide(rows, additions: true).map((m) => m['name']), [
      'A',
      'B',
    ]);
    expect(discoverManagerSide(rows, additions: false).single['name'], 'C');
    expect(rows.first['name'], 'B');
    expect(
      discoverShareChange({'previousShares': 100, 'changeShares': -50}),
      -.5,
    );
    expect(
      discoverShareChange({'previousShares': 0, 'changeShares': 100}),
      isNull,
    );
    expect(discoverShareChange({'previousShares': 100}), isNull);
  });
  for (final size in [
    const Size(1487, 1058),
    const Size(1280, 720),
    const Size(390, 844),
  ]) {
    for (final lang in AppLanguage.values) {
      for (final tab in [
        ('business', 'Business', '经营研究'),
        ('financials', 'Financials', '财务趋势'),
        ('valuation', 'Valuation', '估值拆解'),
        ('13f', '13F insights', '13F 洞察'),
      ]) {
        testWidgets('current ${tab.$1} evidence $size $lang', (t) async {
          final api = facts.FundamentalApi();
          await facts.mount(t, api, width: size.width, language: lang);
          t.view.physicalSize = size;
          await t.pumpAndSettle();
          if (size.width < 900) {
            await facts.tap(t, find.byKey(const ValueKey('fund-row-UBER')));
          }
          await facts.tap(
            t,
            find.text(lang == AppLanguage.en ? tab.$2 : tab.$3),
          );
          expect(
            find.byKey(const ValueKey('fundamental-detail-tabs')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('discover-collection-growth')),
            findsNothing,
          );
          if (tab.$1 == 'business') {
            await facts.tap(
              t,
              find.byKey(const ValueKey('fundamental-evidence-expansion')),
            );
            expect(
              find.textContaining(
                lang == AppLanguage.en
                    ? 'Fact OS does not explain causality'
                    : 'Fact OS 不解释因果',
              ),
              findsOneWidget,
            );
          } else if (tab.$1 == 'financials') {
            expect(
              find.text(
                lang == AppLanguage.en
                    ? 'Growth and operating conversion'
                    : '增长与经营转化',
              ),
              findsOneWidget,
            );
            expect(
              find.text(lang == AppLanguage.en ? 'Target P / E' : '目标市盈率'),
              findsNothing,
            );
          } else if (tab.$1 == 'valuation') {
            expect(
              find.text(lang == AppLanguage.en ? 'Target P / E' : '目标市盈率'),
              findsOneWidget,
            );
            expect(
              find.text(lang == AppLanguage.en ? 'Discount rate' : '折现率'),
              findsOneWidget,
            );
          } else {
            expect(
              api.calls.where((p) => p.contains('/13f-insights/')).length,
              1,
            );
            expect(find.text('Fixture Capital'), findsOneWidget);
            expect(
              find.text(
                lang == AppLanguage.en
                    ? 'Institution count history'
                    : '持有机构数量变化',
              ),
              findsOneWidget,
            );
            expect(
              find.text(
                lang == AppLanguage.en
                    ? 'Institutional ownership history'
                    : '机构持股与占总股本变化',
              ),
              findsOneWidget,
            );
          }
          expect(api.saved, isFalse);
          expect(t.takeException(), isNull);
        });
      }
    }
  }
  testWidgets(
    'switching evidence changes content and fetches holdings only on demand',
    (t) async {
      final api = facts.FundamentalApi();
      await facts.mount(t, api);
      expect(api.calls.where((p) => p.contains('/13f-insights/')), isEmpty);
      await facts.tap(t, find.text('Valuation'));
      expect(find.text('Target P / E'), findsOneWidget);
      await facts.tap(t, find.text('Financials'));
      expect(find.text('Target P / E'), findsNothing);
      await facts.tap(t, find.text('13F insights'));
      expect(find.text('Fixture Capital'), findsOneWidget);
      expect(api.saved, isFalse);
    },
  );
  testWidgets(
    'research handoff and restored selection preserve ticker, cutoff and tab',
    (t) async {
      final api = facts.FundamentalApi();
      final opened = <(String, String)>[];
      await facts.mount(t, api, onCompany: (a, b) => opened.add((a, b)));
      await facts.tap(t, find.byKey(const ValueKey('fund-open-research')));
      expect(opened, [('UBER', 'financials')]);
      await t.pumpWidget(const SizedBox());
      await facts.mount(
        t,
        api,
        selection: {'ticker': 'UBER', 'detailTab': 'valuation'},
      );
      expect(find.text('Published valuation, fully explained'), findsOneWidget);
      expect(
        api.calls
            .where((p) => p.contains('/fundamentals/UBER?'))
            .every((p) => p.contains('asOf=2026-09-21')),
        isTrue,
      );
    },
  );
  testWidgets(
    'missing valuation keeps fact-only research without inventing a model',
    (t) async {
      final api = facts.FundamentalApi();
      final opened = <(String, String)>[];
      await facts.mount(t, api, onCompany: (a, b) => opened.add((a, b)));
      await facts.tap(t, find.byKey(const ValueKey('fund-row-FACT')));
      expect(find.text('No valuation model'), findsOneWidget);
      await facts.tap(t, find.text('Valuation'));
      expect(find.text('Target P / E'), findsNothing);
      await facts.tap(t, find.text('Business'));
      await facts.tap(t, find.byKey(const ValueKey('fund-open-research')));
      expect(opened, [('FACT', 'financials')]);
      expect(api.saved, isFalse);
    },
  );
}
