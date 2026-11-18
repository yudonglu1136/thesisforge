import fs from 'node:fs';
import {DatabaseSync} from 'node:sqlite';
import {signature} from './investmentMath.js';

const fail=(code)=>{throw Object.assign(new Error(code),{status:422});};
const check=(ok,code)=>{if(!ok)fail(code);};
export const hedgeVersion='qqq-expiry-hedge-v1';
export function hedgeRules(input){
 const date=String(input?.date??''),expiry=String(input?.expiry??'');
 const validDate=s=>/^\d{4}-\d{2}-\d{2}$/.test(s)&&!Number.isNaN(Date.parse(s+'T00:00:00Z'))&&new Date(s).toISOString().slice(0,10)===s;
 check(validDate(date)&&validDate(expiry)&&expiry>date,'hedge_invalid_date');
 const shares=Number(input.shares),coverage=Number(input.coverage),fee=Number(input.fee),slippage=Number(input.slippage);
 check(Number.isInteger(shares)&&shares>=100&&shares<=1000000,'hedge_invalid_shares');
 check(Number.isFinite(coverage)&&coverage>0&&coverage<=1,'hedge_invalid_coverage');
 check(Number.isFinite(fee)&&fee>=0&&fee<=10&&Number.isFinite(slippage)&&slippage>=0&&slippage<=.5,'hedge_invalid_cost');
 check(Math.floor(shares*coverage/100)>=1,'hedge_zero_contracts');
 const tickers=['putTicker','shortPutTicker','callTicker'];
 for(const key of tickers)check(typeof input[key]==='string'&&/^O:QQQ\d{6}[CP]\d{8}$/.test(input[key]),'hedge_invalid_contract');
 return {date,expiry,shares,coverage,fee,slippage,...Object.fromEntries(tickers.map(k=>[k,input[k]]))};
}
export function hedgeExperiment(input,chain,spot){
 const rules=hedgeRules(input);check(Number.isFinite(spot)&&spot>0,'hedge_underlying_missing');
 const contracts=Math.floor(rules.shares*rules.coverage/100),units=100*contracts;
 const find=(ticker,type)=>{
  const row=chain.find(c=>c.ticker===ticker);
  check(row&&row.type===type&&row.expiry===rules.expiry&&row.date===rules.date,'hedge_contract_not_available');
  check(row.standard===1&&row.multiplier===100,'hedge_nonstandard_contract');
  check(Number.isFinite(row.close)&&row.close>0&&row.volume>0,'hedge_untraded_contract');
  check(row.close+1e-8>=Math.max(0,type==='put'?row.strike-spot:spot-row.strike),'hedge_inconsistent_close');
  return row;
 };
 const put=find(rules.putTicker,'put'),shortPut=find(rules.shortPutTicker,'put'),call=find(rules.callTicker,'call');
 check(shortPut.strike<put.strike&&put.strike<=spot&&call.strike>=spot,'hedge_invalid_strike_order');
 check(put.close>=shortPut.close&&put.close-shortPut.close<put.strike-shortPut.strike,'hedge_inconsistent_spread');
 const definitions={unhedged:[],protective_put:[[put,1]],collar:[[put,1],[call,-1]],put_spread:[[put,1],[shortPut,-1]]};
 const evaluate=(legs,s)=>legs.reduce((v,[c,side])=>v+side*units*Math.max(0,c.type==='put'?c.strike-s:s-c.strike),0);
 const scenarioMoves=[-.5,-.3,-.2,-.1,-.05,0,.05,.1,.2,.3,.5];
 const prices=[...new Set([0,spot,put.strike,shortPut.strike,call.strike,...Array.from({length:91},(_,i)=>spot*i/60)])].sort((a,b)=>a-b);
 const results=Object.entries(definitions).map(([strategy,legs])=>{
  const premium=legs.reduce((v,[c,side])=>v+side*c.close*units,0);
  const costs=legs.reduce((v,[c])=>v+units*c.close*rules.slippage+contracts*rules.fee,0);
  const netDebit=premium+costs,initialCapital=rules.shares*spot+netDebit;
  check(initialCapital>0,'hedge_invalid_capital');
  const pnl=s=>rules.shares*(s-spot)+evaluate(legs,s)-netDebit;
  return {strategy,premium,costs,netDebit,initialCapital,contracts:legs.length?contracts:0,
   maxLoss:-Math.min(pnl(0),pnl(put.strike),pnl(shortPut.strike),pnl(call.strike),0),
   maxGain:strategy==='collar'&&units===rules.shares?pnl(call.strike):null,
   protectionFloor:strategy==='protective_put'||strategy==='collar'?put.strike:null,
   protectionEnds:strategy==='put_spread'?shortPut.strike:null,
   legs:legs.map(([c,side])=>({ticker:c.ticker,type:c.type,strike:c.strike,side,contracts,mark:c.close,
    assumedFill:c.close*(1+side*rules.slippage),volume:c.volume,date:c.date,provider:c.provider})),
   curve:prices.map(s=>({price:s,pnl:pnl(s)})),
   scenarios:scenarioMoves.map(move=>({move,price:spot*(1+move),pnl:pnl(spot*(1+move)),returnOnInitialCapital:pnl(spot*(1+move))/initialCapital}))};
 });
 return {version:hedgeVersion,status:'scenario_only',rules,spot,contracts,coveredShares:units,uncoveredShares:rules.shares-units,
  actualCoverage:units/rules.shares,results,sourceHash:signature({rules,spot,chain:[put,shortPut,call]}),
  limitations:['daily_close_not_bid_ask','expiry_not_path_backtest','early_assignment_dividends_and_tax_not_modelled','QQQ_not_other_portfolio_proxy']};
}

