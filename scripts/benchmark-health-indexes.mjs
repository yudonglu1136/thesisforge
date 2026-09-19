import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { Worker } from 'node:worker_threads';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { gzipSync } from 'node:zlib';
const [repo, baselineDb, indexedDb] = process.argv.slice(2);
if (!indexedDb) throw Error('Usage: node benchmark REPO BASELINE_SQLITE INDEXED_SQLITE');
const url = file => pathToFileURL(path.join(repo, 'server', file)).href;
const {createPublicHealthWorkerBuilder} = await import(url('publicHealthWorkerRunner.js'));
const {createPublicHealthService} = await import(url('publicHealthService.js'));
const {holdingResolutionVersion} = await import(url('cusipOverrides.js'));
const source = fs.readFileSync(path.join(repo,'server/backtest.js'),'utf8');
const constant = name => source.match(new RegExp(`export const ${name} = "([^"]+)"`))[1];
const methodIdentity = {backtestEndGraceDays:12,manager13fBacktestMethodVersion:constant('manager13fBacktestMethodVersion'),
  manager13fProxyMethodVersion:constant('manager13fProxyMethodVersion'),manager13fSecurityMasterVersion:holdingResolutionVersion()};
const baselineSource = execFileSync('git',['show','47973e1:server/databaseTableSummaries.js'],{cwd:repo,encoding:'utf8'});
const baselineModule = `data:text/javascript;base64,${Buffer.from(baselineSource).toString('base64')}`;
const workerSource = `
  const {parentPort,workerData}=require('node:worker_threads');
  (async()=>{
    const {DatabaseSync}=await import('node:sqlite');
    const {createSystemHealth}=await import(workerData.coreUrl);
    const {readDatabaseTableSummariesFrom}=await import(workerData.summaryUrl);
    const db=new DatabaseSync(workerData.databasePath,{readOnly:true});
    try {
      db.exec('PRAGMA query_only=ON;PRAGMA busy_timeout=250;PRAGMA cache_size=-8192;PRAGMA mmap_size=0;BEGIN');
      const read=(table,id,years)=>{const row=db.prepare('SELECT payload_json FROM '+table+' WHERE guru_id=? AND years=?').get(id,years);try{return row?JSON.parse(row.payload_json):null;}catch{return null;}};
      const api=createSystemHealth({...workerData.methodIdentity,databaseInfo:()=>({path:workerData.databasePath}),
        readDatabaseTableSummaries:()=>readDatabaseTableSummariesFrom(db),
        readGuruBacktest:(id,y)=>read('guru_backtests',id,y),readGuruBacktestProxy:(id,y)=>read('guru_backtest_proxies',id,y)});
      parentPort.postMessage({health:api.buildPublicSystemHealth(workerData.options)});
    } finally {db.close();parentPort.close();}
  })().catch(()=>parentPort.postMessage({error:'health_audit_failed'}));
`;
const now = Date.parse('2026-09-12T21:00:00Z');
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
function semanticHealth(health) {
  const copy=structuredClone(health);
  // Only file-level metadata necessarily changes when adding indexes. Economic
  // source dates, counts, all matrix outcomes and all readiness gates remain.
  delete copy.database.sizeBytes; delete copy.database.updatedAt;
  const module=copy.modules.find(row=>row.id==='database');
  delete module.details.sizeBytes; delete module.freshness.latestAt; delete module.freshness.ageHours;
  return copy;
}
const results=[];
let expectedHash;
let expectedRawHash;
for(const variant of ['before','after']) {
  for(let round=1;round<=3;round++) {
    const databasePath=variant==='before'?baselineDb:indexedDb;
    const exits=[];
    let workers=0;
    const builder=createPublicHealthWorkerBuilder({databasePath,methodIdentity,workerFactory:workerData=>{
      workers++;
      const worker=new Worker(workerSource,{eval:true,resourceLimits:{maxOldGenerationSizeMb:256,maxYoungGenerationSizeMb:16,stackSizeMb:4},
        workerData:{...workerData,coreUrl:url('systemHealthCore.js'),summaryUrl:variant==='before'?baselineModule:url('databaseTableSummaries.js')}});
      exits.push(new Promise(resolve=>worker.once('exit',resolve)));
      return worker;
    }});
    const api=createPublicHealthService({resolveOntology:async()=>({}),buildHealth:options=>builder.buildHealth({...options,now}),
      successTtlMs:0,failureTtlMs:0,now:()=>now});
    const latencies=[];
    let payload;
    for(let wave=0;wave<3;wave++) {
      const responses=await Promise.all(Array.from({length:20},async()=>{
        const start=performance.now(); const value=await api.read(); latencies.push(performance.now()-start); return value;
      }));
      await Promise.all(exits);
      for(const health of responses) {
        if(health.modules.some(module=>module.details?.verificationError))throw Error('Audit did not complete');
        const hash=digest(semanticHealth(health)); expectedHash??=hash;
        if(hash!==expectedHash)throw Error('Semantic health response changed');
        if(baselineDb===indexedDb) {
          expectedRawHash??=digest(health);
          if(digest(health)!==expectedRawHash)throw Error('Complete response changed on identical snapshot');
        }
        payload=health;
      }
    }
    latencies.sort((a,b)=>a-b);
    const bytes=Buffer.from(JSON.stringify(payload));
    const curves=payload.modules.find(row=>row.id==='guru_backtests').details.curveAvailability;
    const result={variant,round,samples:latencies.length,concurrency:20,workers,p95Ms:+latencies[56].toFixed(2),
      semanticSha256:expectedHash,responseBytes:bytes.length,gzipBytes:gzipSync(bytes).length,
      completeResponseSha256:expectedRawHash||null,
      matrix:{expectedRows:curves.expectedRows,displayable:curves.displayable,failures:curves.failures.length}};
    results.push(result);process.stdout.write(JSON.stringify(result)+'\n');
  }
}
const median=values=>values.sort((a,b)=>a-b)[1];
const beforeP95=median(results.filter(row=>row.variant==='before').map(row=>row.p95Ms));
const afterP95=median(results.filter(row=>row.variant==='after').map(row=>row.p95Ms));
process.stdout.write(JSON.stringify({phase:'complete',node:process.version,sourceRevision:'47973e1',beforeMedianP95Ms:beforeP95,afterMedianP95Ms:afterP95,
  improvementPct:+((1-afterP95/beforeP95)*100).toFixed(2),semanticSha256:expectedHash,completeResponseSha256:expectedRawHash||null})+'\n');
