import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class _Milestone4ResearchApi extends ApiClient {
  _Milestone4ResearchApi() : super(() => 'test-token');

  final posts = <(String, Map<String, dynamic>)>[];
  bool watched = false;
  List<Map<String, dynamic>> records = [
    {
      'id': 'rec-101',
      'ticker': 'FACT',
      'asOf': '2026-11-18',
      'question': 'Can FACT sustain 22% operating margin?',
      'supportingEvidence': 'Pricing power in core enterprise tier',
      'opposingEvidence': 'R&D step-up in Q4',
      'invalidationCondition': 'Gross margin drops below 65%',
      'reviewDate': '2027-02-15',
      'tags': ['Moat', 'Earnings'],
      'status': 'open',
    },
  ];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/api/investment/home')) {
      return {
        'watches': [
          if (watched) {'ticker': 'FACT', 'asOf': '2026-11-18'},
        ],
        'decisions': [],
        'attention': [],
        'researchNotebook': records.where((r) => r['status'] != 'archived').toList(),
      };
    }
    if (path.startsWith('/api/investment/research/FACT/records')) {
      return {
        'version': 'research-record-v1',
        'rows': records.where((r) => r['status'] != 'archived').toList(),
      };
    }
    if (path.startsWith('/api/investment/research/FACT')) {
      return {
        'ticker': 'FACT',
        'name': 'FactOnly Industrial Corp.',
        'currency': 'USD',
        'asOf': '2026-11-18',
        'coverage': {
          'company': 'available',
          'platformModel': 'not_modeled',
          'personalResearch': 'available',
        },
        'snapshot': {
          'periodEnd': '2026-09-30',
          'availableAt': '2026-11-01',
          'price': {'value': 88.50, 'date': '2026-11-17', 'currency': 'USD'},
          'metrics': {'revenueGrowth': 0.18, 'operatingMargin': 0.22},
        },
        'financials': {'annual': [], 'quarterly': []},
        'researchRecords': records.where((r) => r['status'] != 'archived').toList(),
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    posts.add((path, body));
    if (path == '/api/investment/watches') {
      watched = body['active'] != false;
      return {'ok': true};
    }
    if (path == '/api/investment/research-records') {
      final parentId = body['parentRecordId'] as String?;
      if (parentId != null) {
        final idx = records.indexWhere((r) => r['id'] == parentId);
        if (idx >= 0) {
          records[idx] = {
            ...records[idx],
            ...body,
            'id': parentId,
          };
        }
      } else {
        records.add({'id': 'rec-${records.length + 200}', ...body});
      }
      return {'ok': true};
    }
    return {};
  }
}

void main() {
  testWidgets(
    'Cross-company Research Notebook opens Fact OS company, supports Watch/Unwatch, Edit, Validate, Remove, and guards unsaved draft',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _Milestone4ResearchApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'research',
              initialTicker: '',
              initialAsOf: '2026-11-18',
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Cross-company Research Notebook is visible on Research launcher
      expect(
        find.byKey(const ValueKey('global-research-notebook')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('notebook-row-rec-101')), findsOneWidget);

      // Click notebook row -> jumps straight to FACT Research records
      await tester.tap(find.byKey(const ValueKey('notebook-row-rec-101')));
      await tester.pumpAndSettle();

      expect(find.text('FactOnly Industrial Corp.'), findsWidgets);
      expect(find.text('#Moat'), findsWidgets);

      // 2. Fact OS-only company supports Watch & Unwatch toggle
      await tester.tap(find.byKey(const ValueKey('research-watch-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Saved to watch'), findsOneWidget);
      expect(api.posts.last.$2['origin'], 'fact_os');

      await tester.tap(find.byKey(const ValueKey('research-watch-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Save to watch'), findsOneWidget);
      expect(api.posts.last.$2['active'], false);

      // 3. Edit record -> updates via parentRecordId
      await tester.ensureVisible(
        find.byKey(const ValueKey('record-edit-rec-101')),
      );
      await tester.tap(find.byKey(const ValueKey('record-edit-rec-101')));
      await tester.pumpAndSettle();
      expect(find.text('Edit research record'), findsOneWidget);

      await tester.tap(find.text('Update research record'));
      await tester.pumpAndSettle();
      expect(api.posts.last.$2['parentRecordId'], 'rec-101');

      // 4. Mark validated -> updates status badge
      await tester.ensureVisible(
        find.byKey(const ValueKey('record-validate-rec-101')),
      );
      await tester.tap(find.byKey(const ValueKey('record-validate-rec-101')));
      await tester.pumpAndSettle();
      expect(find.text('Validated ✓'), findsOneWidget);

      // 5. Remove (archive) record -> hides from active list
      await tester.ensureVisible(
        find.byKey(const ValueKey('record-archive-rec-101')),
      );
      await tester.tap(find.byKey(const ValueKey('record-archive-rec-101')));
      await tester.pumpAndSettle();
      expect(find.text('Can FACT sustain 22% operating margin?'), findsNothing);

      // 6. Unsaved note draft guard triggers when navigating away
      await tester.enterText(
        find.widgetWithText(TextField, 'Research question'),
        'Half-written thesis question',
      );
      await tester.pump();
      await tester.tap(find.text('Home').first);
      await tester.pumpAndSettle();
      expect(find.text('Leave unsaved research note?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Half-written thesis question'), findsOneWidget);
    },
  );
}
