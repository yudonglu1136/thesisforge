"""Synthetic data only; no credential or upstream access needed."""
import csv
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from .contracts import Contract
from .store import Store
from .repository import FactRepository,PriceType,PITUnavailable,MissingData

SCHEMAS={
'tickers': [('table','TEXT'),('permaticker','INTEGER'),('ticker','TEXT'),('secfilings','TEXT'),('lastupdated','TEXT')],
'stocks': [('ticker','TEXT'),('date','TEXT'),('close','REAL'),('closeadj','REAL'),('closeunadj','REAL'),('lastupdated','TEXT')],
'fundamentals':[('ticker','TEXT'),('dimension','TEXT'),('date','TEXT'),('reportperiod','TEXT'),('revenue','INTEGER'),('fcf','INTEGER'),('lastupdated','TEXT')],
'holdings':[('ticker','TEXT'),('investorid','TEXT'),('securitytype','TEXT'),('date','TEXT'),('value','REAL'),('units','REAL')],
'holdings_investor':[('date','TEXT'),('investorid','TEXT'),('investorname','TEXT')],
'holdings_ticker':[('date','TEXT'),('ticker','TEXT'),('shrholders','INTEGER'),('shrunits','REAL'),('shrvalue','REAL'),('totalvalue','REAL'),('percentoftotal','REAL')],
}
KEYS={'tickers':('table','permaticker','ticker'),'stocks':('ticker','date'),
      'fundamentals':('ticker','dimension','date','reportperiod'),
      'holdings':('ticker','investorid','securitytype','date'),
      'holdings_investor':('date','investorid'),'holdings_ticker':('date','ticker')}

class FactOSTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.store=Store(self.root/'warehouse');self.serial=0
        for table,cols in SCHEMAS.items():
            ddl='CREATE TABLE IF NOT EXISTS "'+table+'" ('+', '.join('"'+k+'" '+t for k,t in cols)+', PRIMARY KEY ('+','.join('"'+k+'"' for k in KEYS[table])+'));'
            self.store.install_contract(table,ddl)
        self.put('tickers',[['SEP',123,'ABC','https://www.sec.gov/cgi-bin/browse-edgar?CIK=000123','2024-01-01'],
                            ['SEP',123,'OLD','https://www.sec.gov/cgi-bin/browse-edgar?CIK=000123','2024-01-01']])
    def tearDown(self): self.tmp.cleanup()
    def put(self,table,rows,scope='archive_unverified'):
        self.serial+=1;p=self.root/f'{self.serial}.csv'
        with p.open('w',newline='') as f:
            w=csv.writer(f);w.writerow([k for k,t in SCHEMAS[table]]);w.writerows(rows)
        return self.store.ingest(table,p,scope=scope)

    def test_upsert_downgrade_and_offline_prices(self):
        self.put('stocks',[['ABC','2000-01-03',5,4,20,'2024-01-01'],['ABC','2024-01-02',10,9,10,'2024-01-02']])
        self.put('stocks',[['ABC','2024-01-02',11,10,11,'2024-01-03']])
        result=self.put('stocks',[['ABC','2024-01-02',11,10,11,'2024-01-03']])
        self.assertEqual(result['status'],'unchanged')
        self.assertEqual(next(s for s in self.store.status() if s['dataset']=='stocks')['row_count'],2)
        with patch('socket.socket',side_effect=AssertionError('network forbidden')):
            r=FactRepository(self.store.root)
            try:
                values=[r.get_price('ABC','2000-01-03',p)['value'] for p in PriceType]
                self.assertEqual(values,[20,5,4])
                self.assertEqual(r.resolve_security('OLD')['security_id'],r.resolve_security('ABC')['security_id'])
            finally:r.close()

    def test_pit_and_dimensions(self):
        self.put('fundamentals',[
            ['ABC','ART','2024-02-01','2023-12-31',100,10,'2024-02-01'],
            ['ABC','ART','2024-05-01','2024-03-31',120,12,'2024-05-01'],
            ['ABC','MRT','2023-12-31','2023-12-31',999,99,'2025-02-01']])
        r=FactRepository(self.store.root)
        try:
            self.assertEqual(len(r.get_fundamentals('ABC',as_of='2024-03-01')),1)
            self.assertEqual(r.get_fundamentals('ABC',as_of='2024-01-01'),[])
            with self.assertRaises(PITUnavailable):r.get_fundamentals('ABC','MRT',as_of='2024-03-01')
            from .registry import FeatureEngine,default_registry
            f=FeatureEngine(r,default_registry()).calculate('FCFMargin','1','ABC','2024-03-01')
            self.assertEqual(f['value'],.1)
        finally:r.close()

    def test_duplicate_rejected_and_old_rows_preserved(self):
        row=['ABC','2024-01-02',10,9,10,'2024-01-02']
        self.put('stocks',[row])
        with self.assertRaisesRegex(ValueError,'duplicate'):self.put('stocks',[row,row])
        self.assertEqual(next(s for s in self.store.status() if s['dataset']=='stocks')['row_count'],1)

    def test_holdings_changes_and_security_types(self):
        self.put('holdings',[
            ['ABC','A','SHR','2023-12-31',1,2],['ABC','B','SHR','2023-12-31',1,2],
            ['ABC','D','SHR','2023-12-31',1,2],['ABC','E','SHR','2023-12-31',1,2],
            ['ABC','A','SHR','2024-03-31',2,3],['ABC','C','SHR','2024-03-31',1,1],
            ['ABC','D','SHR','2024-03-31',1,2],['ABC','E','SHR','2024-03-31',.5,1],
            ['ABC','A','PUT','2024-03-31',5,10]],scope='verified_full_bulk')
        self.put('holdings_investor',[['2024-03-31','A','Manager A']])
        r=FactRepository(self.store.root)
        try:
            changes={x['investor_id']:x for x in r.get_holder_changes('ABC','2024-03-31')}
            self.assertEqual([changes[k]['change'] for k in 'ABCDE'],['INCREASED','EXITED','NEW','UNCHANGED','DECREASED'])
            self.assertEqual(changes['A']['current_units'],3000)
            self.assertEqual(changes['A']['current_value_usd'],2000000)
            with self.assertRaises(PITUnavailable):r.get_institutional_holdings('ABC','2024-03-31',as_of='2024-04-01')
        finally:r.close()

    def test_ownership_does_not_bridge_missing_quarter(self):
        self.put('holdings_ticker',[
            ['2023-12-31','ABC',2,3,4,5,1],['2024-03-31','ABC',3,4,5,6,2],
            ['2024-09-30','ABC',5,6,7,8,3]])
        r=FactRepository(self.store.root)
        try:
            rows=r.get_institutional_ownership_history('ABC')
            self.assertEqual(rows[1]['qoq_institutional_share_units'],1000)
            self.assertIsNone(rows[2]['qoq_institutional_share_units'])
        finally:r.close()

    def test_schema_drift_and_unvalidated_backfill(self):
        from .sync import Synchronizer,UpstreamError
        sync=Synchronizer(self.store,'synthetic-test-key')
        try:
            with self.assertRaisesRegex(UpstreamError,'full backfill'):sync.sync('stocks')
        finally:sync.close()
        self.assertFalse(self.store.status()[0]['backfill_complete'])

    def test_ticker_update_does_not_move_identity_between_partitions(self):
        self.put('tickers',[['SEP',123,'ABC','https://www.sec.gov/cgi-bin/browse-edgar?CIK=000123','2025-01-01']])
        state=next(s for s in self.store.status() if s['dataset']=='tickers')
        self.assertEqual(state['row_count'],2)
        r=FactRepository(self.store.root)
        try:self.assertEqual(r.resolve_security('ABC')['company_id'],'sec:cik:123')
        finally:r.close()

    def test_invalid_price_and_future_report_do_not_publish(self):
        with self.assertRaisesRegex(ValueError,'invalid price'):
            self.put('stocks',[['ABC','2024-01-02',10,9,0,'2024-01-02']])
        with self.assertRaisesRegex(ValueError,'future reporting period'):
            self.put('fundamentals',[['ABC','ARQ','2024-01-01','2024-03-31',100,10,'2024-01-01']])

    def test_verified_source_anomalies_retained_but_not_consumed(self):
        import json
        self.put('stocks',[['ABC','2024-01-02',10,9,0,'2024-01-02']],scope='verified_full_bulk')
        self.put('fundamentals',[['ABC','ARQ','2024-01-01','2024-03-31',100,10,'2024-01-01']],scope='verified_full_bulk')
        manifest=json.loads((self.store.root/'manifests/catalog.json').read_text())
        self.assertEqual(manifest['datasets']['stocks']['quality']['invalid_price:closeunadj'],1)
        r=FactRepository(self.store.root)
        try:
            with self.assertRaises(MissingData):r.get_price('ABC','2024-01-02',PriceType.RAW_CLOSE)
            self.assertEqual(r.get_price('ABC','2024-01-02',PriceType.SPLIT_ADJUSTED_CLOSE)['value'],10)
            self.assertEqual(r.get_fundamentals('ABC','ARQ',as_of='2025-01-01'),[])
            self.assertEqual(r.db.execute('SELECT closeunadj FROM stocks').fetchone()[0],0)
        finally:r.close()
        # A legitimate correction replaces the key and clears the anomaly.
        self.put('stocks',[['ABC','2024-01-02',10,9,20,'2024-01-03']],scope='incremental')
        manifest=json.loads((self.store.root/'manifests/catalog.json').read_text())
        self.assertEqual(manifest['datasets']['stocks']['quality']['invalid_price:closeunadj'],0)

    def test_archive_relocation_still_offline(self):
        import shutil
        relocated=self.root/'relocated'
        shutil.copytree(self.store.root,relocated)
        r=FactRepository(relocated)
        try:self.assertEqual(r.resolve_security('ABC')['security_id'],'sharadar:security:123')
        finally:r.close()

if __name__=='__main__':unittest.main()
