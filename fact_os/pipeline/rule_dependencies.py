"""Acquire public rule dependencies before offline planning; never on the API.

The single worker lock owns this step. Small immutable inputs are archived and
then hardlinked into the run snapshot. No private data or credentials are used.
"""
import csv
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import urllib.request
from ..store import Store,checksum
from .contracts import digest
from .registry import PROJECT
from .publisher import load_active
from .snapshots import freeze

BOOTSTRAP='fact-os/published/rule-ledgers/2e12b6a17897b9e8aa0fc295bd964e97096255ba92edb973ccf40738a6b1afbd/'


def archived(store,label,data,suffix):
    sha=hashlib.sha256(data).hexdigest()
    path=store.root/'raw'/f'{label}-{sha}.{suffix}'
    if path.exists():
        if checksum(path)!=sha:raise ValueError('public_input_archive_corrupt')
    else:
        path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('xb') as f:f.write(data)
    return path


def external_input(files,*,as_of=None):
    records=[{'source':str(path),'path':relative,'bytes':path.stat().st_size,'sha256':checksum(path)}
             for relative,path in sorted(files.items())]
    identity=[{k:v for k,v in row.items() if k!='source'} for row in records]
    return {'status':'ready','schema':'rule-external-files-v1','contentVersion':digest(identity),
            'sourceAsOf':as_of,'files':records}


def acquire(store,s3,bucket,cutoff,*,fetch=None):
    """Fail closed: a source outage is not permission to use an undated rate."""
    fetch=fetch or (lambda url:urllib.request.urlopen(urllib.request.Request(url,
        headers={'User-Agent':'ThesisForge public research contact@thesisforge.tech'}),timeout=60).read(4*1024*1024+1))
    raw=fetch('https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10')
    if len(raw)>4*1024*1024:raise ValueError('rates_response_too_large')
    rows=list(csv.DictReader(io.StringIO(raw.decode('utf-8-sig'))))
    sys.path.insert(0,str(PROJECT/'scripts'))
    from rule_daily_dependencies import rate_at
    rate=rate_at(rows,cutoff)
    rate_file=archived(store,'dgs_ten',raw,'csv')
    # SEC adapter resolves exact CUSIPs using a pinned canonical catalog. Its
    # archived responses are independent of the Sharadar source entitlement.
    pinned=freeze(store,code_version='rule-external-acquisition-v1')
    staging=store.root/'staging/rule-dependencies'/digest([pinned.snapshotId,cutoff])
    staging.mkdir(parents=True,exist_ok=True)
    qqq=staging/'qqq.json'
    env={'PATH':__import__('os').environ['PATH'],'PYTHONPATH':str(PROJECT)}
    with (staging/'sec.log').open('wb') as log:
        result=subprocess.run([sys.executable,str(PROJECT/'scripts/build-sec-qqq-universe.py'),
            '--fact-root',pinned.root,'--archive',str(store.root/'raw/sec-qqq'),
            '--output',str(qqq),'--as-of',cutoff],env=env,cwd=PROJECT,stdout=log,stderr=subprocess.STDOUT,timeout=900)
    if result.returncode:raise ValueError('qqq_public_source_failed')
    value=json.loads(qqq.read_text())
    if value.get('unresolved') or not value.get('snapshots'):raise ValueError('qqq_identity_incomplete')
    # File handed to freeze must not be the mutable staging name.
    fixed=staging/(checksum(qqq)+'.json')
    if not fixed.exists():Store._atomic_if_changed(fixed,qqq.read_text())
    parent={}
    active,_=load_active(s3,bucket)
    reference=(active or {}).get('groups',{}).get('strategy_inputs')
    if reference:
        data=s3.get_object(Bucket=bucket,Key=reference['manifestKey'])['Body'].read()
        if hashlib.sha256(data).hexdigest()!=reference['manifestSha256']:raise ValueError('parent_manifest_checksum')
        manifest=json.loads(data)
        if manifest['compatibilityVersion']=='rule-portfolio-bundle-v1':
            parent_root=store.root/'derived/rule-parents'/reference['generationId']
            for item in manifest['files']:
                relative=Path(item['path'])
                if relative.is_absolute() or '..' in relative.parts:raise ValueError('parent_path_escape')
                if item['key']!='fact-os/published/objects/'+item['sha256']:raise ValueError('parent_object_namespace')
                target=parent_root/relative;target.parent.mkdir(parents=True,exist_ok=True)
                if not target.exists():
                    body=s3.get_object(Bucket=bucket,Key=item['key'])['Body'].read()
                    if len(body)!=item['bytes'] or hashlib.sha256(body).hexdigest()!=item['sha256']:raise ValueError('parent_object_checksum')
                    with target.open('xb') as f:f.write(body)
                if checksum(target)!=item['sha256']:raise ValueError('parent_local_checksum')
                parent['external/parent/'+str(relative)]=target
    if not parent:
        # Explicit, reviewed bootstrap ledger. No fresh marks are substituted
        # for the published history. The Node builder replays the whole ledger.
        folder=store.root/'derived/rule-bootstrap'
        folder.mkdir(parents=True,exist_ok=True)
        raw_manifest=s3.get_object(Bucket=bucket,Key=BOOTSTRAP+'manifest.json')['Body'].read()
        manifest=json.loads(raw_manifest)
        for item in manifest['entries'].values():
            name=item['file']
            if Path(name).name!=name:raise ValueError('bootstrap_path_escape')
            target=folder/name
            if not target.exists():
                body=s3.get_object(Bucket=bucket,Key=BOOTSTRAP+name)['Body'].read()
                if len(body)!=item['bytes'] or hashlib.sha256(body).hexdigest()!=item['sha256']:raise ValueError('bootstrap_checksum')
                with target.open('xb') as f:f.write(body)
            if checksum(target)!=item['sha256']:raise ValueError('bootstrap_checksum')
            parent['external/bootstrap/'+name]=target
        target=folder/'manifest.json'
        if target.exists() and target.read_bytes()!=raw_manifest:raise ValueError('bootstrap_manifest_changed')
        if not target.exists():target.write_bytes(raw_manifest)
        parent['external/bootstrap/manifest.json']=target
    return {'external.rule_rates':external_input({'external/rates.csv':rate_file},as_of=rate['date']),
            'external.rule_qqq':external_input({'external/qqq.json':fixed},as_of=max(s['filed'] for s in value['snapshots'])),
            'external.rule_parent':external_input(parent)}
