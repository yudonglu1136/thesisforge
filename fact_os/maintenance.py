"""Reclaim obsolete derived generations; raw vendor history is never deleted."""
from collections import defaultdict
import fcntl
import re
import time
import json

from .contracts import TABLES


def collect_unreferenced(store, *, retention_days=7, apply=False):
    if retention_days < 1:
        raise ValueError('at least one day of rollback retention is required')
    # Writer excludes a concurrent commit; reader lease excludes older pinned
    # catalogs. No active reader can lose a Parquet file during its query.
    with store.writer() as db, (store.root/'sync/readers.lock').open('a') as lease:
        try:
            fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            return {'status':'readers_active','deleted_files':0,'candidates':[]}
        try:
            referenced={str(p) for (p,) in db.execute('SELECT path FROM partitions').fetchall()}
            # Pipeline/rollback/saved-research pins outlive an individual RPC.
            # Invalid pins fail closed; never guess that a broken reference is unused.
            for pin in (store.root/'sync/snapshot-pins').glob('*.json'):
                value=json.loads(pin.read_text())
                if not isinstance(value.get('paths'),list): raise ValueError('invalid_snapshot_pin')
                referenced.update(value['paths'])
            groups=defaultdict(list)
            for table in TABLES:
                directory=store.root/'parquet'/table
                if not directory.is_dir() or directory.is_symlink():continue
                for path in directory.glob('*.parquet'):
                    match=re.fullmatch(r'(\d+)-[a-f0-9]{32}\.parquet',path.name)
                    if not match or path.is_symlink() or not path.is_file():continue
                    groups[(table,match[1])].append(path)
            cutoff=time.time()-retention_days*86400
            candidates=[]
            for files in groups.values():
                files.sort(key=lambda p:p.stat().st_mtime,reverse=True)
                # Keep at least two generations even after retention expires.
                for path in files[2:]:
                    relative=str(path.relative_to(store.root));stat=path.stat()
                    if relative not in referenced and stat.st_mtime < cutoff:
                        candidates.append({'path':relative,'bytes':stat.st_size})
            if apply:
                for entry in candidates:(store.root/entry['path']).unlink()
            return {'status':'collected' if apply else 'dry_run',
                'deleted_files':len(candidates) if apply else 0,
                'reclaimable_bytes':sum(item['bytes'] for item in candidates),
                'raw_history_preserved':True,'candidates':candidates}
        finally:
            fcntl.flock(lease,fcntl.LOCK_UN)
