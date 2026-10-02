import unittest
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from rule_daily_dependencies import rate_at,revalidate_qqq

class DependenciesTest(unittest.TestCase):
    def test_rates_are_dated_not_future_and_cannot_be_silently_stale(self):
        rows=[{'observation_date':'2026-09-29','DGS10':'4'},
              {'observation_date':'2026-10-01','DGS10':'9'}]
        self.assertEqual(rate_at(rows,'2026-09-30')['value'],.04)
        with self.assertRaisesRegex(ValueError,'stale'):rate_at(rows,'2026-10-20')
        with self.assertRaisesRegex(ValueError,'missing'):rate_at(rows,'2026-09-01')
        with self.assertRaisesRegex(ValueError,'conflicting'):rate_at(rows+[dict(rows[0],DGS10='5')],'2026-09-30')

    def test_qqq_requires_actual_same_identity_in_new_catalog(self):
        source={'version':'sec-qqq-disclosed-universe-v1','identityGeneration':'old','unresolved':[],
            'snapshots':[{'period':'2026-06-30','filed':'2026-08-20','sourceMemberCount':1,
              'members':[{'cusip':'123','permaticker':'1','tickers':['OLD']}]}]}
        result=revalidate_qqq(source,[('1','NEW','123')],'new','2026-09-30')
        self.assertEqual(result['snapshots'][0]['members'][0]['tickers'],['NEW'])
        self.assertEqual(source['identityGeneration'],'old')
        for rows in [[],[('2','NEW','123')],[('1','A','123'),('2','B','123')]]:
            with self.assertRaisesRegex(ValueError,'identity_changed'):revalidate_qqq(source,rows,'new','2026-09-30')

if __name__=='__main__':unittest.main()
