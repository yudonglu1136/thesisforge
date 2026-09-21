import fs from 'node:fs';
import {finite} from './investmentMath.js';
import {opportunityValuations} from './investmentOpportunities.js';
import {sp500CanonicalTicker} from './sp500ValuationUniverse.js';

const sum=xs=>xs.reduce((s,x)=>s+x,0);
const mean=xs=>sum(xs)/xs.length;
const variance=xs=>xs.length>1?sum(xs.map(x=>(x-mean(xs))**2))/(xs.length-1):null;
const covariance=(xs,ys)=>sum(xs.map((x,i)=>(x-mean(xs))*(ys[i]-mean(ys))))/(xs.length-1);
const positive=x=>finite(x)&&x>0;
const ratio=(a,b)=>finite(a)&&b>0?a/b:null;
const dated=x=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(x)&&Number.isFinite(Date.parse(x))&&new Date(x).toISOString().slice(0,10)===x;
// Cache only public market inputs, never portfolio balances or credentials.
// SQLite data_version invalidates after a source refresh; each map is bounded.
const sourceCaches=new WeakMap();
function cacheFor(source) {
  const generation=`${source.db.prepare('PRAGMA data_version').get().data_version}:${source.db.prepare('SELECT total_changes() n').get().n}`;
  let c=sourceCaches.get(source);
  if(!c||c.generation!==generation){c={generation,models:new Map(),snapshots:new Map(),series:new Map()};sourceCaches.set(source,c);}
  return c;
}
function remember(map,key,value,limit){if(map.size>=limit)map.delete(map.keys().next().value);map.set(key,value);return value;}
export function portfolioValuations(source,date,tickers=null) {
  const cache=cacheFor(source).models;
  const selected=tickers?[...new Set(tickers.filter(Boolean))].sort():null;
  const requested=selected?[...new Set(selected.flatMap(t=>t==='GOOG'?['GOOG','GOOGL']:[t]))]:null;
  const key=selected?`${date}:${selected.join(',')}`:`${date}:*`;
  if(cache.has(key))return cache.get(key);
  const models=opportunityValuations(source,date,requested);
  // Reuse the platform's reviewed share-class map, not a fuzzy ticker guess.
  if(!models.has('GOOG')&&sp500CanonicalTicker('GOOG')==='GOOGL'&&models.get('GOOGL')?.currency==='USD')
    models.set('GOOG',{...models.get('GOOGL'),modelTicker:'GOOGL',claimPolicy:'Shared Alphabet economic per-share model; no voting-rights premium modelled.'});
  return remember(cache,key,models,64);
}
export function returnStatistics(returns,benchmark,{riskFreeRate=.04,minObservations=60}={}) {
  if(returns.length!==benchmark.length||returns.length<minObservations||!returns.every(x=>finite(x)&&x>-1)||!benchmark.every(x=>finite(x)&&x>-1))return {status:'insufficient_aligned_returns',observations:returns.length};
  const sd=Math.sqrt(variance(returns)),bs=Math.sqrt(variance(benchmark));
  const dailyRf=(1+riskFreeRate)**(1/252)-1;
  let value=1,peak=1,maxDrawdown=0;
  for(const r of returns){value*=1+r;peak=Math.max(peak,value);maxDrawdown=Math.min(maxDrawdown,value/peak-1);}
  return {status:'ready',observations:returns.length,totalReturn:value-1,cagr:value**(252/returns.length)-1,
    volatility:sd*Math.sqrt(252),sharpe:sd>0?(mean(returns)-dailyRf)/sd*Math.sqrt(252):null,
    beta:bs>0?covariance(returns,benchmark)/(bs*bs):null,
    correlation:sd>0&&bs>0?covariance(returns,benchmark)/(sd*bs):null,maxDrawdown,
    trackingError:Math.sqrt(variance(returns.map((r,i)=>r-benchmark[i])))*Math.sqrt(252),riskFreeRate};
}

