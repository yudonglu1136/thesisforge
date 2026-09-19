import importlib.util
import json
import sys
import unittest
import sqlite3
import tempfile


class FirstBatchReplayRegressionTests(unittest.TestCase):
    def test_compensation_hurdles_are_not_operating_guidance(self):
        award = (
            "Achievement of each Stock Price Goal hurdle will be based on the average closing price "
            "during the Performance Period. In no event will any tranche of the Special PSUs be achieved more than once. "
            "The tranche 1 revenue hurdle of $2,500,000,000 represents an approximate 87% increase from fiscal 2026 revenue."
        )
        self.assertEqual(MODULE.guidance_lines([award], "CRDO"), [])
        mixed = "For fiscal 2027, management revenue guidance is $3.0 billion. " + award
        self.assertTrue(MODULE.guidance_lines([mixed], "CRDO"), "Mixed actual guidance must remain reviewable")

    def test_crdo_fiscal_quarter_outlook_heading_is_preserved(self):
        # Original issuer wording: the raw $530m midpoint is quarterly, not FY.
        lines = [
            "Second Quarter of Fiscal 2027 Financial Outlook",
            "Revenue is expected to be between $525 million and $535 million",
        ]
        pairs = MODULE.guidance_lines(lines, "CRDO")
        self.assertEqual(len(pairs), 1)
        event = MODULE.extract_metric_event(MODULE.guidance_module(), "CRDO", "2027-Q1", "2026-09-01",
                                            "https://www.sec.gov/Archives/edgar/data/1807794/000162828026059795/credoq12027ex-991.htm",
                                            "fixture", *pairs[0])
        self.assertEqual(event["amount"], 530)
        self.assertEqual(event["guidance_scope"], "quarter")
        self.assertEqual(event["fiscal_period"], "2027-Q1")
        self.assertTrue(event["evidence_excerpt"].startswith(lines[0]))
        # Bare $ is still unresolved until separate, dated currency evidence.
        self.assertIsNone(event["currency"])

    def test_quarter_heading_does_not_leak_into_following_annual_or_disclaimer(self):
        pairs = MODULE.guidance_lines([
            "Second Quarter of Fiscal 2027 Financial Outlook",
            "Revenue is expected to be between $525 million and $535 million",
            "Fiscal Year 2027 Outlook",
            "Revenue is expected to be between $2.0 billion and $2.2 billion",
            "Forward-looking statements",
            "Revenue is expected to be $3.0 billion",
        ], "CRDO")
        excerpts = [p[1] for p in pairs]
        self.assertIn("Fiscal Year 2027 Outlook. Revenue is expected to be between $2.0 billion and $2.2 billion", excerpts)
        self.assertTrue(all(not e.startswith("Second Quarter") for e in excerpts if "$3.0" in e))

    def test_crox_real_ended_year_paragraph_is_retained_only_as_actual(self):
        evidence = (
            "“We ended 2025 on a strong note with a better-than-expected Holiday quarter. "
            "For the year, revenue exceeded $4 billion, led by low-double digit international growth "
            "for the Crocs Brand. At the same time, we accelerated our strategic actions to strengthen "
            "the long-term health of both the Crocs and HEYDUDE brands. Our powerful value creation "
            "model drove operating cash flow of approximately $700 million which enabled us to return "
            "shareholder value as we repurchased approximately 10% of our shares outstanding, and paid "
            "down $128 million of debt,” said Andrew Rees, Chief Executive Officer."
        )
        pairs = MODULE.guidance_lines([evidence], "CROX")
        self.assertTrue(any(metric == "revenue_guidance" for metric, _ in pairs))
        event = MODULE.extract_metric_event(MODULE.guidance_module(), "CROX", "2025-Q4", "2026-02-12", "https://www.sec.gov/Archives/edgar/data/1334036/000133403626000004/croxq42025-pressrelease.htm", "SEC:0001334036-26-000004:croxq42025-pressrelease.htm", "revenue_guidance", evidence)
        self.assertEqual(event["amount"], 4000)
        self.assertEqual(event["actual_or_guidance"], "actual")
        self.assertEqual(event["quality_status"], "historical_actual")
        self.assertFalse(MODULE.usable_guidance_event(event))
        self.assertIsNone(MODULE.guidance_event_review_reason(event))

    def test_sfix_official_table_and_plural_expects_are_not_no_quantified(self):
        lines = ["Financial Outlook", "Stitch Fix's financial outlook for the fourth quarter of fiscal 2026 is as follows:", "Q4 2026", "Net Revenue", "$322 million - $327 million", "The Company's updated financial outlook for fiscal year 2026 is as follows:", "Fiscal Year 2026", "Net Revenue", "$1.346 billion - $1.351 billion", "The Company expects full fiscal year 2026 gross margin to be between 43% and 44%."]
        events = [MODULE.extract_metric_event(MODULE.guidance_module(), "SFIX", "2026-Q3", "2026-06-10", "https://example.test/release", "fixture", metric, text) for metric, text in MODULE.guidance_lines(lines, "SFIX")]
        self.assertTrue(any(event.get("amount") == 324.5 and event["guidance_scope"] == "quarter" for event in events))
        self.assertTrue(any(event.get("amount") == 1348.5 and event["guidance_scope"] == "full_year" for event in events))
        self.assertTrue(any(event.get("margin_pct") == 43.5 and MODULE.usable_guidance_event(event) for event in events))

    def test_real_first_batch_additional_owned_targets(self):
        cases = [
            ("POWL", "gross_margin", "Meanwhile, the team continues to demonstrate high levels of project execution, delivering a gross margin of 29.6% in the quarter.", {"actual_or_guidance": "actual", "quality_status": "historical_actual"}),
            ("CROX", "revenue_guidance", "For the first quarter of 2026, we expect:. Revenues to be down approximately 5.5% to 3.5% to the first quarter of 2025.", {"growth_yoy": -4.5, "guidance_scope": "quarter"}),
            ("CROX", "eps_guidance", "For 2026, we expect:. Adjusted diluted earnings per share to be in the range of $13.70 to $14.00, up from our previous guidance range of $13.20 to $13.75. Adjusted diluted earnings per share guidance does not assume any impact from potential future share repurchases.", {"per_share_value": 13.85, "guidance_subject": "company_total_or_unspecified"}),
            ("SOFI", "revenue_guidance", "Over the medium term, management expects to deliver compounded annual growth in adjusted net revenue of at least 30% from 2025 to 2028.", {"guidance_scope": "multi_year_target", "guidance_subject": "non_company_or_non_periodic"}),
            ("SOFI", "eps_guidance", "For the full year 2026, management expects adjusted EPS of approximately 60 cents per share.", {"per_share_value": 0.6, "amount": None}),
            ("CBRS", "operating_margin", "Third Quarter 2026 Financial Outlook. Core operating margins in the range of (25%) to (23%)", {"margin_pct": -24, "guidance_scope": "quarter"}),
            ("CBRS", "operating_margin", "Q2 2026 Financial Outlook. Core operating margins in the range of (30) to (32)%", {"margin_pct": -31, "guidance_scope": "quarter"}),
            ("QNT", "revenue_guidance", "Establishing first formal guidance as a public company, with 2026 revenue expected to be in the range of $28 to $32 million.", {"amount": 30, "guidance_scope": "full_year", "guidance_target_year": 2026}),
            ("QNT", "revenue_guidance", "Second-Quarter Revenue Grew 279% Year-Over-Year; Increased FY2026 Outlook", {"actual_or_guidance": "actual", "quality_status": "historical_actual"}),
        ]
        for ticker, metric, evidence, expected in cases:
            with self.subTest(ticker=ticker, evidence=evidence):
                event = MODULE.extract_metric_event(MODULE.guidance_module(), ticker, "2026-Q2", "2026-07-30", "https://example.test/release", "fixture", metric, evidence)
                for key, value in expected.items():
                    self.assertEqual(event.get(key), value)

    def test_actual_outlook_heading_is_retained_without_promoting_results_bullets(self):
        pairs = MODULE.guidance_lines(["Cerebras Reports Second Quarter 2026 Results and Provides Outlook", "GAAP operating margin of (265%); Core operating margin of (16%), an improvement of 2600 basis points from Q2'25.", "Third Quarter 2026 Financial Outlook", "Core Non-GAAP Financial Outlook:", "Core revenue of approximately $214 to $216 million", "Core operating margins in the range of (25%) to (23%)"], "CBRS")
        self.assertFalse(any("265%" in text for _, text in pairs))
        self.assertTrue(all(text.startswith("Third Quarter 2026 Financial Outlook.") for _, text in pairs))

    def test_currency_resolution_uses_only_latest_visible_source_facts(self):
        event = self._bare_eps()
        def fact(date, currency, status=None):
            return {"ticker": "TEST", "available_at": date, "payload_json": json.dumps({"sourceFinancialStatementCurrency": currency, "sourceRecord": {"sourceCurrency": currency, "dataset": "Original issuer source", "candidateReviewStatus": status}})}
        before = fact("2026-01-01", "CAD")
        future = fact("2026-08-01", "USD")
        result = MODULE.resolve_guidance_reporting_currencies([event], [before, future])[0]
        self.assertIsNone(result["currency"])
        self.assertEqual(MODULE.resolved_guidance_currency(result), "CAD")
        self.assertEqual(result["currency_resolution"]["evidence"][0]["availableAt"], "2026-01-01")
        for blocked in [[future], [before, fact("2026-07-01", "USD", "pending_currency")], [before, fact("2026-01-01", "USD")]]:
            self.assertIsNone(MODULE.resolved_guidance_currency(MODULE.resolve_guidance_reporting_currencies([event], blocked)[0]))

    def _bare_eps(self):
        return MODULE.extract_metric_event(MODULE.guidance_module(), "TEST", "2026-Q2", "2026-07-30", "https://example.test/release", "fixture", "eps_guidance", "Full-year 2026 guidance: adjusted EPS of $1.20.")

    def test_actual_first_batch_consumption_findings(self):
        fixture = json.loads((Path(__file__).parents[1] / "server/fixtures/guidance-first-batch-consumption-2026.json").read_text())
        guidance = MODULE.guidance_module()
        for item in fixture["events"]:
            row = item["original"]
            with self.subTest(ticker=row["ticker"], source_id=row["id"]):
                events = MODULE.extract_metric_events(guidance, row["ticker"], row["fiscal_period"], row["observed_at"], row["source_url"], "fixture", row["metric_name"], item["correctedEvidence"])
                self.assertTrue(any(all(event.get(key) == value for key, value in item["expected"].items()) for event in events), events)

    def test_inline_and_source_newlines_do_not_truncate_financial_amounts(self):
        html = "<p>Total full-year 2025 revenue is expected to be $913\nmillion<sup>1</sup>, an increase of 51%.</p>"
        self.assertEqual(MODULE.clean_lines(html), ["Total full-year 2025 revenue is expected to be $913 million 1 , an increase of 51%."])

    def test_original_outlook_heading_is_carried_not_comparison_year(self):
        rows = MODULE.guidance_lines(["Financial Outlook", "Full Year 2026", "For 2026, we expect:", "Revenues to be down approximately 1% to up 1% compared to full year 2025, up from our previous guidance of down 1% to up slightly."], "CROX")
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0][1].startswith("For 2026, we expect:"))

    def test_preliminary_results_carry_original_heading(self):
        rows = MODULE.guidance_lines(["Accelerant Announces Unaudited Preliminary Fourth Quarter and Full Year 2025 Financial Results", "Total full-year 2025 revenue is expected to be $913 million."], "ARX")
        self.assertTrue(rows)
        event = MODULE.extract_metric_event(MODULE.guidance_module(), "ARX", "2025-Q4", "2026-02-27", "https://example.test/release", "fixture", *rows[0])
        self.assertEqual(event["actual_or_guidance"], "actual")

    def test_two_eps_targets_keep_units_and_distinct_ids(self):
        text = "Full Year 2026 Guidance. GAAP diluted earnings per share in a range of $5.29 to $6.09 and adjusted diluted earnings per share in a range of $10.20 to $11.00."
        events = MODULE.extract_metric_events(MODULE.guidance_module(), "RRX", "2025-Q4", "2026-02-05", "https://example.test/release", "fixture", "eps_guidance", text)
        self.assertEqual(len(events), 2)
        self.assertEqual(len({event["id"] for event in events}), 2)
        self.assertEqual({event["per_share_basis"] for event in events}, {"gaap", "adjusted"})
        for event in events:
            self.assertIsNone(event["amount"])
            self.assertEqual(event["unit"], "currency_per_share")
            self.assertEqual(MODULE.guidance_event_review_reason(event), "guidance_currency_unresolved")
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "alignment.sqlite"
            with sqlite3.connect(database) as connection:
                connection.execute("CREATE TABLE pit_financial_periods (ticker TEXT, fiscal_period TEXT, available_at TEXT, payload_json TEXT)")
                connection.execute("INSERT INTO pit_financial_periods VALUES (?,?,?,?)", ("RRX", "2025-Q4", "2026-02-05", "{}"))
            aligned = MODULE.align_events_to_financial_periods(database, events, "2026-09-05")
            self.assertEqual(len({event["id"] for event in aligned}), 2, "period alignment must not collapse adjusted and GAAP targets")
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("import-sec-official-guidance.py")
SPEC = importlib.util.spec_from_file_location("import_sec_official_guidance", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class OfficialSecGuidanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guidance = MODULE.guidance_module()

    def event(self, excerpt, metric="ebitda_guidance"):
        return MODULE.extract_metric_event(
            self.guidance,
            "PSX",
            "2024-Q1",
            "2024-04-26",
            "https://example.test/filing",
            "SEC:test:release.htm",
            metric,
            excerpt,
        )

    def test_amount_before_metric_is_retained_for_company_target(self):
        event = self.event(
            "Our strategic priorities put us on a clear path to achieve our "
            "$14 billion mid-cycle adjusted EBITDA target by 2025."
        )

        self.assertEqual(event["amount"], 14_000)

    def test_synergy_components_do_not_become_company_ebitda_guidance(self):
        event = self.event(
            "The company has provided an incremental $1.25 billion toward its 2025 "
            "mid-cycle adjusted EBITDA target, including approximately $250 million "
            "of synergies, and remains focused on capturing over $400 million of "
            "run-rate commercial and operating synergies by year end."
        )

        self.assertIsNone(event["amount"])

    def test_official_source_cannot_upgrade_rejected_parser_quality(self):
        with mock.patch.object(self.guidance, "extract_event", return_value={
            "amount": None, "currency": None, "quality_status": "ambiguous",
            "extraction_confidence": 0.25, "currency_rejection_reason": "unknown_currency",
        }):
            event = self.event("For the full year, we expect adjusted EBITDA of 100 million.")
        self.assertEqual(event["quality_status"], "ambiguous")
        self.assertEqual(event["extraction_confidence"], 0.25)
        self.assertEqual(event["currency_rejection_reason"], "unknown_currency")

    def test_tbbb_fy2026_table_and_paragraph_bind_total_revenue_not_same_store_sales(self):
        fixture = json.loads(Path("server/fixtures/tbbb-fy2026-guidance.json").read_text())
        # Exact clean_lines structure from the cited official release, p.12.
        lines = [
            "2026 guidance", "Range", "Same Store Sales Growth (%)", "13% - 16%",
            "Revenue Growth (%)", "29% - 32%", "Number of New Stores", "590 - 630",
            "For 2026, the Company plans to open between 590 and 630 stores during the year. We expect Same Store Sales growth between 13% and 16%, and total revenue is forecast to grow by 29% to 32%.",
        ]
        pairs = MODULE.guidance_lines(lines, "TBBB")
        events = [MODULE.extract_metric_event(
            self.guidance, fixture["ticker"], fixture["fiscal_period"], fixture["observed_at"],
            fixture["source_url"], "SEC:TBBB:FY2025", metric, excerpt,
        ) for metric, excerpt in pairs]
        revenue = [event for event in events if event["metric_name"] == "revenue_guidance"]
        self.assertEqual(len(revenue), 2)
        for event in revenue:
            self.assertEqual(event["growth_yoy"], 30.5)
            self.assertEqual(event["fiscal_period"], "Q42025")
            self.assertEqual(event["guidance_scope"], "full_year")
            self.assertEqual(event["guidance_target_year"], 2026)
            self.assertIsNone(event["amount"])
            self.assertIsNone(event["currency"])
            self.assertTrue(MODULE.usable_guidance_event(event))

    def test_unknown_table_scope_cannot_be_promoted_to_annual(self):
        pairs = MODULE.guidance_lines(["Guidance", "Revenue Growth (%)", "29% - 32%"], "REVIEW")
        events = [self.event(excerpt, metric) for metric, excerpt in pairs]
        self.assertTrue(events)
        self.assertTrue(all(event["guidance_scope"] is None for event in events))
        self.assertTrue(all(not MODULE.usable_guidance_event(event) for event in events))

    def test_quarter_heading_stops_prior_annual_guidance_context(self):
        pairs = MODULE.guidance_lines([
            "2026 guidance", "Revenue Growth (%)", "29% - 32%",
            "Q1 FY2027 guidance", "Revenue Growth (%)", "10% - 12%",
        ], "REVIEW")
        events = [self.event(excerpt, metric) for metric, excerpt in pairs]
        quarterly_table = [event for event in events if event["growth_yoy"] == 11]
        self.assertTrue(quarterly_table)
        self.assertTrue(all(event["guidance_scope"] != "full_year" for event in quarterly_table))

    def test_ambiguous_or_non_company_evidence_does_not_establish_usable_coverage(self):
        event = MODULE.extract_metric_event(
            self.guidance, "REVIEW", "Q42025", "2026-03-11", "https://example.test/release",
            "SEC:fixture", "revenue_guidance", "2026 guidance. Total revenue is forecast to grow by 29% to 32%.",
        )
        self.assertTrue(MODULE.usable_guidance_event(event))
        for update in (
            {"quality_status": "ambiguous"},
            {"guidance_subject": "segment_or_subset"},
            {"guidance_scope": "multi_year_target"},
            {"growth_yoy": None},
            {"actual_or_guidance": "actual"},
        ):
            research = {**event, **update}
            counts = MODULE.guidance_coverage_counts([research])
            self.assertEqual(counts["events"], 1)
            self.assertEqual(counts["researchEvents"], 1)
            self.assertEqual(counts["usableOfficialEvents"], 0)
        counts = MODULE.guidance_coverage_counts([event, {**event, "quality_status": "ambiguous"}])
        self.assertEqual(counts["events"], 2)
        self.assertEqual(counts["usableEvents"], 1)
        self.assertEqual(counts["usableOfficialEvents"], 1)
        self.assertEqual(counts["reviewRequiredEvents"], 1)

    def test_unresolved_monetary_currency_is_incomplete_not_no_quantified_guidance(self):
        event = self.event("For full year 2026, we expect revenue of $100 million.", "revenue_guidance")
        self.assertEqual(event["amount"], 100)
        self.assertIsNone(event["currency"])
        self.assertFalse(MODULE.usable_guidance_event(event))
        counts = MODULE.guidance_coverage_counts([event])
        self.assertEqual(counts["reviewRequiredEvents"], 1)
        self.assertEqual(counts["reviewRequiredReasons"], {"guidance_currency_unresolved": 1})
        # A percentage on the same unresolved monetary row cannot green-light it.
        self.assertFalse(MODULE.usable_guidance_event({**event, "growth_yoy": 12}))

    def test_seven_real_source_review_findings_are_corrected_without_changing_evidence(self):
        fixture = json.loads(Path("server/fixtures/guidance-review-seven-2026.json").read_text())
        for case in fixture["events"]:
            original, expected = case["original"], case["expected"]
            with self.subTest(ticker=original["ticker"], source_id=original["id"]):
                event = MODULE.extract_metric_event(
                    self.guidance, original["ticker"], original["fiscal_period"], original["observed_at"],
                    original["source_url"], original["source_file"], original["metric_name"], original["evidence_excerpt"],
                )
                self.assertEqual(event["id"], original["id"])
                self.assertEqual(event["evidence_excerpt"], original["evidence_excerpt"])
                self.assertEqual(event["source_url"], original["source_url"])
                for key, value in expected.items():
                    if key not in {"modelEligible", "currencyReviewRequired"}:
                        self.assertEqual(event[key], value, key)
                self.assertEqual(MODULE.usable_guidance_event(event), expected["modelEligible"])
                if expected.get("currencyReviewRequired"):
                    self.assertEqual(MODULE.guidance_event_review_reason(event), "guidance_currency_unresolved")

    def test_tbbb_long_mda_budget_retains_total_components_and_noncash_basis_as_research(self):
        fixture = json.loads(Path("server/fixtures/tbbb-q1-2026-capital-budget.json").read_text())
        self.assertGreater(len(fixture["lines"][-1]), 500)
        candidates = MODULE.guidance_lines(fixture["lines"], fixture["ticker"])
        self.assertEqual(len(candidates), 1)
        metric, excerpt = candidates[0]
        event = MODULE.extract_metric_event(self.guidance, fixture["ticker"], "Q12026", "2026-05-27",
            fixture["source_url"], "SEC:0001193125-26-241914:tbbb-ex99_2.htm", metric, excerpt)
        for key, value in fixture["expected"].items():
            self.assertEqual(event[key], value, key)
        self.assertNotEqual(event["amount"], 3555)
        self.assertNotEqual(event["amount"], 490)
        self.assertNotEqual(event["amount"], 3555 + 490)
        self.assertIn("including as right-of-use assets", event["evidence_excerpt"])
        self.assertIn("Ps.706,574 thousand was funded through cash", event["evidence_excerpt"])
        self.assertEqual(event["guidance_measure_basis"], "capital_program_budget_not_cash_capex")
        self.assertFalse(MODULE.usable_guidance_event(event))
        self.assertFalse(MODULE.usable_guidance_event({**event, "quality_status": "clear"}))
        self.assertEqual(MODULE.guidance_coverage_counts([event])["reviewRequiredEvents"], 0)

    def test_a_research_label_without_actual_noncash_budget_evidence_cannot_bypass_review(self):
        event = self.event("For full year 2026 we expect revenue of USD100 million.", "revenue_guidance")
        event.update({"quality_status": "research_only_cash_noncash_mapping", "model_exclusion_reason": "cash-noncash-mapping-needed"})
        self.assertEqual(MODULE.guidance_event_review_reason(event), "quantified_guidance_not_clear")

    def test_plain_cash_capex_does_not_enter_special_noncash_budget_research_path(self):
        self.assertFalse(MODULE.capital_budget_research_candidates([
            "For full year 2026 we have budgeted capital expenditures of USD100 million, excluding noncash additions."
        ]))

    def test_explicit_mxn_currency_and_percentage_only_are_usable_independently(self):
        for excerpt in (
            "For full year 2026, we expect total revenue of MXN80 billion.",
            "For full year 2026, we expect total revenue of Ps. 80 billion.",
            "For full year 2026, we expect total revenue of 80 billion Mexican pesos.",
            "For full year 2026, we expect total revenue to grow by 29% to 32%.",
        ):
            with self.subTest(excerpt=excerpt):
                event = self.event(excerpt, "revenue_guidance")
                self.assertTrue(MODULE.usable_guidance_event(event), event)
                self.assertEqual(MODULE.guidance_coverage_counts([event])["reviewRequiredEvents"], 0)

    def test_conflicting_currency_and_ambiguous_quantities_require_review(self):
        event = self.event("For full year 2026, we expect revenue of US$100 million.", "revenue_guidance")
        for update, reason in (
            ({"quality_status": "currency_conflict", "amount": None}, "guidance_currency_conflict"),
            ({"quality_status": "ambiguous"}, "quantified_guidance_not_clear"),
        ):
            with self.subTest(update=update):
                counts = MODULE.guidance_coverage_counts([{**event, **update}])
                self.assertEqual(counts["usableEvents"], 0)
                self.assertEqual(counts["reviewRequiredReasons"], {reason: 1})
        for update in ({"guidance_subject": "segment_or_subset"}, {"actual_or_guidance": "actual"}):
            counts = MODULE.guidance_coverage_counts([{**event, "currency": None, **update}])
            self.assertEqual(counts["reviewRequiredEvents"], 0)


class OfficialSecGuidanceScopeTest(unittest.TestCase):
    def coverage(self):
        return [
            ("REVIEW", "covered", 0),
            ("GAP", "missing_transcripts", 0),
            ("RETRY", "official_guidance_review_incomplete", 0),
            ("OFFICIAL", "covered_official_filing", 1),
        ]

    def identities(self):
        return {ticker: {f"{index:010}"} for index, (ticker, _, _) in enumerate(self.coverage(), 1)}

    def test_explicit_scope_reviews_transcript_covered_issuer_and_only_requested_tickers(self):
        result = MODULE.select_issuer_targets(
            self.coverage(), self.identities(), tickers=["review, REVIEW"],
            start_date="2026-01-01", as_of="2026-09-05",
        )
        self.assertEqual(result, {"REVIEW": {
            "cik": "0000000001", "start": "2026-01-01", "as_of": "2026-09-05",
        }})

    def test_omitted_scope_preserves_fallback_and_existing_official_targets(self):
        result = MODULE.select_issuer_targets(self.coverage(), self.identities(), as_of="2026-09-05")
        self.assertEqual(set(result), {"GAP", "RETRY", "OFFICIAL"})

    def test_explicit_scope_rejects_missing_coverage_and_missing_cik_together(self):
        with self.assertRaisesRegex(ValueError, "GAP: missing_issuer_cik.*MISSING: missing_guidance_coverage"):
            MODULE.select_issuer_targets(self.coverage(), {}, tickers=["MISSING", "GAP"], as_of="2026-09-05")

    def test_even_fallback_scope_cannot_silently_drop_missing_cik(self):
        identities = self.identities()
        del identities["GAP"]
        with self.assertRaisesRegex(ValueError, "GAP: missing_issuer_cik"):
            MODULE.select_issuer_targets(self.coverage(), identities, as_of="2026-09-05")

    def test_conflicting_issuer_identity_is_not_overwritten_by_snapshot(self):
        identities = self.identities()
        identities["REVIEW"].add("0000000002")
        with self.assertRaisesRegex(ValueError, "REVIEW: conflicting_issuer_ciks"):
            MODULE.select_issuer_targets(self.coverage(), identities, tickers=["REVIEW"], as_of="2026-09-05")

    def test_invalid_zero_and_ambiguous_cik_are_not_accepted(self):
        for value in ("0000000000", "CIK123", "123-456", "12345678901", None):
            self.assertIsNone(MODULE.normalize_cik(value))
        self.assertEqual(MODULE.normalize_cik("1234"), "0000001234")

    def test_cli_accepts_bounded_comma_or_space_ticker_scope(self):
        args = MODULE.parse_args([
            "--tickers", "REVIEW,GAP", "REVIEW", "--as-of", "2026-09-05",
            "--start-date", "2025-01-01", "--guru-manifest", "/unused-guru.json",
        ])
        self.assertEqual(args.tickers, ["GAP", "REVIEW"])
        self.assertEqual(args.as_of, "2026-09-05")
        self.assertEqual(args.start_date, "2025-01-01")
        self.assertEqual(args.guru_manifest, Path("/unused-guru.json"))

    def test_scope_rejects_empty_tickers_bad_dates_and_reversed_window(self):
        for values in ([], ["REVIEW,"], ["REVIEW/USD"]):
            with self.assertRaises(ValueError):
                MODULE.normalize_tickers(values)
        with self.assertRaises(ValueError):
            MODULE.select_issuer_targets(self.coverage(), self.identities(), tickers=["REVIEW"],
                                         start_date="2026-09-06", as_of="2026-09-05")
        with self.assertRaises(Exception):
            MODULE.iso_date("2026-02-30")

    def test_guru_manifest_supplies_cik_for_evidence_collection_before_model_review(self):
        manifests = {
            "/unused-index.json": {"companies": []},
            "/unused-guru.json": {"companies": [{
                "ticker": "REVIEW", "cik": "0000000001", "reviewStatus": "unreviewed",
            }]},
        }
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.execute.return_value.fetchall.return_value = [("REVIEW", "covered", 0)]
        with mock.patch.object(Path, "read_text", autospec=True, side_effect=lambda file, **_: json.dumps(manifests[str(file)])), \
                mock.patch.object(Path, "exists", return_value=False), \
                mock.patch.object(MODULE.sqlite3, "connect", return_value=connection) as connect:
            targets = MODULE.issuer_targets(
                Path("/unused-source.sqlite"), Path("/unused-target.sqlite"), Path("/unused-index.json"),
                guru_manifest_path=Path("/unused-guru.json"), tickers=["REVIEW"], as_of="2026-09-05",
            )
        self.assertEqual(targets["REVIEW"]["cik"], "0000000001")
        self.assertEqual(connect.call_args.kwargs, {"uri": True})
        self.assertTrue(connect.call_args.args[0].endswith("?mode=ro"))

    def records(self):
        dates = ["2025-12-31", "2026-01-01", "2026-09-05", "2026-09-06"]
        return {
            "form": ["8-K"] * len(dates),
            "filingDate": dates,
            "primaryDocument": ["earnings.htm"] * len(dates),
            "items": ["2.02"] * len(dates),
            "accessionNumber": [f"test-{index}" for index in range(len(dates))],
            "reportDate": dates,
        }

    def test_filing_window_includes_both_edges_but_excludes_future_documents(self):
        filings = list(MODULE.filing_rows(self.records(), "2026-01-01", "2026-09-05"))
        self.assertEqual([row["filing_date"] for row in filings], ["2026-01-01", "2026-09-05"])

    def test_tbbb_results_and_generic_6k_wrappers_are_discovered(self):
        names = ["tbbb_4q25_earnings_relea.htm", "6k_tbbb_2q26_earnings_re.htm", "generic6-k.htm", "weeklyrepurchase.htm"]
        records = self.records()
        records.update({"form": ["6-K"] * 4, "primaryDocument": names, "filingDate": ["2026-08-12"] * 4})
        filings = list(MODULE.filing_rows(records, "2026-01-01", "2026-09-05"))
        self.assertEqual([row["primary"] for row in filings], names[:3])
        self.assertTrue(MODULE.RESULT_DOCUMENT.search(names[0]))
        self.assertTrue(MODULE.RESULT_DOCUMENT.search(names[1]))
        self.assertEqual(MODULE.fiscal_period([], {"primary": names[0], "report_date": "2026-03-15", "filing_date": "2026-03-15"}), "Q42025")
        self.assertEqual(MODULE.fiscal_period([], {"primary": names[1], "report_date": "2026-08-12", "filing_date": "2026-08-12"}), "Q22026")

    def test_generic_wrapper_discovers_ex99_attachment_from_accession_directory(self):
        filing = {
            "accession": "0000000001-26-000001", "primary": "generic6-k.htm",
            "form": "6-K", "filing_date": "2026-08-12", "report_date": "2026-06-30",
        }
        index = {"directory": {"item": [{"name": name} for name in ["generic6-k.htm", "EX99.1.htm", "FilingSummary.xml"]]}}
        with mock.patch.object(MODULE, "get_json", return_value=index), \
                mock.patch.object(MODULE, "get_text", return_value="<p>Fixture release</p>"):
            documents = list(MODULE.accession_documents(mock.MagicMock(), "0000000001", filing, Path("/unused-cache")))
        self.assertEqual([row[0] for row in documents], ["generic6-k.htm", "EX99.1.htm"])

    def test_missing_primary_reads_only_bounded_directory_listed_html(self):
        filing = {"accession": "0001628280-26-043288", "primary": "missing.htm"}
        names = ["0001628280-26-043288-index-headers.html", "0001628280-26-043288-index.html",
                 "0001628280-26-043288.txt", "exhibit11-8xk.htm", "../other.htm", "chart.jpg"]
        index = {"directory": {"item": [{"name": name} for name in names]}}
        with mock.patch.object(MODULE, "get_json", return_value=index), \
                mock.patch.object(MODULE, "get_text", return_value="<p>Agreement, not earnings guidance.</p>") as read:
            documents = list(MODULE.accession_documents(mock.MagicMock(), "0001181412", filing, Path("/unused-cache")))
        self.assertEqual([row[0] for row in documents], ["exhibit11-8xk.htm"])
        self.assertEqual(read.call_args.args[1], "https://www.sec.gov/Archives/edgar/data/1181412/000162828026043288/exhibit11-8xk.htm")

    def test_unclassified_html_fallback_cannot_silently_truncate_or_invent_documents(self):
        filing = {"accession": "0000000001-26-000001", "primary": "missing.htm"}
        for names, too_many in [([f"item{i}.htm" for i in range(7)], True), (["image.jpg"], False)]:
            index = {"directory": {"item": [{"name": name} for name in names]}}
            with mock.patch.object(MODULE, "get_json", return_value=index), \
                    mock.patch.object(MODULE, "get_text") as read:
                if too_many:
                    with self.assertRaisesRegex(ValueError, "Too many unclassified"):
                        list(MODULE.accession_documents(mock.MagicMock(), "0000000001", filing, Path("/unused-cache")))
                else:
                    self.assertEqual(list(MODULE.accession_documents(mock.MagicMock(), "0000000001", filing, Path("/unused-cache"))), [])
                read.assert_not_called()

    def scan_fixture_documents(self, documents, *, records=None):
        records = records or self.records()
        submission = {"filings": {"recent": records, "files": []}}
        with mock.patch.object(MODULE, "build_session", return_value=mock.MagicMock()), \
                mock.patch.object(MODULE, "get_json", return_value=submission), \
                mock.patch.object(MODULE, "accession_documents", return_value=documents):
            return MODULE.scan_issuer("REVIEW", {
                "cik": "0000000001", "start": "2026-01-01", "as_of": "2026-09-05",
            }, Path("/unused-cache"))

    def test_zero_filings_or_empty_html_cannot_claim_no_quantified_guidance(self):
        future = self.records()
        future["filingDate"] = ["2026-09-06"] * 4
        for documents, records in [
            ([], future), ([], self.records()),
            ([("EX99.1.htm", "https://example.test/release", "<html><body></body></html>")], self.records()),
        ]:
            _, events, coverage = self.scan_fixture_documents(documents, records=records)
            self.assertEqual(events, [])
            self.assertGreater(coverage["filingErrors"], 0)
            self.assertEqual(coverage["reviewedDocuments"], 0)

    def test_calendar_date_does_not_fabricate_unknown_fiscal_period(self):
        filing = {"primary": "generic6-k.htm", "report_date": "2026-06-30", "filing_date": "2026-08-12"}
        self.assertIsNone(MODULE.fiscal_period(["A generic issuer update."], filing))
        _, events, coverage = self.scan_fixture_documents([
            ("generic6-k.htm", "https://example.test/release", "<p>A generic issuer update.</p>"),
        ])
        self.assertEqual(events, [])
        self.assertGreater(coverage["filingErrors"], 0)
        self.assertEqual(coverage["recognizedPeriodDocuments"], 0)
        self.assertTrue(any(row["error"] == "no_identifiable_fiscal_periods" for row in coverage["accessErrors"]))

    def test_generic_wrapper_can_complete_review_when_ex99_identifies_the_period(self):
        records = self.records()
        records["form"] = ["6-K"] * 4
        records["primaryDocument"] = ["generic6-k.htm"] * 4
        _, _, coverage = self.scan_fixture_documents([
            ("generic6-k.htm", "https://example.test/wrapper", "<p>Form 6-K wrapper.</p>"),
            ("EX99.1.htm", "https://example.test/exhibit", "<h1>Second quarter 2026 financial results</h1><p>The company reported its financial statements.</p>"),
        ], records=records)
        self.assertEqual(coverage["filingErrors"], 0)
        self.assertGreater(coverage["recognizedPeriodDocuments"], 0)
        self.assertGreater(coverage["unknownPeriodDocuments"], 0)

    def test_scanner_never_requests_documents_outside_requested_filing_window(self):
        session = mock.MagicMock()
        submission = {"filings": {"recent": self.records(), "files": []}}
        with mock.patch.object(MODULE, "build_session", return_value=session), \
                mock.patch.object(MODULE, "get_json", return_value=submission), \
                mock.patch.object(MODULE, "accession_documents", return_value=[]) as documents:
            ticker, events, coverage = MODULE.scan_issuer("REVIEW", {
                "cik": "0000000001", "start": "2026-01-01", "as_of": "2026-09-05",
            }, Path("/unused-cache"))
        self.assertEqual(ticker, "REVIEW")
        self.assertEqual(events, [])
        self.assertEqual(coverage["filings"], 2)
        self.assertEqual([call.args[2]["filing_date"] for call in documents.call_args_list],
                         ["2026-01-01", "2026-09-05"])
        session.close.assert_called_once()

    def test_empty_scope_has_no_cache_network_or_database_write(self):
        args = MODULE.parse_args(["--as-of", "2026-09-05"])
        with mock.patch.object(MODULE, "parse_args", return_value=args), \
                mock.patch.object(MODULE, "issuer_targets", return_value={}), \
                mock.patch.object(Path, "mkdir") as mkdir, \
                mock.patch.object(MODULE.sqlite3, "connect") as connect, \
                mock.patch.object(MODULE, "scan_issuer") as scan, \
                mock.patch("builtins.print"):
            MODULE.main()
        mkdir.assert_not_called()
        connect.assert_not_called()
        scan.assert_not_called()

    def test_tbbb_mda_uses_explicit_parent_filing_quarter_and_discovers_budget_without_network(self):
        fixture = json.loads(Path("server/fixtures/tbbb-q1-2026-capital-budget.json").read_text())
        filing = fixture["filing"]
        records = {key: [value] for key, value in {
            "form": filing["form"], "filingDate": filing["filing_date"], "reportDate": filing["report_date"],
            "primaryDocument": filing["primary"], "accessionNumber": filing["accession"], "items": ""
        }.items()}
        html = "".join(f"<p>{line}</p>" for line in fixture["lines"])
        session = mock.MagicMock()
        with mock.patch.object(MODULE, "build_session", return_value=session), \
                mock.patch.object(MODULE, "get_json", return_value={"filings": {"recent": records, "files": []}}), \
                mock.patch.object(MODULE, "accession_documents", return_value=[(fixture["document_name"], fixture["source_url"], html)]):
            _, events, coverage = MODULE.scan_issuer("TBBB", {"cik": "0001978954", "start": "2026-05-27", "as_of": "2026-05-27"}, Path("/unused-cache"))
        self.assertEqual(coverage["filingErrors"], 0)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["fiscal_period"], "Q12026")
        self.assertEqual(events[0]["observed_at"], "2026-05-27")
        self.assertEqual(events[0]["amount"], 5250)
        self.assertEqual(events[0]["model_exclusion_reason"], "cash-noncash-mapping-needed")
        session.get.assert_not_called()

    def test_scoped_writes_preserve_failed_issuer_and_outside_window_history(self):
        args = MODULE.parse_args([
            "--tickers", "REVIEW", "FAILED", "--start-date", "2026-01-01", "--as-of", "2026-09-05",
        ])
        issuers = {
            ticker: {"cik": "0000000001", "start": "2026-01-01", "as_of": "2026-09-05"}
            for ticker in ("REVIEW", "FAILED")
        }
        guide = MODULE.guidance_module()
        event = MODULE.extract_metric_event(
            guide, "REVIEW", "2026-Q2", "2026-08-20", "https://example.test/release",
            "SEC:fixture", "revenue_guidance", "For full year 2026, we expect revenue of US$100 million.",
        )

        def scan(ticker, _config, _cache):
            return ticker, [{**event, "ticker": ticker}], {
                "filings": 1, "filingErrors": int(ticker == "FAILED"), "periods": 1,
            }

        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        # Existing evidence remains present for both issuers, including the
        # incomplete one; positive counts must not turn its status green.
        connection.execute.return_value.fetchall.return_value = [(event["payload_json"], "official_issuer_sec_filing", "clear")]
        with mock.patch.object(MODULE, "parse_args", return_value=args), \
                mock.patch.object(MODULE, "issuer_targets", return_value=issuers), \
                mock.patch.object(Path, "mkdir"), \
                mock.patch.object(MODULE, "scan_issuer", side_effect=scan), \
                mock.patch.object(MODULE, "align_events_to_financial_periods", side_effect=lambda _db, rows, _as_of: rows), \
                mock.patch.object(MODULE, "ensure_schema"), \
                mock.patch.object(MODULE.sqlite3, "connect", return_value=connection), \
                mock.patch("builtins.print"):
            with self.assertRaisesRegex(RuntimeError, "incomplete for: FAILED"):
                MODULE.main()

        deletes = [call for call in connection.execute.call_args_list if call.args[0].lstrip().startswith("DELETE")]
        self.assertEqual(len(deletes), 1)
        self.assertIn("source_type='official_issuer_sec_filing'", deletes[0].args[0])
        self.assertIn("ticker=? AND observed_at>=? AND observed_at<=?", deletes[0].args[0])
        self.assertEqual(deletes[0].args[1], ("REVIEW", "2026-01-01", "2026-09-05"))
        inserts = [call for call in connection.execute.call_args_list if "INSERT OR REPLACE INTO pit_guidance_events" in call.args[0]]
        self.assertEqual(len(inserts), 1)
        self.assertEqual(inserts[0].args[1][1], "REVIEW")
        updates = [call for call in connection.execute.call_args_list if "UPDATE pit_guidance_coverage" in call.args[0]]
        self.assertEqual(len(updates), 2)
        self.assertTrue(all("WHERE ticker=?" in call.args[0] for call in updates))
        statuses = {call.args[1][-1]: call.args[1][2] for call in updates}
        self.assertEqual(statuses["FAILED"], "official_guidance_review_incomplete")
        self.assertEqual(statuses["REVIEW"], "covered_official_filing")
        connection.commit.assert_called_once()

    def test_main_retains_unresolved_amount_but_records_incomplete_currency_review(self):
        args = MODULE.parse_args(["--tickers", "REVIEW", "--start-date", "2026-01-01", "--as-of", "2026-09-05"])
        issuers = {"REVIEW": {"cik": "0000000001", "start": "2026-01-01", "as_of": "2026-09-05"}}
        event = MODULE.extract_metric_event(
            MODULE.guidance_module(), "REVIEW", "2026-Q2", "2026-08-20", "https://example.test/release",
            "SEC:fixture", "revenue_guidance", "For full year 2026, we expect revenue of $100 million.",
        )
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.execute.return_value.fetchall.return_value = [(event["payload_json"], "official_issuer_sec_filing", "clear")]
        with mock.patch.object(MODULE, "parse_args", return_value=args), \
                mock.patch.object(MODULE, "issuer_targets", return_value=issuers), \
                mock.patch.object(Path, "mkdir"), \
                mock.patch.object(MODULE, "scan_issuer", return_value=("REVIEW", [event], {"filings": 1, "filingErrors": 0, "periods": 1})), \
                mock.patch.object(MODULE, "align_events_to_financial_periods", side_effect=lambda _db, rows, _as_of: rows), \
                mock.patch.object(MODULE, "ensure_schema"), \
                mock.patch.object(MODULE.sqlite3, "connect", return_value=connection), \
                mock.patch("builtins.print") as printed:
            with self.assertRaisesRegex(RuntimeError, "incomplete for: REVIEW"):
                MODULE.main()
        inserts = [call for call in connection.execute.call_args_list if "INSERT OR REPLACE INTO pit_guidance_events" in call.args[0]]
        self.assertEqual(len(inserts), 1)
        self.assertEqual(inserts[0].args[1][6], 100)
        self.assertIsNone(inserts[0].args[1][8])
        updates = [call for call in connection.execute.call_args_list if "UPDATE pit_guidance_coverage" in call.args[0]]
        self.assertEqual(len(updates), 1)
        self.assertEqual(updates[0].args[1][2], "official_guidance_review_incomplete")
        self.assertIn("guidance_currency_unresolved", updates[0].args[1][3])
        result = json.loads(printed.call_args_list[-1].args[0])
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["failedTickers"], ["REVIEW"])
        connection.commit.assert_called_once()


if __name__ == "__main__":
    unittest.main()
