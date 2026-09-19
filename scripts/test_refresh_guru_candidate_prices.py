import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("candidate_prices", Path(__file__).with_name("refresh-guru-candidate-prices.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CandidatePriceTests(unittest.TestCase):
    def validate(self, rows, tickers=("CROX",)):
        return module.validate_prices(rows, list(tickers), "2026-08-20", "2026-09-04")

    def test_exact_currency_value_unchanged(self):
        rows = [{"ticker": "CROX", "date": "2026-09-04", "close": 95.61}]
        self.assertEqual(self.validate(rows), rows)

    def test_nonpositive_nonfinite_and_boolean_close_rejected(self):
        for close in (0, -1, float("nan"), float("inf"), True, None, "95.61"):
            with self.subTest(close=close), self.assertRaises(ValueError):
                self.validate([{"ticker": "CROX", "date": "2026-09-04", "close": close}])

    def test_no_substitute_security(self):
        with self.assertRaises(ValueError):
            self.validate([{"ticker": "SOFI", "date": "2026-09-04", "close": 5}])

    def test_missing_requested_security_rejected(self):
        with self.assertRaises(ValueError):
            self.validate([{"ticker": "CROX", "date": "2026-09-04", "close": 5}], ("CROX", "SOFI"))

    def test_duplicate_observation_rejected(self):
        row = {"ticker": "CROX", "date": "2026-09-04", "close": 5}
        with self.assertRaises(ValueError):
            self.validate([row, row])

    def test_out_of_window_rejected(self):
        for date in ("2026-08-19", "2026-09-05", "2026-08-99"):
            with self.subTest(date=date), self.assertRaises(ValueError):
                self.validate([{"ticker": "CROX", "date": date, "close": 5}])

    def test_empty_or_duplicate_scope_rejected(self):
        for tickers in ((), ("CROX", "CROX"), ("",), ("crox",)):
            with self.subTest(tickers=tickers), self.assertRaises(ValueError):
                self.validate([], tickers)


if __name__ == "__main__":
    unittest.main()
