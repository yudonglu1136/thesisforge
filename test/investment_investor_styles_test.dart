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
  Map<String, dynamic> payload() => {
    ...jsonDecode(
          File(
            'server/config/investor-style-dashboard.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>,
    'snapshotId': 'test-reviewed-snapshot',
  };
  final analysisPending = <String, Completer<Map<String, dynamic>>>{};
  bool failAnalysis = false;
  Map<String, dynamic> analysis(String path) {
    final q = Uri.parse(path).queryParameters;
    final stock = <String, dynamic>{
      'ticker': 'ANET',
      'netContribution': .06,
      'grossContribution': .061,
      'costContribution': .001,
      'openAtStart': true,
      'openAtEnd': true,
      'openingMark': {'date': q['start'], 'price': 20.0},
      'closingMark': {'date': q['end'], 'price': 40.0},
      'purchases': [
        {'date': '2023-01-03', 'price': 15.0, 'beforeRange': true},
      ],
      'sales': [],
      'corporateActions': [],
    };
    return {
      'version': 'rule-range-attribution-v1',
      'snapshotId': q['snapshotId'],
      'start': q['start'],
      'end': q['end'],
      'styles': [
        for (final id in ['quality_rank', 'ackman'])
          {
            'id': id,
            'tradeStats': {
              'wins': 3,
              'losses': 1,
              'flat': 0,
              'open': 1,
              'winRate': .75,
              'payoffRatio': 2.0,
            },
            'holdings': [stock],
            'best': stock,
            'worst': null,
            'reconciliation': {'difference': 0.0},
            'turnover': {
              'version': 'rule-range-turnover-v1',
              'oneWay': q['start'] == '2023-01-03' ? 1.25 : .4,
              'annualizedOneWay': .8,
              'executions': 4,
            },
            'distribution': [
              for (var i = 0; i < 9; i++)
                {
                  'count': i == 6
                      ? 2
                      : i == 2 || i == 7
                      ? 1
                      : 0,
                },
            ],
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    if (fail) throw Exception('fixture failure');
    if (path.contains('/analysis?')) {
      if (failAnalysis) throw Exception('attribution unavailable');
      final start = Uri.parse(path).queryParameters['start'];
      if (analysisPending.containsKey(start)) {
        return analysisPending[start]!.future;
      }
      return analysis(path);
    }
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
  for (final size in [const Size(1280, 900), const Size(390, 844)]) {
    for (final lang in AppLanguage.values) {
      testWidgets('horizontal P&L bands and range turnover: $size $lang', (
        tester,
      ) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = _RuleApi();
        await _mount(tester, api, size: size, language: lang);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final left = find.byKey(
          const ValueKey('distribution-chart-quality_rank'),
        );
        final right = find.byKey(const ValueKey('distribution-chart-ackman'));
        if (size.width > 840) {
          expect(tester.getTopLeft(left).dy, tester.getTopLeft(right).dy);
          expect(
            tester.getTopLeft(right).dx,
            greaterThan(tester.getTopLeft(left).dx),
          );
        } else {
          expect(
            tester.getTopLeft(right).dy,
            greaterThan(tester.getBottomLeft(left).dy),
          );
        }
        for (final id in ['quality_rank', 'ackman']) {
          final first = find.byKey(ValueKey('distribution-bar-$id-0'));
          final last = find.byKey(ValueKey('distribution-bar-$id-8'));
          expect(
            tester.getTopLeft(last).dx,
            greaterThan(tester.getTopLeft(first).dx),
          );
          expect(tester.getBottomLeft(first).dy, tester.getBottomLeft(last).dy);
          expect(
            tester.widget<Text>(find.byKey(ValueKey('range-$id-8'))).data,
            '125.00%',
          );
          expect(
            tester.widget<Text>(find.byKey(ValueKey('range-$id-9'))).data,
            '80.00%',
          );
        }
        final tap = find.byKey(
          const ValueKey('distribution-bin-quality_rank-7'),
        );
        await tester.ensureVisible(tap);
        await tester.tap(tap);
        await tester.pumpAndSettle();
        expect(find.textContaining('+5 ≤ x < +10'), findsWidgets);
        expect(find.textContaining('25.00%'), findsWidgets);
        tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(
          const RangeValues(.5, 1),
        );
        await tester.pumpAndSettle();
        for (final id in ['quality_rank', 'ackman']) {
          expect(
            tester.widget<Text>(find.byKey(ValueKey('range-$id-8'))).data,
            '40.00%',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
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
        api.paths.where((p) => !p.contains('/analysis?')).single,
        '/api/investment/investor-styles?asOf=2026-09-24',
      );
      expect(find.text('Rule portfolio dashboard'), findsOneWidget);
      expect(find.text('Sharpe · 0% Rf'), findsOneWidget);
      expect(find.text('Annualized vol'), findsOneWidget);
      expect(find.text('Max drawdown'), findsOneWidget);
      expect(find.text('LATEST · RETURN NOT MATURE'), findsOneWidget);
      expect(find.byKey(const ValueKey('rule-range-metrics')), findsOneWidget);
      expect(find.text('Stock P&L distribution'), findsOneWidget);
      expect(find.text('75.00%'), findsNWidgets(2));
      expect(api.paths.where((p) => p.contains('/analysis?')).length, 1);
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
  testWidgets(
    'range updates both metrics, drops stale attribution and keeps marks distinct from sells',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _RuleApi();
      await _mount(tester, api);
      await tester.pumpAndSettle();
      final curve = (api.payload()['backtest'] as Map)['curve'] as List;
      final first = (0.5 * (curve.length - 1)).round();
      final start = curve[first]['date'] as String;
      api.analysisPending[start] = Completer();
      tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(
        const RangeValues(.5, 1),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // The section must not disappear while an updated interval is loading.
      expect(find.text('Stock P&L distribution'), findsOneWidget);
      expect(find.textContaining('Reconciling stock P&L'), findsOneWidget);
      final rangePath = api.paths.last;
      expect(Uri.parse(rangePath).queryParameters['start'], start);
      final expected = strategyRangeMetrics([
        for (final r in curve.skip(first))
          {'date': r['date'], 'value': r['ackman']},
      ]);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('range-ackman-0'))).data,
        '${(expected['totalReturn']! * 100).toStringAsFixed(2)}%',
      );
      // A later range must win even if the half-range response arrives last.
      tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(
        const RangeValues(.75, 1),
      );
      await tester.pumpAndSettle();
      final latestPath = api.paths.last;
      api.analysisPending[start]!.complete(api.analysis(rangePath));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          '${Uri.parse(latestPath).queryParameters['start']} →',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('range-quality_rank-best')),
      );
      await tester.tap(find.byKey(const ValueKey('range-quality_rank-best')));
      await tester.pumpAndSettle();
      expect(find.text('ANET · Range P&L'), findsOneWidget);
      expect(
        find.textContaining('2023-01-03 · ANET · \$15.0000'),
        findsOneWidget,
      );
      expect(find.text('Sells · within range'), findsOneWidget);
      expect(find.textContaining('Open at range end'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('date presets update the shared interval for both portfolios', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _RuleApi();
    await _mount(tester, api);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('rule-range-1y')));
    await tester.tap(find.byKey(const ValueKey('rule-range-1y')));
    await tester.pumpAndSettle();
    final query = Uri.parse(api.paths.last).queryParameters;
    final curve = (api.payload()['backtest'] as Map)['curve'] as List;
    final end = DateTime.parse(curve.last['date'] as String);
    final target = DateTime(
      end.year - 1,
      end.month,
      end.day,
    ).toIso8601String().substring(0, 10);
    final start = curve.firstWhere(
      (r) => (r['date'] as String).compareTo(target) >= 0,
    )['date'];
    expect(query['start'], start);
    expect(query['end'], curve.last['date']);
    expect(find.text('Stock P&L distribution'), findsOneWidget);
    for (final id in ['quality_rank', 'ackman']) {
      final m = strategyRangeMetrics([
        for (final r in curve.where(
          (r) => (r['date'] as String).compareTo(start as String) >= 0,
        ))
          {'date': r['date'], 'value': r[id]},
      ]);
      expect(
        tester.widget<Text>(find.byKey(ValueKey('range-$id-0'))).data,
        '${(m['totalReturn']! * 100).toStringAsFixed(2)}%',
      );
    }
    expect(find.byKey(const ValueKey('rule-range-start')), findsOneWidget);
    expect(find.byKey(const ValueKey('rule-range-end')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'calendar end-date selection re-queries both strategy distributions',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _RuleApi();
      await _mount(tester, api);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('rule-range-end')));
      await tester.tap(find.byKey(const ValueKey('rule-range-end')));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('14').last);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      final query = Uri.parse(api.paths.last).queryParameters;
      expect(query['end'], '2026-09-14');
      expect(query['start'], '2023-01-03');
      expect(find.text('Stock P&L distribution'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('range-quality_rank-0')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('range-ackman-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'attribution failure preserves both net metrics and retry works on a narrow screen',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _RuleApi()..failAnalysis = true;
      await _mount(
        tester,
        api,
        size: const Size(390, 844),
        language: AppLanguage.zh,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('range-quality_rank-0')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('range-ackman-0')), findsOneWidget);
      expect(find.textContaining('不会编造买卖价格'), findsOneWidget);
      api.failAnalysis = false;
      await tester.ensureVisible(find.text('重试逐股分析'));
      await tester.tap(find.text('重试逐股分析'));
      await tester.pumpAndSettle();
      expect(find.text('个股盈亏分布'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('range-ackman-best')),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
