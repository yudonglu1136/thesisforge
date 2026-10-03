import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import {loadInvestorStyleDashboard} from '../server/investorStyleDashboard.js';
import {queryFacts,factGeneration,PRICE_TYPES} from '../server/factRepository.js';
import {readRuleLedgerArchive} from '../server/ruleLedgerArchive.js';
import {canonicalRulePrices,hydrateRuleLedger,buildRuleLedger} from '../server/rulePortfolioAnalysis.js';
import {extendPublishedPriceVintage} from '../server/rulePriceVintage.js';
import {refreshRuleSnapshot} from '../server/rulePortfolioRefresh.js';
import {buildRulePortfolioBundle,validateRulePortfolioBundle} from '../server/rulePortfolioBundleBuild.js';
import {RULE_BUNDLE_UNIVERSES,ruleBundlePaths} from '../server/rulePortfolioBundle.js';
import {appendRuleQuarterSelections} from '../server/ruleQuarterAppend.js';
import {attachQqqBenchmark} from '../server/ruleBenchmark.js';

// Offline worker only. No network fetch, mutable writer database or API request
// computation. Caller freezes the canonical root and exact parent artifacts.
const {values:v}=parseArgs({options:{root:{type:'string'},parent:{type:'string'},
  'bootstrap-ledger':{type:'string'},'as-of':{type:'string'},output:{type:'string'},selections:{type:'string'}}});
if(!v.root||!v.output||!/^\d{4}-\d{2}-\d{2}$/.test(v['as-of']??'')||
   Boolean(v.parent)===Boolean(v['bootstrap-ledger']))throw new Error('root_output_asof_and_exactly_one_parent_required');
const root=path.resolve(v.root),output=path.resolve(v.output),sha=x=>createHash('sha256').update(x).digest('hex');
if(output===root||output.startsWith(root+path.sep))throw new Error('output_must_not_mutate_input_snapshot');
process.env.FACT_OS_ROOT=root;
const catalog=()=>fs.readFileSync(path.join(root,'manifests/catalog.json'));
// factGeneration() is a request/cache token (path/mtime/runtime), not the
// canonical fact identity. Python selections bind to the catalog SHA-256.
const sourceManifestSha256=sha(catalog()),generation=sourceManifestSha256;
const cacheToken=await factGeneration();
const parent=v.parent?validateRulePortfolioBundle(v.parent):null;
const selectionBytes=v.selections?fs.readFileSync(v.selections):null;
const selections=selectionBytes?JSON.parse(selectionBytes):null;
const dashboards={},allPrices={};let commonEnd;
for(const universe of RULE_BUNDLE_UNIVERSES){
  const source=loadInvestorStyleDashboard({universe,bundleRoot:v.parent??null});
  const bundle=v.parent?ruleBundlePaths(v.parent,universe,{required:true}):null;
  const archive=readRuleLedgerArchive(source,{root:bundle?.ledgerRoot??v['bootstrap-ledger'],
    ...(bundle?{identity:bundle.ledgerIdentity}:{})});
  if(!archive)throw new Error('published_price_archive_required');
  const ledger=hydrateRuleLedger(archive.ledger);
  buildRuleLedger(source,extendPublishedPriceVintage(source,ledger,new Map()).prices);
  if(v['as-of']<source.dataThrough)throw new Error('rule_daily_clock_before_parent');
  const benchmark=await queryFacts('get_price_history',['SPY',source.backtest.from,v['as-of'],PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE]);
  const end=benchmark.at(-1)?.date;
  if(!end||end<source.dataThrough||commonEnd&&end!==commonEnd)throw new Error('rule_daily_benchmark_cutoff_invalid');
  commonEnd=end;
  const appended=selections?appendRuleQuarterSelections(source,selections[universe],{
    sourceGeneration:generation,tradingDates:benchmark.map(r=>r.date),end}):{snapshot:source,newSymbols:{}};
  const request=structuredClone(appended.snapshot);
  request.backtest.curve=[{date:source.backtest.from},{date:end}];
  for(const style of request.styles)style.trades=style.quarters.filter(q=>q.executionDate<end).map(q=>({date:q.executionDate}));
  const current=await canonicalRulePrices(request);
  current.set('SPY',new Map(benchmark.map(r=>[r.date,r.value])));
  const vintage=extendPublishedPriceVintage(source,ledger,current,{newSymbols:appended.newSymbols});
  let result=refreshRuleSnapshot(appended.snapshot,vintage.prices,end);
  if(universe==='nasdaq100'){
    const qqq=await queryFacts('get_price_history',['QQQ',source.backtest.from,end,PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE]);
    result=attachQqqBenchmark(source,result,qqq,generation);
  }
  result.lineage={...result.lineage,dailyRefresh:{method:'rule-daily-vintage-v1',sourceManifestSha256,
    sourceGeneration:generation,parentSnapshot:source.snapshotId,parentBundle:parent?.identity??null,
    priceVintage:vintage.basis,bridges:vintage.bridges,archiveIdentity:archive.archiveIdentity,
    sourceWrites:false,allDailyNavReconciled:true}};
  dashboards[universe]=result;allPrices[universe]=vintage.prices;
}
if(sha(catalog())!==sourceManifestSha256||await factGeneration()!==cacheToken)throw new Error('rule_daily_input_changed');
if(parent&&validateRulePortfolioBundle(v.parent).identity!==parent.identity)throw new Error('rule_daily_parent_changed');
if(selectionBytes&&sha(fs.readFileSync(v.selections))!==sha(selectionBytes))throw new Error('rule_daily_selections_changed');
const result=buildRulePortfolioBundle({output,dashboards,prices:allPrices,sourceGeneration:generation,sourceManifestSha256});
console.log(JSON.stringify({...result,dataThrough:commonEnd,sourceWrites:false}));
