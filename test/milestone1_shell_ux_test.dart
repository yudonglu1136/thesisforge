import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class _ShellUxApi extends ApiClient {
  _ShellUxApi() : super(() => 'test-token');

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/api/investment/companies')) {
      final asOf = Uri.parse(path).queryParameters['asOf'] ?? '2026-11-18';
      return {
        'asOf': asOf,
        'companies': [
          {
            'ticker': 'NVDA',
            'name': 'NVIDIA Corporation',
            'sector': 'Technology',
            'availableAt': '2026-08-27',
            'coverage': 'stored_model',
            'valuationStatus': 'available',
          },
          {
            'ticker': 'AMZN',
            'name': 'Amazon.com, Inc.',
            'sector': 'Consumer Cyclical',
            'availableAt': '2026-07-31',
            'coverage': 'stored_model',
            'valuationStatus': 'available',
          },
        ],
      };
    }
    if (path.startsWith('/api/investment/research/NVDA')) {
      return {
        'ticker': 'NVDA',
        'name': 'NVIDIA Corporation',
        'currency': 'USD',
        'asOf': '2026-11-18',
        'hasPlatformModel': true,
        'snapshot': {
          'quarter': '2026-Q2',
          'availableAt': '2026-08-27',
          'fairValue': 274.86,
          'priceComparison': {'marketPrice': 227.98, 'priceDate': '2026-11-17'},
          'methods': [],
          'reconciliation': {'steps': []},
        },
        'financials': {'annual': [], 'quarterly': []},
        'researchRecords': [],
      };
    }
    if (path.startsWith('/api/investment/home')) {
      return {
        'watches': [],
        'decisions': [],
        'attention': [],
      };
    }
    if (path.startsWith('/api/investment/portfolio-analysis')) {
      return {'groups': [], 'accounts': []};
    }
    return {};
  }
}

void main() {
  testWidgets(
    'Live dateControl shows Live indicator while historical date shows replay badge and one-click Live reset',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      final api = _ShellUxApi();

      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'research',
              initialTicker: '',
              initialAsOf: today,
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('As of $today'), findsOneWidget);
      expect(find.text('Live · Latest available data'), findsOneWidget);
      expect(find.text('Historical point-in-time data'), findsNothing);
      expect(find.byKey(const ValueKey('date-reset-live')), findsNothing);

      // Open date dialog and rewind to a historical preset
      await tester.tap(find.byKey(const ValueKey('global-date-control')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('date-open-calendar')), findsOneWidget);
      await tester.tap(find.text('2022 Trough'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply date'));
      await tester.pumpAndSettle();

      expect(find.text('As of 2022-10-14'), findsOneWidget);
      expect(find.text('Point-in-time replay active'), findsOneWidget);
      expect(find.byKey(const ValueKey('date-reset-live')), findsOneWidget);

      // One-click Return to Live
      await tester.tap(find.byKey(const ValueKey('date-reset-live')));
      await tester.pumpAndSettle();
      expect(find.text('As of $today'), findsOneWidget);
      expect(find.text('Live · Latest available data'), findsOneWidget);
    },
  );

  testWidgets(
    'Global Cmd+K shortcut and sidebar search pill open CompanySearchDialog from Home and navigate to Research',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _ShellUxApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'home',
              initialTicker: '',
              initialAsOf: '2026-11-18',
              userEmail: 'investor@thesisforge.tech',
              colorBlind: false,
              onToggleColorBlind: (_) {},
              sessionExpired: true,
              onLogout: () {},
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Session-expired banner and global search trigger are visible
      expect(find.byKey(const ValueKey('session-expired-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('global-search-trigger')), findsOneWidget);

      // Trigger Ctrl+K keyboard shortcut
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.byType(CompanySearchDialog), findsOneWidget);
      await tester.tap(find.text('NVDA').first);
      await tester.pumpAndSettle();

      expect(find.text('NVIDIA Corporation'), findsWidgets);

      // Active email is always visible in the desktop sidebar AND inside preferences modal
      expect(find.byKey(const ValueKey('rail-active-account-card')), findsOneWidget);
      expect(find.text('investor@thesisforge.tech'), findsOneWidget);

      // Open preferences modal and verify signed-in email & color-blind switch
      await tester.tap(find.byKey(const ValueKey('workspace-preferences-button')));
      await tester.pumpAndSettle();
      expect(find.text('investor@thesisforge.tech'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('toggle-color-blind-mode')), findsOneWidget);
    },
  );

  testWidgets(
    'Desktop sidebar active-account card exposes current email and triggers 1-click Google account switch',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var switchCalls = 0;
      var logoutCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.zh,
            child: InvestmentWorkspace(
              api: _ShellUxApi(),
              palette: Palette(false),
              initialPage: 'home',
              initialTicker: '',
              initialAsOf: '2026-11-18',
              userEmail: 'thesisforger@gmail.com',
              showAdmin: false,
              onLogout: () => logoutCalls++,
              onSwitchAccount: () => switchCalls++,
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('thesisforger@gmail.com'), findsOneWidget);
      expect(find.text('管理'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('rail-active-account-card')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('prefs-switch-account')), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-logout')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('prefs-switch-account')));
      await tester.pumpAndSettle();
      expect(switchCalls, 1);
      expect(logoutCalls, 0);
    },
  );
}
