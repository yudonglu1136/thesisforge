import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("additive_rebuild", Path(__file__).with_name("prepare-additive-pit-rebuild.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AdditiveRebuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.baseline = self.root / "baseline.sqlite"
        self.base = self.root / "base.sqlite"
        self.addition = self.root / "addition.sqlite"
        self.metadata = self.root / "metadata.sqlite"
        self.manifest = self.root / "manifest.json"
        self.output = self.root / "assembled"
        for p, ticker in ((self.baseline, "OLD"), (self.metadata, "NEW")):
            with sqlite3.connect(p) as db:
                db.execute("CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY,generated_at TEXT,payload_json TEXT)")
                db.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?,?)", (ticker,"2026-09-05",json.dumps({"ticker":ticker,"history":[{"quarter":"Q12025","source":"unchanged"}]})))
                db.execute("CREATE TABLE users(id TEXT PRIMARY KEY,payload TEXT)")
                db.execute("INSERT INTO users VALUES('preserve','private')")
        for p, ticker in ((self.base,"OLD"),(self.addition,"NEW")):
            with sqlite3.connect(p) as db:
                db.execute("CREATE TABLE pit_source_metadata(key TEXT PRIMARY KEY,value TEXT)")
                db.execute("INSERT INTO pit_source_metadata VALUES('source_fingerprint','old-fingerprint')")
                for table in ("pit_financial_coverage","pit_guidance_coverage"):
                    db.execute(f"CREATE TABLE {table}(ticker TEXT PRIMARY KEY,status TEXT)")
                    db.execute(f"INSERT INTO {table} VALUES(?,'covered')",(ticker,))
                for table in ("pit_financial_periods","pit_guidance_events"):
                    db.execute(f"CREATE TABLE {table}(id TEXT PRIMARY KEY,ticker TEXT,payload_json TEXT)")
                    db.execute(f"INSERT INTO {table} VALUES(?,?,?)",(ticker,ticker,'{"value":12,"sourceDate":"2025-01-01"}'))
                db.execute("CREATE TABLE pit_fx_reference_rates(currency TEXT,rate_date TEXT,units_per_eur REAL,source_url TEXT,extraction_version TEXT,imported_at TEXT,PRIMARY KEY(currency,rate_date))")
                db.execute("INSERT INTO pit_fx_reference_rates VALUES('GBP','2026-09-04',0.9,'ecb','v2','old')")
        with sqlite3.connect(self.addition) as db:
            db.execute("CREATE TABLE pit_issuer_review(ticker TEXT PRIMARY KEY,status TEXT NOT NULL,reason TEXT NOT NULL)")
            db.execute("INSERT INTO pit_issuer_review VALUES('NEW','reviewed','explicit evidence')")
        self.manifest.write_text(json.dumps({"companies":[{"ticker":"NEW","reviewStatus":"reviewed","valuationProfile":"consumer","cik":"0000000001","reviewedAt":"2026-09-05","identityEvidence":[{"source":"fixture"}]}]}))

    def tearDown(self):
        self.temp.cleanup()

    def assemble(self, tickers=None):
        return module.assemble(self.baseline,self.base,self.addition,self.metadata,self.manifest,self.output,tickers or ["NEW"])

    def test_full_union_preserves_originals_and_keeps_legacy_provenance_pending(self):
        hashes = {p:module.sha256(p) for p in (self.baseline,self.base,self.addition,self.metadata)}
        report = self.assemble()
        self.assertFalse(report["releaseAuthorized"])
        self.assertEqual(report["pendingLegacyReviewProvenance"],["OLD"])
        self.assertEqual(report["inputBlockers"],[{"ticker":"OLD","kind":"review","status":"inherited_release_review_pending"}])
        for p,digest in hashes.items(): self.assertEqual(module.sha256(p),digest)
        with sqlite3.connect(self.output / "candidate.sqlite") as db, sqlite3.connect(self.baseline) as before:
            self.assertEqual(db.execute("SELECT * FROM users").fetchall(),before.execute("SELECT * FROM users").fetchall())
            self.assertEqual(db.execute("SELECT * FROM valuation_ticker_snapshots WHERE ticker='OLD'").fetchone(),before.execute("SELECT * FROM valuation_ticker_snapshots").fetchone())
            self.assertEqual(db.execute("SELECT COUNT(*) FROM valuation_ticker_snapshots").fetchone()[0],2)
            added=json.loads(db.execute("SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker='NEW'").fetchone()[0])
            self.assertNotIn("history",added)
            self.assertEqual(added["dataQuality"]["valuationStatus"],"pending_full_rebuild")
        with sqlite3.connect(self.output / "source.sqlite") as db, sqlite3.connect(self.base) as before:
            self.assertEqual(db.execute("SELECT * FROM pit_financial_periods WHERE ticker='OLD'").fetchone(),before.execute("SELECT * FROM pit_financial_periods").fetchone())
            self.assertEqual(db.execute("SELECT status FROM pit_issuer_review WHERE ticker='NEW'").fetchone()[0],"reviewed")
            self.assertNotEqual(db.execute("SELECT value FROM pit_source_metadata WHERE key='source_fingerprint'").fetchone()[0],"old-fingerprint")

    def test_existing_legacy_review_is_retained_not_overwritten(self):
        with sqlite3.connect(self.base) as db:
            db.execute("CREATE TABLE pit_issuer_review(ticker TEXT PRIMARY KEY,status TEXT NOT NULL,reason TEXT NOT NULL)")
            db.execute("INSERT INTO pit_issuer_review VALUES('OLD','reviewed','verified inherited release provenance')")
        report=self.assemble()
        self.assertEqual(report["pendingLegacyReviewProvenance"],[])
        self.assertEqual(report["inputBlockers"],[])
        self.assertFalse(report["releaseAuthorized"])

    def test_unreviewed_addition_rejected_before_output(self):
        with sqlite3.connect(self.addition) as db: db.execute("UPDATE pit_issuer_review SET status='pending'")
        with self.assertRaisesRegex(ValueError,"review is incomplete"): self.assemble()
        self.assertFalse(self.output.exists())

    def test_incomplete_full_base_rejected_before_output(self):
        with sqlite3.connect(self.base) as db: db.execute("DELETE FROM pit_financial_coverage")
        with self.assertRaisesRegex(ValueError,"exact full retained"): self.assemble()
        self.assertFalse(self.output.exists())

    def test_existing_output_and_duplicate_scope_rejected(self):
        with self.assertRaisesRegex(ValueError,"duplicate-free"): self.assemble(["NEW","NEW"])
        self.output.mkdir()
        with self.assertRaises(FileExistsError): self.assemble()

    def test_fx_conflict_preserves_inputs_and_rolls_back_additions(self):
        with sqlite3.connect(self.addition) as db: db.execute("UPDATE pit_fx_reference_rates SET units_per_eur=0.8")
        before=module.sha256(self.base)
        with self.assertRaisesRegex(ValueError,"Conflicting dated official FX"): self.assemble()
        self.assertEqual(module.sha256(self.base),before)
        with sqlite3.connect(self.output / "source.sqlite") as db:
            self.assertEqual(db.execute("SELECT ticker FROM pit_financial_coverage").fetchall(),[("OLD",)])
        self.assertFalse((self.output / "assembly.json").exists())


if __name__ == "__main__": unittest.main()
