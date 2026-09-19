import json
from pathlib import Path
import runpy
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace


ENGINE = runpy.run_path("scripts/translate-valuation-qa-mlx.py")
SOURCE = "Revenue increased 15% in Q2."
TARGET = "营收在 Q2 增长了 15%。"


def valid_audit():
    return {
        "source_sha256": ENGINE["sha256_text"](SOURCE),
        "translation_sha256": ENGINE["sha256_text"](TARGET),
        "source_chars": len(SOURCE), "translation_chars": len(TARGET),
        "chunk_count": 1, "status": "pass", "warnings": [],
    }


class ResumeIntegrityTests(unittest.TestCase):
    def test_translation_model_never_reconstructs_speaker_identity(self):
        source = "Hock Tan — President and CEO, Broadcom: Revenue grew ⟦N0⟧."
        tokenizer = mock.Mock()
        tokenizer.apply_chat_template.return_value = [1, 2]
        generate = mock.Mock(return_value=SimpleNamespace(texts=["营收增长了 ⟦N0⟧。 "]))
        modules = {"mlx_lm": SimpleNamespace(batch_generate=generate),
                   "mlx_lm.sample_utils": SimpleNamespace(make_sampler=lambda **kwargs: kwargs)}
        with mock.patch.dict(sys.modules, modules):
            result = ENGINE["translate_chunk_batch"]("model", tokenizer, [{"protected": source, "source": source}])
        self.assertEqual(tokenizer.apply_chat_template.call_args.args[0][1]["content"], "Revenue grew ⟦N0⟧.")
        self.assertTrue(result[0].startswith("Hock Tan — President and CEO, Broadcom:"))
        self.assertIn("营收增长了 ⟦N0⟧", result[0])

    def test_speaker_and_company_identity_cannot_be_fluently_substituted(self):
        source = "Hock Tan — President and CEO, Broadcom: No comment. Are you trying to locate who they are?"
        wrong = "霍克·谭 — 英特尔董事长兼首席执行官：无评论。你们是在试图找到他们是谁吗？"
        label, body = ENGINE["split_speaker_label"](source)
        self.assertEqual(label, "Hock Tan — President and CEO, Broadcom:")
        self.assertEqual(body, "No comment. Are you trying to locate who they are?")
        self.assertIn("speaker_identity_changed_or_not_preserved", ENGINE["chunk_warnings"](source, wrong))
        self.assertEqual(ENGINE["chunk_warnings"](source, label + " 无可奉告。你们在试图找出他们是谁吗？"), [])
        audit = {"source_sha256": ENGINE["sha256_text"](source), "translation_sha256": ENGINE["sha256_text"](wrong),
                 "source_chars": len(source), "translation_chars": len(wrong), "chunk_count": 1,
                 "status": "pass", "warnings": []}
        self.assertIsNone(ENGINE["reusable_source_audit"](source, wrong, audit))
        # An ordinary colon or dash in prose is not a speaker attribution.
        self.assertEqual(ENGINE["split_speaker_label"]("The outlook — more growth: Can you elaborate?")[0], "")

    def test_exact_pair_can_resume(self):
        for status in ["pass", "approved"]:
            row = valid_audit(); row["status"] = status
            self.assertIsNotNone(ENGINE["reusable_source_audit"](SOURCE, TARGET, row))

    def test_changed_source_or_target_is_not_approved_by_old_status(self):
        check = ENGINE["reusable_source_audit"]
        self.assertIsNone(check(SOURCE.replace("15%", "25%"), TARGET, valid_audit()))
        self.assertIsNone(check(SOURCE, TARGET.replace("15%", "25%"), valid_audit()))
        for key, value in [("source_sha256", ""), ("translation_sha256", ""),
                           ("source_chars", 0), ("translation_chars", 0),
                           ("status", "recovery_checked"), ("warnings", ["review"]),
                           ("chunk_count", 0), ("chunk_count", True)]:
            row = valid_audit(); row[key] = value
            with self.subTest(key=key, value=value):
                self.assertIsNone(check(SOURCE, TARGET, row))

    def test_editorial_provenance_is_not_silently_flattened(self):
        row = valid_audit(); row["editorialReview"] = {"reviewer": "explicit-owner"}
        self.assertIsNone(ENGINE["reusable_source_audit"](SOURCE, TARGET, row))

    def test_profit_amounts_are_not_rewritten_as_margins_in_mixed_clauses(self):
        for source, target in [
            ("Gross profit was $5 million and gross margin was 25%.",
             "毛利为500 万美元，毛利率为25%。"),
            ("Operating income was $2 million and operating margin was 10%.",
             "营业利润为200 万美元，营业利润率为10%。"),
        ]:
            self.assertEqual(ENGINE["normalize_financial_terms"](source, target), target)

    def test_dry_run_reports_modified_cache_as_missing_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "qa.sqlite"
            payload = {"history": [{"dataSnapshot": {"youtubeEarnings": {
                "qa": [{"question": SOURCE, "answer": ""}]}}}]}
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT)")
                db.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?)", ("TEST", json.dumps(payload)))
            cache, audit = root / "cache.json", root / "audit.json"
            cache.write_text(json.dumps({SOURCE: TARGET.replace("15%", "25%")}))
            audit.write_text(json.dumps({"numericProtection": ENGINE["NUMERIC_PROTECTION_VERSION"],
                                         "systemPromptSha256": ENGINE["sha256_text"](ENGINE["SYSTEM_PROMPT"]),
                                         "model": ENGINE["DEFAULT_MODEL"],
                                         "sources": {SOURCE: valid_audit()}}))
            before = (cache.read_bytes(), audit.read_bytes(), database.read_bytes())
            result = subprocess.run([sys.executable, "scripts/translate-valuation-qa-mlx.py",
                "--db", str(database), "--cache", str(cache), "--audit", str(audit), "--dry-run"],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            counts = json.loads(result.stdout)
            self.assertEqual((counts["cached"], counts["missing"]), (0, 1))
            self.assertEqual((cache.read_bytes(), audit.read_bytes(), database.read_bytes()), before)

            for field, value, message in [
                ("systemPromptSha256", "old-prompt", "Translation prompt changed"),
                ("model", "different-model", "Translation model changed"),
            ]:
                payload = {"numericProtection": ENGINE["NUMERIC_PROTECTION_VERSION"],
                           "systemPromptSha256": ENGINE["sha256_text"](ENGINE["SYSTEM_PROMPT"]),
                           "model": ENGINE["DEFAULT_MODEL"], "sources": {SOURCE: valid_audit()}}
                payload[field] = value
                audit.write_text(json.dumps(payload))
                prior = (cache.read_bytes(), audit.read_bytes())
                result = subprocess.run([sys.executable, "scripts/translate-valuation-qa-mlx.py",
                    "--db", str(database), "--cache", str(cache), "--audit", str(audit), "--dry-run"],
                    capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual((cache.read_bytes(), audit.read_bytes()), prior)


if __name__ == "__main__":
    unittest.main()
