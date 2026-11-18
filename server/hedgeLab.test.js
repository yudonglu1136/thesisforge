import test from 'node:test';
import a from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import express from 'express';
import {hedgeExperiment,HedgeSource,hedgeRules} from './hedgeLab.js';
import {registerHedgeRoutes} from './hedgeRoutes.js';
import {InvestmentStore} from './investmentStore.js';

const base={date:'2026-09-09',expiry:'2026-10-16',shares:100,coverage:1,fee:0,slippage:0,
 putTicker:'O:QQQ261016P00095000',shortPutTicker:'O:QQQ261016P00085000',callTicker:'O:QQQ261016C00105000'};
const chain=[['put',95,3,base.putTicker],['put',85,1,base.shortPutTicker],['call',105,2,base.callTicker]]
 .map(([type,strike,close,ticker])=>({type,strike,close,ticker,expiry:base.expiry,date:base.date,standard:1,multiplier:100,volume:100,provider:'fixture'}));
const result=(patch={})=>hedgeExperiment({...base,...patch},chain,100);
const row=(r,key)=>r.results.find(x=>x.strategy===key);
const at=(r,move)=>r.scenarios.find(x=>Math.abs(x.move-move)<1e-9).pnl;
test('expiry arithmetic hand-reconciles all four overlays and premiums once',()=>{
 const r=result();a.equal(at(row(r,'unhedged'),-.2),-2000);
 a.equal(at(row(r,'protective_put'),-.2),-800);
 a.equal(at(row(r,'collar'),-.2),-600);a.equal(at(row(r,'collar'),.2),400);
 a.equal(at(row(r,'put_spread'),-.2),-1200);a.equal(at(row(r,'put_spread'),-.5),-4200);
 a.equal(row(r,'collar').maxLoss,600);a.equal(row(r,'collar').maxGain,400);
 a.equal(row(r,'protective_put').maxGain,null);
 a.equal(row(r,'put_spread').maxLoss,9200);
});
test('opening slippage and commissions are charged for each leg',()=>{
 const r=row(result({fee:.65,slippage:.05}),'collar');
 a.ok(Math.abs(r.costs-26.3)<1e-10);a.ok(Math.abs(r.netDebit-126.3)<1e-10);
 a.ok(Math.abs(r.legs[0].assumedFill-3.15)<1e-10);a.ok(Math.abs(r.legs[1].assumedFill-1.9)<1e-10);
});
test('whole contracts respect stock coverage and preserve uncovered risk',()=>{
 const r=result({shares:250,coverage:.5});a.equal(r.contracts,1);a.equal(r.coveredShares,100);a.equal(r.uncoveredShares,150);a.equal(r.actualCoverage,.4);
 a.equal(row(r,'collar').maxGain,null);a.equal(row(r,'collar').maxLoss,15600);
});
test('net credit is not mistaken for free risk or an extra return',()=>{
 const c=chain.map(x=>({...x,close:x.type==='call'?4:x.close}));const r=hedgeExperiment(base,c,100);
 a.equal(row(r,'collar').netDebit,-100);a.equal(at(row(r,'collar'),0),100);a.equal(row(r,'collar').initialCapital,9900);
});
test('date, shares, coverage, fees and ticker inputs are bounded',()=>{
 for(const patch of [{date:'2026-02-30'},{expiry:'2026-09-01'},{shares:99},{shares:100.5},{coverage:2},{coverage:.5},{fee:-1},{slippage:Infinity},{putTicker:'file:/secret'}])a.throws(()=>hedgeRules({...base,...patch}));
});
test('unavailable, nonstandard, nontraded and inconsistent legs fail closed',()=>{
 for(const patch of [{date:'2026-09-08'},{expiry:'2026-11-20'},{standard:0},{multiplier:10},{volume:0},{close:null}])a.throws(()=>hedgeExperiment(base,[{...chain[0],...patch},...chain.slice(1)],100));
 a.throws(()=>hedgeExperiment(base,[chain[0],{...chain[1],close:4},chain[2]],100),/inconsistent_spread/);
 a.throws(()=>hedgeExperiment(base,[{...chain[0],strike:101,close:.5},...chain.slice(1)],100),/inconsistent_close/);
});
test('result is reproducible and does not mutate input observations',()=>{
 const copy=JSON.stringify(chain);a.deepEqual(result(),result());a.equal(JSON.stringify(chain),copy);
});
function fixtureDb(t){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tf-hedge-'));
 const file=path.join(dir,'hedge.sqlite'),db=new DatabaseSync(file);
 db.exec(fs.readFileSync(new URL('./hedgeSchema.sql',import.meta.url),'utf8'));
 db.prepare('INSERT INTO hedge_meta VALUES(?,?)').run('schema_version','1');
 for(const day of ['2026-09-08',base.date])db.prepare('INSERT INTO hedge_bars VALUES(?,?,?,?,?,?,?,?,?,?)').run('QQQ',day,'polygon_api','raw',100,101,99,100,1000,day);
 for(const c of chain){db.prepare('INSERT INTO hedge_contracts VALUES(?,?,?,?,?,?,?,?,?,?,?)').run(c.ticker,base.date,'polygon_api','QQQ',c.expiry,c.type,c.strike,100,'american',1,'{}');
  for(const day of ['2026-09-08',base.date])db.prepare('INSERT INTO hedge_bars VALUES(?,?,?,?,?,?,?,?,?,?)').run(c.ticker,day,'polygon_api','raw',c.close,c.close,c.close,c.close,100,day);
 }
 db.close();t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));return {dir,file};
}
test('database excludes future contract identity and never substitutes a legacy mark',t=>{
 const {file}=fixtureDb(t),source=new HedgeSource(file);t.after(()=>source.close());
 a.equal(source.catalog().chain.length,3);a.equal(source.catalog('2026-09-08').chain.length,0);
 a.throws(()=>source.catalog('2026-09-10'));a.equal(source.calculate(base).status,'scenario_only');
 a.equal(source.db.prepare('PRAGMA query_only').get().query_only,1);
});
test('authenticated APIs isolate saved experiments and preserve immutable snapshots',async t=>{
 const {dir,file}=fixtureDb(t),store=new InvestmentStore(path.join(dir,'users.sqlite'));
 const app=express();app.use(express.json());app.use((r,_,next)=>{if(r.headers['x-user'])r.user={id:r.headers['x-user']};next();});
 registerHedgeRoutes(app,{store},{file:()=>file});
 const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
 t.after(async()=>{await new Promise(r=>server.close(r));store.close();});
 const req=async(route,body=null,user='a')=>{
  const r=await fetch(`http://127.0.0.1:${server.address().port}/api/investment/hedge${route}`,{method:body?'POST':'GET',headers:{'Content-Type':'application/json',...(user?{'X-User':user}:{})},...(body?{body:JSON.stringify(body)}:{})});
  return {status:r.status,cache:r.headers.get('cache-control'),body:await r.json()};};
 for(const [route,body] of [['',null],['/calculate',base],['/save',base]])a.equal((await req(route,body,null)).status,401);
 const x=await req('/calculate',base);a.equal(x.status,200);a.equal(x.cache,'private, no-store');a.equal(store.list('a').length,0);
 const save={...base,name:'Private collar',operationId:'hedge_operation_1234'};
 const one=await req('/save',save),two=await req('/save',save);a.equal(one.body.id,two.body.id);
 a.equal((await req('',null,'a')).body.saved.length,1);a.equal((await req('',null,'b')).body.saved.length,0);
 a.equal((await req('/save',{...save,shares:200})).status,422);
});

