// Read-only launch audit. Never imports application modules or emits user rows.
// Writes only sanitized evidence beside this script; no DB or remote mutations.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
const out=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(out,'../../..');
const mode=process.argv[2]??'database';
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const save=(name,data)=>fs.writeFileSync(path.join(out,name),JSON.stringify({capturedAt:new Date().toISOString(),...data},null,2)+'\n');
const quote=s=>'"'+s.replaceAll('"','""')+'"';
if(mode==='cloud'){
  const region='us-east-1';
  const aws=(service,operation,...args)=>JSON.parse(execFileSync('/usr/local/bin/aws',[service,operation,...args,'--region',region,'--output','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe']}));
  const env=aws('elasticbeanstalk','describe-environments','--environment-names','guru-analysis-api-prod').Environments[0];
  const cfg=aws('elasticbeanstalk','describe-configuration-settings','--application-name',env.ApplicationName,'--environment-name',env.EnvironmentName).ConfigurationSettings[0];
  const allowed=new Set(['SQLITE_DB_PATH','NODE_ENV','API_AUTH_PROVIDER','API_AUTH_DEV_BYPASS','GURU_BACKTEST_AUTO_REFRESH','INVESTMENT_WORKFLOW_ENABLED','INVESTMENT_DB_PATH','STRATEGY_DATA_DB_PATH','USER_PORTFOLIO_DATA_DIR','MinSize','MaxSize','EnvironmentType','InstanceType']);
  const config=cfg.OptionSettings.filter(x=>allowed.has(x.OptionName)).map(x=>({namespace:x.Namespace,key:x.OptionName,value:x.Value}));
  const resources=aws('elasticbeanstalk','describe-environment-resources','--environment-name',env.EnvironmentName).EnvironmentResources;
  const instanceIds=resources.Instances.map(x=>x.Id);
  const instances=aws('ec2','describe-instances','--instance-ids',...instanceIds).Reservations.flatMap(r=>r.Instances);
  const instanceFacts=instances.map(i=>({type:i.InstanceType,launchTime:i.LaunchTime,state:i.State.Name,volumeCount:i.BlockDeviceMappings.length,deleteOnTermination:i.BlockDeviceMappings.map(x=>x.Ebs.DeleteOnTermination)}));
  const volumeIds=instances.flatMap(i=>i.BlockDeviceMappings.map(x=>x.Ebs.VolumeId));
  const volumes=aws('ec2','describe-volumes','--volume-ids',...volumeIds).Volumes.map(v=>({sizeGiB:v.Size,type:v.VolumeType,encrypted:v.Encrypted,state:v.State}));
  const snapshots=aws('ec2','describe-snapshots','--owner-ids','self','--filters',`Name=volume-id,Values=${volumeIds.join(',')}`).Snapshots;
  const backupPlans=aws('backup','list-backup-plans').BackupPlansList;
  const dlm=aws('dlm','get-lifecycle-policies').Policies;
  const rds=aws('rds','describe-db-instances').DBInstances.map(d=>({engine:d.Engine,status:d.DBInstanceStatus,encrypted:d.StorageEncrypted,multiAz:d.MultiAZ,backupRetentionDays:d.BackupRetentionPeriod}));
  const data={region,environment:{name:env.EnvironmentName,status:env.Status,health:env.Health,healthStatus:env.HealthStatus,version:env.VersionLabel,updated:env.DateUpdated,platform:env.PlatformArn?.split('platform/')[1]},config,instances:instanceFacts,volumes,loadBalancerCount:resources.LoadBalancers.length,snapshots:{count:snapshots.length,encryptedCount:snapshots.filter(x=>x.Encrypted).length,latest:snapshots.map(s=>s.StartTime).sort().at(-1)},backupPlanCount:backupPlans.length,dlmPolicyCount:dlm.length,rds,limitations:['AWS Backup and DLM scope is us-east-1. No claim that S3 or cron backups do not exist.','Root-volume snapshots were filtered by the active volume IDs; copies under other volume IDs are not covered.','Production filesystem and SQL contents were not directly accessible through the current read-only host access.']};
  save('cloud.json',data);console.log(JSON.stringify(data,null,2));
}
if(mode==='freshness'){
  const db=new DatabaseSync('/Users/yudonglu/Documents/investment-prices-release-20260911/runtime.sqlite',{readOnly:true});
  db.exec('PRAGMA query_only=ON;');
  const queries={
    prices:"WITH s AS (SELECT symbol,max(date) latest FROM price_points GROUP BY symbol) SELECT count(*) symbols,sum(latest >= '2026-09-10') reached_cutoff,sum(latest < '2026-09-10') older,min(latest) earliest_last,max(latest) latest_last FROM s",
    financials:"SELECT dimension,count(*) rows,count(DISTINCT ticker) tickers,max(available_at) latest_available,max(report_period) latest_report,sum(available_at > '2026-09-10') after_cutoff FROM valuation_pit_financials GROUP BY dimension",
    financialModelLineage:"SELECT count(*) models,sum(financial_available_at > as_of_date) future_financial_input,sum(guidance_max_observed_at > as_of_date) future_guidance_input,max(as_of_date) last_model FROM valuation_pit_model_runs",
    jsonValidity:"SELECT 'financials' kind,count(*) invalid FROM valuation_pit_financials WHERE NOT json_valid(payload_json) UNION ALL SELECT 'model_input',count(*) FROM valuation_pit_model_runs WHERE NOT json_valid(input_json) UNION ALL SELECT 'model_output',count(*) FROM valuation_pit_model_runs WHERE NOT json_valid(output_json)",
  };
  const results=Object.entries(queries).map(([id,sql])=>({id,sql,rows:db.prepare(sql).all()}));
  db.close();save('freshness.json',{results,limitations:['All-symbol historical population includes delisted instruments; older series are not automatically missing active-market quotes.','PIT date-order and JSON checks do not certify financial values, economic provenance or all historical source selections.','Date comparison uses stored date strings; records after the cutoff can be valid stored future snapshots if runtime selectors exclude them.']});console.log(JSON.stringify(results,null,2));
}
if(mode==='database'){
  const files=[
    ['serving_runtime','/Users/yudonglu/Documents/investment-prices-release-20260911/runtime.sqlite'],
    ['strategy','/Users/yudonglu/Documents/investment-prices-release-20260911/strategy.sqlite'],
    ['composition_prices','/Users/yudonglu/Documents/investment-composition-prices-20260911/prices.sqlite'],
    ['user_research',path.join(repo,'output/investment-workflow-20260908/decisions.sqlite')],
    ['owner_preview',path.join(repo,'output/owner-portfolio-20260912/portfolio-v4.sqlite')],
    ['bundled_runtime',path.join(repo,'server/data/guru-analysis.sqlite')],
    ['bundled_ontology',path.join(repo,'server/data/ontology-snapshot.sqlite')]
  ];
  const databases=[];
  for(const [label,file] of files){
    if(!fs.existsSync(file)){databases.push({label,exists:false});continue;}
    const stat=fs.statSync(file),db=new DatabaseSync(file,{readOnly:true});
    db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000;');
    try{
      const schema=db.prepare("SELECT name,type,sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type,name").all();
      const tables=schema.filter(x=>x.type==='table').map(x=>({name:x.name,
        rows:db.prepare(`SELECT count(*) n FROM ${quote(x.name)}`).get().n,
        columns:db.prepare(`PRAGMA table_info(${quote(x.name)})`).all().map(c=>({name:c.name,type:c.type,required:!!c.notnull,pk:c.pk})),
        indexes:db.prepare(`PRAGMA index_list(${quote(x.name)})`).all().map(i=>({name:i.name,unique:!!i.unique})),
        foreignKeys:db.prepare(`PRAGMA foreign_key_list(${quote(x.name)})`).all().map(f=>({table:f.table,from:f.from,to:f.to}))
      }));
      const integrity=db.prepare('PRAGMA integrity_check').all();
      const foreignKeyViolations=db.prepare('PRAGMA foreign_key_check').all().length;
      const facts={};
      if(tables.some(x=>x.name==='investment_events')){
        facts.eventOwners=db.prepare('SELECT count(DISTINCT owner) n FROM investment_events').get().n;
        facts.localDevEvents=db.prepare("SELECT count(*) n FROM investment_events WHERE owner='local-dev-user'").get().n;
        facts.eventsByKind=db.prepare('SELECT kind,count(*) n,min(recorded_at) first,max(recorded_at) last FROM investment_events GROUP BY kind').all();
        facts.invalidJson=db.prepare('SELECT count(*) n FROM investment_events WHERE NOT json_valid(payload_json)').get().n;
        facts.invalidPayloadHash=0;
        for(const r of db.prepare('SELECT payload_json,payload_hash FROM investment_events').iterate())if(hash(r.payload_json)!==r.payload_hash)facts.invalidPayloadHash++;
        facts.queryPlan=db.prepare("EXPLAIN QUERY PLAN SELECT * FROM investment_events WHERE owner=? AND (? IS NULL OR kind=?) ORDER BY seq").all('audit-placeholder','scenario','scenario');
      }
      for(const spec of [['price_points','date'],['valuation_pit_financials','filing_date'],['valuation_pit_model_runs','as_of_date'],['daily_prices','date'],['prices','date'],['nav','date']]){
        const t=tables.find(x=>x.name===spec[0]);if(t?.columns.some(x=>x.name===spec[1]))facts[`${spec[0]}_range`]=db.prepare(`SELECT min(${quote(spec[1])}) first,max(${quote(spec[1])}) last FROM ${quote(spec[0])}`).get();
      }
      databases.push({label,exists:true,bytes:stat.size,mode:(stat.mode&0o777).toString(8),modifiedAt:stat.mtime.toISOString(),
        walBytes:fs.existsSync(file+'-wal')?fs.statSync(file+'-wal').size:0,
        journal:db.prepare('PRAGMA journal_mode').get(),pageCount:db.prepare('PRAGMA page_count').get(),freePages:db.prepare('PRAGMA freelist_count').get(),
        schemaSha256:hash(JSON.stringify(schema)),integrity,foreignKeyViolations,tables,facts});
      console.log(JSON.stringify({label,bytes:stat.size,tables:tables.length,integrity,foreignKeyViolations,facts}));
    }catch(e){databases.push({label,error:e.message});console.error(label,e.message);}finally{db.close();}
  }
  save('local-databases.json',{readOnly:true,databases});
}
function request(url,{auth=false,encoding='gzip',headers={}}={}){
  if(auth&&!url.startsWith('http://127.0.0.1:8789/'))throw new Error('Audit token restricted to local preview');
  return new Promise(resolve=>{
    const t=performance.now();const req=(url.startsWith('https:')?https:http).get(url,{headers:{'accept-encoding':encoding,...(auth?{authorization:'Bearer local-dev-token'}:{}),...headers}},res=>{
      let bytes=0;const chunks=[];res.on('data',c=>{bytes+=c.length;chunks.push(c)});
      res.on('end',()=>resolve({status:res.statusCode,ms:Math.round(performance.now()-t),bytes,headers:res.headers,body:Buffer.concat(chunks)}));
    });req.setTimeout(20000,()=>req.destroy(new Error('timeout')));req.on('error',e=>resolve({error:e.message,ms:Math.round(performance.now()-t)}));
  });
}
const safe=r=>({status:r.status,ms:r.ms,bytes:r.bytes,error:r.error,headers:Object.fromEntries(Object.entries(r.headers??{}).filter(([k])=>['server','cache-control','content-encoding','content-length','vary','etag','content-type','strict-transport-security','content-security-policy','x-frame-options','x-content-type-options','x-powered-by','access-control-allow-origin'].includes(k)))});
if(mode==='http'){
  const targets=['https://www.thesisforge.tech','https://thesisforge.tech','http://guru-analysis-api-prod-378477120101.us-east-1.elasticbeanstalk.com'];
  const rows=[];
  for(const base of targets){
    for(const route of ['/api/health','/api/portfolio','/api/investment/strategy-lab','/api/internal/backtests/status','/api/INTERNAL/backtests/status']){
      const r=await request(base+route,{encoding:'identity'});const item={base,route,...safe(r)};
      if(route==='/api/health'&&r.body){try{const j=JSON.parse(r.body);item.health={status:j.status,generatedAt:j.generatedAt,modules:j.modules?.map(x=>({id:x.id,state:x.state,message:x.message,freshness:x.freshness,curveAvailability:x.details?.curveAvailability}))};}catch{}}
      rows.push(item);console.log(JSON.stringify({base,route,status:r.status,ms:r.ms}));
    }
  }
  rows.push({base:targets[0],route:'/',...safe(await request(targets[0]+'/'))});
  for(const origin of ['https://www.thesisforge.tech','https://thesisforge.tech','https://audit-untrusted.invalid'])rows.push({origin,...safe(await request(targets[2]+'/api/portfolio',{headers:{origin}}))});
  // Eight concurrent metadata requests only; not a production load test.
  const burst=await Promise.all(Array.from({length:8},()=>request(targets[0]+'/api/health')));
  save('http.json',{rows,healthBurst:burst.map(safe),scope:'Unauthenticated GETs and one 8-request metadata burst. No production workload load test.'});
  console.log(JSON.stringify({healthBurst:burst.map(r=>({status:r.status,ms:r.ms}))}));
}
if(mode==='preview-performance'){
  const routes=['/api/investment/fundamentals?asOf=2026-09-10','/api/investment/research/GOOGL?asOf=2026-09-10','/api/investment/guru-study?asOf=2026-09-10&period=common'];
  const rows=[];
  for(const route of routes){
    const url='http://127.0.0.1:8789'+route;
    const cold=await request(url,{auth:true});
    const warm=[];for(let i=0;i<5;i++)warm.push(await request(url,{auth:true}));
    const concurrent=[];for(let i=0;i<4;i++)concurrent.push(...await Promise.all(Array.from({length:5},()=>request(url,{auth:true}))));
    const identity=await request(url,{auth:true,encoding:'identity'});
    const conditional=cold.headers?.etag?await request(url,{auth:true,headers:{'if-none-match':cold.headers.etag}}):null;
    const sorted=concurrent.map(r=>r.ms).sort((a,b)=>a-b);
    const row={route,cold:safe(cold),warm:warm.map(safe),concurrent:concurrent.map(safe),concurrency:5,p50:sorted[9],p95:sorted[18],
      identity:safe(identity),reductionPct:identity.bytes?(1-cold.bytes/identity.bytes)*100:null,conditional:conditional?safe(conditional):null};
    rows.push(row);console.log(JSON.stringify({route,coldMs:cold.ms,warmMs:warm.map(r=>r.ms),p50:row.p50,p95:row.p95,bytes:identity.bytes,reductionPct:row.reductionPct,status:cold.status}));
  }
  save('preview-performance.json',{scope:'Diagnostic only: 1 cold, 5 sequential, 20 requests at concurrency 5 per route. Not the 60-sample/concurrency-20/three-run production release comparison.',rows});
}
