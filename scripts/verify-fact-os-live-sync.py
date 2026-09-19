#!/usr/bin/env python3
"""Run two real local syncs and retain bounded, credential-free acceptance evidence."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from fact_os.contracts import TABLES
from fact_os.store import Store
from fact_os.sync import Synchronizer, UpstreamError, load_key


def main():
    project=Path(__file__).resolve().parents[1]
    parser=argparse.ArgumentParser()
    parser.add_argument('--tables',nargs='+',choices=TABLES,default=list(TABLES))
    parser.add_argument('--output',type=Path,default=project/'data/fact_os/audit/live-sync-idempotency.json')
    args=parser.parse_args()
    store=Store(project/'data/fact_os')
    before={s['dataset']:s for s in store.status()}
    if any(not before.get(t,{}).get('backfill_complete') for t in args.tables):
        raise SystemExit('All requested tables must have verified full backfills before live sync acceptance.')
    report={'started_at':datetime.now(timezone.utc).isoformat(),'scope':'local_only',
        'before':before,'passes':[],'assertions':{},'errors':[]}
    def checkpoint():
        args.output.parent.mkdir(parents=True,exist_ok=True)
        temporary=args.output.with_suffix('.tmp')
        temporary.write_text(json.dumps(report,indent=2,default=str));temporary.replace(args.output)
    sync=Synchronizer(store,load_key(project/'.env.local'),
        progress=lambda event:print(json.dumps(event),flush=True))
    try:
        with sync.job_lock():
            for number in (1,2):
                record={'pass':number,'results':[]};report['passes'].append(record)
                for table in args.tables:
                    start=time.monotonic()
                    print(json.dumps({'phase':'sync_start','pass':number,'table':table}),flush=True)
                    try:
                        result=sync.sync(table)
                    except Exception as error:
                        message=str(error) if isinstance(error,UpstreamError) else type(error).__name__
                        store.record_error(table,message)
                        result={'dataset':table,'error':message}
                        report['errors'].append({'pass':number,**result})
                    result['elapsed_seconds']=round(time.monotonic()-start,3)
                    record['results'].append(result)
                    record['after']={s['dataset']:s for s in store.status()}
                    checkpoint();print(json.dumps({'pass':number,**result},default=str),flush=True)
            first,second=[entry['after'] for entry in report['passes']]
            report['assertions']={
                'no_history_shrink':all(second[t]['row_count']>=before[t]['row_count'] and
                    (not before[t]['min_date'] or second[t]['min_date']<=before[t]['min_date']) for t in args.tables),
                'second_pass_same_row_counts':all(first[t]['row_count']==second[t]['row_count'] for t in args.tables),
                'second_pass_same_date_coverage':all((first[t]['min_date'],first[t]['max_date'])==
                    (second[t]['min_date'],second[t]['max_date']) for t in args.tables),
                'all_syncs_succeeded':not report['errors']}
    finally:
        sync.close();report['finished_at']=datetime.now(timezone.utc).isoformat();checkpoint()
    print(json.dumps({'report':str(args.output),'assertions':report['assertions']}),flush=True)
    return 0 if report['assertions'] and all(report['assertions'].values()) else 1


if __name__=='__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:
        print('Interrupted safely; previously published local history is unchanged.',flush=True);sys.exit(130)
