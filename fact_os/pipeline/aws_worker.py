"""Fixed AWS entrypoint: source -> accepted catalog -> builds -> install -> ACK."""
import argparse
from datetime import datetime,timezone
import json
import os
from pathlib import Path
import shutil
import time
from ..contracts import TABLES
from ..store import Store,now
from ..sync import Synchronizer,UpstreamError
from .contracts import encode
from .runner import run
from .publisher import prepare,activate,load_active,missing
from .ledger import Ledger
from .registry import DATA_DAILY_GROUPS


DATA_READY_KEY='fact-os/data-ready/latest.json'


def load_data_ready(s3,bucket):
    try:
        obj=s3.get_object(Bucket=bucket,Key=DATA_READY_KEY)
        value=json.loads(obj['Body'].read())
        if value.get('dataSyncStatus')!='verified' or value.get('actualApiActivation')!='not_requested':
            raise ValueError('invalid_data_ready_pointer')
        return value,obj['ETag']
    except Exception as error:
        if missing(error):return None,None
        raise


def mark_data_ready(s3,bucket,receipt,candidate,expected_etag):
    """Independent data-only ACK. Never writes the serving/API active pointer."""
    if receipt.get('profile')!='aws-data-daily' or receipt.get('status') not in ('succeeded','no_change'):
        raise ValueError('data_daily_run_not_complete')
    if receipt.get('failedSources') or set(receipt.get('sources',{}))!=set(TABLES) or any(
            v.get('status')!='ready' for v in receipt['sources'].values()):
        raise ValueError('fourteen_verified_sources_required')
    if set(receipt.get('tasks',{}))!=DATA_DAILY_GROUPS or any(
            v.get('status') not in ('succeeded','unchanged') for v in receipt['tasks'].values()):
        raise ValueError('data_daily_tasks_not_complete')
    if set(candidate.get('groups',{}))!=DATA_DAILY_GROUPS or any(
            candidate['groups'][k]['generationId']!=receipt.get('groups',{}).get(k,{}).get('generationId')
            for k in DATA_DAILY_GROUPS):
        raise ValueError('data_daily_group_mismatch')
    value={'schemaVersion':1,'dataSyncStatus':'verified','actualApiActivation':'not_requested',
        'runId':receipt['runId'],'scheduledFor':receipt['scheduledFor'],'verifiedAt':now(),
        'candidate':candidate,'deferredTasks':['guru_strict','valuation_candidates']}
    fence={'IfMatch':expected_etag} if expected_etag else {'IfNoneMatch':'*'}
    s3.put_object(Bucket=bucket,Key=DATA_READY_KEY,Body=encode(value),ServerSideEncryption='AES256',**fence)
    return value


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--scheduled-for',required=True)
    parser.add_argument('--resume-publication',help='Existing run receipt; no source fetch or build')
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--stage-only',action='store_true',help='Validate on isolated worker; explicitly do not install or activate API data')
    modes.add_argument('--data-only',action='store_true',help='Daily 14-table sync and automatic derived artifacts; defer reviewed models/backtests and do not activate API')
    args=parser.parse_args()
    datetime.fromisoformat(args.scheduled_for.replace('Z','+00:00'))
    import boto3
    root=Path(os.environ['FACT_OS_ROOT']).resolve();store=Store(root)
    os.environ['FACT_OS_TEMP_ROOT']=str(root/'staging/query-spill')
    code_file=Path(__file__).resolve().parents[2]/'CODE_COMMIT'
    code_commit=code_file.read_text().strip() if code_file.is_file() else None
    if code_commit is not None and (len(code_commit)!=40 or any(c not in 'abcdef0123456789' for c in code_commit)):
        raise ValueError('invalid_installed_code_commit')
    if not (root/'sync/authority-import.json').is_file():raise ValueError('authority_migration_required')
    bucket=os.environ['FACT_OS_BUCKET'];s3=boto3.client('s3');ssm=boto3.client('ssm')
    emit=lambda value:print(json.dumps(value),flush=True)
    if args.resume_publication:
        receipt_path=(root/'audit/pipeline'/args.resume_publication).resolve()
        if receipt_path.parent!=root/'audit/pipeline':raise ValueError('receipt_path_invalid')
        receipt=json.loads(receipt_path.read_text())
        if args.scheduled_for!=receipt.get('scheduledFor'):
            raise ValueError('resume_schedule_mismatch')
        if args.data_only and receipt.get('profile')!='aws-data-daily':
            raise ValueError('data_daily_resume_profile_mismatch')
    else:
        # Conservative launch budget for raw staging, changed partitions and
        # builds. Retention is deliberate: never delete archives/pins to make
        # a scheduled run green. Recheck actual capacity on every invocation.
        free=shutil.disk_usage(root).free
        budget={'scheduledFor':args.scheduled_for,'checkedAt':now(),
                'freeBytes':free,'estimatedAdditionalBytes':8*1024**3,
                'reserveBytes':8*1024**3,'sourceFetchStarted':False,
                'status':'ready' if free>=16*1024**3 else 'blocked',
                'retention':'preserve_raw_archives_saved_snapshots_and_rollback'}
        (root/'audit/pipeline').mkdir(parents=True,exist_ok=True)
        Store._atomic_if_changed(root/'audit/pipeline/capacity-latest.json',encode(budget).decode())
        emit({'phase':'capacity',**budget})
        if budget['status']=='blocked':return 2
        key=boto3.client('secretsmanager').get_secret_value(SecretId=os.environ['FACT_OS_SECRET_ID'])['SecretString']
        if not key or key=='test-api-key':raise ValueError('paid_native_key_required')
        sync=Synchronizer(store,key,progress=emit);del key
        failed=[]
        try:
            with sync.job_lock():
                store.recover_catalog()
                for table in TABLES:
                    try:emit({'phase':'source','table':table,**sync.sync(table)})
                    except Exception as error:
                        code=str(error) if isinstance(error,UpstreamError) else type(error).__name__
                        store.record_error(table,code);failed.append(table)
                        emit({'phase':'source','table':table,'status':'failed','code':code})
                receipt={**run(store,profile='aws-data-daily' if args.data_only else 'aws-daily',scheduled_for=args.scheduled_for,failed_sources=failed),
                         'workerCodeCommit':code_commit}
        finally:sync.close()
    # Publication has its own serialized fence even during resume.
    from .cli import ingestion_lock
    with ingestion_lock(store):
        ledger=Ledger(store)
        if args.stage_only or args.data_only:
            try:
                ready,ready_etag=load_data_ready(s3,bucket) if args.data_only else (None,None)
                previous=ready['candidate'] if ready else None
                if ready and receipt['scheduledFor']<ready['scheduledFor']:
                    raise ValueError('stale_data_daily_run')
                if not args.data_only:previous,_=load_active(s3,bucket)
                candidate,upload=prepare(s3,bucket,store,receipt,previous)
                if args.data_only:
                    # Upload and record every required group before marking the
                    # DATA contract complete. API activation is a separate gate.
                    mark_data_ready(s3,bucket,receipt,candidate,ready_etag)
            except Exception as error:
                failure={'errorType':type(error).__name__,'failedAt':now()}
                ledger.publication(receipt,'failed',failure)
                failed={**receipt,'publicationStatus':'failed','publicationFailure':failure}
                Store._atomic_if_changed(root/'audit/pipeline'/(receipt['runId']+'.json'),encode(failed).decode())
                Store._atomic_if_changed(root/'audit/pipeline/latest.json',encode(failed).decode())
                emit({'phase':'staging','runId':receipt['runId'],'status':'failed',**failure})
                return 2
            ledger.publication(receipt,'staged_not_activated',{'reason':'daily_data_only' if args.data_only else 'operator_requested_isolated_verification',
                'candidateReleaseId':candidate['releaseId']})
            staged={**receipt,'publicationStatus':'staged_not_activated','candidateReleaseId':candidate['releaseId'],
                    'upload':upload,'actualApiActivation':'not_requested' if args.data_only else 'not_attempted',
                    'publicationWorkerCodeCommit':code_commit,
                    **({'dataSyncStatus':'verified','deferredTasks':['guru_strict','valuation_candidates']} if args.data_only else {})}
            Store._atomic_if_changed(root/'audit/pipeline'/(receipt['runId']+'.json'),encode(staged).decode())
            Store._atomic_if_changed(root/'audit/pipeline/latest.json',encode(staged).decode())
            s3.put_object(Bucket=bucket,Key='fact-os/runs/'+receipt['runId']+'.json',Body=encode(staged),ServerSideEncryption='AES256')
            emit({'phase':'final','runId':receipt['runId'],'status':receipt['status'],'publicationStatus':'staged_not_activated',
                  'candidateReleaseId':candidate['releaseId'],
                  **({'dataSyncStatus':'verified','actualApiActivation':'not_requested'} if args.data_only else {})})
            return 0 if args.data_only else 2
        ledger.publication(receipt,'uploading',{})
        try:
            return publish(store,receipt,s3,ssm,bucket,emit,ledger)
        except Exception as error:
            # Provider/SDK errors may contain signed URLs. Persist only the
            # bounded failure class; command ids are recorded before waiting.
            failure={'status':'failed','errorType':type(error).__name__,'failedAt':now()}
            ledger.publication(receipt,'failed',failure)
            failed={**receipt,'publicationStatus':'failed','publicationFailure':failure}
            Store._atomic_if_changed(root/'audit/pipeline'/(receipt['runId']+'.json'),encode(failed).decode())
            Store._atomic_if_changed(root/'audit/pipeline/latest.json',encode(failed).decode())
            emit({'phase':'publication','runId':receipt['runId'],**failure})
            return 2


