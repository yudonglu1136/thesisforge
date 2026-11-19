import 'dart:async';
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
    if (path.contains('/research/') && !Uri.parse(path).path.endsWith('/dividends')) {
      (d['snapshot'] as Map)['id'] = snapshot;
    }
    return d;
  }
}

void main() {
  testWidgets(
    'Research caches dividends per ApiClient instance and reuses session cache without extra network hits',
    (t) async {
      final api = MemoryApi();
      await ui.open(t, api);

      expect(
        api.reads.where((p) => p.contains('/research/TEST/dividends')).length,
        1,
      );
      await t.tap(find.byKey(const ValueKey('research-tab-dividends')));
      await t.pumpAndSettle();
      // Tapping Dividends tab reuses prefetched dividend payload (still 1 read)
      expect(
        api.reads.where((p) => p.contains('/research/TEST/dividends')).length,
        1,
      );
      expect(
        find.byKey(const ValueKey('research-dividend-yield-chart')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
}
