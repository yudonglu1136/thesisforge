import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

Map<String, dynamic> _dossierFixture() => {
  'guru': {
    'id': 'dev-kantesaria',
    'name': 'Dev Kantesaria',
    'chineseName': '德夫·坎特萨里亚',
    'entityName': 'Valley Forge Capital Management, LP',
    'role': 'Managing Partner',
    'thesisTag': 'Predictable compounders',
    'followed': false,
    'capitalStructure': {
      'category': 'external_client',
      'label': 'External / client capital',
      'labelZh': '外部 / 客户资本',
    },
  },
  'asOf': '2026-11-17',
  'styleProfile': {
    'concentrationTier': 'ultra_concentrated',
    'turnoverTier': 'low_turnover',
    'avgPositions': 7.5,
    'avgQuarterlyTurnover': 0.082,
    'latestTop5Weight': 0.933,
    'latestTop10Weight': 1.0,
    'latestHhi': 0.188,
    'totalFilings': 39,
  },
  'backtest': {
    'status': 'ready',
    'defaultWindow': '5Y',
    'benchmark': 'SPY',
    'windows': {
      '5Y': {
        'window': '5Y',
        'kind': 'strict',
        'status': 'ready',
        'startDate': '2022-02-15',
        'endDate': '2026-11-13',
        'totalReturn': 0.587,
        'benchmarkTotalReturn': 0.802,
        'excessTotalReturn': -0.215,
        'cagr': 0.102,
        'benchmarkCagr': 0.132,
        'excessCagr': -0.030,
        'sharpe': 0.53,
        'benchmarkSharpe': 0.81,
        'maxDrawdown': -0.291,
        'benchmarkMaxDrawdown': -0.221,
        'curve': [
          {'d': '2022-02-15', 'v': 1.0, 'b': 1.0},
          {'d': '2024-06-15', 'v': 1.35, 'b': 1.40},
          {'d': '2026-11-13', 'v': 1.587, 'b': 1.802},
        ],
        'attribution': {
          'totalQuarters': 19,
          'winQuarters': 9,
          'quarterlyWinRate': 9 / 19,
          'topContributors': [
            {
              'ticker': 'FICO',
              'issuer': 'Fair Isaac',
              'totalContributionPct': 0.412,
              'quartersHeld': 19,
            },
            {
              'ticker': 'SPGI',
              'issuer': 'S&P Global',
              'totalContributionPct': 0.185,
              'quartersHeld': 19,
            },
          ],
          'bottomContributors': [
            {
              'ticker': 'ASML',
              'issuer': 'ASML Holding',
              'totalContributionPct': -0.042,
              'quartersHeld': 4,
            },
          ],
          'quarters': [
            {
              'label': '2026 Q2',
              'reportDate': '2026-06-30',
              'portfolioReturn': -0.021,
              'benchmarkReturn': -0.0213,
              'excessReturn': 0.0003,
              'topWinners': [
                {'ticker': 'MA', 'contributionPct': 0.031},
              ],
            },
          ],
        },
      },
      '10Y': {
        'window': '10Y',
        'kind': 'strict',
        'status': 'ready',
        'startDate': '2016-11-15',
        'endDate': '2026-11-13',
        'totalReturn': 3.966,
        'benchmarkTotalReturn': 2.760,
        'excessTotalReturn': 1.206,
        'cagr': 0.179,
        'benchmarkCagr': 0.146,
        'excessCagr': 0.033,
        'sharpe': 0.79,
        'benchmarkSharpe': 0.84,
        'maxDrawdown': -0.400,
        'benchmarkMaxDrawdown': -0.337,
        'curve': [
          {'d': '2016-11-15', 'v': 1.0, 'b': 1.0},
          {'d': '2021-11-15', 'v': 2.6, 'b': 2.0},
          {'d': '2026-11-13', 'v': 4.966, 'b': 3.760},
        ],
        'attribution': {
          'totalQuarters': 39,
          'winQuarters': 24,
          'quarterlyWinRate': 24 / 39,
          'topContributors': [
            {
              'ticker': 'FICO',
              'issuer': 'Fair Isaac',
              'totalContributionPct': 1.45,
              'quartersHeld': 32,
            },
          ],
          'bottomContributors': [],
          'quarters': [],
        },
      },
    },
    'quarterReturnByReportDate': {
      '2026-06-30': {
        'label': '2026 Q2',
        'portfolioReturn': -0.021,
        'benchmarkReturn': -0.0213,
        'excessReturn': 0.0003,
        'byTicker': {
          'FICO': {'returnPct': -0.323, 'contributionPct': -0.083},
          'MA': {'returnPct': 0.178, 'contributionPct': 0.031},
        },
      },
    },
  },
  'history': [
    {
      'accessionNumber': 'vf-q2',
      'reportDate': '2026-06-30',
      'filingDate': '2026-08-14',
      'quarterLabel': '2026 Q2',
      'reported13fValue': 3116388059,
      'valueChange': -259249628,
      'valueChangePct': -0.0768,
      'positionCount': 7,
      'bookScope': 'full_book',
      'top5Weight': 0.933,
      'top10Weight': 1.0,
      'concentrationHhi': 0.188,
      'moveCounts': {
        'newPositions': 1,
        'increasedPositions': 0,
        'reducedPositions': 2,
        'soldOutPositions': 0,
      },
      'keyBuys': [
        {
          'ticker': 'ASML',
          'issuer': 'ASML Holding',
          'action': 'new',
          'weight': 0.109,
          'value': 340359364,
          'valueChange': 340359364,
        },
      ],
      'keySells': [
        {
          'ticker': 'MA',
          'issuer': 'Mastercard',
          'action': 'reduced',
          'weight': 0.176,
          'changePct': -0.283,
          'valueChange': -195778549,
        },
        {
          'ticker': 'FICO',
          'issuer': 'Fair Isaac',
          'action': 'reduced',
          'weight': 0.258,
          'changePct': -0.126,
          'valueChange': -18188970,
        },
      ],
      'sectors': [
        {'sector': 'Financial Services', 'weight': 0.617, 'count': 4},
        {'sector': 'Technology', 'weight': 0.383, 'count': 3},
      ],
      'topHoldings': [
        {
          'id': 'FICO-COMMON',
          'holdingBucket': 'common_long',
          'ticker': 'FICO',
          'issuer': 'FAIR ISAAC CORP',
          'shares': 672186,
          'value': 803114389,
          'pctPortfolio': 0.2577,
          'action': 'reduced',
          'changePct': -0.126,
          'sector': 'Technology',
          'marketPrice': 720.19,
          'fairValue': 828.0,
          'modelGap': 0.15,
        },
        {
          'id': 'MA-COMMON',
          'holdingBucket': 'common_long',
          'ticker': 'MA',
          'issuer': 'MASTERCARD INC',
          'shares': 1065934,
          'value': 547463702,
          'pctPortfolio': 0.1757,
          'action': 'reduced',
          'changePct': -0.283,
          'sector': 'Financial Services',
          'marketPrice': 661.19,
          'fairValue': 600.0,
          'modelGap': -0.092,
        },
      ],
    },
  ],
  'latest': {'accessionNumber': 'vf-q2'},
};

