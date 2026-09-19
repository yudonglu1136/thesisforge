"""Offline regression for source reversions and content-based ingestion no-ops."""
import csv
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from .repository import FactRepository
from .store import Store, checksum
from .test_sync import DDL, FIELDS



class StoreRevisionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fact-store-revision-test-')
        self.root = Path(self.temp.name)
        self.store = Store(self.root / 'facts')
        self.store.install_contract('stocks', DDL)
        self.network = patch('socket.socket', side_effect=AssertionError('network forbidden'))
        self.network.start()

    def tearDown(self):
        self.network.stop()
        self.temp.cleanup()

    def source(self, name, rows):
        path = self.root / name
        with path.open('w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(FIELDS)
            writer.writerows(rows)
        return path

    def row(self, ticker='ABC', value=10, day='2026-09-18'):
        return [ticker, day, value, value, value, '2026-09-19']

    def facts(self):
        with FactRepository(self.store.root) as repo:
            return repo.db.execute(
                'SELECT ticker,date,close,_ingestion_run FROM stocks ORDER BY ticker,date').fetchall()

    def partitions(self):
        return {str(p.relative_to(self.store.root)): checksum(p)
                for p in (self.store.root / 'parquet').rglob('*.parquet')}

    def receipts(self):
        # Test-only read of the closed writer's metadata; no overlapping writer.
        import duckdb
        with duckdb.connect(str(self.store.path), read_only=True) as db:
            return db.execute('SELECT run_id,checksum,scope FROM ingest_runs ORDER BY run_id').fetchall()

    def test_a_b_a_a_restores_values_retains_extra_keys_and_preserves_noop_lineage(self):
        source_a = self.source('a.csv', [self.row(), self.row('KEEP', 7, '1999-01-04')])
        source_b = self.source('b.csv', [self.row(value=11), self.row('EXTRA', 22)])
        first = self.store.ingest('stocks', source_a, scope='verified_full_bulk')
        second = self.store.ingest('stocks', source_b, scope='incremental')
        restored = self.store.ingest('stocks', source_a, scope='incremental')
        self.assertEqual(restored['status'], 'ingested')
        self.assertNotIn(restored['run_id'], (first['run_id'], second['run_id']))
        rows = {ticker: (value, run) for ticker, _, value, run in self.facts()}
        self.assertEqual(rows, {'ABC': (10, restored['run_id']),
                                'EXTRA': (22, second['run_id']),
                                'KEEP': (7, first['run_id'])})
        before_facts, before_partitions = self.facts(), self.partitions()
        repeated = self.store.ingest('stocks', source_a, scope='incremental')
        self.assertEqual(repeated['status'], 'unchanged')
        self.assertNotEqual(repeated['run_id'], restored['run_id'])
        self.assertEqual(self.facts(), before_facts)
        self.assertEqual(self.partitions(), before_partitions)
        with FactRepository(self.store.root) as repo:
            self.assertEqual(repo.db.execute('SELECT count(*) FROM stocks').fetchone()[0], 3)
            self.assertEqual(repo.db.execute('SELECT count(*) FROM (SELECT ticker,date FROM stocks '
                'GROUP BY ticker,date HAVING count(*)>1)').fetchone()[0], 0)
        receipts = self.receipts()
        self.assertEqual(len(receipts), 4)
        self.assertEqual(sum(digest == checksum(source_a) for _, digest, _ in receipts), 3)
        self.assertIn(repeated['run_id'], {run for run, _, _ in receipts})

    def test_unseen_checksum_with_identical_current_subset_is_noop(self):
        full = self.source('full.csv', [self.row(), self.row('EXTRA', 22)])
        subset = self.source('subset.csv', [self.row()])
        self.store.ingest('stocks', full, scope='verified_full_bulk')
        before_facts, before_partitions = self.facts(), self.partitions()
        result = self.store.ingest('stocks', subset, scope='incremental')
        self.assertEqual(result['status'], 'unchanged')
        self.assertEqual(self.facts(), before_facts)
        self.assertEqual(self.partitions(), before_partitions)

    def test_noop_promotes_full_validation_without_rewriting_rows(self):
        source = self.source('a.csv', [self.row()])
        self.store.ingest('stocks', source)
        self.assertFalse(self.store.status()[0]['backfill_complete'])
        before_facts, before_partitions = self.facts(), self.partitions()
        result = self.store.ingest('stocks', source, scope='verified_full_bulk')
        self.assertEqual(result['status'], 'unchanged')
        self.assertTrue(self.store.status()[0]['backfill_complete'])
        self.assertEqual(self.facts(), before_facts)
        self.assertEqual(self.partitions(), before_partitions)
        self.assertIn((result['run_id'], checksum(source), 'verified_full_bulk'), self.receipts())

    def test_seen_checksum_cannot_bypass_scope_quality_validation(self):
        source = self.source('invalid.csv', [self.row(value=0)])
        self.store.ingest('stocks', source, scope='verified_full_bulk')
        repeated = self.store.ingest('stocks', source, scope='incremental')
        self.assertEqual(repeated['status'], 'unchanged')
        before_facts, before_partitions, before_receipts = self.facts(), self.partitions(), self.receipts()
        with self.assertRaisesRegex(ValueError, 'invalid price'):
            self.store.ingest('stocks', source, scope='archive_unverified')
        self.assertEqual(self.facts(), before_facts)
        self.assertEqual(self.partitions(), before_partitions)
        self.assertEqual(self.receipts(), before_receipts)
        catalog = json.loads((self.store.root / 'manifests/catalog.json').read_text())
        self.assertTrue(catalog['datasets']['stocks']['state']['backfill_complete'])
        self.assertEqual(catalog['datasets']['stocks']['quality']['invalid_price:closeunadj'], 1)

    def test_quality_flags_are_restored_with_a_reverted_source(self):
        bad = self.source('a.csv', [self.row(value=0)])
        good = self.source('b.csv', [self.row(value=11)])
        self.store.ingest('stocks', bad, scope='verified_full_bulk')
        self.store.ingest('stocks', good, scope='incremental')
        catalog_path = self.store.root / 'manifests/catalog.json'
        self.assertEqual(json.loads(catalog_path.read_text())['datasets']['stocks']['quality']
                         ['invalid_price:closeunadj'], 0)
        restored = self.store.ingest('stocks', bad, scope='incremental')
        self.assertEqual(restored['status'], 'ingested')
        self.assertEqual(json.loads(catalog_path.read_text())['datasets']['stocks']['quality']
                         ['invalid_price:closeunadj'], 1)
        with FactRepository(self.store.root) as repo:
            value, flag, run = repo.db.execute('SELECT closeunadj,_quality_issues,_ingestion_run FROM stocks').fetchone()
            self.assertEqual(value, 0)
            self.assertIn('invalid_price:closeunadj', flag)
            self.assertEqual(run, restored['run_id'])

    def test_supplied_observation_timestamp_does_not_decide_source_revision_order(self):
        a = self.source('a.csv', [self.row()])
        b = self.source('b.csv', [self.row(value=11)])
        self.store.ingest('stocks', a, scope='verified_full_bulk', observed_at='2026-09-19T12:00:00Z')
        self.store.ingest('stocks', b, scope='incremental', observed_at='2026-09-19T11:00:00Z')
        restored = self.store.ingest('stocks', a, scope='incremental', observed_at='2026-09-19T10:00:00Z')
        self.assertEqual(self.facts()[0][2:], (10, restored['run_id']))


if __name__ == '__main__':
    unittest.main()
