import test from 'node:test';import assert from 'node:assert/strict';
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import crypto from 'node:crypto';import {DatabaseSync} from 'node:sqlite';
import {validateInstallPayload,classifyStagedFiles,acquireInstallLock,installPublicFile,releaseDiskProjection,reuseFinalizedRelease,findIdenticalFinalizedRelease,minimumReleaseHeadroomBytes} from './install-investment-release.mjs';
const validation=(sha256,bytes)=>({version:'sqlite-full-validation-v1',sha256,bytes,integrityCheck:'ok',foreignKeyCheck:'ok',schema:'pass',privateDataExcluded:true,verifiedAt:'2026-09-12T12:00:00Z'});
const base=()=>({version:'investment-install-v1',releaseId:'redesign-20260912-v1',cutoff:'2026-09-11',sourceAlignment:'pass',rollbackSnapshot:'snap-123abc',rollbackVerified:true,files:Object.fromEntries(['research','strategy','composition'].map(k=>[k,{bytes:4096,sha256:'a'.repeat(64),tables:['public_prices'],producerValidation:validation('a'.repeat(64),4096),downloadUrl:`https://thesisforge-production-378477120101-us-east-1.s3.amazonaws.com/investment-releases/redesign-20260912-v1/${k}.sqlite?signature=fixture`}]))});
test('installer accepts only new dedicated release identity and exact S3 objects',()=>{assert.equal(validateInstallPayload(base()),'/var/app/data/investment-releases/redesign-20260912-v1');for(const patch of [{releaseId:'../user-portfolios'},{rollbackVerified:false},{sourceAlignment:'unknown'}])assert.throws(()=>validateInstallPayload({...base(),...patch}));});
test('installer refuses private tables, redirected downloads and invalid fingerprints',()=>{for(const patch of [{tables:['portfolio_nav_points']},{tables:['investment_events']},{downloadUrl:'http://example.test/data'},{sha256:'missing'}]){const p=base();Object.assign(p.files.research,patch);assert.throws(()=>validateInstallPayload(p));}});
test('installer accepts the same private bucket regional endpoint but rejects other regions',()=>{const p=base();p.files.research.downloadUrl=p.files.research.downloadUrl.replace('.s3.amazonaws.com','.s3.us-east-1.amazonaws.com');assert.ok(validateInstallPayload(p));p.files.research.downloadUrl=p.files.research.downloadUrl.replace('.us-east-1.','.us-west-2.');assert.throws(()=>validateInstallPayload(p));});

test('resume and transferred integrity require exact producer proof, not an unbound success flag',()=>{
 const p=base();p.resume=true;assert.throws(()=>validateInstallPayload(p),/previous_installer_pid/);p.previousInstallerPid=1445291;assert.ok(validateInstallPayload(p));
 for(const patch of [{sha256:'b'.repeat(64)},{bytes:8192},{integrityCheck:'unknown'},{foreignKeyCheck:'not_run'},{privateDataExcluded:false},{verifiedAt:'not-a-date'}]){
  const bad=base();Object.assign(bad.files.research.producerValidation,patch);assert.throws(()=>validateInstallPayload(bad),/producer_full_validation/);
 }
 const bad=base();delete bad.files.research.producerValidation;assert.throws(()=>validateInstallPayload(bad));
});

function fixture(t){
 const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'tf-install-resume-')));
 t.after(()=>{for(const name of fs.readdirSync(root)){const p=path.join(root,name);if(fs.lstatSync(p).isDirectory())fs.chmodSync(p,0o700);}fs.rmSync(root,{recursive:true,force:true});});
 const file=path.join(root,'source.sqlite'),db=new DatabaseSync(file);db.exec("CREATE TABLE public_prices(symbol TEXT,close REAL); INSERT INTO public_prices VALUES('EXAMPLE',1.25)");
 assert.equal(db.prepare('PRAGMA integrity_check').get().integrity_check,'ok');assert.equal(db.prepare('PRAGMA foreign_key_check').all().length,0);db.close();
 const bytes=fs.readFileSync(file),sha256=crypto.createHash('sha256').update(bytes).digest('hex'),directory=path.join(root,'release');fs.mkdirSync(directory,{mode:0o700});
 const contract={bytes:bytes.length,sha256,tables:['public_prices'],downloadUrl:'https://fixture.invalid',producerValidation:validation(sha256,bytes.length)};
 return {root,directory,bytes,contract,file:path.join(directory,'research.sqlite'),partial:path.join(directory,'research.sqlite.part')};
}
const digest=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const response=(bytes,status=200,range)=>new Response(bytes,{status,headers:{'content-length':String(bytes.length),...(range?{'content-range':range}:{})}});

