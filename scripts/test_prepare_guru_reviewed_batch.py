import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("prepare_batch", Path(__file__).with_name("prepare-guru-reviewed-batch.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReviewedBatchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "stage.sqlite"
        self.meta = self.root / "metadata.sqlite"
        self.manifest = self.root / "review.json"
        with sqlite3.connect(self.source) as db:
            db.executescript("""
                CREATE TABLE pit_source_metadata(key TEXT PRIMARY KEY,value TEXT);
                CREATE TABLE pit_financial_coverage(ticker TEXT,status TEXT);
                CREATE TABLE pit_guidance_coverage(ticker TEXT,status TEXT);
                CREATE TABLE pit_issuer_review(ticker TEXT,status TEXT,reason TEXT);
                CREATE TABLE pit_financial_periods(ticker TEXT);
                CREATE TABLE pit_guidance_events(ticker TEXT);
                CREATE TABLE pit_raw_financial_review(ticker TEXT);
            """)
            for ticker in ("READY", "PENDING"):
                db.execute("INSERT INTO pit_financial_coverage VALUES(?,'covered')", (ticker,))
                db.execute("INSERT INTO pit_guidance_coverage VALUES(?,'covered_official_filing')", (ticker,))
                db.execute("INSERT INTO pit_issuer_review VALUES(?,'pending_economic_review','pending')", (ticker,))
                for table in ("pit_financial_periods", "pit_guidance_events", "pit_raw_financial_review"):
                    db.execute(f"INSERT INTO {table} VALUES(?)", (ticker,))
        with sqlite3.connect(self.meta) as db:
            db.execute("CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY,payload_json TEXT)")
            for ticker in ("READY", "PENDING"):
                db.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?)", (ticker, json.dumps({"ticker": ticker, "priceHistory": [{"close": 10}]})))
        self.companies = [{"ticker": "READY", "reviewStatus": "reviewed", "valuationProfile": "industrial_growth",
                           "identityEvidence": [{"url": "https://example.test/filing"}], "cik": "0000000123", "reviewedAt": "2026-09-05"},
                          {"ticker": "PENDING", "reviewStatus": "unreviewed"}]
        self.write_manifest()

    def write_manifest(self):
        self.manifest.write_text(json.dumps({"companies": self.companies}))

    def prepare(self, tickers=("READY",)):
        return MODULE.prepare(self.source, self.meta, self.manifest, self.root / "candidate", tickers)

    def test_exact_subset_isolated_and_source_unchanged(self):
        hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in (self.source, self.meta)]
        result = self.prepare()
        self.assertEqual(result["status"], "isolated_model_candidate_not_release")
        self.assertEqual(hashes, [hashlib.sha256(p.read_bytes()).hexdigest() for p in (self.source, self.meta)])
        with sqlite3.connect(result["source"]) as db:
            self.assertEqual(db.execute("SELECT ticker,status FROM pit_issuer_review").fetchall(), [("READY", "reviewed")])
            self.assertEqual(db.execute("SELECT ticker FROM pit_guidance_events").fetchall(), [("READY",)])
        with sqlite3.connect(result["model"]) as db:
            self.assertEqual(db.execute("SELECT ticker FROM valuation_ticker_snapshots").fetchall(), [("READY",)])
            self.assertEqual(json.loads(db.execute("SELECT payload_json FROM valuation_ticker_snapshots").fetchone()[0])["priceHistory"], [{"close": 10}])

    def test_unreviewed_cannot_be_promoted(self):
        with self.assertRaises(ValueError):
            self.prepare(("PENDING",))
        self.assertFalse((self.root / "candidate").exists())

    def test_open_input_blockers_prevent_promotion(self):
        self.companies[0]["releaseNeeds"] = ["period_end_shares"]
        self.write_manifest()
        with self.assertRaises(ValueError):
            self.prepare()

    def test_incomplete_guidance_prevents_candidate(self):
        with sqlite3.connect(self.source) as db:
            db.execute("UPDATE pit_guidance_coverage SET status='official_guidance_review_incomplete'")
        with self.assertRaises(ValueError):
            self.prepare()

    def test_missing_metadata_is_not_substituted(self):
        with sqlite3.connect(self.meta) as db:
            db.execute("DELETE FROM valuation_ticker_snapshots WHERE ticker='READY'")
        with self.assertRaises(ValueError):
            self.prepare()

    def test_empty_scope_and_overwrite_rejected(self):
        with self.assertRaises(ValueError):
            self.prepare(())
        self.prepare()
        with self.assertRaises(FileExistsError):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
