import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {parseArgs} from 'node:util';
import {loadInvestorStyleDashboard} from '../server/investorStyleDashboard.js';
import {buildRuleLedger,canonicalRulePrices,serializeRuleLedger,analyzeRuleRange,RULE_ANALYSIS_VERSION} from '../server/rulePortfolioAnalysis.js';
import {readRuleLedgerArchive,ruleLedgerArchiveIdentity} from '../server/ruleLedgerArchive.js';

// Explicit offline packaging, never a request-time or daily backtest. Only
// derived public strategy data is exported; no database/private user records.
const {values}=parseArgs({options:{output:{type:'string'},root:{type:'string'}}});
if(!values.output||!values.root)throw new Error('root_and_new_output_required');
const root=path.resolve(values.root),output=path.resolve(values.output);
process.env.FACT_OS_ROOT=root;
const hash=b=>createHash('sha256').update(b).digest('hex');
const catalog=()=>fs.readFileSync(path.join(root,'manifests/catalog.json'));
const initial=catalog(),sourceManifestSha256=hash(initial);
const sourceGeneration=JSON.parse(initial).generationId??sourceManifestSha256;
fs.mkdirSync(output,{recursive:false,mode:0o700});
const entries={},receipts=[];
for(const universe of ['all','sp500','nasdaq100']){
  const dashboard=loadInvestorStyleDashboard({universe});
  const prices=await canonicalRulePrices(dashboard);
  if(hash(catalog())!==sourceManifestSha256)throw new Error('rule_analysis_generation_changed');
  const ledger=buildRuleLedger(dashboard,prices),curve=dashboard.backtest.curve;
  const windows=[[curve[0].date,curve.at(-1).date],...['2013','2014'].flatMap(year=>{
    const rows=curve.filter(r=>r.date.startsWith(year));return rows.length>1?[[rows[0].date,rows.at(-1).date]]:[];
  })];
  const checks=windows.map(([start,end])=>{
    const result=analyzeRuleRange(ledger,start,end);
    for(const style of result.styles){
      if(style.status==='coverage_gap')continue;
      if(Math.abs(style.reconciliation.difference)>1e-8||style.distribution.reduce((n,b)=>n+b.count,0)!==style.tradeStats.stocks)
        throw new Error('rule_archive_range_reconciliation_failed');
    }
    return {start,end,styles:result.styles.map(s=>({id:s.id,status:s.status??'available',
      residual:s.reconciliation?.difference,stocks:s.tradeStats?.stocks,winRate:s.tradeStats?.winRate,turnover:s.turnover?.oneWay}))};
  });
  const value={version:'strategy-ledger-public-analysis-v1',snapshotId:dashboard.snapshotId,
    sourceGeneration,sourceManifestSha256,ledger:serializeRuleLedger(ledger)};
  const bytes=gzipSync(JSON.stringify(value)),sha256=hash(bytes),file=`${sha256}.json.gz`;
  fs.writeFileSync(path.join(output,file),bytes,{flag:'wx',mode:0o400});
  entries[universe]={snapshotId:dashboard.snapshotId,sourceGeneration,sourceManifestSha256,file,sha256,bytes:bytes.length};
  receipts.push({universe,checks});
}
if(hash(catalog())!==sourceManifestSha256)throw new Error('rule_analysis_generation_changed');
const manifest={schemaVersion:1,method:RULE_ANALYSIS_VERSION,entries};
fs.writeFileSync(path.join(output,'manifest.json'),JSON.stringify(manifest),{flag:'wx',mode:0o400});
const identity=ruleLedgerArchiveIdentity(output);
for(const universe of Object.keys(entries))readRuleLedgerArchive(loadInvestorStyleDashboard({universe}),{root:output,identity});
console.log(JSON.stringify({status:'verified',identity,entries,receipts},null,2));
