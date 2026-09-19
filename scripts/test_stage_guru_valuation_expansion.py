import datetime as dt
import copy
import hashlib
import importlib.util
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SPEC = importlib.util.spec_from_file_location("stage_guru_expansion", Path(__file__).with_name("stage-guru-valuation-expansion.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def identity(ticker="NEW", currency="MXN", **updates):
    return {"ticker": ticker, "inLatestSelectedBook": True,
            "status": "needs_economic_profile_and_official_guidance_review",
            "name": f"{ticker} issuer", "cusip": "000000001", "secFilings": "https://www.sec.gov/edgar/browse/?CIK=123",
            "reportingCurrency": currency, "sector": "Consumer Defensive", "industry": "Retail", **updates}


def financial_row(ticker="NEW"):
    return {"ticker": ticker, "fiscalperiod": "2026-Q1", "dimension": "ARQ",
            "datekey": dt.date(2026, 5, 20), "revenue": 80_000, "fcf": None,
            "currency": "MXN", "sharesbas": 100, "source_field_to_preserve": "raw"}


def normalized_period():
    return {"sourceRecord": {"reportingCurrency": "MXN"}, "sourceDimension": "ARQ",
            "fiscalYear": 2026, "fiscalQuarter": 1, "asOfDate": "2026-05-20",
            "periodEndDate": "2026-03-31", "financialStatementCurrency": "USD", "revenue": 4_000}


class StageGuruValuationExpansionTest(unittest.TestCase):
    def visible_fixture(self):
        occurrence = {"target": "NEW", "cusip": "000000001", "rendered": True, "clickable": True,
                      "conditional": False, "surface": "exposure.holdings", "reportDate": "2026-06-30"}
        visible = {"asOf": "2026-09-05", "dataCuts": {"exposureReportDates": ["2026-03-31", "2026-06-30"]},
                   "occurrences": [occurrence], "currentQuarterAndLatestSnapshotInventory": {
                       "missingTickers": ["NEW"], "missingValuationTargets": 1,
                       "releasedValuationTargets": 2, "uniqueClickableTargets": 3}}
        records = [{"table": table, "ticker": "NEW", "permaticker": 123, "cusips": "000000001",
                    "isdelisted": "N", "category": "Domestic Common Stock", "lastupdated": "2026-08-20",
                    "secfilings": "https://www.sec.gov/?CIK=123", "currency": "MXN" if table == "SF1" else "USD"}
                   for table in ("SF1", "SEP")]
        row = identity(inLatestSelectedBook=False, inCurrentVisibleTarget=True, cik="0000000123",
                       quoteCurrency="USD", reviewStatus="unreviewed", economicModelAuthorized=False,
                       sourceMetadataRecords=records, currentVisibleEvidence={"sourcePath": "/synthetic-visible.json",
                           "inventoryKey": "currentQuarterAndLatestSnapshotInventory", "ticker": "NEW", "cusip": "000000001"})
        inventory = {"scope": MODULE.CURRENT_VISIBLE_SCOPE, "status": "private_staging_candidates_only",
                     "economicApproval": False, "asOf": "2026-09-05", "securities": [row],
                     "sourceVisibilityBinding": {"path": "/synthetic-visible.json"}}
        return inventory, visible

    def bind_visible_fixture(self, inventory, visible):
        raw = json.dumps(visible).encode()
        digest = hashlib.sha256(raw).hexdigest()
        inventory["sourceVisibilityBinding"]["sha256"] = digest
        for row in inventory["securities"]:
            row["currentVisibleEvidence"]["sourceSha256"] = digest
            row["currentVisibleEvidence"]["metadataSha256"] = hashlib.sha256(
                json.dumps(row["sourceMetadataRecords"], sort_keys=True, default=str).encode()).hexdigest()
        return raw

    def test_current_visible_inputs_are_independently_source_bound_not_relabelled(self):
        inventory, visible = self.visible_fixture()
        raw = self.bind_visible_fixture(inventory, visible)
        with mock.patch.object(Path, "read_bytes", return_value=raw):
            result = MODULE.select_staging_targets(inventory)
        self.assertEqual(set(result), {"NEW"})
        self.assertFalse(result["NEW"]["inLatestSelectedBook"])
        self.assertFalse(result["NEW"]["economicModelAuthorized"])

    def test_visible_source_or_original_metadata_byte_changes_fail(self):
        inventory, visible = self.visible_fixture()
        raw = self.bind_visible_fixture(inventory, visible)
        with mock.patch.object(Path, "read_bytes", return_value=raw + b" "):
            with self.assertRaisesRegex(ValueError, "source SHA256"):
                MODULE.select_staging_targets(inventory)
        inventory["securities"][0]["sourceMetadataRecords"][0]["currency"] = "EUR"
        with mock.patch.object(Path, "read_bytes", return_value=raw):
            with self.assertRaisesRegex(ValueError, "metadata SHA256"):
                MODULE.select_staging_targets(inventory)

    def test_even_rehashed_wrong_identity_dates_and_funds_are_rejected(self):
        scenarios = {
            "old-exposure": lambda i, v: v["occurrences"][0].update(reportDate="2026-03-31"),
            "future-occurrence": lambda i, v: v["occurrences"][0].update(reportDate="2026-09-07"),
            "conditional": lambda i, v: v["occurrences"][0].update(conditional=True),
            "wrong-cusip": lambda i, v: v["occurrences"][0].update(cusip="000000002"),
            "future-meta": lambda i, v: i["securities"][0]["sourceMetadataRecords"][0].update(lastupdated="2026-09-07"),
            "other-permaticker": lambda i, v: i["securities"][0]["sourceMetadataRecords"][1].update(permaticker=456),
            "fund": lambda i, v: i["securities"][0]["sourceMetadataRecords"][0].update(category="ETF"),
            "delisted": lambda i, v: i["securities"][0]["sourceMetadataRecords"][0].update(isdelisted="Y"),
            "other-cik": lambda i, v: i["securities"][0]["sourceMetadataRecords"][1].update(secfilings="https://www.sec.gov/?CIK=456"),
            "other-currency": lambda i, v: i["securities"][0]["sourceMetadataRecords"][0].update(currency="EUR"),
            "approval": lambda i, v: i["securities"][0].update(economicModelAuthorized=True),
            "relabelled-book": lambda i, v: i["securities"][0].update(inLatestSelectedBook=True),
            "denominator": lambda i, v: v["currentQuarterAndLatestSnapshotInventory"].update(missingValuationTargets=2),
        }
        for name, mutate in scenarios.items():
            with self.subTest(name=name):
                inventory, visible = self.visible_fixture()
                mutate(inventory, visible)
                raw = self.bind_visible_fixture(inventory, visible)
                with mock.patch.object(Path, "read_bytes", return_value=raw):
                    with self.assertRaises(ValueError):
                        MODULE.select_staging_targets(inventory)

    def test_selects_only_exact_missing_current_holdings_and_bounded_subset(self):
        inventory = {"securities": [identity("NEW"), identity("OTHER"),
            identity("RELEASED", status="covered"), identity("OLD", inLatestSelectedBook=False)]}
        self.assertEqual(set(MODULE.select_staging_targets(inventory)), {"NEW", "OTHER"})
        self.assertEqual(set(MODULE.select_staging_targets(inventory, " new,NEW ")), {"NEW"})
        for ticker in ("RELEASED", "OLD", "UNKNOWN"):
            with self.subTest(ticker=ticker), self.assertRaisesRegex(ValueError, "exact-identity missing"):
                MODULE.select_staging_targets(inventory, ticker)

    def test_duplicate_share_class_or_empty_scope_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "Duplicate ticker/share-class"):
            MODULE.select_staging_targets({"securities": [identity(), identity(cusip="000000002")]})
        with self.assertRaisesRegex(ValueError, "No eligible"):
            MODULE.select_staging_targets({"securities": []})

    def test_identity_remains_unreviewed_without_invented_security_factor_or_fair_value(self):
        company = MODULE.pending_company_identity("NEW", identity())
        self.assertEqual(company["reviewStatus"], "unreviewed")
        self.assertEqual(company["reportingCurrency"], "MXN")
        self.assertEqual(company["currency"], "USD")
        self.assertEqual(company["cik"], "0000000123")
        self.assertNotIn("fairValue", company)
        self.assertNotIn("adrRatio", company)
        self.assertIn("Pending historical issuer currency", company["reason"])
        with self.assertRaisesRegex(ValueError, "Missing issuer CIK"):
            MODULE.pending_company_identity("NEW", identity(secFilings=None))

    def test_original_money_null_and_dates_are_written_before_normalization(self):
        source, builder = mock.MagicMock(), mock.MagicMock()
        row = financial_row()
        company = MODULE.pending_company_identity("NEW", identity())

        def convert(*_args, **_kwargs):
            self.assertEqual(source.execute.call_count, 1)
            sql, values = source.execute.call_args.args
            self.assertIn("pit_raw_financial_review", sql)
            raw = json.loads(values[-1])
            self.assertEqual(raw["revenue"], 80_000)
            self.assertEqual(raw["currency"], "MXN")
            self.assertIsNone(raw["fcf"])
            self.assertEqual(raw["datekey"], "2026-05-20")
            self.assertEqual(raw["source_field_to_preserve"], "raw")
            return normalized_period()

        builder.build_period.side_effect = convert
        period = MODULE.stage_financial_period(source, builder, "NEW", row, company, "prior-date-fx", {})
        self.assertEqual(row["revenue"], 80_000)
        self.assertEqual(period["revenue"], 4_000)
        self.assertEqual(period["sourceRecord"]["candidateReviewStatus"], "pending_economic_review")
        self.assertIn("historical currency validation pending", period["sourceRecord"]["currencyIdentityBasis"])
        self.assertIn("pit_financial_periods", source.execute.call_args.args[0])
        stored = json.loads(source.execute.call_args.args[1][-1])
        self.assertEqual(stored["sourceRecord"]["candidateReviewStatus"], "pending_economic_review")
        builder.build_period.assert_called_once_with("NEW", "NEW", row, fx_rate_book="prior-date-fx", identity=company)

    def test_unsupported_fx_preserves_raw_without_normalized_rows_or_fallback(self):
        source, builder = mock.MagicMock(), mock.MagicMock()
        company = MODULE.pending_company_identity("NEW", identity())
        result = MODULE.stage_financial_period(source, builder, "NEW", financial_row(), company, None, {"MXN": "missing prior official rate"})
        self.assertIsNone(result)
        self.assertEqual(source.execute.call_count, 1)
        self.assertIn("pit_raw_financial_review", source.execute.call_args.args[0])
        builder.build_period.assert_not_called()

    def test_every_candidate_gate_is_pending_with_zero_uncertified_guidance(self):
        source = mock.MagicMock()
        company = MODULE.pending_company_identity("NEW", identity())
        MODULE.insert_candidate_review_gates(source, "NEW", company)
        review, guidance = source.execute.call_args_list
        self.assertIn("pit_issuer_review", review.args[0])
        self.assertEqual(review.args[1], ("NEW", "pending_economic_review", company["reason"]))
        self.assertIn("0,0,0,0,'official_guidance_review_incomplete'", guidance.args[0])
        self.assertEqual(guidance.args[1][0], "NEW")

    def test_existing_candidate_refused_before_dataset_database_or_network(self):
        inventory = {"asOf": "2026-09-05", "securities": [identity()]}
        argv = ["stage", "--inventory", "/unused-inventory.json", "--jansen-root", "/unused-data", "--output-dir", "/unused-private-stage"]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(MODULE, "module") as modules, \
                mock.patch.object(Path, "read_text", return_value=json.dumps(inventory)), \
                mock.patch.object(Path, "mkdir"), mock.patch.object(Path, "exists", return_value=True), \
                mock.patch.object(MODULE.ds, "dataset") as dataset, \
                mock.patch.object(MODULE.sqlite3, "connect") as connect:
            with self.assertRaisesRegex(FileExistsError, "Refusing to replace"):
                MODULE.main()
        dataset.assert_not_called()
        connect.assert_not_called()
        modules.return_value.create_database.assert_not_called()
        modules.return_value.rate_book_for_range.assert_not_called()

    def test_full_stage_mock_preserves_fx_blocked_raw_and_all_review_gates(self):
        # Exercise the real main flow with no disk/database/network writes.
        inventory = {"asOf": "2026-09-05", "securities": [identity("SAFE", "USD"), identity("BLOCKED", "PEN")]}
        builder, extractor = mock.MagicMock(), mock.MagicMock()
        builder.PIT_CUTOFF_FIELD_CANDIDATES = ["datekey"]
        builder.SOURCE_COLUMNS = ["ticker", "dimension"]
        builder.first_visible_rows.side_effect = lambda rows: rows
        builder.FxRateBook.side_effect = lambda rows: SimpleNamespace(rows=rows)
        builder.build_period.side_effect = lambda *_args, **_kwargs: normalized_period()
        builder.source_fingerprint.return_value = "fixture-only"
        source, target = mock.MagicMock(), mock.MagicMock()
        source.execute.return_value.fetchone.return_value = target.execute.return_value.fetchone.return_value = ("ok",)
        builder.create_database.return_value = source
        fundamentals, prices = mock.MagicMock(), mock.MagicMock()
        fundamentals.schema.names = ["datekey"]
        fundamentals.to_table.return_value.to_pylist.return_value = [financial_row("SAFE"), financial_row("BLOCKED")]
        prices.to_table.return_value.to_pylist.return_value = [
            {"ticker": ticker, "date": dt.date(2026, 9, 4), "close": 10} for ticker in ("SAFE", "BLOCKED")]
        argv = ["stage", "--inventory", "/unused-inventory.json", "--jansen-root", "/unused-data", "--output-dir", "/unused-private-stage"]
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(MODULE, "module", side_effect=[builder, extractor]), \
                mock.patch.object(Path, "read_text", return_value=json.dumps(inventory)), \
                mock.patch.object(Path, "mkdir"), mock.patch.object(Path, "exists", return_value=False), \
                mock.patch.object(Path, "write_text") as writes, \
                mock.patch.object(MODULE.ds, "dataset", side_effect=[fundamentals, prices]), \
                mock.patch.object(MODULE.sqlite3, "connect", return_value=target) as connect, \
                mock.patch("builtins.print"):
            MODULE.main()
        builder.create_database.assert_called_once_with(Path("/unused-private-stage/candidate-source.sqlite"))
        connect.assert_called_once_with(Path("/unused-private-stage/candidate-metadata.sqlite"))
        calls = source.execute.call_args_list
        self.assertEqual(len([c for c in calls if "INSERT INTO pit_raw_financial_review" in c.args[0]]), 2)
        self.assertEqual(len([c for c in calls if "INSERT INTO pit_financial_periods" in c.args[0]]), 1)
        reviews = [c.args[1] for c in calls if "INSERT INTO pit_issuer_review" in c.args[0]]
        self.assertEqual({r[0] for r in reviews}, {"SAFE", "BLOCKED"})
        self.assertTrue(all(r[1] == "pending_economic_review" for r in reviews))
        snapshot_calls = [c for c in target.execute.call_args_list if "INSERT INTO valuation_ticker_snapshots" in c.args[0]]
        for call in snapshot_calls:
            snapshot = json.loads(call.args[1][-1])
            self.assertEqual(snapshot["history"], [])
            self.assertEqual(set(snapshot["latest"]), {"latestPrice", "latestPriceDate"})
            self.assertEqual(snapshot["reviewStatus"], "unreviewed")
        manifest, summary = [json.loads(call.args[0]) for call in writes.call_args_list]
        self.assertTrue(all(c["reviewStatus"] == "unreviewed" for c in manifest["companies"]))
        self.assertEqual(summary["status"], "staged_not_released")
        self.assertEqual(summary["rawPitRows"], 2)
        self.assertEqual(summary["normalizedFinancialRows"], 1)
        self.assertIn("PEN", summary["fxBlockers"])
        builder.rate_book_for_range.assert_not_called()


if __name__ == "__main__":
    unittest.main()
