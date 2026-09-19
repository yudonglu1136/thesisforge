// Read-only source staging for the explicitly requested September catalog additions.
// No serving database, dashboard, price cache, or existing Guru artifact is written.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {pathToFileURL} from 'node:url';

export const additionIds = Object.freeze(['william-heard', 'evan-mcgoff', 'michael-cuggino', 'john-stamas']);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');

export function validateHistory(guru, history) {
  const errors = [], accessions = new Set(), quarters = new Set();
  for (const quarter of history) {
    const filing = quarter.filing;
    if (filing.filerCik !== guru.cik) errors.push(`wrong_cik:${quarter.reportDate}:${filing.filerCik}`);
    if (accessions.has(filing.accessionNumber)) errors.push(`duplicate_accession:${filing.accessionNumber}`);
    if (quarters.has(quarter.reportDate)) errors.push(`duplicate_quarter:${quarter.reportDate}`);
    accessions.add(filing.accessionNumber); quarters.add(quarter.reportDate);
    const holdingIds = new Set();
    let weight = 0, commonValue = 0, reportedValue = 0;
    for (const holding of quarter.holdings) {
      if (holdingIds.has(holding.id)) errors.push(`duplicate_holding:${quarter.reportDate}:${holding.id}`);
      holdingIds.add(holding.id);
      if (![holding.shares, holding.value, holding.pctPortfolio].every(Number.isFinite)) errors.push(`invalid_number:${quarter.reportDate}:${holding.id}`);
      weight += holding.pctPortfolio;
      reportedValue += holding.value;
      if (holding.pctPortfolio > 0) commonValue += holding.value;
    }
    if (quarter.commonLongValue > 0 && Math.abs(weight - 1) > 1e-9) errors.push(`weight_total:${quarter.reportDate}`);
    if (Math.abs(commonValue - quarter.commonLongValue) > 0.01) errors.push(`common_value_total:${quarter.reportDate}`);
    if (Math.abs(reportedValue - quarter.reported13fTableValue) > 0.01) errors.push(`reported_value_total:${quarter.reportDate}`);
  }
  return errors;
}

export async function stage(out) {
  if (!path.isAbsolute(out)) throw Error('absolute_staging_directory_required');
  if (!process.env.SEC_USER_AGENT || /example\.com/.test(process.env.SEC_USER_AGENT)) throw Error('SEC_contact_required');
  fs.mkdirSync(out, {recursive: true, mode: 0o700});
  const cache = path.join(out, 'sec-sources');
  fs.mkdirSync(cache, {recursive: true, mode: 0o700});
  process.env.SQLITE_DB_PATH = path.join(out, 'isolated-staging.sqlite');
  for (const key of ['SYNC_BUNDLED_VALUATION_SNAPSHOTS','SYNC_BUNDLED_GURU_BACKTESTS','SYNC_BUNDLED_DIVIDEND_CALENDAR','SYNC_BUNDLED_PODCAST_INSIGHTS']) process.env[key] = 'false';
  const originalFetch = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = async (input, init) => {
    const url = String(input), parsed = new URL(url);
    if (!['data.sec.gov', 'www.sec.gov'].includes(parsed.hostname)) throw Error('non_SEC_source_blocked');
    const file = path.join(cache, sha(url) + '.json');
    if (fs.existsSync(file)) {
      const stored = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (stored.url !== url || sha(stored.body) !== stored.sha256) throw Error('SEC_cache_integrity_failure');
      return new Response(stored.body, {status: stored.status, headers: stored.headers});
    }
    const response = await originalFetch(input, init), body = await response.text();
    if (response.ok) fs.writeFileSync(file, JSON.stringify({url, status: response.status, headers: Object.fromEntries(response.headers), sha256: sha(body), fetchedAt: new Date().toISOString(), body}), {mode: 0o600});
    if (++requests % 20 === 0) console.log(JSON.stringify({event: 'source_progress', requests}));
    return new Response(body, {status: response.status, headers: response.headers});
  };
  try {
    const {gurus} = await import('../server/gurus.js');
    const {load13fHoldingHistory, refreshGuruSnapshot, refreshGuruExposureSnapshot} = await import('../server/secClient.js');
    const reports = [];
    for (const id of additionIds) {
      const guru = gurus.find(g => g.id === id);
      if (!guru || guru.type !== 'manager13f') throw Error('missing_configured_manager:' + id);
      console.log(JSON.stringify({event: 'start', id, cik: guru.cik}));
      const history = await load13fHoldingHistory(guru, {years: 'all', limit: 0});
      const metadata = Object.fromEntries(['excludedFilings','duplicateAccessions','blockedReportDates','reportingCiks','filingErrors'].map(k => [k, history[k]]));
      const validationErrors = validateHistory(guru, history);
      const snapshot = await refreshGuruSnapshot(id, {persist: false});
      const exposure = await refreshGuruExposureSnapshot(id, {limit: 40, persist: false});
      const artifact = {guru, stagedAt: new Date().toISOString(), history, ...metadata, validationErrors, snapshot, exposure};
      fs.writeFileSync(path.join(out, id + '.json'), JSON.stringify(artifact, null, 2), {mode: 0o600});
      const report = {id, cik: guru.cik, quarters: history.length, earliest: history[0]?.reportDate, latest: history.at(-1)?.reportDate, validationErrors, ...metadata};
      reports.push(report);
      fs.writeFileSync(path.join(out, 'staging-report.json'), JSON.stringify({schemaVersion: 1, servingDatabaseWritten: false, managers: reports}, null, 2), {mode: 0o600});
      console.log(JSON.stringify({event: 'staged', id, quarters: history.length, earliest: history[0]?.reportDate, latest: history.at(-1)?.reportDate, errors: validationErrors.length, filingErrors: metadata.filingErrors.length}));
    }
    return reports;
  } finally { globalThis.fetch = originalFetch; }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  stage(process.argv[2]).catch(error => { console.error(error.stack); process.exitCode = 1; });
}
