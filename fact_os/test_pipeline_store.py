"""Publication/outbox regressions; all fixtures are isolated synthetic facts."""
import json
from unittest.mock import patch

from .store import checksum
from .test_store_revision import StoreRevisionTest


class PipelineStoreTest(StoreRevisionTest):
    def test_noop_and_operational_failure_do_not_change_catalog_identity(self):
        source = self.source('a.csv', [self.row()])
        self.store.ingest('stocks', source, scope='verified_full_bulk')
        catalog = self.store.root / 'manifests/catalog.json'
        before = (catalog.read_bytes(), catalog.stat().st_mtime_ns)
        self.store.ingest('stocks', source, scope='incremental')
        self.store.record_error('stocks', 'upstream_timeout')
        self.assertEqual((catalog.read_bytes(), catalog.stat().st_mtime_ns), before)
        self.assertEqual(self.store.status()[0]['last_error'], 'upstream_timeout')

    def test_unchanged_rows_in_a_changed_partition_keep_lineage(self):
        first = self.store.ingest('stocks', self.source('a.csv', [self.row(), self.row('KEEP', 7)]))
        second = self.store.ingest('stocks', self.source('b.csv', [self.row(value=11), self.row('KEEP', 7)]))
        rows = {ticker: run for ticker, _, _, run in self.facts()}
        self.assertEqual(rows, {'ABC': second['run_id'], 'KEEP': first['run_id']})

    def test_commit_before_catalog_crash_recovers_pending_events(self):
        source = self.source('a.csv', [self.row()])
        with patch.object(self.store, '_publish_manifest', side_effect=OSError('simulated crash')):
            with self.assertRaises(OSError):
                self.store.ingest('stocks', source, scope='verified_full_bulk')
        import duckdb
        with duckdb.connect(str(self.store.path), read_only=True) as db:
            self.assertEqual(db.execute('SELECT status FROM source_change_events').fetchall(), [('committed',)])
        self.store.recover_catalog()
        catalog = self.store.root / 'manifests/catalog.json'
        with duckdb.connect(str(self.store.path), read_only=True) as db:
            status, generation = db.execute('SELECT status,catalog_generation FROM source_change_events').fetchone()
        self.assertEqual(status, 'catalog_published')
        self.assertEqual(generation, checksum(catalog))
        data = json.loads(catalog.read_text())['datasets']['stocks']
        self.assertTrue(data['contentVersion'])
        self.assertEqual(data['partitions'][0]['sha256'], checksum(self.store.root / data['partitions'][0]['path']))

