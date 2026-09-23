#!/usr/bin/env python3
"""Root-only AWS installer; public data only, actual webapp read and API ACK."""
import argparse
import json
import os
from pathlib import Path
import pwd
import sqlite3
import subprocess
import sys
import urllib.request
from datetime import date
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from fact_os.pipeline.installer import install
from fact_os.pipeline.checks import validate_canonical,validate_api_read
from fact_os.pipeline.contracts import digest
from fact_os.contracts import TABLES


def api_port(config, environment=None):
    # EB injects its platform PORT into web.service even when get-config's
    # user environment omits it. Match the other production loopback runners;
    # 8787 is the local development server, not the EB Node platform default.
    environment = os.environ if environment is None else environment
    value = str(config.get('PORT') or environment.get('PORT') or '8080')
    if not value.isascii() or not value.isdecimal() or not 1 <= int(value) <= 65535:
        raise ValueError('internal_ack_port_invalid')
    return int(value)


def validate_live_ack(body,installed):
    if (body.get('releaseId')!=installed['releaseId'] or body.get('status')!='verified'
            or body.get('fundamentals',{}).get('status')!='ready'):
        raise ValueError('live_api_generation_mismatch')
    expected={name:item['generationId'] for name,item in installed['groups'].items()}
    observed={name:item.get('generationId') for name,item in body.get('groups',{}).items()}
    if observed!=expected:raise ValueError('live_api_group_mismatch')
    coverage={row.get('dataset'):row for row in body.get('coverage',[])}
    if any(not coverage.get(t,{}).get('locally_available') or
           not coverage.get(t,{}).get('backfill_complete') for t in TABLES):
        raise ValueError('live_api_coverage_incomplete')
    return True


def main():
    if os.geteuid()!=0:raise ValueError('root_installer_required')
    parser=argparse.ArgumentParser();parser.add_argument('--bucket',required=True);parser.add_argument('--candidate-key',required=True)
    parser.add_argument('--expected-release',required=True,help='Exact previous root release id, or none for first install')
    args=parser.parse_args()
    import boto3
    s3=boto3.client('s3')
    if not args.candidate_key.startswith('fact-os/published/releases/') or not args.candidate_key.endswith('.json'):raise ValueError('release_key_invalid')
    candidate=json.loads(s3.get_object(Bucket=args.bucket,Key=args.candidate_key)['Body'].read())
    if digest({k:candidate[k] for k in ('schemaVersion','groups')})!=candidate['releaseId']:raise ValueError('release_identity_invalid')
    root=Path('/var/app/data/fact-os');active=root/'active.json'
    expected=None if args.expected_release=='none' else args.expected_release
    lease=Path('/var/app/data/fact-os-leases');lease.mkdir(exist_ok=True)
    account=pwd.getpwnam('webapp');os.chown(lease,account.pw_uid,account.pw_gid);lease.chmod(0o700)
    os.environ['FACT_OS_LEASE_ROOT']=str(root/'installer-leases')
    def validate(name,path,manifest):
        if name == 'canonical':
            validate_canonical(path,manifest['requiredMatrix']);return
        if name=='public_observations':
            with sqlite3.connect('file:'+str(path/'observations.sqlite')+'?mode=ro',uri=True) as db:
                if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('observation_integrity_failed')
                metadata={k:json.loads(v) for k,v in db.execute('SELECT key,value FROM projection_metadata')}
                if metadata.get('schemaVersion')!='canonical-public-observations-v1':raise ValueError('observation_schema_invalid')
                for table in ('investment_current_quotes','investment_quality_annual'):
                    if not db.execute('SELECT count(*) FROM '+table).fetchone()[0]:raise ValueError('observation_projection_empty')
            return
        if name in ('research_inputs','strategy_inputs'):
            value=json.loads((path/'inputs.json').read_text())
            if value.get('schemaVersion')!='fact-os-input-vector-v1' or value.get('inputs')!=manifest['inputVector']:
                raise ValueError('canonical_input_vector_invalid')
            return
        if name=='ai_insights':
            script="import {validateAiInsightsArtifact} from './server/investmentRuntimeConfig.js'; validateAiInsightsArtifact(process.argv[1],process.argv[1]+'/release-manifest.json');"
        elif name=='institutional_13f':
            script="import {validateInstitutional13fArtifact} from './server/investmentRuntimeConfig.js'; validateInstitutional13fArtifact(process.argv[1]+'/13f-insights.sqlite',process.argv[1]+'/manifest.json');"
        else:raise ValueError('unregistered_install_validator')
        result=subprocess.run(['runuser','-u','webapp','--','node','--input-type=module','-e',script,str(path)],capture_output=True)
        if result.returncode:raise ValueError('existing_production_validator_failed:'+name)
    def probe(installed,activated):
        canonical=installed['groups'].get('canonical',{}).get('root')
        if not canonical:raise ValueError('canonical_release_required')
        if not activated:
            result=subprocess.run(['runuser','-u','webapp','--','env','FACT_OS_LEASE_ROOT='+str(lease),
                sys.executable,'-m','fact_os.rpc','--root',canonical],input=json.dumps({'batch':[
                    {'method':'get_coverage'},
                    {'method':'get_fundamental_company_index','args':[date.today().isoformat()],'kwargs':{'limit':2}}
                ]}),text=True,capture_output=True,timeout=120)
            value=json.loads(result.stdout)
            if result.returncode:raise ValueError('actual_api_uid_read_failed')
            validate_api_read(value)
            return {}
        # Existing internal credential read in memory; never emitted or sent off-host.
        config=json.loads(subprocess.check_output(['/opt/elasticbeanstalk/bin/get-config','environment']))
        secret=config.get('INTERNAL_CRON_SECRET') or config.get('CRON_SECRET')
        if not secret:raise ValueError('internal_ack_credential_missing')
        request=urllib.request.Request('http://127.0.0.1:'+str(api_port(config))+'/api/internal/data-release',headers={'Authorization':'Bearer '+secret})
        with urllib.request.urlopen(request,timeout=120) as response:body=json.load(response)
        validate_live_ack(body,installed)
        return {'status':'verified','releaseId':installed['releaseId'],'actualApiUserRead':True,'canonicalReadVerified':True,
                'groups':{k:v['generationId'] for k,v in body['groups'].items()},'fundamentals':body['fundamentals']}
    result=install(s3,args.bucket,candidate,root,validate_group=validate,probe=probe,expected_release=expected)
    print(json.dumps(result))


if __name__=='__main__':main()
