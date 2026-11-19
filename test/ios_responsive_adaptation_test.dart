import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/browser_location.dart';
import 'package:guru_analysis_terminal/main.dart';

import 'investment_workflow_test.dart' as wf;

void main() {
  tearDown(() {
    debugStandaloneDisplayModeOverride = null;
  });

  const iphoneDevices = <(String, Size, EdgeInsets)>[
    ('iPhone SE', Size(375, 667), EdgeInsets.only(top: 20)),
    ('iPhone 16 Pro', Size(393, 852), EdgeInsets.only(top: 59, bottom: 34)),
    ('iPhone 16 Pro Max', Size(430, 932), EdgeInsets.only(top: 59, bottom: 34)),
  ];

  for (final device in iphoneDevices) {
    for (final language in AppLanguage.values) {
      testWidgets(
        'LoginScreen + iOS install guide adapt cleanly on ${device.$1} ($language)',
        (tester) async {
          debugStandaloneDisplayModeOverride = false;
          tester.view.physicalSize = device.$2;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(padding: device.$3),
                child: child!,
              ),
              home: LanguageScope(
                language: language,
                child: LoginScreen(
                  authConfigured: true,
                  localBypassEnabled: true,
                  language: language,
                  onLanguage: (_) {},
                  onGoogle: () {},
                  onLocal: () {},
                  onRetry: () {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final installBtn = find.byKey(
            const ValueKey('login-install-ios-app'),
          );
          expect(installBtn, findsOneWidget);
          expect(tester.getSize(installBtn).height, greaterThanOrEqualTo(44));

          await tester.ensureVisible(installBtn);
          await tester.tap(installBtn);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const ValueKey('ios-install-guide-dialog')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('ios-install-download-profile')),
            findsOneWidget,
          );
          expect(find.textContaining('.dmg'), findsWidgets);

          if (language == AppLanguage.en) {
            final dialogTexts = tester
                .widgetList<Text>(
                  find.descendant(
                    of: find.byKey(const ValueKey('ios-install-guide-dialog')),
                    matching: find.byType(Text),
                  ),
                )
                .map((w) => w.data ?? '')
                .join('\n');
            expect(RegExp(r'[\u3400-\u9fff]').hasMatch(dialogTexts), isFalse);
          }

          await tester.tap(
            find.byKey(const ValueKey('ios-install-guide-close')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('ios-install-guide-dialog')),
            findsNothing,
          );
        },
      );
    }
  }

  testWidgets(
    'Standalone mode hides redundant browser install buttons automatically',
    (tester) async {
      debugStandaloneDisplayModeOverride = true;
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.zh,
            child: InvestmentWorkspace(
              api: wf.WorkflowTestApi(),
              palette: Palette(false),
              initialPage: 'home',
              initialTicker: '',
              initialAsOf: '2026-06-01',
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-install-app-button')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final device in iphoneDevices) {
    for (final language in AppLanguage.values) {
      testWidgets(
        'Workspace mobile header, >=44pt touch targets, Dynamic Island & Home Indicator SafeArea, and all tabs work on ${device.$1} ($language)',
        (tester) async {
          debugStandaloneDisplayModeOverride = false;
          tester.view.physicalSize = device.$2;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(padding: device.$3),
                child: child!,
              ),
              home: LanguageScope(
                language: language,
                child: InvestmentWorkspace(
                  api: wf.WorkflowTestApi(),
                  palette: Palette(false),
                  initialPage: 'home',
                  initialTicker: '',
                  initialAsOf: '2026-06-01',
                  onLanguage: (_) {},
                  onLegacy: () {},
                  onLegacyView: (_) {},
                  onLogout: () {},
                  showAdmin: true,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // Top header respects Dynamic Island top SafeArea
          final topHeaderRect = tester.getRect(
            find.byKey(const ValueKey('ios-mobile-top-header')),
          );
          expect(topHeaderRect.top, closeTo(device.$3.top, 0.5));

          // Every top header interactive button meets >= 44x44pt Apple HIG target
          for (final keyName in [
            'mobile-search-trigger',
            'mobile-date-control',
            'mobile-install-app-button',
            'mobile-preferences-button',
            'mobile-language-toggle',
          ]) {
            final size = tester.getSize(find.byKey(ValueKey(keyName)));
            expect(size.width, greaterThanOrEqualTo(44), reason: keyName);
            expect(size.height, greaterThanOrEqualTo(44), reason: keyName);
          }

          // Bottom nav bar exists, meets >= 44pt tap target, and respects bottom Home Indicator SafeArea
          expect(
            find.byKey(const ValueKey('ios-bottom-nav-bar')),
            findsOneWidget,
          );
          for (final tabId in [
            'home',
            'discover',
            'research',
            'book',
            'strategies',
            'admin',
          ]) {
            final tabFinder = find.byKey(ValueKey('mobile-nav-$tabId'));
            expect(tabFinder, findsOneWidget);
            final tabRect = tester.getRect(tabFinder);
            expect(tabRect.width, greaterThanOrEqualTo(44), reason: tabId);
            expect(tabRect.height, greaterThanOrEqualTo(44), reason: tabId);
            expect(
              tabRect.bottom,
              lessThanOrEqualTo(device.$2.height - device.$3.bottom + 0.5),
              reason: '$tabId respects bottom Home Indicator inset',
            );
          }

          // Tap through Discover, Research, Portfolio, Strategies via bottom bar
          for (final tabId in ['discover', 'research', 'book', 'strategies']) {
            await tester.tap(find.byKey(ValueKey('mobile-nav-$tabId')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'tab $tabId');
          }

          // Open iOS Install Guide from mobile header
          await tester.tap(
            find.byKey(const ValueKey('mobile-install-app-button')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('ios-install-guide-dialog')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('ios-install-guide-close')),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'iPhone SE 375x667 at 150% accessibility text scale has zero overflow',
    (tester) async {
      debugStandaloneDisplayModeOverride = false;
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.5),
              padding: const EdgeInsets.only(top: 20),
            ),
            child: child!,
          ),
          home: LanguageScope(
            language: AppLanguage.zh,
            child: InvestmentWorkspace(
              api: wf.WorkflowTestApi(),
              palette: Palette(false),
              initialPage: 'book',
              initialTicker: '',
              initialAsOf: '2026-06-01',
              onLanguage: (_) {},
              onLegacy: () {},
              onLogout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
