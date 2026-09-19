// Local serving/worker parity, separate from the complete calculation matrix.
// POST /strategy-backtests computes only; this verifier never saves rules.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {signature} from '../server/investmentMath.js';
import {loadStoredStrategyData} from '../server/strategyDatabase.js';
import {strategyActionFor,strategyComparisonPrices} from '../server/strategyLabSource.js';
import {strategyRules,runStrategyLab} from '../server/strategyLab.js';
const [dir,out,base='http://127.0.0.1:8789']=process.argv.slice(2);
if(!dir||!out||fs.existsSync(out))throw Error('Usage: completed-matrix-dir NEW_REPORT_FILE [local-origin]');
assert.ok(['127.0.0.1','localhost'].includes(new URL(base).hostname),'local verification only');
const token=process.env.STRATEGY_VERIFY_TOKEN;if(!token)throw Error('STRATEGY_VERIFY_TOKEN required');
const summary=JSON.parse(fs.readFileSync(path.join(dir,'summary.json')));
const cases=fs.readFileSync(path.join(dir,'cases.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
assert.equal(cases.length,summary.expected);assert.equal(summary.completed,summary.expected);
const headers={Authorization:'Bearer '+token,'Content-Type':'application/json'};
const catalogPath=base+'/api/investment/strategy-lab?asOf='+summary.cutoff;
assert.equal((await fetch(catalogPath)).status,401,'anonymous request must be denied');
const catalogResponse=await fetch(catalogPath,{headers});assert.equal(catalogResponse.status,200);
const catalog=await catalogResponse.json();assert.equal(catalog.storage.generation,summary.generation);
assert.deepEqual(catalog.managers.map(m=>m.id).sort(),summary.managers);
const selected=new Map();const add=row=>{assert.ok(row,'missing matrix case');selected.set(row.id,row);};
for(const id of summary.managers)add(cases.find(c=>c.kind==='manager_top_horizon'&&c.rules.managers[0]===id&&c.rules.topN===1));
for(const cta of ['KMLM','DBMF'])for(const years of [1,3,5,10])
 add(cases.find(c=>c.kind==='parameter_interaction'&&c.rules.cta===cta&&c.rules.start.startsWith(String(Number(summary.cutoff.slice(0,4))-years))));
for(const multiple of [1.25,1.5,2])add(cases.find(c=>c.status==='ready'&&c.rules.leverage.multiple===multiple));
for(const size of [2,3,10])add(cases.find(c=>c.rules.managers.length===size));
const rows=[...selected.values()],checks=[];
for(let i=0;i<rows.length;i+=2)await Promise.all(rows.slice(i,i+2).map(async item=>{
 const begin=performance.now();
 const response=await fetch(base+'/api/investment/strategy-backtests',{method:'POST',headers,body:JSON.stringify(item.rules),signal:AbortSignal.timeout(60000)});
 assert.equal(response.status,200,item.id+': HTTP');const result=await response.json();
 assert.equal(result.sources.generation,summary.generation,item.id+': generation');
 assert.equal(result.calculationVersion,summary.calculationVersion,item.id+': code version');
 assert.equal(result.status,item.status,item.id+': status');
 assert.equal(result.failure?.code,item.failure?.code,item.id+': failure');
 if(item.snapshotHash){
  // The population sweep deliberately caches a ten-year source extract. Its
  // provenance hashes (and snapshot IDs) differ from the HTTP worker's exact
  // requested extract even when every holding/NAV agrees. Recompute the same
  // requested source window here and compare ALL snapshot fields, including ID.
  const rules=strategyRules(item.rules,catalog.managers);
  const data=loadStoredStrategyData(summary.database,rules,{comparisonPrices:strategyComparisonPrices,actionFor:strategyActionFor});
  const exact=runStrategyLab(data,rules);
  assert.equal(signature(result.holdingSnapshots??[]),signature(exact.holdingSnapshots??[]),item.id+': exact-window holdings snapshot parity');
 }
 for(const [kind,curve] of Object.entries(item.curves??{})){
  assert.equal(result.results?.[kind]?.status,curve.status,item.id+': '+kind);
  if(curve.status==='ready')assert.equal(signature(result.results[kind].equity),curve.equityHash,item.id+': '+kind+' curve');
 }
 checks.push({id:item.id,managers:item.rules.managers,expected:item.status,status:'pass',elapsedMs:Math.round(performance.now()-begin)});
}));
const report={status:'pass',scope:'local_http_worker_parity_not_all_configurations_ready',generation:summary.generation,
 calculationVersion:summary.calculationVersion,anonymousDenied:true,savedRulesWritten:0,checks};
fs.writeFileSync(out,JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
console.log(JSON.stringify({...report,checks:checks.length}));
