import test from 'node:test';
import a from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { enabledManager13fGurus } from './gurus.js';
import { validateInvestmentRelease } from './investmentRuntimeConfig.js';
import { applyGuruDelta, guruDeltaRowSha256, guruDeltaTables, newGuruIds, validateGuruDeltaContract } from '../scripts/investment-guru-delta.mjs';
import { stageGuruDeltaRelease, validateGuruReleaseInstall, guruDeltaDiskProjection, copyGuruReleaseFile } from '../scripts/install-investment-guru-delta.mjs';

const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const info = file => ({bytes:fs.statSync(file).size,sha256:hash(file)});
function schema(db) {
  db.exec(`CREATE TABLE guru_snapshots(guru_id TEXT PRIMARY KEY,cik TEXT,type TEXT,generated_at TEXT NOT NULL,payload_json TEXT NOT NULL);
    CREATE TABLE guru_exposure_snapshots(guru_id TEXT PRIMARY KEY,generated_at TEXT NOT NULL,payload_json TEXT NOT NULL);
    CREATE TABLE guru_backtests(guru_id TEXT NOT NULL,years INTEGER NOT NULL,generated_at TEXT NOT NULL,start_date TEXT,end_date TEXT,payload_json TEXT NOT NULL,PRIMARY KEY(guru_id,years));
    CREATE TABLE guru_backtest_proxies(guru_id TEXT NOT NULL,years INTEGER NOT NULL,generated_at TEXT NOT NULL,start_date TEXT,end_date TEXT,method_version TEXT NOT NULL,payload_json TEXT NOT NULL,PRIMARY KEY(guru_id,years));`);
}
function insert(db,table,row) {
  const columns = guruDeltaTables[table];
  db.prepare(`INSERT INTO ${table}(${columns.join(',')}) VALUES(${columns.map(() => '?').join(',')})`).run(...columns.map(c => row[c]));
}
function row(table,id,years,version='new') {
  const guru = enabledManager13fGurus.find(g => g.id === id), generatedAt = version === 'new' ? '2026-09-13T00:00:00Z' : '2026-09-11T00:00:00Z';
  const payload = table === 'guru_snapshots' ? {id,cik:guru.cik,type:'manager13f',generatedAt}
    : {guru:{id},method:{years:String(years)},generatedAt,status:id === 'john-stamas' ? 'insufficient_data' : 'fixture',equityCurve:[]};
  return {guru_id:id,cik:guru.cik,type:'manager13f',years,generated_at:generatedAt,start_date:'2021-09-11',end_date:'2026-09-11',method_version:'fixture',payload_json:JSON.stringify(payload)};
}
function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'tf-guru-delta-')));
  t.after(() => { for (const directory of [path.join(root,'redesign-20260912-v1'),path.join(root,'guru-sync-20260913-v1')])
    if (fs.existsSync(directory)) fs.chmodSync(directory,0o700); fs.rmSync(root,{recursive:true,force:true}); });
  const baseDirectory = path.join(root,'redesign-20260912-v1'); fs.mkdirSync(baseDirectory);
  const baseFile = path.join(baseDirectory,'research.sqlite'), deltaFile = path.join(root,'delta.sqlite');
  const baseDb = new DatabaseSync(baseFile), deltaDb = new DatabaseSync(deltaFile); schema(baseDb); schema(deltaDb);
  baseDb.exec("CREATE TABLE price_points(symbol TEXT PRIMARY KEY,close REAL); INSERT INTO price_points VALUES('UNTOUCHED',123.45); CREATE TABLE valuation_snapshots(id TEXT PRIMARY KEY,payload_json TEXT); INSERT INTO valuation_snapshots VALUES('UNTOUCHED','{\"cash\":123}');");
  const scope = {snapshotGuruIds:[...newGuruIds],cacheGuruIds:enabledManager13fGurus.map(g => g.id),years:[5,10]}, tables = {};
  for (const [table,columns] of Object.entries(guruDeltaTables)) {
    const caches = table.startsWith('guru_backtest'), keys = caches ? scope.cacheGuruIds.flatMap(id => [5,10].map(years => [id,years])) : newGuruIds.map(id => [id]);
    tables[table] = {columns,operations:[]};
    if (!caches) insert(baseDb,table,row(table,'bill-ackman',undefined,'old'));
    for (const [id,years] of keys) {
      const before = caches ? row(table,id,years,'old') : null;
      const after = table === 'guru_backtest_proxies' && id !== 'evan-mcgoff' ? null : row(table,id,years);
      if (before) insert(baseDb,table,before); if (after) insert(deltaDb,table,after);
      tables[table].operations.push({key:caches?[id,years]:[id],beforeSha256:guruDeltaRowSha256(table,before),afterSha256:guruDeltaRowSha256(table,after)});
    }
  }
  baseDb.close(); deltaDb.close();
  const contract = {version:'investment-guru-delta-v1',baseResearch:info(baseFile),scope,tables};
  const candidate = path.join(root,'candidate.sqlite'); fs.copyFileSync(baseFile,candidate); fs.chmodSync(candidate,0o600);
  const base = {version:'investment-runtime-release-v1',releaseId:'redesign-20260912-v1',state:'verified',cutoff:'2026-09-11',
    checks:{integrity:'ok',schema:'pass',sourceAlignment:'pass',privateDataExcluded:true},files:{research:{path:baseFile,...info(baseFile)}}};
  for (const key of ['strategy','composition']) { const file = path.join(baseDirectory,`${key}.sqlite`); const db = new DatabaseSync(file); db.exec('CREATE TABLE fixture(id TEXT)'); db.close(); base.files[key] = {path:file,...info(file)}; }
  for (const item of Object.values(base.files)) fs.chmodSync(item.path,0o444);
  const manifestPath = path.join(baseDirectory,'manifest.json'); fs.writeFileSync(manifestPath,JSON.stringify(base),{mode:0o444}); fs.chmodSync(baseDirectory,0o555);
  return {root,baseDirectory,baseFile,deltaFile,candidate,contract,base,manifestPath};
}
function installPayload(f) {
  applyGuruDelta(f.candidate,f.deltaFile,f.contract);
  const result = info(f.candidate), releaseId = 'guru-sync-20260913-v1';
  const tables = [...Object.keys(guruDeltaTables),'price_points','valuation_snapshots'];
  return {version:'investment-guru-install-v1',releaseId,cutoff:'2026-09-11',sourceAlignment:'pass',rollbackVerified:true,rollbackSnapshot:'snap-123abc',
    measuredJournalBytes:64*1024,baseManifest:{path:f.manifestPath,releaseId:f.base.releaseId,sha256:hash(f.manifestPath)},patch:f.contract,
    delta:{...info(f.deltaFile),tables:Object.keys(guruDeltaTables),downloadUrl:`https://thesisforge-production-378477120101-us-east-1.s3.amazonaws.com/investment-releases/${releaseId}/delta.sqlite`},
    research:{...result,tables,producerValidation:{version:'sqlite-full-validation-v1',...result,integrityCheck:'ok',foreignKeyCheck:'ok',schema:'pass',privateDataExcluded:true,
      nonGuruTablesUnchanged:true,nonTargetGuruRowsUnchanged:true,baseResearchSha256:f.contract.baseResearch.sha256,verifiedAt:'2026-09-13T00:00:00Z'}}};
}
const installOptions = f => ({releaseRoot:f.root,space:()=>20*1024**3,maxBytesPerSecond:Infinity,
  fetchFile:async () => new Response(fs.readFileSync(f.deltaFile),{status:200,headers:{'content-length':String(fs.statSync(f.deltaFile).size)}})});

