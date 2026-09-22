"""Offline AI Insights publication tests using small synthetic canonical facts."""
import contextlib
import csv
import io
import json
import fcntl
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from .ai_insights import build_ai_insights, load_universe
from .store import Store


class AiInsightsArtifactTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store(self.root / 'facts')
        self.serial = 0
        self.columns = {
            'tickers': [('table', 'TEXT'), ('permaticker', 'INTEGER'), ('ticker', 'TEXT'),
                ('secfilings', 'TEXT'), ('currency', 'TEXT'), ('firstpricedate', 'TEXT'), ('lastupdated', 'TEXT')],
            'fundamentals': [('ticker', 'TEXT'), ('dimension', 'TEXT'), ('date', 'TEXT'),
                ('reportperiod', 'TEXT'), ('calendardate', 'TEXT'), ('fiscalperiod', 'TEXT'),
                ('revenue', 'INTEGER'), ('revenueusd', 'INTEGER'), ('capex', 'INTEGER'), ('lastupdated', 'TEXT')],
        }
        keys = {'tickers': ('table', 'permaticker', 'ticker'), 'fundamentals': ('ticker', 'dimension', 'date', 'reportperiod')}
        for name, columns in self.columns.items():
            ddl = f'CREATE TABLE IF NOT EXISTS "{name}" (' + ','.join(f'"{field}" {kind}' for field, kind in columns)
            ddl += ',PRIMARY KEY (' + ','.join(f'"{field}"' for field in keys[name]) + '));'
            self.store.install_contract(name, ddl)
        self.put('tickers', [['fundamentals', 10, 'TEST', 'https://www.sec.gov/Archives/edgar/data/123/', 'USD', '2023-05-01', '2026-01-01']])
        self.universe = self.root / 'universe.json'
        self.registry = {'schemaVersion': 1, 'universeVersion': 'test-v1', 'knownAt': '2026-01-01',
            'classificationBasis': 'current_registry_retrospective_not_historical_investable',
            'revenueBasis': 'whole_company_revenue_proxy_not_ai_segment_revenue',
            'companies': [{'ticker': 'TEST', 'name': 'Test', 'group': 'hardware', 'sector': 'compute'}]}
        self.universe.write_text(json.dumps(self.registry))
        self.put('fundamentals', [
            ['TEST', 'ARQ', '2024-02-01', '2023-12-31', '2023-12-31', '2023Q4', 100, 100, -10, '2024-02-01'],
            ['TEST', 'ARQ', '2024-05-01', '2023-12-31', '2023-12-31', '2023Q4', 110, 110, -12, '2024-05-01'],
            ['TEST', 'ARQ', '2024-05-01', '2024-03-31', '2024-03-31', '2024Q1', 120, 120, 5, '2024-05-01'],
            ['TEST', 'ARQ', '2024-08-01', '2024-06-30', '2024-06-30', '2024Q2', 130, 130, 0, '2024-08-01'],
            ['TEST', 'ARQ', '2024-11-01', '2024-09-30', '2024-09-30', '2024Q3', 140, 140, '\\N', '2024-11-01'],
            ['TEST', 'MRQ', '2024-02-01', '2023-12-31', '2023-12-31', '2023Q4', 999, 999, -10, '2024-02-01'],
        ])

    def put(self, name, rows):
        self.serial += 1
        path = self.root / f'fixture-{self.serial}.csv'
        with path.open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow([field for field, _ in self.columns[name]])
            writer.writerows(rows)
        self.store.ingest(name, path)

    def build(self):
        return build_ai_insights(self.store.root, universe_path=self.universe)

    def test_preserves_revisions_signed_capex_and_missing_separately(self):
        catalog = self.store.root / 'manifests/catalog.json'
        original = catalog.read_bytes()
        result = self.build()
        artifact = json.loads(Path(result['artifactPath']).read_text())
        rows = artifact['facts']
        self.assertEqual(len(rows), 5)
        self.assertEqual([row['revenue'] for row in rows], [100, 110, 120, 130, 140])
        self.assertEqual([row['capex'] for row in rows], [-10, -12, 5, 0, None])
        self.assertEqual(rows[2]['capexStatus'], 'net_disposal_inflow')
        self.assertEqual(rows[3]['capexStatus'], 'provider_zero_unverified')
        self.assertEqual(rows[4]['capexStatus'], 'missing')
        self.assertEqual(len({row['sourceRevisionId'] for row in rows}), 5)
        self.assertEqual(rows[0]['source']['key']['date'], '2024-02-01')
        self.assertEqual(artifact['companies'][0]['issuerId'], 'sec:cik:123')
        self.assertIsNone(artifact['companies'][0]['listingDate'])
        self.assertEqual(catalog.read_bytes(), original)

    def test_same_input_replay_keeps_artifact_and_manifest_bytes_and_mtimes(self):
        first = self.build()
        manifest = Path(first['manifestPath'])
        artifact = Path(first['artifactPath'])
        stamp = lambda path: (path.read_bytes(), path.stat().st_mtime_ns)
        before = (stamp(manifest), stamp(artifact))
        replay = self.build()
        self.assertEqual(replay['status'], 'no_op')
        self.assertEqual(replay['generationId'], first['generationId'])
        self.assertEqual((stamp(manifest), stamp(artifact)), before)
        self.assertTrue(json.loads(Path(replay['auditPath']).read_text())['sameInputReplay'])

    def test_unrelated_catalog_publication_keeps_financial_identity_and_artifact(self):
        first = self.build()
        manifest = Path(first['manifestPath'])
        artifact = Path(first['artifactPath'])
        initial = json.loads(artifact.read_text())
        before = (manifest.read_bytes(), manifest.stat().st_mtime_ns,
                  artifact.read_bytes(), artifact.stat().st_mtime_ns)
        self.put('tickers', [['fundamentals', 99, 'OTHER',
            'https://www.sec.gov/Archives/edgar/data/999/', 'USD',
            '2024-01-01', '2026-01-02']])
        replay = self.build()
        self.assertEqual(replay['status'], 'no_op')
        self.assertEqual((manifest.read_bytes(), manifest.stat().st_mtime_ns,
                          artifact.read_bytes(), artifact.stat().st_mtime_ns), before)
        current = json.loads(artifact.read_text())
        self.assertEqual([row['sourceRevisionId'] for row in current['facts']],
                         [row['sourceRevisionId'] for row in initial['facts']])

    def test_new_public_revision_preserves_previous_generation(self):
        first = self.build()
        old = Path(first['artifactPath']).read_bytes()
        self.put('fundamentals', [['TEST', 'ARQ', '2024-12-01', '2024-09-30', '2024-09-30', '2024Q3', 145, 145, -6, '2024-12-01']])
        second = self.build()
        self.assertNotEqual(second['generationId'], first['generationId'])
        self.assertEqual(Path(first['artifactPath']).read_bytes(), old)
        prior_manifest = Path(first['artifactPath']).with_suffix('.manifest.json')
        self.assertEqual(json.loads(prior_manifest.read_text())['generationId'], first['generationId'])
        self.assertEqual(json.loads(Path(second['artifactPath']).with_suffix('.manifest.json').read_text())['generationId'], second['generationId'])
        self.assertEqual(second['after']['rowCount'], 6)
        self.assertEqual(second['before']['oldestDatekey'], second['after']['oldestDatekey'])

    def test_no_op_restores_missing_sidecar_without_changing_current_manifest(self):
        first = self.build()
        sidecar = Path(first['artifactPath']).with_suffix('.manifest.json')
        expected = sidecar.read_bytes()
        sidecar.unlink()
        manifest = Path(first['manifestPath'])
        before = (manifest.read_bytes(), manifest.stat().st_mtime_ns)
        self.assertEqual(self.build()['status'], 'no_op')
        self.assertEqual(sidecar.read_bytes(), expected)
        self.assertEqual((manifest.read_bytes(), manifest.stat().st_mtime_ns), before)

    def test_writer_lock_is_respected(self):
        with (self.store.root / 'sync/writer.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.build()

    def test_scope_events_preserve_effective_date_proxy_and_canonical_evidence(self):
        self.columns['actions'] = [('date', 'TEXT'), ('action', 'TEXT'), ('ticker', 'TEXT'),
            ('name', 'TEXT'), ('value', 'REAL'), ('contraticker', 'TEXT'), ('contraname', 'TEXT')]
        self.store.install_contract('actions', '''CREATE TABLE IF NOT EXISTS "actions" (
            "date" TEXT, "action" TEXT, "ticker" TEXT, "name" TEXT, "value" REAL,
            "contraticker" TEXT, "contraname" TEXT,
            PRIMARY KEY ("date","action","ticker","name","contraticker","contraname"));''')
        self.put('actions', [
            ['2024-02-24', 'spinoff', 'TEST', 'Test', 0.5, 'OTHER', 'Other'],
            ['2024-02-25', 'split', 'TEST', 'Test', 2, 'N/A', 'N/A'],
            ['2024-02-26', 'namechangefrom', 'TEST', 'Test', '\\N', 'N/A', 'Old Test'],
        ])
        result = self.build()
        company = json.loads(Path(result['artifactPath']).read_text())['companies'][0]
        self.assertEqual(len(company['corporateActions']), 1)
        event = company['corporateActions'][0]
        self.assertEqual((event['type'], event['date'], event['knownAt']), ('spinoff', '2024-02-24', '2024-02-24'))
        self.assertEqual(event['basis'], 'provider_effective_date_proxy')
        self.assertEqual(event['source']['key']['contraticker'], 'OTHER')
        self.assertEqual(event['source']['table'], 'actions')
        self.assertTrue(event['sourceRevisionId'].startswith('action:'))
        self.assertEqual(company['corporateActionsCoverage'], 'provider_actions_not_complete_scope_bridge')

    def test_ambiguous_share_classes_fail_without_replacing_published_manifest(self):
        first = self.build()
        manifest = Path(first['manifestPath'])
        before = manifest.read_bytes()
        self.put('tickers', [['fundamentals', 11, 'OTHER', 'https://www.sec.gov/Archives/edgar/data/123/', 'USD', '2023-05-01', '2026-01-01']])
        self.registry['companies'].append({'ticker': 'OTHER', 'name': 'Other', 'group': 'hardware', 'sector': 'compute'})
        self.universe.write_text(json.dumps(self.registry))
        with self.assertRaisesRegex(ValueError, 'duplicate issuer'):
            self.build()
        self.assertEqual(manifest.read_bytes(), before)

    def test_history_regression_does_not_replace_published_manifest(self):
        first = self.build()
        manifest = Path(first['manifestPath'])
        before = manifest.read_bytes()
        # Model a bad upstream-derived snapshot without modifying canonical data.
        from .ai_insights import collect
        def truncated(repo, universe):
            companies, rows = collect(repo, universe)
            return companies, rows[1:]
        self.put('tickers', [['fundamentals', 10, 'TEST', 'https://www.sec.gov/Archives/edgar/data/123/', 'USD', '2023-05-01', '2026-01-02']])
        with patch('fact_os.ai_insights.collect', side_effect=truncated):
            with self.assertRaisesRegex(ValueError, 'regressed'):
                self.build()
        self.assertEqual(manifest.read_bytes(), before)


class AiInsightsDailyHookTest(unittest.TestCase):
    def run_cli(self, sync_error=False, artifact_error=False, tables=('fundamentals',)):
        from .__main__ import main
        with tempfile.TemporaryDirectory() as temporary:
            output = io.StringIO()
            with patch('sys.argv', ['fact-os', '--root', temporary, 'sync', '--tables', *tables]), \
                    patch('fact_os.sync.load_key', return_value='local-test-only'), \
                    patch('fact_os.sync.Synchronizer') as sync_class, \
                    patch('fact_os.ai_insights.build_ai_insights') as build, \
                    patch.object(Store, 'status', return_value=[
                        {'dataset': 'fundamentals', 'backfill_complete': True},
                        {'dataset': 'tickers', 'backfill_complete': True},
                    ]), \
                    contextlib.redirect_stdout(output):
                sync_class.return_value.sync.side_effect = RuntimeError('failure') if sync_error else None
                sync_class.return_value.sync.return_value = {'dataset': 'fundamentals', 'status': 'no_op'}
                build.side_effect = ValueError('failure') if artifact_error else None
                build.return_value = {'status': 'published'}
                status = main()
            return status, build.call_count, output.getvalue()

    def test_successful_daily_sync_refreshes_ai_insights(self):
        status, calls, output = self.run_cli()
        self.assertEqual((status, calls), (0, 1))
        self.assertIn('"derived": "ai-insights"', output)

    def test_failed_source_sync_does_not_publish_a_partial_analysis(self):
        self.assertEqual(self.run_cli(sync_error=True)[:2], (1, 0))

    def test_price_only_sync_does_not_rebuild_ai_insights(self):
        status, calls, output = self.run_cli(tables=('daily',))
        self.assertEqual((status, calls), (0, 0))
        self.assertIn('no_relevant_dependency_updated', output)

    def test_derived_failure_makes_daily_job_nonzero_and_retains_old_generation(self):
        status, calls, output = self.run_cli(artifact_error=True)
        self.assertEqual((status, calls), (1, 1))
        self.assertIn('"previous_generation_retained": true', output)


if __name__ == '__main__':
    unittest.main()
