"""Bounded market-data harvest. Credentials stay inside the existing provider client."""
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

plan_file, out_dir = map(Path, sys.argv[1:])
plan = json.loads(plan_file.read_text())
sys.path.insert(0, str(Path.home() / 'Documents/jansen_us_firm_replication'))
from modern_us.sharadar import SharadarClient

client = SharadarClient(retries=1, timeout_seconds=30)
result = {'rows': [], 'failures': [], 'fundamentals': {}}
symbols = plan['sharadarSymbols']
def fetch_symbol(symbol):
    try:
        # One security per documented query; keep responses bounded.
        _, payload, _ = client.get_json('stocks', {'ticker': symbol, 'date.gte': plan['overlapStart'], 'date.lte': plan['cutoff'], 'format': 'json'})
        with (out_dir / f'sharadar-{symbol.replace("/", "_")}.json').open('x') as f:
            json.dump(payload, f)
        rows = client._extract_rows(payload)
        cols, _ = client._extract_columns(payload, rows)
        return {'rows': [dict(zip(cols, r)) if isinstance(r, list) else r for r in rows]}
    except Exception as e:
        # Never persist exception text containing a request URL or credential.
        return {'failure': {'symbol': symbol, 'error': type(e).__name__}}
with ThreadPoolExecutor(max_workers=3) as pool:
    for i, item in enumerate(pool.map(fetch_symbol, symbols)):
        result['rows'].extend(item.get('rows', []))
        if 'failure' in item:
            result['failures'].append(item['failure'])
        if (i+1) % 40 == 0:
            print(json.dumps({'provider': 'sharadar', 'completed': i+1, 'total': len(symbols)}), flush=True)
try:
    _, payload, _ = client.get_json('fundamentals', {'ticker': 'AVGO', 'dimension': 'ARQ', 'date.gte': plan['previousCutoff'], 'date.lte': plan['cutoff'], 'format': 'json'})
    result['fundamentals'] = {'status': 'accessible', 'scope': 'AVGO probe only; not a full financial refresh'}
except Exception as e:
    result['fundamentals'] = {'status': 'blocked', 'reason': 'provider_subscription_required' if '403' in str(e) else type(e).__name__}
with (out_dir / 'sharadar-results.json').open('x') as f:
    json.dump(result, f)