test('bounded copy allocates an exclusive exact-length target before copying inside its fixed EOF',async t => {
  const f = fixture(t), output = path.join(f.root,'allocated-copy.sqlite'), sourceHash = hash(f.baseFile), sourceSize = fs.statSync(f.baseFile).size;
  let allocations = 0; const sizes = [], events = [];
  const result = await copyGuruReleaseFile(f.baseFile,{output,platform:'linux',maxBytesPerSecond:Infinity,
    space:() => { if (fs.existsSync(output)) sizes.push(fs.statSync(output).size); return 20*1024**3; },
    allocate:({file,fd,bytes,platform}) => {
      allocations++; a.equal(platform,'linux'); a.equal(file,output); a.equal(fs.fstatSync(fd).size,0); a.equal(bytes,sourceSize);
      // Deterministic fixture for real allocated extents; Linux production uses
      // fallocate, not this write and not a sparse ftruncate fallback.
      fs.writeFileSync(fd,Buffer.alloc(bytes,0x7e));
    },progress:event => events.push(event)});
  a.equal(allocations,1); a.ok(sizes.length > 1); a.ok(sizes.every(size => size === sourceSize));
  a.equal(events[0].phase,'allocated_copy'); a.ok(events[0].allocatedBytes >= sourceSize);
  a.equal(result.sha256,sourceHash); a.equal(hash(output),sourceHash); a.equal(hash(f.baseFile),sourceHash);
  a.equal(fs.statSync(output).nlink,1);
});

