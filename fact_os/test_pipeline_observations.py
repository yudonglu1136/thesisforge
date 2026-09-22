import csv
import sqlite3
import tempfile
import unittest
from pathlib import Path
from .store import Store,checksum
from .pipeline.observations import build_observations,quality_logic


class ObservationProjectionTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.store=Store(self.root/'facts')
        definitions={
            'tickers':[('table','TEXT'),('permaticker','INTEGER'),('ticker','TEXT'),('lastupdated','TEXT')],
            'stocks':[('ticker','TEXT'),('date','TEXT'),('close','REAL'),('closeadj','REAL'),('closeunadj','REAL'),('lastupdated','TEXT')],
            'fundamentals':[(name,'TEXT' if name in ('ticker','dimension','fiscalperiod','date','reportperiod') else 'REAL') for name in quality_logic().COLUMNS]+[('lastupdated','TEXT')]}
        keys={'tickers':'"table",permaticker,ticker','stocks':'ticker,date','fundamentals':'ticker,dimension,date,reportperiod'}
        self.definitions=definitions
        for table,fields in definitions.items():
            self.store.install_contract(table,'CREATE TABLE IF NOT EXISTS "'+table+'" ('+','.join('"'+name+'" '+kind for name,kind in fields)+',PRIMARY KEY('+keys[table]+'));')
        self.put('tickers',[['SEP',1,'TEST','2026-02-01'],['SF1',1,'TEST','2026-02-01']])
        self.put('stocks',[['TEST','2026-02-01',50,50,50,'2026-02-02']])
        self.put('fundamentals',[['TEST','ART','2026-02-01','2025-12-31','2025-Q4',.2,100,20,100,15,8,12,10,-4,'2026-02-02']])

    def put(self,table,rows):
        file=self.root/(table+'.csv')
        with file.open('w') as stream:
            writer=csv.writer(stream);writer.writerow([name for name,_ in self.definitions[table]]);writer.writerows(rows)
        self.store.ingest(table,file,scope='verified_full_bulk')

    def test_projection_reuses_quality_formula_and_replays_identically(self):
        file=self.root/'derived/observations.sqlite'
        result=build_observations(self.store.root,file,'generation')
        self.assertEqual(result['priceRows'],1);self.assertEqual(result['qualityRows'],1)
        before=checksum(file)
        build_observations(self.store.root,file,'generation')
        self.assertEqual(before,checksum(file))
        with sqlite3.connect(file) as db:
            self.assertEqual(db.execute('SELECT roic,fcf_margin FROM investment_quality_annual').fetchone(),(.2,.08))
            self.assertEqual(db.execute('SELECT close FROM investment_current_quotes').fetchone()[0],50)
            names={r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            self.assertEqual(names,{'investment_current_quotes','investment_quality_annual','projection_metadata'})

    def test_ambiguous_identity_never_silently_duplicates_company(self):
        self.put('tickers',[['SEP',2,'TEST','2026-02-01']])
        with self.assertRaisesRegex(ValueError,'projection_empty'):
            build_observations(self.store.root,self.root/'bad.sqlite','bad')
