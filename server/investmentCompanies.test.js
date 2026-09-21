import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { researchCompanies } from './investmentCompanies.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';

function fixture() {
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE valuation_pit_model_runs(ticker TEXT, as_of_date TEXT, financial_available_at TEXT, guidance_max_observed_at TEXT);
    CREATE TABLE valuation_ticker_snapshots(ticker TEXT, payload_json TEXT);`);
  const insert = db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?)');
  insert.run('TEST','2026-04-20','2026-04-20',null);
  insert.run('TEST','2026-07-20','2026-07-20','2026-07-19');
  insert.run('TEST','2026-07-20','2026-07-20','2026-07-19');
  insert.run('FUTURE','2026-09-01','2026-09-01',null);
  insert.run('BAD','2026-04-01','2026-04-02',null);
  insert.run('BADGUIDE','2026-04-01','2026-04-01','2026-04-02');
  insert.run('NONAME','2026-04-20','2026-04-20',null);
  db.prepare('INSERT INTO valuation_ticker_snapshots VALUES(?,?)').run('TEST',JSON.stringify({name:'Synthetic Research Company',secret:'financial payload must not leave source'}));
  return {db,fundamentalCompanyIndex:async()=>({catalog_generation:'fixture',companies:[]})};
}
test('deduplicated compact identity catalog respects cutoff and known input dates',async()=>{
  const s=fixture(), result=await researchCompanies(s,'2026-06-01');
  assert.deepEqual(result.companies,[
    {ticker:'NONAME',name:'NONAME',availableAt:'2026-04-20',coverage:'stored_model'},
    {ticker:'TEST',name:'Synthetic Research Company',availableAt:'2026-04-20',coverage:'stored_model'},
  ]);
  assert(!JSON.stringify(result).includes('secret'));
  assert(!JSON.stringify(result).includes('financial payload'));
  assert.equal((await researchCompanies(s,'2026-08-28')).companies.find(c=>c.ticker==='TEST').availableAt,'2026-07-20');
  s.db.close();
});
test('empty historical cutoff is not silently replaced by current coverage',async()=>{
  const s=fixture();assert.deepEqual((await researchCompanies(s,'2025-01-01')).companies,[]);
  await assert.rejects(researchCompanies(s,'nonsense'),/invalid_date/);s.db.close();
});
test('cache is immutable and invalidates when source changes',async()=>{
  const s=fixture(), first=await researchCompanies(s,'2026-08-28');
  first.companies[0].name='mutated';
  assert.notEqual((await researchCompanies(s,'2026-08-28')).companies[0].name,'mutated');
  s.db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?)').run('NEW','2026-08-01','2026-08-01',null);
  assert((await researchCompanies(s,'2026-08-28')).companies.some(c=>c.ticker==='NEW'));s.db.close();
});
test('catalog names never create coverage without a dated model',async()=>{
  const s=fixture();assert(!(await researchCompanies(s,'2026-08-28')).companies.some(c=>c.ticker==='NVDA'));
  s.db.prepare('INSERT INTO valuation_pit_model_runs VALUES(?,?,?,?)').run('NVDA','2026-08-26','2026-08-26',null);
  assert((await researchCompanies(s,'2026-08-28')).companies.find(c=>c.ticker==='NVDA').name);
  assert(!(await researchCompanies(s,'2026-06-01')).companies.some(c=>c.ticker==='NVDA'));s.db.close();
});
test('company catalog stays authenticated, read-only and private/no-store',async()=>{
  const routes=new Map(),app={get:(p,h)=>routes.set(p,h),post:()=>{}};
  const source=fixture();registerInvestmentRoutes(app,{source,date:d=>d});
  const handler=routes.get('/api/investment/companies');let status=200,body;const headers={};
  const res={setHeader:(k,v)=>headers[k]=v,status:s=>{status=s;return res;},json:v=>body=v};
  await handler({query:{asOf:'2026-08-28'}},res);assert.equal(status,401);
  const before=source.db.prepare('SELECT total_changes() n').get().n;
  status=200;await handler({user:{id:'alice'},query:{asOf:'2026-08-28'}},res);
  assert.equal(status,200);assert.equal(body.companies.length,2);
  assert.equal(headers['Cache-Control'],'private, no-store');
  assert.equal(source.db.prepare('SELECT total_changes() n').get().n,before);source.db.close();
});
test('bounded 13F summaries are privately reusable without changing other investment routes',async()=>{
  const routes=new Map(),app={get:(p,h)=>routes.set(p,h),post:()=>{}};
  const source=fixture();
  source.db.exec(`CREATE TABLE institutional_13f_insight_snapshots(
    report_date TEXT,source_generation TEXT,available_at TEXT,generated_at TEXT,
    payload_hash TEXT,payload_json TEXT,PRIMARY KEY(report_date,source_generation));`);
  source.db.prepare('INSERT INTO institutional_13f_insight_snapshots VALUES(?,?,?,?,?,?)').run(
    '2026-06-30','g1','2026-08-14','2026-09-20','hash',JSON.stringify({
      version:'institutional-13f-insights-v3',reportDate:'2026-06-30',
      coverage:{currentFilers:1,securities:1},rows:[{ticker:'TEST',increases:1,holders:1}],
      institutions:[],details:{},
    }),
  );
  registerInvestmentRoutes(app,{source,date:d=>d});
  const headers={};let body;
  const res={setHeader:(k,v)=>headers[k]=v,status:()=>res,json:v=>body=v};
  await routes.get('/api/investment/13f-insights')({
    user:{id:'alice'},query:{asOf:'2026-09-18',action:'increased',rank:'amount',limit:'100'},
  },res);
  assert.equal(body.rows.length,1);
  assert.equal(headers['Cache-Control'],'private, max-age=300, stale-while-revalidate=3600');
  source.db.close();
});
