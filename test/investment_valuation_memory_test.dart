import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'investment_valuation_test.dart' as ui;

class MemoryApi extends ui.PersonalApi {
  final drafts = <Map<String, dynamic>>[];
  bool failDraft = false;
  Completer<void>? delayDraft;
  String snapshot = 'fixture';
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final d = await super.getJson(path);
    if (path.contains('/research/')) {
      (d['snapshot'] as Map)['id'] = snapshot;
      d['worksheetHead'] = drafts.lastOrNull?['id'];
      d['activeWorksheet'] = drafts.lastOrNull;
    }
    return d;
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!path.endsWith('/valuation-drafts')) return super.postJson(path, body);
    final copy = Map<String, dynamic>.from(jsonDecode(jsonEncode(body)));
    calls.add((path, copy));
    if (failDraft) throw StateError('offline');
    final gate = delayDraft;
    delayDraft = null;
    if (gate != null) await gate.future;
    final saved = {
      ...copy,
      'id': 'draft-${drafts.length + 1}',
      'kind': 'valuation_draft',
      'snapshot': {'id': snapshot},
      'result': {'fairValue': outputValue},
      'ownershipConfirmed': false,
    };
    drafts.add(saved);
    return saved;
  }
}

Future<void> settleSave(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 800));
  await t.pumpAndSettle();
}

Future<void> reopen(WidgetTester t, MemoryApi api) async {
  await t.pumpWidget(const SizedBox());
  await ui.open(t, api);
}

String input(WidgetTester t, String metric, int year) =>
    t.widget<TextField>(ui.cell(metric, year)).controller!.text;

