import { simulateDriftedPortfolio, nextTradingSessionAfter } from './backtestEngine.js';
import { assert, finite, isoDate, signature } from './investmentMath.js';
import {strategyHedgeRules} from './strategyHedge.js';
import {leverageRules,financeStrategy} from './strategyLeverage.js';
import {equityMixRules} from './strategyEquityMix.js';
import {ctaPolicyRules,simulateFlexibleCta,CTA_VERSION} from './strategyCta.js';
import {strategyValuationModel} from './strategyValuationLinks.js';

export const STRATEGY_LAB_VERSION = 'guru-valuation-cta-v1';
export const STRATEGY_CALCULATION_VERSION = 'strategy-share-class-valuation-20260911-v6';
const day = 86400000;
const positive = v => finite(v) && v > 0;
const total = xs => xs.reduce((a,b)=>a+b,0);
const mean = xs => xs.length ? total(xs)/xs.length : null;
const variance = xs => xs.length>1 ? total(xs.map(x=>(x-mean(xs))**2))/(xs.length-1) : null;
const fail = (code, detail={}) => ({status:'blocked',failure:{code,...detail},equity:[],metrics:null});

export function strategyRules(body, catalog) {
  const equityMix=equityMixRules(body.equityMix);
  assert(Array.isArray(body.managers) && body.managers.length>=(equityMix&&equityMix.weights.guru===0?0:1) && body.managers.length<=10,'invalid_strategy_managers');
  if(equityMix)assert(body.excludedAllocation==='fully_invested','equity_mix_requires_full_investment');
  assert(body.managers.every(id=>typeof id==='string' && catalog.some(g=>g.id===id)),'unknown_guru');
  assert(Number.isInteger(body.topN) && body.topN>=1 && body.topN<=10,'unsupported_top_n');
  assert(typeof body.valuationEnabled==='boolean','invalid_valuation_toggle');
  assert(finite(body.maxPremium) && body.maxPremium>=0 && body.maxPremium<=1,'invalid_premium');
  assert(['cash','redistribute','fully_invested'].includes(body.excludedAllocation),'invalid_excluded_allocation');
  assert(['none','KMLM','DBMF'].includes(body.cta),'invalid_cta');
  assert(finite(body.ctaWeight) && body.ctaWeight>=0 && body.ctaWeight<=.8,'invalid_cta_weight');
  assert(body.cta!=='none' || body.ctaWeight===0,'cta_weight_without_fund');
  assert(body.cta==='none' || body.ctaWeight>0,'cta_requires_positive_weight');
  assert(finite(body.costBps) && body.costBps>=0 && body.costBps<=100,'invalid_cost');
  const start=isoDate(body.start), end=isoDate(body.end), asOf=isoDate(body.asOf);
  assert(start<end && end<=asOf && Date.parse(end)-Date.parse(start)<=3660*day,'invalid_strategy_window');
  return {version:STRATEGY_LAB_VERSION,managers:[...new Set(body.managers)].sort(),topN:body.topN,
    valuationEnabled:body.valuationEnabled,maxPremium:body.maxPremium,excludedAllocation:body.excludedAllocation,
    cta:body.cta,ctaWeight:body.ctaWeight,costBps:body.costBps,start,end,asOf,
    leverage:leverageRules(body.leverage),
    ...(body.ctaPolicy?{ctaPolicy:ctaPolicyRules(body.ctaPolicy,body.ctaWeight,body.excludedAllocation)}:{}),
    ...(equityMix?{equityMix}:{}),
    ...(body.hedge?{hedge:strategyHedgeRules(body.hedge)}:{})};
}

