"""Export existing local vendor observations for the experiment; no DB writes."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path

import pyarrow.dataset as ds


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--selection', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--source', default='/Users/yudonglu/Documents/jansen_us_firm_replication/data/sharadar/parquet/prices')
    a = p.parse_args()
    selected = json.loads(Path(a.selection).read_text())
    # Include ALL factor-pass candidates, not a return-coverage-optimized subset.
    symbols = sorted({r['ticker'] for s in selected['snapshots'] for r in s['candidates'] if not r['reasons']})
    dataset = ds.dataset(a.source, format='parquet', partitioning='hive')
    table = dataset.to_table(columns=['ticker', 'date', 'close', 'closeadj'],
                            filter=ds.field('ticker').isin(symbols) & (ds.field('year') >= 2016))
    by_symbol = {}
    for r in table.to_pylist():
        date = r['date'].isoformat()
        if date > selected['rules']['end']:
            continue
        if not (r['close'] > 0 and r['closeadj'] > 0):
            raise ValueError(f"Nonpositive price: {r['ticker']} {date}")
        by_symbol.setdefault(r['ticker'], []).append([date, r['close'], r['closeadj']])
    for symbol, rows in by_symbol.items():
        rows.sort()
        if len({r[0] for r in rows}) != len(rows):
            raise ValueError(f'Duplicate price: {symbol}')
    digest = hashlib.sha256(json.dumps(by_symbol, sort_keys=True).encode()).hexdigest()
    payload = {'source': str(Path(a.source).resolve()), 'fields': ['date', 'close', 'closeadj'],
               'basis': 'Sharadar SEP close split-only; closeadj total return', 'hash': digest,
               'selectionHash': selected['selectionHash'], 'series': by_symbol}
    Path(a.output).write_text(json.dumps(payload, separators=(',', ':')))
    print(json.dumps({'symbols': len(by_symbol), 'missing': sorted(set(symbols) - set(by_symbol)),
                      'rows': sum(map(len, by_symbol.values())),
                      'end': max(r[-1][0] for r in by_symbol.values()), 'hash': digest}))


if __name__ == '__main__':
    main()
