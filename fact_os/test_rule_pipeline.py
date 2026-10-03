import json
import unittest
from unittest.mock import patch
import sys
from dataclasses import replace
from pathlib import Path
from .test_pipeline import RunnerTest
from .pipeline.snapshots import freeze,load
from .pipeline.rule_dependencies import external_input
from .pipeline.rule_builder import new_quarter_due,reusable_benchmark
from .pipeline.registry import tasks,DATA_DAILY_GROUPS
from .pipeline.planner import plan


class RuleExternalSnapshotTest(unittest.TestCase):
    setUp=RunnerTest.setUp
    tearDown=RunnerTest.tearDown
    source=RunnerTest.source
    row=RunnerTest.row

    def test_external_files_are_frozen_and_changed_content_invalidates(self):
        source=self.store.root/'rates.csv';source.write_text('date,rate\n2026-09-30,5.29\n')
        inputs={'external.rule_rates':external_input({'external/rates.csv':source},as_of='2026-09-30')}
        first=freeze(self.store,code_version='v1',external=inputs)
        self.assertEqual((Path(first.root)/'external/rates.csv').read_text(),source.read_text())
        self.assertEqual(load(first.root).inputs,first.inputs)
        self.assertEqual(freeze(self.store,code_version='v1',external=inputs).snapshotId,first.snapshotId)
        # Atomic replacement, never mutate the pinned inode.
        staged=source.with_suffix('.new');staged.write_text('date,rate\n2026-09-30,5.30\n');staged.replace(source)
        second=freeze(self.store,code_version='v1',external={
            'external.rule_rates':external_input({'external/rates.csv':source},as_of='2026-09-30')})
        self.assertNotEqual(first.snapshotId,second.snapshotId)
        self.assertIn('5.29',(Path(first.root)/'external/rates.csv').read_text())
        with self.assertRaisesRegex(ValueError,'external_input_changed'):
            freeze(self.store,code_version='v1',external=inputs)

    def test_external_path_escape_rejected(self):
        source=self.store.root/'rates.csv';source.write_text('test')
        with self.assertRaisesRegex(ValueError,'external_input_path_escape'):
            freeze(self.store,code_version='v1',external={'external.rule_rates':external_input({'../bad':source})})

    def test_explicit_daily_opt_in_and_required_external_dependencies(self):
        baseline={s.id:s for s in tasks(profile='aws-data-daily')}
        enabled={s.id:s for s in tasks(profile='aws-data-daily',rule_daily=True)}
        self.assertEqual(set(enabled),DATA_DAILY_GROUPS)
        self.assertEqual(baseline['strategy_inputs'].kind,'read_release')
        spec=enabled['strategy_inputs']
        self.assertEqual(spec.outputSchemaVersion,'rule-portfolio-bundle-v1')
        self.assertTrue({'fundamentals','sp500','external.rule_rates','external.rule_qqq','external.rule_parent'}<=set(spec.requiredInputs))
        snapshot=freeze(self.store,code_version='v1')
        p=plan([spec],snapshot)[0]
        self.assertIn('external.rule_rates',p.missingRequired)
        self.assertIn('external.rule_qqq',p.missingRequired)


class QuarterClockTest(unittest.TestCase):
    def test_unchanged_session_requires_qqq_migration_for_legacy_bundle(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            parent=Path(d);source=parent/'nasdaq100.json'
            source.write_text(json.dumps({'backtest':{}}))
            self.assertFalse(reusable_benchmark(parent))
            source.write_text(json.dumps({'backtest':{'qqqBenchmark':{'ticker':'QQQ'}}}))
            self.assertTrue(reusable_benchmark(parent))

    def test_only_observed_new_quarter_session_is_executable(self):
        self.assertFalse(new_quarter_due(['2026-06-30'],['2026-09-30'],'2026-09-30'))
        self.assertTrue(new_quarter_due(['2026-06-30'],['2026-09-30','2026-10-01'],'2026-10-01'))
        self.assertFalse(new_quarter_due(['2026-09-30'],['2026-09-30','2026-10-01'],'2026-10-01'))
        self.assertFalse(new_quarter_due(['2026-06-30'],['2026-10-01'],'2026-09-30'))

    def test_node_builder_uses_same_python_runtime_without_source_credentials(self):
        from .pipeline.builders import execute
        import tempfile
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as d,patch.dict('os.environ',{'SHARADAR_API_KEY':'not-a-real-key'}),patch(
                'fact_os.pipeline.builders.subprocess.run',return_value=SimpleNamespace(returncode=0)) as call:
            execute(['node','builder.mjs'],Path(d)/'build.log',5)
            env=call.call_args.kwargs['env']
            self.assertEqual(env['FACT_OS_PYTHON'],sys.executable)
            self.assertNotIn('SHARADAR_API_KEY',env)

if __name__=='__main__':unittest.main()