test('new transfer and immutable completed-file resume preserve exact bytes without downloading twice',async t=>{
 const f=fixture(t);let requests=0;
 const first=await installPublicFile(f.directory,'research',f.contract,{fetchFile:async(_url,options)=>{requests++;assert.equal(options.redirect,'error');return response(f.bytes);}});
 assert.equal(first.reused,false);assert.equal(digest(f.file),f.contract.sha256);assert.equal(fs.statSync(f.file).mode&0o777,0o444);assert.equal(fs.existsSync(f.partial),false);
 const second=await installPublicFile(f.directory,'research',f.contract,{fetchFile:async()=>{requests++;throw Error('must not redownload');}});
 assert.equal(second.reused,true);assert.equal(requests,1);assert.equal(digest(f.file),f.contract.sha256);
});

test('exact Range append resumes existing bytes, including a complete or empty partial',async t=>{
 for(const offset of [0,1234,8192]) {
  const f=fixture(t),start=Math.min(offset,f.bytes.length);fs.writeFileSync(f.partial,f.bytes.subarray(0,start),{mode:0o600});let requested=false;
  const result=await installPublicFile(f.directory,'research',f.contract,{fetchFile:async(_url,options)=>{
   requested=true;assert.deepEqual(options.headers,start?{Range:`bytes=${start}-`}:{});
   return response(f.bytes.subarray(start),start?206:200,start?`bytes ${start}-${f.bytes.length-1}/${f.bytes.length}`:undefined);
  }});
  assert.equal(result.resumedBytes,start);assert.equal(requested,start<f.bytes.length);assert.equal(digest(f.file),f.contract.sha256);
 }
});

test('incorrect resume response or bytes never overwrite a partial or publish a final',async t=>{
 const f=fixture(t);fs.writeFileSync(f.partial,f.bytes.subarray(0,100),{mode:0o600});const before=digest(f.partial);
 await assert.rejects(installPublicFile(f.directory,'research',f.contract,{fetchFile:async()=>response(f.bytes)}),/metadata_mismatch/);
 assert.equal(digest(f.partial),before);assert.equal(fs.existsSync(f.file),false);
 const tail=Buffer.from(f.bytes.subarray(100));tail[tail.length-1]^=1;
 await assert.rejects(installPublicFile(f.directory,'research',f.contract,{fetchFile:async()=>response(tail,206,`bytes 100-${f.bytes.length-1}/${f.bytes.length}`)}),/release_sha_mismatch/);
 assert.deepEqual(fs.readFileSync(f.partial).subarray(0,100),f.bytes.subarray(0,100));assert.equal(fs.existsSync(f.file),false);
});

test('lock, unexpected entries, finalized releases and alias files fail closed',t=>{
 const f=fixture(t),files=Object.fromEntries(['research','strategy','composition'].map(k=>[k,f.contract]));
 const unlock=acquireInstallLock(f.directory);assert.throws(()=>acquireInstallLock(f.directory),/lock_exists/);unlock();
 fs.writeFileSync(path.join(f.directory,'unexpected'),'',{mode:0o600});assert.throws(()=>classifyStagedFiles(f.directory,files),/unexpected_release_entry/);fs.unlinkSync(path.join(f.directory,'unexpected'));
 fs.symlinkSync(path.join(f.root,'source.sqlite'),f.file);assert.throws(()=>classifyStagedFiles(f.directory,files),/unsafe_staged_file/);fs.unlinkSync(f.file);
 fs.writeFileSync(path.join(f.directory,'manifest.json'),'{}',{mode:0o444});assert.throws(()=>classifyStagedFiles(f.directory,files),/already_finalized/);
});

