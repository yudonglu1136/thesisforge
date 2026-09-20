import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { gurus, enabledManager13fGurus, requiredGuruCurveWindows } from '../server/gurus.js';
import { performance } from '../server/guruTurnoverMath.js';
import { auditInvestmentGuruFile, currentGuruAuditIdentity, inspectInvestmentGuruReadiness, parseGuruReadinessArgs } from './audit-investment-guru-readiness.mjs';

const versions={strict:'strict-current',proxy:'proxy-current',security:'security-current'};
const generation='a'.repeat(64),asOf='2026-09-12',now=Date.parse('2026-09-12T12:00:00Z');
const notBefore='2026-09-12T09:00:00Z';
const catalog=[gurus.find(g=>g.id==='bill-ackman'),gurus.find(g=>g.id==='li-lu')];
const options={asOf,now,versions,refreshGeneration:generation,notBefore,catalog};
const tables=['guru_exposure_snapshots','guru_snapshots','guru_backtests','guru_backtest_proxies'];
function schema(db) {
  for(const t of tables)db.exec(`CREATE TABLE ${t}(guru_id TEXT${t.includes('backtest')?',years INTEGER':''},payload_json TEXT)`);
}
function put(db,table,id,p,years) {
  db.prepare(`INSERT INTO ${table} VALUES(${years===undefined?'?,?':'?,?,?'})`).run(...(years===undefined?[id,JSON.stringify(p)]:[id,years,JSON.stringify(p)]));
}
function mutate(db,table,id,fn,years) {
  const where=`guru_id=?${years===undefined?'':' AND years=?'}`,params=years===undefined?[id]:[id,years];
  const p=JSON.parse(db.prepare(`SELECT payload_json FROM ${table} WHERE ${where}`).get(...params).payload_json);
  fn(p);db.prepare(`UPDATE ${table} SET payload_json=? WHERE ${where}`).run(JSON.stringify(p),...params);
}
function curve(id,years) {
  const equity=[{date:'2025-09-10',value:1,benchmark:1},{date:'2026-01-05',value:1.1,benchmark:1.06},
    {date:'2026-06-01',value:1.3,benchmark:1.15},{date:'2026-09-10',value:1.4,benchmark:1.22}];
  return {guru:{id},status:'ready',generatedAt:'2026-09-12T10:00:00Z',refreshGeneration:`${generation}:${years}`,
    method:{version:versions.strict,securityMasterVersion:versions.security,years,benchmark:'SPY',minimumExecutionCoverage:.9},
    equity,window:{start:equity[0].date,end:equity.at(-1).date},summary:{...performance(equity),averagePositions:1,averageCoverage:1},
    dataQuality:{minimumExecutionCoverage:.9,minimumObservedExecutionCoverage:1,attributionReconciliation:{difference:0}},
    rebalances:[{coveragePct:1,commonLongValue:100,selectedValue:100}],
    quarterContributions:equity.slice(0,-1).map((e,i)=>({executionDate:e.date,filingDate:`${Number(e.date.slice(0,4))-1}-12-31`,
      reportDate:'2026-06-30',endDate:equity[i+1].date,nextExecutionDate:equity[i+1].date,
      portfolioReturn:equity[i+1].value/e.value-1,attributionReconciliation:0,cashWeight:0,
      contributions:[{ticker:'FIXTURE',weight:1,endingWeight:1}]}))};
}
function fixture(db=new DatabaseSync(':memory:'),selected=catalog) {
  schema(db);
  for(const g of selected) {
    const filing={accessionNumber:`${g.cik}-26-000001`,reportDate:'2026-06-30',filingDate:'2026-08-14',cik:g.cik};
    const h={...filing,filing,topHoldings:[{id:'FIXTURE-COMMON',shares:1}],largestChanges:[]};
    put(db,'guru_exposure_snapshots',g.id,{guru:{id:g.id,name:g.name,entityName:g.entityName,cik:g.cik},latest:h,history:[h]});
    put(db,'guru_snapshots',g.id,{id:g.id,name:g.name,entityName:g.entityName,cik:g.cik,latestFiling:filing,
      summary:{reportDate:filing.reportDate,filingDate:filing.filingDate,totalPositions:1},holdings:[{id:'FIXTURE-COMMON'}],activity:[]});
    if(!g.disableSimulation)for(const y of requiredGuruCurveWindows)put(db,'guru_backtests',g.id,curve(g.id,y),y);
  }
  return db;
}
const codes=r=>[...r.structuralFailures.map(x=>x.reason),...r.profiles.failures.flatMap(x=>x.failures),
  ...r.curves.failures.flatMap(x=>[...x.failures,...x.publicationFailures]),...r.comparison.failures];
