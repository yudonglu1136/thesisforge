// Operator-only, copy-on-write Guru revision. The v1 warehouse files remain at
// their original immutable paths; never hard-link, modify, or duplicate them.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { validateInvestmentRelease, INVESTMENT_RELEASE_VERSION, INVESTMENT_REUSED_RELEASE_VERSION } from '../server/investmentRuntimeConfig.js';
import { acquireInstallLock, installPublicFile, checkDownloadedSchema, minimumReleaseHeadroomBytes } from './install-investment-release.mjs';
import { applyGuruDelta, validateGuruDeltaContract, guruDeltaTables } from './investment-guru-delta.mjs';

const defaultRoot = '/var/app/data/investment-releases';
const rate = 32 * 1024 ** 2;
const fail = code => { throw Error(code); };
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key,canonical(value[key])])) : value;
const contractSha = value => sha(JSON.stringify(canonical(value)));
const hex = value => /^[a-f0-9]{64}$/.test(value ?? '');
const regular = (file,uid,{immutable=false}={}) => {
  const info = fs.lstatSync(file);
  if (!info.isFile() || info.isSymbolicLink() || info.uid !== uid || info.nlink !== 1 || (info.mode & 0o022)
    || (immutable && (info.mode & 0o222)) || fs.realpathSync(file) !== file) fail('unsafe_guru_release_file');
  return info;
};
const directorySafe = (directory,uid,{immutable=false}={}) => {
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.uid !== uid || (info.mode & 0o022) || (immutable && (info.mode & 0o222))
    || fs.realpathSync(directory) !== directory) fail('unsafe_guru_release_directory');
};
const freeDisk = directory => { const s = fs.statfsSync(directory); return s.bavail * s.bsize; };

export function validateGuruReleaseInstall(p,releaseRoot=defaultRoot) {
  validateGuruDeltaContract(p?.patch);
  if (p.version !== 'investment-guru-install-v1' || !/^guru-sync-\d{8}-v[1-9]\d*$/.test(p.releaseId ?? '')
    || p.rollbackVerified !== true || !/^snap-[a-f0-9]+$/.test(p.rollbackSnapshot ?? '')
    || p.sourceAlignment !== 'pass' || !/^\d{4}-\d{2}-\d{2}$/.test(p.cutoff ?? '')
    || !Number.isSafeInteger(p.measuredJournalBytes) || p.measuredJournalBytes <= 0
    || p.measuredJournalBytes > p.patch.baseResearch.bytes) fail('invalid_guru_install_contract');
  const r = p.research, v = r?.producerValidation, d = p.delta;
  if (!Number.isSafeInteger(r?.bytes) || r.bytes < 4096 || !hex(r.sha256)
    || !Array.isArray(r.tables) || r.tables.some(t => !/^[a-z][a-z0-9_]*$/.test(t) || /user|portfolio|login|credential|investment_events/.test(t))
    || new Set(r.tables).size !== r.tables.length || Object.keys(guruDeltaTables).some(t => !r.tables.includes(t))
    || v?.version !== 'sqlite-full-validation-v1' || v.bytes !== r.bytes || v.sha256 !== r.sha256
    || v.integrityCheck !== 'ok' || v.foreignKeyCheck !== 'ok' || v.schema !== 'pass' || v.privateDataExcluded !== true
    || v.nonGuruTablesUnchanged !== true || v.nonTargetGuruRowsUnchanged !== true
    || v.baseResearchSha256 !== p.patch.baseResearch.sha256 || Number.isNaN(Date.parse(v.verifiedAt))) fail('invalid_guru_result_attestation');
  if (!Number.isSafeInteger(d?.bytes) || d.bytes < 4096 || d.bytes > 256 * 1024 ** 2 || !hex(d.sha256)
    || JSON.stringify([...(d.tables ?? [])].sort()) !== JSON.stringify(Object.keys(guruDeltaTables).sort())) fail('invalid_guru_delta_file');
  const url = new URL(d.downloadUrl);
  if (url.protocol !== 'https:' || url.username || url.password || url.port || url.hash
    || !['thesisforge-production-378477120101-us-east-1.s3.amazonaws.com','thesisforge-production-378477120101-us-east-1.s3.us-east-1.amazonaws.com'].includes(url.hostname)
    || url.pathname !== `/investment-releases/${p.releaseId}/delta.sqlite`) fail('invalid_guru_delta_object');
  const base = p.baseManifest;
  if (!hex(base?.sha256) || !/^redesign-\d{8}-v[1-9]\d*$/.test(base.releaseId ?? '')
    || base.releaseId === p.releaseId || base.path !== path.join(releaseRoot,base.releaseId,'manifest.json')) fail('invalid_guru_base_manifest');
  return path.join(releaseRoot,p.releaseId);
}

