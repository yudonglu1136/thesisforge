import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {InvestmentSource} from '../server/investmentSource.js';
import {withCanonicalMarket,marketQuotes,marketPriceHistory} from '../server/investmentMarketContext.js';
import {opportunityCompanySummary,opportunityValuationBreakdown} from '../server/investmentOpportunities.js';
import {overlayValuationFacts} from '../server/valuationFacts.js';
import {buildFundamentalCompany,buildFundamentalDiscovery} from '../server/fundamentalResearch.js';

// Read-only, public evidence only. No credentials, private journal, provider
// calls, database copy or snapshot rewrite. FACT_OS_ROOT may pin an installed
// production generation; never assume the development default on AWS.
const [file,asOf='2026-09-22',symbols='AMZN,MSFT,NVDA,GOOGL,MU']=process.argv.slice(2);
if(!file)throw Error('Usage: node scripts/audit-consumer-data-consistency.mjs <research.sqlite> [asOf] [comma-separated tickers]');
const tickers=symbols.split(',');
const source=new InvestmentSource(file,{canonicalMarket:true});
const hash=value=>createHash('sha256').update(JSON.stringify(value)).digest('hex');
const ledger=()=>source.db.prepare(`SELECT ticker,fiscal_period,as_of_date,model_version,input_json,output_json
  FROM valuation_pit_model_runs WHERE ticker IN (${tickers.map(()=>'?').join(',')})
  ORDER BY ticker,fiscal_period,as_of_date,model_version`).all(...tickers);
try{
  const before=hash(ledger()),rows=[];
  const started=performance.now();
  const financials=[];
  await withCanonicalMarket(tickers,asOf,async()=>{
    for(const ticker of tickers){
      const canonical=marketQuotes([ticker],asOf).get(ticker);
      const research=source.company(ticker,asOf);
      const guru=opportunityCompanySummary(source,ticker,asOf);
      const stored=JSON.parse(source.db.prepare('SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?').get(ticker)?.payload_json??'{}');
      const valuation=overlayValuationFacts(stored,{asOf,prices:canonical.value==null?[]:[canonical]});
      assert.equal(research.snapshot.price.value,canonical.value,ticker+' Research value');
      assert.equal(guru.price.value,canonical.value,ticker+' Guru value');
      assert.equal(valuation.latest.latestPrice,canonical.value,ticker+' Valuation value');
      assert.equal(research.snapshot.price.date,canonical.date,ticker+' Research date');
      assert.equal(guru.price.date,canonical.date,ticker+' Guru date');
      assert.equal(valuation.latest.latestPriceDate,canonical.date,ticker+' Valuation date');
      assert.equal(marketPriceHistory(ticker,asOf).at(-1)?.value??null,canonical.value,ticker+' curve endpoint');
      const lastStored=(stored.priceHistory??[]).filter(p=>p.date<=asOf).at(-1);
      const breakdown=opportunityValuationBreakdown(source,ticker,asOf);
      rows.push({ticker,canonical: {value:canonical.value,date:canonical.date,currency:canonical.currency,
        priceType:canonical.priceType},archivedComparison:{value:lastStored?.close??null,date:lastStored?.date??null},
        model:{value:research.published.fairValue,date:research.snapshot.availableAt,
          version:research.published.modelVersion,reconciliation:breakdown?.reconciliationStatus??null},
        status:'matched'});
      const discovery=await buildFundamentalDiscovery(asOf,{search:ticker,limit:200});
      const listed=discovery.rows.find(row=>row.ticker===ticker);
      const detail=await buildFundamentalCompany(source,ticker,asOf);
      assert.ok(listed,ticker+' discovery coverage');
      const keys=['revenueGrowth','priorRevenueGrowth','ttmRevenue','operatingMargin','fcfMargin','capexIntensity'];
      for(const key of keys)assert.equal(detail.company.metrics[key],listed.metrics[key],ticker+' '+key);
      assert.equal(detail.price.value,canonical.value,ticker+' Fundamentals current price');
      assert.equal(detail.valuation.price.value,canonical.value,ticker+' Fundamentals model comparison');
      financials.push({ticker,period:detail.company.period_end,methodVersion:detail.methodVersion,
        metricKeys:keys,status:'list_detail_research_matched'});
    }
  },{historyTickers:tickers});
  const after=hash(ledger());assert.equal(after,before,'published model ledger changed');
  console.log(JSON.stringify({version:'consumer-data-consistency-v1',asOf,executedAt:new Date().toISOString(),
    runtime:process.version,elapsedMs:Math.round(performance.now()-started),rows,financials,
    modelLedger:{before,after,unchanged:before===after},status:'pass'},null,2));
}finally{source.close();}
