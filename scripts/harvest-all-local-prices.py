"""Versioned all-security price harvest; never overwrite a served database.

One provider vintage per series. Preserve raw responses and rejected observations;
do not forward-fill, interpolate, silently alias securities, or splice return bases.
"""
import argparse
import concurrent.futures as futures
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import time
import urllib.request
import urllib.error

import pyarrow.dataset as ds

ALIASES = {'BRK.A': 'BRK-A', 'BRK.B': 'BRK-B', 'BF.A': 'BF-A', 'BF.B': 'BF-B',
           'HEI.A': 'HEI-A', 'LEN.B': 'LEN-B'}


def positive(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def parse_chart(symbol, payload, start, end):
    chart = (payload.get('chart', {}).get('result') or [None])[0]
    if not chart or payload['chart'].get('error'):
        raise ValueError('provider_history_unavailable')
    meta = chart['meta']
    if meta.get('symbol') != ALIASES.get(symbol, symbol) or meta.get('instrumentType') not in ('EQUITY', 'ETF'):
        raise ValueError('security_identity_mismatch')
    if meta.get('currency') not in ('USD', 'GBP', 'GBp'):
        raise ValueError('quote_unit_requires_review')
    quote = chart['indicators']['quote'][0]
    adjusted = chart['indicators'].get('adjclose', [{}])[0].get('adjclose', [])
    stamps = chart.get('timestamp', [])
    if len(stamps) != len(adjusted):
        raise ValueError('missing_adjusted_series')
    rows, rejected, seen = [], [], set()
    for i, stamp in enumerate(stamps):
        date = dt.datetime.fromtimestamp(stamp, dt.timezone.utc).date().isoformat()
        if not start <= date <= end:
            continue
        if date in seen:
            raise ValueError('duplicate_provider_date')
        seen.add(date)
        close, adj, high, low = quote['close'][i], adjusted[i], quote['high'][i], quote['low'][i]
        if not all(positive(v) for v in [close, adj, high, low]) or not low <= close <= high:
            rejected.append({'date': date, 'reason': 'invalid_close_or_adjusted_price'})
            continue
        opening = quote['open'][i]
        quarantine = opening is not None and (not positive(opening) or not low <= opening <= high)
        rows.append((date, None if quarantine else opening, high, low, close, adj,
                     quote['volume'][i], 'open_quarantined' if quarantine else 'verified_daily_bar'))
    if not rows:
        raise ValueError('no_valid_observations')
    return rows, rejected, {k: meta.get(k) for k in ['symbol', 'currency', 'instrumentType', 'exchangeName',
        'longName', 'shortName', 'firstTradeDate']}, chart.get('events', {})


def harvest(runtime_dir, output, cutoff, workers=5):
    os.umask(0o077)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'responses').mkdir(exist_ok=True)
    runtime = sqlite3.connect(f'file:{runtime_dir / "runtime.sqlite"}?mode=ro', uri=True)
    warehouse = sqlite3.connect(f'file:{runtime_dir / "strategy.sqlite"}?mode=ro', uri=True)
    raw = {s: {'first': first, 'last': last, 'rows': n} for s, first, last, n in runtime.execute(
        'SELECT symbol,MIN(date),MAX(date),COUNT(*) FROM price_points GROUP BY symbol')}
    snaps = {s: {'currency': currency, 'last': last} for s, currency, last in runtime.execute(
        "SELECT ticker,json_extract(payload_json,'$.currency'),json_extract(payload_json,'$.priceHistory[#-1].date') FROM valuation_ticker_snapshots")}
    symbols = sorted(set(raw) | set(snaps) | {s for s, in warehouse.execute('SELECT DISTINCT symbol FROM price_series')})
    catalog = ds.dataset('/Users/yudonglu/Documents/jansen_us_firm_replication/data/sharadar/parquet/tickers', format='parquet')
    metadata = {r['ticker']: r for r in catalog.to_table(filter=(ds.field('table') == 'SEP') & ds.field('ticker').isin(symbols)).to_pylist()}
    plan = {'cutoff': cutoff, 'sourceDirectory': str(runtime_dir), 'symbols': symbols, 'beforeRaw': raw,
            'beforeComparisons': snaps, 'scope': 'Union of all local daily-price, research and strategy securities',
            'provider': 'Yahoo chart, separate full-history vintage; Sharadar API denied subscription access',
            'startedAt': dt.datetime.now(dt.timezone.utc).isoformat()}
    plan_file = output / 'plan.json'
    if plan_file.exists():
        old = json.loads(plan_file.read_text())
        if old['symbols'] != symbols or old['cutoff'] != cutoff:
            raise ValueError('Resume scope changed')
    else:
        plan_file.write_text(json.dumps(plan, indent=2))
    db = sqlite3.connect(output / 'prices.sqlite')
    db.executescript('''CREATE TABLE IF NOT EXISTS series(symbol TEXT PRIMARY KEY,provider_symbol TEXT,currency TEXT,
        first_date TEXT,last_date TEXT,row_count INTEGER,source_sha256 TEXT,metadata_json TEXT,events_json TEXT,status TEXT);
        CREATE TABLE IF NOT EXISTS prices(symbol TEXT,date TEXT,open REAL,high REAL,low REAL,close REAL,
        adjusted_close REAL,volume REAL,quality_status TEXT,PRIMARY KEY(symbol,date));
        CREATE TABLE IF NOT EXISTS audit(symbol TEXT PRIMARY KEY,payload_json TEXT);''')

    def fetch(symbol):
        prior, reference = raw.get(symbol, {}), metadata.get(symbol, {})
        start = min(prior.get('first', '2016-09-01'), '2016-09-01')
        end = cutoff
        delisted = reference.get('isdelisted') == 'Y'
        if delisted and reference.get('lastpricedate'):
            end = min(cutoff, reference['lastpricedate'].isoformat())
        end_seconds = int(dt.datetime.fromisoformat(end).replace(tzinfo=dt.timezone.utc).timestamp()) + 86400
        begin_seconds = int(dt.datetime.fromisoformat(start).replace(tzinfo=dt.timezone.utc).timestamp())
        provider_symbol = ALIASES.get(symbol, symbol)
        url = f'https://query1.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(provider_symbol)}?period1={begin_seconds}&period2={end_seconds}&interval=1d&events=div%2Csplits&includeAdjustedClose=true'
        archive = output / 'responses' / (urllib.parse.quote(symbol, safe='') + '.json')
        info = {'symbol': symbol, 'requestedStart': start, 'requestedEnd': end, 'catalogDelisted': delisted,
                'catalogName': reference.get('name'), 'catalogLastPrice': str(reference.get('lastpricedate', '')),
                'previousLast': prior.get('last'), 'status': 'failed'}
        for attempt in range(2):
            try:
                if archive.exists():
                    content = archive.read_bytes()
                else:
                    request = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 ThesisForge local research'})
                    with urllib.request.urlopen(request, timeout=30) as response:
                        content = response.read()
                    # Provider data are private. No API credentials are involved.
                    archive.write_bytes(content)
                rows, rejected, meta, events = parse_chart(symbol, json.loads(content), start, end)
                digest = hashlib.sha256(content).hexdigest()
                info.update(status='delisted_history' if delisted else 'current' if rows[-1][0] == cutoff else 'stale',
                            first=rows[0][0], last=rows[-1][0], rows=len(rows), rejected=rejected,
                            sourceHash=digest, currency=meta['currency'], metadata=meta, events=events)
                return info, rows
            except urllib.error.HTTPError as e:
                info['error'] = 'provider_http_' + str(e.code)
                if e.code in (404, 403):
                    break
            except Exception as e:
                info['error'] = str(e) if isinstance(e, ValueError) else type(e).__name__
            if attempt == 0:
                time.sleep(0.3)
        return info, []

    reports = []
    with futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for i, (info, rows) in enumerate(pool.map(fetch, symbols), 1):
            reports.append(info)
            symbol = info['symbol']
            if rows:
                db.execute('INSERT OR REPLACE INTO series VALUES(?,?,?,?,?,?,?,?,?,?)', (symbol,
                    ALIASES.get(symbol, symbol), info['currency'], info['first'], info['last'], len(rows),
                    info['sourceHash'], json.dumps(info['metadata']), json.dumps(info['events']), info['status']))
                db.executemany('INSERT OR REPLACE INTO prices VALUES(?,?,?,?,?,?,?,?,?)', [(symbol, *r) for r in rows])
            db.execute('INSERT OR REPLACE INTO audit VALUES(?,?)', (symbol, json.dumps(info)))
            if i % 50 == 0 or i == len(symbols):
                db.commit()
                counts = {k: sum(r['status'] == k for r in reports) for k in ['current','stale','delisted_history','failed']}
                print(json.dumps({'phase': 'harvest', 'completed': i, 'total': len(symbols), **counts}), flush=True)
    db.commit()
    (output / 'harvest-audit.json').write_text(json.dumps({'plan': plan, 'securities': reports}, indent=2))
    if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise ValueError('Candidate integrity failure')
    db.close(); runtime.close(); warehouse.close()


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--cutoff', required=True)
    a = p.parse_args()
    if dt.date.fromisoformat(a.cutoff) >= dt.datetime.now(dt.timezone.utc).date():
        raise ValueError('Use a completed market day, not an unfinished current session')
    if a.output.resolve() == a.source.resolve():
        raise ValueError('An isolated output directory is required')
    harvest(a.source.resolve(), a.output.resolve(), a.cutoff)
