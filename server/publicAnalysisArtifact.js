import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Worker } from 'node:worker_threads';
import { dataReleaseStatus } from './dataReleaseContext.js';
import { resolveInvestmentRuntimeConfig } from './investmentRuntimeConfig.js';

const schema='public-analysis-index-v2';
const stable=value=>Array.isArray(value)?value.map(stable):value&&typeof value==='object'
  ?Object.fromEntries(Object.keys(value).sort().map(key=>[key,stable(value[key])])):value;
const digest=value=>crypto.createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');
const safeKey=value=>String(value).replace(/[^a-zA-Z0-9:._-]/g,'_').slice(0,180);

function defaultRoot() {
  return path.resolve(process.env.PUBLIC_ANALYSIS_ROOT??(process.env.NODE_ENV==='production'
    ?'/var/app/data/public-analysis':'server/data/public-analysis'));
}

export class PublicAnalysisArtifacts {
  constructor({root=defaultRoot(),maxActive=1,compute=null,runtimeConfig=null}={}) {
    this.root=path.resolve(root);this.maxActive=Math.max(1,Math.min(2,maxActive));this.compute=compute;
    this.runtimeConfig=runtimeConfig;this.runtimeConfigResolved=runtimeConfig!==null;
    this.pending=[];this.active=0;this.keys=new Set();this.warming=new Set();this.cache=new Map();this.failures=new Map();
  }
  context() {
    // Runtime release validation hashes and opens several immutable artifacts.
    // Startup already performs that validation, so keep the resolved paths for
    // this process instead of repeating the audit on every public API read.
    if(!this.runtimeConfigResolved){this.runtimeConfig=resolveInvestmentRuntimeConfig();this.runtimeConfigResolved=true;}
    const release=dataReleaseStatus(),config=this.runtimeConfig;
    return {releaseId:release?.releaseId??'legacy',groups:Object.fromEntries(Object.entries(release?.groups??{}).map(([k,v])=>[k,v.generationId])),
      canonicalRoot:release?.groups?.canonical?.root??process.env.FACT_OS_ROOT??null,
      publicFactsFile:release?.groups?.public_observations?.root?path.join(release.groups.public_observations.root,'observations.sqlite'):null,
      insightsFile:release?.groups?.institutional_13f?.root?path.join(release.groups.institutional_13f.root,'13f-insights.sqlite'):config?.insights??null,
      researchFile:config?.research??null,investmentReleaseId:config?.releaseId??process.env.INVESTMENT_RELEASE_ID??null};
  }
  identity(kind,args,context=this.context()) {
    const logicalKey=safeKey(`${kind}:${args.asOf}:${args.reportDate??args.universe??'default'}`);
    const dependencies={fundamentals:['canonical'],opportunities:['canonical','institutional_13f','public_observations'],
      strategy:['canonical','strategy_inputs'],'strategy-ledger':['canonical','strategy_inputs']}[kind]??Object.keys(context.groups);
    const groups=Object.fromEntries(dependencies.filter(key=>context.groups[key]).map(key=>[key,context.groups[key]]));
    const inputs={args,releaseId:Object.keys(groups).length?null:context.releaseId,groups,
      investmentReleaseId:kind==='fundamentals'?null:context.investmentReleaseId};
    return {logicalKey,fingerprint:digest({schema,kind,...inputs}),
      cohortFingerprint:digest({schema:'public-analysis-cohort-v1',family:kind.startsWith('strategy')?'strategy':kind,...inputs})};
  }
  #index() {
    try{const value=JSON.parse(fs.readFileSync(path.join(this.root,'active.json'),'utf8'));return value.schemaVersion===schema?value:{schemaVersion:schema,entries:{}};}
    catch{return {schemaVersion:schema,entries:{}};}
  }
  #read(entry,{clone=true}={}) {
    if(!entry)return null;
    const file=path.resolve(this.root,entry.path??'');
    if(!file.startsWith(this.root+path.sep)||!fs.existsSync(file))return null;
    const stat=fs.statSync(file),key=`${file}:${stat.ino}:${stat.size}:${stat.mtimeMs}`;
    if(this.cache.has(key))return clone?structuredClone(this.cache.get(key)):this.cache.get(key);
    const bytes=fs.readFileSync(file);
    if(bytes.length!==entry.bytes||crypto.createHash('sha256').update(bytes).digest('hex')!==entry.sha256)return null;
    const value=JSON.parse(bytes);this.cache.set(key,value);
    while(this.cache.size>8)this.cache.delete(this.cache.keys().next().value);
    return clone?structuredClone(value):value;
  }
  get(kind,args,{clone=true}={}) {
    const context=this.context(),identity=this.identity(kind,args,context),index=this.#index(),entry=index.entries[identity.logicalKey];
    const value=this.#read(entry,{clone}),exact=entry?.fingerprint===identity.fingerprint&&
      entry?.cohortFingerprint===identity.cohortFingerprint;
    if(!exact)this.enqueue({kind,args,context,...identity});
    const failure=this.failures.get(identity.fingerprint);
    return {value,exact:Boolean(exact&&value),status:exact&&value?'ready':failure?'stale':'updating',fingerprint:identity.fingerprint,
      ...(failure?{error:'public_analysis_build_failed'}:{}),
      cohortFingerprint:identity.cohortFingerprint,activeCohortFingerprint:entry?.cohortFingerprint??null,
      updatedAt:entry?.createdAt??null};
  }
  async warmCurrent(asOf,{timeoutMs=110_000}={}) {
    const jobs=[['fundamentals',{asOf}],['opportunities',{asOf,reportDate:null}],
      ...['all','sp500','nasdaq100'].flatMap(universe=>[
        ['strategy',{asOf,universe}],['strategy-ledger',{asOf,universe}],
      ])];
    const context=this.context(),prepared=jobs.map(([kind,args])=>({kind,args,context,...this.identity(kind,args,context)}));
    const index=this.#index(),missing=prepared.filter(job=>index.entries[job.logicalKey]?.fingerprint!==job.fingerprint||
      index.entries[job.logicalKey]?.cohortFingerprint!==job.cohortFingerprint||
      !this.#read(index.entries[job.logicalKey]));
    if(!missing.length)return {status:'ready',asOf,generations:Object.fromEntries(prepared.map(job=>
      [`${job.kind}:${job.args.universe??'default'}`,job.fingerprint]))};
    for(const job of missing)this.warming.add(job.fingerprint);
    let timeout;
    const deadline=new Promise((_,reject)=>{timeout=setTimeout(()=>reject(new Error('public_analysis_prewarm_timeout')),timeoutMs);});
    try{
      // Build against one pinned context, validate every immutable artifact,
      // then switch the compatibility group with one manifest-last rename.
      const entries=[];
      for(const job of missing){
        const entry=await Promise.race([this.#run(job),deadline]);
        if(entry.fingerprint!==job.fingerprint||entry.cohortFingerprint!==job.cohortFingerprint||!this.#read(entry,{clone:false}))
          throw new Error('public_analysis_build_invalid');
        entries.push([job,entry]);
      }
      const next=this.#index();for(const [job,entry] of entries)next.entries[job.logicalKey]=entry;
      this.#writeIndex(next);
      return {status:'ready',asOf,generations:Object.fromEntries(prepared.map(job=>
        [`${job.kind}:${job.args.universe??'default'}`,job.fingerprint]))};
    }finally{clearTimeout(timeout);for(const job of missing)this.warming.delete(job.fingerprint);}
  }
  enqueue(job) {
    if(this.keys.has(job.fingerprint)||this.warming.has(job.fingerprint))return false;
    const failure=this.failures.get(job.fingerprint);
    if(failure&&Date.now()-failure.at<30_000)return false;
    this.failures.delete(job.fingerprint);
    this.keys.add(job.fingerprint);this.pending.push(job);this.#drain();return true;
  }
  #drain() {
    while(this.active<this.maxActive&&this.pending.length){const job=this.pending.shift();this.active++;
      this.#run(job).then(entry=>{this.failures.delete(job.fingerprint);this.#activate(job,entry);},error=>{
        this.failures.set(job.fingerprint,{at:Date.now(),code:error?.code??'public_analysis_build_failed'});
      }).finally(()=>{this.keys.delete(job.fingerprint);this.active--;this.#drain();});}
  }
  async #run(job) {
    if(this.compute)return this.compute(job);
    fs.mkdirSync(path.join(this.root,'releases'),{recursive:true,mode:0o755});
    return new Promise((resolve,reject)=>{
      const worker=new Worker(new URL('./publicAnalysisWorker.js',import.meta.url),{workerData:{...job,root:this.root},
        resourceLimits:{maxOldGenerationSizeMb:512,maxYoungGenerationSizeMb:48,stackSizeMb:8}});
      let settled=false;const finish=(error,value)=>{if(settled)return;settled=true;clearTimeout(timer);worker.terminate().catch(()=>{});error?reject(error):resolve(value);};
      const timer=setTimeout(()=>finish(new Error('public_analysis_worker_timeout')),180_000);
      worker.once('message',m=>m?.ok?finish(null,m.entry):finish(new Error(m?.error??'public_analysis_worker_failed')));
      worker.once('error',e=>finish(e));worker.once('exit',code=>{if(code&&!settled)finish(new Error('public_analysis_worker_exit'));});
    });
  }
  #activate(job,entry) {
    if(entry.fingerprint!==job.fingerprint)return;
    const index=this.#index();index.entries[job.logicalKey]=entry;
    this.#writeIndex(index);
  }
  #writeIndex(index) {
    fs.mkdirSync(this.root,{recursive:true,mode:0o755});
    const temporary=path.join(this.root,`.active.${process.pid}.tmp`);
    const handle=fs.openSync(temporary,'w',0o644);
    try{fs.writeFileSync(handle,JSON.stringify(index));fs.fsyncSync(handle);}finally{fs.closeSync(handle);}
    fs.renameSync(temporary,path.join(this.root,'active.json'));
    const directory=fs.openSync(this.root,'r');try{fs.fsyncSync(directory);}finally{fs.closeSync(directory);}
  }
}

export const publicAnalysisArtifacts=new PublicAnalysisArtifacts({maxActive:Number(process.env.PUBLIC_ANALYSIS_WORKERS)||1});
