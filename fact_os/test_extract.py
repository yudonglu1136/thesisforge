"""Offline completeness tests for native no-offset extraction."""
from datetime import date, timedelta
import threading
import time
import unittest

from .extract import ExtractionError, SplitQueryRequired, canonical_rows_hash, complete_queries


class ExtractTest(unittest.TestCase):
    def setUp(self):
        self.params = {'format': 'json', 'from': '2026-01-01', 'to': '2026-01-08'}
        self.calls = []

    def fetcher(self, source):
        def fetch(query):
            self.assertNotIn('skip', query); self.assertNotIn('offset', query)
            self.assertLessEqual(len(query.get('ticker', '')), 200)
            if 'ticker' in query:
                self.assertLessEqual(len(query['ticker'].split(',')), 30)
            self.calls.append(dict(query))
            tickers = query.get('ticker', '').split(',') if 'ticker' in query else None
            rows = [row for row in source if query['from'] <= row['date'] <= query['to']
                    and (tickers is None or row['ticker'] in tickers)
                    and ('ticker.gt' not in query or row['ticker'] > query['ticker.gt'])
                    and ('ticker.gte' not in query or row['ticker'] >= query['ticker.gte'])
                    and ('ticker.lt' not in query or row['ticker'] < query['ticker.lt'])
                    and ('ticker.lte' not in query or row['ticker'] <= query['ticker.lte'])]
            return rows[:query['limit']]
        return fetch

    def test_date_split_is_complete_and_nonoverlapping(self):
        rows = [{'ticker': 'A', 'date': (date(2026, 1, 1) + timedelta(days=index)).isoformat(), 'value': index}
                for index in range(8)]
        original = dict(self.params)
        leaves = list(complete_queries(self.params, self.fetcher(rows), 3))
        self.assertEqual(self.params, original)
        self.assertEqual(sorted([row for _, data in leaves for row in data], key=lambda row: row['date']), rows)
        self.assertTrue(all(len(data) < 3 for _, data in leaves))
        chronological = sorted(leaves, key=lambda leaf: leaf[0]['from'])
        for (left, _), (right, _) in zip(chronological, chronological[1:]):
            self.assertEqual(date.fromisoformat(left['to']) + timedelta(days=1), date.fromisoformat(right['from']))

    def test_explicit_read_failure_splits_dates_without_missing_or_repeating_days(self):
        rows = [{'ticker': 'A', 'date': (date(2024, 2, 25) + timedelta(days=index)).isoformat()}
                for index in range(9)]
        base = self.fetcher(rows)
        query = {**self.params, 'from': '2024-02-25', 'to': '2024-03-04',
                 'lastupdated.gte': '2026-09-04', 'lastupdated.lte': '2026-09-19'}
        def fetch(current):
            self.assertEqual(current['lastupdated.gte'], query['lastupdated.gte'])
            self.assertEqual(current['lastupdated.lte'], query['lastupdated.lte'])
            if (date.fromisoformat(current['to']) - date.fromisoformat(current['from'])).days > 1:
                raise SplitQueryRequired('read timeout')
            return base(current)
        leaves = list(complete_queries(query, fetch, 100))
        self.assertEqual(sorted(row['date'] for _, data in leaves for row in data),
                         [row['date'] for row in rows])
        chronological = sorted(leaves, key=lambda leaf: leaf[0]['from'])
        self.assertEqual(chronological[0][0]['from'], query['from'])
        self.assertEqual(chronological[-1][0]['to'], query['to'])
        for (left, _), (right, _) in zip(chronological, chronological[1:]):
            self.assertEqual(date.fromisoformat(left['to']) + timedelta(days=1),
                             date.fromisoformat(right['from']))

    def test_explicit_read_failure_on_one_day_fails_without_empty_substitution(self):
        calls = []
        def fetch(query):
            calls.append(query)
            raise SplitQueryRequired('single day still unreadable')
        iterator = complete_queries({**self.params, 'to': self.params['from']}, fetch, 100)
        with self.assertRaisesRegex(SplitQueryRequired, 'single day still unreadable'):
            next(iterator)
        self.assertEqual(len(calls), 1)

    def test_ordinary_failures_are_not_eligible_for_date_subdivision(self):
        for error in (RuntimeError('source denied'), ExtractionError('schema drift')):
            with self.subTest(error=error):
                calls = []
                def fetch(query):
                    calls.append(query)
                    raise error
                with self.assertRaises(type(error)):
                    list(complete_queries(self.params, fetch, 100))
                self.assertEqual(len(calls), 1)

    def test_read_failure_splitting_respects_seeded_window_gaps(self):
        rows = [{'ticker': 'A', 'date': f'2026-01-0{index}'} for index in range(1, 9)]
        base = self.fetcher(rows)
        def fetch(query):
            if query['from'] != query['to']:
                raise SplitQueryRequired('split only this requested interval')
            return base(query)
        windows = [('2026-01-01', '2026-01-03'), ('2026-01-06', '2026-01-08')]
        leaves = list(complete_queries(self.params, fetch, 100, date_windows=windows))
        self.assertEqual(sorted(row['date'] for _, data in leaves for row in data),
                         [f'2026-01-0{index}' for index in (1, 2, 3, 6, 7, 8)])

    def test_full_day_splits_existing_ticker_list(self):
        rows = [{'ticker': ticker, 'date': '2026-01-01', 'value': 1} for ticker in 'ABCDE']
        query = {**self.params, 'to': '2026-01-01', 'ticker': 'A,B,C,D,E'}
        leaves = list(complete_queries(query, self.fetcher(rows), 3))
        self.assertEqual([row for _, data in leaves for row in data], rows)
        self.assertEqual([leaf['ticker'] for leaf, _ in leaves], ['A,B', 'C', 'D,E'])

    def test_discovery_starts_with_bounded_chunks_and_recursively_splits(self):
        tickers = [f'T{index:03d}' for index in range(205)]
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in tickers]
        discovered = []
        def discover(query): discovered.append(query); return tickers
        query = {**self.params, 'to': '2026-01-01'}
        leaves = list(complete_queries(query, self.fetcher(rows), 30, discover))
        self.assertEqual(len(discovered), 1)
        self.assertEqual(sorted([row for _, data in leaves for row in data], key=lambda row: row['ticker']), rows)
        self.assertTrue(all(len(call.get('ticker', '')) <= 200 for call in self.calls))
        self.assertEqual([len(data) for _, data in leaves], [25] + [15] * 12)

    def test_initial_short_ticker_parameter_obeys_count_limit_too(self):
        tickers = [f'T{index}' for index in range(31)]
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in tickers]
        query = {**self.params, 'to': '2026-01-01', 'ticker': ','.join(tickers)}
        self.assertLess(len(query['ticker']), 200)
        leaves = list(complete_queries(query, self.fetcher(rows), 100))
        self.assertEqual([row for _, data in leaves for row in data], rows)
        self.assertEqual([len(leaf['ticker'].split(',')) for leaf, _ in leaves], [30, 1])

    def test_ticker_ranges_recursively_cover_whole_parent_without_overlap(self):
        tickers = ['A', 'A-A', 'A.B', 'A0', 'AA', 'B', 'BA', 'C', 'Z']
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in tickers]
        base = self.fetcher(rows)
        discovered = []
        def discover(query):
            discovered.append(dict(query))
            return [row['ticker'] for row in base({**query, 'limit': 100})]
        leaves = list(complete_queries({**self.params, 'to': '2026-01-01'}, base, 3,
                                       discover, ticker_ranges=True))
        self.assertEqual(sorted([row for _, data in leaves for row in data], key=lambda row: row['ticker']), rows)
        self.assertTrue(all(len(data) < 3 for _, data in leaves))
        self.assertGreater(len(discovered), 1)
        self.assertTrue(all('ticker' not in call for call in self.calls))
        # Hypothetical symbols absent during discovery still belong to exactly
        # one leaf; partitioning is over lexical intervals, not cached members.
        for ticker in ['', '0', 'A-', 'A.A', 'AB', 'BB', 'Y', 'ZZ']:
            memberships = [not ('ticker.gt' in q and ticker <= q['ticker.gt'])
                           and not ('ticker.lte' in q and ticker > q['ticker.lte']) for q, _ in leaves]
            self.assertEqual(sum(memberships), 1, ticker)

    def test_ticker_ranges_preserve_existing_inclusive_and_exclusive_bounds(self):
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in 'ABCDEFGH']
        base = self.fetcher(rows)
        query = {**self.params, 'to': '2026-01-01', 'ticker.gte': 'B', 'ticker.lt': 'G'}
        def discover(q): return [row['ticker'] for row in base({**q, 'limit': 100})]
        leaves = list(complete_queries(query, base, 3, discover, ticker_ranges=True))
        self.assertEqual(sorted(row['ticker'] for _, data in leaves for row in data), list('BCDEF'))
        self.assertTrue(all(q['ticker.gte'] == 'B' and q['ticker.lt'] == 'G' for q, _ in leaves))

    def test_ticker_ranges_preserve_explicit_subset_and_fail_ambiguous_discovery(self):
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in 'ABCDE']
        base = self.fetcher(rows)
        query = {**self.params, 'to': '2026-01-01', 'ticker': 'A,C,E'}
        leaves = list(complete_queries(query, base, 3, ticker_ranges=True))
        self.assertEqual([row['ticker'] for _, data in leaves for row in data], ['A', 'C', 'E'])
        query = {**self.params, 'to': '2026-01-01', 'ticker.gt': 'A', 'ticker.lte': 'D'}
        with self.assertRaisesRegex(ExtractionError, 'outside'):
            list(complete_queries(query, base, 3, lambda _: ['A', 'B', 'C'], ticker_ranges=True))
        with self.assertRaisesRegex(ExtractionError, 'single ticker/day'):
            list(complete_queries(query, lambda _: [1, 2, 3], 3, lambda _: ['B'], ticker_ranges=True))

    def test_ticker_range_input_validation(self):
        for value in (None, '', 3, 'A' * 201):
            with self.subTest(value=value), self.assertRaises(ValueError):
                list(complete_queries({**self.params, 'ticker.gt': value}, self.fetcher([]), 3))
        with self.assertRaises(ValueError):
            list(complete_queries(self.params, self.fetcher([]), 3, ticker_ranges='yes'))
        self.assertFalse(self.calls)

    def test_initial_long_ticker_parameter_is_split_before_any_fetch(self):
        tickers = [str(index) + 'A' * 74 for index in range(5)]
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in tickers]
        query = {**self.params, 'to': '2026-01-01', 'ticker': ','.join(tickers)}
        leaves = list(complete_queries(query, self.fetcher(rows), 10))
        self.assertEqual([row for _, data in leaves for row in data], rows)
        self.assertEqual([len(leaf['ticker']) for leaf, _ in leaves], [151, 151, 75])
        self.assertEqual(len(self.calls), 3)

    def test_single_oversized_ticker_fails_before_a_bad_request(self):
        query = {**self.params, 'ticker': 'A' * 201}
        with self.assertRaisesRegex(ExtractionError, '200-character'):
            list(complete_queries(query, self.fetcher([]), 3))
        self.assertEqual(self.calls, [])
        query = {**self.params, 'to': '2026-01-01'}
        with self.assertRaisesRegex(ExtractionError, '200-character'):
            list(complete_queries(query, lambda _: [1, 2], 2, lambda _: ['A' * 201]))

    def test_parallel_groups_are_bounded_and_yield_in_stable_order(self):
        tickers = [str(index) + 'A' * 103 for index in range(10)]
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in tickers]
        query = {**self.params, 'to': '2026-01-01'}
        base = self.fetcher(rows)
        active = peak = 0
        lock = threading.Lock()
        def fetch(params):
            nonlocal active, peak
            if 'ticker' not in params:
                return base(params)
            with lock:
                active += 1; peak = max(peak, active)
            # Reverse completion order within each group batch.
            time.sleep(.003 * (3 - int(params['ticker'][0]) % 3))
            result = base(params)
            with lock: active -= 1
            return result
        iterator = complete_queries(query, fetch, 3, lambda _: tickers, workers=3)
        first = next(iterator)
        self.assertEqual(len(self.calls), 4)  # Root + only the first3 groups.
        leaves = [first, *iterator]
        self.assertEqual([row for _, data in leaves for row in data], rows)
        self.assertGreater(peak, 1)
        self.assertLessEqual(peak, 3)

    def test_parallel_group_failure_aborts_before_batch_yield(self):
        tickers = [str(index) + 'B' * 103 for index in range(8)]
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in tickers]
        base = self.fetcher(rows)
        def fetch(query):
            if query.get('ticker') == tickers[1]:
                raise RuntimeError('parallel group failed')
            return base(query)
        iterator = complete_queries({**self.params, 'to': '2026-01-01'}, fetch, 3, lambda _: tickers)
        with self.assertRaisesRegex(RuntimeError, 'parallel group failed'):
            next(iterator)
        self.assertLessEqual(len(self.calls), 4)
        self.assertFalse(any(call.get('ticker') in tickers[3:] for call in self.calls))

    def test_date_splits_share_one_bounded_parallel_pool(self):
        rows = [{'ticker': 'A', 'date': (date(2026, 1, 1) + timedelta(days=index)).isoformat()}
                for index in range(8)]
        base = self.fetcher(rows)
        active = peak = 0
        threads = set(); lock = threading.Lock()
        def fetch(query):
            nonlocal active, peak
            with lock:
                active += 1; peak = max(peak, active)
                threads.add(threading.current_thread().name.rsplit('_', 1)[0])
            time.sleep(.004)
            result = base(query)
            with lock: active -= 1
            return result
        leaves = list(complete_queries(self.params, fetch, 3, workers=3))
        self.assertEqual(sorted([row for _, data in leaves for row in data], key=lambda row: row['date']), rows)
        self.assertGreater(peak, 1)
        self.assertLessEqual(peak, 3)
        self.assertEqual(len(threads), 1)

    def test_date_windows_seed_same_queue_and_allow_gaps(self):
        rows = [{'ticker': 'A', 'date': (date(2026, 1, 1) + timedelta(days=index)).isoformat()}
                for index in range(8)]
        windows = [('2026-01-01', '2026-01-02'), ('2026-01-04', '2026-01-04'), ('2026-01-07', '2026-01-08')]
        base = self.fetcher(rows); lock = threading.Lock()
        active = peak = 0
        def fetch(query):
            nonlocal active, peak
            with lock: active += 1; peak = max(peak, active)
            time.sleep(.004)
            result = base(query)
            with lock: active -= 1
            return result
        leaves = list(complete_queries(self.params, fetch, 4, date_windows=windows))
        self.assertEqual([(leaf['from'], leaf['to']) for leaf, _ in leaves], windows)
        self.assertEqual([row['date'] for _, data in leaves for row in data],
                         ['2026-01-01', '2026-01-02', '2026-01-04', '2026-01-07', '2026-01-08'])
        self.assertGreater(peak, 1)
        self.assertLessEqual(peak, 3)

    def test_date_windows_are_validated_before_any_fetch(self):
        cases = [[], '2026-01-01', [('2026-01-01',)], [('bad', '2026-01-02')],
                 [('2025-12-31', '2026-01-01')], [('2026-01-08', '2026-01-09')],
                 [('2026-01-02', '2026-01-01')],
                 [('2026-01-03', '2026-01-04'), ('2026-01-01', '2026-01-02')],
                 [('2026-01-01', '2026-01-03'), ('2026-01-03', '2026-01-04')]]
        for windows in cases:
            with self.subTest(windows=windows):
                with self.assertRaises(ValueError):
                    list(complete_queries(self.params, self.fetcher([]), 3, date_windows=windows))
        self.assertEqual(self.calls, [])

    def test_empty_leaf_is_yielded_and_an_exact_limit_is_not_accepted(self):
        rows = [{'ticker': 'A', 'date': '2026-01-01', 'value': index} for index in range(2)]
        params = {**self.params, 'to': '2026-01-02', 'ticker': 'A'}
        with self.assertRaisesRegex(ExtractionError, 'single ticker/day'):
            list(complete_queries(params, self.fetcher(rows), 2))
        leaves = list(complete_queries(params, self.fetcher([]), 2))
        self.assertEqual(leaves, [({**params, 'limit': 2}, [])])

    def test_missing_invalid_empty_or_duplicate_discovery_fails(self):
        query = {**self.params, 'to': '2026-01-01'}
        rows = [{'ticker': ticker, 'date': '2026-01-01'} for ticker in 'ABC']
        for discovery in (None, lambda _: [], lambda _: ['A', 'A'], lambda _: ['A', ' A '],
                          lambda _: ['A', ''], lambda _: ['A', None], lambda _: 'A,B', lambda _: ['A,B']):
            with self.subTest(discovery=discovery):
                with self.assertRaises(ExtractionError):
                    list(complete_queries(query, self.fetcher(rows), 2, discovery))

    def test_single_ticker_day_over_limit_fails_closed(self):
        rows = [{'ticker': 'A', 'date': '2026-01-01', 'value': index} for index in range(4)]
        with self.assertRaisesRegex(ExtractionError, 'single ticker/day'):
            list(complete_queries({**self.params, 'to': '2026-01-01'}, self.fetcher(rows), 3, lambda _: ['A']))

    def test_fetch_failure_or_oversized_response_never_returns_complete_result(self):
        def raises(_): raise RuntimeError('source failed')
        with self.assertRaisesRegex(RuntimeError, 'source failed'):
            list(complete_queries(self.params, raises, 3))
        with self.assertRaisesRegex(ExtractionError, 'more than'):
            list(complete_queries(self.params, lambda _: [1, 2, 3, 4], 3))
        with self.assertRaisesRegex(ExtractionError, 'list of rows'):
            list(complete_queries(self.params, lambda _: {}, 3))

    def test_query_protocol_validation(self):
        for params in ({**self.params, 'skip': 0}, {**self.params, 'offset': 0},
                       {**self.params, 'ticker': ''}, {**self.params, 'ticker': 'A,A'}):
            with self.assertRaises(ExtractionError): list(complete_queries(params, lambda _: [], 3))
        for params in ({}, {**self.params, 'from': 'bad'}, {**self.params, 'to': '2025-01-01'}):
            with self.assertRaises(ValueError): list(complete_queries(params, lambda _: [], 3))
        for limit in (0, -1, True, 1.5):
            with self.assertRaises(ValueError): list(complete_queries(self.params, lambda _: [], limit))
        for workers in (0, 4, True, 1.5):
            with self.assertRaises(ValueError): list(complete_queries(self.params, lambda _: [], 3, workers=workers))

    def test_canonical_hash_ignores_order_but_detects_value_changes(self):
        rows = [{'ticker': 'B', 'date': '2026-01-01', 'value': 2},
                {'ticker': 'A', 'date': '2026-01-01', 'value': 1}]
        keys = ('ticker', 'date')
        self.assertEqual(canonical_rows_hash(rows, keys), canonical_rows_hash(list(reversed(rows)), keys))
        reordered_fields = [{key: row[key] for key in reversed(list(row))} for row in rows]
        self.assertEqual(canonical_rows_hash(rows, keys), canonical_rows_hash(reordered_fields, keys))
        changed = [{**rows[0], 'value': 3}, rows[1]]
        self.assertNotEqual(canonical_rows_hash(rows, keys), canonical_rows_hash(changed, keys))
        self.assertEqual(len(canonical_rows_hash([], keys)), 64)

    def test_canonical_hash_rejects_ambiguous_keys_and_nonfinite_values(self):
        for rows in ([{'ticker': 'A'}, {'ticker': 'A'}], [{}], [{'ticker': None}],
                     [{'ticker': 'A', 'value': float('nan')}], [{'ticker': 'A', 'value': object()}]):
            with self.assertRaises(ExtractionError): canonical_rows_hash(rows, ('ticker',))
        for keys in ((), 'ticker', ('ticker', 'ticker')):
            with self.assertRaises(ValueError): canonical_rows_hash([], keys)


if __name__ == '__main__': unittest.main()
