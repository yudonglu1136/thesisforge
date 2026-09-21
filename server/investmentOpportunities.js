import { gurus } from './gurus.js';
import { is13fCommonLongHolding } from './thirteenF.js';
import { assert, finite, change, isoDate, signature } from './investmentMath.js';
import { tickerKey } from './investmentSource.js';
import { valueTrend } from './investmentValueTrend.js';
import { valuationModelRoute } from './valuationModelRoute.js';
import { opportunityQuality } from './investmentQuality.js';
import { investmentCurrentQuotes,preferInvestmentQuote } from './investmentPrices.js';
import { institutional13fInsightDetail } from './institutional13fInsights.js';

const parse = r => r ? JSON.parse(r.payload_json) : null;
const scalar = v => finite(v) ? v : null;
const sumKnown = (a,b) => finite(a)&&finite(b)?a+b:null;
const readCaches=new WeakMap();
const median = a => { const s=a.filter(finite).sort((a,b)=>a-b); return s.length ? (s[Math.floor((s.length-1)/2)]+s[Math.floor(s.length/2)])/2 : null; };
const common = h => h.holdingBucket ? h.holdingBucket==='common_long' : String(h.id??'').endsWith('-COMMON') && (!h.shareType || is13fCommonLongHolding(h));
const symbol = h => /^[A-Z][A-Z0-9.-]{0,14}$/.test(h.ticker??'') ? h.ticker : null;
const boundedText = (value,limit=160) => typeof value==='string'?value.slice(0,limit):null;

function bounded13fResearchEvidence(value) {
  if(!value||typeof value!=='object'||Array.isArray(value))return null;
  const number=value=>finite(value)?value:null;
  const evidence=Object.fromEntries(['breadth','shares','weights'].flatMap(key=>{
    const row=value.evidence?.[key];
    return row&&typeof row==='object'&&!Array.isArray(row)?[[key,Object.fromEntries(
      Object.entries(row).slice(0,12).map(([field,item])=>[boundedText(field,60),
        typeof item==='string'?boundedText(item):number(item)]).filter(([field])=>field)
    )]]:[];
  }));
  const importantChanges=Array.isArray(value.importantChanges)?value.importantChanges.slice(0,10).map(row=>({
    investorId:boundedText(row?.investorId,80),name:boundedText(row?.name,160),
    action:boundedText(row?.action,40),unitsChangeK:number(row?.unitsChangeK),
    currentWeight:number(row?.currentWeight),previousWeight:number(row?.previousWeight),
    weightChangeBps:number(row?.weightChangeBps),
    continuity:boundedText(row?.continuity,60),
    consecutiveDirectionQuarters:number(row?.consecutiveDirectionQuarters),
    tags:Array.isArray(row?.tags)?row.tags.slice(0,6).map(tag=>boundedText(tag,60)).filter(Boolean):[],
  })).filter(row=>row.investorId&&row.name):[];
  return {
    kind:'institutional_13f_analysis',methodVersion:boundedText(value.methodVersion,80),
    headlineKey:boundedText(value.headlineKey,80),reportDate:boundedText(value.reportDate,10),
    previousReportDate:boundedText(value.previousReportDate,10),availableAt:boundedText(value.availableAt,32),
    evidence,importantChanges,
  };
}

function current13fResearchEvidence(source,ticker,asOf) {
  try {
    const detail=institutional13fInsightDetail(source,ticker,asOf),analysis=detail.details?.analysis;
    if(!analysis)return null;
    return bounded13fResearchEvidence({
      ...analysis,reportDate:detail.reportDate,previousReportDate:detail.previousReportDate,
      availableAt:detail.availableAt,
    });
  } catch(error) {
    if(error?.status===422||String(error?.message??'').startsWith('institutional_13f_'))return null;
    throw error;
  }
}