test('bounded copy cannot clobber existing files or allocate before passing the unchanged disk floor',async t => {
  const f = fixture(t), output = path.join(f.root,'exclusive-copy.sqlite'); fs.writeFileSync(output,'preserve me');
  let allocations = 0; const allocate = () => allocations++;
  await a.rejects(copyGuruReleaseFile(f.baseFile,{output,allocate,maxBytesPerSecond:Infinity}),/EEXIST/);
  a.equal(fs.readFileSync(output,'utf8'),'preserve me'); a.equal(allocations,0);
  const absent = path.join(f.root,'insufficient-copy.sqlite');
  await a.rejects(copyGuruReleaseFile(f.baseFile,{output:absent,allocate,space:()=>10*1024**3}),/disk_headroom_exhausted/);
  a.equal(fs.existsSync(absent),false); a.equal(allocations,0);
});

test('bounded copy reserves approved SQLite growth while preserving exact source EOF and checksum',async t => {
  const f = fixture(t), output = path.join(f.root,'growth-copy.sqlite'), size = fs.statSync(f.baseFile).size;
  let reservation;
  const result = await copyGuruReleaseFile(f.baseFile,{output,allocationBytes:size+4*1024**2,platform:'darwin',maxBytesPerSecond:Infinity,
    allocate:({fd,bytes,allocationBytes}) => { a.equal(bytes,size); reservation=allocationBytes; fs.ftruncateSync(fd,bytes); }});
  a.equal(reservation,size+4*1024**2); a.equal(fs.statSync(output).size,size); a.equal(result.sha256,hash(f.baseFile));
  const invalid = path.join(f.root,'too-small-copy.sqlite');
  await a.rejects(copyGuruReleaseFile(f.baseFile,{output:invalid,allocationBytes:size-1}),/allocation_size_invalid/);
  a.equal(fs.existsSync(invalid),false);
});

test('Linux copy rejects unsupported, incomplete or excess allocation instead of reverting to append writes',async t => {
  const f = fixture(t); const before = hash(f.baseFile);
  for (const [name,allocate] of [
    ['unsupported',() => { throw Error('allocation_not_supported'); }],
    ['incomplete',({fd,bytes}) => fs.ftruncateSync(fd,bytes)],
    ['excess',({fd,bytes}) => fs.writeFileSync(fd,Buffer.alloc(bytes+2*1024**2,0x7e))]
  ]) {
    const output = path.join(f.root,`${name}-copy.sqlite`);
    await a.rejects(copyGuruReleaseFile(f.baseFile,{output,platform:'linux',allocate,maxBytesPerSecond:Infinity}),/allocation_/);
    a.equal(hash(f.baseFile),before);
  }
});

test('a real drop below the 10 GiB floor after allocation stops before copying source bytes',async t => {
  const f = fixture(t), output = path.join(f.root,'space-loss-copy.sqlite'); let allocated = false;
  await a.rejects(copyGuruReleaseFile(f.baseFile,{output,platform:'linux',maxBytesPerSecond:Infinity,
    space:() => allocated ? 10*1024**3 : 20*1024**3,
    allocate:({fd,bytes}) => { fs.writeFileSync(fd,Buffer.alloc(bytes,0x7e)); allocated=true; }}),/disk_headroom_exhausted/);
  a.ok(fs.readFileSync(output).every(byte => byte === 0x7e));
});

test('exact public Guru delta atomically preserves unrelated data, failed caches, and idempotent file bytes',t => {
  const f = fixture(t), beforeBase = hash(f.baseFile), beforeDelta = hash(f.deltaFile);
  a.equal(validateGuruDeltaContract(f.contract),f.contract);
  const result = applyGuruDelta(f.candidate,f.deltaFile,f.contract); a.equal(result.upserts,74); a.equal(result.deletes,62); a.equal(result.nonTargetWrites,0);
  const db = new DatabaseSync(f.candidate,{readOnly:true});
  a.equal(db.prepare('SELECT close FROM price_points').get().close,123.45);
  a.equal(db.prepare('SELECT payload_json FROM valuation_snapshots').get().payload_json,'{"cash":123}');
  a.equal(db.prepare("SELECT generated_at FROM guru_snapshots WHERE guru_id='bill-ackman'").get().generated_at,'2026-09-11T00:00:00Z');
  a.equal(JSON.parse(db.prepare("SELECT payload_json FROM guru_backtests WHERE guru_id='john-stamas' AND years=5").get().payload_json).status,'insufficient_data');
  db.close(); const after = hash(f.candidate);
  a.equal(applyGuruDelta(f.candidate,f.deltaFile,f.contract).status,'already_applied'); a.equal(hash(f.candidate),after);
  a.equal(hash(f.baseFile),beforeBase); a.equal(hash(f.deltaFile),beforeDelta);
});

