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
      final strat = qp['strategy'] ?? 'U4_DualEngine';
      return {
        ...raw,
        'snapshotId': 'fixture-crisis-v1',
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
    'Discover renders Crisis Observatory via ?discoverTab=crisis_observatory with 6 lights, Naked Put / Collar command center, equity curve & crisis zoom-in',
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

      // 1. Verify Hero Live Tactical Signal Command Center (Slot 1, Slot 2, Slow-Bear Shield)
      expect(
        find.byKey(const ValueKey('crisis-observatory-command-center')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('crisis-slot-card-slot1')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-slot-card-slot2')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-slot-card-shield')), findsOneWidget);
      expect(
        find.textContaining('SLOW-BEAR 50% T-BILL SHIELD ACTIVE'),
        findsOneWidget,
      );
      expect(find.text('HARD FROZEN (DD > 5%)'), findsOneWidget);

      // 2. Verify Six Crisis Signals Grid (6/6 ON) & AD Breadth Banner
      expect(find.text('6 / 6 LIGHTS ON'), findsOneWidget);
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

      // 3. Verify Strategy KPI Strip ($1,479,143 End NAV, +$190,838 Alpha) & Chart Canvas
      expect(find.text('\$1,479,143'), findsOneWidget);
      expect(find.text('+\$190,838'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-observatory-canvas')),
        findsOneWidget,
      );

      // 4. Zoom into 2025-04 Tariff Crash and verify rebased header & reset button
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2025-04')),
      );
      expect(
        find.byKey(const ValueKey('crisis-zoom-reset-btn')),
        findsOneWidget,
      );
      expect(find.textContaining('Rebased to 100.0'), findsOneWidget);

      // Zoom into 2026-11 LIVE Dual-Engine Campaign
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2026-08_11_LIVE')),
      );
      expect(find.textContaining('2026-08 to 2026-11 LIVE'), findsWidgets);

      // Switch strategy to U1 Pure Options -> updates KPI to $1,454,618 / +$166,313
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-U1_PureOptions')),
      );
      expect(find.text('\$1,454,618'), findsOneWidget);
      expect(find.text('+\$166,313'), findsOneWidget);

      // Toggle full historical trade ledger & methodology accordion
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-ledger-scope-toggle')),
      );
      expect(
        find.textContaining('Full Historical Option & Shield Action Ledger'),
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
    'Crisis Observatory renders full localized Chinese UI cleanly on both Desktop and 390x844 Mobile without overflow',
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
        expect(find.textContaining('五灯破年线 50% 美债慢熊盾运行中'), findsOneWidget);
        expect(find.textContaining('首仓 50% 裸 -10% Put'), findsWidgets);
        expect(find.textContaining('次仓 50% 零成本 Collar'), findsWidgets);
        expect(tester.takeException(), isNull);
      }

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
}
