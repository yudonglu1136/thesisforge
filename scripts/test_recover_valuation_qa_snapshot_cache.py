import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("qa_recovery", Path(__file__).with_name("recover-valuation-qa-snapshot-cache.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SnapshotRecoveryTest(unittest.TestCase):
    def fixture(self):
        source, target = "Revenue grew 20% in Q3.", "第三季度营收增长20%。"
        expected = {"baselineSha256": "a" * 64, "cacheSha256": "b" * 64, "auditSha256": "c" * 64, "usedSourceCount": 1}
        attestation = {**{k: v for k, v in expected.items() if k != "baselineSha256"}, "status": "pass", "model": "prior Qwen attestation"}
        row = {"sha256": expected["baselineSha256"], "cache": {source: target}, "references": {source: [{"ticker": "TEST", "field": "question"}]},
               "sources": {source}, "counts": {"uniqueSourceFields": 1}, "metadata": {"transcript_qa_translation_audit": json.dumps(attestation)}}
        return row, expected

    def test_recovery_preserves_text_and_prior_attestation_without_fabricating_approval(self):
        row, expected = self.fixture(); before = copy.deepcopy(row)
        cache, audit, samples = MODULE.recover(row, expected)
        self.assertEqual(row, before)
        self.assertEqual(cache, row["cache"])
        self.assertFalse(audit["consumableByEnricher"])
        self.assertFalse(audit["originalCacheBytesRecovered"])
        self.assertFalse(audit["manualSemanticApproval"])
        self.assertEqual(audit["statusCounts"], {"recovery_checked": 1})
        self.assertEqual(audit["groupCounts"], {"explicit_representation_equivalence": 1})

    def test_missing_or_stale_baseline_and_attestation_fail(self):
        for key in ("baselineSha256", "cacheSha256", "auditSha256", "usedSourceCount"):
            row, expected = self.fixture(); expected[key] = "changed"
            with self.assertRaises(ValueError): MODULE.recover(row, expected)

    def test_number_mutation_duplicate_and_omission_do_not_pass(self):
        for target in ("第三季度营收增长200%。", "第三季度营收增长20%，20%。", "第三季度营收增长。", "第四季度营收增长20%。"):
            result = MODULE.check_pair("Revenue grew 20% in Q3.", target)
            self.assertEqual(result["status"], "recovered_pending_review")

    def test_fiscal_year_equivalence_is_narrow(self):
        self.assertEqual(MODULE.numeric_check("FY2026 grew 20%.", "2026财年增长20%。", normalize=True)["status"], "pass")
        self.assertEqual(MODULE.numeric_check("FY2026 grew 20%.", "2027财年增长20%。", normalize=True)["status"], "pending_review")
        self.assertEqual(MODULE.numeric_check("Revenue grew 20%.", "营收增长20倍。", normalize=True)["status"], "pending_review")

    def test_language_guard_has_priority_even_if_numeric_tokens_match(self):
        result = MODULE.check_pair("Revenue increased 20%.", "Revenue increased 20%.")
        self.assertEqual(result["group"], "language_or_terminology_guard_review")
        self.assertEqual(result["status"], "recovered_pending_review")

    def test_optional_aliases_cannot_reject_an_exact_match(self):
        result = MODULE.check_pair("Q1 and 1Q are labels.", "Q1与1Q均为季度标签。")
        self.assertEqual(result["group"], "exact_numeric_guard_pass")
        self.assertEqual(result["status"], "recovery_checked")

    def test_new_sources_are_not_inherited_and_conflicts_fail(self):
        row, expected = self.fixture()
        candidate = {"sources": {*row["sources"], "New question?"}, "sha256": "d" * 64,
                     "counts": {}, "references": {"New question?": [{"ticker": "NEW"}]}}
        _, audit, _ = MODULE.recover(row, expected, candidate)
        self.assertEqual(audit["untranslatedCurrentSourceCount"], 1)
        source = next(iter(row["cache"]))
        with self.assertRaisesRegex(ValueError, "Conflicting translation"):
            MODULE.recover(row, expected, extra=({source: "另一份中文"}, {}, {}))

    def test_output_is_immutable_and_not_an_approval_cache(self):
        row, expected = self.fixture(); outputs = MODULE.recover(row, expected)
        with tempfile.TemporaryDirectory() as parent:
            directory = Path(parent) / "new"
            MODULE.write_new(directory, *outputs)
            with self.assertRaises(FileExistsError): MODULE.write_new(directory, *outputs)
            self.assertFalse((directory / "audit.json").exists())


if __name__ == "__main__":
    unittest.main()
