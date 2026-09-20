#!/usr/bin/env node
// Release gate for the redesigned Guru surfaces, NOT the legacy /api/health
// database or the operational schema-compatibility smoke. No server startup,
// database initializer, network call, cache refresh or private-store read.
// node scripts/audit-investment-guru-readiness.mjs --db /release/research.sqlite \
//   --as-of YYYY-MM-DD --refresh-generation <root 64-hex> --not-before <ISO>
// Omitting the last two arguments produces a failing diagnostic, never a
// publication certificate. JSON contains identifiers/counts, not holdings/prices.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import {
  gurus,
  requiredGuruCurveWindows,
  requiredGuruCurveWindowsFor,
  manager13fPublicProxyAllowed
} from '../server/gurus.js';
import { holdingResolutionVersion } from '../server/cusipOverrides.js';
import { auditManager13fStrictReadyPayload } from '../server/backtestStrictAudit.js';
import { auditPublicHoldingsProxyPayload } from '../server/backtestProxyAudit.js';
import { auditPayload, performance } from '../server/guruTurnoverMath.js';
import { INVESTMENT_ALLOWED_SOURCE_TABLES } from '../server/investmentRuntimeConfig.js';

const requiredTables = ['guru_exposure_snapshots', 'guru_snapshots', 'guru_backtests'];
const day = 86400000;
const isDate = value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
  && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0,10) === value;
const isTimestamp = value => typeof value === 'string' && value.includes('T') && Number.isFinite(Date.parse(value));
const cik = value => /^\d{1,10}$/.test(String(value ?? '')) ? String(value).padStart(10,'0') : null;
const fingerprint = file => { const s=fs.statSync(file); return {device:s.dev,inode:s.ino,bytes:s.size,mtimeMs:s.mtimeMs}; };

export function currentGuruAuditIdentity() {
  // backtest.js imports localDatabase.js and must NOT be imported by a read-only
  // operator check. Fail closed if its literal declarations ever change shape.
  const source=fs.readFileSync(new URL('../server/backtest.js',import.meta.url),'utf8');
  const read=name=>{
    const value=source.match(new RegExp(`export const ${name} = ["']([^"']+)["'];`))?.[1];
    if(!value)throw new Error('unrecognized_current_backtest_method_declaration');
    return value;
  };
  return {strict:read('manager13fBacktestMethodVersion'),proxy:read('manager13fProxyMethodVersion'),security:holdingResolutionVersion()};
}

