"""Explicit and rolling retired API release eviction; immutable S3 restoration is required."""
import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
import uuid

PROJECT = Path(__file__).resolve().parents[1]
if str(PROJECT) not in sys.path:
    sys.path.insert(0, str(PROJECT))

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
    for name in ('active.json','research-active.json','rollback-active.json'):
        path=root/name
        if path.exists():
            raw=path.read_bytes();identities[name]=hashlib.sha256(raw).hexdigest()
            value=json.loads(raw)
            for group,item in value.get('groups',{}).items():refs.add((group,item['generationId']))
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
    proc=Path('/proc')
    if not targets or not proc.is_dir():return
    for process in proc.iterdir():
        if not process.name.isdigit():continue
        try:
            for fd in (process/'fd').iterdir():
                try: value=os.readlink(fd)
                except (FileNotFoundError,PermissionError,ProcessLookupError):continue
                if any(value==str(p) or value.startswith(str(p)+'/') for p in targets):raise ValueError('open_reader')
        except (FileNotFoundError,PermissionError,ProcessLookupError):continue

def prune(root,lease_root,candidate,s3,bucket,*,apply=False,retired_failed_generation=None,retired_generation=None,
          retention_days=7,extra_protected=None,remote_checked=None):
    root=Path(root).resolve();lease_root=Path(lease_root).resolve()
    if retention_days<0:raise ValueError('invalid_retention_days')
    if retired_generation is not None and retired_failed_generation is not None:
        raise ValueError('ambiguous_retirement_override')
    retirement = retired_generation if retired_generation is not None else retired_failed_generation
    if retirement is not None and (
            not HEX.fullmatch(retirement) or len(candidate['groups'])!=1 or
            next(iter(candidate['groups'].values()))['generationId']!=retirement):
        raise ValueError('invalid_failed_generation_override')
    report={'applied':apply,'deletedFiles':0,'deletedGenerations':[],'restorableFromS3':True,
            'retiredFailedGeneration':retired_failed_generation,'operatorRetiredGeneration':retired_generation}
    extra=set(extra_protected or ())
    checked=remote_checked if remote_checked is not None else set()
    with ExitStack() as stack:
        lock=stack.enter_context((root/'install.lock').open('a'));fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        protected,pointers=referenced(root);report['pointerChecksums']=pointers
        plans=[]
        for group,item in candidate['groups'].items():
            generation=item['generationId']
            if group not in GROUPS or not HEX.fullmatch(generation):raise ValueError('invalid_generation')
            if (group,generation) in protected or (group,generation) in extra:raise ValueError('active_reference')
            base=member(root,'releases/'+group+'/'+generation)
            if not base.exists():continue
            # Explicit operator retirement or post-ACK rolling window beyond active+rollback
            # may adjust age check; every reference, lease, open-fd, and S3 checksum gate remains.
            if retention_days>0 and generation!=retirement and base.stat().st_mtime>time.time()-retention_days*86400:
                raise ValueError('retention_window')
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
                if key in checked:continue
                response=s3.get_object(Bucket=bucket,Key=key);h=hashlib.sha256();size=0
                with response['Body'] as body:
                    for chunk in iter(lambda:body.read(1024*1024),b''):h.update(chunk);size+=len(chunk)
                if size!=entry['bytes'] or h.hexdigest()!=sha:raise ValueError('remote_restore_checksum')
                checked.add(key)
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


def _load_release_descriptor(root, s3, bucket, release_id):
    if not HEX.fullmatch(release_id or ''):
        return None
    cached = root / 'audit/installed-candidates' / (release_id + '.json')
    if cached.is_file() and not cached.is_symlink():
        try:
            value = json.loads(cached.read_text())
            if value.get('releaseId') == release_id and isinstance(value.get('groups'), dict):
                return value
        except Exception:
            pass
    try:
        raw = s3.get_object(Bucket=bucket, Key='fact-os/published/releases/' + release_id + '.json')['Body'].read()
        value = json.loads(raw)
        if value.get('releaseId') == release_id and isinstance(value.get('groups'), dict):
            return value
    except Exception:
        return None
    return None


