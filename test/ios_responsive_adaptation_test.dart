import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/browser_location.dart';
import 'package:guru_analysis_terminal/main.dart';

import 'investment_portfolio_home_test.dart' as home_fixtures;
import 'investment_workflow_test.dart' as wf;

void main() {
  tearDown(() {
    debugStandaloneDisplayModeOverride = null;
    portfolioPrivacyMode.value = false;
  });

  const iphoneDevices = <(String, Size, EdgeInsets)>[
    ('iPhone SE', Size(375, 667), EdgeInsets.only(top: 20)),
    ('iPhone 16 Pro', Size(393, 852), EdgeInsets.only(top: 59, bottom: 34)),
    ('iPhone 16 Pro Max', Size(430, 932), EdgeInsets.only(top: 59, bottom: 34)),
  ];

  for (final device in iphoneDevices) {
    for (final language in AppLanguage.values) {
      testWidgets(
        'LoginScreen iOS v5 2-mode native In-App Login (6-Digit Code + Direct Password FaceID) & zero Google browser redirect on ${device.$1} ($language)',
        (tester) async {
          debugStandaloneDisplayModeOverride = false;
          tester.view.physicalSize = device.$2;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          String? sentOtpEmail;
          String? verifiedCode;
          String? passwordEmail;
          String? submittedPassword;

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
                  onPasswordSignIn: (email, pwd) async {
                    passwordEmail = email;
                    submittedPassword = pwd;
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

          // Browser-redirecting Google OAuth MUST be hidden on mobile viewports!
          expect(find.textContaining('Google'), findsNothing);

          // 1. Direct 6-digit pairing code shortcut works without sending email
          expect(
            find.byKey(const ValueKey('login-email-otp-card')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('login-open-pair-code-btn')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('login-otp-code-input')),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const ValueKey('login-otp-code-input')),
            '482917',
          );
          await tester.tap(find.byKey(const ValueKey('login-verify-otp-btn')));
          await tester.pumpAndSettle();
          expect(verifiedCode, '482917');

          // 2. Email OTP / Handoff send + verify works in-app
          await tester.enterText(
            find.byKey(const ValueKey('login-email-input')),
            'trader@thesisforge.tech',
          );
          await tester.tap(find.text(language == AppLanguage.zh ? '重发邮件' : 'Resend'));
          await tester.pumpAndSettle();
          expect(sentOtpEmail, 'trader@thesisforge.tech');

          // 3. Switch to Mode 2: Direct Password · FaceID
          await tester.tap(find.byKey(const ValueKey('login-mode-password')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('login-password-card')),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const ValueKey('login-password-input')),
            'SnowballSecret88!',
          );
          await tester.tap(
            find.byKey(const ValueKey('login-password-submit-btn')),
          );
          await tester.pumpAndSettle();
          expect(passwordEmail, 'trader@thesisforge.tech');
          expect(submittedPassword, 'SnowballSecret88!');

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
        'Snowball Pocket Edition 4-Tab pruning (Overview, Holdings, Income, Account) + zero desktop clutter on ${device.$1} ($language)',
        (tester) async {
          debugStandaloneDisplayModeOverride = true;
          tester.view.physicalSize = device.$2;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          String? savedPassword;
          final api = home_fixtures.HomeApi()
            ..history = true
            ..pnlHistory = true;

          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(padding: device.$3),
                child: child!,
              ),
              home: LanguageScope(
                language: language,
                child: InvestmentWorkspace(
                  api: api,
                  palette: Palette(false),
                  initialPage: 'home',
                  initialTicker: '',
                  initialAsOf: '2026-09-09',
                  userEmail: 'owner@thesisforge.tech',
                  onLanguage: (_) {},
                  onLegacy: () {},
                  onLegacyView: (_) {},
                  onLogout: () {},
                  onUpdatePassword: (pwd) async {
                    savedPassword = pwd;
                    return null;
                  },
                  onCreatePairCode: () async => {
                    'code': '482917',
                    'expiresInSeconds': 300,
                  },
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

          // Header controls >= 44x44 and NO desktop global search button on mobile
          expect(
            find.byKey(const ValueKey('mobile-search-trigger')),
            findsNothing,
          );
          for (final keyName in [
            'mobile-date-control',
            'mobile-header-privacy-toggle',
            'mobile-account-sheet-button',
          ]) {
            final size = tester.getSize(find.byKey(ValueKey(keyName)));
            expect(size.width, greaterThanOrEqualTo(44), reason: keyName);
            expect(size.height, greaterThanOrEqualTo(44), reason: keyName);
          }

          // Strictly ONLY 4 Snowball tabs in bottom nav bar; zero desktop tabs!
          for (final pruned in [
            'discover',
            'research',
            'book',
            'strategies',
            'admin',
          ]) {
            expect(
              find.byKey(ValueKey('mobile-nav-$pruned')),
              findsNothing,
              reason: '$pruned must be pruned from mobile navigation',
            );
          }
          for (final tabId in ['home', 'holdings', 'income', 'accounts']) {
            final tabFinder = find.byKey(ValueKey('mobile-nav-$tabId'));
            expect(tabFinder, findsOneWidget);
            final tabRect = tester.getRect(tabFinder);
            expect(tabRect.width, greaterThanOrEqualTo(44), reason: tabId);
            expect(tabRect.height, greaterThanOrEqualTo(44), reason: tabId);
            expect(
              tabRect.bottom,
              lessThanOrEqualTo(device.$2.height - device.$3.bottom + 0.5),
            );
          }

          // Tab 2: Holdings -> tap equity card opens mobile snapshot sheet (NEVER desktop Research!)
          await tester.tap(find.byKey(const ValueKey('mobile-nav-holdings')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('snowball-mobile-holdings-screen')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('snowball-holding-card-AAA')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('mobile-stock-snapshot-sheet')),
            findsOneWidget,
          );
          await tester.tap(
            find.byTooltip(language == AppLanguage.zh ? '关闭' : 'Close'),
          );
          await tester.pumpAndSettle();

          // Tab 3: Income -> verify 3-segment ledger
          await tester.tap(find.byKey(const ValueKey('mobile-nav-income')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('snowball-mobile-income-screen')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('snowball-income-tab-daily')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('snowball-income-tab-dividends')),
          );
          await tester.pumpAndSettle();

          // Tab 4: Account -> verify Direct Password (FaceID) + 6-Digit Pairing Code dialogs
          await tester.tap(find.byKey(const ValueKey('mobile-nav-accounts')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('snowball-mobile-accounts-screen')),
            findsOneWidget,
          );

          await tester.tap(
            find.byKey(const ValueKey('mobile-account-set-password-btn')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('app-password-dialog')),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const ValueKey('app-password-input')),
            'DirectPass99!',
          );
          await tester.enterText(
            find.byKey(const ValueKey('app-password-confirm-input')),
            'DirectPass99!',
          );
          await tester.tap(find.byKey(const ValueKey('app-password-submit')));
          await tester.pumpAndSettle();
          expect(savedPassword, 'DirectPass99!');
          await tester.tap(
            find.text(language == AppLanguage.zh ? '完成' : 'Done'),
          );
          await tester.pumpAndSettle();

          await tester.tap(
            find.byKey(const ValueKey('mobile-account-pair-code-btn')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('device-pair-code-dialog')),
            findsOneWidget,
          );
          expect(find.text('482 917'), findsOneWidget);
          await tester.tap(
            find.text(language == AppLanguage.zh ? '关闭' : 'Close'),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Desktop (>= 1100px) keeps all 6 full research rail tabs 100% untouched',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: wf.WorkflowTestApi(),
              palette: Palette(false),
              initialPage: 'home',
              initialTicker: '',
              initialAsOf: '2026-06-01',
              onLanguage: (_) {},
              onLegacy: () {},
              onLegacyView: (_) {},
              showAdmin: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ios-bottom-nav-bar')), findsNothing);
      expect(
        find.byKey(const ValueKey('global-search-trigger')),
        findsOneWidget,
      );
      for (final label in [
        'Home',
        'Discover',
        'Research',
        'Portfolio',
        'Strategies',
        'Admin',
      ]) {
        expect(find.text(label), findsWidgets);
      }
      expect(tester.takeException(), isNull);
    },
  );

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

      final chartRect = tester.getRect(chartFinder);
      final bentoRect = tester.getRect(bentoFinder);
      expect(chartRect.top, lessThan(300));
      expect(chartRect.bottom, lessThan(470));
      expect(bentoRect.bottom, lessThan(760));

      expect(find.byType(Slider), findsNothing);
      await tester.drag(chartFinder, const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

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
    'iOS v4/v5 Interactive Bento sheets, Hero pills, chart range/metric InkWells, and option detail sheets work end-to-end',
    (tester) async {
      debugStandaloneDisplayModeOverride = true;
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final openedCompanies = <(String, String)>[];
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
                  onCompany: (sym, sec) => openedCompanies.add((sym, sec)),
                  onGuru: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('mobile-bento-realized')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-realized-pnl-sheet')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('realized-inst-AAA')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('realized-inst-AAA CALL')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('realized-sheet-tab-daily')));
      await tester.pumpAndSettle();
      expect(find.text('2026-08-20'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('realized-sheet-tab-income')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已确认现金收入合计'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('sheet-switch-chart-realized')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-realized-pnl-sheet')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('realized-pnl-chart')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mobile-bento-session')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-daily-pnl-sheet')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('sheet-switch-chart-estimate')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cashAdjusted-pnl-chart')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('history-metric-nav')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('actual-nav-chart')), findsOneWidget);
      for (final r in ['1M', 'YTD', 'All']) {
        await tester.tap(find.byKey(ValueKey('history-range-$r')));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byKey(const ValueKey('mobile-hero-accounts-pill')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-cash-accounts-sheet')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('mobile-bento-cash')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-cash-accounts-sheet')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('mobile-bento-income-banner')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('已确认现金收入合计'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('mobile-bento-positions')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-positions-sheet')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('positions-sheet-tab-equity')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sheet-position-AAA')));
      await tester.pumpAndSettle();
      expect(openedCompanies, contains(('AAA', 'evidence')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'iPhone SE 375x667 at 150% accessibility text scale has zero overflow across all 4 Snowball tabs',
    (tester) async {
      debugStandaloneDisplayModeOverride = false;
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = home_fixtures.HomeApi()
        ..history = true
        ..pnlHistory = true;

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
              api: api,
              palette: Palette(false),
              initialPage: 'home',
              initialTicker: '',
              initialAsOf: '2026-09-09',
              onLanguage: (_) {},
              onLegacy: () {},
              onLogout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final tabId in ['holdings', 'income', 'accounts']) {
        await tester.tap(find.byKey(ValueKey('mobile-nav-$tabId')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '150% scale on $tabId');
      }
    },
  );
}
