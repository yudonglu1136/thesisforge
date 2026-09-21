import { assert, finite, isoDate, signature } from './investmentMath.js';
import { tickerKey } from './investmentSource.js';
import { buildFundamentalCompany } from './fundamentalResearch.js';
import { opportunityValuationBreakdown } from './investmentOpportunities.js';
import { institutional13fInsightDetail } from './institutional13fInsights.js';
import { worksheetState } from './investmentDrafts.js';

const RESEARCH_PRICE_POINT_LIMIT=360;

// The overview chart does not need every daily close. Preserve both endpoints
// and evenly sample the middle so the initial company response stays compact.
// Full financial facts and institutional history continue to load from their
// dedicated, on-demand routes.
export function compactResearchSeries(rows,limit=RESEARCH_PRICE_POINT_LIMIT) {
  if(!Array.isArray(rows)||rows.length<=limit)return Array.isArray(rows)?rows:[];
  const sampled=[];
  for(let index=0;index<limit;index++){
    const sourceIndex=Math.round(index*(rows.length-1)/(limit-1));
    const row=rows[sourceIndex];
    if(row&&sampled.at(-1)!==row)sampled.push(row);
  }
  return sampled;
}

function compactHistoryNode(row) {
  const source=row?.source??{};
  return {
    period:row?.period??null,periodEnd:row?.periodEnd??null,
    availableAt:row?.availableAt??null,filingDate:row?.filingDate??null,
    metrics:row?.metrics??{},publishedFairValue:row?.publishedFairValue??null,
    publishedFormula:row?.publishedFormula??null,
    source:{dataset:source.dataset??null,dimension:source.dimension??null,
      periodEnd:source.periodEnd??null,availableAt:source.availableAt??null,
      url:source.url??null,modelVersion:source.modelVersion??null,hash:source.hash??null},
  };
}

function compactFundamentalOverview(detail) {
  if(!detail||typeof detail!=='object')return detail;
  return {
    version:detail.version??null,methodVersion:detail.methodVersion??null,
    ticker:detail.ticker??null,name:detail.name??detail.company?.name??null,
    asOf:detail.asOf??null,company:detail.company??null,identity:detail.identity??null,
    economicTemplate:detail.economicTemplate??null,judgment:detail.judgment??null,
    importantChanges:detail.importantChanges??[],counterEvidence:detail.counterEvidence??null,
    researchGaps:detail.researchGaps??[],valuation:detail.valuation??null,
    transportCoverage:{mode:'overview_summary',fullFacts:'on_demand'},
  };
}

function compactPriceNode(row) {
  const provenance=row?.provenance??{};
  return {
    date:row?.date??row?.available_at??null,
    value:row?.value??row?.close??row?.adjustedClose??null,
    currency:row?.currency??null,
    source:row?.source??provenance.source??null,
    priceType:row?.priceType??row?.price_type??null,
  };
}

function compactResearchCore(core) {
  const originalPrices=Array.isArray(core.priceHistory)?core.priceHistory:[];
  const priceHistory=compactResearchSeries(originalPrices).map(compactPriceNode);
  return {...core,fundamental:compactFundamentalOverview(core.fundamental),
    history:(core.history??[]).map(compactHistoryNode),priceHistory,
    transportCoverage:{...(core.transportCoverage??{}),
      pricePointsAvailable:originalPrices.length,pricePointsReturned:priceHistory.length,
      historyNodesReturned:(core.history??[]).length,
      detailPolicy:'overview_compact; facts, documents and institutions load on demand'},
  };
}

