import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_portfolio_test.dart' as detail;

class Milestone5PortfolioApi extends detail.PortfolioApi {
  final List<String> deletedAccounts = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/api/portfolio/broker/futu') {
      return {'status': 'unconfigured'};
    }
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async {
    deletedAccounts.add(path);
    return {'status': 'ready'};
  }

  @override
  Map<String, dynamic> group(String c) {
    final base = super.group(c);
    if (c != 'USD') return base;
    return {
      ...base,
      'accountCount': 2,
      'accountMeta': [
        {
          'accountNumber': 1,
          'label': 'Margin Core',
          'reportDate': '2026-11-17',
          'reportedNav': 2200,
        },
        {
          'accountNumber': 2,
          'label': 'Roth Sleeve',
          'reportDate': '2026-11-17',
          'reportedNav': 800,
        },
      ],
      'leverage': {
        'grossToNav': 1.15,
        'longToNav': 1.05,
        'borrowing': 150,
        'borrowingToNav': 0.05,
        'shortOptions': 2,
      },
      'positions': [
        {
          'ticker': 'NVDA',
          'name': 'NVIDIA CORP',
          'kind': 'equity',
          'assetCategory': 'STK',
          'accountNumber': 1,
          'accountNumbers': [1],
          'value': 1500,
          'currency': 'USD',
          'quantity': 10,
          'price': 150,
          'costBasis': 1100,
          'avgCost': 110,
          'unrealizedPnl': 400,
          'unrealizedPct': 400 / 1100,
          'netWeight': 0.5,
          'modelGap': 0.2,
          'modelValue': 1800,
          'contribution': 0.1,
          'modelStatus': 'covered',
          'model': {
            'fairValue': 180,
            'currency': 'USD',
            'date': '2026-10-31',
            'modelRoute': 'operating_company',
            'formula': '60% normalized earnings + 40% FCFE DCF',
          },
        },
        {
          'ticker': 'MSFT',
          'name': 'MICROSOFT CORP',
          'kind': 'equity',
          'assetCategory': 'STK',
          'accountNumber': 2,
          'accountNumbers': [2],
          'value': 800,
          'currency': 'USD',
          'quantity': 2,
          'price': 400,
          'costBasis': 700,
          'avgCost': 350,
          'unrealizedPnl': 100,
          'unrealizedPct': 100 / 700,
          'netWeight': 0.266,
          'modelStatus': 'no_model',
        },
        {
          'ticker': 'PLTR  260320C00250000',
          'name': 'PLTR 20MAR26 250 C',
          'kind': 'other',
          'assetCategory': 'OPT',
          'accountNumber': 1,
          'accountNumbers': [1],
          'value': -150,
          'currency': 'USD',
          'quantity': -3,
          'price': 0.5,
          'costBasis': -420,
          'avgCost': 1.4,
          'netWeight': -0.05,
          'modelStatus': 'outside_model_scope',
        },
      ],
      'home': {
        'passiveIncome': {
          'status': 'ready',
          'fromDate': '2026-01-01',
          'toDate': '2026-11-17',
          'totalConfirmed': 355,
          'totalConfirmedNet': 340,
          'dividends': {
            'grossAmount': 115,
            'withholdingTax': -15,
            'netAmount': 100,
            'eventCount': 2,
            'bySymbol': [
              {'symbol': 'MSFT', 'amount': 115, 'events': 2},
            ],
          },
          'expiredCalls': {
            'amount': 240,
            'settlementCount': 1,
            'contractCount': 2,
            'byUnderlying': [
              {'symbol': 'NVDA', 'amount': 240, 'contracts': 2, 'settlements': 1},
            ],
          },
          'monthly': [
            {
              'month': '2026-02',
              'dividends': 115,
              'dividendsNet': 100,
              'expiredCalls': 240,
              'total': 355,
            },
          ],
          'annualSummaries': [
            {
              'year': 2026,
              'fromDate': '2026-01-01',
              'toDate': '2026-11-17',
              'isPartialYear': true,
              'dividendsGross': 115,
              'withholdingTax': -15,
              'dividendsNet': 100,
              'expiredCalls': 240,
              'total': 355,
              'totalNet': 340,
            },
          ],
          'pendingShortCalls': {
            'confirmed': false,
            'count': 1,
            'totalContracts': 3,
            'collectedPremium': 420,
            'rows': [
              {
                'symbol': 'PLTR  260320C00250000',
                'ticker': 'PLTR',
                'contracts': 3,
                'strike': 250,
                'expiry': '2026-03-20',
                'collectedPremium': 420,
              },
            ],
          },
          'pendingShortPuts': {
            'confirmed': false,
            'count': 1,
            'totalContracts': 2,
            'collectedPremium': 560,
            'collateralExposure': 24000,
            'rows': [
              {
                'symbol': 'NVDA  260417P00120000',
                'ticker': 'NVDA',
                'contracts': 2,
                'strike': 120,
                'expiry': '2026-04-17',
                'collectedPremium': 560,
                'collateralExposure': 24000,
              },
            ],
          },
        },
      },
    };
  }
}

