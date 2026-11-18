#!/usr/bin/env python3
"""Local ThesisForge <-> AWS Fact OS synchronization & publication bridge.

Connects the local canonical warehouse (`data/fact_os`) to the AWS
`thesisforge-fact-os` stack (`us-east-1`) using the exact content-addressed S3
publisher, rule-portfolio builder, and fenced SSM API installer contracts.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import sys
from urllib.parse import urlparse

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT))

from fact_os.capacity import capacity_budget
from fact_os.contracts import TABLES
from fact_os.pipeline import aws_worker, rule_dependencies
from fact_os.pipeline.cli import ingestion_lock
from fact_os.pipeline.contracts import encode
from fact_os.pipeline.ledger import Ledger
from fact_os.pipeline.publisher import load_active, prepare
from fact_os.pipeline.registry import tasks
from fact_os.pipeline.runner import run
from fact_os.store import Store, now


def sanitize_dead_local_proxy():
    """Drop broken localhost proxy env vars when no local proxy daemon is listening."""
    for key in ('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'https_proxy', 'http_proxy', 'all_proxy'):
        raw = os.environ.get(key)
        if not raw:
            continue
        parsed = urlparse(raw if '://' in raw else f'http://{raw}')
        if parsed.hostname in ('127.0.0.1', 'localhost') and parsed.port:
            try:
                with socket.create_connection((parsed.hostname, parsed.port), timeout=0.5):
                    pass
            except OSError:
                os.environ.pop(key, None)


def resolve_stack_config(cfn, stack_name):
    stacks = cfn.describe_stacks(StackName=stack_name)['Stacks']
    if not stacks:
        raise ValueError(f'CloudFormation stack not found: {stack_name}')
    stack = stacks[0]
    params = {p['ParameterKey']: p['ParameterValue'] for p in stack.get('Parameters', [])}
    outputs = {o['OutputKey']: o['OutputValue'] for o in stack.get('Outputs', [])}
    return {
        'stackName': stack_name,
        'stackStatus': stack['StackStatus'],
        'bucket': params['Bucket'],
        'apiInstanceId': params['ApiInstanceId'],
        'installDocument': outputs['InstallDocument'],
        'installDocumentVersion': params['InstallDocumentVersion'],
        'workerId': outputs.get('WorkerId'),
        'stateMachineArn': outputs.get('StateMachineArn'),
        'rulePortfolios': params.get('RulePortfolios') == 'true',
        'activateDaily': params.get('ActivateDaily') == 'true',
        'scheduleState': params.get('ScheduleState'),
    }


def cmd_status(store, region, stack_name, emit):
    import boto3

    cfn = boto3.client('cloudformation', region_name=region)
    s3 = boto3.client('s3', region_name=region)
    sfn = boto3.client('stepfunctions', region_name=region)
    cfg = resolve_stack_config(cfn, stack_name)
    active, _ = load_active(s3, cfg['bucket'])
    ready, _ = aws_worker.load_data_ready(s3, cfg['bucket'])
    execs = sfn.list_executions(stateMachineArn=cfg['stateMachineArn'], maxResults=3)['executions']
    local_status = store.status()
    local_ready = sum(1 for r in local_status if r['backfill_complete'] and not r['last_error'])
    local_max = max((r['max_date'] for r in local_status if r['max_date']), default=None)
    latest_path = store.root / 'audit/pipeline/latest.json'
    latest_local_run = json.loads(latest_path.read_text()) if latest_path.is_file() else {}
    emit({
        'aws': {
            'stack': cfg['stackName'],
            'stackStatus': cfg['stackStatus'],
            'bucket': cfg['bucket'],
            'scheduleState': cfg['scheduleState'],
            'rulePortfolios': cfg['rulePortfolios'],
            'activeRelease': {
                'releaseId': (active or {}).get('releaseId'),
                'scheduledFor': (active or {}).get('scheduledFor'),
                'runId': (active or {}).get('runId'),
            },
            'dataReady': {
                'scheduledFor': (ready or {}).get('scheduledFor'),
                'verifiedAt': (ready or {}).get('verifiedAt'),
                'releaseId': ((ready or {}).get('candidate') or {}).get('releaseId'),
            },
            'recentExecutions': [
                {
                    'name': e['name'],
                    'status': e['status'],
                    'startDate': e['startDate'].isoformat(),
                }
                for e in execs
            ],
        },
        'local': {
            'root': str(store.root),
            'verifiedTables': f'{local_ready}/{len(TABLES)}',
            'maxDate': local_max,
            'latestPipelineRun': {
                'runId': latest_local_run.get('runId'),
                'status': latest_local_run.get('status'),
                'publicationStatus': latest_local_run.get('publicationStatus'),
            },
        },
    })
    return 0


def cmd_sync(store, args, emit):
    import boto3

    statuses = {s['dataset']: s for s in store.status()}
    incomplete = [t for t in TABLES if not statuses.get(t, {}).get('backfill_complete') or statuses[t].get('last_error')]
    if incomplete:
        raise ValueError(f'local Fact OS sources not clean/complete: {incomplete}')
    budget = capacity_budget(store.root)
    if budget['status'] == 'blocked':
        raise ValueError('insufficient_local_disk_headroom')

    cfn = boto3.client('cloudformation', region_name=args.region)
    s3 = boto3.client('s3', region_name=args.region)
    ssm = boto3.client('ssm', region_name=args.region)
    cfg = resolve_stack_config(cfn, args.stack_name)
    bucket = cfg['bucket']

    scheduled_for = args.scheduled_for or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
    use_rules = cfg['rulePortfolios'] if args.rule_portfolios is None else args.rule_portfolios

    store.recover_catalog()
    external = {}
    specs = None
    if use_rules:
        emit({'phase': 'acquire_rule_dependencies', 'cutoff': scheduled_for[:10], 'bucket': bucket})
        specs = tasks(profile='aws-data-daily', rule_daily=True)
        external = rule_dependencies.acquire(store, s3, bucket, scheduled_for[:10])

    def require_space(_stage):
        if capacity_budget(store.root)['status'] == 'blocked':
            raise ValueError('insufficient_local_disk_headroom')

    emit({'phase': 'build_or_reuse_pipeline', 'scheduledFor': scheduled_for, 'rulePortfolios': use_rules})
    receipt = run(
        store,
        profile='aws-data-daily',
        scheduled_for=scheduled_for,
        failed_sources=[],
        specs=specs,
        external=external,
        capacity_check=require_space,
    )
    if receipt.get('status') not in ('succeeded', 'no_change'):
        emit({'phase': 'build_failed', 'runId': receipt.get('runId'), 'status': receipt.get('status')})
        return 2

    with ingestion_lock(store):
        ledger = Ledger(store)
        ready, ready_etag = aws_worker.load_data_ready(s3, bucket)
        if ready and receipt['scheduledFor'] < ready['scheduledFor']:
            raise ValueError(f"scheduled_for {receipt['scheduledFor']} older than S3 data-ready {ready['scheduledFor']}")
        previous = ready['candidate'] if ready else None
        emit({'phase': 's3_upload_start', 'bucket': bucket, 'runId': receipt['runId']})
        candidate, upload = prepare(s3, bucket, store, receipt, previous)
        aws_worker.mark_data_ready(s3, bucket, receipt, candidate, ready_etag)
        ledger.publication(receipt, 'staged_not_activated', {
            'reason': 'local_aws_bridge',
            'candidateReleaseId': candidate['releaseId'],
        })
        staged = {
            **receipt,
            'publicationStatus': 'staged_not_activated',
            'candidateReleaseId': candidate['releaseId'],
            'upload': upload,
            'actualApiActivation': 'not_requested',
            'dataSyncStatus': 'verified',
            'deferredTasks': ['guru_strict', 'valuation_candidates'],
        }
        Store._atomic_if_changed(store.root / 'audit/pipeline' / (receipt['runId'] + '.json'), encode(staged).decode())
        Store._atomic_if_changed(store.root / 'audit/pipeline/latest.json', encode(staged).decode())
        s3.put_object(
            Bucket=bucket,
            Key='fact-os/runs/' + receipt['runId'] + '.json',
            Body=encode(staged),
            ServerSideEncryption='AES256',
        )
        emit({
            'phase': 'data_ready_verified',
            'runId': receipt['runId'],
            'candidateReleaseId': candidate['releaseId'],
            'uploadedObjects': upload.get('uploadedObjects', 0),
        })
        if not args.activate:
            aws_worker.run_retention_maintenance(store, emit)
            return 0

        os.environ['FACT_OS_API_INSTANCE_ID'] = cfg['apiInstanceId']
        os.environ['FACT_OS_INSTALL_DOCUMENT'] = cfg['installDocument']
        os.environ['FACT_OS_INSTALL_DOCUMENT_VERSION'] = str(cfg['installDocumentVersion'])
        ledger.publication(receipt, 'uploading', {})
        return aws_worker.publish(store, receipt, s3, ssm, bucket, emit, ledger)


def main():
    sanitize_dead_local_proxy()
    parser = argparse.ArgumentParser(description='ThesisForge local <-> AWS Fact OS sync bridge')
    parser.add_argument('action', choices=['status', 'sync'], default='status', nargs='?')
    parser.add_argument('--root', default=os.environ.get('FACT_OS_ROOT', str(PROJECT / 'data/fact_os')))
    parser.add_argument('--region', default=os.environ.get('AWS_DEFAULT_REGION', 'us-east-1'))
    parser.add_argument('--stack-name', default='thesisforge-fact-os')
    parser.add_argument('--scheduled-for', help='ISO-8601 UTC timestamp for the release')
    parser.add_argument('--activate', action='store_true', help='Also install onto the live AWS EB API instance and verify ACK before updating active.json')
    rules = parser.add_mutually_exclusive_group()
    rules.add_argument('--rule-portfolios', dest='rule_portfolios', action='store_true', default=None)
    rules.add_argument('--no-rule-portfolios', dest='rule_portfolios', action='store_false')
    args = parser.parse_args()
    store = Store(args.root)
    emit = lambda obj: print(json.dumps(obj, default=str), flush=True)
    if args.action == 'status':
        return cmd_status(store, args.region, args.stack_name, emit)
    return cmd_sync(store, args, emit)


if __name__ == '__main__':
    raise SystemExit(main())
