import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_workflow_test.dart' as fixtures;

class PersonalApi extends fixtures.HomeFixtureApi {
  final versions = <Map<String, dynamic>>[];
  bool failSave = false;
  bool failCalculation = false;
  bool independent = false;
  double outputValue = 30;
  Completer<Map<String, dynamic>>? heldCalculation;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final d = await super.getJson(path);
    if (path.contains('/research/')) {
      d['base'] = {'revenueM': 1000, 'sharesM': 100, 'fcfM': 200};
      d['scenarios'] = [...versions];
      d['templateReconciliation'] = {
        'startingForecast': {'firstGrowth': .1552, 'finalGrowth': .025},
      };
      d['guidance'] = {
        'audit': {'annualRevenueCount': 0, 'status': 'stored_evidence_checked'},
        'evidence': <Map<String, dynamic>>[],
      };
      (d['snapshot'] as Map)['periodEnd'] = '2026-03-31';
      if (independent) {
        final a = Map<String, dynamic>.from((d['templates'] as Map)['Base']);
        a['growth'] = List.filled(5, null);
        a['margin'] = List.filled(5, null);
        d['templates'] = {'Base': a};
        d['templateReconciliation'] = {'basis': 'user_defined_cashflow_path'};
        d['base'] = {'revenueM': 1000, 'sharesM': 100, 'fcfM': -12};
        d['published'] = {'fairValue': 99, 'dcf': null};
      }
    }
    return d;
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path.endsWith('/scenarios')) {
      calls.add((path, body));
      if (failSave) throw StateError('fixture_save_failed');
      final saved = {
        ...body,
        'id': 'personal-${versions.length + 1}',
        'version': versions.length + 1,
        'snapshot': {'id': 'fixture'},
        'recordedAt': '2026-09-09T12:00:00Z',
        'result': {'fairValue': 30},
      };
      versions.add(saved);
      return saved;
    }
    if (path.endsWith('/calculate') && heldCalculation != null) {
      calls.add((path, body));
      final held = heldCalculation!;
      heldCalculation = null;
      return held.future;
    }
    if (path.endsWith('/calculate') && failCalculation) {
      calls.add((path, body));
      throw StateError('fixture_calculation_failed');
    }
    final response = await super.postJson(path, body);
    if (path.endsWith('/calculate')) {
      return {
        ...response,
        'result': {
          ...(response['result'] as Map),
          'fairValue': outputValue,
          'terminalValueM': 4000,
          'terminalPvM': 2400,
          'explicitPvM': 600,
          'terminalShare': .8,
        },
      };
    }
    return response;
  }
}