void main() {
  testWidgets('an intentional saved zero survives newer default assumptions', (
    t,
  ) async {
    final api = MemoryApi();
    await ui.open(t, api);
    await ui.edit(t, ui.cell('growth %', 1), '0');
    await settleSave(t);
    await reopen(t, api);
    expect(input(t, 'growth %', 1), '0.00');
    expect(find.textContaining('Your saved assumptions'), findsOneWidget);
    expect(api.drafts.last['assumptions']['growth'][0], 0);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'server declines legacy QA auto-restore; history remains without blanking defaults',
    (t) async {
      final api = MemoryApi();
      api.versions.add({
        'id': 'legacy-qa',
        'name': 'LOCAL QA — workflow check',
        'asOf': '2026-06-01',
        'snapshot': {'id': 'fixture'},
        'assumptions': {},
        'result': {'fairValue': 1},
      });
      await ui.open(t, api);
      expect(input(t, 'growth %', 1), isNotEmpty);
      expect(find.textContaining('LOCAL QA — workflow check'), findsWidgets);
      expect(api.drafts, isEmpty);
    },
  );
  testWidgets(
    'prefilled worksheet auto-saves edits and restores after a fresh widget load',
    (t) async {
      final api = MemoryApi();
      await ui.open(t, api);
      expect(input(t, 'growth %', 1), isNotEmpty);
      expect(api.drafts, isEmpty); // A read is not an account write.
      await ui.edit(t, ui.cell('growth %', 2), '23');
      await settleSave(t);
      expect(api.drafts.length, 1);
      expect((api.drafts.last['assumptions'] as Map)['growth'][1], .23);
      expect(find.text('Auto-saved to your account'), findsWidgets);
      expect(api.versions, isEmpty);
      expect(api.calls.where((x) => x.$1.endsWith('/decisions')), isEmpty);
      await reopen(t, api);
      expect(input(t, 'growth %', 2), '23.00');
      expect(api.drafts.length, 1);
      expect(find.text('Auto-saved to your account'), findsWidgets);
    },
  );
  testWidgets(
    'name, hypothesis and terminal growth save without manual version confirmation',
    (t) async {
      final api = MemoryApi();
      await ui.open(t, api);
      final name = find.widgetWithText(TextField, 'Scenario name');
      await t.ensureVisible(name);
      await t.enterText(name, 'My durable case');
      final hypo = find.widgetWithText(TextField, 'My hypothesis');
      await t.ensureVisible(hypo);
      await t.enterText(hypo, 'Cash conversion recovers');
      await settleSave(t);
      expect(api.drafts.last['name'], 'My durable case');
      expect(api.drafts.last['hypothesis'], 'Cash conversion recovers');
      await reopen(t, api);
      expect(find.text('My durable case'), findsOneWidget);
      expect(find.text('Cash conversion recovers'), findsOneWidget);
    },
  );
  testWidgets(
    'save failure is visible and retry preserves identical operation before newer edits',
    (t) async {
      final api = MemoryApi()..failDraft = true;
      await ui.open(t, api);
      await ui.edit(t, ui.cell('growth %', 1), '19');
      await settleSave(t);
      expect(find.text('Not saved · your edits are still here'), findsWidgets);
      final first = api.calls
          .lastWhere((x) => x.$1.endsWith('/valuation-drafts'))
          .$2;
      await ui.edit(t, ui.cell('growth %', 2), '24');
      await settleSave(t);
      api.failDraft = false;
      final retry = find.text('Retry saving').first;
      await t.ensureVisible(retry);
      await t.tap(retry);
      await settleSave(t);
      final savedCalls = api.calls
          .where((x) => x.$1.endsWith('/valuation-drafts'))
          .toList();
      expect(savedCalls[savedCalls.length - 2].$2, first);
      expect(savedCalls.last.$2['expectedHead'], api.drafts.first['id']);
      await reopen(t, api);
      expect(input(t, 'growth %', 1), '19.00');
      expect(input(t, 'growth %', 2), '24.00');
    },
  );
  testWidgets(
    'rapid edits while saving serialize and a late response never resets the inputs',
    (t) async {
      final api = MemoryApi();
      await ui.open(t, api);
      final gate = Completer<void>();
      api.delayDraft = gate;
      await ui.edit(t, ui.cell('growth %', 1), '11');
      await settleSave(t);
      await ui.edit(t, ui.cell('growth %', 1), '22');
      await settleSave(t);
      expect(
        api.calls.where((x) => x.$1.endsWith('/valuation-drafts')).length,
        1,
      );
      gate.complete();
      await settleSave(t);
      expect(api.drafts.length, 2);
      expect((api.drafts.last['assumptions'] as Map)['growth'][0], .22);
      expect(input(t, 'growth %', 1), '22');
      await reopen(t, api);
      expect(input(t, 'growth %', 1), '22.00');
    },
  );
  testWidgets(
    'invalid partial input is remembered rather than replaced by defaults',
    (t) async {
      final api = MemoryApi();
      await ui.open(t, api);
      await ui.edit(t, ui.cell('FCFE margin %', 3), '');
      await settleSave(t);
      expect((api.drafts.last['assumptions'] as Map)['margin'][2], isNull);
      await reopen(t, api);
      expect(input(t, 'FCFE margin %', 3), isEmpty);
      expect(
        find.textContaining('Year 3: FCFE margin must be between −90% and 90%'),
        findsWidgets,
      );
    },
  );
  testWidgets(
    'updated source snapshot retains saved assumptions and discloses recalculation',
    (t) async {
      final api = MemoryApi();
      await ui.open(t, api);
      await ui.edit(t, ui.cell('growth %', 4), '18');
      await settleSave(t);
      api.snapshot = 'new-financial-base';
      await reopen(t, api);
      expect(input(t, 'growth %', 4), '18.00');
      expect(
        find.textContaining('Financial data or the cutoff changed'),
        findsOneWidget,
      );
      expect(api.versions, isEmpty);
    },
  );
  testWidgets('leaving research flushes pending edits without discard dialog', (
    t,
  ) async {
    final api = MemoryApi();
    await ui.open(t, api);
    await ui.edit(t, ui.cell('growth %', 1), '17');
    final home = find.text('Home').first;
    await t.ensureVisible(home);
    await t.tap(home);
    await settleSave(t);
    expect(find.text('Leave this unsaved scenario?'), findsNothing);
    expect((api.drafts.last['assumptions'] as Map)['growth'][0], .17);
  });
}
