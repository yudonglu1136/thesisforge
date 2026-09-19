"""Complete bounded native queries without unstable offset pagination.

The caller supplies HTTP, schema validation, retries and publication. A leaf is
complete only when its row count is strictly below the provider's requested
limit. At-limit responses are ambiguous and must be subdivided, never accepted.
"""
from datetime import date, timedelta
from concurrent.futures import ThreadPoolExecutor
from collections import deque
import hashlib
import json


class ExtractionError(RuntimeError):
    pass


class SplitQueryRequired(ExtractionError):
    """The caller identified a transient read failure eligible for date splitting.

    This is never an empty result or proof of completeness. Only a multi-day
    query can be subdivided; an unresolved single-day query aborts extraction.
    Authentication, schema, source-integrity and ordinary errors must not use
    this signal.
    """


def _tickers(value, *, discovery=False):
    if isinstance(value, str):
        if discovery:
            raise ExtractionError('ticker discovery must return a list, not a string')
        values = value.split(',')
    elif isinstance(value, (list, tuple)):
        values = list(value)
    else:
        raise ExtractionError('ticker list is missing or invalid')
    if not values:
        raise ExtractionError('ticker discovery/list is empty for a full query')
    tickers = []
    for value in values:
        if not isinstance(value, str) or not value.strip() or ',' in value:
            raise ExtractionError('ticker discovery/list contains an invalid ticker')
        if len(value.strip()) > 200:
            raise ExtractionError('single ticker exceeds the provider 200-character limit')
        tickers.append(value.strip())
    if len(set(tickers)) != len(tickers):
        raise ExtractionError('ticker discovery/list contains duplicate tickers')
    return tickers


def _ticker_chunks(tickers):
    """Pack disjoint groups within both native API ticker limits."""
    group, length = [], 0
    for ticker in tickers:
        needed = len(ticker) + bool(group)
        if group and (length + needed > 200 or len(group) >= 30):
            yield ','.join(group)
            group, length = [], 0
        length += len(ticker) + bool(group)
        group.append(ticker)
    if group:
        yield ','.join(group)


def _within_ticker_bounds(ticker, query):
    return (('ticker.gt' not in query or ticker > query['ticker.gt'])
            and ('ticker.gte' not in query or ticker >= query['ticker.gte'])
            and ('ticker.lt' not in query or ticker < query['ticker.lt'])
            and ('ticker.lte' not in query or ticker <= query['ticker.lte']))


