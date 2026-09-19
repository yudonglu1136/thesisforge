"""Render the already-verified PIT replays as a standalone static image."""
import datetime as dt
import argparse
import csv
import hashlib
import importlib.util
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline30',type=Path,default=ROOT / 'output/fundamental-pit-top10-20260911/full-price-result.json')
parser.add_argument('--comparison50',type=Path,default=ROOT / 'output/fundamental-pit-top10-premium50-20260911/full-price-result.json')
parser.add_argument('--three-only', action='store_true', help='Only unfiltered, 30%% and 50%% full-pool, fully-invested portfolios')
parser.add_argument('--output-dir', type=Path)
args=parser.parse_args()
OLD,NEW=args.baseline30,args.comparison50
OUT = args.output_dir or NEW.parent
old, new = (json.loads(p.read_text()) for p in (OLD, NEW))
for file in (OLD, NEW):
    assert json.loads((file.parent / 'verification.json').read_text())['status'] == 'pass'
assert old['source']['selectionHash'] == new['source']['selectionHash']
assert old['variants']['unfiltered']['equity'] == new['variants']['unfiltered']['equity']
OUT.mkdir(parents=True, exist_ok=True)
checks = []
if args.three_only:
    assert old['rules']['maxPremium'] == .3 and new['rules']['maxPremium'] == .5
    common_rules = {k:v for k,v in old['rules'].items() if k != 'maxPremium'}
    assert common_rules == {k:v for k,v in new['rules'].items() if k != 'maxPremium'}
    spec = importlib.util.spec_from_file_location('independent_metrics', ROOT / 'scripts/verify-fundamental-pit-experiment.py')
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    holdings = []
    for name, result, variant_key in [('No exclusion', new, 'unfiltered'), ('Exclude >30%', old, 'filterBeforeRanking'), ('Exclude >50%', new, 'filterBeforeRanking')]:
        variant = result['variants'][variant_key]
        assert variant['status'] == 'ready' and not result['validation']['priceGaps']
        computed = verifier.metrics(variant['equity'], 'value')
        assert all(abs(v - variant['metrics'][k]) < 1e-10 for k,v in computed.items())
        assert variant['independentLedgerMaxDifference'] < 1e-9
        for snapshot in result['snapshots']:
            positions = snapshot[variant_key]
            assert 1 <= len(positions) <= result['rules']['topN']
            assert abs(sum(p['weight'] for p in positions) - 1) < 1e-12
            assert all(abs(p['weight'] - 1 / len(positions)) < 1e-12 for p in positions)
            evidence = {r['ticker']: r for r in snapshot['allEligibleValuations']}
            ranked = sorted(evidence.values(), key=lambda r: (-r['metrics']['revenueGrowth'], -r['worstRoic'], r['ticker']))
            if variant_key != 'unfiltered':
                ranked = [r for r in ranked if r['valuationDecision']['status'] == 'eligible']
            assert [p['ticker'] for p in positions] == [r['ticker'] for r in ranked[:result['rules']['topN']]]
            for p in positions:
                row = evidence[p['ticker']]
                assert not row['reasons'] and row['availableAt'] <= snapshot['decisionDate'] < snapshot['executionDate']
                assert row['metrics']['revenueGrowth'] >= .15 - 1e-10
                assert row['metrics']['operatingMargin'] >= .1 - 1e-10
                assert row['metrics']['fcfMargin'] >= .05 - 1e-10
                assert len(row['annualQuality']) == 5
                assert all(y['availableAt'] <= snapshot['decisionDate'] and y['roic'] >= .15 - 1e-10 for y in row['annualQuality'])
                valuation = row['valuationDecision']
                if variant_key != 'unfiltered':
                    assert valuation['modelDate'] <= snapshot['decisionDate']
                    assert valuation['priceDate'] == snapshot['decisionDate']
                    premium = valuation['price'] / valuation['fairValue'] - 1
                    assert abs(premium - valuation['premium']) < 1e-12
                    assert premium <= result['rules']['maxPremium'] + 1e-10
                holdings.append({'strategy':name, 'execution_date':snapshot['executionDate'], 'decision_date':snapshot['decisionDate'],
                                 'ticker':p['ticker'], 'weight':p['weight'], 'cash_weight':0,
                                 'premium':valuation.get('premium'), 'model_date':valuation.get('modelDate')})
        counts = [len(s[variant_key]) for s in result['snapshots']]
        checks.append({'strategy':name, 'quarters':len(counts), 'cash_target':0, 'min_holdings':min(counts),
                       'max_holdings':max(counts), 'average_holdings':sum(counts)/len(counts), 'metrics':computed})
    with (OUT / 'fully-invested-quarterly-holdings.csv').open('w', newline='') as stream:
        writer=csv.DictWriter(stream, fieldnames=list(holdings[0]));writer.writeheader();writer.writerows(holdings)

BG, FG, MUTED, GRID = '#0D1820', '#F2F6F8', '#A6B9C5', '#29404D'
plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 12,
                     'text.color': FG, 'axes.labelcolor': MUTED,
                     'xtick.color': MUTED, 'ytick.color': MUTED,
                     'axes.facecolor': BG, 'figure.facecolor': BG,
                     'path.simplify': False, 'svg.fonttype': 'none'})
