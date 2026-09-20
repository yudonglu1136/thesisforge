// Root/operator-only immutable public release installation. Local full SQLite
// integrity/FK checks are bound to exact SHA-256 bytes. Host verification checks
// those bytes and bounded schemas, not a second expensive live-EBS full scan.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {Readable,Transform} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import {setTimeout as delay} from 'node:timers/promises';
import {DatabaseSync} from 'node:sqlite';
import {execFileSync} from 'node:child_process';

const root='/var/app/data/investment-releases';
const keys=['research','strategy','composition'];
const rate=32*1024**2;
export const minimumReleaseHeadroomBytes=10*1024**3;
const fail=code=>{throw Error(code);};
const exists=file=>{try{fs.lstatSync(file);return true;}catch(e){if(e.code==='ENOENT')return false;throw e;}};
const validDate=s=>typeof s==='string'&&!Number.isNaN(Date.parse(s));

export function validateInstallPayload(p) {
 if(p?.version!=='investment-install-v1'||!/^redesign-\d{8}-v[1-9]\d*$/.test(p.releaseId||'')
  ||!/^\d{4}-\d{2}-\d{2}$/.test(p.cutoff||'')||!validDate(p.cutoff)||new Date(p.cutoff).toISOString().slice(0,10)!==p.cutoff
  ||p.sourceAlignment!=='pass'||!/^snap-[a-f0-9]+$/.test(p.rollbackSnapshot||'')||p.rollbackVerified!==true
  ||Object.keys(p.files??{}).sort().join(',')!==[...keys].sort().join(','))fail('invalid_install_contract');
 if(p.resume!==undefined&&typeof p.resume!=='boolean')fail('invalid_resume_contract');
 if(p.resume&&(!Number.isSafeInteger(p.previousInstallerPid)||p.previousInstallerPid<=1))fail('previous_installer_pid_required');
 for(const key of keys) {
  const f=p.files[key],v=f?.producerValidation;
  if(!f||!Number.isSafeInteger(f.bytes)||f.bytes<4096||! /^[a-f0-9]{64}$/.test(f.sha256||'')
   ||!Array.isArray(f.tables)||!f.tables.length||new Set(f.tables).size!==f.tables.length
   ||f.tables.some(t=>!/^[a-z][a-z0-9_]*$/.test(t)||/user|portfolio|login|credential|investment_events/.test(t)))fail('invalid_public_file_contract');
  if(v?.version!=='sqlite-full-validation-v1'||v.sha256!==f.sha256||v.bytes!==f.bytes
   ||v.integrityCheck!=='ok'||v.foreignKeyCheck!=='ok'||v.schema!=='pass'||v.privateDataExcluded!==true
   ||!validDate(v.verifiedAt))fail('exact_producer_full_validation_required');
  const url=new URL(f.downloadUrl);
  if(url.protocol!=='https:'||url.username||url.password||url.port||url.hash
   ||!['thesisforge-production-378477120101-us-east-1.s3.amazonaws.com','thesisforge-production-378477120101-us-east-1.s3.us-east-1.amazonaws.com'].includes(url.hostname)
   ||url.pathname!==`/investment-releases/${p.releaseId}/${key}.sqlite`)fail('invalid_private_object');
 }
 return path.join(root,p.releaseId);
}

function regular(file,{immutable=false,uid=process.getuid()}={}) {
 const s=fs.lstatSync(file);
 if(!s.isFile()||s.isSymbolicLink()||s.nlink!==1||s.uid!==uid||fs.realpathSync(file)!==file
  ||(s.mode&0o022)||(immutable&&(s.mode&0o222)))fail('unsafe_staged_file');
 return s;
}

