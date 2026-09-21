import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_research_test.dart' as research;

class HoldersApi extends research.ResearchApi {
  bool noHolders = false;
  final evidence = <Map<String, dynamic>>[
    {
      'guruId': 'baillie-gifford',
      'name': 'Baillie Gifford',
      'shares': 42000000,
      'previousShares': 40000000,
      'rawReportedChangeShares': 2000000,
      'weight': .075,
    },
    {
      'guruId': 'brad-gerstner',
      'name': 'Brad Gerstner',
      'shares': 9000000,
      'previousShares': null,
      'rawReportedChangeShares': null,
      'weight': null,
    },
    {
      'guruId': 'renaissance-technologies',
      'name': 'Renaissance Technologies',
      'shares': 7000000,
      'previousShares': 8000000,
      'rawReportedChangeShares': -1000000,
      'weight': .02,
    },
    {
      'guruId': 'test-manager',
      'name': 'Test manager',
      'shares': 0,
      'previousShares': 20,
      'rawReportedChangeShares': -20,
      'weight': 0,
    },
  ];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final response = await super.getJson(path);
    if (path.contains('/research/')) {
      response['provenance'] = noHolders
          ? []
          : [
              for (final row in evidence)
                {
                  ...row,
                  'reportDate': '2026-03-31',
                  'availableAt': '2026-05-15',
                  'accession': 'new-filing',
                  'comparisonStatus': 'corporate_action_unverified',
                  'sourceUrl':
                      'https://www.sec.gov/edgar/search/#/q=test-fixture',
                },
            ];
    }
    return response;
  }
}

Future<void> mountHolders(
  WidgetTester t,
  HoldersApi api, {
  Size size = const Size(1720, 1120),
  AppLanguage lang = AppLanguage.en,
}) async {
  await research.mount(t, api, size: size, lang: lang);
  final tab = find.text(
    lang == AppLanguage.en ? 'Announcements & financials' : '公告与财务',
  );
  await t.ensureVisible(tab);
  await t.tap(tab);
  await t.pumpAndSettle();
}

Finder holder(String id) => find.byKey(ValueKey('holder-row-$id'));
Future<void> choose(WidgetTester t, String id) async {
  await t.ensureVisible(holder(id));
  await t.tap(holder(id));
  await t.pumpAndSettle();
}

