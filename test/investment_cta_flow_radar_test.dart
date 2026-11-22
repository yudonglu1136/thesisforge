import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class CtaFlowRadarFixtureApi extends ApiClient {
  CtaFlowRadarFixtureApi() : super(() => 'test');

  static Map<String, dynamic>? _cachedArtifact;
  static Map<String, dynamic> get artifact => _cachedArtifact ??=
      jsonDecode(
            File(
              'server/config/cta-flow-radar-dashboard.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(path);
    final uri = Uri.parse(path);
    if (uri.path == '/api/investment/cta-flow-radar') {
      final raw = Map<String, dynamic>.from(artifact);
      raw.remove('runtimeCheckpoint');
      final qp = uri.queryParameters;
      return {
        ...raw,
        'snapshotId': 'fixture-cta-v1',
        'requestedAsOf': qp['asOf'] ?? raw['asOfDate'],
        'selectedAsset': qp['asset'] ?? 'SPY',
        'selectedHorizon': qp['horizon'] ?? '10D',
        'availableAssets': const ['SPY', 'QQQ'],
        'availableHorizons': const ['5D', '10D'],
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
    'Discover renders CTA Flow Radar via ?discoverTab=cta_radar and switches SPY/QQQ + 10D/5D + 2022 caveat + 13F drawer',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = CtaFlowRadarFixtureApi();
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
              initialQuery: const {'discoverTab': 'cta_radar'},
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CTA Flow Radar'), findsWidgets);
      expect(
        find.byKey(const ValueKey('cta-flow-radar-root')),
        findsOneWidget,
      );
      expect(
        api.calls.any((c) => c.contains('/api/investment/cta-flow-radar')),
        isTrue,
      );

      // Verify exact SPY 10D live KPIs & beacons from artifact
      expect(find.text('\$689.81'), findsWidgets);
      expect(find.text('-10.56'), findsOneWidget);
      expect(find.text('1.160'), findsOneWidget);
      expect(find.text('1.87x'), findsOneWidget);
      expect(find.textContaining('\$716.98'), findsWidgets);
      expect(find.textContaining('ACTIVE · #11 Trigger'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cta-dual-track-curve-canvas')),
        findsOneWidget,
      );

      // Toggle 5D (1W) horizon -> breakeven flip updates to SPY 5D ($738.78)
      await tapVisible(tester, find.byKey(const ValueKey('cta-horizon-5D')));
      expect(find.textContaining('\$738.78'), findsWidgets);

      // Toggle back to 10D and switch asset to QQQ -> spot $608.45 & 10D flip $641.61
      await tapVisible(tester, find.byKey(const ValueKey('cta-horizon-10D')));
      await tapVisible(tester, find.byKey(const ValueKey('cta-asset-QQQ')));
      expect(find.text('\$608.45'), findsWidgets);
      expect(find.text('-12.20'), findsOneWidget);
      expect(find.textContaining('\$641.61'), findsWidgets);
      expect(find.textContaining('DEEP SHORT WATCH'), findsOneWidget);

      // Select 2022 slow-bear caveat battleground card
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cta-episode-2022_bear')),
      );
      expect(
        find.byKey(const ValueKey('cta-episode-detail-2022_bear')),
        findsOneWidget,
      );
      expect(find.text('SLOW-BEAR CAVEAT'), findsOneWidget);

      // Expand collapsible 31-institution 13F PIT scale & EWMAC methodology drawer
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cta-methodology-toggle')),
      );
      expect(
        find.byKey(const ValueKey('cta-13f-pit-scale-canvas')),
        findsOneWidget,
      );
      expect(find.text('EWMAC(2,8)'), findsOneWidget);
      expect(find.text('EWMAC(64,256)'), findsOneWidget);
      expect(find.text('SMA200'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CTA Flow Radar renders full localized Chinese UI cleanly without exception',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = CtaFlowRadarFixtureApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.zh,
            child: Scaffold(
              backgroundColor: const Color(0xFF06090F),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: CtaFlowRadarPanel(
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

      expect(find.text('CTA 系统化资金流雷达'), findsOneWidget);
      expect(find.textContaining('已触发 · 历史第 11 次'), findsOneWidget);
      expect(find.textContaining('倒挂锁开启'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
