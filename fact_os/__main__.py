import argparse
import json
from pathlib import Path
import os
import sys

from .contracts import TABLES
from .store import Store

def main():
    p=argparse.ArgumentParser(prog='fact-os')
    p.add_argument('--root',default=os.environ.get('FACT_OS_ROOT',str(Path(__file__).resolve().parents[1]/'data/fact_os')))
    p.add_argument('--env-file',default=os.environ.get('FACT_OS_ENV_FILE',str(Path(__file__).resolve().parents[1]/'.env.local')))
    p.add_argument('command',choices=['inspect','backfill','sync','status','import-archive','gc'])
    p.add_argument('--tables',nargs='+',choices=TABLES,default=list(TABLES))
    p.add_argument('--archive')
    p.add_argument('--quarters',type=int,default=3)
    p.add_argument('--apply',action='store_true',help='Apply safe derived-generation garbage collection only')
    p.add_argument('--retention-days',type=int,default=7)
    args=p.parse_args()
    store=Store(args.root)
    emit=lambda x:print(json.dumps(x,default=str),flush=True)
    if args.command=='status': emit(store.status());return 0
    if args.command=='gc':
        from .maintenance import collect_unreferenced
        emit(collect_unreferenced(store,retention_days=args.retention_days,apply=args.apply));return 0
    if args.command=='import-archive':
        if not args.archive or len(args.tables)!=1: p.error('import requires --archive and exactly one --tables value')
        emit(store.ingest(args.tables[0],args.archive));return 0
    from .sync import Synchronizer,load_key
    sync=Synchronizer(store,load_key(args.env_file))
    errors=0
    try:
        with sync.job_lock():
            if args.command=='inspect':
                result=sync.inspect(args.tables);emit(result)
                return int(any(r.get('full_bulk_status') not in (301,302,303,307,308) for r in result))
            for table in args.tables:
                try:
                    if args.command=='backfill':
                        states={s['dataset']:s for s in store.status()}
                        if not states.get(table,{}).get('backfill_complete'):
                            result=sync.inspect([table]);emit(result)
                        emit(sync.backfill(table))
                    else: emit(sync.sync(table,quarters=args.quarters))
                except Exception as e:
                    # Network exceptions can embed signed URLs. Only our own
                    # sanitized protocol errors are emitted, never tracebacks.
                    from .sync import UpstreamError
                    code=str(e) if isinstance(e,UpstreamError) else type(e).__name__
                    store.record_error(table,code);emit({'dataset':table,'error':code});errors+=1
    finally: sync.close()
    return int(errors>0)

if __name__=='__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(json.dumps({'status':'interrupted','history_preserved':True,'download_resumable':True}),flush=True)
        sys.exit(130)
