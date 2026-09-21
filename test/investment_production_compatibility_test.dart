import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_valuation_memory_test.dart' show MemoryApi;
import 'investment_valuation_test.dart' as worksheet;

class _CompatibilityApi extends ApiClient {
  _CompatibilityApi() : super(() => 'synthetic-session');
  final paths = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    if (path.startsWith('/api/investment/portfolio-analysis')) {
      return {
        'version': 'portfolio-research-v1',
        'asOf': Uri.parse(path).queryParameters['asOf'],
        'status': 'not_connected',
        'groups': <Map<String, dynamic>>[],
      };
    }
    return {
      'attention': [],
      'discovery': [],
      'decisions': [],
      'gurus': [],
      'portfolio': {
        'positions': [],
        'overlap': [],
        'shadow': {'issues': []},
      },
    };
  }
}

void main() {
  test(
    'the nonvisual build marker identifies the compiled workflow branch',
    () {
      expect(
        investmentWorkflowBuildMarker,
        investmentWorkflowEnabled
            ? 'thesisforge-workflow-enabled-v1'
            : 'thesisforge-workflow-disabled-v1',
      );
    },
  );
  for (final width in [390.0, 1280.0]) {
    for (final language in AppLanguage.values) {
      testWidgets('production navigation is usable at $width / $language', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, width == 390 ? 844 : 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? destination;
        var signedOut = false;
        final api = _CompatibilityApi();
        await tester.pumpWidget(
          MaterialApp(
            home: LanguageScope(
              language: language,
              child: InvestmentWorkspace(
                api: api,
                palette: Palette(false),
                initialPage: 'home',
                initialTicker: '',
                initialAsOf: '2026-09-10',
                onLanguage: (_) {},
                onLegacy: () {},
                onLegacyView: (value) => destination = value,
                onLogout: () => signedOut = true,
                showAdmin: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Local preview · Historical PIT'), findsNothing);
        expect(find.text('本地预览 · 历史 PIT'), findsNothing);
        expect(find.text('Ontology'), findsNothing);
        expect(find.text('图谱'), findsNothing);
        final admin = language == AppLanguage.en ? 'Admin' : '管理';
        await tester.tap(find.text(admin));
        await tester.pumpAndSettle();
        expect(destination, 'admin');
        final signOut = language == AppLanguage.en ? 'Sign out' : '退出登录';
        await tester.tap(find.byTooltip(signOut));
        await tester.pumpAndSettle();
        expect(signedOut, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  test('legacy product bookmarks migrate into the new ThesisForge routes', () {
    expect(
      normalizeRouteMode('portfolio'),
      investmentWorkflowEnabled ? 'book' : 'portfolio',
    );
    expect(normalizeRouteMode('valuation'), 'valuation');
    expect(
      normalizeRouteMode('guru'),
      investmentWorkflowEnabled ? 'discover' : 'guru',
    );
    expect(
      normalizeRouteMode('dbmf'),
      investmentWorkflowEnabled ? 'discover' : 'guru',
    );
    expect(
      normalizeRouteMode(null),
      investmentWorkflowEnabled ? 'home' : 'guru',
    );
  });

  if (investmentWorkflowEnabled) {
    testWidgets('retired bookmarks render Discover without retired API calls', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _CompatibilityApi();
      for (final path in [
        '/?view=ontology&lang=zh',
        '/?mode=dbmf&lang=en',
        '/ontology/?view=market&lang=zh',
        '/ontology/index.html?code=oauth-callback&lang=en',
        '/dbmf/history?lang=en',
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: TerminalHome(
              key: ValueKey(path),
              api: api,
              accessToken: 'synthetic-session',
              userId: 'user-a',
              userName: 'Test user',
              userEmail: 'user@example.com',
              language: AppLanguage.en,
              routeUri: Uri.parse('https://thesisforge.tech$path'),
              onLanguage: (_) {},
              onLogout: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<InvestmentWorkspace>(find.byType(InvestmentWorkspace))
              .initialPage,
          'discover',
        );
        expect(find.text('Ontology'), findsNothing);
        expect(
          api.paths.where(
            (path) =>
                path.startsWith('/api/ontology') ||
                path.startsWith('/api/dbmf'),
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('browser Back waits for the current account worksheet save', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = MemoryApi();
      Widget terminal(String view, int revision) => MaterialApp(
        home: TerminalHome(
          key: const ValueKey('same-user'),
          api: api,
          accessToken: 'synthetic-session',
          userId: 'user-a',
          userName: 'Test user',
          userEmail: 'user@example.com',
          language: AppLanguage.en,
          routeUri: Uri.parse(
            'https://thesisforge.tech/?view=$view&valuation=TEST&section=value&asOf=2026-06-01&lang=en',
          ),
          routeRevision: revision,
          onLanguage: (_) {},
          onLogout: () {},
        ),
      );
      await tester.pumpWidget(terminal('research', 0));
      await tester.pumpAndSettle();
      final input = worksheet.cell('growth %', 1);
      await tester.ensureVisible(input);
      final gate = Completer<void>();
      api.delayDraft = gate;
      await tester.enterText(input, '21');
      // Navigate before the 650 ms debounce has fired.
      await tester.pumpWidget(terminal('home', 1));
      await tester.pump();
      expect(
        api.calls.where((call) => call.$1.endsWith('/valuation-drafts')).length,
        1,
      );
      expect(api.drafts, isEmpty);
      expect(
        tester
            .widget<InvestmentWorkspace>(find.byType(InvestmentWorkspace))
            .initialPage,
        'research',
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(api.drafts.single['assumptions']['growth'][0], .21);
      expect(
        tester
            .widget<InvestmentWorkspace>(find.byType(InvestmentWorkspace))
            .initialPage,
        'home',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'browser Back restores the workspace even to the original URL',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = _CompatibilityApi();
        Widget terminal(int routeRevision) => MaterialApp(
          home: TerminalHome(
            key: const ValueKey('same-user'),
            api: api,
            accessToken: 'synthetic-session',
            userId: 'user-a',
            userName: 'Test user',
            userEmail: 'user@example.com',
            language: AppLanguage.en,
            routeUri: Uri.parse(
              'https://thesisforge.tech/?view=home&asOf=2026-09-10&lang=en',
            ),
            routeRevision: routeRevision,
            onLanguage: (_) {},
            onLogout: () {},
          ),
        );
        await tester.pumpWidget(terminal(0));
        await tester.pumpAndSettle();
        final homeReads = api.paths
            .where((path) => path.startsWith('/api/investment/home'))
            .length;
        await tester.tap(find.text('Portfolio').first);
        await tester.pumpAndSettle();
        await tester.pumpWidget(terminal(1));
        await tester.pumpAndSettle();
        expect(
          api.paths
              .where((path) => path.startsWith('/api/investment/home'))
              .length,
          homeReads + 1,
        );
        expect(find.byType(InvestmentWorkspace), findsOneWidget);
        expect(
          api.paths.where((path) => path.startsWith('/api/gurus')),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
