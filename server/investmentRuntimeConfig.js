import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { resolveUserDataPaths } from './userDataPaths.js';
import { openStrategyDatabase } from './strategyDatabase.js';

export const INVESTMENT_RELEASE_VERSION = 'investment-runtime-release-v1';
export const INVESTMENT_REUSED_RELEASE_VERSION = 'investment-runtime-release-v2';
export const AI_INSIGHTS_RELEASE_VERSION = 'ai-insights-runtime-release-v1';
export const INVESTMENT_REQUIRED_SOURCE_TABLES = Object.freeze(['valuation_pit_model_runs', 'valuation_pit_financials', 'valuation_pit_guidance',
  'valuation_ticker_snapshots', 'guru_snapshots', 'guru_exposure_snapshots', 'guru_backtests', 'price_points',
  'investment_quality_annual', 'investment_quality_metadata']);
export const INVESTMENT_ALLOWED_SOURCE_TABLES = Object.freeze([...INVESTMENT_REQUIRED_SOURCE_TABLES,
  'guru_backtest_proxies', 'valuation_pit_source_metadata', 'valuation_pit_price_observations', 'valuation_snapshots',
  'investment_current_quotes', 'investment_current_quote_metadata', 'sqlite_sequence', 'sqlite_stat1', 'sqlite_stat4']);
export const INVESTMENT_13F_INSIGHTS_TABLES = Object.freeze([
  'institutional_13f_insight_snapshots',
  'institutional_13f_insight_snapshots_v2',
  'institutional_13f_active_snapshots_v1',
  'institutional_13f_active_details_v1',
]);
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

export function validateInstitutional13fArtifact(file,manifestPath,{trustedUid=0,stat=fs.statSync}={}) {
  const database=absolute(file,'institutional_13f_artifact_path_required');
  const metadata=absolute(manifestPath,'institutional_13f_manifest_required');
  if(canonicalExisting(database)!==database||canonicalExisting(metadata)!==metadata)fail('institutional_13f_artifact_path_invalid');
  const databaseStat=stat(database),manifestStat=stat(metadata);
  if(!databaseStat.isFile()||!manifestStat.isFile()||databaseStat.uid!==trustedUid||manifestStat.uid!==trustedUid
    ||(databaseStat.mode&0o222)||(manifestStat.mode&0o222)||databaseStat.nlink!==1||manifestStat.nlink!==1
    ||manifestStat.size>65536)fail('institutional_13f_artifact_permissions');
  if(fs.existsSync(`${database}-wal`)&&stat(`${database}-wal`).size>0)fail('institutional_13f_artifact_pending_wal');
  const manifest=JSON.parse(fs.readFileSync(metadata,'utf8'));
  const fullArtifactVersions=new Set([
    'institutional-13f-artifact-v3',
    'institutional-13f-artifact-v5',
    'institutional-13f-artifact-v6',
  ]);
  const fullArtifact=fullArtifactVersions.has(manifest.version);
  const expectedTable=fullArtifact
    ? 'institutional_13f_insight_snapshots_v2'
    : manifest.version==='institutional-13f-artifact-v2'
    ? 'institutional_13f_insight_snapshots_v2'
    : manifest.version==='institutional-13f-artifact-v1'
      ? 'institutional_13f_insight_snapshots'
      : null;
  if(!expectedTable||manifest.state!=='verified'
    ||manifest.file?.path!==database||manifest.file.bytes!==databaseStat.size
    ||!/^[a-f0-9]{64}$/.test(manifest.file?.sha256??'')||manifest.checks?.integrity!=='ok'
    ||manifest.checks?.naturalKeyUniqueness!=='pass'||manifest.checks?.privateDataExcluded!==true
    ||(manifest.table??expectedTable)!==expectedTable
    ||!Number.isSafeInteger(manifest.rows)||manifest.rows<1)fail('institutional_13f_manifest_invalid');
  const digest=crypto.createHash('sha256').update(fs.readFileSync(database)).digest('hex');
  if(digest!==manifest.file.sha256)fail('institutional_13f_artifact_hash_mismatch');
  const auxiliaryTables=fullArtifact
    ? ['institutional_13f_insight_details_v1','institutional_13f_market_history_v1','institutional_13f_security_history_v1',
      ...(manifest.version==='institutional-13f-artifact-v6'
        ?['institutional_13f_active_snapshots_v1','institutional_13f_active_details_v1']:[])]
    : [];
  if(fullArtifact
    && (!Number.isSafeInteger(manifest.detailRows)||manifest.detailRows<1
      ||!Number.isSafeInteger(manifest.marketRows)||manifest.marketRows<1))fail('institutional_13f_manifest_invalid');
  if(fullArtifact
    && (!Number.isSafeInteger(manifest.securityHistoryRows)||manifest.securityHistoryRows<1))fail('institutional_13f_manifest_invalid');
  if(manifest.version==='institutional-13f-artifact-v6'
    && (!Number.isSafeInteger(manifest.activeRows)||manifest.activeRows<1
      ||!Number.isSafeInteger(manifest.activeDetailRows)||manifest.activeDetailRows<1))fail('institutional_13f_manifest_invalid');
  assertTables(database,[expectedTable,...auxiliaryTables],[expectedTable,...auxiliaryTables]);
  const db=new DatabaseSync(database,{readOnly:true});
  try {
    const rows=db.prepare(`SELECT count(*) count FROM ${expectedTable}`).get().count;
    const duplicates=db.prepare(`SELECT count(*) count FROM (SELECT report_date,source_generation,count(*) n
      FROM ${expectedTable} GROUP BY report_date,source_generation HAVING n>1)`).get().count;
    const detailRows=auxiliaryTables.length?db.prepare('SELECT count(*) count FROM institutional_13f_insight_details_v1').get().count:null;
    const marketRows=auxiliaryTables.length?db.prepare('SELECT count(*) count FROM institutional_13f_market_history_v1').get().count:null;
    const securityHistoryRows=auxiliaryTables.length?db.prepare('SELECT count(*) count FROM institutional_13f_security_history_v1').get().count:null;
    const activeRows=manifest.version==='institutional-13f-artifact-v6'
      ?db.prepare('SELECT count(*) count FROM institutional_13f_active_snapshots_v1').get().count:null;
    const activeDetailRows=manifest.version==='institutional-13f-artifact-v6'
      ?db.prepare('SELECT count(*) count FROM institutional_13f_active_details_v1').get().count:null;
    if(rows!==manifest.rows||duplicates!==0
      ||(auxiliaryTables.length&&(detailRows!==manifest.detailRows||marketRows!==manifest.marketRows
        ||securityHistoryRows!==manifest.securityHistoryRows))
      ||(manifest.version==='institutional-13f-artifact-v6'
        &&(activeRows!==manifest.activeRows||activeDetailRows!==manifest.activeDetailRows)))fail('institutional_13f_artifact_rows_invalid');
  } finally {db.close();}
  return manifest;
}

