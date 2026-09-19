import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("qa_edit", Path(__file__).with_name("review-valuation-qa-translations.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EditorialReviewTest(unittest.TestCase):
    def fixture(self):
        source, translated = "Next quarter revenue will grow 20%.", "本季度营收将增长20%。"
        audit = {"sources": {source: {"source_sha256": MODULE.sha(source), "translation_sha256": MODULE.sha(translated),
                 "source_chars": len(source), "translation_chars": len(translated), "chunk_count": 1, "status": "pass", "warnings": []}}}
        manifest = {"reviewer": "source-aligned test editor", "reviewedAt": "2026-09-06", "corrections": [{
            "sourceSha256": MODULE.sha(source), "originalTranslationSha256": MODULE.sha(translated),
            "protectedTranslation": "下一季度营收将增长⟦N0⟧。", "reason": "Preserve next-quarter timing."}]}
        return {source: translated}, audit, manifest

    def test_exact_edit_retains_prior_inputs_and_numeric_meaning(self):
        cache, audit, manifest = self.fixture()
        original = copy.deepcopy((cache, audit, manifest))
        output, report = MODULE.apply_review(cache, audit, manifest)
        self.assertEqual((cache, audit, manifest), original)
        self.assertEqual(next(iter(output.values())), "下一季度营收将增长20%。")
        self.assertEqual(report["statusCounts"], {"approved": 1})
        self.assertEqual(report["editorialReview"]["corrections"][0]["priorStatus"], "pass")

    def test_unknown_source_stale_translation_missing_or_duplicate_numbers_fail(self):
        for key, value in [("sourceSha256", "wrong"), ("originalTranslationSha256", "wrong"),
                           ("protectedTranslation", "下一季度营收将增长。"),
                           ("protectedTranslation", "下一季度营收将增长⟦N0⟧，另增30%。"),
                           ("protectedTranslation", "下一季度营收将增长⟦N0⟧，⟦N0⟧。"), ("reason", "")]:
            with self.subTest(key=key, value=value):
                cache, audit, manifest = self.fixture()
                manifest["corrections"][0][key] = value
                with self.assertRaises(ValueError):
                    MODULE.apply_review(cache, audit, manifest)

    def test_editorial_approval_cannot_erase_unreviewed_failures(self):
        cache, audit, manifest = self.fixture()
        audit["sources"]["Another source"] = {"status": "failed"}
        _, report = MODULE.apply_review(cache, audit, manifest)
        self.assertEqual(report["statusCounts"], {"approved": 1, "failed": 1})


if __name__ == "__main__":
    unittest.main()
