import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("reconcile", Path(__file__).with_name("reconcile-guru-visible-valuation-gaps.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VisibleGapReconciliationTests(unittest.TestCase):
    def test_fund_is_not_operating_dcf(self):
        kind, _ = module.disposition([{"status": "fund_not_operating_company"}], [], set())
        self.assertEqual(kind, "fund_requires_nav_or_fund_method")

    def test_unique_symbol_does_not_prove_identity(self):
        meta = [{"ticker": "FB", "permaticker": 1, "cusips": "74349Y613"}]
        self.assertEqual(module.disposition([], meta, set())[0], "unresolved_or_historical_symbol")

    def test_exact_cusip_not_fuzzy_or_ticker_match(self):
        meta = [{"ticker": "A", "permaticker": 1, "cusips": "123456789"}]
        self.assertEqual(module.disposition([], meta, {"123456789"})[0], "additional_exact_local_identity_candidate")
        self.assertEqual(module.disposition([], meta, {"123456788"})[0], "unresolved_or_historical_symbol")

    def test_delisting_and_multiple_permanent_ids_remain_blocked(self):
        meta = [{"permaticker": 1, "cusips": "123456789", "isdelisted": "Y"}]
        self.assertEqual(module.disposition([], meta, {"123456789"})[0], "exact_local_identity_delisting_review")
        meta.append({"permaticker": 2, "cusips": "123456789"})
        self.assertEqual(module.disposition([], meta, {"123456789"})[0], "ambiguous_local_identity")

    def test_share_classes_and_conflicts_do_not_become_aliases(self):
        self.assertEqual(module.disposition([{"status": "missing_exact_local_identity"}], [], set())[0], "share_class_or_local_identity_review")
        self.assertEqual(module.disposition([{"status": "fund_not_operating_company"}, {"status": "covered"}], [], set())[0], "conflicting_security_dispositions_require_review")

    def test_denominator_duplicate_is_error(self):
        visible = {"currentQuarterAndLatestSnapshotInventory": {"missingTickers": ["A", "A"], "missingValuationTargets": 2}}
        with self.assertRaises(ValueError):
            module.reconcile(visible, {}, {}, {}, [], [], [])

    def test_staged_and_reviewed_are_not_deployed(self):
        visible = {"asOf": "2026-09-05", "occurrences": [], "currentQuarterAndLatestSnapshotInventory": {
            "missingTickers": ["A"], "missingValuationTargets": 1, "releasedValuationTargets": 0, "uniqueClickableTargets": 1}}
        inventory = {"securities": [{"ticker": "A", "status": "needs_economic_profile_and_official_guidance_review"}]}
        readiness = {"securities": [{"ticker": "A", "issuerReviewStatus": "pending_economic_review"}]}
        report = module.reconcile(visible, inventory, readiness, {"companies": [{"ticker": "A", "reviewStatus": "reviewed"}]}, [], [], [])
        self.assertEqual(report["stagedMissingTargets"], 1)
        self.assertEqual(report["newlyPublished"], 0)
        self.assertFalse(report["rows"][0]["publication"]["releaseAuthorizedByThisAudit"])

    def test_historical_exposure_cusip_does_not_authorize_current_identity(self):
        visible = {"asOf": "2026-09-05", "occurrences": [
            {"target": "A", "surface": "exposure.positions", "reportDate": "2025-06-30", "cusip": "123456789", "rendered": True, "clickable": True},
            {"target": "A", "surface": "guru_snapshot.holdings", "cusip": "", "rendered": True, "clickable": True}],
            "currentQuarterAndLatestSnapshotInventory": {"missingTickers": ["A"], "missingValuationTargets": 1,
                "releasedValuationTargets": 0, "uniqueClickableTargets": 1}}
        report = module.reconcile(visible, {"securities": []}, {"securities": []}, {"companies": []},
            [{"ticker": "A", "permaticker": 1, "cusips": "123456789"}], [], [])
        self.assertEqual(report["rows"][0]["disposition"], "unresolved_or_historical_symbol")


if __name__ == "__main__":
    unittest.main()
