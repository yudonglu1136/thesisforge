import runpy
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


MODULE = runpy.run_path("scripts/translate-valuation-qa-mlx.py")


class TranslationNumericProtectionTests(unittest.TestCase):
    def test_monetary_suffix_never_consumes_the_first_letter_of_the_next_word(self):
        for source, expected in [
            ("$50 to $100 to $200", ["50美元至100美元", "200美元"]),
            ("$500,000 TAM per megawatt", ["50 万美元"]),
            ("$15 million of sales and $20 margin", ["1500 万美元", "20美元"]),
            ("$70 billion, $4B and $8m.", ["700 亿美元", "40 亿美元", "800 万美元"]),
            ("$9 total and $5 market cap", ["9美元", "5美元"]),
            ("a couple of $8 billions", ["80 亿美元"]),
        ]:
            with self.subTest(source=source):
                _, values = MODULE["protect_numbers"](source)
                self.assertEqual(values, expected)
        protected, _ = MODULE["protect_numbers"]("$50 to $100; $500,000 TAM")
        self.assertEqual(protected, "⟦N0⟧; ⟦N1⟧ TAM")
        plural_protected, _ = MODULE["protect_numbers"]("a couple of $8 billions")
        self.assertEqual(plural_protected, "a couple of ⟦N0⟧")

    def test_shared_scale_money_ranges_are_atomic_without_changing_currency_or_owners(self):
        for source, expected in [
            ("$250 to 275 million", ["2.5 亿美元至2.75 亿美元"]),
            ("$75-$100 million", ["7500 万美元至1 亿美元"]),
            ("$5 million through $8 million", ["500 万美元至800 万美元"]),
            ("between $1.66 and $1.68 billion", ["16.6 亿美元至16.8 亿美元"]),
            ("$5 to €10 million", ["5美元", "1000 万欧元"]),
            ("$5 million and $10 million", ["500 万美元", "1000 万美元"]),
            ("$5 million versus $10 million", ["500 万美元", "1000 万美元"]),
            ("raise by $5 to $10 million", ["5美元", "1000 万美元"]),
            ("revenue $5 million to costs of $10 million", ["500 万美元", "1000 万美元"]),
            ("2025 to $1.4 billion", ["2025", "14 亿美元"]),
        ]:
            with self.subTest(source=source):
                _, values = MODULE["protect_numbers"](source)
                self.assertEqual(values, expected)
        parts = MODULE["split_numeric_spans"]("Revenue of $250 to 275 million next year.")
        self.assertEqual([value for kind, value in parts if kind == "value"], ["2.5 亿美元至2.75 亿美元"])

    def test_previous_numeric_generation_cannot_be_silently_resumed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); database = root / "qa.sqlite"
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE valuation_ticker_snapshots(ticker TEXT, payload_json TEXT)")
                db.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?)", ("TEST", json.dumps({"history": []})))
            cache, audit = root / "cache.json", root / "audit.json"
            cache.write_text(json.dumps({"Old source": "原文"}))
            audit.write_text(json.dumps({"numericProtection": "deterministic-v5-segmented-span-reinsertion"}))
            result = subprocess.run([sys.executable, "scripts/translate-valuation-qa-mlx.py", "--db", str(database),
                "--cache", str(cache), "--audit", str(audit), "--dry-run"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Numeric protection changed", result.stderr)

    def test_domain_context_cannot_silently_reuse_cache_from_another_prompt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "qa.sqlite"
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE valuation_ticker_snapshots(ticker TEXT, payload_json TEXT)")
                db.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?)", ("TEST", json.dumps({"history": []})))
            cache, audit = root / "cache.json", root / "audit.json"
            cache.write_text(json.dumps({"Old source": "原文"}))
            audit.write_text(json.dumps({"systemPromptSha256": "old-context"}))
            before = (cache.read_bytes(), audit.read_bytes())
            result = subprocess.run([sys.executable, "scripts/translate-valuation-qa-mlx.py",
                "--db", str(database), "--cache", str(cache), "--audit", str(audit),
                "--context", "Semiconductor interconnects", "--dry-run"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("context changed", result.stderr)
            self.assertEqual((cache.read_bytes(), audit.read_bytes()), before)

    def test_currency_scales_are_converted_deterministically(self):
        protect_numbers = MODULE["protect_numbers"]
        restore_numbers = MODULE["restore_numbers"]
        source = "$8.15 billion, $925 million, $1 million, £2.7 billion"
        protected, values = protect_numbers(source)
        self.assertEqual(
            values,
            ["81.5 亿美元", "9.25 亿美元", "100 万美元", "27 亿英镑"],
        )
        self.assertEqual(
            restore_numbers(protected, values),
            "81.5 亿美元, 9.25 亿美元, 100 万美元, 27 亿英镑",
        )

    def test_percent_quarter_and_basis_points_are_preserved(self):
        protect_numbers = MODULE["protect_numbers"]
        restore_numbers = MODULE["restore_numbers"]
        source = "FY2026 Q2 grew 49% and margin expanded 300 basis points."
        protected, values = protect_numbers(source)
        translated = f"{protected}"
        restored = restore_numbers(translated, values)
        self.assertIn("FY2026 Q2", restored)
        self.assertIn("49%", restored)
        self.assertIn("300 个基点", restored)

    def test_missing_placeholder_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "placeholder mismatch"):
            MODULE["restore_numbers"]("译文只有 ⟦N0⟧", ["49%", "300 个基点"])

    def test_ascii_retry_placeholders_round_trip(self):
        protect_numbers = MODULE["protect_numbers"]
        restore_numbers = MODULE["restore_numbers"]
        source = "Revenue grew 49% in FY2026 Q2 and expanded 300 basis points."
        protected, values = protect_numbers(source, retry=True)
        self.assertIn("【49%】", protected)
        self.assertIn("【FY2026 Q2】", protected)
        self.assertIn("【300 个基点】", protected)
        retry_token = MODULE["retry_token"]
        translated = (
            f"营收增长 {retry_token(0, values[0])}，在 {retry_token(1, values[1])} "
            f"扩大 {retry_token(2, values[2])}。"
        )
        restored = restore_numbers(translated, values, retry=True)
        self.assertIn("FY2026 Q2", restored)
        self.assertIn("49%", restored)
        self.assertIn("300 个基点", restored)

    def test_repeated_numeric_values_keep_distinct_placeholders(self):
        protect_numbers = MODULE["protect_numbers"]
        restore_numbers = MODULE["restore_numbers"]
        protected, values = protect_numbers("Revenue was 178 and target was 178.", retry=True)
        self.assertEqual(values, ["178", "178"])
        self.assertEqual(protected.count("【178】"), 2)
        restored = restore_numbers(
            "营收为【178】，目标为【178】。",
            values,
            retry=True,
        )
        self.assertEqual(restored.count("178"), 2)

    def test_retry_prompt_lists_every_required_marker(self):
        prompt = MODULE["retry_system_prompt"](["2026", "15%"], final=True)
        self.assertIn("【2026】", prompt)
        self.assertIn("【15%】", prompt)
        self.assertIn("不得直接照抄英文", prompt)

    def test_short_english_echo_is_not_accepted_as_chinese(self):
        enough_chinese = MODULE["enough_chinese"]
        self.assertFalse(enough_chinese("谢谢. Great, thanks for taking my question.", "Great, thanks for taking my question."))
        self.assertTrue(enough_chinese("好的，感谢您回答我的问题。", "Great, thanks for taking my question."))

    def test_short_numeric_span_connector_can_contract_in_chinese(self):
        warnings = MODULE["numeric_span_warnings"]("this year compared to ", "今年与")
        self.assertEqual(warnings, [])
        self.assertIn(
            "unexpected_numeric_text_in_translated_span",
            MODULE["numeric_span_warnings"]("ended on December ", "结束于12月"),
        )

    def test_numeric_spans_preserve_order_and_repeated_values(self):
        split_numeric_spans = MODULE["split_numeric_spans"]
        spans = split_numeric_spans("Revenue was 178 in FY2026 Q2, versus 178 before.")
        self.assertEqual(
            [value for kind, value in spans if kind == "value"],
            ["178", "FY2026 Q2", "178"],
        )
        self.assertEqual("".join(value for _, value in spans), "Revenue was 178 in FY2026 Q2, versus 178 before.")

    def test_financial_margin_terms_are_normalized(self):
        normalize = MODULE["normalize_financial_terms"]
        has_financial_margin = MODULE["has_financial_margin"]
        self.assertEqual(normalize("gross margin pressure", "毛利压力"), "毛利率压力")
        self.assertEqual(normalize("contribution margin", "贡献毛利"), "贡献利润率")
        self.assertEqual(normalize("profit margin", "利润空间"), "利润率")
        self.assertEqual(normalize("free cash flow margin", "自由现金流利润率"), "自由现金流率")
        self.assertEqual(normalize("a high margin business", "高毛利业务"), "高毛利率业务")
        self.assertEqual(normalize("number one by a very long margin", "以很大优势排名第一"), "以很大优势排名第一")
        self.assertFalse(has_financial_margin("move resources on the margin"))
        self.assertFalse(has_financial_margin("at the margin of a problem"))
        self.assertFalse(has_financial_margin("outperformed by such a significant margin"))
        self.assertFalse(has_financial_margin("operational risk in margin loans"))
        self.assertTrue(has_financial_margin("operating margin expanded"))

    def test_product_versions_and_short_fiscal_years_are_protected(self):
        protect_numbers = MODULE["protect_numbers"]
        protected, values = protect_numbers(
            "E3, E5, FY25, RAV4, 2D, 5G and mid-20s",
            retry=True,
        )
        self.assertEqual(values, ["E3", "E5", "FY25", "RAV4", "2D", "5G", "mid-20s"])
        for value in values:
            self.assertIn(f"【{value}】", protected)

    def test_engineering_units_are_single_audit_values(self):
        protect_numbers = MODULE["protect_numbers"]
        protected, values = protect_numbers("800G and 1.6T transceivers", retry=True)
        self.assertEqual(values, ["800G", "1.6T"])
        self.assertIn("【800G】", protected)
        self.assertIn("【1.6T】", protected)

    def test_long_source_splits_without_losing_text(self):
        source = " ".join(["Revenue grew 20%." for _ in range(300)])
        chunks = MODULE["split_source"](source, 600)
        self.assertGreater(len(chunks), 1)
        self.assertEqual(" ".join(chunks), source)


if __name__ == "__main__":
    unittest.main()
