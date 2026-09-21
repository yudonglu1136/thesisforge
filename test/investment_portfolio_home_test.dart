import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_portfolio_test.dart' as fixtures;
import 'investment_workflow_test.dart' as workflow;

class HomeApi extends fixtures.PortfolioApi {
  bool daily = false, history = false, pnlHistory = false;
  @override
  Map<String, dynamic> group(String c) => {
    ...super.group(c),
    'home': {
      'version': 'portfolio-home-v1',
      'reportDate': '2026-09-09',
      'accountValue': 3000,
      'nav': {
        'rows': [
          if (history) {'date': '2026-07-01', 'nav': 2500},
          {'date': '2026-09-09', 'nav': 3000},
        ],
      },
      'daily': {
        'status': daily ? 'ready' : 'daily_mtm_required',
        'date': '2026-09-09',
        'pnl': daily ? 50 : null,
        'rows': daily
            ? [
                {'ticker': 'AAA', 'pnl': 100, 'assetCategory': 'STK'},
                {'ticker': 'BBB', 'pnl': -50, 'assetCategory': 'STK'},
              ]
            : [],
      },
      'unrealized': {
        'status': 'ready',
        'covered': 1,
        'total': 2,
        'rows': [
          {'ticker': 'AAA', 'pnl': 200, 'assetCategory': 'STK'},
        ],
      },
      if (pnlHistory)
        'history': {
          'realized': {
            'status': 'ready',
            'fromDate': '2026-07-01',
            'toDate': '2026-09-09',
            'total': 50,
            'tradeCount': 3,
            'rows': [
              {'date': '2026-07-01', 'pnl': 20, 'cumulativePnl': 20},
              {'date': '2026-08-20', 'pnl': 50, 'cumulativePnl': 70},
              {'date': '2026-09-09', 'pnl': -20, 'cumulativePnl': 50},
            ],
            'byInstrument': [
              {'ticker': 'AAA', 'pnl': 70, 'assetCategory': 'STK'},
              {'ticker': 'AAA CALL', 'pnl': -20, 'assetCategory': 'OPT'},
            ],
          },
          'cashAdjusted': {
            'status': 'estimate',
            'rows': [
              {
                'date': '2026-07-01',
                'pnl': 0,
                'cumulativePnl': 0,
                'netFlow': 0,
              },
              {
                'date': '2026-08-20',
                'previousDate': '2026-07-01',
                'pnl': 50,
                'cumulativePnl': 50,
                'netFlow': 500,
              },
              {
                'date': '2026-09-09',
                'previousDate': '2026-08-20',
                'pnl': -10,
                'cumulativePnl': 40,
                'netFlow': 0,
              },
            ],
          },
        },
    },
  };
}

class ConnectedHomeApi extends HomeApi {
  int syncs = 0;
  bool failSync = false;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/api/portfolio/connection') {
      reads.add(path);
      return {
        'registered': true,
        'configured': true,
        'status': 'linked',
        'provider': 'ibkr_flex',
        'accounts': const [],
      };
    }
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path.startsWith('/api/investment/portfolio-analysis/sync?')) {
      syncs += 1;
      if (failSync) {
        return {
          'version': 'portfolio-research-v1',
          'asOf': '2026-08-28',
          'status': 'connection_error',
          'groups': const [],
          'connection': {'configured': true, 'status': 'error'},
          'sync': {
            'ok': false,
            'connection': {'configured': true, 'status': 'error'},
          },
        };
      }
      return {
        ...result('2026-08-28'),
        'sync': {
          'ok': true,
          'historyStatus': 'ready',
          'incomeStatus': 'cash_transactions_required',
        },
      };
    }
    throw StateError('Unexpected write: $path');
  }
}

class HomeWorkflowApi extends workflow.DiscoveryFixtureApi {
  final reads = <String>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) {
    reads.add(path);
    return super.getJson(path);
  }
}

