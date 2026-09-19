import fs from 'node:fs';
import assert from 'node:assert/strict';
const [journal,report]=process.argv.slice(2);
assert.ok(journal&&report&&!fs.existsSync(report),'new report required');
const rows=fs.readFileSync(journal,'utf8').trim().split('\n').map(JSON.parse);
const causes={},missing=new Map(),groups={};
for(const r of rows){
  const group=r.name.startsWith('factors-')?'factors':r.name==='all-components'?'mixed':/^(QQQ|SPY|SCHD)-/.test(r.name)?'index_cta':'guru';
  groups[group]??={};groups[group][r.status]=(groups[group][r.status]??0)+1;
  if(r.status==='ready')continue;
  const f=r.failure;
  const reason=f.managerExclusions?.length?[...new Set(f.managerExclusions.map(x=>x.code))].sort().join('+'):
    f.selected>0?[...new Set(f.exclusions?.map(x=>x.status)??[])].sort().join('+')||f.code:f.code;
  causes[reason]=(causes[reason]??0)+1;
  if(f.code==='missing_active_price')missing.set(`${f.date}|${(f.tickers??[f.ticker]).join(',')}`,f);
}
assert.equal(rows.length,793);
assert.deepEqual(groups.factors,{ready:90});assert.deepEqual(groups.index_cta,{ready:60});assert.deepEqual(groups.mixed,{ready:3});
const result={cases:rows.length,groups,byRootCause:causes,missingActivePrices:[...missing.values()],
  policy:'Expected data/rule blocks are not successful backtests; every unresolved reason remains in the case journal.'};
fs.writeFileSync(report,JSON.stringify(result,null,2),{flag:'wx',mode:0o600});console.log(JSON.stringify(result));
