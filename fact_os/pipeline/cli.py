from contextlib import contextmanager
import fcntl
from .contracts import record,digest
from .registry import tasks
from .snapshots import freeze
from .planner import plan
from .ledger import Ledger
from .runner import run


@contextmanager
def ingestion_lock(store):
    with (store.root/'sync/ingestion-job.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        try: yield
        finally: fcntl.flock(lock,fcntl.LOCK_UN)


def drain(store,args,emit,failed_sources=()):
    receipt=run(store,profile=args.profile,scheduled_for=args.scheduled_for,failed_sources=failed_sources)
    emit({'pipeline':{k:receipt[k] for k in ('runId','status','publicationStatus','snapshotId')},
          'tasks':{key:{k:v for k,v in value.items() if k in ('status','reason','errorType','missingRequired')} for key,value in receipt['tasks'].items()}})
    return int(receipt['status'] in ('degraded','failed'))


def pipeline_command(store,args,emit):
    with ingestion_lock(store):
        if args.pipeline_action=='status': emit(Ledger(store).status());return 0
        store.recover_catalog()
        if args.pipeline_action=='reconcile': emit({'status':'catalog_recovered'});return 0
        if args.pipeline_action=='plan':
            specs=tasks(profile=args.profile)
            snapshot=freeze(store,code_version=digest([record(s) for s in specs]),configs={s.id:s.configHashes for s in specs})
            emit({'snapshotId':snapshot.snapshotId,'tasks':[record(p) for p in plan(specs,snapshot,Ledger(store).results())]});return 0
        # Resume never fetches upstream. Validated task+fingerprint results and
        # partial append-only builder work are reused after catalog recovery.
        return drain(store,args,emit)
