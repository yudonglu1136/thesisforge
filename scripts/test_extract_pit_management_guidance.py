import importlib.util
import json
import sys
import unittest
from pathlib import Path
import contextlib
import copy
import io
import sqlite3
import tempfile
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).with_name("extract-pit-management-guidance.py")
SPEC = importlib.util.spec_from_file_location("extract_pit_management_guidance", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class EpsChangesTests(unittest.TestCase):
    def events(self,quote):
        metrics=MODULE.metric_names(quote)
        return MODULE.deduplicate_sentence_events([MODULE.extract_event("TEST","Q12026","2026-04-01","https://example.com/original",Path("original.txt"),"Chief Financial Officer",quote,name,pos,metrics)for name,pos in metrics if name=="eps_guidance"])

    def test_explicit_current_target_is_not_delta_or_old_target(self):
        for quote, expected in [
            ("Increasing our full year adjusted EPS guidance by $0.22 per share to a midpoint of $7.57 per share.",7.57),
            ("We have raised our full-year outlook for adjusted earnings per share by $0.60 from greater than $24.50 to greater than $25.10.",25.10),
            ("We are raising our full-year EPS outlook by $0.13-$0.15, to $5.03-$5.11, reflecting growth of 13%-15%.",5.07),
            ("We are raising our full-year EPS outlook by $0.09-$0.12 to $5.15-$5.20.",5.175),
            ("We raise the 2022 adjusted EPS guidance by $0.08 from $22.93 to $23.01.",23.01),
        ]:
            row=self.events(quote)[0]
            self.assertAlmostEqual(row["per_share_value"],expected,msg=quote)
            self.assertEqual(row["eps_change_evidence"]["kind"],"current_target")
            self.assertEqual(row["evidence_excerpt"],quote)
            self.assertIsNone(row["amount"])
        self.assertEqual(self.events("We raised full-year EPS guidance by $0.60 from greater than $24.50 to greater than $25.10.")[0]["eps_change_evidence"]["target_kind"],"lower_bound")

    def test_standalone_changes_and_operational_drivers_are_not_eps_levels(self):
        for quote in [
            "We raised full-year EPS guidance by $0.10.",
            "We expect optimization actions to impact fiscal 2024 GAAP operating margin by 70 basis points and EPS by $0.56.",
            "We expect current exchange rates to negatively impact second quarter earnings per share by $0.02-$0.03.",
            "The EPS guidance range is increased $0.05 for first quarter tailwinds.",
            "We exceeded our third quarter EPS guidance range by $0.05.",
            "We are raising the high end of our outlook for non-GAAP net income by $0.09 per diluted share for the year.",
        ]:
            row=self.events(quote)[0]
            self.assertIsNone(row["per_share_value"],quote)
            self.assertEqual(row["eps_change_evidence"]["kind"],"change_only",quote)
            self.assertEqual(row["evidence_excerpt"],quote)
            self.assertEqual(row["guidance_subject"],"non_company_or_non_periodic")
            self.assertFalse(row["research_per_share_evidence"][-1]["included_in_valuation_inputs"])

    def test_separate_new_target_owner_never_replaces_or_deletes_delta_owner(self):
        quote="We are raising our full-year adjusted earnings per share guidance by $0.10 and now expect adjusted EPS between $12.09 and $12.29."
        rows=self.events(quote)
        self.assertEqual(len(rows),2)
        self.assertIsNone(rows[0]["per_share_value"])
        self.assertEqual(rows[0]["eps_change_evidence"]["kind"],"change_only")
        self.assertAlmostEqual(rows[1]["per_share_value"],12.19)
        self.assertNotEqual(rows[0]["id"],rows[1]["id"])
        self.assertNotEqual(rows[0]["metric_position"],rows[1]["metric_position"])
        self.assertTrue(all(r["evidence_excerpt"]==quote for r in rows))

    def test_dash_only_changes_are_explicitly_unresolved_not_fabricated_current_targets(self):
        for quote in [
            "We're raising our adjusted EPS guidance for 2021 by $0.01- $2.83-$2.87.",
            "We're raising our adjusted earnings per share guidance for the year by $0.50- $6.25-$6.75.",
            "For the full year, we are raising the midpoint of our adjusted EPS guidance by $0.03- $3.78.",
            "We're raising our adjusted EPS guidance for 2022 by $0.28- $22.93.",
        ]:
            row=self.events(quote)[0]
            self.assertIsNone(row["per_share_value"])
            self.assertEqual(row["extraction_review_required"],"eps_change_target_original_source_required")
            self.assertEqual(row["eps_change_evidence"]["kind"],"ambiguous_change_vs_target")
            self.assertEqual(row["evidence_excerpt"],quote)


class PlusMinusGuidanceTests(unittest.TestCase):
    def test_signed_growth_ranges_preserve_their_economic_direction(self):
        for quote, expected in [
            ("For full year 2020, we expect reported sales growth between -1% and 1%.", 0),
            ("We expect annual revenue growth between -0.5% and 1%.", 0.25),
            ("We expect annual revenue growth of -2% to 1%.", -0.5),
            ("We expect annual sales to decline in the range of 1.5%-3%.", -2.25),
            ("We forecast Q1 revenue to decline 3%-7% on a constant currency basis.", -5),
            ("We expect full-year revenue down 2% to up 1%.", -0.5),
        ]:
            row = self.event(quote)
            self.assertAlmostEqual(row["growth_yoy"], expected, msg=quote)
            self.assertEqual(row["evidence_excerpt"], quote)

    def test_growth_projection_revision_selects_new_level_not_midpoint(self):
        row = self.event("We increased our 2022 full year revenue growth projection from 8.75% to 10.25% at the midpoint of our guidance range.")
        self.assertAlmostEqual(row["growth_yoy"], 10.25)
        ranged = self.event("We increased our full-year revenue growth guidance to a range from 8.75% to 10.25%.")
        self.assertAlmostEqual(ranged["growth_yoy"], 9.5)

    def test_named_business_and_currency_driver_sources_retain_exact_component_disposition(self):
        for quote in [
            "We expect revenue for HAPS business this year of $60 million.",
            "For the full year, we expect UGG brand sales to grow 4%.",
            "For fiscal 2026, we expect a $265 million impact to revenues.",
            "We expect revenues from reimbursable travel to decline 2% this year.",
        ]:
            row = self.event(quote)
            self.assertIn(row["guidance_subject"], {"segment_or_subset", "non_company_or_non_periodic"}, quote)
            self.assertEqual(row["evidence_excerpt"], quote)

    def test_original_actual_beat_cannot_be_a_new_forward_target(self):
        for quote in [
            "For the quarter, worldwide net sales of $121.2 billion exceeded the top end of our revenue guidance range and represented an increase of 10% year-over-year.",
            "The company closed the first quarter with sales of $1,560 million and a diluted EPS of $0.71, exceeding the high end of the company's guidance for sales and EPS by $25 million and $0.04 respectively.",
        ]:
            for row in self.events(quote):
                self.assertEqual(row["actual_or_guidance"], "actual", quote)
                self.assertEqual(row["evidence_excerpt"], quote)
        current = self.event("For next quarter, we expect revenue of $1.6 billion, exceeding our previous guidance of $1.5 billion.")
        self.assertEqual(current["actual_or_guidance"], "guidance")

    def test_direct_eps_components_retain_quote_but_not_absolute_eps_scalar(self):
        for quote in [
            "For 2026, we expect approximately $0.85 of non-GAAP EPS dilution, primarily from financing costs associated with the transaction.",
            "We continue to expect an approximate $0.04 foreign exchange headwind on full-year adjusted earnings per share.",
            "We anticipate $0.05 of EPS pickup attributable to rate relief for this year.",
            "For the fiscal year, we anticipate an adverse impact of approximately $6 million or $0.12 on earnings per share.",
            "We expect FX to be around $0.03 headwind to adjusted EPS for the year.",
            "At current spot rates, we expect a tailwind of approximately $0.30 to adjusted EPS for 2026.",
        ]:
            row = self.event(quote, metric="eps_guidance")
            self.assertIsNone(row["per_share_value"], quote)
            self.assertEqual(row["guidance_subject"], "non_company_or_non_periodic", quote)
            self.assertEqual(row["model_exclusion_reason"], "eps_component_not_absolute_earnings_level", quote)
            self.assertEqual(row["evidence_excerpt"], quote)
            self.assertFalse(row["research_per_share_evidence"][-1]["included_in_valuation_inputs"])
        for quote, expected in [
            ("We expect full-year adjusted EPS of $3.70-$3.80, despite the impact of delayed deals.", 3.75),
            ("Despite a $0.04 FX headwind, we expect full-year adjusted EPS of $3.70-$3.80.", 3.75),
        ]:
            row = self.event(quote, metric="eps_guidance")
            self.assertAlmostEqual(row["per_share_value"], expected)
            self.assertNotEqual(row["model_exclusion_reason"], "eps_component_not_absolute_earnings_level")

    def test_updated_net_income_per_share_cannot_borrow_later_normalized_ffo(self):
        for low, high, ffo_low, ffo_high, expected in [
            ("0.73", "0.84", "3.48", "3.59", 0.785),
            ("0.91", "0.95", "3.59", "3.63", 0.93),
        ]:
            quote = f"Last night, we updated our previously issued full year 2023 outlook for net income attributable to common stockholders to a range of ${low}-${high} per diluted share, and normalized FFO of ${ffo_low}-${ffo_high} per diluted share, or ${((float(ffo_low)+float(ffo_high))/2):g} at the midpoint."
            row = self.event(quote, metric="eps_guidance")
            self.assertAlmostEqual(row["per_share_value"], expected)
            self.assertEqual(row["unit"], "currency_per_share")
            self.assertIsNone(row["amount"])
            ffo = row["research_per_share_evidence"][0]
            self.assertAlmostEqual(ffo["per_share_value"], (float(ffo_low)+float(ffo_high))/2)
            self.assertFalse(ffo["included_in_valuation_inputs"])
            self.assertEqual(row["evidence_excerpt"], quote)
        maintained = self.event("We are maintaining our previously provided full year adjusted earnings per share range of $9.80-$10.10.", metric="eps_guidance")
        self.assertAlmostEqual(maintained["per_share_value"], 9.95)
        previous_only = self.event("For the full year our previously issued EPS guidance range was $3.00-$3.20, before we withdrew guidance.", metric="eps_guidance")
        self.assertIsNone(previous_only["per_share_value"])
        wrong_owner = self.event("We expect annual net income to improve, with normalized FFO of $3.48-$3.59 per diluted share.", metric="eps_guidance")
        self.assertIsNone(wrong_owner["per_share_value"])

    def test_separated_net_income_per_share_adds_eps_without_scaling_total_income(self):
        for quote, expected in [
            ("For Q2 we expect net income to range from $1.20 to $1.35 per share.", 1.275),
            ("For Q3 we expect non-GAAP net income for diluted share in a range of $1 to $1.04.", 1.02),
            ("For the full year we expect net income in the range of $1.18-$1.22 per diluted share.", 1.20),
        ]:
            row = self.event(quote, metric="eps_guidance")
            self.assertAlmostEqual(row["per_share_value"], expected)
            self.assertEqual(row["unit"], "currency_per_share")
            self.assertIsNone(row["amount"])
        for quote in [
            "For the full year we expect operating income of $5.10-$5.40 per share.",
            "For the full year we expect operating earnings of $5.10-$5.40 per share.",
            "For Q2 we expect net income of $5 million and dividends of $0.25 per share.",
            "For Q2 we expect net income to be $5 million based on 100 million shares.",
        ]:
            self.assertFalse(any(name == "eps_guidance" for name, _ in MODULE.metric_names(quote)), quote)

    def test_prior_nonforecast_announcement_does_not_erase_current_split_adjusted_eps(self):
        quote = "The company reaffirmed its fiscal 2018 underlying outlook for net sales growth of 6% to 7%. Split-adjusted fiscal 2018 EPS of $1.43 to $1.48 includes an expected full year negative impact due to tax reform of $0.03 and a negative impact of $0.10 from creating the previously announced charitable foundation during the fourth quarter."
        row = self.event(quote, metric="eps_guidance")
        self.assertAlmostEqual(row["per_share_value"], 1.455)
        self.assertEqual(row["per_share_basis"], "unspecified")
    def test_sequential_growth_is_not_yoy_and_declines_keep_negative_sign(self):
        for phrase, yoy, qoq in [
            ("6% sequential increase and 27.6% year-over-year increase", 27.6, 6),
            ("1% sequential decrease or 22% year-over-year increase", 22, -1),
            ("6.2% sequential decline", None, -6.2),
            ("6%-8% sequential decline and 20%-22% year over year growth", 21, -7),
        ]:
            quote = "For the first quarter we expect revenue of $9 billion, representing a " + phrase + "."
            row = self.event(quote)
            self.assertEqual(row["growth_yoy"], yoy, phrase)
            self.assertEqual(row["growth_qoq"], qoq, phrase)
    def test_past_delivery_with_fiscal_qualifier_cannot_borrow_later_forward_narrative(self):
        quote = "We delivered fiscal Q3 revenue of $31.8 million, an increase of 136% compared to Q3 last year. We expect to broaden customer relationships and continue growth in revenue."
        row = self.event(quote)
        self.assertEqual(row["actual_or_guidance"], "actual")
        self.assertEqual(row["quality_status"], "historical_actual")
        real = self.event("Fourth Quarter of Fiscal 2022 Financial Outlook. Revenue is expected to be between $37 million to $41 million, up 97% year over year at the midpoint")
        self.assertEqual(real["actual_or_guidance"], "guidance")
        self.assertEqual(real["growth_yoy"], 97)
        actual = self.event("In Q1, we achieved another quarter of record revenue at $46.5 million, above our guidance range and up 24% sequentially.")
        self.assertEqual(actual["actual_or_guidance"], "actual")
        self.assertIsNone(actual["growth_yoy"])
        self.assertEqual(actual["growth_qoq"], 24)
        next_quarter = self.event("Turning to guidance for the first quarter, we expect revenue in Q1 fiscal 2023 between $43.5 million and $47.5 million, up 21% sequentially at the midpoint and 324% year-over-year.")
        self.assertEqual(next_quarter["amount"], 45.5)
        self.assertEqual(next_quarter["growth_yoy"], 324)
        self.assertEqual(next_quarter["growth_qoq"], 21)
    def test_explicit_eps_guidance_midpoint_reference_does_not_select_old_actual(self):
        for quote, expected in [
            ("The difference between the Company's full year 2018 EPS of $1.77 and the midpoint of the full year 2019 guidance range of $1.93 is due primarily to lower expected property sale gains.", 1.93),
            ("The difference between the fourth quarter 2018 EPS of $0.31 and the first quarter 2019 guidance midpoint of $0.27 is due primarily to the items described below.", 0.27),
        ]:
            self.assertAlmostEqual(self.event(quote, metric="eps_guidance")["per_share_value"], expected)
    def test_original_eps_owner_excludes_fx_assumption_and_identifies_reported_actual(self):
        quote = "We expect underlying earnings per share to grow mid-single digit compared to full-year earnings per share in 2018 of 42.9p, assuming a US$1.30 to sterling exchange rate."
        for metric, position in MODULE.metric_names(quote):
            if metric == "eps_guidance":
                event = MODULE.extract_event("TEST", "Q12019", "2019-04-01", "https://example.test", Path("source.txt"), "CFO", quote, metric, position, MODULE.metric_names(quote))
                self.assertIsNone(event["per_share_value"])
        actual = self.event("Q1 2026 adjusted earnings per share of $0.80 grew 6% versus 2025, achieving the high end of our guidance range of $0.78-$0.80.", metric="eps_guidance")
        self.assertEqual(actual["actual_or_guidance"], "actual")
        target = self.event("For Q1 we expect adjusted earnings per share of $0.80 representing growth of 6%.", metric="eps_guidance")
        self.assertEqual(target["actual_or_guidance"], "guidance")

    def test_qualifier_does_not_break_direct_following_percentage_owner(self):
        quote = "The company reaffirmed full year expectations for 4-5% underlying net sales growth and 6-8% underlying operating income growth, and increased the FY18 EPS outlook to $1.85-$1.95."
        self.assertEqual(self.event(quote)["growth_yoy"], 4.5)

    def test_questions_and_historical_statements_are_not_forecasts(self):
        quote = "14. Based on the strong free cash flow model should we expect further increases? How can we utilize the $1B cash balance?"
        self.assertEqual(self.event(quote, metric="free_cash_flow_guidance")["actual_or_guidance"], "question")
        self.assertEqual(self.event("Income Statement - 2025 Fourth Quarter and Year-To-Date ($ in millions) QTD Total operating revenues $3,995. Gain on sale of project $4.")["actual_or_guidance"], "actual")
        driver = self.event("For full year 2018 earnings per share will be negatively impacted by $0.13.", metric="eps_guidance")
        self.assertEqual(driver["guidance_subject"], "non_company_or_non_periodic")

    def test_eps_driver_and_dividend_are_not_absolute_earnings(self):
        driver = self.event("For 2021, we expect an EPS headwind of $0.25-$0.30 related to direct material input costs.", metric="eps_guidance")
        self.assertEqual(driver["guidance_subject"], "non_company_or_non_periodic")
        dividend = self.event("For fiscal 2026 we rebased the annual dividend to $4 per share and plan to grow our dividend in line with EPS growth of 6%-8% annually.", metric="eps_guidance")
        self.assertIsNone(dividend["per_share_value"])
        self.assertFalse(any(item["value"] == 1 for item in MODULE.per_share_values("Revenue is $1,025,000,000 and EPS is $5.25.")))
        self.assertEqual(self.event("For 2026 we expect adjusted EPS of $5.25 and dividends of $1.25 per share.", metric="eps_guidance")["per_share_value"], 5.25)

    def test_comparison_fiscal_year_cannot_replace_forward_target_year(self):
        for quote, expected in [
            ("For the full fiscal year 2014, we expect net revenue growth of 2%-6% in local currency over fiscal 2013.", 2014),
            ("For the full FY2026, we expect revenue growth of 5%-7% relative to FY2025.", 2026),
        ]:
            self.assertEqual(self.event(quote)["guidance_target_year"], expected)

    def test_fiscal_short_year_is_annual_but_qualified_quarter_stays_quarter(self):
        quote = "For fiscal 26, given further weakness through the first half in the US we have updated both organic net sales and operating profit growth guidance. We have reiterated free cash flow guidance of $3 billion."
        result = self.event(quote, metric="free_cash_flow_guidance")
        self.assertEqual(result["guidance_scope"], "full_year")
        self.assertEqual(result["guidance_target_year"], 2026)
        self.assertEqual(result["amount"], 3000)
        self.assertIsNone(result["currency"])
        for prefix in ["For Q2 fiscal 26", "For the second quarter of fiscal 26"]:
            quarter = self.event(prefix + " we expect revenue of $1 billion.")
            self.assertEqual(quarter["guidance_scope"], "quarter")
            self.assertEqual(quarter["guidance_target_year"], 2026)
        no_year = self.event("For the next 26 months we expect revenue of $1 billion.")
        self.assertNotEqual(no_year["guidance_scope"], "full_year")

    def test_full_dollar_guidance_reconciles_to_millions_and_preserves_currency(self):
        for quote, expected in (
            ("We expect Q4 2025 worldwide revenues to be in the range of $1,025,000,000- $1,045,000,000, up sequentially from Q3 of 2025.", 1035),
            ("For the full year of 2018, we now expect sales in the range of $7,630,000,000 -$7,750,000,000 and adjusted diluted EPS in the range of $3.49-$3.55.", 7690),
            ("For the fourth quarter, we expect revenue in the range of $1,370 ,000,000- $1,390,000,000 and Q4 earnings per share in the range of $1.79- $1.85, based on a weighted diluted share count of approximately 173 million shares.", 1380),
        ):
            with self.subTest(quote=quote):
                result = self.event(quote)
                self.assertEqual(result["amount"], expected)
                self.assertIsNone(result["currency"], "A bare dollar remains unresolved currency")
                self.assertEqual(len(result["selected_values"]), 2)
                for value in result["selected_values"]:
                    self.assertEqual(quote[value["position"]:value["end"]], value["text"])
        self.assertEqual(self.event("For the full year we expect revenue of MXN 1,025,000,000.")["currency"], "MXN")

    def test_full_dollar_amount_parser_does_not_borrow_year_shares_or_eps(self):
        self.assertEqual(MODULE.amount_values("For 2026, EPS is $1.20 and diluted shares are 1,025,000,000."), [])
        result = self.event("For the full year we expect revenue of $1,200,000,000 and costs of $1,000,000,000.")
        self.assertEqual(result["amount"], 1200)
        self.assertEqual(MODULE.amount_values("USD (1,200,000,000)")[0]["value"], -1200)
        self.assertEqual(len(MODULE.amount_values("$1,200,000,000 million")), 1)

    def test_original_are_ordinal_midpoints_and_range_width_changes(self):
        fixture = json.loads((Path(__file__).parents[1] / "server/fixtures/guidance-are-ordinal-widths-2026.json").read_text())
        for case in fixture["cases"]:
            original = case["original"]
            with self.subTest(source_id=original["id"]):
                event = self.event(original["evidence_excerpt"], metric="eps_guidance")
                for key, expected in case["expected"].items():
                    if isinstance(expected, float):
                        self.assertAlmostEqual(event[key], expected, places=9, msg=key)
                    else:
                        self.assertEqual(event[key], expected, key)
                self.assertEqual(len(event["research_per_share_evidence"]), 1)
                research = event["research_per_share_evidence"][0]
                for key, expected in case["researchExpected"].items():
                    if isinstance(expected, float):
                        self.assertAlmostEqual(research[key], expected, places=9, msg=key)
                    else:
                        self.assertEqual(research[key], expected, key)
                self.assertIsNone(event["amount"])
                self.assertIsNone(research["currency"])
                if research["metric_name"] == "guidance_range_width":
                    self.assertEqual(event["selected_values"], [])
                    self.assertEqual(research["affected_metrics"], ["eps_guidance", "ffo_per_share"])

    def test_eps_ffo_ordinal_is_explicit_and_preserves_reversed_order(self):
        explicit = self.event("For 2026 we expect FFO per share and EPS at $7.38 and $2.22, respectively.", metric="eps_guidance")
        self.assertEqual(explicit["per_share_value"], 2.22)
        self.assertEqual(explicit["research_per_share_evidence"][0]["per_share_value"], 7.38)
        unclear = self.event("For 2026 we expect EPS and FFO per share at $2.22 and $7.38.", metric="eps_guidance")
        self.assertIsNone(unclear["per_share_value"], "Different per-share metrics require explicit ordinal evidence")

    def test_narrowed_target_range_is_not_a_range_width_change(self):
        event = self.event("We narrowed our 2026 EPS guidance range to $2.20-$2.24 and FFO per share guidance to $7.36-$7.40.", metric="eps_guidance")
        self.assertAlmostEqual(event["per_share_value"], 2.22)
        self.assertAlmostEqual(event["research_per_share_evidence"][0]["per_share_value"], 7.38)
        self.assertEqual(event["quality_status"], "clear")
        self.assertIsNone(event["model_exclusion_reason"])

    def test_range_width_rejection_is_owned_not_paragraph_wide(self):
        sentence = ("For 2026, we expect EPS of $2.22. "
                    "We narrowed the range for FFO per share from a range of $0.08 to a range of $0.02 per share.")
        event = self.event(sentence, metric="eps_guidance")
        self.assertEqual(event["per_share_value"], 2.22)
        self.assertEqual(event["quality_status"], "clear")
        research = event["research_per_share_evidence"][0]
        self.assertEqual(research["metric_name"], "guidance_range_width")
        self.assertEqual(research["affected_metrics"], ["ffo_per_share"])
        self.assertIsNone(research["per_share_value"])
        self.assertEqual((research["range_width_before"], research["range_width_after"]), (0.08, 0.02))

    def test_original_ffiv_year_range_and_are_eps_ffo_economic_owners(self):
        fixture = json.loads((Path(__file__).parents[1] / "server/fixtures/guidance-ffiv-are-owned-evidence-2026.json").read_text())
        for case in fixture["cases"]:
            with self.subTest(ticker=case["ticker"], source_id=case["sourceId"]):
                event = self.event(case["originalQuote"], metric=case["metric"])
                for key, value in case["expected"].items():
                    if isinstance(value, (float, int)):
                        self.assertAlmostEqual(event[key], value, places=9, msg=key)
                    else:
                        self.assertEqual(event[key], value, key)
                self.assertEqual(len(event["selected_values"]), 2)
                if case["researchExpected"]:
                    research = event["research_per_share_evidence"]
                    self.assertEqual(len(research), 1)
                    for key, value in case["researchExpected"].items():
                        if isinstance(value, float):
                            self.assertAlmostEqual(research[0][key], value, places=9, msg=key)
                        else:
                            self.assertEqual(research[0][key], value, key)
                    self.assertIsNone(research[0]["currency"], "Bare dollar is not currency evidence")
                    self.assertEqual(research[0]["unit"], "currency_per_share")
                    self.assertEqual(event["per_share_basis"], "unspecified")

    def test_rejected_year_does_not_consume_the_real_percent_range(self):
        for sentence, expected in (
            ("We are raising our revenue outlook for FY 2025 to 6.5%-7.5% growth.", 7),
            ("We are lowering our revenue outlook for FY 2025 to -7.5% to -6.5% growth.", -7),
            ("For FY2025, we expect revenue growth of 2000%-2100%.", 2050),
            ("We are raising our revenue growth outlook for 2025 to 6.5%.", 6.5),
        ):
            with self.subTest(sentence=sentence):
                event = self.event(sentence)
                self.assertEqual(event["growth_yoy"], expected)
                self.assertTrue(all(value["value"] != 2025 for value in event["selected_values"]))

    def test_ffo_never_becomes_eps_in_either_clause_order(self):
        for sentence in (
            "For 2026, we expect EPS ranging from $1.08 to $1.18 and FFO per share ranging from $8.33 to $8.43.",
            "For 2026, we expect FFO per share ranging from $8.33 to $8.43 and EPS ranging from $1.08 to $1.18.",
            "For 2026, we expect EPS ranging from $1.08 to $1.18 and funds from operations per share ranging from $8.33 to $8.43.",
        ):
            with self.subTest(sentence=sentence):
                event = self.event(sentence, metric="eps_guidance")
                self.assertAlmostEqual(event["per_share_value"], 1.13)
                self.assertIsNone(event["amount"])
                research = event["research_per_share_evidence"][0]
                self.assertAlmostEqual(research["per_share_value"], 8.38)
                self.assertEqual(research["per_share_basis"], "ffo")
                self.assertFalse(research["included_in_valuation_inputs"])
                self.assertIsNone(research["amount"])
        self.assertEqual(self.events("For 2026, we expect FFO per share of $8.38.", metric="eps_guidance"), [])

    def test_ranging_from_is_a_range_but_historical_from_is_not(self):
        sentence = "EPS increased from $1.08 to $1.18 last year."
        values = MODULE.per_share_values(sentence)
        self.assertFalse(MODULE.explicit_range_pair(values[0], values[1], sentence))
        event = self.event("For 2026, we expect EPS ranging from $1.08 to $1.18.", metric="eps_guidance")
        self.assertAlmostEqual(event["per_share_value"], 1.13)
        self.assertNotIn("research_per_share_evidence", event)

    def test_six_original_quotes_for_four_confirmed_owned_parser_defects(self):
        fixture = json.loads((Path(__file__).parents[1] / "server/fixtures/guidance-four-owned-parser-errors-2026.json").read_text())
        for case in fixture["cases"]:
            original = case["original"]
            metrics = MODULE.metric_names(original["evidence_excerpt"])
            metric, position = next(item for item in metrics if item[0] == original["metric_name"])
            with self.subTest(ticker=original["ticker"], source_id=original["id"]):
                event = MODULE.extract_event(original["ticker"], original["fiscal_period"], original["observed_at"], original["source_url"], Path("public-transcript-fixture"), original["speaker"], original["evidence_excerpt"], metric, position, metrics)
                for key, expected in case["expected"].items():
                    if isinstance(expected, float):
                        self.assertAlmostEqual(event[key], expected, places=9, msg=key)
                    else:
                        self.assertEqual(event[key], expected, key)
                if metric == "eps_guidance":
                    self.assertEqual(len(event["selected_values"]), 2)

    def test_explicit_per_share_range_cannot_be_split_by_another_metric_owner(self):
        sentence = "We expect revenue growth and EPS between $1.10 and $1.30 for the full year."
        event = self.event(sentence, metric="eps_guidance")
        self.assertAlmostEqual(event["per_share_value"], 1.20)
        self.assertEqual(len(event["selected_values"]), 2)
        # A real parallel pair of different company-level monetary metrics is
        # still ordinal; the protected unit is only per-share or a legal range.
        pair = "We expect EBITDA and operating income of $2.6 billion and $1.9 billion, respectively."
        self.assertEqual(self.event(pair, metric="ebitda_guidance")["amount"], 2600)
        self.assertEqual(self.event(pair, metric="operating_income_guidance")["amount"], 1900)

    def test_revised_eps_range_is_distinct_from_delta_and_later_other_values(self):
        range_event = self.event("We are raising full-year EPS guidance by $0.20 to $2.10-$2.30, including a $0.05 tax benefit.", metric="eps_guidance")
        self.assertAlmostEqual(range_event["per_share_value"], 2.20)
        point_event = self.event("We are raising full-year EPS guidance by $0.20 to $2.10, including a $0.05 tax benefit.", metric="eps_guidance")
        self.assertEqual(point_event["per_share_value"], 2.10)

    def test_q4_of_fiscal_year_remains_quarter_and_distinct_annual_target_survives(self):
        for marker in ("Q4 of FY21", "Q4 of fiscal 2021", "Q4 of fiscal year 2021"):
            with self.subTest(marker=marker):
                event = self.event(f"For {marker}, we expect revenue of USD 13 billion.")
                self.assertEqual(event["guidance_scope"], "quarter")
                self.assertEqual(event["guidance_target_year"], 2021)
        annual = self.event("For full-year FY21, we expect revenue of USD 50 billion.")
        self.assertEqual(annual["guidance_scope"], "full_year")

    def test_employee_growth_does_not_bind_to_revenue_in_either_clause_order(self):
        for sentence in (
            "For the full year, we expect employee growth of 2%-3% and revenue growth of 3%-4%.",
            "For the full year, we expect revenue growth of 3%-4% and employee growth of 2%-3%.",
        ):
            with self.subTest(sentence=sentence):
                event = self.event(sentence)
                self.assertEqual(event["growth_yoy"], 3.5)

    def events(self, sentence, metric="revenue_guidance"):
        metrics = MODULE.metric_names(sentence)
        return [
            MODULE.extract_event(
                "TEST",
                "Q12026",
                "2026-05-01",
                "https://example.test/release",
                Path("TEST-Q1-2026.txt"),
                "Test CEO",
                sentence,
                name,
                position,
                metrics,
            )
            for name, position in metrics
            if name == metric
        ]

    def event(self, sentence, metric="revenue_guidance"):
        return self.events(sentence, metric)[0]

    def test_money_plus_minus_uses_center_not_tolerance_average(self):
        event = self.event("Revenue is expected to be $4.1 billion, ±$100 million.")

        self.assertEqual(event["amount"], 4_100)
        self.assertIsNone(event["currency"])
        self.assertEqual(event["currency_resolution"]["status"], "source_currency_required")

    def test_plus_or_minus_words_use_center_not_tolerance_average(self):
        event = self.event("Revenue is expected to be $2.1 billion, + or - $150 million.")

        self.assertEqual(event["amount"], 2_100)

    def test_mojibake_plus_minus_uses_center(self):
        event = self.event("Revenue is expected to be $1.5 billion Â±$50 million.")

        self.assertEqual(event["amount"], 1_500)

    def test_mojibake_attached_to_scale_does_not_hide_center(self):
        event = self.event("Revenue is expected to be $3.1 billionÂ±, $100 million.")

        self.assertEqual(event["amount"], 3_100)

    def test_percentage_tolerance_keeps_monetary_center(self):
        event = self.event("Revenue is expected to be $2.32 billion Â±5%.")

        self.assertEqual(event["amount"], 2_320)

    def test_multiple_percentage_tolerances_stay_with_their_metric(self):
        event = self.event(
            "We expect capital expenditures of $700 million Â±5% and depreciation of $690 million Â±5%.",
            metric="capex_guidance",
        )

        self.assertEqual(event["amount"], 700)

    def test_revenue_amount_is_not_stolen_by_a_later_margin_metric(self):
        event = self.event(
            "We expect revenue and gross margin to be $10 billion and 50%, respectively."
        )

        self.assertEqual(event["amount"], 10_000)

    def test_equidistant_amount_belongs_to_preceding_revenue_metric(self):
        event = self.event(
            "We expect total revenue to be $2.32 billion Â±5%, gross margin to be at least 26.5%, and EPS of $0.83 Â±5%."
        )

        self.assertEqual(event["amount"], 2_320)

    def test_margin_plus_minus_uses_percentage_center_and_no_money_amount(self):
        event = self.event(
            "Operating margin is expected to be 42% ±100 basis points and includes $100 million of synergies.",
            metric="operating_margin",
        )

        self.assertEqual(event["margin_pct"], 42)
        self.assertIsNone(event["amount"])

    def test_versus_values_are_not_averaged_as_a_range(self):
        event = self.event(
            "We expect to spend around $3.5 billion versus free cash flow of $2.4 billion.",
            metric="free_cash_flow_guidance",
        )

        self.assertEqual(event["amount"], 2_400)

    def test_explicit_to_range_uses_endpoint_midpoint(self):
        event = self.event("Revenue is expected to be $4.0 billion to $4.2 billion.")

        self.assertEqual(event["amount"], 4_100)

    def test_between_and_range_uses_endpoint_midpoint(self):
        event = self.event("We expect revenue between $900 million and $1.1 billion.")

        self.assertEqual(event["amount"], 1_000)

    def test_range_with_scale_only_after_second_endpoint_uses_midpoint(self):
        revenue = self.event("We expect revenue of $1.66-$1.68 billion.")
        operating_income = self.event(
            "We expect operating income of $205-$225 million.",
            metric="operating_income_guidance",
        )

        self.assertEqual(revenue["amount"], 1_670)
        self.assertEqual(operating_income["amount"], 215)

    def test_company_sales_and_data_center_revenue_are_separate_events(self):
        events = self.events(
            "We now expect full year sales to be roughly $23 billion, with organic growth up "
            "mid to high single-digits and full year data center revenue of approximately "
            "$2 billion versus $1.5 billion prior guide."
        )

        self.assertEqual([event["amount"] for event in events], [23_000, 2_000])
        self.assertEqual(events[0]["guidance_scope"], "full_year")
        self.assertEqual(events[0]["guidance_subject"], "company_total_or_unspecified")
        self.assertEqual(events[1]["guidance_subject"], "segment_or_subset")

    def test_mixed_horizon_sentence_scopes_selected_full_year_amount_locally(self):
        events = self.events(
            "Turning to service revenues, we continue to expect to deliver full-year service "
            "revenues of approximately $77 billion this year, representing 8% growth, with Q3 "
            "expectations of approximately $19.3 billion, or up 6% year-over-year."
        )
        valued = [event for event in events if event["amount"] is not None]

        self.assertEqual(len(valued), 1)
        self.assertEqual(valued[0]["amount"], 77_000)
        self.assertEqual(valued[0]["guidance_scope"], "full_year")
        self.assertEqual(valued[0]["guidance_subject"], "segment_or_subset")

    def test_month_named_quarter_is_structured_quarter_scope(self):
        event = self.event(
            "September quarter revenue is expected to be in a range of $2.1 billion, "
            "+ or - $150 million."
        )

        self.assertEqual(event["amount"], 2_100)
        self.assertEqual(event["guidance_scope"], "quarter")

    def test_cost_amount_is_not_owned_by_a_revenue_guidance_reference(self):
        sentences = (
            "At the midpoint of our revenue guidance, we expect operating margin to improve, "
            "including underutilization costs of approximately $20 million.",
            "We expect OpEx savings of approximately $40 million, with no expected impact to revenue.",
            "At the midpoint of our revenue guidance, we expect operating margin in the low "
            "single digits, including between $50 million and $60 million in underutilization cost.",
        )
        for sentence in sentences:
            with self.subTest(sentence=sentence):
                revenue_events = self.events(sentence)
                self.assertTrue(revenue_events)
                self.assertTrue(all(event["amount"] is None for event in revenue_events))

    def test_operating_cash_flow_amount_is_not_assigned_to_revenue_growth(self):
        sentence = (
            "At the midpoint, we now expect revenue growth of 19%, operating margin of "
            "44.25%, EPS of $8.10, and operating cash flow of $2 billion for the year."
        )
        event = self.event(sentence)
        cash_flow = self.event(sentence, metric="operating_cash_flow_guidance")

        self.assertIsNone(event["amount"])
        self.assertEqual(event["growth_yoy"], 19)
        self.assertEqual(cash_flow["amount"], 2_000)

    def test_amount_immediately_before_operating_cash_flow_uses_following_owner(self):
        sentence = (
            "We expect consolidated adjusted revenues to grow at least 20%, and we expect "
            "to generate at least $11 billion of operating cash flow."
        )

        self.assertIsNone(self.event(sentence)["amount"])
        self.assertEqual(
            self.event(sentence, metric="operating_cash_flow_guidance")["amount"],
            11_000,
        )

    def test_revenue_ocf_and_capex_values_bind_to_three_separate_metrics(self):
        sentence = (
            "We expect revenue growth of 10.5%-11%, adjusted EPS in the range of "
            "$6.28-$6.33, operating cash flow of approximately $900 million, and "
            "capital expenditures of $150 million."
        )

        self.assertIsNone(self.event(sentence)["amount"])
        self.assertEqual(
            self.event(sentence, metric="operating_cash_flow_guidance")["amount"],
            900,
        )
        self.assertEqual(self.event(sentence, metric="capex_guidance")["amount"], 150)

    def test_billings_and_revenue_ranges_bind_to_their_own_metrics(self):
        sentence = (
            "For fiscal 2026, we expect billings of $7.2 billion to $7.3 billion and "
            "revenue of $6.26 billion to $6.34 billion."
        )

        self.assertEqual(self.event(sentence, metric="backlog_guidance")["amount"], 7_250)
        self.assertEqual(self.event(sentence)["amount"], 6_300)

    def test_fcf_revision_delta_does_not_cross_average_with_new_range(self):
        event = self.event(
            "We are raising our free cash flow outlook by $88 million to a new range of "
            "$2.2 billion to $2.275 billion.",
            metric="free_cash_flow_guidance",
        )

        self.assertEqual(event["amount"], 2_237.5)

    def test_raise_by_delta_to_new_level_selects_new_level(self):
        event = self.event(
            "We are increasing our projected free cash flow by $200 million to about "
            "$1.9 billion.",
            metric="free_cash_flow_guidance",
        )

        self.assertEqual(event["amount"], 1_900)
        self.assertNotEqual(event["guidance_subject"], "non_company_or_non_periodic")

    def test_revenue_and_ebit_amounts_bind_independently(self):
        sentence = (
            "For the full year, we expect revenue of $16.5 billion and adjusted EBIT "
            "of $4.235 billion."
        )

        self.assertEqual(self.event(sentence)["amount"], 16_500)
        self.assertEqual(
            self.event(sentence, metric="operating_income_guidance")["amount"],
            4_235,
        )

    def test_fx_impacts_on_revenue_and_ebit_are_non_periodic_deltas(self):
        sentence = (
            "We estimate the full-year negative impact of foreign exchange on reported "
            "revenue and EBIT to be approximately $4 billion and $900 million, respectively."
        )

        revenue = self.event(sentence)
        ebit = self.event(sentence, metric="operating_income_guidance")
        self.assertEqual(revenue["amount"], 4_000)
        self.assertEqual(ebit["amount"], 900)
        self.assertEqual(revenue["guidance_subject"], "non_company_or_non_periodic")
        self.assertEqual(ebit["guidance_subject"], "non_company_or_non_periodic")

    def test_fx_reduction_to_operating_profit_is_non_periodic(self):
        event = self.event(
            "For the full year, we estimate foreign exchange will reduce operating "
            "profits by approximately $28 million.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["guidance_subject"], "non_company_or_non_periodic")

    def test_revenue_used_only_as_capex_ratio_denominator_is_non_company(self):
        for sentence in (
            "We expect capital expenditures to be approximately 3% of revenue, with a "
            "capacity access fee of $70 million and an equity investment of $80 million.",
            "We anticipate full-year capital expenditures will be 40%-42% of total "
            "revenue, including a $700 million impact from a contract.",
        ):
            with self.subTest(sentence=sentence):
                event = self.event(sentence)
                self.assertEqual(
                    event["guidance_subject"],
                    "non_company_or_non_periodic",
                )

    def test_fx_revenue_headwind_is_not_a_company_revenue_level(self):
        event = self.event(
            "We now expect FX to be a year-over-year headwind of $1.25 billion in "
            "revenue, or 3.2%."
        )

        self.assertEqual(event["guidance_subject"], "non_company_or_non_periodic")

    def test_depreciation_amount_does_not_enter_capex_range(self):
        event = self.event(
            "We expect depreciation and amortization of $57 million and capital "
            "expenditures of $35 million to $45 million.",
            metric="capex_guidance",
        )

        self.assertEqual(event["amount"], 40)

    def test_capex_range_and_fcf_level_do_not_cross_average(self):
        sentence = (
            "For the year, we expect capital spending of $1.4 billion to $1.7 billion "
            "and free cash flow of $7 billion."
        )

        self.assertEqual(self.event(sentence, metric="capex_guidance")["amount"], 1_550)
        self.assertEqual(self.event(sentence, metric="free_cash_flow_guidance")["amount"], 7_000)

    def test_between_range_accepts_text_currency_tokens(self):
        event = self.event(
            "For the full year, we expect revenue between EUR 8.4 billion and EUR 9 billion."
        )

        self.assertEqual(event["amount"], 8_700)

    def test_multiple_ranges_for_one_metric_choose_nearest_explicit_pair(self):
        event = self.event(
            "We expect capex in the range of $28 billion to $29 billion, compared with "
            "$27 billion to $28 billion in the prior year.",
            metric="capex_guidance",
        )

        self.assertEqual(event["amount"], 28_500)

    def test_low_and_high_end_wording_is_an_explicit_range(self):
        event = self.event(
            "We are raising the low end of revenue guidance to $8.7 billion and "
            "maintaining the high end at $8.9 billion."
        )

        self.assertEqual(event["amount"], 8_800)

    def test_down_to_up_range_preserves_endpoint_signs(self):
        event = self.event(
            "We expect operating profit to be in the range of down $125 million to "
            "up $25 million.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["amount"], -50)

    def test_q2_fy_label_is_quarter_scope_not_full_year(self):
        event = self.event(
            "For Q2 FY 2027, we expect revenue between $265 million and $273 million."
        )

        self.assertEqual(event["guidance_scope"], "quarter")

    def test_compact_forecast_year_stays_annual_but_q2_fy26e_stays_quarter(self):
        annual = self.event("FY26E revenue guidance is USD 100 million.")
        self.assertEqual(annual["guidance_scope"], "full_year")
        self.assertEqual(annual["guidance_target_year"], 2026)
        quarterly = self.event("Q2 FY26E revenue guidance is USD 100 million.")
        self.assertEqual(quarterly["guidance_scope"], "quarter")
        self.assertIsNone(quarterly["guidance_target_year"])

    def test_bare_left_percent_endpoint_and_comparison_base_are_not_lost(self):
        for value in ("15-18%", "15–18%", "15 to 18%", "15% to 18%"):
            with self.subTest(value=value):
                event = self.event(f"For full year 2026 we expect revenue growth of {value}.")
                self.assertEqual(event["growth_yoy"], 16.5)
                self.assertEqual(len(event["selected_values"]), 2)
        current = self.event("Updated FY2026 outlook reflects 22-23% year-over-year increase in net sales, compared to 18-20% previously.")
        self.assertEqual(current["growth_yoy"], 22.5)
        decimals = self.event("Updated FY2026 outlook reflects 22.5-23.5% year-over-year increase in net sales, compared to the previous 18.5-20.5% range.")
        self.assertEqual(decimals["growth_yoy"], 23)

    def test_annual_paragraph_scope_does_not_cross_a_new_quarter_horizon(self):
        sentence = ("For the full year 2026, revenue is expected to be USD 900 million. "
                    "The company outlined its planned investment in facilities and supporting operations. "
                    "For Q3 we expect a separate investment program. "
                    "Guidance for capital expenditures is USD 20 million.")
        event = self.event(sentence, metric="capex_guidance")
        self.assertEqual(event["guidance_scope"], "quarter")

    def test_results_versus_outlook_table_is_preserved_as_actual_not_new_guidance(self):
        event = self.event("Financial Results vs. Outlook Q2 2026 RESULTS Q2 2026 OUTLOOK Revenue USD 260.2 million USD 139-143 million.")
        self.assertEqual(event["actual_or_guidance"], "actual")
        self.assertEqual(event["quality_status"], "historical_actual")

    def test_met_guidance_is_historical_not_a_new_outlook(self):
        sentence = "Revenue of $2 billion met our guidance for the second quarter."

        self.assertIsNotNone(MODULE.HISTORICAL_GUIDANCE.search(sentence))

    def test_owned_revenue_exceeded_is_actual_despite_better_than_expected(self):
        sentence = (
            "We ended 2025 on a strong note with a better-than-expected Holiday quarter. "
            "For the year, revenue exceeded $4 billion, led by low-double digit "
            "international growth for the Crocs Brand."
        )
        event = self.event(sentence)
        self.assertEqual(event["amount"], 4000)
        self.assertEqual(event["actual_or_guidance"], "actual")
        self.assertEqual(event["quality_status"], "historical_actual")
        for past in ("has exceeded", "had exceeded"):
            with self.subTest(past=past):
                self.assertEqual(self.event(sentence.replace("exceeded", past))["actual_or_guidance"], "actual")

    def test_owned_future_target_survives_unrelated_past_performance(self):
        for sentence in (
            "We ended 2025 with a better-than-expected Holiday quarter. For 2026, we expect revenue to exceed $4 billion.",
            "We exceeded expectations last year. For 2026, revenue is expected to exceed $4 billion.",
            "This results in us maintaining our full year reported revenue guidance range of $6.67 billion-$6.73 billion for the full year.",
        ):
            with self.subTest(sentence=sentence):
                event = self.event(sentence)
                self.assertEqual(event["actual_or_guidance"], "guidance")
                self.assertEqual(event["quality_status"], "clear")

    def test_actual_value_does_not_enter_later_forward_sentence_context(self):
        event = self.event(
            "We expect other income expense to remain flat in the June quarter. "
            "non-GAAP net income grew to $934 million with corresponding EPS of $4.10.",
            metric="net_income_guidance",
        )

        self.assertIsNone(event["amount"])

    def test_lowercase_following_actual_net_loss_is_not_forward_operating_income(self):
        event = self.event(
            "We expect to achieve non-GAAP operating income break even next quarter. "
            "non-GAAP net loss in Q3 was $13.4 million, compared with a net loss of "
            "$28.8 million last year.",
            metric="operating_income_guidance",
        )

        self.assertIsNone(event["amount"])

    def test_delivered_comparison_base_is_not_forward_fcf_guidance(self):
        event = self.event(
            "We expect to deliver over 50% growth in free cash flow in 2024 versus the "
            "$518 million we delivered in 2023.",
            metric="free_cash_flow_guidance",
        )

        self.assertIsNone(event["amount"])

    def test_actual_and_forward_revenue_values_bind_independently(self):
        events = MODULE.deduplicate_sentence_events(self.events(
            "Residential revenue came in at $10 million in the third quarter, and we expect "
            "full year revenue of $43 million."
        ))

        self.assertEqual([event["amount"] for event in events if event["amount"] is not None], [43])

    def test_reported_revenue_is_an_accounting_modifier_not_a_past_tense_verb(self):
        event = self.event(
            "We expect our reported revenue to be in the range of $1.79 billion-$1.82 billion."
        )

        self.assertEqual(event["amount"], 1_805)

    def test_closed_sales_is_a_pipeline_metric_not_a_past_tense_close(self):
        event = self.event(
            "We expect closed sales to be in the range of $170 million-$210 million."
        )

        self.assertEqual(event["amount"], 190)

    def test_excluded_expense_clause_does_not_steal_operating_income_range(self):
        event = self.event(
            "We anticipate consolidated operating income, which excludes stock-based compensation "
            "and other operating expense, to be between $275 million and $425 million.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["amount"], 350)

    def test_cash_balance_does_not_average_with_forward_fcf(self):
        event = self.event(
            "Our cash balance at year end was $8.4 billion, and we expect to generate free cash "
            "flow of approximately $21 billion in 2026.",
            metric="free_cash_flow_guidance",
        )

        self.assertEqual(event["amount"], 21_000)

    def test_fiscal_year_and_share_repurchase_do_not_become_fcf_guidance(self):
        sentence = (
            "This brings total share repurchases since the beginning of fiscal year 2025 "
            "to $1.4 billion, we see continued runway moving forward given our strong "
            "outlook for free cash flow."
        )
        event = self.event(sentence, metric="free_cash_flow_guidance")

        self.assertEqual(
            [value["value"] for value in MODULE.amount_values(sentence)],
            [1_400],
        )
        self.assertIsNone(event["amount"])
        self.assertEqual(event["guidance_subject"], "non_company_or_non_periodic")

    def test_earlier_cost_clause_does_not_steal_later_revenue(self):
        event = self.event(
            "Ramp-up costs will affect the fourth quarter, but in 2027 we expect to generate "
            "about $20 million of revenue."
        )

        self.assertEqual(event["amount"], 20)

    def test_repeated_metric_words_do_not_weight_the_same_sentence_more_than_once(self):
        events = self.events(
            "We expect revenue growth to improve and revenue momentum to support revenue "
            "of approximately $4 billion for the full year."
        )
        deduplicated = MODULE.deduplicate_sentence_events(events)

        self.assertEqual(len(deduplicated), 1)
        self.assertEqual(sum(event["amount"] is not None for event in deduplicated), 1)

    def test_empty_repeated_revenue_word_is_removed_after_plus_minus_center(self):
        for sentence, expected in (
            (
                "We expect revenue to be approximately $9.8 billion, plus or minus $300 million, "
                "including approximately $100 million of MI308 sales to China.",
                9_800,
            ),
            (
                "We expect revenue to be $8.7 billion +/- $200 million, which will represent a "
                "new record for quarterly revenues.",
                8_700,
            ),
        ):
            with self.subTest(sentence=sentence):
                deduplicated = MODULE.deduplicate_sentence_events(self.events(sentence))
                self.assertEqual(len(deduplicated), 1)
                self.assertEqual(deduplicated[0]["amount"], expected)

    def test_past_period_estimate_is_not_forward_guidance(self):
        sentence = (
            "We estimate the extra week last year was approximately $760 million in revenue "
            "and approximately $0.20 of non-GAAP diluted EPS."
        )

        self.assertIsNotNone(MODULE.HISTORICAL_GUIDANCE.search(sentence))

    def test_first_quarter_of_fiscal_year_is_quarter_scope(self):
        event = self.event(
            "For the first quarter of fiscal year 2027, we expect revenue between "
            "$10.3 billion and $10.8 billion."
        )

        self.assertEqual(event["amount"], 10_550)
        self.assertEqual(event["guidance_scope"], "quarter")

    def test_fy_scope_near_amount_outranks_earlier_quarter_reference(self):
        event = self.event(
            "After a transaction we expect to close later in Q3, we are increasing our FY 2026 "
            "subscription revenue guidance to $8.815 billion."
        )

        self.assertEqual(event["guidance_scope"], "full_year")
        self.assertEqual(event["guidance_subject"], "segment_or_subset")

    def test_non_company_sales_and_market_revenue_are_labeled(self):
        asset_sales = self.event("The total asset sales that we project are still $1.9 billion by 2028.")
        market_revenue = self.event(
            "We estimate the NAND market will exceed $300 billion in revenue in calendar year 2027."
        )

        self.assertEqual(asset_sales["guidance_subject"], "non_company_or_non_periodic")
        self.assertEqual(asset_sales["guidance_scope"], "multi_year_target")
        self.assertEqual(market_revenue["guidance_subject"], "non_company_or_non_periodic")

    def test_named_segment_revenues_are_not_company_total(self):
        events = self.events(
            "Within this outlook, we expect Semiconductor Systems revenue of around $6.9 billion, "
            "AGS revenue of about $1.75 billion, and other revenue of around $300 million."
        )

        self.assertEqual([event["amount"] for event in events], [6_900, 1_750, 300])
        self.assertTrue(all(event["guidance_subject"] == "segment_or_subset" for event in events))

    def test_segment_named_before_expect_revenue_is_not_company_total(self):
        event = self.event(
            "Shifting now to our Health Services segment, we expect revenue of approximately "
            "$185 billion, primarily driven by growth at Caremark."
        )

        self.assertEqual(event["amount"], 185_000)
        self.assertEqual(event["guidance_subject"], "segment_or_subset")

    def test_numeric_product_revenue_is_segment_evidence(self):
        events = self.events(
            "Looking ahead to Q4, we expect a substantial sequential increase in our data center "
            "revenue driven by growth in 400G revenue, as well as increased 800G revenue."
        )
        deduplicated = MODULE.deduplicate_sentence_events(events)

        self.assertTrue(deduplicated)
        self.assertTrue(all(event["guidance_subject"] == "segment_or_subset" for event in deduplicated))

    def test_direct_company_total_outranks_an_earlier_segment_reference(self):
        event = self.event(
            "After discussing the Health Services segment, we expect total company revenue "
            "of approximately $400 billion for the full year."
        )

        self.assertEqual(event["guidance_subject"], "company_total")

    def test_total_or_net_revenue_inside_named_segment_remains_segment(self):
        for sentence in (
            "Within the Healthcare Benefits segment, we expect total revenues in the range of "
            "$74.1 billion to $74.8 billion.",
            "For the international segment, net sales are expected to be approximately $275 million.",
        ):
            with self.subTest(sentence=sentence):
                event = self.event(sentence)
                self.assertEqual(event["guidance_subject"], "segment_or_subset")

    def test_company_total_revenue_can_be_driven_by_segments(self):
        event = self.event(
            "We now expect full-year total company revenues of at least $397 billion, "
            "driven by increases across all segments."
        )

        self.assertEqual(event["guidance_subject"], "company_total")

    def test_revenue_deltas_and_business_contributions_are_not_company_levels(self):
        for sentence in (
            "We estimate that we may lose revenues of between $240 million and $270 million "
            "on an annualized basis.",
            "We expect this new business to contribute annual revenues of approximately $390 million.",
            "We expect this business to contribute approximately $20 million in annual revenues.",
            "We expect $105 million per quarter of incremental revenue from Transco.",
        ):
            with self.subTest(sentence=sentence):
                event = self.event(sentence)
                self.assertEqual(event["guidance_subject"], "non_company_or_non_periodic")

    def test_actual_result_above_prior_guidance_is_not_forward_guidance(self):
        sentence = (
            "In the fourth quarter, we exceeded the high end of our guidance for both revenue "
            "and Adjusted EBITDA, achieving $953 million in total revenue and $476 million in Adjusted EBITDA."
        )

        self.assertIsNotNone(MODULE.HISTORICAL_GUIDANCE.search(sentence))

    def test_named_retail_business_revenue_is_segment_evidence(self):
        event = self.event(
            "For the year, we expect retail long-term care revenue to be between "
            "$85.3 billion and $86.8 billion."
        )

        self.assertEqual(event["guidance_subject"], "segment_or_subset")

    def test_annualized_run_rate_is_not_current_full_year_guidance(self):
        event = self.event(
            "We plan to grow our annualized sales run rate to $20 billion by the end of 2026."
        )

        self.assertEqual(event["guidance_scope"], "multi_year_target")
        self.assertEqual(event["guidance_subject"], "non_company_or_non_periodic")

    def test_segment_operating_income_and_discontinued_fcf_are_not_company_guidance(self):
        segment = self.event(
            "For the full year, the Health Services segment expects adjusted operating income of $7 billion.",
            metric="operating_income_guidance",
        )
        discontinued = self.event(
            "We expect $250 million of free cash flow from our discontinued operations in full year 2025.",
            metric="free_cash_flow_guidance",
        )

        self.assertEqual(segment["guidance_subject"], "segment_or_subset")
        self.assertEqual(discontinued["guidance_subject"], "segment_or_subset")

    def test_company_operating_income_and_fcf_levels_are_retained(self):
        operating_income = self.event(
            "In aggregate, we expect full-year enterprise adjusted operating income of $16.75 billion.",
            metric="operating_income_guidance",
        )
        free_cash_flow = self.event(
            "We expect aggregate company free cash flow of approximately $2.5 billion in 2026.",
            metric="free_cash_flow_guidance",
        )

        self.assertEqual(operating_income["guidance_subject"], "company_total")
        self.assertEqual(free_cash_flow["guidance_subject"], "company_total")

    def test_parallel_ebitda_and_operating_income_amounts_follow_metric_order(self):
        event = self.event(
            "EBITDA and operating income are expected to be approximately $2.6 billion "
            "and $1.9 billion at the midpoint, respectively.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["amount"], 1_900)

    def test_parallel_metric_list_without_respectively_follows_metric_order(self):
        event = self.event(
            "EBITDA and operating income are expected to be approximately $2.6 billion "
            "and $1.9 billion at the midpoint.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["amount"], 1_900)

    def test_trailing_sales_driver_does_not_break_parallel_amount_binding(self):
        event = self.event(
            "EBITDA and operating income are expected to be $2.4 billion and $1.6 billion "
            "at the midpoint, respectively, with strong year-over-year sales conversion.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["amount"], 1_600)

    def test_separate_ebitda_and_operating_income_ranges_do_not_cross_average(self):
        event = self.event(
            "We expect Adjusted EBITDA of $1.66 billion-$1.68 billion and adjusted operating "
            "income of $205 million-$225 million.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["amount"], 215)

    def test_named_services_revenue_carries_segment_subject_to_operating_income(self):
        event = self.event(
            "Moving to the segments for the full year, we expect Pharmacy Services revenues "
            "of $138 billion, with adjusted operating income of $5.25 billion.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["guidance_subject"], "segment_or_subset")

    def test_consolidated_operating_income_outranks_segment_driver_context(self):
        event = self.event(
            "Despite pressure in the Health Services segment, we expect consolidated operating "
            "income of $16.75 billion for the full year.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["guidance_subject"], "company_total")

    def test_operating_income_delta_is_not_an_absolute_company_level(self):
        event = self.event(
            "We estimate this will decrease full-year operating income by approximately $400 million.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["guidance_subject"], "non_company_or_non_periodic")

    def test_company_operating_income_delta_remains_non_periodic(self):
        event = self.event(
            "We estimate this will decrease company operating income by approximately $400 million.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["guidance_subject"], "non_company_or_non_periodic")

    def test_operating_profit_guarantee_is_not_company_profit_guidance(self):
        event = self.event(
            "We expect to benefit from approximately $27 million of operating profit "
            "guarantees this year.",
            metric="operating_income_guidance",
        )

        self.assertEqual(event["guidance_subject"], "non_company_or_non_periodic")


class CurrencyGuidanceTests(unittest.TestCase):
    def event(self, sentence):
        metrics = MODULE.metric_names(sentence)
        name, position = next(item for item in metrics if item[0] == "revenue_guidance")
        return MODULE.extract_event("TBBB", "Q22026", "2026-08-01",
                                    "https://example.test/issuer-release", Path("fixture.txt"),
                                    "Fixture CFO", sentence, name, position, metrics)

    def test_mxn_prefix_spellings_are_never_usd(self):
        for marker in ("MXN", "Ps.", "MX$", "MEX$", "Mexican pesos"):
            with self.subTest(marker=marker):
                event = self.event(f"We expect full year revenue of {marker} 80 billion.")
                self.assertEqual(event["amount"], 80_000)
                self.assertEqual(event["currency"], "MXN")

    def test_mxn_suffix_spellings(self):
        for marker in ("MXN", "Mexican pesos"):
            event = self.event(f"We expect full year revenue of 80 billion {marker}.")
            self.assertEqual(event["currency"], "MXN")
            self.assertEqual(event["amount"], 80_000)

    def test_currency_code_can_touch_amount_but_not_form_part_of_a_word(self):
        for marker, currency in (("MXN", "MXN"), ("USD", "USD"), ("GBP", "GBP"), ("EUR", "EUR")):
            with self.subTest(marker=marker):
                event = self.event(f"We expect full year revenue of {marker}80 billion.")
                self.assertEqual(event["currency"], currency)
                self.assertEqual(event["amount"], 80_000)
        self.assertIsNone(self.event("We expect full year revenue of AMXN80 billion.")["currency"])

    def test_mxn_shared_scale_ranges(self):
        for sentence in ("We expect full year revenue of MXN 80-84 billion.",
                         "We expect full year revenue of Ps. 80 to Ps. 84 billion.",
                         "We expect full year revenue of 80–84 billion Mexican pesos."):
            with self.subTest(sentence=sentence):
                event = self.event(sentence)
                self.assertEqual(event["amount"], 82_000)
                self.assertEqual(event["currency"], "MXN")

    def test_repeated_scale_and_between_ranges(self):
        for sentence in ("We expect full year revenue of MXN 80 billion to MXN 84 billion.",
                         "We expect full year revenue between Ps. 80 billion and Ps. 84 billion."):
            event = self.event(sentence)
            self.assertEqual(event["amount"], 82_000)
            self.assertEqual(event["currency"], "MXN")

    def test_explicit_us_currency_is_preserved(self):
        for marker in ("US$", "USD", "U.S. dollars"):
            event = self.event(f"We expect full year revenue of {marker} 4 billion.")
            self.assertEqual(event["currency"], "USD")

    def test_bare_dollar_requires_reporting_currency(self):
        event = self.event("We expect full year revenue of $80 billion.")
        self.assertIsNone(event["currency"])
        self.assertEqual(event["amount"], 80_000)
        self.assertEqual(event["currency_resolution"]["status"], "source_currency_required")

    def test_peso_evidence_disambiguates_dollar(self):
        event = self.event("In Mexican pesos, we expect full year revenue of $80 billion.")
        self.assertEqual(event["currency"], "MXN")

    def test_mixed_currency_range_is_not_averaged(self):
        event = self.event("We expect full year revenue between MXN 80 billion and USD 4 billion.")
        self.assertIsNone(event["amount"])
        self.assertIsNone(event["currency"])
        self.assertEqual(event["quality_status"], "currency_conflict")

    def test_conflicting_prefix_suffix_fails_closed(self):
        event = self.event("We expect full year revenue of USD 80 billion Mexican pesos.")
        self.assertIsNone(event["amount"])
        self.assertEqual(event["quality_status"], "currency_conflict")

    def test_ps_abbreviation_does_not_split_the_amount_from_metric(self):
        sentence = "We expect full year revenue of Ps. 80 billion to Ps. 84 billion."
        self.assertEqual(list(MODULE.sentences(sentence)), [sentence])

    def test_percentage_only_needs_no_currency(self):
        event = self.event("We expect full year revenue growth of 15%.")
        self.assertIsNone(event["amount"])
        self.assertIsNone(event["currency"])
        self.assertEqual(event["growth_yoy"], 15)
        self.assertEqual(event["quality_status"], "clear")

    def test_mxn_plus_minus_uses_center(self):
        event = self.event("We expect full year revenue of MXN 80 billion plus or minus Ps. 100 million.")
        self.assertEqual(event["amount"], 80_000)
        self.assertEqual(event["currency"], "MXN")

    def test_actual_tbbb_fy2026_guidance_does_not_become_a_2025_money_forecast(self):
        fixture = json.loads((Path(__file__).parents[1] / "server/fixtures/tbbb-fy2026-guidance.json").read_text())
        sentence = fixture["evidence"]
        metrics = MODULE.metric_names(sentence)
        name, position = next(item for item in metrics if item[0] == "revenue_guidance")
        event = MODULE.extract_event(fixture["ticker"], fixture["fiscal_period"], fixture["observed_at"],
                                     fixture["source_url"], Path("official-sec-fixture"), "Issuer management",
                                     sentence, name, position, metrics)
        for key, expected in fixture["expected"].items():
            self.assertEqual(event[key], expected, key)
        self.assertEqual(event["fiscal_period"], "Q42025")
        self.assertEqual(event["observed_at"], "2026-03-11")


class OwnedMonetaryRangeTests(unittest.TestCase):
    def event(self, quote, metric):
        metrics = MODULE.metric_names(quote)
        position = next(position for name, position in metrics if name == metric)
        return MODULE.extract_event("TEST", "Q12026", "2026-04-01", "https://example.test/original", Path("original.txt"), "Issuer CFO", quote, metric, position, metrics)

    def test_capex_cannot_borrow_the_previous_net_interest_expense_range(self):
        quote = "Additionally, we now expect the following for 2022: an adjusted annual effective tax rate of 16%-18%, net interest expense in the range of $250 million-$270 million, capital expenditures in the range of $650 million-$750 million, and depreciation and amortization of approximately $420 million."
        event = self.event(quote, "capex_guidance")
        self.assertEqual(event["amount"], 700)
        self.assertEqual([v["value"] for v in event["selected_values"]], [650, 750])

    def test_breakeven_range_preserves_negative_and_zero_endpoints(self):
        quote = "For the second quarter, we expect adjusted revenues to be within the range of $151 million-$156 million, and adjusted EBITDA to be in the range of negative $4 million to break even."
        event = self.event(quote, "ebitda_guidance")
        self.assertEqual(event["amount"], -2)
        self.assertEqual([v["value"] for v in event["selected_values"]], [-4, 0])
        self.assertEqual(self.event(quote, "revenue_guidance")["amount"], 153.5)
        self.assertEqual(self.event("For the second quarter, we expect EBITDA of negative $4 million, with a goal to reach break even next year.", "ebitda_guidance")["amount"], -4)

    def test_expense_and_restructuring_payment_targets_do_not_become_revenue_or_fcf(self):
        for quote, metric in [
            ("However, taking into account our current revenue outlook for the year, we are now planning for operating expense to average $340 million-$345 million per quarter in fiscal year 2024, down from our previous guidance of $355 million per quarter.", "revenue_guidance"),
            ("In terms of free cash flow, we expect Q2 to look similar to last year, including cash restructuring payments of approximately $100 million.", "free_cash_flow_guidance"),
        ]:
            event = self.event(quote, metric)
            self.assertIsNone(event["amount"], quote)
            self.assertEqual(event["evidence_excerpt"], quote)
        self.assertEqual(self.event("We expect full year free cash flow of $600 million, after restructuring payments of $100 million.", "free_cash_flow_guidance")["amount"], 600)

    def test_margin_and_customer_growth_cannot_become_revenue_growth(self):
        quote = "I mentioned earlier, I think, on this call, we expect Q3 to be about maybe 10%-10.5% margins, flattish year over year, but growing to about 12% in Q4, reflecting stronger sales, but also more of the productivity actions that we've been implementing all year."
        self.assertIsNone(self.event(quote, "revenue_guidance")["growth_yoy"])
        self.assertIsNone(self.event("We continue to forecast 2% customer growth for 2016, which equates to approximately $25 million-$30 million in incremental base revenue annually.", "revenue_guidance")["growth_yoy"])
        self.assertEqual(self.event("We expect full year revenue growth of 8%, compared with customer growth of 2%.", "revenue_guidance")["growth_yoy"], 8)


class PointInTimeCutoffTests(unittest.TestCase):
    def test_cutoff_requires_source_date_or_explicit_legacy_opt_in(self):
        with sqlite3.connect(":memory:") as connection:
            with self.assertRaisesRegex(ValueError, "as_of_cutoff is required"):
                MODULE.resolve_as_of_cutoff(connection)
            self.assertIsNone(MODULE.resolve_as_of_cutoff(connection, allow_legacy=True))
            self.assertEqual(MODULE.resolve_as_of_cutoff(connection, "2026-09-05"), "2026-09-05")

    def test_existing_cutoff_cannot_be_widened_or_changed(self):
        with sqlite3.connect(":memory:") as connection:
            connection.execute("CREATE TABLE pit_source_metadata (key TEXT PRIMARY KEY, value TEXT)")
            connection.execute("INSERT INTO pit_source_metadata VALUES ('as_of_cutoff','2026-09-05')")
            self.assertEqual(MODULE.resolve_as_of_cutoff(connection), "2026-09-05")
            self.assertEqual(MODULE.resolve_as_of_cutoff(connection, "2026-09-05"), "2026-09-05")
            for cutoff in ("2026-09-06", "2026-09-04", "2026-09-05T00:00:00", "2026-02-30"):
                with self.subTest(cutoff=cutoff), self.assertRaises(ValueError):
                    MODULE.resolve_as_of_cutoff(connection, cutoff, allow_legacy=True)

    def test_future_transcript_is_excluded_and_observation_date_is_preserved(self):
        text = "Earnings Call: Q2 2026\n2026-09-06\nhttps://example.test/original\n"
        quote = "We expect full year revenue of USD 5 billion."
        with mock.patch.object(Path, "read_text", return_value=text), mock.patch.object(MODULE, "speaker_sections", return_value=[("Chief Financial Officer", quote)]):
            period, events = MODULE.extract_file("TEST", Path("original.txt"), "2026-09-05")
            self.assertIsNone(period)
            self.assertEqual(events, [])
            for cutoff in ("2026-09-06", "2026-09-07"):
                period, events = MODULE.extract_file("TEST", Path("original.txt"), cutoff)
                self.assertEqual(period, "Q22026")
                self.assertTrue(events)
                self.assertEqual(events[0]["observed_at"], "2026-09-06")
                self.assertEqual(events[0]["source_url"], "https://example.test/original")


class UniqueTranscriptPersistenceTests(unittest.TestCase):
    def event(self):
        sentence = "We expect CapEx in 2021 to be around $800 million."
        metrics = MODULE.metric_names(sentence)
        metric, position = next(item for item in metrics if item[0] == "capex_guidance")
        return MODULE.extract_event("IP", "Q42020", "2021-01-28", "https://stockanalysis.com/stocks/ip/transcripts/268771-q4-2020/", Path("IP/earnings_IP_Q42020_268771-q4-2020.txt"), "Issuer CFO", sentence, metric, position, metrics)

    def test_real_repeated_capex_sentence_is_one_identical_persisted_event(self):
        with sqlite3.connect(":memory:") as connection:
            MODULE.ensure_schema(connection)
            event = self.event()
            self.assertTrue(MODULE.persist_unique_transcript_event(connection, event))
            self.assertFalse(MODULE.persist_unique_transcript_event(connection, copy.deepcopy(event)))
            self.assertFalse(MODULE.persist_unique_transcript_event(connection, dict(reversed(list(event.items())))))
            self.assertEqual(connection.execute("SELECT count(*) FROM pit_guidance_events").fetchone()[0], 1)

    def test_same_id_with_different_payload_fails_closed(self):
        for change in ({"amount": 900}, {"guidance_scope": "quarter"}, {"per_share_value": 2.0},
                       {"source_url": "https://example.test/other"}, {"source_file": "other.txt"},
                       {"actual_or_guidance": "actual"}):
            with self.subTest(change=change), sqlite3.connect(":memory:") as connection:
                MODULE.ensure_schema(connection)
                event = self.event()
                MODULE.persist_unique_transcript_event(connection, event)
                with self.assertRaisesRegex(ValueError, "Conflicting guidance event ID"):
                    MODULE.persist_unique_transcript_event(connection, {**event, **change})
                self.assertEqual(json.loads(connection.execute("SELECT payload_json FROM pit_guidance_events").fetchone()[0]), event)

    def test_typed_column_or_other_source_collision_cannot_hide_in_payload(self):
        for column, value in (("amount", 999), ("source_type", "official_issuer_sec_filing")):
            with self.subTest(column=column), sqlite3.connect(":memory:") as connection:
                MODULE.ensure_schema(connection)
                event = self.event()
                MODULE.persist_unique_transcript_event(connection, event)
                connection.execute(f"UPDATE pit_guidance_events SET {column}=?", (value,))
                with self.assertRaisesRegex(ValueError, "Conflicting guidance event ID"):
                    MODULE.persist_unique_transcript_event(connection, event)

    def test_writer_rejects_non_transcript_source(self):
        with sqlite3.connect(":memory:") as connection:
            MODULE.ensure_schema(connection)
            with self.assertRaisesRegex(ValueError, "another guidance source type"):
                MODULE.persist_unique_transcript_event(connection, {**self.event(), "source_type": "official_issuer_sec_filing"})

    def test_cli_reports_occurrences_separately_from_unique_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "IP").mkdir()
            (root / "IP" / "fixture.txt").touch()
            database = root / "source.sqlite"
            with sqlite3.connect(database) as connection:
                connection.execute("CREATE TABLE pit_source_metadata (key TEXT PRIMARY KEY, value TEXT)")
                connection.execute("INSERT INTO pit_source_metadata VALUES ('as_of_cutoff','2026-09-05')")
            event = self.event()
            args = SimpleNamespace(source_db=database, target_db=root / "unused.sqlite", transcript_root=root)
            with mock.patch.object(MODULE, "parse_args", return_value=args), mock.patch.object(MODULE, "target_tickers", return_value=[("IP", "IP")]), mock.patch.object(MODULE, "extract_file", return_value=("Q42020", [event, copy.deepcopy(event), copy.deepcopy(event)])), contextlib.redirect_stdout(io.StringIO()) as output:
                MODULE.main()
            result = json.loads(output.getvalue())
            self.assertEqual((result["extractedOccurrences"], result["events"], result["duplicateOccurrences"]), (3, 1, 2))
            with sqlite3.connect(database) as connection:
                self.assertEqual(connection.execute("SELECT count(*) FROM pit_guidance_events").fetchone()[0], 1)
                self.assertEqual(connection.execute("SELECT guidance_events FROM pit_guidance_coverage WHERE ticker='IP'").fetchone()[0], 1)

    def test_cli_collision_rolls_back_deletion_and_preserves_official_source(self):
        for cross_source in (False, True):
            with self.subTest(cross_source=cross_source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "IP").mkdir()
                (root / "IP" / "fixture.txt").touch()
                database = root / "source.sqlite"
                event = self.event()
                with sqlite3.connect(database) as connection:
                    MODULE.ensure_schema(connection)
                    connection.execute("CREATE TABLE pit_source_metadata (key TEXT PRIMARY KEY, value TEXT)")
                    connection.execute("INSERT INTO pit_source_metadata VALUES ('as_of_cutoff','2026-09-05')")
                    MODULE.persist_unique_transcript_event(connection, {**event, "id": "retained-transcript"})
                    MODULE.persist_unique_transcript_event(connection, {**event, "id": event["id"] if cross_source else "retained-official"})
                    connection.execute("UPDATE pit_guidance_events SET source_type='official_issuer_sec_filing' WHERE id!=?", ("retained-transcript",))
                    connection.execute("INSERT INTO pit_guidance_coverage VALUES ('IP',1,1,1,1,'covered','prior coverage')")
                    before = connection.execute("SELECT * FROM pit_guidance_events ORDER BY id").fetchall()
                    coverage_before = connection.execute("SELECT * FROM pit_guidance_coverage").fetchall()
                args = SimpleNamespace(source_db=database, target_db=root / "unused.sqlite", transcript_root=root)
                events = [event] if cross_source else [event, {**event, "amount": 999}]
                with mock.patch.object(MODULE, "parse_args", return_value=args), mock.patch.object(MODULE, "target_tickers", return_value=[("IP", "IP")]), mock.patch.object(MODULE, "extract_file", return_value=("Q42020", events)):
                    with self.assertRaisesRegex(ValueError, "Conflicting guidance event ID"):
                        MODULE.main()
                with sqlite3.connect(database) as connection:
                    self.assertEqual(connection.execute("SELECT * FROM pit_guidance_events ORDER BY id").fetchall(), before)
                    self.assertEqual(connection.execute("SELECT * FROM pit_guidance_coverage").fetchall(), coverage_before)


if __name__ == "__main__":
    unittest.main()
