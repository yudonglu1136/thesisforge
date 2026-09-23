import { assert, finite, isoDate, calculateScenario, reverseScenario, operatingIsoValueCurve, sensitivity, validateRules, evaluateRules, CALC_VERSION, RULE_VERSION, overlap } from './investmentMath.js';
import { tickerKey } from './investmentSource.js';
import { reviewWatch, buildOpportunities } from './investmentOpportunities.js';
import fs from 'node:fs';

const legacyValueFlowProvenance = JSON.parse(fs.readFileSync(new URL('./config/legacy-value-flow-provenance.json', import.meta.url), 'utf8'));
import { buildFundamentals, FUNDAMENTALS_VERSION } from './investmentFundamentals.js';
import { worksheetState, saveWorksheet } from './investmentDrafts.js';
import { buildResearchWorkbench } from './researchWorkbench.js';

const selectedManagers=['gavin-baker','bill-ackman','stanley-druckenmiller'];
export const SHADOW_RULES=Object.freeze({version:'guru-top3-disclosure-preview-v1',managers:selectedManagers,topN:3,rank:'reported_common_long_value_desc_then_ticker',duplicate:'aggregate_CUSIP_then_union_ticker',weight:'equal_unique_security',rebalance:'first_market_session_after_public_availability',costBps:10,valuationFilter:false});

