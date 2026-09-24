import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { loadInvestorStyleDashboard } from '../server/investorStyleDashboard.js';
import { queryFacts, factGeneration, PRICE_TYPES } from '../server/factRepository.js';
import { canonicalRulePrices } from '../server/rulePortfolioAnalysis.js';
import { refreshRuleSnapshot } from '../server/rulePortfolioRefresh.js';
import { releaseRoot } from '../server/dataReleaseContext.js';
import path from 'node:path';

const [end, output, auditPriceOutput] = process.argv.slice(2);
if (!/^\d{4}-\d{2}-\d{2}$/.test(end ?? '') || !output) throw new Error('Usage: node scripts/refresh-rule-portfolio-observations.mjs END_DATE OUTPUT_JSON');
const sha = x=>createHash('sha256').update(x).digest('hex');
const source=loadInvestorStyleDashboard(), generation=await factGeneration();
const root=releaseRoot('canonical',process.env.FACT_OS_ROOT || fileURLToPath(new URL('../data/fact_os',import.meta.url)));
const catalog=path.join(root,'manifests/catalog.json');
const priceSourceGeneration=sha(fs.readFileSync(catalog));
const benchmark=await queryFacts('get_price_history',['SPY',source.backtest.from,end,PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE]);
if (benchmark.at(-1)?.date!==end) throw new Error('end_not_observed_in_canonical_prices');
const request=structuredClone(source);
request.backtest.curve=[{date:source.backtest.from},{date:end}];
for(const style of request.styles)style.trades=style.quarters.filter(q=>q.executionDate<end).map(q=>({date:q.executionDate}));
const prices=await canonicalRulePrices(request);
prices.set('SPY',new Map(benchmark.map(r=>[r.date,r.value])));
if(await factGeneration()!==generation || sha(fs.readFileSync(catalog))!==priceSourceGeneration)throw new Error('input_generation_changed');
const result=refreshRuleSnapshot(source,prices,end);
// Optional bounded, local-only extract for the independent Python audit; never
// part of a release package or source-controlled data. No full database copy.
const csv='ticker,date,closeadj\n'+[...prices].sort(([a],[b])=>a.localeCompare(b)).flatMap(([ticker,rows])=>[...rows].sort(([a],[b])=>a.localeCompare(b)).map(([date,value])=>`${ticker},${date},${value}\n`)).join('');
result.lineage.priceSha256=sha(csv);
if (auditPriceOutput) {
  fs.writeFileSync(auditPriceOutput,csv,{flag:'wx',mode:0o600});
}
result.lineage={...result.lineage, refresh:{method:'rule-observed-window-v1', parentSnapshot:source.snapshotId,
  priceSourceGeneration,requestedEnd:end,sourceWrites:false,
  builderSha256:sha(fs.readFileSync(fileURLToPath(import.meta.url))),
  engineSha256:sha(fs.readFileSync(new URL('../server/backtestEngine.js',import.meta.url))),
  allDailyNavReconciled:true, partialQuarterExecuted:true}};
const bytes=JSON.stringify(result)+'\n', temp=`${output}.${process.pid}.tmp`;
fs.writeFileSync(temp,bytes,{flag:'wx'});fs.renameSync(temp,output);
console.log(JSON.stringify({status:'pass',snapshotId:sha(bytes),from:result.backtest.from,to:end,
  observations:result.backtest.observations,sourceWrites:false,styles:result.styles.map(s=>({id:s.id,...s.metrics}))},null,2));