// Aggregate exact common claims before ranking, including unresolved positive
// positions so they cannot disappear. Full SEC books can contain reported zeros.
export function selectedBook(filing, topN) {
  if(filing.sourceFailure)return {error:filing.sourceFailure};
  if(filing.missingOriginal)return {error:'original_filing_missing'};
  if(filing.amendmentUnreviewed)return {error:'amendment_requires_reconciliation'};
  const byClaim=new Map();
  for(const h of filing.holdings??[]) {
    if(!finite(h.value) || h.value<0 || !h.cusip)return {error:'invalid_selected_book'};
    const prior=byClaim.get(h.cusip);
    if(prior && (prior.ticker!==h.ticker || prior.priceSymbol!==h.priceSymbol))return {error:'conflicting_security_identity'};
    byClaim.set(h.cusip,prior?{...prior,value:prior.value+h.value}: {...h});
  }
  // Retain reported zero rows in the warehouse, but do not give them an equal
  // portfolio weight or let an unselected zero invalidate the positive Top N.
  // This is not a substitute for a missing value or an execution price.
  const sorted=[...byClaim.values()].filter(h=>h.value>0).sort((a,b)=>b.value-a.value || a.cusip.localeCompare(b.cusip));
  if(!sorted.length || (sorted.length<topN && !filing.complete))return {error:'insufficient_top_n_extract'};
  return {holdings:sorted.slice(0,topN)};
}

export function buildStrategySchedule({rules,histories,dates}) {
  const fullyInvested=rules.excludedAllocation==='fully_invested';
  const events=new Map(), first=dates.find(d=>d>=rules.start), end=dates.at(-1);
  if(!first)return {failure:{code:'missing_benchmark_history'}};
  const initial=dates.indexOf(first)-1;
  if(initial<0)return {failure:{code:'missing_decision_session'}};
  events.set(first,[]);
  for(const id of rules.managers) for(const f of histories.get(id)??[]) {
    if(!f.publicDate || f.publicDate>rules.end || f.reportDate>f.publicDate)continue;
    const execution=nextTradingSessionAfter(dates,f.publicDate);
    if(execution && execution>=first && execution<=end) {
      if(!events.has(execution))events.set(execution,[]);
      events.get(execution).push(id);
    }
  }
  const schedule=[];
  for(const [executionDate,updated] of [...events.entries()].sort(([a],[b])=>a.localeCompare(b))) {
    const decisionDate=dates[dates.indexOf(executionDate)-1], selected=new Map(), filings=[], managerExclusions=[];
    for(const id of rules.managers) {
      const eligible=(histories.get(id)??[]).filter(f=>f.publicDate<executionDate && f.reportDate<=f.publicDate)
        .sort((a,b)=>a.reportDate.localeCompare(b.reportDate)||a.publicDate.localeCompare(b.publicDate));
      const f=eligible.at(-1);
      if(!f) {
        const firstStored=(histories.get(id)??[]).filter(f=>f.publicDate&&f.reportDate<=f.publicDate)
          .sort((a,b)=>a.publicDate.localeCompare(b.publicDate))[0];
        const reason={code:'manager_history_unavailable',guruId:id,
          firstStoredPublicDate:firstStored?.publicDate??null,
          firstStoredReportDate:firstStored?.reportDate??null,
          firstStoredSourceUrl:firstStored?.sourceUrl??null};
        if(fullyInvested){managerExclusions.push(reason);continue;}
        return {failure:{...reason,date:executionDate}};
      }
      if(Date.parse(executionDate)-Date.parse(f.publicDate)>200*day){
        if(fullyInvested){managerExclusions.push({code:'stale_manager_filing',guruId:id,publicDate:f.publicDate,reportDate:f.reportDate});continue;}
        return {failure:{code:'stale_manager_filing',guruId:id,date:executionDate}};
      }
      const book=selectedBook(f,rules.topN);
      if(book.error){
        const reason={code:book.error,guruId:id,reportDate:f.reportDate,accession:f.accession??null,sourceUrl:f.sourceUrl??null};
        // Exclude an unavailable whole book, never pretend a partial/unchecked
        // extract is the manager's Top N. Ambiguous security claims still fail.
        if(fullyInvested&&['original_filing_missing','amendment_requires_reconciliation','insufficient_top_n_extract','filing_classification_unverified','manager_identity_mismatch'].includes(book.error)){
          managerExclusions.push(reason);continue;
        }
        return {failure:{...reason,date:executionDate}};
      }
      filings.push({guruId:id,reportDate:f.reportDate,publicDate:f.publicDate,accession:f.accession??null,sourceUrl:f.sourceUrl??null});
      for(const [rank,h] of book.holdings.entries()) {
        const prior=selected.get(h.cusip);
        if(prior && prior.ticker!==h.ticker)return {failure:{code:'conflicting_security_identity',date:executionDate,cusip:h.cusip}};
        selected.set(h.cusip,{...h,managers:[...(prior?.managers??[]),id],ranks:[...(prior?.ranks??[]),rank+1],reportDate:f.reportDate});
      }
    }
    // A late disclosure for an older report does not replace the active book.
    // It must not reset drift, financing or valuation filters or charge a trade.
    // A new active quarter still rebalances even if its Top N is unchanged.
    const previous=schedule.at(-1);
    const changed=filings.filter(f=>signature(f)!==signature(previous?.filings.find(p=>p.guruId===f.guruId)??null));
    if(previous&&!changed.length&&signature(managerExclusions)===signature(previous.managerExclusions??[])&&
      previous.filings.length===filings.length)continue;
    // Different share claims must not silently collapse to a recycled ticker.
    const symbols=new Set();
    for(const h of selected.values())if(h.ticker){if(symbols.has(h.ticker))return {failure:{code:'conflicting_security_identity',ticker:h.ticker,date:executionDate}};symbols.add(h.ticker);}
    schedule.push({executionDate,decisionDate,filings,...(fullyInvested?{managerExclusions}:{}),updatedManagers:[...new Set(updated)].filter(id=>changed.some(f=>f.guruId===id)),holdings:[...selected.values()]});
  }
  return {schedule};
}

