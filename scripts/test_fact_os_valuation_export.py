import importlib.util
from datetime import date
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("fact_valuation_export", Path(__file__).with_name("export-fact-os-valuation-source.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ExportTest(unittest.TestCase):
    def row(self):
        return {"ticker": "MSFT", "dimension": "ART", "fiscalperiod": "2020-Q1",
                "date": date(2020, 4, 20), "reportperiod": date(2020, 3, 31), "calendardate": date(2020, 3, 31),
                "fxusd": 1, "sharefactor": 1, "shareswadil": 10_000_000,
                "ncfo": 5_000_000, "capex": -1_000_000, "revenue": 10_000_000,
                "provenance": {"source": "Sharadar", "table": "fundamentals", "ingestion_run": "test"}}

    def test_ttm_is_not_annualized_again(self):
        period = module.build_period("MSFT", self.row())
        self.assertEqual(period["revenue_m"], 10)
        self.assertEqual(period["fcf_after_capex_m"], 4)
        self.assertTrue(period["sourceRecord"]["metricsAreTrailingTwelveMonths"])
        self.assertEqual(period["sourceRecord"]["provenance"]["ingestion_run"], "test")

    def test_earliest_ar_dimension_remains_separate(self):
        first = self.row()
        later = {**first, "date": date(2020, 7, 1), "revenue": 20_000_000}
        quarter = {**first, "dimension": "ARQ"}
        selected = module.first_visible([later, first, quarter])
        self.assertEqual(len(selected), 2)
        self.assertEqual({row["dimension"] for row in selected}, {"ART", "ARQ"})
        self.assertTrue(all(row["date"] == first["date"] for row in selected))

    def test_missing_fx_and_sharefactor_are_not_assumed(self):
        with self.assertRaises(ValueError):
            module.build_period("MSFT", {**self.row(), "fxusd": None})
        with self.assertRaises(ValueError):
            module.build_period("MSFT", {**self.row(), "sharefactor": None})


if __name__ == "__main__":
    unittest.main()