export class InvestmentService {
  constructor(source,store,today=()=>new Date().toISOString().slice(0,10),options={}) {
    Object.assign(this,{source,store,today});
    this.aiInsights=options.aiInsights??null;
  }
  date(value) { const date=isoDate(value??this.today());assert(date<=this.today(),'future_as_of');return date; }
  guruDirectory(owner) {
    const follows=new Map(this.store.list(owner,'follow').map(x=>[x.guruId,x.followed]));
    return this.source.guruCatalog().map(g=>({...g,followed:follows.get(g.id)??false}));
  }
  research(owner,ticker,date) {return buildResearchWorkbench(this,owner,ticker,date);}
  saveWorksheet(owner,body) {return saveWorksheet(this,owner,body);}
  calculate(body) {
    const company=this.source.company(tickerKey(body.ticker),this.date(body.asOf));
    assert(company.templates,'scenario_method_not_supported');
    if(body.snapshotId)assert(body.snapshotId===company.snapshot.id,'actual_base_changed_reload');
    const result=calculateScenario(company.base,body.assumptions);
    // A missing comparison price must not prevent price-independent DCF math.
    // Explicit targets are scenario-currency inputs. Automatic targets require
    // a comparable quote; never use a USD listing price against a GBP/EUR model.
    const explicitPrice=Object.hasOwn(body,'reversePrice');
    const quote=company.snapshot.price;
    const comparableCurrency=Boolean(quote?.currency&&quote.currency===company.base.currency);
    const price=explicitPrice?body.reversePrice:comparableCurrency?quote.value:null;
    let reverse;
    try {
      assert(explicitPrice||comparableCurrency,'comparison_price_currency_mismatch');
      reverse=reverseScenario(company.base,body.assumptions,price,body.reverseVariable??'growth',body.targetReturn??body.assumptions.ke);
    }
    catch(error) {if(!error.status)throw error;reverse={status:'unavailable',reason:error.message,value:null};}
    const templateResults=Object.fromEntries(Object.entries(company.templates).map(([name,assumptions])=>{
      try {return [name,calculateScenario(company.base,assumptions).fairValue];}
      catch(error){if(!error.status)throw error;return [name,null];}
    }));
    const isoValueCurve=body.assumptions?.method==='operating_fcff'&&finite(price)
      ?operatingIsoValueCurve(company.base,body.assumptions,price):null;
    return {result,templateResults,sensitivity:sensitivity(company.base,body.assumptions),reverse,isoValueCurve,snapshotId:company.snapshot.id};
  }
  saveScenario(owner,body) {
    return this.store.write(owner,'scenario',tickerKey(body.ticker),body.operationId,body,()=>{
      const c=this.source.company(body.ticker,this.date(body.asOf));assert(c.templates,'scenario_method_not_supported');
      assert(body.snapshotId===c.snapshot.id,'actual_base_changed_reload');
      assert(body.ownershipConfirmed===true,'parent_fcfe_ownership_confirmation_required');
      assert(typeof body.name==='string'&&body.name.trim().length>0&&body.name.length<=80,'invalid_scenario_name');
      assert(body.hypothesis===undefined||(typeof body.hypothesis==='string'&&body.hypothesis.length<=4000),'invalid_hypothesis');
      if(body.parentId){ const p=this.store.get(owner,body.parentId,'scenario');assert(p.ticker===c.ticker,'scenario_ticker_mismatch'); }
      const versions=this.store.list(owner,'scenario').filter(x=>x.ticker===c.ticker);
      const result=calculateScenario(c.base,body.assumptions);
      return {version:versions.length+1,name:body.name.trim(),hypothesis:body.hypothesis??'',asOf:c.asOf,parentId:body.parentId??null,snapshot:c.snapshot,assumptions:body.assumptions,
        templateReconciliation:c.templateReconciliation??null,
        calcVersion:result.calcVersion??CALC_VERSION,result,ownershipConfirmed:true};
    });
  }
  saveDecision(owner,body) {
    return this.store.write(owner,'decision',tickerKey(body.ticker),body.operationId,body,()=>{
      assert(['Watch','Pass','Invest'].includes(body.action),'invalid_decision');
      const scenario=this.store.get(owner,body.scenarioId,'scenario');assert(scenario.ticker===tickerKey(body.ticker),'scenario_ticker_mismatch');
      const asOf=this.date(body.asOf);assert(scenario.asOf<=asOf,'future_scenario');
      const c=this.source.company(body.ticker,asOf);assert(c.snapshot.id===scenario.snapshot.id,'scenario_not_current_for_decision_date');
      assert(typeof body.notes==='string'&&body.notes.length<=4000,'invalid_notes');
      const rules=body.rules??[];validateRules(rules);
      const sourceGuruIds=body.sourceGuruIds??[];
      assert(Array.isArray(sourceGuruIds),'invalid_discovery_guru');
      let discovery=c.provenance.filter(g=>sourceGuruIds.includes(g.guruId));
      if(body.entryEvidence) {
        const entry=body.entryEvidence;
        assert(typeof entry.guruId==='string'&&typeof entry.accession==='string','invalid_entry_evidence');
        const filing=this.source.guruHistory(entry.guruId,asOf).find(f=>f.accessionNumber===entry.accession);
        assert(filing,'entry_disclosure_not_available');
        const h=[...(filing.topHoldings??[]),...(filing.largestChanges??[])].find(x=>x.ticker===c.ticker&&String(x.id).endsWith('-COMMON'));
        assert(h&&sourceGuruIds.includes(entry.guruId),'entry_holding_not_available');
        discovery=discovery.filter(g=>g.guruId!==entry.guruId);
        discovery.push({guruId:entry.guruId,name:this.source.guruCatalog().find(g=>g.id===entry.guruId)?.name,
          ticker:c.ticker,accession:entry.accession,reportDate:filing.reportDate,availableAt:filing.filingDate,
          shares:h.shares??null,weight:h.pctPortfolio??null,sourceUrl:filing.filing?.secUrl??null,
          comparisonStatus:'corporate_action_unverified',coverage:'top_holdings_and_reported_largest_changes_only'});
      }
      assert(sourceGuruIds.every(id=>discovery.some(g=>g.guruId===id)),'invalid_discovery_guru');
      const discoveryOrigin=body.discoveryOrigin??'direct_research';
      assert(['direct_research','fundamental_rule','fundamental_research','guru_disclosure','value_flow','ai_insights'].includes(discoveryOrigin),'invalid_discovery_origin');
      const fundamentalEntry=discoveryOrigin==='fundamental_research'?buildFundamentals(this.source,asOf).companies.find(r=>r.ticker===c.ticker):null;
      if(discoveryOrigin==='fundamental_research')assert(fundamentalEntry,'invalid_fundamental_company');
      let aiInsightsContext=null;
      if(discoveryOrigin==='ai_insights') {
        const selection=body.discoveryContext;
        assert(selection&&typeof selection.snapshotId==='string'&&selection.snapshotId.length>0,'ai_insights_snapshot_required');
        assert(this.aiInsights,'ai_insights_service_unavailable');
        const analysis=this.aiInsights.company(c.ticker,{
          asOf,quarter:selection.quarter,window:selection.window,snapshotId:selection.snapshotId,
        });
        aiInsightsContext={...analysis.context,ticker:c.ticker,
          sourceRevisionId:analysis.company?.sourceRevisionId??null,
          filters:Object.fromEntries(['tab','metric','group','sector','sort','query','selected'].filter(key=>typeof selection[key]==='string').map(key=>[key,selection[key].slice(0,120)])),
          compareTickers:Array.isArray(selection.tickers)?selection.tickers.filter(x=>typeof x==='string'&&/^[A-Z0-9.\-]{1,12}$/.test(x)).slice(0,4):[],
        };
      }
      if(discoveryOrigin==='value_flow')assert(legacyValueFlowProvenance.tickers.includes(c.ticker),'company_not_in_value_chain');
      if(discoveryOrigin==='fundamental_rule')assert(c.snapshot.metrics.revenueGrowth>=.15,'discovery_rule_not_satisfied');
      if(discoveryOrigin==='guru_disclosure')assert(sourceGuruIds.length>0,'discovery_guru_required');
      let candidateContext=null;
      if(body.candidateContext) {
        const {lens,reportDate}=body.candidateContext;
        assert(['holdings','adds','trims','value'].includes(lens),'invalid_candidate_lens');
        const list=buildOpportunities(this.source,asOf,reportDate??null);
        const candidate=list.rows.find(r=>r.ticker===c.ticker);
        assert(candidate,'candidate_not_available_at_date');
        candidateContext={kind:'guru_valuation_discovery',lens,asOf,reportDate:list.reportDate,evidence:candidate.managers,
          monitoring:'only_explicitly_selected_sourceGuruIds_are_monitored'};
      }
      assert(finite(body.units)&&body.units>=0&&body.units<=1e12,'invalid_position_units');
      assert(body.action!=='Invest'||body.units>0,'invest_requires_units');
      assert(body.action==='Invest'||body.units===0,'non_invest_units_must_be_zero');
      assert(finite(body.targetWeight)&&body.targetWeight>=0&&body.targetWeight<=1,'invalid_target_weight');
      const prior=this.heads(owner).find(x=>x.ticker===c.ticker);
      assert(!prior || prior.units===0,'existing_position_requires_review');
      return {action:body.action,decisionDate:asOf,executionDate:null,recordType:'research_paper_position_not_order',scenario,
        snapshot:c.snapshot,price:c.snapshot.price,units:body.units,targetWeight:body.targetWeight,priority:body.priority===true,
        discovery,candidateContext,discoveryContext:aiInsightsContext,
        entryEvidence:body.entryEvidence?discovery.find(g=>g.guruId===body.entryEvidence.guruId&&g.accession===body.entryEvidence.accession):null,
        discoveryOrigin:{kind:discoveryOrigin,asOf,ruleVersion:discoveryOrigin==='fundamental_rule'?'quarterly-growth-15pct-v1':null,
          ...(fundamentalEntry?{ruleVersion:FUNDAMENTALS_VERSION,matchedScreens:fundamentalEntry.screens,sourceHash:fundamentalEntry.source.hash,comparisonStatus:fundamentalEntry.comparisonStatus}:{}),
          ...(aiInsightsContext?{snapshotId:aiInsightsContext.snapshotId,universeVersion:aiInsightsContext.universeVersion,methodologyVersion:aiInsightsContext.methodologyVersion}:{}),
          ...(discoveryOrigin==='value_flow'?{classificationVersion:legacyValueFlowProvenance.version,retrospectiveClassification:true}:{})},
        notes:body.notes,rules,ruleVersion:RULE_VERSION,retrospective:true};
    });
  }
  heads(owner,asOf=this.today()) {
    const heads=new Map();
    for(const d of this.store.list(owner,'decision').filter(x=>x.decisionDate<=asOf)) heads.set(d.ticker,{...d,decisionId:d.id,scenarioId:d.scenario.id,lastReview:null,costBasisReliable:true});
    for(const r of this.store.list(owner,'review').filter(x=>x.asOf<=asOf)) {
      const h=heads.get(r.ticker);if(h?.decisionId===r.decisionId) heads.set(r.ticker,{...h,scenarioId:r.scenario.id,scenario:r.scenario,units:r.units,lastReview:r,costBasisReliable:h.costBasisReliable&&!['Add','Reduce'].includes(r.action)});
    }
    return [...heads.values()];
  }
  reviewContext(owner,decisionId,date) {
    const d=this.store.get(owner,decisionId,'decision');const asOf=this.date(date);assert(asOf>=d.decisionDate,'review_before_decision');
    const head=this.heads(owner,asOf).find(x=>x.decisionId===decisionId);assert(head,'superseded_decision');
    const now=this.source.company(d.ticker,asOf); const sameAssumptions=calculateScenario(now.base,head.scenario.assumptions);
    const triggers=evaluateRules(d.rules,now.history,d.snapshot.periodEnd,asOf);
    const guruChanges=d.discovery.map(original=>({original,current:now.provenance.find(x=>x.guruId===original.guruId)??null})).filter(x=>x.current && x.current.availableAt>x.original.availableAt && x.current.rawReportedChangeShares!==null && x.current.rawReportedChangeShares<0);
    return {decision:d,headId:head.lastReview?.id??d.id,activeUnits:head.units,activeScenario:head.scenario,now,triggers,guruChanges,sameAssumptions,
      reviewHistory:this.store.list(owner,'review').filter(x=>x.decisionId===d.id&&x.asOf<=asOf),
      thenValue:d.scenario.result.fairValue,changeUnderSameAssumptions:sameAssumptions.fairValue-head.scenario.result.fairValue,
      activeThenValue:head.scenario.result.fairValue,
      originalSameAssumptions:calculateScenario(now.base,d.scenario.assumptions),
      activeDelta:Object.keys(head.scenario.snapshot.metrics).map(metric=>({metric,then:head.scenario.snapshot.metrics[metric],now:now.snapshot.metrics[metric]})),
      reviewRequired:triggers.some(x=>x.status==='review_required')||guruChanges.length>0,
      delta:Object.keys(d.snapshot.metrics).map(metric=>({metric,then:d.snapshot.metrics[metric],now:now.snapshot.metrics[metric]}))};
  }
  saveReview(owner,body) {
    const decision=this.store.get(owner,body.decisionId,'decision');
    return this.store.write(owner,'review',decision.ticker,body.operationId,body,()=>{
      assert(['Maintain','Change','Add','Reduce','Exit'].includes(body.action),'invalid_review_action');
      const c=this.reviewContext(owner,body.decisionId,body.asOf);assert(c.headId===body.expectedHeadId,'review_conflict_reload');
      const latestHead=this.heads(owner).find(x=>x.decisionId===decision.id);
      assert(latestHead && (latestHead.lastReview?.id??decision.id)===c.headId,'review_date_regression');
      assert(typeof body.notes==='string'&&body.notes.trim().length>0&&body.notes.length<=4000,'review_reason_required');
      let scenario=c.activeScenario;
      if(body.action==='Change') { scenario=this.store.get(owner,body.scenarioId,'scenario');assert(scenario.ticker===decision.ticker && scenario.id!==c.activeScenario.id && scenario.snapshot.id===c.now.snapshot.id,'new_scenario_required'); }
      else assert(!body.scenarioId||body.scenarioId===scenario.id,'maintain_cannot_change_assumptions');
      const head=this.heads(owner).find(x=>x.decisionId===decision.id); let units=head.units;
      if(['Add','Reduce'].includes(body.action)) { assert(finite(body.units)&&body.units>0&&body.units<=1e12,'invalid_position_units');
        assert(body.action==='Add'?body.units>units:body.units<units,'invalid_position_direction');units=body.units; }
      if(body.action==='Exit')units=0;
      return {decisionId:decision.id,previousHeadId:c.headId,action:body.action,asOf:c.now.asOf,scenario,snapshot:c.now.snapshot,
        sameAssumptions:c.sameAssumptions,triggers:c.triggers,guruChanges:c.guruChanges,notes:body.notes,units,ruleVersion:RULE_VERSION};
    });
  }
  follow(owner,body) {
    assert(this.source.guruCatalog().some(x=>x.id===body.guruId),'unknown_guru');
    return this.store.write(owner,'follow','',body.operationId,body,()=>({guruId:body.guruId,followed:body.followed===true}));
  }
  strategy(owner,body) {
    assert(Array.isArray(body.managers)&&body.managers.length>=1&&body.managers.length<=10,'invalid_strategy_managers');
    assert(body.managers.every(id=>this.source.guruCatalog().some(x=>x.id===id)),'unknown_guru');
    assert(Number.isInteger(body.topN)&&body.topN>=1&&body.topN<=3,'unsupported_top_n');
    return this.store.write(owner,'strategy','',body.operationId,body,()=>({version:this.store.list(owner,'strategy').length+1,
      rules:{...SHADOW_RULES,managers:[...new Set(body.managers)].sort(),topN:body.topN},asOf:this.date(body.asOf)}));
  }
  shadow(owner,asOf) {
    const version=this.store.list(owner,'strategy').filter(x=>x.asOf<=asOf).at(-1); const rules=version?.rules??SHADOW_RULES;
    const union=new Map(),evidence=[],issues=[];
    for(const id of rules.managers) {
      const filing=this.source.guruHistory(id,asOf).at(-1); if(!filing){issues.push({guruId:id,reason:'missing_disclosure'});continue;}
      // Historical exposure is bounded; only call it a selected-book preview.
      const book=new Map();
      for(const h of filing.topHoldings??[]) {
        if(!String(h.id).endsWith('-COMMON')||!finite(h.value)||!finite(h.shares))continue;
        const k=h.cusip;const old=book.get(k);if(old && old.ticker!==h.ticker){issues.push({guruId:id,reason:'ambiguous_identity'});continue;}
        book.set(k,{...h,value:(old?.value??0)+h.value,shares:(old?.shares??0)+h.shares});
      }
      const top=[...book.values()].sort((a,b)=>b.value-a.value||String(a.ticker).localeCompare(String(b.ticker))||String(a.cusip).localeCompare(String(b.cusip))).slice(0,rules.topN);
      if(top.length<rules.topN)issues.push({guruId:id,reason:'incomplete_common_book'});
      for(const h of top) {
        if(!h.ticker){issues.push({guruId:id,reason:'unresolved_selected_security'});continue;}
        const existing=union.get(h.ticker)??{ticker:h.ticker,managers:[]};existing.managers.push(id);union.set(h.ticker,existing);
      }
      evidence.push({guruId:id,reportDate:filing.reportDate,availableAt:filing.filingDate,accession:filing.accessionNumber});
    }
    const holdings=issues.length?[]:[...union.values()].sort((a,b)=>a.ticker.localeCompare(b.ticker)).map(x=>({...x,weight:1/union.size}));
    return {strategyVersionId:version?.id??null,rules,holdings,evidence,issues,status:issues.length?'incomplete':'disclosure_preview',
      performance:null,note:'Disclosure-only selected-book preview. Not executable holdings or fund performance; use the existing audited strategy engine for returns.'};
  }
  portfolio(owner,date) {
    const asOf=this.date(date);const heads=this.heads(owner,asOf).filter(d=>d.units>0);
    const positions=heads.map(d=>{const price=this.source.price(d.ticker,asOf);const marketValue=finite(price.value)&&price.currency===d.snapshot.base.currency?price.value*d.units:null;
      return {ticker:d.ticker,decisionId:d.decisionId,units:d.units,currency:d.snapshot.base.currency,price,marketValue,
        cost:d.costBasisReliable&&finite(d.price.value)?d.units*d.price.value:null,targetWeight:d.targetWeight,scenarioId:d.scenarioId,scenarioValue:d.scenario.result.fairValue,
        note:'Research allocation. Corporate actions, additions/reductions cost lots and broker execution are not reconciled.'};});
    const currencies=[...new Set(positions.map(x=>x.currency))];
    const totals=currencies.map(currency=>{const group=positions.filter(x=>x.currency===currency),unpriced=group.filter(x=>x.marketValue===null).length;
      const pricedMarketValue=group.filter(x=>finite(x.marketValue)).reduce((sum,x)=>sum+x.marketValue,0);
      return {currency,marketValue:unpriced?null:pricedMarketValue,pricedMarketValue,unpriced};});
    for(const p of positions){const total=totals.find(x=>x.currency===p.currency);p.weight=total.unpriced===0&&total.marketValue>0?p.marketValue/total.marketValue:null;}
    const shadow=this.shadow(owner,asOf);
    return {asOf,positions,totals,shadow,overlap:currencies.length<=1&&positions.every(x=>finite(x.weight))&&shadow.holdings.length?overlap(positions,shadow.holdings):[],
      cta:{status:'not_connected',allocation:null,metrics:null},combinedRisk:null};
  }
  home(owner,date) {
    const asOf=this.date(date);const attention=[];
    for(const d of this.heads(owner,asOf).filter(x=>x.units>0 || x.action==='Watch'&&x.priority)) {
      try {const c=this.reviewContext(owner,d.decisionId,asOf);
        const newPeriod=!d.lastReview||c.now.snapshot.periodEnd>d.lastReview.snapshot.periodEnd;
        const newGuru=c.guruChanges.some(g=>!d.lastReview||g.current.availableAt>d.lastReview.asOf);
        if(c.reviewRequired&&(newPeriod||newGuru))attention.push({ticker:d.ticker,decisionId:d.decisionId,period:c.now.snapshot.period,triggers:c.triggers,guruChanges:c.guruChanges});
      }catch(error){attention.push({ticker:d.ticker,decisionId:d.decisionId,status:'data_unavailable',reason:error.message});}
    }
    const watches=[...new Map(this.store.list(owner,'watch').filter(w=>w.baseline.asOf<=asOf).map(w=>[w.ticker,w])).values()].map(w=>{
      try {const r=reviewWatch(this,owner,w.id,asOf);return {id:w.id,ticker:w.ticker,asOf:w.baseline.asOf,status:r.status,modelChange:r.modelChange,priceChange:r.priceChange,newFilings:r.newFilings.length,lastReviewedAt:r.lastReviewedAt};}
      catch(e){return {id:w.id,ticker:w.ticker,asOf:w.baseline.asOf,status:'data_unavailable',modelChange:null,priceChange:null,newFilings:0,lastReviewedAt:null};}
    });
    return {asOf,attention,watches,discovery:this.source.discovery(asOf),discoveryRule:'Latest public PIT quarterly revenue YoY >= 15%; alphabetical; not a recommendation.',
      gurus:this.guruDirectory(owner),decisions:this.heads(owner,asOf),portfolio:this.portfolio(owner,asOf)};
  }
  discover(owner,date) {
    const asOf=this.date(date);
    const gurus=this.guruDirectory(owner).map(g=>{
      const latest=this.source.guruHistory(g.id,asOf).at(-1);
      return {...g,latest:latest?{
        reportDate:latest.reportDate,availableAt:latest.filingDate,quarter:latest.quarterLabel,
        accession:latest.accessionNumber,reported13fValue:latest.reported13fValue??null,
        positionCount:latest.positionCount??null,topHoldings:(latest.topHoldings??[]).slice(0,3),
      }:null};
    });
    return {asOf,gurus,discovery:this.source.discovery(asOf)};
  }
}