export function valuationDecision(holding, date, valuations, comparisonPrices) {
  const {model,valuationLink}=strategyValuationModel(holding,date,valuations);
  const evidence=valuationLink?{modelTicker:valuationLink.modelTicker,valuationLink}:{};
  if(!model || !positive(model.fairValue))return {status:'no_model'};
  if(Date.parse(date)-Date.parse(model.date)>550*day)return {status:'stale_model',modelDate:model.date,...evidence};
  const prices=comparisonPrices.get(holding.ticker);
  if(model.currency!=='USD' || prices?.currency!=='USD')return {status:'currency_unverified',modelDate:model.date,...evidence};
  const price=prices.points.get(date);
  if(!positive(price))return {status:'comparison_price_missing',modelDate:model.date,...evidence};
  return {status:'comparable',price,priceDate:date,fairValue:model.fairValue,modelDate:model.date,
    modelVersion:model.version??null,premium:price/model.fairValue-1,...evidence,
    ...(valuationLink&&prices.provenance?{comparisonPriceSource:prices.provenance}:{})};
}

export function strategyMetrics(rows,field='value') {
  if(rows.length<2)return null;
  const values=rows.map(r=>r[field]);
  if(!values.every(positive))return null;
  const returns=values.slice(1).map((v,i)=>v/values[i]-1), elapsed=(Date.parse(rows.at(-1).date)-Date.parse(rows[0].date))/day;
  let peak=1, maxDrawdown=0;
  for(const v of values){peak=Math.max(peak,v);maxDrawdown=Math.min(maxDrawdown,v/peak-1);}
  const vol=variance(returns), volatility=vol===null?null:Math.sqrt(vol*252);
  return {totalReturn:values.at(-1)-1,cagr:elapsed>0?values.at(-1)**(365.25/elapsed)-1:null,
    maxDrawdown,volatility,sharpeZeroRf:vol>0?mean(returns)/Math.sqrt(vol)*Math.sqrt(252):null,
    endingValue:values.at(-1),observations:rows.length};
}

