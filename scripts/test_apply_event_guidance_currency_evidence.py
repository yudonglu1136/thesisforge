import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("event_currency", Path(__file__).with_name("apply-event-guidance-currency-evidence.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EventCurrencyApplierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.sqlite"
        self.html = "<p>The reporting currency of the Company is the United States dollar.</p>"
        self.document = self.root / "original.htm"
        self.document.write_text(self.html)
        self.quote = "For the full year, we expect revenue of $350 million to $352 million."
        self.payload = {"ticker": "DDOG", "currency": None, "amount": 351, "growth_yoy": 20,
            "source_review": {"status": "pending_economics"}, "currency_resolution": {"status": "source_currency_required"}}
        with sqlite3.connect(self.source) as db:
            db.execute("CREATE TABLE pit_guidance_events (id TEXT PRIMARY KEY,ticker TEXT,observed_at TEXT,evidence_excerpt TEXT,currency TEXT,payload_json TEXT,amount REAL,unit TEXT,metric_name TEXT,fiscal_period TEXT)")
            db.execute("INSERT INTO pit_guidance_events VALUES (?,?,?,?,?,?,?,?,?,?)", ["id1", "DDOG", "2019-11-12", self.quote, None, json.dumps(self.payload), 351, "reported millions", "revenue_guidance", "Q32019"])
            db.execute("INSERT INTO pit_guidance_events VALUES (?,?,?,?,?,?,?,?,?,?)", ["unrelated", "OTHER", "2020-01-01", "unchanged", "GBP", "{}", 1, "reported millions", "revenue_guidance", "Q12020"])
            db.execute("CREATE TABLE pit_financial_periods (ticker TEXT,payload_json TEXT)")
            db.execute("INSERT INTO pit_financial_periods VALUES ('TSM','{\"nativeCurrency\":\"TWD\"}')")
        self.event = {"ticker": "DDOG", "sourceId": "id1", "observedAt": "2019-11-12", "originalQuote": self.quote,
            "originalQuoteSha256": MODULE.digest(self.quote), "originalPayloadSha256": MODULE.digest(json.dumps(self.payload)),
            "proof": {"currency": "USD", "evidenceType": "explicit_company_reporting_currency_declaration",
                "quotes": ["The reporting currency of the Company is the United States dollar."], "availableAt": "2019-09-19",
                "sourceUrl": "https://www.sec.gov/Archives/edgar/data/1561550/000119312519249577/d745413d424b4.htm",
                "documentPath": str(self.document), "documentSha256": MODULE.digest(self.html),
                "form": "424B4", "accession": "0001193125-19-249577", "cik": "0001561550"}}

    def apply(self, events=None):
        ledger = self.root / "ledger.json"
        ledger.write_text(json.dumps({"events": events if events is not None else [self.event]}))
        return MODULE.apply(self.source, [ledger], self.root / "new.sqlite", self.root / "registry.json", self.root / "report.json")

    def test_copy_only_exact_currency_fields_and_financial_identity_preserved(self):
        before = self.source.read_bytes()
        report = self.apply()
        self.assertEqual(before, self.source.read_bytes())
        self.assertEqual(report["changedEvents"], 1)
        self.assertTrue(report["allFinancialRowsExact"])
        self.assertFalse(report["releaseAuthorized"])
        with sqlite3.connect(self.root / "new.sqlite") as db:
            currency, raw = db.execute("SELECT currency,payload_json FROM pit_guidance_events WHERE id='id1'").fetchone()
            self.assertEqual(currency, "USD")
            enriched = json.loads(raw)
            for key in ["amount", "growth_yoy", "source_review"]:
                self.assertEqual(enriched[key], self.payload[key])
            self.assertIsNone(enriched["official_guidance_currency_evidence"]["originalQuotedCurrency"])
            self.assertEqual(db.execute("SELECT payload_json FROM pit_financial_periods").fetchone()[0], '{"nativeCurrency":"TWD"}')
            self.assertEqual(db.execute("SELECT currency,payload_json FROM pit_guidance_events WHERE id='unrelated'").fetchone(), ("GBP", "{}"))

    def test_future_wrong_cik_or_wrong_quote_fails_before_copy(self):
        for field, value in [("availableAt", "2020-01-01"), ("cik", "0000000001"), ("documentSha256", "f" * 64)]:
            with self.subTest(field=field):
                event = copy.deepcopy(self.event)
                event["proof"][field] = value
                with self.assertRaises(ValueError):
                    self.apply([event])
                self.assertFalse((self.root / "new.sqlite").exists())
        self.event["originalQuoteSha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "quote changed"):
            self.apply()

    def test_tampered_original_document_and_sales_currency_only_are_rejected(self):
        self.document.write_text(self.html + "tampered")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.apply()
        html = "<p>Our sales contracts are denominated in U.S. dollars.</p>"
        self.document.write_text(html)
        self.event["proof"]["documentSha256"] = MODULE.digest(html)
        self.event["proof"]["quotes"] = ["Our sales contracts are denominated in U.S. dollars."]
        with self.assertRaisesRegex(ValueError, "No direct"):
            self.apply()

    def test_duplicates_existing_output_and_already_resolved_currency_fail(self):
        with self.assertRaisesRegex(ValueError, "unique"):
            self.apply([self.event, self.event])
        self.apply()
        with self.assertRaises(FileExistsError):
            self.apply()

    def test_existing_currency_is_not_overwritten(self):
        with sqlite3.connect(self.source) as db:
            db.execute("UPDATE pit_guidance_events SET currency='CAD' WHERE id='id1'")
        with self.assertRaisesRegex(ValueError, "Existing currency"):
            self.apply()

    def test_existing_registry_entries_are_preserved_and_missing_contracts_rejected(self):
        inherited = self.root / "existing.json"
        prior = {"version": MODULE.VERSION, "documents": {"prior-document": {"ticker": "PREV", "sourceIds": ["prior"], "paragraphSha256": ["abc"]}}}
        inherited.write_text(json.dumps(prior))
        ledger = self.root / "ledger.json"
        ledger.write_text(json.dumps({"events": [self.event]}))
        MODULE.apply(self.source, [ledger], self.root / "new.sqlite", self.root / "registry.json", self.root / "report.json", inherited)
        self.assertEqual(json.loads((self.root / "registry.json").read_text())["documents"]["prior-document"], prior["documents"]["prior-document"])
        with sqlite3.connect(self.source) as db:
            db.execute("UPDATE pit_guidance_events SET payload_json=? WHERE id='unrelated'", (json.dumps({"official_guidance_currency_evidence": {"proof": {"documentSha256": "missing"}}}),))
        with self.assertRaisesRegex(ValueError, "Inherited reviewed"):
            MODULE.apply(self.source, [ledger], self.root / "new2.sqlite", self.root / "registry2.json", self.root / "report2.json", inherited)

    def test_eps_keeps_null_monetary_amount_and_preserves_per_share_scalar(self):
        quote = "We expect adjusted EPS of $2.19-$2.43 for the full year."
        payload = {**self.payload, "amount": None, "per_share_value": 2.31}
        with sqlite3.connect(self.source) as db:
            db.execute("UPDATE pit_guidance_events SET metric_name='eps_guidance',unit='currency_per_share',amount=NULL,evidence_excerpt=?,payload_json=? WHERE id='id1'", (quote, json.dumps(payload)))
        self.event.update(originalQuote=quote, originalQuoteSha256=MODULE.digest(quote), originalPayloadSha256=MODULE.digest(json.dumps(payload)))
        self.apply()
        with sqlite3.connect(self.root / "new.sqlite") as db:
            amount, raw = db.execute("SELECT amount,payload_json FROM pit_guidance_events WHERE id='id1'").fetchone()
            self.assertIsNone(amount)
            result=json.loads(raw)
            self.assertEqual(result["per_share_value"], 2.31)
            self.assertIsNone(result["official_guidance_currency_evidence"]["amountM"])
            self.assertEqual(result["official_guidance_currency_evidence"]["perShareValue"], 2.31)


if __name__ == "__main__":
    unittest.main()
