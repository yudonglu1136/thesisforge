// Candidate-only use of the existing strict/proxy engine; no quality overrides.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {additionIds} from './stage-guru-additions.mjs';

const out = process.argv[2];
const ids = process.argv.slice(3);
if (!out || !path.isAbsolute(out) || !ids.length || new Set(ids).size !== ids.length || ids.some(id => !additionIds.includes(id))) throw Error('explicit_addition_allowlist_required');
const candidate = path.join(out, 'runtime.candidate.sqlite');
if (!fs.existsSync(candidate)) throw Error('candidate_backup_required');
process.env.SQLITE_DB_PATH = candidate;
process.env.PRICE_CACHE_DIR = path.join(out, 'candidate-price-cache');
for (const key of ['SYNC_BUNDLED_VALUATION_SNAPSHOTS','SYNC_BUNDLED_GURU_BACKTESTS','SYNC_BUNDLED_DIVIDEND_CALENDAR','SYNC_BUNDLED_PODCAST_INSIGHTS']) process.env[key] = 'false';
const originalFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = String(input);
  if (['www.sec.gov','data.sec.gov'].includes(new URL(url).hostname)) {
    const file = path.join(out, 'sec-sources', crypto.createHash('sha256').update(url).digest('hex') + '.json');
    if (!fs.existsSync(file)) throw Error('SEC_source_not_staged:' + url);
    const source = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (source.url !== url || crypto.createHash('sha256').update(source.body).digest('hex') !== source.sha256) throw Error('SEC_source_hash_mismatch');
    return new Response(source.body, {status: source.status, headers: source.headers});
  }
  return originalFetch(input, init);
};
const {loadGuruBacktest} = await import('../server/backtest.js');
const {databaseInfo} = await import('../server/localDatabase.js');
console.log(JSON.stringify({event: 'candidate_curve_check', candidate, databaseInfo}));
for (const id of ids) for (const years of [5,10]) {
  console.log(JSON.stringify({event: 'start', id, years}));
  try {
    let artifacts;
    const publicPayload = await loadGuruBacktest(id, {refresh: true, years, detail: 'full', persist: false, shareComputation: false, preserveReadyOnFailure: false,
      onComputedArtifacts: value => {artifacts = value;}});
    if (!artifacts?.strictPayload) throw Error('missing_strict_artifact');
    fs.writeFileSync(path.join(out, `${id}-${years}y.json`), JSON.stringify({...artifacts, publicStatus: publicPayload.status}, null, 2), {mode: 0o600});
    console.log(JSON.stringify({event: 'result', id, years, strict: artifacts.strictPayload.status, proxy: artifacts.proxyPayload?.status, failure: artifacts.strictPayload.failure,
      coverageFailures: artifacts.strictPayload.dataQuality?.coverageFailures?.length ?? 0, window: artifacts.strictPayload.window}));
  } catch (error) {
    fs.writeFileSync(path.join(out, `${id}-${years}y.error.json`), JSON.stringify({id, years, error: error.message}, null, 2), {mode: 0o600});
    console.log(JSON.stringify({event: 'failed', id, years, error: error.message}));
    process.exitCode = 1;
  }
}
