import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("ipo_inference", Path(__file__).with_name("build-ipo-reviewed-currency-inference.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReviewedCurrencyInferenceTests(unittest.TestCase):
    def test_reviewed_scope_is_specific_and_inferences_not_literal_declarations(self):
        self.assertEqual(set(MODULE.REVIEWED), {"CRWD", "PLTR", "APP", "ZS", "GDDY"})
        for review in MODULE.REVIEWED.values():
            self.assertEqual(len(review["sha"]), 64)
            self.assertIn("consolidat", review["reason"].lower())
            self.assertIn("consolidated financial statements", review["basis"].lower())

    def test_unknown_document_or_different_issuer_is_rejected(self):
        review = MODULE.REVIEWED["ZS"]
        document = {"cik": review["cik"], "filed": review["date"], "form": "424B4", "documentSha256": review["sha"]}
        with self.assertRaisesRegex(ValueError, "hash"):
            MODULE.reviewed_paragraphs("ZS", document, "invented source")
        document["filed"] = "2026-09-06"
        with self.assertRaisesRegex(ValueError, "exact reviewed"):
            MODULE.reviewed_paragraphs("ZS", document, "invented source")


if __name__ == "__main__":
    unittest.main()