// Read model only. Never imports filings, changes valuations, or refreshes curves.
export function opportunityBooks(source, asOf, reportDate = null) {
  isoDate(asOf); if(reportDate)isoDate(reportDate);
  const catalog=source.guruCatalog();
  const configured=new Map(gurus.map(g=>[g.id,g]));
  // Opportunities is the complete covered institutional tape, not the
  // concentrated-manager consensus screen. Broad systematic books remain in
  // this ranking because the user is explicitly asking who reported each
  // quarterly change; their style caveats stay attached to the Guru profile.
  const eligible=catalog.filter(g=>configured.get(g.id)?.type==='manager13f');
  const histories=eligible.map(g=>({g,history:source.guruHistory(g.id,asOf)}));
  const quarters=[...new Set(histories.flatMap(x=>x.history.map(h=>h.reportDate)))].sort().reverse();
  const selected=reportDate??quarters[0]??null;
  assert(!reportDate || quarters.includes(reportDate),'report_quarter_not_available');
  const snapshots=new Map(source.db.prepare('SELECT guru_id,payload_json FROM guru_snapshots').all().map(r=>[r.guru_id,parse(r)]));
  const books=[];
  for(const {g,history} of histories) {
    const filing=history.filter(h=>h.reportDate===selected).at(-1); if(!filing)continue;
    const snap=snapshots.get(g.id), meta=snap?.summary??{};
    // Accession match prevents an older same-quarter filing from impersonating
    // an amendment. No latest-snapshot data is used before public availability.
    const full=meta.reportDate===filing.reportDate && meta.filingDate<=asOf &&
      snap?.latestFiling?.accessionNumber===filing.accessionNumber;
    const holdings=(full?snap.holdings:filing.topHoldings)??[];
    const activity=(full?snap.activity:filing.largestChanges)??[];
    books.push({guru:g,filing,full,reportedPositionCount:full?meta.totalPositions:filing.positionCount,
      holdings:holdings.filter(common),activity:activity.filter(common)});
  }
  return {asOf,reportDate:selected,quarters,eligibleManagers:eligible.length,books};
}

export function opportunityValuations(source,asOf,tickers=null) {
  const selected=tickers?.map(tickerKey)??null;
  if(selected?.length===0)return new Map();
  const tickerClause=selected?` AND ticker IN (${selected.map(()=>'?').join(',')})`:'';
  // Bounded scalar extraction: no per-stock company()/transcript blob loading.
  const rows=source.db.prepare(`WITH visible AS (
    SELECT rowid rid,ticker,as_of_date,model_version,
      ROW_NUMBER() OVER(PARTITION BY ticker ORDER BY as_of_date DESC,model_version DESC,fiscal_period DESC,rowid DESC) n,
      ROW_NUMBER() OVER(PARTITION BY ticker,fiscal_period ORDER BY as_of_date DESC,model_version DESC,rowid DESC) quarter_n
    FROM valuation_pit_model_runs WHERE as_of_date<=?${tickerClause} AND financial_available_at<=as_of_date
      AND (guidance_max_observed_at IS NULL OR guidance_max_observed_at<=as_of_date)),
    quarters AS (SELECT rid,ROW_NUMBER() OVER(PARTITION BY ticker ORDER BY as_of_date DESC,model_version DESC,rid DESC) qn
      FROM visible WHERE quarter_n=1)
    SELECT p.ticker,p.as_of_date,p.model_version,p.fiscal_period,n,qn,
      json_extract(output_json,'$.fairValue') fairValue,
      COALESCE(json_extract(input_json,'$.valuationSemantics.fairValueFormula'),json_extract(output_json,'$.method')) formula,
      json_extract(input_json,'$.sourceRecord.currency') currency,
      json_extract(input_json,'$.financial.revenue_growth_pct') revenueGrowth,
      json_extract(input_json,'$.valuationSemantics.scoreInputs') score
    FROM visible JOIN valuation_pit_model_runs p ON p.rowid=visible.rid
      LEFT JOIN quarters ON quarters.rid=visible.rid
    WHERE n<=2 OR qn<=8 ORDER BY p.ticker,n`).all(asOf,...(selected??[]));
  const result=new Map();
  const histories=new Map();
  for(const r of rows) {
    r.modelRoute=valuationModelRoute(JSON.parse(r.score??'{}'));
    if(r.qn!=null && r.qn<=8) {
      if(!histories.has(r.ticker))histories.set(r.ticker,[]);
      histories.get(r.ticker).push({period:r.fiscal_period,date:r.as_of_date,fairValue:scalar(r.fairValue),
        modelVersion:r.model_version,formula:r.formula,currency:r.currency,modelRoute:r.modelRoute});
    }
    if(r.n===1)result.set(r.ticker,{fairValue:scalar(r.fairValue),date:r.as_of_date,modelVersion:r.model_version,formula:r.formula,currency:r.currency,modelRoute:r.modelRoute,revenueGrowth:finite(r.revenueGrowth)?r.revenueGrowth/100:null,change:null,comparable:false});
    else if(r.n===2) {
      const v=result.get(r.ticker);
      v.comparable=!!v.modelVersion && !!v.formula && !!v.currency && v.date>r.as_of_date &&
        v.modelVersion===r.model_version && v.formula===r.formula && v.currency===r.currency;
      v.change=v.comparable?change(v.fairValue,r.fairValue):null;
      v.previousDate=r.as_of_date;
      // Preserve the observed endpoint, never reverse-engineer it from a
      // rounded percentage. Comparison remains gated by method/currency/version.
      v.previousFairValue=scalar(r.fairValue);
    }
  }
  for(const [ticker,v] of result)v.trend=valueTrend((histories.get(ticker)??[]).reverse(),asOf);
  return result;
}

