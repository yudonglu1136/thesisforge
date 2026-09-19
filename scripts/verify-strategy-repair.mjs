import fs from 'node:fs';
import assert from 'node:assert/strict';
import {loadStoredStrategyData,storedStrategyCatalog} from '../server/strategyDatabase.js';
import {strategyActionFor,strategyComparisonPrices} from '../server/strategyLabSource.js';
import {strategyRules,runStrategyLab} from '../server/strategyLab.js';
const [file,out]=process.argv.slice(2);
if(!file||!out)throw Error('Usage: candidate.sqlite NEW_REPORT.json');
const common={managers:['bill-ackman','li-lu','warren-buffett'],topN:5,valuationEnabled:true,maxPremium:.3,
 excludedAllocation:'redistribute',cta:'KMLM',ctaWeight:.3,costBps:10,start:'2021-08-28',end:'2026-08-28',asOf:'2026-08-28'};
const catalog=storedStrategyCatalog(file,common.asOf);
assert.ok(catalog.managers.every(m=>m.avatar===`/guru-avatars/${m.id}.png`));
const baseRules=strategyRules(common,catalog.managers);
const data=loadStoredStrategyData(file,baseRules,{comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
const variants=[{name:'Screenshot: 3 Gurus Top5 KMLM30 premium30'},
 ...[1,3,10].map(topN=>({name:`Top ${topN}`,topN})),
 ...common.managers.map(id=>({name:id,managers:[id]})),
 {name:'Premium 15%',maxPremium:.15},{name:'DBMF 50%',cta:'DBMF',ctaWeight:.5},
 {name:'No valuation, no CTA',valuationEnabled:false,cta:'none',ctaWeight:0},
 {name:'Leverage 1.5x',leverage:{multiple:1.5,annualRate:.04,reset:'filing'}},
 {name:'1 year',start:'2025-08-28'},{name:'3 years',start:'2023-08-28'}];
const report={database:file,generation:data.sources.generation,checks:[],sourceWrites:0};
for(const {name,...options} of variants){
 const rules=strategyRules({...common,...options},catalog.managers),result=runStrategyLab(data,rules);
 for(const l of result.ledger??[]){assert.ok(Math.abs(l.holdings.reduce((s,h)=>s+h.targetWeight,0)+l.cashWeight+l.ctaWeight-1)<1e-8);assert.ok(l.filings.every(f=>f.publicDate<l.executionDate));assert.ok(l.holdings.every(h=>!h.modelDate||h.modelDate<=l.decisionDate));}
 const row={name,status:result.status,failure:result.failure,effective:result.effective,rows:result.results?.blend?.equity?.length,coverage:result.summary&&{execution:result.summary.minExecutionCoverage,model:result.summary.minModelCoverage,rebalances:result.summary.rebalances},
  metrics:Object.fromEntries(Object.entries(result.results??{}).map(([k,v])=>[k,{status:v.status,failure:v.failure,metrics:v.metrics}]))};
 report.checks.push(row);console.log(JSON.stringify(row));
 if(name.startsWith('Screenshot'))fs.writeFileSync(out.replace(/\.json$/,'.screenshot.json'),JSON.stringify(result),{flag:'wx',mode:0o600});
}
report.status=report.checks.every(r=>r.status==='ready')?'pass':'blocked';
fs.writeFileSync(out,JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
if(report.status!=='pass')process.exitCode=1;
