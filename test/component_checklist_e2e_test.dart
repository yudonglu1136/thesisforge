import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_research_test.dart' show ResearchApi;

class ChecklistResearchApi extends ResearchApi {
  Completer<Map<String, dynamic>>? slowRemoteSearch;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final uri = Uri.parse(path);
    if (uri.path == '/api/investment/companies') {
      reads.add(path);
      final q = (uri.queryParameters['search'] ?? '').trim().toLowerCase();
      if (q.isNotEmpty && slowRemoteSearch != null) {
        return slowRemoteSearch!.future;
      }
      final all = [
        {
          'ticker': 'NVDA',
          'name': 'NVIDIA Corporation',
          'availableAt': '2026-05-28',
          'coverage': 'stored_model',
        },
        {
          'ticker': 'ISRG',
          'name': 'Intuitive Surgical, Inc.',
          'availableAt': '2026-04-20',
          'coverage': 'stored_model',
        },
        {
          'ticker': 'TEST',
          'name': 'Test Robotics Corp.',
          'availableAt': '2026-05-01',
          'coverage': 'stored_model',
        },
      ];
      return {
        'asOf': uri.queryParameters['asOf'] ?? '2026-06-01',
        'companies': q.isEmpty
            ? all
            : all
                  .where(
                    (c) =>
                        '${c['ticker']} ${c['name']}'.toLowerCase().contains(q),
                  )
                  .toList(),
      };
    }
    if (uri.path.endsWith('/earnings')) {
      reads.add(path);
      return {
        'ticker': uri.pathSegments[uri.pathSegments.length - 2],
        'asOf': uri.queryParameters['asOf'] ?? '2026-06-01',
        'periods': [
          {
            'period': '2026-Q1',
            'availableAt': '2026-05-01',
            'periodEnd': '2026-03-31',
          },
        ],
        'selected': {
          'period': '2026-Q1',
          'availableAt': '2026-05-01',
          'periodEnd': '2026-03-31',
          'currency': 'USD',
          'metrics': const [],
          'actual': {'revenueM': 44000.0},
          'model': {'value': 135.0, 'formula': 'FCFE'},
          'guidance': [
            {
              'excerpt':
                  'For Q3, we expect GAAP and non-GAAP gross margins to be 74% Â±50 basis points.',
              'speaker': 'Colette Kress — EVP and CFO',
              'observedAt': '2026-05-01',
              'disposition': 'quantified_evidence',
              'targetYear': '2026',
            },
          ],
          'qa': const [],
          'coverage': {'status': 'has_qa', 'qaCount': 0},
        },
      };
    }
    if (uri.path.endsWith('/insiders')) {
      reads.add(path);
      return {
        'methodVersion': 'reported-insider-activity-v1',
        'ticker': uri.pathSegments[uri.pathSegments.length - 2],
        'asOf': uri.queryParameters['asOf'] ?? '2026-06-01',
        'start': '2026-01-01',
        'windowMonths': 6,
        'currency': 'USD',
        'coverage': 'available',
        'summary': {
          'purchases': {
            'value': 0,
            'lines': 0,
            'priced': 0,
            'unpriced': 0,
            'complete': true,
          },
          'sales': {
            'value': 1200000,
            'lines': 1,
            'priced': 1,
            'unpriced': 0,
            'complete': true,
          },
          'otherLines': 0,
          'excludedLines': 0,
          'reportingNames': 1,
          'netReportedValue': -1200000,
        },
        'months': const [],
        'total': 1,
        'offset': 0,
        'limit': 20,
        'rows': [
          {
            'id': 'ins_1',
            'date': '2026-05-10',
            'transactiondate': '2026-05-08',
            'ownername': 'JENSEN HUANG',
            'officertitle': 'President and CEO',
            'formtype': '4',
            'kind': 'sale',
            'securityadcode': 'ND',
            'shares': -10000,
            'priceUsd': 120.0,
            'valueUsd': 1200000.0,
          },
        ],
      };
    }
    final base = await super.getJson(path);
    if (uri.path.startsWith('/api/investment/research/') &&
        !uri.path.endsWith('/fundamentals') &&
        !uri.path.endsWith('/dividends') &&
        !uri.path.endsWith('/documents') &&
        !uri.path.endsWith('/institutions') &&
        !uri.path.endsWith('/records')) {
      return {
        ...base,
        'guidance': {
          'evidence': [
            {
              'excerpt':
                  'For Q3, we expect GAAP and non-GAAP gross margins to be 74% Â±50 basis points.',
              'speaker': 'Colette Kress — EVP and CFO, NVIDIA',
              'observedAt': '2026-05-01',
            },
          ],
        },
      };
    }
    return base;
  }
}

