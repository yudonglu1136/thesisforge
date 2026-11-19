import {finite, isoDate} from './investmentMath.js';
import {portfolioHistory} from './portfolioHistory.js';
import {portfolioPassiveIncome} from './portfolioIncome.js';

const date = x => { try { return isoDate(x); } catch { return null; } };
const sum = xs => xs.reduce((a,b)=>a+b,0);

// This is account evidence, not a backtest of today's positions. Never bridge
// different accounts' dates, currency groups, missing marks or cash flows.
export function portfolioHome(accounts, positions, currency) {
  const reportDates=[...new Set(accounts.map(a=>date(a.reportDate)))];
  const reportDate=reportDates.length===1?reportDates[0]:null;
  const maps=accounts.map(a=>{
    const m=new Map(), conflicts=new Set();
    for(const p of a.navHistory??[]) {
      if(!date(p.date)||!finite(p.nav)||p.nav<0||!date(a.reportDate)||p.date>a.reportDate)continue;
      if(m.has(p.date)&&m.get(p.date)!==p.nav)conflicts.add(p.date);
      m.set(p.date,p.nav);
    }
    for(const d of conflicts)m.delete(d);
    return m;
  });
  const firstPositiveDates=maps.map(m=>[...m.entries()].filter(([,v])=>v>0).map(([d])=>d).sort()[0]??null);
  const inceptionDates=accounts.map((a,i)=>{
    const explicit=date(a.inceptionDate)||date(a.dateOpened);
    const firstPos=firstPositiveDates[i];
    if(explicit)return firstPos&&explicit>firstPos?firstPos:explicit;
    const h=a.historyEvidence;
    if(!firstPos||h?.cashStatus!=='ready'||h?.tradeStatus!=='ready')return null;
    const from=date(h.fromDate);
    const earliest=[firstPos,...(h.realized??[]).map(r=>r.date),...(h.cashFlows??[]).map(r=>r.date),...(h.income??[]).map(r=>r.date)].filter(Boolean).sort()[0];
    return from&&earliest&&from<earliest?firstPos:null;
  });
  const candidateDates=currency&&maps.length?[...new Set(maps.flatMap(m=>[...m.keys()]))].sort():[];
  const navHistory=candidateDates.filter(d=>maps.every((m,i)=>{
    if(m.has(d))return true;
    const inc=inceptionDates[i],firstPos=firstPositiveDates[i],rep=date(accounts[i]?.reportDate);
    return Boolean(inc&&d<inc&&(!firstPos||d<firstPos)&&rep&&d<=rep);
  })).map(d=>({date:d,nav:sum(maps.map(m=>m.get(d)??0))})).filter(r=>r.nav>0||maps.every(m=>m.has(r.date)));
  const snapshotsAligned=!!currency&&!!reportDate;
  const accountValue=snapshotsAligned&&accounts.every(a=>finite(a.reportedNav))?sum(accounts.map(a=>a.reportedNav)):null;
  const dailyAccounts=accounts.map(a=>a.dailyMtm);
  const dailyReady=snapshotsAligned&&dailyAccounts.every(d=>d?.date===reportDate&&d?.basis==='ibkr_instrument_mtm_in_base'&&d.rows?.length&&d.rows.every(r=>finite(r.pnl)));
  const combine = rows => {
    const result=new Map();
    for(const r of rows) {
      // Instrument identity, not the underlying ticker. Do not merge option
      // strikes/expiries into an equity's winner/loser figure.
      const key=`${r.instrumentId??r.ticker}:${r.assetCategory??'STK'}`;
      const old=result.get(key);
      result.set(key,{...r,pnl:(old?.pnl??0)+r.pnl});
    }
    return [...result.values()].sort((a,b)=>b.pnl-a.pnl);
  };
  const dailyRows=dailyReady?combine(dailyAccounts.flatMap(a=>a.rows)):[];
  const unrealized=positions.filter(p=>p.kind==='equity'&&finite(p.unrealizedPnl))
    .map(p=>({ticker:p.ticker,name:p.name,assetCategory:p.assetCategory,pnl:p.unrealizedPnl}));
  const history=portfolioHistory(accounts,navHistory);
  return {version:'portfolio-home-v2',reportDate,reportDates,accountValue,
    history,
    passiveIncome:portfolioPassiveIncome(accounts,currency),
    nav:{status:navHistory.length>=2?'ready':navHistory.length===1?'single_observation':'history_required',
      basis:'broker_account_value_not_cash_flow_adjusted_return',rows:navHistory,accountCount:accounts.length},
    daily:{status:dailyReady?'ready':'daily_mtm_required',date:reportDate,
      basis:'reported_instrument_mtm_in_base_not_whole_account_return',rows:dailyRows,
      pnl:dailyReady?sum(dailyRows.map(r=>r.pnl)):null},
    unrealized:{status:!snapshotsAligned?'report_dates_or_currency_required':unrealized.length?'ready':'cost_basis_required',date:reportDate,rows:snapshotsAligned?combine(unrealized):[],
      covered:unrealized.length,total:positions.filter(p=>p.kind==='equity').length,
      basis:'open_equities_report_marks_minus_report_cost_basis_not_daily_pnl'},
  };
}