function inspectProfiles(read, managers, asOf) {
  return managers.map(g=>{
    const failures=[],warnings=[],exposure=read('guru_exposure_snapshots',g.id),snapshot=read('guru_snapshots',g.id);
    const allowedCiks=new Set([g.cik,...(g.alternateCiks??[])].map(cik).filter(Boolean));
    for(const [label,p,id] of [['exposure',exposure,exposure?.guru?.id],['snapshot',snapshot,snapshot?.id]]) {
      if(!p){failures.push(`missing_or_invalid_${label}`);continue;}
      if(id!==g.id)failures.push(`${label}_manager_mismatch`);
      const profile=label==='exposure'?p.guru:p;
      if(!profile?.name||!profile?.entityName)failures.push(`${label}_profile_fields_missing`);
      if(!allowedCiks.has(cik(profile?.cik)))failures.push(`${label}_profile_cik_mismatch`);
    }
    const history=Array.isArray(exposure?.history)?exposure.history:[];
    const accessions=new Set();
    for(const h of history) {
      if(!h.accessionNumber||accessions.has(h.accessionNumber))failures.push('exposure_duplicate_or_missing_accession');
      accessions.add(h.accessionNumber);
      if(!isDate(h.reportDate)||!isDate(h.filingDate)||h.reportDate>h.filingDate)failures.push('exposure_invalid_filing_dates');
      const filingCik=h.filing?.cik??h.filing?.filerCik;
      if(!filingCik||!allowedCiks.has(cik(filingCik)))failures.push('exposure_filer_cik_mismatch');
    }
    const visible=history.filter(h=>isDate(h.filingDate)&&h.filingDate<=asOf&&isDate(h.reportDate)&&h.reportDate<=h.filingDate)
      .sort((a,b)=>a.filingDate.localeCompare(b.filingDate)||String(a.accessionNumber).localeCompare(String(b.accessionNumber)));
    const latest=visible.at(-1), filing=snapshot?.latestFiling, summary=snapshot?.summary;
    if(exposure&&!latest)failures.push('no_exposure_history_at_cutoff');
    if(latest && exposure.latest?.accessionNumber!==latest.accessionNumber)failures.push('exposure_latest_not_selected_history');
    if(snapshot) {
      if(!Array.isArray(snapshot.holdings)||!snapshot.holdings.length)failures.push('snapshot_holdings_empty');
      if(!Array.isArray(snapshot.activity))failures.push('snapshot_activity_missing');
      if(!Number.isInteger(summary?.totalPositions)||summary.totalPositions<1)failures.push('snapshot_position_count_invalid');
      if(!isDate(summary?.reportDate)||!isDate(summary?.filingDate)||summary.reportDate>summary.filingDate||summary.filingDate>asOf)failures.push('snapshot_invalid_filing_dates');
      const filerCiks=[filing?.filerCik??filing?.cik,...(filing?.componentCiks??[])].filter(Boolean);
      if(!filerCiks.length||filerCiks.some(c=>!allowedCiks.has(cik(c))))failures.push('snapshot_filer_cik_mismatch');
      if(latest&&(summary?.reportDate!==latest.reportDate||summary?.filingDate!==latest.filingDate||filing?.accessionNumber!==latest.accessionNumber)) {
        // Retired/unsupported profiles stay visible, but do not block the
        // enabled-manager curve gate on their explicitly historical last book.
        (g.disableSimulation?warnings:failures).push('snapshot_exposure_latest_mismatch');
      }
    }
    return {guruId:g.id,enabled:!g.disableSimulation,exposurePresent:!!exposure,snapshotPresent:!!snapshot,
      historyRows:history.length,visibleHistoryRows:visible.length,latestReportDate:latest?.reportDate??null,
      latestAccession:latest?.accessionNumber??null,snapshotHoldings:snapshot?.holdings?.length??0,
      failures:[...new Set(failures)],warnings:[...new Set(warnings)]};
  });
}

