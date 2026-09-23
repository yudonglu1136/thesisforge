import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { withCanonicalMarket, marketFactsVersion, marketPriceHistory } from './investmentMarketContext.js';
import { investmentCurrentQuotes, preferInvestmentQuote } from './investmentPrices.js';
import { InvestmentSource } from './investmentSource.js';
import { opportunityCompanySummary } from './investmentOpportunities.js';
import { overlayValuationFacts } from './valuationFacts.js';

const cutoff='2026-09-22';
const old={value:253.71,date:'2026-09-18',currency:'USD',source:'archived model'};
const point=(value=260,date='2026-09-21')=>({value,date,currency:'USD',ticker:'AMZN',security_id:'fixture-security',price_type:'RAW_CLOSE',provenance:{dataset:'stocks'}});
const reader=points=>async requests=>requests.map(r=>({ok:true,result:r.method==='get_prices'?points:[]}));
const options=points=>({readBatch:reader(points),getGeneration:async()=>'fixture-generation'});

test('Research, Guru company preview and Valuation use the same canonical comparison quote',async()=>{
  const source=Object.create(InvestmentSource.prototype);source.db=new DatabaseSync(':memory:');
  source.db.exec(`CREATE TABLE valuation_ticker_snapshots(ticker TEXT,payload_json TEXT);
    CREATE TABLE valuation_pit_model_runs(ticker TEXT,fiscal_period TEXT,as_of_date TEXT,financial_available_at TEXT,guidance_max_observed_at TEXT,model_version TEXT,input_json TEXT,output_json TEXT);
    CREATE TABLE guru_exposure_snapshots(guru_id TEXT,payload_json TEXT);`);
  source.db.prepare('INSERT INTO valuation_ticker_snapshots VALUES(?,?)').run('AMZN',JSON.stringify({currency:'USD',priceHistory:[{date:old.date,close:old.value}]}));
  try {
    await withCanonicalMarket(['AMZN'],cutoff,()=>{
      const research=source.price('AMZN',cutoff);
      const guru=opportunityCompanySummary(source,'AMZN',cutoff).price;
      const valuation=overlayValuationFacts({ticker:'AMZN',currency:'USD',latest:{baseFairValue:235.69}},{prices:[point()],asOf:cutoff}).latest;
      assert.equal(research.value,260);assert.equal(guru.value,260);assert.equal(valuation.latestPrice,260);
      assert.equal(research.date,guru.date);assert.equal(research.date,valuation.latestPriceDate);
      assert.equal(research.priceType,'RAW_CLOSE');assert.equal(research.currency,'USD');
      assert.equal(JSON.parse(source.db.prepare('SELECT payload_json FROM valuation_ticker_snapshots').get().payload_json).priceHistory[0].close,253.71);
    },options({AMZN:point()}));
  } finally {source.close();}
});

test('missing, invalid and future canonical quotes cannot revive archived model prices',async()=>{
  for(const p of [null,point(0),point(260,'2026-09-23'),{...point(),currency:'GBP'}]){
    await withCanonicalMarket(['AMZN'],cutoff,()=>{
      const quote=investmentCurrentQuotes({},['AMZN'],cutoff).get('AMZN');
      assert.equal(preferInvestmentQuote(quote,old).value,null);
    },options({AMZN:p}));
  }
  await withCanonicalMarket(['AMZN'],cutoff,()=>{
    const p=investmentCurrentQuotes({},['AMZN'],cutoff).get('AMZN');
    assert.equal(preferInvestmentQuote(p,{...old,date:'2026-09-22'}).value,260);
    assert.equal(preferInvestmentQuote(p,{...old,currency:'GBP'}).currency,'USD');
  },options({AMZN:point()}));
});

test('canonical context is request-local, PIT-scoped, batched and versioned',async()=>{
  let calls=0,release;const paused=new Promise(r=>{release=r;});
  const a=withCanonicalMarket(['AMZN','AMZN'],cutoff,async()=>{
    const version=marketFactsVersion();await paused;
    assert.equal(marketFactsVersion(),version);
    assert.equal(investmentCurrentQuotes({},['AMZN'],cutoff).get('AMZN').value,260);
    assert.throws(()=>investmentCurrentQuotes({},['AMZN'],'2026-09-18'),/market_cutoff_mismatch/);
  },{getGeneration:async()=>'a',readBatch:async requests=>{
    calls++;assert.equal(requests.length,1);assert.deepEqual(requests[0].args,[['AMZN'],cutoff,'RAW_CLOSE']);
    return [{ok:true,result:{AMZN:point()}}];
  }});
  await withCanonicalMarket(['AMZN'],'2026-09-18',()=>{
    assert.equal(investmentCurrentQuotes({},['AMZN'],'2026-09-18').get('AMZN').value,253.71);
  },options({AMZN:point(253.71,'2026-09-18')}));
  release();await a;assert.equal(calls,1);assert.equal(marketFactsVersion(),null);
});

test('reader failure and generation change are not concealed by stored prices',async()=>{
  await assert.rejects(withCanonicalMarket(['AMZN'],cutoff,()=>assert.fail(),{
    getGeneration:async()=>'g',readBatch:async()=>[{ok:false,error:{code:'local_data_unavailable'}}],
  }),/local_data_unavailable/);
  let n=0;
  await assert.rejects(withCanonicalMarket(['AMZN'],cutoff,()=>assert.fail(),{
    ...options({AMZN:point()}),getGeneration:async()=>String(n++),
  }),/local_snapshot_changed/);
});

test('history is cutoff-scoped and a failed or corrected history cannot reuse an old company cache',async()=>{
  const versions=[];
  for(const history of [[point(250,'2026-09-18'),point(260),point(280,'2026-09-23')],null,[point(249,'2026-09-18'),point(260)]]){
    await withCanonicalMarket(['AMZN'],cutoff,()=>{
      const rows=marketPriceHistory('AMZN',cutoff);
      assert.ok(rows.every(row=>row.date<=cutoff&&row.priceType==='RAW_CLOSE'));
      assert.equal(rows.length,history?2:0);
      assert.equal(rows[0]?.close,history?.[0].value);
      versions.push(marketFactsVersion());
    },{getGeneration:async()=>'same-generation',historyTickers:['AMZN'],readBatch:async()=>[
      {ok:true,result:{AMZN:point()}},history?{ok:true,result:history}:{ok:false,error:{code:'read_failed'}}]});
  }
  assert.equal(new Set(versions).size,3);
});