test('delta rejects unknown table, incomplete windows, duplicate operations, extra manager, and nonproxy deletions',t => {
  const f = fixture(t);
  for (const mutate of [c => c.tables.price_points=c.tables.guru_backtests,c => c.tables.guru_backtests.operations.pop(),
    c => c.tables.guru_backtests.operations[1]=c.tables.guru_backtests.operations[0],c => c.scope.cacheGuruIds[0]='other-filer',
    c => c.tables.guru_snapshots.operations[0].afterSha256=null]) {
    const c = structuredClone(f.contract); mutate(c); a.throws(() => validateGuruDeltaContract(c));
  }
});

test('late stale-target precondition leaves every row and complete candidate bytes untouched',t => {
  const f = fixture(t), c = structuredClone(f.contract); c.tables.guru_backtest_proxies.operations.at(-1).beforeSha256='f'.repeat(64);
  const before = hash(f.candidate); a.throws(() => applyGuruDelta(f.candidate,f.deltaFile,c),/stale_target/); a.equal(hash(f.candidate),before);
});

test('unlisted delta rows, wrong payload identity, and executable schema never apply',t => {
  const f = fixture(t), before = hash(f.candidate); const db = new DatabaseSync(f.deltaFile);
  insert(db,'guru_snapshots',row('guru_snapshots','bill-ackman')); db.close();
  a.throws(() => applyGuruDelta(f.candidate,f.deltaFile,f.contract),/unlisted_row/); a.equal(hash(f.candidate),before);
  const target = new DatabaseSync(f.candidate); target.exec("CREATE TRIGGER unrelated AFTER INSERT ON guru_snapshots BEGIN UPDATE price_points SET close=0; END"); target.close();
  const triggerBefore = hash(f.candidate); a.throws(() => applyGuruDelta(f.candidate,f.deltaFile,f.contract),/executable_schema/); a.equal(hash(f.candidate),triggerBefore);
});

test('a self-consistent digest cannot authorize a wrong filer or cache payload identity',t => {
  const f = fixture(t), before = hash(f.candidate), c = structuredClone(f.contract);
  const db = new DatabaseSync(f.deltaFile), table = 'guru_snapshots';
  const changed = db.prepare("SELECT * FROM guru_snapshots WHERE guru_id='john-stamas'").get();
  const payload = JSON.parse(changed.payload_json); payload.cik = '0000000001'; changed.payload_json = JSON.stringify(payload);
  db.prepare("UPDATE guru_snapshots SET payload_json=? WHERE guru_id='john-stamas'").run(changed.payload_json); db.close();
  c.tables[table].operations.find(op => op.key[0] === 'john-stamas').afterSha256 = guruDeltaRowSha256(table,changed);
  a.throws(() => applyGuruDelta(f.candidate,f.deltaFile,c),/payload_identity_mismatch/); a.equal(hash(f.candidate),before);
});

test('immutable base files, hard links, and WAL sidecars cannot be patch targets',t => {
  const f = fixture(t); a.throws(() => applyGuruDelta(f.baseFile,f.deltaFile,f.contract),/unsafe_file/);
  const linked = path.join(f.root,'linked.sqlite'); fs.linkSync(f.candidate,linked); a.throws(() => applyGuruDelta(linked,f.deltaFile,f.contract),/unsafe_file/); fs.unlinkSync(linked);
  fs.writeFileSync(`${f.candidate}-wal`,'pending'); a.throws(() => applyGuruDelta(f.candidate,f.deltaFile,f.contract),/unsafe_file/);
});

test('v2 delta publication preserves v1 rollback and reuses the same two immutable files without hard links',async t => {
  const f = fixture(t), p = installPayload(f), baseHashes = Object.fromEntries(Object.entries(f.base.files).map(([key,value]) => [key,hash(value.path)]));
  const first = await stageGuruDeltaRelease(p,installOptions(f)); a.equal(first.status,'verified');
  const m = first.manifest; a.equal(m.files.strategy.path,f.base.files.strategy.path); a.equal(m.files.composition.path,f.base.files.composition.path);
  a.notEqual(fs.statSync(m.files.research.path).ino,fs.statSync(f.baseFile).ino);
  for (const [key,value] of Object.entries(f.base.files)) { a.equal(hash(value.path),baseHashes[key]); a.equal(fs.statSync(value.path).nlink,1); }
  a.equal(fs.existsSync(path.join(f.root,p.releaseId,'strategy.sqlite')),false);
  const paths = {releaseId:p.releaseId,...Object.fromEntries(Object.entries(m.files).map(([key,value]) => [key,value.path]))};
  a.equal(validateInvestmentRelease(m,paths,{manifestPath:path.join(f.root,p.releaseId,'manifest.json'),trustedUid:process.getuid()}),m);
  const originalManifestHash = hash(path.join(f.root,p.releaseId,'manifest.json'));
  const again = await stageGuruDeltaRelease(p,{...installOptions(f),fetchFile:() => { throw Error('must_not_download'); }});
  a.equal(again.status,'already_verified'); a.equal(again.additionalDiskBytes,0); a.equal(hash(path.join(f.root,p.releaseId,'manifest.json')),originalManifestHash);
});

