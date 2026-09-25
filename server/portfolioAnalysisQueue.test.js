import test from 'node:test';
import assert from 'node:assert/strict';
import {PortfolioAnalysisQueue,portfolioAnalysisIdentity} from './portfolioAnalysisQueue.js';

const payload=(price=10,retrievedAt='2026-09-25T01:00:00Z')=>({
  generatedAt:retrievedAt,source:{mode:'live',userScoped:true,asOf:'2026-09-24',retrievedAt},
  connection:{status:'linked',updatedAt:retrievedAt,message:'transport-only'},holdings:[{ticker:'IGNORED'}],
  analysisAccounts:[{currency:'USD',reportDate:'2026-09-24',positions:[{ticker:'AAA',price,quantity:2,localValue:price*2}]}],
});

test('portfolio fingerprint ignores transport timestamps but changes for analytical inputs and connection revision',()=>{
  const options={asOf:'2026-09-25',scope:'detail',riskFreeRate:.04,investmentReleaseId:'r1',
    connectionRevision:'a'.repeat(64),release:{releaseId:'f1',groups:{canonical:{generationId:'g1'}}}};
  const first=portfolioAnalysisIdentity(payload(),options).inputFingerprint;
  assert.equal(portfolioAnalysisIdentity(payload(10,'2026-09-25T02:00:00Z'),options).inputFingerprint,first);
  assert.notEqual(portfolioAnalysisIdentity(payload(11),options).inputFingerprint,first);
  assert.notEqual(portfolioAnalysisIdentity(payload(),{...options,connectionRevision:'b'.repeat(64)}).inputFingerprint,first);
});

test('queue dependencies bind snapshots to the reviewed investment release',()=>{
  const queue=new PortfolioAnalysisQueue({compute:async()=>null,runtimeConfig:{releaseId:'investment-reviewed-v2'}});
  assert.equal(queue.dependencies().investmentReleaseId,'investment-reviewed-v2');
});

test('portfolio analysis queue deduplicates an in-flight snapshot',async()=>{
  let calls=0,release;
  const gate=new Promise(resolve=>release=resolve);
  const queue=new PortfolioAnalysisQueue({compute:async job=>{calls++;await gate;return job.inputFingerprint;}});
  const completed=[];
  assert.equal(queue.enqueue({inputFingerprint:'a'.repeat(64)},{onSuccess:value=>completed.push(value)}),true);
  assert.equal(queue.enqueue({inputFingerprint:'a'.repeat(64)},{onSuccess:value=>completed.push(value)}),false);
  release();
  for(let i=0;i<100&&!completed.length;i++)await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(calls,1);assert.deepEqual(completed,['a'.repeat(64)]);
});

test('failed portfolio work is surfaced and not hot-looped',async()=>{
  let calls=0,failed=0;
  const queue=new PortfolioAnalysisQueue({compute:async()=>{calls++;throw new Error('synthetic');}});
  const fingerprint='b'.repeat(64);
  queue.enqueue({inputFingerprint:fingerprint},{onFailure:()=>failed++});
  for(let i=0;i<100&&!failed;i++)await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(queue.status(fingerprint),'failed');
  assert.equal(queue.enqueue({inputFingerprint:fingerprint}),false);
  assert.equal(calls,1);
});
