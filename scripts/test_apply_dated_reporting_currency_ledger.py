from contextlib import closing
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from apply_dated_reporting_currency_ledger import apply_ledger
from build_dated_reporting_currency_ledger import companyfacts_filings, resolve_currency, VERSION
from test_build_dated_reporting_currency_ledger import source as facts_source


class ApplyReportingCurrencyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source.sqlite"
        self.metadata = self.root / "metadata.sqlite"
        self.ledger_path = self.root / "ledger.json"
        self.output = self.root / "new.sqlite"
        facts = facts_source()
        self.facts_path = self.root / "CIK0000000001.json"
        raw_facts = json.dumps(facts).encode()
        self.facts_path.write_bytes(raw_facts)
        proof = resolve_currency(companyfacts_filings(facts, "0000000001"), "0000000001", "2026-05-01")
        self.ledger = {"version": VERSION, "asOf": "2026-09-05", "issuers": {"A": {
            "cik": "0000000001", "cachePath": str(self.facts_path), "sha256": hashlib.sha256(raw_facts).hexdigest(),
            "url": "https://data.sec.gov/api/xbrl/companyfacts/CIK0000000001.json"}}, "targets": [
            {"ticker": "A", "targetAvailableAt": "2026-05-01", "financialRows": 2, **proof},
            {"ticker": "A", "targetAvailableAt": "2008-05-01", "financialRows": 1, "status": "blocked", "reason": "no_dated_aggregate_statement_facts"}]}
        with closing(sqlite3.connect(self.source)) as db:
            db.execute("CREATE TABLE pit_financial_periods(ticker TEXT,fiscal_period TEXT,dimension TEXT,available_at TEXT,currency TEXT,payload_json TEXT,PRIMARY KEY(ticker,fiscal_period,dimension))")
            db.execute("CREATE TABLE untouched(value TEXT)")
            db.execute("INSERT INTO untouched VALUES('review statuses, guidance and other tables must survive')")
            for period, dimension, available in [("2026-Q1", "ARQ", "2026-05-01"), ("2026-Q1", "ART", "2026-05-01"), ("2008-Q1", "ARQ", "2008-05-01")]:
                p = {"ticker": "A", "asOfDate": available, "sourceDimension": dimension,
                     "cfo_m": 15.125, "capex_m": 2, "shares_m": 7.123456, "arbitrary": [1, 2, "stay"],
                     "sourceRecord": {"currency": "USD", "currencyScale": 1, "fxConversion": None}}
                db.execute("INSERT INTO pit_financial_periods VALUES(?,?,?,?,?,?)", ("A", period, dimension, available, "USD", json.dumps(p)))
            db.commit()
        with closing(sqlite3.connect(self.metadata)) as db:
            db.execute("CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY,payload_json TEXT)")
            db.execute("INSERT INTO valuation_ticker_snapshots VALUES('A',?)", (json.dumps({"cik": "0000000001"}),))
            db.commit()
        self.save_ledger()

    def save_ledger(self):
        self.ledger_path.write_text(json.dumps(self.ledger))

    def run_apply(self):
        return apply_ledger(self.source, self.metadata, self.ledger_path, self.output)

    def test_only_new_copy_two_fields_changed_original_and_blocked_byte_exact(self):
        original_hash = hashlib.sha256(self.source.read_bytes()).hexdigest()
        result = self.run_apply()
        self.assertEqual(result["enrichedRows"], 2)
        self.assertEqual(result["unchangedRows"], 1)
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), original_hash)
        with closing(sqlite3.connect(self.source)) as before, closing(sqlite3.connect(self.output)) as after:
            old = before.execute("SELECT * FROM pit_financial_periods ORDER BY fiscal_period,dimension").fetchall()
            new = after.execute("SELECT * FROM pit_financial_periods ORDER BY fiscal_period,dimension").fetchall()
            for x, y in zip(old, new):
                self.assertEqual(x[:-1], y[:-1])
                if x[1] == "2008-Q1":
                    self.assertEqual(x[-1], y[-1])
                else:
                    p = json.loads(y[-1])
                    self.assertEqual(p.pop("reportingCurrency"), "USD")
                    evidence = p.pop("reportingCurrencyEvidence")
                    self.assertEqual(evidence["originalPayloadSha256"], hashlib.sha256(x[-1].encode()).hexdigest())
                    self.assertEqual(p, json.loads(x[-1]))
            self.assertEqual(before.execute("SELECT * FROM untouched").fetchall(), after.execute("SELECT * FROM untouched").fetchall())

    def test_refuses_existing_file_even_empty(self):
        self.output.touch()
        with self.assertRaises(FileExistsError): self.run_apply()

    def test_refuses_symlink_target(self):
        self.output.symlink_to(self.root / "not-present")
        with self.assertRaises(FileExistsError): self.run_apply()

    def test_runtime_snapshot_identity_not_ledger_self_claim(self):
        with closing(sqlite3.connect(self.metadata)) as db:
            db.execute("UPDATE valuation_ticker_snapshots SET payload_json=?", (json.dumps({"cik": "0000000002"}),)); db.commit()
        with self.assertRaisesRegex(ValueError, "CIK"): self.run_apply()
        self.assertFalse(self.output.exists())

    def test_tampered_public_cache_blocks_before_copy(self):
        self.facts_path.write_text("{}")
        with self.assertRaisesRegex(ValueError, "audit failed"): self.run_apply()
        self.assertFalse(self.output.exists())

    def test_wrong_row_count_blocks_before_copy(self):
        self.ledger["targets"][0]["financialRows"] = 1
        self.save_ledger()
        with self.assertRaisesRegex(ValueError, "row count"): self.run_apply()
        self.assertFalse(self.output.exists())

    def test_duplicate_ledger_target_rejected(self):
        self.ledger["targets"].append(copy.deepcopy(self.ledger["targets"][0]))
        self.save_ledger()
        with self.assertRaisesRegex(ValueError, "Duplicate"): self.run_apply()

    def test_existing_independent_currency_not_overwritten(self):
        with closing(sqlite3.connect(self.source)) as db:
            r = db.execute("SELECT payload_json FROM pit_financial_periods WHERE fiscal_period='2026-Q1' AND dimension='ARQ'").fetchone()[0]
            p = json.loads(r); p["reportingCurrency"] = "USD"
            db.execute("UPDATE pit_financial_periods SET payload_json=? WHERE fiscal_period='2026-Q1' AND dimension='ARQ'", (json.dumps(p),)); db.commit()
        with self.assertRaisesRegex(ValueError, "cannot be overwritten"): self.run_apply()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
