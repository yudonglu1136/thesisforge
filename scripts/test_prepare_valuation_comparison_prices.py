import copy
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

import pyarrow as pa
import pyarrow.parquet as pq

spec = importlib.util.spec_from_file_location("price_prep", Path(__file__).with_name("prepare-valuation-comparison-prices.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class PricePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.date = "2026-08-28"
        self.row = dict(ticker="ABNB", date=self.date, open=184.67, high=191.49, low=184.67,
                        close=189.43, volume=4829000, closeadj=99.0, closeunadj=199.0, lastupdated="2026-08-31")
        self.snapshot = dict(currency="USD", fairValue=777.31, currentPrice=189.4149932861328,
                             model={"dcf": [1, 2, 3]}, priceSource="yahoo",
                             priceHistory=[dict(date=self.date, close=189.4149932861328, source="yahoo")])
        self.conflict = dict(ticker="ABNB", priceSymbol="ABNB", date=self.date, provider="yahoo", importBlocking=True,
                             left=dict(kind="released_snapshot", index=0, **self.snapshot["priceHistory"][0]),
                             right=dict(kind="raw_price_point", index=0, date=self.date, close=189.42999267578125, source="yahoo"))

    def parquet(self, rows):
        directory = self.directory / "parquet"
        directory.mkdir(exist_ok=True)
        values = [{**row, "date": mod.dt.date.fromisoformat(row["date"]),
                   "lastupdated": mod.dt.date.fromisoformat(row["lastupdated"])} for row in rows]
        pq.write_table(pa.Table.from_pylist(values), directory / "original.parquet")
        return directory

    def evidence(self):
        return {("ABNB", self.date): dict(row=self.row, source=mod.API_SOURCE, origin="frozen-vendor-response.json",
                                          rawRowSha256=mod.sha_bytes(json.dumps(self.row, sort_keys=True, separators=(",", ":"))))}

    def test_close_is_not_closeadj_or_closeunadj(self):
        rows = mod.original_paid_rows(self.parquet([self.row]), None, {("ABNB", self.date)}, "2026-09-05")
        fixed, edits = mod.repair_snapshot(self.snapshot, [self.conflict], rows, "2026-09-05")
        self.assertEqual(fixed["priceHistory"][0]["close"], 189.43)
        self.assertEqual(fixed["priceHistory"][0]["source"], mod.PARQUET_SOURCE)
        self.assertEqual(edits[0]["originalPaidEvidence"]["row"]["closeadj"], 99)

    def test_only_explicit_price_fields_change_original_is_untouched(self):
        original = copy.deepcopy(self.snapshot)
        fixed, edits = mod.repair_snapshot(self.snapshot, [self.conflict], self.evidence(), "2026-09-05")
        self.assertEqual(self.snapshot, original)
        for key in original:
            if key != "priceHistory":
                self.assertEqual(fixed[key], original[key])
        self.assertEqual(edits[0]["before"], original["priceHistory"][0])
        self.assertEqual(edits[0]["rawPriceRowsPreserved"], [self.conflict["right"]])
        self.assertEqual(fixed["priceHistory"][0]["source"], mod.API_SOURCE)

    def test_future_vintage_and_wrong_identity_blocked(self):
        for patch in [{"lastupdated": "2026-09-06"}, {"date": "2026-09-06"}, {"ticker": "AIRBNB"}, {"close": None}, {"close": -1}, {"close": float("nan")}, {"close": True}]:
            with self.subTest(patch=patch), self.assertRaises((ValueError, TypeError)):
                mod.validate_original({**self.row, **patch}, ("ABNB", self.date), "2026-09-05")

    def test_paid_conflict_is_not_relabelled(self):
        with self.assertRaisesRegex(ValueError, "Yahoo"):
            mod.repair_snapshot(self.snapshot, [{**self.conflict, "provider": "sharadar"}], self.evidence(), "2026-09-05")

    def test_non_us_currency_duplicate_or_changed_point_blocked(self):
        with self.assertRaisesRegex(ValueError, "non-USD"):
            mod.repair_snapshot({**self.snapshot, "currency": "GBP"}, [self.conflict], self.evidence(), "2026-09-05")
        with self.assertRaisesRegex(ValueError, "Duplicate repair"):
            mod.repair_snapshot(self.snapshot, [self.conflict, self.conflict], self.evidence(), "2026-09-05")
        changed = copy.deepcopy(self.snapshot)
        changed["priceHistory"][0]["close"] = 199
        with self.assertRaisesRegex(ValueError, "changed since"):
            mod.repair_snapshot(changed, [self.conflict], self.evidence(), "2026-09-05")

    def api(self, rows):
        raw = self.directory / "raw.json"
        raw.write_text(json.dumps(dict(fetchedAt="2026-09-06T00:00:00Z", batches=[dict(
            httpStatus=200, endpoint="https://api.sharadar.com/v1.0/data/stocks",
            request={"ticker": "ABNB", "date.gte": self.date, "date.lte": self.date},
            response={"count": len(rows), "data": rows})])))
        return raw

    def test_actual_paid_api_object_schema_missing_and_duplicate_scope(self):
        parquet = self.parquet([{**self.row, "ticker": "OTHER"}])
        originals = mod.original_paid_rows(parquet, self.api([self.row]), {("ABNB", self.date)}, "2026-09-05")
        self.assertEqual(originals[("ABNB", self.date)]["source"], mod.API_SOURCE)
        with self.assertRaisesRegex(ValueError, "Duplicate original API"):
            mod.original_paid_rows(parquet, self.api([self.row, self.row]), {("ABNB", self.date)}, "2026-09-05")
        with self.assertRaisesRegex(ValueError, "Missing independently"):
            mod.original_paid_rows(parquet, None, {("ABNB", self.date)}, "2026-09-05")

    def test_paid_original_disagreement_and_duplicate_parquet_rejected(self):
        parquet = self.parquet([self.row])
        with self.assertRaisesRegex(ValueError, "paid same-series conflict"):
            mod.original_paid_rows(parquet, self.api([{**self.row, "close": 188}]), {("ABNB", self.date)}, "2026-09-05")
        pq.write_table(pq.read_table(parquet / "original.parquet"), parquet / "duplicate.parquet")
        with self.assertRaisesRegex(ValueError, "Duplicate original parquet"):
            mod.original_paid_rows(parquet, None, {("ABNB", self.date)}, "2026-09-05")

    def test_full_copy_only_preservation_and_reimport_merge(self):
        source, output = self.directory / "original.sqlite", self.directory / "price-lane-seed.sqlite"
        with sqlite3.connect(source) as db:
            db.executescript("CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY,generated_at TEXT,payload_json TEXT); CREATE TABLE price_points(symbol TEXT,date TEXT,close REAL,source TEXT); CREATE TABLE valuation_model_runs(id TEXT,payload TEXT); CREATE TABLE users(id TEXT,secret TEXT);")
            db.executescript("CREATE TABLE cache_revisions(scope TEXT,revision INTEGER); INSERT INTO cache_revisions VALUES('valuation_ticker_snapshots',42); CREATE TRIGGER valuation_ticker_snapshots_revision_update AFTER UPDATE ON valuation_ticker_snapshots BEGIN UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_ticker_snapshots'; END;")
            db.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?,?)", ("ABNB", "original-date", json.dumps(self.snapshot)))
            db.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?,?)", ("XYZ", "original-date", json.dumps({"currency": "USD", "model": 123, "priceHistory": []})))
            db.execute("INSERT INTO price_points VALUES(?,?,?,?)", ("ABNB", self.date, 189.42999267578125, "yahoo"))
            db.execute("INSERT INTO valuation_model_runs VALUES('unchanged','model')")
            db.execute("INSERT INTO users VALUES('unchanged','private')")
        source_hash = mod.file_sha(source)
        result = mod.run(source, output, self.parquet([self.row]), None, "2026-09-05", self.directory / "price-lane-audit")
        self.assertEqual(result["before"]["blocking"], 1)
        self.assertEqual(result["after"]["blocking"], 0)
        self.assertEqual(result["after"]["actualMergeFailures"], 0)
        self.assertEqual(result["actualImporterComparisonMergeVerified"], 2)
        self.assertTrue(result["allNonSnapshotTablesExact"])
        self.assertEqual(mod.file_sha(source), source_hash)
        self.assertTrue(result["schemaAndTriggersExact"])
        self.assertTrue(result["cacheRevisionsExact"])
        with self.assertRaises(FileExistsError):
            mod.run(source, output, self.directory, None, "2026-09-05", self.directory / "price-lane-another-audit")

    def test_never_suspend_unreviewed_trigger(self):
        with sqlite3.connect(":memory:") as db:
            db.executescript("CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT); CREATE TRIGGER valuation_ticker_snapshots_revision_update AFTER UPDATE ON valuation_ticker_snapshots BEGIN SELECT RAISE(ABORT,'financial review required'); END;")
            with self.assertRaisesRegex(ValueError, "Unreviewed snapshot trigger"):
                mod.update_candidate_snapshots(db, [])

    def test_exception_rolls_back_snapshot_and_restores_exact_trigger(self):
        with sqlite3.connect(":memory:") as db:
            db.executescript("CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT); INSERT INTO valuation_ticker_snapshots VALUES('ABNB','original'); CREATE TABLE cache_revisions(scope TEXT,revision INTEGER); INSERT INTO cache_revisions VALUES('valuation_ticker_snapshots',42); CREATE TRIGGER valuation_ticker_snapshots_revision_update AFTER UPDATE ON valuation_ticker_snapshots BEGIN UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_ticker_snapshots'; END;")
            original_sql = db.execute("SELECT sql FROM sqlite_master WHERE type='trigger'").fetchone()[0]
            with self.assertRaises(sqlite3.ProgrammingError):
                mod.update_candidate_snapshots(db, [("changed", "ABNB"), ({"invalid sqlite binding": True}, "ABNB")])
            self.assertEqual(db.execute("SELECT payload_json FROM valuation_ticker_snapshots").fetchone()[0], "original")
            self.assertEqual(db.execute("SELECT revision FROM cache_revisions").fetchone()[0], 42)
            self.assertEqual(db.execute("SELECT sql FROM sqlite_master WHERE type='trigger'").fetchone()[0], original_sql)


if __name__ == "__main__":
    unittest.main()
