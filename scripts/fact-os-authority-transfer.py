#!/usr/bin/env python3
"""One-time audited authority migration. No raw data enters API release prefixes."""
import argparse
from concurrent.futures import ThreadPoolExecutor,as_completed
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import threading
import subprocess
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from fact_os.store import Store,checksum
from fact_os.pipeline.migration import restore_metadata
from fact_os.pipeline.contracts import encode,digest


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['upload','download'])
    parser.add_argument('--root',required=True,type=Path)
    parser.add_argument('--bucket',required=True)
    parser.add_argument('--manifest',required=True,help='Local manifest path for upload, immutable S3 key for download')
    args=parser.parse_args()
    try:
        import boto3
        from boto3.s3.transfer import TransferConfig
        s3=boto3.client('s3',region_name='us-east-1')
        transfer=TransferConfig(max_concurrency=2,multipart_threshold=64*1024**2,multipart_chunksize=32*1024**2)
    except ImportError:
        if args.action!='upload':raise
        s3=None
    def aws(*command,allow_missing=False):
        result=subprocess.run(['aws','--region','us-east-1',*command],capture_output=True,text=True)
        if result.returncode:
            if allow_missing and ('(404)' in result.stderr or 'Not Found' in result.stderr):return None
            raise ValueError('authority_aws_cli_failed')
        return json.loads(result.stdout) if result.stdout.strip() else {}
    root=args.root.resolve();root.mkdir(parents=True,exist_ok=True)
    manifest=json.loads(Path(args.manifest).read_text()) if args.action=='upload' else json.loads(s3.get_object(Bucket=args.bucket,Key=args.manifest)['Body'].read())
    core={key:manifest[key] for key in ('schemaVersion','metadata','files','bytes','privateDataExcluded')}
    if manifest.get('migrationId')!=digest(core):raise ValueError('authority_manifest_integrity')
    if args.action=='download' and shutil.disk_usage(root).free<manifest['capacity']['targetMinimumFreeBytes']:
        raise ValueError('insufficient_authority_storage_headroom')
    lock=threading.Lock();completed=0;copied=0
    def one(entry):
        nonlocal completed,copied
        relative=Path(entry['path']);path=(root/relative).resolve()
        if relative.is_absolute() or relative.parts[0] not in ('raw','parquet','manifests') or not path.is_relative_to(root):
            raise ValueError('authority_path_escape')
        key='fact-os/authority/objects/'+entry['sha256']
        changed=False
        if args.action=='upload':
            if path.stat().st_size!=entry['bytes'] or checksum(path)!=entry['sha256']: raise ValueError('authority_source_changed')
            if s3:
                try:remote=s3.head_object(Bucket=args.bucket,Key=key)
                except s3.exceptions.ClientError as error:
                    if error.response['Error']['Code'] not in ('404','NoSuchKey'):raise
                    remote=None
            else:remote=aws('s3api','head-object','--bucket',args.bucket,'--key',key,allow_missing=True)
            if remote and (remote['ContentLength']!=entry['bytes'] or remote['Metadata'].get('sha256')!=entry['sha256']):
                raise ValueError('authority_remote_conflict')
            if not remote:
                if s3:s3.upload_file(str(path),args.bucket,key,ExtraArgs={'ServerSideEncryption':'AES256','Metadata':{'sha256':entry['sha256']}},Config=transfer)
                else:aws('s3','cp',str(path),'s3://'+args.bucket+'/'+key,'--sse','AES256','--metadata','sha256='+entry['sha256'],'--only-show-errors')
                changed=True
        else:
            if not path.exists():
                path.parent.mkdir(parents=True,exist_ok=True)
                partial=path.with_name(path.name+'.part')
                s3.download_file(args.bucket,key,str(partial),Config=transfer)
                if checksum(partial)!=entry['sha256'] or partial.stat().st_size!=entry['bytes']:raise ValueError('authority_download_corrupt')
                partial.replace(path);changed=True
            if checksum(path)!=entry['sha256'] or path.stat().st_size!=entry['bytes']:raise ValueError('authority_existing_conflict')
        with lock:
            completed+=1;copied+=entry['bytes'] if changed else 0
            if completed%25==0:print(json.dumps({'phase':args.action,'verifiedFiles':completed,'totalFiles':len(manifest['files']),'copiedBytes':copied}),flush=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        for future in as_completed([pool.submit(one,entry) for entry in manifest['files']]):future.result()
    key='fact-os/authority/manifests/'+manifest['migrationId']+'.json'
    if args.action=='upload':
        content=encode(manifest)
        if s3:s3.put_object(Bucket=args.bucket,Key=key,Body=content,Metadata={'sha256':hashlib.sha256(content).hexdigest()},ServerSideEncryption='AES256')
        else:aws('s3','cp',args.manifest,'s3://'+args.bucket+'/'+key,'--sse','AES256','--only-show-errors')
        result={'status':'uploaded_authority_not_activated','key':key}
    else:
        result=restore_metadata(Store(root),manifest)
    print(json.dumps({**result,'migrationId':manifest['migrationId'],'bytes':manifest['bytes'],'files':completed,'copiedBytes':copied}),flush=True)


if __name__=='__main__':main()
