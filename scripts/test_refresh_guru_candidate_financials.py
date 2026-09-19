import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location("refresh_financials", Path(__file__).with_name("refresh-guru-candidate-financials.py"))
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


def row(**changes):
    return {"ticker": "TEST", "dimension": "ARQ", "fiscalperiod": "2027-Q1",
            "date": "2026-09-02", "reportperiod": "2026-08-01", "calendardate": "2026-09-30",
            "revenue": "2000000", "ncfo": "1000000", "capex": "-200000",
            "sharesbas": "1000000", "sharefactor": "1", **changes}


class CandidateFinancialsTests(unittest.TestCase):
    def test_large_scope_is_batched_with_exact_response_validation(self):
        tickers = [f"TICKER{i:03d}" for i in range(90)]
        get = Mock(side_effect=lambda client, table, params: [row(ticker=t) for t in params["ticker"].split(",")])
        api = SimpleNamespace(normalized_rows=get)
        result = M.fetch_scoped_rows("client", api, tickers, "2026-09-01", "2026-09-05")
        self.assertEqual([r["ticker"] for r in result], tickers)
        self.assertGreater(get.call_count, 1)
        self.assertTrue(all(len(c.args[2]["ticker"]) <= 180 for c in get.call_args_list))
        get.side_effect = lambda client, table, params: [row(ticker=tickers[-1])]
        with self.assertRaisesRegex(ValueError, "Unexpected security"):
            M.fetch_scoped_rows("client", api, tickers, "2026-09-01", "2026-09-05")

    def select(self, rows, tickers=("TEST",)):
        return M.select_rows(rows, list(tickers), "2026-09-01", "2026-09-05")

    def test_earliest_observation_is_selected_not_later_restatement(self):
        self.assertEqual(self.select([row(date="2026-09-03", revenue="9000000"), row()]), [row()])

    def test_identical_repeats_are_idempotent_conflicts_fail(self):
        self.assertEqual(self.select([row(), row()]), [row()])
        with self.assertRaises(ValueError):
            self.select([row(), row(revenue="123")])

    def test_rejects_future_rows_wrong_tickers_dimensions_and_bad_periods(self):
        for changes in [{"date": "2026-09-06"}, {"date": "2026-08-31"}, {"reportperiod": "2026-10-01"},
                        {"ticker": "OTHER"}, {"dimension": "MRQ"}, {"fiscalperiod": "Q12027"}, {"date": "bad"}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.select([row(**changes)])

    def test_scope_is_explicit_unique_and_exact(self):
        for tickers in [(), ("TEST", "TEST"), ("test",), ("TEST!",)]:
            with self.subTest(tickers=tickers), self.assertRaises(ValueError):
                self.select([], tickers)

    def test_copy_only_preserves_original_non_targets_guidance_and_prices(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.sqlite"
            target = Path(tmp) / "candidate.sqlite"
            builder = M.module("test_builder", "build-pit-valuation-source.py")
            extractor = M.module("test_extractor", "extract-pit-management-guidance.py")
            db = builder.create_database(source)
            extractor.ensure_schema(db)
            db.executescript("""
              CREATE TABLE pit_issuer_review(ticker TEXT PRIMARY KEY,status TEXT,reason TEXT);
              CREATE TABLE pit_raw_financial_review(ticker TEXT,fiscal_period TEXT,dimension TEXT,available_at TEXT,payload_json TEXT,PRIMARY KEY(ticker,fiscal_period,dimension));
              CREATE TABLE price_points(ticker TEXT,value REAL);
              INSERT INTO price_points VALUES('TEST',123);
              INSERT INTO pit_issuer_review VALUES('TEST','reviewed','old approval');
              INSERT INTO pit_issuer_review VALUES('OTHER','reviewed','preserve this');
              INSERT INTO pit_guidance_coverage VALUES('TEST',0,0,0,0,'covered','old');
              INSERT INTO pit_guidance_coverage VALUES('OTHER',0,0,0,0,'covered','preserve');
              INSERT INTO pit_financial_coverage VALUES('TEST','TEST','covered',0,0,NULL,NULL,'old');
            """)
            db.commit()
            before = list(db.iterdump())
            db.close()
            companies = [{"ticker": "TEST", "sourceTicker": "TEST", "currency": "USD", "reportingCurrency": "USD", "cik": "0000000001"}]
            result = M.refresh_candidate(source, target, companies, [row(), row(dimension="ART")], ["TEST"], "2026-09-01", "2026-09-05")
            self.assertEqual(result["newFinancialRows"], 2)
            self.assertEqual(result["modelRowsAdded"], 0)
            with sqlite3.connect(source) as unchanged:
                self.assertEqual(list(unchanged.iterdump()), before)
            with sqlite3.connect(target) as candidate:
                self.assertEqual(candidate.execute("SELECT * FROM price_points").fetchall(), [("TEST", 123)])
                self.assertEqual(candidate.execute("SELECT status,reason FROM pit_issuer_review WHERE ticker='OTHER'").fetchone(), ("reviewed", "preserve this"))
                self.assertEqual(candidate.execute("SELECT status FROM pit_issuer_review WHERE ticker='TEST'").fetchone()[0], "pending_economic_review")
                self.assertEqual(candidate.execute("SELECT status FROM pit_guidance_coverage WHERE ticker='TEST'").fetchone()[0], "official_guidance_review_incomplete")
                payloads = [json.loads(r[0]) for r in candidate.execute("SELECT payload_json FROM pit_financial_periods")]
                self.assertEqual({p["fcf_after_capex_m"] for p in payloads}, {0.8})
                self.assertTrue(next(p for p in payloads if p["sourceDimension"] == "ART")["sourceRecord"]["metricsAreTrailingTwelveMonths"])
                self.assertEqual({p["currencyReviewStatus"] for p in payloads}, {"pending_currency"})
            with self.assertRaises(FileExistsError):
                M.refresh_candidate(source, target, companies, [], ["TEST"], "2026-09-01", "2026-09-05")


if __name__ == "__main__":
    unittest.main()
