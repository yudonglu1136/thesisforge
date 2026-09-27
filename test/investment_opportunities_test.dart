import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_workflow_test.dart' as fixtures;

class OpportunityApi extends fixtures.HomeFixtureApi {
  String failure = '';
  bool saved = false, reviewed = false;
  bool readOnly = false;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/api/investment/opportunities?')) {
      return {
        'asOf': '2026-06-01',
        'reportDate': '2026-03-31',
        'quarters': ['2026-03-31', '2025-12-31'],
        'coverage': {
          'eligibleManagers': 2,
          'reportedManagers': 2,
          'extractedBooks': 2,
          'modelled': 2,
          'total': 3,
        },
        'rows': [
          for (final ticker in ['TEST', 'ISRG', 'NVDA'])
            {
              'ticker': ticker,
              'name': '$ticker synthetic fixture',
              'managerCount': 2,
              'adds': ticker == 'ISRG' ? 0 : 1,
              'trims': ticker == 'ISRG' ? 1 : 0,
              'modelGap': ticker == 'TEST' ? -.4 : .2,
              'valuation': {'change': .1},
              'managers': [
                {
                  'guruId': 'test-manager',
                  'name': 'Test manager',
                  'action': 'increased',
                  'weight': .2,
                  'availableAt': '2026-05-15',
                  'reportDate': '2026-03-31',
                },
              ],
            },
        ],
      };
    }
    if (path.startsWith('/api/investment/opportunities/')) {
      return {
        'events': [
          {
            'date': '2026-05-15',
            'reportDate': '2026-03-31',
            'guruId': 'test-manager',
            'name': 'Test manager',
          },
          {
            'date': '2026-02-15',
            'reportDate': '2025-12-31',
            'guruId': 'test-manager',
            'name': 'Test manager',
          },
        ],
      };
    }
    if (path.contains('/watches/')) {
      return {
        'watch': {
          'id': 'watch-fixture',
          'ticker': 'TEST',
          'baseline': {
            'asOf': '2026-05-15',
            'price': {'value': 50, 'currency': 'USD'},
            'published': {'fairValue': 30},
          },
        },
        'now': {
          'price': {'value': 55, 'currency': 'USD'},
          'published': {'fairValue': 33},
        },
        'comparable': true,
        'modelChange': .1,
        'priceChange': .1,
        'comparisonId': 'comparison-fixture',
        'newFilings': reviewed
            ? []
            : [
                {
                  'name': 'Test manager',
                  'availableAt': '2026-05-15',
                  'action': 'increased',
                },
              ],
        'metrics': [],
      };
    }
    if (path.contains('/research/') && failure == 'missing') {
      throw const ApiRequestException(
        statusCode: 422,
        message: 'no_pit_research_at_date',
        code: 'no_pit_research_at_date',
      );
    }
    if (path.contains('/research/') && failure == 'network') {
      throw StateError('connection failed');
    }
    final r = await super.getJson(path);
    if (readOnly && path.contains('/research/')) {
      r['templates'] = {};
      // Published-model coverage is independent of personal DCF eligibility.
      r['coverage'] = {'platformModel': 'available'};
      r['publishedBreakdown'] = {
        'fairValue': 30,
        'weightedValue': 30,
        'modelVersion': 'synthetic-read-only-fixture',
        'availableAt': '2026-04-20',
        'reconciliationStatus': 'reconciled',
        'components': [],
        'postModelAdjustments': [],
      };
    }
    if (path.contains('/research/') && failure == 'identity') {
      r['ticker'] = 'WRONG';
    }
    if (path.contains('/home')) {
      r['watches'] = saved
          ? [
              {
                'id': 'watch-fixture',
                'ticker': 'TEST',
                'asOf': '2026-05-15',
                'status': reviewed ? 'unchanged' : 'new_evidence',
              },
            ]
          : [];
    }
    return r;
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path.endsWith('/watches')) saved = true;
    if (path.endsWith('/watch-reviews')) reviewed = true;
    return super.postJson(path, body);
  }
}