export function classifyStagedFiles(directory,files,{uid=process.getuid()}={}) {
 const allowed=new Set(keys.flatMap(k=>[`${k}.sqlite`,`${k}.sqlite.part`]));
 const names=fs.readdirSync(directory);
 if(names.includes('manifest.json'))fail('release_already_finalized');
 if(names.some(n=>!allowed.has(n)))fail('unexpected_release_entry');
 return Object.fromEntries(keys.map(key=>{
  const final=path.join(directory,`${key}.sqlite`),partial=`${final}.part`;
  if(exists(final)&&exists(partial))fail('ambiguous_final_and_partial');
  if(exists(final)){const s=regular(final,{immutable:true,uid});if(s.size!==files[key].bytes)fail('completed_file_size_mismatch');return [key,{state:'completed',bytes:s.size}];}
  if(exists(partial)){const s=regular(partial,{uid});if(s.size>files[key].bytes)fail('partial_file_size_exceeded');return [key,{state:'partial',bytes:s.size}];}
  return [key,{state:'missing',bytes:0}];
 }));
}

export function releaseDiskProjection(files,states,freeBytes,{minimumHeadroomBytes=minimumReleaseHeadroomBytes}={}) {
 const totalBytes=keys.reduce((s,k)=>s+files[k].bytes,0);
 const existingBytes=keys.reduce((s,k)=>s+(states[k]?.bytes??0),0);
 const additionalBytes=totalBytes-existingBytes,projectedFreeBytes=freeBytes-additionalBytes;
 return {totalBytes,existingBytes,additionalBytes,freeBytes,projectedFreeBytes,minimumHeadroomBytes,
  ready:additionalBytes>=0&&projectedFreeBytes>=minimumHeadroomBytes};
}

// A completed root-owned immutable release is a trusted install receipt, not a
// reason to download/copy 8 GB again. Recheck exact contract, physical isolation
// and small schemas; preserve manifest bytes and existing files unchanged.
export function reuseFinalizedRelease(directory,p,{uid=process.getuid()}={}) {
 const manifestPath=path.join(directory,'manifest.json');
 if(!exists(manifestPath))return null;
 const info=regular(manifestPath,{immutable:true,uid});if(info.size>65536)fail('invalid_completed_manifest');
 const s=fs.lstatSync(directory);
 if(!s.isDirectory()||s.uid!==uid||(s.mode&0o222)||fs.realpathSync(directory)!==directory)fail('unsafe_completed_release_directory');
 const names=fs.readdirSync(directory).sort();
 if(names.join(',')!==['manifest.json',...keys.map(k=>`${k}.sqlite`)].sort().join(','))fail('unexpected_completed_release_entry');
 const m=JSON.parse(fs.readFileSync(manifestPath,'utf8'));
 if(m.version!=='investment-runtime-release-v1'||m.state!=='verified'||m.releaseId!==p.releaseId||m.cutoff!==p.cutoff
  ||m.checks?.integrity!=='ok'||m.checks?.schema!=='pass'||m.checks?.sourceAlignment!=='pass'||m.checks?.privateDataExcluded!==true
  ||Object.keys(m.files??{}).sort().join(',')!==[...keys].sort().join(','))fail('completed_manifest_contract_mismatch');
 const identities=new Set();
 for(const key of keys) {
  const file=path.join(directory,`${key}.sqlite`),a=m.files[key],b=p.files[key],st=regular(file,{immutable:true,uid}),identity=`${st.dev}:${st.ino}`;
  if(a.path!==file||a.bytes!==b.bytes||a.sha256!==b.sha256||st.size!==b.bytes||identities.has(identity))fail('completed_file_contract_mismatch');
  identities.add(identity);checkDownloadedSchema(file,b,key);
 }
 return m;
}

