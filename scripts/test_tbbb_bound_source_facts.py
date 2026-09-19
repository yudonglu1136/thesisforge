import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("tbbb_source_review", Path(__file__).with_name("review-tbbb-bound-source-facts.py"))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class TbbbExactSourceFactsTests(unittest.TestCase):
    def fixture(self, directory, row="Net cash flows provided by operating activities 4,285,393 1,955,169"):
        path = Path(directory)/"issuer.htm"
        raw = f"<html><table><tr><td>{row}</td></tr></table></html>".encode()
        path.write_bytes(raw)
        source = "https://www.sec.gov/Archives/edgar/data/1978954/test/current.htm"
        economic = {"sources": {"q2": {"url": source, "availableDate": "2026-08-12"}},
                    "financialPeriods": [{"id": "h12026", "sourceId": "q2", "periodStartDate": "2026-01-01",
                                          "periodEndDate": "2026-06-30", "values": {"cfo": 4285393}}]}
        documents = {source: {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest()}}
        return economic, documents, path

    def test_exact_value_row_date_and_thousand_unit_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            e, d, _ = self.fixture(directory)
            fact = review.reconcile_financial_rows(e, d)[0]
            self.assertEqual(fact["value"], 4285393)
            self.assertEqual(fact["unit"], "MXN_thousand")
            self.assertEqual(fact["availableDate"], "2026-08-12")
            self.assertEqual(fact["periodEndDate"], "2026-06-30")
            self.assertIn("4,285,393", fact["sourceRow"])

    def test_different_value_is_not_rounded_into_agreement(self):
        with tempfile.TemporaryDirectory() as directory:
            e, d, _ = self.fixture(directory)
            e["financialPeriods"][0]["values"]["cfo"] = 4285392
            with self.assertRaisesRegex(ValueError, "No exact financial source row"):
                review.reconcile_financial_rows(e, d)

    def test_wrong_metric_with_same_number_does_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            e, d, _ = self.fixture(directory, "Total revenue 4,285,393")
            with self.assertRaises(ValueError): review.reconcile_financial_rows(e, d)

    def test_changed_original_bytes_do_not_pass_old_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            e, d, path = self.fixture(directory)
            path.write_bytes(b"modified document")
            with self.assertRaisesRegex(ValueError, "Source bytes changed"):
                review.reconcile_financial_rows(e, d)

    def test_missing_zero_is_not_defaulted(self):
        with tempfile.TemporaryDirectory() as directory:
            e, d, _ = self.fixture(directory)
            e["financialPeriods"][0]["values"]["cfo"] = 0
            with self.assertRaises(ValueError): review.reconcile_financial_rows(e, d)

    def test_numeric_substring_cannot_prove_smaller_value(self):
        with tempfile.TemporaryDirectory() as directory:
            e, d, _ = self.fixture(directory, "Net cash flows provided by operating activities 14,285,393")
            with self.assertRaises(ValueError): review.reconcile_financial_rows(e, d)


if __name__ == "__main__": unittest.main()
