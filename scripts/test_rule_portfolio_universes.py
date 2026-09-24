import unittest
from rule_portfolio_universes import sp500_members_at, qqq_members_at, select_universe
import pandas as pd
import importlib.util
from pathlib import Path


class UniverseTests(unittest.TestCase):
    def test_sec_parser_verifies_fund_identity_complete_holdings_and_unique_securities(self):
        spec=importlib.util.spec_from_file_location('sec_qqq',Path(__file__).with_name('build-sec-qqq-universe.py'))
        module=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        rows=''.join(f'<invstOrSec><name>Stock {i}</name><cusip>{i:09d}</cusip><assetCat>EC</assetCat>'
            '<payoffProfile>Long</payoffProfile><valUSD>100</valUSD></invstOrSec>' for i in range(100))
        raw='<edgarSubmission xmlns="http://www.sec.gov/edgar/nport"><genInfo><regCik>1067839</regCik>' \
            '<repPdDate>2020-03-31</repPdDate></genInfo><invstOrSecs>'+rows+'</invstOrSecs></edgarSubmission>'
        period, holdings=module.parse_holdings(raw)
        self.assertEqual(period,'2020-03-31')
        self.assertEqual(len(holdings),100)
        for bad in [raw.replace('1067839','123'),raw.replace('000000099','000000001'),
                    raw.replace('<assetCat>EC</assetCat>','<assetCat>DBT</assetCat>')]:
            with self.assertRaises(ValueError): module.parse_holdings(bad)

    def test_qqq_uses_disclosure_not_report_date_and_ignores_late_old_amendment(self):
        def snapshot(period, filed, tag):
            return dict(period=period, filed=filed, accession=tag, sourceUrl='sec:'+tag,
                sourceSha256='a'*64, sourceMemberCount=100,
                members=[dict(permaticker=f'{tag}{i}') for i in range(100)])
        rows = [snapshot('2019-09-30','2019-11-29','old'),
                snapshot('2019-12-31','2020-02-28','new'),
                snapshot('2019-09-30','2020-03-01','amend')]
        ids, e = qqq_members_at(rows, '2019-12-31')
        self.assertIn('old0', ids)
        self.assertEqual(e['filed'], '2019-11-29')
        self.assertIn('new0', qqq_members_at(rows, '2020-03-31')[0])
        for cutoff in ['2019-10-31', '2021-03-31']:
            with self.assertRaisesRegex(ValueError, 'membership_snapshot'):
                qqq_members_at(rows, cutoff)
        self.assertIn('old0', qqq_members_at(rows, '2020-02-28')[0])
        rows[1]['members'].pop()
        with self.assertRaisesRegex(ValueError, 'membership_incomplete'):
            qqq_members_at(rows, '2020-03-31')

    def test_membership_uses_effective_events_not_future_or_current_list(self):
        rows = [('2012-12-31', 'historical', 'A'), ('2012-12-31', 'historical', 'B'),
                ('2013-02-01', 'removed', 'A'), ('2013-02-01', 'added', 'C'),
                ('2013-04-01', 'added', 'FUTURE'), ('2026-09-21', 'current', 'TODAY')]
        members, evidence = sp500_members_at(rows, '2013-03-28', minimum=2)
        self.assertEqual(members, {'B', 'C'})
        self.assertEqual(evidence['snapshotDate'], '2012-12-31')
        self.assertEqual(evidence['effectiveThrough'], '2013-03-28')
        self.assertEqual(evidence['memberCount'], 2)
        self.assertEqual(evidence, sp500_members_at(list(reversed(rows)), '2013-03-28', minimum=2)[1])

    def test_missing_or_stale_membership_does_not_fall_back_to_all_market(self):
        for rows in [[], [('2011-12-31', 'historical', 'A')]]:
            with self.assertRaisesRegex(ValueError, 'membership'):
                sp500_members_at(rows, '2013-03-28', minimum=1)

    def test_only_selected_population_is_ranked_without_changing_the_base(self):
        frame = pd.DataFrame({'q': ['2013-03-31']*3, 'ticker': ['A', 'B', 'C'], 'value': [1, 2, 3]})
        selected = select_universe(frame, {'2013-03-31': {'A', 'C'}})
        self.assertEqual(selected.ticker.tolist(), ['A', 'C'])
        self.assertEqual(selected.value.rank(pct=True).tolist(), [.5, 1.])
        self.assertEqual(len(frame), 3)
        with self.assertRaisesRegex(ValueError, 'membership_quarter_missing'):
            select_universe(frame, {})


if __name__ == '__main__':
    unittest.main()
