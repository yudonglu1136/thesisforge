import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class CrisisObservatoryFixtureApi extends ApiClient {
  CrisisObservatoryFixtureApi() : super(() => 'test');

  static final Map<String, Map<String, dynamic>> _nodeCache = {};
  final calls = <String>[];

  static Map<String, dynamic> _callBackend(String path) {
    final uri = Uri.parse(path);
    final isPit = uri.path.endsWith('/pit');
    final cacheKey = path;
    final cached = _nodeCache[cacheKey];
    if (cached != null) return cached;

    final script = isPit
        ? '''
import { loadCrisisObservatoryPitSnapshot } from './server/crisisObservatory.js';
const date = process.env.TF_PIT_DATE || '2022-03-18';
process.stdout.write(JSON.stringify(loadCrisisObservatoryPitSnapshot({ date })));
'''
        : '''
import { loadCrisisObservatoryDashboard } from './server/crisisObservatory.js';
const win = process.env.TF_WIN || '11y_opra';
const asOf = process.env.TF_ASOF || null;
process.stdout.write(JSON.stringify(loadCrisisObservatoryDashboard({ window: win, asOf })));
''';

    final res = Process.runSync(
      'node',
      ['--input-type=module', '-e', script],
      environment: {
        ...Platform.environment,
        if (uri.queryParameters['date'] != null)
          'TF_PIT_DATE': uri.queryParameters['date']!,
        if (uri.queryParameters['window'] != null)
          'TF_WIN': uri.queryParameters['window']!,
        if (uri.queryParameters['asOf'] != null &&
            uri.queryParameters['asOf']!.isNotEmpty)
          'TF_ASOF': uri.queryParameters['asOf']!,
      },
    );
    if (res.exitCode != 0) {
      throw StateError('Node fixture failed: ${res.stderr}');
    }
    final decoded =
        jsonDecode(res.stdout as String) as Map<String, dynamic>;
    _nodeCache[cacheKey] = decoded;
    return decoded;
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(path);
    return _callBackend(path);
  }
}

Widget _wrapPanel({
  required ApiClient api,
  required Locale locale,
  String asOf = '2026-11-25',
  Map<String, dynamic> initialSelection = const {},
  ValueChanged<Map<String, dynamic>>? onSelection,
}) {
  return MaterialApp(
    locale: locale,
    home: Scaffold(
      body: SingleChildScrollView(
        child: CrisisObservatoryPanel(
          api: api,
          palette: Palette(false),
          asOf: asOf,
          onCompany: (_) {},
          initialSelection: initialSelection,
          onSelection: onSelection,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'renders redesigned v2.0 Single-Strategy Cockpit on 1280x720 desktop in ZH with zero Wheel clutter',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = CrisisObservatoryFixtureApi();
      Map<String, dynamic>? latestSel;
      await tester.pumpWidget(
        _wrapPanel(
          api: api,
          locale: const Locale('zh'),
          onSelection: (sel) => latestSel = sel,
        ),
      );
      await tester.pumpAndSettle();

      // Verify all 5 redesigned v2.0 sections exist
      expect(find.byKey(const ValueKey('crisis-v2-hero')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-v2-action-directive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-v2-subengines-grid')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('crisis-v2-sizer')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-v2-dualcta-radar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-v2-latch-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-v2-timer-card')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('crisis-v2-pillars')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-v2-tp-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-v2-backtest')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-v2-chart')), findsOneWidget);

      // Verify live 2026-11-25 Dual-Track stress & CONT_2M & verified 11Y OPRA numbers appear
      expect(find.textContaining('87 / 100'), findsWidgets);
      expect(find.textContaining('\$707,763'), findsWidgets);
      expect(find.textContaining('19.57%'), findsWidgets);
      expect(find.textContaining('1.200x'), findsWidgets);
      expect(find.textContaining('9 / 60'), findsWidgets);

      // Verify ZERO Wheel / Covered Call / Short Put / Collar / Multi-Profile remnants
      for (final banned in [
        'Wheel',
        '卖Call',
        '领口',
        'Covered Call',
        'Short Put',
        'Core-3',
        '多策略切换',
      ]) {
        expect(find.textContaining(banned), findsNothing);
      }

      // Switch to 5Y Zero-Splice window
      final win5Btn = find.byKey(const ValueKey('crisis-v2-win-5y_live'));
      await tester.ensureVisible(win5Btn);
      await tester.tap(win5Btn);
      await tester.pumpAndSettle();

      expect(latestSel?['window'], '5y_live');
      expect(find.textContaining('\$235,715'), findsWidgets);
      expect(find.textContaining('18.57%'), findsWidgets);

      // Expand real MIT OPRA forensic ledger
      final ledgerToggle = find.byKey(
        const ValueKey('crisis-v2-ledger-toggle'),
      );
      await tester.ensureVisible(ledgerToggle);
      await tester.tap(ledgerToggle);
      await tester.pumpAndSettle();
      expect(find.textContaining('M4 90D -10%'), findsWidgets);

      // Interactive NAV Sizer update
      final navInput = find.byKey(const ValueKey('crisis-v2-nav-input'));
      await tester.ensureVisible(navInput);
      await tester.enterText(navInput, '250000');
      await tester.pumpAndSettle();
      expect(find.textContaining('\$250,000'), findsWidgets);
    },
  );

  testWidgets(
    'renders cleanly in English on 390x844 mobile viewport with zero overflow and zero CJK leakage',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = CrisisObservatoryFixtureApi();
      await tester.pumpWidget(
        _wrapPanel(api: api, locale: const Locale('en')),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('v2.0 LOCKED MASTER STRATEGY'), findsOneWidget);
      expect(find.textContaining('Slow-Bear +8% Hysteresis Latch'), findsWidgets);
      expect(
        find.textContaining('2-Month Continuous Bear Timer'),
        findsOneWidget,
      );
      expect(find.textContaining('LIVE STRESS 87 / 100'), findsWidgets);
      expect(find.textContaining('\$707,763'), findsWidgets);

      // Ensure zero CJK characters appear in English mode
      final cjkRegex = RegExp(r'[\u4E00-\u9FFF]');
      for (final widget in tester.widgetList<Text>(find.byType(Text))) {
        final s = widget.data ?? '';
        expect(
          cjkRegex.hasMatch(s),
          isFalse,
          reason: 'Unexpected CJK string in English mode: "$s"',
        );
      }
    },
  );
}
