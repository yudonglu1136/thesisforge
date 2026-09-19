import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("coverage_audit", Path(__file__).with_name("audit-guru-valuation-coverage.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CoverageClassificationTests(unittest.TestCase):
    def test_financial_presence_does_not_mean_model_ready(self):
        self.assertEqual(MODULE.classify({"securityType2": "Common Stock"}, {"cusips": "123456789"}, True, True, False),
                         "needs_economic_profile_and_official_guidance_review")

    def test_funds_do_not_receive_operating_company_dcf(self):
        for security in ({"securityType2": "Mutual Fund"}, {"providerValidation": {"instrumentType": "ETF"}}):
            self.assertEqual(MODULE.classify(security, {"ticker": "FUND"}, True, True, False), "fund_not_operating_company")

    def test_identity_precedes_availability(self):
        self.assertEqual(MODULE.classify({}, None, True, True, False), "missing_exact_local_identity")

    def test_existing_coverage_and_input_gaps_remain_distinct(self):
        self.assertEqual(MODULE.classify({}, {}, False, False, True), "covered")
        self.assertEqual(MODULE.classify({}, {"ticker": "X"}, False, True, False), "missing_local_pit_financials")
        self.assertEqual(MODULE.classify({}, {"ticker": "X"}, True, False, False), "missing_local_price_history")

    def test_missing_readonly_database_never_created(self):
        with tempfile.TemporaryDirectory() as folder:
            database = Path(folder) / "missing.sqlite"
            with self.assertRaises(FileNotFoundError):
                MODULE.read_snapshots(database)
            self.assertFalse(database.exists())


if __name__ == "__main__":
    unittest.main()