test('BundledHedgeSource serves verified Polygon QQQ catalog and runs Protective Put / Collar / Put Spread when HEDGE_DB_PATH is unset',async t=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tf-hedge-bundled-'));
 const store=new InvestmentStore(path.join(dir,'users.sqlite'));
 const app=express();app.use(express.json());app.use((r,_,next)=>{r.user={id:'bundled-user'};next();});
 registerHedgeRoutes(app,{store},{file:()=>''});
 const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
 t.after(async()=>{await new Promise(r=>server.close(r));store.close();fs.rmSync(dir,{recursive:true,force:true});});
 const baseUrl=`http://127.0.0.1:${server.address().port}/api/investment/hedge`;
 const cat=await (await fetch(baseUrl)).json();
 a.equal(cat.status,'ready');
 a.ok(cat.dates.length>=5);
 a.ok(cat.spot>0);
 const exp=cat.expiries[0].expiry;
 const puts=cat.chain.filter(c=>c.expiry===exp&&c.type==='put'&&c.strike<=cat.spot).sort((x,y)=>y.strike-x.strike);
 const calls=cat.chain.filter(c=>c.expiry===exp&&c.type==='call'&&c.strike>=cat.spot).sort((x,y)=>x.strike-y.strike);
 a.ok(puts.length>=2&&calls.length>=1);
 const calcRes=await fetch(`${baseUrl}/calculate`,{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({date:cat.date,expiry:exp,shares:100,coverage:1,fee:.65,slippage:.05,
   putTicker:puts[0].ticker,shortPutTicker:puts[1].ticker,callTicker:calls[0].ticker})});
 a.equal(calcRes.status,200);
 const calc=await calcRes.json();
 a.equal(calc.results.length,4);
});
