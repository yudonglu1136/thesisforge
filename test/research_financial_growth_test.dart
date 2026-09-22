import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

void main() {
  Map<String, dynamic> quarter(
    int q,
    double? revenue, {
    String currency = 'USD',
  }) => {
    'fiscalperiod': '${q ~/ 4}-Q${q % 4 + 1}',
    'revenue': revenue,
    'currency': currency,
    'dps': 0.25,
  };

  test(
    'quarter comparison requires exact fiscal period including non-calendar fiscal years',
    () {
      final current = {...quarter(8104, 120), 'reportperiod': '2025-10-31'};
      final rows = [current, quarter(8102, 100), quarter(8100, 80)];
      expect(researchFinancialQuarterLabel(current), '2026 Q1');
      expect(researchFinancialPrior(current, rows, 1), isNull);
      expect(researchFinancialPrior(current, rows, 4)?['revenue'], 80);
      expect(
        researchFinancialPrior(current, [...rows, quarter(8100, 90)], 4),
        isNull,
      );
    },
  );

  test(
    'growth preserves missing zero negative and currency-mismatch bases',
    () {
      Map<String, dynamic> point(double? base, {String currency = 'USD'}) => {
        'kind': 'quarterly',
        'row': quarter(8104, 120),
        'yoy': {'row': quarter(8100, base, currency: currency)},
      };
      expect(
        researchFinancialGrowth(point(100), 'revenue', 'yoy').value,
        closeTo(.2, 1e-12),
      );
      expect(
        researchFinancialGrowth(point(null), 'revenue', 'yoy').reason,
        'missing_comparable_period',
      );
      for (final base in [0.0, -100.0]) {
        expect(
          researchFinancialGrowth(point(base), 'revenue', 'yoy').reason,
          'non_positive_base',
        );
      }
      expect(
        researchFinancialGrowth(
          point(100, currency: 'EUR'),
          'revenue',
          'yoy',
        ).reason,
        'currency_changed',
      );
      expect(
        researchFinancialGrowth(
          {...point(100), 'kind': 'annual'},
          'revenue',
          'qoq',
        ).reason,
        'quarterly_only',
      );
      expect(
        researchFinancialGrowth(
          {...point(100), 'row': quarter(8104, -20)},
          'revenue',
          'yoy',
        ).value,
        -1.2,
      );
    },
  );

  test(
    'TTM requires four consecutive quarters; dividends sum; no guessed shares',
    () {
      final rows = [for (var i = 0; i < 4; i++) quarter(8104 - i, 100.0 + i)];
      final ttm = {'kind': 'ttm', 'rows': rows, 'row': rows.first};
      expect(researchFinancialReportedValue(ttm, 'revenue'), 406);
      expect(researchFinancialReportedValue(ttm, 'dps'), 1);
      expect(researchFinancialReportedValue(ttm, 'shareswadil'), isNull);
      expect(
        researchFinancialReportedValue({
          ...ttm,
          'rows': [rows[0], rows[2], rows[3], quarter(8100, 50)],
        }, 'revenue'),
        isNull,
      );
      expect(
        researchFinancialReportedValue({
          ...ttm,
          'rows': [
            rows[0],
            rows[1],
            rows[2],
            quarter(8101, 50, currency: 'EUR'),
          ],
        }, 'revenue'),
        isNull,
      );
      expect(
        researchFinancialReportedValue({
          ...ttm,
          'rows': rows.take(3).toList(),
        }, 'revenue'),
        isNull,
      );
    },
  );
}
