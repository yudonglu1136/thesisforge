"""Offline adapter for one atomic three-universe strategy publication group."""
import json
from pathlib import Path
import sys
from ..repository import FactRepository
from ..store import Store
from .contracts import BuildResult,digest,encode
from .checks import file_record
from .registry import PROJECT


def new_quarter_due(quarters,sessions,end):
    # A quarter is executable only once its next observed SPY session exists.
    from datetime import date
    previous=max(quarters)
    for session in sessions:
        if session>end:continue
        d=date.fromisoformat(session)
        start=date(d.year,((d.month-1)//3)*3+1,1)
        from datetime import timedelta
        signal=(start-timedelta(days=1)).isoformat()
        if signal>previous:return True
    return False


def build_rules(spec,snapshot,plan,store):
    from .builders import execute
    root=Path(snapshot.root);parent=root/'external/parent';bootstrap=root/'external/bootstrap'
    has_parent=(parent/'rule-manifest.json').exists()
    source=(parent/'all.json' if has_parent else root/'config/server/config/investor-style-dashboard.json')
    dashboard=json.loads(source.read_text())
    with FactRepository(root) as repo:
        dates=[str(r[0]) for r in repo.db.execute("SELECT date FROM funds WHERE ticker='SPY' AND closeadj>0 ORDER BY date").fetchall()]
    if not dates or dates[-1]<dashboard['dataThrough']:raise ValueError('rule_benchmark_behind_parent')
    end=dates[-1]
    directory=store.root/'derived/pipeline/strategy_inputs'/plan.inputFingerprint
    directory.mkdir(parents=True,exist_ok=True)
    bundle=directory/'bundle'
    if has_parent and end==dashboard['dataThrough'] and not bundle.exists():
        # No new observed session: preserve exact curve and ledger bytes. A
        # financial revision cannot silently rewrite an already published run.
        import tempfile,shutil,os
        staged=Path(tempfile.mkdtemp(prefix='reuse-',dir=directory))
        for f in parent.rglob('*'):
            if f.is_file() and f.name!='inputs.json':
                target=staged/f.relative_to(parent);target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(f,target)
        os.rename(staged,bundle)
    if not bundle.exists():
        selection=None
        quarters=[q['quarter'] for style in dashboard['styles'] for q in style['quarters']]
        if new_quarter_due(quarters,dates,end):
            selection=directory/'quarter/selections.json'
            # A failed subprocess gets its own retry directory; never overwrite
            # or treat a partial packet as a completed build.
            import tempfile
            attempt=Path(tempfile.mkdtemp(prefix='quarter-',dir=directory))/'output'
            command=[sys.executable,str(PROJECT/'scripts/build-rule-quarter-selections.py'),
                '--fact-root',str(root),'--output',str(attempt),'--rates',str(root/'external/rates.csv'),
                '--qqq-source',str(root/'external/qqq.json'),'--as-of',end]
            if has_parent:command+=['--parent',str(parent)]
            execute(command,directory/'quarter.log',spec.timeout)
            selection=attempt/'selections.json'
        command=['node',str(PROJECT/'scripts/build-rule-daily-bundle.mjs'),'--root',str(root),
                 '--output',str(bundle),'--as-of',end,
                 *(['--parent',str(parent)] if has_parent else ['--bootstrap-ledger',str(bootstrap)])]
        if selection:command+=['--selections',str(selection)]
        execute(command,directory/'bundle.log',spec.timeout)
    # Validate on retries too. Process exit alone is not proof of a valid bundle.
    execute(['node','--input-type=module','-e',
        "import {validateRulePortfolioBundle as v} from './server/rulePortfolioBundleBuild.js'; console.log(JSON.stringify(v(process.argv[1])))",
        str(bundle)],directory/'verify.log',spec.timeout)
    manifest=json.loads((bundle/'rule-manifest.json').read_text())
    Store._atomic_if_changed(bundle/'inputs.json',encode({'schemaVersion':'fact-os-input-vector-v1',
        'inputs':plan.inputVector,'policy':'public_rule_bundle_only_saved_user_results_unchanged'}).decode())
    files=tuple({**file_record(f,store.root),'installPath':str(f.relative_to(bundle))}
                for f in sorted(bundle.rglob('*')) if f.is_file())
    return BuildResult('succeeded',digest(manifest),digest(manifest),files,spec.outputSchemaVersion,
        {'dataThrough':end,'universes':list(manifest['entries'])},plan.inputVector,
        {'curveLedgerAtomic':'pass','dailyNavReplay':'pass','quarterSelection':'checked',
         'privateDataExcluded':True,'userResultsUnchanged':True})