void main() {
  testWidgets(
    'unsupported scenario keeps the actual published valuation visible',
    (tester) async {
      final api = OpportunityApi()..readOnly = true;
      await fixtures.mountHome(
        tester,
        const Size(1487, 1058),
        AppLanguage.en,
        api,
        managers: false,
      );
      await tester.ensureVisible(find.text('View valuation method'));
      await tester.tap(find.text('View valuation method'));
      await tester.pumpAndSettle();
      expect(find.text('Published model · read-only'), findsOneWidget);
      expect(find.text('Published-model reconciliation'), findsOneWidget);
      expect(find.text('Final published value'), findsOneWidget);
      expect(find.text(r'$30.00'), findsNWidgets(2));
      await tester.tap(find.text('My DCF'));
      await tester.pumpAndSettle();
      expect(find.text('No personal DCF starting point'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final language in AppLanguage.values) {
    for (final size in [
      const Size(1487, 1058),
      const Size(1024, 768),
      const Size(390, 844),
    ]) {
      testWidgets('integrated populated candidate flow $language $size', (
        tester,
      ) async {
        final api = OpportunityApi();
        await fixtures.mountHome(tester, size, language, api, managers: false);
        expect(find.byKey(const ValueKey('candidate-TEST')), findsOneWidget);
        if (size.width < 1200) {
          await tester.ensureVisible(
            find.byKey(const ValueKey('candidate-TEST')),
          );
          await tester.tap(find.byKey(const ValueKey('candidate-TEST')));
          await tester.pumpAndSettle();
        }
        expect(find.byType(ValuationTrendChart), findsOneWidget);
        expect(find.text(r'$30.00'), findsOneWidget);
        expect(
          find.text(language == AppLanguage.en ? 'Save to watch' : '保存观察'),
          findsOneWidget,
        );
        expect(api.calls, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'filters and search retain missing coverage and select exact ticker',
    (tester) async {
      final api = OpportunityApi();
      await fixtures.mountHome(
        tester,
        const Size(1487, 1058),
        AppLanguage.en,
        api,
        managers: false,
      );
      await tester.tap(find.text('Reported adds'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-ISRG')), findsNothing);
      await tester.tap(find.text('Reported trims'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-TEST')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('candidate-ISRG')));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic home example'), findsOneWidget);
      await tester.tap(find.text('Shared holdings'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Find a company…'),
        'NVDA',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-NVDA')), findsOneWidget);
      expect(find.byKey(const ValueKey('candidate-TEST')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final failure in ['missing', 'network', 'identity']) {
    testWidgets(
      'research $failure is explicit and never shows substitute chart',
      (tester) async {
        final api = OpportunityApi()..failure = failure;
        await fixtures.mountHome(
          tester,
          const Size(1487, 1058),
          AppLanguage.en,
          api,
          managers: false,
        );
        expect(find.byType(ValuationTrendChart), findsNothing);
        if (failure == 'missing') {
          expect(
            find.textContaining('No published model at this date'),
            findsOneWidget,
          );
        } else {
          expect(
            find.textContaining('This research request failed'),
            findsWidgets,
          );
          expect(
            find.textContaining('No published model at this date'),
            findsNothing,
          );
        }
        api.failure = '';
        final retry = find.text(
          failure == 'missing' ? 'Retry company research' : 'Retry research',
        );
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(find.byType(ValuationTrendChart), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'historical selection saves without a DCF then compares and acknowledges',
    (tester) async {
      final api = OpportunityApi();
      await fixtures.mountHome(
        tester,
        const Size(1487, 1058),
        AppLanguage.en,
        api,
        managers: false,
      );
      await tester.tap(find.byKey(const ValueKey('opportunity-timeline')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026-05-15').last);
      await tester.pumpAndSettle();
      expect(
        api.reads.any((p) => p.endsWith('/research/TEST?asOf=2026-05-15')),
        isTrue,
      );
      await tester.ensureVisible(find.text('Save to watch'));
      await tester.tap(find.text('Save to watch'));
      await tester.pumpAndSettle();
      final save = api.calls.singleWhere((c) => c.$1.endsWith('/watches')).$2;
      expect(save['asOf'], '2026-05-15');
      expect(save['ticker'], 'TEST');
      expect(api.calls.any((c) => c.$1.contains('/scenarios')), isFalse);
      await tester.ensureVisible(find.text('Watching'));
      await tester.tap(find.text('Watching'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(find.text('TEST · Then → Now'), findsOneWidget);
      await tester.ensureVisible(find.text('Mark reviewed'));
      await tester.tap(find.text('Mark reviewed'));
      await tester.pumpAndSettle();
      expect(api.reviewed, isTrue);
      expect(
        find.textContaining('Original observation preserved'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('valuation round trip keeps candidate and restores list cutoff', (
    tester,
  ) async {
    final api = OpportunityApi();
    await fixtures.mountHome(
      tester,
      const Size(1487, 1058),
      AppLanguage.en,
      api,
      managers: false,
    );
    await tester.tap(find.byKey(const ValueKey('opportunity-timeline')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026-05-15').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Test my assumptions'));
    await tester.tap(find.text('Test my assumptions'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('TEST / Evidence as of 2026-05-15'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Back to candidates'));
    await tester.tap(find.text('Back to candidates'));
    await tester.pumpAndSettle();
    expect(find.text('As of 2026-06-01'), findsOneWidget);
    expect(find.byKey(const ValueKey('candidate-TEST')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('late previous company cannot replace the latest selection', (
    tester,
  ) async {
    final api = OpportunityApi()..heldIsrg = Completer<void>();
    await fixtures.mountHome(
      tester,
      const Size(1487, 1058),
      AppLanguage.en,
      api,
      managers: false,
    );
    await tester.tap(find.byKey(const ValueKey('candidate-ISRG')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('candidate-NVDA')));
    await tester.pumpAndSettle();
    api.heldIsrg!.complete();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save to watch'));
    await tester.tap(find.text('Save to watch'));
    await tester.pumpAndSettle();
    expect(
      api.calls.singleWhere((c) => c.$1.endsWith('/watches')).$2['ticker'],
      'NVDA',
    );
    expect(tester.takeException(), isNull);
  });
}
