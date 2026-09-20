// Operator-only WAL maintenance. Default is a read-only inspection. Never
// unlink/copy/replace SQLite sidecars, VACUUM, or mutate application rows.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const MAIN_DATABASE=process.env.SQLITE_DB_PATH||'/var/app/data/thesisforge.sqlite';
const DEADLINE_MS=15000;
export function validateCheckpointRequest(options, now=Date.now()) {
  const database=options.database||MAIN_DATABASE;
  if(!path.isAbsolute(database)||fs.realpathSync(database)!==database)throw Error('exact_regular_database_path_required');
  const stat=fs.lstatSync(database);
  if(!stat.isFile()||stat.isSymbolicLink())throw Error('exact_regular_database_path_required');
  const identity={device:stat.dev,inode:stat.ino,owner:stat.uid};
  const execute=options.execute===true;
  if(execute) {
    if(typeof process.getuid!=='function'||process.getuid()===0||process.getuid()!==stat.uid)throw Error('run_as_database_owner_not_root');
    if(Number(options.expectedInode)!==stat.ino||Number(options.expectedDevice)!==stat.dev)throw Error('database_identity_changed');
    const backup=options.backupReceipt;
    const age=now-Date.parse(backup?.capturedAt);
    if(!backup||backup.status!=='verified_off_host_user_backup'||backup.remoteRestore!==true
      ||backup.offHostRestore!==true||backup.credentialRecoveryEnvelopeVerified!==true
      ||backup.productionDatabasesWritten!==false||!Number.isFinite(age)||age<0||age>2*60*60*1000
      ||!/^[-a-f0-9]{36}$/.test(backup.generation||'')||options.backupGeneration!==backup.generation)throw Error('fresh_verified_user_backup_required');
    if(!/^snap-[a-f0-9]{8,17}$/.test(options.rollbackSnapshot||''))throw Error('completed_rollback_snapshot_acknowledgement_required');
  }
  return {database,execute,identity,backupGeneration:execute?options.backupGeneration:null,
    rollbackSnapshot:execute?options.rollbackSnapshot:null};
}

// Run all SQLite I/O outside the operator process. busy_timeout limits lock
// waits, not disk I/O; the parent imposes an independent wall-clock deadline.
const workerSource=String.raw`
import fs from 'node:fs';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
const request=JSON.parse(process.argv[1]);
function fileState(file) {
  try {const s=fs.lstatSync(file);return {bytes:s.size,device:s.dev,inode:s.ino,modifiedAt:s.mtime.toISOString()};}
  catch(error) {if(error.code==='ENOENT')return null;throw error;}
}
function checkIdentity() {
  const s=fs.lstatSync(request.database);
  if(!s.isFile()||s.isSymbolicLink()||s.dev!==request.identity.device||s.ino!==request.identity.inode
    ||s.uid!==request.identity.owner)throw Error('database_identity_changed');
}
checkIdentity();
let db;
try {
  db=new DatabaseSync(request.database,{readOnly:!request.execute});
  db.exec('PRAGMA busy_timeout=1000; PRAGMA cache_size=-2048; PRAGMA mmap_size=0;');
  if(!request.execute)db.exec('PRAGMA query_only=ON;');
  const sqliteVersion=db.prepare('SELECT sqlite_version() AS v').get().v;
  const version=sqliteVersion.split('.').map(Number);
  if(version[0]!==3||version[1]<51||(version[1]===51&&version[2]<3))throw Error('wal_reset_fixed_sqlite_runtime_required');
  if(db.prepare('PRAGMA main.journal_mode').get().journal_mode!=='wal')throw Error('database_is_not_in_wal_mode');
  function state() {
    const schema=db.prepare("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name").all();
    if(schema.length>10000)throw Error('unexpected_schema_size');
    return {main:fileState(request.database),wal:fileState(request.database+'-wal'),shm:fileState(request.database+'-shm'),
      schemaVersion:db.prepare('PRAGMA main.schema_version').get().schema_version,
      schemaSha256:crypto.createHash('sha256').update(JSON.stringify(schema)).digest('hex'),
      logicalWal:db.prepare('PRAGMA main.wal_checkpoint(NOOP)').get()};
  }
  const before=state();
  checkIdentity();
  const checkpoint=request.execute?db.prepare('PRAGMA main.wal_checkpoint(TRUNCATE)').get():null;
  const after=request.execute?state():before;
  checkIdentity();
  if(before.schemaVersion!==after.schemaVersion||before.schemaSha256!==after.schemaSha256)throw Error('concurrent_schema_change_requires_review');
  const status=!request.execute?'read_only_wal_inspection':checkpoint.busy===0?'checkpoint_complete':'checkpoint_busy';
  console.log(JSON.stringify({status,database:request.database,sqliteVersion,before,checkpoint,after,
    applicationRowsMutated:false,sidecarsDeletedByOperator:false,backupGeneration:request.backupGeneration,
    rollbackSnapshotAcknowledged:request.rollbackSnapshot,
    note:request.execute?'Concurrent writers may append after checkpoint; a busy result must not trigger file deletion or an unbounded retry.':'NOOP reports logical WAL frames without checkpointing. File size is retained allocation, not necessarily uncheckpointed data.'}));
} finally {if(db)db.close();}
`;

export function checkpointSqliteWal(options) {
  const request=validateCheckpointRequest(options);
  try {
    return JSON.parse(execFileSync(process.execPath,['--input-type=module','--eval',workerSource,JSON.stringify(request)],
      {encoding:'utf8',timeout:DEADLINE_MS,killSignal:'SIGKILL',maxBuffer:1024*1024,stdio:['ignore','pipe','pipe']}));
  } catch(error) {
    // A checkpoint may have partly/completely progressed before timeout. Do
    // not claim that no disk operation occurred, or automatically retry.
    throw Error(error.code==='ETIMEDOUT'
      ?'checkpoint_deadline_exceeded_preserve_all_files_and_inspect'
      :'checkpoint_not_confirmed_preserve_all_files_and_review');
  }
}

function parseArguments(args) {
  const result={};
  const fields={'--database':'database','--expected-inode':'expectedInode','--expected-device':'expectedDevice',
    '--backup-generation':'backupGeneration','--rollback-snapshot':'rollbackSnapshot'};
  for(let i=0;i<args.length;i++) {
    const arg=args[i];
    if(arg==='--execute') {if(result.execute)throw Error('duplicate_argument');result.execute=true;}
    else if(arg==='--backup-receipt') {
      const file=args[++i];
      if(result.backupReceipt||!file||!path.isAbsolute(file)||fs.statSync(file).size>64*1024)throw Error('invalid_backup_receipt');
      result.backupReceipt=JSON.parse(fs.readFileSync(file,'utf8'));
    } else if(fields[arg]) {
      if(result[fields[arg]]!==undefined||!args[i+1]||args[i+1].startsWith('--'))throw Error('invalid_argument');
      result[fields[arg]]=args[++i];
    } else throw Error('unknown_argument');
  }
  return result;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const result=checkpointSqliteWal(parseArguments(process.argv.slice(2)));
    console.log(JSON.stringify(result,null,2));
    if(result.status==='checkpoint_busy')process.exitCode=2;
  } catch(error) {console.error(JSON.stringify({status:'maintenance_not_confirmed',reason:error.message}));process.exitCode=1;}
}
