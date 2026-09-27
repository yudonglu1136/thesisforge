import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { dataReleaseMiddleware,releaseRoot,releaseResource,readDataRelease,dataReleaseId } from './dataReleaseContext.js';
import { factGeneration as valuationGeneration } from './valuationFacts.js';

test('requests pin release, old resources drain, new requests switch and restart reloads manifest',async()=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'fact-release-context-'));
  const previous=process.env.FACT_OS_ACTIVE_MANIFEST;
  const active=path.join(directory,'active.json');process.env.FACT_OS_ACTIVE_MANIFEST=active;
  const publish=id=>{
    const root=path.join(directory,'releases','canonical',id);fs.mkdirSync(root,{recursive:true});
    fs.writeFileSync(active,JSON.stringify({schemaVersion:1,state:'verified',releaseId:id.repeat(64),groups:{canonical:{root}}}));return root;
  };
  const response=()=>Object.assign(new EventEmitter(),{setHeader(){},status(){return this;},json(value){throw Error(JSON.stringify(value));}});
  try {
    const firstRoot=publish('a');const firstResponse=response();let closed=0,releaseOld;
    const oldDone=new Promise(resolve=>{releaseOld=resolve;});
    const old=new Promise((resolve,reject)=>dataReleaseMiddleware({},firstResponse,async()=>{
      try{
        assert.equal(releaseRoot('canonical'),firstRoot);
        assert.equal(valuationGeneration(),'a'.repeat(64));
        releaseResource('reader',()=>({root:firstRoot}),()=>closed++);
        await oldDone;
        assert.equal(releaseRoot('canonical'),firstRoot);assert.equal(closed,0);
        assert.equal(valuationGeneration(),'a'.repeat(64));
        firstResponse.emit('finish');assert.equal(closed,1);resolve();
      }catch(error){reject(error);}
    }));
    const nextRoot=publish('b');const secondResponse=response();
    dataReleaseMiddleware({},secondResponse,()=>{
      assert.equal(releaseRoot('canonical'),nextRoot);
      assert.equal(valuationGeneration(),'b'.repeat(64));
    });
    secondResponse.emit('finish');assert.equal(closed,0);releaseOld();await old;
    assert.equal(readDataRelease(active).manifest.releaseId,'b'.repeat(64));
    fs.writeFileSync(active,'{}');assert.throws(()=>readDataRelease(active),/invalid/);
  }finally{
    if(previous===undefined)delete process.env.FACT_OS_ACTIVE_MANIFEST;else process.env.FACT_OS_ACTIVE_MANIFEST=previous;
    fs.rmSync(directory,{recursive:true,force:true});
  }
});

test('Research activation does not switch Strategy, Discover or Portfolio data',()=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'research-release-context-'));
  const prior={global:process.env.FACT_OS_ACTIVE_MANIFEST,research:process.env.FACT_OS_RESEARCH_MANIFEST};
  const root=path.join(directory,'releases','canonical');fs.mkdirSync(root,{recursive:true});
  const global=path.join(directory,'active.json'),research=path.join(directory,'research-active.json');
  const groups={canonical:{root},research_inputs:{root}};
  fs.writeFileSync(global,JSON.stringify({schemaVersion:1,state:'verified',releaseId:'a'.repeat(64),groups}));
  fs.writeFileSync(research,JSON.stringify({schemaVersion:1,state:'verified',releaseId:'b'.repeat(64),groups}));
  process.env.FACT_OS_ACTIVE_MANIFEST=global;process.env.FACT_OS_RESEARCH_MANIFEST=research;
  const response=()=>Object.assign(new EventEmitter(),{setHeader(){},status(){return this;},json(v){this.error=v;}});
  try {
    for(const url of ['/api/investment/research/AMZN/fundamentals?asOf=2026-09-22','/api/internal/research-data-release',
      '/api/investment/strategies','/api/investment/opportunities','/api/portfolio','/api/investment/research-not-a-route']) {
      const res=response();let called=false;
      dataReleaseMiddleware({originalUrl:url},res,()=>{called=true;
        assert.equal(dataReleaseId(),(url.includes('/research/')||url.includes('/internal/research-data-release')?'b':'a').repeat(64));});
      assert.equal(called,true);res.emit('finish');
    }
    fs.writeFileSync(research,'{}');const res=response();
    dataReleaseMiddleware({originalUrl:'/api/investment/research/AMZN/fundamentals'},res,()=>assert.fail('invalid manifest accepted'));
    assert.equal(res.error.error,'data_release_unavailable');
    assert.equal(readDataRelease(global).manifest.releaseId,'a'.repeat(64));
  }finally {
    for(const [key,value] of [['FACT_OS_ACTIVE_MANIFEST',prior.global],['FACT_OS_RESEARCH_MANIFEST',prior.research]])
      if(value===undefined)delete process.env[key];else process.env[key]=value;
    fs.rmSync(directory,{recursive:true,force:true});
  }
});
