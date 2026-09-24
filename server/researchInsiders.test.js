import test from 'node:test';
import assert from 'node:assert/strict';
import { researchInsiders } from './researchInsiders.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

const row = (n, extra={}) => ({ticker:'PLTR',date:'2026-09-17',formtype:'4',ownername:`Owner ${n}`,rownum:n,
  transactiondate:'2026-09-15',transactioncode:'S',securityadcode:'ND',transactionshares:-10,
  transactionvalue:100,securitytitle:'ClA',fact_id:`fact-${n}`,...extra});
const read = rows => async method => {
  assert.equal(method,'get_insider_transactions');
  return {security_id:'sharadar:security:632043',company_id:'sec:cik:1321655',ticker:'PLTR',rows,
    source_as_of:'2026-09-21',generation:'catalog-1'};
};
test('summary separates P/S non-derivative lines from awards, exercise, gifts and withholding',async()=>{
  const rows=[row(1),row(2,{transactioncode:'P',securityadcode:'NA',transactionshares:10,transactionvalue:200}),
    ...['A','M','G','F'].map((c,i)=>row(i+3,{transactioncode:c,transactionvalue:9000})),
    row(8,{securityadcode:'DD',transactionvalue:10000})];
  const r=await researchInsiders('PLTR','2026-09-22',{},read(rows));
  assert.equal(r.summary.purchases.value,200);assert.equal(r.summary.sales.value,100);
  assert.equal(r.summary.netReportedValue,100);assert.equal(r.summary.otherLines,5);
  assert.equal(r.months.at(-1).sales.value,100);
  assert.equal(r.currency,'USD');assert.equal(r.rows.length,7);
});
test('cutoff, invalid direction, missing value, amendments and future transaction dates never inflate totals',async()=>{
  const r=await researchInsiders('PLTR','2026-09-22',{},read([
    row(1,{transactionvalue:null}),row(2,{date:'2026-09-23'}),
    row(3,{transactiondate:'2026-09-23'}),row(4,{securityadcode:'NA'}),
    row(5,{formtype:'4/A'}),row(6,{ownername:'Owner 5'}),row(7,{transactionvalue:-50}),
  ]));
  assert.equal(r.summary.sales.lines,2);assert.equal(r.summary.sales.value,null);
  assert.equal(r.summary.sales.unpriced,2);assert.equal(r.summary.netReportedValue,null);
  assert.equal(r.rows.find(x=>x.rownum===6).exclusion,'amendment_unresolved');
  assert.equal(r.rows.some(x=>x.rownum===2),false);
  assert.equal(r.rows.find(x=>x.rownum===3).exclusion,'invalid_transaction_date');
});
test('filter and pagination preserve full-window summary; snapshot mismatch fails explicitly',async()=>{
  const rows=Array.from({length:55},(_,i)=>row(i));
  const a=await researchInsiders('PLTR','2026-09-22',{limit:20},read(rows));
  const b=await researchInsiders('PLTR','2026-09-22',{limit:20,offset:20,kind:'sale',snapshotId:a.snapshotId},read(rows));
  assert.equal(a.total,55);assert.equal(b.summary.sales.lines,55);assert.equal(b.rows.length,20);
  assert.notEqual(a.rows[0].id,b.rows[0].id);
  await assert.rejects(researchInsiders('PLTR','2026-09-22',{snapshotId:'old'},read(rows)),{status:409});
  for(const options of [{months:99},{kind:'evil'},{offset:-1},{limit:500}])
    await assert.rejects(researchInsiders('PLTR','2026-09-22',options,read(rows)),{status:400});
});
test('missing source fails, unknown inputs stay missing, holdings-only forms are not purchases',async()=>{
  await assert.rejects(researchInsiders('PLTR','2026-09-22',{},async()=>{throw Error('missing source');}),/missing source/);
  const r=await researchInsiders('PLTR','2026-09-22',{},read([row(1,{formtype:'3',transactioncode:''})]));
  assert.equal(r.summary.purchases.lines,0);assert.equal(r.summary.purchases.value,0);
  assert.equal(r.rows[0].kind,'holding');assert.equal(r.sourceLinkStatus,'issuer_search_only');
});
test('endpoint requires authentication, no valuation model or price scan, and preserves failure status',async()=>{
  const routes=new Map();let calls=0,status=200,body;
  registerInvestmentRoutes({get:(p,h)=>routes.set(p,h),post:()=>{}},{source:{canonicalMarket:true},date:d=>d,
    researchInsiders:async(t,d,q)=>{calls++;return researchInsiders(t,d,q,read([row(1)]));}});
  const handler=routes.get('/api/investment/research/:ticker/insiders');
  const res={setHeader(){},status(n){status=n;return this;},json(x){body=x;}};
  const req={params:{ticker:'PLTR'},query:{asOf:'2026-09-22'}};
  await handler(req,res);assert.equal(status,401);assert.equal(calls,0);
  status=200;await handler({...req,user:{id:'fixture'}},res);assert.equal(status,200);assert.equal(body.summary.sales.value,100);
  await handler({...req,user:{id:'fixture'},query:{...req.query,snapshotId:'stale'}},res);assert.equal(status,409);
});