// Costs are a scalar drag on every unit and on residual cash. Applying the
// cumulative factors to the gross engine is equivalent to proportional funding
// of the cost at every rebalance. Gross traded notional excludes cash.
export function applyStrategyCosts(result,rebalances,costBps) {
  const intervals=result.quarterContributions, trades=[];
  for(let i=0;i<rebalances.length;i++) {
    const old=new Map();
    for(const h of i?intervals[i-1].contributions:[]) {
      const action=h.corporateActionResolution;
      // Settled cash is not sold again. A stock conversion is now the exact
      // successor claim and can net against that claim's new target weight.
      if(action?.considerationType==='cash')continue;
      const converted=['stock','stock_and_cash'].includes(action?.considerationType);
      const symbol=converted?action.successorTicker:h.priceSymbol??h.ticker;
      // Mixed consideration contains a settled cash leg: only the successor
      // security is traded at the next rebalance, never the merger cash.
      const stockFraction=action?.considerationType==='stock_and_cash'
        ? (action.successorPrice*action.successorSharesPerShare)/h.endPrice : 1;
      if (!Number.isFinite(stockFraction) || stockFraction<0 || stockFraction>1) throw new Error('invalid_mixed_consideration');
      old.set(symbol,(old.get(symbol)??0)+h.endingWeight*stockFraction);
    }
    const target=new Map();
    for(const h of rebalances[i].weights){const symbol=h.priceSymbol??h.ticker;target.set(symbol,(target.get(symbol)??0)+h.weight);}
    const turnover=total([...new Set([...old.keys(),...target.keys()])].map(t=>Math.abs((target.get(t)??0)-(old.get(t)??0))));
    trades.push({date:rebalances[i].executionDate,turnover,costFraction:turnover*costBps/10000});
  }
  let factor=1, cursor=0;
  const equity=result.equity.map(r=>{
    while(cursor<trades.length && trades[cursor].date<=r.date) {factor*=1-trades[cursor++].costFraction;}
    return {date:r.date,value:r.value*factor,gross:r.value};
  });
  return {equity,trades,costDrag:result.equity.at(-1).value-equity.at(-1).value};
}

