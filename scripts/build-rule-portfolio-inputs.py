#!/usr/bin/env python3
"""Reconstruct the selected, existing research rules on immutable Fact OS inputs.

No provider fetch, source write, forward-return selection, or database copy. The
feature adapter is the versioned original Ackman/common-cohort implementation.
All inputs are explicit so a production build never depends on /private/tmp.
"""
import argparse
from datetime import date
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fact_os.repository import FactRepository

def digest(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def history_window(frame, start='2013-01-01'):
    if date.fromisoformat(start).isoformat() != start:
        raise ValueError('invalid_history_start')
    result = frame[frame.entry.ge(start)].copy()
    if result.empty:
        raise ValueError('empty_history_window')
    return result

def require_quarter_coverage(expected, actual):
    missing = sorted(set(expected) - set(actual))
    if missing:
        raise ValueError('candidate_history_incomplete:' + ','.join(missing))

def build(a):
    metadata = json.loads(a.metadata.read_text())
    if digest(a.panel) != metadata['panelSha256']:
        raise ValueError('panel_fingerprint_mismatch')
    screen = json.loads(a.candidates.read_text())
    if screen['lineage']['generation'] != metadata['factGeneration']:
        raise ValueError('candidate_generation_mismatch')
    spec = importlib.util.spec_from_file_location('original_selector', a.adapter)
    adapter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(adapter)
    d = pd.read_csv(a.panel, usecols=lambda c: c not in adapter.FORBIDDEN,
                    keep_default_na=False, na_values=[''], low_memory=False)
    d = history_window(d, a.start)
    if d.duplicated(['q', 'ticker']).any():
        raise ValueError('duplicate_security_quarter')
    features, cols = adapter.build_features(d.copy())
    common = features[features.common_feature_complete].copy()
    for key in cols['ackman']:
        common['pct_' + key] = common.groupby('q')[key].rank(method='average', pct=True)
    weights = [ .4/3, .4/3, .4/3, .15, .15, .15, .15 ]
    common['score'] = sum(w * common['pct_' + key] for key, w in zip(cols['ackman'], weights))

    quality = pd.DataFrame(screen['candidates']).rename(columns={
        'quarter': 'q', 'revenueYoY': 'revenue_yoy', 'operatingMargin': 'opmargin',
        'fcfMargin': 'fcfmargin', 'roicMin5Y': 'roic_min5'})
    require_quarter_coverage(d.q.unique(), quality.q.unique())
    # Only beta is reused; quality percentiles and the selected variant are recomputed.
    quality = quality[['q', 'ticker', 'beta', 'roic_min5']].merge(d, on=['q', 'ticker'], validate='one_to_one')
    rates = pd.read_csv(a.rates)
    rates['DGS10'] = pd.to_numeric(rates.DGS10, errors='coerce') / 100
    rates = rates.dropna().sort_values('observation_date')
    for q, group in quality.groupby('q'):
        signal = group.signal_date.iloc[0]
        eligible_rates = rates[rates.observation_date.le(signal)]
        if eligible_rates.empty:
            raise ValueError('missing_prior_risk_free_rate')
        quality.loc[group.index, 'risk_free'] = eligible_rates.DGS10.iloc[-1]
    equity, debt = quality.cap_m, quality.ttm_debt.abs() * quality.ttm_fxusd / 1e6
    debt_cost = pd.concat([quality.ttm_intexp.abs() / quality.ttm_debt.abs().replace(0, np.nan),
                           quality.risk_free + .015], axis=1).max(axis=1).clip(upper=.15)
    quality['wacc'] = equity / (equity + debt) * (quality.risk_free + quality.beta.clip(.5, 2) * .05) + \
        debt / (equity + debt) * debt_cost * .79
    quality_cols = ['revenue_yoy', 'opmargin', 'fcfmargin', 'roic_min5']
    for key in quality_cols:
        quality['pct_' + key] = quality.groupby('q')[key].rank(method='average', pct=True)
    quality['score'] = quality[['pct_' + k for k in quality_cols]].mean(axis=1)
    quality['eligible'] = quality.revenue_yoy.gt(.08) & quality.opmargin.ge(.10) & quality.fcfmargin.ge(.05) & \
        quality.roic_min5.ge(.10) & quality.roic_verified.gt(quality.wacc)

    original = json.loads(a.schedule.read_text())
    if 'rebalances' in original:
        frozen = [r for r in original['rebalances'] if r['model'] == 'aihf_rank_sqrt_top10_cap15']
    else:
        frozen = [*original['pre']['aihf_rank_sqrt_top10_cap15_pre2023'],
                  *original['post']['aihf_rank_sqrt_top10_cap15']]
    schedules = {'quality_rank': [], 'ackman': []}
    for model, frame, keys, component_weights, mask in [
        ('quality_rank', quality, quality_cols, [.25]*4, 'eligible'),
        ('ackman', common, cols['ackman'], weights, 'ackman_style_gate')]:
        for q, group in frame.groupby('q', sort=True):
            ranked = group[group[mask]].sort_values(
                ['score', 'beta', 'ticker'] if model == 'quality_rank' else ['score', 'ticker'],
                ascending=[False, True, True] if model == 'quality_rank' else [False, True])
            selected = ranked.head(10 if model == 'quality_rank' else 20)
            clock = group.iloc[0]
            positions = []
            for rank, (_, r) in enumerate(selected.iterrows(), 1):
                source_dates = {key: str(r[key]) for key in ['ttm_date', 'q0_date', 'q4_date',
                                *[f'y{i}_date' for i in range(5)]]}
                if any(value > q for value in source_dates.values()):
                    raise ValueError('future_financial_publication')
                positions.append(dict(ticker=r.ticker, permaticker=str(r.permaticker), rank=rank,
                    score=float(r.score), beta=float(r.beta) if model == 'quality_rank' else None,
                    wacc=float(r.wacc) if model == 'quality_rank' else None,
                    pretaxReturn=float(r.roic_verified), sourceDates=source_dates,
                    sourcePeriods={key: str(r[key]) for key in ['ttm_reportperiod', 'q0_reportperiod', 'y0_reportperiod']},
                    inputs=[dict(id=key, value=float(r[key]), percentile=float(r['pct_' + key]),
                                 weight=w, contribution=float(r['pct_' + key])*w)
                            for key, w in zip(keys, component_weights)]))
            record = dict(quarter=q, signalDate=clock.signal_date, executionDate=clock.entry,
                          nextExecutionDate=None if pd.isna(clock.next_entry) else clock.next_entry,
                          eligibleCount=len(ranked), populationCount=len(group), positions=positions)
            if model == 'quality_rank':
                prior = next((r for r in frozen if r['reportDate'] == q), None)
                if prior is not None:
                    ordered = sorted(prior['targetWeights'], key=lambda r: -r['weight'])
                    if [p['ticker'] for p in positions] != [p['ticker'] for p in ordered]:
                        raise ValueError('quality_rank_changed_from_requested_research')
                    # Actions come from the separately reviewed, adjusted-unit
                    # ledger. A research schedule can contain rounded vendor
                    # ratios or legal dates which are not executable sessions.
            schedules[model].append(record)

    for rows in schedules.values():
        require_quarter_coverage(d.q.unique(), [q['quarter'] for q in rows])

    a.output.mkdir(parents=True, exist_ok=True)
    with FactRepository(a.fact_root) as repo:
        if repo.generation != metadata['factGeneration']:
            raise ValueError('fact_generation_mismatch')
        # Bounded selected symbols, not the whole price database. Readers use pinned Parquet.
        tickers = sorted({p['ticker'] for rows in schedules.values() for q in rows for p in q['positions']})
        actions = json.loads(a.actions.read_text())
        if actions['generation'] != repo.generation:
            raise ValueError('action_generation_mismatch')
        tickers += [r['corporateAction']['successorTicker'] for r in actions['actions']
                    if r['ticker'] in tickers and r['corporateAction']['considerationType'] in ('stock','stock_and_cash')]
        start = min(q['executionDate'] for rows in schedules.values() for q in rows)
        end = metadata['priceCutoff']
        prices = repo.db.execute('''SELECT ticker,cast(date AS VARCHAR) date,closeadj FROM stocks
            WHERE ticker IN (SELECT * FROM unnest(?)) AND date BETWEEN ? AND ?
            UNION ALL SELECT ticker,cast(date AS VARCHAR),closeadj FROM funds
            WHERE ticker='SPY' AND date BETWEEN ? AND ? ORDER BY ticker,date''',
            [tickers, start, end, start, end]).fetchdf()
        if prices.duplicated(['ticker', 'date']).any() or not np.isfinite(prices.closeadj).all() or prices.closeadj.le(0).any():
            raise ValueError('invalid_observed_prices')
        for q in schedules['quality_rank']:
            for action in q.get('actions', []):
                if action['considerationType'] != 'cash':
                    raise ValueError('unaudited_quality_corporate_action')
                basis = repo.db.execute('''SELECT closeadj/closeunadj FROM stocks WHERE ticker=? AND date<?
                    AND closeadj>0 AND closeunadj>0 ORDER BY date DESC LIMIT 1''',
                    [action['ticker'], action['effectiveDate']]).fetchone()
                if not basis:
                    raise ValueError('missing_action_price_basis')
                action['terminalCashEntitlementPerShare'] *= basis[0]
                action['adjustedUnitFactor'] = basis[0]
        prices.to_csv(a.output / 'prices.csv', index=False)
    receipt = {key: digest(value) for key, value in vars(a).items()
               if isinstance(value, Path) and value.is_file()}
    receipt.update(sourceGeneration=metadata['factGeneration'], sourceWrites=False,
                   requestedStart=a.start, forwardOutcomeColumnsRead=False,
                   priceSha256=digest(a.output/'prices.csv'), builder=digest(__file__))
    payload = dict(schedules=schedules, actions=actions['actions'], lineage=receipt)
    (a.output/'inputs.json').write_text(json.dumps(payload, allow_nan=False, separators=(',', ':')))
    print(json.dumps(dict(status='ready', quarters={k: len(v) for k,v in schedules.items()},
                         selectedSymbols=len(set(tickers)), prices=len(prices), sourceWrites=False)))

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    for name in ['panel', 'metadata', 'candidates', 'rates', 'adapter', 'schedule', 'actions', 'fact-root', 'output']:
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--start', default='2013-01-01')
    build(p.parse_args())
