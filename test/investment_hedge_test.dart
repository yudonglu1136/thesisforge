import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class HedgeApiFixture extends ApiClient {
  HedgeApiFixture() : super(() => 'fixture');
  final posts = <String>[];
  bool fail = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async => {
    'status': 'ready',
    'date': '2026-09-09',
    'latest': '2026-09-09',
    'spot': 100,
    'dates': ['2026-09-09'],
    'saved': [],
    'expiries': [
      {'expiry': '2026-10-16', 'puts': 2, 'calls': 1},
    ],
    'chain': [
      for (final r in [('put', 95, 3), ('put', 85, 1), ('call', 105, 2)])
        {
          'ticker': '${r.$1}-${r.$2}',
          'expiry': '2026-10-16',
          'type': r.$1,
          'strike': r.$2,
          'close': r.$3,
        },
    ],
  };
  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    posts.add(path);
    if (fail) throw StateError('fixture failure');
    return {
      'rules': body,
      'coveredShares': 100,
      'uncoveredShares': 0,
      'results': [
        for (final id in ['unhedged', 'protective_put', 'collar', 'put_spread'])
          {
            'strategy': id,
            'netDebit': 100,
            'maxLoss': 600,
            'maxGain': id == 'collar' ? 400 : null,
            'protectionEnds': 85,
            'curve': [
              {'price': 0, 'pnl': -600},
              {'price': 100, 'pnl': -100},
              {'price': 150, 'pnl': 400},
            ],
            'scenarios': [
              for (final move in [
                -.5,
                -.3,
                -.2,
                -.1,
                -.05,
                0.0,
                .05,
                .1,
                .2,
                .3,
                .5,
              ])
                {'move': move, 'price': 100 * (1 + move), 'pnl': -600},
            ],
            'legs': [],
          },
      ],
    };
  }
}

Future<void> mount(
  WidgetTester t,
  HedgeApiFixture api,
  Size size,
  AppLanguage language,
) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    LanguageScope(
      language: language,
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: HedgeLabPanel(api: api, palette: Palette(false)),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('explicit experiment command, dirty result and disabled saving', (
    t,
  ) async {
    final api = HedgeApiFixture();
    await mount(t, api, const Size(1380, 1000), AppLanguage.en);
    expect(api.posts, isEmpty);
    expect(find.text('Collar'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('hedge-run')));
    await t.tap(find.byKey(const Key('hedge-run')));
    await t.pumpAndSettle();
    expect(api.posts, ['/api/investment/hedge/calculate']);
    expect(find.text('AT EXPIRY · NOT A BACKTEST'), findsOneWidget);
    await t.enterText(find.byKey(const Key('hedge-shares')), '250');
    await t.pump();
    expect(
      find.text('Inputs changed. Compare again to update these results.'),
      findsOneWidget,
    );
    final save = t.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Save private experiment'),
    );
    expect(save.onPressed, isNull);
    expect(t.takeException(), isNull);
  });
  testWidgets('mobile Chinese controls and results do not overflow', (t) async {
    final api = HedgeApiFixture();
    await mount(t, api, const Size(390, 844), AppLanguage.zh);
    expect(find.text('保留持仓，调整风险。'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('hedge-run')));
    await t.tap(find.byKey(const Key('hedge-run')));
    await t.pumpAndSettle();
    expect(find.text('到期情景 · 非历史回测'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('too few covered shares disables calculate with an explanation', (
    t,
  ) async {
    final api = HedgeApiFixture();
    await mount(t, api, const Size(1280, 720), AppLanguage.en);
    await t.enterText(find.byKey(const Key('hedge-shares')), '50');
    await t.pump();
    expect(
      t.widget<FilledButton>(find.byKey(const Key('hedge-run'))).onPressed,
      isNull,
    );
    expect(
      find.text('Choose available legs and cover at least 100 shares.'),
      findsOneWidget,
    );
    expect(api.posts, isEmpty);
  });
}
