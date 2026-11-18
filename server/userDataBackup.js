import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { DatabaseSync, backup } from 'node:sqlite';

// Operator-only, versioned encrypted exports. Not an HTTP endpoint. Each SQLite
// snapshot is consistent (including WAL), but multiple databases are NOT one
// global transaction. Freeze writes before using an export for a cutover.
const MAGIC = Buffer.from('TFUD0001');
const HEADER = MAGIC.length + 12;
const MAX_FILES = 10000;
const MAX_BYTES = 1024 * 1024 * 1024;
const MAX_MANIFEST_BYTES = 2 * 1024 * 1024;
const kinds = {
  registry: ['portfolio_user_registry'],
  login: ['login_activity_users'],
  portfolio: [
    'portfolio_connections',
    'portfolio_connection_recovery',
    'portfolio_nav_points',
    'portfolio_report_snapshots',
    'portfolio_analysis_snapshots',
    'portfolio_passive_ledgers',
    'portfolio_account_sync_status',
    'user_preferences',
    'readonly_brokers'
  ],
  investment: ['investment_events']
};
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw new Error(message); };
function keyBuffer(key) {
  if (typeof key !== 'string' || !/^[a-fA-F0-9]{64}$/.test(key)) fail('A dedicated 32-byte hex USER_DATA_BACKUP_KEY is required');
  return Buffer.from(key, 'hex');
}
function kindFor(logical) {
  if (logical === 'portfolios/portfolio-admin.sqlite') return 'registry';
  if (logical === 'portfolios/login-activity.sqlite') return 'login';
  if (logical === 'investment.sqlite') return 'investment';
  if (/^portfolios\/[a-f0-9]{40}\/portfolio\.sqlite$/.test(logical)) return 'portfolio';
  fail('Unknown user database path');
}
function fileStat(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) fail('User database must be a regular non-symlink file');
  return stat;
}
function directory(dir) {
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail('User data directory must not be a symlink');
}
function newDirectory(dir) {
  const target = path.resolve(dir);
  // Parent must exist and be trusted; never recursively create operator paths.
  directory(path.dirname(target));
  fs.mkdirSync(target, {mode:0o700}); // EEXIST is intentional, even if empty.
  return target;
}
export function discoverUserDatabases(paths) {
  const entries = [];
  // A configured private investment journal may share the portfolio root.
  // Recognize only that exact file and its SQLite sidecars here; enumerate
  // the database once, below, under its existing investment logical name.
  const investmentFiles = new Set(paths.investment
    ? ['', '-wal', '-shm'].map(suffix=>path.resolve(paths.investment)+suffix) : []);
  const add = (file, logical) => {
    if (!fs.existsSync(file)) return;
    fileStat(file);
    entries.push({file:path.resolve(file), logical, kind:kindFor(logical)});
  };
  if (fs.existsSync(paths.portfolios)) {
    directory(paths.portfolios);
    for (const item of fs.readdirSync(paths.portfolios, {withFileTypes:true})) {
      const full = path.join(paths.portfolios,item.name);
      if (item.isSymbolicLink()) fail('Symlinks are not allowed in user database inventory');
      if (item.isDirectory()) {
        if (!/^[a-f0-9]{40}$/.test(item.name)) fail('Unknown directory in user database inventory');
        for (const nested of fs.readdirSync(full, {withFileTypes:true})) {
          if (!nested.isFile() || !/^portfolio\.sqlite(?:-wal|-shm)?$/.test(nested.name)) fail('Unknown file in user database inventory');
        }
        add(path.join(full,'portfolio.sqlite'),`portfolios/${item.name}/portfolio.sqlite`);
      } else if (!/^(?:portfolio-admin|login-activity)\.sqlite(?:-wal|-shm)?$/.test(item.name)
        && !(item.isFile() && investmentFiles.has(path.resolve(full)))) {
        fail('Unknown file in user database inventory');
      }
    }
  }
  add(paths.registry,'portfolios/portfolio-admin.sqlite');
  add(paths.login,'portfolios/login-activity.sqlite');
  if (paths.investment) {
    if (!fs.existsSync(paths.investment)) fail('Configured investment database is missing');
    add(paths.investment,'investment.sqlite');
  }
  if (!entries.length || entries.length > MAX_FILES) fail('User database inventory is empty or exceeds the bound');
  const identity=file=>{const stat=fs.statSync(file);return `${stat.dev}:${stat.ino}`;};
  if (new Set(entries.map(e=>identity(e.file))).size !== entries.length) fail('User database paths overlap');
  if (paths.research && fs.existsSync(paths.research)
    && entries.some(e=>identity(e.file)===identity(paths.research))) fail('Research data is not user data');
  return entries.sort((a,b)=>a.logical.localeCompare(b.logical));
}
function inspect(file, kind) {
  const db = new DatabaseSync(file, {readOnly:true});
  try {
    if (db.prepare('PRAGMA integrity_check').all().some(r=>Object.values(r)[0]!=='ok')) fail('User database integrity check failed');
    const schema = db.prepare("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").all();
    const tables = schema.filter(r=>r.type==='table').map(r=>r.name);
    if (!tables.length || tables.some(t=>!kinds[kind].includes(t))) fail('Unexpected table in user database; no data was skipped');
    const counts = Object.fromEntries(tables.map(t=>[t,Number(db.prepare(`SELECT count(*) AS n FROM "${t}"`).get().n)]));
    return {counts, schemaHash:hash(JSON.stringify(schema))};
  } finally {db.close();}
}
async function digestFile(file) {
  const digest = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) digest.update(chunk);
  return digest.digest('hex');
}
function sealBytes(plain,key,aad) {
  const iv=crypto.randomBytes(12), cipher=crypto.createCipheriv('aes-256-gcm',key,iv);
  cipher.setAAD(Buffer.from(aad));
  const ciphertext=Buffer.concat([cipher.update(plain),cipher.final()]);
  return Buffer.concat([MAGIC,iv,ciphertext,cipher.getAuthTag()]);
}
function openBytes(blob,key,aad) {
  if (blob.length<HEADER+16 || !blob.subarray(0,MAGIC.length).equals(MAGIC)) fail('Invalid encrypted backup header');
  const decipher=crypto.createDecipheriv('aes-256-gcm',key,blob.subarray(MAGIC.length,HEADER));
  decipher.setAAD(Buffer.from(aad));decipher.setAuthTag(blob.subarray(-16));
  return Buffer.concat([decipher.update(blob.subarray(HEADER,-16)),decipher.final()]);
}
async function sealFile(input,output,key,aad) {
  const iv=crypto.randomBytes(12), cipher=crypto.createCipheriv('aes-256-gcm',key,iv);
  cipher.setAAD(Buffer.from(aad));
  fs.writeFileSync(output,Buffer.concat([MAGIC,iv]),{flag:'wx',mode:0o600});
  await pipeline(fs.createReadStream(input),cipher,fs.createWriteStream(output,{flags:'r+',start:HEADER}));
  fs.appendFileSync(output,cipher.getAuthTag());
}
async function openFile(input,output,key,aad,expectedBytes) {
  const size=fileStat(input).size;
  if (size!==expectedBytes+HEADER+16 || expectedBytes<=0 || expectedBytes>MAX_BYTES) fail('Encrypted database size mismatch');
  const fd=fs.openSync(input,'r'), header=Buffer.alloc(HEADER), tag=Buffer.alloc(16);
  try {fs.readSync(fd,header,0,HEADER,0);fs.readSync(fd,tag,0,16,size-16);} finally {fs.closeSync(fd);}
  if (!header.subarray(0,MAGIC.length).equals(MAGIC)) fail('Invalid encrypted backup header');
  const decipher=crypto.createDecipheriv('aes-256-gcm',key,header.subarray(MAGIC.length));
  decipher.setAAD(Buffer.from(aad));decipher.setAuthTag(tag);
  await pipeline(fs.createReadStream(input,{start:HEADER,end:size-17}),decipher,fs.createWriteStream(output,{flags:'wx',mode:0o600}));
}
export async function backupUserData({paths,output,key,keyId='v1'}) {
  const secret=keyBuffer(key);
  if (!/^[a-zA-Z0-9_-]{1,64}$/.test(keyId)) fail('Invalid backup key ID');
  const sources=discoverUserDatabases(paths), target=path.resolve(output);
  if (sources.some(s=>target===path.dirname(s.file) || target.startsWith(`${paths.portfolios}${path.sep}`))) fail('Backup must be outside the live user directory');
  const out=newDirectory(target), work=fs.mkdtempSync(path.join(out,'.snapshot-'));
  const manifest={version:1,generation:crypto.randomUUID(),keyId,startedAt:new Date().toISOString(),consistency:'per_database_online_snapshot',files:[]};
  try {
    let totalBytes=0;
    for (const source of sources) {
      const snapshot=path.join(work,'snapshot.sqlite'), start=new Date().toISOString();
      const db=new DatabaseSync(source.file,{readOnly:true});
      try {await backup(db,snapshot,{rate:128});} finally {db.close();}
      // Materialize the private copy as one file. A WAL-mode header can cause
      // even a read-only inspection to create sidecars; never reuse/export a
      // main file while private WAL pages or locks remain beside it.
      const materialized=new DatabaseSync(snapshot);
      try {materialized.exec('PRAGMA journal_mode=DELETE');} finally {materialized.close();}
      fs.chmodSync(snapshot,0o600);
      const bytes=fileStat(snapshot).size;
      totalBytes+=bytes;if(totalBytes>MAX_BYTES) fail('User backup exceeds the 1 GiB safety bound');
      const evidence=inspect(snapshot,source.kind), sha256=await digestFile(snapshot);
      const object=`db-${String(manifest.files.length+1).padStart(5,'0')}.enc`;
      await sealFile(snapshot,path.join(out,object),secret,`${manifest.generation}:${source.logical}`);
      manifest.files.push({logical:source.logical,object,kind:source.kind,bytes,sha256,...evidence,startedAt:start,finishedAt:new Date().toISOString()});
      fs.unlinkSync(snapshot);
    }
    manifest.finishedAt=new Date().toISOString();
    const manifestBytes=Buffer.from(JSON.stringify(manifest));
    if(manifestBytes.length+HEADER+16>MAX_MANIFEST_BYTES) fail('Backup manifest exceeds the safety bound');
    fs.writeFileSync(path.join(out,'manifest.enc'),sealBytes(manifestBytes,secret,'thesisforge-user-data-manifest-v1'),{flag:'wx',mode:0o600});
    fs.rmdirSync(work);
    return {status:'verified_local_backup',generation:manifest.generation,databases:manifest.files.length,bytes:totalBytes,startedAt:manifest.startedAt,finishedAt:manifest.finishedAt,consistency:manifest.consistency};
  } catch (error) {
    // Only this invocation's newly-created directory is eligible for cleanup.
    fs.rmSync(out,{recursive:true,force:true});throw error;
  }
}
export async function restoreUserData({input,output,key}) {
  const secret=keyBuffer(key);directory(input);
  const manifestFile=path.join(input,'manifest.enc');
  if(fileStat(manifestFile).size>MAX_MANIFEST_BYTES) fail('Backup manifest exceeds the safety bound');
  const manifest=JSON.parse(openBytes(fs.readFileSync(manifestFile),secret,'thesisforge-user-data-manifest-v1'));
  if(manifest.version!==1 || !/^[a-f0-9-]{36}$/.test(manifest.generation) || !Array.isArray(manifest.files)
    || !manifest.files.length || manifest.files.length>MAX_FILES) fail('Invalid backup manifest');
  const names=new Set(),objects=new Set();let bytes=0;
  for (const f of manifest.files) {
    if (kindFor(f.logical)!==f.kind || !/^db-\d{5}\.enc$/.test(f.object) || !/^[a-f0-9]{64}$/.test(f.sha256)
      || names.has(f.logical) || objects.has(f.object) || !Number.isSafeInteger(f.bytes) || f.bytes<=0) fail('Invalid backup entry');
    names.add(f.logical);objects.add(f.object);bytes+=f.bytes;
  }
  if(bytes>MAX_BYTES) fail('Restored data exceeds the safety bound');
  if(fs.readdirSync(input).some(f=>f!=='manifest.enc'&&!objects.has(f))) fail('Unexpected backup file');
  // Reserve a NEW destination. There is no overwrite/merge/production mode.
  const out=newDirectory(output);
  try {
    for (const f of manifest.files) {
      const dest=path.join(out,f.logical);
      fs.mkdirSync(path.dirname(dest),{recursive:true,mode:0o700});
      await openFile(path.join(input,f.object),dest,secret,`${manifest.generation}:${f.logical}`,f.bytes);
      if(await digestFile(dest)!==f.sha256) fail('Restored database hash mismatch');
      const evidence=inspect(dest,f.kind);
      if(evidence.schemaHash!==f.schemaHash || JSON.stringify(evidence.counts)!==JSON.stringify(f.counts)) fail('Restored schema/count mismatch');
    }
    return {status:'verified_isolated_restore',generation:manifest.generation,databases:manifest.files.length,bytes,keyId:manifest.keyId};
  } catch (error) {fs.rmSync(out,{recursive:true,force:true});throw error;}
}
