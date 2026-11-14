import {assert,finite} from './investmentMath.js';

const DAY=86400000;
const sum=xs=>xs.reduce((a,b)=>a+b,0);
export function leverageRules(value) {
  const v=value??{multiple:1,annualRate:.04,reset:'filing'};
  assert(v&&typeof v==='object'&&!Array.isArray(v),'invalid_leverage');
  assert(finite(v.multiple)&&v.multiple>=1&&v.multiple<=2,'invalid_leverage_multiple');
  assert(v.annualRate===.04,'leverage_rate_must_be_4_percent');
  assert(v.reset==='filing','invalid_leverage_reset');
  return {multiple:v.multiple,annualRate:.04,reset:'filing'};
}

// Reuse the audited unlevered engine's marked returns and corporate-action
// resolutions. Positions/debt reset only at disclosure rebalances, not daily.
// Borrow only after target cash has offset funding needs; interest capitalizes
// at each observed close using ACT/365, including weekends and holidays.
export function financeStrategy(gross,targets,config,costBps) {
  const {multiple:L,annualRate}=leverageRules(config),k=costBps/10000;
  assert(gross.ok&&gross.equity.length&&targets.length,'leverage_base_unavailable');
  let entryEquity=1,baseEntry=1,debt=0,interestInterval=0,interestPaid=0,costPaid=0,index=0,previousDate=null,maxDebtToEquity=0;
  const equity=[],trades=[],financing=[];
  const failed=(code,date,value)=>({status:'blocked',failure:{code,date,equity:value},equity:[],metrics:null,
    financing:{annualRate,dayCount:'ACT/365',interestPaid,costPaid,rows:financing},trades});
  for(const row of gross.equity) {
    const days=previousDate?(Date.parse(row.date)-Date.parse(previousDate))/DAY:0;
    const interest=debt*annualRate*days/365;
    debt+=interest;interestInterval+=interest;interestPaid+=interest;
    let value=entryEquity*(1+L*(row.value/baseEntry-1))-interestInterval;
    if(!(value>0)||!Number.isFinite(value))return failed('leverage_equity_exhausted',row.date,value);
    const target=targets[index];
    if(target&&target.executionDate===row.date) {
      const old=new Map();
      const factor=entryEquity*L*row.value/baseEntry;
      for(const h of index?gross.quarterContributions[index-1].contributions:[]) {
        const a=h.corporateActionResolution;
        if(a?.considerationType==='cash')continue;
        const converted=['stock','stock_and_cash'].includes(a?.considerationType);
        const t=converted?a.successorTicker:h.priceSymbol??h.ticker;
        const stockFraction=a?.considerationType==='stock_and_cash'?(a.successorPrice*a.successorSharesPerShare)/h.endPrice:1;
        old.set(t,(old.get(t)??0)+factor*h.endingWeight*stockFraction);
      }
      const next=new Map();
      for(const h of target.weights) {const t=h.priceSymbol??h.ticker;next.set(t,(next.get(t)??0)+L*h.weight);}
      const symbols=[...new Set([...old.keys(),...next.keys()])];
      const turnover=x=>sum(symbols.map(t=>Math.abs(x*(next.get(t)??0)-(old.get(t)??0))));
      // Self-financing post-fee targets: NAV_after + cost(actual trades) = NAV_before.
      if(k*turnover(0)>=value)return failed('leverage_cost_exhausted',row.date,value);
      let lo=0,hi=value;
      for(let n=0;n<70;n++){const mid=(lo+hi)/2;if(mid+k*turnover(mid)>value)hi=mid;else lo=mid;}
      const after=k===0?value:(lo+hi)/2,tradeCost=k*turnover(after),riskyWeight=sum([...next.values()]);
      const principal=Math.max(0,riskyWeight-1)*after;
      trades.push({date:row.date,navBefore:value,navAfter:after,tradedNotional:turnover(after),cost:tradeCost,
        riskyWeight,borrowed:principal,cash:Math.max(0,1-riskyWeight)*after,interestSincePriorRebalance:interestInterval});
      costPaid+=tradeCost;entryEquity=after;baseEntry=row.value;debt=principal;interestInterval=0;value=after;index++;
    }
    maxDebtToEquity=Math.max(maxDebtToEquity,debt/value);
    financing.push({date:row.date,days,interest,debt,nav:value});
    equity.push({date:row.date,value});previousDate=row.date;
  }
  return {status:'ready',equity,trades,financing:{version:'filing-reset-leverage-v1',annualRate,dayCount:'ACT/365',
    interestPaid,costPaid,maxDebtToEquity,rows:financing,reset:'filing',cashYield:0,
    limitations:'Not broker execution. No margin calls, liquidation threshold, changing interest rates or lending constraints. Debt is held until the next disclosure rebalance; interest capitalizes at observed closes.'}};
}
