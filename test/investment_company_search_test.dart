import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class SearchApi extends ApiClient {
  SearchApi() : super(() => 'fixture');
  final reads = <String>[];
  bool fail = false, wrongDate = false, future = false;
  Completer<Map<String, dynamic>>? pending;
  List<Map<String, dynamic>> companies = [
    for (final item in [
      ('TEST', 'Synthetic current company'),
      ('ISRG', 'Intuitive Surgical'),
      ('NVDA', 'NVIDIA Corporation'),
      ('NVDAA', 'Synthetic NVIDIA alternate'),
    ])
      {
        'ticker': item.$1,
        'name': item.$2,
        'availableAt': '2026-04-20',
        'coverage': 'stored_model',
      },
  ];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    reads.add(path);
    if (fail) throw StateError('offline');
    if (pending != null) return pending!.future;
    return {
      'asOf': wrongDate ? '2099-01-01' : '2026-08-28',
      'companies': future
          ? [
              {...companies.first, 'availableAt': '2099-01-01'},
            ]
          : companies,
    };
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) => throw StateError('No writes permitted');
}

Future<void> mount(
  WidgetTester t,
  SearchApi api, {
  Size size = const Size(1487, 1058),
  AppLanguage lang = AppLanguage.en,
  double scale = 1,
  ValueChanged<String?>? selected,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      builder: (context, child) => LanguageScope(
        language: lang,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final value = await showDialog<String>(
                context: context,
                builder: (_) => CompanySearchDialog(
                  api: api,
                  palette: Palette(false),
                  asOf: '2026-08-28',
                  currentTicker: 'TEST',
                  recentTickers: const ['NVDA'],
                ),
              );
              selected?.call(value);
            },
            child: const Text('Open fixture'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('Open fixture'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Finder get input => find.byKey(const ValueKey('company-search-input'));

void main() {
  test(
    'case-insensitive name/ticker matching, exact symbol first, no mutation',
    () {
      final all = SearchApi().companies;
      expect(matchResearchCompanies(all, 'nvidia').map((r) => r['ticker']), [
        'NVDA',
        'NVDAA',
      ]);
      expect(matchResearchCompanies(all, '  nvda ').first['ticker'], 'NVDA');
      expect(
        matchResearchCompanies(all, 'intuitive surgical').single['ticker'],
        'ISRG',
      );
      expect(matchResearchCompanies(all, 'unknown'), isEmpty);
      expect(all.first['ticker'], 'TEST');
    },
  );
  for (final lang in AppLanguage.values) {
    for (final size in [const Size(1487, 1058), const Size(390, 844)]) {
      testWidgets('search and select name with logo at $size in $lang', (
        t,
      ) async {
        final api = SearchApi();
        String? selected;
        await mount(
          t,
          api,
          size: size,
          lang: lang,
          selected: (v) => selected = v,
        );
        await t.pumpAndSettle();
        expect(
          find.text(lang == AppLanguage.en ? 'Current' : '当前'),
          findsOneWidget,
        );
        expect(
          find.text(lang == AppLanguage.en ? 'Recent' : '最近查看'),
          findsOneWidget,
        );
        expect(find.byType(StockLogo), findsNWidgets(4));
        await t.enterText(input, 'Intuitive');
        await t.pumpAndSettle();
        expect(find.text('ISRG'), findsOneWidget);
        expect(find.text('NVDA'), findsNothing);
        expect(api.reads.length, 2);
        expect(api.reads.first, contains('search=&limit=120'));
        expect(api.reads.last, contains('search=Intuitive&limit=120'));
        await t.tap(find.text('ISRG'));
        await t.pumpAndSettle();
        expect(selected, 'ISRG');
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'keyboard moves selection, Enter opens exact result, Escape cancels',
    (t) async {
      String? selected;
      await mount(t, SearchApi(), selected: (v) => selected = v);
      await t.pumpAndSettle();
      await t.enterText(input, 'nvda');
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();
      expect(selected, 'NVDAA');
      selected = 'not cancelled';
      await t.tap(find.text('Open fixture'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(selected, isNull);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'unknown does not submit raw ticker; clear restores dated directory',
    (t) async {
      final api = SearchApi();
      String? selected;
      await mount(t, api, selected: (v) => selected = v);
      await t.pumpAndSettle();
      await t.enterText(input, 'no such stock');
      await t.pumpAndSettle();
      expect(find.text('No matching companies'), findsOneWidget);
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pump();
      expect(selected, isNull);
      await t.tap(find.byTooltip('Clear search'));
      await t.pumpAndSettle();
      expect(find.text('Browse companies · 4'), findsOneWidget);
      // Clearing before the debounce fires cancels the obsolete remote query
      // and immediately restores the bounded directory.
      expect(api.reads.length, 2);
      expect(api.reads.last, contains('search=&limit=120'));
    },
  );
  testWidgets('failure, retry and explicit loading do not change selection', (
    t,
  ) async {
    final api = SearchApi()..fail = true;
    await mount(t, api);
    await t.pumpAndSettle();
    expect(find.text('Couldn’t load companies'), findsOneWidget);
    api.fail = false;
    api.pending = Completer<Map<String, dynamic>>();
    await t.tap(find.text('Try again'));
    await t.pump();
    expect(find.text('Loading companies…'), findsOneWidget);
    api.pending!.complete({'asOf': '2026-08-28', 'companies': api.companies});
    await t.pumpAndSettle();
    expect(find.text('NVIDIA Corporation'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('cutoff mismatch and future catalog data fail closed', (t) async {
    final api = SearchApi()..wrongDate = true;
    await mount(t, api);
    await t.pumpAndSettle();
    expect(find.text('Couldn’t load companies'), findsOneWidget);
    api.wrongDate = false;
    api.future = true;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('Couldn’t load companies'), findsOneWidget);
    expect(find.text('TEST'), findsNothing);
  });
  testWidgets(
    '12-second timeout has a retry; late response after close is safe',
    (t) async {
      final api = SearchApi()..pending = Completer<Map<String, dynamic>>();
      await mount(t, api);
      await t.pump(const Duration(seconds: 13));
      await t.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      await t.tap(find.byTooltip('Close search'));
      await t.pumpAndSettle();
      api.pending!.complete({'asOf': '2026-08-28', 'companies': api.companies});
      await t.pumpAndSettle();
      expect(find.byType(CompanySearchDialog), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'phone large text and software keyboard leave results scrollable',
    (t) async {
      t.view.viewInsets = const FakeViewPadding(bottom: 284);
      addTearDown(t.view.resetViewInsets);
      await mount(t, SearchApi(), size: const Size(390, 844), scale: 1.5);
      await t.pumpAndSettle();
      await t.enterText(input, 'NVIDIA');
      await t.pumpAndSettle();
      expect(find.text('NVDA'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('large directories keep keyboard selection visible', (t) async {
    final api = SearchApi();
    api.companies = [
      for (var i = 0; i < 100; i++)
        {
          'ticker': 'T${i.toString().padLeft(3, '0')}',
          'name': 'Synthetic $i',
          'availableAt': '2026-04-20',
          'coverage': 'stored_model',
        },
    ];
    String? selected;
    await mount(t, api, selected: (v) => selected = v);
    await t.pumpAndSettle();
    for (var i = 0; i < 20; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
    }
    expect(find.text('T020').hitTestable(), findsOneWidget);
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(selected, 'T020');
    expect(t.takeException(), isNull);
  });
}
