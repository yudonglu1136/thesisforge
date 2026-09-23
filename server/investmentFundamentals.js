import { finite, isoDate } from './investmentMath.js';
import { sourceNode, tickerKey } from './investmentSource.js';
import { dataReleaseId } from './dataReleaseContext.js';
import { opportunityQuality } from './investmentQuality.js';
import { buildOpportunities } from './investmentOpportunities.js';
import { investmentCurrentQuotes,preferInvestmentQuote } from './investmentPrices.js';
import { marketFactsVersion } from './investmentMarketContext.js';

export const FUNDAMENTALS_VERSION = 'fundamental-changes-v1';
const cache = new WeakMap();
const MAX_PIT_DATES = 48;
const MAX_COMPACT_NODES = 4096;
const keys = ['revenueGrowth','operatingMargin','fcfMargin','capexIntensity'];
const operatingRoutes=new Set(['operating_company','multi_method_growth','revenue_stage']);
const nullMetrics = () => Object.fromEntries(keys.map(k=>[k,null]));
const delta = (a,b) => finite(a)&&finite(b)?a-b:null;

// Screens are observable conditions, not quality scores or buy recommendations.
export function fundamentalScreens(metrics, changes) {
  const g=metrics.revenueGrowth, op=metrics.operatingMargin, cash=metrics.fcfMargin;
  const high=finite(g)&&g>=.15, atLeast=(x,n)=>finite(x)&&x>=n-1e-10;
  return [
    high&&atLeast(changes.revenueGrowth,.05)?'acceleration':null,
    finite(g)&&g>0&&finite(op)&&op>0&&atLeast(changes.operatingMargin,.02)?'profit':null,
    high&&finite(cash)&&cash>0&&atLeast(changes.fcfMargin,0)?'cash':null,
    high&&[changes.operatingMargin,changes.fcfMargin].some(x=>finite(x)&&x<=-.02+1e-10)?'divergence':null,
  ].filter(Boolean);
}

function compact(row) {
  const n=sourceNode(row);
  return {period:n.period,periodEnd:n.periodEnd,availableAt:n.availableAt,filingDate:n.filingDate,
    metrics:n.metrics,route:n.score.modelRoute,currency:n.input.sourceRecord?.currency??null,
    fairValue:n.publishedFairValue,formula:n.publishedFormula,
    source:{dataset:n.source.dataset,dimension:n.source.dimension,hash:n.source.hash,modelVersion:n.source.modelVersion}};
}

export function fundamentalComparison(n,p) {
  const days=n&&p?(Date.parse(n.periodEnd)-Date.parse(p.periodEnd))/86400000:0;
  // Distinct, adjacent quarterly statements only. ART growth is not quarterly growth.
  return !!n&&!!p&&n.source.dimension==='ARQ'&&p.source.dimension==='ARQ'&&
    n.source.modelVersion===p.source.modelVersion&&n.currency!=null&&n.currency===p.currency&&
    p.availableAt<n.availableAt&&days>=60&&days<=120;
}

function replayState(source) {
  // data_version detects other connections; total_changes also detects writes
  // through this connection (e.g. an import or a test). Never reuse a different
  // generation's PIT observations. Bound dates per source, not per user.
  const generation=source.db.prepare('PRAGMA data_version').get().data_version+':'+(dataReleaseId()??'legacy')+':'+(marketFactsVersion()??'stored');
  const changes=source.db.prepare('SELECT total_changes() n').get().n;
  let state=cache.get(source);
  if(!state||state.db!==source.db||state.generation!==generation||state.changes!==changes) {
    state={db:source.db,generation,changes,dates:new Map(),snapshots:null,modelIndex:null,nodes:new Map()};
    cache.set(source,state);
  }
  return state;
}

function priceAt(snapshot,asOf) {
  if(!snapshot)return undefined;
  // Parse only a consumed company's history. An unused snapshot must not
  // change the behavior of otherwise valid operating-company observations.
  if(!snapshot.priceIndex) {
    snapshot.priceIndex=JSON.parse(snapshot.prices??'[]')
      .filter(x=>typeof x.date==='string'&&finite(x.close)&&x.close>0)
      .sort((a,b)=>a.date.localeCompare(b.date)).map(({date,close,source})=>({date,close,source}));
    snapshot.prices=null;
  }
  const prices=snapshot.priceIndex;
  let lo=0,hi=prices.length;
  while(lo<hi){const mid=(lo+hi)>>>1;if(prices[mid].date<=asOf)lo=mid+1;else hi=mid;}
  return prices[lo-1];
}

function visibleModelRows(state,asOf) {
  // Read only the small selection metadata once. Replaying a quarter must not
  // scan the entire (large JSON) model table again. SQL defines revision order;
  // the cutoff is still applied before choosing each period's latest revision.
  if(!state.modelIndex) {
    const rows=state.db.prepare(`SELECT rowid rowKey,ticker,fiscal_period,as_of_date,model_version
      FROM valuation_pit_model_runs ORDER BY ticker,fiscal_period,as_of_date DESC,model_version DESC`).all();
    state.modelIndex=new Map([...Map.groupBy(rows,r=>r.ticker)].map(([ticker,items])=>[ticker,Map.groupBy(items,r=>r.fiscal_period)]));
    state.readNode=state.db.prepare('SELECT * FROM valuation_pit_model_runs WHERE rowid=?');
  }
  const groups=new Map(),desc=(a,b)=>a===b?0:a==null?1:b==null?-1:a>b?-1:1;
  for(const [ticker,periods] of state.modelIndex) {
    const latest=[...periods.values()].map(revisions=>revisions.find(r=>r.as_of_date<=asOf)).filter(Boolean)
      .sort((a,b)=>desc(a.as_of_date,b.as_of_date)||desc(a.fiscal_period,b.fiscal_period)).slice(0,2);
    if(latest.length)groups.set(ticker,latest);
  }
  return groups;
}

