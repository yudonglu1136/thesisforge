import {brokerStatementHistory} from './portfolioHistory.js';
// Untouched broker units, one account/report grain. No legacy display guesses.
export function reportRows(value, key) {
  if(!value || typeof value!=='object')return [];
  return Object.entries(value).flatMap(([k,v])=>k===key?[].concat(v):reportRows(v,key));
}
const num=v=>v===null||v===undefined||v===''||typeof v==='boolean'?null:Number.isFinite(Number(v))?Number(v):null;
const first=(r,keys)=>keys.map(k=>num(r[k])).find(x=>x!==null)??null;
const date=v=>{const s=String(v??'').replace(/^(\d{4})(\d{2})(\d{2})$/,'$1-$2-$3');const ms=Date.parse(s);return /^\d{4}-\d{2}-\d{2}$/.test(s)&&Number.isFinite(ms)&&new Date(ms).toISOString().slice(0,10)===s?s:null;};
export function reportAnalysisAccounts(parsed, {historyParsed=null}={}) {
  return reportRows(parsed,'FlexStatement').map((s,index)=>{
    const info=reportRows(s,'AccountInformation')[0]??{};
    const currency=String(info.currency||s.currency||s.reportCurrency||'');
    const reportDate=date(s.toDate||s.fromDate);
    const summaries=reportRows(s,'EquitySummaryByReportDateInBase');
    // A history query is joined only by the same broker account identity AND
    // base currency. Array order or a single foreign account is not a match.
    const accountId=s.accountId||info.accountId;
    const history=accountId?reportRows(historyParsed,'FlexStatement').filter(h=>
      (h.accountId||reportRows(h,'AccountInformation')[0]?.accountId)===accountId&&
      String(reportRows(h,'AccountInformation')[0]?.currency||h.currency||h.reportCurrency||'')===currency):[];
    const historyRows=history.flatMap(h=>reportRows(h,'EquitySummaryByReportDateInBase'));
    // Choose one complete statement, never concatenate overlapping trade/cash
    // reports (which would double-count realised P&L and deposits).
    const evidenceReport=[s,...history].filter(h=>date(h.fromDate)&&date(h.toDate)===reportDate)
      .sort((a,b)=>date(a.fromDate).localeCompare(date(b.fromDate)))[0];
    const historyEvidence=evidenceReport?brokerStatementHistory(evidenceReport,currency,reportRows):null;
    const nav=summaries.find(r=>date(r.reportDate)===reportDate)??(summaries.length===1?summaries[0]:{});
    const rows=['OpenPosition','Position','Holding'].flatMap(k=>reportRows(s,k));
    const positions=rows.map(r=>{
      const originalTicker=String(r.symbol||r.ticker||'').trim();
      const lseg=(r.isin||r.securityID)==='GB00B0SWJX34'&&r.currency==='GBP'&&r.listingExchange==='LSE';
      return {ticker:lseg?'LSEG':originalTicker.toUpperCase(),originalTicker,
        name:String(r.description||r.name||originalTicker),cusip:r.cusip||null,isin:r.isin||null,
        assetCategory:String(r.assetCategory||r.category||''),currency:String(r.currency||r.currencyPrimary||''),
        quantity:first(r,['quantity','position','shares','units']),price:first(r,['markPrice','price','closePrice']),
        localValue:first(r,['positionValue','marketValue','value']),fxRateToBase:first(r,['fxRateToBase','fxRate']),
        costBasisMoney:num(r.costBasisMoney),
        multiplier:num(r.multiplier),strike:num(r.strike),expiry:date(r.expiry),
        identity:lseg?'ISIN_GB00B0SWJX34_LSE_GBP':'reported_symbol'};
    });
    const cashRows=reportRows(s,'CashReportCurrency').filter(r=>r.currency==='BASE_SUMMARY'||r.levelOfDetail==='BaseCurrency');
    const cash=first(nav??{},['cash'])??(cashRows.length===1?first(cashRows[0],['endingCash']):null);
    if(cash!==null)positions.push({ticker:'CASH',name:'Base currency cash',assetCategory:'CASH',currency,quantity:cash,price:1,localValue:cash,fxRateToBase:1});
    for(const field of ['dividendAccruals','interestAccruals']) {
      const value=num(nav?.[field]);
      if(value!==null&&value!==0)positions.push({ticker:field==='dividendAccruals'?'DIV.ACCRUAL':'INT.ACCRUAL',name:field,
        assetCategory:'ACCRUAL',currency,quantity:value,price:1,localValue:value,fxRateToBase:1});
    }
    // IBKR MTM is statement-period P&L. A monthly/undated statement must never
    // become a daily winner list. Only explicit instrument totals in base pass.
    const mtm=reportRows(s,'MTMPerformanceSummaryInBase').flatMap(x=>reportRows(x,'MTMPerformanceSummaryUnderlying'));
    const dailyRows=mtm.filter(r=>r.symbol).map(r=>({ticker:String(r.symbol),name:String(r.description||r.symbol),
      assetCategory:String(r.assetCategory||''),instrumentId:String(r.conid||r.symbol),pnl:num(r.total)}));
    const dailyMtm=date(s.fromDate)===reportDate&&reportDate&&dailyRows.length&&dailyRows.every(r=>r.pnl!==null)&&
      new Set(dailyRows.map(r=>`${r.instrumentId}:${r.assetCategory}`)).size===dailyRows.length
      ?{date:reportDate,basis:'ibkr_instrument_mtm_in_base',rows:dailyRows}:null;
    return {accountId:accountId?String(accountId):null,currency,reportDate,reportedNav:num(nav?.total),accountNumber:index+1,positions,dailyMtm,historyEvidence,
      navHistory:[...historyRows,...summaries].map(r=>({date:date(r.reportDate),nav:num(r.total)})).filter(r=>r.date&&r.nav!==null&&reportDate&&r.date<=reportDate),
      performanceBasis:'nav_only_external_flows_not_reconciled'};
  });
}