def publish(store,receipt,s3,ssm,bucket,emit,ledger):
        root=store.root
        previous,etag=load_active(s3,bucket)
        candidate,upload=prepare(s3,bucket,store,receipt,previous)
        emit({'phase':'publication',**upload,'releaseId':candidate['releaseId']})
        config={'apiInstanceId':os.environ['FACT_OS_API_INSTANCE_ID'],'installDocument':os.environ['FACT_OS_INSTALL_DOCUMENT']}
        command=ssm.send_command(InstanceIds=[config['apiInstanceId']],DocumentName=config['installDocument'],DocumentVersion=os.environ['FACT_OS_INSTALL_DOCUMENT_VERSION'],
            Parameters={'ReleaseKey':['fact-os/published/releases/'+candidate['releaseId']+'.json'],
                        'ExpectedRelease':[(previous or {}).get('releaseId') or 'none']},TimeoutSeconds=600)
        command_id=command['Command']['CommandId'];deadline=time.monotonic()+3600
        ledger.publication(receipt,'installing',{'commandId':command_id,'releaseId':candidate['releaseId']})
        while time.monotonic()<deadline:
            time.sleep(15)
            try:status=ssm.get_command_invocation(CommandId=command_id,InstanceId=config['apiInstanceId'])
            except ssm.exceptions.InvocationDoesNotExist:continue
            if status['Status'] in ('Pending','InProgress','Delayed'):continue
            if status['Status']!='Success':raise ValueError('api_install_or_activation_failed:'+command_id)
            ack=json.loads(status['StandardOutputContent'].strip().splitlines()[-1]);break
        else:raise ValueError('api_install_timeout:'+command_id)
        result=activate(s3,bucket,candidate,etag,ack)
        ledger.publication(receipt,'verified',{'releaseId':candidate['releaseId'],'ack':ack})
        final={**receipt,'publicationStatus':'verified','releaseId':candidate['releaseId'],'ack':ack,'verifiedAt':now()}
        Store._atomic_if_changed(root/'audit/pipeline'/(receipt['runId']+'.json'),encode(final).decode())
        Store._atomic_if_changed(root/'audit/pipeline/latest.json',encode(final).decode())
        s3.put_object(Bucket=bucket,Key='fact-os/runs/'+receipt['runId']+'.json',Body=encode(final),ServerSideEncryption='AES256')
        emit({'phase':'final','runId':receipt['runId'],'status':receipt['status'],'publication':result})
        # Scheduling/transport success cannot hide incomplete required consumers.
        return 0 if receipt['status'] in ('succeeded','no_change') else 2


if __name__=='__main__':
    raise SystemExit(main())