function checkMutation(fn,expected) {
  const db=fixture();try{fn(db);const r=inspectInvestmentGuruReadiness(db,options);assert.equal(r.status,'failed');assert.ok(codes(r).includes(expected),JSON.stringify(codes(r)));}finally{db.close();}
}

test('dynamic complete profile and 5Y/10Y publication matrix passes without changing rows',()=>{
  const db=fixture();try {
    const before=db.prepare('SELECT total_changes() n').get().n;
    const r=inspectInvestmentGuruReadiness(db,options);
    assert.equal(r.status,'pass',JSON.stringify(codes(r)));assert.equal(r.profiles.expected,catalog.length);
    assert.equal(r.curves.expected,catalog.length*requiredGuruCurveWindows.length);
    assert.equal(r.curves.releaseReady,4);assert.equal(r.comparison.commonObservations,4);
    assert.equal(db.prepare('SELECT total_changes() n').get().n,before);
    assert.equal(JSON.stringify(r).includes('FIXTURE'),false,'no holdings or raw price rows in evidence');
  }finally{db.close();}
});

test('empty source expands actual catalog rather than hard-coded counts',()=>{
  const db=new DatabaseSync(':memory:');try {
    schema(db);const r=inspectInvestmentGuruReadiness(db,{...options,catalog:gurus});
    assert.equal(r.profiles.expected,gurus.filter(g=>g.type==='manager13f').length);
    assert.equal(r.curves.expected,enabledManager13fGurus.length*requiredGuruCurveWindows.length);
    for(const id of ['william-heard','evan-mcgoff','michael-cuggino','john-stamas']) {
      assert.ok(r.profiles.failures.some(x=>x.guruId===id&&x.failures.includes('missing_or_invalid_exposure')));
      assert.deepEqual(r.curves.failures.filter(x=>x.guruId===id).map(x=>x.years),id==='john-stamas'?[]:[5,10]);
    }
  }finally{db.close();}
});

test('schema alone, duplicate keys, unknown IDs and malformed JSON fail closed',()=>{
  checkMutation(db=>db.prepare('DELETE FROM guru_exposure_snapshots WHERE guru_id=?').run(catalog[0].id),'missing_or_invalid_exposure');
  checkMutation(db=>db.exec('INSERT INTO guru_snapshots SELECT * FROM guru_snapshots LIMIT 1'),'duplicate_key');
  checkMutation(db=>db.prepare("UPDATE guru_snapshots SET payload_json='{' WHERE guru_id=?").run(catalog[0].id),'missing_or_invalid_snapshot');
  checkMutation(db=>put(db,'guru_exposure_snapshots','unconfigured',{}),'unconfigured_guru');
  checkMutation(db=>db.exec('DROP TABLE guru_backtests'),'required_table_missing');
});

test('manager/filer identity, duplicate exposure accession and latest filing joins are validated',()=>{
  for(const [table,fn,expected] of [
    ['guru_exposure_snapshots',p=>{p.guru.id='wrong';},'exposure_manager_mismatch'],
    ['guru_snapshots',p=>{p.cik='0000000001';},'snapshot_profile_cik_mismatch'],
    ['guru_snapshots',p=>{p.latestFiling.cik='0000000001';},'snapshot_filer_cik_mismatch'],
    ['guru_exposure_snapshots',p=>{p.history[0].filing.cik='0000000001';},'exposure_filer_cik_mismatch'],
    ['guru_exposure_snapshots',p=>{p.history.push(p.history[0]);},'exposure_duplicate_or_missing_accession'],
    ['guru_snapshots',p=>{p.latestFiling.accessionNumber='stale';},'snapshot_exposure_latest_mismatch'],
    ['guru_exposure_snapshots',p=>{p.history[0].filingDate='2026-02-30';},'exposure_invalid_filing_dates'],
    ['guru_snapshots',p=>{p.holdings=[];},'snapshot_holdings_empty'],
  ])checkMutation(db=>mutate(db,table,catalog[0].id,fn),expected);
});