Future<void> mount(
  WidgetTester t,
  HomeApi api, {
  Size size = const Size(1500, 1100),
  AppLanguage lang = AppLanguage.en,
  double scale = 1,
  void Function(String, String)? onCompany,
  VoidCallback? onDetails,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: lang,
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: PortfolioResearchPanel(
                  api: api,
                  palette: Palette(false),
                  asOf: '2026-08-28',
                  homeMode: true,
                  onCompany: onCompany ?? (_, _) {},
                  onDetails: onDetails ?? () {},
                  onGuru: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'NAV and both P&L curves switch with correct labels and range rebasing',
    (t) async {
      await mount(
        t,
        HomeApi()
          ..history = true
          ..pnlHistory = true,
      );
      expect(find.byKey(const ValueKey('actual-nav-chart')), findsOneWidget);
      expect(find.text('Latest P&L estimate'), findsOneWidget);
      await fixtures.tap(
        t,
        find.byKey(const ValueKey('history-metric-realized')),
      );
      expect(find.byKey(const ValueKey('realized-pnl-chart')), findsOneWidget);
      expect(find.text('2026-09-09 · USD 50'), findsOneWidget);
      await fixtures.tap(t, find.text('1M'));
      expect(
        find.text('2026-09-09 · USD 30'),
        findsOneWidget,
      ); // 70 - prior 20 - 20 = 30
      await fixtures.tap(
        t,
        find.byKey(const ValueKey('history-metric-cashAdjusted')),
      );
      expect(
        find.byKey(const ValueKey('cashAdjusted-pnl-chart')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Security transfers are not reconciled'),
        findsWidgets,
      );
      await fixtures.tap(t, find.byKey(const ValueKey('history-metric-nav')));
      await fixtures.tap(t, find.text('All'));
      expect(find.byKey(const ValueKey('actual-nav-chart')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  for (final lang in [AppLanguage.en, AppLanguage.zh]) {
    testWidgets('historical P&L controls and notices fit mobile ${lang.name}', (
      t,
    ) async {
      await mount(
        t,
        HomeApi()
          ..history = true
          ..pnlHistory = true,
        size: const Size(390, 844),
        lang: lang,
        scale: 1.2,
      );
      await fixtures.tap(
        t,
        find.byKey(const ValueKey('history-metric-realized')),
      );
      expect(find.byKey(const ValueKey('realized-pnl-chart')), findsOneWidget);
      await fixtures.tap(
        t,
        find.byKey(const ValueKey('history-metric-cashAdjusted')),
      );
      expect(
        find.byKey(const ValueKey('cashAdjusted-pnl-chart')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
    'Home defaults to the owner portfolio without eager Guru searches',
    (t) async {
      final api = HomeWorkflowApi();
      await t.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'home',
              initialTicker: '',
              initialAsOf: '2026-08-28',
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('personal-home')), findsOneWidget);
      expect(find.text('My portfolio'), findsOneWidget);
      expect(find.text('Shared holdings'), findsNothing);
      expect(
        api.reads.any(
          (r) =>
              r.contains('/opportunities') ||
              r.contains('/discovery') ||
              r.contains('/gurus/'),
        ),
        isFalse,
      );
      expect(
        find.byKey(const ValueKey('open-home-research-desk')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'single balance and missing daily data are explicit; open P&L is labelled cumulative',
    (t) async {
      await mount(t, HomeApi());
      expect(find.byKey(const ValueKey('nav-history-needed')), findsOneWidget);
      expect(find.byKey(const ValueKey('actual-nav-chart')), findsNothing);
      expect(
        find.text(
          'Daily P&L unavailable · showing cumulative open-position P&L',
        ),
        findsOneWidget,
      );
      expect(find.text('Synced · 2026-09-09'), findsOneWidget);
      expect(
        find.text('Open equities · unrealized P&L, not today’s move'),
        findsOneWidget,
      );
      expect(find.text('+USD 200'), findsOneWidget);
      await fixtures.tap(t, find.text('Day P&L'));
      expect(find.text('+USD 200'), findsNothing);
      expect(find.text('Day P&L is not in this report.'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'real NAV history supports ranges and date inspection, not return simulation',
    (t) async {
      await mount(t, HomeApi()..history = true);
      expect(find.byKey(const ValueKey('actual-nav-chart')), findsOneWidget);
      await fixtures.tap(t, find.text('1M'));
      expect(find.byKey(const ValueKey('actual-nav-chart')), findsNothing);
      expect(
        find.text(
          'Only one observation in this range. Select a longer period.',
        ),
        findsOneWidget,
      );
      await fixtures.tap(t, find.text('All'));
      final slider = t.widget<Slider>(find.byType(Slider));
      slider.onChanged!(0);
      await t.pump();
      expect(find.text('2026-07-01 · USD 2,500'), findsOneWidget);
    },
  );
  testWidgets(
    'dated daily winners and losers use signed account-currency P&L',
    (t) async {
      await mount(t, HomeApi()..daily = true);
      expect(find.text('Portfolio allocation'), findsOneWidget);
      expect(find.text('Top gainers'), findsOneWidget);
      expect(find.text('Top losers'), findsOneWidget);
      expect(find.text('+USD 100'), findsOneWidget);
      expect(find.text('USD -50'), findsOneWidget);
      expect(find.text('Session contribution · 2026-09-09'), findsOneWidget);
      expect(find.text('Day P&L is not in this report.'), findsNothing);
      await fixtures.tap(t, find.text('EUR'));
      expect(find.text('+EUR 100'), findsOneWidget);
      expect(find.text('+USD 100'), findsNothing);
    },
  );
  testWidgets(
    'own holding opens exact equity; full analysis remains accessible',
    (t) async {
      final selected = <(String, String)>[];
      var details = 0;
      await mount(
        t,
        HomeApi(),
        onCompany: (a, b) => selected.add((a, b)),
        onDetails: () => details++,
      );
      await fixtures.tap(t, find.byKey(const ValueKey('home-position-AAA')));
      expect(selected, [('AAA', 'evidence')]);
      await fixtures.tap(t, find.text('Full analysis'));
      expect(details, 1);
    },
  );
  testWidgets(
    'new portfolio owns IBKR management and sync without a legacy route',
    (t) async {
      final api = ConnectedHomeApi();
      await mount(t, api);

      await fixtures.tap(t, find.byKey(const ValueKey('home-manage-ibkr')));
      expect(find.text('Manage IBKR connection'), findsOneWidget);
      expect(find.text('Open existing terminal'), findsNothing);
      await fixtures.tap(t, find.byTooltip('Close'));

      await fixtures.tap(t, find.byKey(const ValueKey('home-sync-now')));
      expect(api.syncs, 1);
      expect(
        find.textContaining('Holdings and NAV were refreshed'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'configured sync failure stays in the saved connection flow, not onboarding',
    (t) async {
      final api = ConnectedHomeApi()..failSync = true;
      await mount(t, api);

      await fixtures.tap(t, find.byKey(const ValueKey('home-sync-now')));

      expect(api.syncs, 1);
      expect(
        find.text('Your IBKR connection is saved, but it needs attention.'),
        findsOneWidget,
      );
      expect(find.text('Connect IBKR'), findsNothing);
      expect(
        find.byKey(const ValueKey('portfolio-retry-sync')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('portfolio-review-connection')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('summary cards render account and realized P&L icons', (t) async {
    await mount(t, HomeApi()..pnlHistory = true);
    expect(find.byIcon(Icons.account_balance_wallet_rounded), findsOneWidget);
    expect(find.byIcon(Icons.receipt_long_rounded), findsOneWidget);
  });
  testWidgets(
    'empty and failed account never substitute Guru holdings or sample curves',
    (t) async {
      final api = HomeApi()..preview = true;
      await mount(t, api);
      expect(
        find.text('This preview is not your online account.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('actual-nav-chart')), findsNothing);
      api.preview = false;
      api.fail = true;
      await fixtures.tap(t, find.byTooltip('Reload portfolio'));
      expect(find.text('Could not read your portfolio'), findsOneWidget);
      expect(find.text('AAA'), findsNothing);
    },
  );
  for (final lang in AppLanguage.values) {
    testWidgets('personal home narrow layout and history help ${lang.name}', (
      t,
    ) async {
      await mount(
        t,
        HomeApi(),
        size: const Size(390, 844),
        lang: lang,
        scale: 1.2,
      );
      expect(t.takeException(), isNull);
      await fixtures.tap(
        t,
        find.text(
          lang == AppLanguage.en ? 'Set up account history' : '设置账户历史数据',
        ),
      );
      expect(
        find.text(
          lang == AppLanguage.en ? 'Complete your account history' : '补齐账户历史数据',
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  }
}
