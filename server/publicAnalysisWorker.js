import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { parentPort,workerData } from 'node:worker_threads';
import { queryFacts } from './factRepository.js';
import { InvestmentSource } from './investmentSource.js';
import { buildOpportunities } from './investmentOpportunities.js';
import { loadInvestorStyleDashboard } from './investorStyleDashboard.js';
import { buildRuleLedger,canonicalRulePrices,serializeRuleLedger } from './rulePortfolioAnalysis.js';

async function build() {
  const {kind,args,context,fingerprint,cohortFingerprint,logicalKey,root}=workerData;
  if(context.canonicalRoot)process.env.FACT_OS_ROOT=context.canonicalRoot;
  if(context.canonicalRoot&&process.env.NODE_ENV==='production'&&!process.env.FACT_OS_LEASE_ROOT)
    process.env.FACT_OS_LEASE_ROOT='/var/app/data/fact-os-leases';
  let value;
  if(kind==='fundamentals')value=await queryFacts('get_fundamental_change_universe',[args.asOf],{limit:6000});
  else if(kind==='opportunities'){
    if(!context.researchFile)throw new Error('research_release_unavailable');
    const source=new InvestmentSource(context.researchFile,{canonicalMarket:true,publicFactsFile:context.publicFactsFile,insightsFile:context.insightsFile});
    try{value=buildOpportunities(source,args.asOf,args.reportDate??null);}finally{source.close();}
  }else if(kind==='strategy')value=loadInvestorStyleDashboard({asOf:args.asOf,universe:args.universe??'all'});
  else if(kind==='strategy-ledger'){
    const dashboard=loadInvestorStyleDashboard({asOf:args.asOf,universe:args.universe??'all'});
    const prices=await canonicalRulePrices(dashboard);
    value={version:'strategy-ledger-public-analysis-v1',snapshotId:dashboard.snapshotId,
      sourceGeneration:dashboard.lineage?.sourceGeneration??null,
      ledger:serializeRuleLedger(buildRuleLedger(dashboard,prices))};
  }
  else throw new Error('public_analysis_kind_invalid');
  const directory=path.join(root,'releases',fingerprint);fs.mkdirSync(directory,{recursive:true,mode:0o755});
  const file=path.join(directory,'artifact.json'),temporary=`${file}.${process.pid}.part`;
  const bytes=Buffer.from(JSON.stringify(value)),sha256=crypto.createHash('sha256').update(bytes).digest('hex');
  if(fs.existsSync(file)){
    const existing=fs.readFileSync(file);if(existing.length!==bytes.length||crypto.createHash('sha256').update(existing).digest('hex')!==sha256)throw new Error('immutable_public_analysis_conflict');
  }else{
    const handle=fs.openSync(temporary,'wx',0o644);
    try{fs.writeFileSync(handle,bytes);fs.fsyncSync(handle);}finally{fs.closeSync(handle);}
    fs.renameSync(temporary,file);fs.chmodSync(file,0o444);
    const parent=fs.openSync(directory,'r');try{fs.fsyncSync(parent);}finally{fs.closeSync(parent);}
  }
  return {logicalKey,fingerprint,cohortFingerprint,kind,asOf:args.asOf,createdAt:new Date().toISOString(),
    path:path.relative(root,file),bytes:bytes.length,sha256};
}

build().then(entry=>parentPort.postMessage({ok:true,entry}),()=>parentPort.postMessage({ok:false,error:'public_analysis_build_failed'}));