function inspectCurve(read,g,years,options) {
  const {versions,asOf,now,refreshGeneration,notBefore,profile}=options;
  const s=read('guru_backtests',g.id,years),p=read('guru_backtest_proxies',g.id,years);
  const failures=[];
  const identity=(payload,proxy=false)=>payload?.guru?.id===g.id&&payload?.method?.version===versions.strict
    &&payload?.method?.securityMasterVersion===versions.security&&String(payload?.method?.years)===String(years)
    &&payload.method.benchmark==='SPY'&&(!proxy||(payload.method.variant===versions.proxy
      &&payload.proxy?.methodVersion===versions.proxy&&payload.proxy?.securityMasterVersion===versions.security));
  if(!s)failures.push('missing_or_invalid_strict_cache');
  else if(!identity(s))failures.push('incompatible_strict_identity');
  let selected=null,basis=null;
  if(identity(s)&&s.status==='ready') {
    const audit=auditManager13fStrictReadyPayload(s);
    if(audit.ok){selected=s;basis='strict';}else failures.push(audit.reason);
  } else if(identity(s)&&s.status==='insufficient_data') {
    if(!manager13fPublicProxyAllowed(g.id,years))failures.push('proxy_not_permitted_for_manager_window');
    else if(!p)failures.push('missing_or_invalid_proxy_cache');
    else if(!identity(p,true)||p.status!=='proxy_ready')failures.push('incompatible_proxy_identity');
    else if(p.proxy.strictFailureGeneratedAt!==s.generatedAt||p.generatedAt!==s.generatedAt
      ||((s.refreshGeneration||p.refreshGeneration)&&(!s.refreshGeneration||p.refreshGeneration!==s.refreshGeneration)))failures.push('proxy_not_linked_to_strict_failure');
    else {
      const audit=auditPublicHoldingsProxyPayload(p);
      if(audit.ok){selected=p;basis='proxy';}else failures.push(audit.reason);
    }
  } else if(identity(s))failures.push(`strict_status_${s.status??'missing'}`);
  if(selected) {
    try {auditPayload(selected);}catch{failures.push('turnover_or_performance_reconciliation_failed');}
    if(!isTimestamp(selected.generatedAt)||Date.parse(selected.generatedAt)>now+300000
      ||now-Date.parse(selected.generatedAt)>48*3600000)failures.push('curve_generated_at_stale_or_future');
    const end=selected.window?.end;
    if(!isDate(end)||end>asOf||(Date.parse(asOf)-Date.parse(end))/day>12)failures.push('curve_end_stale_or_future');
    if(profile?.latestReportDate&&selected.quarterContributions?.at(-1)?.reportDate!==profile.latestReportDate)
      failures.push('curve_exposure_latest_report_mismatch');
  }
  const displayable=!!selected&&!failures.length;
  const publicationFailures=[];
  if(!refreshGeneration||!notBefore)publicationFailures.push('release_attestation_missing');
  else if(selected)for(const payload of basis==='proxy'?[s,selected]:[selected]) {
    if(payload.refreshGeneration!==`${refreshGeneration}:${years}`)publicationFailures.push('refresh_generation_mismatch');
    if(!isTimestamp(payload.generatedAt)||Date.parse(payload.generatedAt)<Date.parse(notBefore))publicationFailures.push('curve_predates_release');
  }
  return {row:{guruId:g.id,years,basis,displayable,releaseReady:displayable&&!publicationFailures.length,
    storedStrictStatus:s?.status??null,storedStrictSecurity:s?.method?.securityMasterVersion??null,
    generatedAt:selected?.generatedAt??s?.generatedAt??null,endDate:selected?.window?.end??s?.window?.end??null,
    failures,publicationFailures:[...new Set(publicationFailures)]},
    // Compact internal-only rows for the exact same common-session benchmark
    // comparison as guruStudy(); never include financial observations in report.
    equity:displayable&&years===5?selected.equity.filter(e=>e.date<=asOf):null};
}

