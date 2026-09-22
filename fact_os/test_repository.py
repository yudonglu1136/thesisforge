"""Offline semantic contract regressions; all fixture data is synthetic."""
import csv
import fcntl
import json
from datetime import date
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from .repository import FactRepository, MissingData, PITUnavailable
from .store import Store
from .test_fact_os import SCHEMAS, KEYS


class RepositoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = Store(self.root / 'warehouse')
        self.serial = 0
        self.schemas = {key: list(value) for key, value in SCHEMAS.items()}
        self.keys = dict(KEYS)
        self.schemas['tickers'] += [('name', 'TEXT'), ('lastpricedate', 'TEXT'), ('firstquarter', 'TEXT'), ('lastquarter', 'TEXT')]
        self.schemas['actions'] = [('date', 'TEXT'), ('action', 'TEXT'), ('ticker', 'TEXT'), ('name', 'TEXT'), ('value', 'REAL'), ('contraticker', 'TEXT'), ('contraname', 'TEXT')]
        self.keys['actions'] = ('date', 'action', 'ticker', 'name', 'contraticker', 'contraname')
        self.schemas['daily'] = [('ticker', 'TEXT'), ('date', 'TEXT'), ('marketcap', 'REAL'), ('lastupdated', 'TEXT')]
        self.keys['daily'] = ('ticker', 'date')
        self.schemas['funds'] = list(self.schemas['stocks'])
        self.keys['funds'] = self.keys['stocks']
        for table, columns in self.schemas.items():
            ddl = f'CREATE TABLE IF NOT EXISTS "{table}" (' + ','.join(f'"{field}" {kind}' for field, kind in columns)
            ddl += ',PRIMARY KEY (' + ','.join(f'"{field}"' for field in self.keys[table]) + '));'
            self.store.install_contract(table, ddl)
        self.put('tickers', [
            ['stocks', 10, 'NEW', 'https://www.sec.gov/Archives/edgar/data/123/', '2024-06-01', 'Issuer', '2024-06-01', '', ''],
            ['stocks', 11, 'CLASSB', 'https://www.sec.gov/cgi-bin/browse-edgar?CIK=0000123', '2024-06-01', 'Issuer Class B', '2024-06-01', '', ''],
            ['holdings_investor', 90, 'FIRM01', 'https://www.sec.gov/cgi-bin/browse-edgar?CIK=000999', '2024-06-01', 'Exact Firm LP', '', '2013-06-30', '2024-03-31'],
        ])

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, table, rows, scope='archive_unverified'):
        self.serial += 1
        path = self.root / f'{self.serial}.csv'
        with path.open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow([field for field, _ in self.schemas[table]])
            writer.writerows(rows)
        return self.store.ingest(table, path, scope=scope)

    def test_snapshot_reader_survives_writer_and_pins_generation(self):
        self.put('stocks', [['NEW', '2024-01-02', 10, 9, 20, '2024-01-03']])
        with FactRepository(self.store.root) as old:
            self.put('stocks', [['NEW', '2024-01-02', 11, 10, 22, '2024-01-04']])
            with self.store.writer():
                with FactRepository(self.store.root) as fresh:
                    self.assertEqual(fresh.get_price('NEW', '2024-01-02', 'RAW_CLOSE')['value'], 22)
            self.assertEqual(old.get_price('NEW', '2024-01-02', 'RAW_CLOSE')['value'], 20)

    def test_pinned_readers_block_exclusive_gc_until_all_close(self):
        first = FactRepository(self.store.root)
        second = FactRepository(self.store.root)
        try:
            with (self.store.root / 'sync/readers.lock').open('a') as gc:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(gc, fcntl.LOCK_EX | fcntl.LOCK_NB)
                first.close()
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(gc, fcntl.LOCK_EX | fcntl.LOCK_NB)
                second.close()
                fcntl.flock(gc, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(gc, fcntl.LOCK_UN)
        finally:
            first.close(); second.close()

    def test_reader_initialization_failure_releases_gc_lock(self):
        path = self.store.root / 'manifests/catalog.json'
        catalog = json.loads(path.read_text()); catalog['version'] = 999
        path.write_text(json.dumps(catalog))
        with self.assertRaises(MissingData): FactRepository(self.store.root)
        with (self.store.root / 'sync/readers.lock').open('a') as gc:
            fcntl.flock(gc, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(gc, fcntl.LOCK_UN)

    def test_new_quality_field_coexists_with_old_parquet_schema(self):
        self.put('stocks', [['NEW', '2000-01-03', 5, 4, 10, '2024-01-03'],
                            ['NEW', '2024-01-02', 10, 9, 20, '2024-01-03']])
        manifest = self.store.root / 'manifests/catalog.json'
        catalog = json.loads(manifest.read_text())
        old = next(part for part in catalog['datasets']['stocks']['partitions'] if part['bucket'] == 2000)
        legacy_path = self.store.root / 'parquet/stocks/legacy-fixture.parquet'
        import duckdb
        with duckdb.connect(':memory:') as database:
            source = str(self.store.root / old['path']).replace("'", "''")
            target = str(legacy_path).replace("'", "''")
            database.execute(f"COPY (SELECT * EXCLUDE(_quality_issues) FROM read_parquet('{source}')) TO '{target}' (FORMAT PARQUET)")
        old['path'] = str(legacy_path.relative_to(self.store.root))
        manifest.write_text(json.dumps(catalog))
        with FactRepository(self.store.root) as repo:
            rows = repo.get_price_history('NEW', '2000-01-01', '2024-02-01', 'RAW_CLOSE')
            self.assertEqual([row['value'] for row in rows], [10, 20])
            self.assertIsNone(rows[0]['provenance']['quality_issues'])

    def test_feature_registry_references_canonical_facts_and_versions(self):
        from .registry import FeatureDefinition, FeatureEngine, MetricRegistry, default_registry
        self.put('fundamentals', [['NEW', 'ART', '2024-02-01', '2023-12-31', 100, 10, '2024-02-01']])
        registry = default_registry()
        with self.assertRaises(ValueError):
            registry.register(FeatureDefinition('FCFMargin', '1', ('Revenue',), 'ratio', lambda values: 1))
        with self.assertRaises(ValueError):
            registry.register(FeatureDefinition('Bad', '1', ('revenueusd',), 'ratio', lambda values: 1))
        with FactRepository(self.store.root) as repo:
            fact = FeatureEngine(repo, registry).calculate('FCFMargin', '1', 'NEW', '2024-03-01')
            self.assertEqual(fact['value'], .1)
            self.assertEqual(fact['calculation_version'], '1')
            self.assertEqual(fact['input_facts']['Revenue']['company_id'], 'sec:cik:123')
        self.assertEqual(MetricRegistry().get('InstitutionalShareUnits')['unit'], 'shares')

    def test_explicit_aliases_and_share_classes(self):
        self.put('actions', [
            ['2022-06-09', 'tickerchangefrom', 'NEW', 'Issuer', '', 'OLD', ''],
            ['2022-06-09', 'tickerchangeto', 'NEW', 'Issuer', '', 'NEW', ''],
        ])
        self.put('stocks', [['NEW', '2020-01-02', 10, 9, 20, '2024-01-03']])
        with FactRepository(self.store.root) as repo:
            current = repo.resolve_security('NEW')
            self.assertEqual(current['security_id'], repo.resolve_security('OLD')['security_id'])
            other = repo.resolve_security('CLASSB')
            self.assertEqual(current['company_id'], other['company_id'])
            self.assertNotEqual(current['security_id'], other['security_id'])
            self.assertEqual(repo.get_price('sharadar:security:10', '2020-01-02', 'RAW_CLOSE')['value'], 20)
            event = repo.get_ticker_history('OLD')[0]
            self.assertEqual((event['from_ticker'], event['to_ticker']), ('OLD', 'NEW'))

    def test_reused_ticker_does_not_merge_companies(self):
        self.put('actions', [['2022-06-09', 'tickerchangefrom', 'NEW', 'Issuer', '', 'OLD', '']])
        self.put('tickers', [['stocks', 20, 'OLD', 'https://www.sec.gov/Archives/edgar/data/456/', '2024-06-01', 'Different issuer', '2024-06-01', '', '']])
        with FactRepository(self.store.root) as repo:
            self.assertNotEqual(repo.resolve_security('NEW')['security_id'], repo.resolve_security('OLD')['security_id'])
            self.assertNotEqual(repo.resolve_security('NEW')['company_id'], repo.resolve_security('OLD')['company_id'])

    def test_batch_prices_are_offline_explicit_and_partial(self):
        self.put('stocks', [['NEW', '2024-01-02', 10, 9, 20, '2024-01-03']])
        with patch('socket.socket', side_effect=AssertionError('network forbidden')):
            with FactRepository(self.store.root) as repo:
                result = repo.get_prices(['NEW', 'CLASSB', 'UNKNOWN'], '2024-01-03', 'TOTAL_RETURN_ADJUSTED_CLOSE')
                self.assertEqual(result['NEW']['value'], 9)
                self.assertIsNone(result['CLASSB'])
                self.assertIsNone(result['UNKNOWN'])
                with self.assertRaises(ValueError):
                    repo.get_price('NEW', '2024-01-03', 'adjusted')

    def test_batch_invalid_quote_does_not_erase_other_securities(self):
        self.put('stocks', [
            ['NEW', '2024-01-02', 10, 9, 0, '2024-01-03'],
            ['CLASSB', '2024-01-02', 20, 19, 40, '2024-01-03'],
        ], scope='verified_full_bulk')
        with FactRepository(self.store.root) as repo:
            result = repo.get_prices(['NEW', 'CLASSB'], '2024-01-03', 'RAW_CLOSE')
            self.assertIsNone(result['NEW'])
            self.assertEqual(result['CLASSB']['value'], 40)
            self.assertEqual(repo.get_price('NEW', '2024-01-03', 'SPLIT_ADJUSTED_CLOSE')['value'], 10)
            with self.assertRaises(MissingData): repo.get_price('NEW', '2024-01-03', 'RAW_CLOSE')

    def test_dividend_semantics_do_not_invent_payment(self):
        self.put('actions', [['2024-03-01', 'dividend', 'NEW', 'Issuer', .25, '', '']])
        with FactRepository(self.store.root) as repo:
            fact = repo.get_dividends('NEW', '2024-01-01', '2024-12-31')[0]
            self.assertEqual(fact['unit'], 'USD/share')
            self.assertEqual(fact['basis'], 'split_and_stock_dividend_adjusted_per_share')
            self.assertEqual(fact['ex_date'], date(2024, 3, 1))
            self.assertIsNone(fact['payment_date'])
            self.assertFalse(fact['cash_accounting_ready'])

    def test_fundamental_research_is_bounded_pit_and_never_mixes_restated_rows(self):
        self.put('fundamentals', [
            ['NEW', 'ARQ', '2024-05-01', '2024-03-31', 100, 10, '2024-05-01'],
            ['NEW', 'ARQ', '2024-05-03', '2024-03-31', 101, 11, '2024-05-03'],
            ['NEW', 'ARQ', '2024-08-01', '2024-06-30', 120, 13, '2024-08-01'],
            ['NEW', 'ARY', '2024-02-01', '2023-12-31', 400, 40, '2024-02-01'],
            ['NEW', 'MRY', '2023-12-31', '2023-12-31', 999, 99, '2026-01-01'],
        ], scope='verified_full_bulk')
        with FactRepository(self.store.root) as repo:
            early = repo.get_fundamental_research('NEW', '2024-05-02')
            self.assertEqual(early['quarterly'][0]['revenue'], 100)
            current = repo.get_fundamental_research('NEW', '2024-09-01', quarters=4, years=2)
            self.assertEqual([row['revenue'] for row in current['quarterly']], [120, 101])
            self.assertEqual([row['revenue'] for row in current['annual']], [400])
            self.assertEqual(current['restated_basis'], 'withheld_in_historical_pit; MRQ/MRY are not mixed with as-reported facts')
            self.assertEqual(current['quarterly'][0]['pit_basis'], 'as_reported_filing_date_day_precision')
            with self.assertRaises(ValueError):
                repo.get_fundamental_research('NEW', '2024-09-01', quarters=100)

    def test_fundamental_company_index_is_pit_bounded_and_model_independent(self):
        self.put('fundamentals', [
            ['NEW', 'ARQ', '2024-05-01', '2024-03-31', 100, 10, '2024-05-01'],
            ['NEW', 'ARQ', '2024-08-01', '2024-06-30', 120, 13, '2024-08-01'],
        ], scope='verified_full_bulk')
        with FactRepository(self.store.root) as repo:
            early = repo.get_fundamental_company_index('2024-05-02')
            self.assertEqual(early['version'], 'fact-fundamental-company-index-v1')
            self.assertEqual(early['companies'][0]['available_at'], date(2024, 5, 1))
            self.assertEqual(early['companies'][0]['period_end'], date(2024, 3, 31))
            current = repo.get_fundamental_company_index('2024-09-01')
            self.assertEqual(current['companies'][0]['period_end'], date(2024, 6, 30))

    def test_fundamental_change_metrics_preserve_missing_and_semantic_names(self):
        points = []
        for rank in range(1, 9):
            points.append({'quarter_rank': rank, 'revenue': 100 - rank,
                           'opinc': 20 - rank, 'ebit': 21 - rank,
                           'netinccmn': 10 - rank, 'ncfo': 15 - rank,
                           'capex': -(5 + rank), 'fcf': 9 - rank,
                           'sbcomp': 2, 'ncfcommon': -3, 'ncfdiv': -1,
                           'intexp': -1, 'shareswadil': 100 + rank,
                           'invcap': 200 + rank})
        metrics = FactRepository._quarter_metrics(points)
        self.assertIn('netCommonFinancing', metrics)
        self.assertIn('preTaxCapitalReturn', metrics)
        self.assertNotIn('grossBuybacks', metrics)
        self.assertNotIn('roic', metrics)
        points[2]['fcf'] = None
        self.assertIsNone(FactRepository._quarter_metrics(points)['fcfMargin'])

    def test_research_point_exposes_three_statement_rows_without_zero_fill(self):
        row = {
            'ticker': 'NEW', 'dimension': 'ARY', 'date': '2025-02-01',
            'reportperiod': '2024-12-31', 'cor': 60, 'taxexp': 5,
            'liabilities': 120, 'receivables': 30, 'ncfi': -20,
            'ncfdebt': None, 'depamor': 7,
        }
        point = FactRepository._research_point(row, {'source': 'fixture'})
        self.assertEqual(point['cor'], 60)
        self.assertEqual(point['liabilities'], 120)
        self.assertEqual(point['ncfi'], -20)
        self.assertIsNone(point['ncfdebt'])
        self.assertNotIn('inventory', point)
        self.assertEqual(point['period_end'], '2024-12-31')

    def test_official_master_routes_funds_not_provider_fallback(self):
        self.put('tickers', [['funds', 30, 'ETF', '', '2024-06-01', 'Index fund', '2024-06-01', '', '']])
        self.put('funds', [['ETF', '2024-01-02', 50, 49, 50, '2024-01-03']])
        self.put('stocks', [['NEW', '2024-01-02', 10, 9, 20, '2024-01-03']])
        with FactRepository(self.store.root) as repo:
            self.assertEqual(repo.resolve_security('ETF')['price_dataset'], 'funds')
            self.assertEqual(repo.get_price('ETF', '2024-01-03', 'RAW_CLOSE')['value'], 50)
            mixed = repo.get_prices(['ETF', 'NEW', 'UNKNOWN'], '2024-01-03', 'RAW_CLOSE')
            self.assertEqual((mixed['ETF']['value'], mixed['NEW']['value'], mixed['UNKNOWN']), (50, 20, None))
            self.assertIsNone(repo.get_price('ETF', '2024-01-03', 'RAW_CLOSE', dataset='stocks'))

    def test_latest_fundamentals_select_newest_period_not_old_amendment(self):
        self.put('fundamentals', [
            ['NEW', 'ART', '2024-02-01', '2023-12-31', 100, 10, '2024-02-01'],
            ['NEW', 'ART', '2024-05-01', '2024-03-31', 120, 12, '2024-05-01'],
            ['NEW', 'ART', '2024-05-15', '2023-12-31', 101, 11, '2024-05-15'],
            ['NEW', 'MRT', '2023-12-31', '2023-12-31', 999, 99, '2025-01-01'],
        ])
        with FactRepository(self.store.root) as repo:
            self.assertEqual(repo.get_metric('NEW', 'Revenue', as_of='2024-05-20')['value'], 120)
            before = repo.get_latest_fundamentals(['NEW', 'UNKNOWN'], as_of='2024-04-01')
            after = repo.get_latest_fundamentals(['NEW', 'UNKNOWN'], as_of='2024-05-20')
            self.assertEqual(before['NEW']['revenue'], 100)
            self.assertEqual(after['NEW']['revenue'], 120)
            self.assertIsNone(after['UNKNOWN'])
            with self.assertRaises(PITUnavailable):
                repo.get_latest_fundamentals(['NEW'], 'MRT', as_of='2024-05-20')

    def test_investor_identity_exact_and_no_fuzzy_guess(self):
        with FactRepository(self.store.root) as repo:
            one = repo.resolve_investor(cik='0000999')
            two = repo.resolve_investor(name='Exact Firm LP')
            self.assertEqual(one['institutional_investor_id'], two['institutional_investor_id'])
            self.assertEqual(one['investor_id'], 'FIRM01')
            with self.assertRaises(MissingData):
                repo.resolve_investor(name='Exact Firm')
            with self.assertRaises(ValueError):
                repo.resolve_investor('FIRM01', cik='999')

    def test_all_security_types_preserved_without_false_stock_changes(self):
        self.put('holdings', [
            ['NEW', 'FIRM01', 'SHR', '2023-12-31', 2, 4],
            ['NEW', 'FIRM01', 'CLL', '2023-12-31', 1, 3],
            ['NEW', 'FIRM01', 'SHR', '2024-03-31', 3, 5],
            ['NEW', 'FIRM01', 'CLL', '2024-03-31', .5, 2],
            ['CLASSB', 'FIRM01', 'PRF', '2024-03-31', .5, 1],
        ], scope='verified_full_bulk')
        with FactRepository(self.store.root) as repo:
            portfolio = repo.get_investor_portfolio('FIRM01', '2024-03-31', None)
            self.assertEqual({row['security_type'] for row in portfolio}, {'SHR', 'CLL', 'PRF'})
            self.assertAlmostEqual(sum(row['portfolio_weight'] for row in portfolio), 1)
            self.assertEqual(portfolio[0]['value_usd'], 3000000)
            changes = repo.get_investor_changes('FIRM01', '2024-03-31', None)
            self.assertEqual({(row['ticker'], row['security_type']): row['change'] for row in changes},
                {('NEW', 'SHR'): 'INCREASED', ('NEW', 'CLL'): 'DECREASED', ('CLASSB', 'PRF'): 'NEW'})
            self.assertEqual(repo.get_investor_portfolio('FIRM01', '2024-03-31', 'CALL')[0]['security_type'], 'CLL')

    def test_institutional_metric_units_and_missing_pit(self):
        self.put('holdings_ticker', [['2024-03-31', 'NEW', 3, 4, 5, 6, .01]])
        self.put('daily', [['NEW', '2024-04-01', 123, '2024-04-01']])
        with FactRepository(self.store.root) as repo:
            fact = repo.get_metric('NEW', 'InstitutionalShareUnits')
            self.assertEqual(fact['value'], 4000)
            self.assertFalse(fact['pit_supported'])
            self.assertIsNone(fact['available_at'])
            self.assertEqual(repo.get_metric('NEW', 'MarketCap', as_of='2024-04-02')['value'], 123000000)
            with self.assertRaises(PITUnavailable):
                repo.get_metric('NEW', 'InstitutionalShareUnits', as_of='2024-05-01')
            with self.assertRaises(PITUnavailable):
                repo.get_institutional_ownership_history('NEW', as_of='2024-05-01')

    def test_conflicting_alias_facts_fail_instead_of_double_counting(self):
        self.put('tickers', [['stocks', 10, 'OLD', 'https://www.sec.gov/Archives/edgar/data/123/', '2020-01-01', 'Issuer', '2020-01-01', '', '']])
        self.put('stocks', [['NEW', '2024-01-02', 10, 9, 20, '2024-01-03'], ['OLD', '2024-01-02', 10, 9, 21, '2024-01-03'], ['CLASSB', '2024-01-02', 30, 29, 60, '2024-01-03']])
        with FactRepository(self.store.root) as repo:
            with self.assertRaises(MissingData):
                repo.get_price_history('NEW', '2024-01-01', '2024-01-03', 'RAW_CLOSE')
            result = repo.get_prices(['NEW', 'CLASSB'], '2024-01-03', 'RAW_CLOSE')
            self.assertIsNone(result['NEW'])
            self.assertEqual(result['CLASSB']['value'], 60)


if __name__ == '__main__':
    unittest.main()
