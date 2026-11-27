import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

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
const win = process.env.TF_WIN || '11y_opra';
process.stdout.write(JSON.stringify(loadCrisisObservatoryPitSnapshot({ date, window: win })));
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
  final lang = locale.languageCode == 'zh' ? AppLanguage.zh : AppLanguage.en;
  return LanguageScope(
    language: lang,
    child: MaterialApp(
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

      // Verify live 2026-11-25 Dual-Track stress, CONT_2M, M7G Roll Audit & verified Plan D (OPRA + 2026 Calibrated BSM) numbers appear
      expect(find.textContaining('87 / 100'), findsWidgets);
      expect(find.textContaining('\$1,007,160'), findsWidgets);
      expect(find.textContaining('21.43%'), findsWidgets);
      expect(find.textContaining('\$944,612'), findsWidgets);
      expect(find.textContaining('22.76%'), findsWidgets);
      expect(find.textContaining('1.257x'), findsWidgets);
      expect(find.textContaining('2.04%'), findsWidgets);
      expect(find.textContaining('9 / 60'), findsWidgets);
      expect(find.byKey(const ValueKey('crisis-v2-bsm-calibration-note')), findsOneWidget);

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

      // Switch to 6Y Zero-Splice window (2020.12-2026.11)
      final win5Btn = find.byKey(const ValueKey('crisis-v2-win-5y_live'));
      await tester.ensureVisible(win5Btn);
      await tester.tap(win5Btn);
      await tester.pumpAndSettle();

      expect(latestSel?['window'], '5y_live');
      expect(find.textContaining('\$321,985'), findsWidgets);
      expect(find.textContaining('21.61%'), findsWidgets);
      expect(find.textContaining('24.56%'), findsWidgets);

      // Expand real MIT OPRA forensic ledger
      final ledgerToggle = find.byKey(
        const ValueKey('crisis-v2-ledger-toggle'),
      );
      await tester.ensureVisible(ledgerToggle);
      await tester.tap(ledgerToggle);
      await tester.pumpAndSettle();
      expect(find.textContaining('M4 90D -15%'), findsWidgets);

      // Interactive NAV Sizer update
      final navInput = find.byKey(const ValueKey('crisis-v2-nav-input'));
      await tester.ensureVisible(navInput);
      await tester.enterText(navInput, '250000');
      await tester.pumpAndSettle();
      expect(find.textContaining('\$250,000'), findsWidgets);

      // Verify time-range brush bar + preset zoom + drag + rebase toggle
      expect(find.byKey(const ValueKey('crisis-v2-range-brush')), findsOneWidget);
      final preset2025 = find.byKey(const ValueKey('crisis-v2-range-preset-2025'));
      await tester.ensureVisible(preset2025);
      await tester.tap(preset2025);
      await tester.pumpAndSettle();
      expect(find.textContaining('2024-12-16 -> 2025-07-31'), findsOneWidget);
      expect(find.textContaining('起点归一=100'), findsOneWidget);

      // Toggle Base=100 <-> Abs NAV ($)
      final rebaseBtn = find.byKey(
        const ValueKey('crisis-v2-range-preset-rebase_toggle'),
      );
      await tester.tap(rebaseBtn);
      await tester.pumpAndSettle();
      expect(find.textContaining('绝对净值(\$)'), findsOneWidget);

      // Reset to full window via '全部' preset
      final presetAll = find.byKey(const ValueKey('crisis-v2-range-preset-all'));
      await tester.tap(presetAll);
      await tester.pumpAndSettle();
      expect(find.textContaining('起点归一=100'), findsNothing);

      // Drag across the brush track -> creates custom sub-range via brush/handle drag
      final brushTrack = find.byKey(const ValueKey('crisis-v2-range-track'));
      await tester.ensureVisible(brushTrack);
      await tester.pumpAndSettle();
      final trackRect = tester.getRect(brushTrack);
      await tester.dragFrom(
        Offset(trackRect.left + 48, trackRect.center.dy),
        const Offset(220, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('crisis-v2-range-preset-rebase_toggle')),
        findsOneWidget,
      );

      // Verify 2026 Calibrated BSM Extension preset & hover trade-detail tooltip on 2026-11-06 Put TP
      final preset2026 = find.byKey(const ValueKey('crisis-v2-range-preset-2026'));
      await tester.ensureVisible(preset2026);
      await tester.tap(preset2026);
      await tester.pumpAndSettle();
      expect(find.textContaining('2025-12-16 -> 2026-11-25'), findsOneWidget);

      final chartCanvas = find.byKey(const ValueKey('crisis-v2-chart-canvas'));
      await tester.ensureVisible(chartCanvas);
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();

      Offset chartPointAtFrac(double frac) {
        final rect = tester.getRect(chartCanvas);
        final plotW = rect.width - 54.0 - 14.0;
        return Offset(rect.left + 54.0 + frac * plotW, rect.top + 80.0);
      }

      // Hover over 2026-11-06 (Put TP day in 5y_live 2026 slice: 224/237)
      await mouse.moveTo(chartPointAtFrac(224 / 237));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crisis-v2-hover-tooltip')), findsOneWidget);
      expect(find.textContaining('◆ 止盈卖出'), findsWidgets);
      expect(find.textContaining('QQQ 27-02-19 \$646 Put'), findsOneWidget);
      expect(find.textContaining('数量 0.72 张'), findsOneWidget);
      expect(find.textContaining('卖出金额 \$2,401'), findsOneWidget);

      // Zoom into 2022 Slow-Bear -> hover Dual-CTA rotation (2022-06-07) & Put Open (2022-11-25)
      final preset2022 = find.byKey(const ValueKey('crisis-v2-range-preset-2022'));
      await tester.ensureVisible(preset2022);
      await tester.tap(preset2022);
      await tester.pumpAndSettle();
      await tester.ensureVisible(chartCanvas);
      await tester.pumpAndSettle();

      await mouse.moveTo(chartPointAtFrac(150 / 417));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crisis-v2-hover-tooltip')), findsOneWidget);
      expect(find.textContaining('■ 卖CTA买QQQ'), findsWidgets);
      expect(find.textContaining('卖出 DBMF -> 买入 QQQ'), findsOneWidget);
      expect(find.textContaining('卖出金额 \$2,869'), findsOneWidget);

      await mouse.moveTo(chartPointAtFrac(244 / 417));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crisis-v2-hover-tooltip')), findsOneWidget);
      expect(find.textContaining('▼ 30D 残值收回'), findsWidgets);
      expect(find.textContaining('QQQ 22-11-18 \$275 Put'), findsOneWidget);
      expect(find.textContaining('数量 3.08 张'), findsOneWidget);
      expect(find.textContaining('卖出金额 \$4,041'), findsOneWidget);
      expect(find.textContaining('2.77x'), findsWidgets);

      await mouse.moveTo(chartPointAtFrac(269 / 417));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crisis-v2-hover-tooltip')), findsOneWidget);
      expect(find.textContaining('▲ 买入开仓'), findsWidgets);
      expect(find.textContaining('QQQ 23-02-17 \$245 Put'), findsOneWidget);
      expect(find.textContaining('数量 4.19 张'), findsOneWidget);
      expect(find.textContaining('买入金额 \$1,337'), findsOneWidget);

      // Move pointer off chart so hover cleanly dismisses
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('crisis-v2-hover-tooltip')), findsNothing);

      // Click 2025-04-07 Put TP quick-jump badge -> verifies PIT operations, Put TP, Skew Ratio & 1-Put/100-QQQ %
      final tpChip = find.textContaining('◆ 2025-04-07').first;
      await tester.ensureVisible(tpChip);
      await tester.tap(tpChip);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crisis-v2-pit-inspector')), findsOneWidget);
      expect(find.textContaining('PIT · 2025-04-07'), findsOneWidget);
      expect(find.textContaining('OPRA 偏度比 Skew Ratio'), findsOneWidget);
      expect(find.textContaining('1张 Put / 1手 QQQ'), findsWidgets);
      expect(find.textContaining('QQQ \$423.69'), findsWidgets);
      expect(find.textContaining('◆ PUT 止盈兑现'), findsWidgets);
      expect(find.textContaining('4.51x'), findsWidgets);

      // Expand v3.0 Double-Champion full strategy operating manual
      final manualToggle = find.byKey(
        const ValueKey('crisis-v3-playbook-toggle'),
      );
      await tester.ensureVisible(manualToggle);
      await tester.tap(manualToggle);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('真实净磨损审计'), findsOneWidget);
      expect(find.textContaining('IBKR 实盘下单纪律'), findsOneWidget);
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
      expect(find.textContaining('v3.0 DOUBLE-CHAMPION (PLAN D)'), findsOneWidget);
      expect(find.textContaining('Slow-Bear +8% Hysteresis Latch'), findsWidgets);
      expect(
        find.textContaining('2-Month Continuous Bear Timer'),
        findsOneWidget,
      );
      expect(find.textContaining('LIVE STRESS 87 / 100'), findsWidgets);
      expect(find.textContaining('\$1,007,160'), findsWidgets);
      expect(find.textContaining('22.76%'), findsWidgets);
      expect(find.byKey(const ValueKey('crisis-v2-bsm-calibration-note')), findsOneWidget);

      // Zoom into 2025 Tariff via range brush preset on mobile EN -> verify hover tooltip zero overflow & zero CJK
      expect(find.byKey(const ValueKey('crisis-v2-range-brush')), findsOneWidget);
      final enPreset2025 = find.byKey(const ValueKey('crisis-v2-range-preset-2025'));
      await tester.ensureVisible(enPreset2025);
      await tester.tap(enPreset2025);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Base = 100'), findsOneWidget);

      final enCanvas = find.byKey(const ValueKey('crisis-v2-chart-canvas'));
      await tester.ensureVisible(enCanvas);
      await tester.pumpAndSettle();
      final enMouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(enMouse.removePointer);
      await enMouse.addPointer(location: Offset.zero);
      await tester.pump();
      final enRect = tester.getRect(enCanvas);
      final enPlotW = enRect.width - 54.0 - 14.0;
      await enMouse.moveTo(
        Offset(enRect.left + 54.0 + (75 / 154) * enPlotW, enRect.top + 80.0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crisis-v2-hover-tooltip')), findsOneWidget);
      expect(find.textContaining('◆ SELL TP'), findsWidgets);
      expect(find.textContaining('Qty 11.49 cts'), findsOneWidget);
      expect(find.textContaining('Sell \$36,173'), findsOneWidget);
      expect(find.textContaining('+2 more trades'), findsOneWidget);

      // Click 2025-04-07 Put TP badge on mobile EN -> verify PIT inspector renders cleanly with zero overflow & zero CJK
      final enTpChip = find.textContaining('◆ 2025-04-07').first;
      await tester.ensureVisible(enTpChip);
      await tester.tap(enTpChip);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crisis-v2-pit-inspector')), findsOneWidget);
      expect(find.textContaining('OPRA Skew Ratio (125D)'), findsOneWidget);
      expect(find.textContaining('1 Put / 100 QQQ'), findsWidgets);
      expect(find.textContaining('QQQ \$423.69'), findsWidgets);
      expect(find.textContaining('◆ PUT TAKE-PROFIT'), findsWidgets);

      // Expand v3.0 Double-Champion full operating manual on mobile EN -> verify zero overflow & zero CJK
      final enManualToggle = find.byKey(
        const ValueKey('crisis-v3-playbook-toggle'),
      );
      await tester.ensureVisible(enManualToggle);
      await tester.tap(enManualToggle);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('True Roll Cost vs Gross Turnover'), findsOneWidget);

      // Ensure zero CJK characters appear in English mode (including expanded PIT inspector & SOP manual)
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
