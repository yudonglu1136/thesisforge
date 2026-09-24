"""Resolve only reviewed historical entitlements in fixed Fact OS price units.

Not a corporate-action inference engine. No changes to canonical facts. Legal
terms below come from issuer completion filings, not rounded vendor ratios.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fact_os.repository import FactRepository

REVIEWED = [
    dict(ticker='BMC', permaticker='198189', cik='835729',
         effective='2013-09-10', legalDate='2013-09-10', cash=46.25,
         source='https://www.sec.gov/Archives/edgar/data/835729/000119312513364103/d595671d8k.htm',
         timing='Item 3.01: merger completed and trading suspended on September 10.'),
    dict(ticker='LO', permaticker='193634', cik='1424847', successor='RAI', successorCik='1275283',
         effective='2015-06-12', legalDate='2015-06-12', cash=50.50, ratio=.2909,
         source='https://www.sec.gov/Archives/edgar/data/1424847/000119312515221980/d941804d8k.htm',
         timing='Completion June 12; shares ceased trading on the NYSE following closing.'),
    dict(ticker='ANSS', permaticker='197076', cik='1013462', successor='SNPS', successorCik='883241',
         effective='2025-07-17', legalDate='2025-07-17', cash=199.91, ratio=.3399,
         source='https://www.sec.gov/Archives/edgar/data/1013462/000114036125026141/ef20052066_8k.htm',
         timing='Item 3.01: suspended before July 17 open. Item 2.01 gives FINAL adjusted consideration, not the announcement ratio.'),
    dict(ticker='LLTC', permaticker='198484', cik='791907', successor='ADI', successorCik='6281',
         effective='2017-03-13', legalDate='2017-03-10', cash=46., ratio=.2321,
         source='https://www.sec.gov/Archives/edgar/data/791907/000119312517078946/d340243d8k.htm',
         timing='Item 3.01: suspended after March 10 close; first ex-security session March 13.'),
    dict(ticker='QCOR', permaticker='197733', cik='891288', successor='MNKKQ', successorCik='1567892',
         effective='2014-08-15', legalDate='2014-08-14', cash=30., ratio=.897,
         source='https://www.sec.gov/Archives/edgar/data/891288/000120919114053195/xslF345X03/doc4.xml',
         timing='Completion at 16:30 ET on August 14; first ex-security session August 15.'),
    dict(ticker='CNVR', permaticker='196418', cik='1080034', successor='BFH', successorCik='1101215',
         effective='2014-12-10', legalDate='2014-12-10', cash=15.14, ratio=.07037,
         source='https://www.sec.gov/Archives/edgar/data/1080034/000110121514000309/form_8k.htm',
         timing='Trading suspended before open December 10. Base consideration; no cash/stock election.'),
    dict(ticker='NSR1', permaticker='195318', cik='1265888', effective='2017-08-08',
         legalDate='2017-08-08', cash=33.50,
         source='https://www.sec.gov/Archives/edgar/data/1265888/000119312517251307/d434981d8k.htm',
         timing='Completion and NYSE trading suspension on August 8.'),
    dict(ticker='CELG', permaticker='198310', cik='816284', successor='BMY', successorCik='14272',
         effective='2019-11-21', legalDate='2019-11-20', cash=50., ratio=1.,
         rightTicker='BMYRT', rightFirstTradingDate='2019-11-21', rightFirstTradePrice=2.30,
         rightLiquidationCostBps=25, rightNet=2.30 * (1 - 25 / 10_000),
         source='https://www.sec.gov/Archives/edgar/data/816284/000110465919065939/tm1923405d1_8k.htm',
         rightSource='https://www.sec.gov/Archives/edgar/data/14272/000001427220000082/bmy-20191231x10xk.htm',
         timing='CELG trading was suspended before the November 21 open; BMYRT first traded November 21.'),
]


def cash_entitlement(term):
    """Return modeled cash in legal source-share units.

    A separately traded right is not merger cash.  When an official first-trade
    price is available but the licensed price source has no series, the right is
    explicitly liquidated at that observable price, net of the strategy's
    standard one-way transaction cost.
    """
    return term['cash'] + term.get('rightNet', 0)

def build(root, output, stock_actions, published):
    with FactRepository(root) as repo:
        original = json.loads(stock_actions.read_text())
        if original['generation'] != repo.generation:
            raise ValueError('action_generation_mismatch')
        actions = original['actions']
        for term in REVIEWED:
            if any(r['ticker']==term['ticker'] and r['corporateAction']['effectiveDate']==term['effective'] for r in actions):
                continue
            identity = repo.db.execute('SELECT DISTINCT permaticker,secfilings FROM tickers WHERE ticker=? AND "table"=\'SEP\'', [term['ticker']]).fetchall()
            if len(identity) != 1 or str(identity[0][0]) != term['permaticker'] or str(int(term['cik'])) != str(int(identity[0][1].split('CIK=')[-1])):
                raise ValueError('action_identity_mismatch')
            def price(ticker, date, before=False):
                rows = repo.db.execute('SELECT cast(date AS VARCHAR),closeadj,closeunadj FROM stocks WHERE ticker=? AND date'+('<' if before else '=')+'? ORDER BY date DESC LIMIT 1', [ticker, date]).fetchall()
                if not rows or not all(v > 0 for v in rows[0][1:]):
                    raise ValueError('missing_action_basis')
                return dict(zip(['date', 'adjusted', 'raw'], rows[0]))
            source = price(term['ticker'], term['effective'], True)
            factor = source['adjusted']/source['raw']
            action = dict(actionId=f"rule-history:{term['ticker']}:{term['effective']}",
                considerationType='stock_and_cash' if term.get('successor') else 'cash',
                effectiveDate=term['effective'], publicTradingEndExclusive=term['effective'],
                legalCompletionDate=term['legalDate'], terminalCashEntitlementPerShare=cash_entitlement(term)*factor,
                legalCashPerShare=term['cash'], sourceUrl=term['source'], legalSourceVerified=True,
                syntheticPriceUsed=False, timingEvidence=term['timing'],
                sourceAdjustmentFactor=factor, sourceBasis=source)
            if term.get('rightTicker'):
                action.update(contingentRightTicker=term['rightTicker'],
                    contingentRightFirstTradingDate=term['rightFirstTradingDate'],
                    contingentRightFirstTradePrice=term['rightFirstTradePrice'],
                    contingentRightLiquidationCostBps=term['rightLiquidationCostBps'],
                    contingentRightNetProceedsPerShare=term['rightNet'],
                    contingentRightSourceUrl=term['rightSource'],
                    contingentRightPriceBasis='first_trade_reported_by_issuer_10k',
                    modeledRightDisposition='liquidated_at_first_trade')
            if term.get('successor'):
                identity = repo.db.execute('SELECT DISTINCT permaticker,secfilings FROM tickers WHERE ticker=? AND "table"=\'SEP\'', [term['successor']]).fetchall()
                if len(identity) != 1 or int(identity[0][1].split('CIK=')[-1]) != int(term['successorCik']):
                    raise ValueError('successor_identity_mismatch')
                target = price(term['successor'], term['effective'])
                target_factor = target['adjusted']/target['raw']
                action.update(successorTicker=term['successor'], successorPermaticker=str(identity[0][0]),
                    successorSharesPerShare=term['ratio']*factor/target_factor,
                    legalSuccessorSharesPerShare=term['ratio'], successorBasis=target,
                    successorAdjustmentFactor=target_factor, successorFirstTradingDate=term['effective'])
            actions.append(dict(ticker=term['ticker'], permaticker=term['permaticker'],
                status='verified_research_accounting', corporateAction=action))
        # Carry the already published receipts (not a partial research schedule).
        source = json.loads(published.read_text())
        for style in source['styles']:
            for action in style['corporateActions']:
                if any(a['ticker'] == action['ticker'] and a['corporateAction']['effectiveDate'] == action['effectiveDate'] for a in actions):
                    continue
                position = next(p for q in style['quarters'] if q['executionDate'] == action['executionDate'] for p in q['positions'] if p['ticker'] == action['ticker'])
                receipt = {k:v for k,v in action.items() if k not in ('ticker', 'executionDate')}
                receipt['legalSourceVerified'] = True
                actions.append(dict(ticker=action['ticker'], permaticker=position['permaticker'],
                    status='verified_research_accounting', corporateAction=receipt))
        output.write_text(json.dumps(dict(generation=repo.generation, actions=actions,
            builderSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()), allow_nan=False))

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for key in ['root','output','stock-actions','published']:
        p.add_argument('--'+key, required=True, type=Path)
    a=p.parse_args()
    build(a.root,a.output,a.stock_actions,a.published)