function compactNode(state,row) {
  if(state.nodes.has(row.rowKey)){
    const n=state.nodes.get(row.rowKey);state.nodes.delete(row.rowKey);state.nodes.set(row.rowKey,n);return n;
  }
  const n=compact(state.readNode.get(row.rowKey));
  state.nodes.set(row.rowKey,n);
  if(state.nodes.size>MAX_COMPACT_NODES)state.nodes.delete(state.nodes.keys().next().value);
  return n;
}

export function buildFundamentals(source,asOf) {
  isoDate(asOf);
  const state=replayState(source),priorCache=state.dates.get(asOf);
  if(priorCache){state.dates.delete(asOf);state.dates.set(asOf,priorCache);return structuredClone(priorCache);}
  // Select the latest node first, then validate it. A bad latest node must not
  // be replaced by a silently older "healthy" observation.
  const groups=visibleModelRows(state,asOf),companies=[];
  const quality=opportunityQuality(source,asOf);
  let invalid=0,excluded=0;
  if(!state.snapshots) state.snapshots=new Map(source.db.prepare(`SELECT ticker,json_extract(payload_json,'$.name') name,
    json_extract(payload_json,'$.currency') currency,json_extract(payload_json,'$.priceSource') priceSource,
    json_extract(payload_json,'$.priceHistory') prices FROM valuation_ticker_snapshots`).all().map(s=>[s.ticker,s]));
  const snapshots=state.snapshots;
  const currentQuotes=investmentCurrentQuotes(source,[...groups.keys()],asOf);
  for(const [ticker,group] of groups) {
    let n,p;
    try{n=compactNode(state,group[0]);}catch{invalid++;continue;}
    if(!operatingRoutes.has(n.route)){excluded++;continue;}
    try{p=group[1]?compactNode(state,group[1]):null;}catch{p=null;}
    const comparable=fundamentalComparison(n,p);
    const metrics={...n.metrics,revenueGrowth:n.source.dimension==='ARQ'?n.metrics.revenueGrowth:null};
    const changes=comparable?Object.fromEntries(keys.map(k=>[k,delta(n.metrics[k],p.metrics[k])])):nullMetrics();
    const snap=snapshots.get(ticker);
    const storedPrice=priceAt(snap,asOf);
    const price=preferInvestmentQuote(currentQuotes.get(ticker),storedPrice?{
      value:storedPrice.close,date:storedPrice.date,source:storedPrice.source??snap?.priceSource??null,currency:snap?.currency??null,
    }:{value:null,date:null,source:null,currency:snap?.currency??null});
    const priceAgeDays=price?.date?Math.floor((Date.parse(asOf)-Date.parse(price.date))/86400000):null;
    const valueKnown=finite(n.fairValue)&&n.fairValue>0;
    const valueComparable=valueKnown&&finite(price?.value)&&price.value>0&&n.currency!=null&&n.currency===price?.currency&&priceAgeDays<=7;
    companies.push({ticker,name:snap?.name??ticker,period:n.period,periodEnd:n.periodEnd,
      availableAt:n.availableAt,filingDate:n.filingDate,source:n.source,metrics,changes,
      previous:comparable?{period:p.period,periodEnd:p.periodEnd,availableAt:p.availableAt,metrics:p.metrics}:null,
      comparisonStatus:comparable?'adjacent_quarters':n.source.dimension!=='ARQ'?'not_quarterly':'prior_not_comparable',
      screens:fundamentalScreens(metrics,changes),
      quality:quality.get(ticker)??{status:'unavailable',years:[]},
      price:{value:price?.value??null,date:price?.date??null,currency:price?.currency??snap?.currency??null,ageDays:priceAgeDays,source:price?.source??snap?.priceSource??null},
      valuation:{fairValue:valueKnown?n.fairValue:null,date:n.availableAt,currency:n.currency,formula:n.formula},
      modelGap:valueComparable?n.fairValue/price.value-1:null,
      valuationStatus:!valueKnown?'no_value':!finite(price?.value)||price.value<=0?'no_price':n.currency!==price?.currency?'currency_unverified':priceAgeDays>7?'stale_price':'available'});
  }
  const result={version:FUNDAMENTALS_VERSION,asOf,retrospective:true,companies,
    coverage:{total:groups.size,operating:companies.length,excluded,invalid,
      comparable:companies.filter(c=>c.previous).length,valuations:companies.filter(c=>c.modelGap!=null).length},
    counts:Object.fromEntries(['acceleration','profit','cash','divergence'].map(k=>[k,companies.filter(c=>c.screens.includes(k)).length]))};
  state.dates.set(asOf,result);
  if(state.dates.size>MAX_PIT_DATES)state.dates.delete(state.dates.keys().next().value);
  return structuredClone(result);
}

// Same exact-claim, PIT and manager-universe rules as Discover. A missing
// ticker in a bounded extract is not proof that no manager owned it.
export function fundamentalGuruQuarter(source,ticker,asOf,quarter=null) {
  ticker=tickerKey(ticker);
  const r=buildOpportunities(source,asOf,quarter);
  const stock=r.rows.find(row=>row.ticker===ticker);
  return {version:'fundamental-guru-quarter-v1',ticker,asOf,reportDate:r.reportDate,
    quarters:r.quarters,coverage:r.coverage,managers:stock?.managers??[],
    managerCount:stock?.managerCount??0,adds:stock?.adds??0,trims:stock?.trims??0};
}