test('reuse pins reject mutated base manifest, inode substitution, wrong role, writable file and unlisted reuse',async t => {
  const f = fixture(t), p = installPayload(f), {manifest:m} = await stageGuruDeltaRelease(p,installOptions(f));
  const paths = {releaseId:p.releaseId,...Object.fromEntries(Object.entries(m.files).map(([key,value]) => [key,value.path]))};
  const options = {manifestPath:path.join(f.root,p.releaseId,'manifest.json'),trustedUid:process.getuid()};
  for (const mutate of [v => v.reuse.baseManifestSha256='f'.repeat(64),v => v.reuse.files.strategy.inode++,
    v => v.reuse.files.research={device:1,inode:2},v => v.files.strategy=v.files.composition,
    v => v.releaseId='arbitrary-release']) {
    const changed = structuredClone(m); mutate(changed); a.throws(() => validateInvestmentRelease(changed,paths,options));
  }
  fs.chmodSync(f.base.files.strategy.path,0o600); a.throws(() => validateInvestmentRelease(m,paths,options),/permissions/); fs.chmodSync(f.base.files.strategy.path,0o444);
  fs.chmodSync(f.baseDirectory,0o700); a.throws(() => validateInvestmentRelease(m,paths,options),/permissions/); fs.chmodSync(f.baseDirectory,0o555);
  const linkDirectory = path.join(f.root,'linked-base'); fs.symlinkSync(f.baseDirectory,linkDirectory);
  const linked = structuredClone(m); linked.reuse.baseManifestPath=path.join(linkDirectory,'manifest.json');
  a.throws(() => validateInvestmentRelease(linked,paths,options),/manifest_invalid/);
});

test('peak disk guard includes actual delta, copied research, measured journal reserve and keeps 10 GiB minimum',async t => {
  const f = fixture(t), p = installPayload(f), projection = guruDeltaDiskProjection(p,14_555_856_896);
  a.ok(projection.ready); a.equal(projection.additionalBytes,p.research.bytes+p.delta.bytes);
  a.ok(projection.journalReserveBytes >= p.measuredJournalBytes);
  a.equal(guruDeltaDiskProjection(p,10*1024**3).ready,false);
  await a.rejects(stageGuruDeltaRelease(p,{...installOptions(f),space:()=>10*1024**3}),/insufficient_disk/);
  a.equal(fs.existsSync(path.join(f.root,p.releaseId)),false);
});

test('wrong result digest is never finalized or activated, and retry cannot overwrite a partial candidate',async t => {
  const f = fixture(t), p = installPayload(f); p.research.sha256='f'.repeat(64); p.research.producerValidation.sha256=p.research.sha256;
  await a.rejects(stageGuruDeltaRelease(p,installOptions(f)),/result_sha_mismatch/);
  a.equal(fs.existsSync(path.join(f.root,p.releaseId,'manifest.json')),false);
  await a.rejects(stageGuruDeltaRelease(p,installOptions(f)),/partial_release_requires_operator_review/);
});

test('operator contract refuses other paths, public objects, no rollback receipt, and unproven non-Guru preservation',t => {
  const f = fixture(t), p = installPayload(f); a.equal(validateGuruReleaseInstall(p,f.root),path.join(f.root,p.releaseId));
  for (const mutate of [v => v.baseManifest.path='/var/app/data/user-portfolios/investment.sqlite',v => v.delta.downloadUrl='https://evil.example/delta.sqlite',
    v => v.rollbackVerified=false,v => v.measuredJournalBytes=0,v => v.research.producerValidation.nonGuruTablesUnchanged=false,
    v => v.research.tables.push('portfolio_nav_points'),v => v.releaseId='../../anything']) {
    const changed = structuredClone(p); mutate(changed); a.throws(() => validateGuruReleaseInstall(changed,f.root));
  }
});
