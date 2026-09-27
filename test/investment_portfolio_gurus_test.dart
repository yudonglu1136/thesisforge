import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_portfolio_test.dart' as fixtures;
import 'investment_portfolio_home_test.dart' as home;

class GuruPortfolioApi extends home.HomeApi {
  @override
  Map<String, dynamic> group(String c) {
    final g = super.group(c);
    final positions = g['positions'] as List;
    positions.first['guruActivity'] = {
      'status': 'available',
      'reportDate': '2026-06-30',
      'reportedManagers': 4,
      'eligibleManagers': 4,
      'extractedBooks': 0,
      'holders': 3,
      'adds': 2,
      'trims': 1,
      'unknown': 0,
      'balance': 'more_adds',
      'rows': [
        for (final (id, action) in [
          ('Alpha', 'new'),
          ('Beta', 'increased'),
          ('Gamma', 'sold_out'),
          ('Delta', 'unchanged'),
        ])
          {
            'guruId': id,
            'name': '$id Guru',
            'avatar': '',
            'accession': '$id-filing',
            'action': action,
            'weight': action == 'sold_out' ? 0 : .15,
            'shareChange': action == 'new' ? null : .1,
            'availableAt': '2026-08-14',
          },
      ],
    };
    positions.last['guruActivity'] = {
      'status': 'no_matches',
      'reportDate': '2026-06-30',
      'reportedManagers': 4,
      'eligibleManagers': 4,
      'extractedBooks': 1,
      'rows': [],
    };
    return g;
  }
}

void main() {
  setUp(() => portfolioPrivacyMode.value = false);
  tearDown(() => portfolioPrivacyMode.value = false);
  testWidgets(
    'holdings combine valuation and full activity; exact Guru filing drilldown',
    (t) async {
      final actions = <(String, String)>[];
      await fixtures.mount(
        t,
        GuruPortfolioApi(),
        onGuru: (a, b) => actions.add((a, b)),
      );
      await fixtures.tap(t, find.text('Holdings & value'));
      expect(find.text('20.0%'), findsWidgets);
      await fixtures.tap(
        t,
        find.byKey(const ValueKey('portfolio-guru-open-AAA')),
      );
      expect(find.text('2 added / new'), findsOneWidget);
      expect(find.text('1 reduced / exited'), findsOneWidget);
      await fixtures.tap(t, find.text('Guru activity · 2026 Q2'));
      expect(find.text('Added & new · 2'), findsOneWidget);
      expect(find.text('Reduced & exited · 1'), findsOneWidget);
      await fixtures.tap(t, find.widgetWithText(OutlinedButton, 'Gamma Guru'));
      expect(actions, [('Gamma', 'Gamma-filing')]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  for (final lang in [AppLanguage.en, AppLanguage.zh]) {
    testWidgets('holdings Guru evidence is accessible at 390px: $lang', (
      t,
    ) async {
      portfolioPrivacyMode.value = true;
      final actions = <(String, String)>[];
      await fixtures.mount(
        t,
        GuruPortfolioApi(),
        size: const Size(390, 844),
        scale: 1.5,
        lang: lang,
        onGuru: (a, b) => actions.add((a, b)),
      );
      await fixtures.tap(
        t,
        find.text(lang == AppLanguage.en ? 'Holdings & value' : '持仓与估值'),
      );
      await fixtures.tap(
        t,
        find.byKey(const ValueKey('portfolio-guru-open-AAA')),
      );
      expect(find.text('USD 1,000'), findsNothing);
      await fixtures.tap(
        t,
        find.text(
          lang == AppLanguage.en ? 'Guru activity · 2026 Q2' : '大佬动向 · 2026 Q2',
        ),
      );
      expect(
        find.text(lang == AppLanguage.en ? 'Added & new · 2' : '加仓与新建 · 2'),
        findsOneWidget,
      );
        await fixtures.tap(t, find.widgetWithText(OutlinedButton, 'Gamma Guru'));
        expect(actions, [('Gamma', 'Gamma-filing')]);
        expect(find.byType(AlertDialog), findsNothing);
      expect(t.takeException(), isNull);
    });
    testWidgets('Home activity fits 390px at 150% with privacy on: $lang', (
      t,
    ) async {
      portfolioPrivacyMode.value = true;
      final actions = <(String, String)>[];
      await home.mount(
        t,
        GuruPortfolioApi(),
        size: const Size(390, 844),
        scale: 1.5,
        lang: lang,
        onCompany: (a, b) => actions.add((a, b)),
      );
      await fixtures.tap(
        t,
        find.text(
          lang == AppLanguage.en ? 'Guru activity · 2026 Q2' : '大佬动向 · 2026 Q2',
        ),
      );
      expect(
        find.text(lang == AppLanguage.en ? 'Added & new · 2' : '加仓与新建 · 2'),
        findsOneWidget,
      );
      expect(find.text('USD 1,000'), findsNothing);
      expect(find.text('USD 3,000'), findsNothing);
      expect(find.textContaining('15.0%'), findsWidgets);
      await fixtures.tap(
        t,
        find.text(lang == AppLanguage.en ? 'Valuation →' : '查看估值 →').last,
      );
      expect(actions, [('AAA', 'value')]);
      expect(t.takeException(), isNull);
    });
  }
}
