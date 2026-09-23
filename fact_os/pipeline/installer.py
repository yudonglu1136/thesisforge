"""Install only manifest-listed public data; atomically activate after probes."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import uuid
from ..store import Store,checksum
from .contracts import digest,encode
from .checks import validate_canonical


def download(s3,bucket,entry,target):
    if target.exists():
        if target.stat().st_size!=entry['bytes'] or checksum(target)!=entry['sha256']:
            raise ValueError('installed_object_conflict')
        return
    target.parent.mkdir(parents=True,exist_ok=True)
    temporary=target.with_name(target.name+'.part')
    # Interrupted incomplete bytes are not trusted or combined with new objects.
    with temporary.open('wb') as stream:
        s3.download_fileobj(bucket,entry['key'],stream)
        stream.flush();os.fsync(stream.fileno())
    if temporary.stat().st_size!=entry['bytes'] or checksum(temporary)!=entry['sha256']:
        raise ValueError('download_checksum_mismatch')
    temporary.replace(target)


def safe_member(base,relative):
    relative=Path(relative)
    if relative.is_absolute() or not relative.parts or '..' in relative.parts:
        raise ValueError('install_path_escape')
    path=base/relative
    if any(part.is_symlink() for part in (path,*path.parents)):
        raise ValueError('install_path_escape')
    if not path.resolve().is_relative_to(base.resolve()):raise ValueError('install_path_escape')
    return path


def reusable_file(root,previous,name,relative,entry):
    """Reuse only immutable public bytes from the exact previous group.

    Never scan the API filesystem, user stores, or follow a saved root outside
    the release namespace. Verify content before sharing an inode; neither
    release is edited afterwards and rollback retains both names.
    """
    prior=(previous or {}).get('groups',{}).get(name,{})
    generation=prior.get('generationId','')
    if len(generation)!=64 or any(c not in 'abcdef0123456789' for c in generation):return None
    base=root/'releases'/name/generation
    if prior.get('root')!=str(base):return None
    path=safe_member(base,relative)
    if (path.is_file() and not path.stat().st_mode & 0o222
            and path.stat().st_size==entry['bytes'] and checksum(path)==entry['sha256']):return path
    return None


def install(s3,bucket,candidate,root,*,validate_group,probe,expected_release=None,
            reserve_bytes=1024**3):
    root=Path(root).resolve();root.mkdir(parents=True,exist_ok=True)
    # The base must be root-owned and traverseable by the actual API account.
    root.chmod(0o755)
    with (root/'install.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        active=root/'active.json'
        previous=json.loads(active.read_text()) if active.exists() else None
        if (previous or {}).get('releaseId')!=expected_release:
            if (previous or {}).get('releaseId')!=candidate['releaseId']: raise ValueError('installer_fence_conflict')
        groups={};plans=[];required_bytes=0
        for name,item in candidate['groups'].items():
            raw=s3.get_object(Bucket=bucket,Key=item['manifestKey'])['Body'].read()
            if hashlib.sha256(raw).hexdigest()!=item['manifestSha256']: raise ValueError('group_manifest_checksum_mismatch')
            manifest=json.loads(raw)
            if manifest['groupId']!=name or manifest['generationId']!=item['generationId']: raise ValueError('group_identity_mismatch')
            if not name.replace('_','').isalnum() or len(name)>64 or len(item['generationId'])!=64 or not all(c in 'abcdef0123456789' for c in item['generationId']):
                raise ValueError('invalid_group_path')
            target=root/'releases'/name/item['generationId']
            stage=target if target.exists() else target.with_name(target.name+'.part')
            members=[]
            for entry in manifest['files']:
                sha=entry['sha256']
                if (len(sha)!=64 or any(c not in 'abcdef0123456789' for c in sha)
                        or type(entry['bytes']) is not int or entry['bytes']<0
                        or entry['key']!='fact-os/published/objects/'+sha):
                    raise ValueError('invalid_install_object')
                path=safe_member(stage,entry['path'])
                reuse=None if path.exists() else reusable_file(root,previous,name,entry['path'],entry)
                if not path.exists() and reuse is None:required_bytes+=entry['bytes']
                members.append((entry,path,reuse))
            plans.append((name,item,manifest,target,stage,members))
        # Check the complete candidate before writing any payload. Leave room
        # for live SQLite journals, logs and rollback; never GC to pass a gate.
        if reserve_bytes<0 or shutil.disk_usage(root).free<required_bytes+reserve_bytes:
            raise ValueError('insufficient_install_capacity')
        for name,item,manifest,target,stage,members in plans:
            stage.mkdir(parents=True,exist_ok=True)
            for entry,path,reuse in members:
                if reuse is not None:
                    path.parent.mkdir(parents=True,exist_ok=True)
                    os.link(reuse,path)
                else:download(s3,bucket,entry,path)
            if stage!=target: stage.rename(target)
            for directory,_,files in os.walk(target):
                for file in files: (Path(directory)/file).chmod(0o444)
                Path(directory).chmod(0o555)
            # Parent dirs are part of the permission contract, not just files.
            target.parent.chmod(0o755);target.parent.parent.chmod(0o755)
            validate_group(name,target,manifest)
            groups[name]={'generationId':item['generationId'],'root':str(target),'inputVector':manifest['inputVector']}
        installed={**candidate,'groups':groups}
        # Probe with the real API UID before switching; then probe live request
        # activation. Failures restore only this data pointer, never user stores.
        probe(installed,False)
        prior=active.read_text() if active.exists() else None
        Store._atomic_if_changed(active,encode(installed).decode());active.chmod(0o444)
        try:
            acknowledgement=probe(installed,True)
            if acknowledgement.get('releaseId')!=candidate['releaseId'] or acknowledgement.get('status')!='verified':
                raise ValueError('api_ack_mismatch')
        except Exception:
            if prior is not None: Store._atomic_if_changed(active,prior)
            else: active.unlink(missing_ok=True)
            raise
        return acknowledgement
