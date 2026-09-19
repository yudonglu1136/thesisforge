import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const required = {
  research: ['price_points', 'guru_snapshots', 'guru_backtests'],
  strategy: ['warehouse_meta', 'managers', 'filings', 'filing_holdings', 'price_observations', 'valuation_nodes'],
  portfolio: ['portfolio_connections', 'portfolio_nav_points'],
  registry: ['portfolio_user_registry'], login: ['login_activity_users'], investment: ['investment_events']
};
const publicTables = new Set(['price_points', 'guru_snapshots', 'guru_exposure_snapshots', 'guru_backtests',
  'guru_backtest_proxies', 'valuation_pit_financials', 'valuation_pit_guidance', 'valuation_pit_model_runs',
  'valuation_pit_price_observations', 'valuation_ticker_snapshots', 'valuation_snapshots']);
const quote = value => '"' + value.replaceAll('"', '""') + '"';
const encode = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? { integer: String(v) }
  : v instanceof Uint8Array ? { blob: Buffer.from(v).toString('base64') } : v);
const hash = value => crypto.createHash('sha256').update(encode(value)).digest('hex');

// Operator-only: no application imports, schema initialization or row exports.
// Explicit public digests are optional; private data is never a sync source.
export function inspectDatabase(file, kind, { digestTables = [], schemaOnly = false } = {}) {
  if (!Object.hasOwn(required, kind)) throw Error('unknown_database_kind');
  if (!Array.isArray(digestTables) || digestTables.some(t => kind !== 'research' || !publicTables.has(t))) {
    throw Error('only_allowlisted_public_tables_can_be_fingerprinted');
  }
  if (schemaOnly && digestTables.length) throw Error('schema_only_cannot_verify_data');
  if (!path.isAbsolute(file) || !fs.lstatSync(file).isFile()) throw Error('existing_regular_absolute_database_required');
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=3000; BEGIN;');
    const schema = db.prepare("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").all();
    const tables = schema.filter(o => o.type === 'table').map(o => {
      const columns = db.prepare(`PRAGMA table_xinfo(${quote(o.name)})`).all();
      const indexes = db.prepare(`PRAGMA index_list(${quote(o.name)})`).all().map(i => ({
        name: i.name, unique: i.unique, origin: i.origin, partial: i.partial,
        columns: db.prepare(`PRAGMA index_xinfo(${quote(i.name)})`).all()
      })).sort((a, b) => a.name.localeCompare(b.name));
      const foreignKeys = db.prepare(`PRAGMA foreign_key_list(${quote(o.name)})`).all();
      const n = schemaOnly ? null : db.prepare(`SELECT count(*) n FROM ${quote(o.name)}`).get().n;
      let dataSha256 = null;
      if (digestTables.includes(o.name)) {
        // All-column ordering makes equal-count edits and insertion-order differences visible.
        // sqlite preserves exact integer values; no rounding of shares or timestamps.
        const statement = db.prepare(`SELECT * FROM ${quote(o.name)} ORDER BY ${columns.filter(c => c.hidden !== 1).map(c => quote(c.name)).join(',')}`);
        statement.setReadBigInts(true);
        const digest = crypto.createHash('sha256');
        for (const row of statement.iterate()) digest.update(encode(row) + '\n');
        dataSha256 = digest.digest('hex');
      }
      return { name: o.name, rows: n, columns, indexes, foreignKeys, definitionSha256: hash(o.sql), dataSha256 };
    });
    const missingTables = required[kind].filter(t => !tables.some(o => o.name === t));
    const missingDigests = digestTables.filter(t => !tables.some(o => o.name === t));
    const integrityOk = schemaOnly ? null : db.prepare('PRAGMA integrity_check').all().every(r => r.integrity_check === 'ok');
    const foreignKeyViolations = schemaOnly ? null : db.prepare('PRAGMA foreign_key_check').all().length;
    const result = { format: 'thesisforge-database-audit-v1', kind,
      capturedAt: new Date().toISOString(), sqliteVersion: db.prepare('SELECT sqlite_version() version').get().version,
      userVersion: db.prepare('PRAGMA user_version').get().user_version,
      schemaSha256: hash(schema),
      objects: schema.map(o => ({ type: o.type, name: o.name, table: o.tbl_name, definitionSha256: hash(o.sql) })),
      integrityOk, integrityCheck: schemaOnly ? 'not_run' : 'full', foreignKeyViolations, missingTables, missingDigests, tables,
      status: missingTables.length || missingDigests.length ? 'blocked' : schemaOnly ? 'inventory_only'
        : integrityOk && !foreignKeyViolations ? 'inspected' : 'blocked',
      scope: 'Read-only schema and aggregate counts. Matching schema is not matching data or release approval. Private stores must never be mirrored from local preview.' };
    db.exec('COMMIT');
    return result;
  } finally { db.close(); }
}

