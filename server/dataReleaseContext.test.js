import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { dataReleaseMiddleware,releaseRoot,releaseResource,readDataRelease } from './dataReleaseContext.js';

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
        releaseResource('reader',()=>({root:firstRoot}),()=>closed++);
        await oldDone;
        assert.equal(releaseRoot('canonical'),firstRoot);assert.equal(closed,0);
        firstResponse.emit('finish');assert.equal(closed,1);resolve();
      }catch(error){reject(error);}
    }));
    const nextRoot=publish('b');const secondResponse=response();
    dataReleaseMiddleware({},secondResponse,()=>assert.equal(releaseRoot('canonical'),nextRoot));
    secondResponse.emit('finish');assert.equal(closed,0);releaseOld();await old;
    assert.equal(readDataRelease(active).manifest.releaseId,'b'.repeat(64));
    fs.writeFileSync(active,'{}');assert.throws(()=>readDataRelease(active),/invalid/);
  }finally{
    if(previous===undefined)delete process.env.FACT_OS_ACTIVE_MANIFEST;else process.env.FACT_OS_ACTIVE_MANIFEST=previous;
    fs.rmSync(directory,{recursive:true,force:true});
  }
});
