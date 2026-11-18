import { Worker } from 'node:worker_threads';
import { strategyRules } from './strategyLab.js';
import { strategyCatalog } from './strategyLabSource.js';
import {attachStrategyHedge} from './strategyHedge.js';
import {assertStrategyFreshness} from './strategyFreshness.js';

export function strategyWorkerLimits(env=process.env) {
  // One CPU-heavy job on the existing 2GB AWS host; no unbounded queue. The
  // worker heap is bounded independently of the API process and SQLite cache.
  return env.NODE_ENV==='production'
    ? {maxActive:1,resourceLimits:{maxOldGenerationSizeMb:512,maxYoungGenerationSizeMb:32,stackSizeMb:4}}
    : {maxActive:2,resourceLimits:{maxOldGenerationSizeMb:512,maxYoungGenerationSizeMb:32,stackSizeMb:4}};
}

export function registerStrategyLabRoutes(app,service,{run=null,limits=strategyWorkerLimits()}={}) {
  let active=0;
  const catalog=asOf=>strategyCatalog(service.source,asOf,process.env.STRATEGY_ETF_INPUT_PATH);
  const compute=run??(rules=>new Promise((resolve,reject)=>{
    const file=service.source.db.prepare('PRAGMA database_list').get().file;
    const worker=new Worker(new URL('./strategyLabWorker.js',import.meta.url),{workerData:{file,rules,etfFile:process.env.STRATEGY_ETF_INPUT_PATH},resourceLimits:limits.resourceLimits});
    let settled=false;
    const finish=(error,result)=>{if(settled)return;settled=true;clearTimeout(timer);void worker.terminate();error?reject(error):resolve(result);};
    const timer=setTimeout(()=>finish(Object.assign(new Error('strategy_timeout'),{status:503})),rules.equityMix?90000:45000);
    worker.once('message',m=>finish(m.error?Object.assign(new Error(m.error),{status:422}):null,m.result));
    worker.once('error',e=>finish(e));worker.once('exit',()=>{if(!settled)finish(new Error('worker_exit'));});
  }));
  const route=(method,path,handler)=>app[method]('/api/investment'+path,async(req,res)=>{
    res.setHeader('Cache-Control','private, no-store');
    if(!req.user?.id)return res.status(401).json({error:'unauthorized'});
    try{res.json(await handler(req.user.id,req));}
    catch(e){res.status(e.status??500).json({error:e.status?e.message:'strategy_request_failed'});}
  });
  route('get','/strategy-lab',(owner,r)=>{
    const asOf=service.date(r.query.asOf);
    const archived=new Set(service.store.list(owner,'strategy_lab_archive').map(x=>x.targetId).filter(Boolean));
    return {...catalog(asOf),saved:service.store.list(owner,'strategy_lab').filter(x=>x.asOf<=asOf&&!archived.has(x.id))};
  });
  route('post','/strategy-backtests',async(_,r)=>{
    const inputs=catalog(service.date(r.body.asOf));
    const rules=strategyRules(r.body,inputs.managers);
    assertStrategyFreshness(inputs,rules);
    if(active>=limits.maxActive)throw Object.assign(new Error('strategy_busy'),{status:429});
    active++;
    try{return attachStrategyHedge(await compute(rules),rules);}finally{active--;}
  });
  route('post','/strategy-rules',(owner,r)=>{
    const rules=strategyRules(r.body,catalog(service.date(r.body.asOf)).managers);
    const name=String(r.body.name??'').trim().slice(0,80)||'My strategy';
    return service.store.write(owner,'strategy_lab','',r.body.operationId,{rules,name},()=>({asOf:rules.asOf,name,rules}));
  });
  route('post','/strategy-rules/archive',(owner,r)=>{
    const targetId=String(r.body?.targetId??'').trim();
    if(!targetId)throw Object.assign(new Error('missing_target_id'),{status:400});
    const opId=typeof r.body?.operationId==='string'&&r.body.operationId.length>=12
      ? r.body.operationId
      : `strategy_archive_${targetId.replace(/[^a-zA-Z0-9_-]/g,'').slice(0,48)}`;
    return service.store.write(owner,'strategy_lab_archive','',opId,{targetId},()=>({targetId,archivedAt:new Date().toISOString()}));
  });
}
