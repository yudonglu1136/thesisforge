"""Consolidate identical immutable public Parquet inodes, retaining every path.

Explicit operator maintenance, not GC. Never visits raw archives, product
SQLite artifacts, leases, user stores or directories outside canonical releases.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import uuid

from fact_os.pipeline.installer import safe_member
from fact_os.store import Store, checksum, now


def consolidate(root, *, apply=False):
    root=Path(root).resolve()
    report={'startedAt':now(),'applied':apply,'status':'planning','replacedPaths':[],
            'preservedAllPaths':True,'rawAndPrivateDataTouched':False}
    with (root/'install.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        report['freeBytesBefore']=shutil.disk_usage(root).free
        try:
            groups={}
            base=safe_member(root,'releases/canonical')
            for generation in sorted(base.iterdir()):
                if not re.fullmatch('[a-f0-9]{64}',generation.name):continue
                catalog=safe_member(generation,'manifests/catalog.json')
                if not catalog.is_file():continue
                for dataset in json.loads(catalog.read_text())['datasets'].values():
                    for entry in dataset['partitions']:
                        relative=Path(entry['path'])
                        if relative.parts[0]!='parquet' or relative.suffix!='.parquet':
                            raise ValueError('canonical_partition_namespace')
                        path=safe_member(generation,relative)
                        stat=path.stat()
                        if (stat.st_uid!=os.geteuid() or stat.st_mode & 0o222
                                or stat.st_size!=entry['bytes']):
                            raise ValueError('canonical_partition_not_immutable')
                        groups.setdefault((entry['sha256'],entry['bytes']),set()).add(path)
            plan=[]
            for (sha,size),members in sorted(groups.items()):
                paths=sorted(members)
                identities={(p.stat().st_dev,p.stat().st_ino) for p in paths}
                if len(identities)<2:continue
                # Validate the entire plan before changing any directory entry.
                if any(checksum(p)!=sha for p in paths):
                    raise ValueError('canonical_partition_checksum_mismatch')
                source=max(paths,key=lambda p:p.stat().st_nlink)
                for target in paths:
                    if not os.path.samefile(source,target):plan.append((source,target,sha,size))
            report['plannedPaths']=len(plan)
            if apply:
                for source,target,sha,size in plan:
                    if os.path.samefile(source,target):continue
                    if checksum(source)!=sha or checksum(target)!=sha:
                        raise ValueError('canonical_partition_changed')
                    parent=target.parent;mode=parent.stat().st_mode & 0o777
                    temporary=target.with_name('.deduplicate-'+uuid.uuid4().hex)
                    try:
                        parent.chmod(mode | 0o200)
                        os.link(source,temporary)
                        os.replace(temporary,target)
                        fd=os.open(parent,os.O_RDONLY)
                        try:os.fsync(fd)
                        finally:os.close(fd)
                    finally:
                        temporary.unlink(missing_ok=True)
                        parent.chmod(mode)
                    report['replacedPaths'].append(str(target.relative_to(root)))
            report['status']='verified' if apply else 'dry_run'
        except Exception as error:
            report.update(status='failed',errorType=type(error).__name__)
            raise
        finally:
            report['freeBytesAfter']=shutil.disk_usage(root).free
            report['completedAt']=now()
            if apply:
                directory=root/'audit';directory.mkdir(exist_ok=True)
                receipt=directory/('canonical-inode-dedup-'+uuid.uuid4().hex+'.json')
                Store._atomic_if_changed(receipt,json.dumps(report,sort_keys=True)+'\n')
                report['receipt']=str(receipt)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    result=consolidate(args.root,apply=args.apply)
    print(json.dumps({k:v for k,v in result.items() if k!='replacedPaths'} |
                     {'replacedPathCount':len(result['replacedPaths'])}))
