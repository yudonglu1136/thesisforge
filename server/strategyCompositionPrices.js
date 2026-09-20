import {DatabaseSync} from 'node:sqlite';
import {signature} from './investmentMath.js';
import {reviewedStrategyValuationLink} from './strategyValuationLinks.js';

// A reviewed company-model link does not supply a quote. Obtain the held class's
// own close from its independently verified USD series when no comparison
// snapshot exists. Leave existing comparison evidence and all return maps alone.
export function linkedStrategyComparisonPrices(file,data,end) {
  const needed=[...(data.comparisonPrices?.keys()??[])].filter(symbol=>{
    const old=data.comparisonPrices.get(symbol);
    return reviewedStrategyValuationLink(symbol)&&!old?.points?.size&&(!old?.currency||old.currency==='USD');
  });
  if(!file||!needed.length)return data;
  const db=new DatabaseSync(file,{readOnly:true}),comparisonPrices=new Map(data.comparisonPrices),evidence={};
  try {
    for(const symbol of needed) {
      const series=db.prepare('SELECT * FROM series WHERE symbol=?').get(symbol);
      if(!series||series.currency!=='USD'||series.provider_symbol!==symbol||series.provider!=='sharadar'||!series.source_sha256)continue;
      const meta=JSON.parse(series.metadata_json);
      if(meta.symbol!==symbol||meta.currency!=='USD'||meta.instrumentType!=='EQUITY')continue;
      const link=reviewedStrategyValuationLink(symbol);
      const rows=db.prepare('SELECT date,close,quality_status FROM prices WHERE symbol=? AND date>=? AND date<=? ORDER BY date').all(symbol,link.availableAt,end);
      if(!rows.length||rows.some(r=>!['verified_daily_bar','open_quarantined'].includes(r.quality_status)||!Number.isFinite(r.close)||r.close<=0))continue;
      const provenance={symbol,currency:'USD',provider:'Sharadar SEP/SFP',field:'close',basis:'split_adjusted_close_not_total_return',sourceHash:series.source_sha256,
        pointsHash:signature(rows),first:rows[0].date,last:rows.at(-1).date,rows:rows.length};
      comparisonPrices.set(symbol,{currency:'USD',points:new Map(rows.map(r=>[r.date,r.close])),provenance});
      evidence[symbol]=provenance;
    }
    return {...data,comparisonPrices,sources:{...data.sources,linkedComparisonPrices:evidence}};
  }finally{db.close();}
}

// One complete provider vintage per security, never a splice of adjusted bases.
// This explicit research source does not change the strict Guru replication DB.
export function compositionPrices(file,data,end) {
  if(!file)return data;
  const db=new DatabaseSync(file,{readOnly:true}),priceMaps=new Map(data.priceMaps),evidence={};
  try {
    for(const symbol of priceMaps.keys()) {
      // Keep CTA in its existing audited ETF series.
      if(['KMLM','DBMF'].includes(symbol))continue;
      const series=db.prepare('SELECT * FROM series WHERE symbol=?').get(symbol);
      if(!series||series.currency!=='USD'||symbol!==series.provider_symbol||series.provider!=='sharadar'||!series.source_sha256)continue;
      const meta=JSON.parse(series.metadata_json);
      if(meta.symbol!==symbol||meta.currency!=='USD'||!['EQUITY','ETF'].includes(meta.instrumentType))continue;
      if(['QQQ','SPY','SCHD'].includes(symbol)&&meta.instrumentType!=='ETF')throw Error('index_identity_mismatch');
      const rows=db.prepare("SELECT date,close,adjusted_close,quality_status FROM prices WHERE symbol=? AND date<=? ORDER BY date").all(symbol,end);
      if(!rows.length||rows.some(r=>!['verified_daily_bar','open_quarantined'].includes(r.quality_status)||!Number.isFinite(r.adjusted_close)||r.adjusted_close<=0||!Number.isFinite(r.close)||r.close<=0))continue;
      priceMaps.set(symbol,new Map(rows.map(r=>[r.date,r.adjusted_close])));
      evidence[symbol]={provider:'Sharadar SEP/SFP',providerSymbol:series.provider_symbol,sourceHash:series.source_sha256,pointsHash:signature(rows),first:rows[0].date,last:rows.at(-1).date,rows:rows.length,returnBasis:'single_vintage_total_return_adjusted_close'};
    }
    return {...data,priceMaps,dates:[...(priceMaps.get('SPY')?.keys()??data.dates)].sort(),sources:{...data.sources,compositionPrices:evidence}};
  }finally{db.close();}
}