export function compareDatabases(expected, actual) {
  const valid = r => r?.format === 'thesisforge-database-audit-v1' && Object.hasOwn(required, r.kind)
    && ['inspected', 'inventory_only'].includes(r.status)
    && Array.isArray(r.tables) && Array.isArray(r.objects) && /^[a-f0-9]{64}$/.test(r.schemaSha256);
  if (!valid(expected) || !valid(actual) || expected.kind !== actual.kind) {
    return { status: 'blocked', reason: 'valid_same_kind_inventories_required', schemaMatch: false, dataMatch: null };
  }
  const a = new Map(expected.objects.map(o => [o.type + ':' + o.name, o]));
  const b = new Map(actual.objects.map(o => [o.type + ':' + o.name, o]));
  const missing = [...a.keys()].filter(k => !b.has(k));
  const extra = [...b.keys()].filter(k => !a.has(k));
  const changed = [...a.keys()].filter(k => b.has(k) && a.get(k).definitionSha256 !== b.get(k).definitionSha256);
  const rowCountsDiffer = expected.tables.filter(t => Number.isSafeInteger(t.rows) && actual.tables.some(r =>
    r.name === t.name && Number.isSafeInteger(r.rows) && r.rows !== t.rows)).map(t => t.name);
  const digests = expected.tables.filter(t => t.dataSha256).map(t => ({ table: t.name,
    matches: t.dataSha256 === actual.tables.find(r => r.name === t.name)?.dataSha256 }));
  const schemaMatch = expected.userVersion === actual.userVersion && expected.schemaSha256 === actual.schemaSha256;
  const integrityVerified = [expected, actual].every(r => r.integrityOk === true && r.integrityCheck === 'full' && r.foreignKeyViolations === 0);
  return { status: integrityVerified && schemaMatch && digests.every(d => d.matches) ? 'schema_verified' : 'blocked',
    integrityVerified,
    kind: expected.kind, schemaMatch, missing, extra, changed,
    userVersionMatch: expected.userVersion === actual.userVersion, rowCountsDiffer,
    dataMatch: digests.length ? digests.every(d => d.matches) : null, digests,
    scope: 'No writes performed. Data equality covers only explicitly fingerprinted public tables, not full database equivalence. Private row-count differences do not authorize merging or replacement.' };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values, positionals } = parseArgs({ allowPositionals: true, options: {
      db: { type: 'string' }, kind: { type: 'string' }, expected: { type: 'string' }, actual: { type: 'string' },
      output: { type: 'string' },
      'schema-only': { type: 'boolean' },
      'digest-table': { type: 'string', multiple: true }
    } });
    if (positionals.length !== 1) throw Error('usage');
    const result = positionals[0] === 'inspect' ? inspectDatabase(values.db, values.kind, { digestTables: values['digest-table'] || [], schemaOnly: values['schema-only'] || false })
      : positionals[0] === 'compare' ? compareDatabases(JSON.parse(fs.readFileSync(values.expected, 'utf8')), JSON.parse(fs.readFileSync(values.actual, 'utf8')))
      : null;
    if (!result) throw Error('usage');
    if (values.output) {
      if (!path.isAbsolute(values.output)) throw Error('absolute_output_required');
      fs.writeFileSync(values.output, JSON.stringify(result, null, 2), { mode: 0o600, flag: 'wx' });
      console.log(JSON.stringify({ status: result.status, output: values.output, kind: result.kind,
        schemaSha256: result.schemaSha256, tables: result.tables?.length, integrityOk: result.integrityOk }));
    } else console.log(JSON.stringify(result));
    if (result.status === 'blocked') process.exitCode = 1;
  } catch {
    console.error('Database audit failed closed. Check explicit paths, database kind and readable schema. No database was created, migrated or replaced.');
    process.exitCode = 1;
  }
}
