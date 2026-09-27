import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {validateEncryptedExport,privateBackupOutput,matchingTemporaryIngressRules,requireLegacyUserBackupPaths,verifyRestoredCredentialEnvelopes,resolveBackupInstance} from './backup-aws-user-data.mjs';
test('backup follows the current production environment, not a retired instance',()=>{
  const environment={ApplicationName:'thesisforge-api',EnvironmentName:'thesisforge-api-prod',Status:'Ready'};
  const resources={Instances:[{Id:'i-0eabc67533fb38fca'}]};
  assert.equal(resolveBackupInstance(environment,resources),'i-0eabc67533fb38fca');
  for(const env of [{...environment,ApplicationName:'other'},{...environment,EnvironmentName:'staging'},{...environment,Status:'Updating'}])
    assert.throws(()=>resolveBackupInstance(env,resources));
  for(const instances of [[],[{Id:'i-123'},{Id:'i-456'}],[{Id:'invalid'}]])
    assert.throws(()=>resolveBackupInstance(environment,{Instances:instances}));
});
const cipher=Buffer.alloc(64,7).toString('base64');
const valid=()=>({generation:'2db3cf31-5594-4fa2-bbd2-9aed49bf4cde',databases:1,
  objects:[{name:'db-00001.enc',base64:cipher},{name:'manifest.enc',base64:cipher}],recovery:cipher});
test('real-user export accepts only bounded encrypted database envelopes',()=>assert.equal(validateEncryptedExport(valid()),192));
test('export rejects traversal, duplicate objects, missing manifest and invalid ciphertext',()=>{
  for(const mutate of [
    v=>v.objects[0].name='../key',v=>v.objects[0].name='manifest.enc',
    v=>v.objects[1].name='db-00002.enc',v=>v.objects[0].base64='not cipher',
    v=>v.recovery='',v=>v.databases=2,v=>v.generation='../../outside'
  ]){const v=valid();mutate(v);assert.throws(()=>validateEncryptedExport(v));}
});
test('operator backup contract keeps recovery secret separate and never restores live',()=>{
  const source=fs.readFileSync(new URL('./backup-aws-user-data.mjs',import.meta.url),'utf8');
  assert.match(source,/--backup-real-users/);
  assert.match(source,/--if-none-match','\*'/);
  assert.match(source,/CidrIp:ip\+'\/32'/);
  assert.match(source,/revoke-security-group-ingress/);
  assert.match(source,/ingressRequested=true/);
  assert.match(source,/describe-security-group-rules/);
  assert.match(source,/StrictHostKeyChecking=yes/);
  assert.match(source,/output:path\.join\(output,'restored'\)/);
  assert.match(source,/productionDatabasesWritten:false/);
  assert.doesNotMatch(source,/put-object[^\n]*recovery-key/);
  assert.doesNotMatch(source,/update-environment|update-application|stop-service|systemctl.*restart/);
});
test('output must resolve outside repository even through a parent symlink',t=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tf-backup-scope-test-'));
  t.after(()=>fs.rmSync(temp,{recursive:true,force:true}));
  const repo=path.join(temp,'repo');fs.mkdirSync(repo);
  fs.symlinkSync(repo,path.join(temp,'alias'));
  assert.throws(()=>privateBackupOutput(path.join(temp,'alias','recovery'),repo));
  assert.throws(()=>privateBackupOutput(path.join(repo,'recovery'),repo));
  assert.throws(()=>privateBackupOutput(path.join(temp,'repo'),repo));
  assert.throws(()=>privateBackupOutput('/new-unsafe-root-backup',repo));
  assert.equal(privateBackupOutput(path.join(temp,'safe-recovery'),repo),path.join(fs.realpathSync(temp),'safe-recovery'));
});
test('unsupported USER_DATA_ROOT fails closed instead of backing up the wrong directory',()=>{
  assert.doesNotThrow(()=>requireLegacyUserBackupPaths({USER_PORTFOLIO_DATA_DIR:'/var/app/data/user-portfolios'}));
  assert.throws(()=>requireLegacyUserBackupPaths({USER_DATA_ROOT:'/var/app/data/private-users'}));
});
test('uncertain SSH creation cleanup selects only exact operation/group/address TCP22 ingress',()=>{
  const identity={group:'sg-1234',ip:'192.0.2.1',description:'ThesisForge portfolio backup '+crypto.randomUUID()};
  const exact={GroupId:identity.group,IsEgress:false,IpProtocol:'tcp',FromPort:22,ToPort:22,CidrIpv4:identity.ip+'/32',Description:identity.description,SecurityGroupRuleId:'sgr-a123'};
  const other=[
    {...exact,Description:'another-operation'}, {...exact,GroupId:'sg-5678'},
    {...exact,CidrIpv4:'0.0.0.0/0'}, {...exact,IsEgress:true}, {...exact,ToPort:23},
    {...exact,FromPort:21}, {...exact,IpProtocol:'-1'}, {...exact,SecurityGroupRuleId:'unsafe'}
  ];
  assert.deepEqual(matchingTemporaryIngressRules([exact,...other],identity),['sgr-a123']);
  assert.deepEqual(matchingTemporaryIngressRules(other,identity),[]);
  assert.deepEqual(matchingTemporaryIngressRules(undefined,identity),[]);
});
test('isolated restored credentials and reports decrypt with original key and owner AAD',t=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tf-backup-decrypt-test-'));
  t.after(()=>fs.rmSync(temp,{recursive:true,force:true}));
  const hash='a'.repeat(40),directory=path.join(temp,'portfolios',hash);fs.mkdirSync(directory,{recursive:true});
  const key='synthetic-key-never-exported',db=new DatabaseSync(path.join(directory,'portfolio.sqlite'));
  const seal=(aad)=>{
    const iv=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',crypto.createHash('sha256').update(key).digest(),iv);
    cipher.setAAD(Buffer.from(aad));
    const ciphertext=Buffer.concat([cipher.update(JSON.stringify({synthetic:true})),cipher.final()]);
    return [iv,cipher.getAuthTag(),ciphertext].map(b=>b.toString('base64url')).join('.');
  };
  for(const table of ['portfolio_connections','portfolio_connection_recovery','portfolio_report_snapshots']) {
    db.exec(`CREATE TABLE ${table}(encrypted_json TEXT NOT NULL)`);
    db.prepare(`INSERT INTO ${table} VALUES (?)`).run(seal(table==='portfolio_report_snapshots'?'thesisforge-portfolio-report-v1:'+hash:'thesisforge-portfolio-connection-v1'));
  }
  db.close();
  assert.deepEqual(verifyRestoredCredentialEnvelopes(temp,key),{connectionEnvelopes:1,recoveryEnvelopes:1,reportEnvelopes:1});
  assert.throws(()=>verifyRestoredCredentialEnvelopes(temp,'wrong-key'));
  fs.renameSync(directory,path.join(temp,'portfolios','b'.repeat(40)));
  assert.throws(()=>verifyRestoredCredentialEnvelopes(temp,key));
});
