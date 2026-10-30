import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_portfolio_test.dart' as base;

class RiskApi extends base.PortfolioApi {
  @override
  Map<String, dynamic> result(String date) => {
    ...super.result(date),
    'source': 'local_owner_broker_snapshot',
    'benchmarkValuation': {
      'status': 'ready',
      'gap': -.1,
      'coverage': .95,
      'coveredCount': 480,
      'totalCount': 503,
      'priceDate': '2026-08-27',
      'weightDate': '2026-08-27',
      'source': 'https://www.ssga.com',
    },
  };
  @override
  Map<String, dynamic> group(String currency) => {
    ...super.group(currency),
    'reportedNav': 3000,
    'leverage': {'grossToNav': 1.2, 'borrowingToNav': .1, 'shortOptions': 2},
    'actualPerformance': {'navPointCount': 1},
    'benchmarkComparison': {
      'gap': .2,
      'coverage': .7,
      'coveredCount': 1,
      'totalCount': 2,
      'difference': .3,
      'covered': [
        {'ticker': 'AAA', 'modelDate': '2026-07-01', 'gap': .2},
      ],
      'excluded': [],
    },
    'risk': {
      'status': 'ready',
      'start': '2026-01-01',
      'end': '2026-03-02',
      'coverage': .8,
      'metrics': {
        'observations': 60,
        'beta': 1.5,
        'sharpe': 1.2,
        'volatility': .2,
        'maxDrawdown': -.1,
      },
      'benchmarkMetrics': {
        'beta': 1,
        'sharpe': 1,
        'volatility': .1,
        'maxDrawdown': -.05,
      },
      'included': [
        {'ticker': 'AAA', 'weight': 1, 'beta': 1.5},
      ],
      'excluded': [
        {'ticker': 'OPT', 'reason': 'outside_usd_long_sleeve'},
      ],
      'curve': List.generate(
        61,
        (i) => {
          'date': DateTime(
            2026,
            1,
            1,
          ).add(Duration(days: i)).toIso8601String().substring(0, 10),
          'portfolio': 1 + i * .002,
          'benchmark': 1 + i * .001,
        },
      ),
    },
  };
}

class ConnectApi extends ApiClient {
  ConnectApi() : super(() => 'fixture');
  final writes = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    writes.add({'path': path, ...body});
    return {
      'portfolio': {
        'connection': {'status': 'linked'},
      },
    };
  }
}

class ReadOnlyApi extends ConnectApi {
  @override
  Future<Map<String, dynamic>> getJson(String path) async => {
    'connected': true, 'status': 'connected', 'snapshot': {
      'retrievedAt': '2026-10-30T07:00:00Z', 'accounts': [{
        'id': '1234', 'name': 'Synthetic',
        'balances': [{'currency': 'CAD', 'totalEquity': 100, 'cash': 10}],
        'positions': [{'ticker': 'EXAMPLE', 'quantity': 2, 'price': 45, 'value': 90}],
      }],
    },
  };
}

void main() {
  for (final lang in [AppLanguage.en, AppLanguage.zh]) {
    for (final provider in ['questrade', 'futu']) {
      testWidgets('read-only $provider dialog fits mobile ${lang.name}', (t) async {
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final api = ReadOnlyApi();
        await t.pumpWidget(MaterialApp(home: LanguageScope(language: lang,
          child: Scaffold(body: PortfolioReadOnlyBroker(api: api, palette: Palette(false), provider: provider)))));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(api.writes, isEmpty);
        expect(find.textContaining('CAD'), findsOneWidget);
        if (provider == 'questrade') {
          expect(t.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
          await t.enterText(find.byType(TextField), 'synthetic-questrade-token');
          await t.ensureVisible(find.text(lang == AppLanguage.en ? 'Connect & sync' : '连接并同步'));
          await t.tap(find.text(lang == AppLanguage.en ? 'Connect & sync' : '连接并同步'));
          await t.pumpAndSettle();
          expect(api.writes.single['path'], '/api/portfolio/broker/questrade/connect');
          expect(api.writes.single.containsKey('ibkrFlexToken'), isFalse);
          expect(t.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
        }
      });
    }
  }
  testWidgets(
    'risk route separates real NAV from simulation and exposes benchmark inputs',
    (t) async {
      final api = RiskApi();
      await base.mount(t, api);
      expect(
        find.text('Your IBKR report · local read-only copy'),
        findsOneWidget,
      );
      expect(find.text('Open live account'), findsOneWidget);
      expect(find.text('Manage accounts'), findsNothing);
      await base.tap(t, find.text('Risk & SPY'));
      expect(
        find.text('Are your holdings cheaper than the market?'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Actual account: 1 NAV observations'),
        findsOneWidget,
      );
      expect(find.text('Sharpe'), findsOneWidget);
      await base.tap(t, find.text('Drawdown'));
      expect(t.takeException(), isNull);
      await base.tap(t, find.text('5%'));
      expect(api.reads.last, contains('riskFreeRate=0.05'));
    },
  );
  for (final lang in [AppLanguage.en, AppLanguage.zh]) {
    testWidgets('new risk panels fit mobile ${lang.name} with large text', (
      t,
    ) async {
      await base.mount(
        t,
        RiskApi(),
        size: const Size(390, 844),
        lang: lang,
        scale: 1.5,
      );
      expect(t.takeException(), isNull);
      await base.tap(
        t,
        find.text(lang == AppLanguage.en ? 'Risk & SPY' : '风险与 SPY'),
      );
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('onboarding explains token and query without invented holdings', (
    t,
  ) async {
    await base.mount(
      t,
      base.PortfolioApi()..preview = true,
      size: const Size(390, 844),
    );
    expect(find.text('1  Create a read-only IBKR report'), findsOneWidget);
    expect(find.text('Sign in to connect IBKR'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'IBKR form validates, masks token and writes only after explicit submit',
    (t) async {
      final api = ConnectApi();
      await t.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        PortfolioIbkrSetup(api: api, palette: Palette(false)),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(
        t.widget<TextField>(find.byType(TextField).first).obscureText,
        isTrue,
      );
      await t.tap(find.text('Connect & sync'));
      await t.pumpAndSettle();
      expect(api.writes, isEmpty);
      await t.enterText(find.byType(TextField).at(0), 'synthetic-secret');
      await t.enterText(find.byType(TextField).at(1), '123456');
      await t.tap(find.text('Connect & sync'));
      await t.pumpAndSettle();
      expect(api.writes.single['path'], '/api/portfolio/connection');
      expect(api.writes.single['ibkrFlexQueryId'], '123456');
      expect(find.byType(PortfolioIbkrSetup), findsNothing);
    },
  );
  testWidgets('switching brokers never submits IBKR credentials', (t) async {
    final api = ConnectApi();
    await t.pumpWidget(MaterialApp(home: LanguageScope(
      language: AppLanguage.en,
      child: Scaffold(body: PortfolioIbkrSetup(api: api, palette: Palette(false))),
    )));
    await t.enterText(find.byType(TextField).first, 'synthetic-secret');
    await t.tap(find.text('Interactive Brokers'));
    await t.pumpAndSettle();
    await t.tap(find.text('Questrade').last);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    expect(api.writes, isEmpty);
    await t.tap(find.text('Questrade'));
    await t.pumpAndSettle();
    await t.tap(find.text('Futu / moomoo').last);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(api.writes, isEmpty);
    await t.tap(find.text('Futu / moomoo'));
    await t.pumpAndSettle();
    await t.tap(find.text('Interactive Brokers').last);
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byType(TextField).first).controller!.text, isEmpty);
  });
}
