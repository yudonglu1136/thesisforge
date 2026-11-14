import {assert,finite} from './investmentMath.js';
import {allocateAtClose,markPositions} from './backtestEngine.js';

export const CTA_VERSION='independent-cta-v1';
const sum=xs=>xs.reduce((a,b)=>a+b,0), epsilon=1e-10;
export function ctaPolicyRules(value,weight,allocation) {
  if(value==null)return null; // Old saved rules retain their original synchronized policy.
  assert(value&&typeof value==='object'&&!Array.isArray(value),'invalid_cta_policy');
  const {mode,frequency='quarterly',minWeight=Math.min(.15,weight),trancheWeight=.05,
    trimThresholds=[.15,.25,.35],buyThresholds=[.08,.12,.18],cooldownSessions=5}=value;
  assert(['hold','scheduled','tranches'].includes(mode),'invalid_cta_policy_mode');
  assert(['monthly','quarterly','annually'].includes(frequency),'invalid_cta_frequency');
  assert(allocation==='fully_invested','flexible_cta_requires_full_investment');
  assert(finite(minWeight)&&minWeight>=0&&minWeight<=weight,'invalid_cta_min_weight');
  assert(finite(trancheWeight)&&trancheWeight>0&&trancheWeight<=.5,'invalid_cta_tranche');
  for(const levels of [trimThresholds,buyThresholds])assert(Array.isArray(levels)&&levels.length>=1&&levels.length<=8&&
    levels.every((v,i)=>finite(v)&&v>0&&v<1&&(i===0||v>levels[i-1])),'invalid_cta_thresholds');
  assert(buyThresholds.length>=trimThresholds.length,'cta_buy_levels_must_cover_trims');
  assert(Number.isInteger(cooldownSessions)&&cooldownSessions>=0&&cooldownSessions<=252,'invalid_cta_cooldown');
  return {mode,frequency,minWeight,trancheWeight,trimThresholds:[...trimThresholds],buyThresholds:[...buyThresholds],cooldownSessions};
}
const period=(d,frequency)=>frequency==='annually'?d.slice(0,4):frequency==='monthly'?d.slice(0,7):`${d.slice(0,4)}-${Math.floor((Number(d.slice(5,7))-1)/3)}`;

