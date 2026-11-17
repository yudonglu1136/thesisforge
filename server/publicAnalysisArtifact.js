import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Worker } from 'node:worker_threads';
import { dataReleaseStatus } from './dataReleaseContext.js';
import { heavyWorkerLimiter } from './heavyWorkerLimiter.js';
import { resolveInvestmentRuntimeConfig } from './investmentRuntimeConfig.js';
import { analysisFailureCode } from './analysisFailure.js';
import {defaultRuleLedgerRoot,ruleLedgerArchiveIdentity} from './ruleLedgerArchive.js';
import {ruleBundlePaths} from './rulePortfolioBundle.js';

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
  constructor({root=defaultRoot(),maxActive=1,compute=null,runtimeConfig=null,retentionDays=14,minCohortsPerFamily=3}={}) {
    this.root=path.resolve(root);this.maxActive=Math.max(1,Math.min(2,maxActive));this.compute=compute;
    this.runtimeConfig=runtimeConfig;this.runtimeConfigResolved=runtimeConfig!==null;
    this.retentionMs=Math.max(1,Number(retentionDays)||14)*86_400_000;
    this.minCohortsPerFamily=Math.max(2,Number(minCohortsPerFamily)||3);
    this.pending=[];this.active=0;this.keys=new Set();this.warming=new Set();this.cache=new Map();this.failures=new Map();
  }
  context() {
    // Runtime release validation hashes and opens several immutable artifacts.
    // Startup already performs that validation, so keep the resolved paths for
    // this process instead of repeating the audit on every public API read.
    if(!this.runtimeConfigResolved){this.runtimeConfig=resolveInvestmentRuntimeConfig();this.runtimeConfigResolved=true;}
    const release=dataReleaseStatus(),config=this.runtimeConfig;
    const bundleRoot=release?.groups?.strategy_inputs?.root??null;
    const bundle=ruleBundlePaths(bundleRoot,'all',{required:release?.groups?.strategy_inputs?.rulePortfolioBundleRequired===true});
    return {releaseId:release?.releaseId??'legacy',groups:Object.fromEntries(Object.entries(release?.groups??{}).map(([k,v])=>[k,v.generationId])),
      canonicalRoot:release?.groups?.canonical?.root??process.env.FACT_OS_ROOT??null,
      publicFactsFile:release?.groups?.public_observations?.root?path.join(release.groups.public_observations.root,'observations.sqlite'):null,
      insightsFile:release?.groups?.institutional_13f?.root?path.join(release.groups.institutional_13f.root,'13f-insights.sqlite'):config?.insights??null,
      researchFile:config?.research??null,investmentReleaseId:config?.releaseId??process.env.INVESTMENT_RELEASE_ID??null,
      ruleBundleRoot:bundle?bundleRoot:null,ruleBundleIdentity:bundle?.identity??null,
      ruleLedgerRoot:bundle?.ledgerRoot??defaultRuleLedgerRoot(),
      ruleLedgerIdentity:bundle?.ledgerIdentity??ruleLedgerArchiveIdentity()};
  }
  identity(kind,args,context=this.context()) {
    const logicalKey=safeKey(`${kind}:${args.asOf}:${args.reportDate??args.universe??'default'}`);
    const dependencies={fundamentals:['canonical'],opportunities:['canonical','institutional_13f','public_observations'],
      strategy:['canonical','strategy_inputs'],'strategy-ledger':['canonical','strategy_inputs']}[kind]??Object.keys(context.groups);
    const groups=Object.fromEntries(dependencies.filter(key=>context.groups[key]).map(key=>[key,context.groups[key]]));
    const inputs={args,releaseId:Object.keys(groups).length?null:context.releaseId,groups,
      ...(kind.startsWith('strategy')&&context.ruleLedgerIdentity?{ruleLedgerIdentity:context.ruleLedgerIdentity}:{}),
      ...(kind.startsWith('strategy')&&context.ruleBundleIdentity?{ruleBundleIdentity:context.ruleBundleIdentity}:{}),
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
    let value;try{value=JSON.parse(bytes);}catch{return null;}
    this.cache.set(key,value);
    while(this.cache.size>8)this.cache.delete(this.cache.keys().next().value);
    return clone?structuredClone(value):value;
  }
  get(kind,args,{clone=true}={}) {
    const context=this.context(),identity=this.identity(kind,args,context),index=this.#index(),entry=index.entries[identity.logicalKey];
    const value=this.#read(entry,{clone}),exact=entry?.fingerprint===identity.fingerprint&&
      entry?.cohortFingerprint===identity.cohortFingerprint;
    if(!exact||!value)this.enqueue({kind,args,context,...identity});
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
    const receipt=index=>{
      let rulePortfolios;
      if(context.ruleBundleRoot){
        const universes={};
        for(const universe of ['all','sp500','nasdaq100']){
          const jobs=prepared.filter(j=>j.args.universe===universe);
          const values=Object.fromEntries(jobs.map(j=>[j.kind,this.#read(index.entries[j.logicalKey],{clone:false})]));
          const d=values.strategy,l=values['strategy-ledger'],expected=ruleBundlePaths(context.ruleBundleRoot,universe,{required:true});
          if(!d||!l||d.snapshotId!==expected.snapshotId||l.snapshotId!==d.snapshotId||
            l.archiveIdentity!==expected.ledgerIdentity||d.dataThrough!==expected.dataThrough)
            throw new Error('rule_bundle_actual_serving_mismatch');
          universes[universe]={snapshotId:d.snapshotId,dataThrough:d.dataThrough,observations:d.backtest.curve.length};
        }
        rulePortfolios={status:'ready',bundleIdentity:context.ruleBundleIdentity,universes};
      }
      return {status:'ready',asOf,generations:Object.fromEntries(prepared.map(job=>
        [`${job.kind}:${job.args.universe??'default'}`,job.fingerprint])),...(rulePortfolios?{rulePortfolios}:{})};
    };
    if(!missing.length)return receipt(index);
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
      const result=receipt(next);
      this.#writeIndex(next);
      return result;
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
      this.#run(job).then(entry=>{this.#activate(job,entry);this.failures.delete(job.fingerprint);}).catch(error=>{
        const code=analysisFailureCode(error);
        this.failures.set(job.fingerprint,{at:Date.now(),code});
        console.warn('[public-analysis] build failed',{kind:job.kind,asOf:job.args.asOf,code});
      }).finally(()=>{this.keys.delete(job.fingerprint);this.active--;this.#drain();});}
  }
  async #run(job) {
    if(this.compute)return this.compute(job);
    fs.mkdirSync(path.join(this.root,'releases'),{recursive:true,mode:0o755});
    return heavyWorkerLimiter.run(()=>new Promise((resolve,reject)=>{
      const worker=new Worker(new URL('./publicAnalysisWorker.js',import.meta.url),{workerData:{...job,root:this.root},
        resourceLimits:{maxOldGenerationSizeMb:512,maxYoungGenerationSizeMb:48,stackSizeMb:8}});
      let settled=false;const finish=(error,value)=>{if(settled)return;settled=true;clearTimeout(timer);worker.terminate().catch(()=>{});error?reject(error):resolve(value);};
      const timer=setTimeout(()=>finish(new Error('public_analysis_worker_timeout')),180_000);
      worker.once('message',m=>m?.ok?finish(null,m.entry):finish(new Error(m?.error??'public_analysis_worker_failed')));
      worker.once('error',e=>finish(e));worker.once('exit',code=>{if(code&&!settled)finish(new Error('public_analysis_worker_exit'));});
    }),{priority:'normal'});
  }
  #activate(job,entry) {
    if(entry.fingerprint!==job.fingerprint)return;
    const index=this.#index();index.entries[job.logicalKey]=entry;
    this.#writeIndex(index);
  }
  #pruneIndexEntries(entries,nowMs=Date.now()) {
    const cutoff=nowMs-this.retentionMs,byFamily=new Map(),retained={};
    for(const [key,entry] of Object.entries(entries??{})){
      const parts=String(key).split(':'),family=`${entry?.kind??parts[0]}:${parts.slice(2).join(':')||'default'}`;
      if(!byFamily.has(family))byFamily.set(family,[]);
      byFamily.get(family).push([key,entry]);
    }
    for(const items of byFamily.values()){
      items.sort(([,a],[,b])=>String(b?.asOf??'').localeCompare(String(a?.asOf??''))||
        String(b?.createdAt??'').localeCompare(String(a?.createdAt??'')));
      items.forEach(([key,entry],rank)=>{
        const createdMs=entry?.createdAt?Date.parse(entry.createdAt):NaN;
        const recent=Number.isNaN(createdMs)||createdMs>=cutoff;
        const activeBuild=entry?.fingerprint&&(this.keys.has(entry.fingerprint)||this.warming.has(entry.fingerprint));
        if(rank<this.minCohortsPerFamily||recent||activeBuild)retained[key]=entry;
      });
    }
    return retained;
  }
  #pruneReleaseDirs(retainedEntries,nowMs=Date.now()) {
    const releasesRoot=path.join(this.root,'releases');
    if(!fs.existsSync(releasesRoot))return;
    const cutoff=nowMs-this.retentionMs;
    const protectedFingerprints=new Set([...this.keys,...this.warming]);
    for(const entry of Object.values(retainedEntries??{})){
      if(entry?.fingerprint)protectedFingerprints.add(entry.fingerprint);
      if(typeof entry?.path==='string'){
        const parts=entry.path.split(/[\\/]/);
        if(parts[0]==='releases'&&parts[1])protectedFingerprints.add(parts[1]);
      }
    }
    for(const dirent of fs.readdirSync(releasesRoot,{withFileTypes:true})){
      if(!dirent.isDirectory()||dirent.isSymbolicLink()||!/^[a-f0-9]{64}$/.test(dirent.name))continue;
      if(protectedFingerprints.has(dirent.name))continue;
      const dirPath=path.join(releasesRoot,dirent.name);
      const dirStat=fs.lstatSync(dirPath);
      if(dirStat.isSymbolicLink())continue;
      const children=fs.readdirSync(dirPath,{withFileTypes:true});
      if(children.some(child=>child.isSymbolicLink()||(child.name!=='artifact.json'&&!child.name.startsWith('artifact.json.'))))continue;
      let latestMs=dirStat.mtimeMs;
      for(const child of children)latestMs=Math.max(latestMs,fs.lstatSync(path.join(dirPath,child.name)).mtimeMs);
      if(latestMs>=cutoff)continue;
      for(const child of children){
        const filePath=path.join(dirPath,child.name);
        fs.chmodSync(filePath,0o644);fs.unlinkSync(filePath);
      }
      fs.rmdirSync(dirPath);
    }
  }
  #writeIndex(index,nowMs=Date.now()) {
    const next={...index,entries:this.#pruneIndexEntries(index.entries,nowMs)};
    fs.mkdirSync(this.root,{recursive:true,mode:0o755});
    const temporary=path.join(this.root,`.active.${process.pid}.tmp`);
    const handle=fs.openSync(temporary,'w',0o644);
    try{fs.writeFileSync(handle,JSON.stringify(next));fs.fsyncSync(handle);}finally{fs.closeSync(handle);}
    fs.renameSync(temporary,path.join(this.root,'active.json'));
    const directory=fs.openSync(this.root,'r');try{fs.fsyncSync(directory);}finally{fs.closeSync(directory);}
    try{this.#pruneReleaseDirs(next.entries,nowMs);}catch{}
  }
}

export const publicAnalysisArtifacts=new PublicAnalysisArtifacts({maxActive:Number(process.env.PUBLIC_ANALYSIS_WORKERS)||1});
