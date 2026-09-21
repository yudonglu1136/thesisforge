import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

const _savedReport = <String, dynamic>{
  'status': 'success',
  'source': {
    'mode': 'saved_broker_report',
    'asOf': '2026-09-10',
    'retrievedAt': '2026-09-10T12:00:00Z',
    'stale': true,
  },
  'freshness': {
    'status': 'stale',
    'basis': 'last_successful_broker_report',
    'reportAsOf': '2026-09-10',
    'retrievedAt': '2026-09-10T12:00:00Z',
    'live': false,
  },
  'summary': {'totalValue': 12345, 'currency': 'USD'},
  'connection': {
    'status': 'stale_report',
    'registered': true,
    'configured': true,
    'accounts': <Map<String, dynamic>>[],
  },
  'accounts': <Map<String, dynamic>>[],
  'holdings': <Map<String, dynamic>>[],
};

class _SavedReportApi extends ApiClient {
  _SavedReportApi([this.payload = _savedReport]) : super(() => 'test-session');

  final Map<String, dynamic> payload;

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async => payload;
}

Map<String, dynamic> _syncResponse(
  String status, {
  required bool ok,
  Map<String, dynamic>? portfolio,
}) => {
  'ok': ok,
  'connection': {'status': status},
  'summary': {'accounts': 1, 'holdings': 4},
  'portfolio':
      portfolio ??
      {
        'connection': {'status': status},
        'source': {'mode': 'live', 'asOf': '2026-09-10'},
        'freshness': {'status': 'current_report', 'live': false},
      },
};

void main() {
  test('saved report stays stale even when its date is current', () {
    expect(isSavedPortfolioReport(_savedReport), isTrue);
    expect(
      isSavedPortfolioReport({
        'source': {'mode': 'live'},
      }),
      isFalse,
    );
    final state = moduleHeaderState(
      mode: 'portfolio',
      payload: _savedReport,
      loading: false,
      now: DateTime.utc(2026, 9, 10, 14),
    );
    expect(state.status, 'stale');
    expect(state.asOf, '2026-09-10');
    final en = savedPortfolioReportNotice(_savedReport, AppLanguage.en);
    expect(en, contains('last saved report dated 2026-09-10'));
    expect(en, contains('no new sync completed'));
    expect(en, isNot(contains('12345')));
    expect(
      savedPortfolioReportNotice({}, AppLanguage.en),
      contains('date not recorded'),
    );
  });

  for (final language in AppLanguage.values) {
    testWidgets('saved portfolio notice is explicit in $language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: language,
            child: Scaffold(
              body: SingleChildScrollView(
                child: PortfolioDashboard(
                  data: _savedReport,
                  api: _SavedReportApi(),
                  palette: Palette(false),
                  onRefresh: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          language == AppLanguage.en ? 'Saved portfolio report' : '已保存的组合报告',
        ),
        findsOneWidget,
      );
      expect(
        find.text(savedPortfolioReportNotice(_savedReport, language)),
        findsOneWidget,
      );
      expect(find.text('IBKR holdings synced through Yodlee.'), findsNothing);
      expect(find.text('Day P/L'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('manual sync fallback never claims successful synchronization', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var refreshed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LanguageScope(
          language: AppLanguage.en,
          child: Scaffold(
            body: PortfolioConnectionStatusPanel(
              connection: const {'status': 'linked'},
              api: _SavedReportApi(),
              palette: Palette(false),
              onRefresh: () async => refreshed++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Update data'));
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(find.textContaining('no new sync completed'), findsOneWidget);
    expect(find.textContaining('Synced from IBKR/Yodlee'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final language in AppLanguage.values) {
    final cases = <String, Map<String, dynamic>>{
      'saved report': _syncResponse(
        'stale_report',
        ok: false,
        portfolio: _savedReport,
      ),
      'partial': _syncResponse('linked_partial', ok: false),
      'failed': _syncResponse('error', ok: false),
      'ok false even with linked connection': _syncResponse(
        'linked',
        ok: false,
      ),
      'nested partial overrides outer ok': _syncResponse(
        'linked',
        ok: true,
        portfolio: {
          'connection': {'status': 'linked_partial'},
        },
      ),
      'error overrides outer ok': _syncResponse('error', ok: true),
      'complete': _syncResponse('linked', ok: true),
    };
    for (final entry in cases.entries) {
      testWidgets('sync wrapper ${entry.key} reports honestly in $language', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var refreshed = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: LanguageScope(
              language: language,
              child: Scaffold(
                body: PortfolioConnectionStatusPanel(
                  connection: const {'status': 'linked'},
                  api: _SavedReportApi(entry.value),
                  palette: Palette(false),
                  onRefresh: () async => refreshed++,
                ),
              ),
            ),
          ),
        );
        await tester.tap(
          find.text(language == AppLanguage.en ? 'Update data' : '更新数据'),
        );
        await tester.pumpAndSettle();
        expect(refreshed, 1);
        final success = find.textContaining(
          language == AppLanguage.en
              ? 'IBKR verified and saved'
              : 'IBKR 已验证并写入后端',
        );
        if (entry.key == 'complete') {
          expect(success, findsOneWidget);
        } else {
          expect(success, findsNothing);
          if (entry.key == 'saved report') {
            expect(
              find.text(savedPortfolioReportNotice(_savedReport, language)),
              findsOneWidget,
            );
          } else {
            final partial = entry.key.contains('partial');
            expect(
              find.textContaining(
                language == AppLanguage.en
                    ? partial
                          ? 'Only some accounts synced'
                          : 'Broker sync did not complete'
                    : partial
                    ? '仅部分账户同步成功'
                    : '券商同步未完成',
              ),
              findsOneWidget,
            );
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
