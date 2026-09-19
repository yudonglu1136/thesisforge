import importlib.util
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("merge", Path(__file__).with_name("merge-staged-transcript-evidence.py"))
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)


class ScopedMergeTests(unittest.TestCase):
    def fixture(self, directory):
        source, target = (Path(directory) / name for name in ("source.sqlite", "target.sqlite"))
        for path in (source, target):
            with closing(sqlite3.connect(path)) as db, db:
                db.executescript('''
                    CREATE TABLE pit_guidance_events(id TEXT PRIMARY KEY,ticker TEXT,source_type TEXT,observed_at TEXT,fiscal_period TEXT);
                    CREATE TABLE pit_issuer_review(ticker TEXT PRIMARY KEY,status TEXT);
                    CREATE TABLE pit_guidance_coverage(ticker TEXT PRIMARY KEY,status TEXT,note TEXT,guidance_events INTEGER,guidance_periods INTEGER);
                ''')
        with closing(sqlite3.connect(source)) as db, db:
            db.executemany("INSERT INTO pit_guidance_events VALUES (?,?,?,?,?)", [
                ("t1", "TEST", merge.OWNER, "2026-08-12", "Q22026"),
                ("future", "TEST", merge.OWNER, "2026-09-06", "Q22026")])
        with closing(sqlite3.connect(target)) as db, db:
            db.execute("INSERT INTO pit_guidance_events VALUES ('official','TEST','official_issuer_sec_filing','2026-08-12','Q22026')")
            db.executemany("INSERT INTO pit_issuer_review VALUES (?,?)", [("TEST", "pending_economic_review"), ("BAP", "pending_economic_review")])
            db.executemany("INSERT INTO pit_guidance_coverage VALUES (?,?,?,?,?)", [
                ("TEST", "covered_official_filing", "original", 1, 1),
                ("BAP", "official_guidance_review_incomplete", "keep exact reason", 0, 0)])
        return source, target

    def test_scoped_idempotent_merge_preserves_official_and_unrelated_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = self.fixture(directory)
            before = target.read_bytes()
            self.assertFalse(merge.merge(source, target, ["TEST"], "2026-09-05")["applied"])
            self.assertEqual(before, target.read_bytes())
            for _ in range(2):
                result = merge.merge(source, target, ["TEST"], "2026-09-05", True)
                self.assertEqual(result["rawTranscriptEvents"], 1)
            with closing(sqlite3.connect(target)) as db, db:
                self.assertEqual(db.execute("SELECT id FROM pit_guidance_events ORDER BY id").fetchall(), [("official",), ("t1",)])
                self.assertEqual(db.execute("SELECT note FROM pit_guidance_coverage WHERE ticker='BAP'").fetchone()[0], "keep exact reason")
                self.assertEqual(db.execute("SELECT count(*) FROM pit_issuer_review WHERE status='pending_economic_review'").fetchone()[0], 2)

    def test_empty_extraction_collision_and_reviewed_target_cannot_be_written(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = self.fixture(directory)
            before = target.read_bytes()
            with self.assertRaisesRegex(ValueError, "no dated"):
                merge.merge(source, target, ["BAP"], "2026-09-05", True)
            self.assertEqual(before, target.read_bytes())
            with closing(sqlite3.connect(target)) as db, db:
                db.execute("INSERT INTO pit_guidance_events VALUES ('t1','TEST','official_issuer_sec_filing','2026-08-12','Q22026')")
            with self.assertRaisesRegex(ValueError, "collides"):
                merge.merge(source, target, ["TEST"], "2026-09-05", True)
            with closing(sqlite3.connect(target)) as db, db:
                db.execute("UPDATE pit_issuer_review SET status='reviewed' WHERE ticker='TEST'")
            with self.assertRaisesRegex(ValueError, "pending-review"):
                merge.merge(source, target, ["TEST"], "2026-09-05", True)


if __name__ == "__main__":
    unittest.main()