export function inspectInvestmentGuruReadiness(db,{asOf,now=Date.now(),refreshGeneration='',notBefore='',
  versions=currentGuruAuditIdentity(),catalog=gurus}={}) {
  if(!isDate(asOf)||!Number.isFinite(now))throw new Error('valid_as_of_and_clock_required');
  if(refreshGeneration&&!/^[a-f0-9]{64}$/.test(refreshGeneration))throw new Error('invalid_refresh_generation');
  if(notBefore&&(!isTimestamp(notBefore)||Date.parse(notBefore)>now+300000))throw new Error('invalid_not_before');
  if(!!refreshGeneration!==!!notBefore)throw new Error('generation_and_not_before_must_be_paired');
  const managers=catalog.filter(g=>g.type==='manager13f'),enabled=managers.filter(g=>!g.disableSimulation);
  if(!managers.length||new Set(catalog.map(g=>g.id)).size!==catalog.length)throw new Error('invalid_dynamic_catalog');
  const tables=new Set(db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r=>r.name));
  const structuralFailures=requiredTables.filter(t=>!tables.has(t)).map(table=>({table,reason:'required_table_missing'}));
  const knownIds=new Set(catalog.map(g=>g.id)),managerIds=new Set(managers.map(g=>g.id)),enabledIds=new Set(enabled.map(g=>g.id));
  for(const table of [...requiredTables,'guru_backtest_proxies'].filter(t=>tables.has(t))) {
    const curves=table==='guru_backtests'||table==='guru_backtest_proxies';
    const keys=db.prepare(`SELECT guru_id${curves?',years':''}, COUNT(*) n FROM ${table} GROUP BY guru_id${curves?',years':''}`).all();
    for(const r of keys) {
      if(r.n!==1)structuralFailures.push({table,guruId:r.guru_id,...(curves?{years:r.years}:{}),reason:'duplicate_key'});
      if(!knownIds.has(r.guru_id))structuralFailures.push({table,guruId:r.guru_id,reason:'unconfigured_guru'});
      if(curves&&requiredGuruCurveWindows.includes(Number(r.years))&&managerIds.has(r.guru_id)&&!enabledIds.has(r.guru_id)) {
        // Historical unsupported rows are allowed, but never counted in the
        // exact enabled matrix; a ready disabled curve is a publication error.
        const rows=db.prepare(`SELECT payload_json FROM ${table} WHERE guru_id=? AND years=?`).all(r.guru_id,r.years);
        if(rows.some(x=>{try{return ['ready','proxy_ready'].includes(JSON.parse(x.payload_json).status);}catch{return false;}}))
          structuralFailures.push({table,guruId:r.guru_id,years:r.years,reason:'disabled_manager_ready_curve'});
      }
    }
  }
  const statements=new Map();
  const read=(table,id,years)=>{
    if(!tables.has(table))return null;
    if(!statements.has(table))statements.set(table,db.prepare(`SELECT payload_json FROM ${table} WHERE guru_id=?${years===undefined?'':' AND years=?'}`));
    const rows=years===undefined?statements.get(table).all(id):statements.get(table).all(id,years);
    if(rows.length!==1)return null;
    try {const p=JSON.parse(rows[0].payload_json);return p&&typeof p==='object'&&!Array.isArray(p)?p:null;}catch{return null;}
  };
  const profiles=inspectProfiles(read,managers,asOf),rows=[],studies=[];
  const profileById=new Map(profiles.map(p=>[p.guruId,p]));
  for(const g of enabled)for(const years of requiredGuruCurveWindowsFor(g)) {
    const result=inspectCurve(read,g,years,{versions,asOf,now,refreshGeneration,notBefore,profile:profileById.get(g.id)});rows.push(result.row);
    if(result.equity)studies.push({id:g.id,equity:result.equity});
  }
  const comparison={managers:studies.length,expectedManagers:enabled.length,commonObservations:0,start:null,end:null,failures:[]};
  if(studies.length) {
    const sets=studies.map(s=>new Set(s.equity.map(e=>e.date)));
    const dates=studies[0].equity.map(e=>e.date).filter(d=>sets.every(s=>s.has(d))),common=new Set(dates);
    Object.assign(comparison,{commonObservations:dates.length,start:dates[0]??null,end:dates.at(-1)??null});
    if(dates.length<3)comparison.failures.push('insufficient_common_sessions');
    else {
      const benchmarks=studies.map(s=>performance(s.equity.filter(e=>common.has(e.date)),'benchmark'));
      if(benchmarks.some(b=>!Number.isFinite(b.cagr)||Math.abs(b.cagr-benchmarks[0].cagr)>=1e-7
        ||!Number.isFinite(b.sharpe)||Math.abs(b.sharpe-benchmarks[0].sharpe)>=1e-7))comparison.failures.push('common_benchmark_not_comparable');
    }
  }else comparison.failures.push('no_comparable_study_curves');
  if(studies.length!==enabled.length)comparison.failures.push('study_population_incomplete');
  const profileFailures=profiles.filter(r=>r.failures.length),curveFailures=rows.filter(r=>!r.releaseReady);
  const byWindow=Object.fromEntries(requiredGuruCurveWindows.map(y=>[`${y}Y`,{
    expected:enabled.filter(g=>requiredGuruCurveWindowsFor(g).includes(y)).length,
    displayable:rows.filter(r=>r.years===y&&r.displayable).length,
    releaseReady:rows.filter(r=>r.years===y&&r.releaseReady).length}]));
  const ok=!structuralFailures.length&&!profileFailures.length&&!curveFailures.length&&!comparison.failures.length;
  return {auditVersion:'investment-guru-readiness-v1',status:ok?'pass':'failed',asOf,checkedAt:new Date(now).toISOString(),
    scope:'Redesigned public research Guru data only. No SEC source re-ingestion, price rebuild, authenticated browser acceptance or legacy health certification.',
    identity:versions,attestation:{refreshGeneration:refreshGeneration||null,notBefore:notBefore||null},
    population:{managerIds:managers.map(g=>g.id),enabledManagerIds:enabled.map(g=>g.id),requiredWindows:[...requiredGuruCurveWindows]},
    structuralFailures,profiles:{expected:managers.length,presentExposure:profiles.filter(r=>r.exposurePresent).length,
      presentSnapshot:profiles.filter(r=>r.snapshotPresent).length,failures:profileFailures,rows:profiles},
    curves:{expected:rows.length,displayable:rows.filter(r=>r.displayable).length,releaseReady:rows.filter(r=>r.releaseReady).length,byWindow,failures:curveFailures,rows},comparison};
}

