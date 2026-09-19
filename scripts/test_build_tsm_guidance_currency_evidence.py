import hashlib
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("tsm_currency", Path(__file__).with_name("build-tsm-guidance-currency-evidence.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
HTML = "<p>TSMC reports financial statements in NT dollars.</p><p>Based on the Company’s current business outlook, management expects the overall performance for second quarter 2024 to be as follows:</p><ul><li>Revenue is expected to be between US$19.6 billion and US$20.4 billion;</li></ul>"


class EventCurrencyEvidenceTests(unittest.TestCase):
    def inputs(self):
        row = dict(ticker="TSM", metric_name="revenue_guidance", id="test", observed_at="2024-04-18", fiscal_period="Q12024", amount=20000,
                   evidence_excerpt="We expect our Q2 revenue to be between $19.6 billion and $20.4 billion.", payload_json="{}")
        doc = dict(filed="2024-04-18", url="https://www.sec.gov/Archives/edgar/data/1046179/000104617924000046/primary.htm",
                   sha256=hashlib.sha256(HTML.encode()).hexdigest(), accession="0001046179-24-000046", textPath="fixture")
        return row, doc

    def test_usd_outlook_does_not_relabel_twd_financials(self):
        row, doc = self.inputs()
        result = MODULE.bind_event(row, doc, HTML)
        self.assertEqual(result["currency"], "USD")
        self.assertFalse(result["reportingCurrencyOverride"])
        self.assertEqual(result["primaryGuidance"]["midpointM"], 20000)
        self.assertEqual(result["originalQuote"], row["evidence_excerpt"])
        self.assertTrue(result["growthBasisReviewRequired"])

    def test_later_official_report_cannot_fix_earlier_quote(self):
        row, doc = self.inputs()
        doc["filed"] = "2024-07-18"
        with self.assertRaisesRegex(ValueError, "same filing date"):
            MODULE.bind_event(row, doc, HTML)

    def test_wrong_range_or_quarter_fails(self):
        row, doc = self.inputs()
        row["amount"] = 25000
        with self.assertRaisesRegex(ValueError, "disagree"):
            MODULE.bind_event(row, doc, HTML)
        row["amount"] = 20000
        row["fiscal_period"] = "Q22024"
        with self.assertRaisesRegex(ValueError, "next quarter"):
            MODULE.bind_event(row, doc, HTML)

    def test_bare_dollar_or_corrupt_document_cannot_prove_usd(self):
        with self.assertRaisesRegex(ValueError, "explicitly scoped"):
            MODULE.primary_guidance(HTML.replace("US$", "$"))
        row, doc = self.inputs()
        with self.assertRaisesRegex(ValueError, "hash"):
            MODULE.bind_event(row, doc, HTML + "changed")


if __name__ == "__main__":
    unittest.main()
