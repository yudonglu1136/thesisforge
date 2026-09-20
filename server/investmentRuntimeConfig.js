import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { resolveUserDataPaths } from './userDataPaths.js';
import { openStrategyDatabase } from './strategyDatabase.js';

export const INVESTMENT_RELEASE_VERSION = 'investment-runtime-release-v1';
export const INVESTMENT_REUSED_RELEASE_VERSION = 'investment-runtime-release-v2';
export const INVESTMENT_REQUIRED_SOURCE_TABLES = Object.freeze(['valuation_pit_model_runs', 'valuation_pit_financials', 'valuation_pit_guidance',
  'valuation_ticker_snapshots', 'guru_snapshots', 'guru_exposure_snapshots', 'guru_backtests', 'price_points',
  'investment_quality_annual', 'investment_quality_metadata']);
export const INVESTMENT_ALLOWED_SOURCE_TABLES = Object.freeze([...INVESTMENT_REQUIRED_SOURCE_TABLES,
  'guru_backtest_proxies', 'valuation_pit_source_metadata', 'valuation_pit_price_observations', 'valuation_snapshots',
  'investment_current_quotes', 'investment_current_quote_metadata', 'sqlite_sequence', 'sqlite_stat1', 'sqlite_stat4']);
export const verifiedInvestmentOwner = owner => typeof owner === 'string'
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(owner);
const within = (parent, child) => child.startsWith(`${parent}${path.sep}`);
const fail = code => { throw new Error(code); };
const absolute = (value, code) => typeof value === 'string' && path.isAbsolute(value)
  ? path.resolve(value) : fail(code);
const canonicalExisting = file => fs.realpathSync(file);

// These are small schema/identity checks, not a full database audit on every
// process restart. The private installer owns SHA-256 and integrity_check and
// writes the root-owned attestation only after those checks have passed.
export function validateInvestmentRelease(manifest, paths, { manifestPath, stat = fs.statSync, trustedUid = 0 } = {}) {
  const reused = manifest?.version === INVESTMENT_REUSED_RELEASE_VERSION;
  if ((!reused && manifest?.version !== INVESTMENT_RELEASE_VERSION) || manifest.state !== 'verified'
    || manifest.releaseId !== paths.releaseId || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{5,100}$/.test(manifest.releaseId ?? '')
    || !/^\d{4}-\d{2}-\d{2}$/.test(manifest.cutoff ?? '')
    || Number.isNaN(Date.parse(manifest.cutoff)) || new Date(manifest.cutoff).toISOString().slice(0,10) !== manifest.cutoff
    || manifest.checks?.integrity !== 'ok' || manifest.checks?.schema !== 'pass'
    || manifest.checks?.sourceAlignment !== 'pass' || manifest.checks?.privateDataExcluded !== true) fail('investment_release_not_verified');
  const manifestStat = stat(manifestPath);
  if (!manifestStat.isFile() || manifestStat.uid !== trustedUid || (manifestStat.mode & 0o022)) fail('investment_release_manifest_permissions');
  const directory = canonicalExisting(path.dirname(manifestPath));
  let base;
  if (reused) {
    if (!/^guru-sync-\d{8}-v[1-9]\d*$/.test(manifest.releaseId)) fail('investment_reuse_release_id_invalid');
    const ownDirectory = stat(directory);
    if (manifestStat.nlink !== 1 || (manifestStat.mode & 0o222) || ownDirectory.uid !== trustedUid
      || !ownDirectory.isDirectory() || (ownDirectory.mode & 0o222)) fail('investment_reuse_manifest_permissions');
    const reuse = manifest.reuse, basePath = absolute(reuse?.baseManifestPath, 'investment_reuse_manifest_invalid');
    if (path.basename(basePath) !== 'manifest.json' || canonicalExisting(basePath) !== basePath
      || path.dirname(path.dirname(basePath)) !== path.dirname(directory) || path.dirname(basePath) === directory
      || Object.keys(reuse?.files ?? {}).sort().join(',') !== 'composition,strategy') fail('investment_reuse_manifest_invalid');
    const info = stat(basePath), parent = stat(path.dirname(basePath));
    if (!info.isFile() || info.size > 65536 || info.uid !== trustedUid || info.nlink !== 1 || (info.mode & 0o222)
      || !parent.isDirectory() || parent.uid !== trustedUid || (parent.mode & 0o222)) fail('investment_reuse_manifest_permissions');
    const bytes = fs.readFileSync(basePath);
    if (crypto.createHash('sha256').update(bytes).digest('hex') !== reuse.baseManifestSha256) fail('investment_reuse_manifest_changed');
    base = JSON.parse(bytes);
    if (base.version !== INVESTMENT_RELEASE_VERSION || base.releaseId !== reuse.baseReleaseId || base.cutoff !== manifest.cutoff)
      fail('investment_reuse_base_mismatch');
    validateInvestmentRelease(base, { releaseId: base.releaseId, ...Object.fromEntries(
      ['research', 'strategy', 'composition'].map(key => [key, base.files?.[key]?.path])) },
    { manifestPath: basePath, stat, trustedUid });
  }
  const seen = new Set();
  for (const key of ['research', 'strategy', 'composition']) {
    const entry = manifest.files?.[key];
    if (!entry || !Number.isSafeInteger(entry.bytes) || entry.bytes <= 0 || !/^[a-f0-9]{64}$/.test(entry.sha256 ?? '')) fail('investment_release_file_invalid');
    const file = absolute(entry.path, 'investment_release_file_invalid');
    const external = reused && key !== 'research';
    if (file !== paths[key] || canonicalExisting(file) !== file || (!external && !within(directory, file))) fail('investment_release_path_mismatch');
    const info = stat(file), identity = `${info.dev}:${info.ino}`;
    if (!info.isFile() || info.size !== entry.bytes || (info.mode & 0o022) || seen.has(identity)) fail('investment_release_file_mismatch');
    if (reused && (info.uid !== trustedUid || info.nlink !== 1 || (info.mode & 0o222))) fail('investment_reuse_file_permissions');
    if (external) {
      const original = base.files[key], pin = manifest.reuse.files[key];
      if (entry.path !== original.path || entry.bytes !== original.bytes || entry.sha256 !== original.sha256
        || pin.device !== info.dev || pin.inode !== info.ino) fail('investment_reuse_file_mismatch');
    }
    if (fs.existsSync(`${file}-wal`) && stat(`${file}-wal`).size > 0) fail('investment_release_pending_wal');
    seen.add(identity);
  }
  return manifest;
}