export function auditInvestmentGuruFile(file,options) {
  const before=fingerprint(file);
  if(fs.existsSync(`${file}-wal`)||fs.existsSync(`${file}-shm`))throw new Error('public_database_sidecars_present');
  // A read-only SQLite connection may still create WAL shared-memory sidecars.
  // Inspect the public file header before opening SQLite, so unsupported WAL
  // inputs are refused without creating those files as a side effect.
  const header=Buffer.alloc(100),fd=fs.openSync(file,'r');
  try {fs.readSync(fd,header,0,header.length,0);}finally{fs.closeSync(fd);}
  if(header.subarray(0,16).toString()!=='SQLite format 3\0'||header[18]!==1||header[19]!==1)
    throw new Error('public_database_not_self_contained');
  const db=new DatabaseSync(file,{readOnly:true});
  try {
    db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000; PRAGMA cache_size=-8192; PRAGMA mmap_size=0; BEGIN;');
    if(db.prepare('PRAGMA journal_mode').get().journal_mode!=='delete')throw new Error('public_database_not_self_contained');
    const schema=db.prepare("SELECT type,name FROM sqlite_master WHERE type IN ('table','view','trigger')").all();
    if(schema.some(r=>r.type!=='table'||!INVESTMENT_ALLOWED_SOURCE_TABLES.includes(r.name)))throw new Error('not_an_isolated_public_research_database');
    return {...inspectInvestmentGuruReadiness(db,options),source:{...before,queryOnly:true,privateDataRead:false,legacyDatabaseOpened:false}};
  }finally {
    db.close();
    if(JSON.stringify(before)!==JSON.stringify(fingerprint(file)))throw new Error('source_changed_during_audit');
    if(fs.existsSync(`${file}-wal`)||fs.existsSync(`${file}-shm`))throw new Error('public_database_sidecars_present');
  }
}

export function parseGuruReadinessArgs(argv) {
  const options={};
  for(let i=0;i<argv.length;i++) {
    const [key,inline]=argv[i].split(/=(.*)/s),name={'--db':'db','--as-of':'asOf','--refresh-generation':'refreshGeneration','--not-before':'notBefore'}[key];
    if(!name||options[name]!==undefined)throw new Error('unknown_or_duplicate_argument');
    const value=inline??argv[++i];if(!value||value.startsWith('--'))throw new Error('missing_argument_value');options[name]=value;
  }
  if(!options.db||!options.asOf)throw new Error('explicit_research_db_and_as_of_required');
  return options;
}

if(process.argv[1]&&fs.existsSync(process.argv[1])&&fileURLToPath(import.meta.url)===fs.realpathSync(process.argv[1])) {
  try {
    const {db,...options}=parseGuruReadinessArgs(process.argv.slice(2)),report=auditInvestmentGuruFile(db,options);
    console.log(JSON.stringify(report,null,2));if(report.status!=='pass')process.exitCode=1;
  }catch(error){console.error(JSON.stringify({status:'failed',error:String(error.message).slice(0,180)}));process.exitCode=1;}
}
