import hashlib
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("ipo_currency", Path(__file__).with_name("build-ipo-reporting-currency-evidence.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class IpoReportingCurrencyTests(unittest.TestCase):
    def test_direct_reporting_declarations(self):
        for quote in ["The reporting currency of the Company is the United States dollar (“USD”).",
                      "The reporting currency of the Company is the U.S. dollar.",
                      "Shopify reports in U.S. dollars and in accordance with U.S. GAAP"]:
            self.assertTrue(MODULE.declarations("<p>" + quote + "</p>"))

    def test_foreign_subsidiary_or_sales_contract_currency_is_not_reporting_proof(self):
        for text in ["The functional currency of the Company's foreign subsidiaries is the U.S. dollar.",
                     "Our sales contracts are denominated in U.S. dollars.",
                     "The Company translates foreign subsidiary assets into U.S. dollars."]:
            self.assertEqual(MODULE.declarations(text), [])

    def test_later_currency_fact_or_wrong_issuer_is_rejected(self):
        html = "<p>The reporting currency of the Company is the U.S. dollar.</p>"
        doc = dict(ticker="GTLB", cik="0001653482", filed="2021-10-14", form="424B4", accession="0001628280-21-020056",
                   url="https://www.sec.gov/Archives/edgar/data/1653482/000162828021020056/gitlab-424b4.htm",
                   documentSha256=hashlib.sha256(html.encode()).hexdigest(), htmlPath="fixture")
        self.assertEqual(MODULE.direct_proof(doc, "GTLB", "0001653482", "2021-12-06", html)["currency"], "USD")
        with self.assertRaisesRegex(ValueError, "Later"):
            MODULE.direct_proof(doc, "GTLB", "0001653482", "2021-10-13", html)
        with self.assertRaisesRegex(ValueError, "issuer"):
            MODULE.direct_proof(doc, "OTHER", "0001653482", "2021-12-06", html)


if __name__ == "__main__":
    unittest.main()