// Conservative research proxy: common dates, dividend-adjusted observations,
// an explicit fixed covered sleeve. Never reweight on each missing-data day.
export function holdingRisk(group,series,asOf,{riskFreeRate=.04}={}) {
  const bench=series.get('SPY')??[];
  const cutoff=new Date(asOf+'T00:00:00Z');cutoff.setUTCDate(cutoff.getUTCDate()-366);
  const start=cutoff.toISOString().slice(0,10);
  const points=bench.filter(p=>p.date>=start&&p.date<=asOf&&positive(p.adjustedClose));
  const result={status:'insufficient_benchmark',scope:'covered_usd_long_sleeve',notActualPerformance:true,
    benchmark:'SPY',returnBasis:'dividend_adjusted_close',riskFreeRate,riskFreeRateBasis:'user-adjustable assumption; not a fetched yield',
    requestedEnd:asOf,start:points[0]?.date??null,end:points.at(-1)?.date??null,excluded:[],included:[],curve:[],
    limitations:['Current report weights, rebalanced daily in a retrospective simulation. No ownership claim for those dates.',
      'Options, shorts, foreign-currency assets, margin interest, fees and taxes excluded. Not whole-account Beta or Sharpe.']};
  if(points.length<61)return result;
  const spyReturns=points.slice(1).map((p,i)=>p.adjustedClose/points[i].adjustedClose-1);
  const byTicker=new Map();
  for(const p of group.positions) {
    if(p.kind==='cash'||p.assetCategory==='ACCRUAL')continue;
    if(p.kind!=='equity'||p.currency!=='USD'||p.value<=0||!positive(p.value)) {result.excluded.push({ticker:p.ticker,value:p.value,reason:'outside_usd_long_sleeve'});continue;}
    const old=byTicker.get(p.ticker);
    byTicker.set(p.ticker,{ticker:p.ticker,value:(old?.value??0)+p.value});
  }
  const valid=[];
  for(const p of byTicker.values()) {
    const rows=series.get(p.ticker)??[], map=new Map(rows.map(r=>[r.date,r.adjustedClose]));
    const missing=points.filter(r=>!positive(map.get(r.date))).length;
    if(missing){result.excluded.push({...p,reason:'incomplete_common_date_history',missingSessions:missing});continue;}
    valid.push({...p,returns:points.slice(1).map((r,i)=>map.get(r.date)/map.get(points[i].date)-1)});
  }
  const total=sum(valid.map(p=>p.value));
  result.coverage=ratio(total,group.longValue);
  result.coveredValue=total;
  result.coverageDenominator='known positive non-cash report marks';
  if(!positive(total)){result.status='no_complete_holding_history';return result;}
  const returns=spyReturns.map((_,i)=>sum(valid.map(p=>p.value/total*p.returns[i])));
  result.included=valid.map(p=>({ticker:p.ticker,weight:p.value/total,value:p.value,
    ...returnStatistics(p.returns,spyReturns,{riskFreeRate})}));
  result.metrics=returnStatistics(returns,spyReturns,{riskFreeRate});
  result.benchmarkMetrics=returnStatistics(spyReturns,spyReturns,{riskFreeRate});
  result.status=result.metrics.status;
  let pv=1,bv=1;result.curve=[{date:points[0].date,portfolio:1,benchmark:1}];
  for(let i=0;i<returns.length;i++){pv*=1+returns[i];bv*=1+spyReturns[i];result.curve.push({date:points[i+1].date,portfolio:pv,benchmark:bv});}
  return result;
}

export function weightedValue(rows,models,prices,date) {
  const covered=[],excluded=[];let eligible=0,priced=0,delta=0,fullWeight=0;
  for(const r of rows) {
    if(!positive(r.weight))continue;
    fullWeight+=r.weight;
    const m=models.get(r.ticker),p=prices.get(r.ticker);
    let reason=!p||!positive(p.value)||p.date!==date?'missing_exact_date_price':p.currency!=='USD'?'currency_mismatch':null;
    if(!reason)priced+=r.weight;
    if(!reason)reason=!m||!positive(m.fairValue)||!dated(m.date)||m.date>date?'no_dated_model':m.currency!=='USD'?'currency_mismatch':null;
    if(reason){excluded.push({ticker:r.ticker,weight:r.weight,reason});continue;}
    const gap=m.fairValue/p.value-1;eligible+=r.weight;delta+=r.weight*gap;
    covered.push({...r,price:p.value,fairValue:m.fairValue,modelDate:m.date,gap,contribution:r.weight*gap});
  }
  return {gap:ratio(delta,eligible),coverage:ratio(eligible,fullWeight),coveredWeight:eligible,totalWeight:fullWeight,
    priceCoverage:ratio(priced,fullWeight),coveredCount:covered.length,totalCount:rows.length,
    markedRemainderGap:ratio(delta,fullWeight),covered,excluded,
    formula:'sum(w × (fair value / price − 1)) / sum(covered w)'};
}

