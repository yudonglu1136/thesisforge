import fs from 'node:fs';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import assert from 'node:assert/strict';
import {signature} from '../server/investmentMath.js';
import {gurus} from '../server/gurus.js';
import {storedStrategyCatalog,loadStoredStrategyData} from '../server/strategyDatabase.js';
import {strategyActionFor,strategyComparisonPrices} from '../server/strategyLabSource.js';
import {STRATEGY_CALCULATION_VERSION,strategyRules,runStrategyLab} from '../server/strategyLab.js';
import {strategyRegressionCases,verifyStrategyResult,regressionGate,yearsBefore} from './strategy-regression-matrix.mjs';

const [file,out,cutoff='2026-08-28',allocationOverride]=process.argv.slice(2);
if(!file||!out||fs.existsSync(out))throw Error('Usage: strategy.sqlite NEW_OUTPUT_DIRECTORY [cutoff]');
assert.ok(!allocationOverride||allocationOverride==='fully_invested','unsupported allocation override');
fs.mkdirSync(out,{mode:0o700});
const catalog=storedStrategyCatalog(file,cutoff);
const ids=gurus.filter(g=>g.type==='manager13f'&&!g.disableSimulation).map(g=>g.id).sort();
assert.deepEqual(catalog.managers.map(g=>g.id).sort(),ids,'serving catalog must include the exact configured population');
const generated=strategyRegressionCases(ids,cutoff);
const cases=allocationOverride?[...new Map(generated.map(item=>{
 const rules={...item.rules,excludedAllocation:allocationOverride};
 const id=signature({kind:item.kind,rules});return [id,{...item,id,rules}];
})).values()]:generated,rows=[];
const startedAt=new Date().toISOString(),journal=fs.openSync(path.join(out,'cases.jsonl'),'wx',0o600);
const write=(name,value)=>fs.writeFileSync(path.join(out,name),JSON.stringify(value,null,2),{flag:'wx',mode:0o600});
write('plan.json',{database:file,generation:catalog.storage.generation,calculationVersion:STRATEGY_CALCULATION_VERSION,
 startedAt,cutoff,allocationPolicy:allocationOverride??'legacy_matrix',managers:ids,cases:cases.length,core:ids.length*10*4,allManagerPairs:ids.length*(ids.length-1)/2,
 limitations:'Exhaustive single-manager Top 1–10 and 1/3/5/10Y. All manager pairs, parameter levels and rotating 3/10-manager interactions; not every continuous slider value, date or possible subset.'});
let data,key;
try {
 for(const item of cases) {
  const begin=performance.now();let row;
  try {
   const rules=strategyRules(item.rules,catalog.managers),next=rules.managers.join(',');
   if(next!==key) {
    data=loadStoredStrategyData(file,{...rules,start:yearsBefore(cutoff,10),valuationEnabled:true},
     {comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});key=next;
   }
   const result=runStrategyLab(data,rules);
   verifyStrategyResult(result,data,rules);
   row={...item,status:result.status,failure:result.failure,curves:Object.fromEntries(Object.entries(result.results??{}).map(([k,v])=>[k,{status:v.status,rows:v.equity?.length??0,failure:v.failure??null,
    metrics:v.metrics??null,equityHash:v.status==='ready'?signature(v.equity):null}])),
    rebalances:result.ledger?.length??0,snapshots:result.holdingSnapshots?.length??0,
    snapshotHash:signature(result.holdingSnapshots??[])};
  } catch(error) {row={...item,status:'error',failure:{code:error.message,stack:error.stack}};}
  row.elapsedMs=Math.round(performance.now()-begin);rows.push(row);fs.writeSync(journal,JSON.stringify(row)+'\n');
  if(rows.length%50===0||row.status==='error')console.log(JSON.stringify({completed:rows.length,total:cases.length,manager:item.rules.managers,status:row.status,failure:row.failure?.code}));
 }
} finally {fs.closeSync(journal);}
const db=new DatabaseSync(file,{readOnly:true});
const integrity=db.prepare('PRAGMA integrity_check').get(),foreignKeyIssues=db.prepare('PRAGMA foreign_key_check').all().length;
const sourceWrites=db.prepare('SELECT total_changes() n').get().n;db.close();
assert.equal(Object.values(integrity)[0],'ok');assert.equal(foreignKeyIssues,0);assert.equal(sourceWrites,0);
const gate=regressionGate(rows,cases),failures={};
for(const row of rows)if(row.status!=='ready')failures[row.failure?.code??row.status]=(failures[row.failure?.code??row.status]??0)+1;
write('summary.json',{...gate,database:file,generation:catalog.storage.generation,calculationVersion:STRATEGY_CALCULATION_VERSION,
 startedAt,finishedAt:new Date().toISOString(),managers:ids,cutoff,allocationPolicy:allocationOverride??'legacy_matrix',failures,integrity,foreignKeyIssues,sourceWrites});
console.log(JSON.stringify({...gate,failures}));
if(gate.status!=='pass')process.exitCode=1;
