"""Independently verify replay metrics and export reviewable quarter ledgers."""
import csv
import datetime as dt
import json
import math
import statistics
import sys
from pathlib import Path


def metrics(rows, field):
    values = [r[field] for r in rows]
    assert all(math.isfinite(v) and v > 0 for v in values)
    returns = [b / a - 1 for a, b in zip(values, values[1:])]
    elapsed = (dt.date.fromisoformat(rows[-1]['date']) - dt.date.fromisoformat(rows[0]['date'])).days
    peak, drawdown = 1.0, 0.0
    for value in values:
        peak = max(peak, value)
        drawdown = min(drawdown, value / peak - 1)
    return {'totalReturn': values[-1] - 1, 'cagr': values[-1] ** (365.25 / elapsed) - 1,
            'maxDrawdown': drawdown, 'volatility': statistics.stdev(returns) * math.sqrt(252),
            'sharpeZeroRf': statistics.mean(returns) / statistics.stdev(returns) * math.sqrt(252)}


def write_csv(file, rows):
    if not rows:
        return
    with file.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else 'output/fundamental-pit-top10-20260911')
    data = json.loads((directory / 'full-price-result.json').read_text())
    assert not data['validation']['priceGaps']
    assert data['validation']['allSourcesBeforeDecision']
    assert data['validation']['zeroCashTargets']
    checks, holdings, exclusions, summary = {}, [], [], []
    for key, variant in data['variants'].items():
        if variant['status'] != 'ready':
            continue
        for field, expected in [('value', variant['metrics']), ('spy', variant['spyMetrics'])]:
            computed = metrics(variant['equity'], field)
            differences = {k: abs(v - expected[k]) for k, v in computed.items()}
            assert max(differences.values()) < 1e-10, differences
            checks[f'{key}/{field}'] = differences
        assert variant['independentLedgerMaxDifference'] < 1e-9
        dates = [r['date'] for r in variant['equity']]
        assert dates == sorted(set(dates))
        assert dates[-1] == data['rules']['end']
    for snapshot in data['snapshots']:
        date, decision = snapshot['executionDate'], snapshot['decisionDate']
        assert decision < date
        assert snapshot['eligibleCount'] >= len(snapshot['top'])
        assert [r['metrics']['revenueGrowth'] for r in snapshot['top']] == sorted(
            [r['metrics']['revenueGrowth'] for r in snapshot['top']], reverse=True)
        evidence = {r['ticker']: r for r in snapshot['allEligibleValuations']}
        for variant in ['unfiltered', 'filtered', 'filterBeforeRanking']:
            for position in snapshot[variant]:
                r = evidence[position['ticker']]
                m, val = r['metrics'], r['valuationDecision']
                assert not r['reasons'] and r['availableAt'] <= decision
                assert m['revenueGrowth'] >= .15 - 1e-10
                assert m['operatingMargin'] >= .10 - 1e-10
                assert m['fcfMargin'] >= .05 - 1e-10
                assert len(r['annualQuality']) == 5
                assert all(y['roic'] >= .15 - 1e-10 and y['availableAt'] <= decision for y in r['annualQuality'])
                if variant != 'unfiltered':
                    assert val['status'] == 'eligible' and val['premium'] <= data['rules']['maxPremium'] + 1e-10
                holdings.append({'execution_date': date, 'decision_date': decision, 'variant': variant,
                                 'ticker': r['ticker'], 'weight': position['weight'],
                                 'quarterly_revenue_yoy': m['revenueGrowth'], 'ttm_operating_margin': m['operatingMargin'],
                                 'ttm_fcf_margin': m['fcfMargin'], 'worst_5y_pretax_roic': r['worstRoic'],
                                 'financial_public_date': r['availableAt'], 'price': val.get('price'),
                                 'fair_value': val.get('fairValue'), 'premium': val.get('premium'),
                                 'model_date': val.get('modelDate'), 'model_version': r['source']['modelVersion']})
        for r in snapshot['exclusions']:
            v = r['valuationDecision']
            exclusions.append({'execution_date': date, 'decision_date': decision, 'ticker': r['ticker'],
                               'reason': v['status'], 'price': v.get('price'), 'fair_value': v.get('fairValue'),
                               'premium': v.get('premium'), 'threshold': data['rules']['maxPremium'], 'model_date': v.get('modelDate')})
        summary.append({'execution_date': date, 'decision_date': decision,
                        'factor_eligible': snapshot['eligibleCount'], 'top10_count': len(snapshot['unfiltered']),
                        'same_top10_filtered_count': len(snapshot['filtered']),
                        'filter_then_rank_count': len(snapshot['filterBeforeRanking']),
                        'top10_tickers': ' '.join(p['ticker'] for p in snapshot['unfiltered']),
                        'filter_then_rank_tickers': ' '.join(p['ticker'] for p in snapshot['filterBeforeRanking'])})
    write_csv(directory / 'quarterly-holdings.csv', holdings)
    write_csv(directory / 'filtered-stocks.csv', exclusions)
    write_csv(directory / 'quarterly-summary.csv', summary)
    verification = {'status': 'pass', 'quarters': len(summary), 'holding_rows': len(holdings),
                    'exclusion_rows': len(exclusions), 'independent_metric_differences': checks,
                    'no_missing_held_prices': True, 'no_cash_targets': True,
                    'sources_available_before_trade': True,
                    'limitation': 'This verifies implementation and supplied inputs, not historical-universe completeness or model investment validity.'}
    (directory / 'verification.json').write_text(json.dumps(verification, indent=2))
    print(json.dumps(verification, indent=2))


if __name__ == '__main__':
    main()
