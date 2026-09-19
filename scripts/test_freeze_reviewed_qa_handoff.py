import copy
import importlib.util
from pathlib import Path
import sys
import unittest

SPEC = importlib.util.spec_from_file_location("qa_freeze_test", Path(__file__).with_name("freeze-reviewed-qa-recovery-handoff.py"))
MOD = importlib.util.module_from_spec(SPEC); sys.modules[SPEC.name] = MOD; SPEC.loader.exec_module(MOD)


class FrozenQaProofTests(unittest.TestCase):
    def record(self, source, target):
        return {"status": "approved", "source_sha256": MOD.sha(source), "translation_sha256": MOD.sha(target)}

    def test_exact_target_replays_and_does_not_claim_semantic_auto_approval(self):
        source, target = "Revenue is $5-$7 million.", "营收为500 万美元至700 万美元。"
        proof = MOD.verify_final_pair(source, target, self.record(source, target))
        self.assertEqual(proof["replayedTranslationSha256"], MOD.sha(target))
        self.assertIn("not_automatic_semantic_approval", proof["scope"])

    def test_target_or_source_hash_change_fails(self):
        source, target = "Revenue is $5 million.", "营收为500 万美元。"
        record = self.record(source, target)
        for bad_source, bad_target in ((source + "!", target), (source, target + "!")):
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                MOD.verify_final_pair(bad_source, bad_target, record)

    def test_pending_status_is_not_promoted(self):
        source, target = "Revenue is $5 million.", "营收为500 万美元。"
        record = self.record(source, target); record["status"] = "recovery_checked"
        with self.assertRaisesRegex(ValueError, "unreviewed recovery status"):
            MOD.verify_final_pair(source, target, record)

    def test_extra_digits_fail_even_with_matching_self_asserted_hash(self):
        source, target = "Revenue is $5 million.", "营收为500 万美元，2024年。"
        with self.assertRaisesRegex(ValueError, "unbound numeric"):
            MOD.verify_final_pair(source, target, self.record(source, target))

    def test_self_forged_cache_and_audit_pair_is_not_trusted(self):
        with self.assertRaisesRegex(ValueError, "independently reviewed"):
            MOD.verify_bundle_bytes(b'{"fake":"pass"}', b'{"status":"approved"}')

    def test_full_check_recognizes_only_exact_source_money_range_values(self):
        source = "Revenue is $5-$7 million."
        good = MOD.current_mechanical_check(source, "营收为500 万美元-700 万美元。")
        self.assertEqual(good["group"], "exact_source_money_range_representation_equivalence")
        bad = MOD.current_mechanical_check(source, "营收为5美元-700 万美元。")
        self.assertEqual(bad["status"], "recovered_pending_review")


if __name__ == "__main__": unittest.main()
