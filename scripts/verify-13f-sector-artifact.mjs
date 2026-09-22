#!/usr/bin/env node
import fs from 'node:fs';
import {DatabaseSync} from 'node:sqlite';
import {gunzipSync,gzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {institutional13fInsights,institutional13fSectorDetail} from '../server/institutional13fInsights.js';

const [file,previous,output]=process.argv.slice(2);
const db=new DatabaseSync(file,{readOnly:true}),old=new DatabaseSync(previous,{readOnly:true});
const source={db},almost=(a,b)=>assert.ok(Math.abs(a-b)<1e-5*Math.max(1,Math.abs(b)),`${a} != ${b}`);
const snapshots=db.prepare('SELECT * FROM institutional_13f_active_snapshots_v1').all();
let rows=0,positions=0;
const sectors=db.prepare('SELECT * FROM institutional_13f_active_sectors_v1').all();
for(const stored of sectors) {
  const raw=gunzipSync(stored.payload_gzip);
  assert.equal(createHash('sha256').update(raw).digest('hex'),stored.payload_hash);
  const data=JSON.parse(raw);
  for(const group of ['stocks','managers','industries']) {
    for(const metric of ['currentValueM','previousValueM','addProxyM','trimProxyM','netProxyM']) {
      const sum=data[group].filter(row=>row[metric]!=null).reduce((n,row)=>n+row[metric],0);
      if(data.summary[metric]!=null)almost(sum,data.summary[metric]);
    }
  }
  const snapshot=JSON.parse(gunzipSync(snapshots.find(row=>row.report_date===stored.report_date&&row.source_generation===stored.source_generation).payload_gzip));
  const rotation=snapshot.activeAnalysis.sectorRotation.find(row=>row.sector===stored.sector);
  assert.ok(rotation);
  almost(data.summary.currentValueM??0,rotation.currentValueM);
  almost(data.summary.previousValueM??0,rotation.previousValueM);
  rows++;positions+=data.summary.positions;
}
// This release must not change the all-institution 13F artifacts at all.
const preserved={};
for(const table of ['institutional_13f_insight_snapshots_v2','institutional_13f_insight_details_v1',
  'institutional_13f_market_history_v1','institutional_13f_security_history_v1']) {
  const hash=handle=>{
    const digest=createHash('sha256');
    for(const row of handle.prepare(`SELECT * FROM ${table} ORDER BY rowid`).iterate()) {
      for(const [key,value] of Object.entries(row)) {
        digest.update(key);digest.update(value instanceof Uint8Array?value:JSON.stringify(value));digest.update('\n');
      }
    }
    return digest.digest('hex');
  };
  const before=hash(old),after=hash(db);assert.equal(before,after,table);preserved[table]=after;
}
const result=institutional13fInsights(source,'2026-09-21',null,{scope:'active'});
const options={generation:result.sourceGeneration};
const start=performance.now();
const first=institutional13fSectorDetail(source,'Technology','2026-09-21',null,options);
const coldMs=performance.now()-start,times=[];
for(let i=0;i<60;i++) {
  const t=performance.now();institutional13fSectorDetail(source,'Technology','2026-09-21',null,{...options,offset:(i%10)*20});times.push(performance.now()-t);
}
times.sort((a,b)=>a-b);
const bytes=Buffer.from(JSON.stringify(first));
const receipt={status:'pass',sectorSnapshots:rows,quarters:snapshots.length,comparablePositionsAcrossQuarters:positions,
  generation:result.sourceGeneration,technology:first.summary,allInstitutionTablesUnchanged:preserved,
  localReadTiming:{coldMs,p95Ms:times[56],samples:60,responseBytes:bytes.length,gzipBytes:gzipSync(bytes).length},
  note:'Local direct-function timings, not HTTP or production latency. No canonical facts or private stores modified.'};
if(output)fs.writeFileSync(output,JSON.stringify(receipt,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify(receipt,null,2));
db.close();old.close();
