"""Canonical insiders reader: no provider calls, no partial-backfill fallback."""
import unittest
from .test_repository import RepositoryTest
from .repository import FactRepository, MissingData
from .rpc import dispatch


class InsiderReaderTest(unittest.TestCase):
    put = RepositoryTest.put
    tearDown = RepositoryTest.tearDown

    def setUp(self):
        RepositoryTest.setUp(self)
        self.schemas['insiders'] = [(x, t) for x, t in [
            ('ticker', 'TEXT'), ('date', 'TEXT'), ('formtype', 'TEXT'),
            ('ownername', 'TEXT'), ('rownum', 'INTEGER'), ('transactiondate', 'TEXT'),
            ('transactioncode', 'TEXT'), ('transactionshares', 'INTEGER')]]
        self.keys['insiders'] = ('ticker', 'date', 'formtype', 'ownername', 'rownum')
        self.store.install_contract('insiders', 'CREATE TABLE IF NOT EXISTS "insiders" (' +
            ','.join(f'"{k}" {t}' for k, t in self.schemas['insiders']) +
            ',PRIMARY KEY ("ticker","date","formtype","ownername","rownum"));')

    def test_insider_cutoff_is_filing_date_and_rows_keep_transaction_date(self):
        self.put('insiders', [
            ['NEW','2024-06-01','4','Owner',1,'2024-05-30','P',10],
            ['NEW','2024-06-02','4','Owner',1,'2024-05-30','S',-5],
            ['CLASSB','2024-06-01','4','Owner',1,'2024-05-30','P',999],
        ])
        with FactRepository(self.store.root) as r:
            result = r.get_insider_transactions('NEW', '2024-03-01', '2024-06-01')
            self.assertEqual(len(result['rows']), 1)
            self.assertEqual(str(result['rows'][0]['transactiondate']), '2024-05-30')
            self.assertEqual(result['security_id'], 'sharadar:security:10')
            with self.assertRaises(ValueError):
                r.get_insider_transactions('NEW', '2020-01-01', '2024-06-01')
            with self.assertRaises(MissingData):
                dispatch(r, {'method': 'get_insider_transactions', 'args': ['NEW','2024-03-01','2024-06-01']})

    def test_insider_row_identity_is_content_based_not_catalog_based(self):
        self.put('insiders', [['NEW','2024-06-01','4','Owner',1,'2024-05-30','P',10]])
        with FactRepository(self.store.root) as r:
            before = r.get_insider_transactions('NEW','2024-03-01','2024-06-01')['rows'][0]['fact_id']
        self.put('stocks', [['NEW', '2024-06-01', 10, 10, 10, '2024-06-01']])
        with FactRepository(self.store.root) as r:
            self.assertEqual(before, r.get_insider_transactions('NEW','2024-03-01','2024-06-01')['rows'][0]['fact_id'])
        self.put('insiders', [['NEW','2024-06-01','4','Owner',1,'2024-05-30','P',11]])
        with FactRepository(self.store.root) as r:
            self.assertNotEqual(before, r.get_insider_transactions('NEW','2024-03-01','2024-06-01')['rows'][0]['fact_id'])


if __name__ == '__main__': unittest.main()