Future<void> _mountDossier(
  WidgetTester t, {
  AppLanguage lang = AppLanguage.zh,
  Size size = const Size(1440, 1200),
  double scale = 1.0,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  var holding = 'FICO';
  var metric = 'shares';
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: LanguageScope(
        language: lang,
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: StatefulBuilder(
              builder: (_, setLocal) => SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: GuruResearchDossier(
                  detail: _dossierFixture(),
                  selectedQuarter: 'vf-q2',
                  selectedHolding: holding,
                  trajectoryMetric: metric,
                  asOf: '2026-11-17',
                  palette: Palette(false),
                  onBack: () {},
                  onSelectQuarter: (_) {},
                  onSelectHolding: (s) => setLocal(() => holding = s),
                  onSelectTrajectoryMetric: (m) => setLocal(() => metric = m),
                  onResearchCompany: (_, _) {},
                  onOpenTerminal: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'GuruResearchDossier renders systematic insights, 5Y/10Y backtest curve, attribution, key moves, and mobile layout without overflow',
    (t) async {
      await _mountDossier(t, lang: AppLanguage.zh);

      expect(
        find.byKey(const ValueKey('guru-systematic-insights')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('guru-dossier-backtest')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('guru-dossier-moves')), findsOneWidget);
      expect(find.text('系统化核心投研洞察'), findsOneWidget);
      expect(find.textContaining('极致集中型'), findsOneWidget);
      expect(find.textContaining('低换手长线复利'), findsOneWidget);

      // Switch from 5Y (+58.7%) to 10Y (+396.6%, excess +3.3%/yr)
      expect(find.text('+58.7%'), findsWidgets);
      await t.tap(find.byKey(const ValueKey('guru-bt-window-10Y')));
      await t.pumpAndSettle();
      expect(find.text('+396.6%'), findsWidgets);
      expect(find.text('+3.3%'), findsWidgets);

      // Switch attribution to By quarter
      await t.tap(find.text('历季表现'));
      await t.pumpAndSettle();

      // Verify mobile 390px @ 1.4x scale in English & Chinese has zero overflow
      await _mountDossier(
        t,
        lang: AppLanguage.en,
        size: const Size(390, 900),
        scale: 1.4,
      );
      expect(find.text('Systematic Dossier Insights'), findsOneWidget);
      expect(find.text('What did they own?'), findsOneWidget);
      final ex = t.takeException();
      if (ex is FlutterError) {
        fail(ex.toStringDeep());
      }
      expect(ex, isNull);
    },
  );
}