export function guruDeltaDiskProjection(p,freeBytes) {
  const journalReserveBytes = Math.max(16 * 1024 ** 2,Math.ceil(p.measuredJournalBytes * 1.25) + 1024 ** 2);
  const operationalReserveBytes = 16 * 1024 ** 2;
  const additionalBytes = Math.max(p.patch.baseResearch.bytes,p.research.bytes) + p.delta.bytes;
  const projectedPeakFreeBytes = freeBytes - additionalBytes - journalReserveBytes - operationalReserveBytes;
  return {freeBytes,additionalBytes,journalReserveBytes,operationalReserveBytes,projectedPeakFreeBytes,
    projectedFinalFreeBytes:freeBytes - p.research.bytes - p.delta.bytes,minimumHeadroomBytes:minimumReleaseHeadroomBytes,
    ready:Number.isSafeInteger(freeBytes) && projectedPeakFreeBytes >= minimumReleaseHeadroomBytes};
}

function readBase(p,releaseRoot,uid) {
  const file = p.baseManifest.path, info = regular(file,uid,{immutable:true});
  directorySafe(path.dirname(file),uid,{immutable:true});
  if (info.size > 65536) fail('guru_base_manifest_too_large');
  const bytes = fs.readFileSync(file);
  if (sha(bytes) !== p.baseManifest.sha256) fail('guru_base_manifest_changed');
  const base = JSON.parse(bytes);
  if (base.version !== INVESTMENT_RELEASE_VERSION || base.releaseId !== p.baseManifest.releaseId || base.cutoff !== p.cutoff
    || path.dirname(path.dirname(file)) !== releaseRoot) fail('guru_base_release_mismatch');
  validateInvestmentRelease(base,{releaseId:base.releaseId,...Object.fromEntries(['research','strategy','composition'].map(k => [k,base.files?.[k]?.path]))},
    {manifestPath:file,trustedUid:uid});
  for (const key of ['research','strategy','composition']) regular(base.files[key].path,uid,{immutable:true});
  if (base.files.research.bytes !== p.patch.baseResearch.bytes || base.files.research.sha256 !== p.patch.baseResearch.sha256) fail('guru_base_research_mismatch');
  checkDownloadedSchema(base.files.research.path,{bytes:base.files.research.bytes,tables:p.research.tables},'research');
  return base;
}

function allocateCopyFile({file,fd,bytes,allocationBytes,platform}) {
  if (platform === 'linux') {
    // Fixed EOF and allocated extents prevent XFS's speculative allocation for
    // an ever-growing buffered append. KEEP_SIZE also reserves the already
    // budgeted SQLite growth without appending zeros to the byte-exact source.
    // Explicit fallocate reservations survive close, unlike speculative EOF
    // allocation. Never operate on an existing target.
    fs.ftruncateSync(fd,bytes);
    execFileSync('/usr/bin/fallocate',['--keep-size','--length',String(allocationBytes),'--',file],{timeout:10000,stdio:'pipe'});
  } else {
    // Local fixtures run on macOS. Production installation is Linux-only and
    // requires real allocation; sparse pre-sizing is not its fallback.
    fs.ftruncateSync(fd,bytes);
  }
}

