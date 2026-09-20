import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

import duckdb


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/migrate-research-prices-to-sharadar.py"


class SharadarResearchMigrationTest(unittest.TestCase):
    def test_replaces_prices_and_preserves_unrelated_and_false_positive_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fact_root = root / "fact"
            (fact_root / "sync").mkdir(parents=True)
            (fact_root / "manifests").mkdir()
            (fact_root / "manifests/catalog.json").write_text('{"generation":"fixture"}')
            fact = duckdb.connect(str(fact_root / "fact_os.duckdb"))
            fact.execute("""
              CREATE TABLE stocks(ticker VARCHAR,date DATE,open DOUBLE,high DOUBLE,low DOUBLE,
                close DOUBLE,volume DOUBLE,closeadj DOUBLE,_observed_at VARCHAR);
              CREATE TABLE funds AS SELECT * FROM stocks WHERE false;
              CREATE TABLE actions(date DATE,action VARCHAR,ticker VARCHAR,name VARCHAR,value DOUBLE,
                contraticker VARCHAR,contraname VARCHAR,_ingestion_run VARCHAR,_observed_at VARCHAR);
              INSERT INTO stocks VALUES
                ('AAA','2026-09-17',9,11,8,10,100,9.5,'2026-09-19T00:00:00Z'),
                ('AAA','2026-09-18',10,12,9,11,110,10.6,'2026-09-19T00:00:00Z');
              INSERT INTO funds VALUES
                ('SPY','2026-09-18',600,601,599,600,1000,598,'2026-09-19T00:00:00Z');
              INSERT INTO actions VALUES
                ('2026-09-17','dividend','AAA','AAA INC',0.25,'N/A','N/A','fixture','2026-09-19T00:00:00Z');
            """)
            fact.close()
            source = root / "source.sqlite"
            db = sqlite3.connect(source)
            db.executescript("""
              CREATE TABLE price_points(symbol TEXT,date TEXT,open REAL,high REAL,low REAL,close REAL,
                volume REAL,source TEXT,updated_at TEXT,adjusted_close REAL,PRIMARY KEY(symbol,date));
              INSERT INTO price_points VALUES('AAA','2026-09-17',1,1,1,1,1,'yahoo','old',1);
              INSERT INTO price_points VALUES('SPY','2026-09-18',1,1,1,1,1,'yahoo','old',1);
              CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY,generated_at TEXT,payload_json TEXT);
              CREATE TABLE valuation_snapshots(id TEXT PRIMARY KEY,generated_at TEXT,payload_json TEXT);
              CREATE TABLE dividend_events(ticker TEXT,company_name TEXT,ex_date TEXT,pay_date TEXT,
                record_date TEXT,declaration_date TEXT,amount REAL,currency TEXT,status TEXT,source TEXT,
                source_label TEXT,logo_url TEXT,payload_json TEXT,updated_at TEXT,
                PRIMARY KEY(ticker,ex_date,source));
              CREATE TABLE guru_backtests(guru_id TEXT,years INTEGER,generated_at TEXT,start_date TEXT,
                end_date TEXT,payload_json TEXT,PRIMARY KEY(guru_id,years));
              CREATE TABLE guru_backtest_proxies(guru_id TEXT,years INTEGER,generated_at TEXT,start_date TEXT,
                end_date TEXT,method_version TEXT,payload_json TEXT,PRIMARY KEY(guru_id,years));
              CREATE TABLE private_user_data(id TEXT PRIMARY KEY,payload TEXT);
              INSERT INTO private_user_data VALUES('user','untouched');
            """)
            ticker = {"ticker":"AAA","priceHistory":[{"date":"2026-09-17","close":1,"source":"yahoo"}],
                      "priceSource":"yahoo","latest":{"latestPrice":1,"latestPriceDate":"2026-09-17",
                      "latestPriceSource":"yahoo","baseFairValue":22,"targetPrice3Y":33},
                      "history":[{"asOfDate":"2026-09-17","fairValue":20,"targetPrice3Y":30,
                      "priceAtDate":1,"dataSnapshot":{"asOfPriceSource":{"source":"yahoo"}}}]}
            db.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?,?)",('AAA','old',json.dumps(ticker)))
            db.execute("INSERT INTO valuation_snapshots VALUES(?,?,?)",('latest','old',json.dumps({"tickers":[ticker]})))
            db.execute("INSERT INTO dividend_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       ('AAA','AAA INC','2026-09-01',None,None,None,.2,'USD','historical',
                        'yahoo_dividend_history','Yahoo',None,'{}','old'))
            db.execute("INSERT INTO guru_backtests VALUES(?,?,?,?,?,?)",
                       ('one',5,'old',None,None,json.dumps({"source":"Yahoo adjusted close"})))
            db.execute("INSERT INTO guru_backtest_proxies VALUES(?,?,?,?,?,?,?)",
                       ('two',5,'old',None,None,'v1',json.dumps({"holding":"YAHOO INC","source":"Sharadar"})))
            db.commit(); db.close()
            output, receipt = root / "candidate.sqlite", root / "receipt.json"
            completed = subprocess.run([sys.executable,str(SCRIPT),'--source',str(source),'--fact-os-root',str(fact_root),
                '--output',str(output),'--receipt',str(receipt),'--cutoff','2026-09-18',
                '--generated-at','2026-09-20T00:00:00Z'],capture_output=True,text=True)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            result = sqlite3.connect(output)
            self.assertEqual(result.execute("SELECT close,source FROM price_points WHERE symbol='AAA' AND date='2026-09-18'").fetchone(),(11.0,'sharadar_fact_os_sep'))
            self.assertEqual(result.execute("SELECT COUNT(*) FROM price_points WHERE source LIKE '%yahoo%'").fetchone()[0],0)
            self.assertEqual(result.execute("SELECT payload FROM private_user_data").fetchone()[0],'untouched')
            self.assertEqual(result.execute("SELECT COUNT(*) FROM guru_backtests").fetchone()[0],0)
            self.assertEqual(result.execute("SELECT COUNT(*) FROM guru_backtest_proxies").fetchone()[0],0)
            self.assertEqual(result.execute("SELECT source,amount FROM dividend_events").fetchone(),('sharadar_fact_os_actions',.25))
            payload=json.loads(result.execute("SELECT payload_json FROM valuation_ticker_snapshots").fetchone()[0])
            self.assertEqual(payload['latest']['latestPrice'],11)
            self.assertEqual(payload['history'][0]['priceAtDate'],10)
            self.assertFalse('yahoo' in json.dumps(payload).lower())
            result.close()
            audit=json.loads(receipt.read_text())
            self.assertEqual(audit['activeYahooCounts'],{k:0 for k in audit['activeYahooCounts']})


if __name__ == '__main__':
    unittest.main()
