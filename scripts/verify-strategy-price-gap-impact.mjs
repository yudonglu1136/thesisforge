// Explain changed previously-ready curves, without changing regression gates.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {loadStoredStrategyData} from '../server/strategyDatabase.js';
import {strategyComparisonPrices,strategyActionFor} from '../server/strategyLabSource.js';
import {runStrategyLab} from '../server/strategyLab.js';
import {signature} from '../server/investmentMath.js';
const [beforeFile,afterFile,comparisonFile,out]=process.argv.slice(2);
if(!out||fs.existsSync(out))throw Error('Usage: BEFORE.sqlite AFTER.sqlite COMPARISON.json NEW_REPORT.json');
const comparison=JSON.parse(fs.readFileSync(comparisonFile));
assert.equal(comparison.regressed.length,0);
const cases=new Map(comparison.changedReadyCurves.map(r=>[r.id,r])),checks=[];
for(const [id,c] of cases) {
  const load=f=>loadStoredStrategyData(f,c.rules,{comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
  const oldData=load(beforeFile),newData=load(afterFile),old=runStrategyLab(oldData,c.rules),fresh=runStrategyLab(newData,c.rules);
  const changes=fresh.ledger.flatMap((l,i)=>l.holdings.flatMap(h=>{
    const prior=old.ledger[i]?.holdings.find(x=>x.cusip===h.cusip);
    return prior&&(prior.status!==h.status||prior.targetWeight!==h.targetWeight)?[{
      date:l.executionDate,ticker:h.ticker,cusip:h.cusip,before:{status:prior.status,weight:prior.targetWeight},after:{status:h.status,weight:h.targetWeight}}]:[];
  }));
  // Restore only symbols implicated in a changed allocation, not all inputs.
  const restored=[...new Set(changes.map(c=>c.ticker))];
  assert.ok(restored.length,'changed curve without a documented allocation cause');
  for(const symbol of restored){newData.priceMaps.set(symbol,oldData.priceMaps.get(symbol));newData.comparisonPrices.set(symbol,oldData.comparisonPrices.get(symbol));}
  const counterfactual=runStrategyLab(newData,c.rules);
  for(const [name,curve] of Object.entries(old.results))if(curve.status==='ready')
    assert.equal(signature(counterfactual.results[name].equity),signature(curve.equity),name+' counterfactual mismatch');
  checks.push({id,managers:c.rules.managers,changes,restored,exactCurveHashesRecovered:true});
}
const report={status:'pass',scope:'explanation_of_changed_ready_curves_not_all_configurations_ready',checks};
fs.writeFileSync(out,JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
console.log(JSON.stringify(report));
