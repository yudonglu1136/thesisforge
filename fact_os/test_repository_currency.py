"""Synthetic ADR currency fixtures; no network or production archive access."""
import copy
import csv
from datetime import date
from pathlib import Path
import tempfile
import unittest

from .repository import FactRepository
from .registry import FeatureDefinition, FeatureEngine, FeatureRegistry, METRICS, default_registry
from .store import Store
from .test_fact_os import SCHEMAS, KEYS


class CurrencyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = Store(self.root / 'warehouse')
        self.serial = 0
        self.schemas = {table: list(SCHEMAS[table]) for table in ('tickers', 'fundamentals')}
        self.schemas['tickers'].append(('currency', 'TEXT'))
        self.schemas['daily'] = [('ticker', 'TEXT'), ('date', 'TEXT'), ('marketcap', 'REAL'), ('lastupdated', 'TEXT')]
        for table, columns in self.schemas.items():
            keys = KEYS[table] if table != 'daily' else ('ticker', 'date')
            ddl = f'CREATE TABLE IF NOT EXISTS "{table}" (' + ','.join(f'"{name}" {kind}' for name, kind in columns)
            ddl += ',PRIMARY KEY (' + ','.join(f'"{name}"' for name in keys) + '));'
            self.store.install_contract(table, ddl)
        self.put('tickers', [
            ['SEP', 10, 'ADR_A', '', '2024-06-01', 'USD'],
            ['SF1', 10, 'ADR_A', '', '2024-06-01', 'CNY'],
            ['SEP', 20, 'ADR_B', '', '2024-06-01', 'USD'],
            ['SF1', 20, 'ADR_B', '', '2024-06-01', 'TWD'],
            ['SEP', 30, 'NO_SF1', '', '2024-06-01', 'USD'],
        ])
        self.put('fundamentals', [
            ['ADR_A', 'ART', '2024-02-01', '2023-12-31', 100, 10, '2024-02-01'],
            ['ADR_A', 'ART', '2024-05-01', '2024-03-31', 120, 12, '2024-05-01'],
            ['ADR_B', 'ART', '2024-05-01', '2024-03-31', 200, 50, '2024-05-01'],
            ['NO_SF1', 'ART', '2024-05-01', '2024-03-31', 300, 30, '2024-05-01'],
        ])
        # Matching period tests the currency guard, not the independent period guard.
        self.put('daily', [['ADR_A', '2024-03-31', 2, '2024-04-01']])

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, table, rows):
        self.serial += 1
        path = self.root / f'{self.serial}.csv'
        with path.open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow([name for name, _ in self.schemas[table]])
            writer.writerows(rows)
        return self.store.ingest(table, path)

    def test_current_adr_currency_is_sf1_not_us_quote_currency(self):
        with FactRepository(self.store.root) as repo:
            for ticker, currency, value in [('ADR_A', 'CNY', 120), ('ADR_B', 'TWD', 200)]:
                fact = repo.get_metric(ticker, 'Revenue')
                self.assertEqual((fact['value'], fact['unit'], fact['currency']), (value, 'reporting_currency', currency))
                self.assertEqual(fact['currency_basis'], 'current_sf1_master_not_historical')
                self.assertFalse(fact['currency_pit_supported'])
                self.assertEqual(fact['currency_provenance'][0]['key']['table'], 'SF1')
                self.assertEqual(fact['currency_provenance'][0]['key']['ticker'], ticker)
                self.assertTrue(fact['currency_provenance'][0]['ingestion_run'])
            self.assertEqual(repo.get_metric('sharadar:security:10', 'FreeCashFlow')['currency'], 'CNY')
            cap = repo.get_metric('ADR_A', 'MarketCap')
            self.assertEqual((cap['value'], cap['currency']), (2000000, 'USD'))

    def test_history_and_explicit_asof_never_backfill_current_currency(self):
        with FactRepository(self.store.root) as repo:
            for rows in [repo.get_metric_history('ADR_A', 'Revenue'),
                         repo.get_metric_history('ADR_A', 'FreeCashFlow', as_of='2024-06-01'),
                         [repo.get_metric('ADR_A', 'Revenue', as_of='2024-06-01')]]:
                for fact in rows:
                    self.assertIsNone(fact['currency'])
                    self.assertEqual(fact['currency_basis'], 'historical_reporting_currency_unavailable')
                    self.assertFalse(fact['currency_pit_supported'])
                    self.assertEqual(fact['currency_provenance'], [])
            self.assertEqual(repo.get_metric('ADR_A', 'Revenue')['currency'], 'CNY')
            self.assertIsNone(repo.get_metric_history('ADR_A', 'Revenue')[-1]['currency'])

    def test_missing_sf1_never_uses_quote_currency_or_similar_ticker(self):
        self.put('tickers', [['SF1', 31, 'NO_SF1_OTHER', '', '2024-06-01', 'EUR']])
        with FactRepository(self.store.root) as repo:
            fact = repo.get_metric('NO_SF1', 'Revenue')
            self.assertIsNone(fact['currency'])
            self.assertEqual(fact['currency_provenance'], [])
            self.assertEqual(fact['currency_basis'], 'current_sf1_master_currency_unavailable')

    def test_conflicting_sf1_alias_metadata_stays_unknown(self):
        self.put('tickers', [['SF1', 10, 'ADR_A_OLD', '', '2024-01-01', 'EUR']])
        with FactRepository(self.store.root) as repo:
            fact = repo.get_metric('ADR_A', 'Revenue')
            self.assertIsNone(fact['currency'])
            self.assertEqual(fact['currency_basis'], 'current_sf1_master_currency_ambiguous')
            self.assertEqual(len(fact['currency_provenance']), 2)

    def test_missing_or_malformed_sf1_currency_stays_unknown(self):
        for currency in ('', 'US DOLLARS'):
            with self.subTest(currency=currency):
                self.put('tickers', [['SF1', 10, 'ADR_A', '', '2024-06-02', currency]])
                with FactRepository(self.store.root) as repo:
                    fact = repo.get_metric('ADR_A', 'FreeCashFlow')
                    self.assertIsNone(fact['currency'])
                    self.assertEqual(fact['currency_basis'], 'current_sf1_master_currency_unavailable')

    def test_default_fcf_margin_preserves_historical_native_currency_cancellation(self):
        with FactRepository(self.store.root) as repo:
            for ticker, expected in [('ADR_A', .1), ('ADR_B', .25)]:
                fact = FeatureEngine(repo, default_registry()).calculate('FCFMargin', '1', ticker, '2024-06-01')
                self.assertEqual((fact['status'], fact['value'], fact['version']), ('ok', expected, '1'))
                self.assertTrue(all(row['currency'] is None for row in fact['input_facts'].values()))
        self.assertEqual(len(METRICS), 7)

    def test_unknown_native_and_usd_amounts_cannot_mix(self):
        registry = FeatureRegistry()
        registry.register(FeatureDefinition('FixtureRatio', '1', ('FreeCashFlow', 'MarketCap'), 'ratio',
                                             lambda facts: facts['FreeCashFlow'] / facts['MarketCap']))
        with FactRepository(self.store.root) as repo:
            result = FeatureEngine(repo, registry).calculate('FixtureRatio', '1', 'ADR_A', '2024-06-01')
            self.assertEqual({fact['period_end'] for fact in result['input_facts'].values()}, {date(2024, 3, 31)})
            self.assertIsNone(result['value'])
            self.assertEqual(result['status'], 'missing_or_incompatible_inputs')

    def test_unknown_currencies_only_cancel_for_identical_source_observation(self):
        with FactRepository(self.store.root) as repo:
            original = {metric: repo.get_metric('ADR_A', metric, as_of='2024-06-01')
                        for metric in ('Revenue', 'FreeCashFlow')}
        for mismatch in ('security', 'key', 'run', 'missing_lineage'):
            with self.subTest(mismatch=mismatch):
                facts = copy.deepcopy(original)
                if mismatch == 'security': facts['FreeCashFlow']['security_id'] = 'sharadar:security:20'
                elif mismatch == 'key': facts['FreeCashFlow']['provenance']['key']['date'] = date(2024, 5, 2)
                elif mismatch == 'run': facts['FreeCashFlow']['provenance']['ingestion_run'] = 'different-source-run'
                else: facts['FreeCashFlow']['provenance'] = None
                stub = type('FixtureRepository', (), {'get_metric': lambda _, ticker, metric, **kw: facts[metric]})()
                result = FeatureEngine(stub, default_registry()).calculate('FCFMargin', '1', 'ADR_A', '2024-06-01')
                self.assertIsNone(result['value'])

    def test_known_incompatible_currencies_still_fail(self):
        with FactRepository(self.store.root) as repo:
            facts = {metric: repo.get_metric('ADR_A', metric, as_of='2024-06-01')
                     for metric in ('Revenue', 'FreeCashFlow')}
        facts['Revenue']['currency'], facts['FreeCashFlow']['currency'] = 'CNY', 'USD'
        stub = type('FixtureRepository', (), {'get_metric': lambda _, ticker, metric, **kw: facts[metric]})()
        result = FeatureEngine(stub, default_registry()).calculate('FCFMargin', '1', 'ADR_A', '2024-06-01')
        self.assertIsNone(result['value'])


if __name__ == '__main__':
    unittest.main()