export async function copyGuruReleaseFile(file,{output,uid=process.getuid(),maxBytesPerSecond=rate,space=()=>Infinity,
  progress=()=>{},allocate=allocateCopyFile,platform=process.platform,allocationBytes}={}) {
  const before = regular(file,uid), hash = crypto.createHash('sha256');
  let outputFd, reservedBytes, copyCompleted = false;
  try {
    if (output) {
      reservedBytes = allocationBytes ?? before.size;
      if (!Number.isSafeInteger(reservedBytes) || reservedBytes < before.size) fail('guru_copy_allocation_size_invalid');
      if (space() - reservedBytes < minimumReleaseHeadroomBytes + 16 * 1024**2) fail('guru_copy_disk_headroom_exhausted');
      outputFd = fs.openSync(output,'wx',0o600);
      const created = fs.fstatSync(outputFd);
      allocate({file:output,fd:outputFd,bytes:before.size,allocationBytes:reservedBytes,platform});
      const allocated = regular(output,uid), blocks = allocated.blocks * 512;
      if (allocated.dev !== created.dev || allocated.ino !== created.ino || allocated.size !== before.size
        || blocks > reservedBytes + 1024**2 || (platform === 'linux' && blocks < reservedBytes)) fail('guru_copy_allocation_mismatch');
      if (space() < minimumReleaseHeadroomBytes + 16 * 1024**2) fail('guru_copy_disk_headroom_exhausted');
      progress({phase:'allocated_copy',bytes:before.size,reservedBytes,allocatedBytes:blocks});
    }
  let bytes = 0, last = Date.now(); const started = performance.now();
  const meter = new Transform({highWaterMark:1024**2,transform(chunk,_encoding,done) {
    bytes += chunk.length; hash.update(chunk);
    if (output && space() - chunk.length < minimumReleaseHeadroomBytes + 16 * 1024**2) return done(Error('guru_copy_disk_headroom_exhausted'));
    if (Date.now() - last >= 15000) { progress({phase:output?'copy_base':'verify_result',bytes}); last = Date.now(); }
    const wait = Math.max(0,bytes / maxBytesPerSecond * 1000 - (performance.now() - started));
    if (wait) delay(wait).then(() => done(null,chunk),done); else done(null,chunk);
  }});
  if (output) await pipeline(fs.createReadStream(file,{highWaterMark:1024**2}),meter,
    fs.createWriteStream(output,{fd:outputFd,autoClose:false,start:0}));
  else await pipeline(fs.createReadStream(file,{highWaterMark:1024**2}),meter,async function*(chunks){for await (const _ of chunks) { /* bounded sink */ }});
  const after = regular(file,uid);
  if (['dev','ino','size','mtimeMs','ctimeMs'].some(k => before[k] !== after[k]) || bytes !== before.size) fail('guru_source_changed_during_read');
  if (outputFd !== undefined) fs.fsyncSync(outputFd);
  copyCompleted = true;
  return {bytes,sha256:hash.digest('hex')};
  } finally {
    if (outputFd !== undefined) {
      fs.closeSync(outputFd);
      if (copyCompleted && platform === 'linux') {
        const completed = regular(output,uid);
        if (completed.size !== before.size || completed.blocks * 512 < reservedBytes
          || completed.blocks * 512 > reservedBytes + 1024**2) fail('guru_copy_allocation_not_retained');
      }
    }
  }
}

