import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {regressionGate} from './strategy-regression-matrix.mjs';

const [oldDir,newDir,out]=process.argv.slice(2);
if(!oldDir||!newDir||!out||fs.existsSync(out))throw Error('Usage: previous-run next-run NEW_REPORT_FILE');
const read=dir=>{
 const summary=JSON.parse(fs.readFileSync(path.join(dir,'summary.json')));
 const rows=fs.readFileSync(path.join(dir,'cases.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
 assert.equal(rows.length,summary.expected);assert.equal(summary.completed,summary.expected);
 assert.equal(new Set(rows.map(r=>r.id)).size,rows.length);return {summary,rows};
};
const before=read(oldDir),after=read(newDir),byId=new Map(before.rows.map(r=>[r.id,r]));
assert.deepEqual([...byId.keys()].sort(),after.rows.map(r=>r.id).sort(),'different test populations');
const improved=[],regressed=[],changedReadyCurves=[];
for(const row of after.rows) {
 const old=byId.get(row.id);
 if(old.status==='ready'&&row.status!=='ready')regressed.push(row);
 if(old.status!=='ready'&&row.status==='ready')improved.push(row);
 if(old.status==='ready'&&row.status==='ready')for(const [kind,curve] of Object.entries(old.curves??{})) {
  if(curve.equityHash&&row.curves?.[kind]?.equityHash!==curve.equityHash)
   changedReadyCurves.push({id:row.id,rules:row.rules,kind,before:curve.equityHash,after:row.curves?.[kind]?.equityHash??null});
 }
}
const gate=regressionGate(after.rows,before.rows);
const result={scope:'population_non_regression_not_all_configurations_ready',
 status:regressed.length||changedReadyCurves.length||gate.errors||gate.invalid?'fail':'pass',
 allConfigurationsReady:gate.status==='pass',before:before.summary,after:after.summary,
 improved:improved.length,regressed,changedReadyCurves,
 improvedCases:improved.map(r=>({id:r.id,rules:r.rules})),remaining:after.rows.filter(r=>r.status!=='ready').length};
fs.writeFileSync(out,JSON.stringify(result,null,2),{flag:'wx',mode:0o600});
console.log(JSON.stringify({status:result.status,scope:result.scope,allConfigurationsReady:result.allConfigurationsReady,
 improved:result.improved,regressed:regressed.length,changedReadyCurves:changedReadyCurves.length,remaining:result.remaining}));
if(result.status!=='pass')process.exitCode=1;