export class HedgeSource {
 constructor(file){
  if(!file||!fs.existsSync(file))throw Object.assign(new Error('hedge_database_not_configured'),{status:503});
  this.db=new DatabaseSync(file,{readOnly:true});this.db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=5000');
  if(this.db.prepare("SELECT value FROM hedge_meta WHERE key='schema_version'").get()?.value!=='1'){this.db.close();throw Error('hedge_schema_mismatch');}
 }
 close(){this.db.close();}
 catalog(date=null){
  const latest=this.db.prepare("SELECT max(date) date FROM hedge_bars WHERE ticker='QQQ' AND provider='polygon_api' AND adjustment='raw' AND close>0").get().date;
  if(!latest)return {version:hedgeVersion,status:'awaiting_sync',dates:[],chain:[],expiries:[],latest:null};
  date=date??latest;check(typeof date==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(date)&&date<=latest,'hedge_invalid_date');
  const spot=this.db.prepare("SELECT close FROM hedge_bars WHERE ticker='QQQ' AND date=? AND provider='polygon_api' AND adjustment='raw'").get(date)?.close;
  check(spot>0,'hedge_underlying_missing');
  const chain=this.db.prepare(`SELECT c.ticker,c.expiry,c.type,c.strike,c.multiplier,c.standard,c.exercise_style,
   b.date,b.close,b.volume,b.provider FROM hedge_contracts c JOIN hedge_bars b ON b.ticker=c.ticker
   WHERE c.provider='polygon_api' AND c.standard=1 AND c.as_of<=? AND c.expiry>? AND b.date=? AND b.provider='polygon_api'
   AND b.adjustment='raw' AND b.close>0 AND b.volume>0
   AND c.as_of=(SELECT max(c2.as_of) FROM hedge_contracts c2 WHERE c2.ticker=c.ticker AND c2.provider=c.provider AND c2.as_of<=?)
   ORDER BY c.expiry,c.strike,c.type`).all(date,date,date,date);
  const expiryCounts=new Map();for(const c of chain){const n=expiryCounts.get(c.expiry)??{expiry:c.expiry,puts:0,calls:0};n[c.type==='put'?'puts':'calls']++;expiryCounts.set(c.expiry,n);}
  const sync=this.db.prepare('SELECT status,report_json FROM hedge_sync_runs ORDER BY started_at DESC LIMIT 1').get();
  const report=sync?JSON.parse(sync.report_json):null;
  const dates=this.db.prepare(`SELECT DISTINCT b.date FROM hedge_bars b WHERE b.ticker='QQQ' AND b.provider='polygon_api' AND b.adjustment='raw'
    AND EXISTS(SELECT 1 FROM hedge_contracts c WHERE c.provider='polygon_api' AND c.standard=1 AND c.as_of<=b.date) ORDER BY b.date DESC LIMIT 90`).all().map(r=>r.date);
  return {version:hedgeVersion,status:chain.length?'ready':'awaiting_sync',date,latest,spot,dates,chain,expiries:[...expiryCounts.values()],
   quoteBasis:'daily_close',snapshotStatus:report?.snapshotStatus??'unavailable_by_plan',
   sync:report?{status:sync.status,start:report.start,end:report.end,scope:report.scope,selectedContracts:report.selectedContracts??null}:null};
 }
 calculate(input){const rules=hedgeRules(input),data=this.catalog(rules.date);return hedgeExperiment(rules,data.chain,data.spot);}
}

let cachedBundledHedgeCatalog=null;
export class BundledHedgeSource {
 constructor(configUrl=new URL('./config/qqq-hedge-catalog.json',import.meta.url)){
  if(!cachedBundledHedgeCatalog){
   cachedBundledHedgeCatalog=JSON.parse(fs.readFileSync(configUrl,'utf8'));
  }
  this.archive=cachedBundledHedgeCatalog;
 }
 close(){}
 catalog(date=null){
  const {dates=[],latest=null,byDate={}}=this.archive??{};
  if(!latest||!dates.length)return {version:hedgeVersion,status:'awaiting_sync',dates:[],chain:[],expiries:[],latest:null};
  date=date??latest;
  check(typeof date==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(date)&&Boolean(byDate[date]),'hedge_invalid_date');
  const day=byDate[date];
  return {
   version:hedgeVersion,
   status:day.chain?.length?'ready':'awaiting_sync',
   date,
   latest,
   spot:day.spot,
   dates,
   chain:day.chain??[],
   expiries:day.expiries??[],
   quoteBasis:'daily_close',
   snapshotStatus:'bundled_polygon_archive',
   sync:{status:'ready',start:dates.at(-1),end:latest,scope:'bundled_qqq_options_archive',selectedContracts:day.chain?.length??0},
  };
 }
 calculate(input){
  const rules=hedgeRules(input),data=this.catalog(rules.date);
  return hedgeExperiment(rules,data.chain,data.spot);
 }
}
