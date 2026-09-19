#!/usr/bin/env python3
"""Four source-specific CRDO guidance corrections; original excerpts unchanged.

Creates a new SQLite copy. Does not alter common parsers, issuer review, models,
prices or any other issuer; output is still subject to independent audit.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3

REVIEWS={
    '427b88dd3726254e70d7b1f8':{
        'date':'2022-11-30','quote':'Today, we remain focused on delivering strong execution in our fiscal 23, and we continue to expect to achieve at least $200 million in revenue, representing more than 88% growth compared to fiscal 22.',
        'changes':{'guidance_scope':'full_year','guidance_target_year':2023,'guidance_scope_evidence':'our fiscal 23'},
        'reason':'The fiscal23 target denotes fiscal2023 annual revenue; comparison fiscal22 is historical and does not change target ownership.'},
    '6009a158ccea4eac4699e1ed':{
        'date':'2026-02-09','quote':'Credo Provides Preliminary Third Quarter Fiscal Year 2026 Revenue Results, Updated Revenue Guidance for Fourth Quarter of Fiscal Year 2026 and Schedules Third Quarter Fiscal Year 2026 Financial Results Conference. Looking towards the end of fiscal year 2026 and into fiscal 2027, Credo expects sequential revenue growth in the mid-single digits leading to more than 200% year-over-year growth in the current fiscal year.',
        'changes':{'actual_or_guidance':'guidance','quality_status':'clear','guidance_scope':'full_year','guidance_target_year':2026,'guidance_scope_evidence':'more than 200% year-over-year growth in the current fiscal year'},
        'reason':'The body forecasts currentFY2026 growth; preliminary results wording belongs to the unrelated release title. The 200% target refers to current fiscal year2026, not the adjacent FY2027 token.'},
    '3e6d4939138148bb8957591e':{
        'date':'2026-03-02','quote':'As we look ahead to fiscal 2027, we expect sequential revenue growth in the mid-single digits, leading to more than 50% year-over-year growth.',
        'changes':{'guidance_scope':'full_year','guidance_target_year':2027,'guidance_scope_evidence':'As we look ahead to fiscal 2027'},
        'reason':'Explicit forward fiscal2027 target scopes the annual growth figure; the separate sequential mid-single-digit statement is not a50% quarter forecast.'},
    'e6d6008e43469aac45359ae7':{
        'date':'2022-06-01','quote':'As Bill mentioned, we expect to achieve at least $200 million of revenue in fiscal 2023.',
        'changes':{'guidance_scope':'full_year','guidance_target_year':2023,'guidance_scope_evidence':'revenue in fiscal 2023'},
        'reason':'Explicit fiscal2023 annual companyrevenue target; original wording and amount preserved.'},
}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--report',type=Path,required=True);a=p.parse_args()
    if a.out.exists() or a.report.exists():raise ValueError('Use new immutable outputs')
    source=sqlite3.connect(a.source.resolve(strict=True).as_uri()+'?mode=ro',uri=True);source.row_factory=sqlite3.Row
    rows=[]
    for event_id,r in REVIEWS.items():
        original=source.execute("select * from pit_guidance_events where ticker='CRDO' and id=?",(event_id,)).fetchone()
        if not original or original['observed_at']!=r['date'] or original['evidence_excerpt']!=r['quote']:
            raise ValueError(f'Exact frozen source quote/date changed: {event_id}')
        payload=json.loads(original['payload_json']);before={key:payload.get(key) for key in r['changes']}
        payload.update(r['changes'])
        payload['sourceSpecificReview']={'version':'crdo-original-evidence-adjudication-v1-2026-09-06','status':'reviewed','reason':r['reason'],'originalFields':before,'evidenceSha256':hashlib.sha256(r['quote'].encode()).hexdigest(),'sourceUrl':original['source_url'],'observedAt':original['observed_at']}
        rows.append((event_id,payload,before,r))
    a.out.parent.mkdir(parents=True,exist_ok=True);target=sqlite3.connect(a.out);source.backup(target);source.close()
    with target:
        for event_id,payload,before,r in rows:
            target.execute("UPDATE pit_guidance_events SET actual_or_guidance=?,quality_status=?,payload_json=? WHERE ticker='CRDO' AND id=?",(payload['actual_or_guidance'],payload['quality_status'],json.dumps(payload,separators=(',',':')),event_id))
    assert target.execute('pragma integrity_check').fetchone()[0]=='ok';target.close()
    report={'status':'four_exact_source_adjudications_applied_independent_audit_required','source':str(a.source.resolve()),'output':str(a.out.resolve()),'reviews':[{'id':event_id,'observedAt':r['date'],'sourceUrl':payload['source_url'],'before':before,'after':r['changes'],'reason':r['reason'],'evidenceSha256':hashlib.sha256(r['quote'].encode()).hexdigest()} for event_id,payload,before,r in rows]}
    a.report.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n');print(json.dumps({'output':str(a.out),'reviews':len(rows)}))


if __name__=='__main__':main()
