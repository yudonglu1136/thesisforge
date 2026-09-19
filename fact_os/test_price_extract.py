"""Offline regressions for small-page, all-market historical price refreshes."""
import csv
import io
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

import httpx

from .store import Store
from .sync import Synchronizer, UpstreamError


FIELDS = ['ticker', 'date', 'close', 'closeadj', 'closeunadj', 'lastupdated']
DDL = ('CREATE TABLE IF NOT EXISTS "stocks" ("ticker" TEXT,"date" TEXT,'
       '"close" REAL,"closeadj" REAL,"closeunadj" REAL,"lastupdated" TEXT,'
       'PRIMARY KEY ("ticker","date"));')


class PriceExtractionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.store = Store(self.root / 'facts')
        self.store.install_contract('stocks', DDL)
        self.seed = self.root / 'seed.csv'
        self.seed.write_text(','.join(FIELDS) + '\nOLD,2000-01-03,1,1,1,2026-09-18\n')
        self.store.ingest('stocks', self.seed, scope='verified_full_bulk')
        self.sync = Synchronizer(self.store, 'offline-only-key')
        self.requests, self.discovery_calls = [], 0
        self.environment = patch.dict('os.environ', {
            'FACT_OS_SYNC_FORMAT': 'csv', 'FACT_OS_SYNC_PAGE_SIZE': '100000',
            'FACT_OS_SYNC_WORKERS': '3',
        })
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.sync.close()
        self.temporary.cleanup()

    def provider(self, size, discovery_mode='duplicate'):
        # More than 10,000 rows on one date must progress beyond date splitting.
        source = {f'T{index:05}': {'ticker': f'T{index:05}', 'date': '2012-02-29',
                  'close': 2, 'closeadj': 2, 'closeunadj': 2, 'lastupdated': '2026-09-18'}
                  for index in range(size)}
        lock = threading.Lock()
        def handle(request):
            query = dict(request.url.params)
            with lock: self.requests.append(query)
            self.assertNotIn('skip', query); self.assertNotIn('offset', query)
            selected = ['ticker'] if query.get('fields') == 'ticker' else FIELDS
            if not query['from'] <= '2012-02-29' <= query['to']:
                rows = []
            elif selected == ['ticker']:
                with lock:
                    self.discovery_calls += 1
                    occurrence = self.discovery_calls
                if discovery_mode == 'full_ambiguous':
                    rows = [{'ticker': 'T00000'}] * 100000
                else:
                    # Duplicate projected values must be de-duplicated, without
                    # weakening the raw-response limit check.
                    rows = [{'ticker': ticker} for ticker in source] * 2
                    if discovery_mode == 'mutates' and occurrence >= 3:
                        rows.append({'ticker': 'NEW'})
            elif 'ticker' in query:
                tickers = query['ticker'].split(',')
                self.assertLessEqual(len(tickers), 30)
                self.assertLessEqual(len(query['ticker']), 200)
                rows = [source[ticker] for ticker in tickers if ticker in source]
            else:
                rows = list(source.values())
            rows = rows[:int(query['limit'])]
            output = io.StringIO()
            writer = csv.DictWriter(output, fieldnames=selected)
            writer.writeheader(); writer.writerows(rows)
            return httpx.Response(200, text=output.getvalue())
        self.sync.http.close()
        self.sync.http = httpx.Client(transport=httpx.MockTransport(handle))

    def test_single_day_over_ten_thousand_and_duplicate_projection_are_complete(self):
        self.provider(10001)
        result = self.sync.sync('stocks')
        self.assertEqual(result['input_rows'], 10001)
        self.assertEqual(result['local_rows'], 10002)  # Unrelated old fact retained.
        self.assertGreaterEqual(self.discovery_calls, 3)  # Double-read plus final universe check.
        queries = [query for query in self.requests if 'fields' not in query]
        self.assertTrue(all(int(query['limit']) == 10000 for query in queries))
        self.assertTrue(any('ticker' in query for query in queries))
        self.assertTrue(all(query['from'] == query['to'] == '2012-02-29'
                            for query in queries if 'ticker' in query))

    def test_full_discovery_response_fails_even_when_all_tickers_repeat(self):
        before = self.store.status()
        self.provider(10001, 'full_ambiguous')
        with self.assertRaisesRegex(UpstreamError, 'complete current ticker universe'):
            self.sync.sync('stocks')
        self.assertEqual(self.store.status(), before)
        self.assertFalse(list((self.store.root / 'raw').glob('*sync*.csv')))
        self.assertFalse(list((self.store.root / 'staging').glob('*sync*.csv')))

    def test_new_symbol_after_discovery_cannot_be_silently_omitted(self):
        before = self.store.status()
        self.provider(10000, 'mutates')
        with self.assertRaisesRegex(UpstreamError, 'ticker universe changed'):
            self.sync.sync('stocks')
        self.assertEqual(self.store.status(), before)
        self.assertFalse(list((self.store.root / 'raw').glob('*sync*.csv')))
        self.assertFalse(list((self.store.root / 'staging').glob('*sync*.csv')))


if __name__ == '__main__':
    unittest.main()
