import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { enabledManager13fGurus } from '../server/gurus.js';

const tables = Object.freeze({
  guru_snapshots: ['guru_id', 'cik', 'type', 'generated_at', 'payload_json'],
  guru_exposure_snapshots: ['guru_id', 'generated_at', 'payload_json'],
  guru_backtests: ['guru_id', 'years', 'generated_at', 'start_date', 'end_date', 'payload_json'],
  guru_backtest_proxies: ['guru_id', 'years', 'generated_at', 'start_date', 'end_date', 'method_version', 'payload_json'],
});

const args = Object.fromEntries(process.argv.slice(2).map((value, index, all) => {
  if (!value.startsWith('--')) return null;
  const [key, inline] = value.slice(2).split('=', 2);
  return [key, inline ?? all[index + 1]];
}).filter(Boolean));
const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const target = path.resolve(args.target ?? path.join(root, 'server/data/guru-analysis.sqlite'));
const base = path.resolve(args.base ?? '/private/tmp/thesisforge-production-research.sqlite');
const delta = path.resolve(args.delta ?? '/private/tmp/thesisforge-guru-sync-20260913-v1-delta.sqlite');
const auditFile = path.resolve(args.audit ?? path.join(root, 'docs/audits/guru-limited-sync-2026-09-13.json'));
const receiptFile = args.receipt ? path.resolve(args.receipt) : null;

const sha256 = async file => {
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
};
const stable = value => JSON.stringify(value);
const keyFor = (table, row) => table.startsWith('guru_backtest')
  ? stable([row.guru_id, Number(row.years)])
  : stable([row.guru_id]);
const readTable = (db, table) => db.prepare(`SELECT ${tables[table].join(',')} FROM ${table}`).all();
const digestRows = (table, rows) => crypto.createHash('sha256')
  .update(rows.slice().sort((a, b) => keyFor(table, a).localeCompare(keyFor(table, b)))
    .map(row => stable(tables[table].map(column => row[column]))).join('\n'))
  .digest('hex');
const tableInfo = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all().map(row => row.name);
const integrity = db => db.prepare('PRAGMA quick_check').all().map(row => row.quick_check).join(',');

if (![target, base, delta, auditFile].every(fs.existsSync)) throw Error('guru_sync_input_missing');
if (new Set([target, base, delta]).size !== 3) throw Error('guru_sync_path_collision');
if (path.basename(target) !== 'guru-analysis.sqlite' || !target.startsWith(path.join(root, 'server/data/'))) {
  throw Error('guru_sync_target_must_be_canonical_public_database');
}

const audit = JSON.parse(fs.readFileSync(auditFile, 'utf8'));
const source = {
  base: { bytes: fs.statSync(base).size, sha256: await sha256(base) },
  delta: { bytes: fs.statSync(delta).size, sha256: await sha256(delta) },
};
if (source.base.bytes !== audit.baseResearch.bytes || source.base.sha256 !== audit.baseResearch.sha256
  || source.delta.bytes !== audit.delta.bytes || source.delta.sha256 !== audit.delta.sha256) {
  throw Error('guru_sync_source_attestation_mismatch');
}

const targetDb = new DatabaseSync(target);
const baseDb = new DatabaseSync(base, { readOnly: true });
const deltaDb = new DatabaseSync(delta, { readOnly: true });
let transaction = false;
try {
  for (const db of [targetDb, baseDb, deltaDb]) {
    if (integrity(db) !== 'ok') throw Error('guru_sync_integrity_check_failed');
    for (const [table, columns] of Object.entries(tables)) {
      if (stable(tableInfo(db, table)) !== stable(columns)) throw Error(`guru_sync_schema_mismatch:${table}`);
    }
  }

  const managerIds = new Set(enabledManager13fGurus.map(guru => guru.id));
  if (managerIds.size !== 32) throw Error('guru_sync_manager_catalog_mismatch');
  const desired = {};
  for (const table of Object.keys(tables)) {
    const rows = new Map(readTable(baseDb, table).map(row => [keyFor(table, row), row]));
    if (table === 'guru_backtest_proxies') {
      for (const id of managerIds) for (const years of [5, 10]) rows.delete(stable([id, years]));
    }
    for (const row of readTable(deltaDb, table)) rows.set(keyFor(table, row), row);
    desired[table] = [...rows.values()];
  }

  const expectedCounts = { guru_snapshots: 42, guru_exposure_snapshots: 33, guru_backtests: 86, guru_backtest_proxies: 33 };
  for (const [table, expected] of Object.entries(expectedCounts)) {
    if (desired[table].length !== expected) throw Error(`guru_sync_release_count_mismatch:${table}`);
  }
  const finalManagerIds = new Set(desired.guru_snapshots.filter(row => row.type === 'manager13f').map(row => row.guru_id));
  if ([...managerIds].some(id => !finalManagerIds.has(id))) throw Error('guru_sync_release_manager_missing');

  const before = Object.fromEntries(Object.keys(tables).map(table => {
    const rows = readTable(targetDb, table);
    return [table, { rows: rows.length, sha256: digestRows(table, rows) }];
  }));
  const expected = Object.fromEntries(Object.keys(tables).map(table => [table, {
    rows: desired[table].length,
    sha256: digestRows(table, desired[table]),
  }]));
  const alreadySynced = Object.keys(tables).every(table => before[table].sha256 === expected[table].sha256);

  if (!alreadySynced) {
    targetDb.exec('PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; BEGIN IMMEDIATE;');
    transaction = true;
    for (const [table, columns] of Object.entries(tables)) {
      targetDb.exec(`DELETE FROM ${table}`);
      const insert = targetDb.prepare(`INSERT INTO ${table}(${columns.join(',')}) VALUES(${columns.map(() => '?').join(',')})`);
      for (const row of desired[table]) insert.run(...columns.map(column => row[column]));
    }
    targetDb.exec('COMMIT');
    transaction = false;
  }

  const after = Object.fromEntries(Object.keys(tables).map(table => {
    const rows = readTable(targetDb, table);
    return [table, { rows: rows.length, sha256: digestRows(table, rows) }];
  }));
  if (integrity(targetDb) !== 'ok' || Object.keys(tables).some(table => after[table].sha256 !== expected[table].sha256)) {
    throw Error('guru_sync_postcondition_failed');
  }

  const result = {
    version: 'local-guru-production-sync-v1',
    status: alreadySynced ? 'already_synced' : 'synced',
    completedAt: new Date().toISOString(),
    target,
    source,
    release: { base: 'redesign-20260912-v1', delta: 'guru-sync-20260913-v1' },
    before,
    after,
    privateDataTouched: false,
    targetIntegrity: 'ok',
  };
  if (receiptFile) {
    fs.mkdirSync(path.dirname(receiptFile), { recursive: true });
    const handle = fs.openSync(receiptFile, 'wx', 0o600);
    try { fs.writeFileSync(handle, `${JSON.stringify(result, null, 2)}\n`); fs.fsyncSync(handle); } finally { fs.closeSync(handle); }
  }
  console.log(JSON.stringify(result, null, 2));
} finally {
  if (transaction) targetDb.exec('ROLLBACK');
  deltaDb.close();
  baseDb.close();
  targetDb.close();
}
