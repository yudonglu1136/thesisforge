import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('harvest', Path(__file__).with_name('harvest-all-local-prices.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PriceValidation(unittest.TestCase):
    def payload(self):
        return {'chart': {'result': [{'meta': {'symbol':'ANET','currency':'USD','instrumentType':'EQUITY'},
            'timestamp':[1788998400], 'indicators': {'quote':[{'open':[100.0],'high':[110.0],'low':[90.0],
            'close':[105.0],'volume':[100]}], 'adjclose':[{'adjclose':[103.0]}]}}]}}

    def test_valid_close(self):
        rows, rejected, _, _ = module.parse_chart('ANET',self.payload(),'2026-09-01','2026-09-10')
        self.assertEqual(len(rows),1);self.assertFalse(rejected)

    def test_bad_close_never_becomes_price(self):
        p=self.payload();p['chart']['result'][0]['indicators']['quote'][0]['close']=[500.0]
        with self.assertRaisesRegex(ValueError,'no_valid'): module.parse_chart('ANET',p,'2026-09-01','2026-09-10')

    def test_open_quarantine_is_not_close_rewrite(self):
        p=self.payload();p['chart']['result'][0]['indicators']['quote'][0]['open']=[500.0]
        rows,_,_,_=module.parse_chart('ANET',p,'2026-09-01','2026-09-10')
        self.assertIsNone(rows[0][1]);self.assertEqual(rows[0][4],105.0);self.assertEqual(rows[0][-1],'open_quarantined')

    def test_identity_must_match(self):
        with self.assertRaisesRegex(ValueError,'identity'): module.parse_chart('APH',self.payload(),'2026-09-01','2026-09-10')


if __name__=='__main__': unittest.main()
