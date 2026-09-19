// Counterfactual check: every previously changed READY curve must reconcile
// when only the calendar fix is applied to the unchanged, old database.
// This does not waive the full population's remaining data blockers.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {signature} from '../server/investmentMath.js';
import {loadStoredStrategyData} from '../server/strategyDatabase.js';
import {strategyActionFor,strategyComparisonPrices} from '../server/strategyLabSource.js';
import {runStrategyLab,STRATEGY_CALCULATION_VERSION} from '../server/strategyLab.js';
const [comparisonFile,out]=process.argv.slice(2);
if(!comparisonFile||!out||fs.existsSync(out))throw Error('Usage: comparison.json NEW_REPORT_FILE');
const comparison=JSON.parse(fs.readFileSync(comparisonFile));
assert.equal(comparison.regressed.length,0,'ready-to-blocked regression');
const changed=comparison.changedReadyCurves;
assert.ok(changed.length,'no changed curves to investigate');
const cases=[...new Map(changed.map(r=>[r.id,r])).values()],checks=[];
let key,data;
for(const item of cases){
 const next=signature(item.rules);
 if(next!==key){
  data=loadStoredStrategyData(comparison.before.database,{...item.rules,valuationEnabled:true},
   {comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});key=next;
 }
 const result=runStrategyLab(data,item.rules);
 for(const curve of changed.filter(r=>r.id===item.id)){
  const actual=result.results?.[curve.kind];
  checks.push({id:item.id,kind:curve.kind,expected:curve.after,
   actual:actual?.status==='ready'?signature(actual.equity):null,
   status:actual?.status==='ready'&&signature(actual.equity)===curve.after?'pass':'fail'});
 }
}
const report={scope:'counterfactual_schedule_correction_not_release_readiness',
 calculationVersion:STRATEGY_CALCULATION_VERSION,database:comparison.before.database,
 generation:comparison.before.generation,cases:cases.length,curves:checks.length,
 status:checks.every(c=>c.status==='pass')?'pass':'fail',checks};
fs.writeFileSync(out,JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
console.log(JSON.stringify({...report,checks:undefined}));
if(report.status!=='pass')process.exitCode=1;
