import importlib.util
import unittest
import json
import sqlite3
import tempfile
from contextlib import closing
from datetime import date
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("build-pit-valuation-source.py")
SPEC = importlib.util.spec_from_file_location("build_pit_valuation_source", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ShareCountBasisTests(unittest.TestCase):
    def base_row(self):
        return {
            "fiscalperiod": "2026-Q2",
            "datekey": date(2026, 8, 1),
            "reportperiod": date(2026, 6, 30),
            "calendardate": date(2026, 6, 30),
            "lastupdated": date(2026, 8, 2),
            "dimension": "ARQ",
            "sharesbas": 100_000_000,
            "shareswadil": 60_000_000,
            "shareswa": 55_000_000,
            "sharefactor": 2,
            "revenueusd": 1_000_000_000,
            "netinccmnusd": 100_000_000,
        }

    def test_period_end_basic_shares_are_preferred_and_adjusted_once(self):
        result = MODULE.build_period("TEST", "TEST", self.base_row(), Path("unused.sqlite"))

        self.assertEqual(result["shares_m"], 200)
        self.assertEqual(result["sourceRecord"]["shareCountBasis"], "sharesbas")
        self.assertEqual(result["sourceRecord"]["appliedShareFactor"], 2)
        self.assertEqual(result["sourceRecord"]["rawShareCounts"]["shareswadil"], 60_000_000)
        self.assertIn("never infer splits", result["sourceRecord"]["shareCountPolicy"])

    def test_diluted_shares_are_only_a_fallback(self):
        row = self.base_row()
        row["sharesbas"] = None

        result = MODULE.build_period("TEST", "TEST", row, Path("unused.sqlite"))

        self.assertEqual(result["shares_m"], 120)
        self.assertEqual(result["sourceRecord"]["shareCountBasis"], "shareswadil")

    def test_london_ordinary_listing_excludes_us_adr_sharefactor(self):
        row = self.base_row()
        row["sharefactor"] = 0.25
        row["sharesbas"] = 2_400_000_000
        row.update(reportperiod=date(2023, 6, 30), datekey=date(2023, 8, 3), fiscalperiod="2023-Q4")

        result = MODULE.build_period("DGE.L", "DEO", row, Path("unused.sqlite"))

        self.assertEqual(result["shares_m"], 2400)
        self.assertEqual(result["sourceRecord"]["sharefactor"], 0.25)
        self.assertEqual(result["sourceRecord"]["appliedShareFactor"], 1)
        self.assertIn("US ADR equivalents", result["sourceRecord"]["shareCountPolicy"])

    def test_dge_dated_usd_financials_convert_all_money_but_not_ordinary_shares(self):
        row = self.base_row()
        row.update(sharefactor=0.25, sharesbas=2_400_000_000, fxusd=999,
                   revenue=20_000_000_000, gp=12_000_000_000, opinc=4_000_000_000,
                   netinc=2_000_000_000, ncfo=4_000_000_000, capex=-1_000_000_000,
                   equity=10_000_000_000, assets=50_000_000_000, cashneq=2_000_000_000, debt=24_000_000_000)
        rates = MODULE.FxRateBook([
            {"currency": "USD", "rate_date": "2026-07-31", "units_per_eur": 1.2},
            {"currency": "GBP", "rate_date": "2026-07-31", "units_per_eur": 0.9},
            {"currency": "GBP", "rate_date": "2026-08-03", "units_per_eur": 9},
        ])
        result = MODULE.build_period("DGE.L", "DEO", row, fx_rate_book=rates,
                                     identity={"reportingCurrency": "GBP", "currency": "GBP"})
        native = dict(revenue_m=20000, gross_profit_m=12000, operating_income_m=4000, net_income_m=2000,
                      cfo_m=4000, capex_m=1000, fcf_after_capex_m=3000, equity_m=10000, assets_m=50000, cash_m=2000, debt_m=24000)
        for key, value in native.items():
            self.assertAlmostEqual(result[key], value * .75, msg=key)
        self.assertEqual(result["shares_m"], 2400)
        self.assertEqual(result["sourceFinancialStatementCurrency"], "USD")
        self.assertEqual(result["sourceRecord"]["fxConversion"]["targetRateDate"], "2026-07-31")
        self.assertEqual(result["reportingCurrencyEvidence"]["availableAt"], "2024-01-30")

    def test_dge_fy23_is_not_recast_by_current_manifest_currency(self):
        row = self.base_row()
        row.update(reportperiod=date(2023, 6, 30), datekey=date(2023, 8, 3), fiscalperiod="2023-Q4", revenue=17_113_000_000)
        result = MODULE.build_period("DGE.L", "DEO", row, identity={"reportingCurrency": "USD", "currency": "GBP"})
        self.assertEqual(result["revenue_m"], 17113)
        self.assertEqual(result["sourceFinancialStatementCurrency"], "GBP")
        self.assertIsNone(result["sourceRecord"]["fxConversion"])

    def test_dge_missing_or_future_currency_evidence_fails(self):
        with self.assertRaisesRegex(RuntimeError, "requires official ECB FX"):
            MODULE.build_period("DGE.L", "DEO", self.base_row())
        row = self.base_row()
        row.update(datekey=date(2023, 12, 31), reportperiod=date(2023, 12, 31))
        with self.assertRaisesRegex(ValueError, "predates"):
            MODULE.build_period("DGE.L", "DEO", row)

    def test_azn_uses_ecb_pit_fx_instead_of_cross_listing_price_ratio(self):
        row = self.base_row()
        row.update(
            {
                "revenue": 1_000_000_000,
                "revenueusd": 1_000_000_000,
                "fxusd": 1.0,
                "price": 200.0,
            }
        )
        rates = MODULE.FxRateBook(
            [
                {
                    "currency": "USD",
                    "rate_date": "2026-07-31",
                    "units_per_eur": 1.16,
                    "source_url": "https://data-api.ecb.europa.eu/usd",
                },
                {
                    "currency": "GBP",
                    "rate_date": "2026-07-31",
                    "units_per_eur": 0.87,
                    "source_url": "https://data-api.ecb.europa.eu/gbp",
                },
            ]
        )

        result = MODULE.build_period(
            "AZN", "AZN", row, Path("unused.sqlite"), fx_rate_book=rates
        )

        expected_rate = 0.87 / 1.16
        self.assertAlmostEqual(result["revenue_m"], 1_000 * expected_rate)
        self.assertEqual(result["financialStatementCurrency"], "GBP")
        self.assertEqual(result["sourceFinancialStatementCurrency"], "USD")
        self.assertEqual(result["sourceRecord"]["sourceCurrency"], "USD")
        self.assertEqual(result["sourceRecord"]["modelCurrency"], "GBP")
        self.assertAlmostEqual(
            result["sourceRecord"]["fxConversion"]["conversionRate"], expected_rate
        )
        self.assertEqual(
            result["sourceRecord"]["fxConversion"]["targetRateDate"],
            "2026-07-31",
        )
        self.assertNotIn("price", result["sourceRecord"]["currencyScaleNote"].lower())
        self.assertNotIn("fallback", result["sourceRecord"]["currencyScaleNote"].lower())

    def test_azn_missing_ecb_rates_is_a_hard_failure(self):
        with self.assertRaisesRegex(RuntimeError, "requires official ECB FX rates"):
            MODULE.build_period("AZN", "AZN", self.base_row(), Path("unused.sqlite"))

    def test_reviewed_mxn_financials_use_raw_values_and_official_fx_only(self):
        row = self.base_row()
        row.update(revenue=20_000_000_000, revenueusd=999, ncfo=2_000_000_000,
                   capex=-1_000_000_000, fxusd=777, sharefactor=1)
        rates = MODULE.FxRateBook([
            {"currency": "MXN", "rate_date": "2026-07-31", "units_per_eur": 20, "source_url": "https://data-api.ecb.europa.eu/mxn"},
            {"currency": "USD", "rate_date": "2026-07-31", "units_per_eur": 1.2, "source_url": "https://data-api.ecb.europa.eu/usd"},
            {"currency": "MXN", "rate_date": "2026-08-03", "units_per_eur": 1, "source_url": "https://data-api.ecb.europa.eu/mxn"},
        ])
        result = MODULE.build_period("TBBB", "TBBB", row, fx_rate_book=rates,
            identity={"reportingCurrency": "MXN", "currency": "USD"})
        self.assertAlmostEqual(result["revenue_m"], 1200)
        self.assertAlmostEqual(result["cfo_m"], 120)
        self.assertAlmostEqual(result["capex_m"], 60)
        self.assertAlmostEqual(result["fcf_after_capex_m"], 60)
        self.assertEqual(result["shares_m"], 100)
        self.assertEqual(result["sourceRecord"]["rawProviderFxusd"], 777)
        self.assertEqual(result["sourceRecord"]["fxConversion"]["sourceRateDate"], "2026-07-31")
        # No normalized USD fallback when the underlying reported field is missing.
        self.assertIsNone(result["net_income_m"])

    def test_reviewed_foreign_currency_never_falls_back_to_provider_fx(self):
        with self.assertRaisesRegex(RuntimeError, "Missing ECB PIT FX"):
            MODULE.build_period("TBBB", "TBBB", self.base_row(), fx_rate_book=MODULE.FxRateBook([]),
                identity={"reportingCurrency": "MXN", "currency": "USD"})


class GuruUniverseTests(unittest.TestCase):
    def test_union_preserves_research_extras_and_excludes_unreviewed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            database = root / "baseline.sqlite"
            with closing(sqlite3.connect(database)) as db:
                db.execute("CREATE TABLE valuation_ticker_snapshots(ticker TEXT, payload_json TEXT)")
                db.execute("INSERT INTO valuation_ticker_snapshots VALUES('EXTRA', ?)", (json.dumps({"cik": "123"}),))
                db.commit()
            manifest = root / "guru.json"
            manifest.write_text(json.dumps({"schemaVersion": 1, "companies": [
                {"ticker": "NEW", "sourceTicker": "NEW", "priceTicker": "NEW", "cik": "456", "currency": "USD",
                 "reportingCurrency": "USD", "valuationProfile": "consumer_staples", "identityEvidence": ["fixture"], "reviewStatus": "reviewed"},
                {"ticker": "UNREVIEWED", "reviewStatus": "unreviewed"},
            ]}))
            rows = MODULE.target_universe(database, None, manifest)
            self.assertEqual([r["ticker"] for r in rows], ["EXTRA", "NEW"])
            self.assertEqual(rows[1]["membership"], "guru_reviewed_extra")

    def test_read_only_missing_baseline_is_not_created(self):
        with tempfile.TemporaryDirectory() as folder:
            database = Path(folder) / "absent.sqlite"
            with self.assertRaises(FileNotFoundError):
                MODULE.target_universe(database, None)
            self.assertFalse(database.exists())


if __name__ == "__main__":
    unittest.main()
