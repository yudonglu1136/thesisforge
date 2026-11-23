import 'dart:convert';
import 'dart:io';

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
        'snapshotId': 'fixture-crisis-v2',
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
    'Discover renders pure-options U1 Crisis Observatory (zero T-Bill) with interactive Zoom In, Period Presets & RangeSlider',
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

      // 1. Verify Hero Live Tactical Signal Command Center (Slot 1 + Slot 2 ONLY, ZERO T-Bill Shield)
      expect(
        find.byKey(const ValueKey('crisis-observatory-command-center')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('crisis-slot-card-slot1')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-slot-card-slot2')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-slot-card-shield')), findsNothing);
      expect(find.textContaining('T-BILL'), findsNothing);
      expect(find.textContaining('T-Bill'), findsNothing);
      expect(
        find.textContaining('NEW COLLARS HARD FROZEN BELOW ATH -5%'),
        findsOneWidget,
      );
      expect(find.text('HARD FROZEN (DD > 5%)'), findsOneWidget);
      expect(find.textContaining('100% QQQ'), findsWidgets);

      // 2. Verify Six Crisis Signals Grid (6/6 ON) & AD Breadth Banner
      expect(find.text('6 / 6 LIGHTS ON'), findsOneWidget);
      expect(find.textContaining('5D Avg: 5.40'), findsOneWidget);
      expect(find.textContaining('ATH <= 5%: -19.90%'), findsOneWidget);
      expect(find.textContaining('VIX/VIX3M >= 1.10 TP: 1.160'), findsOneWidget);
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

      // 3. Verify default U1 Pure Options KPI Strip ($1,454,618 End NAV, +$166,313 Alpha) & Chart Canvas
      expect(find.text('\$1,454,618'), findsOneWidget);
      expect(find.text('+\$166,313'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-strategy-pill-U4_DualEngine')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('crisis-observatory-canvas')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-zoom-range-slider')),
        findsOneWidget,
      );

      // 4. Test Quick Period Preset (1Y) -> reveals dynamic zoomed-window stats bar & reset button
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-period-pill-1Y')),
      );
      expect(
        find.byKey(const ValueKey('crisis-zoom-window-stats')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-zoom-reset-btn')),
        findsOneWidget,
      );
      expect(find.textContaining('252D'), findsWidgets);

      // 5. Test Interactive Zoom In (+) & Pan Left (←) & Rebased/USD Toggle
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-in-btn')),
      );
      expect(find.textContaining('Custom Range:'), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-pan-left-btn')),
      );
      expect(
        find.byKey(const ValueKey('crisis-zoom-window-stats')),
        findsOneWidget,
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-rebased-toggle-btn')),
      );
      expect(find.textContaining('Absolute NAV'), findsOneWidget);

      // 6. Zoom into 2025-04 Tariff Crash crisis pill -> snaps slider & rebases to 100.0
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2025-04')),
      );
      expect(find.textContaining('Rebased to 100.0'), findsOneWidget);

      // Zoom into 2026-11 LIVE Pure-Options Campaign
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2026-08_11_LIVE')),
      );
      expect(find.textContaining('2026-08 to 2026-11 LIVE'), findsWidgets);

      // Reset back to full 2015-2026 range
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-reset-btn')),
      );
      expect(
        find.byKey(const ValueKey('crisis-zoom-window-stats')),
        findsNothing,
      );

      // Switch strategy to B1c Pure AD Line -> updates KPI to $1,453,136 / +$164,831
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-B1c_PureAD')),
      );
      expect(find.text('\$1,453,136'), findsOneWidget);
      expect(find.text('+\$164,831'), findsOneWidget);

      // Toggle full historical trade ledger & methodology accordion
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-ledger-scope-toggle')),
      );
      expect(
        find.textContaining('Full Historical Pure-Options Action Ledger'),
        findsOneWidget,
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-methodology-toggle')),
      );
      expect(find.textContaining('Empirical OPRA Skew'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Crisis Observatory renders full localized Chinese pure-options UI cleanly on both Desktop and 390x844 Mobile without overflow',
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

        expect(find.text('6 / 6 危机灯亮起'), findsOneWidget);
        expect(find.textContaining('100% 满仓 QQQ'), findsWidgets);
        expect(find.textContaining('美债慢熊盾'), findsNothing);
        expect(find.textContaining('首仓 50% 裸 -10% Put'), findsWidgets);
        expect(find.textContaining('次仓 50% 零成本 Collar'), findsWidgets);
        expect(
          find.byKey(const ValueKey('crisis-zoom-range-slider')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
}
