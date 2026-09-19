#!/usr/bin/env python3
"""Import paid, as-reported fiscal-year quality observations; never edit models.

Uses ART at fiscal Q4 (one non-overlapping TTM observation per fiscal year).
The first published row wins even when a later restatement looks healthier.
"""
import argparse
import hashlib
import json
import math
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


COLUMNS = ['ticker', 'dimension', 'date', 'reportperiod', 'fiscalperiod',
           'roic', 'invcapavg', 'ebit', 'revenue', 'opinc', 'fcf', 'ncfo',
           'netinc', 'capex']


def number(value):
    return float(value) if isinstance(value, (int, float)) and math.isfinite(value) else None


def ratio(numerator, denominator):
    n, d = number(numerator), number(denominator)
    return n / d if n is not None and d is not None and d > 0 else None


def observation(raw, ticker):
    fy = re.fullmatch(r'(\d{4})-Q4', str(raw['fiscalperiod']))
    if raw['dimension'] != 'ART' or not fy:
        return None
    available, period = str(raw['date']), str(raw['reportperiod'])
    if period > available or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', available):
        return None
    reasons = []
    roic = number(raw['roic'])
    check = ratio(raw['ebit'], raw['invcapavg'])
    if check is None:
        roic = None
        reasons.append('missing_or_nonpositive_invested_capital')
    elif roic is None or abs(check - roic) > .0011:
        roic = None
        reasons.append('roic_missing_or_formula_mismatch')
    fcf = number(raw['fcf'])
    cfo, capex = number(raw['ncfo']), number(raw['capex'])
    # Sharadar cash-flow capex is signed (outflows negative).
    if fcf is None or cfo is None or capex is None or abs(fcf - cfo - capex) > max(1, abs(fcf) * .000001):
        fcf = None
        reasons.append('fcf_missing_or_formula_mismatch')
    payload = {k: str(raw[k]) if k in ['date', 'reportperiod'] else raw[k] for k in COLUMNS}
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()
    return (ticker, raw['ticker'], int(fy[1]), period, available, 'ART', roic,
            ratio(raw['opinc'], raw['revenue']), ratio(fcf, raw['revenue']),
            ratio(raw['ncfo'], raw['netinc']), number(raw['roic']),
            number(raw['ebit']), number(raw['invcapavg']), number(raw['revenue']),
            number(raw['opinc']), cfo, capex, number(raw['netinc']),
            json.dumps(reasons), digest)


def first_reports(rows):
    grouped = {}
    for r in rows:
        if r['dimension'] != 'ART' or not re.fullmatch(r'\d{4}-Q4', str(r['fiscalperiod'])):
            continue
        key = (r['ticker'], str(r['reportperiod']))
        current = grouped.get(key)
        if current is None or str(r['date']) < str(current['date']):
            grouped[key] = r
        elif str(r['date']) == str(current['date']) and r != current:
            raise ValueError(f'Ambiguous first publication: {key}')
    return list(grouped.values())


def main():
    import pyarrow.dataset as ds
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--db', required=True, type=Path)
    args = parser.parse_args()
    if not args.db.is_file():
        raise ValueError('Existing runtime database required')
    db = sqlite3.connect(args.db, timeout=30)
    # Reuse audited, explicit source-symbol mappings, never guess ADR/UK aliases.
    mappings = db.execute('SELECT DISTINCT ticker,source_ticker FROM valuation_pit_financials WHERE source_ticker IS NOT NULL').fetchall()
    aliases = {}
    for ticker, source in mappings:
        aliases.setdefault(source, set()).add(ticker)
    data = ds.dataset(args.source, format='parquet', partitioning='hive')
    rows = data.to_table(columns=COLUMNS, filter=(ds.field('dimension') == 'ART') & ds.field('ticker').isin(list(aliases))).to_pylist()
    records = [o for r in first_reports(rows) for ticker in aliases[r['ticker']] if (o := observation(r, ticker)) is not None]
    if not records:
        raise ValueError('No matched annual observations; existing quality data was not changed')
    with db:
        db.execute('''CREATE TABLE IF NOT EXISTS investment_quality_annual (
          ticker TEXT NOT NULL, source_ticker TEXT NOT NULL, fiscal_year INTEGER NOT NULL,
          report_period TEXT NOT NULL, available_at TEXT NOT NULL, dimension TEXT NOT NULL CHECK(dimension='ART'),
          roic REAL, operating_margin REAL, fcf_margin REAL, cash_conversion REAL,
          raw_roic REAL, ebit REAL, invested_capital_avg REAL, revenue REAL, operating_income REAL,
          cfo REAL, capex REAL, net_income REAL, issues_json TEXT NOT NULL, source_hash TEXT NOT NULL,
          PRIMARY KEY(ticker,report_period))''')
        db.execute('CREATE INDEX IF NOT EXISTS investment_quality_pit ON investment_quality_annual(ticker,available_at,fiscal_year)')
        db.execute('CREATE TABLE IF NOT EXISTS investment_quality_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)')
        # A single transaction replaces ONLY this importer-owned factor layer.
        db.execute('DELETE FROM investment_quality_annual')
        db.executemany('INSERT INTO investment_quality_annual VALUES (' + ','.join('?' for _ in range(20)) + ')', records)
        meta = {'source': 'Jansen / Sharadar SF1', 'version': 'annual-quality-v1',
                'importedAt': datetime.now(timezone.utc).isoformat(),
                'roicDefinition': 'Pre-tax EBIT / average invested capital. Invested capital = debt + assets - intangibles - cash - current liabilities.',
                'selection': 'Earliest date per source ticker/report period; ART fiscal Q4 only; never MR dimensions.',
                'rows': len(records), 'tickers': len(set(r[0] for r in records))}
        db.executemany('INSERT OR REPLACE INTO investment_quality_metadata VALUES (?,?)', [(k,json.dumps(v)) for k,v in meta.items()])
    print(json.dumps(meta, indent=2))
    db.close()


if __name__ == '__main__':
    main()
