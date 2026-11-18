import { parentPort, workerData } from 'node:worker_threads';
import { InvestmentSource } from './investmentSource.js';
import { buildPortfolioAnalysis,attachPortfolioTrailingDividends } from './investmentPortfolio.js';
import { loadDividendCalendarForTickers } from './dividendClient.js';
import { analysisFailureCode } from './analysisFailure.js';
import { loadPriceSeriesBatch } from './marketData.js';
import { factOsEnabled, PRICE_TYPES } from './factRepository.js';

const eligible=analysis=>(analysis.groups??[]).flatMap(group=>(group.positions??[]).filter(position=>{
  if(position.kind!=='equity'||!(position.quantity>0)||!(position.price>0)||!(position.value>0)||!(position.fxRateToBase>0))return false;
  return Math.abs(position.quantity*position.price*position.fxRateToBase-position.value)<=Math.max(1,Math.abs(position.value)*.01);
}).map(position=>({...position,baseCurrency:group.currency,quoteCurrency:position.currency})));
const trailingStart=asOf=>{const date=new Date(`${asOf}T00:00:00Z`);date.setUTCFullYear(date.getUTCFullYear()-1);return date.toISOString().slice(0,10);};
const riskSymbols=payload=>{
  const out=new Set(['SPY']);
  for(const acc of payload?.analysisAccounts??[]){
    for(const pos of acc?.positions??[]){
      const kind=String(pos?.assetCategory??'').toUpperCase();
      if(['STK','STOCK','EQUITY','COMMON STOCK'].includes(kind)&&String(pos?.currency??'').toUpperCase()==='USD'&&pos?.ticker){
        out.add(String(pos.ticker).trim().toUpperCase());
      }
    }
  }
  return [...out].filter(Boolean);
};

async function main() {
  if(workerData.canonicalRoot)process.env.FACT_OS_ROOT=workerData.canonicalRoot;
  if(workerData.canonicalRoot&&process.env.NODE_ENV==='production'&&!process.env.FACT_OS_LEASE_ROOT)
    process.env.FACT_OS_LEASE_ROOT='/var/app/data/fact-os-leases';
  const source=new InvestmentSource(workerData.researchFile,{canonicalMarket:true,
    publicFactsFile:workerData.publicFactsFile,insightsFile:workerData.insightsFile});
  try{
    let priceSeries=null;
    if(workerData.scope==='detail'&&factOsEnabled()){
      try{
        const start=new Date(Date.parse(workerData.asOf+'T00:00:00Z')-367*86400000).toISOString().slice(0,10);
        const batch=await loadPriceSeriesBatch(riskSymbols(workerData.payload).map(symbol=>({
          symbol,start,end:workerData.asOf,priceType:PRICE_TYPES.TOTAL_RETURN_ADJUSTED_CLOSE,
        })));
        priceSeries=new Map(batch.filter(item=>item?.points?.length).map(item=>[item.symbol,item.points]));
      }catch{}
    }
    const options={riskFreeRate:workerData.riskFreeRate,home:workerData.scope==='home',summary:workerData.scope==='summary',priceSeries};
    const analysis=buildPortfolioAnalysis(source,workerData.payload,workerData.asOf,options);
    if(workerData.scope!=='summary'&&analysis.groups?.length){
      try{
        const calendar=await loadDividendCalendarForTickers(eligible(analysis),{startDate:trailingStart(workerData.asOf),endDate:workerData.asOf});
        attachPortfolioTrailingDividends(analysis,calendar,{asOf:workerData.asOf});
      }catch{attachPortfolioTrailingDividends(analysis,{status:{source:'unavailable'},events:[]},{asOf:workerData.asOf});}
    }
    parentPort.postMessage({ok:true,result:analysis});
  }finally{source.close();}
}

main().catch(error=>parentPort.postMessage({ok:false,error:analysisFailureCode(error)}));
