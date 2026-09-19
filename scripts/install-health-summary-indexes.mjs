// Explicit maintenance only. Default mode opens the existing database read-only.
// Never copy a database, change application rows, or install indexes at startup.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { validateCheckpointRequest } from "./checkpoint-sqlite-wal.mjs";

const DEADLINE_MS = 120_000;
const indexesModule = new URL("../server/databaseHealthIndexes.js", import.meta.url).href;

const workerSource = String.raw`
import fs from 'node:fs';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
const request=JSON.parse(process.argv[1]);
const {inspectDatabaseHealthIndexes,installDatabaseHealthIndexes,databaseHealthIndexes}=await import(request.indexesModule);
function identity() {
  const stat=fs.lstatSync(request.database);
  if(!stat.isFile()||stat.isSymbolicLink()||stat.ino!==request.identity.inode||stat.dev!==request.identity.device
    ||stat.uid!==request.identity.owner)throw Error('database_identity_changed');
}
const digest=value=>crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
identity();
const db=new DatabaseSync(request.database,{readOnly:!request.execute});
try {
  db.exec('PRAGMA busy_timeout=1000; PRAGMA cache_size=-8192; PRAGMA mmap_size=0; PRAGMA temp_store=FILE;');
  if(!request.execute)db.exec('PRAGMA query_only=ON;');
  else db.exec('PRAGMA wal_autocheckpoint=1000; PRAGMA journal_size_limit=67108864;');
  const version=db.prepare('SELECT sqlite_version() AS v').get().v.split('.').map(Number);
  if(version[0]!==3||version[1]<51||(version[1]===51&&version[2]<3))throw Error('wal_reset_fixed_sqlite_runtime_required');
  const schema=()=>db.prepare('SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name').all();
  const before=schema();
  if(before.length>10000)throw Error('unexpected_schema_size');
  const started=performance.now();
  const migration=request.execute?installDatabaseHealthIndexes(db):null;
  const after=schema();
  const expectedNames=new Set(databaseHealthIndexes.map(row=>row.name));
  if(request.execute) {
    // Original tables, triggers and indexes must still have identical SQL.
    const existingNames=new Set(before.map(row=>row.name));
    if(digest(before)!==digest(after.filter(row=>existingNames.has(row.name)))
      ||after.some(row=>!existingNames.has(row.name)&&!expectedNames.has(row.name))) {
      throw Error('unexpected_schema_change_requires_review');
    }
  }
  identity();
  console.log(JSON.stringify({status:request.execute?'health_indexes_installed':'read_only_health_index_inspection',
    database:request.database,identity:request.identity,elapsedMs:Math.round(performance.now()-started),
    beforeSchemaSha256:digest(before),afterSchemaSha256:digest(after),indexes:inspectDatabaseHealthIndexes(db),
    created:migration?.created||[],applicationRowsMutated:false,existingSchemaObjectsChanged:false,
    backupGeneration:request.backupGeneration,rollbackSnapshotAcknowledged:request.rollbackSnapshot}));
} finally {db.close();}
`;

export function installHealthSummaryIndexes(options) {
  // Same exact-file identity, database-owner, fresh verified user backup and
  // completed rollback snapshot gates as the approved WAL maintenance tool.
  const request = { ...validateCheckpointRequest(options), indexesModule };
  try {
    return JSON.parse(execFileSync(process.execPath,
      ["--input-type=module", "--eval", workerSource, JSON.stringify(request)],
      { encoding: "utf8", timeout: DEADLINE_MS, killSignal: "SIGKILL", maxBuffer: 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] }));
  } catch (error) {
    // A killed SQLite transaction must be recovered by SQLite, not by deleting
    // WAL/journal files. Do not retry automatically or claim installation.
    throw Error(error.code === "ETIMEDOUT"
      ? "health_index_deadline_exceeded_preserve_files_and_inspect"
      : "health_index_installation_not_confirmed_preserve_files_and_review");
  }
}

function parseArguments(args) {
  const result = {};
  const fields = { "--database": "database", "--expected-inode": "expectedInode", "--expected-device": "expectedDevice",
    "--backup-generation": "backupGeneration", "--rollback-snapshot": "rollbackSnapshot" };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--execute") {
      if (result.execute) throw Error("duplicate_argument");
      result.execute = true;
    } else if (arg === "--backup-receipt") {
      const file = args[++i];
      if (result.backupReceipt || !file || !path.isAbsolute(file) || fs.statSync(file).size > 64 * 1024) throw Error("invalid_backup_receipt");
      result.backupReceipt = JSON.parse(fs.readFileSync(file, "utf8"));
    } else if (fields[arg]) {
      if (result[fields[arg]] !== undefined || !args[i + 1] || args[i + 1].startsWith("--")) throw Error("invalid_argument");
      result[fields[arg]] = args[++i];
    } else throw Error("unknown_argument");
  }
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(installHealthSummaryIndexes(parseArguments(process.argv.slice(2))), null, 2)); }
  catch (error) { console.error(JSON.stringify({ status: "maintenance_not_confirmed", reason: error.message })); process.exitCode = 1; }
}
