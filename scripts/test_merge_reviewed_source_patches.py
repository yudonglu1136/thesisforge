import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("source_patch", Path(__file__).with_name("merge-reviewed-source-patches.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SourcePatchIntegrationTest(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        base, patch = root / "base.sqlite", root / "patch.sqlite"
        for path in (base, patch):
            with sqlite3.connect(path) as db:
                db.executescript("""
                    CREATE TABLE pit_source_metadata(key TEXT PRIMARY KEY,value TEXT);
                    CREATE TABLE pit_guidance_events(id TEXT PRIMARY KEY,ticker TEXT,source_type TEXT,payload_json TEXT);
                    CREATE TABLE pit_guidance_coverage(ticker TEXT PRIMARY KEY,status TEXT);
                    CREATE TABLE pit_financial_periods(ticker TEXT,fiscal_period TEXT,dimension TEXT,payload_json TEXT,PRIMARY KEY(ticker,fiscal_period,dimension));
                    CREATE TABLE pit_fx_reference_rates(currency TEXT,rate_date TEXT,rate REAL,PRIMARY KEY(currency,rate_date));
                    CREATE TABLE pit_issuer_review(ticker TEXT PRIMARY KEY,status TEXT);
                """)
                db.execute("INSERT INTO pit_source_metadata VALUES('official_review','old')")
                db.executemany("INSERT INTO pit_guidance_events VALUES(?,?,?,?)", [
                    ("official", "TEST", "official_issuer_sec_filing", "old"),
                    ("transcript", "TEST", "downloaded_online_earnings_transcript", "unchanged"),
                    ("other", "OTHER", "official_issuer_sec_filing", "unchanged")])
                db.executemany("INSERT INTO pit_guidance_coverage VALUES(?,?)", [("TEST", "missing"), ("OTHER", "covered")])
                db.executemany("INSERT INTO pit_financial_periods VALUES(?,?,?,?)", [
                    ("TEST", "2026-Q2", "ART", json.dumps({"shares_m": 10, "revenue_m": 100})),
                    ("TEST", "2025-Q2", "ART", json.dumps({"shares_m": 11, "revenue_m": 90}))])
                db.execute("INSERT INTO pit_issuer_review VALUES('TEST','pending')")
                db.execute("INSERT INTO pit_fx_reference_rates VALUES('GBP','2026-01-01',.8)")
        with sqlite3.connect(patch) as db:
            db.execute("UPDATE pit_guidance_events SET payload_json='reviewed' WHERE id='official'")
            db.execute("UPDATE pit_guidance_coverage SET status='covered_official_filing' WHERE ticker='TEST'")
            db.execute("UPDATE pit_financial_periods SET payload_json=? WHERE fiscal_period='2026-Q2'", (json.dumps({"shares_m": 10, "revenue_m": 80}),))
            db.execute("UPDATE pit_source_metadata SET value='reviewed'")
        manifest = {"patchSha256": MODULE.sha(patch), "officialTickers": ["TEST"],
                    "financialKeys": [["TEST", "2026-Q2", "ART"]], "metadataKeys": ["official_review"]}
        return base, patch, manifest, root / "output.sqlite"

    def test_scoped_patch_preserves_transcript_other_history_and_review(self):
        with tempfile.TemporaryDirectory() as directory:
            base, patch, manifest, output = self.fixture(directory)
            original = (MODULE.sha(base), MODULE.sha(patch))
            report = MODULE.integrate(base, patch, manifest, output)
            self.assertFalse(report["releaseAuthorized"])
            self.assertTrue(report["unrelatedRowsExact"])
            self.assertEqual(original, (MODULE.sha(base), MODULE.sha(patch)))
            with sqlite3.connect(output) as db:
                self.assertEqual(db.execute("SELECT payload_json FROM pit_guidance_events WHERE id='transcript'").fetchone()[0], "unchanged")
                self.assertEqual(db.execute("SELECT status FROM pit_issuer_review").fetchone()[0], "pending")

    def test_refuses_overwrite_hash_scope_claim_or_fx_conflict(self):
        for kind in ["existing", "hash", "duplicate", "shares", "fx", "collision"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                base, patch, manifest, output = self.fixture(directory)
                if kind == "existing":
                    output.touch()
                elif kind == "hash":
                    manifest["patchSha256"] = "wrong"
                elif kind == "duplicate":
                    manifest["officialTickers"].append("TEST")
                else:
                    with sqlite3.connect(patch) as db:
                        if kind == "shares":
                            db.execute("UPDATE pit_financial_periods SET payload_json=? WHERE fiscal_period='2026-Q2'", (json.dumps({"shares_m": 9}),))
                        elif kind == "fx":
                            db.execute("UPDATE pit_fx_reference_rates SET rate=.9")
                        else:
                            db.execute("DELETE FROM pit_guidance_events WHERE id='transcript'")
                            db.execute("UPDATE pit_guidance_events SET id='transcript' WHERE id='official'")
                    manifest["patchSha256"] = MODULE.sha(patch)
                with self.assertRaises((ValueError, FileExistsError)):
                    MODULE.integrate(base, patch, manifest, output)


if __name__ == "__main__":
    unittest.main()
