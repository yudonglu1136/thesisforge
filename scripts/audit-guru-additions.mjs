// Read-only audit of the four staged additions. This is not a publication gate
// bypass: it never installs a catalog, changes a source, or writes SQLite.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {additionIds, validateHistory} from './stage-guru-additions.mjs';
import {gurus} from '../server/gurus.js';

const out = process.argv[2], serving = process.argv[3];
if (!out || !serving || !path.isAbsolute(out) || !path.isAbsolute(serving)) throw Error('absolute_staging_and_serving_paths_required');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const oldCode = execFileSync('git', ['show', 'HEAD:server/gurus.js'], {encoding:'utf8'});
const prior = await import('data:text/javascript;base64,' + Buffer.from(oldCode).toString('base64'));
const originalCatalog = prior.gurus.filter(g => !additionIds.includes(g.id));
const unchangedCatalog = gurus.filter(g => !additionIds.includes(g.id));
if (JSON.stringify(originalCatalog) !== JSON.stringify(unchangedCatalog)) throw Error('non_target_catalog_changed');

const reports = [];
for (const id of additionIds) {
  const artifact = read(path.join(out, id + '.json'));
  const {guru, history, snapshot, exposure} = artifact;
  const errors = validateHistory(guru, history);
  const book = date => history.find(q => q.reportDate === date);
  const common = q => (q?.holdings || []).filter(h => h.holdingBucket === 'common_long');
  let checks = 0;
  const check = (actual, expected, label) => {
    checks++;
    const equal = typeof expected === 'number'
      ? Number.isFinite(actual) && Math.abs(actual - expected) <= Math.max(1e-9, Math.abs(expected) * 1e-12)
      : actual === expected;
    if (!equal) errors.push(`${label}:expected=${expected}:actual=${actual}`);
  };
  function verifySummary(summary, current, previous) {
    const rows = common(current), before = new Map(common(previous).map(h => [h.id, h]));
    const currentMap = new Map(rows.map(h => [h.id,h]));
    const counts = {new:0,increased:0,reduced:0,sold_out:0,unchanged:0};
    for (const key of new Set([...before.keys(),...currentMap.keys()])) {
      const a = currentMap.get(key), b = before.get(key);
      const action = !b ? 'new' : !a ? 'sold_out' : a.shares > b.shares ? 'increased' : a.shares < b.shares ? 'reduced' : 'unchanged';
      counts[action]++;
    }
    for (const [field, action] of Object.entries({newPositions:'new',increasedPositions:'increased',reducedPositions:'reduced',soldOutPositions:'sold_out'})) check(summary[field],counts[action],`${current.reportDate}:${field}`);
    const total = rows.reduce((s,h) => s + h.value,0);
    const ranked = rows.filter(h=>h.value>0).sort((a,b)=>b.value-a.value);
    check(summary.commonLongValue,total,`${current.reportDate}:commonLongValue`);
    check(summary.top10Weight,total ? ranked.slice(0,10).reduce((s,h)=>s+h.value,0)/total : 0,`${current.reportDate}:top10Weight`);
    check(summary.concentrationHhi,total ? rows.reduce((s,h)=>s+(h.value/total)**2,0):0,`${current.reportDate}:concentrationHhi`);
    if (summary.topHoldings) for (const [i,h] of summary.topHoldings.entries()) check(h.id,ranked[i]?.id,`${current.reportDate}:rank:${i+1}`);
    for (const h of [...(summary.largestChanges || []),...(summary.activity || [])]) {
      const a = currentMap.get(h.id), b = before.get(h.id);
      const delta = (a?.shares || 0)-(b?.shares || 0);
      check(h.changeShares,delta,`${current.reportDate}:${h.id}:changeShares`);
      check(h.changePct,b?.shares ? delta/Math.abs(b.shares):null,`${current.reportDate}:${h.id}:changePct`);
    }
  }
  verifySummary({...snapshot.summary,activity:snapshot.activity},book(snapshot.summary.reportDate),book(snapshot.summary.previousReportDate));
  for (const [i,q] of exposure.history.entries()) verifySummary(q,book(q.reportDate),i ? book(exposure.history[i-1].reportDate):null);
  for (const [i,h] of snapshot.holdings.entries()) {
    check(h.value,common(book(snapshot.summary.reportDate)).sort((a,b)=>b.value-a.value)[i]?.value,`snapshot_rank:${i+1}`);
    check(h.pctPortfolio,h.value/snapshot.summary.commonLongValue,`snapshot_weight:${h.id}`);
  }
  const curves = [5,10].map(years => {
    const file = path.join(out,`${id}-${years}y.json`), c = read(file);
    return {years,sha256:sha(fs.readFileSync(file)),generatedAt:c.strictPayload.generatedAt,strict:c.strictPayload.status,
      proxy:c.proxyPayload?.status || null,securityMasterVersion:c.strictPayload.method.securityMasterVersion,
      methodVersion:c.strictPayload.method.version,window:c.strictPayload.window,
      failure:c.strictPayload.failure || null,coverageFailures:c.strictPayload.dataQuality?.coverageFailures || []};
  });
  const heardCoverChecks = id === 'william-heard' ? history.filter(q => q.reportDate >= '2020-12-31' && q.reportDate <= '2021-09-30').map(q => {
    const url = q.filing.filingIndexUrl + 'primary_doc.xml';
    const source = read(path.join(out,'sec-sources',sha(url)+'.json'));
    const coverTotal = Number(source.body.match(/<(?:\w+:)?tableValueTotal>(.*?)</)?.[1]);
    const rowTotal = q.holdings.reduce((s,h)=>s+h.reportedValue,0);
    return {reportDate:q.reportDate,url,sha256:source.sha256,coverTotal,rowTotal,delta:rowTotal-coverTotal,
      normalizedDollars:q.reported13fTableValue,valueScales:[...new Set(q.holdings.map(h=>h.valueScale))],
      status:rowTotal===coverTotal ? 'reconciled' : 'source_total_discrepancy_unresolved'};
  }) : [];
  reports.push({id,name:guru.name,entityName:guru.entityName,cik:guru.cik,stagedAt:artifact.stagedAt,
    parsedQuarters:history.length,first:history[0].reportDate,last:history.at(-1).reportDate,
    originalQuarters:history.length + artifact.filingErrors.length,exposureQuarters:exposure.history.length,
    excludedAmendments:artifact.excludedFilings,filingErrors:artifact.filingErrors,duplicateAccessions:artifact.duplicateAccessions,
    latestSource:snapshot.latestFiling,latestSummary:snapshot.summary,checks,errors,curves,heardCoverChecks,
    stagedArtifactSha256:sha(fs.readFileSync(path.join(out,id+'.json')))});
}

