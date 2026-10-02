"""Small pure validators for public rule-selection dependencies.

These do not fetch data or create a second security master. Callers supply a
dated rate series and canonical identity rows from the frozen Fact OS catalog.
"""
from datetime import date
import copy
import hashlib
import json
import math


def rate_at(rows, cutoff):
    target=date.fromisoformat(cutoff)
    known={}
    for row in rows:
        day=date.fromisoformat(row['observation_date'])
        if day>target or row['DGS10'] in ('','.'):continue
        value=float(row['DGS10'])
        if not math.isfinite(value) or not -5<=value<=30:raise ValueError('invalid_dgs10')
        if day in known and known[day]!=value:raise ValueError('conflicting_dgs10')
        known[day]=value
    if not known:raise ValueError('missing_prior_risk_free_rate')
    day=max(known)
    if (target-day).days>10:raise ValueError('stale_risk_free_rate')
    return {'date':day.isoformat(),'value':known[day]/100,'series':'DGS10'}


def revalidate_qqq(source, identities, generation, cutoff):
    if source.get('version')!='sec-qqq-disclosed-universe-v1' or source.get('unresolved'):
        raise ValueError('invalid_qqq_source')
    by_cusip={}
    for permaticker,ticker,cusips in identities:
        for cusip in str(cusips or '').replace(',',' ').split():
            by_cusip.setdefault(cusip,{}).setdefault(str(permaticker),set()).add(ticker)
    result=copy.deepcopy(source)
    result['snapshots']=[s for s in result['snapshots'] if s['filed']<=cutoff]
    if not result['snapshots']:raise ValueError('qqq_snapshot_missing')
    evidence=[]
    for snapshot in result['snapshots']:
        if snapshot['period']>snapshot['filed'] or len(snapshot['members'])!=snapshot['sourceMemberCount']:
            raise ValueError('qqq_snapshot_invalid')
        for member in snapshot['members']:
            cusip=member.get('resolvedCusip') or member['cusip']
            matches=by_cusip.get(cusip,{})
            if len(matches)!=1 or str(member['permaticker']) not in matches:
                raise ValueError('qqq_identity_changed_or_ambiguous:'+cusip)
            member['tickers']=sorted(matches[str(member['permaticker'])])
            evidence.append([cusip,str(member['permaticker']),member['tickers']])
    result['identityGeneration']=generation
    result['identityRevalidation']={'method':'exact_cusip_same_permaticker_v1',
        'sourceSha256':hashlib.sha256(json.dumps(source,sort_keys=True).encode()).hexdigest(),
        'resolvedRowsSha256':hashlib.sha256(json.dumps(sorted(evidence),sort_keys=True).encode()).hexdigest(),
        'cutoff':cutoff}
    return result
