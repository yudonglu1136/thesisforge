import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {loadInvestorStyleDashboard,validateInvestorStyleDashboard} from './investorStyleDashboard.js';
import {buildRuleLedger,serializeRuleLedger,hydrateRuleLedger,analyzeRuleRange,RULE_ANALYSIS_VERSION} from './rulePortfolioAnalysis.js';
import {readRuleLedgerArchive,ruleLedgerArchiveIdentity} from './ruleLedgerArchive.js';
import {extendPublishedPriceVintage} from './rulePriceVintage.js';
import {RULE_BUNDLE_SCHEMA,RULE_BUNDLE_UNIVERSES,readRuleBundleManifest,ruleBundlePaths} from './rulePortfolioBundle.js';

const hash=b=>createHash('sha256').update(b).digest('hex');
const json=x=>JSON.stringify(x)+'\n';
const syncDirectory=directory=>{const fd=fs.openSync(directory,'r');try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}};
const write=(file,bytes)=>{
  const fd=fs.openSync(file,'wx',0o444);
  try{fs.writeFileSync(fd,bytes);fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
};

export function validateRulePortfolioBundle(root) {
  const {manifest,identity}=readRuleBundleManifest(root,{required:true}),universes={};
  if(ruleLedgerArchiveIdentity(path.join(root,'ledger'))!==manifest.ledgerIdentity)throw new Error('rule_bundle_ledger_identity');
  for(const universe of RULE_BUNDLE_UNIVERSES){
    const p=ruleBundlePaths(root,universe,{required:true});
    const dashboard=loadInvestorStyleDashboard({bundleRoot:root,universe});
    const archive=readRuleLedgerArchive(dashboard,{root:p.ledgerRoot,identity:p.ledgerIdentity});
    if(!archive||archive.sourceGeneration!==manifest.sourceGeneration)throw new Error('rule_bundle_source_mismatch');
    const ledger=hydrateRuleLedger(archive.ledger);
    // Recompute the ledger from its recorded marks: do not trust success flags.
    buildRuleLedger(dashboard,extendPublishedPriceVintage(dashboard,ledger,new Map()).prices);
    const curve=dashboard.backtest.curve;
    const windows=[[curve[0].date,curve.at(-1).date],[curve[Math.max(0,curve.length-30)].date,curve.at(-1).date],
      ...['2013','2014'].flatMap(y=>{const rows=curve.filter(r=>r.date.startsWith(y));return rows.length>1?[[rows[0].date,rows.at(-1).date]]:[];})];
    for(const [start,end] of windows){
      const result=analyzeRuleRange(ledger,start,end);
      for(const style of result.styles){
        if(style.status==='coverage_gap')continue;
        if(Math.abs(style.reconciliation.difference)>1e-8||
          style.distribution.reduce((n,b)=>n+b.count,0)!==style.tradeStats.stocks)
          throw new Error('rule_bundle_range_mismatch');
      }
    }
    universes[universe]={snapshotId:dashboard.snapshotId,dataThrough:dashboard.dataThrough,
      observations:curve.length,rangeChecks:windows.length};
  }
  return {status:'verified',identity,sourceGeneration:manifest.sourceGeneration,universes};
}

// Called offline on the single worker. Manifest-last + directory rename makes
// the three universes and their exact ledgers one indivisible read artifact.
export function buildRulePortfolioBundle({output,dashboards,prices,sourceGeneration,sourceManifestSha256}) {
  if(!/^[a-f0-9]{64}$/.test(sourceGeneration??'')||!/^[a-f0-9]{64}$/.test(sourceManifestSha256??''))
    throw new Error('rule_bundle_source_required');
  if(Object.keys(dashboards).sort().join(',')!==[...RULE_BUNDLE_UNIVERSES].sort().join(','))
    throw new Error('rule_bundle_universe_matrix_incomplete');
  const parent=path.dirname(path.resolve(output));fs.mkdirSync(parent,{recursive:true});
  const staged=fs.mkdtempSync(path.join(parent,'.rule-bundle-'));
  try{
    fs.mkdirSync(path.join(staged,'ledger'));
    const entries={},ledgerEntries={};
    for(const universe of RULE_BUNDLE_UNIVERSES){
      const payload=structuredClone(dashboards[universe]);
      // These are request metadata, not immutable source facts.
      for(const field of ['snapshotId','requestedAsOf','status','universeOptions'])delete payload[field];
      validateInvestorStyleDashboard(payload);
      if((payload.universe?.id??'all')!==universe)throw new Error('rule_bundle_universe_mismatch');
      const bytes=json(payload),snapshotId=hash(bytes),file=`${universe}.json`;
      write(path.join(staged,file),bytes);
      const ledger=buildRuleLedger({...payload,snapshotId},prices[universe]);
      const value={version:'strategy-ledger-public-analysis-v1',snapshotId,sourceGeneration,sourceManifestSha256,
        ledger:serializeRuleLedger(ledger)};
      const compressed=gzipSync(json(value)),sha256=hash(compressed),ledgerFile=`${sha256}.json.gz`;
      write(path.join(staged,'ledger',ledgerFile),compressed);
      entries[universe]={file,snapshotId,dataThrough:payload.dataThrough};
      ledgerEntries[universe]={snapshotId,sourceGeneration,sourceManifestSha256,file:ledgerFile,sha256,bytes:compressed.length};
    }
    write(path.join(staged,'ledger','manifest.json'),json({schemaVersion:1,method:RULE_ANALYSIS_VERSION,entries:ledgerEntries}));
    syncDirectory(path.join(staged,'ledger'));
    write(path.join(staged,'rule-manifest.json'),json({schemaVersion:RULE_BUNDLE_SCHEMA,sourceGeneration,
      sourceManifestSha256,entries,ledgerIdentity:ruleLedgerArchiveIdentity(path.join(staged,'ledger'))}));
    const receipt=validateRulePortfolioBundle(staged);
    syncDirectory(staged);
    if(fs.existsSync(output)){
      const previous=validateRulePortfolioBundle(output);
      if(previous.identity!==receipt.identity)throw new Error('immutable_rule_bundle_conflict');
      return {...previous,status:'unchanged'};
    }
    fs.renameSync(staged,output);
    syncDirectory(parent);
    return receipt;
  }finally{
    // Only the exact temporary directory owned by this invocation; never an
    // installed bundle, database, raw archive or prior output.
    if(fs.existsSync(staged))fs.rmSync(staged,{recursive:true});
  }
}