Future<void> open(
  WidgetTester t,
  PersonalApi api, {
  Size size = const Size(1487, 1058),
  AppLanguage language = AppLanguage.en,
  double scale = 1,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: LanguageScope(
        language: language,
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
  await t.tap(find.byKey(const ValueKey('research-tab-value')));
  await t.pumpAndSettle();
  await t.ensureVisible(
    find.text(language == AppLanguage.en ? 'My DCF' : '我的 DCF'),
  );
  await t.tap(find.text(language == AppLanguage.en ? 'My DCF' : '我的 DCF'));
  await t.pumpAndSettle();
}

Finder cell(String metric, int year) =>
    find.byKey(ValueKey('forecast-Year $year $metric'));
Future<void> edit(WidgetTester t, Finder f, String value) async {
  await t.ensureVisible(f);
  await t.enterText(f, value);
  await t.pump(const Duration(milliseconds: 450));
  await t.pumpAndSettle();
}

Future<void> save(WidgetTester t) async {
  await t.ensureVisible(find.text('Save scenario'));
  await t.tap(find.text('Save scenario'));
  await t.pumpAndSettle();
  await t.tap(find.byType(CheckboxListTile));
  await t.pumpAndSettle();
  await t.tap(find.text('Save version'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'operating FCFF editor exposes the full bridge and retains ten-year paths',
    (t) async {
      final api = PersonalApi();
      await open(t, api, size: const Size(1487, 1058));
      await t.ensureVisible(find.byKey(const ValueKey('dcf-method-fcff')));
      await t.tap(find.byKey(const ValueKey('dcf-method-fcff')));
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(find.text('Operating FCFF'), findsWidgets);
      expect(
        find.byKey(const ValueKey('forecast-Year 1 EBIT margin %')),
        findsOneWidget,
      );
      expect(
        find.text('Enterprise-to-equity bridge · USD millions'),
        findsOneWidget,
      );
      final calculation = api.calls.lastWhere(
        (call) => call.$1.endsWith('/calculate'),
      );
      expect(
        (calculation.$2['assumptions'] as Map)['method'],
        'operating_fcff',
      );
      await t.ensureVisible(find.byKey(const ValueKey('forecast-horizon-10')));
      await t.tap(find.byKey(const ValueKey('forecast-horizon-10')));
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('forecast-Year 10 capex / revenue %')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );

  for (final language in AppLanguage.values) {
    testWidgets(
      'prefill is labeled as model years and assumptions, not missing zero guidance $language',
      (t) async {
        await open(
          t,
          PersonalApi(),
          language: language,
          size: const Size(390, 844),
        );
        final notice = find.byKey(const ValueKey('forecast-origin-notice'));
        await t.ensureVisible(notice);
        expect(notice, findsOneWidget);
        expect(
          find.textContaining(
            language == AppLanguage.en
                ? 'Missing guidance is not 0%'
                : '缺少指引不等于 0%',
          ),
          findsOneWidget,
        );
        expect(
          find.text(language == AppLanguage.en ? 'Model year 1' : '预测第 1 年'),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      },
    );
    testWidgets(
      'earnings-only worksheet accepts annual hypotheses and copies year one $language',
      (t) async {
        final api = PersonalApi()..independent = true;
        await open(t, api, language: language, size: const Size(390, 844));
        expect(
          find.byKey(const ValueKey('independent-valuation-notice')),
          findsOneWidget,
        );
        expect(
          t.widget<TextField>(cell('growth %', 1)).controller!.text,
          isEmpty,
        );
        expect(
          t.widget<TextField>(cell('FCFE margin %', 1)).controller!.text,
          isEmpty,
        );
        expect(api.calls.where((x) => x.$1.endsWith('/calculate')), isEmpty);
        await edit(t, cell('growth %', 1), '10');
        await edit(t, cell('FCFE margin %', 1), '5');
        expect(api.calls.where((x) => x.$1.endsWith('/calculate')), isEmpty);
        final copy = find.byKey(const ValueKey('forecast-copy-year-one'));
        await t.ensureVisible(copy);
        await t.tap(copy);
        await t.pump(const Duration(milliseconds: 450));
        await t.pumpAndSettle();
        final a = api.calls.last.$2['assumptions'] as Map;
        expect(a['growth'], List.filled(5, .1));
        expect(a['margin'], List.filled(5, .05));
        expect(find.textContaining('99.00'), findsOneWidget);
        api.outputValue = 40;
        await edit(t, cell('FCFE margin %', 2), '7');
        expect(
          t.widget<Text>(find.byKey(const ValueKey('valuation-delta'))).data,
          contains('10.00'),
        );
        expect(
          t
              .widget<Text>(
                find.byKey(const ValueKey('valuation-before-after')),
              )
              .data,
          contains('30.00'),
        );
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'comparison stays fixed across invalid drafts and can be explicitly rebased',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      api.outputValue = 36;
      await edit(t, cell('growth %', 2), '20');
      expect(
        t.widget<Text>(find.byKey(const ValueKey('valuation-delta'))).data,
        contains('6.00'),
      );
      await edit(t, cell('growth %', 2), '');
      expect(
        t.widget<Text>(find.byKey(const ValueKey('valuation-delta'))).data,
        '—',
      );
      expect(
        t
            .widget<Text>(find.byKey(const ValueKey('valuation-before-after')))
            .data,
        contains('30.00'),
      );
      await edit(t, cell('growth %', 2), '20');
      final rebase = find.byKey(const ValueKey('valuation-set-reference'));
      await t.ensureVisible(rebase);
      await t.tap(rebase);
      await t.pumpAndSettle();
      expect(
        t
            .widget<Text>(find.byKey(const ValueKey('valuation-before-after')))
            .data,
        contains('36.00'),
      );
      expect(
        t.widget<Text>(find.byKey(const ValueKey('valuation-delta'))).data,
        contains('0.00'),
      );
    },
  );
  final terminalField = find.byKey(
    const ValueKey('compact-Terminal growth (g)'),
  );
  for (final language in AppLanguage.values) {
    testWidgets(
      'invalid terminal input is explained beside the field and recovers without losing focus $language',
      (t) async {
        final api = PersonalApi();
        await open(t, api, language: language, size: const Size(390, 844));
        final originalRevenue = t
            .widget<TextField>(cell('revenue m', 1))
            .controller!
            .text;
        for (final invalid in ['8', '', '-1', 'NaN']) {
          final before = api.calls.length;
          await edit(t, terminalField, invalid);
          expect(api.calls.length, before);
          final status = find.byKey(
            const ValueKey('valuation-calculation-status-true'),
          );
          expect(
            find.descendant(
              of: status,
              matching: find.textContaining(
                language == AppLanguage.en ? 'Edit g to resume' : '修改 g 后自动重算',
              ),
            ),
            findsOneWidget,
          );
          final editor = t.widget<EditableText>(
            find.descendant(
              of: terminalField,
              matching: find.byType(EditableText),
            ),
          );
          expect(editor.focusNode.hasFocus, isTrue);
          expect(find.text('Retry workspace'), findsNothing);
          expect(
            t.widget<TextField>(cell('revenue m', 1)).controller!.text,
            originalRevenue,
          );
          expect(
            t
                .widget<FilledButton>(
                  find.widgetWithText(
                    FilledButton,
                    language == AppLanguage.en ? 'Save scenario' : '保存情景',
                  ),
                )
                .onPressed,
            isNull,
          );
        }
        for (final valid in ['4', '5', '0']) {
          await edit(t, terminalField, valid);
          expect(
            api.calls.last.$2['assumptions']['g'],
            double.parse(valid) / 100,
          );
          expect(
            t
                .widget<FilledButton>(
                  find.widgetWithText(
                    FilledButton,
                    language == AppLanguage.en ? 'Save scenario' : '保存情景',
                  ),
                )
                .onPressed,
            isNotNull,
          );
        }
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'terminal amount PV and share are visible without expanding diagnostics',
    (t) async {
      await open(t, PersonalApi());
      expect(find.text('Terminal value'), findsOneWidget);
      expect(find.text('4,000m'), findsOneWidget);
      expect(find.text('2,400m'), findsOneWidget);
      expect(find.text('80.00%'), findsOneWidget);
      expect(find.textContaining('PV(TV) = TV ÷ (1 + Ke)^5'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'waiting calculation has a visible state and timeout can retry without losing the draft',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      final pending = Completer<Map<String, dynamic>>();
      api.heldCalculation = pending;
      await edit(t, terminalField, '4');
      expect(find.textContaining('Recalculating…'), findsWidgets);
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save scenario'),
            )
            .onPressed,
        isNull,
      );
      await t.pump(const Duration(seconds: 12));
      await t.pumpAndSettle();
      expect(find.textContaining('Calculation timed out.'), findsWidgets);
      expect(t.widget<TextField>(terminalField).controller!.text, '4');
      await t.ensureVisible(find.text('Retry calculation'));
      await t.tap(find.text('Retry calculation'));
      await t.pumpAndSettle();
      expect(find.textContaining('Calculation timed out.'), findsNothing);
      expect(api.calls.last.$2['assumptions']['g'], .04);
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save scenario'),
            )
            .onPressed,
        isNotNull,
      );
      pending.complete({
        'result': {'fairValue': 999},
      });
      await t.pumpAndSettle();
      expect(find.text(r'$999.00'), findsNothing);
    },
  );
  testWidgets(
    'request failure stays in the worksheet and retry preserves hypotheses',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      await edit(
        t,
        find.byKey(const ValueKey('personal-hypothesis')),
        'Keep my assumptions',
      );
      api.failCalculation = true;
      await edit(t, terminalField, '4');
      expect(find.textContaining('Calculation failed.'), findsWidgets);
      expect(find.text('Retry workspace'), findsNothing);
      api.failCalculation = false;
      await t.ensureVisible(find.text('Retry calculation'));
      await t.tap(find.text('Retry calculation'));
      await t.pumpAndSettle();
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('personal-hypothesis')),
            )
            .controller!
            .text,
        'Keep my assumptions',
      );
      expect(t.widget<TextField>(terminalField).controller!.text, '4');
      expect(find.textContaining('Calculation failed.'), findsNothing);
    },
  );
  testWidgets('invalid terminal draft rejects a late valid calculation', (
    t,
  ) async {
    final api = PersonalApi();
    await open(t, api);
    final pending = Completer<Map<String, dynamic>>();
    api.heldCalculation = pending;
    await edit(t, terminalField, '4');
    await edit(t, terminalField, '8');
    pending.complete({
      'result': {'fairValue': 999},
    });
    await t.pumpAndSettle();
    expect(find.textContaining('Edit g to resume'), findsOneWidget);
    expect(find.textContaining('Recalculating…'), findsNothing);
    expect(find.text(r'$999.00'), findsNothing);
  });
  for (final language in AppLanguage.values) {
    for (final size in [
      const Size(1487, 1058),
      const Size(1024, 768),
      const Size(390, 844),
    ]) {
      testWidgets(
        'personal worksheet $language $size has five editable years without overflow',
        (t) async {
          final api = PersonalApi();
          await open(t, api, size: size, language: language);
          expect(find.byType(Table), findsWidgets);
          for (var i = 1; i <= 5; i++) {
            expect(cell('revenue m', i), findsOneWidget);
            expect(cell('growth %', i), findsOneWidget);
            expect(cell('FCFE margin %', i), findsOneWidget);
          }
          await t.ensureVisible(cell('revenue m', 5));
          await t.enterText(cell('revenue m', 5), '1800');
          await t.pump(const Duration(milliseconds: 450));
          await t.pumpAndSettle();
          expect(
            api.calls.last.$2['assumptions']['growth'][4],
            closeTo(1800 / 1464.1 - 1, 1e-12),
          );
          expect(t.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'revenue edits one growth rate and preserves future assumptions',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      await edit(t, cell('revenue m', 2), '1500');
      final a = api.calls.last.$2['assumptions'] as Map;
      expect(a['growth'][1], closeTo(1500 / 1100 - 1, 1e-12));
      expect(a['growth'][2], .1);
      expect(
        t.widget<TextField>(cell('revenue m', 3)).controller!.text,
        '1650.00',
      );
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'editing growth updates revenue while untouched rate precision survives',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      await edit(t, cell('growth %', 1), '25');
      expect(
        t.widget<TextField>(cell('revenue m', 1)).controller!.text,
        '1250.00',
      );
      expect(
        t.widget<TextField>(cell('revenue m', 2)).controller!.text,
        '1375.00',
      );
      expect(api.calls.last.$2['assumptions']['margin'][0], .2290987654321);
      expect(api.calls.last.$2['assumptions']['g'], .024698294551041777);
    },
  );
  testWidgets(
    'blank and zero revenue invalidate result rather than silently keeping an old valuation',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      for (final invalid in ['', '0', 'NaN']) {
        final before = api.calls.length;
        await edit(t, cell('revenue m', 1), invalid);
        expect(api.calls.length, before);
        expect(
          t
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save scenario'),
              )
              .onPressed,
          isNull,
        );
        expect(
          find.textContaining('Blank or invalid revenue is not zero.'),
          findsOneWidget,
        );
      }
      await edit(t, cell('revenue m', 1), '1200');
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save scenario'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'negative explicit FCFE is preserved while invalid Ke spread is rejected',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      await edit(t, cell('FCFE margin %', 3), '-5');
      expect(find.textContaining('FCFE margin must be between'), findsNothing);
      await edit(t, cell('FCFE margin %', 3), '20');
      await edit(
        t,
        find.byKey(const ValueKey('compact-Terminal growth (g)')),
        '10',
      );
      expect(find.textContaining('1.5 percentage points'), findsOneWidget);
    },
  );
  testWidgets('5Y and 10Y switching preserves the extended forecast', (
    t,
  ) async {
    await open(t, PersonalApi());
    final tenYear = find.byKey(const ValueKey('forecast-horizon-10'));
    final fiveYear = find.byKey(const ValueKey('forecast-horizon-5'));
    await t.ensureVisible(tenYear);
    await t.tap(tenYear);
    await t.pumpAndSettle();
    expect(cell('growth %', 10), findsOneWidget);
    await edit(t, cell('growth %', 10), '3.75');
    await t.ensureVisible(fiveYear);
    await t.tap(fiveYear);
    await t.pumpAndSettle();
    expect(cell('growth %', 10), findsNothing);
    await t.ensureVisible(tenYear);
    await t.tap(tenYear);
    await t.pumpAndSettle();
    expect(t.widget<TextField>(cell('growth %', 10)).controller?.text, '3.75');
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'hypothesis saves with the current owner version and reload restores numbers and reasoning',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      await edit(t, cell('revenue m', 2), '1500');
      await edit(
        t,
        find.byKey(const ValueKey('personal-hypothesis')),
        'Demand grows; cash conversion stays above 20%.',
      );
      await save(t);
      expect(
        api.versions.single['hypothesis'],
        'Demand grows; cash conversion stays above 20%.',
      );
      expect(api.versions.single.containsKey('owner'), isFalse);
      expect(find.text('Saved to your account'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      await open(t, api);
      expect(
        t.widget<TextField>(cell('revenue m', 2)).controller!.text,
        '1500.00',
      );
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('personal-hypothesis')),
            )
            .controller!
            .text,
        api.versions.single['hypothesis'],
      );
      await edit(t, cell('FCFE margin %', 2), '18');
      await save(t);
      expect(api.versions.length, 2);
      expect(api.versions.last['parentId'], 'personal-1');
      expect(api.versions.first['assumptions']['margin'][1], .2);
      expect(api.versions.last['assumptions']['margin'][1], .18);
    },
  );
  testWidgets(
    'failed save keeps the edited hypothesis and never reports success',
    (t) async {
      final api = PersonalApi()..failSave = true;
      await open(t, api);
      await edit(
        t,
        find.byKey(const ValueKey('personal-hypothesis')),
        'Keep this draft',
      );
      await save(t);
      expect(api.versions, isEmpty);
      expect(find.text('Saved to your account'), findsNothing);
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('personal-hypothesis')),
            )
            .controller!
            .text,
        'Keep this draft',
      );
      expect(find.text('Unsaved draft'), findsOneWidget);
    },
  );
  testWidgets('late calculation cannot overwrite a newer edited draft', (
    t,
  ) async {
    final api = PersonalApi();
    await open(t, api);
    final pending = Completer<Map<String, dynamic>>();
    api.heldCalculation = pending;
    await edit(t, cell('growth %', 1), '12');
    await edit(t, cell('growth %', 1), '15');
    pending.complete({
      'result': {'fairValue': 999},
      'reverse': {},
      'sensitivity': [],
    });
    await t.pumpAndSettle();
    expect(find.text(r'$999.00'), findsNothing);
    expect(find.text(r'$30.00'), findsWidgets);
  });
  testWidgets(
    'hypothesis-only edits also trigger the unsaved navigation guard',
    (t) async {
      final api = PersonalApi();
      await open(t, api);
      await edit(
        t,
        find.byKey(const ValueKey('personal-hypothesis')),
        'A private reason',
      );
      await t.tap(find.text('Home'));
      await t.pumpAndSettle();
      expect(find.text('Leave this unsaved scenario?'), findsOneWidget);
      await t.tap(find.text('Keep editing'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('personal-hypothesis')), findsOneWidget);
    },
  );
  testWidgets('desktop large text retains input and action reachability', (
    t,
  ) async {
    await open(t, PersonalApi(), scale: 1.5);
    await t.ensureVisible(cell('revenue m', 5));
    await t.ensureVisible(find.text('Save scenario'));
    expect(t.takeException(), isNull);
  });
}
