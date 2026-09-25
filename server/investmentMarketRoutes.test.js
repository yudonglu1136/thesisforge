import test from 'node:test';
import assert from 'node:assert/strict';
import { withInvestmentMarketFacts } from './investmentMarketRoutes.js';
import { investmentCurrentQuotes } from './investmentPrices.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

const asOf='2026-09-22';
function fixture(){
  const calls=[];
  return {calls,source:{canonicalMarket:true},date:value=>value??asOf,
    store:{get(owner,id,kind){assert.equal(owner,'verified-owner');return {ticker:'AMZN'};},list:()=>[{ticker:'MSFT'}]},
    heads:()=>[{ticker:'AMZN'}],marketReadOptions:{getGeneration:async()=>'test',readBatch:async requests=>{
      calls.push(requests);return requests.map(r=>({ok:true,result:r.method==='get_prices'
        ?Object.fromEntries(r.args[0].map(t=>[t,{ticker:t,value:260,date:'2026-09-21',currency:'USD',price_type:'RAW_CLOSE'}])):[]}));
    }}};
}
test('all current comparison and save/review routes use canonical quotes at the selected cutoff',async()=>{
  for(const route of ['/research/:ticker','/opportunities/:ticker','/fundamentals/:ticker','/calculate','/valuation-drafts','/scenarios','/decisions','/watches','/reviews','/review/:id','/watch-reviews','/watches/:id','/home','/portfolio']) {
    const service=fixture();
    await withInvestmentMarketFacts(service,'verified-owner',{query:{asOf},params:{ticker:'AMZN',id:'owned'},body:{ticker:'AMZN',asOf,watchId:'owned',decisionId:'owned'}},route,()=>{
      assert.equal(investmentCurrentQuotes({},['AMZN'],asOf).get('AMZN').value,260,route);
    });
    assert.equal(service.calls.length,1,route);
    assert.equal(service.calls[0][0].args[1],asOf);
    assert.equal(service.calls[0][0].args[2],'RAW_CLOSE');
  }
});
test('holdings, AI, company search and published model ledger do not trigger quote work',async()=>{
  const service=fixture();
  for(const route of ['/guru-holdings','/13f-insights','/ai-insights','/companies','/research/:ticker/published-model','/research/:ticker/records'])
    await withInvestmentMarketFacts(service,'verified-owner',{query:{asOf}},route,()=>true);
  assert.equal(service.calls.length,0);
});
test('materialized opportunities never rebuild canonical quotes in a user request',async()=>{
  const service=fixture();service.publicAnalysis={get:()=>({})};
  const result=await withInvestmentMarketFacts(service,'verified-owner',{query:{asOf}},'/opportunities',()=>({from:'artifact'}));
  assert.deepEqual(result,{from:'artifact'});assert.equal(service.calls.length,0);
});
test('company research remains readable from the released research snapshot when no Fact OS generation is active',async()=>{
  const service=fixture();
  service.marketReadOptions.getGeneration=async()=>'';
  service.marketReadOptions.readBatch=async()=>assert.fail('no canonical read without a published generation');
  const result=await withInvestmentMarketFacts(service,'verified-owner',
    {query:{asOf},params:{ticker:'AMZN'}},'/research/:ticker',
    ()=>({ticker:'AMZN',coverage:{company:'available'}}));
  assert.deepEqual(result,{ticker:'AMZN',coverage:{company:'available'}});
});
test('price-sensitive writes remain fail-closed when no Fact OS generation is active',async()=>{
  const service=fixture();
  service.marketReadOptions.getGeneration=async()=>'';
  service.marketReadOptions.readBatch=async()=>[{ok:false,error:{code:'local_data_unavailable'}}];
  await assert.rejects(()=>withInvestmentMarketFacts(service,'verified-owner',
    {query:{asOf},body:{ticker:'AMZN',asOf}},'/calculate',()=>assert.fail()),/local_data_unavailable/);
});
test('private review ownership is validated before price reads',async()=>{
  const service=fixture();service.store.get=()=>{throw Error('not_owned');};
  await assert.rejects(()=>withInvestmentMarketFacts(service,'attacker',{query:{asOf},params:{id:'other'}},'/review/:id',()=>assert.fail()),/not_owned/);
  assert.equal(service.calls.length,0);
});

test('registered production-style routes revalidate mutable URLs and expose a typed failure, never stored price',async()=>{
  const service=fixture(),routes=new Map();
  service.fundamentalCompany=(_source,ticker,date)=>({price:investmentCurrentQuotes({},[ticker],date).get(ticker)});
  registerInvestmentRoutes({get:(path,handler)=>routes.set(path,handler),post:()=>{}},service);
  const request={user:{id:'verified-owner'},query:{asOf},params:{ticker:'AMZN'}};
  const headers={};let status=200,body;
  const response={setHeader:(key,value)=>{headers[key]=value;},json:value=>{body=value;},status:code=>{status=code;return response;}};
  await routes.get('/api/investment/fundamentals/:ticker')(request,response);
  assert.equal(body.price.value,260);assert.equal(headers['Cache-Control'],'private, no-cache');
  service.marketReadOptions.readBatch=async()=>[{ok:false,error:{code:'local_data_unavailable',message:'private path'}}];
  await routes.get('/api/investment/fundamentals/:ticker')(request,response);
  assert.equal(status,503);assert.deepEqual(body,{error:'local_data_unavailable'});
  assert.equal(headers['Cache-Control'],'private, no-store');
});
