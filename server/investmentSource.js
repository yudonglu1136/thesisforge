import { DatabaseSync } from 'node:sqlite';
import { assert, finite, ratio, change, isoDate, signature, percentile, personalScenarioPackage } from './investmentMath.js';
import { researchGuidanceReview } from './investmentGuidance.js';
import { valuationModelRoute } from './valuationModelRoute.js';
import { investmentCurrentQuotes,preferInvestmentQuote } from './investmentPrices.js';
import { gurus, guruIsVisible } from './gurus.js';
import { guruCapitalStructure } from './guruCapitalStructures.js';
import path from 'node:path';
import { releaseRoot,releaseResource,dataReleaseId } from './dataReleaseContext.js';
import { marketFactsVersion,marketPriceHistory } from './investmentMarketContext.js';

export const SOURCE_ADAPTER_VERSION='investment-pit-adapter-v1';
const metricNames=['revenueGrowth','operatingMargin','fcfMargin','capexIntensity'];
const readJson=r=>r?JSON.parse(r.payload_json):null;
const compare=(a,b)=>a<b?-1:a>b?1:0;
export function tickerKey(value) {
  const t=String(value??'').trim().toUpperCase();
  assert(/^[A-Z][A-Z0-9.-]{0,14}$/.test(t),'invalid_ticker'); return t;
}
export function assertLineage(input, asOf) {
  function visit(value) {
    if(!value || typeof value!=='object') return;
    for(const [key,v] of Object.entries(value)) {
      if(['datekey','filed','observedAt','rateDate','availableAt'].includes(key) && v) assert(String(v).slice(0,10)<=asOf,'future_source_evidence');
      else if(typeof v==='object') visit(v);
    }
  }
  visit(input);
}
export function sourceNode(row) {
  const input=JSON.parse(row.input_json),output=JSON.parse(row.output_json);
  assert(row.financial_available_at<=row.as_of_date && (!row.guidance_max_observed_at||row.guidance_max_observed_at<=row.as_of_date),'future_model_input');
  assertLineage(input,row.as_of_date);
  const t=input.trailingTwelveMonths??{},f=input.financial??{},record=input.sourceRecord??{};
  const metric=(v)=>finite(v)?v:null;
  const periodEnd=record.reportperiod??record.calendardate??record.periodEndDate;
  assert(typeof periodEnd==='string' && periodEnd<=row.as_of_date,'missing_period_end');
  isoDate(periodEnd);
  return {period:row.fiscal_period,periodEnd,availableAt:row.as_of_date,filingDate:row.financial_available_at,
    metrics:{revenueGrowth:metric(f.revenue_growth_pct)===null?null:f.revenue_growth_pct/100,
      operatingMargin:ratio(t.operating_income_m,t.revenue_m),fcfMargin:ratio(t.fcf_after_capex_m,t.revenue_m),capexIntensity:ratio(t.capex_m,t.revenue_m)},
    actual:{revenueM:metric(t.revenue_m),sharesM:metric(t.shares_m),fcfM:metric(t.fcf_after_capex_m),cfoM:metric(t.cfo_m),capexM:metric(t.capex_m),operatingIncomeM:metric(t.operating_income_m)},
    source:{dataset:record.dataset??'stored PIT model',dimension:record.dimension??null,periodEnd,availableAt:row.financial_available_at,url:output.sourceUrl??null,
      modelVersion:row.model_version,hash:signature({input,output}),record,ttmRecord:input.trailingTwelveMonthsSourceRecord??null},
    publishedFairValue:finite(output.fairValue)?output.fairValue:null,
    publishedFormula:input.valuationSemantics?.fairValueFormula??output.method??null,
    score:{...(input.valuationSemantics?.scoreInputs??{}),modelRoute:valuationModelRoute(input.valuationSemantics?.scoreInputs)},guidance:input.guidance??{},input,
  };
}