test('configured alternate filer accepted; retired manager stays outside required matrix',()=>{
  const retired={...catalog[1],disableSimulation:true},selected=[catalog[0],retired],db=fixture(undefined,selected);
  try {
    const alternate=catalog[0].alternateCiks[0];
    mutate(db,'guru_snapshots',catalog[0].id,p=>{p.latestFiling.cik=alternate;});
    mutate(db,'guru_exposure_snapshots',catalog[0].id,p=>{p.history[0].filing.cik=alternate;});
    const r=inspectInvestmentGuruReadiness(db,{...options,catalog:selected});
    assert.equal(r.status,'pass',JSON.stringify(codes(r)));assert.equal(r.profiles.expected,2);assert.equal(r.curves.expected,2);
    put(db,'guru_backtests',retired.id,curve(retired.id,5),5);
    assert.ok(codes(inspectInvestmentGuruReadiness(db,{...options,catalog:selected})).includes('disabled_manager_ready_curve'));
  }finally{db.close();}
});

test('old security/method/window/manager identity cannot masquerade as ready',()=>{
  for(const fn of [p=>{p.method.securityMasterVersion='old';},p=>{p.method.version='old';},
    p=>{p.method.years=10;},p=>{p.guru.id='wrong';},p=>{p.method.benchmark='QQQ';}])
    checkMutation(db=>mutate(db,'guru_backtests',catalog[0].id,fn,5),'incompatible_strict_identity');
});

test('strict coverage, full-detail turnover reconciliation and freshness are necessary',()=>{
  for(const [fn,reason] of [
    [p=>{p.rebalances[0].coveragePct=.8;},'strict_rebalance_coverage_below_minimum'],
    [p=>{p.summary.cagr=99;},'turnover_or_performance_reconciliation_failed'],
    [p=>{delete p.quarterContributions;},'turnover_or_performance_reconciliation_failed'],
    [p=>{p.generatedAt='2026-09-01T00:00:00Z';},'curve_generated_at_stale_or_future'],
    [p=>{p.generatedAt='2027-01-01T00:00:00Z';},'curve_generated_at_stale_or_future'],
    [p=>{p.window.end='2026-08-01';},'curve_end_stale_or_future'],
    [p=>{p.quarterContributions.at(-1).reportDate='2026-03-31';},'curve_exposure_latest_report_mismatch'],
  ])checkMutation(db=>mutate(db,'guru_backtests',catalog[0].id,fn,5),reason);
});

function addProxy(db,id,years=5) {
  const p=curve(id,years),s=structuredClone(p);s.status='insufficient_data';
  db.prepare('DELETE FROM guru_backtests WHERE guru_id=? AND years=?').run(id,years);put(db,'guru_backtests',id,s,years);
  p.status='proxy_ready';p.method.variant=versions.proxy;
  p.proxy={methodVersion:versions.proxy,securityMasterVersion:versions.security,strictFailureGeneratedAt:s.generatedAt,
    minimumProxyCoverage:.3,minimumProxyPositions:2,minimumSelectedBookCoverage:.5,averageSelectedBookCoverage:.5,
    maximumExcludedBookWeight:.5,minimumIncludedPositions:2};
  p.rebalances=p.rebalances.map(r=>({...r,selectedBookCoverage:.5,includedPositions:2}));put(db,'guru_backtest_proxies',id,p,years);
}
test('policy-permitted exactly linked audited proxy is distinct from strict',()=>{
  const db=fixture();try {
    addProxy(db,catalog[0].id);const r=inspectInvestmentGuruReadiness(db,options);
    assert.equal(r.status,'pass',JSON.stringify(codes(r)));assert.equal(r.curves.rows[0].basis,'proxy');
  }finally{db.close();}
  for(const [fn,reason] of [
    [p=>{p.proxy.strictFailureGeneratedAt='older';},'proxy_not_linked_to_strict_failure'],
    [p=>{p.refreshGeneration='b'.repeat(64)+':5';},'proxy_not_linked_to_strict_failure'],
    [p=>{p.method.variant='old';},'incompatible_proxy_identity'],
    [p=>{p.rebalances[0].includedPositions=1;},'proxy_rebalance_positions_below_minimum'],
  ])checkMutation(db=>{addProxy(db,catalog[0].id);mutate(db,'guru_backtest_proxies',catalog[0].id,fn,5);},reason);
  const renaissance=gurus.find(g=>g.id==='renaissance-technologies'),other=fixture(undefined,[renaissance]);
  try {addProxy(other,renaissance.id);assert.ok(codes(inspectInvestmentGuruReadiness(other,{...options,catalog:[renaissance]})).includes('proxy_not_permitted_for_manager_window'));}finally{other.close();}
});

