import importlib.util
from pathlib import Path
import unittest

SPEC=importlib.util.spec_from_file_location('avav',Path(__file__).with_name('validate_avav_statement_currency.py'))
MODULE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MODULE)

def synthetic_statement():
    # Synthetic quantities only; never issuer observations or release input.
    root='<xbrl xmlns="http://www.xbrl.org/2003/instance" xmlns:us-gaap="http://fasb.org/us-gaap/2020-01-31" xmlns:iso4217="http://www.xbrl.org/2003/iso4217">'
    root+='<unit id="usd"><measure>iso4217:USD</measure></unit><unit id="eps"><divide><unitNumerator><measure>iso4217:USD</measure></unitNumerator><unitDenominator><measure>shares</measure></unitDenominator></divide></unit>'
    for ident,period in [('instant','<instant>2020-04-30</instant>'),('annual','<startDate>2019-05-01</startDate><endDate>2020-04-30</endDate>')]:
        root+=f'<context id="{ident}"><entity><identifier scheme="http://www.sec.gov/CIK">0001368622</identifier></entity><period>{period}</period></context>'
    for i,name in enumerate(MODULE.NAMES):
        root+=f'<us-gaap:{name} contextRef="{"instant" if i==0 else "annual"}" unitRef="{"eps" if i==3 else "usd"}">1</us-gaap:{name}>'
    return root+'</xbrl>'

class StatementTests(unittest.TestCase):
    def test_four_parent_categories(self):self.assertEqual(len(MODULE.inspect_statement(synthetic_statement())[0]),4)
    def test_wrong_unit_issuer_segment_future_period(self):
        raw=synthetic_statement()
        for before,after in [('iso4217:USD','iso4217:CAD'),('0001368622','0000000001'),('</entity>','<segment>subsidiary</segment></entity>'),('2020-04-30','2021-04-30'),('2019-05-01','2020-02-01')]:
            with self.subTest(before=before),self.assertRaises(ValueError):MODULE.inspect_statement(raw.replace(before,after))
    def test_wrong_namespace_not_gaap(self):
        with self.assertRaises(ValueError):MODULE.inspect_statement(synthetic_statement().replace('http://fasb.org/us-gaap/2020-01-31','https://fake.invalid'))
    def test_missing_category(self):
        raw=synthetic_statement();name=MODULE.NAMES[-1]
        with self.assertRaises(ValueError):MODULE.inspect_statement(raw.replace(f'<us-gaap:{name} contextRef="annual" unitRef="eps">1</us-gaap:{name}>',''))

if __name__=='__main__':unittest.main()
