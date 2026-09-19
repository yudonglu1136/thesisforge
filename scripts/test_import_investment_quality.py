import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('quality', Path(__file__).with_name('import-investment-quality.py'))
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)

def raw(**kwargs):
    return dict(ticker='TEST',dimension='ART',date='2026-02-15',reportperiod='2025-12-31',
                fiscalperiod='2025-Q4',roic=.2,invcapavg=1000,ebit=200,revenue=1000,
                opinc=190,fcf=80,ncfo=100,netinc=80,capex=-20,**kwargs)

class QualityTests(unittest.TestCase):
    def test_formulas_and_ratio_units(self):
        row=quality.observation(raw(),'TEST')
        self.assertEqual(row[6:10],(.2,.19,.08,1.25))
        self.assertEqual(len(row),20)
    def test_no_restatement_or_healthy_row_substitution(self):
        first=raw();first['roic']=None
        later={**first,'date':'2026-03-01','roic':.8}
        rows=quality.first_reports([later,first,first])
        self.assertEqual(len(rows),1)
        self.assertIsNone(quality.observation(rows[0],'TEST')[6])
    def test_only_nonoverlapping_as_reported_fiscal_years(self):
        for dimension,period in [('MRT','2025-Q4'),('ARQ','2025-Q4'),('ART','2025-Q3')]:
            r={**raw(),'dimension':dimension,'fiscalperiod':period}
            self.assertIsNone(quality.observation(r,'TEST'))
    def test_capital_cash_and_availability_gates(self):
        for cap in [None,0,-1000]:
            self.assertIsNone(quality.observation({**raw(),'invcapavg':cap},'TEST')[6])
        self.assertIsNone(quality.observation({**raw(),'roic':20},'TEST')[6])
        self.assertIsNone(quality.observation({**raw(),'netinc':-80},'TEST')[9])
        self.assertIsNone(quality.observation({**raw(),'fcf':10000},'TEST')[8])
        self.assertIsNone(quality.observation({**raw(),'date':'2025-01-01'},'TEST'))
    def test_ambiguous_first_source_fails_closed(self):
        with self.assertRaises(ValueError):quality.first_reports([raw(),{**raw(),'roic':.4}])

if __name__=='__main__':unittest.main()
