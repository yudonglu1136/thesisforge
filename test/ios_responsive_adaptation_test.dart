import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/browser_location.dart';
import 'package:guru_analysis_terminal/main.dart';

import 'investment_portfolio_home_test.dart' as home_fixtures;
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
        'LoginScreen Zero-Redirect Email OTP + iOS install guide adapt cleanly on ${device.$1} ($language)',
        (tester) async {
          debugStandaloneDisplayModeOverride = false;
          tester.view.physicalSize = device.$2;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          String? sentOtpEmail;
          String? verifiedCode;
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
                  onSendOtp: (email) async {
                    sentOtpEmail = email;
                    return null;
                  },
                  onVerifyOtp: (email, code) async {
                    sentOtpEmail = email;
                    verifiedCode = code;
                    return null;
                  },
                  onLocal: () {},
                  onRetry: () {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // Verify Zero-Redirect Email OTP flow works completely in-app
          expect(
            find.byKey(const ValueKey('login-email-otp-card')),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const ValueKey('login-email-input')),
            'trader@thesisforge.tech',
          );
          await tester.tap(find.byKey(const ValueKey('login-send-otp-btn')));
          await tester.pumpAndSettle();
          expect(sentOtpEmail, 'trader@thesisforge.tech');

          expect(
            find.byKey(const ValueKey('login-otp-code-input')),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const ValueKey('login-otp-code-input')),
            '654321',
          );
          await tester.tap(find.byKey(const ValueKey('login-verify-otp-btn')));
          await tester.pumpAndSettle();
          expect(verifiedCode, '654321');

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
    'Standalone mode hides redundant browser install action inside Account sheet',
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
      await tester.tap(
        find.byKey(const ValueKey('mobile-account-sheet-button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-account-bottom-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sheet-install-ios-app')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final device in iphoneDevices) {
    for (final language in AppLanguage.values) {
      testWidgets(
        'Calm 46px mobile header, Account bottom sheet, strict 5-tab bottom bar, and SafeAreas work on ${device.$1} ($language)',
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
                  userEmail: 'owner@thesisforge.tech',
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

          // Calm mobile header has compact date pill + 2 circular icon buttons >= 44pt
          for (final keyName in [
            'mobile-date-control',
            'mobile-search-trigger',
            'mobile-account-sheet-button',
          ]) {
            final size = tester.getSize(find.byKey(ValueKey(keyName)));
            expect(size.width, greaterThanOrEqualTo(44), reason: keyName);
            expect(size.height, greaterThanOrEqualTo(44), reason: keyName);
          }

          // Strictly 5 tabs in bottom nav bar (Admin moved to Account bottom sheet)
          expect(
            find.byKey(const ValueKey('ios-bottom-nav-bar')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('mobile-nav-admin')),
            findsNothing,
          );
          for (final tabId in [
            'home',
            'discover',
            'research',
            'book',
            'strategies',
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

          // Open Account bottom sheet and verify Admin + Install Guide + Language + Logout live cleanly inside
          await tester.tap(
            find.byKey(const ValueKey('mobile-account-sheet-button')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('mobile-account-bottom-sheet')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('sheet-language-toggle')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('sheet-date-picker')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('sheet-open-admin')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('sheet-install-ios-app')),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('sheet-logout')), findsOneWidget);

          // Open iOS Install Guide from Account sheet
          await tester.tap(find.byKey(const ValueKey('sheet-install-ios-app')));
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
    'Mobile Home on iPhone 16 Pro (393x852) places NAV Curve + 2x2 Bento Grid above the fold with thumb scrubbing',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = home_fixtures.HomeApi()
        ..history = true
        ..pnlHistory = true;

      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.zh,
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
                child: PortfolioResearchPanel(
                  api: api,
                  palette: Palette(false),
                  asOf: '2026-09-09',
                  homeMode: true,
                  onDetails: () {},
                  onCompany: (_, _) {},
                  onGuru: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final chartFinder = find.byKey(const ValueKey('actual-nav-chart'));
      final bentoFinder = find.byKey(
        const ValueKey('mobile-portfolio-bento-grid'),
      );
      expect(chartFinder, findsOneWidget);
      expect(bentoFinder, findsOneWidget);

      // Verify BOTH the interactive NAV curve AND 2x2 Bento grid sit above the 852px fold!
      final chartRect = tester.getRect(chartFinder);
      final bentoRect = tester.getRect(bentoFinder);
      expect(chartRect.top, lessThan(300));
      expect(chartRect.bottom, lessThan(470));
      expect(bentoRect.bottom, lessThan(760));

      // Verify horizontal thumb-scrubbing on mobile NAV chart works without Slider
      expect(find.byType(Slider), findsNothing);
      await tester.drag(chartFinder, const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Verify switching metric capsule to Realized works cleanly on mobile
      await tester.tap(find.byKey(const ValueKey('history-metric-realized')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('realized-pnl-chart')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

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