export function researchDocuments(source,ticker,asOf) {
  ticker=tickerKey(ticker);isoDate(asOf);
  const rows=source.db.prepare(`SELECT fiscal_period,as_of_date,financial_available_at,input_json,output_json,model_version
    FROM valuation_pit_model_runs WHERE ticker=? AND as_of_date<=? AND financial_available_at<=as_of_date
    ORDER BY as_of_date DESC,fiscal_period DESC LIMIT 40`).all(ticker,asOf);
  const seen=new Set(),documents=[];
  for(const row of rows){
    const input=JSON.parse(row.input_json),output=JSON.parse(row.output_json);
    const record=input.sourceRecord??{};
    const sourceUrl=output.sourceUrl??record.sourceUrl??record.url??null;
    const key=`${row.fiscal_period}|${row.financial_available_at}|${sourceUrl??''}`;
    if(seen.has(key))continue;seen.add(key);
    documents.push({
      id:signature({ticker,key,modelVersion:row.model_version}),ticker,
      form:record.form??record.dimension??'financial_update',
      category:'earnings',title:`${ticker} ${row.fiscal_period} financial disclosure`,
      reportPeriod:record.reportperiod??record.calendardate??null,
      publishedAt:row.financial_available_at,observedAt:row.as_of_date,
      sourceUrl,documentHash:record.sha256??null,attachments:[],amends:null,
      contentStatus:sourceUrl?'verified_link_only':'classification_clue_only',
      bodyAvailable:false,evidenceRefs:[`model:${row.model_version}:${row.fiscal_period}`],
      limitation:'No source body is stored in this catalog record; no document-text summary is generated.',
    });
  }
  return {version:'research-documents-v1',ticker,asOf,rows:documents,
    coverage:{count:documents.length,readableBody:0,verifiedLinks:documents.filter(row=>row.sourceUrl).length,
      status:documents.length?'metadata_only':'unavailable',
      distinction:'event classifications and verified links are not document-body coverage'}};
}

function fundamentalResearchShape(detail) {
  const latest=detail.trend?.at(-1)??{};
  const sourceMetrics=detail.company?.metrics??{};
  // Research overview is deliberately a small, unit-safe decision set. Do not
  // pass arbitrary Fact OS counters or currency amounts into a percentage card.
  const metrics=[
    ['revenueGrowth','priorRevenueGrowth'],
    ['operatingMargin','operatingMarginPriorYear'],
    ['fcfMargin','fcfMarginPriorYear'],
    ['capexIntensity','capexIntensityPriorYear'],
  ].filter(([key])=>finite(sourceMetrics[key])).map(([key,previousKey])=>{
    const value=sourceMetrics[key],previous=finite(sourceMetrics[previousKey])?sourceMetrics[previousKey]:null;
    return {key,value,previous,change:previous==null?null:value-previous,period:detail.company?.period_end,
      availableAt:detail.company?.available_at,unit:'ratio',source:'Fact OS'};
  });
  return {
    ticker:detail.ticker,name:detail.company?.name??detail.ticker,currency:detail.identity?.currency??'USD',asOf:detail.asOf,
    base:{revenueM:detail.company?.metrics?.ttmRevenue??null,sharesM:null,fcfM:detail.company?.metrics?.ttmFcf??null,currency:detail.identity?.currency??'USD'},
    snapshot:{ticker:detail.ticker,asOf:detail.asOf,period:detail.company?.fiscalperiod??detail.company?.period_end,
      periodEnd:detail.company?.period_end,availableAt:detail.company?.available_at,
      price:detail.price??{value:null,date:null,source:null,currency:null},
      id:signature({ticker:detail.ticker,asOf:detail.asOf,catalogGeneration:detail.catalogGeneration})},
    metrics,history:(detail.trend??[]).map(row=>({period:row.fiscalPeriod??row.periodEnd,periodEnd:row.periodEnd,
      availableAt:row.availableAt,metrics:{revenueGrowth:row.revenueGrowth,operatingMargin:row.operatingMargin,fcfMargin:row.fcfMargin},
      publishedFairValue:null,publishedFormula:null,source:{dataset:'Fact OS',modelVersion:null}})),
    priceHistory:detail.priceHistory??[],published:{fairValue:null,formula:null,dcf:null,modelVersion:null},
    templates:null,templateReconciliation:null,provenance:[],guidance:{evidence:[],audit:null},
    fundamental:detail,retrospective:true,
  };
}