export function validateAiInsightsArtifact(rootPath, releaseManifestPath, { trustedUid = 0, stat = fs.statSync } = {}) {
  const requestedRoot = absolute(rootPath, 'ai_insights_artifact_root_required');
  const requestedRelease = absolute(releaseManifestPath, 'ai_insights_release_manifest_required');
  const root = canonicalExisting(requestedRoot), releasePath = canonicalExisting(requestedRelease);
  if (!within(root, releasePath)) fail('ai_insights_artifact_path_invalid');
  const rootStat = stat(root), releaseStat = stat(releasePath);
  if (!rootStat.isDirectory() || !releaseStat.isFile() || rootStat.uid !== trustedUid
    || releaseStat.uid !== trustedUid || (rootStat.mode & 0o222) || (releaseStat.mode & 0o222)
    || releaseStat.nlink !== 1 || releaseStat.size > 1024 * 1024) fail('ai_insights_artifact_permissions');
  const release = JSON.parse(fs.readFileSync(releasePath, 'utf8'));
  if (release.version !== AI_INSIGHTS_RELEASE_VERSION || release.state !== 'verified'
    || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{5,100}$/.test(release.releaseId ?? '')
    || !/^[a-f0-9]{64}$/.test(release.currentGeneration ?? '')
    || !/^[a-f0-9]{64}$/.test(release.sourceManifestSha256 ?? '')
    || release.checks?.schema !== 'pass' || release.checks?.privateDataExcluded !== true
    || release.checks?.immutableGenerations !== 'pass' || !Array.isArray(release.files)
    || release.files.length < 3 || release.files.length > 1024) fail('ai_insights_release_manifest_invalid');
  const listed = new Set();
  for (const entry of release.files) {
    if (!entry || typeof entry.relativePath !== 'string' || entry.relativePath.startsWith('/')
      || entry.relativePath.includes('..') || !Number.isSafeInteger(entry.bytes) || entry.bytes <= 0
      || !/^[a-f0-9]{64}$/.test(entry.sha256 ?? '')) fail('ai_insights_release_file_invalid');
    const file = path.resolve(root, entry.relativePath);
    if (!within(root, file) || canonicalExisting(file) !== file || listed.has(file)) fail('ai_insights_release_file_invalid');
    const info = stat(file);
    if (!info.isFile() || info.uid !== trustedUid || (info.mode & 0o222) || info.nlink !== 1
      || info.size !== entry.bytes) fail('ai_insights_release_file_mismatch');
    const sha = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    if (sha !== entry.sha256) fail('ai_insights_release_file_hash_mismatch');
    listed.add(file);
  }
  const currentPath = path.join(root, 'derived/ai-insights/manifest.json');
  const generationPath = path.join(root, 'derived/ai-insights/generations', `${release.currentGeneration}.json`);
  const sidecarPath = path.join(root, 'derived/ai-insights/generations', `${release.currentGeneration}.manifest.json`);
  if (![currentPath, generationPath, sidecarPath].every(file => listed.has(file))) fail('ai_insights_release_current_generation_missing');
  const current = JSON.parse(fs.readFileSync(currentPath, 'utf8'));
  const artifactBytes = fs.readFileSync(generationPath), artifact = JSON.parse(artifactBytes);
  const sidecar = JSON.parse(fs.readFileSync(sidecarPath, 'utf8'));
  if (current.schemaVersion !== 1 || current.builderVersion !== 'ai-insights-artifact-v3'
    || current.generationId !== release.currentGeneration || artifact.schemaVersion !== 1
    || artifact.generationId !== release.currentGeneration || sidecar.generationId !== release.currentGeneration
    || current.sourceManifestSha256 !== release.sourceManifestSha256
    || current.artifactSha256 !== crypto.createHash('sha256').update(artifactBytes).digest('hex')
    || current.artifactPath !== `derived/ai-insights/generations/${release.currentGeneration}.json`)
    fail('ai_insights_release_identity_mismatch');
  if (release.files.some(entry => /(?:^|\/)(?:catalog\.json|warehouse\.duckdb|.*\.(?:parquet|sqlite|db))(?:$|\/)/i.test(entry.relativePath)))
    fail('ai_insights_release_private_data_present');
  return release;
}

