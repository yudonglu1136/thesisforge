import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import express from 'express';
import { guruStudy } from './investmentGuruStudy.js';
import { performance } from './guruTurnoverMath.js';
import { registerInvestmentRoutes } from './investmentRoutes.js';
import { manager13fBacktestMethodVersion, manager13fProxyMethodVersion, manager13fSecurityMasterVersion } from './backtest.js';

function fixture(){
  const db=new DatabaseSync(':memory:');
  db.exec('CREATE TABLE guru_backtests(guru_id TEXT,years INTEGER,payload_json TEXT); CREATE TABLE guru_backtest_proxies(guru_id TEXT,years INTEGER,payload_json TEXT)');
  const equity=[{date:'2023-01-03',value:1,benchmark:1},{date:'2024-01-03',value:1.1,benchmark:1.05},{date:'2025-01-03',value:1.3,benchmark:1.2},{date:'2026-01-05',value:1.4,benchmark:1.3}];
  const p={status:'ready',generatedAt:'2026-09-01',method:{version:manager13fBacktestMethodVersion,securityMasterVersion:manager13fSecurityMasterVersion,minimumExecutionCoverage:.9,years:5,benchmark:'SPY'},window:{start:equity[0].date,end:equity.at(-1).date},equity,
    summary:{...performance(equity),averagePositions:1,averageCoverage:1},dataQuality:{minimumExecutionCoverage:.9,minimumObservedExecutionCoverage:1,attributionReconciliation:{difference:0}},rebalances:[{coveragePct:1,commonLongValue:100,selectedValue:100}],
    quarterContributions:equity.slice(0,-1).map((e,i)=>({executionDate:e.date,filingDate:`${Number(e.date.slice(0,4))-1}-12-31`,endDate:equity[i+1].date,nextExecutionDate:equity[i+1].date,portfolioReturn:equity[i+1].value/e.value-1,attributionReconciliation:0,cashWeight:0,contributions:[{ticker:'FIXTURE',weight:1,endingWeight:1}]}))};
  p.guru={id:'bill-ackman'};
  db.prepare('INSERT INTO guru_backtests VALUES(?,5,?)').run('bill-ackman',JSON.stringify(p));
  return {db};
}
test('same-date recomputation, no future values, no source writes',()=>{
  const source=fixture(),before=source.db.prepare('SELECT payload_json FROM guru_backtests').get();
  const r=guruStudy(source,'2025-06-30');
  assert.equal(r.rows.length,1);assert.equal(r.range.end,'2025-01-03');assert.equal(r.rows[0].annualTurnover,0);
  assert.ok(Math.abs(r.rows[0].cagr-(1.3**(365.25/731)-1))<1e-9);
  assert.equal(r.method.riskFreeRate,0);assert.equal(r.method.costsIncluded,false);
  assert.deepEqual(source.db.prepare('SELECT payload_json FROM guru_backtests').get(),before);
  assert.equal(guruStudy(source,'2025-06-30'),r);source.db.close();
});
test('invalid date/period rejected, insufficient history stays empty',()=>{
  const source=fixture();assert.throws(()=>guruStudy(source,'2026-02-30'));assert.throws(()=>guruStudy(source,'2026-08-28','ALL'));
  assert.equal(guruStudy(source,'2022-01-01').rows.length,0);assert.equal(guruStudy(source,'2026-08-28','1Y').range,null);source.db.close();
});
test('unreconciled source excluded, never manufactured into chart values',()=>{
  const source=fixture();const p=JSON.parse(source.db.prepare('SELECT payload_json FROM guru_backtests').get().payload_json);p.summary.cagr=123;
  source.db.prepare('UPDATE guru_backtests SET payload_json=?').run(JSON.stringify(p));
  const r=guruStudy(source,'2026-08-28');assert.equal(r.rows.length,0);assert.ok(r.unavailable.some(g=>g.id==='bill-ackman'));source.db.close();
});
test('current public-cache identity and strict audit apply to the study too',()=>{
  for(const mutate of [
    p=>{p.method.securityMasterVersion='old-security-master';},
    p=>{delete p.method.securityMasterVersion;},
    p=>{p.method.version='old-method';},
    p=>{p.method.years=10;},
    p=>{p.guru={id:'li-lu'};},
    p=>{p.dataQuality.minimumObservedExecutionCoverage=.5;},
    p=>{p.method.minimumExecutionCoverage=.5;},
  ]) {
    const source=fixture();
    assert.equal(guruStudy(source,'2026-08-28').rows.length,1);
    const p=JSON.parse(source.db.prepare('SELECT payload_json FROM guru_backtests').get().payload_json);
    mutate(p);source.db.prepare('UPDATE guru_backtests SET payload_json=?').run(JSON.stringify(p));
    const result=guruStudy(source,'2026-08-28');
    assert.equal(result.rows.length,0,'same-connection mutation must invalidate cached eligibility');
    assert.ok(result.unavailable.some(g=>g.id==='bill-ackman'));
    source.db.close();
  }
});
function proxyFixture(id='bill-ackman') {
  const source=fixture();
  const p=JSON.parse(source.db.prepare('SELECT payload_json FROM guru_backtests').get().payload_json);
  p.guru={id};
  const strict={...structuredClone(p),status:'insufficient_data',refreshGeneration:'a'.repeat(64)+':5'};
  p.status='proxy_ready';p.refreshGeneration=strict.refreshGeneration;
  p.method.variant=manager13fProxyMethodVersion;
  p.proxy={methodVersion:manager13fProxyMethodVersion,securityMasterVersion:manager13fSecurityMasterVersion,
    strictFailureGeneratedAt:strict.generatedAt,minimumSelectedBookCoverage:.5,averageSelectedBookCoverage:.5,
    maximumExcludedBookWeight:.5,minimumIncludedPositions:2,minimumProxyCoverage:.3,minimumProxyPositions:2};
  p.rebalances=p.rebalances.map(r=>({...r,selectedBookCoverage:.5,includedPositions:2}));
  source.db.prepare('UPDATE guru_backtests SET guru_id=?,payload_json=?').run(id,JSON.stringify(strict));
  source.db.prepare('INSERT INTO guru_backtest_proxies VALUES(?,5,?)').run(id,JSON.stringify(p));
  return source;
}
test('proxy requires current strict failure, exact linkage, method and per-quarter audited coverage',()=>{
  const valid=proxyFixture();assert.equal(guruStudy(valid,'2026-08-28').rows[0].basis,'proxy');valid.db.close();
  for(const mutate of [
    p=>{p.proxy.strictFailureGeneratedAt='older-generation';},
    p=>{p.refreshGeneration='b'.repeat(64)+':5';},
    p=>{p.proxy.securityMasterVersion='old-security-master';},
    p=>{p.method.variant='old-proxy-method';},
    p=>{p.rebalances[0].selectedBookCoverage=.2;},
    p=>{p.rebalances[0].includedPositions=1;},
  ]) {
    const source=proxyFixture();
    const p=JSON.parse(source.db.prepare('SELECT payload_json FROM guru_backtest_proxies').get().payload_json);
    mutate(p);source.db.prepare('UPDATE guru_backtest_proxies SET payload_json=?').run(JSON.stringify(p));
    assert.equal(guruStudy(source,'2026-08-28').rows.length,0);source.db.close();
  }
  const denied=proxyFixture('renaissance-technologies');
  assert.equal(guruStudy(denied,'2026-08-28').rows.length,0,'Renaissance 5Y may not use a public proxy');denied.db.close();
});
test('one malformed JSON payload is isolated to its manager',()=>{
  const source=fixture();source.db.prepare('INSERT INTO guru_backtests VALUES(?,5,?)').run('li-lu','malformed');
  const result=guruStudy(source,'2026-08-28');assert.equal(result.rows.length,1);
  assert.ok(result.unavailable.some(g=>g.id==='li-lu'));source.db.close();
});
test('authenticated route, bad input and no cache leakage',async()=>{
  const source=fixture(),app=express();app.use((req,res,next)=>{if(req.headers.authorization==='Bearer fixture')req.user={id:'fixture'};next();});
  registerInvestmentRoutes(app,{source,date:d=>d});const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
  try{const url=`http://127.0.0.1:${server.address().port}/api/investment/guru-study?asOf=2026-08-28`;
    assert.equal((await fetch(url)).status,401);const r=await fetch(url,{headers:{authorization:'Bearer fixture'}});
    assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'private, no-store');assert.equal((await r.json()).rows.length,1);
    assert.equal((await fetch(url+'&period=bad',{headers:{authorization:'Bearer fixture'}})).status,422);
  }finally{await new Promise(r=>server.close(r));source.db.close();}
});
