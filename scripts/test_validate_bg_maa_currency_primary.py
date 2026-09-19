import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("statement_units", Path(__file__).with_name("validate_bg_maa_currency_primary.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OriginalStatementUnitTests(unittest.TestCase):
    def setUp(self):
        records = json.loads((Path(__file__).parent.parent / "server/fixtures/event-guidance-currency-evidence-bg-maa.json").read_text())
        self.proof = next(r for r in records if r["ticker"] == "MAA")["contract"]["proof"]
        fragments = self.proof["xbrlStatementEvidence"]["fragments"]
        self.xml = '<xbrli:xbrl xmlns:xbrli="http://www.xbrl.org/2003/instance" xmlns:xbrldi="http://xbrl.org/2006/xbrldi" xmlns:us-gaap="http://fasb.org/us-gaap/2018-01-31">' + ''.join(f["raw"] for f in fragments) + '</xbrli:xbrl>'

    def test_real_parent_usd_and_eps_per_share_units(self):
        facts = module.validate_maa_original_xml(self.xml)
        self.assertEqual(len(facts), 4)
        self.assertEqual(next(f.attrib["unitRef"] for n, f in facts if n == "EarningsPerShareDiluted"), "usdPerShare")

    def test_lp_or_business_segment_cannot_substitute(self):
        for replacement in ['srt:OperatingSegmentsMember', 'us-gaap:LimitedPartnerMember']:
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                module.validate_maa_original_xml(self.xml.replace('>srt:ParentCompanyMember<', '>' + replacement + '<'))

    def test_changed_cik_period_or_currency_rejected(self):
        for old, new in [('0000912595','0000912596'), ('2018-12-31','2019-12-31'), ('iso4217:USD','iso4217:CAD'), ('>xbrli:shares<','>xbrli:pure<')]:
            with self.subTest(new=new), self.assertRaises(ValueError):
                module.validate_maa_original_xml(self.xml.replace(old, new))

    def test_eps_million_unit_or_duplicate_fact_rejected(self):
        for raw in [self.xml.replace('unitRef="usdPerShare"', 'unitRef="usd"'), self.xml.replace('</xbrli:xbrl>', self.proof["xbrlStatementEvidence"]["fragments"][-1]["raw"] + '</xbrli:xbrl>')]:
            with self.assertRaises(ValueError):
                module.validate_maa_original_xml(raw)


if __name__ == "__main__":
    unittest.main()
