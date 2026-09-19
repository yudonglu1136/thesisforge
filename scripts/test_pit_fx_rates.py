import tempfile
import csv
import io
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import pit_fx_rates as fx


class CurrencyCacheTests(unittest.TestCase):
    def test_historical_stopped_series_cannot_value_current_money(self):
        rows = [{"currency": "ARS", "rate_date": "2020-10-30", "units_per_eur": 92},
                {"currency": "USD", "rate_date": "2026-04-16", "units_per_eur": 1.15}]
        with self.assertRaisesRegex(RuntimeError, "Stale ECB PIT FX rate"):
            fx.FxRateBook(rows).conversion("ARS", "USD", "2026-04-16")
        with patch.object(fx, "fetch_currency", return_value=rows[:1]):
            with self.assertRaisesRegex(RuntimeError, "Stale ECB PIT FX coverage"):
                fx.rate_book_for_range("2020-10-30", "2026-04-16", currencies=("ARS",), cache_path=None)

    def test_weekend_carry_allowed_but_gap_within_range_rejected(self):
        rows = [{"currency": "USD", "rate_date": date, "units_per_eur": 1.15}
                for date in ("2026-01-02", "2026-09-04")]
        book = fx.FxRateBook(rows)
        self.assertAlmostEqual(book.conversion("EUR", "USD", "2026-09-06")["conversionRate"], 1.15)
        with self.assertRaisesRegex(RuntimeError, "Stale ECB PIT FX rate"):
            book.conversion("EUR", "USD", "2026-08-20")

    def test_nan_infinity_and_nonpositive_values_rejected(self):
        for value in (float("nan"), float("inf"), -1, 0):
            with self.subTest(value=value), self.assertRaises(ValueError):
                fx.FxRateBook([{"currency": "USD", "rate_date": "2026-09-04", "units_per_eur": value}])

    def test_series_units_dates_and_values_bound_to_actual_ecb_response(self):
        valid = {"KEY": "EXR.D.USD.EUR.SP00.A", "FREQ": "D", "CURRENCY": "USD",
                 "CURRENCY_DENOM": "EUR", "UNIT": "USD", "UNIT_MULT": "0",
                 "TIME_PERIOD": "2026-09-04", "OBS_VALUE": "1.15"}
        def encoded(records):
            stream = io.StringIO()
            writer = csv.DictWriter(stream, fieldnames=list(valid))
            writer.writeheader()
            writer.writerows(records)
            return stream.getvalue()
        args = ("USD", "2026-09-01", "2026-09-05", "https://data-api.ecb.europa.eu/fixture")
        self.assertEqual(fx.parse_currency_csv(encoded([valid]), *args)[0]["units_per_eur"], 1.15)
        for change in ({"KEY": "EXR.D.GBP.EUR.SP00.A"}, {"CURRENCY": "ARS"}, {"UNIT_MULT": "3"},
                       {"CURRENCY_DENOM": "USD"}, {"TIME_PERIOD": "2026-09-06"}, {"OBS_VALUE": "NaN"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                fx.parse_currency_csv(encoded([{**valid, **change}]), *args)
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            fx.parse_currency_csv(encoded([valid, {**valid, "OBS_VALUE": "1.3"}]), *args)

    def test_adding_a_currency_preserves_previous_official_currency_history(self):
        def rows(currency, start, end):
            return [{"currency": currency, "rate_date": "2026-08-12", "units_per_eur": {"USD": 1.15, "GBP": .85, "MXN": 20}[currency],
                     "source_url": f"https://data-api.ecb.europa.eu/{currency}"}]
        with tempfile.TemporaryDirectory() as folder, patch.object(fx, "fetch_currency", side_effect=rows) as fetch:
            cache = Path(folder) / "ecb.json"
            fx.rate_book_for_range("2026-08-12", "2026-08-12", currencies=("USD", "GBP"), cache_path=cache)
            book = fx.rate_book_for_range("2026-08-12", "2026-08-12", currencies=("USD", "MXN"), cache_path=cache)
            self.assertEqual({r["currency"] for r in fx.read_cache(cache)}, {"USD", "GBP", "MXN"})
            self.assertEqual(fetch.call_count, 3)
            fx.rate_book_for_range("2026-08-12", "2026-08-12", currencies=("USD", "GBP"), cache_path=cache)
            self.assertEqual(fetch.call_count, 3)
            self.assertAlmostEqual(book.conversion("MXN", "USD", "2026-08-12")["conversionRate"], 1.15 / 20)

    def test_future_fx_cannot_supply_a_historical_missing_rate(self):
        book = fx.FxRateBook([{"currency": "USD", "rate_date": "2026-08-13", "units_per_eur": 1.15},
                              {"currency": "MXN", "rate_date": "2026-08-13", "units_per_eur": 20}])
        with self.assertRaisesRegex(RuntimeError, "Missing ECB PIT FX"):
            book.conversion("MXN", "USD", "2026-08-12")


if __name__ == "__main__":
    unittest.main()
