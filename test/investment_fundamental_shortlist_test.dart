import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

void main() {
  test('legacy saved advanced filters remain null-safe during migration', () {
    const rules = FundamentalRules();
    final complete = {
      'metrics': {
        'revenueGrowth': .15,
        'operatingMargin': .10,
        'fcfMargin': .05,
      },
    };
    final missing = {
      'metrics': {
        'revenueGrowth': .15,
        'operatingMargin': .10,
        'fcfMargin': null,
      },
    };
    expect(rules.accepts(complete), true);
    expect(rules.check(missing)['cash'], null);
    expect(rules.accepts(missing), false);
    expect(rules.copyWith(requireAll: false).accepts(missing), true);
  });

  test('restored rules reject invalid bounds and unknown factors', () {
    final restored = FundamentalRules.restore({
      'growth': -1,
      'margin': double.infinity,
      'years': 4,
      'factors': ['growth', 'fake'],
      'requireAll': false,
    });
    expect(restored.growth, .15);
    expect(restored.margin, .1);
    expect(restored.years, 5);
    expect(restored.factors, {'growth'});
    expect(FundamentalRules.restore(restored.json).json, restored.json);
  });

  test(
    'compatibility filter preserves unknown values instead of zero filling',
    () {
      final rows = <Map<String, dynamic>>[
        {
          'ticker': 'KNOWN',
          'name': 'Known Co',
          'screens': ['cash'],
          'metrics': {'revenueGrowth': .2},
          'changes': {'fcfMargin': .02},
          'modelGap': .1,
        },
        {
          'ticker': 'UNKNOWN',
          'name': 'Unknown Co',
          'screens': <String>[],
          'metrics': {'revenueGrowth': null},
          'changes': {'fcfMargin': null},
          'modelGap': null,
        },
      ];
      expect(
        filterFundamentals(rows, screen: 'cash').single['ticker'],
        'KNOWN',
      );
      expect(
        filterFundamentals(rows, belowValue: true).single['ticker'],
        'KNOWN',
      );
      expect(filterFundamentals(rows).map((row) => row['ticker']), [
        'KNOWN',
        'UNKNOWN',
      ]);
    },
  );
}