// Extract only the dated price series, not the large transcripts and model
// history in each snapshot. No current quote is substituted for a missing date.
function opportunityPrices(source,tickers,asOf) {
  const result=new Map();
  if(!tickers.length)return result;
  const rows=source.db.prepare(`SELECT ticker,
    json_extract(payload_json,'$.currency') currency,
    json_extract(payload_json,'$.priceSource') source,
    json_extract(payload_json,'$.priceHistory') history
    FROM valuation_ticker_snapshots WHERE ticker IN (${tickers.map(()=>'?').join(',')})`).all(...tickers);
  for(const r of rows) {
    const p=(JSON.parse(r.history??'[]')).filter(p=>p.date<=asOf&&finite(p.close)&&p.close>0).sort((a,b)=>a.date.localeCompare(b.date)).at(-1);
    result.set(r.ticker,{value:p?.close??null,date:p?.date??null,currency:r.currency,
      source:p?(p.source??r.source??'stored ticker prices'):null,adjustment:'stored published close; no rescaling'});
  }
  for(const [ticker,quote] of investmentCurrentQuotes(source,tickers,asOf))
    result.set(ticker,preferInvestmentQuote(quote,result.get(ticker)??{value:null,date:null,source:null,currency:null}));
  return result;
}

export function opportunityCompanySummary(source,ticker,asOf) {
  ticker=tickerKey(ticker);isoDate(asOf);
  const valuation=opportunityValuations(source,asOf,[ticker]).get(ticker)??null;
  const price=opportunityPrices(source,[ticker],asOf).get(ticker)??
    {value:null,date:null,source:null,currency:null};
  const comparable=finite(valuation?.fairValue)&&valuation.fairValue>0&&finite(price.value)&&price.value>0&&
    !!valuation?.currency&&valuation.currency===price.currency;
  return {ticker,asOf,price,valuation,
    modelGap:comparable?change(valuation.fairValue,price.value):null,
    valuationStatus:!finite(valuation?.fairValue)||valuation.fairValue<=0?'not_modeled':
      !finite(price.value)||price.value<=0?'price_unavailable':!comparable?'currency_unverified':'available',
    events:opportunityTimeline(source,ticker,asOf)};
}

