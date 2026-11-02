"""Explicit retired API release eviction; immutable S3 restoration is required."""
import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import time

HEX = re.compile(r'^[a-f0-9]{64}$')
GROUPS = {'canonical','ai_insights','institutional_13f','research_inputs','public_observations','strategy_inputs'}

def sha_file(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()

def member(base, relative):
    rel=Path(relative)
    if rel.is_absolute() or '..' in rel.parts: raise ValueError('unsafe_member')
    p=base/rel
    for part in [p,*p.parents]:
        if part==base.parent: break
        if part.is_symlink(): raise ValueError('symlink_member')
    if not p.resolve().is_relative_to(base.resolve()): raise ValueError('escaped_member')
    return p

def referenced(root):
    refs=set();identities={}
    for name in ('active.json','research-active.json'):
        path=root/name
        if path.exists():
            raw=path.read_bytes();identities[name]=hashlib.sha256(raw).hexdigest()
            value=json.loads(raw)
            for group,item in value['groups'].items():refs.add((group,item['generationId']))
    return refs,identities

def check_tree(base,manifest):
    expected={entry['path']:entry for entry in manifest['files']}
    if len(expected)!=len(manifest['files']):raise ValueError('duplicate_member')
    found=set()
    for path in base.rglob('*'):
        if path.is_symlink():raise ValueError('symlink_member')
        if path.is_file():found.add(str(path.relative_to(base)))
    if found!=set(expected):raise ValueError('unlisted_or_missing_files')
    for relative,entry in expected.items():
        path=member(base,relative);stat=path.stat()
        if stat.st_uid!=os.geteuid() or stat.st_mode & 0o222:raise ValueError('not_immutable_owner_file')
        if stat.st_size!=entry['bytes'] or sha_file(path)!=entry['sha256']:raise ValueError('checksum_mismatch')
    return [member(base,name) for name in sorted(expected)]

def open_reader_check(targets):
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():continue
        try:
            for fd in (process/'fd').iterdir():
                try: value=os.readlink(fd)
                except FileNotFoundError:continue
                if any(value==str(p) or value.startswith(str(p)+'/') for p in targets):raise ValueError('open_reader')
        except FileNotFoundError:continue

def prune(root,lease_root,candidate,s3,bucket,*,apply=False,retired_failed_generation=None,retired_generation=None):
    root=Path(root).resolve();lease_root=Path(lease_root).resolve()
    if retired_generation is not None and retired_failed_generation is not None:
        raise ValueError('ambiguous_retirement_override')
    retirement = retired_generation if retired_generation is not None else retired_failed_generation
    if retirement is not None and (
            not HEX.fullmatch(retirement) or len(candidate['groups'])!=1 or
            next(iter(candidate['groups'].values()))['generationId']!=retirement):
        raise ValueError('invalid_failed_generation_override')
    report={'applied':apply,'deletedFiles':0,'deletedGenerations':[],'restorableFromS3':True,
            'retiredFailedGeneration':retired_failed_generation,'operatorRetiredGeneration':retired_generation}
    with ExitStack() as stack:
        lock=stack.enter_context((root/'install.lock').open('a'));fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        protected,pointers=referenced(root);report['pointerChecksums']=pointers
        plans=[];remote_checked=set()
        for group,item in candidate['groups'].items():
            generation=item['generationId']
            if group not in GROUPS or not HEX.fullmatch(generation):raise ValueError('invalid_generation')
            if (group,generation) in protected:raise ValueError('active_reference')
            base=member(root,'releases/'+group+'/'+generation)
            if not base.exists():continue
            # Explicit operator retirement of one exact generation may skip
            # the age window; every reference, lease and checksum gate remains.
            if generation!=retirement and base.stat().st_mtime>time.time()-7*86400:raise ValueError('retention_window')
            lease=stack.enter_context((lease_root/(hashlib.sha256(str(base).encode()).hexdigest()+'.lock')).open('a'))
            fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            key=item['manifestKey']
            if key!='fact-os/published/groups/'+group+'/'+item['manifestSha256']+'.json':raise ValueError('manifest_namespace')
            raw=s3.get_object(Bucket=bucket,Key=key)['Body'].read()
            if hashlib.sha256(raw).hexdigest()!=item['manifestSha256']:raise ValueError('manifest_checksum')
            manifest=json.loads(raw)
            if manifest['generationId']!=generation or manifest['groupId']!=group:raise ValueError('manifest_identity')
            files=check_tree(base,manifest)
            for entry in manifest['files']:
                key=entry['key'];sha=entry['sha256']
                if not HEX.fullmatch(sha) or key!='fact-os/published/objects/'+sha:raise ValueError('object_namespace')
                if key in remote_checked:continue
                response=s3.get_object(Bucket=bucket,Key=key);h=hashlib.sha256();size=0
                with response['Body'] as body:
                    for chunk in iter(lambda:body.read(1024*1024),b''):h.update(chunk);size+=len(chunk)
                if size!=entry['bytes'] or h.hexdigest()!=sha:raise ValueError('remote_restore_checksum')
                remote_checked.add(key)
            plans.append((base,files,manifest))
        open_reader_check([p[0] for p in plans])
        if referenced(root)!=(protected,pointers):raise ValueError('pointer_changed')
        report['freeBytesBefore']=shutil.disk_usage(root).free
        report['candidates']=[str(p[0]) for p in plans]
        report['logicalBytes']=sum(f.stat().st_size for _,files,_ in plans for f in files)
        if apply:
            for base,files,manifest in plans:
                # Exact manifest members only. Never recursively remove an unknown file.
                check_tree(base,manifest)
                for file in files:
                    file.parent.chmod(file.parent.stat().st_mode | 0o200);file.unlink();report['deletedFiles']+=1
                for directory in sorted((p for p in base.rglob('*') if p.is_dir()),key=lambda p:len(p.parts),reverse=True):
                    directory.parent.chmod(directory.parent.stat().st_mode | 0o200);directory.rmdir()
                base.parent.chmod(base.parent.stat().st_mode | 0o200);base.rmdir()
                report['deletedGenerations'].append(str(base))
        if referenced(root)!=(protected,pointers):raise ValueError('pointer_changed')
        report['freeBytesAfter']=shutil.disk_usage(root).free
        report['reclaimedBytes']=report['freeBytesAfter']-report['freeBytesBefore']
        report['status']='applied' if apply else 'dry_run'
        return report

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--candidate',required=True);parser.add_argument('--apply',action='store_true');parser.add_argument('--receipt',required=True)
    args=parser.parse_args()
    import boto3
    result=prune('/var/app/data/fact-os','/var/app/data/fact-os-leases',json.loads(Path(args.candidate).read_text()),boto3.client('s3',region_name='us-east-1'),'thesisforge-production-378477120101-us-east-1',apply=args.apply)
    Path(args.receipt).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
