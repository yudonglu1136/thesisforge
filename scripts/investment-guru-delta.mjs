// Exact-row public-data patching. No database initializer, arbitrary SQL,
// valuation/price writes, catalog scoring, or successful-cache fabrication.
import fs from 'node:fs';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { gurus, enabledManager13fGurus } from '../server/gurus.js';

export const guruDeltaTables = Object.freeze({
  guru_snapshots: ['guru_id','cik','type','generated_at','payload_json'],
  guru_exposure_snapshots: ['guru_id','generated_at','payload_json'],
  guru_backtests: ['guru_id','years','generated_at','start_date','end_date','payload_json'],
  guru_backtest_proxies: ['guru_id','years','generated_at','start_date','end_date','method_version','payload_json']
});
export const newGuruIds = Object.freeze(['evan-mcgoff','john-stamas','michael-cuggino','william-heard']);
const fail = code => { throw Error(code); };
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const stable = value => JSON.stringify(value);
export const guruDeltaRowSha256 = (table,row) => row ? sha(stable(guruDeltaTables[table].map(column => row[column]))) : null;
const keysFor = table => table.startsWith('guru_backtest') ? ['guru_id','years'] : ['guru_id'];
const rowKey = (table,row) => keysFor(table).map(column => row[column]);

export function validateGuruDeltaContract(contract) {
  if (contract?.version !== 'investment-guru-delta-v1'
    || !Number.isSafeInteger(contract.baseResearch?.bytes) || contract.baseResearch.bytes < 4096 || !digest(contract.baseResearch.sha256)
    || stable(Object.keys(contract.tables ?? {}).sort()) !== stable(Object.keys(guruDeltaTables).sort())
    || stable([...(contract.scope?.snapshotGuruIds ?? [])].sort()) !== stable(newGuruIds)
    || stable(contract.scope?.years) !== '[5,10]') fail('invalid_guru_delta_contract');
  const gurus = contract.scope.cacheGuruIds;
  if (!Array.isArray(gurus) || gurus.length !== enabledManager13fGurus.length
    || new Set(gurus).size !== gurus.length
    || stable([...gurus].sort()) !== stable(enabledManager13fGurus.map(guru => guru.id).sort())) fail('invalid_guru_delta_catalog');
  for (const [table,columns] of Object.entries(guruDeltaTables)) {
    const item = contract.tables[table], caches = table.startsWith('guru_backtest');
    const expected = caches ? gurus.flatMap(id => [5,10].map(year => stable([id,year]))) : newGuruIds.map(id => stable([id]));
    if (stable(item?.columns) !== stable(columns) || !Array.isArray(item?.operations)
      || item.operations.length !== expected.length) fail('invalid_guru_delta_operations');
    const seen = new Set();
    for (const operation of item.operations) {
      const key = stable(operation.key);
      if (!expected.includes(key) || seen.has(key) || !('beforeSha256' in operation) || !('afterSha256' in operation)
        || (operation.beforeSha256 !== null && !digest(operation.beforeSha256))
        || (operation.afterSha256 !== null && !digest(operation.afterSha256))
        || (table !== 'guru_backtest_proxies' && operation.afterSha256 === null)) fail('invalid_guru_delta_operation');
      seen.add(key);
    }
  }
  return contract;
}

function schema(db, {delta = false} = {}) {
  const objects = db.prepare("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").all();
  if (objects.some(row => row.type === 'trigger' || row.type === 'view')) fail('guru_delta_executable_schema_forbidden');
  if (delta && objects.some(row => !Object.keys(guruDeltaTables).includes(row.tbl_name))) fail('guru_delta_unexpected_table');
  for (const [table,columns] of Object.entries(guruDeltaTables)) {
    if (stable(db.prepare(`PRAGMA table_info(${table})`).all().map(row => row.name)) !== stable(columns)) fail('guru_delta_schema_mismatch');
    if (db.prepare(`PRAGMA foreign_key_list(${table})`).all().length) fail('guru_delta_foreign_keys_forbidden');
  }
  for (const object of objects.filter(row => row.type === 'table')) {
    if (!/^[a-z][a-z0-9_]*$/.test(object.name)) fail('guru_delta_unexpected_table');
    if (db.prepare(`PRAGMA foreign_key_list(${object.name})`).all().some(row => Object.hasOwn(guruDeltaTables,row.table))) fail('guru_delta_foreign_keys_forbidden');
  }
  if (db.prepare('PRAGMA journal_mode').get().journal_mode !== 'delete') fail('guru_delta_self_contained_required');
  return stable(objects);
}

function selfContained(file, {writable = false} = {}) {
  const info = fs.lstatSync(file);
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || fs.realpathSync(file) !== file
    || (info.mode & 0o022) || (writable && !(info.mode & 0o200))
    || ['-wal','-shm','-journal'].some(suffix => fs.existsSync(`${file}${suffix}`))) fail('guru_delta_unsafe_file');
  return `${info.dev}:${info.ino}`;
}

