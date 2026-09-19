import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class ResearchApi extends ApiClient {
  ResearchApi() : super(() => 'test');
  final calls = <String>[];
  final requests = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) {
    calls.add(path);
    final request = Completer<Map<String, dynamic>>();
    requests.add(request);
    return request.future;
  }
}

// Synthetic test inputs only; never bundled into the production app.
Map<String, dynamic> fixture(String ticker) => {
  'ticker': {
    'ticker': ticker,
    'name': 'Test issuer',
    'currency': 'USD',
    'latest': {
      'latestPrice': 100,
      'baseFairValue': 120,
      'upsideToBase': .2,
      'latestPriceDate': '2026-08-27',
    },
    'history': [
      {'asOfDate': '2026-04-20', 'fairValue': 110, 'currentPrice': 100},
      {'asOfDate': '2026-07-20', 'fairValue': 120, 'currentPrice': 100},
    ],
    'priceHistory': [
      {'date': '2026-04-20', 'close': 100},
      {'date': '2026-07-20', 'close': 100},
    ],
  },
};

void main() {
  testWidgets('logo backdrop can change without changing issuer identity', (
    tester,
  ) async {
    for (final backdrop in [null, const Color(0xff1b2932)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: StockLogo(
              ticker: 'AMZN',
              palette: Palette(false),
              backgroundColor: backdrop,
            ),
          ),
        ),
      );
      final box = tester.widget<Container>(
        find.descendant(
          of: find.byType(StockLogo),
          matching: find.byType(Container),
        ),
      );
      expect(
        (box.decoration! as BoxDecoration).color,
        backdrop ?? const Color(0xFFF4F6F8),
      );
      expect(find.byKey(const ValueKey('stock-logo-AMZN')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  for (final language in AppLanguage.values) {
    for (final size in [const Size(1280, 720), const Size(390, 844)]) {
      for (final missing in [true, false]) {
        testWidgets(
          'coverage and service errors differ: $language $size missing=$missing',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final api = ResearchApi();
            await tester.pumpWidget(
              MaterialApp(
                home: LanguageScope(
                  language: language,
                  child: Scaffold(
                    body: StockValuationPanel(
                      ticker: 'CRDO',
                      api: api,
                      palette: Palette(false),
                      sourceLabel: 'Gavin Baker',
                      onClose: () {},
                    ),
                  ),
                ),
              ),
            );
            api.requests.single.completeError(
              ApiRequestException(
                statusCode: missing ? 404 : 503,
                code: missing
                    ? 'valuation_not_covered'
                    : 'valuation_request_failed',
                message: 'server prose must not be rendered',
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(ValuationTrendChart), findsNothing);
            expect(find.textContaining('server prose'), findsNothing);
            expect(
              find.textContaining(
                language == AppLanguage.en
                    ? (missing
                          ? 'No valuation model has been published for CRDO'
                          : 'the request failed')
                    : (missing ? 'CRDO 尚无已发布' : '估值暂时加载失败'),
              ),
              findsOneWidget,
            );
            final retry = find.text(
              language == AppLanguage.en ? 'Retry' : '重试',
            );
            expect(retry, missing ? findsNothing : findsOneWidget);
            expect(find.text('Gavin Baker'), findsOneWidget);
            expect(tester.takeException(), isNull);
            if (!missing) {
              await tester.tap(retry);
              await tester.pump();
              api.requests.last.complete(fixture('CRDO'));
              await tester.pumpAndSettle();
              expect(find.byType(ValuationTrendChart), findsOneWidget);
            }
          },
        );
      }
    }
  }
  testWidgets('authorization loss clears previously displayed valuation', (
    tester,
  ) async {
    final api = ResearchApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StockValuationPanel(
            ticker: 'CRDO',
            api: api,
            palette: Palette(false),
            onClose: () {},
          ),
        ),
      ),
    );
    api.requests.single.complete(fixture('CRDO'));
    await tester.pumpAndSettle();
    expect(find.byType(ValuationTrendChart), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    api.requests.last.completeError(
      const ApiRequestException(
        statusCode: 401,
        code: 'unauthorized',
        message: 'not displayed',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ValuationTrendChart), findsNothing);
    expect(find.textContaining('Sign in again'), findsOneWidget);
  });
  testWidgets(
    'quarterly lens opens inline valuation and returns without closing the ranking',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ResearchApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuarterlyMarketLensDialog(
              gurus: const [
                {
                  'id': 'test-guru',
                  'name': 'Test Guru',
                  'type': 'manager13f',
                  'summary': {
                    'reportDate': '2026-06-30',
                    'filingDate': '2026-08-14',
                    'commonLongValue': 100,
                  },
                  'holdings': [
                    {'ticker': 'AMZN', 'issuer': 'Amazon', 'value': 100},
                  ],
                },
              ],
              palette: Palette(false),
              initialView: 0,
              initialTicker: 'AMZN',
              researchApi: api,
              onOpenGuruTrade: (_, _) {},
              onOpenValuation: (_) => fail('must not navigate away'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('quarterly-market-lens-valuation')),
      );
      await tester.pump();
      api.requests.first.complete(fixture('AMZN'));
      await tester.pumpAndSettle();
      expect(find.byType(StockValuationPanel), findsOneWidget);
      expect(find.byType(QuarterlyMarketLensDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('stock-research-close')));
      await tester.pumpAndSettle();
      expect(find.byType(StockValuationPanel), findsNothing);
      expect(
        find.byKey(const ValueKey('quarterly-market-lens-valuation')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'private holdings keep identity but cannot open a public valuation',
    (tester) async {
      final api = ResearchApi();
      await tester.pumpWidget(
        MaterialApp(
          home: StockResearchScope(
            api: api,
            palette: Palette(false),
            sourceLabel: 'Test',
            child: Scaffold(
              body: HoldingRow(
                holding: const {
                  'ticker': 'SPCX',
                  'value': 10,
                  'publicReplicable': false,
                },
                total: 10,
                palette: Palette(false),
              ),
            ),
          ),
        ),
      );
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('stock-research-SPCX')),
      );
      expect(button.onPressed, isNull);
      expect(api.calls, isEmpty);
      expect(find.byType(StockLogo), findsOneWidget);
    },
  );
  test(
    'logo symbols preserve venue and class; invalid/private names stay unbound',
    () {
      expect(stockLogoTicker(' lseg.l '), 'LSEG.L');
      expect(stockLogoTicker('BRK.A'), 'BRK.A');
      expect(stockLogoTicker('AMZN260918C00250000'), 'AMZN');
      expect(stockLogoTicker('../AMZN'), '');
      expect(stockLogoTicker('SPACE EXPLORATION TECHNOLOGIES'), '');
    },
  );
  test(
    'one request per client/ticker; full research remains lazy; failed requests retry',
    () async {
      final api = ResearchApi(), other = ResearchApi();
      final cache = StockResearchCache.of(api);
      final a = cache.load('AMZN'), b = cache.load('AMZN');
      expect(api.calls, ['/api/valuation/AMZN?pricePoints=300&detail=summary']);
      api.requests.first.complete(fixture('AMZN'));
      await Future.wait([a, b]);
      await cache.load('AMZN');
      expect(api.calls.length, 1);
      final full = cache.load('AMZN', full: true);
      expect(api.calls.last, contains('pricePoints=900&detail=full'));
      api.requests.last.complete(fixture('AMZN'));
      await full;
      final independent = StockResearchCache.of(other).load('AMZN');
      expect(other.calls.length, 1);
      other.requests.first.complete(fixture('AMZN'));
      await independent;
      final failed = cache.load('MISSING');
      api.requests.last.completeError(StateError('missing'));
      await expectLater(failed, throwsStateError);
      final retry = cache.load('MISSING');
      api.requests.last.complete(fixture('MISSING'));
      await retry;
      expect(api.calls.length, 4);
    },
  );
  for (final language in AppLanguage.values) {
    for (final size in [const Size(1280, 720), const Size(390, 844)]) {
      testWidgets(
        'drawer closes without losing source state: $language $size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = ResearchApi();
          await tester.pumpWidget(
            MaterialApp(
              home: LanguageScope(
                language: language,
                child: StockResearchScope(
                  api: api,
                  palette: Palette(false),
                  sourceLabel: 'Test Guru · 2026 Q2',
                  child: Scaffold(
                    body: Column(
                      children: [
                        const TextField(key: ValueKey('source-filter')),
                        HoldingRow(
                          holding: const {
                            'ticker': 'AMZN',
                            'issuer': 'Amazon',
                            'value': 100,
                          },
                          total: 100,
                          palette: Palette(false),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.enterText(
            find.byKey(const ValueKey('source-filter')),
            'keep this quarter',
          );
          await tester.tap(find.byKey(const ValueKey('stock-research-AMZN')));
          await tester.pump(const Duration(milliseconds: 250));
          expect(api.calls.length, 1);
          api.requests.first.complete(fixture('AMZN'));
          await tester.pumpAndSettle();
          expect(find.byType(ValuationTrendChart), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('stock-research-close')));
          await tester.pumpAndSettle();
          expect(find.byType(StockValuationPanel), findsNothing);
          expect(find.text('keep this quarter'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'rapid ticker switching and unrelated response cannot show stale model',
    (tester) async {
      final api = ResearchApi();
      Widget panel(String ticker) => MaterialApp(
        home: Scaffold(
          body: StockValuationPanel(
            ticker: ticker,
            api: api,
            palette: Palette(false),
            onClose: () {},
          ),
        ),
      );
      await tester.pumpWidget(panel('AMZN'));
      await tester.pumpWidget(panel('NVDA'));
      api.requests[0].complete(fixture('AMZN'));
      await tester.pump();
      expect(find.byType(ValuationTrendChart), findsNothing);
      api.requests[1].complete(fixture('MSFT'));
      await tester.pump();
      expect(find.byType(ValuationTrendChart), findsNothing);
      expect(find.textContaining('Valuation unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