// Different release names must not create another full copy of identical data.
// Return the verified existing release for an explicit operator pointer reuse;
// do not silently change the requested activation ID or create hard links.
export function findIdenticalFinalizedRelease(base,p,{uid=process.getuid()}={}) {
 const names=fs.readdirSync(base).filter(n=>/^redesign-\d{8}-v[1-9]\d*$/.test(n)&&n!==p.releaseId);
 if(names.length>64)fail('release_retention_review_required');
 for(const name of names) {
  const directory=path.join(base,name),file=path.join(directory,'manifest.json');
  if(!exists(file))continue;
  const st=fs.lstatSync(file);if(!st.isFile()||st.isSymbolicLink()||st.uid!==uid||st.size>65536)continue;
  let m;try{m=JSON.parse(fs.readFileSync(file,'utf8'));}catch{continue;}
  if(m.cutoff===p.cutoff&&keys.every(k=>m.files?.[k]?.bytes===p.files[k].bytes&&m.files[k].sha256===p.files[k].sha256)) {
   return reuseFinalizedRelease(directory,{...p,releaseId:name},{uid});
  }
 }
 return null;
}

// The lock is outside the release directory. Never steal/reap an old lock here.
export function acquireInstallLock(directory,{uid=process.getuid()}={}) {
 const lock=`${directory}.install-lock`,nonce=crypto.randomUUID();
 try{fs.mkdirSync(lock,{mode:0o700});}catch(e){if(e.code==='EEXIST')fail('installer_lock_exists_operator_review_required');throw e;}
 const info=fs.lstatSync(lock);
 if(info.uid!==uid||!info.isDirectory()||fs.realpathSync(lock)!==lock)fail('unsafe_installer_lock');
 const owner=path.join(lock,'owner.json');
 fs.writeFileSync(owner,JSON.stringify({pid:process.pid,nonce,startedAt:new Date().toISOString()}),{flag:'wx',mode:0o600});
 return ()=>{
  const current=JSON.parse(fs.readFileSync(owner,'utf8'));
  if(current.nonce!==nonce||current.pid!==process.pid)fail('installer_lock_identity_changed');
  fs.unlinkSync(owner);fs.rmdirSync(lock);
 };
}

const fingerprint=s=>`${s.dev}:${s.ino}:${s.size}:${s.mtimeMs}:${s.ctimeMs}`;
function byteMeter(digest,{initial=0,maxBytes,maxBytesPerSecond=rate,onProgress=()=>{}}) {
 let bytes=initial,last=Date.now();const start=performance.now();
 return new Transform({highWaterMark:1024**2,transform(chunk,_encoding,done){
  bytes+=chunk.length;if(bytes>maxBytes)return done(Error('release_size_exceeded'));digest.update(chunk);
  const wait=Math.max(0,(bytes-initial)/maxBytesPerSecond*1000-(performance.now()-start));
  if(Date.now()-last>=15000){onProgress(bytes);last=Date.now();}
  if(wait>0)delay(wait).then(()=>done(null,chunk),done);else done(null,chunk);
 }});
}

async function hashFile(file,digest,{maxBytesPerSecond=rate,onProgress=()=>{}}={}) {
 const before=regular(file),meter=byteMeter(digest,{maxBytes:before.size,maxBytesPerSecond,onProgress});
 // Drain without buffering the DB; yield to keep operator deadlines responsive.
 await pipeline(fs.createReadStream(file,{highWaterMark:1024**2}),meter,async function*(chunks){for await(const _chunk of chunks){/* discard */}});
 if(fingerprint(before)!==fingerprint(regular(file)))fail('staged_file_changed_during_hash');
 return before.size;
}

