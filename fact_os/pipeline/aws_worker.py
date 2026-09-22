"""Fixed AWS entrypoint: source -> accepted catalog -> builds -> install -> ACK."""
import argparse
from datetime import datetime,timezone
import json
import os
from pathlib import Path
import time
from ..contracts import TABLES
from ..store import Store,now
from ..sync import Synchronizer,UpstreamError
from .contracts import encode
from .runner import run
from .publisher import prepare,activate,load_active
from .ledger import Ledger


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--scheduled-for',required=True)
    parser.add_argument('--resume-publication',help='Existing run receipt; no source fetch or build')
    args=parser.parse_args()
    datetime.fromisoformat(args.scheduled_for.replace('Z','+00:00'))
    import boto3
    root=Path(os.environ['FACT_OS_ROOT']).resolve();store=Store(root)
    if not (root/'sync/authority-import.json').is_file():raise ValueError('authority_migration_required')
    bucket=os.environ['FACT_OS_BUCKET'];s3=boto3.client('s3');ssm=boto3.client('ssm')
    emit=lambda value:print(json.dumps(value),flush=True)
    if args.resume_publication:
        receipt_path=(root/'audit/pipeline'/args.resume_publication).resolve()
        if receipt_path.parent!=root/'audit/pipeline':raise ValueError('receipt_path_invalid')
        receipt=json.loads(receipt_path.read_text())
    else:
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
                receipt=run(store,profile='aws-daily',scheduled_for=args.scheduled_for,failed_sources=failed)
        finally:sync.close()
    # Publication has its own serialized fence even during resume.
    from .cli import ingestion_lock
    with ingestion_lock(store):
        ledger=Ledger(store)
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
