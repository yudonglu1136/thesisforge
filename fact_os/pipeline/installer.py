"""Install only manifest-listed public data; atomically activate after probes."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
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


def install(s3,bucket,candidate,root,*,validate_group,probe,expected_release=None):
    root=Path(root).resolve();root.mkdir(parents=True,exist_ok=True)
    # The base must be root-owned and traverseable by the actual API account.
    root.chmod(0o755)
    with (root/'install.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        active=root/'active.json'
        previous=json.loads(active.read_text()) if active.exists() else None
        if (previous or {}).get('releaseId')!=expected_release:
            if (previous or {}).get('releaseId')!=candidate['releaseId']: raise ValueError('installer_fence_conflict')
        groups={}
        for name,item in candidate['groups'].items():
            raw=s3.get_object(Bucket=bucket,Key=item['manifestKey'])['Body'].read()
            if hashlib.sha256(raw).hexdigest()!=item['manifestSha256']: raise ValueError('group_manifest_checksum_mismatch')
            manifest=json.loads(raw)
            if manifest['groupId']!=name or manifest['generationId']!=item['generationId']: raise ValueError('group_identity_mismatch')
            if not name.replace('_','').isalnum() or len(name)>64 or not all(c in 'abcdef0123456789' for c in item['generationId']):
                raise ValueError('invalid_group_path')
            target=root/'releases'/name/item['generationId']
            stage=target if target.exists() else target.with_name(target.name+'.part')
            stage.mkdir(parents=True,exist_ok=True)
            for entry in manifest['files']:
                path=(stage/entry['path']).resolve()
                if not path.is_relative_to(stage.resolve()) or path.is_symlink(): raise ValueError('install_path_escape')
                download(s3,bucket,entry,path)
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
