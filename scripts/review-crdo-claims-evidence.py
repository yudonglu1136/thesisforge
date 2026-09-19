#!/usr/bin/env python3
"""CRDO claims facts, with exercisable/vested distinction and dated warrants.

An evidence ledger, not a claims valuation or a release approval.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
from datetime import date
from bs4 import BeautifulSoup

spec=importlib.util.spec_from_file_location("crdo_review",Path(__file__).with_name("review-crdo-economic-source-bridge.py"))
review=importlib.util.module_from_spec(spec);spec.loader.exec_module(review)
WARRANT_VESTED={"2022-03-10":.04,"2022-06-08":.04,"2022-09-01":.04,"2022-12-01":.04,
               "2023-03-02":.08,"2023-06-23":.08,"2023-08-29":.08,"2023-11-30":.08,
               "2024-02-28":.58,"2024-06-24":1.08,"2024-09-05":1.58,"2024-12-03":2.08,
               "2025-03-10":4.08,"2025-07-02":4.08,"2025-09-04":4.08,"2025-12-02":2.04,
               "2026-03-03":0,"2026-06-15":0,"2026-09-02":0}


def item(doc,locator,quote=None):
    return {"url":doc['url'],"availableDate":doc['filed'],"sha256":doc['sha256'],"locator":locator,
            **({"evidenceExcerpt":quote} if quote else {})}


def claims(doc,end):
    raw=Path(doc['localPath']).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=doc['sha256']:raise ValueError('Frozen filing hash changed')
    soup=BeautifulSoup(raw,'html.parser');text=soup.get_text(' ',strip=True)
    option_table=next(t.get_text(' ',strip=True) for t in soup.find_all('table')
                      if len(t.get_text(' ',strip=True))<8000 and 'Outstanding Share Options' in t.get_text(' ',strip=True))
    prefix='us-gaap:ShareBasedCompensationArrangementByShareBasedPaymentAwardOptions'
    option_rows=[f for f in doc['aggregateFacts'] if f['end']==end and not f.get('start') and f['tag'].startswith(prefix)
                 and any(s in f['tag'] for s in ['OutstandingNumber','OutstandingWeightedAverageExercisePrice',
                                                'VestedAndExpectedToVestOutstandingNumber','VestedAndExpectedToVestOutstandingWeightedAverageExercisePrice',
                                                'VestedAndExpectedToVestExercisableNumber','VestedAndExpectedToVestExercisableWeightedAverageExercisePrice'])]
    # IAS/US-GAAP taxonomy naming is not enough to label exercisable as vested.
    # The January 2022 table explicitly gives different vested/exercisable counts.
    option_status='exercisable_includes_expected_to_vest_not_certified_vested'
    vested_explicit=None
    if doc['filed']=='2022-03-10':
        assert 'Vested as of January 31, 2022 6,342,760 $ 1.05' in option_table
        vested_explicit={"countM":6.342760,"strike":1.05,"currency":"USD","basis":"explicitly_vested_employee_option"}
    # Exact customer-warrant terms originate in the 2022 contract. Later 4.1m
    # disclosures are rounded; carry the original4.08m maximum only while the
    # period's note says unexercised or reconciles an exact2.04m partial exercise.
    count=WARRANT_VESTED[doc['filed']]
    if doc['filed'] in {'2026-03-03','2026-06-15','2026-09-02'}:
        pattern=r'(?:As of January 31, 2026, Amazon.{0,350}no longer outstanding|As of May 2, 2026, the Holder has exercised all.{0,200}|The Customer Warrant relates.{0,220}fiscal year 2026)'
    elif doc['filed']=='2025-12-02':
        pattern=r'The Holder exercised 2\.04 million Customer Warrant shares as of November 1, 2025\.'
    elif count==.04:
        pattern=r'No other tranches were vested as of .{0,40}?\.'
    else:
        pattern=r'A total of [\d,.]+.{0,220}(?:vested|unexercised).{0,150}?\.'
    match=re.search(pattern,text,re.I)
    if not match:raise ValueError(f"No independently visible warrant evidence {doc['filed']}")
    maximum=0 if count==0 else (2.04 if doc['filed']=='2025-12-02' else 4.08)
    warrant={"vestedUnexercisedCountM":count,"maximumUnexercisedCountM":maximum,"strike":10.74,"currency":"USD",
             "basis":"customer_warrant","evidence":[item(doc,'Customer Warrant note, period-end vesting/exercise',match.group())],
             "policy":"Do not substitute maximum count for vested count without an explicit probability/vesting scenario. GAAP revenue already reflects grant-value contra-revenue; avoid charging it again."}
    contra=[f for f in doc['aggregateFacts'] if f['tag']=='crdo:ClassOfWarrantOrRightContraRevenue' and f['end']==end]
    if not contra:
        contra=[f for f in doc['aggregateFacts'] if f['tag'].endswith(':ClassOfWarrantOrRightContraRevenue') and f['end']==end]
    claims_evidence=[]
    contingent=None
    if doc['filed']=='2026-09-02':
        match=re.search(r'records the estimated fair value of contingent consideration as a liability of \$ 10\.0 million and equity of \$ 300\.0 million',text)
        if not match:raise ValueError('Missing explicit liability/equity contingent allocation')
        contingent={"liabilityM":10,"equityM":300,"totalM":310,"eventDate":"2026-05-28",
                    "valuationLabel":"issuer acquisition-date preliminary fair values, not a new model estimate",
                    "evidence":[item(doc,'DustPhotonics acquisition note, contingent earn-out allocation',match.group())]}
    else:
        # Explicit review of the full statements and acquisition notes: no
        # material purchase-price contingent liability/equity is recorded as
        # of these balance-sheet dates. It is not a generic missing-field0.
        if doc['filed'] in {'2025-12-02','2026-03-03','2026-06-15'}:
            assert 'Cash consideration $ 88,698 Cash settlement of Hyperlume share-based payment awards 3,319 Total purchase consideration 92,017' in text
            if doc['filed']=='2026-06-15':
                assert 'total cash consideration of $ 35.1 million' in text
            locator='Business Combination: Hyperlume consideration entirely cash/settled awards; CoMira cash consideration when present; no recorded contingent purchase-price claim at period end'
        else:
            assert not any(f['tag']=='us-gaap:PaymentsToAcquireBusinessesNetOfCashAcquired' and f['value']>0 and f['end']==end for f in doc['aggregateFacts'])
            assert not any('contingentconsideration' in f['tag'].lower() and f['value']>0 and f['end']==end for f in doc['customFacts'])
            locator='Reviewed full balance sheet, cash-flow statement and notes: no disclosed material acquisition contingent consideration; existing options/warrants handled separately'
        contingent={"liabilityM":0,"equityM":0,"totalM":0,
                    "valuationLabel":"reviewed absence of disclosed material contingent purchase-price claims at period end",
                    "evidence":[item(doc,locator)]}
    unrecognized=None
    pattern=r'As of (.{0,25}?), the total unrecognized compensation cost was \$ ([\d.]+) million related to share options, which are expected to be recognized over a weighted-average period of ([\d.]+) years'
    m=re.search(pattern,text)
    if m:
        unrecognized={"amountM":float(m.group(2)),"weightedAverageRemainingYears":float(m.group(3)),
                      "asOfDate":end,"status":"reported_actual","evidence":[item(doc,'Share option compensation footnote',m.group())]}
    if 'As of May 2, 2026, there was no unrecognized compensation cost related to share options' in text:
        unrecognized={"amountM":0,"weightedAverageRemainingYears":0,"asOfDate":end,"status":"reported_actual",
                      "evidence":[item(doc,'Share option compensation footnote','No unrecognized compensation cost related to share options as of May 2, 2026.')]}
    if doc['filed']=='2026-09-02':
        assert 'Options vested and exercised' in option_table and 'Options granted' not in option_table
        unrecognized={"amountM":0,"weightedAverageRemainingYears":0,"asOfDate":end,"status":"zero_prior_unrecognized_cost_no_new_option_grants",
                      "evidence":[item(doc,'Quarterly option rollforward: only exercises, no grants')]}
    return {"availableDate":doc['filed'],"periodEndDate":end,"status":"reported_claims_facts_not_valuation_approval",
            "employeeOptions":{"facts":option_rows,"explicitVested":vested_explicit,"status":option_status,
                               "evidence":[item(doc,'Stock options activity table; outstanding, expected-to-vest and exercisable labels distinct')],
                               "tableText":option_table,"unrecognizedOptionCompensation":unrecognized},
            "customerWarrant":warrant,"warrantContraRevenueFacts":contra,
            "acquisitionContingentConsideration":contingent,
            "absencePolicy":"The explicit zero applies only to reviewed contingent purchase-price claims, not to stock options, customer warrants, leases or all other liabilities."}


def contra_fact(doc,start,end):
    rows=[f for f in doc['aggregateFacts'] if f['tag']=='crdo:ClassOfWarrantOrRightContraRevenue' and f['start']==start and f['end']==end]
    if rows:
        precision=max(int(f['decimals']) for f in rows)
        precise=[f for f in rows if int(f['decimals'])==precision]
        values={f['value'] for f in precise}
        if len(values)!=1:raise ValueError('Conflicting precise warrant charges')
        f=precise[0]
        return f['value']/1e6,review.evidence(doc,f)
    if end<'2021-12-28':
        return 0,item(doc,'Cash-flow period precedes first customer warrant issuance (December28,2021); no customer-warrant charge')
    if doc['filed']=='2026-09-02' and start>='2025-05-04':
        return 0,item(doc,'No customer-warrant cash-flow addback; warrant fully vested inFY2025 and exercised inFY2026; reportedFY2026 chargezero')
    raise ValueError(f'No reviewed exact warrant contra-revenue {doc["filed"]}/{start}/{end}')


def attach_contra(capture,source_bridge,rows):
    docs={d['url']:d for d in capture['documents']}
    bridges={r['availableDate']:r for r in source_bridge['periods'] if r.get('quarter')}
    for row in rows:
        for window in ['quarter','ttm']:
            ledger=[];total=0
            for ev in bridges[row['availableDate']][window]['evidence'][::4]:
                value,evidence=contra_fact(docs[ev['url']],ev['periodStartDate'],ev['periodEndDate'])
                total+=ev['multiplier']*value
                ledger.append({**evidence,'valueM':value,'multiplier':ev['multiplier']})
            row.setdefault('customerWarrantContraRevenue',{})[window]={"amountM":round(total,9),"evidence":ledger,
                "basis":"Highest-precision original cash-flow addback; quarter=YTD-priorYTD;TTM=currentYTD+priorFY-priorYTD. Already noncash addback inside CFO."}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--capture',type=Path,required=True);parser.add_argument('--out',type=Path,required=True);parser.add_argument('--source-bridge',type=Path,required=True)
    args=parser.parse_args()
    if args.out.exists():raise ValueError('Use a new immutable evidence output')
    raw=args.capture.read_bytes();capture=json.loads(raw)
    dates={r['available_at']:r for r in capture['financials'] if r['dimension']=='ARQ'}
    rows=[claims(doc,dates[doc['filed']]['report_period']) for doc in capture['documents'] if doc['form'] in {'10-K','10-Q'}]
    attach_contra(capture,json.loads(args.source_bridge.read_text()),rows)
    last_reported=None
    for row in rows:
        opts=row['employeeOptions'];known=opts['unrecognizedOptionCompensation']
        if known and known.get('status')=='zero_prior_unrecognized_cost_no_new_option_grants':
            if not last_reported or last_reported['amountM'] != 0:
                raise ValueError('No reviewed prior zero option service cost')
            known['evidence']=[*last_reported['evidence'],*known['evidence']]
        if known is not None:last_reported=known
        elif last_reported:
            elapsed=(date.fromisoformat(row['periodEndDate'])-date.fromisoformat(last_reported['asOfDate'])).days/365.25
            years=last_reported['weightedAverageRemainingYears']
            estimate=last_reported['amountM']*max(0,1-elapsed/years) if years>0 else 0
            opts['unrecognizedOptionCompensation']={"amountM":round(estimate,6),"status":"analyst_straight_line_estimate_not_reported_actual",
                "asOfDate":row['periodEndDate'],"lastReportedAmountM":last_reported['amountM'],"lastReportedAsOf":last_reported['asOfDate'],
                "weightedAverageRemainingYears":years,"evidence":last_reported['evidence'],
                "policy":"Existing award expense remaining, estimated with no new option grants; sensitivity from 0 to prior reported unrecognized cost. This estimate is not a vested-count certification."}
    result={"version":"crdo-claims-evidence-v2-2026-09-06","status":"claims_source_review_model_treatment_required",
            "ticker":"CRDO","cutoff":"2026-09-05","captureSha256":hashlib.sha256(raw).hexdigest(),"periods":rows}
    args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(json.dumps({"output":str(args.out),"periods":len(rows),"sha256":hashlib.sha256(args.out.read_bytes()).hexdigest()}))


if __name__=='__main__':main()
