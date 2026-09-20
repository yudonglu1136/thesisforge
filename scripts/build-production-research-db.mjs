import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import {
  INVESTMENT_ALLOWED_SOURCE_TABLES,
  INVESTMENT_REQUIRED_SOURCE_TABLES,
} from '../server/investmentRuntimeConfig.js';

const fail = code => { throw new Error(code); };
const quote = value => `"${String(value).replaceAll('"', '""')}"`;
const sha256 = file => {
  const digest = crypto.createHash('sha256');
  const fd = fs.openSync(file, 'r');
  const buffer = Buffer.allocUnsafe(8 * 1024 * 1024);
  try {
    for (;;) {
      const bytes = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (!bytes) break;
      digest.update(buffer.subarray(0, bytes));
    }
  } finally { fs.closeSync(fd); }
  return digest.digest('hex');
};

export function buildProductionResearchDatabase(sourceValue, outputValue) {
  const source = path.resolve(sourceValue);
  const output = path.resolve(outputValue);
  if (!path.isAbsolute(sourceValue) || !path.isAbsolute(outputValue)
    || source === output || fs.existsSync(output) || !fs.lstatSync(source).isFile()) fail('safe_absolute_paths_required');
  if (fs.existsSync(`${source}-wal`) && fs.statSync(`${source}-wal`).size) fail('source_has_pending_wal');
  const sourceDb = new DatabaseSync(source, { readOnly: true });
  try {
    sourceDb.exec('PRAGMA query_only=ON;');
    if (sourceDb.prepare('PRAGMA journal_mode').get().journal_mode !== 'delete') fail('source_must_be_checkpointed');
    if (sourceDb.prepare('PRAGMA quick_check').get().quick_check !== 'ok') fail('source_integrity_failed');
  } finally { sourceDb.close(); }

  fs.copyFileSync(source, output, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(output, 0o600);
  try {
    const db = new DatabaseSync(output);
    try {
      db.exec('PRAGMA foreign_keys=OFF; PRAGMA journal_mode=DELETE; BEGIN IMMEDIATE;');
      const allowed = new Set(INVESTMENT_ALLOWED_SOURCE_TABLES);
      const objects = db.prepare("SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'trigger' THEN 0 WHEN 'view' THEN 1 ELSE 2 END,name").all();
      for (const object of objects) {
        if (object.type === 'trigger') db.exec(`DROP TRIGGER ${quote(object.name)}`);
        else if (object.type === 'view') db.exec(`DROP VIEW ${quote(object.name)}`);
        else if (object.type === 'table' && !allowed.has(object.name)) db.exec(`DROP TABLE ${quote(object.name)}`);
      }
      db.exec('COMMIT; VACUUM; PRAGMA optimize;');
      const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map(row => row.name);
      const missing = INVESTMENT_REQUIRED_SOURCE_TABLES.filter(table => !tables.includes(table));
      const unexpected = tables.filter(table => !allowed.has(table));
      const triggers = db.prepare("SELECT COUNT(*) count FROM sqlite_master WHERE type='trigger'").get().count;
      const views = db.prepare("SELECT COUNT(*) count FROM sqlite_master WHERE type='view'").get().count;
      const integrity = db.prepare('PRAGMA integrity_check').all().every(row => row.integrity_check === 'ok');
      const foreignKeys = db.prepare('PRAGMA foreign_key_check').all().length;
      if (missing.length || unexpected.length || triggers || views || !integrity || foreignKeys) fail('production_research_validation_failed');
    } finally { db.close(); }
    if (fs.existsSync(`${output}-wal`) || fs.existsSync(`${output}-shm`)) fail('production_research_sidecar_created');
    const stat = fs.statSync(output);
    return {
      format: 'thesisforge-production-research-v1',
      createdAt: new Date().toISOString(),
      sourceBytes: fs.statSync(source).size,
      bytes: stat.size,
      sha256: sha256(output),
      requiredTables: [...INVESTMENT_REQUIRED_SOURCE_TABLES],
      allowedTables: [...INVESTMENT_ALLOWED_SOURCE_TABLES],
      privateDataExcluded: true,
      integrity: 'ok',
      foreignKeyViolations: 0,
    };
  } catch (error) {
    fs.rmSync(output, { force: true });
    throw error;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { source: { type: 'string' }, output: { type: 'string' }, receipt: { type: 'string' } } });
    if (!values.source || !values.output || !values.receipt || !path.isAbsolute(values.receipt) || fs.existsSync(values.receipt)) fail('explicit_paths_required');
    const result = buildProductionResearchDatabase(values.source, values.output);
    fs.writeFileSync(values.receipt, `${JSON.stringify(result, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    console.log(JSON.stringify({ status: 'production_research_ready', output: values.output, receipt: values.receipt, bytes: result.bytes, sha256: result.sha256 }));
  } catch (error) {
    console.error(JSON.stringify({ status: 'production_research_failed', error: String(error.message).slice(0, 160) }));
    process.exitCode = 1;
  }
}
