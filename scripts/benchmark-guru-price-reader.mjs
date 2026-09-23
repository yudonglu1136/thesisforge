import fs from 'node:fs';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
const repo=path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const mode=process.argv[2];
const root=repo+'/data/fact_os';
const manifest=root+'/manifests/catalog.json';
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const requests=['SPY','MSFT','AMZN','NVDA','LOW','QSR'].map(symbol=>({symbol,start:'2016-09-23',end:'2026-09-21',priceType:'TOTAL_RETURN_ADJUSTED_CLOSE'}));
if(mode){
 Object.assign(process.env,{SQLITE_DB_PATH:':memory:',FACT_OS_ROOT:root,FACT_OS_ENABLED:'1',SYNC_BUNDLED_VALUATION_SNAPSHOTS:'false',SYNC_BUNDLED_GURU_BACKTESTS:'false',SYNC_BUNDLED_DIVIDEND_CALENDAR:'false',SYNC_BUNDLED_PODCAST_INSIGHTS:'false'});
 const market=await import(repo+'/server/marketData.js');
 const before=sha(fs.readFileSync(manifest));
 const started=performance.now();
 const result=mode==='batch'?await market.loadPriceSeriesBatch(requests):await Promise.all(requests.map(({symbol,...options})=>market.loadPriceSeries(symbol,options)));
 const elapsedMs=performance.now()-started;
 if(before!==sha(fs.readFileSync(manifest)))throw Error('source_catalog_changed');
 if(result.some(r=>r.status!=='available'))throw Error('real_price_coverage_missing');
 console.log(JSON.stringify({mode,elapsedMs,catalogSha256:before,semanticSha256:sha(JSON.stringify(result.map(({generatedAt,...row})=>row))),securities:result.map(r=>({symbol:r.symbol,points:r.points.length,first:r.points[0].date,last:r.points.at(-1).date})),peakRssKiB:process.resourceUsage().maxRSS}));
}else{
 const results=[];
 for(let repeat=0;repeat<3;repeat++)for(const mode of repeat%2?['batch','single']:['single','batch']){
  const result=spawnSync(process.execPath,[import.meta.filename,mode],{encoding:'utf8',timeout:300000,maxBuffer:1024*1024});
  if(result.status!==0)throw Error(result.stderr||result.stdout);
  const row=JSON.parse(result.stdout.trim().split('\n').at(-1));results.push(row);console.log(JSON.stringify(row));
 }
 if(new Set(results.map(r=>r.semanticSha256)).size!==1||new Set(results.map(r=>r.catalogSha256)).size!==1)throw Error('comparison_mismatch');
 const median=mode=>results.filter(r=>r.mode===mode).map(r=>r.elapsedMs).sort((a,b)=>a-b)[1];
 const report={scope:'Six real 10Y canonical histories, three fresh-process repetitions per mode; reader-only benchmark, not API p95 or production latency.',pass:true,inputs:requests,results,singleMedianMs:median('single'),batchMedianMs:median('batch'),improvementPercent:100*(1-median('batch')/median('single'))};
 fs.writeFileSync(path.join(os.tmpdir(),'guru-price-batch-benchmark.json'),JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify({pass:report.pass,singleMedianMs:report.singleMedianMs,batchMedianMs:report.batchMedianMs,improvementPercent:report.improvementPercent}));
}