export function runStrategyLab(data,rules) {
  const {dates,priceMaps,histories,valuations,comparisonPrices,actionFor}=data;
  const fullyInvested=rules.excludedAllocation==='fully_invested';
  const base={version:STRATEGY_LAB_VERSION,calculationVersion:STRATEGY_CALCULATION_VERSION,rules,ruleHash:signature(rules),sources:data.sources??{},requested:{start:rules.start,end:rules.end},retrospective:true,
    ...(fullyInvested?{selectionBasis:'eligible_subset_full_investment',strictGuruReplication:false}:{} )};
  const usableDates=dates.filter(d=>d<=rules.end);
  const end=usableDates.at(-1);
  if(!end || Date.parse(rules.end)-Date.parse(end)>5*day)return {...base,...fail('stale_benchmark',{lastDate:end??null})};
  const built=buildStrategySchedule({rules,histories,dates:usableDates});
  if(built.failure)return {...base,...fail(built.failure.code,built.failure)};
  const schedule=built.schedule, activeDates=usableDates.filter(d=>d>=schedule[0].executionDate);
  if(activeDates.length<20)return {...base,...fail('insufficient_observations')};
  const kinds=['guru','filtered','blend'], targets=Object.fromEntries(kinds.map(k=>[k,[]])), ledger=[];
  for(const event of schedule) {
    const n=event.holdings.length;
    const rows=event.holdings.map(h=>{
      const action=actionFor?.(h,event.executionDate)??{};
      const symbol=action.priceSymbol??h.priceSymbol??h.ticker;
      const resolved=!!h.identityResolved && !action.blocked && (action.cash || positive(priceMaps.get(symbol)?.get(event.executionDate)));
      const v=rules.valuationEnabled?valuationDecision(h,event.decisionDate,valuations,comparisonPrices):{status:'filter_off'};
      const status=!resolved?'execution_unavailable':action.cash?'corporate_action_cash':!rules.valuationEnabled?'included':v.status!=='comparable'?v.status:v.premium>rules.maxPremium+1e-12?'expensive':'included';
      return {...h,...v,status,resolved,originalWeight:1/n,action,priceSymbol:symbol};
    });
    const coverage=n?rows.filter(h=>h.resolved).length/n:0;
    if(!fullyInvested&&coverage<.9-1e-12)return {...base,...fail('execution_coverage_below_90',{date:event.executionDate,coverage,
      tickers:rows.filter(h=>!h.resolved).map(h=>h.ticker??h.cusip)}),ledger};
    const included=rows.filter(h=>h.status==='included'), expensive=rows.filter(h=>h.status==='expensive').length/n;
    if(fullyInvested&&!included.length)return {...base,...fail('no_eligible_stocks',{date:event.executionDate,
      selected:n,managerExclusions:event.managerExclusions,exclusions:rows.map(h=>({ticker:h.ticker,cusip:h.cusip,status:h.status}))}),ledger};
    const executable=rows.filter(h=>h.resolved&&!h.action.cash);
    const chosen=fullyInvested?1/included.length:rules.excludedAllocation==='redistribute' && included.length?1/n+expensive/included.length:1/n;
    const make=(kind)=>{
      const blend=kind==='blend', filtered=kind!=='guru', equityFraction=blend?1-rules.ctaWeight:1;
      const weights=rows.filter(h=>h.resolved&&!h.action.cash&&(!filtered||h.status==='included')).map(h=>({
        ticker:h.ticker,priceSymbol:h.priceSymbol,issuer:h.issuer,value:h.value,assetKind:'stock',
        weight:equityFraction*(filtered?chosen:fullyInvested?1/executable.length:1/n),...(h.action.corporateAction?{corporateAction:h.action.corporateAction}:{})
      }));
      if(blend&&rules.ctaWeight>0)weights.push({ticker:rules.cta,weight:rules.ctaWeight,issuer:rules.cta,assetKind:'cta'});
      return {executionDate:event.executionDate,reportDate:event.filings.at(-1).reportDate,weights,
        coveragePct:coverage,cashWeight:fullyInvested?0:Math.max(0,1-total(weights.map(w=>w.weight))),cashReason:'strategy_rules'};
    };
    for(const kind of kinds)targets[kind].push(make(kind));
    ledger.push({...event,holdings:rows.map(({action,identityResolved,...h})=>({...h,
      targetWeight:h.status==='included'?chosen*(1-rules.ctaWeight):0})),
      coverage,modelCoverage:rules.valuationEnabled?rows.filter(h=>h.premium!=null).length/n:null,
      included:included.length,expensive:rows.filter(h=>h.status==='expensive').length,
      unknown:rows.filter(h=>!['included','expensive','corporate_action_cash'].includes(h.status)).length,
      cashWeight:targets.blend.at(-1).cashWeight,ctaWeight:rules.ctaWeight,
      ...(fullyInvested?{redistributedWeight:(n-included.length)/n,
        executableCount:executable.length,selectionBasis:'eligible_subset_full_investment'}:{})});
  }
  return completeStrategyRun(data,rules,base,activeDates,targets,ledger);
}

