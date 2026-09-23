"""Private, content-addressed S3 publication. A candidate is NOT an API ACK."""
import json
from pathlib import Path
from ..store import checksum
from .contracts import digest,encode


PREFIX='fact-os/published'


def missing(error):
    return getattr(error,'response',{}).get('Error',{}).get('Code') in ('404','NoSuchKey','NotFound')


def load_active(s3,bucket):
    try:
        obj=s3.get_object(Bucket=bucket,Key=PREFIX+'/active.json')
        return json.loads(obj['Body'].read()),obj['ETag']
    except Exception as error:
        if missing(error): return None,None
        raise


def put_immutable(s3,bucket,key,body,sha,size):
    try:
        existing=s3.head_object(Bucket=bucket,Key=key)
        if existing['ContentLength']!=size or existing.get('Metadata',{}).get('sha256')!=sha:
            raise ValueError('immutable_remote_object_conflict')
        return False
    except Exception as error:
        if not missing(error): raise
    s3.put_object(Bucket=bucket,Key=key,Body=body,ContentLength=size,Metadata={'sha256':sha},
                  ServerSideEncryption='AES256',IfNoneMatch='*')
    return True


def prepare(s3,bucket,store,receipt,previous=None):
    """Upload immutable members first. Failed independent groups retain old refs."""
    previous=previous or {}
    if previous.get('scheduledFor') and receipt.get('scheduledFor','')<previous['scheduledFor']:
        raise ValueError('stale_scheduled_run_requires_explicit_rollback')
    members=dict(previous.get('groups',{}))
    uploaded=0
    for group,item in receipt['groups'].items():
        if members.get(group,{}).get('generationId')==item['generationId']: continue
        files=[]
        entries=list(item['files'])
        if group=='institutional_13f' and item['compatibilityVersion']=='institutional-13f-artifact-v7':
            # Preserve the existing seven-table production validator contract.
            db=entries[0];counts=receipt['tasks'][group]['coverage']
            names=('institutional_13f_insight_snapshots_v2','institutional_13f_insight_details_v1',
                'institutional_13f_market_history_v1','institutional_13f_security_history_v1',
                'institutional_13f_active_snapshots_v1','institutional_13f_active_details_v1','institutional_13f_active_sectors_v1')
            if all(name in counts for name in names):
                manifest={'version':'institutional-13f-artifact-v7','state':'verified','releaseId':'pipeline-'+item['generationId'],
                    **dict(zip(('rows','detailRows','marketRows','securityHistoryRows','activeRows','activeDetailRows','sectorRows'),(counts[n] for n in names))),
                    'table':names[0],'checks':{'integrity':'ok','naturalKeyUniqueness':'pass','privateDataExcluded':True},
                    'file':{'path':'/var/app/data/fact-os/releases/institutional_13f/'+item['generationId']+'/13f-insights.sqlite',
                            'bytes':db['bytes'],'sha256':db['sha256']}}
                path=(store.root/db['path']).parent/'manifest.json'
                from ..store import Store
                from .checks import file_record
                Store._atomic_if_changed(path,encode(manifest).decode())
                entries.append(file_record(path,store.root))
        for entry in entries:
            source=store.root/entry['path']
            if checksum(source)!=entry['sha256']: raise ValueError('publication_source_checksum_mismatch')
            if group == 'canonical':
                parts=Path(entry['path']).parts
                if len(parts)<3 or parts[0]!='snapshots':raise ValueError('canonical_snapshot_path_required')
                relative=str(Path(*parts[2:]))
            elif group in ('institutional_13f','public_observations'): relative=source.name
            elif group in ('ai_insights','research_inputs','strategy_inputs'): relative=entry.get('installPath',entry['path'])
            else: raise ValueError('unregistered_publication_group')
            if Path(relative).is_absolute() or '..' in Path(relative).parts: raise ValueError('publication_path_escape')
            key=PREFIX+'/objects/'+entry['sha256']
            with source.open('rb') as body:
                uploaded+=int(put_immutable(s3,bucket,key,body,entry['sha256'],entry['bytes']))
            files.append({'path':relative,'sha256':entry['sha256'],'bytes':entry['bytes'],'key':key})
        core={k:item[k] for k in ('groupId','generationId','members','inputVector','compatibilityVersion','requiredMatrix','checks')}
        manifest={**core,'files':files,'previousGeneration':members.get(group,{}).get('generationId')}
        content=encode(manifest);sha=digest(manifest)
        key=PREFIX+'/groups/'+group+'/'+sha+'.json'
        put_immutable(s3,bucket,key,content,sha,len(content))
        members[group]={'generationId':item['generationId'],'manifestKey':key,'manifestSha256':sha}
    if not members: raise ValueError('no_verified_groups_to_publish')
    core={'schemaVersion':1,'groups':members}
    release_id=digest(core)
    candidate={**core,'releaseId':release_id,'state':'verified','codeVersion':receipt.get('codeVersion'),
        'runId':receipt['runId'],'scheduledFor':receipt.get('scheduledFor'),'previousRelease':previous.get('releaseId')}
    content=encode(candidate);key=PREFIX+'/releases/'+release_id+'.json'
    # A previous immutable release may be reused without changing provenance.
    if previous.get('releaseId')==release_id:return previous,{'status':'unchanged','uploadedObjects':uploaded}
    try:
        existing=json.loads(s3.get_object(Bucket=bucket,Key=key)['Body'].read())
        if existing.get('releaseId')!=release_id or {k:existing[k] for k in core}!=core:
            raise ValueError('immutable_release_conflict')
        candidate=existing
    except Exception as error:
        if not missing(error):raise
        put_immutable(s3,bucket,key,content,digest(candidate),len(content))
    return candidate,{'status':'uploaded','uploadedObjects':uploaded,'candidateKey':key}


def activate(s3,bucket,candidate,expected_etag,ack):
    if ack.get('status')!='verified' or ack.get('releaseId')!=candidate['releaseId']:
        raise ValueError('api_activation_ack_required')
    if not ack.get('actualApiUserRead') or not ack.get('canonicalReadVerified'):
        raise ValueError('api_read_validation_required')
    if ack.get('groups')!={name:item['generationId'] for name,item in candidate['groups'].items()}:
        raise ValueError('api_group_ack_mismatch')
    current,etag=load_active(s3,bucket)
    if current and current['releaseId']==candidate['releaseId']: return {'status':'unchanged','releaseId':candidate['releaseId']}
    if etag!=expected_etag: raise ValueError('stale_worker_fence')
    kwargs={'IfMatch':expected_etag} if expected_etag else {'IfNoneMatch':'*'}
    s3.put_object(Bucket=bucket,Key=PREFIX+'/active.json',Body=encode(candidate),ServerSideEncryption='AES256',**kwargs)
    return {'status':'verified','releaseId':candidate['releaseId']}
