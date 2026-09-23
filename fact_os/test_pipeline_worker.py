import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock,patch
from .pipeline import aws_worker
from .contracts import TABLES
from .pipeline.contracts import digest


class DataReadyBoundaryTest(unittest.TestCase):
    def fixture(self):
        groups={k:{'generationId':digest(k)} for k in aws_worker.DATA_DAILY_GROUPS}
        receipt={'runId':'r','profile':'aws-data-daily','scheduledFor':'2026-09-23T04:30:00Z',
            'status':'succeeded','failedSources':[],
            'sources':{k:{'status':'ready'} for k in TABLES},
            'tasks':{k:{'status':'succeeded'} for k in groups},'groups':groups}
        return receipt,{'releaseId':digest(groups),'groups':groups}

    def test_data_ready_is_distinct_from_api_activation(self):
        receipt,candidate=self.fixture();s3=MagicMock()
        result=aws_worker.mark_data_ready(s3,'synthetic',receipt,candidate,None)
        self.assertEqual(result['dataSyncStatus'],'verified')
        self.assertEqual(result['actualApiActivation'],'not_requested')
        call=s3.put_object.call_args.kwargs
        self.assertEqual(call['Key'],'fact-os/data-ready/latest.json')
        self.assertEqual(call['IfNoneMatch'],'*')
        self.assertNotIn('fact-os/published/active.json',str(s3.mock_calls))

    def test_failed_source_missing_task_or_wrong_profile_never_mark_ready(self):
        for mutation in ('source','task','group','profile','source_state'):
            receipt,candidate=self.fixture();s3=MagicMock()
            if mutation=='source':receipt['failedSources']=['stocks']
            elif mutation=='task':receipt['tasks']['ai_insights']['status']='failed'
            elif mutation=='group':candidate['groups'].pop('canonical')
            elif mutation=='profile':receipt['profile']='aws-daily'
            else:receipt['sources']['stocks']['status']='missing'
            with self.assertRaises(ValueError):aws_worker.mark_data_ready(s3,'synthetic',receipt,candidate,None)
            s3.put_object.assert_not_called()

    def test_data_ready_compare_and_swap_and_no_change(self):
        receipt,candidate=self.fixture();s3=MagicMock()
        aws_worker.mark_data_ready(s3,'synthetic',receipt,candidate,'prior-etag')
        self.assertEqual(s3.put_object.call_args.kwargs['IfMatch'],'prior-etag')
        receipt['status']='no_change'
        for task in receipt['tasks'].values():task['status']='unchanged'
        self.assertEqual(aws_worker.mark_data_ready(s3,'synthetic',receipt,candidate,None)['dataSyncStatus'],'verified')