// Validate all operations before beginning, then re-read the guarded old rows
// under the write lock. Repeating an already-applied patch is a byte-stable no-op.
// The installer also verifies full source/result SHA-256 and producer integrity.
export function applyGuruDelta(candidateFile, deltaFile, contract) {
  validateGuruDeltaContract(contract);
  if (selfContained(candidateFile,{writable:true}) === selfContained(deltaFile)) fail('guru_delta_database_collision');
  const target = new DatabaseSync(candidateFile), delta = new DatabaseSync(deltaFile,{readOnly:true});
  let transaction = false;
  try {
    target.exec('PRAGMA busy_timeout=1000; PRAGMA cache_size=-8192; PRAGMA synchronous=FULL;');
    delta.exec('PRAGMA query_only=ON; PRAGMA cache_size=-2048;');
    const originalSchema = schema(target); schema(delta,{delta:true});
    const prepared = [];
    for (const [table,columns] of Object.entries(guruDeltaTables)) {
      const item = contract.tables[table], expectedRows = new Map();
      for (const row of delta.prepare(`SELECT ${columns.join(',')} FROM ${table}`).iterate()) {
        const key = stable(rowKey(table,row));
        if (expectedRows.has(key)) fail('guru_delta_duplicate_row');
        expectedRows.set(key,row);
      }
      const operations = [...item.operations].sort((a,b) => stable(a.key) < stable(b.key) ? -1 : stable(a.key) > stable(b.key) ? 1 : 0);
      for (const operation of operations) {
        const key = stable(operation.key), row = expectedRows.get(key) ?? null;
        if (guruDeltaRowSha256(table,row) !== operation.afterSha256) fail('guru_delta_row_digest_mismatch');
        expectedRows.delete(key);
        if (row) {
          const payload = JSON.parse(row.payload_json);
          const identity = table === 'guru_snapshots' ? payload : payload.guru;
          const catalog = gurus.find(guru => guru.id === row.guru_id && guru.type === 'manager13f');
          if (identity?.id !== row.guru_id || (table === 'guru_snapshots'
            && (row.cik !== catalog.cik || payload.cik !== catalog.cik || row.type !== 'manager13f' || payload.type !== row.type))) fail('guru_delta_payload_identity_mismatch');
          if (table.startsWith('guru_backtest') && (payload.guru?.id !== row.guru_id || Number(payload.method?.years) !== row.years)) fail('guru_delta_payload_identity_mismatch');
          if (typeof row.generated_at !== 'string' || Number.isNaN(Date.parse(row.generated_at))) fail('guru_delta_generation_invalid');
        }
        prepared.push({table,columns,operation,row});
      }
      if (expectedRows.size) fail('guru_delta_unlisted_row');
    }
    const selected = new Map(Object.keys(guruDeltaTables).map(table => [table,target.prepare(
      `SELECT ${guruDeltaTables[table].join(',')} FROM ${table} WHERE ${keysFor(table).map(column => `${column}=?`).join(' AND ')}`)]));
    const check = () => {
      let before = 0, after = 0;
      for (const item of prepared) {
        const actual = guruDeltaRowSha256(item.table,selected.get(item.table).get(...item.operation.key));
        if (actual !== item.operation.beforeSha256 && actual !== item.operation.afterSha256) fail('guru_delta_stale_target');
        if (actual !== item.operation.afterSha256) before++;
        if (actual !== item.operation.beforeSha256) after++;
      }
      if (before && after) fail('guru_delta_partially_applied_target');
      return before;
    };
    if (!check()) return {status:'already_applied',upserts:0,deletes:0,nonTargetWrites:0};
    target.exec('BEGIN IMMEDIATE'); transaction = true; check();
    let upserts = 0, deletes = 0;
    for (const {table,columns,operation,row} of prepared) {
      if (row) {
        const keyColumns = keysFor(table), updates = columns.filter(column => !keyColumns.includes(column));
        target.prepare(`INSERT INTO ${table}(${columns.join(',')}) VALUES(${columns.map(() => '?').join(',')})
          ON CONFLICT(${keyColumns.join(',')}) DO UPDATE SET ${updates.map(column => `${column}=excluded.${column}`).join(',')}`)
          .run(...columns.map(column => row[column])); upserts++;
      } else {
        deletes += target.prepare(`DELETE FROM ${table} WHERE ${keysFor(table).map(column => `${column}=?`).join(' AND ')}`).run(...operation.key).changes;
      }
    }
    for (const item of prepared) {
      if (guruDeltaRowSha256(item.table,selected.get(item.table).get(...item.operation.key)) !== item.operation.afterSha256) fail('guru_delta_postcondition_failed');
    }
    if (schema(target) !== originalSchema) fail('guru_delta_schema_changed');
    target.exec('COMMIT'); transaction = false;
    return {status:'applied',upserts,deletes,nonTargetWrites:0};
  } finally {
    if (transaction) target.exec('ROLLBACK');
    delta.close(); target.close();
  }
}