test('completed file mismatch is not repaired or overwritten',async t=>{
 const f=fixture(t);fs.writeFileSync(f.file,f.bytes,{mode:0o444});const before=digest(f.file);
 await assert.rejects(installPublicFile(f.directory,'research',{...f.contract,sha256:'b'.repeat(64)}),/completed_file_sha_mismatch/);
 assert.equal(digest(f.file),before);
 await assert.rejects(installPublicFile(f.directory,'research',{...f.contract,tables:['other']}),/table_allowlist_mismatch/);
 assert.equal(digest(f.file),before);
});

test('disk projection budgets only missing bytes and enforces 10 GiB final headroom',()=>{
 const files={research:{bytes:2952052736},strategy:{bytes:4905816064},composition:{bytes:543330304}};
 const states={research:{state:'completed',bytes:2952052736},strategy:{state:'missing',bytes:0},composition:{state:'missing',bytes:0}};
 const before=releaseDiskProjection(files,states,14901981184);
 assert.equal(before.additionalBytes,5449146368);assert.equal(before.projectedFreeBytes,9452834816);assert.equal(before.ready,false);
 const after=releaseDiskProjection(files,states,14901981184+2739396608);
 assert.equal(after.ready,true);assert.equal(after.minimumHeadroomBytes,minimumReleaseHeadroomBytes);
 const partial=releaseDiskProjection(files,{...states,strategy:{bytes:1024}},14901981184);
 assert.equal(partial.additionalBytes,before.additionalBytes-1024);
});

function finalized(t){
 const f=fixture(t),p=base(),directory=path.join(f.root,p.releaseId);fs.mkdirSync(directory,{mode:0o700});const files={};
 for(const key of ['research','strategy','composition']){
  const file=path.join(directory,`${key}.sqlite`);fs.writeFileSync(file,f.bytes,{mode:0o444});
  p.files[key]={...p.files[key],...f.contract};files[key]={path:file,bytes:f.bytes.length,sha256:f.contract.sha256};
 }
 const manifest={version:'investment-runtime-release-v1',releaseId:p.releaseId,state:'verified',cutoff:p.cutoff,
  checks:{integrity:'ok',schema:'pass',sourceAlignment:'pass',privateDataExcluded:true},files};
 fs.writeFileSync(path.join(directory,'manifest.json'),JSON.stringify(manifest),{mode:0o444});fs.chmodSync(directory,0o555);
 return {...f,p,directory,manifest};
}

test('identical finalized release is idempotent without copies or manifest updates',t=>{
 const f=finalized(t),before=fs.readdirSync(f.directory).map(name=>[name,digest(path.join(f.directory,name))]);
 assert.deepEqual(reuseFinalizedRelease(f.directory,f.p),f.manifest);
 assert.deepEqual(fs.readdirSync(f.directory).map(name=>[name,digest(path.join(f.directory,name))]),before);
 const bad=structuredClone(f.p);bad.files.research.sha256='b'.repeat(64);
 assert.throws(()=>reuseFinalizedRelease(f.directory,bad),/completed_file_contract_mismatch/);
 const newId={...f.p,releaseId:'redesign-20260912-v2'};
 assert.equal(findIdenticalFinalizedRelease(f.root,newId).releaseId,f.p.releaseId);
 assert.equal(fs.existsSync(path.join(f.root,newId.releaseId)),false);
});

test('finalized reuse rejects extra entries or writable ownership boundaries',t=>{
 const f=finalized(t);fs.chmodSync(f.directory,0o700);
 assert.throws(()=>reuseFinalizedRelease(f.directory,f.p),/unsafe_completed_release_directory/);
 fs.writeFileSync(path.join(f.directory,'private.sqlite'),'',{mode:0o600});fs.chmodSync(f.directory,0o555);
 assert.throws(()=>reuseFinalizedRelease(f.directory,f.p),/unexpected_completed_release_entry/);
});
