import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

Map<String, dynamic> stock() => {
  'ticker': 'TEST',
  'grossContribution': .00235,
  'costContribution': .00006,
  'netContribution': .00229,
  'lotAnalysis': {
    'status': 'available',
    'method': 'fifo-post-cost-v1',
    'realized': .002152,
    'unrealized': .000138,
    'reconciliation': {'difference': 0},
    'intervals': [
      for (var i = 0; i < 3; i++)
        {
          'id': 'test-$i',
          'buyDate': i == 0 ? '2023-12-01' : '2024-02-01',
          'buyPrice': i == 0 ? 9.0 : 20.0,
          'entryDate': i == 0 ? '2024-01-02' : '2024-02-01',
          'entryPrice': i == 0 ? 10.0 : 20.0,
          'exitDate': i == 2 ? '2024-04-01' : '2024-03-01',
          'exitPrice': i == 2 ? 25.0 : 30.0,
          'carriedIn': i == 0,
          'status': i == 2 ? 'open' : 'closed',
          'exitKind': i == 2 ? 'mark' : 'trim',
          'quantity': [10.0, 2.0, 3.0][i] / 100000,
          'entryValue': [100.0, 40.0, 60.0][i] / 100000,
          'exitValue': [300.0, 60.0, 75.0][i] / 100000,
          'costContribution': [3.5, 1.3, 1.2][i] / 100000,
          'netContribution': [196.5, 18.7, 13.8][i] / 100000,
          'returnOnBasis': [1.965, .4675, .23][i],
        },
    ],
  },
};

void main() {
  for (final language in AppLanguage.values) {
    for (final size in [const Size(1280, 720), const Size(390, 844)]) {
      testWidgets(
        'paired lots, range basis, open marks and navigation: $language $size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          String? opened;
          await tester.pumpWidget(
            LanguageScope(
              language: language,
              child: MaterialApp(
                theme: ThemeData.dark(),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => RuleTradeDetailDialog(
                          stock: stock(),
                          start: '2024-01-02',
                          end: '2024-04-01',
                          palette: Palette(false),
                          onCompany: (ticker) => opened = ticker,
                        ),
                      ),
                      child: const Text('Open fixture'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open fixture'));
          await tester.pumpAndSettle();
          final zh = language == AppLanguage.zh;
          expect(
            find.text(zh ? 'TEST · 持仓区间明细' : 'TEST · Holding intervals'),
            findsOneWidget,
          );
          expect(
            find.text(zh ? '已卖出部分 · 净盈亏' : 'Sold portions · net P&L'),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              zh ? '本段计价起点 2024-01-02' : 'range basis 2024-01-02',
            ),
            findsOneWidget,
          );
          await tester.ensureVisible(find.byKey(const ValueKey('lot-test-2')));
          await tester.pumpAndSettle();
          expect(
            find.textContaining(zh ? '期末估值，非卖出' : 'closing mark, not a sale'),
            findsOneWidget,
          );
          expect(find.textContaining('23.00%'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final dialogRect = tester.getRect(find.byType(Dialog));
          expect(dialogRect.left, greaterThanOrEqualTo(0));
          expect(dialogRect.right, lessThanOrEqualTo(size.width));
          final allText = tester
              .widgetList<Text>(find.byType(Text))
              .map((w) => w.data ?? '')
              .join(' ');
          if (!zh) {
            expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(allText), isFalse);
          }
          await tester.tap(find.text(zh ? '研究公司' : 'Research company'));
          await tester.pumpAndSettle();
          expect(opened, 'TEST');
          expect(find.byType(Dialog), findsNothing);
        },
      );
    }
  }
}
