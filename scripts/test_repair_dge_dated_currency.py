import importlib.util
from datetime import date
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("dge_repair", Path(__file__).with_name("repair-dge-dated-currency.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
BUILDER = MODULE.builder_module()


class DgeCurrencyRepairTests(unittest.TestCase):
    def inputs(self):
        raw = dict(ticker="DEO", fiscalperiod="2026-Q2", dimension="ART", datekey=date(2026, 2, 25),
                   reportperiod=date(2025, 12, 31), calendardate=date(2025, 12, 31), sharesbas=2_000_000_000,
                   sharefactor=.25, ncfo=4_000_000_000, capex=-1_000_000_000, revenue=20_000_000_000)
        rates = BUILDER.FxRateBook([
            {"currency": "USD", "rate_date": "2026-02-25", "units_per_eur": 1.2},
            {"currency": "GBP", "rate_date": "2026-02-25", "units_per_eur": .9}])
        old = dict(ticker="DGE.L", sourceTicker="DEO", periodEndDate="2025-12-31", asOfDate="2026-02-25",
                   sourceDimension="ART", financialStatementCurrency="GBP", sourceRecord={"currencyScale": 1},
                   shares_m=2000, revenue_m=20000, cfo_m=4000, capex_m=1000, fcf_after_capex_m=3000)
        return old, raw, rates

    def test_independent_provider_and_fx_reconstruction(self):
        old, raw, rates = self.inputs()
        fixed, audit = MODULE.repaired_payload(old, raw, rates, BUILDER)
        self.assertEqual(fixed["revenue_m"], 15000)
        self.assertEqual(fixed["fcf_after_capex_m"], 2250)
        self.assertEqual(fixed["shares_m"], 2000)
        self.assertEqual(fixed["sourceRecord"]["nativeReportedFinancialsM"]["revenue_m"], 20000)
        self.assertEqual(audit["independentGbpReconstruction"], "pass")
        self.assertEqual(old["revenue_m"], 20000)

    def test_double_conversion_is_rejected(self):
        old, raw, rates = self.inputs()
        old["sourceRecord"]["currencyScale"] = .75
        with self.assertRaisesRegex(ValueError, "double FX"):
            MODULE.repaired_payload(old, raw, rates, BUILDER)

    def test_changed_provider_observation_requires_reconciliation(self):
        old, raw, rates = self.inputs()
        raw["revenue"] = 999
        with self.assertRaisesRegex(ValueError, "Native provider reconciliation"):
            MODULE.repaired_payload(old, raw, rates, BUILDER)

    def test_fy23_cannot_be_relabelled_with_later_usd_recasts(self):
        old, raw, rates = self.inputs()
        old["periodEndDate"] = "2023-06-30"
        with self.assertRaisesRegex(ValueError, "Outside exact"):
            MODULE.repaired_payload(old, raw, rates, BUILDER)


if __name__ == "__main__":
    unittest.main()