export function checkDownloadedSchema(file,contract,key) {
 const before=regular(file),db=new DatabaseSync(file,{readOnly:true});
 try {
  db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000; PRAGMA cache_size=-2048; PRAGMA cell_size_check=ON;');
  if(db.prepare('PRAGMA journal_mode').get().journal_mode!=='delete'||exists(`${file}-wal`)||exists(`${file}-shm`))fail('release_requires_self_contained_database');
  const actual=db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all().map(r=>r.name);
  if(JSON.stringify(actual)!==JSON.stringify([...contract.tables].sort()))fail('release_table_allowlist_mismatch');
  const views=key==='strategy'?['coverage_summary','verified_common_holdings']:[];
  if(db.prepare("SELECT name FROM sqlite_master WHERE type='view'").all().some(r=>!views.includes(r.name))
   ||db.prepare("SELECT COUNT(*) n FROM sqlite_master WHERE type='trigger'").get().n)fail('release_unexpected_view_or_trigger');
  const pages=db.prepare('PRAGMA page_count').get().page_count,pageSize=db.prepare('PRAGMA page_size').get().page_size;
  if(pages*pageSize!==contract.bytes||before.size!==contract.bytes)fail('release_sqlite_size_mismatch');
 }finally{db.close();}
 if(fingerprint(before)!==fingerprint(regular(file)))fail('staged_file_changed_during_schema_check');
}

export async function installPublicFile(directory,key,f,{fetchFile=fetch,maxBytesPerSecond=rate,progress=()=>{}}={}) {
 const file=path.join(directory,`${key}.sqlite`),partial=`${file}.part`,digest=crypto.createHash('sha256');
 if(exists(file)) {
  regular(file,{immutable:true});if(exists(partial))fail('ambiguous_final_and_partial');
  const bytes=await hashFile(file,digest,{maxBytesPerSecond,onProgress:bytes=>progress({phase:'rehash_completed',bytes})});
  if(bytes!==f.bytes||digest.digest('hex')!==f.sha256)fail('completed_file_sha_mismatch');
  checkDownloadedSchema(file,f,key);return {reused:true};
 }
 let offset=0;const partialExisted=exists(partial);
 if(partialExisted)offset=await hashFile(partial,digest,{maxBytesPerSecond,onProgress:bytes=>progress({phase:'rehash_partial',bytes})});
 if(offset>f.bytes)fail('partial_file_size_exceeded');
 if(offset<f.bytes) {
  const response=await fetchFile(f.downloadUrl,{redirect:'error',headers:offset?{Range:`bytes=${offset}-`}:{},signal:AbortSignal.timeout(600000)});
  if(response.status!==(offset?206:200)||Number(response.headers.get('content-length'))!==f.bytes-offset
   ||(response.headers.get('content-encoding')&&!['identity'].includes(response.headers.get('content-encoding')))
   ||(offset&&response.headers.get('content-range')!==`bytes ${offset}-${f.bytes-1}/${f.bytes}`))fail('release_download_metadata_mismatch');
  const expectedOffset=exists(partial)?regular(partial).size:0;
  if(expectedOffset!==offset)fail('partial_changed_before_append');
  const meter=byteMeter(digest,{initial:offset,maxBytes:f.bytes,maxBytesPerSecond,onProgress:bytes=>progress({phase:'download',bytes})});
  // Existing bytes are never overwritten. Interrupted partials retain their
  // bytes for exact Range append followed by one final full SHA comparison.
  const sink=fs.createWriteStream(partial,{flags:partialExisted?'a':'wx',mode:0o600,highWaterMark:1024**2});
  await pipeline(Readable.fromWeb(response.body),meter,sink);
 }
 if(regular(partial).size!==f.bytes||digest.digest('hex')!==f.sha256)fail('release_sha_mismatch');
 checkDownloadedSchema(partial,f,key);
 const fd=fs.openSync(partial,'r');try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
 fs.chmodSync(partial,0o444);
 // link() publishes without clobbering; rename() could overwrite another final.
 fs.linkSync(partial,file);fs.unlinkSync(partial);
 return {reused:false,resumedBytes:offset};
}