function assertTables(file, required, allowed = null) {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000;');
    const tables = new Set(db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name));
    if (required.some(name => !tables.has(name))) fail('investment_release_schema_missing');
    if (allowed && [...tables].some(name => !allowed.includes(name))) fail('investment_release_unexpected_source_table');
  } finally { db.close(); }
}

export function resolveInvestmentRuntimeConfig(env = process.env) {
  if (env.INVESTMENT_WORKFLOW_ENABLED !== 'true') return null;
  const userPaths = resolveUserDataPaths(env);
  const research = env.INVESTMENT_SOURCE_DB_PATH || env.SQLITE_DB_PATH;
  if (!userPaths.investment || !research) fail('investment_explicit_databases_required');
  const config = { research: path.resolve(research), investment: userPaths.investment,
    strategy: env.STRATEGY_DATA_DB_PATH ? path.resolve(env.STRATEGY_DATA_DB_PATH) : null,
    composition: env.STRATEGY_COMPOSITION_PRICE_DB_PATH ? path.resolve(env.STRATEGY_COMPOSITION_PRICE_DB_PATH) : null,
    production: env.NODE_ENV === 'production', releaseId: env.INVESTMENT_RELEASE_ID ?? null };
  // Prevent attaching a private store to a public research database in every
  // environment, including aliases via symlinks or existing hard links.
  const privateIdentity = fs.existsSync(config.investment) ? fs.statSync(config.investment) : null;
  for (const file of [config.research, config.strategy, config.composition].filter(Boolean)) {
    if (file === config.investment) fail('investment_database_collision');
    if (privateIdentity && fs.existsSync(file)) {
      const publicIdentity = fs.statSync(file);
      if (publicIdentity.dev === privateIdentity.dev && publicIdentity.ino === privateIdentity.ino) fail('investment_database_collision');
    }
  }
  if (!config.production) return config;
  if (env.API_AUTH_DEV_BYPASS === 'true' || env.AUTH_DEV_BYPASS === 'true'
    || Object.keys(env).some(key => key.startsWith('LOCAL_OWNER_') && env[key])) fail('investment_production_local_identity_forbidden');
  for (const [key, value] of [['research', env.INVESTMENT_SOURCE_DB_PATH], ['investment', env.INVESTMENT_DB_PATH],
    ['strategy', env.STRATEGY_DATA_DB_PATH], ['composition', env.STRATEGY_COMPOSITION_PRICE_DB_PATH]]) {
    config[key] = absolute(value, 'investment_production_explicit_paths_required');
  }
  // Legacy identities and encryption keys stay where they are. Only a fresh,
  // separate append-only investment journal is introduced beside user stores.
  const privateParent = canonicalExisting(path.dirname(config.investment));
  if (!within(canonicalExisting(userPaths.portfolios), config.investment)
    || privateParent !== path.dirname(config.investment)) fail('investment_private_store_path_invalid');
  if (fs.existsSync(config.investment) && canonicalExisting(config.investment) !== config.investment) fail('investment_private_store_path_invalid');
  const legacy = canonicalExisting(userPaths.research), legacyStat = fs.statSync(legacy);
  if ([config.research, config.strategy, config.composition].some(file => {
    const info = fs.statSync(file);
    return canonicalExisting(file) === legacy || (info.ino === legacyStat.ino && info.dev === legacyStat.dev);
  })) fail('investment_legacy_database_replacement_forbidden');
  const manifestPath = absolute(env.INVESTMENT_RELEASE_MANIFEST_PATH, 'investment_release_manifest_required');
  if (fs.statSync(manifestPath).size > 65536 || canonicalExisting(manifestPath) !== manifestPath) fail('investment_release_manifest_invalid');
  const manifest = validateInvestmentRelease(JSON.parse(fs.readFileSync(manifestPath, 'utf8')), config, { manifestPath });
  assertTables(config.research, INVESTMENT_REQUIRED_SOURCE_TABLES, INVESTMENT_ALLOWED_SOURCE_TABLES);
  assertTables(config.composition, ['series', 'prices']);
  const warehouse = openStrategyDatabase(config.strategy);
  try { if (warehouse.meta.cutoff !== manifest.cutoff) fail('investment_release_cutoff_mismatch'); }
  finally { warehouse.close(); }
  if (fs.existsSync(config.investment)) {
    const db = new DatabaseSync(config.investment, { readOnly: true });
    try {
      const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(row => row.name);
      if (tables.some(name => !['investment_events','sqlite_sequence'].includes(name))) fail('investment_private_store_schema_conflict');
      const table = db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='investment_events'").get();
      if (table && db.prepare('SELECT DISTINCT owner FROM investment_events').all().some(row => !verifiedInvestmentOwner(row.owner))) fail('investment_private_store_unverified_owner');
    } finally { db.close(); }
  }
  return { ...config, cutoff: manifest.cutoff };
}