void main() {
  setUp(() => portfolioPrivacyMode.value = false);
  tearDown(() => portfolioPrivacyMode.value = false);

  testWidgets(
    'Portfolio restores Valuation & stress tab, single-account & asset filters, Cost & P&L, and clickable OCC options',
    (t) async {
      final api = Milestone5PortfolioApi();
      String? openedCompany;
      await detail.mount(
        t,
        api,
        size: const Size(1440, 1100),
        date: '2026-11-17',
        onCompany: (symbol, _) => openedCompany = symbol,
      );

      // 1. Valuation & stress tab exists and mounts portfolio-stress-panel
      expect(find.byKey(const ValueKey('portfolio-tab-stress')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('portfolio-tab-stress')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('portfolio-stress-panel')), findsOneWidget);
      expect(find.text('Sector exposure'), findsOneWidget);
      expect(find.textContaining('uniform mark shock'), findsOneWidget);

      // 2. Holdings tab shows Cost & P&L, account filter chips, kind filter chips & parsed OCC option
      await t.tap(find.byKey(const ValueKey('portfolio-tab-holdings')));
      await t.pumpAndSettle();
      expect(find.text('Cost & P&L'), findsOneWidget);
      expect(find.textContaining('Avg '), findsWidgets);
      expect(
        find.textContaining('Short PLTR · 2026-03-20 · \$250 Call'),
        findsOneWidget,
      );

      // Filter by Account 2 ('Roth Sleeve') -> shows MSFT, hides NVDA
      await t.tap(find.byKey(const ValueKey('portfolio-account-filter-2')));
      await t.pumpAndSettle();
      expect(find.text('MSFT'), findsWidgets);
      expect(find.text('NVDA'), findsNothing);

      // Reset to All accounts and filter by Options -> shows parsed PLTR Call, hides MSFT
      await t.tap(find.byKey(const ValueKey('portfolio-account-filter-all')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('portfolio-kind-filter-options')));
      await t.pumpAndSettle();
      expect(find.text('MSFT'), findsNothing);
      final pltrCallFinder = find.textContaining(
        'Short PLTR · 2026-03-20 · \$250 Call',
      );
      expect(pltrCallFinder, findsOneWidget);

      // Clicking the parsed OCC option row opens underlying equity 'PLTR'
      await t.ensureVisible(pltrCallFinder);
      await t.tap(pltrCallFinder);
      await t.pumpAndSettle();
      expect(openedCompany, 'PLTR');

      // 3. Overview passive income renders after-tax net dividend total & pending short puts collateral
      await t.tap(find.byKey(const ValueKey('portfolio-tab-overview')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('passive-pending-short-puts')), findsOneWidget);
      expect(find.textContaining('24,000'), findsWidgets);
    },
  );

  testWidgets(
    'Per-account Rotate token & Remove actions and clean Futu guide work without overflowing',
    (t) async {
      final api = Milestone5PortfolioApi();
      var refreshed = 0;
      t.view.physicalSize = const Size(1200, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: LanguageScope(
            language: AppLanguage.en,
            child: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    PortfolioConnectionStatusPanel(
                      api: api,
                      palette: Palette(false),
                      onRefresh: () async {
                        refreshed += 1;
                      },
                      connection: const {
                        'configured': true,
                        'status': 'linked_partial',
                        'accountCount': 2,
                        'accounts': [
                          {
                            'id': 'acc-1',
                            'label': 'Primary IBKR',
                            'queryId': '111111',
                            'tokenPreview': '***111',
                          },
                          {
                            'id': 'acc-2',
                            'label': 'Expired Token Account',
                            'queryId': '222222',
                            'tokenPreview': '***222',
                          },
                        ],
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('account-rotate-token-222222')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-remove-222222')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('account-remove-222222')));
      await t.pumpAndSettle();
      expect(api.deletedAccounts, ['/api/portfolio/accounts/acc-2']);
      expect(refreshed, 1);

      // Verify Futu dialog hides developer venv path inside collapsed ExpansionTile by default
      showDialog<void>(
        context: t.element(find.byType(PortfolioConnectionStatusPanel)),
        builder: (_) => PortfolioReadOnlyBroker(
          api: api,
          palette: Palette(false),
          provider: 'futu',
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('tmp/futu-connector-venv'), findsNothing);
      expect(find.textContaining('Local OpenD CLI command'), findsOneWidget);
    },
  );
}
