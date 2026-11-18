import test from 'node:test';
import a from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import express from 'express';
import { InvestmentStore } from './investmentStore.js';
import { registerStrategyLabRoutes, strategyWorkerLimits } from './strategyLabRoutes.js';
import { isoDate } from './investmentMath.js';

const body={asOf:'2026-08-28',start:'2023-08-28',end:'2026-08-28',managers:['bill-ackman'],topN:5,valuationEnabled:true,maxPremium:.3,excludedAllocation:'redistribute',cta:'KMLM',ctaWeight:.3,costBps:10};
async function setup(t,run=async rules=>({version:'guru-valuation-cta-v1',rules,status:'ready'}),options={}) {
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'tf-strategy-tests-'));
  const store=new InvestmentStore(path.join(directory,'private.sqlite'));
  const source={guruCatalog:()=>[{id:'bill-ackman',name:'Fixture Manager'}],guruHistory:()=>[{filingDate:'2023-02-14'}]};
  const app=express();app.use(express.json());app.use((req,_,next)=>{if(req.headers['x-fixture-user'])req.user={id:req.headers['x-fixture-user']};next();});
  registerStrategyLabRoutes(app,{source,store,date:isoDate},{run,...options});
  const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
  t.after(async()=>{await new Promise(r=>server.close(r));store.close();fs.rmSync(directory,{recursive:true,force:true});});
  const req=async(method,url,value=null,user='user-a')=>{
    const r=await fetch(`http://127.0.0.1:${server.address().port}/api/investment${url}`,{method,headers:{'Content-Type':'application/json',...(user?{'X-Fixture-User':user}:{})},...(value?{body:JSON.stringify(value)}:{})});
    return {status:r.status,cache:r.headers.get('cache-control'),data:await r.json()};
  };
  return {req,store};
}
test('catalog, backtest and save require authenticated owner',async t=>{
  const {req}=await setup(t);
  for(const [method,url,payload] of [['GET','/strategy-lab?asOf=2026-08-28',null],['POST','/strategy-backtests',body],['POST','/strategy-rules',body]]){
    const r=await req(method,url,payload,null);a.equal(r.status,401);a.equal(r.cache,'private, no-store');
  }
});
test('equity mix round-trips through owner-scoped saved rules; index-only runs need no manager',async t=>{
  const {req}=await setup(t);
  const mixed={...body,managers:[],excludedAllocation:'fully_invested',equityMix:{weights:{QQQ:.5,SPY:.25,SCHD:.25}}};
  const result=await req('POST','/strategy-backtests',mixed);a.equal(result.status,200);
  const saved=await req('POST','/strategy-rules',{...mixed,name:'Test ETF mix',operationId:'test-equity-mix-save'});a.equal(saved.status,200);
  const own=await req('GET','/strategy-lab?asOf=2026-08-28');a.deepEqual(own.data.saved[0].rules.equityMix,result.data.rules.equityMix);
  const other=await req('GET','/strategy-lab?asOf=2026-08-28',null,'user-b');a.equal(other.data.saved.length,0);
});
test('valid run uses normalized rules, does not persist; rejected inputs never call engine',async t=>{
  let calls=0;const {req,store}=await setup(t,async rules=>{calls++;return {rules};});
  const r=await req('POST','/strategy-backtests',body);a.equal(r.status,200);a.equal(r.data.rules.cta,'KMLM');a.equal(store.list('user-a').length,0);
  for(const patch of [{managers:['no-such-manager']},{maxPremium:999},{topN:0},{cta:'secret-file'},{end:'2030-01-01'}])a.equal((await req('POST','/strategy-backtests',{...body,...patch})).status,422);
  a.equal(calls,1);
});
test('flexible CTA rules persist privately and run with the identical normalized policy',async t=>{
  const {req}=await setup(t);
  const payload={...body,excludedAllocation:'fully_invested',ctaPolicy:{mode:'tranches',minWeight:.1,trancheWeight:.1,
    trimThresholds:[.2,.4],buyThresholds:[.1,.2],cooldownSessions:3},name:'CTA policy',operationId:'cta-policy-save-test'};
  const saved=await req('POST','/strategy-rules',payload);a.equal(saved.status,200);
  const read=await req('GET','/strategy-lab?asOf=2026-08-28');a.deepEqual(read.data.saved[0].rules.ctaPolicy,saved.data.rules.ctaPolicy);
  const run=await req('POST','/strategy-backtests',read.data.saved[0].rules);a.deepEqual(run.data.rules.ctaPolicy,saved.data.rules.ctaPolicy);
  a.equal((await req('GET','/strategy-lab?asOf=2026-08-28',null,'user-b')).data.saved.length,0);
  a.equal((await req('POST','/strategy-backtests',{...payload,ctaPolicy:{mode:'secret'}})).status,422);
});
test('factor selection, ranking and individual parameters round-trip privately and drive run rules',async t=>{
  const {req}=await setup(t);
  const payload={...body,managers:[],excludedAllocation:'fully_invested',equityMix:{weights:{factors:1},factors:{enabled:['roic','fcfMargin'],fcfMargin:.08,roic:.2,qualityYears:5,qualityPassYears:4,rankBy:'fcfMargin',topN:7}},name:'Selected factors',operationId:'factor-selection-save'};
  const saved=await req('POST','/strategy-rules',payload);a.equal(saved.status,200);
  const own=await req('GET','/strategy-lab?asOf=2026-08-28');
  const f=own.data.saved[0].rules.equityMix.factors;
  a.deepEqual(f.enabled,['fcfMargin','roic']);a.equal(f.qualityPassYears,4);a.equal(f.topN,7);a.equal(f.fcfMargin,.08);a.equal(f.rankBy,'fcfMargin');
  a.deepEqual((await req('POST','/strategy-backtests',own.data.saved[0].rules)).data.rules.equityMix.factors,f);
  a.equal((await req('GET','/strategy-lab?asOf=2026-08-28',null,'user-b')).data.saved.length,0);
});
test('saved rules are owner-isolated, append-only, idempotent and separate from old strategy records',async t=>{
  const {req,store}=await setup(t);
  store.write('user-a','strategy','','old_strategy_1234',{fixture:true},()=>({fixture:true}));
  const payload={...body,name:'Private test strategy',operationId:'strategy_save_1234'};
  const first=await req('POST','/strategy-rules',payload),retry=await req('POST','/strategy-rules',payload);
  a.equal(first.status,200);a.equal(first.data.id,retry.data.id);
  a.equal((await req('GET','/strategy-lab?asOf=2026-08-28')).data.saved.length,1);
  a.equal((await req('GET','/strategy-lab?asOf=2026-08-28',null,'user-b')).data.saved.length,0);
  a.equal((await req('GET','/strategy-lab?asOf=2026-08-27')).data.saved.length,0);
  a.equal((await req('POST','/strategy-rules',{...payload,maxPremium:.15})).status,422);
  a.equal(store.list('user-a','strategy').length,1);a.equal(store.list('user-a','strategy_lab').length,1);
});
test('backtest worker concurrency bounded at two and capacity released after error',async t=>{
  const pending=[];const {req}=await setup(t,()=>new Promise((resolve,reject)=>pending.push({resolve,reject})));
  const one=req('POST','/strategy-backtests',body),two=req('POST','/strategy-backtests',body);
  while(pending.length<2)await new Promise(r=>setTimeout(r,5));
  a.equal((await req('POST','/strategy-backtests',body)).status,429);
  pending[0].reject(new Error('private internal detail'));pending[1].resolve({status:'ready'});
  const [failed,ready]=await Promise.all([one,two]);a.equal(failed.status,500);a.equal(failed.data.error,'strategy_request_failed');a.equal(ready.status,200);
  const three=req('POST','/strategy-backtests',body);while(pending.length<3)await new Promise(r=>setTimeout(r,5));pending[2].resolve({});a.equal((await three).status,200);
});
test('production returns busy for a second compute without queueing and releases its slot',async t=>{
  const pending=[];const {req}=await setup(t,()=>new Promise((resolve,reject)=>pending.push({resolve,reject})),{limits:strategyWorkerLimits({NODE_ENV:'production'})});
  const first=req('POST','/strategy-backtests',body);
  while(pending.length<1)await new Promise(r=>setTimeout(r,5));
  const second=await req('POST','/strategy-backtests',body);
  a.equal(second.status,429);a.equal(second.data.error,'strategy_busy');a.equal(pending.length,1);
  pending[0].resolve({status:'ready'});a.equal((await first).status,200);
  const third=req('POST','/strategy-backtests',body);while(pending.length<2)await new Promise(r=>setTimeout(r,5));
  pending[1].resolve({status:'ready'});a.equal((await third).status,200);
});
test('legacy hedge configuration remains readable and isolated by account',async t=>{
 const {req}=await setup(t);
 const hedge={type:'put_spread',date:'2026-09-09',expiry:'2026-10-16',capital:250000,coverage:1,beta:1,ctaReturn:0};
 const value={...body,hedge,name:'Four steps',operationId:'four_steps_save_1234'};
 const saved=await req('POST','/strategy-rules',value);a.equal(saved.status,200);a.deepEqual(saved.data.rules.hedge,hedge);
 a.equal((await req('POST','/strategy-rules',value)).data.id,saved.data.id);
 a.equal((await req('GET','/strategy-lab?asOf=2026-08-28',null,'user-b')).data.saved.length,0);
 const bad=await req('POST','/strategy-backtests',{...body,hedge:{...hedge,coverage:99}});a.equal(bad.status,422);
});
test('leverage rules round-trip privately; fixed interest and ranges are server-enforced',async t=>{
 const {req}=await setup(t),leverage={multiple:1.5,annualRate:.04,reset:'filing'};
 const payload={...body,leverage,name:'Leveraged rules',operationId:'leverage_rules_1234'};
 const saved=await req('POST','/strategy-rules',payload);a.equal(saved.status,200);a.deepEqual(saved.data.rules.leverage,leverage);
 a.equal(saved.data.rules.hedge,undefined);
 const read=await req('GET','/strategy-lab?asOf=2026-08-28');a.deepEqual(read.data.saved[0].rules.leverage,leverage);
 a.equal((await req('GET','/strategy-lab?asOf=2026-08-28',null,'user-b')).data.saved.length,0);
 for(const patch of [{annualRate:.05},{multiple:9},{reset:'daily'}])a.equal((await req('POST','/strategy-backtests',{...body,leverage:{...leverage,...patch}})).status,422);
});
test('fully invested subset rules are explicit, owner-private and do not rewrite old saved rules',async t=>{
 const {req}=await setup(t);
 const old=await req('POST','/strategy-rules',{...body,name:'Legacy',operationId:'legacy_allocation_save'});
 const current=await req('POST','/strategy-rules',{...body,excludedAllocation:'fully_invested',name:'Full investment',operationId:'full_investment_save'});
 a.equal(current.status,200);a.equal(current.data.rules.excludedAllocation,'fully_invested');
 a.equal(old.data.rules.excludedAllocation,'redistribute');
 const read=await req('GET','/strategy-lab?asOf=2026-08-28');a.equal(read.data.saved.length,2);
 a.equal((await req('GET','/strategy-lab?asOf=2026-08-28',null,'user-b')).data.saved.length,0);
 const run=await req('POST','/strategy-backtests',{...body,excludedAllocation:'fully_invested'});
 a.equal(run.status,200);a.equal(run.data.rules.excludedAllocation,'fully_invested');
 a.equal((await req('GET','/strategy-lab?asOf=2026-08-28')).data.saved.length,2);
});

test('saved strategy archive hides target rule for owner while preserving append-only history and other rules',async t=>{
  const {req}=await setup(t);
  const first=await req('POST','/strategy-rules',{...body,name:'Keep me',operationId:'keep_rule_op'});
  const second=await req('POST','/strategy-rules',{...body,name:'Archive me',operationId:'archive_rule_op'});
  a.equal((await req('GET','/strategy-lab?asOf=2026-08-28')).data.saved.length,2);
  const arch=await req('POST','/strategy-rules/archive',{targetId:second.data.id,operationId:'archive_operation_0001'});
  a.equal(arch.status,200);
  const after=await req('GET','/strategy-lab?asOf=2026-08-28');
  a.equal(after.data.saved.length,1);
  a.equal(after.data.saved[0].id,first.data.id);
});
