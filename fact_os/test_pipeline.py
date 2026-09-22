import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch
from .pipeline.contracts import TaskSpec,InputSnapshot,BuildResult,digest
from .pipeline.planner import plan
from .pipeline.registry import ordered,tasks
from .pipeline.runner import run
from .pipeline.snapshots import freeze
from .pipeline.checks import file_record
from .test_store_revision import StoreRevisionTest


class PlannerTest(unittest.TestCase):
    def setUp(self):
        self.spec=TaskSpec('ai','derived','code1','method1',{'universe':'u1'},('fundamentals','tickers'),('actions',))
        self.snapshot=InputSnapshot('s','/unused',{}, {key:{'status':'ready','contentVersion':key+'1','schema':'1',
            'sourceAsOf':'2026-09-21','partitions':[]} for key in ('fundamentals','tickers','stocks')},{},'code1')

    def fingerprint(self,spec=None,snapshot=None):
        return plan([spec or self.spec],snapshot or self.snapshot)[0].inputFingerprint

    def test_price_change_does_not_dirty_financial_task(self):
        changed=replace(self.snapshot,inputs={**self.snapshot.inputs,'stocks':{'status':'ready','contentVersion':'new'}})
        self.assertEqual(self.fingerprint(),self.fingerprint(snapshot=changed))

    def test_financial_identity_method_config_optional_readiness_invalidate(self):
        baseline=self.fingerprint()
        for field,value in [('methodologyVersion','2'),('implementationVersion','2'),('outputSchemaVersion','2'),('configHashes',{'universe':'2'})]:
            self.assertNotEqual(baseline,self.fingerprint(spec=replace(self.spec,**{field:value})))
        for key in ('fundamentals','tickers','actions'):
            changed=replace(self.snapshot,inputs={**self.snapshot.inputs,key:{'status':'ready','contentVersion':'2'}})
            self.assertNotEqual(baseline,self.fingerprint(snapshot=changed))

    def test_unrelated_failure_does_not_block_ai_but_required_failure_does(self):
        self.assertFalse(plan([self.spec],self.snapshot,failed_sources=['stocks'])[0].missingRequired)
        self.assertEqual(plan([self.spec],self.snapshot,failed_sources=['fundamentals'])[0].missingRequired,('fundamentals',))
        stale=plan([self.spec],self.snapshot,failed_sources=['actions'])[0]
        self.assertEqual(stale.inputVector['actions']['status'],'missing')
        self.assertEqual(stale.optionalFailures,('actions',))
        self.assertEqual(stale.inputFingerprint,self.fingerprint())

    def test_cache_key_is_task_and_fingerprint_not_day(self):
        previous={('ai',self.fingerprint()):{'artifactId':'retained'}}
        self.assertEqual(plan([self.spec],self.snapshot,previous)[0].reason,'unchanged')

    def test_cycles_and_missing_nodes_fail(self):
        with self.assertRaises(ValueError): ordered([replace(self.spec,dependsOn=('missing',))])
        with self.assertRaises(ValueError): ordered([self.spec,self.spec])

    def test_real_registry_includes_fourteen_canonical_sources_and_review_gates(self):
        registry={s.id:s for s in tasks()}
        self.assertEqual(len(registry['canonical'].requiredInputs),14)
        self.assertEqual(registry['valuation_candidates'].publicationPolicy,'candidate_only_never_auto_publish')
        self.assertIn('external.sec_accepted_filings',registry['guru_strict'].requiredInputs)


