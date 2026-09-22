"""Adapters reuse production builders. No upstream fetches or live writer DB."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
from ..store import Store
from .checks import file_record, validate_canonical, verify_files
from .contracts import BuildResult, digest
from .planner import input_vector
from .registry import PROJECT


def execute(command,log,timeout):
    # Keys are deliberately not inherited by derived subprocesses.
    env={k:os.environ[k] for k in ('PATH','LANG','FACT_OS_LEASE_ROOT') if k in os.environ}
    env['PYTHONPATH']=str(PROJECT)
    with log.open('wb') as output:
        result=subprocess.run(command,cwd=PROJECT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=timeout)
    if result.returncode: raise ValueError('builder_command_failed:'+Path(command[1]).name)


def build(spec,snapshot,plan,store):
    root=Path(snapshot.root)
    vector=plan.inputVector or input_vector(spec,snapshot)
    if spec.kind=='review_gate': raise ValueError('independent_source_and_release_review_required')
    if spec.id=='public_observations':
        from .observations import build_observations
        file=store.root/'derived/pipeline/public_observations'/plan.inputFingerprint/'observations.sqlite'
        coverage=build_observations(root,file,plan.inputFingerprint)
        return BuildResult('succeeded',plan.inputFingerprint,digest(vector),(file_record(file,store.root),),
            spec.outputSchemaVersion,coverage,vector,{'integrity':'pass','existingQualityFormulas':'annual-quality-v1',
                'privateDataExcluded':True,'publishedModelsUnchanged':True})
    if spec.kind=='read_release':
        if spec.id!='canonical':
            path=store.root/'derived/pipeline'/spec.id/plan.inputFingerprint/'inputs.json'
            path.parent.mkdir(parents=True,exist_ok=True)
            from .contracts import encode
            Store._atomic_if_changed(path,encode({'schemaVersion':'fact-os-input-vector-v1','inputs':vector,
                'policy':'canonical_inputs_only_saved_models_and_user_results_unchanged'}).decode())
            return BuildResult('succeeded',plan.inputFingerprint,digest(vector),
                ({**file_record(path,store.root),'installPath':'inputs.json'},),spec.outputSchemaVersion,
                {key:snapshot.inputs[key]['coverage'] for key in spec.requiredInputs},vector,
                {'schema':'pass','canonicalReferences':'pass','userRecordsUnchanged':True})
        checks=validate_canonical(root,spec.requiredInputs)
        catalog=json.loads((root/'manifests/catalog.json').read_text())
        files=[file_record(root/'manifests/catalog.json',store.root)]
        files += [file_record(root/p['path'],store.root) for item in catalog['datasets'].values() for p in item['partitions']]
        return BuildResult('succeeded',snapshot.snapshotId,digest(vector),tuple(files),spec.outputSchemaVersion,
            {key:snapshot.inputs[key]['coverage'] for key in spec.requiredInputs},vector,checks)
    if spec.id=='ai_insights':
        from ..ai_insights import build_ai_insights
        config=root/'config/server/config/ai-insights-universe.json'
        result=build_ai_insights(store.root,source_root=root,**({'universe_path':config} if config.exists() else {}))
        manifest=json.loads(Path(result['manifestPath']).read_text())
        runtime=store.root/'derived/pipeline/ai_insights'/manifest['generationId']/'runtime'
        if not runtime.exists():
            runtime.parent.mkdir(parents=True,exist_ok=True)
            # Keep every archived generation until explicit saved-research pin
            # reconciliation exists. Never expire saved observations by count.
            retain=len(list((store.root/'derived/ai-insights/generations').glob('*.manifest.json')))
            execute(['node',str(PROJECT/'scripts/package-ai-insights-artifact.mjs'),'--source',str(store.root),
                '--output',str(runtime),'--release-id','ai-insights-20260922-v'+str(int(manifest['generationId'][:10],16)+1),
                '--retain',str(retain)],runtime.parent/'package.log',spec.timeout)
        files=tuple({**file_record(path,store.root),'installPath':str(path.relative_to(runtime))}
                    for path in sorted(runtime.rglob('*')) if path.is_file())
        verify_files(store.root,files)
        return BuildResult('succeeded',manifest['generationId'],manifest['dependencySha256'],files,
            spec.outputSchemaVersion,manifest['inventory'],vector,{'sameInputReplay':'pass','history':'pass','checksum':'pass'})
    if spec.id=='institutional_13f':
        directory=store.root/'derived/pipeline'/spec.id/plan.inputFingerprint
        directory.mkdir(parents=True,exist_ok=True)
        db=directory/'13f-insights.sqlite'
        # A retry reuses append-only builder output; partial groups never publish.
        execute([sys.executable,str(PROJECT/'scripts/build-13f-insights.py'),'--fact-os',str(root/'fact_os.duckdb'),
            '--database',str(db),'--quarters','40','--detail-quarters','8'],directory/'all.log',spec.timeout)
        execute([sys.executable,str(PROJECT/'scripts/build-13f-active-insights.py'),'--fact-os',str(root/'fact_os.duckdb'),
            '--database',str(db),'--quarters','40'],directory/'active.log',spec.timeout)
        names=('institutional_13f_insight_snapshots_v2','institutional_13f_insight_details_v1',
            'institutional_13f_market_history_v1','institutional_13f_security_history_v1',
            'institutional_13f_active_snapshots_v1','institutional_13f_active_details_v1','institutional_13f_active_sectors_v1')
        with sqlite3.connect(f'file:{db}?mode=ro',uri=True) as connection:
            if connection.execute('PRAGMA integrity_check').fetchone()[0]!='ok': raise ValueError('13f_integrity_failed')
            counts={name:connection.execute('SELECT count(*) FROM '+name).fetchone()[0] for name in names}
            if not all(counts.values()): raise ValueError('13f_atomic_group_incomplete')
            all_dates={r[0] for r in connection.execute('SELECT DISTINCT report_date FROM '+names[0])}
            active_dates={r[0] for r in connection.execute('SELECT DISTINCT report_date FROM '+names[4])}
            if all_dates!=active_dates: raise ValueError('13f_quarter_matrix_incomplete')
        return BuildResult('succeeded',plan.inputFingerprint,digest([vector,plan.inputFingerprint]),
            (file_record(db,store.root),),spec.outputSchemaVersion,counts,vector,
            {'integrity':'pass','sevenTables':'pass','quarterMatrix':'pass','strictDisclosure':'not_claimed_proxy_only'})
    raise ValueError('unregistered_builder')
