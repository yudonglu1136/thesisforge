import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("crdo_package", Path(__file__).with_name("build-crdo-reviewed-input-package.py"))
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class CrdoPackageTest(unittest.TestCase):
    def balance_fixture(self, path, liability="Operating lease liabilities 2"):
        raw = ("<table>Cash and cash equivalents 10 Total assets 20 Current Liabilities: " + liability +
               " Total liabilities 5</table><table>Cash flows from operating activities: 3 "
               "Cash flows from financing activities: Employee equity proceeds 1 Effect of exchange rate 0</table>").encode()
        path.write_bytes(raw)
        doc = {"localPath": str(path), "sha256": PACKAGE.sha(raw), "url": "https://www.sec.gov/fixture", "filed": "2022-03-10",
               "aggregateFacts": [{"tag": "us-gaap:" + tag, "value": value * 1e6, "unit": "iso4217:USD", "end": "2022-01-31", "start": None, "context": "exact"}
                   for tag, value in [("CashAndCashEquivalentsAtCarryingValue", 10), ("OperatingLeaseLiabilityCurrent", 1), ("OperatingLeaseLiabilityNoncurrent", 2)]]}
        return doc, {"cash_m": 10, "debt_m": 2}

    def test_reviewed_balance_classifies_provider_lease_without_overwriting_raw(self):
        with tempfile.TemporaryDirectory() as temp:
            doc, raw = self.balance_fixture(Path(temp) / "filing")
            result = PACKAGE.balance_bridge(doc, "2022-01-31", raw)
            self.assertEqual(result["reportedDebtM"], 2)
            self.assertEqual(result["fundedDebtM"], 0)
            self.assertEqual(result["operatingLeaseCurrentM"], 1)
            self.assertEqual(result["operatingLeaseNoncurrentM"], 2)
            self.assertEqual(result["unrestrictedShortTermInvestmentsM"], 0)
            self.assertEqual(raw, {"cash_m": 10, "debt_m": 2})

    def test_funded_borrowing_cannot_be_silently_zeroed(self):
        with tempfile.TemporaryDirectory() as temp:
            doc, raw = self.balance_fixture(Path(temp) / "filing", "Loans payable 3")
            with self.assertRaisesRegex(ValueError, "Unmapped funded"):
                PACKAGE.balance_bridge(doc, "2022-01-31", raw)

    def test_unknown_investment_absence_and_wrong_provider_lease_block(self):
        with tempfile.TemporaryDirectory() as temp:
            doc, raw = self.balance_fixture(Path(temp) / "filing")
            raw["debt_m"] = 3
            with self.assertRaisesRegex(ValueError, "reconcile"):
                PACKAGE.balance_bridge(doc, "2022-01-31", raw)
            raw["debt_m"] = 2
            doc["filed"] = "2023-03-02"
            with self.assertRaisesRegex(ValueError, "No reviewed exact"):
                PACKAGE.balance_bridge(doc, "2022-01-31", raw)

    def test_exact_operating_fact_retains_primary_date_hash_context(self):
        doc = {"aggregateFacts": [{"tag": "us-gaap:GrossProfit", "start": "2022-01-01", "end": "2022-03-31",
            "unit": "iso4217:USD", "value": 12543000, "context": "exact"}], "url": "https://www.sec.gov/synthetic",
            "filed": "2022-05-01", "sha256": "a" * 64}
        item = PACKAGE.operating_component(doc, "gross_profit_m", "2022-01-01", "2022-03-31")
        self.assertEqual(item["valueM"], 12.543)
        self.assertEqual(item["availableDate"], "2022-05-01")
        self.assertIn("exact", item["locator"])

    def test_conflicting_operating_fact_is_not_averaged(self):
        fact = {"tag": "us-gaap:GrossProfit", "start": "2022-01-01", "end": "2022-03-31", "unit": "iso4217:USD", "value": 1000}
        with self.assertRaisesRegex(ValueError, "conflict"):
            PACKAGE.operating_component({"aggregateFacts": [fact, {**fact, "value": 2000}]}, "gross_profit_m", "2022-01-01", "2022-03-31")

    def test_draft_cannot_write_source_or_change_original(self):
        with tempfile.TemporaryDirectory() as temp:
            source, output = Path(temp) / "source", Path(temp) / "candidate"
            source.write_bytes(b"synthetic source identity only")
            manifest = {"sourceDatabaseSha256": PACKAGE.sha(source.read_bytes()), "companies": [{"ticker": "CRDO", "economicInputReview": {"status": "draft"}}]}
            with self.assertRaisesRegex(ValueError, "Draft"):
                PACKAGE.apply_manifest(source, output, manifest)
            self.assertFalse(output.exists())
            self.assertEqual(source.read_bytes(), b"synthetic source identity only")

    def test_reviewed_package_cannot_consume_changed_source_or_overwrite(self):
        with tempfile.TemporaryDirectory() as temp:
            source, output = Path(temp) / "source", Path(temp) / "candidate"
            source.write_bytes(b"synthetic source identity only")
            with self.assertRaisesRegex(ValueError, "changed"):
                PACKAGE.apply_manifest(source, output, {"sourceDatabaseSha256": "0" * 64})
            with self.assertRaisesRegex(ValueError, "overwrite"):
                PACKAGE.apply_manifest(source, source, {})
            self.assertFalse(output.exists())

    def test_source_evidence_date_cannot_be_future(self):
        with self.assertRaisesRegex(ValueError, "postdate"):
            PACKAGE.evidence({"url": "fixture", "availableDate": "2022-01-01"}, {"fixture": "2022-02-01"})


if __name__ == "__main__":
    unittest.main()
