import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class CrisisObservatoryFixtureApi extends ApiClient {
  CrisisObservatoryFixtureApi() : super(() => 'test');

  static Map<String, dynamic>? _cachedArtifact;
  static Map<String, dynamic> get artifact => _cachedArtifact ??=
      jsonDecode(
            File(
              'server/config/crisis-observatory-dashboard.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(path);
    final uri = Uri.parse(path);
    if (uri.path == '/api/investment/crisis-observatory' ||
        uri.path == '/api/discover/crisis-observatory') {
      final raw = Map<String, dynamic>.from(artifact);
      final qp = uri.queryParameters;
      final strat = qp['strategy'] ?? 'U1_PureOptions';
      return {
        ...raw,
        'snapshotId': 'fixture-crisis-v2-minimal',
        'requestedAsOf': qp['asOf'] ?? raw['as_of_date'],
        'selected_strategy_id': strat,
        'liveExtended': false,
      };
    }
    return {
      'asOf': '2026-11-20',
      'rows': const <dynamic>[],
      'gurus': const <dynamic>[],
    };
  }
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Discover renders minimalist Crisis Observatory via ?discoverTab=crisis_observatory with plain human copy, 6 signals, interactive chart hover & expandable timeline',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = CrisisObservatoryFixtureApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'discover',
              initialTicker: '',
              initialAsOf: '2026-11-20',
              initialQuery: const {'discoverTab': 'crisis_observatory'},
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Crisis Observatory'), findsWidgets);
      expect(
        find.byKey(const ValueKey('crisis-observatory-root')),
        findsOneWidget,
      );
      expect(
        api.calls.any(
          (c) => c.contains('/api/investment/crisis-observatory'),
        ),
        isTrue,
      );

      // Zero raw internal engineering IDs or bond-timing clutter exposed on screen
      expect(find.textContaining('U4_DualEngine'), findsNothing);
      expect(find.textContaining('U1_PureOptions'), findsNothing);
      expect(find.textContaining('B1c_PureAD'), findsNothing);
      expect(find.textContaining('MONETIZED_STANDBY'), findsNothing);
      expect(find.textContaining('T-Bill'), findsNothing);

      // 1. Clean Verdict Header + 3-column pure-options hairline strip + expandable rules
      expect(
        find.byKey(const ValueKey('crisis-observatory-command-center')),
        findsOneWidget,
      );
      expect(
        find.text('100% Hold QQQ · Call Caps Paused in Pullback (6/6 Lights)'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('crisis-slot-card-core')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-slot-card-slot1')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-slot-card-slot2')), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('crisis-rules-toggle')));
      expect(find.textContaining('Execution rules:'), findsOneWidget);

      // 2. Minimalist Six Crisis Signals flat grid + AD Line footer
      expect(find.text('6 / 6 Active'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-light-card-sig1_fed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-light-card-sig4_copper')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-observatory-ad-banner')),
        findsOneWidget,
      );

      // 3. Hero Interactive Chart: exact U1 Dual-Track TP metrics + crisis zoom + clean hover card
      expect(find.text('\$1,604,274'), findsOneWidget);
      expect(find.text('+\$315,970'), findsOneWidget);
      expect(find.text('-31.5%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-observatory-canvas')),
        findsOneWidget,
      );

      // Zoom into 2022 Slow Bear and verify Track-2 5x Slow-Bear Harvest (+$37,680 / -31.5% MDD)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2022')),
      );
      expect(find.text('2022 Rate-Hike Grinding Bear Market'), findsWidgets);
      expect(find.textContaining('5x Slow-Bear Harvest'), findsWidgets);
      expect(find.textContaining('+\$37,680'), findsWidgets);

      // Zoom into 2025 April Tariff Crash and hover 2025-04-07 1.10 Panic Harvest
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2025-04')),
      );
      expect(find.text('2025 April Tariff Crash'), findsWidgets);

      final canvasFinder = find.byKey(const ValueKey('crisis-observatory-canvas'));
      await tester.ensureVisible(canvasFinder);
      await tester.pumpAndSettle();
      final canvasRect = tester.getRect(canvasFinder);
      final hoverTarget = Offset(
        canvasRect.left + 52.0 + (canvasRect.width - 64.0) * (73.0 / 101.0),
        canvasRect.top + 120.0,
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(hoverTarget);
      await tester.pumpAndSettle();

      final tooltipFinder = find.byKey(
        const ValueKey('crisis-chart-hover-tooltip'),
      );
      expect(tooltipFinder, findsOneWidget);
      expect(
        find.descendant(
          of: tooltipFinder,
          matching: find.textContaining('2025-04-07'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tooltipFinder,
          matching: find.textContaining('◆ 1.10 Panic Harvest'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tooltipFinder,
          matching: find.textContaining('+\$76,729'),
        ),
        findsOneWidget,
      );

      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('crisis-chart-hover-tooltip')),
        findsNothing,
      );

      // Reset zoom to All 12Y and switch strategy tab to Breadth Divergence (B1c)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-reset-btn')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-B1c_PureAD')),
      );
      expect(find.text('\$1,508,126'), findsOneWidget);
      expect(find.text('+\$219,821'), findsOneWidget);

      // 4. Zoom into 2026 LIVE and expand a tranche row for 4-factor convexity
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-U1_PureOptions')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2026-08_11_LIVE')),
      );
      expect(
        find.byKey(const ValueKey('crisis-tranche-row-34')),
        findsOneWidget,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-tranche-row-34')),
      );
      expect(find.textContaining('Vega'), findsWidgets);

      // Toggle full 12-year chronological ledger
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-ledger-scope-toggle')),
      );
      expect(
        find.textContaining('All 12-Year Historical Operations'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Crisis Observatory renders calm localized Chinese UI cleanly on both Desktop (1440x1200) and Mobile (390x844) without overflow',
    (tester) async {
      final api = CrisisObservatoryFixtureApi();

      for (final size in [const Size(1440, 1200), const Size(390, 844)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          MaterialApp(
            home: LanguageScope(
              language: AppLanguage.zh,
              child: Scaffold(
                backgroundColor: const Color(0xFF06090F),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: CrisisObservatoryPanel(
                    api: api,
                    palette: Palette(false),
                    asOf: '2026-11-20',
                    onCompany: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('100% 持有 QQQ · 低位暂停新卖 Call（6/6 亮灯）'),
          findsOneWidget,
        );
        expect(find.text('6 / 6 亮灯'), findsOneWidget);
        expect(find.text('历史保护策略 vs 死拿 QQQ'), findsOneWidget);
        expect(find.text('100% 满仓 QQQ'), findsOneWidget);
        expect(find.textContaining('短债'), findsNothing);
        expect(tester.takeException(), isNull);
      }

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
}
