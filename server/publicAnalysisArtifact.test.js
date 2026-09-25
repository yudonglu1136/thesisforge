import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {PublicAnalysisArtifacts} from './publicAnalysisArtifact.js';

const waitFor=async predicate=>{
  const deadline=Date.now()+2_000;
  while(Date.now()<deadline){const result=predicate();if(result)return result;await new Promise(resolve=>setTimeout(resolve,10));}
  throw new Error('artifact_test_timeout');
};

test('public analysis keeps last good immutable generation while a deduplicated replacement builds',async()=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'public-analysis-'));
  let builds=0;
  const compute=async job=>{
    builds++;await new Promise(resolve=>setTimeout(resolve,20));
    const directory=path.join(root,'releases',job.fingerprint);fs.mkdirSync(directory,{recursive:true});
    const file=path.join(directory,'artifact.json'),bytes=Buffer.from(JSON.stringify({generation:builds}));
    fs.writeFileSync(file,bytes);
    return {logicalKey:job.logicalKey,fingerprint:job.fingerprint,cohortFingerprint:job.cohortFingerprint,kind:job.kind,asOf:job.args.asOf,
      createdAt:`2026-09-25T00:00:0${builds}Z`,path:path.relative(root,file),bytes:bytes.length,
      sha256:crypto.createHash('sha256').update(bytes).digest('hex')};
  };
  const artifacts=new PublicAnalysisArtifacts({root,compute,runtimeConfig:{releaseId:'investment-v1'}});
  try{
    const args={asOf:'2026-09-25',reportDate:null};
    assert.equal(artifacts.get('opportunities',args).status,'updating');
    artifacts.get('opportunities',args);
    const ready=await waitFor(()=>{const value=artifacts.get('opportunities',args);return value.exact?value:null;});
    assert.equal(builds,1);assert.deepEqual(ready.value,{generation:1});
    artifacts.runtimeConfig={releaseId:'investment-v2'};
    const stale=artifacts.get('opportunities',args);
    assert.equal(stale.status,'updating');assert.deepEqual(stale.value,{generation:1});
    const replaced=await waitFor(()=>{const value=artifacts.get('opportunities',args);return value.exact?value:null;});
    assert.equal(builds,2);assert.deepEqual(replaced.value,{generation:2});
    assert.equal(JSON.parse(fs.readFileSync(path.join(root,'active.json'),'utf8')).schemaVersion,'public-analysis-index-v2');
    assert.equal(fs.readdirSync(path.join(root,'releases')).length,2);
  }finally{fs.rmSync(root,{recursive:true,force:true});}
});

test('daily compatibility group switches only after every public artifact succeeds',async()=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'public-analysis-group-'));
  let failUniverse=null;
  const compute=async job=>{
    if(job.kind==='strategy'&&job.args.universe===failUniverse)throw new Error('synthetic_build_failure');
    const directory=path.join(root,'releases',job.fingerprint);fs.mkdirSync(directory,{recursive:true});
    const file=path.join(directory,'artifact.json'),bytes=Buffer.from(JSON.stringify({kind:job.kind,args:job.args}));
    if(!fs.existsSync(file))fs.writeFileSync(file,bytes);
    return {logicalKey:job.logicalKey,fingerprint:job.fingerprint,cohortFingerprint:job.cohortFingerprint,kind:job.kind,asOf:job.args.asOf,
      createdAt:'2026-09-25T00:00:00Z',path:path.relative(root,file),bytes:bytes.length,
      sha256:crypto.createHash('sha256').update(bytes).digest('hex')};
  };
  const artifacts=new PublicAnalysisArtifacts({root,compute,runtimeConfig:{releaseId:'investment-v1'}});
  try{
    assert.equal((await artifacts.warmCurrent('2026-09-25',{timeoutMs:2_000})).status,'ready');
    const before=fs.readFileSync(path.join(root,'active.json'),'utf8');
    artifacts.runtimeConfig={releaseId:'investment-v2'};failUniverse='sp500';
    await assert.rejects(artifacts.warmCurrent('2026-09-25',{timeoutMs:2_000}),/synthetic_build_failure/);
    assert.equal(fs.readFileSync(path.join(root,'active.json'),'utf8'),before);
  }finally{fs.rmSync(root,{recursive:true,force:true});}
});
