// Real-data regression matrix. Keep every configured manager in the report,
// including unavailable histories and identity blocks; never shorten a run.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {storedStrategyCatalog,loadStoredStrategyData} from '../server/strategyDatabase.js';
import {strategyActionFor,strategyComparisonPrices} from '../server/strategyLabSource.js';
import {strategyRules,runStrategyLab} from '../server/strategyLab.js';

const [file,out,onlyIds]=process.argv.slice(2);
if(!file||!out||fs.existsSync(out))throw Error('Usage: candidate.sqlite NEW_REPORT.json [manager-ids]');
const common={topN:5,valuationEnabled:true,maxPremium:.3,excludedAllocation:'redistribute',
 cta:'KMLM',ctaWeight:.3,costBps:10,start:'2021-08-28',end:'2026-08-28',asOf:'2026-08-28'};
const catalog=storedStrategyCatalog(file,common.asOf);
const ids=onlyIds?onlyIds.split(','):catalog.managers.map(m=>m.id);
assert.ok(ids.every(id=>catalog.managers.some(m=>m.id===id)));
const report={database:file,generation:catalog.storage.generation,cutoff:common.asOf,
 selectedManagers:ids,catalogManagers:catalog.managers.map(m=>m.id),checks:[],sourceWrites:0};
const dataFor=managers=>loadStoredStrategyData(file,{...common,managers},
 {comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
function check(name,data,options,{save=false}={}) {
 const rules=strategyRules({...common,...options},catalog.managers),r=runStrategyLab(data,rules);
 for(const l of r.ledger??[]) {
  assert.ok(Math.abs(l.holdings.reduce((s,h)=>s+h.targetWeight,0)+l.cashWeight+l.ctaWeight-1)<1e-8);
  assert.ok(l.filings.every(f=>f.publicDate<l.executionDate));
  assert.ok(l.holdings.every(h=>!h.modelDate||h.modelDate<=l.decisionDate));
 }
 if(r.status==='ready') {
  const equity=r.results.blend.equity;
  assert.ok(equity.length>=20);
  assert.equal(equity[0].date,data.dates.find(d=>d>=rules.start));
  assert.equal(equity.at(-1).date,data.dates.filter(d=>d<=rules.end).at(-1));
  assert.ok(equity.every((p,i)=>Number.isFinite(p.value)&&p.value>0&&(!i||p.date>equity[i-1].date)));
 }
 const row={name,managers:rules.managers,start:rules.start,end:rules.end,topN:rules.topN,
  status:r.status,failure:r.failure??null,rows:r.results?.blend?.equity?.length??0,
  coverage:r.summary?{execution:r.summary.minExecutionCoverage,model:r.summary.minModelCoverage,rebalances:r.summary.rebalances}:null};
 report.checks.push(row);console.log(JSON.stringify(row));
 if(save)fs.writeFileSync(out.replace(/\.json$/,'.screenshot.json'),JSON.stringify(r),{flag:'wx',mode:0o600});
}
const screenshot=['dev-kantesaria','li-lu','samantha-mclemore'];
const mixedData=dataFor(screenshot);
check('User screenshot — Dev / Li / Samantha, 1Y',mixedData,{managers:screenshot,start:'2025-08-28'},{save:true});
for(const options of [
 {name:'3Y',start:'2023-08-28'},
 {name:'Premium 15%',start:'2025-08-28',maxPremium:.15},
 {name:'DBMF 50%',start:'2025-08-28',cta:'DBMF',ctaWeight:.5},
 {name:'Leverage 1.5x / 4%',start:'2025-08-28',leverage:{multiple:1.5,annualRate:.04,reset:'filing'}},
 {name:'No filter / no CTA',start:'2025-08-28',valuationEnabled:false,cta:'none',ctaWeight:0},
])check(`User mix — ${options.name}`,mixedData,{managers:screenshot,...options});
for(const id of ids) {
 const data=dataFor([id]);
 for(const years of [1,3,5])for(const topN of [1,5,10])
  check(`${id} ${years}Y Top${topN}`,data,{managers:[id],start:`${2026-years}-08-28`,topN});
}
const db=new DatabaseSync(file,{readOnly:true});
report.integrity=db.prepare('PRAGMA integrity_check').get();
report.foreignKeyIssues=db.prepare('PRAGMA foreign_key_check').all().length;
report.sourceWrites=db.prepare('SELECT total_changes() n').get().n;
report.classification=db.prepare(`SELECT m.id,m.identity_status,COUNT(f.id) filings,
 SUM(f.classification_status='verified') verified
 FROM managers m LEFT JOIN filings f ON f.manager_id=m.id AND f.report_date>='2021-06-30'
 WHERE m.simulation_enabled=1 GROUP BY m.id ORDER BY m.id`).all();
db.close();
assert.equal(report.foreignKeyIssues,0);assert.equal(report.sourceWrites,0);
assert.equal(Object.values(report.integrity)[0],'ok');
report.ready=report.checks.filter(r=>r.status==='ready').length;
report.blocked=report.checks.filter(r=>r.status!=='ready').length;
report.failureCounts={};
for(const c of report.checks.filter(r=>r.status!=='ready'))report.failureCounts[c.failure?.code??c.status]=(report.failureCounts[c.failure?.code??c.status]??0)+1;
fs.writeFileSync(out,JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
console.log(JSON.stringify({ready:report.ready,blocked:report.blocked,failureCounts:report.failureCounts}));
// This is a population gate, not a screenshot smoke check. Any unresolved
// configuration must keep the overall run red, including genuine source gaps.
if(report.blocked)process.exitCode=1;