// Shared by Discover and the owner's portfolio. Public evidence only; no
// valuation/quality universe needs to be loaded just to inspect Guru ownership.
export function opportunityOwnership(books) {
  const byTicker=new Map();
  for(const b of books) {
    const claims=new Map();
    // Identity is exact CUSIP/common claim. Multiple rows are summed only in
    // holdings, never by concatenating holdings and changes (double count).
    for(const h of b.holdings) {
      if(!symbol(h) || !finite(h.shares) || h.shares<=0)continue;
      const id=h.cusip??h.id, previous=claims.get(id);
      if(previous && previous.ticker!==h.ticker)continue;
      const weight=scalar(h.pctCommonLong??h.pctPortfolio);
      claims.set(id,{...h,shares:(previous?.shares??0)+h.shares,value:previous?sumKnown(previous.value,h.value):scalar(h.value),weight:previous?sumKnown(previous.weight,weight):weight});
    }
    for(const h of b.activity??[])if(symbol(h) && h.action==='sold_out' && !claims.has(h.cusip??h.id))claims.set(h.cusip??h.id,{...h,weight:0});
    const perTicker=new Map();
    for(const [id,h] of claims) {
      const a=(b.activity??[]).find(x=>(x.cusip??x.id)===id), old=perTicker.get(h.ticker);
      if(old) {old.shares=sumKnown(old.shares,h.shares);old.value=sumKnown(old.value,h.value);old.weight=sumKnown(old.weight,h.weight);old.claims.push(id);old.action='mixed_claims';old.changeShares=null;continue;}
      perTicker.set(h.ticker,{guruId:b.guru.id,name:b.guru.name,avatar:b.guru.avatar,ticker:h.ticker,issuer:h.issuer,
        claims:[id],shares:scalar(h.shares),value:scalar(h.value),weight:h.weight,
        changeShares:scalar(a?.changeShares),previousShares:scalar(a?.prevShares),action:a?.action??'reported_holding',
        comparisonStatus:a?.corporateActionAdjusted===true?'adjusted':'corporate_action_unverified',
        reportDate:b.filing.reportDate,availableAt:b.filing.filingDate,accession:b.filing.accessionNumber,
        sourceUrl:b.filing.filing?.secUrl??null,coverage:b.full?'full_current_book':'historical_extract'});
    }
    for(const e of perTicker.values()) {
      const row=byTicker.get(e.ticker)??{ticker:e.ticker,name:e.issuer,managers:[]};row.managers.push(e);byTicker.set(e.ticker,row);
    }
  }
  return byTicker;
}

// The Guru consensus matrix needs ownership only. Keeping it on the full
// opportunities route used to make first paint wait for every PIT valuation,
// quality factor and price history (roughly 40x the actual ownership work on
// the production snapshot).
export function buildGuruHoldingsMatrix(source,asOf,reportDate=null) {
  const generation=source.db.prepare('PRAGMA data_version').get().data_version;
  let cache=readCaches.get(source);
  if(!cache||cache.generation!==generation){cache={generation,rows:new Map()};readCaches.set(source,cache);}
  const key=`guru-matrix:${asOf}:${reportDate??''}`;
  if(cache.rows.has(key))return structuredClone(cache.rows.get(key));
  const data=opportunityBooks(source,asOf,reportDate), byTicker=opportunityOwnership(data.books);
  const rows=[...byTicker.values()].map(row=>{
    const held=row.managers.filter(m=>m.shares>0);
    const newPositions=row.managers.filter(m=>m.action==='new').length;
    const increases=row.managers.filter(m=>m.action==='increased').length;
    const reductions=row.managers.filter(m=>m.action==='reduced').length;
    const exits=row.managers.filter(m=>m.action==='sold_out').length;
    return {...row,managerCount:held.length,medianWeight:median(held.map(m=>m.weight)),
      newPositions,increases,reductions,exits,adds:newPositions+increases,trims:reductions+exits};
  }).sort((a,b)=>b.managerCount-a.managerCount || (b.medianWeight??0)-(a.medianWeight??0) || a.ticker.localeCompare(b.ticker));
  const result={version:'guru-holdings-matrix-v1',asOf,reportDate:data.reportDate,quarters:data.quarters,
    coverage:{eligibleManagers:data.eligibleManagers,reportedManagers:data.books.length,fullBooks:data.books.filter(b=>b.full).length,
      extractedBooks:data.books.filter(b=>!b.full).length,total:rows.length,
      scope:data.books.every(b=>b.full)?'full_current_books':'includes_historical_extracts'},rows};
  if(cache.rows.size>=8)cache.rows.delete(cache.rows.keys().next().value);
  cache.rows.set(key,result);return structuredClone(result);
}