export function portfolioMarketContext(source,analysis,payload,asOf,{riskFreeRate=.04,spyUniverse}={}) {
  const symbols=new Set(['SPY',...analysis.groups.flatMap(g=>g.positions.filter(p=>p.kind==='equity'&&p.currency==='USD').map(p=>p.ticker))]);
  const series=new Map(),cache=cacheFor(source);
  const start=new Date(Date.parse(asOf+'T00:00:00Z')-367*86400000).toISOString().slice(0,10);
  const query=source.db.prepare("SELECT date,adjusted_close adjustedClose FROM price_points WHERE symbol=? AND date BETWEEN ? AND ? AND source LIKE 'sharadar_fact_os_%' ORDER BY date");
  for(const t of symbols) {
    const key=`${t}:${start}:${asOf}`;
    series.set(t,cache.series.get(key)??remember(cache.series,key,query.all(t,start,asOf),160));
  }
  for(const g of analysis.groups) {
    g.risk=g.currency==='USD'?holdingRisk(g,series,asOf,{riskFreeRate}):{status:'base_currency_not_supported',excluded:[],curve:[]};
    const accounts=payload.analysisAccounts.filter(a=>a.currency===g.currency);
    g.actualPerformance={status:'cash_flow_adjusted_history_required',navPointCount:sum(accounts.map(a=>a.navHistory?.length??0)),
      navHistory:accounts.length===1?accounts[0].navHistory??[]:[],metrics:null,
      reason:'NAV level changes include deposits/withdrawals. No actual-account Sharpe or Beta is inferred from NAV alone.'};
    g.leverage={grossToNav:ratio(g.grossExposure,g.reportedNav),longToNav:ratio(g.longValue,g.reportedNav),
      borrowing:Math.max(0,-g.cash),borrowingToNav:ratio(Math.max(0,-g.cash),g.reportedNav),
      shortOptions:g.positions.filter(p=>p.assetCategory==='OPT'&&p.quantity<0).length};
  }
  const universe=spyUniverse??JSON.parse(fs.readFileSync(new URL('./config/sp500-valuation-universe.json',import.meta.url),'utf8'));
  const date=universe.sources?.officialSpyHoldingsAsOf;
  if(!date||date>asOf||String(universe.generatedAt).slice(0,10)>asOf) {
    analysis.benchmarkValuation={status:'no_pit_constituent_weights',ticker:'SPY'};return analysis;
  }
  const rows=universe.companies.flatMap(c=>c.shareClasses??[]).map(c=>({ticker:c.ticker,weight:c.spyWeightPct/100}));
  const models=portfolioValuations(source,date),prices=new Map();
  const pq=source.db.prepare("SELECT json_extract(payload_json,'$.currency') currency,json_extract(payload_json,'$.priceHistory') history FROM valuation_ticker_snapshots WHERE ticker=?");
  for(const t of new Set([...rows.map(r=>r.ticker),...symbols])) {
    let r=cache.snapshots.get(t);
    if(!cache.snapshots.has(t)) {
      const raw=pq.get(t);
      r=raw?{currency:raw.currency,prices:new Map(JSON.parse(raw.history??'[]').map(p=>[p.date,p]))}:null;
      remember(cache.snapshots,t,r,900);
    }
    const p=r?.prices.get(date);
    if(p)prices.set(t,{value:p.close,date,currency:r.currency});
    else {
      const usd=universe.companies.some(c=>c.currency==='USD'&&c.shareClasses?.some(s=>s.ticker===t))||analysis.groups.some(g=>g.positions.some(p=>p.ticker===t&&p.currency==='USD'));
      const raw=usd?source.db.prepare("SELECT close FROM price_points WHERE symbol=? AND date=? AND source LIKE 'sharadar_fact_os_%'").get(t,date):null;
      if(positive(raw?.close))prices.set(t,{value:raw.close,date,currency:'USD'});
    }
  }
  analysis.benchmarkValuation={status:'ready',ticker:'SPY',weightDate:date,priceDate:date,availableAt:String(universe.generatedAt).slice(0,10),
    source:universe.sources.officialSpyHoldings,method:'Exact SPY security-class weights. Covered components only; no synthetic ETF DCF.',
    ...weightedValue(rows,models,prices,date)};
  for(const g of analysis.groups) {
    const entries=g.positions.filter(p=>p.kind==='equity'&&p.quantity>0&&p.currency==='USD'&&p.value>0);
    // Retain original reported weights. Snapshot weights and ratio date are
    // distinct and visible; this is not a historical account reconstruction.
    g.benchmarkComparison={scope:'reported_usd_long_equity_weights',priceDate:date,reportDates:g.reportDates,
      ...weightedValue(entries.map(p=>({ticker:p.ticker,weight:p.value})),models,prices,date)};
    g.benchmarkComparison.difference=g.benchmarkComparison.gap!==null&&analysis.benchmarkValuation.gap!==null?g.benchmarkComparison.gap-analysis.benchmarkValuation.gap:null;
  }
  return analysis;
}