function finishResearchWorkbench(service,owner,ticker,asOf,core,model) {
  let breakdown=null;
  if(model){
    try {breakdown=opportunityValuationBreakdown(service.source,ticker,asOf);}
    catch(error){
      // Model-backed Research remains usable when an older source adapter does
      // not expose the raw release ledger. Never synthesize a decomposition.
      breakdown={status:'unavailable',reason:error.message,methods:[],reconciliation:null};
    }
  }
  const records=service.store.list(owner,'research_record').filter(row=>row.ticker===ticker&&row.asOf<=asOf);
  const worksheet=model?worksheetState(service.store,owner,ticker,asOf):{activeWorksheet:null,worksheetIgnoredTestVersions:0,worksheetHead:null};
  const scenarios=model?service.store.list(owner,'scenario').filter(row=>row.ticker===ticker&&row.asOf<=asOf):[];
  const decisions=model?service.store.list(owner,'decision').filter(row=>row.ticker===ticker&&row.decisionDate<=asOf):[];
  const compactCore=compactResearchCore(core);
  return {...compactCore,...worksheet,scenarios,decisions,researchRecords:records,
    publishedBreakdown:breakdown,
    coverage:{
      company:'available',facts:model?'model_snapshot_summary':'fact_os_full',
      documents:'on_demand',institutions:'on_demand',
      platformModel:model?'available':'not_modeled',personalResearch:'available',
    },
    researchDates:{cutoff:asOf,financialPeriod:core.snapshot?.periodEnd??null,
      disclosureDate:core.snapshot?.availableAt??null,priceDate:core.snapshot?.price?.date??null,
      modelDate:model?core.snapshot?.availableAt:null},
  };
}

// Preserve the synchronous model-backed path used by the existing workflow and
// tests. Fact-only companies return a Promise because Fact OS may have to build
// its compact artifact first; the HTTP wrapper already awaits either shape.
export function buildResearchWorkbench(service,owner,ticker,date) {
  const asOf=service.date(date);ticker=tickerKey(ticker);
  let model=null;
  try {model=service.source.company(ticker,asOf);} catch(error){if(error.message!=='no_pit_research_at_date')throw error;}
  if(model)return finishResearchWorkbench(service,owner,ticker,asOf,model,model);
  return buildFundamentalCompany(service.source,ticker,asOf)
    .then(fundamental=>finishResearchWorkbench(service,owner,ticker,asOf,fundamentalResearchShape(fundamental),null));
}

export async function researchFundamentals(service,ticker,date) {
  return buildFundamentalCompany(service.source,ticker,service.date(date));
}

export function researchInstitutions(service,ticker,date,quarter=null) {
  return institutional13fInsightDetail(service.source,tickerKey(ticker),service.date(date),quarter);
}

export function researchPublishedModel(service,ticker,date) {
  const asOf=service.date(date),key=tickerKey(ticker);
  const breakdown=opportunityValuationBreakdown(service.source,key,asOf);
  return {ticker:key,asOf,status:breakdown?'available':'unavailable',breakdown};
}

export function saveResearchRecord(service,owner,body) {
  const ticker=tickerKey(body.ticker),asOf=service.date(body.asOf);
  const clean=value=>String(value??'').trim().slice(0,4000);
  const evidence=Array.isArray(body.evidenceRefs)?body.evidenceRefs.map(clean).filter(Boolean).slice(0,40):[];
  assert(clean(body.question).length>0,'research_question_required');
  return service.store.write(owner,'research_record',ticker,body.operationId,body,()=>({
    asOf,question:clean(body.question),supportingEvidence:clean(body.supportingEvidence),
    opposingEvidence:clean(body.opposingEvidence),evidenceRefs:evidence,
    personalScenarioId:body.personalScenarioId??null,impliedScenario:body.impliedScenario??null,
    invalidationCondition:clean(body.invalidationCondition),reviewDate:body.reviewDate??null,
    status:'open',methodVersion:'research-record-v1',
  }));
}

export function listResearchRecords(service,owner,ticker=null) {
  const rows=service.store.list(owner,'research_record');
  return {version:'research-record-v1',rows:ticker?rows.filter(row=>row.ticker===tickerKey(ticker)):rows};
}