// Public for isolated fixture tests. The production entry below supplies fixed
// paths/root ownership and verifies the live EB environment before staging.
export async function stageGuruDeltaRelease(p,{releaseRoot=defaultRoot,uid=process.getuid(),space=()=>freeDisk(releaseRoot),
  maxBytesPerSecond=rate,fetchFile=fetch,progress=()=>{}}={}) {
  const directory = validateGuruReleaseInstall(p,releaseRoot); directorySafe(releaseRoot,uid);
  const base = readBase(p,releaseRoot,uid), unlock = acquireInstallLock(directory,{uid});
  try {
    const manifestPath = path.join(directory,'manifest.json');
    if (fs.existsSync(manifestPath)) {
      directorySafe(directory,uid,{immutable:true}); regular(manifestPath,uid,{immutable:true});
      if (fs.statSync(manifestPath).size > 65536) fail('guru_completed_manifest_too_large');
      const m = JSON.parse(fs.readFileSync(manifestPath,'utf8'));
      if (m.version !== INVESTMENT_REUSED_RELEASE_VERSION || m.delta?.contractSha256 !== contractSha(p.patch)
        || m.delta.sha256 !== p.delta.sha256 || m.files?.research?.sha256 !== p.research.sha256
        || m.files.research.bytes !== p.research.bytes || m.reuse?.baseManifestSha256 !== p.baseManifest.sha256) fail('guru_completed_contract_mismatch');
      validateInvestmentRelease(m,{releaseId:p.releaseId,...Object.fromEntries(['research','strategy','composition'].map(k => [k,m.files[k].path]))},
        {manifestPath,trustedUid:uid});
      if (fs.readdirSync(directory).sort().join(',') !== 'delta.sqlite,manifest.json,research.sqlite') fail('guru_completed_unexpected_file');
      regular(path.join(directory,'delta.sqlite'),uid,{immutable:true});
      return {status:'already_verified',manifest:m,additionalDiskBytes:0};
    }
    // Never silently delete/recreate a partial candidate after a failed run.
    // It cannot be activated without its immutable completion manifest.
    if (fs.existsSync(directory)) fail('guru_partial_release_requires_operator_review');
    const projection = guruDeltaDiskProjection(p,space()); progress({phase:'disk_preflight',...projection});
    if (!projection.ready) fail('insufficient_disk_headroom_for_guru_revision');
    fs.mkdirSync(directory,{mode:0o700});
    await installPublicFile(directory,'delta',p.delta,{fetchFile,maxBytesPerSecond,progress});
    const candidate = path.join(directory,'research.sqlite.part');
    const copied = await copyGuruReleaseFile(base.files.research.path,{output:candidate,uid,maxBytesPerSecond,space,progress,
      allocationBytes:Math.max(p.patch.baseResearch.bytes,p.research.bytes)});
    if (copied.bytes !== p.patch.baseResearch.bytes || copied.sha256 !== p.patch.baseResearch.sha256) fail('guru_base_research_sha_mismatch');
    const beforePatch = space();
    if (beforePatch - projection.journalReserveBytes - projection.operationalReserveBytes < minimumReleaseHeadroomBytes) fail('guru_patch_disk_headroom_exhausted');
    progress({phase:'apply_guru_rows'});
    const applied = applyGuruDelta(candidate,path.join(directory,'delta.sqlite'),p.patch);
    const actual = await copyGuruReleaseFile(candidate,{uid,maxBytesPerSecond,progress});
    if (actual.bytes !== p.research.bytes || actual.sha256 !== p.research.sha256) fail('guru_result_sha_mismatch');
    checkDownloadedSchema(candidate,p.research,'research');
    if (space() < minimumReleaseHeadroomBytes) fail('guru_final_disk_headroom_exhausted');
    const fd = fs.openSync(candidate,'r'); try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.chmodSync(candidate,0o444);
    const research = path.join(directory,'research.sqlite'); fs.linkSync(candidate,research); fs.unlinkSync(candidate);
    const manifest = {version:INVESTMENT_REUSED_RELEASE_VERSION,releaseId:p.releaseId,state:'verified',cutoff:p.cutoff,
      installedAt:new Date().toISOString(),rollbackSnapshot:p.rollbackSnapshot,
      checks:{integrity:'ok',schema:'pass',sourceAlignment:'pass',privateDataExcluded:true},
      validationBasis:'exact_guru_rows_no_other_writes_plus_producer_integrity_and_host_sha256',
      files:{research:{path:research,bytes:actual.bytes,sha256:actual.sha256,producerValidation:p.research.producerValidation,
        hostValidation:{sha256:'matched',schema:'pass',journalMode:'delete'}},strategy:base.files.strategy,composition:base.files.composition},
      reuse:{baseManifestPath:p.baseManifest.path,baseManifestSha256:p.baseManifest.sha256,baseReleaseId:base.releaseId,
        files:Object.fromEntries(['strategy','composition'].map(k => { const s = regular(base.files[k].path,uid,{immutable:true}); return [k,{device:s.dev,inode:s.ino}]; }))},
      delta:{sha256:p.delta.sha256,bytes:p.delta.bytes,contractSha256:contractSha(p.patch),baseResearchSha256:p.patch.baseResearch.sha256,
        applied,sourceErrorsPreserved:true}};
    const manifestBytes = Buffer.from(JSON.stringify(manifest,null,2)); if (manifestBytes.length > 65536) fail('guru_manifest_size_exceeded');
    const handle = fs.openSync(manifestPath,'wx',0o444);
    try { fs.writeFileSync(handle,manifestBytes); fs.fsyncSync(handle); } finally { fs.closeSync(handle); }
    const directoryHandle = fs.openSync(directory,'r');
    try { fs.fsyncSync(directoryHandle); } finally { fs.closeSync(directoryHandle); }
    fs.chmodSync(directory,0o555);
    validateInvestmentRelease(manifest,{releaseId:p.releaseId,research,strategy:base.files.strategy.path,composition:base.files.composition.path},
      {manifestPath,trustedUid:uid});
    return {status:'verified',manifest,additionalDiskBytes:actual.bytes + p.delta.bytes,projection};
  } finally { unlock(); }
}

export async function installInvestmentGuruDelta(p) {
  if (process.platform !== 'linux' || process.getuid() !== 0) fail('guru_operator_root_required');
  const env = JSON.parse(execFileSync('/opt/elasticbeanstalk/bin/get-config',['environment'],{encoding:'utf8'}));
  if (env.NODE_ENV !== 'production' || env.SQLITE_DB_PATH !== '/var/app/data/thesisforge.sqlite'
    || ![p.baseManifest?.path,path.join(defaultRoot,p.releaseId,'manifest.json')].includes(env.INVESTMENT_RELEASE_MANIFEST_PATH)) fail('guru_wrong_live_runtime');
  os.setPriority(process.pid,10); execFileSync('/usr/bin/ionice',['-c','3','-p',String(process.pid)]);
  const result = await stageGuruDeltaRelease(p,{progress:item => console.log(JSON.stringify(item))});
  console.log(JSON.stringify({status:result.status,releaseId:p.releaseId,manifest:path.join(defaultRoot,p.releaseId,'manifest.json'),
    additionalDiskBytes:result.additionalDiskBytes,legacyDatabaseChanged:false,privateDatabaseChanged:false}));
  return result;
}
if (typeof rolloutPayload !== 'undefined') await installInvestmentGuruDelta(rolloutPayload);