export function resolveInvestmentRuntimeConfig(env = process.env) {
  if (env.INVESTMENT_WORKFLOW_ENABLED !== 'true') return null;
  const userPaths = resolveUserDataPaths(env);
  const research = env.INVESTMENT_SOURCE_DB_PATH || env.SQLITE_DB_PATH;
  if (!userPaths.investment || !research) fail('investment_explicit_databases_required');
  const config = { research: path.resolve(research), investment: userPaths.investment,
    strategy: env.STRATEGY_DATA_DB_PATH ? path.resolve(env.STRATEGY_DATA_DB_PATH) : null,
    composition: env.STRATEGY_COMPOSITION_PRICE_DB_PATH ? path.resolve(env.STRATEGY_COMPOSITION_PRICE_DB_PATH) : null,
    insights: env.INVESTMENT_13F_INSIGHTS_DB_PATH ? path.resolve(env.INVESTMENT_13F_INSIGHTS_DB_PATH) : null,
    aiInsightsRoot: path.resolve(env.AI_INSIGHTS_ROOT || env.FACT_OS_ROOT || path.resolve('data/fact_os')),
    production: env.NODE_ENV === 'production', releaseId: env.INVESTMENT_RELEASE_ID ?? null };
  // Prevent attaching a private store to a public research database in every
  // environment, including aliases via symlinks or existing hard links.
  const privateIdentity = fs.existsSync(config.investment) ? fs.statSync(config.investment) : null;
  for (const file of [config.research, config.strategy, config.composition, config.insights].filter(Boolean)) {
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
  config.aiInsightsRoot = absolute(env.AI_INSIGHTS_ROOT, 'ai_insights_artifact_root_required');
  validateAiInsightsArtifact(config.aiInsightsRoot, env.AI_INSIGHTS_RELEASE_MANIFEST_PATH);
  if(config.insights) {
    config.insights=absolute(env.INVESTMENT_13F_INSIGHTS_DB_PATH,'institutional_13f_artifact_path_required');
    validateInstitutional13fArtifact(config.insights,env.INVESTMENT_13F_INSIGHTS_MANIFEST_PATH);
  } else if(env.INVESTMENT_13F_INSIGHTS_MANIFEST_PATH) fail('institutional_13f_artifact_path_required');
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
