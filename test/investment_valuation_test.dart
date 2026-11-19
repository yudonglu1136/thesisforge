import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_workflow_test.dart' as fixtures;

class PersonalApi extends fixtures.HomeFixtureApi {
  double outputValue = 48.0;
  final versions = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add((path, body));
    if (path.endsWith('/scenarios')) {
      final saved = {...body, 'id': 'v-${versions.length + 1}', 'version': versions.length + 1};
      versions.add(saved);
      return saved;
    }
    return {
      'result': {'fairValue': outputValue, 'forecast': []},
      'reverse': {'status': 'solved', 'value': .1},
      'sensitivity': [],
    };
  }
}

Finder cell(String metric, int year) =>
    find.byKey(ValueKey('forecast-Year $year $metric'));

Future<void> edit(WidgetTester t, Finder f, String value) async {
  await t.ensureVisible(f);
  await t.enterText(f, value);
  await t.pumpAndSettle();
}

Future<void> open(
  WidgetTester t,
  ApiClient api, {
  Size size = const Size(1487, 1058),
  AppLanguage language = AppLanguage.en,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: LanguageScope(
        language: language,
        child: InvestmentWorkspace(
          api: api,
          palette: Palette(false),
          initialPage: 'research',
          initialTicker: 'TEST',
          initialAsOf: '2026-06-01',
          onLanguage: (_) {},
          onLegacy: () {},
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'Research retires Valuation workspace, falls back legacy ?section=value to dynamic Financial statements, and renders Margins & returns',
    (t) async {
      t.view.physicalSize = const Size(1487, 1058);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      await t.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.zh,
            child: InvestmentWorkspace(
              api: fixtures.HomeFixtureApi(),
              palette: Palette(false),
              initialPage: 'research',
              initialTicker: 'TEST',
              initialAsOf: '2026-06-01',
              initialQuery: const {'section': 'value'},
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('research-tab-value')), findsNothing);
      expect(find.text('估值工作台'), findsNothing);
      expect(find.text('平台公允估值'), findsNothing);
      expect(find.text('模型估值空间'), findsNothing);
      expect(find.text('财务报表'), findsOneWidget);
      expect(find.text('股息与派息'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('research-statement-ratios')),
        findsOneWidget,
      );

      await t.tap(find.byKey(const ValueKey('research-statement-ratios')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );

  test('formatResearchStatementUnitValue and derived statement ratio helpers stay unit-safe', () {
    expect(formatResearchStatementUnitValue(0.2456, 'percent'), '24.6%');
    expect(formatResearchStatementUnitValue(1.85, 'multiple'), '1.85x');
    expect(formatResearchStatementUnitValue(0.27, 'per_share'), '\$0.270');
    expect(formatResearchStatementUnitValue(3.40, 'per_share'), '\$3.40');

    final period = {
      'kind': 'annual',
      'row': {
        'revenue': 1000.0,
        'gp': 450.0,
        'opinc': 250.0,
        'fcf': 200.0,
        'debt': 300.0,
        'equity': 600.0,
        'currency': 'USD',
      },
      'yoy': {
        'kind': 'annual',
        'row': {
          'revenue': 800.0,
          'gp': 320.0,
          'opinc': 160.0,
          'fcf': 120.0,
          'debt': 300.0,
          'equity': 500.0,
          'currency': 'USD',
        },
      },
    };
    expect(researchFinancialReportedValue(period, 'grossmargin_calc'), closeTo(0.45, 1e-9));
    expect(researchFinancialReportedValue(period, 'opmargin_calc'), closeTo(0.25, 1e-9));
    expect(researchFinancialReportedValue(period, 'de_calc'), closeTo(0.50, 1e-9));
    final marginDelta = researchFinancialGrowth(
      period,
      'grossmargin_calc',
      'yoy',
      unit: 'percent',
    );
    expect(marginDelta.reason, 'pp_delta');
    expect(marginDelta.value!, closeTo(0.05, 1e-9));
  });
}
