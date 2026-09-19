import copy
import importlib.util
from pathlib import Path
import unittest

SPEC=importlib.util.spec_from_file_location('direct',Path(__file__).with_name('validate_csgp_ferg_currency_primary.py'))
MODULE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MODULE)

class ExactDirectTests(unittest.TestCase):
    def make(self,ticker):
        spec=MODULE.REVIEWED[ticker]
        source_id,date=next(iter(spec['events'].items()))
        proof={k:spec[k] for k in ['cik','availableAt','accession','documentSha256']}
        proof.update(sourceUrl=f"https://www.sec.gov/Archives/edgar/data/{int(spec['cik'])}/{spec['accession'].replace('-','')}/{spec['name']}",form='10-K',inference=False,quotes=[spec['declaration'],spec['owner']])
        return dict(ticker=ticker,sourceId=source_id,observedAt=date),proof

    def test_six_exact_event_bindings(self):
        for ticker,spec in MODULE.REVIEWED.items():
            for source_id,date in spec['events'].items():
                event,proof=self.make(ticker)
                MODULE.validate_metadata({**event,'sourceId':source_id,'observedAt':date},proof)

    def test_unknown_events_and_dates(self):
        for ticker in MODULE.REVIEWED:
            event,proof=self.make(ticker)
            for key,value in [('sourceId','other'),('observedAt','2026-01-01')]:
                with self.subTest(ticker=ticker,key=key),self.assertRaises(ValueError):MODULE.validate_metadata({**event,key:value},proof)

    def test_future_and_wrong_identity(self):
        for ticker in MODULE.REVIEWED:
            event,proof=self.make(ticker)
            for key,value in [('cik','0002011641'),('availableAt','2030-01-01'),('documentSha256','0'*64),('form','8-K'),('inference',True)]:
                with self.subTest(ticker=ticker,key=key),self.assertRaises(ValueError):MODULE.validate_metadata(event,{**proof,key:value})

    def test_revenue_subsidiary_and_wrong_owner_rejected(self):
        for ticker in MODULE.REVIEWED:
            event,proof=self.make(ticker)
            for value in ['Our revenue is earned in U.S. dollars.','Our subsidiary functional currency is USD.']:
                changed=copy.deepcopy(proof);changed['quotes'][0]=value
                with self.assertRaises(ValueError):MODULE.validate_metadata(event,changed)
            changed=copy.deepcopy(proof);changed['quotes'][1]='Another issuer'
            with self.assertRaises(ValueError):MODULE.validate_metadata(event,changed)

    def test_original_header_semantics(self):
        for ticker,spec in MODULE.REVIEWED.items():
            text=f"SEC Accession No. {spec['accession']} Filing Date {spec['availableAt']} Form 10-K CIK : {spec['cik']} {spec['name']}"
            MODULE.validate_header(text,spec)
            for old,new in [(spec['cik'],'0002011641'),(spec['availableAt'],'2030-01-01'),(spec['accession'],'unknown')]:
                with self.assertRaises(ValueError):MODULE.validate_header(text.replace(old,new),spec)

if __name__=='__main__':unittest.main()
