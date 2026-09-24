"""Allowlisted local reader for Node consumers. No HTTP or provider credentials."""
import argparse
from datetime import date, datetime
from decimal import Decimal
import json
import math
import sys

from .repository import FactRepository, MissingData, PITUnavailable

METHODS = frozenset({
    'get_coverage',
    'resolve_security', 'get_price', 'get_price_history', 'get_price_histories', 'get_prices',
    'get_fundamentals', 'get_latest_fundamentals', 'get_fundamental_change_universe',
    'get_fundamental_company_index',
    'get_fundamental_research', 'get_dividends', 'get_metric', 'get_metric_history',
    'get_institutional_holdings', 'get_institutional_ownership_history',
    'get_holder_changes', 'get_investors', 'resolve_investor',
    'get_investor_history', 'get_investor_portfolio', 'get_investor_changes',
    'get_insider_transactions',
})


def required_tables(repo, method, args, kwargs):
    if method == 'get_coverage': return set()
    if method == 'get_insider_transactions': return {'tickers', 'insiders'}
    if method == 'get_dividends': return {'tickers', 'actions'}
    if method in ('resolve_security', 'get_investors', 'resolve_investor'):
        return {'tickers'}
    if method == 'get_price_histories':
        spans = kwargs.get('spans', args[0] if args else None)
        if not isinstance(spans, list) or not 1 <= len(spans) <= 512:
            raise ValueError('invalid historical security spans')
        tables = {'tickers'}
        for span in spans:
            selected = repo.resolve_security(span['ticker']).get('price_dataset')
            if selected not in ('stocks', 'funds'):
                raise MissingData('Canonical price table is missing or ambiguous in the security master.')
            tables.add(selected)
        return tables
    if method in ('get_price', 'get_price_history', 'get_prices'):
        dataset = kwargs.get('dataset', 'auto')
        if dataset == 'auto':
            requested = kwargs.get('tickers' if method == 'get_prices' else 'ticker', args[0] if args else None)
            tickers = requested if method == 'get_prices' else [requested]
            tables = {'tickers'}
            for ticker in tickers or []:
                try:
                    identity = repo.resolve_security(ticker)
                    selected = identity.get('price_dataset')
                    if selected not in ('stocks', 'funds'): raise MissingData('Canonical price table is missing or ambiguous in the security master.')
                    tables.add(selected)
                except MissingData:
                    if method != 'get_prices': raise
            return tables
        if dataset not in ('stocks', 'funds'):
            raise ValueError('explicit canonical stock or fund dataset required')
        return {'tickers', dataset}
    if method in ('get_fundamentals', 'get_latest_fundamentals', 'get_fundamental_research'):
        return {'tickers', 'fundamentals'}
    if method == 'get_fundamental_change_universe':
        return {'tickers', 'fundamentals', 'stocks'}
    if method == 'get_fundamental_company_index':
        return {'tickers', 'fundamentals'}
    if method in ('get_metric', 'get_metric_history'):
        from .registry import METRICS
        metric = kwargs.get('metric_id', args[1] if len(args) > 1 else None)
        if metric not in METRICS: raise ValueError('unknown canonical metric')
        return {'tickers', METRICS[metric]['table']}
    if method == 'get_institutional_ownership_history':
        return {'tickers', 'holdings_ticker'}
    if method == 'get_investor_history': return {'tickers', 'holdings_investor'}
    return {'tickers', 'holdings', 'holdings_investor'}


def json_value(value):
    if isinstance(value, (date, datetime)): return value.isoformat()
    if isinstance(value, Decimal): return float(value)
    if isinstance(value, float) and not math.isfinite(value): return None
    if isinstance(value, dict): return {str(k): json_value(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)): return [json_value(v) for v in value]
    return value


def dispatch(repo, request):
    if not isinstance(request, dict) or request.get('method') not in METHODS:
        raise ValueError('unsupported local query')
    args, kwargs = request.get('args', []), request.get('kwargs', {})
    if not isinstance(args, list) or not isinstance(kwargs, dict):
        raise ValueError('invalid local query arguments')
    # Partial archive inspection is an explicit diagnostic capability only.
    # Application bridge requests never include this flag.
    if request.get('allow_partial') is not True:
        required = required_tables(repo, request['method'], args, kwargs)
        states = {row['dataset']: row for row in repo.get_coverage()}
        missing = sorted(table for table in required if not states.get(table, {}).get('backfill_complete') or not states.get(table, {}).get('locally_available'))
        if missing:
            raise MissingData('Full canonical backfill is not complete for: ' + ', '.join(missing) + '. No partial archive or legacy fallback was used.')
    return getattr(repo, request['method'])(*args, **kwargs)


def dispatch_result(repo, request):
    try:
        return {'ok': True, 'result': json_value(dispatch(repo, request))}
    except PITUnavailable as error:
        return {'ok': False, 'error': {'code': 'pit_unavailable', 'message': str(error)}}
    except MissingData as error:
        return {'ok': False, 'error': {'code': 'local_data_unavailable', 'message': str(error)}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    options = parser.parse_args()
    repo = None
    try:
        request = json.loads(sys.stdin.read(1024 * 1024))
        repo = FactRepository(options.root)
        if isinstance(request, dict) and isinstance(request.get('batch'), list):
            if not 1 <= len(request['batch']) <= 256: raise ValueError('batch too large')
            result = {'ok': True, 'result': [dispatch_result(repo, entry) for entry in request['batch']]}
        else:
            result = dispatch_result(repo, request)
    except PITUnavailable as error:
        result = {'ok': False, 'error': {'code': 'pit_unavailable', 'message': str(error)}}
    except MissingData as error:
        result = {'ok': False, 'error': {'code': 'local_data_unavailable', 'message': str(error)}}
    except (ValueError, TypeError, KeyError):
        result = {'ok': False, 'error': {'code': 'invalid_fact_query', 'message': 'Invalid or unsupported local query.'}}
    except Exception:
        result = {'ok': False, 'error': {'code': 'local_data_unavailable', 'message': 'Local Fact OS is not ready for this query. Run backfill or sync separately; provider fallback is disabled.'}}
    finally:
        if repo is not None: repo.close()
    print(json.dumps(result, allow_nan=False, separators=(',', ':')))


if __name__ == '__main__': main()
