import importlib.util
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("report", Path(__file__).with_name("report-guru-valuation-readiness.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReadinessTests(unittest.TestCase):
    def test_missing_database_is_never_created(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "absent.sqlite"
            with self.assertRaises(sqlite3.OperationalError):
                report.build_report({}, path)
            self.assertFalse(path.exists())

    def test_inputs_and_extraction_are_not_a_valuation_release(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.sqlite"
            with closing(sqlite3.connect(path)) as db, db:
                db.executescript('''
                  CREATE TABLE pit_source_metadata(key TEXT,value TEXT);
                  CREATE TABLE pit_financial_coverage(ticker TEXT,status TEXT);
                  CREATE TABLE pit_guidance_coverage(ticker TEXT,status TEXT,note TEXT);
                  CREATE TABLE pit_issuer_review(ticker TEXT,status TEXT,reason TEXT);
                  CREATE TABLE pit_raw_financial_review(ticker TEXT);
                  CREATE TABLE pit_guidance_events(ticker TEXT);
                  CREATE TABLE pit_financial_periods(ticker TEXT);
                  INSERT INTO pit_financial_coverage VALUES ('TEST','covered');
                  INSERT INTO pit_guidance_coverage VALUES ('TEST','covered_official_filing','Source reviewed');
                  INSERT INTO pit_issuer_review VALUES ('TEST','pending_economic_review','Audit required');
                  INSERT INTO pit_raw_financial_review VALUES ('TEST');
                  INSERT INTO pit_guidance_events VALUES ('TEST');
                  INSERT INTO pit_financial_periods VALUES ('TEST');
                ''')
            before = path.read_bytes()
            inventory = {
                "asOf": "2026-09-05", "scope": "selected_book", "latestReportDate": "2026-06-30",
                "securityMasterSha256": "a" * 64, "releasedValuationTickers": 533, "limitations": [],
                "securities": [{"ticker": "TEST", "name": "Test", "reportingCurrency": "USD",
                    "inLatestSelectedBook": True, "status": "needs_economic_profile_and_official_guidance_review"}]
            }
            result = report.build_report(inventory, path)
            self.assertEqual(result["candidateIssuers"], 1)
            self.assertEqual(result["newReleasedValuations"], 0)
            self.assertEqual(result["securities"][0]["releaseStatus"], "not_released")
            self.assertEqual(before, path.read_bytes())
            inventory["securities"] = []
            with self.assertRaisesRegex(ValueError, "population differs"):
                report.build_report(inventory, path)


if __name__ == "__main__":
    unittest.main()
