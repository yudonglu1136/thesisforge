"""Read-only population receipt for a price release, not a max(date) success claim."""
import argparse
import collections
import csv
import json
from pathlib import Path
import sqlite3


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--release',type=Path,required=True)
    p.add_argument('--harvest',type=Path,required=True)
    a=p.parse_args()
    proof=json.loads((a.release/'verification.json').read_text())
    source=json.loads((a.release/'population-audit.json').read_text())
    plan=json.loads((a.harvest/'plan.json').read_text())
    cutoff=proof['cutoff']
    # These are checkpointed, finalized generations, not a live writer's DB.
    # Refuse WAL files before opening immutable snapshots (which ignore WAL).
    paths=[a.release/'runtime.sqlite',a.release/'strategy.sqlite',a.harvest/'prices.sqlite']
    for path in paths:
        wal=Path(str(path)+'-wal')
        if wal.exists() and wal.stat().st_size:
            raise RuntimeError(f'Checkpoint the database before auditing: {path.name}')
    r,s,d=[sqlite3.connect(f'file:{path}?mode=ro&immutable=1',uri=True) for path in paths]
    for db in (r,s,d):
        db.execute('PRAGMA temp_store=MEMORY')
    runtime=dict(r.execute('SELECT symbol,MAX(date) FROM price_points WHERE adjusted_close>0 GROUP BY symbol'))
    warehouse=dict(s.execute("SELECT s.symbol,MAX(p.date) FROM price_series s JOIN price_observations p ON p.series_id=s.id WHERE s.storage_kind='raw_price_points' AND p.adjusted_close>0 GROUP BY s.symbol"))
    etfs=dict(s.execute('SELECT symbol,last_date FROM etf_catalog'))
    snapshots=dict(r.execute("SELECT ticker,json_extract(payload_json,'$.priceHistory[#-1].date') FROM valuation_ticker_snapshots"))
    rows=[]
    for item in source['audits']:
        symbol=item['symbol'];last=warehouse.get(symbol) or etfs.get(symbol)
        row={'symbol':symbol,'provider_status':item['providerStatus'],'provider_last':item['last'],
             'warehouse_last_adjusted':last,'runtime_last_adjusted':runtime.get(symbol),
             'research_last_quote':snapshots.get(symbol),'return_append':item['returnExtension'],
             'return_reason':item.get('returnReason'),'comparison_reason':item.get('comparisonReason'),
             'remaining_historical_sessions':len(item.get('remainingSessions',[])),
             'rejected_provider_rows':item['rejectedObservations']}
        rows.append(row)
    unfinished=[x for x in rows if x['provider_status']=='current' and x['warehouse_last_adjusted']!=cutoff]
    stale_research=[{'ticker':t,'lastQuote':date} for t,date in snapshots.items() if date!=cutoff]
    report={'cutoff':cutoff,'scope':len(rows),'generation':proof['manifestHash'],
      'providerStatuses':dict(collections.Counter(x['provider_status'] for x in rows)),
      'providerRowsStored':d.execute('SELECT COUNT(*) FROM prices').fetchone()[0],
      'previousRuntimeCurrent':sum(v['last']==cutoff for v in plan['beforeRaw'].values()),
      'runtimeCurrentWithAdjustedClose':sum(date==cutoff for date in runtime.values()),
      'strategyCurrentWithAdjustedClose':sum(date==cutoff for date in warehouse.values()),
      'researchCurrent':sum(date==cutoff for date in snapshots.values()),'researchTotal':len(snapshots),
      'latestEtfs':etfs,'append':proof['summary'],'integrity':proof['integrity'],
      'oldPriceChanges':proof['oldPriceChanges'],'protectedRuntimeTables':proof['protectedRuntimeTables'],
      'currentVendorButNotSafeToMerge':unfinished,'staleResearch':stale_research,
      'allPricesReady':not unfinished and not stale_research,
      'scopeLimit':'Local research/strategy price universe; not financial statements, broker NAV, live intraday or option contracts. Historical model evidence and former DB generations remain unchanged.'}
    (a.release/'final-price-audit.json').write_text(json.dumps(report,indent=2))
    with (a.release/'price-coverage.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    print(json.dumps({k:v for k,v in report.items() if k not in ['currentVendorButNotSafeToMerge']},indent=2))
    print('Current vendor series not safely merged:',len(unfinished))
    r.close();s.close();d.close()


if __name__=='__main__':main()
