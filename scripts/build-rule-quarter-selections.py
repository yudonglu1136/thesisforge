"""Generate new-quarter packets offline using the unchanged published rules.

All external inputs are explicit. No provider keys, network calls, writer DB,
private accounts or historical selection rewrites are permitted here.
"""
import argparse
from datetime import date,timedelta
import hashlib
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from fact_os.repository import FactRepository
from rule_daily_dependencies import revalidate_qqq

ROOT=Path(__file__).resolve().parents[1]
DEFAULTS={'all':'investor-style-dashboard.json','sp500':'investor-style-sp500.json','nasdaq100':'investor-style-nasdaq100.json'}

def run(a):
    output=a.output.resolve()
    if output.is_relative_to(a.fact_root.resolve()):raise ValueError('output_must_not_mutate_input_snapshot')
    output.mkdir(parents=True,exist_ok=False)
    files={u:(a.parent/f'{u}.json' if a.parent else ROOT/'server/config'/f) for u,f in DEFAULTS.items()}
    hashes={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in [*files.values(),a.rates,a.qqq_source]}
    parents={u:json.loads(f.read_text()) for u,f in files.items()}
    cuts={p['dataThrough'] for p in parents.values()}
    if len(cuts)!=1:raise ValueError('parent_cutoff_mismatch')
    start=(date.fromisoformat(next(iter(cuts)))+timedelta(days=1)).isoformat()
    def command(script,*args):
        subprocess.run([sys.executable,str(ROOT/'scripts'/script),*map(str,args)],cwd=ROOT,check=True)
    panel=output/'panel'
    command('extract-rule-portfolio-panel.py','--fact-root',a.fact_root,'--output',panel,'--start-entry',start,'--as-of',a.as_of)
    with FactRepository(a.fact_root) as repo:
        generation=repo.generation
        identities=repo.db.execute('SELECT DISTINCT permaticker,ticker,cusips FROM tickers WHERE cusips IS NOT NULL').fetchall()
    source=json.loads(a.qqq_source.read_text())
    qqq=revalidate_qqq(source,identities,generation,a.as_of)
    qqq_file=output/'qqq-identity.json';qqq_file.write_text(json.dumps(qqq,sort_keys=True))
    # Only the old reviewed actions are retained by the parent curve. New
    # unreviewed action events are never invented by quarterly selection.
    actions=output/'actions.json';actions.write_text(json.dumps({'generation':generation,'actions':[]}))
    candidates=output/'candidates.json'
    command('build-rule-portfolio-candidates.py','--fact-root',a.fact_root,'--panel',panel/'common-panel.csv',
        '--metadata',panel/'common-metadata.json','--start',start,'--output',candidates)
    packets={}
    for universe in DEFAULTS:
        target=output/universe
        command('build-rule-portfolio-inputs.py','--fact-root',a.fact_root,'--panel',panel/'common-panel.csv',
            '--metadata',panel/'common-metadata.json','--candidates',candidates,'--rates',a.rates,
            '--adapter',ROOT/'scripts/rule_selection_features.py','--schedule',files[universe],
            '--actions',actions,'--start',start,'--output',target,'--universe',universe,'--sec-universe',qqq_file)
        packets[universe]=json.loads((target/'inputs.json').read_text())
    if any(hashlib.sha256(Path(f).read_bytes()).hexdigest()!=h for f,h in hashes.items()):raise ValueError('quarter_input_changed')
    with FactRepository(a.fact_root) as repo:
        if repo.generation!=generation:raise ValueError('quarter_catalog_changed')
        symbols={p['ticker'] for parent in parents.values() for s in parent['styles'] for p in s['quarters'][-1]['positions']}
        symbols.update(p['ticker'] for packet in packets.values() for rows in packet['schedules'].values() for q in rows for p in q['positions'])
        unexpected=repo.db.execute("SELECT ticker,action,cast(date AS VARCHAR) FROM actions WHERE (ticker IN (SELECT * FROM unnest(?)) OR contraticker IN (SELECT * FROM unnest(?))) AND date>=? AND date<=? AND action NOT IN ('dividend','split')",
            [sorted(symbols),sorted(symbols),start,a.as_of]).fetchall()
        if unexpected:raise ValueError('new_corporate_action_review_required:'+json.dumps(unexpected))
    (output/'selections.json').write_text(json.dumps(packets,allow_nan=False,sort_keys=True))
    print(json.dumps({'status':'ready','sourceGeneration':generation,'selections':str(output/'selections.json')}))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('fact-root','output','rates','qqq-source'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--parent',type=Path)
    p.add_argument('--as-of',required=True)
    run(p.parse_args())
