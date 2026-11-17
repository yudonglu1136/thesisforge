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

test('public analysis index and release directories bound expired cohorts while retaining newest per family',async t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'public-analysis-retention-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const h=x=>crypto.createHash('sha256').update(x).digest('hex');
  const oldEpochSec=Math.floor((Date.now()-20*86_400_000)/1000);
  const recentIso=new Date(Date.now()-2*86_400_000).toISOString();
  const oldIso=new Date(Date.now()-20*86_400_000).toISOString();
  const entries={};
  const writeRelease=(seed,{old=false}={})=>{
    const fp=h(seed),dir=path.join(root,'releases',fp),file=path.join(dir,'artifact.json');
    fs.mkdirSync(dir,{recursive:true});
    const bytes=Buffer.from(JSON.stringify({seed}));
    fs.writeFileSync(file,bytes,{mode:0o444});
    if(old){
      fs.utimesSync(file,oldEpochSec,oldEpochSec);
      fs.utimesSync(dir,oldEpochSec,oldEpochSec);
    }
    return {fp,dir,file,bytes,sha256:h(bytes)};
  };
  // 4 historical cohorts in the same family (`fundamentals:*:default`), 3 of them >14d old + 1 new trigger build.
  const c1=writeRelease('c1',{old:true});
  const c2=writeRelease('c2',{old:true});
  const c3=writeRelease('c3',{old:true});
  const cRecent=writeRelease('c-recent',{old:false});
  const orphanOld=writeRelease('orphan-old',{old:true});
  entries['fundamentals:2026-10-01:default']={logicalKey:'fundamentals:2026-10-01:default',kind:'fundamentals',
    asOf:'2026-10-01',fingerprint:c1.fp,cohortFingerprint:h('cf1'),createdAt:oldIso,
    path:`releases/${c1.fp}/artifact.json`,bytes:c1.bytes.length,sha256:c1.sha256};
  entries['fundamentals:2026-10-02:default']={logicalKey:'fundamentals:2026-10-02:default',kind:'fundamentals',
    asOf:'2026-10-02',fingerprint:c2.fp,cohortFingerprint:h('cf2'),createdAt:oldIso,
    path:`releases/${c2.fp}/artifact.json`,bytes:c2.bytes.length,sha256:c2.sha256};
  entries['fundamentals:2026-10-03:default']={logicalKey:'fundamentals:2026-10-03:default',kind:'fundamentals',
    asOf:'2026-10-03',fingerprint:c3.fp,cohortFingerprint:h('cf3'),createdAt:oldIso,
    path:`releases/${c3.fp}/artifact.json`,bytes:c3.bytes.length,sha256:c3.sha256};
  entries['opportunities:2026-11-09:default']={logicalKey:'opportunities:2026-11-09:default',kind:'opportunities',
    asOf:'2026-11-09',fingerprint:cRecent.fp,cohortFingerprint:h('cf-rec'),createdAt:recentIso,
    path:`releases/${cRecent.fp}/artifact.json`,bytes:cRecent.bytes.length,sha256:cRecent.sha256};
  fs.writeFileSync(path.join(root,'active.json'),JSON.stringify({schemaVersion:'public-analysis-index-v2',entries}));

  const artifacts=new PublicAnalysisArtifacts({root,retentionDays:14,minCohortsPerFamily:3,runtimeConfig:{releaseId:'r1'},
    compute:async job=>{
      const r=writeRelease(`live-${job.fingerprint}`);
      return {logicalKey:job.logicalKey,fingerprint:job.fingerprint,cohortFingerprint:job.cohortFingerprint,
        kind:job.kind,asOf:job.args.asOf,createdAt:new Date().toISOString(),
        path:`releases/${r.fp}/artifact.json`,bytes:r.bytes.length,sha256:r.sha256};
    }});
  artifacts.get('fundamentals',{asOf:'2026-11-11'});
  await waitFor(()=>artifacts.get('fundamentals',{asOf:'2026-11-11'}).exact);

  const updated=JSON.parse(fs.readFileSync(path.join(root,'active.json'),'utf8'));
  // Newest 3 fundamentals cohorts (2026-11-11, 2026-10-03, 2026-10-02) + recent opportunities are kept; 2026-10-01 and orphanOld are pruned.
  assert.equal(Boolean(updated.entries['fundamentals:2026-11-11:default']),true);
  assert.equal(Boolean(updated.entries['fundamentals:2026-10-03:default']),true);
  assert.equal(Boolean(updated.entries['fundamentals:2026-10-02:default']),true);
  assert.equal(Boolean(updated.entries['fundamentals:2026-10-01:default']),false);
  assert.equal(Boolean(updated.entries['opportunities:2026-11-09:default']),true);
  assert.equal(fs.existsSync(c1.dir),false);
  assert.equal(fs.existsSync(orphanOld.dir),false);
  assert.equal(fs.existsSync(c2.dir),true);
  assert.equal(fs.existsSync(c3.dir),true);
  assert.equal(fs.existsSync(cRecent.dir),true);
});
