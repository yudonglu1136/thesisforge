// Preserve published adjusted-price observations. Append only observed future
// returns, expressed in the old adjusted units at an exact common-date anchor.
// This does not overwrite canonical quotes, revise old NAV, or infer a missing
// execution/corporate-action price. The caller must replay the complete ledger
// and retain the existing historical NAV and cost reconciliation gates.
export function extendPublishedPriceVintage(snapshot, ledger, current) {
  if (ledger.snapshotId !== snapshot.snapshotId) throw new Error('vintage_snapshot_mismatch');
  const prices=new Map(),bridges={};
  function put(ticker,date,price){
    if(!(Number.isFinite(price)&&price>0))throw new Error('vintage_invalid_price');
    if(date>snapshot.dataThrough)throw new Error('vintage_future_recorded_price');
    if(!prices.has(ticker))prices.set(ticker,new Map());
    const rows=prices.get(ticker),old=rows.get(date);
    if(old!==undefined&&Math.abs(old-price)>1e-10*Math.max(1,Math.abs(old)))
      throw new Error('vintage_conflicting_price');
    rows.set(date,price);
  }
  for(const style of ledger.styles){
    const source=snapshot.styles.find(s=>s.id===style.id);
    if(!source)throw new Error('vintage_style_mismatch');
    for(const segment of style.segments??[style]){
      for(const day of segment.days)for(const [ticker,mark] of day.positions){
        if(mark.basis==='cash_entitlement')continue;
        if(mark.basis==='total_return_adjusted_close')put(ticker,day.date,mark.price);
        else if(mark.basis==='equivalent_source_adjusted_unit'){
          const matches=(source.corporateActions??[]).filter(a=>a.ticker===ticker&&a.effectiveDate<=day.date&&
            ['stock','stock_and_cash'].includes(a.considerationType));
          if(matches.length!==1)throw new Error('vintage_exchange_ambiguous');
          const a=matches[0],cash=a.considerationType==='stock_and_cash'?a.terminalCashEntitlementPerShare:0;
          if(!(Number.isFinite(cash)&&a.successorSharesPerShare>0&&a.successorTicker))throw new Error('vintage_exchange_invalid');
          put(a.successorTicker,day.date,(mark.price-cash)/a.successorSharesPerShare);
        }else throw new Error('vintage_unknown_price_basis');
      }
      for(const event of segment.events)if(['buy','sell','fee'].includes(event.side)&&event.basis==='total_return_adjusted_close')
        put(event.tradedTicker??event.ticker,event.date,event.price);
    }
  }
  for(const row of snapshot.backtest.curve)put('SPY',row.date,row.spy);
  for(const [ticker,observations] of current){
    const future=[...observations].filter(([d])=>d>snapshot.dataThrough).sort(([a],[b])=>a.localeCompare(b));
    if(!future.length)continue;
    const recorded=prices.get(ticker),anchor=recorded&&[...recorded.keys()].filter(d=>observations.has(d)).sort().at(-1);
    if(!anchor)throw new Error('vintage_anchor_missing:'+ticker);
    const before=observations.get(anchor);
    if(!(Number.isFinite(before)&&before>0))throw new Error('vintage_invalid_anchor');
    const factor=recorded.get(anchor)/before;
    bridges[ticker]={date:anchor,recordedPrice:recorded.get(anchor),currentPrice:before,factor};
    for(const [d,p] of future){
      if(!(Number.isFinite(p)&&p>0))throw new Error('vintage_invalid_price');
      recorded.set(d,p*factor);
    }
  }
  return {prices,bridges,basis:'published_adjusted_units_observed_forward_returns_v1'};
}
