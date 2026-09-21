#!/usr/bin/env node
import express from 'express';
import crypto from 'node:crypto';
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';
import { InvestmentSource } from '../server/investmentSource.js';
import { buildGuruHoldingsMatrix, buildOpportunities, opportunityBooks } from '../server/investmentOpportunities.js';

const arg=(name,fallback)=>process.argv.includes(name)?process.argv[process.argv.indexOf(name)+1]:fallback;
const database=arg('--database','data/releases/thesisforge-20260920-v3/research.sqlite');
const asOf=arg('--as-of','2026-09-21');
const samples=Number(arg('--samples','60')),concurrency=Number(arg('--concurrency','20'));
const output=arg('--output','');
if(samples<60||concurrency<20)throw new Error('guru_benchmark_requires_60_samples_and_concurrency_20');

const project=result=>result.rows.map(r=>({ticker:r.ticker,name:r.name,managerCount:r.managerCount,medianWeight:r.medianWeight,
  newPositions:r.newPositions,increases:r.increases,reductions:r.reductions,exits:r.exits,adds:r.adds,trims:r.trims,managers:r.managers}));
const hash=value=>crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const percentile=(values,p)=>values.slice().sort((a,b)=>a-b)[Math.ceil(values.length*p)-1];

async function runVariant(name,builder,quarters) {
  const source=new InvestmentSource(database),app=express();
  app.get('/bench',(req,res)=>{
    const reportDate=quarters[Number(req.query.i)%quarters.length];
    const started=performance.now(),result=builder(source,asOf,reportDate),semanticHash=hash(project(result));
    res.json({semanticHash,reportDate,serverMs:performance.now()-started,rows:result.rows.length});
  });
  const server=app.listen(0,'127.0.0.1');await new Promise(resolve=>server.once('listening',resolve));
  const root=`http://127.0.0.1:${server.address().port}/bench`,records=[];
  try {
    for(let start=0;start<samples;start+=concurrency) {
      const batch=[];
      for(let i=start;i<Math.min(samples,start+concurrency);i++)batch.push((async()=>{
        const t=performance.now(),response=await fetch(`${root}?i=${i}`),body=await response.json();
        if(!response.ok)throw new Error(`${name}_http_${response.status}`);
        records[i]={index:i,wallMs:performance.now()-t,...body};
      })());
      await Promise.all(batch);
    }
  } finally {await new Promise(resolve=>server.close(resolve));source.close();}
  const wall=records.map(r=>r.wallMs),serverMs=records.map(r=>r.serverMs);
  return {name,samples,concurrency,quarters:quarters.length,
    wall:{medianMs:percentile(wall,.5),p95Ms:percentile(wall,.95),maxMs:Math.max(...wall)},
    server:{medianMs:percentile(serverMs,.5),p95Ms:percentile(serverMs,.95),maxMs:Math.max(...serverMs)},records};
}

const metadataSource=new InvestmentSource(database),quarters=opportunityBooks(metadataSource,asOf).quarters.slice(0,12);metadataSource.close();
const baseline=await runVariant('full-opportunities',buildOpportunities,quarters);
const optimized=await runVariant('guru-holdings-matrix',buildGuruHoldingsMatrix,quarters);
for(let i=0;i<samples;i++)if(baseline.records[i].semanticHash!==optimized.records[i].semanticHash)
  throw new Error(`semantic_hash_mismatch_at_${i}`);
const report={schema:'thesisforge-guru-holdings-benchmark-v1',runtime:process.version,database,asOf,samples,concurrency,
  baseline:{...baseline,records:undefined},optimized:{...optimized,records:undefined},
  p95Improvement:1-optimized.wall.p95Ms/baseline.wall.p95Ms,semanticHashesEqual:true};
const text=JSON.stringify(report,null,2)+'\n';if(output)fs.writeFileSync(output,text);process.stdout.write(text);