configs = [
    ('Unfiltered Top 10', new, 'unfiltered', 'value', '#43D9B4', '-', '9.95'),
    ('30% ceiling · refill', old, 'filterBeforeRanking', 'value', '#9AA8C6', (0, (3, 2)), '6.78'),
    ('50% ceiling · refill', new, 'filterBeforeRanking', 'value', '#65B8FF', '-', '8.23'),
    ('50% ceiling · survivors only', new, 'filtered', 'value', '#F5B75D', '-', '4.68'),
    ('SPY', new, 'unfiltered', 'spy', '#E4E8EC', (0, (6, 3)), '1.00'),
]
if args.three_only:
    configs = [
        ('No valuation exclusion', new, 'unfiltered', 'value', '#43D9B4', '-', None),
        ('Exclude premium >30%', old, 'filterBeforeRanking', 'value', '#F5B75D', (0, (3, 2)), None),
        ('Exclude premium >50%', new, 'filterBeforeRanking', 'value', '#65B8FF', (0, (7, 3)), None),
    ]
configs = [(name, result, key, field, color, style,
            '1.00' if field == 'spy' else f"{sum(len(s[key]) for s in result['snapshots']) / len(result['snapshots']):.2f}")
           for name,result,key,field,color,style,_ in configs]
fig = plt.figure(figsize=(16, 10), dpi=180)
fig.text(.055, .958, 'THESISFORGE / RESEARCH REPLAY', fontsize=11, color='#43D9B4', weight='bold')
fig.text(.055, .911, 'PIT Top 10 · Fully invested' if args.three_only else 'PIT Top 10 · Valuation filter comparison', fontsize=27, weight='bold')
period=new['variants']['unfiltered']['equity']
start_label=dt.date.fromisoformat(period[0]['date']).strftime('%d %b %Y')
end_label=dt.date.fromisoformat(period[-1]['date']).strftime('%d %b %Y')
fig.text(.055, .877, f'{start_label} – {end_label}  |  Quarterly rebalancing  |  10 bps per side  |  Sharpe Rf = 0%',
         fontsize=12, color=MUTED)
ax = fig.add_axes([.073, .439, .82, .347])
handles, summaries = [], []
date_keys = None
for name, result, key, field, color, linestyle, mean_holdings in configs:
    variant = result['variants'][key]
    assert variant['status'] == 'ready'
    rows = variant['equity']
    keys = [r['date'] for r in rows]
    if date_keys is None:
        date_keys = keys
    assert keys == date_keys and len(keys) == len(period)
    dates = [dt.date.fromisoformat(d) for d in keys]
    values = [r[field] for r in rows]
    metrics = variant['spyMetrics'] if field == 'spy' else variant['metrics']
    assert abs(values[-1] - metrics['endingValue']) < 1e-12
    ax.plot(dates, values, color=color, linewidth=1.65, linestyle=linestyle, label=name)
    ax.plot(dates[-1], values[-1], 'o', color=color, markersize=4)
    ax.annotate(f'{values[-1]:.2f}×', (dates[-1], values[-1]), xytext=(12, 0),
                textcoords='offset points', color=color, fontsize=11.5, va='center', weight='bold')
    handles.append(Line2D([0], [0], color=color, linestyle=linestyle, linewidth=2))
    summaries.append((name, color, linestyle, metrics, mean_holdings))
fig.legend(handles, [c[0] for c in configs], loc='center left',
           bbox_to_anchor=(.055, .829), ncol=3, frameon=False,
           fontsize=11, columnspacing=2.4, handlelength=2.5)
ax.set_xlim(dates[0], dates[-1])
if args.three_only:
    maximum = max(r['value'] for _,result,key,*_ in configs for r in result['variants'][key]['equity'])
    ceiling = (int(maximum / 2) + 1) * 2
    ax.set_ylim(0, ceiling)
    ax.set_yticks(range(0, ceiling + 1, 2), [f'{v}×' if v else '0' for v in range(0, ceiling + 1, 2)])
else:
    ax.set_ylim(0, 20)
    ax.set_yticks([0, 5, 10, 15, 20], ['0', '5×', '10×', '15×', '20×'])
ticks = [dates[0], dt.date(2019, 1, 1), dt.date(2021, 1, 1), dt.date(2023, 1, 1),
         dt.date(2025, 1, 1), dates[-1]]
ax.set_xticks(ticks, [start_label, '2019', '2021', '2023', '2025', end_label])
ax.tick_params(axis='both', length=0, pad=10, labelsize=10.5)
ax.grid(axis='y', color=GRID, linewidth=.6)
ax.set_axisbelow(True)
ax.spines[['top', 'right']].set_visible(False)
for side in ('left', 'bottom'):
    ax.spines[side].set_color(GRID)
ax.set_title('NET PORTFOLIO VALUE  /  Initial capital = 1', loc='left', fontsize=10, color=MUTED, pad=10)