def _load_deduplicator():
    dedup_path = Path(__file__).with_name('deduplicate-canonical-release-files.py')
    spec = importlib.util.spec_from_file_location('fact_os_canonical_dedup', dedup_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.consolidate


def prune_superseded_releases(root, lease_root, s3, bucket, *, keep_releases=2, max_chain_depth=24, apply=False):
    """Retain active + immediate rollback(s) + research-active; S3-verify and evict older generations."""
    if keep_releases < 2:
        raise ValueError('minimum_two_releases_required')
    root = Path(root).resolve()
    lease_root = Path(lease_root).resolve()
    lease_root.mkdir(parents=True, exist_ok=True)
    active_path = root / 'active.json'
    if not active_path.is_file():
        free_now = shutil.disk_usage(root).free if root.exists() else 0
        return {
            'status': 'no_active_release',
            'applied': apply,
            'keepReleases': keep_releases,
            'activeReleaseId': None,
            'protectedGroupCount': 0,
            'deletedFiles': 0,
            'prunedGenerations': [],
            'deferredGenerations': [],
            'canonicalDedupReplacedPaths': 0,
            'freeBytesBefore': free_now,
            'freeBytesAfter': free_now,
            'reclaimedBytes': 0,
        }

    active = json.loads(active_path.read_text())
    protected, _ = referenced(root)

    local_generations = set()
    releases_root = root / 'releases'
    if releases_root.is_dir() and not releases_root.is_symlink():
        for grp in GROUPS:
            grp_dir = releases_root / grp
            if grp_dir.is_dir() and not grp_dir.is_symlink():
                for entry in grp_dir.iterdir():
                    if entry.is_dir() and not entry.is_symlink() and HEX.fullmatch(entry.name):
                        local_generations.add((grp, entry.name))

    eviction_descriptors = {}
    visited = set()
    cursor = active.get('releaseId')
    depth = 0
    while cursor and HEX.fullmatch(cursor) and cursor not in visited and depth < max_chain_depth:
        visited.add(cursor)
        descriptor = _load_release_descriptor(root, s3, bucket, cursor)
        if descriptor is None:
            break
        if depth < keep_releases:
            for grp, item in descriptor.get('groups', {}).items():
                gen = item.get('generationId')
                if grp in GROUPS and HEX.fullmatch(gen or ''):
                    protected.add((grp, gen))
        else:
            for grp, item in descriptor.get('groups', {}).items():
                gen = item.get('generationId')
                if (
                    grp in GROUPS
                    and HEX.fullmatch(gen or '')
                    and (grp, gen) in local_generations
                    and (grp, gen) not in protected
                    and (grp, gen) not in eviction_descriptors
                    and 'manifestKey' in item
                    and 'manifestSha256' in item
                ):
                    eviction_descriptors[(grp, gen)] = item
        unaccounted = (local_generations - protected) - set(eviction_descriptors)
        if depth >= keep_releases - 1 and not unaccounted:
            break
        cursor = descriptor.get('previousRelease')
        depth += 1

    # Also check locally cached installed-candidate descriptors for off-chain superseded installations.
    unaccounted = (local_generations - protected) - set(eviction_descriptors)
    catalog_dir = root / 'audit/installed-candidates'
    if unaccounted and catalog_dir.is_dir() and not catalog_dir.is_symlink():
        for descriptor_file in sorted(catalog_dir.glob('*.json')):
            if descriptor_file.is_symlink():
                continue
            try:
                descriptor = json.loads(descriptor_file.read_text())
            except Exception:
                continue
            for grp, item in (descriptor.get('groups') or {}).items():
                gen = item.get('generationId') if isinstance(item, dict) else None
                if (
                    grp in GROUPS
                    and HEX.fullmatch(gen or '')
                    and (grp, gen) in unaccounted
                    and 'manifestKey' in item
                    and 'manifestSha256' in item
                ):
                    eviction_descriptors[(grp, gen)] = item

    free_before = shutil.disk_usage(root).free
    remote_checked = set()
    pruned_generations = []
    deferred_generations = []
    deleted_files = 0

    for (grp, gen), item in sorted(eviction_descriptors.items()):
        if (grp, gen) in protected:
            continue
        try:
            res = prune(
                root,
                lease_root,
                {'groups': {grp: item}},
                s3,
                bucket,
                apply=apply,
                retention_days=0,
                extra_protected=protected,
                remote_checked=remote_checked,
            )
            deleted_files += res['deletedFiles']
            pruned_generations.extend(res['deletedGenerations'] if apply else res['candidates'])
        except BlockingIOError:
            deferred_generations.append({'group': grp, 'generationId': gen, 'reason': 'lease_busy'})
        except ValueError as exc:
            if str(exc) in ('open_reader', 'active_reference'):
                deferred_generations.append({'group': grp, 'generationId': gen, 'reason': str(exc)})
            else:
                raise

    dedup = {'replacedPaths': [], 'plannedPaths': 0}
    if (root / 'releases/canonical').is_dir():
        consolidate = _load_deduplicator()
        dedup = consolidate(root, apply=False)
        if apply and dedup.get('plannedPaths', 0) > 0:
            dedup = consolidate(root, apply=True)
            audit_dir = root / 'audit'
            if audit_dir.is_dir():
                dedup_receipts = sorted(audit_dir.glob('canonical-inode-dedup-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
                for stale in dedup_receipts[32:]:
                    stale.unlink(missing_ok=True)
    free_after = shutil.disk_usage(root).free

    report = {
        'status': 'applied' if apply else 'dry_run',
        'keepReleases': keep_releases,
        'activeReleaseId': active.get('releaseId'),
        'protectedGroupCount': len(protected),
        'deletedFiles': deleted_files,
        'prunedGenerations': pruned_generations,
        'deferredGenerations': deferred_generations,
        'canonicalDedupReplacedPaths': len(dedup.get('replacedPaths', [])),
        'freeBytesBefore': free_before,
        'freeBytesAfter': free_after,
        'reclaimedBytes': max(0, free_after - free_before) if apply else 0,
    }
    if apply:
        audit_dir = root / 'audit'
        audit_dir.mkdir(parents=True, exist_ok=True)
        temp = audit_dir / ('.api-retention-' + uuid.uuid4().hex + '.tmp')
        try:
            with temp.open('x') as stream:
                json.dump(report, stream, indent=2, sort_keys=True)
                stream.write('\n')
                stream.flush()
                os.fsync(stream.fileno())
            temp.replace(audit_dir / 'api-retention-latest.json')
        finally:
            temp.unlink(missing_ok=True)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--candidate',help='Explicit candidate JSON to prune')
    mode.add_argument('--auto-retain',action='store_true',help='Retain active + rollback releases and prune superseded generations')
    parser.add_argument('--keep-releases',type=int,default=2)
    parser.add_argument('--root',default='/var/app/data/fact-os')
    parser.add_argument('--lease-root',default='/var/app/data/fact-os-leases')
    parser.add_argument('--bucket',default='thesisforge-production-378477120101-us-east-1')
    parser.add_argument('--region',default='us-east-1')
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--receipt',required=True)
    args=parser.parse_args()
    import boto3
    s3_client=boto3.client('s3',region_name=args.region)
    if args.auto_retain:
        result=prune_superseded_releases(args.root,args.lease_root,s3_client,args.bucket,keep_releases=args.keep_releases,apply=args.apply)
    else:
        result=prune(args.root,args.lease_root,json.loads(Path(args.candidate).read_text()),s3_client,args.bucket,apply=args.apply)
    Path(args.receipt).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
