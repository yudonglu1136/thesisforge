"""Extend the existing quality candidate population without changing its policy.

Only past 253 SPY sessions are used for beta, with the original >=200 matched
return observation requirement. This is the published policy, not a new ranking
method. Retain the explicit current-vintage/current-classification limitation.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fact_os.repository import FactRepository


def build(a):
    metadata = json.loads(a.metadata.read_text())
    if hashlib.sha256(a.panel.read_bytes()).hexdigest() != metadata['panelSha256']:
        raise ValueError('panel_fingerprint_mismatch')
    roics = [f'y{i}_roic_verified' for i in range(5)]
    cols = ['q', 'ticker', 'signal_date', 'entry', 'revenue_yoy', 'opmargin', 'fcfmargin',
            'q_chain5_valid', 'annual_chain5_valid', 'ttm_age_days', 'annual_age_days', *roics]
    data = pd.read_csv(a.panel, usecols=cols)
    data = data[data.entry.ge(a.start)].copy()
    data['roic_min5'] = data[roics].min(axis=1, skipna=False)
    data = data[data[['revenue_yoy', 'opmargin', 'fcfmargin', 'roic_min5']].notna().all(axis=1)
                & data.q_chain5_valid.eq(True) & data.annual_chain5_valid.eq(True)
                & data.ttm_age_days.between(0, 180) & data.annual_age_days.between(0, 550)]
    result = []
    with FactRepository(a.fact_root) as repo:
        if repo.generation != metadata['factGeneration']:
            raise ValueError('fact_generation_mismatch')
        for q, group in data.groupby('q', sort=True):
            if group.signal_date.nunique() != 1:
                raise ValueError('ambiguous_signal_date')
            rows = repo.db.execute('''
                WITH calendar AS (
                    SELECT date,closeadj spy_close FROM funds
                    WHERE ticker='SPY' AND date<=? AND closeadj>0
                    ORDER BY date DESC LIMIT 253
                ), aligned AS (
                    SELECT s.ticker,c.date,s.closeadj stock_close,c.spy_close
                    FROM calendar c JOIN stocks s USING(date)
                    WHERE s.ticker IN (SELECT * FROM unnest(?)) AND s.closeadj>0
                ), returns AS (
                    SELECT ticker,date,
                      stock_close/lag(stock_close) OVER(PARTITION BY ticker ORDER BY date)-1 stock_return,
                      spy_close/lag(spy_close) OVER(PARTITION BY ticker ORDER BY date)-1 market_return
                    FROM aligned
                ) SELECT ticker,regr_slope(stock_return,market_return) beta,count(*) n
                  FROM returns WHERE isfinite(stock_return) AND isfinite(market_return)
                  GROUP BY ticker HAVING count(*)>=200 AND isfinite(regr_slope(stock_return,market_return))
                  ORDER BY ticker
            ''', [group.signal_date.iloc[0], sorted(group.ticker.unique())]).fetchall()
            betas = {t: (float(b), int(n)) for t, b, n in rows}
            for r in group.sort_values('ticker').itertuples():
                if r.ticker in betas:
                    result.append(dict(quarter=q, ticker=r.ticker, beta=betas[r.ticker][0],
                                       betaObservations=betas[r.ticker][1], roicMin5Y=float(r.roic_min5)))
            print(q, len(rows), flush=True)
    payload = dict(candidates=result, lineage=dict(generation=metadata['factGeneration'],
        panelSha256=metadata['panelSha256'], sourceWrites=False, requestedStart=a.start,
        builderSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()))
    a.output.write_text(json.dumps(payload, allow_nan=False, separators=(',', ':')))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['panel', 'metadata', 'fact-root', 'output']:
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--start', default='2013-01-01')
    build(p.parse_args())
