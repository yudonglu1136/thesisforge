import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("exact_direct", Path(__file__).with_name("validate_gev_nwsa_currency_primary.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FIXTURES = json.loads((Path(__file__).parent.parent / "server/fixtures/event-guidance-currency-evidence-gev-nwsa.json").read_text())


class ExactDirectCurrencyTests(unittest.TestCase):
    def test_actual_two_issuer_definitions_and_original_filing_headers(self):
        self.assertEqual(len(FIXTURES), 2)
        for row in FIXTURES:
            proof = row["contract"]["proof"]
            MODULE.validate_exact_metadata(row, proof)
            MODULE.validate_header_text(row["ticker"], proof["filingDateEvidence"]["headerText"])

    def test_other_event_future_date_form_or_document_rejected(self):
        for original in FIXTURES:
            for field, value in [("cik", "0000000001"), ("availableAt", "2030-01-01"), ("form", "8-K"), ("documentSha256", "0" * 64)]:
                proof = copy.deepcopy(original["contract"]["proof"])
                proof[field] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    MODULE.validate_exact_metadata(original, proof)
            with self.assertRaises(ValueError):
                MODULE.validate_exact_metadata({**original, "sourceId": "different"}, original["contract"]["proof"])

    def test_subsidiary_or_revenue_only_and_other_parent_definitions_rejected(self):
        for original in FIXTURES:
            for quote in ["Our foreign subsidiary functional currency is USD.", "Our revenue is denominated in U.S. dollars."]:
                proof = copy.deepcopy(original["contract"]["proof"])
                proof["quotes"][0] = quote
                with self.assertRaises(ValueError):
                    MODULE.validate_exact_metadata(original, proof)
            proof = copy.deepcopy(original["contract"]["proof"])
            proof["quotes"][1] = "GENERAL ELECTRIC COMPANY consolidated group"
            with self.assertRaises(ValueError):
                MODULE.validate_exact_metadata(original, proof)

    def test_header_future_date_wrong_cik_or_accession_rejected(self):
        for original in FIXTURES:
            proof = original["contract"]["proof"]
            text = proof["filingDateEvidence"]["headerText"]
            date = "20240305" if original["ticker"] == "GEV" else "2013-09-20"
            for before, after in [(date, "2030-01-01"), (proof["cik"], "0000000001"), (proof["accession"], "0000000001-01-000001")]:
                with self.subTest(ticker=original["ticker"], before=before), self.assertRaises(ValueError):
                    MODULE.validate_header_text(original["ticker"], text.replace(before, after))


if __name__ == "__main__":
    unittest.main()
