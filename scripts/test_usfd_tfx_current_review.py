import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("current_review", Path(__file__).with_name("build-usfd-tfx-current-review.py"))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class CurrentReviewTests(unittest.TestCase):
    def test_exact_period_selection_and_duplicate_facts(self):
        row = {"tag": "x", "start": "2025-01-01", "end": "2025-12-31", "value": 1000000}
        doc = {"ticker": "TEST", "aggregateFacts": [row, dict(row), {**row, "end": "2026-12-31", "value": 9000000}]}
        self.assertEqual(review.fact(doc, "x", "2025-01-01", "2025-12-31"), 1)
        with self.assertRaisesRegex(ValueError, "Missing/ambiguous"):
            review.fact(doc, "x", "2024-01-01", "2025-12-31")

    def test_conflicting_same_period_facts_never_silently_selected(self):
        row = {"tag": "x", "start": None, "end": "2025-12-31", "value": 1000000}
        doc = {"ticker": "TEST", "aggregateFacts": [row, {**row, "value": 2000000}]}
        with self.assertRaises(ValueError):
            review.fact(doc, "x", None, "2025-12-31")

    def test_ttm_uses_prior_comparable_subtraction(self):
        self.assertEqual(review.ttm({"fy": {"coefficient": 1, "capex": 410},
                                    "h1": {"coefficient": 1, "capex": 174},
                                    "prior": {"coefficient": -1, "capex": 161}}, "capex"), 423)

    def test_tfx_negative_prior_cfo_is_added_not_absolute_subtracted(self):
        periods = {"fy": {"coefficient": 1, "cfo": 96.682},
                   "h1": {"coefficient": 1, "cfo": 138.559},
                   "prior": {"coefficient": -1, "cfo": -9.296}}
        self.assertEqual(review.ttm(periods, "cfo"), 244.537)

    def test_dcf_perpetuity_with_flat_cash_equals_cash_over_ke(self):
        result = review.dcf(100, 10, [0] * 5, 0.1, 0)
        self.assertAlmostEqual(result["equityValueM"], 1000, places=9)
        self.assertAlmostEqual(result["valuePerShare"], 100, places=9)
        self.assertEqual(result["forecasts"][0]["t"], 1)
        self.assertEqual(result["forecasts"][-1]["t"], 5)

    def test_reserve_and_legacy_option_stress_monotonic_without_double_charge(self):
        values = [review.dcf(cash, shares, [0.08, 0.07, 0.06, 0.04, 0.03], 0.1, 0.025)["valuePerShare"]
                  for cash, shares in [(748, 216.3), (728, 216.3), (728, 217.604833)]]
        self.assertGreater(values[0], values[1])
        self.assertGreater(values[1], values[2])
        self.assertAlmostEqual(values[1] / values[0], 728 / 748)
        self.assertAlmostEqual(values[2] / values[1], 216.3 / 217.604833)

    def test_current_scope_cannot_approve_generic_history(self):
        with self.assertRaisesRegex(ValueError, "historical"):
            review.validate_candidate({"genericHistoryApproved": True, "sources": {}}, "2026-09-05")

    def test_future_source_rejected_before_file_access(self):
        with self.assertRaisesRegex(ValueError, "Future"):
            review.validate_candidate({"genericHistoryApproved": False,
                                       "sources": {"x": {"availableDate": "2026-09-06"}}}, "2026-09-05")

    def test_invalid_discount_conventions_fail(self):
        for growth, ke, g in [([0] * 4, 0.1, 0.025), ([0] * 5, 0.02, 0.025)]:
            with self.assertRaises(ValueError): review.dcf(1, 1, growth, ke, g)


if __name__ == "__main__": unittest.main()