# Exact-value table uses the same identity colors and line styles as the curves.
cols = [.074, .49, .61, .755, .90]
headers = ['MODEL / ALLOCATION', 'CAGR', 'SHARPE', 'MAX DRAWDOWN', 'AVG. HOLDINGS']
for i, (x, label) in enumerate(zip(cols, headers)):
    fig.text(x, .354, label, fontsize=10, color=MUTED, ha='left' if i == 0 else 'right')
fig.lines.append(Line2D([.055, .937], [.338, .338], transform=fig.transFigure, color=GRID, linewidth=.8))
for i, (name, color, linestyle, metrics, mean_holdings) in enumerate(summaries):
    y = .310 - i * .038
    fig.lines.append(Line2D([.057, .069], [y + .005, y + .005], transform=fig.transFigure,
                            color=color, linestyle=linestyle, linewidth=2))
    texts = [name, f"{metrics['cagr']:.2%}", f"{metrics['sharpeZeroRf']:.2f}",
             f"{metrics['maxDrawdown']:.2%}", mean_holdings]
    for j, (x, label) in enumerate(zip(cols, texts)):
        fig.text(x, y, label, fontsize=12, ha='left' if j == 0 else 'right',
                 color=color if j == 0 else FG, weight='bold' if j == 1 else 'normal')
if args.three_only:
    fig.text(.055, .179, '100% STOCKS  /  0% CASH  /  NO CTA OR LEVERAGE', fontsize=12, color='#43D9B4', weight='bold')
    fig.text(.055, .146, 'Each quarter: apply the valuation ceiling to the quality-qualified pool, rank, then hold up to 10 equally.', fontsize=10.5, color=MUTED)
    fig.text(.055, .122, 'Premium = price / dated model value − 1. Fewer than 10 qualify? Invest all capital in those remaining.', fontsize=10.5, color=MUTED)
    fig.text(.055, .098, 'The filtered portfolios can hold just one stock. Trading costs are deducted before fully allocating the remainder.', fontsize=10.5, color='#F5B75D')
    fig.text(.055, .074, 'Quality: revenue YoY ≥15%; operating margin ≥10%; FCF margin ≥5%; pre-tax ROIC ≥15% in each of 5 years.', fontsize=10.5, color=MUTED)
else:
    fig.text(.055, .110, 'Ceiling = price / dated fair value − 1. Refill: filter the eligible pool, then select up to 10.', fontsize=10.5, color=MUTED)
    fig.text(.055, .087, 'Survivors only: filter the original Top 10 and reweight the remainder. Both 50% variants held only SNPS in 2024 Q2.', fontsize=10.5, color='#F5B75D')
fig.text(.055, .048 if args.three_only else .055, 'Retrospective PIT research · Current-coverage / survivorship bias · Not a fresh out-of-sample test',
         fontsize=10.5, color=MUTED)
source_note=('Sources: frozen PIT ledger and decision quotes; refreshed Yahoo returns; retired EA uses full SEP history. No Jansen DCF / ML.'
             if new['source'].get('refreshedPrices') else
             'Sources: frozen financial/valuation ledger, local SEP prices and SPY adjusted closes. Jansen DCF / ML are not included.')
fig.text(.055, .024 if args.three_only else .032, source_note,
         fontsize=10, color=MUTED)

fig.canvas.draw()
# Check figure-coordinate text remains fully inside the export.
renderer = fig.canvas.get_renderer()
width, height = fig.canvas.get_width_height()
for text in fig.texts:
    bounds = text.get_window_extent(renderer)
    assert bounds.x0 >= 0 and bounds.y0 >= 0 and bounds.x1 <= width and bounds.y1 <= height, text.get_text()
for suffix in ('png', 'svg'):
    fig.savefig(OUT / f'pit-top10-premium-comparison.{suffix}', dpi=180, facecolor=BG)
receipt = {'inputs': {p.name + ':' + p.parent.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (OLD, NEW)},
           'observations_per_line': len(date_keys), 'period': [date_keys[0], date_keys[-1]],
           'series': [c[0] for c in configs], 'interpolation': False, 'smoothing': False,
           'output': 'pit-top10-premium-comparison.png'}
if args.three_only:
    receipt.update({'allocation':'Filter the PIT quality-qualified pool, rank, select up to 10; equal-weight 100% of post-cost capital; zero cash.',
                    'checks':checks, 'verification':'pass', 'rules':common_rules | {'allocation':'equal_weight_filter_pool_then_rank_no_cash'},
                    'source_validation_receipts':[str(p.parent / 'verification.json') for p in (OLD,NEW)]})
    with (OUT / 'fully-invested-equity.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['date', 'no_exclusion_net', 'exclude_above_30_net', 'exclude_above_50_net'])
        curves = [result['variants'][key]['equity'] for _,result,key,*_ in configs]
        writer.writerows([date, *[curve[i]['value'] for curve in curves]] for i,date in enumerate(date_keys))
(OUT / 'chart-provenance.json').write_text(json.dumps(receipt, indent=2))
print(OUT / 'pit-top10-premium-comparison.png')