const sourceReceipts = fs.readdirSync(path.join(out,'sec-sources')).filter(f=>f.endsWith('.json')).map(file=>{
  const s = read(path.join(out,'sec-sources',file));
  if (sha(s.body)!==s.sha256 || sha(s.url)+'.json'!==file) throw Error('source_cache_integrity_failure');
  return {url:s.url,sha256:s.sha256,fetchedAt:s.fetchedAt};
}).sort((a,b)=>a.url.localeCompare(b.url));
const baseline = new DatabaseSync(path.join(out,'runtime.candidate.sqlite'),{readOnly:true});
const live = new DatabaseSync(serving,{readOnly:true});
const tables = ['dashboard_snapshots','guru_assets','guru_snapshots','guru_exposure_snapshots','guru_backtests','guru_backtest_proxies'];
const databasePreservation = tables.map(table=>{
  const digest = db => {const rows=db.prepare(`SELECT * FROM "${table}"`).all().map(r=>JSON.stringify(r)).sort();return {rows:rows.length,sha256:sha(JSON.stringify(rows))};};
  const before=digest(baseline),after=digest(live);
  return {table,candidateClone:before,serving:after,unchanged:before.sha256===after.sha256};
});
const integrity = live.prepare('PRAGMA integrity_check').all();
baseline.close();live.close();
const report = {schemaVersion:1,generatedAt:new Date().toISOString(),status:'not_published',servingDatabaseWritten:false,
  nonTargetCatalog:{profiles:unchangedCatalog.length,sha256:sha(JSON.stringify(unchangedCatalog)),unchanged:true},
  databasePreservation,integrity,reports,sourceReceipts,
  caveats:[
    'Parsed quarters are staged, not installed. An arithmetic pass does not resolve conflicting SEC cover totals.',
    'Original-only amendment policy is unchanged. Missing CUSIPs and conflicting original totals are not guessed.',
    'Curve files are diagnostic runs, not a shared-generation release matrix; the additions-only security master is not installed.',
    'Publishing through the existing bootstrap requires fresh 5Y/10Y outcomes for every enabled Guru, not only these four.',
    'The serving strategy warehouse and preview have not been changed; this is not a completed backfill.'
  ]};
fs.writeFileSync(path.join(out,'addition-audit.json'),JSON.stringify(report,null,2),{mode:0o600});
console.log(JSON.stringify({status:report.status,managers:reports.map(r=>({id:r.id,parsed:r.parsedQuarters,originals:r.originalQuarters,checks:r.checks,errors:r.errors})),databasePreservation,integrity,sourceReceipts:sourceReceipts.length},null,2));
if (reports.some(r=>r.errors.length) || databasePreservation.some(t=>!t.unchanged) || integrity.some(r=>Object.values(r)[0]!=='ok')) process.exitCode=1;
