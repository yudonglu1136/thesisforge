import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class _RuleApi extends ApiClient {
  _RuleApi() : super(() => 'fixture');
  final paths = <String>[];
  final pending = <String, Completer<Map<String, dynamic>>>{};
  bool fail = false;
  Map<String, dynamic> payload() =>
      jsonDecode(
            File(
              'server/config/investor-style-dashboard.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    if (fail) throw Exception('fixture failure');
    final day = Uri.parse(path).queryParameters['asOf']!;
    if (pending.containsKey(day)) return pending[day]!.future;
    return payload();
  }
}

Future<void> _mount(
  WidgetTester tester,
  _RuleApi api, {
  Size size = const Size(1280, 900),
  AppLanguage language = AppLanguage.en,
  String asOf = '2026-09-24',
  ValueChanged<String>? open,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: language,
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: InvestorStylesDashboard(
                api: api,
                palette: Palette(false),
                asOf: asOf,
                onCompany: open ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  tearDown(() {});
  testWidgets('shared painter actually draws both rule portfolio series', (
    tester,
  ) async {
    await tester.runAsync(() async {
      const green = Color(0xff12ed34), purple = Color(0xffed12cd);
      final recorder = ui.PictureRecorder();
      StrategyCurvePainter(
        series: {
          'quality_rank': [100, 125, 160],
          'ackman': [100, 95, 120],
        },
        colors: {'quality_rank': green, 'ackman': purple},
        palette: Palette(false),
        drawdown: false,
        cursor: 2,
      ).paint(Canvas(recorder), const Size(600, 280));
      final picture = recorder.endRecording();
      final image = await picture.toImage(600, 280);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      for (final color in [green, purple]) {
        final rgb = color.toARGB32();
        var matches = 0;
        for (var i = 0; i < bytes.lengthInBytes; i += 4) {
          if (bytes.getUint8(i) == (rgb >> 16 & 255) &&
              bytes.getUint8(i + 1) == (rgb >> 8 & 255) &&
                bytes.getUint8(i + 2) == (rgb & 255)) {
              matches++;
            }
        }
        expect(
          matches,
          greaterThan(50),
          reason: 'a visible line must be painted for each enabled portfolio',
        );
      }
      image.dispose();
      picture.dispose();
    });
  });
  testWidgets(
    'real snapshot shows metrics, independent toggles, quarterly weights and score evidence',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _RuleApi();
      String opened = '';
      await _mount(tester, api, open: (v) => opened = v);
      await tester.pumpAndSettle();
      expect(
        api.paths.single,
        '/api/investment/investor-styles?asOf=2026-09-24',
      );
      expect(find.text('Rule portfolio dashboard'), findsOneWidget);
      expect(find.text('Sharpe · 0% Rf'), findsOneWidget);
      expect(find.text('Annualized vol'), findsOneWidget);
      expect(find.text('Max drawdown'), findsOneWidget);
      expect(find.text('LATEST · RETURN NOT MATURE'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('curve-toggle-ackman')),
      );
      await tester.tap(find.byKey(const ValueKey('curve-toggle-ackman')));
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const ValueKey('curve-toggle-ackman')),
            )
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const ValueKey('curve-toggle-quality_rank')),
            )
            .selected,
        isTrue,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('holding-FICO')));
      await tester.tap(find.byKey(const ValueKey('holding-FICO')));
      await tester.pumpAndSettle();
      expect(find.text('FICO · #1'), findsOneWidget);
      expect(find.text('Quarterly revenue YoY'), findsOneWidget);
      expect(find.textContaining('contribution'), findsWidgets);
      await tester.tap(find.text('Research company'));
      await tester.pumpAndSettle();
      expect(opened, 'FICO');
      await tester.ensureVisible(
        find.byKey(const ValueKey('holdings-quarter')),
      );
      await tester.tap(find.byKey(const ValueKey('holdings-quarter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026-03-31').last);
      await tester.pumpAndSettle();
      expect(find.text('COMPLETED RETURN WINDOW'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('style-ackman')));
      await tester.tap(find.byKey(const ValueKey('style-ackman')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Buy the top 20 at 5% each'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '390px Chinese layout, evidence dialog and all-off chart stay usable',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _mount(
        tester,
        _RuleApi(),
        size: const Size(390, 844),
        language: AppLanguage.zh,
      );
      await tester.pumpAndSettle();
      expect(find.text('规则组合看板'), findsOneWidget);
      for (final id in ['quality_rank', 'ackman', 'spy']) {
        await tester.ensureVisible(find.byKey(ValueKey('curve-toggle-$id')));
        await tester.tap(find.byKey(ValueKey('curve-toggle-$id')));
        await tester.pump();
      }
      expect(find.text('打开一条曲线开始比较。'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('holding-FICO')));
      await tester.tap(find.byKey(const ValueKey('holding-FICO')));
      await tester.pumpAndSettle();
      expect(find.text('季度收入同比'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('策略如何运作'));
      await tester.pumpAndSettle();
      expect(find.textContaining('严格历史版本 PIT'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('new cutoff wins even when older request completes later', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _RuleApi();
    api.pending['2024-05-01'] = Completer();
    api.pending['2026-09-24'] = Completer();
    await _mount(tester, api, asOf: '2024-05-01');
    await _mount(tester, api, asOf: '2026-09-24');
    api.pending['2026-09-24']!.complete(api.payload());
    await tester.pumpAndSettle();
    final stale = api.payload();
    stale['backtest'] = {'curve': []};
    stale['status'] = 'unavailable_before_first_observation';
    api.pending['2024-05-01']!.complete(stale);
    await tester.pumpAndSettle();
    expect(find.text('Rule portfolio dashboard'), findsOneWidget);
    expect(find.textContaining('No observed backtest history'), findsNothing);
  });
  testWidgets('load failure is explicit and retry restores real snapshot', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _RuleApi()..fail = true;
    await _mount(tester, api);
    await tester.pumpAndSettle();
    expect(find.text('Rule portfolios could not be loaded.'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Rule portfolio dashboard'), findsOneWidget);
  });
}
