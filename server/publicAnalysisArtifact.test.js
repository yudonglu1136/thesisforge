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

test('missing exact artifact is rebuilt instead of remaining updating forever',async()=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'public-analysis-missing-'));
  let calls=0;
  const artifacts=new PublicAnalysisArtifacts({root,runtimeConfig:{releaseId:'r1'},compute:async()=>{
    calls++;throw new Error('local_data_unavailable');
  }});
  const args={asOf:'2026-09-27'},identity=artifacts.identity('fundamentals',args);
  try{
    fs.writeFileSync(path.join(root,'active.json'),JSON.stringify({schemaVersion:'public-analysis-index-v2',
      entries:{[identity.logicalKey]:{...identity,path:'missing.json',bytes:1,sha256:'0'.repeat(64)}}}));
    artifacts.get('fundamentals',args);
    await waitFor(()=>calls);
    await waitFor(()=>artifacts.get('fundamentals',args).error);
    assert.equal(calls,1);
  }finally{fs.rmSync(root,{recursive:true,force:true});}
});

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

test('bundle activation checks actual curve and ledger identities before publishing the cache index',async t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'public-analysis-bundle-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const bundle=path.join(root,'bundle');fs.mkdirSync(bundle);
  const h=x=>crypto.createHash('sha256').update(x).digest('hex');
  const manifest={schemaVersion:'rule-portfolio-bundle-v1',sourceGeneration:h('source'),sourceManifestSha256:h('catalog'),
    ledgerIdentity:h('ledger'),entries:Object.fromEntries(['all','sp500','nasdaq100'].map(id=>[id,
      {file:`${id}.json`,snapshotId:h(id),dataThrough:'2026-09-30'}]))};
  fs.writeFileSync(path.join(bundle,'rule-manifest.json'),JSON.stringify(manifest));
  let wrong=false,version='v1';
  const artifacts=new PublicAnalysisArtifacts({root,runtimeConfig:{},compute:async job=>{
    const e=manifest.entries[job.args.universe];
    const value=job.kind==='strategy'?{snapshotId:e.snapshotId,dataThrough:wrong?'2026-09-21':e.dataThrough,backtest:{curve:[{},{}]}}
      :job.kind==='strategy-ledger'?{snapshotId:e.snapshotId,archiveIdentity:manifest.ledgerIdentity}:{status:'ready'};
    const bytes=Buffer.from(JSON.stringify(value)),file=path.join(root,job.fingerprint+'.json');fs.writeFileSync(file,bytes);
    return {...job,path:path.basename(file),bytes:bytes.length,sha256:h(bytes)};
  }});
  artifacts.context=()=>({groups:{strategy_inputs:version},releaseId:version,ruleBundleRoot:bundle,
    ruleBundleIdentity:h(JSON.stringify(manifest)),ruleLedgerIdentity:manifest.ledgerIdentity});
  const ready=await artifacts.warmCurrent('2026-10-02');
  assert.equal(ready.rulePortfolios.status,'ready');
  assert.equal(ready.rulePortfolios.universes.all.dataThrough,'2026-09-30');
  const before=fs.readFileSync(path.join(root,'active.json'),'utf8');
  wrong=true;version='v2';
  await assert.rejects(artifacts.warmCurrent('2026-10-02'),/rule_bundle_actual_serving_mismatch/);
  assert.equal(fs.readFileSync(path.join(root,'active.json'),'utf8'),before);
});