test('diagnostic identity pass is not publication without exact paired generation and not-before',()=>{
  const db=fixture();try {
    const r=inspectInvestmentGuruReadiness(db,{...options,refreshGeneration:'',notBefore:''});
    assert.equal(r.curves.displayable,4);assert.equal(r.curves.releaseReady,0);assert.equal(r.status,'failed');
    assert.ok(codes(r).includes('release_attestation_missing'));
    assert.throws(()=>inspectInvestmentGuruReadiness(db,{...options,notBefore:''}),/must_be_paired/);
  }finally{db.close();}
  checkMutation(db=>mutate(db,'guru_backtests',catalog[0].id,p=>{p.refreshGeneration='b'.repeat(64)+':5';},5),'refresh_generation_mismatch');
  checkMutation(db=>mutate(db,'guru_backtests',catalog[0].id,p=>{p.generatedAt='2026-09-12T08:00:00Z';},5),'curve_predates_release');
});

test('common SPY benchmark is compared across managers, not separate attractive metrics',()=>{
  checkMutation(db=>mutate(db,'guru_backtests',catalog[1].id,p=>{p.equity[1].benchmark*=1.01;},5),'common_benchmark_not_comparable');
});

test('file wrapper is read-only, refuses private schemas and does not initialize legacy DB',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tf-guru-readiness-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const file=path.join(dir,'research.sqlite'),db=fixture(new DatabaseSync(file));db.close();
  const hash=()=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'),before=hash();
  assert.equal(auditInvestmentGuruFile(file,options).status,'pass');assert.equal(hash(),before);
  assert.deepEqual(fs.readdirSync(dir),['research.sqlite']);
  const child=spawnSync(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(new URL('./audit-investment-guru-readiness.mjs',import.meta.url).href)}); console.log('read-only-import')`],
    {encoding:'utf8',env:{...process.env,SQLITE_DB_PATH:'/dev/null/no-writes.sqlite'}});
  assert.equal(child.status,0,child.stderr);assert.match(child.stdout,/read-only-import/);
  const stdin=spawnSync(process.execPath,['--input-type=module','-'],{encoding:'utf8',
    input:`await import(${JSON.stringify(new URL('./audit-investment-guru-readiness.mjs',import.meta.url).href)});`,
    env:{...process.env,SQLITE_DB_PATH:'/dev/null/no-writes.sqlite'}});
  assert.equal(stdin.status,0,stdin.stderr);
  const edit=new DatabaseSync(file);edit.exec('CREATE TABLE portfolio_nav_points(secret TEXT)');edit.close();
  assert.throws(()=>auditInvestmentGuruFile(file,options),/not_an_isolated_public/);
});

test('CLI requires explicit research path/date and refuses malformed or repeated arguments',()=>{
  assert.deepEqual(parseGuruReadinessArgs(['--db=/a/research.sqlite','--as-of',asOf]),{db:'/a/research.sqlite',asOf});
  for(const argv of [[],['--db','--as-of',asOf],['--db','/a','--db','/b'],['--unknown','x']])assert.throws(()=>parseGuruReadinessArgs(argv));
  const identity=currentGuruAuditIdentity();assert.match(identity.strict,/manager13f-/);assert.match(identity.security,/holding-resolution-/);
});

test('WAL-mode public inputs are rejected before SQLite can create sidecars',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tf-guru-readiness-wal-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const file=path.join(dir,'research.sqlite'),db=fixture(new DatabaseSync(file));
  db.exec('PRAGMA journal_mode=WAL;');db.close();
  const before=fs.readFileSync(file),names=fs.readdirSync(dir);
  assert.throws(()=>auditInvestmentGuruFile(file,options),/not_self_contained|sidecars_present/);
  assert.deepEqual(fs.readFileSync(file),before);assert.deepEqual(fs.readdirSync(dir),names);
});
