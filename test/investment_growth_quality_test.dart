import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';
import 'investment_explorer_test.dart' as fixture;
import 'investment_fundamentals_test.dart' as facts;

void main() {
  const rules = GrowthQualityRules();
  test(
    'growth-stage operating models share the quality gate; financials do not',
    () {
      for (final route in [
        'operating_company',
        'multi_method_growth',
        'revenue_stage',
        'financial',
        'customer_cash',
      ]) {
        final row = fixture.sampleRows().first;
        (row['valuation'] as Map)['modelRoute'] = route;
        expect(
          filterDiscoverCandidates([row], collection: 'growth').length,
          ['financial', 'customer_cash'].contains(route) ? 0 : 1,
          reason: route,
        );
      }
    },
  );
  test('persistent quality is not a high average or one strong year', () {
    final row = fixture.sampleRows().first;
    final years = (row['quality'] as Map)['years'] as List;
    years[0]['roic'] = 1.5;
    years[1]['roic'] = .14;
    final result = assessGrowthQuality(row, rules);
    expect(result.complete, isTrue);
    expect(result.mean, greaterThan(.15));
    expect(result.passes, isFalse);
    expect(result.passingYears, 4);
    expect(
      assessGrowthQuality(row, rules.copyWith(passingYears: 4)).passes,
      isTrue,
    );
    expect(filterDiscoverCandidates([row], collection: 'growth'), isEmpty);
    expect(
      filterDiscoverCandidates(
        [row],
        collection: 'growth',
        qualityRules: rules.copyWith(enabled: false),
      ),
      hasLength(1),
    );
  });
  test('missing, duplicate, skipped, stale and future years never pass', () {
    for (final kind in ['missing', 'duplicate', 'skipped', 'stale', 'future']) {
      final row = fixture.sampleRows().first;
      final q = row['quality'] as Map;
      final ys = q['years'] as List;
      if (kind == 'missing') ys[2]['roic'] = null;
      if (kind == 'duplicate') ys[2]['year'] = ys[1]['year'];
      if (kind == 'skipped') ys.removeAt(2);
      if (kind == 'stale') q['asOf'] = '2028-08-28';
      if (kind == 'future') ys[0]['availableAt'] = '2026-09-01';
      expect(assessGrowthQuality(row, rules).complete, isFalse, reason: kind);
      expect(assessGrowthQuality(row, rules).passes, isFalse, reason: kind);
    }
  });
  test('each enabled cash factor requires every year and valid data', () {
    final row = fixture.sampleRows().first;
    final ys = (row['quality'] as Map)['years'] as List;
    ys[2]['fcfMargin'] = -.01;
    expect(assessGrowthQuality(row, rules).passes, isTrue);
    expect(
      assessGrowthQuality(row, rules.copyWith(useFcf: true)).passes,
      isFalse,
    );
    ys[2]['cashConversion'] = null;
    expect(
      assessGrowthQuality(row, rules.copyWith(useCash: true)).complete,
      isFalse,
    );
    expect(
      assessGrowthQuality(
        row,
        rules.copyWith(useMargin: true, margin: .3),
      ).passes,
      isFalse,
    );
  });
  test('boundaries, windows, query round-trip and malformed inputs', () {
    final row = fixture.sampleRows().first;
    expect(
      assessGrowthQuality(row, rules.copyWith(roic: .2, years: 10)).passes,
      isTrue,
    );
    expect(rules.copyWith(years: 3).passingYears, 3);
    final copy = rules.copyWith(
      years: 10,
      passingYears: 8,
      roic: .175,
      useFcf: true,
      fcf: .075,
    );
    final restored = GrowthQualityRules.fromQuery(
      copy.query.map((k, v) => MapEntry(k, v ?? ''))
        ..removeWhere((k, v) => v.isEmpty),
    );
    expect(restored.query, copy.query);
    final bad = GrowthQualityRules.fromQuery({
      'qYears': '99',
      'qPass': '999',
      'qRoic': 'NaN',
      'qGrowth': '-1',
    });
    expect(bad.years, 5);
    expect(bad.passingYears, 5);
    expect(bad.roic, .15);
    expect(bad.growth, .15);
  });
  // Persisted quality-rule mathematics above remain covered. The old editable
  // cards were replaced by explicit server-side Fact OS threshold filters.
  for (final language in AppLanguage.values) {
    testWidgets(
      'current thresholds serialize percentages and clear without changing cutoff $language',
      (t) async {
        final api = facts.FundamentalApi();
        await facts.mount(t, api, language: language);
        await facts.tap(t, find.byKey(const ValueKey('fundamental-advanced')));
        for (final pair in [
          ('growth', 'minRevenueGrowth'),
          ('margin', 'minOperatingMargin'),
          ('fcf', 'minFcfMargin'),
        ]) {
          final dropdown = find.descendant(
            of: find.byKey(ValueKey('fund-filter-${pair.$1}')),
            matching: find.byType(DropdownButton<double?>),
          );
          await facts.tap(t, dropdown);
          await facts.tap(t, find.text('10%').last);
          final uri = Uri.parse(
            api.calls.lastWhere(
              (p) => Uri.parse(p).path.endsWith('/fundamentals'),
            ),
          );
          expect(uri.queryParameters[pair.$2], '0.1');
          expect(uri.queryParameters['asOf'], '2026-09-21');
        }
        await facts.tap(
          t,
          find.byKey(const ValueKey('fundamental-clear-thresholds')),
        );
        final uri = Uri.parse(
          api.calls.lastWhere(
            (p) => Uri.parse(p).path.endsWith('/fundamentals'),
          ),
        );
        for (final key in [
          'minRevenueGrowth',
          'minOperatingMargin',
          'minFcfMargin',
        ]) {
          expect(uri.queryParameters[key], isNull);
        }
        expect(find.byKey(const ValueKey('fund-row-UBER')), findsOneWidget);
        expect(api.saved, isFalse);
        expect(t.takeException(), isNull);
      },
    );
  }
}