void main() {
  testWidgets(
    'Checklist C02-C04: CompanySearchDialog filters locally at 0ms without blanking into spinner and reopens from session pool cache',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = ChecklistResearchApi();
      String? picked;

      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.zh,
            child: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () async {
                    picked = await showDialog<String>(
                      context: ctx,
                      builder: (_) => CompanySearchDialog(
                        api: api,
                        palette: Palette(true),
                        asOf: '2026-06-01',
                        currentTicker: 'TEST',
                      ),
                    );
                  },
                  child: const Text('Open Search'),
                ),
              ),
            ),
          ),
        ),
      );

      // 1. Open dialog and load initial directory.
      await tester.tap(find.text('Open Search'));
      await tester.pumpAndSettle();
      expect(find.text('NVIDIA Corporation'), findsOneWidget);

      // 2. Simulate slow network on remote query: local typing MUST filter immediately at 0ms without blanking results into a spinner!
      api.slowRemoteSearch = Completer<Map<String, dynamic>>();
      await tester.enterText(
        find.byKey(const ValueKey('company-search-input')),
        'nvda',
      );
      await tester.pump(const Duration(milliseconds: 250));
      // Even while remote search is still in flight, NVDA remains visible and selectable!
      expect(find.text('NVIDIA Corporation'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('正在加载公司…'), findsNothing);

      // Pressing Enter selects NVDA immediately without waiting for slow remote roundtrip!
      await tester.testTextInput.receiveAction(TextInputAction.search);
      api.slowRemoteSearch!.complete({
        'asOf': '2026-06-01',
        'companies': const [],
      });
      api.slowRemoteSearch = null;
      await tester.pumpAndSettle();
      expect(picked, 'NVDA');

      // 3. Re-opening dialog renders cached pool on frame 0 without loading spinner!
      await tester.tap(find.text('Open Search'));
      await tester.pump(); // single frame!
      expect(find.text('NVIDIA Corporation'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Checklist C25-C36: Research cockpit cleans mojibake, caches 3-statements across company switches (0ms revisit), and loads all lazy tabs cleanly in Chinese',
    (tester) async {
      tester.view.physicalSize = const Size(1487, 1058);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = ChecklistResearchApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.zh,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(true),
              initialPage: 'research',
              initialTicker: 'TEST',
              initialAsOf: '2026-06-01',
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Mojibake '74% Â±50 basis points' is cleaned to '74% ±50 basis points'!
      expect(find.textContaining('74% ±50 basis points'), findsOneWidget);
      expect(find.textContaining('Â±'), findsNothing);

      // 3-Statements loaded once for TEST; switching Income / Balance / Cash + Quarterly works cleanly.
      final fundamentalsCallsAfterFirstOpen = api.reads
          .where((p) => p.endsWith('/fundamentals') || p.contains('/fundamentals?'))
          .length;
      expect(fundamentalsCallsAfterFirstOpen, 1);

      await tester.ensureVisible(
        find.byKey(const ValueKey('research-statement-balance')),
      );
      await tester.tap(find.byKey(const ValueKey('research-statement-balance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('research-statement-cash')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('research-frequency-quarterly')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('research-financial-chart')), findsOneWidget);

      // Switch company TEST -> ISRG -> TEST: revisiting TEST reuses _researchFundamentalsCache (0 extra /TEST/fundamentals network calls!)
      await tester.ensureVisible(find.text('切换公司'));
      await tester.tap(find.text('切换公司'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ISRG'));
      await tester.pumpAndSettle();
      expect(
        api.reads.where((p) => p.contains('/research/ISRG/fundamentals')).length,
        1,
      );

      await tester.ensureVisible(find.text('切换公司'));
      await tester.tap(find.text('切换公司'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TEST'));
      await tester.pumpAndSettle();
      expect(
        api.reads.where((p) => p.contains('/research/TEST/fundamentals')).length,
        1,
      );

      // Valuation workspace tab is permanently removed; exercise active tabs cleanly.
      expect(find.byKey(const ValueKey('research-tab-value')), findsNothing);
      for (final tabKey in const [
        'research-tab-dividends',
        'research-tab-financials',
        'research-tab-institutions',
        'research-tab-records',
      ]) {
        await tester.ensureVisible(find.byKey(ValueKey(tabKey)));
        await tester.tap(find.byKey(ValueKey(tabKey)));
        await tester.pumpAndSettle();
        expect(find.textContaining('Â±'), findsNothing);
      }

      expect(tester.takeException(), isNull);
    },
  );
}
