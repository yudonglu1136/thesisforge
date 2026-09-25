import crypto from 'node:crypto';
import path from 'node:path';
import { Worker } from 'node:worker_threads';
import { dataReleaseStatus } from './dataReleaseContext.js';
import { resolveInvestmentRuntimeConfig } from './investmentRuntimeConfig.js';

const stable=(value)=>{
  if(Array.isArray(value))return value.map(stable);
  if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(key=>[key,stable(value[key])]));
  return value;
};
const sha=value=>crypto.createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');

export function portfolioAnalysisIdentity(payload,{asOf,scope,riskFreeRate,release=null,investmentReleaseId=null,
  connectionRevision=null}={}) {
  const reportDates=[...(payload?.analysisAccounts??[])].map(row=>String(row.reportDate??'')).filter(Boolean).sort();
  // Exclude transport-only timestamps, connection messages and duplicated UI
  // holdings. Only inputs consumed by analysePortfolio participate, otherwise
  // every broker read would create a different snapshot for identical facts.
  const report={source:{mode:payload?.source?.mode??null,userScoped:payload?.source?.userScoped===true,
      localOwnerSnapshot:payload?.source?.localOwnerSnapshot===true,asOf:payload?.source?.asOf??null},
    connection:{status:payload?.connection?.status??null},analysisAccounts:payload?.analysisAccounts??[]};
  const dependencies=['canonical','institutional_13f','public_observations'];
  const groups=Object.fromEntries(dependencies.filter(key=>release?.groups?.[key])
    .map(key=>[key,release.groups[key].generationId]));
  return {inputFingerprint:sha({version:'portfolio-analysis-snapshot-v1',asOf,scope,riskFreeRate,
      report,connectionRevision,release:Object.keys(groups).length?null:release?.releaseId??null,groups,
      investmentReleaseId}),
    reportDate:reportDates.at(-1)??payload?.source?.asOf??asOf};
}

function releasePaths() {
  const status=dataReleaseStatus();
  return {release:status,
    canonicalRoot:status?.groups?.canonical?.root??process.env.FACT_OS_ROOT??null,
    publicFactsFile:status?.groups?.public_observations?.root
      ?path.join(status.groups.public_observations.root,'observations.sqlite'):null,
    insightsFile:status?.groups?.institutional_13f?.root
      ?path.join(status.groups.institutional_13f.root,'13f-insights.sqlite'):null};
}

export class PortfolioAnalysisQueue {
  constructor({maxActive=1,compute=null,runtimeConfig=null}={}) {
    this.maxActive=Math.max(1,Math.min(2,maxActive));this.compute=compute;
    this.runtimeConfig=runtimeConfig;this.runtimeConfigResolved=runtimeConfig!==null;
    this.active=0;this.pending=[];this.keys=new Set();this.failures=new Map();
  }
  dependencies() {
    if(!this.runtimeConfigResolved){this.runtimeConfig=resolveInvestmentRuntimeConfig();this.runtimeConfigResolved=true;}
    return {release:dataReleaseStatus(),investmentReleaseId:this.runtimeConfig?.releaseId??null};
  }
  enqueue(job,{onSuccess=()=>{},onFailure=()=>{}}={}) {
    if(this.keys.has(job.inputFingerprint))return false;
    const failed=this.failures.get(job.inputFingerprint);
    if(failed&&Date.now()-failed<30_000)return false;
    this.failures.delete(job.inputFingerprint);
    this.keys.add(job.inputFingerprint);this.pending.push({job,onSuccess,onFailure});this.#drain();return true;
  }
  status(inputFingerprint) {
    if(this.keys.has(inputFingerprint))return 'updating';
    if(this.failures.has(inputFingerprint))return 'failed';
    return 'idle';
  }
  #drain() {
    while(this.active<this.maxActive&&this.pending.length){
      const item=this.pending.shift();this.active++;
      this.#run(item.job).then(value=>{this.failures.delete(item.job.inputFingerprint);item.onSuccess(value);},error=>{
        this.failures.set(item.job.inputFingerprint,Date.now());item.onFailure(error);
      }).finally(()=>{
        this.keys.delete(item.job.inputFingerprint);this.active--;this.#drain();
      });
    }
  }
  async #run(job) {
    if(this.compute)return this.compute(job);
    this.dependencies();
    const config=this.runtimeConfig,paths=releasePaths();
    if(!config)throw new Error('investment_runtime_unavailable');
    return new Promise((resolve,reject)=>{
      const worker=new Worker(new URL('./portfolioAnalysisWorker.js',import.meta.url),{
        workerData:{...job,researchFile:config.research,investmentReleaseId:config.releaseId,
          canonicalRoot:paths.canonicalRoot,publicFactsFile:paths.publicFactsFile,
          insightsFile:paths.insightsFile??config.insights},
        resourceLimits:{maxOldGenerationSizeMb:384,maxYoungGenerationSizeMb:32,stackSizeMb:8},
      });
      let settled=false;
      const finish=(error,value)=>{if(settled)return;settled=true;clearTimeout(timer);worker.terminate().catch(()=>{});error?reject(error):resolve(value);};
      const timer=setTimeout(()=>finish(new Error('portfolio_analysis_worker_timeout')),120_000);
      worker.once('message',message=>message?.ok?finish(null,message.result):finish(new Error(message?.error??'portfolio_analysis_worker_failed')));
      worker.once('error',error=>finish(error));
      worker.once('exit',code=>{if(code&&!settled)finish(new Error('portfolio_analysis_worker_exit'));});
    });
  }
}

export const portfolioAnalysisQueue=new PortfolioAnalysisQueue({
  maxActive:Number(process.env.PORTFOLIO_ANALYSIS_WORKERS)||1,
});