def complete_queries(params, fetch, limit, discover_tickers=None, workers=3, date_windows=None,
                     ticker_ranges=False):
    """Yield complete ``(query, rows)`` leaves, including empty leaves.

    ``fetch(query)`` returns rows for that exact query and limit. No skip/offset
    is used. The initial query must specify inclusive ISO ``from``/``to`` dates.
    Full responses split by date first, then by ticker on a single day. For an
    unfiltered full day, ``discover_tickers(query)`` must independently provide
    the complete distinct ticker list; each comma-joined group is at most 200
    characters and 30 tickers. Oversized initial ticker parameters are split
    before any fetch.
    At most ``workers`` partitions run concurrently (1–3) in one worker pool.
    A deterministic breadth-first queue handles date and ticker splits; network
    completion order cannot change leaf order. At most one bounded response
    batch is retained. No nested worker pools are created. Optional ordered,
    nonoverlapping ``date_windows`` seed the same queue (gaps are permitted).
    ``ticker_ranges=True`` enables documented lexical .lte/.gt partitions for
    sources whose range semantics the caller has verified. These splits cover
    the entire parent interval, not just symbols seen during discovery. Explicit
    ticker lists still retain their exact subset semantics and native limits.
    Discovery truncation/verification is the caller's responsibility. Invalid or
    duplicate discovery entries fail closed. A full single ticker/day fails
    explicitly because this algorithm cannot prove that response is complete.
    ``fetch`` may explicitly raise ``SplitQueryRequired`` for a read failure:
    a multi-day scope then splits into two exhaustive date intervals. A failing
    single day or any other exception aborts; no error is treated as no rows.

    All yielded leaves must finish and pass the caller's second-pass comparison
    before anything is published. A later failure invalidates earlier leaves.
    """
    if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
        raise ValueError('limit must be a positive integer')
    if isinstance(workers, bool) or not isinstance(workers, int) or not 1 <= workers <= 3:
        raise ValueError('workers must be between 1 and 3')
    if not isinstance(ticker_ranges, bool):
        raise ValueError('ticker_ranges must be a boolean')
    if not isinstance(params, dict) or not callable(fetch):
        raise ValueError('query parameters and a fetch function are required')
    if any(key in params for key in ('skip', 'offset')):
        raise ExtractionError('offset pagination is not permitted for complete queries')
    query = dict(params)
    query['limit'] = limit
    for bound in ('ticker.gt', 'ticker.gte', 'ticker.lt', 'ticker.lte'):
        if bound in query:
            if not isinstance(query[bound], str) or not query[bound] or len(query[bound]) > 200:
                raise ValueError('ticker range bounds must be nonempty strings of at most 200 characters')
    try:
        start = date.fromisoformat(str(query['from']))
        end = date.fromisoformat(str(query['to']))
    except (KeyError, ValueError):
        raise ValueError('complete queries require valid from/to ISO dates') from None
    if start > end:
        raise ValueError('from must not be after to')
    query['from'], query['to'] = start.isoformat(), end.isoformat()
    if 'ticker' in query:
        query['ticker'] = ','.join(_tickers(query['ticker']))
    if date_windows is None:
        windows = [(start, end)]
    else:
        if not isinstance(date_windows, (list, tuple)) or not date_windows:
            raise ValueError('date_windows must be a nonempty ordered list')
        windows, previous = [], None
        for window in date_windows:
            if not isinstance(window, (list, tuple)) or len(window) != 2:
                raise ValueError('each date window must contain start and end')
            try:
                low, high = (date.fromisoformat(str(value)) for value in window)
            except ValueError:
                raise ValueError('date windows require valid ISO dates') from None
            if not start <= low <= high <= end:
                raise ValueError('date window is outside the query range or reversed')
            if previous is not None and low <= previous:
                raise ValueError('date windows must be ordered and nonoverlapping')
            windows.append((low, high)); previous = high
    pending = deque()
    for low, high in windows:
        root = {**query, 'from': low.isoformat(), 'to': high.isoformat()}
        if 'ticker' in root:
            pending.extend({**root, 'ticker': chunk} for chunk in _ticker_chunks(_tickers(root['ticker'])))
        else:
            pending.append(root)
    emitted = set()

    def fetch_partition(current):
        try:
            rows = fetch(dict(current))
        except SplitQueryRequired as error:
            return error
        if not isinstance(rows, list):
            raise ExtractionError('fetch must return a list of rows')
        if len(rows) > limit:
            raise ExtractionError('query returned more than its requested limit')
        return rows

    with ThreadPoolExecutor(max_workers=workers) as pool:
        while pending:
            batch = [pending.popleft() for _ in range(min(workers, len(pending)))]
            futures = [pool.submit(fetch_partition, current) for current in batch]
            # Resolve all before yielding. Any fetch failure aborts this batch;
            # staged leaves from earlier batches must also remain unpublished.
            responses = [future.result() for future in futures]
            del futures
            for index, current in enumerate(batch):
                rows = responses[index]
                responses[index] = None
                if isinstance(rows, SplitQueryRequired):
                    low, high = date.fromisoformat(current['from']), date.fromisoformat(current['to'])
                    if low == high:
                        raise rows
                    midpoint = low + (high - low) // 2
                    pending.append({**current, 'to': midpoint.isoformat()})
                    pending.append({**current, 'from': (midpoint + timedelta(days=1)).isoformat()})
                    del rows
                    continue
                if len(rows) < limit:
                    signature = json.dumps(current, sort_keys=True)
                    if signature in emitted:
                        raise ExtractionError('duplicate complete query generated')
                    emitted.add(signature)
                    yield dict(current), rows
                    del rows
                    continue
                del rows  # Release a full parent before discovery/child queries.
                low, high = date.fromisoformat(current['from']), date.fromisoformat(current['to'])
                if low < high:
                    midpoint = low + (high - low) // 2
                    pending.append({**current, 'to': midpoint.isoformat()})
                    pending.append({**current, 'from': (midpoint + timedelta(days=1)).isoformat()})
                elif 'ticker' in current:
                    tickers = _tickers(current['ticker'])
                    if len(tickers) == 1:
                        raise ExtractionError('single ticker/day reaches query limit; completeness cannot be established')
                    midpoint = len(tickers) // 2
                    pending.append({**current, 'ticker': ','.join(tickers[:midpoint])})
                    pending.append({**current, 'ticker': ','.join(tickers[midpoint:])})
                else:
                    if not callable(discover_tickers):
                        raise ExtractionError('complete ticker discovery is required for an at-limit single day')
                    tickers = _tickers(discover_tickers(dict(current)), discovery=True)
                    if any(not _within_ticker_bounds(ticker, current) for ticker in tickers):
                        raise ExtractionError('ticker discovery returned a symbol outside its requested bounds')
                    if ticker_ranges:
                        if len(tickers) < 2:
                            raise ExtractionError('single ticker/day reaches query limit; completeness cannot be established')
                        pivot = sorted(tickers)[(len(tickers) - 1) // 2]
                        pending.append({**current, 'ticker.lte': pivot})
                        pending.append({**current, 'ticker.gt': pivot})
                    else:
                        pending.extend({**current, 'ticker': chunk} for chunk in _ticker_chunks(tickers))
            del responses, batch


def canonical_rows_hash(rows, keys):
    """Hash source rows sorted by unique natural key, ignoring response order.

    Every source value remains in the digest. Duplicate/missing natural keys,
    non-JSON values and non-finite numbers are explicit failures, not silently
    normalized or discarded. Key fields may contain the vendor's empty strings.
    """
    if not isinstance(rows, list):
        raise ExtractionError('rows must be a list')
    if isinstance(keys, str) or not keys or any(not isinstance(key, str) or not key for key in keys):
        raise ValueError('natural key fields are required')
    if len(set(keys)) != len(keys):
        raise ValueError('natural key fields must be unique')
    keyed = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or any(key not in row or row[key] is None for key in keys):
            raise ExtractionError('row has a missing natural key')
        try:
            key = json.dumps([row[field] for field in keys], sort_keys=True, separators=(',', ':'), allow_nan=False)
        except (TypeError, ValueError):
            raise ExtractionError('natural key is not valid JSON') from None
        if key in seen:
            raise ExtractionError('response contains duplicate natural keys')
        seen.add(key)
        keyed.append((key, row))
    digest = hashlib.sha256(b'[')
    for index, (_, row) in enumerate(sorted(keyed, key=lambda item: item[0])):
        if index:
            digest.update(b',')
        try:
            digest.update(json.dumps(row, sort_keys=True, separators=(',', ':'), allow_nan=False).encode())
        except (TypeError, ValueError):
            raise ExtractionError('row contains a non-JSON or non-finite value') from None
    digest.update(b']')
    return digest.hexdigest()
