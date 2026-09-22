import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { AsyncLocalStorage } from 'node:async_hooks';

const context=new AsyncLocalStorage();
let current=null;

function dispose(entry) {
  if(!entry||entry.current||entry.readers)return;
  for(const resource of entry.resources.values())resource.close(resource.value);
  entry.resources.clear();
}

export function readDataRelease(file=process.env.FACT_OS_ACTIVE_MANIFEST ||
  (process.env.NODE_ENV==='production'&&fs.existsSync('/var/app/data/fact-os/active.json')?'/var/app/data/fact-os/active.json':null)) {
  if(!file)return null;
  const bytes=fs.readFileSync(file);
  const identity=crypto.createHash('sha256').update(bytes).digest('hex');
  if(current?.identity===identity)return current;
  const manifest=JSON.parse(bytes);
  if(manifest.schemaVersion!==1||manifest.state!=='verified'||!/^[a-f0-9]{64}$/.test(manifest.releaseId??''))
    throw Error('data_release_manifest_invalid');
  const base=path.resolve(path.dirname(file),'releases');
  for(const item of Object.values(manifest.groups??{})) {
    if(!item.root||!path.resolve(item.root).startsWith(base+path.sep)||!fs.statSync(item.root).isDirectory())
      throw Error('data_release_group_path_invalid');
  }
  const previous=current;
  current={identity,manifest,current:true,readers:0,resources:new Map()};
  if(previous){previous.current=false;dispose(previous);}
  return current;
}

export function dataReleaseMiddleware(req,res,next) {
  let entry;
  try{entry=readDataRelease();}catch{return res.status(503).json({error:'data_release_unavailable'});}
  if(!entry)return next();
  entry.readers++;
  res.setHeader('X-Data-Release-Id',entry.manifest.releaseId);
  let done=false;
  const finish=()=>{if(done)return;done=true;entry.readers--;dispose(entry);};
  res.once('finish',finish);res.once('close',finish);
  context.run(entry,next);
}

export function releaseRoot(group,fallback) {
  return context.getStore()?.manifest.groups?.[group]?.root??fallback;
}

export function dataReleaseId() {return context.getStore()?.manifest.releaseId??null;}

export function releaseResource(key,create,close) {
  const entry=context.getStore();
  if(!entry)return null;
  if(!entry.resources.has(key))entry.resources.set(key,{value:create(),close});
  return entry.resources.get(key).value;
}

export function dataReleaseStatus() {
  const entry=context.getStore()??readDataRelease();
  return entry?{releaseId:entry.manifest.releaseId,groups:entry.manifest.groups,readers:entry.readers}:null;
}