void main() {
  test(
    'reported share formatting preserves missing and zero; sorting never mutates evidence',
    () {
      expect(disclosedShareCount(null), '—');
      expect(disclosedShareCount(double.nan), '—');
      expect(disclosedShareCount(0), '0');
      expect(disclosedShareCount(41888806), '41.89M');
      expect(disclosedShareCount(-1000000, signed: true), '-1.00M');
      final rows = [
        {'guruId': 'missing', 'name': 'Missing', 'shares': null},
        {'guruId': 'big', 'name': 'Big', 'shares': 42},
        {'guruId': 'zero', 'name': 'Zero', 'shares': 0},
      ];
      expect(orderedDisclosedHolders(rows, '').map((g) => g['guruId']), [
        'big',
        'zero',
        'missing',
      ]);
      expect(rows.first['guruId'], 'missing');
      expect(orderedDisclosedHolders(rows, ' BIG ').single['guruId'], 'big');
    },
  );
  for (final lang in AppLanguage.values) {
    for (final size in [
      const Size(1720, 1120),
      const Size(1280, 720),
      const Size(1024, 768),
      const Size(390, 844),
    ]) {
      testWidgets('holder portrait roster and selected evidence $lang $size', (
        t,
      ) async {
        await mountHolders(t, HoldersApi(), size: size, lang: lang);
        for (final id in [
          'baillie-gifford',
          'brad-gerstner',
          'renaissance-technologies',
        ]) {
          final avatar = find.descendant(
            of: holder(id),
            matching: find.byType(GuruAvatar),
          );
          expect(avatar, findsOneWidget);
          expect(
            t.widget<GuruAvatar>(avatar).guru['avatarUrl'],
            '/guru-avatars/$id.png',
          );
        }
        await choose(t, 'renaissance-technologies');
        final detail = find.byKey(
          const ValueKey('holder-detail-renaissance-technologies'),
        );
        expect(detail, findsOneWidget);
        expect(
          find.descendant(of: detail, matching: find.text('7,000,000')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: detail, matching: find.text('-1,000,000')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: detail,
            matching: find.textContaining(
              lang == AppLanguage.en
                  ? 'not confirmed buys or sells'
                  : '不是已确认买卖',
            ),
          ),
          findsOneWidget,
        );
        await t.ensureVisible(
          find.byKey(const ValueKey('holder-link-renaissance-technologies')),
        );
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'selection does not link automatically; link choice survives switching without writes',
    (t) async {
      final api = HoldersApi();
      await mountHolders(t, api);
      final before = api.calls.length;
      await choose(t, 'brad-gerstner');
      final toggle = find.byKey(const ValueKey('holder-link-brad-gerstner'));
      expect(t.widget<CheckboxListTile>(toggle).value, isFalse);
      final detail = find.byKey(const ValueKey('holder-detail-brad-gerstner'));
      expect(
        find.descendant(of: detail, matching: find.text('—')),
        findsNWidgets(3),
      );
      await t.ensureVisible(toggle);
      await t.tap(toggle);
      await t.pumpAndSettle();
      expect(t.widget<CheckboxListTile>(toggle).value, isTrue);
      await choose(t, 'baillie-gifford');
      await choose(t, 'brad-gerstner');
      expect(t.widget<CheckboxListTile>(toggle).value, isTrue);
      expect(api.calls.length, before);
    },
  );
  testWidgets(
    'search empty state and clear preserve full coverage and exact selected manager',
    (t) async {
      await mountHolders(t, HoldersApi());
      final search = find.byKey(const ValueKey('holder-search'));
      await t.ensureVisible(search);
      await t.enterText(search, 'renaissance');
      await t.pumpAndSettle();
      expect(holder('renaissance-technologies'), findsOneWidget);
      expect(holder('baillie-gifford'), findsNothing);
      await t.enterText(search, 'no matching name');
      await t.pumpAndSettle();
      expect(find.text('No managers match your search.'), findsOneWidget);
      expect(find.byKey(const ValueKey('holder-source-link')), findsNothing);
      await t.tap(find.byTooltip('Clear manager search'));
      await t.pumpAndSettle();
      expect(holder('baillie-gifford'), findsOneWidget);
      expect(holder('renaissance-technologies'), findsOneWidget);
    },
  );
  testWidgets(
    'mobile disclosure opens in place and closes without hiding other managers',
    (t) async {
      await mountHolders(t, HoldersApi(), size: const Size(390, 844));
      expect(
        find.byKey(const ValueKey('holder-detail-baillie-gifford')),
        findsNothing,
      );
      await choose(t, 'baillie-gifford');
      expect(
        find.byKey(const ValueKey('holder-detail-baillie-gifford')),
        findsOneWidget,
      );
      expect(holder('renaissance-technologies'), findsOneWidget);
      await choose(t, 'baillie-gifford');
      expect(
        find.byKey(const ValueKey('holder-detail-baillie-gifford')),
        findsNothing,
      );
    },
  );
  testWidgets('missing holder coverage keeps the honest empty state', (
    t,
  ) async {
    await mountHolders(t, HoldersApi()..noHolders = true);
    expect(
      find.textContaining('does not prove no Guru owns it'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('holder-search')), findsNothing);
    expect(find.byKey(const ValueKey('holder-source-link')), findsNothing);
  });
  testWidgets(
    'Guru history action requests exact manager and keeps the cutoff',
    (t) async {
      final api = HoldersApi();
      await mountHolders(t, api);
      await choose(t, 'test-manager');
      await t.ensureVisible(find.text('Explore Guru history'));
      await t.tap(find.text('Explore Guru history'));
      await t.pumpAndSettle();
      expect(
        api.reads,
        contains('/api/investment/gurus/test-manager?asOf=2026-06-01'),
      );
      expect(t.takeException(), isNull);
    },
  );
}
