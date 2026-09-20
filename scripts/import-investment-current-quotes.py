#!/usr/bin/env python3
"""Append the latest canonical Fact OS stock closes to an investment release.

This bridge never edits archived valuation models or their historical price
anchors. It adds one current, split-adjusted close per mapped equity so the
redesigned workflow can compare an unchanged published model with a current
market observation.
"""
import argparse
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
import fcntl
import hashlib
import json
import math
from pathlib import Path
import sqlite3


@contextmanager
def pinned_stocks(root):
    root = root.resolve()
    catalog = root / 'manifests' / 'catalog.json'
    if not catalog.is_file():
        raise ValueError('Published Fact OS catalog is required')
    lock_path = root / 'sync' / 'readers.lock'
    lock_path.parent.mkdir(exist_ok=True)
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        manifest = json.loads(catalog.read_text())
        item = manifest.get('datasets', {}).get('stocks') or {}
        files = [(root / part['path']).resolve() for part in item.get('partitions', [])]
        if not files or any(not path.is_file() or not path.is_relative_to(root) for path in files):
            raise ValueError('Published Fact OS stocks generation is incomplete')
        yield manifest, item, files


def text_day(value):
    return value.isoformat() if isinstance(value, date) else str(value)[:10]


def row_hash(row):
    payload = {key: (text_day(value) if isinstance(value, date) else value)
               for key, value in row.items()}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def main():
    import pyarrow.dataset as ds
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--db', required=True, type=Path)
    parser.add_argument('--lookback-days', type=int, default=45)
    args = parser.parse_args()
    root, target = args.source.resolve(), args.db.resolve()
    if not target.is_file():
        raise ValueError('Existing investment release database required')
    if args.lookback_days < 7 or args.lookback_days > 366:
        raise ValueError('lookback-days must be between 7 and 366')
    db = sqlite3.connect(target, timeout=30)
    mappings = db.execute('''SELECT DISTINCT ticker,source_ticker
      FROM valuation_pit_financials WHERE source_ticker IS NOT NULL''').fetchall()
    aliases = {}
    for ticker, source_ticker in mappings:
        aliases.setdefault(source_ticker, set()).add(ticker)
    if not aliases:
        raise ValueError('No audited valuation ticker mappings are available')

    with pinned_stocks(root) as (manifest, item, files):
        max_day = date.fromisoformat(item['state']['max_date'])
        start_day = max_day - timedelta(days=args.lookback_days)
        dataset = ds.dataset([str(path) for path in files], format='parquet')
        rows = dataset.to_table(
            columns=['ticker', 'date', 'close', 'lastupdated'],
            filter=(ds.field('ticker').isin(list(aliases))) &
                   (ds.field('date') >= start_day) & (ds.field('date') <= max_day),
        ).to_pylist()
        source_files = [(str(path.relative_to(root)), path.stat().st_size) for path in files]

    latest = {}
    for row in rows:
        close = row.get('close')
        if not isinstance(close, (int, float)) or not math.isfinite(close) or close <= 0:
            continue
        key = row['ticker']
        prior = latest.get(key)
        if prior is None or row['date'] > prior['date']:
            latest[key] = row
        elif row['date'] == prior['date'] and row != prior:
            raise ValueError(f'Ambiguous latest Fact OS close: {key} {row["date"]}')
    if not latest:
        raise ValueError('No mapped current stock closes; target was not changed')

    generation = hashlib.sha256(json.dumps({
        'dataset': 'stocks', 'state': item.get('state'), 'files': source_files,
    }, sort_keys=True).encode()).hexdigest()
    imported_at = datetime.now(timezone.utc).isoformat()
    observed_at = item.get('state', {}).get('last_success') or imported_at
    records = []
    for source_ticker, row in latest.items():
        compact = {'ticker': source_ticker, 'date': text_day(row['date']),
                   'close': float(row['close']), 'lastupdated': text_day(row['lastupdated'])}
        digest = row_hash(compact)
        for ticker in aliases[source_ticker]:
            records.append((ticker, source_ticker, compact['date'], compact['close'],
                            'Sharadar SEP via ThesisForge Fact OS', observed_at,
                            imported_at, generation, digest))

    with db:
        db.execute('''CREATE TABLE IF NOT EXISTS investment_current_quotes(
          ticker TEXT NOT NULL,source_ticker TEXT NOT NULL,price_date TEXT NOT NULL,
          close REAL NOT NULL CHECK(close>0),source TEXT NOT NULL,observed_at TEXT NOT NULL,
          imported_at TEXT NOT NULL,source_generation TEXT NOT NULL,source_hash TEXT NOT NULL,
          PRIMARY KEY(ticker,price_date,source_hash))''')
        db.execute('''CREATE INDEX IF NOT EXISTS investment_current_quotes_latest
          ON investment_current_quotes(ticker,price_date DESC,imported_at DESC)''')
        db.execute('''CREATE TABLE IF NOT EXISTS investment_current_quote_metadata(
          source_generation TEXT PRIMARY KEY,imported_at TEXT NOT NULL,max_price_date TEXT NOT NULL,
          source_row_count INTEGER NOT NULL,mapped_ticker_count INTEGER NOT NULL)''')
        before = db.execute('SELECT COUNT(*) FROM investment_current_quotes').fetchone()[0]
        db.executemany('INSERT OR IGNORE INTO investment_current_quotes VALUES (?,?,?,?,?,?,?,?,?)', records)
        after = db.execute('SELECT COUNT(*) FROM investment_current_quotes').fetchone()[0]
        db.execute('INSERT OR IGNORE INTO investment_current_quote_metadata VALUES (?,?,?,?,?)',
                   (generation, imported_at, max_day.isoformat(), len(latest), len({r[0] for r in records})))
    result = {'source': 'Sharadar SEP via ThesisForge Fact OS', 'sourceGeneration': generation,
              'maxPriceDate': max_day.isoformat(), 'sourceRows': len(latest),
              'mappedTickers': len({r[0] for r in records}), 'inserted': after-before,
              'totalRows': after}
    print(json.dumps(result, indent=2))
    db.close()


if __name__ == '__main__':
    main()