class WorkerBoundaryTest(unittest.TestCase):
    def test_data_only_syncs_all_tables_and_stages_without_api_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'sync').mkdir();(root/'sync/authority-import.json').write_text('{}')
            (root/'audit/pipeline').mkdir(parents=True)
            store=MagicMock(root=root)
            sync=MagicMock();sync.job_lock.return_value=contextlib.nullcontext()
            sync.sync.return_value={'status':'no_change'}
            s3=MagicMock();ssm=MagicMock();secrets=MagicMock()
            secrets.get_secret_value.return_value={'SecretString':'synthetic-fixture-not-a-real-key'}
            boto=SimpleNamespace(client=lambda name: {'s3':s3,'ssm':ssm,'secretsmanager':secrets}[name])
            receipt,candidate=DataReadyBoundaryTest().fixture()
            from .store import Store
            with patch.dict(os.environ,{'FACT_OS_ROOT':temporary,'FACT_OS_BUCKET':'synthetic-bucket','FACT_OS_SECRET_ID':'synthetic-reference'}), \
                 patch.dict('sys.modules',{'boto3':boto}), \
                 patch('sys.argv',['worker','--scheduled-for',receipt['scheduledFor'],'--data-only']), \
                 patch.object(aws_worker,'Store',return_value=store) as store_class, \
                 patch.object(aws_worker,'Synchronizer',return_value=sync), \
                 patch.object(aws_worker,'run',return_value=receipt) as runner, \
                 patch.object(aws_worker,'Ledger'), \
                 patch('fact_os.pipeline.cli.ingestion_lock',return_value=contextlib.nullcontext()), \
                 patch.object(aws_worker,'load_data_ready',return_value=(None,None)), \
                 patch.object(aws_worker,'load_active') as serving_pointer, \
                 patch.object(aws_worker,'prepare',return_value=(candidate,{'status':'uploaded'})), \
                 patch.object(aws_worker,'activate') as activate,contextlib.redirect_stdout(io.StringIO()) as output:
                store_class._atomic_if_changed=Store._atomic_if_changed
                self.assertEqual(aws_worker.main(),0)
            self.assertEqual([c.args[0] for c in sync.sync.call_args_list],list(TABLES))
            self.assertEqual(runner.call_args.kwargs['profile'],'aws-data-daily')
            serving_pointer.assert_not_called();ssm.send_command.assert_not_called();activate.assert_not_called()
            saved=json.loads((root/'audit/pipeline/r.json').read_text())
            self.assertEqual(saved['dataSyncStatus'],'verified')
            self.assertEqual(saved['publicationStatus'],'staged_not_activated')
            self.assertEqual(saved['actualApiActivation'],'not_requested')
            self.assertNotIn('synthetic-fixture-not-a-real-key',output.getvalue())

    def test_capacity_failure_precedes_secret_access_and_source_fetch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'sync').mkdir();(root/'sync/authority-import.json').write_text('{}')
            store=MagicMock(root=root)
            boto=SimpleNamespace(client=MagicMock(return_value=MagicMock()))
            from .store import Store
            with patch.dict(os.environ,{'FACT_OS_ROOT':temporary,'FACT_OS_BUCKET':'synthetic-bucket'}), \
                 patch.dict('sys.modules',{'boto3':boto}), \
                 patch('sys.argv',['worker','--scheduled-for','2026-09-23T04:30:00Z']), \
                 patch.object(aws_worker,'Store',return_value=store) as store_class, \
                 patch.object(aws_worker,'Synchronizer') as sync, \
                 patch('shutil.disk_usage',return_value=SimpleNamespace(free=1024)), \
                 contextlib.redirect_stdout(io.StringIO()):
                store_class._atomic_if_changed=Store._atomic_if_changed
                self.assertEqual(aws_worker.main(),2)
            sync.assert_not_called()
            self.assertNotIn('secretsmanager',[call.args[0] for call in boto.client.call_args_list])
            report=json.loads((root/'audit/pipeline/capacity-latest.json').read_text())
            self.assertEqual(report['status'],'blocked')
            self.assertFalse(report['sourceFetchStarted'])

    def test_stage_only_attempts_all_sources_but_never_installs_or_activates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'sync').mkdir();(root/'sync/authority-import.json').write_text('{}')
            (root/'audit/pipeline').mkdir(parents=True)
            store=MagicMock(root=root)
            sync=MagicMock();sync.job_lock.return_value=contextlib.nullcontext()
            sync.sync.return_value={'status':'no_change'}
            s3=MagicMock();ssm=MagicMock();secrets=MagicMock()
            secrets.get_secret_value.return_value={'SecretString':'synthetic-fixture-not-a-real-key'}
            boto=SimpleNamespace(client=lambda name: {'s3':s3,'ssm':ssm,'secretsmanager':secrets}[name])
            receipt={'runId':'synthetic-run','status':'degraded','tasks':{},'groups':{}}
            # Use the real small audit writer, but never a live store/network.
            from .store import Store
            with patch.dict(os.environ,{'FACT_OS_ROOT':temporary,'FACT_OS_BUCKET':'synthetic-bucket','FACT_OS_SECRET_ID':'synthetic-reference'}), \
                 patch.dict('sys.modules',{'boto3':boto}), \
                 patch('sys.argv',['worker','--scheduled-for','2026-09-22T04:30:00Z','--stage-only']), \
                 patch.object(aws_worker,'Store',return_value=store) as store_class, \
                 patch.object(aws_worker,'Synchronizer',return_value=sync), \
                 patch.object(aws_worker,'run',return_value=receipt), \
                 patch.object(aws_worker,'Ledger'), \
                 patch('fact_os.pipeline.cli.ingestion_lock',return_value=contextlib.nullcontext()), \
                 patch.object(aws_worker,'load_active',return_value=(None,None)), \
                 patch.object(aws_worker,'prepare',return_value=({'releaseId':'a'*64},{'status':'uploaded'})) as prepare, \
                 patch.object(aws_worker,'activate') as activate,contextlib.redirect_stdout(io.StringIO()) as output:
                store_class._atomic_if_changed=Store._atomic_if_changed
                self.assertEqual(aws_worker.main(),2)
            self.assertEqual([call.args[0] for call in sync.sync.call_args_list],list(TABLES))
            prepare.assert_called_once();ssm.send_command.assert_not_called();activate.assert_not_called()
            saved=json.loads((root/'audit/pipeline/synthetic-run.json').read_text())
            self.assertEqual(saved['publicationStatus'],'staged_not_activated')
            self.assertEqual(saved['actualApiActivation'],'not_attempted')
            self.assertNotIn('synthetic-fixture-not-a-real-key',output.getvalue())
            self.assertNotIn('synthetic-fixture-not-a-real-key',json.dumps(saved))


if __name__=='__main__':unittest.main()
