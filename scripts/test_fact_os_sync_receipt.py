import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("sync_receipt", Path(__file__).with_name("verify-fact-os-sync-receipt.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReceiptTests(unittest.TestCase):
    def receipt(self):
        state = {"stocks": {"row_count": 12, "min_date": "2000-01-01", "max_date": "2026-09-18", "last_error": None}}
        return {"finished_at": "2026-09-19", "errors": [], "before": state,
                "passes": [{"pass": number, "results": [{"dataset": "stocks", "status": "unchanged"}], "after": copy.deepcopy(state)} for number in (1, 2)],
                "assertions": {name: True for name in ("no_history_shrink", "second_pass_same_row_counts", "second_pass_same_date_coverage", "all_syncs_succeeded")}}

    def test_finished_at_without_complete_passes_is_not_success(self):
        data = self.receipt()
        data["passes"].pop()
        data["assertions"] = {}
        errors = module.validate_receipt(data, ["stocks"])
        self.assertIn("two_complete_passes_required", errors)
        self.assertIn("missing_or_failed_assertions", errors)

    def test_success_and_actual_states_override_claimed_assertions(self):
        data = self.receipt()
        self.assertEqual(module.validate_receipt(data, ["stocks"]), [])
        empty = self.receipt()
        empty["passes"][0]["results"][0]["status"] = "no_rows"
        self.assertIn("pass_1_result_not_successful", module.validate_receipt(empty, ["stocks"]))
        data["passes"][1]["after"]["stocks"]["row_count"] = 4
        self.assertIn("stocks:history_shrunk", module.validate_receipt(data, ["stocks"]))

    def test_missing_table_and_stale_error_rejected(self):
        data = self.receipt()
        data["passes"][0]["after"]["stocks"]["last_error"] = "previous failure"
        errors = module.validate_receipt(data, ["stocks", "funds"])
        self.assertIn("pass_1_table_set_incomplete", errors)
        self.assertIn("pass_1_unresolved_sync_error", errors)


if __name__ == "__main__":
    unittest.main()