export async function installInvestmentRelease(p) {
 const directory=validateInstallPayload(p);
 if(process.platform!=='linux'||process.getuid()!==0)fail('operator_root_required');
 const env=JSON.parse(execFileSync('/opt/elasticbeanstalk/bin/get-config',['environment'],{encoding:'utf8'}));
 if(env.SQLITE_DB_PATH!=='/var/app/data/thesisforge.sqlite'||env.NODE_ENV!=='production')fail('wrong_runtime');
 if(p.resume) {
  try{process.kill(p.previousInstallerPid,0);fail('previous_installer_still_running');}
  catch(e){if(e.code!=='ESRCH')throw e;}
 }
 // Idle I/O priority and bounded streaming protect the existing small host.
 os.setPriority(process.pid,10);
 execFileSync('/usr/bin/ionice',['-c','3','-p',String(process.pid)]);
 if(!exists(root))fs.mkdirSync(root,{mode:0o755});
 const rootInfo=fs.lstatSync(root);
 if(!rootInfo.isDirectory()||rootInfo.uid!==0||(rootInfo.mode&0o022)||fs.realpathSync(root)!==root)fail('invalid_release_root');
 const releaseLock=acquireInstallLock(directory);
 try {
  const completed=exists(directory)?reuseFinalizedRelease(directory,p):null;
  if(completed){console.log(JSON.stringify({status:'identical_release_already_verified',releaseId:completed.releaseId,manifest:path.join(directory,'manifest.json'),downloadedBytes:0,additionalDiskBytes:0}));return completed;}
  const reusable=findIdenticalFinalizedRelease(root,p);
  if(reusable){console.log(JSON.stringify({status:'identical_data_release_exists',requestedReleaseId:p.releaseId,reuseReleaseId:reusable.releaseId,manifest:path.join(root,reusable.releaseId,'manifest.json'),additionalDiskBytes:0}));fail('reuse_existing_release_id_instead_of_copying');}
  if(exists(directory)) {
   if(!p.resume)fail('explicit_resume_required');
   const s=fs.lstatSync(directory);
   if(!s.isDirectory()||s.uid!==0||(s.mode&0o077)||fs.realpathSync(directory)!==directory)fail('unsafe_release_directory');
  }else fs.mkdirSync(directory,{mode:0o700});
  const states=classifyStagedFiles(directory,p.files);
  const disk=fs.statfsSync('/var/app/data'),projection=releaseDiskProjection(p.files,states,disk.bavail*disk.bsize);
  console.log(JSON.stringify({phase:'disk_preflight',...projection}));
  if(!projection.ready)fail('insufficient_disk_headroom_for_isolated_release');
  const files={};
  for(const key of keys) {
   const f=p.files[key];console.log(JSON.stringify({phase:'checking_public_file',file:key,state:states[key].state}));
   const result=await installPublicFile(directory,key,f,{progress:detail=>console.log(JSON.stringify({file:key,...detail}))});
   files[key]={path:path.join(directory,`${key}.sqlite`),bytes:f.bytes,sha256:f.sha256,
    producerValidation:f.producerValidation,hostValidation:{sha256:'matched',schema:'pass',journalMode:'delete',fullScan:'not_repeated_exact_producer_bytes'}};
   console.log(JSON.stringify({verified:key,bytes:f.bytes,sha256:f.sha256,...result}));
  }
  const manifest={version:'investment-runtime-release-v1',releaseId:p.releaseId,state:'verified',cutoff:p.cutoff,
   installedAt:new Date().toISOString(),rollbackSnapshot:p.rollbackSnapshot,
   checks:{integrity:'ok',schema:'pass',sourceAlignment:'pass',privateDataExcluded:true},
   validationBasis:'producer_full_integrity_and_foreign_keys_plus_host_sha256_and_schema',files};
  fs.writeFileSync(path.join(directory,'manifest.json'),JSON.stringify(manifest,null,2),{flag:'wx',mode:0o444});
  fs.chmodSync(directory,0o555);
  console.log(JSON.stringify({status:'isolated_public_release_verified',releaseId:p.releaseId,manifest:path.join(directory,'manifest.json'),productionDatabasesReplaced:false}));
  return manifest;
 }finally{releaseLock();}
}
if(typeof rolloutPayload!=='undefined')await installInvestmentRelease(rolloutPayload);