class RunnerTest(unittest.TestCase):
    tearDown=StoreRevisionTest.tearDown
    source=StoreRevisionTest.source
    row=StoreRevisionTest.row

    def setUp(self):
        StoreRevisionTest.setUp(self)
        self.store.ingest('stocks',self.source('full.csv',[self.row()]),scope='verified_full_bulk')
        self.spec=TaskSpec('test','derived','code1','method1',{},('stocks',),publicationGroup='test')
        self.calls=0

    def builder(self,spec,snapshot,item,store):
        self.calls+=1
        path=store.root/'derived'/item.inputFingerprint/'payload.json'
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(json.dumps({'source':snapshot.inputs['stocks']['contentVersion']}))
        return BuildResult('succeeded',item.inputFingerprint,item.inputFingerprint,(file_record(path,store.root),),
            '1',{},snapshot.inputs,{'fixture':'pass'})

    def test_repeated_and_interrupted_triggers_reuse_validated_outputs(self):
        first=run(self.store,specs=[self.spec],builder=self.builder,scheduled_for='2026-09-22T04:30:00Z')
        second=run(self.store,specs=[self.spec],builder=self.builder,scheduled_for='2026-09-22T04:30:00Z')
        self.assertEqual(first['runId'],second['runId'])
        self.assertEqual(self.calls,1)
        self.assertEqual(second['tasks']['test']['status'],'unchanged')
        third=run(self.store,specs=[self.spec],builder=self.builder,scheduled_for='2026-09-23T04:30:00Z')
        self.assertNotEqual(first['runId'],third['runId'])
        self.assertEqual(self.calls,1)

    def test_missing_output_is_rebuilt_not_reported_success(self):
        first=run(self.store,specs=[self.spec],builder=self.builder)
        (self.store.root/first['tasks']['test']['files'][0]['path']).unlink()
        second=run(self.store,specs=[self.spec],builder=self.builder)
        self.assertEqual(self.calls,2)
        self.assertEqual(second['status'],'succeeded')

    def test_unrelated_failed_task_retains_successful_group(self):
        missing=replace(self.spec,id='missing',requiredInputs=('fundamentals',),publicationGroup='missing')
        result=run(self.store,specs=[self.spec,missing],builder=self.builder)
        self.assertEqual(result['status'],'degraded')
        self.assertEqual(result['tasks']['missing']['status'],'blocked')
        self.assertEqual(set(result['groups']),{'test'})

    def test_failure_does_not_ack_group_and_can_resume(self):
        def failed(*args): raise RuntimeError('private detail not in receipt')
        first=run(self.store,specs=[self.spec],builder=failed)
        self.assertEqual(first['status'],'failed')
        self.assertFalse(first['groups'])
        self.assertNotIn('private detail',json.dumps(first))
        second=run(self.store,specs=[self.spec],builder=self.builder)
        self.assertEqual(second['status'],'succeeded')

    def test_frozen_snapshot_does_not_read_latest_writer_updates(self):
        snapshot=freeze(self.store,code_version='test')
        before=(Path(snapshot.root)/'manifests/catalog.json').read_bytes()
        self.store.ingest('stocks',self.source('revision.csv',[self.row(value=42)]))
        from .repository import FactRepository
        with FactRepository(snapshot.root) as repo:
            self.assertEqual(repo.db.execute('SELECT close FROM stocks').fetchone()[0],10)
        self.assertEqual((Path(snapshot.root)/'manifests/catalog.json').read_bytes(),before)
        self.assertTrue((self.store.root/'sync/snapshot-pins'/(snapshot.snapshotId+'.json')).is_file())

    def test_retry_same_schedule_does_not_silently_take_a_new_snapshot(self):
        first=run(self.store,specs=[self.spec],builder=self.builder,scheduled_for='2026-09-22T04:30:00Z')
        self.store.ingest('stocks',self.source('revision.csv',[self.row(value=42)]))
        second=run(self.store,specs=[self.spec],builder=self.builder,scheduled_for='2026-09-22T04:30:00Z')
        self.assertEqual(first['snapshotId'],second['snapshotId'])
        self.assertEqual(self.calls,1)
        third=run(self.store,specs=[self.spec],builder=self.builder,scheduled_for='2026-09-23T04:30:00Z')
        self.assertNotEqual(first['snapshotId'],third['snapshotId'])
        self.assertEqual(self.calls,2)

    def test_event_consumption_and_publication_status_are_separate(self):
        from .pipeline.ledger import Ledger
        receipt=run(self.store,specs=[self.spec],builder=self.builder)
        ledger=Ledger(self.store)
        ledger.publication(receipt,'failed',{'errorType':'TimeoutError'})
        with self.store.writer() as db:
            self.assertEqual(db.execute('SELECT status FROM pipeline_source_events').fetchone()[0],'succeeded')
            self.assertEqual(db.execute('SELECT publication_status FROM pipeline_runs').fetchone()[0],'failed')
        ledger.publication(receipt,'verified',{'releaseId':'verified-fixture'})
        self.assertEqual(ledger.status()[0]['publication_status'],'verified')
