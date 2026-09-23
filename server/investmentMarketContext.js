import { AsyncLocalStorage } from 'node:async_hooks';
import { createHash } from 'node:crypto';
import { queryFactsBatch, factGeneration, PRICE_TYPES, FactDataError } from './factRepository.js';
import { isoDate } from './investmentMath.js';

// A request pins facts once; synchronous model/journal code consumes that exact
// read without rewriting the immutable model database or user snapshots.
const context=new AsyncLocalStorage();
const validTicker=t=>/^[A-Z][A-Z0-9.-]{0,14}$/.test(t);
export function canonicalComparisonQuote(point,asOf,generation=null) {
  const valid=Number.isFinite(point?.value)&&point.value>0&&
    /^\d{4}-\d{2}-\d{2}$/.test(point.date??'')&&point.date<=asOf&&
    point.currency==='USD'&&point.price_type===PRICE_TYPES.RAW_CLOSE;
  return {value:valid?point.value:null,date:valid?point.date:null,
    currency:valid?point.currency:null,source:valid?'Sharadar Local Fact OS':null,
    priceType:PRICE_TYPES.RAW_CLOSE,adjustment:'historical quoted price; no dividend or split rescaling',
    sourceTicker:valid?point.ticker??null:null,securityId:valid?point.security_id??null:null,
    sourceGeneration:generation,provenance:valid?point.provenance??null:null,
    canonical:true,status:valid?'available':'unavailable'};
}

export async function withCanonicalMarket(tickers,asOf,handler,{
  readBatch=queryFactsBatch,getGeneration=factGeneration,historyTickers=[],
}={}) {
  isoDate(asOf);
  const names=[...new Set(tickers.map(t=>String(t).trim().toUpperCase()).filter(validTicker))].sort();
  const histories=[...new Set(historyTickers.filter(t=>names.includes(t)))];
  const generation=await getGeneration();
  const requests=names.length?[{method:'get_prices',args:[names,asOf,PRICE_TYPES.RAW_CLOSE],kwargs:{dataset:'auto'}},
    ...histories.map(ticker=>({method:'get_price_history',args:[ticker,'1900-01-01',asOf,PRICE_TYPES.RAW_CLOSE],kwargs:{dataset:'auto'}}))]:[];
  const results=requests.length?await readBatch(requests):[];
  if(names.length&&!results[0]?.ok)throw new FactDataError(results[0]?.error?.code??'local_data_unavailable','local_data_unavailable');
  if(generation!==await getGeneration())throw new FactDataError('local_snapshot_changed','local_snapshot_changed');
  const quotes=new Map(names.map(t=>[t,canonicalComparisonQuote(results[0]?.result?.[t],asOf,generation)]));
  const history=new Map(histories.map((t,i)=>[t,(results[i+1]?.ok?results[i+1].result:[])
    .map(p=>canonicalComparisonQuote(p,asOf,generation)).filter(p=>p.value!==null)
    .map(p=>({...p,close:p.value})).sort((a,b)=>a.date.localeCompare(b.date))]));
  // Failed/unavailable reads and corrected quotes cannot reuse a ready cache,
  // even when the model SQLite data_version has not changed.
  const version=createHash('sha256').update(JSON.stringify([generation,asOf,[...quotes],[...history]])).digest('hex');
  return context.run({asOf,quotes,history,version,generation},handler);
}

export function marketQuotes(tickers,asOf) {
  const current=context.getStore();if(!current)return null;
  if(current.asOf!==asOf)throw new FactDataError('market_cutoff_mismatch','market_cutoff_mismatch');
  return new Map(tickers.map(t=>[t,current.quotes.get(t)??canonicalComparisonQuote(null,asOf,current.generation)]));
}
export function marketPriceHistory(ticker,asOf) {
  const current=context.getStore();if(!current)return null;
  if(current.asOf!==asOf)throw new FactDataError('market_cutoff_mismatch','market_cutoff_mismatch');
  return current.history.get(ticker)??[];
}
export function marketFactsVersion(){return context.getStore()?.version??null;}