// Both sleeves own units, not a daily weighted return. The existing strict
// marker resolves securities and corporate actions. CTA signals use its stored
// total-return series at t-1 and execute at t close. No new source/price fallback.
export function simulateFlexibleCta({rules,targets,dates,priceMaps,multiple=1}) {
  const policy=rules.ctaPolicy,k=rules.costBps/10000,ctaPrices=priceMaps.get(rules.cta);
  const equityEvents=new Map(targets.map(t=>[t.executionDate,t]));
  let active=null,metadata=new Map(),ctaUnits=0,debt=0,previousDate=null;
  let anchor=null,peak=null,frozenPeak=null,outstanding=0,usedTrims=new Set(),usedBuys=new Set(),lastTrade=-Infinity;
  let interestPaid=0,costPaid=0,maxDebtToEquity=0;
  const equity=[],trades=[],ctaEvents=[],allocationHistory=[],snapshots=[],financing=[];
  const fail=(code,date,extra={})=>({status:'blocked',failure:{code,date,...extra},equity:[],metrics:null});
  for(let i=0;i<dates.length;i++) {
    const date=dates[i],price=ctaPrices?.get(date);
    if(!finite(price)||price<=0)return fail('cta_history_missing',date);
    const days=previousDate?(Date.parse(date)-Date.parse(previousDate))/86400000:0;
    const interest=debt*.04*days/365;debt+=interest;interestPaid+=interest;
    const marked=active?markPositions(active,date,priceMaps):{ok:true,portfolioValue:0,values:[]};
    if(!marked.ok)return fail(marked.failure.code,date,marked.failure);
    if(marked.transitionPending?.length)return fail('corporate_action_transition_requires_review',date);
    if(marked.values.some(h=>['cash','stock_and_cash'].includes(h.corporateActionResolution?.considerationType)))return fail('cash_settlement_requires_reinvestment',date);
    const beforeCta=ctaUnits*price,beforeEquity=marked.portfolioValue;
    const beforeAssets=beforeEquity+beforeCta,nav=i?beforeAssets-debt:1;
    if(!(nav>0))return fail('leverage_equity_exhausted',date);
    const equityTarget=equityEvents.get(date),resetLeverage=!!equityTarget;
    let trigger=i===0?{reason:'initial_allocation',target:rules.ctaWeight}:null;
    let signalPrice=null,signalDate=null,signalPeak=null,signalReturn=null;
    if(i>0) {
      signalDate=dates[i-1];signalPrice=ctaPrices.get(signalDate);
      peak=Math.max(peak,signalPrice);signalPeak=frozenPeak??peak;
      if(policy.mode==='scheduled'&&period(date,policy.frequency)!==period(signalDate,policy.frequency))
        trigger={reason:'scheduled_rebalance',target:rules.ctaWeight};
      if(policy.mode==='tranches'&&i-lastTrade>policy.cooldownSessions) {
        const drawdown=1-signalPrice/signalPeak,up=signalPrice/anchor-1;
        const buy=policy.buyThresholds.findIndex((v,n)=>!usedBuys.has(n)&&drawdown+epsilon>=v);
        const trim=policy.trimThresholds.findIndex((v,n)=>!usedTrims.has(n)&&up+epsilon>=v);
        if(outstanding>epsilon&&buy>=0) {
          const step=Math.min(policy.trancheWeight,outstanding);
          trigger={reason:'drawdown_buyback',target:rules.ctaWeight-outstanding+step,level:buy,step};signalReturn=-drawdown;
        } else if(frozenPeak===null&&trim>=0&&rules.ctaWeight-outstanding>policy.minWeight+epsilon) {
          const step=Math.min(policy.trancheWeight,rules.ctaWeight-outstanding-policy.minWeight);
          trigger={reason:'rally_trim',target:rules.ctaWeight-outstanding-step,level:trim,step};signalReturn=up;
        }
      }
    }
    // A crossed threshold is not itself a trade: market drift can already put
    // the sleeve past the requested target. Do not create phantom snapshots,
    // fees, cooldowns or consumed ladder stages for those no-ops.
    const proposedAssets=resetLeverage?multiple*nav:beforeAssets;
    if(trigger?.reason==='rally_trim'&&trigger.target*proposedAssets>=beforeCta-epsilon)trigger=null;
    if(trigger?.reason==='drawdown_buyback'&&trigger.target*proposedAssets<=beforeCta+epsilon)trigger=null;
    let navAfter=nav;
    if(equityTarget||trigger) {
      // Mark the existing equity names; stock consideration becomes its audited
      // successor, never a stale predecessor re-entry on a CTA-only rebalance.
      const drifted=marked.values.map(h=>{
        const action=h.corporateActionResolution,successor=action?.considerationType==='stock'?action.successorTicker:null;
        const prior=metadata.get(h.ticker),weight=h.endValue/beforeEquity;
        return {...prior,ticker:successor??h.ticker,priceSymbol:successor??h.priceSymbol??h.ticker,
          ...(prior?.components?{components:Object.fromEntries(Object.entries(prior.components).map(([key,v])=>[key,v*weight/prior.weight]))}:{}),
          ...(successor?{corporateAction:undefined,corporateActionResolution:undefined}:{}),weight};
      });
      const next=equityTarget?.weights??drifted;
      if(!next.length||Math.abs(sum(next.map(h=>h.weight))-1)>epsilon)return fail('flexible_cta_requires_full_investment',date);
      const old=new Map();
      for(const h of drifted)old.set(h.priceSymbol??h.ticker,(old.get(h.priceSymbol??h.ticker)??0)+h.weight*beforeEquity);
      const relative=new Map();
      for(const h of next)relative.set(h.priceSymbol??h.ticker,(relative.get(h.priceSymbol??h.ticker)??0)+h.weight);
      const symbols=[...new Set([...old.keys(),...relative.keys()])];
      const allocation=after=>{
        const assets=resetLeverage?multiple*after:after+debt;
        let cta=trigger?assets*trigger.target:beforeCta;
        // A trim can only sell, a recovery can only buy, even after a gap/drift.
        if(trigger?.reason==='rally_trim')cta=Math.min(beforeCta,cta);
        if(trigger?.reason==='drawdown_buyback')cta=Math.max(beforeCta,cta);
        const stocks=assets-cta;
        const turnover=Math.abs(cta-beforeCta)+sum(symbols.map(s=>Math.abs(stocks*(relative.get(s)??0)-(old.get(s)??0))));
        return {assets,cta,stocks,turnover};
      };
      let lo=0,hi=nav;
      for(let n=0;n<70;n++){const mid=(lo+hi)/2;if(mid+k*allocation(mid).turnover>nav)hi=mid;else lo=mid;}
      navAfter=k===0?nav:(lo+hi)/2;
      const a=allocation(navAfter),cost=k*a.turnover;
      if(!(a.stocks>0)||!(navAfter>0)||Math.abs(nav-navAfter-cost)>1e-9)return fail('cta_allocation_not_feasible',date);
      active=allocateAtClose({executionDate:date,weights:next,cashWeight:0},a.stocks,priceMaps,true);
      if(!active.ok)return fail(active.failure.code,date,active.failure);
      metadata=new Map(next.map(h=>[h.ticker,h]));
      ctaUnits=a.cta/price;if(resetLeverage)debt=(multiple-1)*navAfter;
      costPaid+=cost;
      const delta=a.cta-beforeCta,executed=trigger&&(trigger.reason==='initial_allocation'||trigger.reason==='scheduled_rebalance'||Math.abs(delta)>epsilon);
      if(executed) {
        if(trigger.reason==='initial_allocation'){anchor=price;peak=price;}
        if(trigger.reason==='rally_trim'){usedTrims.add(trigger.level);outstanding+=trigger.step;lastTrade=i;}
        if(trigger.reason==='drawdown_buyback') {
          frozenPeak??=signalPeak;usedBuys.add(trigger.level);outstanding=Math.max(0,outstanding-trigger.step);lastTrade=i;
          if(outstanding<epsilon){anchor=price;peak=price;frozenPeak=null;usedTrims=new Set();usedBuys=new Set();}
        }
        ctaEvents.push({date,signalDate,reason:trigger.reason,level:trigger.level==null?null:trigger.level+1,
          signalPrice,signalPeak,signalReturn,targetWeight:trigger.target,weightBefore:i?beforeCta/beforeAssets:0,
          weightAfter:a.cta/a.assets,exposureAfter:a.cta/navAfter,ctaNotionalChange:delta,ctaUnits,
          outstandingTranchesWeight:outstanding,cost,equityRebalanced:!!equityTarget});
      }
      trades.push({date,navBefore:nav,navAfter,tradedNotional:a.turnover,cost,riskyWeight:a.assets/navAfter,
        borrowed:debt,cash:0,ctaNotionalChange:delta,equityRebalanced:!!equityTarget,
        reason:executed?trigger.reason:'equity_rebalance'});
      const positions=next.map(h=>({...h,kind:h.assetKind??'stock',weight:h.weight*a.stocks/a.assets,exposureWeight:h.weight*a.stocks/navAfter,
        ...(h.components?{components:Object.fromEntries(Object.entries(h.components).map(([key,v])=>[key,v*a.stocks/a.assets]))}:{})}));
      if(a.cta>epsilon)positions.push({ticker:rules.cta,issuer:rules.cta,kind:'cta',weight:a.cta/a.assets,exposureWeight:a.cta/navAfter});
      snapshots.push({date,decisionDate:signalDate,positions,ctaWeight:a.cta/a.assets,cashWeight:0,borrowedWeight:debt/navAfter,
        leverage:a.assets/navAfter,nav:navAfter,ctaEvent:executed?ctaEvents.at(-1):null,basis:'post_execution_actual_weights'});
    }
    const assets=navAfter+debt;
    allocationHistory.push({date,ctaWeight:ctaUnits*price/assets,ctaExposure:ctaUnits*price/navAfter,ctaUnits,cashWeight:0});
    maxDebtToEquity=Math.max(maxDebtToEquity,debt/navAfter);
    financing.push({date,days,interest,debt,nav:navAfter});
    equity.push({date,value:navAfter});previousDate=date;
  }
  return {status:'ready',equity,trades,ctaEvents,allocationHistory,snapshots,
    financing:{version:CTA_VERSION,annualRate:.04,dayCount:'ACT/365',interestPaid,costPaid,maxDebtToEquity,rows:financing},
    methodology:{version:CTA_VERSION,signal:'prior_session_total_return_close',execution:'next_session_close',
      weights:'fraction_of_gross_assets',ctaUnits:'total_return_units_with_distributions_reinvested',cashWeight:0,
      leverageReset:'equity_rebalances_only',policy}};
}
