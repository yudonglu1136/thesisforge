import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {validatePrimeOptions,verifyPrimeRelease,capturePortfolioPreservationState,verifyPortfolioPreservation} from './prime-aws-user-portfolios.mjs';

const options={expectedRelease:'owner-release-fixture',expectedConnected:2,expectedUsers:17,expectedDatabases:14};
test('explicit release, observed users and tenant database counts are distinct guards',()=>{
  assert.doesNotThrow(()=>validatePrimeOptions(options));
  for(const mutate of [v=>v.expectedRelease='',v=>v.expectedRelease='unsafe; command',v=>v.expectedConnected=0,
    v=>v.expectedDatabases=undefined,v=>v.expectedUsers=1,v=>v.expectedDatabases=18]){
    const v={...options};mutate(v);assert.throws(()=>validatePrimeOptions(v));
  }
});
test('only the exact Ready/Green release and original single instance may be primed',()=>{
  const env={EnvironmentName:'thesisforge-api-prod',VersionLabel:'owner-release-fixture',Status:'Ready',Health:'Green'};
  const resources={Instances:[{Id:'i-0896b2f2f421b847b'}]};
  assert.doesNotThrow(()=>verifyPrimeRelease(env,resources,options.expectedRelease));
  for(const mutate of [e=>e.VersionLabel='old',e=>e.Status='Updating',e=>e.Health='Yellow',e=>e.EnvironmentName='different']){
    const e={...env};mutate(e);assert.throws(()=>verifyPrimeRelease(e,resources,options.expectedRelease));
  }
  assert.throws(()=>verifyPrimeRelease(env,{Instances:[{Id:'other'}]},options.expectedRelease));
});
const synthetic=t=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tf-prime-preservation-test-'));
  t.after(()=>fs.rmSync(temp,{recursive:true,force:true}));
  const h='a'.repeat(40),directory=path.join(temp,h);fs.mkdirSync(directory);
  const registry=path.join(temp,'portfolio-admin.sqlite');
  const registryDb=new DatabaseSync(registry);
  registryDb.exec('CREATE TABLE portfolio_user_registry(user_hash TEXT PRIMARY KEY,user_id TEXT)');
  registryDb.prepare('INSERT INTO portfolio_user_registry VALUES (?,?)').run(h,'synthetic-owner');registryDb.close();
  const file=path.join(directory,'portfolio.sqlite'),db=new DatabaseSync(file);
  db.exec("CREATE TABLE portfolio_connections(provider TEXT,encrypted_json TEXT,created_at TEXT,status TEXT); INSERT INTO portfolio_connections VALUES ('ibkr_flex','original-ciphertext','2026-01-01','linked'); CREATE TABLE portfolio_nav_points(account_id TEXT,date TEXT,nav REAL,updated_at TEXT); INSERT INTO portfolio_nav_points VALUES ('private-account','2026-09-09',1234,'original-time'); CREATE TABLE portfolio_report_snapshots(provider TEXT,connection_revision TEXT,report_date TEXT)");
  db.close();return {locations:{portfolios:temp,registry},file,registry};
};
test('read-only evidence permits appended reports and sync status changes without exposing values',t=>{
  const f=synthetic(t),before=capturePortfolioPreservationState(f.locations),db=new DatabaseSync(f.file);
  db.exec("INSERT INTO portfolio_report_snapshots VALUES ('ibkr_flex','rev','2026-09-09'); UPDATE portfolio_connections SET status='configured'");db.close();
  const receipt=verifyPortfolioPreservation(before,capturePortfolioPreservationState(f.locations));
  assert.equal(receipt.originalNavRowsPreserved,1);assert.equal(receipt.connectionCiphertextsPreserved,1);assert.equal(receipt.newReportRows,1);
  assert.ok(!JSON.stringify(receipt).includes('private-account'));assert.ok(!JSON.stringify(receipt).includes('1234'));
});
test('changing owner identity, credential ciphertext, NAV values or NAV timestamps fails preservation',t=>{
  const f=synthetic(t),before=capturePortfolioPreservationState(f.locations);
  for(const sql of ["UPDATE portfolio_connections SET encrypted_json='changed'","UPDATE portfolio_nav_points SET nav=999",
    "UPDATE portfolio_nav_points SET updated_at='changed'","DELETE FROM portfolio_nav_points"]){
    const db=new DatabaseSync(f.file);db.exec('BEGIN');db.exec(sql);
    // Reads on a separate connection see only committed data, so test capture
    // the change, restore explicitly in this synthetic fixture, then continue.
    db.exec('COMMIT');assert.throws(()=>verifyPortfolioPreservation(before,capturePortfolioPreservationState(f.locations)));
    db.exec("UPDATE portfolio_connections SET encrypted_json='original-ciphertext';DELETE FROM portfolio_nav_points;INSERT INTO portfolio_nav_points VALUES ('private-account','2026-09-09',1234,'original-time')");db.close();
  }
  const reg=new DatabaseSync(f.registry);reg.exec("UPDATE portfolio_user_registry SET user_id='other-owner'");reg.close();
  assert.throws(()=>verifyPortfolioPreservation(before,capturePortfolioPreservationState(f.locations)),/owner_records_changed/);
});
test('operator transport pins host keys, restricts ingress, drops identity, and cannot deploy or wipe',()=>{
  const source=fs.readFileSync(new URL('./prime-aws-user-portfolios.mjs',import.meta.url),'utf8');
  assert.match(source,/matchingTemporaryIngressRules/);assert.match(source,/ingressRequested=true/);
  assert.match(source,/CidrIp:ip\+'\/32'/);assert.match(source,/StrictHostKeyChecking=yes/);
  assert.match(source,/get-console-output/);assert.match(source,/revoke-security-group-ingress/);
  assert.match(source,/if\(findRules\(\)\.length\)/);assert.match(source,/process\.setgroups\(\[\]\)/);
  assert.match(source,/process\.setuid\(uid\)/);assert.match(source,/cwd:current,env,/);
  assert.match(source,/deployed_runtime_mismatch/);assert.match(source,/configuration\(release\(\)\)!==initialConfiguration/);
  assert.doesNotMatch(source,/update-environment|update-application|restoreUserData\(|INSERT INTO|UPDATE portfolio_|DELETE FROM|DROP TABLE|systemctl.*restart/);
});
