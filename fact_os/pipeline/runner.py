"""Coalesce a committed ingestion batch, resume validated tasks, retain failures."""
from pathlib import Path
import json
from ..store import Store,now
from .contracts import digest, encode, record, PublicationGroupManifest
from .registry import tasks, ordered
from .snapshots import freeze,load
from .planner import plan
from .ledger import Ledger
from .checks import verify_files
from .builders import build


def run(store,*,profile='local',scheduled_for=None,failed_sources=(),specs=None,builder=build):
    specs=tuple(specs or tasks())
    ledger=Ledger(store)
    version=digest([record(s) for s in specs])
    scheduled_for=scheduled_for or now()
    run_id=digest({'profile':profile,'scheduledFor':scheduled_for,'planVersion':version})
    existing=ledger.existing_run(run_id)
    snapshot=(load(store.root/'snapshots'/existing) if existing else
              freeze(store,code_version=version,configs={s.id:s.configHashes for s in specs}))
    if snapshot.codeVersion!=version:raise ValueError('resume_implementation_version_mismatch')
    previous=ledger.results()
    # Cache presence is not success: a missing/corrupt output is rebuilt.
    for key,result in list(previous.items()):
        try: verify_files(store.root,result['files'])
        except (ValueError,OSError): del previous[key]
    planned=plan(specs,snapshot,previous,failed_sources)
    ledger.run(run_id,profile,scheduled_for,snapshot.snapshotId,'running')
    if not existing:ledger.record_events(run_id,snapshot.snapshotId,'planned')
    results={};groups={}
    for spec,item in zip(ordered(specs),planned):
        try:
            if item.missingRequired or any(results[d]['status'] in ('failed','blocked') for d in spec.dependsOn):
                result={'status':'blocked','reason':item.reason,'missingRequired':item.missingRequired}
            elif item.reusedOutputs:
                result={**item.reusedOutputs,'status':'unchanged'}
            else:
                ledger.task(run_id,spec.id,item.inputFingerprint,'running')
                result=record(builder(spec,snapshot,item,store))
                verify_files(store.root,result['files'])
                ledger.task(run_id,spec.id,item.inputFingerprint,'succeeded',result)
            if result['status'] in ('blocked','failed'):
                ledger.task(run_id,spec.id,item.inputFingerprint,result['status'],result)
            else:
                core={'groupId':spec.publicationGroup,'members':{spec.id:result['artifactId']},
                    'inputVector':result['inputRefs'],'compatibilityVersion':spec.outputSchemaVersion,
                    'requiredMatrix':list(spec.requiredInputs),'checks':result['validationReceipt']}
                groups[spec.publicationGroup]={**core,'generationId':digest(core),'files':result['files']}
        except Exception as error:
            # Avoid leaking credential-bearing subprocess/network messages.
            result={'status':'failed','errorType':type(error).__name__,'previousGenerationRetained':True}
            ledger.task(run_id,spec.id,item.inputFingerprint,'failed',result)
        results[spec.id]=result
    failures=sum(r['status'] in ('failed','blocked') for r in results.values())
    status='failed' if failures==len(results) else 'degraded' if failures or failed_sources else (
        'no_change' if all(r['status']=='unchanged' for r in results.values()) else 'succeeded')
    receipt={'schemaVersion':1,'runId':run_id,'profile':profile,'scheduledFor':scheduled_for,
        'codeVersion':version,
        'snapshotId':snapshot.snapshotId,'status':status,'publicationStatus':'pending',
        'sources':snapshot.inputs,'failedSources':list(failed_sources),'tasks':results,'groups':groups,'completedAt':now()}
    directory=store.root/'audit/pipeline';directory.mkdir(parents=True,exist_ok=True)
    Store._atomic_if_changed(directory/(run_id+'.json'),encode(receipt).decode())
    Store._atomic_if_changed(directory/'latest.json',encode(receipt).decode())
    ledger.run(run_id,profile,scheduled_for,snapshot.snapshotId,status,receipt)
    ledger.record_events(run_id,snapshot.snapshotId,'succeeded' if status in ('succeeded','no_change') else 'pending_retry')
    return receipt