export class InvestmentSource {
  constructor(file,{insightsFile=null,publicFactsFile=null,canonicalMarket=false}={}) {
    this.canonicalMarket=canonicalMarket;
    this.db=new DatabaseSync(file,{readOnly:true});
    this.db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=3000;');
    this.baseInsightsDb=insightsFile?new DatabaseSync(insightsFile,{readOnly:true}):null;
    this.baseInsightsDb?.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=3000;');
    this.basePublicFactsDb=publicFactsFile?new DatabaseSync(publicFactsFile,{readOnly:true}):null;
    this.basePublicFactsDb?.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=3000;');
    this.companyCache=new Map(); this.cacheGeneration=null;
    this.guruExposureCache=new Map(); this.guruExposureGeneration=null;
  }
  get insightsDb(){
    const root=releaseRoot('institutional_13f',null);
    if(!root)return this.baseInsightsDb;
    return releaseResource('13f:'+root,()=>{
      const db=new DatabaseSync(path.join(root,'13f-insights.sqlite'),{readOnly:true});
      db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=3000;');return db;
    },db=>db.close());
  }
  get publicFactsDb(){
    const root=releaseRoot('public_observations',null);
    if(!root)return this.basePublicFactsDb;
    return releaseResource('observations:'+root,()=>{
      const db=new DatabaseSync(path.join(root,'observations.sqlite'),{readOnly:true});
      db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=3000;');return db;
    },db=>db.close());
  }
  close(){this.basePublicFactsDb?.close();this.baseInsightsDb?.close();this.db.close();}
  availableTickers() { return this.db.prepare('SELECT DISTINCT ticker FROM valuation_pit_model_runs ORDER BY ticker').all().map(x=>x.ticker); }
  periods(ticker,asOf) {
    ticker=tickerKey(ticker);isoDate(asOf);
    const version=this.db.prepare('SELECT model_version FROM valuation_pit_model_runs WHERE ticker=? AND as_of_date<=? ORDER BY as_of_date DESC, model_version DESC LIMIT 1').get(ticker,asOf)?.model_version;
    if(!version) return [];
    return this.db.prepare('SELECT * FROM valuation_pit_model_runs WHERE ticker=? AND as_of_date<=? AND model_version=? ORDER BY as_of_date,fiscal_period').all(ticker,asOf,version).map(sourceNode);
  }
  price(ticker,asOf,snapshot=null) {
    const s=snapshot??readJson(this.db.prepare('SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?').get(ticker));
    const prices=(s?.priceHistory??[]).filter(x=>x.date<=asOf && finite(x.close)&&x.close>0).sort((a,b)=>compare(a.date,b.date));
    const p=prices.at(-1);
    const stored=p?{value:p.close,date:p.date,source:p.source??s.priceSource??'stored ticker prices',currency:s.currency,adjustment:'stored published close; no rescaling'}:
      {value:null,date:null,source:null,currency:s?.currency??null};
    return preferInvestmentQuote(investmentCurrentQuotes(this,[ticker],asOf).get(ticker),stored);
  }
  reviewGuidance(ticker,node) {
    if(!this.db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='valuation_pit_guidance'").get())return null;
    return researchGuidanceReview({ticker,node,
      rows:this.db.prepare('SELECT * FROM valuation_pit_guidance WHERE ticker=? AND fiscal_period=? AND observed_at<=? ORDER BY observed_at,source_database,source_id')
        .all(ticker,node.period.replace(/^(\d{4})-Q([1-4])$/,'Q$2$1'),node.availableAt),
      financialRows:this.db.prepare('SELECT ticker,available_at,currency,payload_json FROM valuation_pit_financials WHERE ticker=? AND available_at<=? ORDER BY available_at DESC').all(ticker,node.availableAt)});
  }
  company(ticker,asOf) {
    ticker=tickerKey(ticker);isoDate(asOf);
    const generation=this.db.prepare('PRAGMA data_version').get().data_version+':'+(dataReleaseId()??'legacy')+':'+(marketFactsVersion()??'stored');
    if(generation!==this.cacheGeneration){this.companyCache.clear();this.cacheGeneration=generation;}
    const cacheKey=ticker+':'+asOf;
    if(this.companyCache.has(cacheKey))return structuredClone(this.companyCache.get(cacheKey));
    const history=this.periods(ticker,asOf);assert(history.length,'no_pit_research_at_date');
    const latest=history.at(-1),previous=history.at(-2);
    const snap=readJson(this.db.prepare('SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?').get(ticker));
    const currency=latest.input.sourceRecord?.currency??snap?.currency;
    const base={...latest.actual,currency};
    // Keep the published valuation separate from user-entered private forecasts.
    // Customer-cash and ownership-specific routes still require their own model.
    const currencyComparable=typeof currency==='string'&&currency===snap?.currency;
    const {templates,reconciliation}=personalScenarioPackage(base,latest.score,currencyComparable);
    const displayHistory=history.map(({input,score,guidance,...r})=>r);
    const metrics=metricNames.map(key=>({key,value:latest.metrics[key],previous:previous?.metrics[key]??null,
      change:finite(latest.metrics[key])&&finite(previous?.metrics[key])?latest.metrics[key]-previous.metrics[key]:null,
      historicalPercentile:percentile(latest.metrics[key],history.slice(-21,-1).map(x=>x.metrics[key])),sampleCount:history.slice(-21,-1).filter(x=>finite(x.metrics[key])).length,
      unit:'ratio',formula:{revenueGrowth:'quarter revenue / same fiscal quarter revenue one year earlier - 1 (stored PIT input)',operatingMargin:'TTM operating income / TTM revenue',fcfMargin:'TTM (CFO - capex) / TTM revenue',capexIntensity:'TTM capex / TTM revenue'}[key],
      period:latest.period,availableAt:latest.availableAt,source:latest.source.dataset}));
    const snapshot={ticker,asOf,period:latest.period,periodEnd:latest.periodEnd,availableAt:latest.availableAt,base,metrics:latest.metrics,
      source:latest.source,adapterVersion:SOURCE_ADAPTER_VERSION,price:this.price(ticker,asOf,snap)};
    const guidanceReview=this.reviewGuidance(ticker,latest)??{};
    const result={ticker,name:snap?.name??ticker,currency,asOf,base,snapshot:{...snapshot,id:signature(snapshot)},metrics,history:displayHistory,
      published:{fairValue:latest.publishedFairValue,formula:latest.publishedFormula,dcf:latest.score.equityDcf?.fairValue??null,modelVersion:latest.source.modelVersion},
      templates,templateReconciliation:reconciliation,templatePolicy:reconciliation?.basis==='user_defined_cashflow_path'
        ? 'Independent private worksheet prefilled with disclosed analyst starting assumptions, not issuer guidance or a published DCF. Ke 10% and g 2.5% are illustrative. Confirm parent ownership before saving a formal scenario.'
        : 'Revenue starts from the stored normalized growth assumption and fades to terminal growth. FCFE margins reconcile the unchanged published cash-flow path before post-DCF adjustments. Neither path is annual management guidance. Bear/Bull are editable stresses; saved user assumptions are never replaced.',
      provenance:this.guruEvidence(ticker,asOf),priceHistory:(marketPriceHistory(ticker,asOf)??snap?.priceHistory??[]).filter(x=>x.date<=asOf && finite(x.close)&&x.close>0).slice(-900),
      guidance:{maxObservedAt:latest.guidance.maxObservedAt??null,selection:latest.guidance.guidanceSelection??{},evidence:(latest.guidance.evidence??[]).filter(x=>x.observedAt<=asOf),...guidanceReview},
      coverage:{scenario:templates?'supported':currencyComparable?'existing_method_only':'currency_reconciliation_required',peers:'not_available_reviewed_cohort',kpis:'not_available',roic:'not_available'},
      retrospective:true};
    if(this.companyCache.size>=8)this.companyCache.delete(this.companyCache.keys().next().value);
    this.companyCache.set(cacheKey,result);return structuredClone(result);
  }
  discovery(asOf) {
    isoDate(asOf);
    // Bounded scalar SQL extraction avoids loading all transcript/snapshot blobs.
    const rows=this.db.prepare(`WITH ranked AS (SELECT ticker,fiscal_period,as_of_date,input_json,
      ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY as_of_date DESC,model_version DESC) n
      FROM valuation_pit_model_runs WHERE as_of_date<=? AND financial_available_at<=as_of_date
      AND (guidance_max_observed_at IS NULL OR guidance_max_observed_at<=as_of_date))
      SELECT ticker, fiscal_period, as_of_date,
      json_extract(input_json,'$.financial.revenue_growth_pct') growth,
      json_extract(input_json,'$.valuationSemantics.scoreInputs') score
      FROM ranked WHERE n=1 ORDER BY ticker`).all(asOf);
    const seen=new Set(); const eligible=[];
    for(const r of rows) {if(seen.has(r.ticker))continue;seen.add(r.ticker);
      const route=valuationModelRoute(JSON.parse(r.score??'{}'));
      if(['operating_company','multi_method_growth','revenue_stage'].includes(route)&&finite(r.growth)&&r.growth>=15) eligible.push({ticker:r.ticker,period:r.fiscal_period,availableAt:r.as_of_date,revenueGrowth:r.growth/100});}
    return eligible.sort((a,b)=>compare(a.ticker,b.ticker));
  }
  guruCatalog() {
    const configured=new Map(gurus.map(g=>[g.id,g]));
    return this.db.prepare('SELECT guru_id FROM guru_exposure_snapshots ORDER BY guru_id').all()
      .filter(r=>!configured.has(r.guru_id)||guruIsVisible(r.guru_id)).map(r=>{
      const g=configured.get(r.guru_id);
      if(g)return {id:g.id,name:g.name,entityName:g.entityName??'',avatar:`/guru-avatars/${g.id}.png`,capitalStructure:guruCapitalStructure(g)};
      // Test fixtures and future staged managers can exist before the catalog
      // lands. Parse only that exceptional row, never all large histories.
      const p=this.guruExposure(r.guru_id);
      return {id:r.guru_id,name:p?.guru?.name??r.guru_id,entityName:p?.guru?.entityName??'',avatar:p?.guru?.avatarUrl??`/guru-avatars/${r.guru_id}.png`,capitalStructure:guruCapitalStructure(r.guru_id)};
    });
  }
  guruExposure(guruId) {
    const generation=this.db.prepare('PRAGMA data_version').get().data_version;
    if(generation!==this.guruExposureGeneration){this.guruExposureCache.clear();this.guruExposureGeneration=generation;}
    if(this.guruExposureCache.has(guruId))return this.guruExposureCache.get(guruId);
    const payload=readJson(this.db.prepare('SELECT payload_json FROM guru_exposure_snapshots WHERE guru_id=?').get(guruId));
    this.guruExposureCache.set(guruId,payload);return payload;
  }
  guruDetail(guruId,asOf) {
    isoDate(asOf);
    const guru=this.guruCatalog().find(g=>g.id===guruId);assert(guru,'unknown_guru');
    // Read the existing public-disclosure history. Never import a later book
    // into a historical route, infer missing holdings, or recalculate returns.
    const history=this.guruHistory(guruId,asOf);
    return {guru,asOf,history,latest:history.at(-1)??null,
      coverage:'reported_top_holdings_and_largest_changes_only',retrospective:true};
  }
  guruHistory(guruId,asOf) {
    const p=this.guruExposure(guruId);
    return (p?.history??[]).filter(r=>r.filingDate && r.filingDate<=asOf && r.reportDate<=r.filingDate).sort((a,b)=>compare(a.filingDate,b.filingDate)||compare(a.accessionNumber,b.accessionNumber));
  }
  guruEvidence(ticker,asOf) {
    const result=[];
    for(const g of this.guruCatalog()) {
      const h=this.guruHistory(g.id,asOf); const latest=h.at(-1); if(!latest)continue;
      const holding=latest.topHoldings?.find(x=>x.ticker===ticker && String(x.id).endsWith('-COMMON'));
      const activity=latest.largestChanges?.find(x=>x.ticker===ticker && String(x.id).endsWith('-COMMON'));
      if(!holding&&!activity)continue;
      result.push({guruId:g.id,name:g.name,reportDate:latest.reportDate,availableAt:latest.filingDate,accession:latest.accessionNumber,
        sourceUrl:'https://www.sec.gov/edgar/search/#/q='+encodeURIComponent(latest.accessionNumber),
        ticker,shares:holding?.shares??activity?.shares??null,previousShares:activity?.prevShares??null,
        rawReportedChangeShares:activity?.changeShares??null,weight:holding?.pctPortfolio??null,
        action:activity?.action??'reported_holding',comparisonStatus:'corporate_action_unverified',coverage:'top_holdings_and_reported_largest_changes_only'});
    }
    return result;
  }
}
