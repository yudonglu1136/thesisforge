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


class WorkerBoundaryTest(unittest.TestCase):
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