export function buildOpportunities(source,asOf,reportDate=null) {
  const generation=source.db.prepare('PRAGMA data_version').get().data_version;
  let cache=readCaches.get(source);
  if(!cache||cache.generation!==generation){cache={generation,rows:new Map()};readCaches.set(source,cache);}
  const key=`${asOf}:${reportDate??''}`;
  if(cache.rows.has(key))return structuredClone(cache.rows.get(key));
  const data=opportunityBooks(source,asOf,reportDate), byTicker=opportunityOwnership(data.books);
  const valuations=opportunityValuations(source,asOf);
  const quality=opportunityQuality(source,asOf);
  const prices=opportunityPrices(source,[...byTicker.keys()],asOf);
  const rows=[...byTicker.values()].map(row=>{
    const held=row.managers.filter(m=>m.shares>0),v=valuations.get(row.ticker)??null;
    const price=prices.get(row.ticker)??{value:null,date:null,source:null,currency:null};
    const comparable=finite(v?.fairValue)&&v.fairValue>0&&finite(price.value)&&price.value>0&&!!v?.currency && v.currency===price.currency;
    const newPositions=row.managers.filter(m=>m.action==='new').length;
    const increases=row.managers.filter(m=>m.action==='increased').length;
    const reductions=row.managers.filter(m=>m.action==='reduced').length;
    const exits=row.managers.filter(m=>m.action==='sold_out').length;
    return {...row,managerCount:held.length,medianWeight:median(held.map(m=>m.weight)),
      // Keep the two legacy aggregates for existing consumers, while exposing
      // the four mutually exclusive reported actions needed by the quarterly
      // institutional-moves ranking. These remain disclosure observations,
      // never inferred trades.
      newPositions,increases,reductions,exits,
      adds:newPositions+increases,
      trims:reductions+exits,
      price,valuation:v,quality:quality.get(row.ticker)??{status:'unavailable',years:[]},modelGap:comparable?change(v.fairValue,price.value):null,
      valuationStatus:!finite(v?.fairValue)||v.fairValue<=0?'not_modeled':!finite(price.value)||price.value<=0?'price_unavailable':!comparable?'currency_unverified':'available'};
  }).sort((a,b)=>b.managerCount-a.managerCount || (b.medianWeight??0)-(a.medianWeight??0) || a.ticker.localeCompare(b.ticker));
  const activity={
    newPositions:rows.reduce((n,r)=>n+r.newPositions,0),
    increases:rows.reduce((n,r)=>n+r.increases,0),
    reductions:rows.reduce((n,r)=>n+r.reductions,0),
    exits:rows.reduce((n,r)=>n+r.exits,0)
  };
  const result={version:'guru-valuation-discovery-v1',asOf,reportDate:data.reportDate,quarters:data.quarters,
    coverage:{eligibleManagers:data.eligibleManagers,reportedManagers:data.books.length,fullBooks:data.books.filter(b=>b.full).length,
      extractedBooks:data.books.filter(b=>!b.full).length,modelled:rows.filter(r=>r.valuationStatus==='available').length,
      total:rows.length,activity,scope:data.books.every(b=>b.full)?'full_current_books':'includes_historical_extracts'},rows};
  if(cache.rows.size>=4)cache.rows.delete(cache.rows.keys().next().value);
  cache.rows.set(key,result);return structuredClone(result);
}

export function opportunityTimeline(source,ticker,asOf) {
  ticker=tickerKey(ticker);isoDate(asOf);
  const events=[];
  const included=new Set(gurus.filter(g=>g.type==='manager13f').map(g=>g.id));
  for(const g of source.guruCatalog().filter(g=>included.has(g.id)))for(const f of source.guruHistory(g.id,asOf)) {
    const h=[...(f.topHoldings??[]),...(f.largestChanges??[])].find(h=>common(h)&&h.ticker===ticker);
    if(!h)continue;
    events.push({id:`${g.id}:${f.accessionNumber}`,guruId:g.id,name:g.name,date:f.filingDate,reportDate:f.reportDate,
      accession:f.accessionNumber,shares:scalar(h.shares),weight:scalar(h.pctPortfolio),action:h.action??'reported_holding'});
  }
  return events.sort((a,b)=>b.date.localeCompare(a.date)||a.name.localeCompare(b.name));
}