// Shared execution, net trading costs, financing, benchmarks and snapshots.
// The composition engine supplies quarterly targets, not precomputed returns.
export function completeStrategyRun(data,rules,base,activeDates,targets,ledger) {
  const {priceMaps}=data,end=activeDates.at(-1),fullyInvested=rules.excludedAllocation==='fully_invested';
  const kinds=['guru','filtered','blend'],results={};
  for(const kind of kinds) {
    if(kind==='blend'&&rules.ctaWeight>0) {
      const missing=activeDates.find(d=>!positive(priceMaps.get(rules.cta)?.get(d)));
      if(missing){results[kind]=fail('cta_history_missing',{ticker:rules.cta,date:missing,available:data.sources?.etfs?.[rules.cta]??null});continue;}
    }
    if(kind==='blend'&&rules.ctaWeight>0&&rules.ctaPolicy) {
      if(results.filtered.status!=='ready'){results.blend=fail(results.filtered.failure.code,results.filtered.failure);continue;}
      for(const multiple of (rules.leverage.multiple>1?[1,rules.leverage.multiple]:[1])) {
        const out=simulateFlexibleCta({rules,targets:targets.filtered,dates:activeDates,priceMaps,multiple});
        results[multiple===1?'blend':'leveraged']={...out,metrics:out.status==='ready'?strategyMetrics(out.equity):null};
      }
      continue;
    }
    const gross=simulateDriftedPortfolio({rebalances:targets[kind],tradingDates:activeDates,priceMaps,endDate:end,allowExplicitCash:true});
    if(!gross.ok){results[kind]=fail(gross.failure?.code??'attribution_reconciliation_failed',gross.failure??{reconciliation:gross.reconciliation??null});continue;}
    // An acquisition settlement can create cash between disclosures. Do not
    // claim this new no-cash strategy succeeded unless reinvestment is modeled.
    if(fullyInvested){
      const cashAction=gross.quarterContributions.flatMap(q=>q.contributions??[])
        .find(h=>h.corporateActionResolution?.considerationType==='cash');
      if(cashAction){results[kind]=fail('cash_settlement_requires_reinvestment',{ticker:cashAction.ticker});continue;}
    }
    if(gross.equity.length!==activeDates.length){
      const sessions=gross.corporateActionTransitionSessions??[],covered=new Set(gross.equity.map(r=>r.date));
      results[kind]=fail('corporate_action_transition_requires_review',{
        date:activeDates.find(d=>!covered.has(d)),missingDates:activeDates.filter(d=>!covered.has(d)),
        tickers:[...new Set(sessions.flatMap(s=>s.actions.map(a=>a.ticker)))],transitions:sessions
      });continue;
    }
    const net=applyStrategyCosts(gross,targets[kind],rules.costBps);
    results[kind]={status:'ready',...net,metrics:strategyMetrics(net.equity)};
    if(kind==='blend'&&(rules.leverage?.multiple??1)>1) {
      const levered=financeStrategy(gross,targets.blend,rules.leverage,rules.costBps);
      results.leveraged={...levered,metrics:levered.status==='ready'?strategyMetrics(levered.equity):null};
    }
  }
  const spy=priceMaps.get('SPY');
  const benchmark=activeDates.every(d=>positive(spy?.get(d)))?activeDates.map(date=>({date,value:spy.get(date)/spy.get(activeDates[0])})):[];
  results.spy=benchmark.length?{status:'ready',equity:benchmark,metrics:strategyMetrics(benchmark)}:fail('missing_benchmark_price');
  const finalResult=(rules.leverage?.multiple??1)>1?(results.leveraged??results.blend):results.blend;
  const ready=finalResult.status==='ready';
  let holdingSnapshots=ready?ledger.map((event,index)=>{
    const L=rules.leverage?.multiple??1,positions=targets.blend[index].weights.map(h=>{
      const evidence=h.assetKind==='stock'?event.holdings.find(row=>row.ticker===h.ticker):null;
      return {ticker:h.ticker,issuer:h.issuer,kind:h.assetKind,
        weight:h.weight,exposureWeight:h.weight*L,managers:h.managers??evidence?.managers??[],
        ...(h.components?{components:h.components}:{}),
        price:evidence?.price??null,fairValue:evidence?.fairValue??null,modelDate:evidence?.modelDate??null,
        ...(evidence?.valuationLink?{modelTicker:evidence.modelTicker,valuationLink:evidence.valuationLink,comparisonPriceSource:evidence.comparisonPriceSource,priceDate:evidence.priceDate}:{}),
        premium:evidence?.premium??null};
    });
    return {id:signature({ruleHash:base.ruleHash,generation:data.sources,executionDate:event.executionDate}),
      date:event.executionDate,decisionDate:event.decisionDate,
      nextRebalanceDate:ledger[index+1]?.executionDate??null,
      throughDate:ledger[index+1]?.executionDate??end,
      nav:finalResult.equity.find(row=>row.date===event.executionDate)?.value??null,
      positions,cashWeight:event.cashWeight,borrowedWeight:Math.max(0,L*(1-event.cashWeight)-1),
      stockWeight:total(positions.filter(h=>h.kind==='stock').map(h=>h.weight)),ctaWeight:rules.ctaWeight,
      leverage:L,filings:event.filings,managerExclusions:event.managerExclusions??[],
      exclusions:event.holdings.filter(h=>h.targetWeight===0),
      executionCoverage:event.coverage,modelCoverage:event.modelCoverage,
      basis:'post_rebalance_target_weights',calculationVersion:base.calculationVersion};
  }):[];
  if(ready&&finalResult.snapshots)holdingSnapshots=finalResult.snapshots.map((snapshot,index)=>{
    const event=ledger.filter(e=>e.executionDate<=snapshot.date).at(-1);
    return {...snapshot,id:signature({ruleHash:base.ruleHash,generation:data.sources,date:snapshot.date}),
      decisionDate:snapshot.decisionDate??event.decisionDate,
      positions:snapshot.positions.map(h=>{const evidence=event.holdings.find(e=>e.ticker===h.ticker);return {...h,
        managers:h.managers??evidence?.managers??[],price:evidence?.price??null,fairValue:evidence?.fairValue??null,
        modelDate:evidence?.modelDate??null,premium:evidence?.premium??null,
        ...(evidence?.valuationLink?{modelTicker:evidence.modelTicker,valuationLink:evidence.valuationLink,comparisonPriceSource:evidence.comparisonPriceSource,priceDate:evidence.priceDate}:{})};}),
      nextRebalanceDate:finalResult.snapshots[index+1]?.date??null,throughDate:finalResult.snapshots[index+1]?.date??end,
      stockWeight:total(snapshot.positions.filter(h=>h.kind!=='cta').map(h=>h.weight)),
      filings:event.filings,managerExclusions:event.managerExclusions??[],exclusions:event.holdings.filter(h=>h.targetWeight===0),
      executionCoverage:event.coverage,modelCoverage:event.modelCoverage,equityDecisionDate:event.decisionDate,
      calculationVersion:`${base.calculationVersion}-${CTA_VERSION}`};
  });
  const completedLedger=ready&&finalResult.snapshots?ledger.map(event=>{
    const snapshot=holdingSnapshots.find(s=>s.date===event.executionDate);
    return {...event,ctaWeight:snapshot.ctaWeight,cashWeight:snapshot.cashWeight,
      holdings:event.holdings.map(h=>({...h,targetWeight:h.targetWeight>0?(snapshot.positions.find(p=>p.ticker===h.ticker)?.weight??0):0})),
      allocationBasis:'post_execution_actual_weights',ctaPolicy:rules.ctaPolicy};
  }):ledger;
  return {...base,...(rules.ctaPolicy?{calculationVersion:`${base.calculationVersion}-${CTA_VERSION}`} : {}),status:ready?'ready':'blocked',failure:ready?null:finalResult.failure,
    effective:{start:activeDates[0],end},results,ledger:completedLedger,holdingSnapshots,
    summary:{rebalances:ledger.length,minExecutionCoverage:Math.min(...ledger.map(l=>l.coverage)),
      minModelCoverage:rules.valuationEnabled?Math.min(...ledger.map(l=>l.modelCoverage)):null,
      latest:completedLedger.at(-1)},dataHash:signature({sources:data.sources,ledger:completedLedger})};
}
