"""Public synthetic regressions; no paid provider fixtures distributed."""
import copy
import importlib.util
from pathlib import Path
import unittest


def load(name, filename):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(filename))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


capture=load('crdo_capture','build-crdo-economic-evidence.py')
review=load('crdo_review','review-crdo-economic-source-bridge.py')
claims=load('crdo_claims','review-crdo-claims-evidence.py')


class SourceTests(unittest.TestCase):
    def test_ix_scale_sign_and_dimensions(self):
        html=b'''<html><xbrli:context id="q"><xbrli:period><xbrli:startDate>2026-05-03</xbrli:startDate><xbrli:endDate>2026-08-01</xbrli:endDate></xbrli:period></xbrli:context><xbrli:context id="segment"><xbrli:entity><xbrldi:explicitMember dimension="axis">member</xbrldi:explicitMember></xbrli:entity><xbrli:period><xbrli:instant>2026-08-01</xbrli:instant></xbrli:period></xbrli:context><xbrli:unit id="USD"><xbrli:measure>iso4217:USD</xbrli:measure></xbrli:unit><ix:nonFraction name="us-gaap:Cash" contextRef="q" unitRef="USD" scale="3" sign="-">1,234</ix:nonFraction><ix:nonFraction name="segment:Cash" contextRef="segment" unitRef="USD" scale="3">7</ix:nonFraction></html>'''
        _,facts=capture.parse_ix(html)
        self.assertEqual(facts[0]['value'],-1234000)
        self.assertEqual(facts[0]['start'],'2026-05-03')
        self.assertFalse(facts[0]['dimensions'])
        self.assertTrue(facts[1]['dimensions'])

    def test_unknown_context_fails(self):
        with self.assertRaisesRegex(ValueError,'missing context'):
            capture.parse_ix(b'<ix:nonFraction contextRef="missing" unitRef="USD" name="test:value">3</ix:nonFraction>')

    def test_exact_fact_conflict_fails(self):
        doc={'filed':'2026-09-02','aggregateFacts':[{'tag':'a','value':1,'unit':'USD','start':None,'end':'2026-08-01'},{'tag':'a','value':2,'unit':'USD','start':None,'end':'2026-08-01'}]}
        with self.assertRaisesRegex(ValueError,'Conflicting'):
            review.fact(doc,'a','2026-08-01',instant=True)

    def test_cfo_license_and_sbc_each_subtracted_once(self):
        raw={'cfoM':90.231,'capexM':7.282,'sbcM':87.979,'licensePaymentsM':5.172,'evidence':[]}
        result=review.combine([(1,raw)],'quarter','2026-08-01')
        self.assertAlmostEqual(result['economicCashAfterLicenseAndSbcM'],-10.202)
        self.assertEqual(raw['cfoM'],90.231)

    def test_ttm_bridge_exact(self):
        current={'cfoM':90.231,'capexM':7.282,'sbcM':87.979,'licensePaymentsM':5.172,'evidence':[]}
        prior_year={'cfoM':464.292,'capexM':57.296,'sbcM':182.638,'licensePaymentsM':6.624,'evidence':[]}
        prior_quarter={'cfoM':54.168,'capexM':2.821,'sbcM':35.455,'licensePaymentsM':3.906,'evidence':[]}
        out=review.combine([(1,current),(1,prior_year),(-1,prior_quarter)],'ttm','2026-08-01')
        self.assertAlmostEqual(out['cfoM'],500.355)
        self.assertAlmostEqual(out['sbcM'],235.162)
        self.assertAlmostEqual(out['licensePaymentsM'],7.890)
        self.assertAlmostEqual(out['economicCashAfterLicenseAndSbcM'],195.546)

    def test_currency_not_inferred_from_sales_or_quote(self):
        doc={'form':'S-1','currencyParagraphs':['The majority of our sales are denominated in U.S. dollars.']}
        with self.assertRaises(StopIteration):review.currency_evidence(doc)

    def test_currency_conflict_blocks(self):
        doc={'form':'10-Q','aggregateFacts':[{'tag':tag,'unit':unit} for tag,unit in [('us-gaap:Assets','iso4217:USD'),('us-gaap:StockholdersEquity','iso4217:USD'),(review.TAGS['cfoM'],'iso4217:CAD')]]}
        with self.assertRaisesRegex(ValueError,'Currency'):
            review.currency_evidence(doc)

    def test_no_automatic_zero_for_absent_license(self):
        doc={'filed':'2026-09-02','tableText':['Cash flows from operating activities: Cash flows from financing activities: Proceeds 7 Effect of exchange rate 1']}
        with self.assertRaisesRegex(ValueError,'No reviewed'):
            review.cashflow_zero(doc,'2026-05-03','2026-08-01')

    def test_preapproved_absence_rejects_unmapped_debt_payment(self):
        doc={'filed':'2022-06-08','tableText':['Cash flows from operating activities: Cash flows from financing activities: Debt payment 7 Effect of exchange rate 1']}
        with self.assertRaisesRegex(ValueError,'Unmapped'):
            review.cashflow_zero(doc,'2021-05-01','2022-04-30')

    def test_customer_warrant_uses_exact_statement_precision(self):
        doc={'filed':'2022-03-10','url':'https://www.sec.gov/example','sha256':'abc','aggregateFacts':[
            {'tag':'crdo:ClassOfWarrantOrRightContraRevenue','start':'2021-05-01','end':'2022-01-31','value':407000,'decimals':'-3','context':'a'},
            {'tag':'crdo:ClassOfWarrantOrRightContraRevenue','start':'2021-05-01','end':'2022-01-31','value':400000,'decimals':'-5','context':'a'}]}
        amount,_=claims.contra_fact(doc,'2021-05-01','2022-01-31')
        self.assertEqual(amount,.407)

    def test_equal_precision_warrant_conflict_fails(self):
        doc={'aggregateFacts':[{'tag':'crdo:ClassOfWarrantOrRightContraRevenue','start':'2021-05-01','end':'2022-01-31','value':v,'decimals':'-3'} for v in [407000,408000]]}
        with self.assertRaisesRegex(ValueError,'Conflicting precise'):
            claims.contra_fact(doc,'2021-05-01','2022-01-31')

    def test_unreviewed_warrant_absence_not_zero(self):
        with self.assertRaisesRegex(ValueError,'No reviewed exact'):
            claims.contra_fact({'filed':'2025-09-04','aggregateFacts':[]},'2025-05-04','2025-08-02')


if __name__=='__main__':unittest.main()