export function watchBaseline(source,ticker,asOf,reportDate) {
  const row=buildOpportunities(source,asOf,reportDate).rows.find(r=>r.ticker===ticker);
  let c=null,unavailable=null;
  try {c=source.company(ticker,asOf);}catch(e){if(e.status!==422)throw e;unavailable=e.message;}
  assert(row||c,'unknown_watch_company');
  return {asOf,reportDate:reportDate??row?.managers[0]?.reportDate??null,price:c?.snapshot.price??row?.price??null,
    published:c?.published??null,snapshot:c?.snapshot??null,unavailable,evidence:row?.managers??[],
    // Frozen platform model is not a user-endorsed assumption set.
    baselineKind:'published_model_observation_not_personal_scenario'};
}

export function reviewWatch(service,owner,id,date) {
  const watch=service.store.get(owner,id,'watch'),asOf=service.date(date);
  assert(asOf>=watch.baseline.asOf,'review_before_watch');
  const now=watchBaseline(service.source,watch.ticker,asOf,null),then=watch.baseline;
  const latest=service.store.list(owner,'watch_review').filter(r=>r.watchId===id&&r.asOf<=asOf).at(-1);
  const compared=latest?.baseline??then;
  const comparable=!!then.published && !!now.published && then.published.modelVersion===now.published.modelVersion &&
    then.published.formula===now.published.formula && then.snapshot?.base.currency===now.snapshot?.base.currency;
  const priceComparable=!!then.price?.currency&&then.price.currency===now.price?.currency;
  const newFilings=now.evidence.filter(e=>!compared.evidence.some(o=>o.guruId===e.guruId&&o.accession===e.accession));
  const financialChanged=now.snapshot?.source.hash!==compared.snapshot?.source.hash;
  const institutionalEvidence=watch.origin==='13f_insight'
    ?current13fResearchEvidence(service.source,watch.ticker,asOf):null;
  const institutionalChanged=!!institutionalEvidence&&institutionalEvidence.reportDate!==watch.researchEvidence?.reportDate;
  return {watch,asOf,now,newFilings,financialChanged,institutionalEvidence,institutionalChanged,comparable,
    modelChange:comparable?change(now.published.fairValue,then.published.fairValue):null,
    priceChange:priceComparable?change(now.price?.value,then.price?.value):null,
    metrics:['revenueGrowth','operatingMargin','fcfMargin'].map(key=>({key,then:then.snapshot?.metrics[key]??null,now:now.snapshot?.metrics[key]??null})),
    status:now.unavailable?'data_unavailable':newFilings.length||financialChanged||institutionalChanged?'new_evidence':'unchanged',
    lastReviewedAt:latest?.asOf??null,comparisonId:signature({id,asOf,now,institutionalEvidence})};
}

export function saveWatch(service,owner,body) {
  const ticker=tickerKey(body.ticker),asOf=service.date(body.asOf);
  return service.store.write(owner,'watch',ticker,body.operationId,body,()=>({baseline:watchBaseline(service.source,ticker,asOf,body.reportDate??null),
    origin:['holdings','adds','trims','value','13f_insight'].includes(body.origin)?body.origin:'holdings',
    researchEvidence:body.origin==='13f_insight'?bounded13fResearchEvidence(body.researchEvidence):null,
    retrospective:true}));
}

export function saveWatchReview(service,owner,body) {
  const r=reviewWatch(service,owner,body.watchId,body.asOf);
  assert(r.comparisonId===body.comparisonId,'watch_comparison_changed');
  const last=service.store.list(owner,'watch_review').filter(x=>x.watchId===body.watchId).at(-1);
  assert(!last||last.asOf<=r.asOf,'review_date_regression');
  return service.store.write(owner,'watch_review',r.watch.ticker,body.operationId,body,()=>({watchId:body.watchId,asOf:r.asOf,baseline:r.now}));
}
