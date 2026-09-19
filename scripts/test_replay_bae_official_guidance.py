import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("bae_replay", Path(__file__).with_name("replay-bae-official-guidance.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
OFFICIAL = MODULE.load("bae_test_sec", "import-sec-official-guidance.py")
TABLE = """##### 2026 Upgraded Group guidance 1
We are upgrading guidance for the full year, as shown in the table below.
| Year ended 31 December 2026 | Updated guidance | Previous guidance | Year ended 31 December 2025 Results |
| --- | --- | --- | --- |
| **Sales** | Increase in the range of 8% to 10% | Increase in the range of 7% to 9% | £30,662m |
| **Underlying EBIT** | Increase in the range of 10% to 12% | Increase in the range of 9% to 11% | £3,322m |
| **Underlying EPS** | Increase in the range of 11% to 13% | Increase in the range of 9% to 11% | 75.2p |
| **Free cash flow target** | >£2.0bn | >£1.3bn | £2,158m |
| **2024 to 2026 cumulative free cash flow** | >£6.7bn | >£6.0bn | |
"""


class BaeTableColumnTests(unittest.TestCase):
    def events(self, text=TABLE):
        return MODULE.project_events(OFFICIAL, "2026-Q2", "2026-07-30", "https://www.baesystems.com/en-sa/article/2026-half-year-results", text)

    def test_current_column_not_previous_guidance_or_historical_actual(self):
        rows = self.events()
        self.assertEqual(len(rows), 5)
        self.assertEqual([r["growth_yoy"] for r in rows[:3]], [9, 11, 12])
        self.assertTrue(all(r["amount"] is None for r in rows[:3]))
        self.assertEqual(rows[3]["amount"], 2000)
        self.assertEqual(rows[3]["currency"], "GBP")
        self.assertEqual(rows[3]["guidance_comparator"], "greater_than")
        self.assertTrue(all(r["guidance_target_year"] == 2026 for r in rows))
        self.assertNotIn("30,662", rows[0]["evidence_excerpt"])
        self.assertIn("30,662", rows[0]["table_column_evidence"]["rawTable"])
        self.assertNotIn("1.3bn", rows[3]["evidence_excerpt"])

    def test_cumulative_cash_flow_cannot_be_used_as_annual(self):
        row = self.events()[-1]
        self.assertEqual(row["amount"], 6700)
        self.assertEqual(row["guidance_scope"], "multi_year_target")
        self.assertEqual(row["guidance_subject"], "non_company_or_non_periodic")
        self.assertFalse(OFFICIAL.usable_guidance_event(row))

    def test_split_header_rows_still_choose_updated_column(self):
        text = TABLE.replace("| Year ended 31 December 2026 | Updated guidance | Previous guidance | Year ended 31 December 2025 Results |\n| --- | --- | --- | --- |", "| Year ended 31 December 2026 | | | Year ended 31 December 2025 |\n| --- | --- | --- | --- |\n| | Updated guidance | Previous guidance | Results |")
        self.assertEqual(self.events(text)[3]["amount"], 2000)

    def test_no_current_column_does_not_promote_previous_or_results(self):
        self.assertEqual(self.events(TABLE.replace("Updated guidance", "Prior outlook")), [])

    def test_ambiguous_current_columns_fail(self):
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            self.events(TABLE.replace("Previous guidance", "Updated guidance"))

    def test_original_table_context_and_hash_are_preserved(self):
        row = self.events()[3]
        evidence = row["table_column_evidence"]
        self.assertEqual(evidence["selectedColumn"], 1)
        self.assertEqual(evidence["selectedHeader"], "Updated guidance")
        self.assertEqual(len(evidence["tableSha256"]), 64)
        self.assertIn("£2,158m", str(evidence["rows"]))

    def test_frozen_flattened_prior_quote_reconstructs_only_named_four_cells(self):
        raw = "Guidance is provided on a constant currency basis using an exchange rate of $1.28:£1. | Year ended 31 December 2025 | | | Year ended 31 December 2024 | | --- | --- | --- | --- | | | Updated guidance | Previous guidance | Results | | Sales | Increase in the range of 8% to 10% | Increase in the range of 7% to 9% | £28,335m | | Underlying EBIT | Increase in the range of 9% to 11% | Increase in the range of 8% to 10% | £3,015m | | Underlying EPS | Increase in the range of 8% to 10% | Increase in the range of 8% to 10% | 68.5p | | Free cash flow target | >£1.1bn | >£1.1bn | £2,505m |"
        rows = self.events(raw)
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["growth_yoy"], 9)
        self.assertIsNone(rows[0]["amount"])
        self.assertEqual(rows[3]["amount"], 1100)
        self.assertEqual(rows[3]["guidance_target_year"], 2025)
        self.assertEqual(rows[3]["table_column_evidence"]["rawTable"], raw)
        self.assertNotIn("1.28", rows[3]["evidence_excerpt"])


if __name__ == "__main__":
    unittest.main()
