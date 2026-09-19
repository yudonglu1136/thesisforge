"""Pure date planning for bounded, all-market lastupdated synchronization.

An unbounded provider query can silently limit historical coverage. Explicit
windows no longer than four calendar years keep old revisions in scope. This
helper performs no IO and does not assert that any provider response is complete;
the synchronizer still owns pagination, ingestion, and coverage validation.
"""
from calendar import monthrange
from datetime import date, timedelta


def _iso_date(value):
    if type(value) is date:
        return value
    if not isinstance(value, str):
        raise ValueError('start and end must be ISO dates')
    try:
        parsed = date.fromisoformat(value)
    except ValueError as error:
        raise ValueError('start and end must be valid ISO dates') from error
    if parsed.isoformat() != value:
        raise ValueError('start and end must use YYYY-MM-DD')
    return parsed


def bounded_date_windows(start, end, years=4):
    """Return disjoint inclusive ISO ranges covering exactly [start, end].

    The next window starts on the calendar anniversary ``years`` later. A leap
    day's anniversary is clamped to February 28 in a non-leap year. Each window
    ends one day BEFORE the next starts, and the final one ends exactly at end.
    One to four years are supported; wider ranges must never reach a broad query.
    """
    if type(years) is not int or not 1 <= years <= 4:
        raise ValueError('years must be an integer from 1 to 4')
    first, last = _iso_date(start), _iso_date(end)
    if first > last:
        raise ValueError('start must not be after end')
    result = []
    while first <= last:
        boundary_year = first.year + years
        if boundary_year > date.max.year:
            stop = last
        else:
            day = min(first.day, monthrange(boundary_year, first.month)[1])
            boundary = date(boundary_year, first.month, day)
            stop = min(last, boundary - timedelta(days=1))
        result.append((first.isoformat(), stop.isoformat()))
        if stop == last:
            break
        first = stop + timedelta(days=1)
    return result


def price_date_windows(start, end, local_min_date=None):
    """Cover the whole query range, using 31-day seeds for stored price history.

    ``local_min_date`` is only a query-granularity hint, NEVER a history cutoff.
    The earlier prefix is still covered by complete four-year windows so newly
    available old prices or revisions cannot be excluded by local metadata.
    Missing, invalid or out-of-range metadata falls back to that same complete
    four-year plan. The caller must still split full/failed requests and verify
    every complete leaf; choosing smaller roots does not establish completeness.
    """
    first, last = _iso_date(start), _iso_date(end)
    if first > last:
        raise ValueError('start must not be after end')
    try:
        anchor = _iso_date(local_min_date)
    except ValueError:
        return bounded_date_windows(first, last)
    if not first <= anchor <= last:
        return bounded_date_windows(first, last)

    result = (bounded_date_windows(first, anchor - timedelta(days=1))
              if first < anchor else [])
    cursor = anchor
    while cursor <= last:
        # Bound the delta before adding so date.max remains a valid endpoint.
        stop = cursor + timedelta(days=min(30, (last - cursor).days))
        result.append((cursor.isoformat(), stop.isoformat()))
        if stop == last:
            break
        cursor = stop + timedelta(days=1)
    return result
