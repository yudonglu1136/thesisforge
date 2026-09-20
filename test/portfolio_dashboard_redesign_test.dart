import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

Map<String, dynamic> _holding({
  required String ticker,
  required double value,
  required double weight,
  required double price,
  required double fairValue,
}) => {
  'ticker': ticker,
  'name': '$ticker synthetic fixture',
  'quantity': value / price,
  'price': price,
  'value': value,
  'weight': weight,
  'currency': 'USD',
  'unrealizedPnl': value * .1,
  'valuation': {
    'covered': true,
    'currency': 'USD',
    'latestPrice': price,
    'latestPriceDate': '2026-09-18',
    'fairValue': fairValue,
    'gap': fairValue / price - 1,
    'model': {
      'route': 'operating_company',
      'formula': '60% normalized earnings + 40% FCFE DCF',
      'asOfDate': '2026-07-31',
    },
  },
};

Map<String, dynamic> _dashboardData() {
  final holdings = [
    _holding(
      ticker: 'AAA',
      value: 60000,
      weight: .6,
      price: 100,
      fairValue: 125,
    ),
    _holding(ticker: 'BBB', value: 40000, weight: .4, price: 80, fairValue: 70),
  ];
  return {
    'source': {'mode': 'saved_authenticated_broker_report'},
    'summary': {
      'totalValue': 100000,
      'accounts': 1,
      'holdings': 2,
      'cash': 0,
      'dayPnl': 500,
      'dayPnlPct': .005,
      'unrealizedPnl': 10000,
      'unrealizedPnlPct': .1,
      'topWeight': .6,
      'currency': 'USD',
    },
    'connection': {
      'configured': true,
      'registered': true,
      'status': 'linked',
      'provider': 'IBKR',
      'institution': 'Interactive Brokers',
      'accounts': <Map<String, dynamic>>[],
    },
    'accounts': [
      {'name': 'Fixture account', 'value': 100000, 'cash': 0},
    ],
    'holdings': holdings,
    'sectors': [
      {'name': 'Technology', 'weight': 1.0},
    ],
    'performance': [
      {'date': '2026-09-17', 'value': 99000},
      {'date': '2026-09-18', 'value': 100000},
    ],
    'performanceStatus': {'real': true},
    'dividends': <Map<String, dynamic>>[],
    'dividendStatus': <String, dynamic>{},
    'analytics': <String, dynamic>{},
  };
}

void main() {
  testWidgets('Portfolio opens with NAV and allocation before model table', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1511, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: Scaffold(
            body: SingleChildScrollView(
              child: PortfolioDashboard(
                data: _dashboardData(),
                api: ApiClient(() => 'fixture'),
                palette: Palette(false),
                onRefresh: () async {},
                readOnly: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Portfolio NAV'), findsOneWidget);
    expect(find.text('Holding Mix'), findsOneWidget);
    expect(find.text('Holdings & Model Structure'), findsOneWidget);
    expect(find.text('Model architecture'), findsOneWidget);
    expect(find.text('Operating-company blend'), findsNWidgets(2));
    expect(find.text('Current → model'), findsOneWidget);
    expect(find.textContaining('not a target allocation'), findsOneWidget);

    final navY = tester.getTopLeft(find.text('Portfolio NAV')).dy;
    final tableY = tester
        .getTopLeft(find.text('Holdings & Model Structure'))
        .dy;
    final connectionY = tester
        .getTopLeft(find.text('Read-Only Portfolio Snapshot'))
        .dy;
    expect(navY, lessThan(tableY));
    expect(tableY, lessThan(connectionY));
    expect(tester.takeException(), isNull);
  });

  testWidgets('model table collapses cleanly on mobile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: Scaffold(
            body: SingleChildScrollView(
              child: PortfolioHoldingsTable(
                holdings: asList(_dashboardData()['holdings']),
                palette: Palette(false),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Holdings & Model Structure'), findsOneWidget);
    expect(find.text('AAA'), findsOneWidget);
    expect(find.text('BBB'), findsOneWidget);
    expect(find.textContaining('not a target allocation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
