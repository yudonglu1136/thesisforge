// Explicit operator-only backup. Existing production databases are read, never
// replaced. EIC ingress is /32-scoped and removed in finally. Secrets never go
// in command arguments, source control, logs, or unencrypted S3 objects.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {DatabaseSync} from 'node:sqlite';
import {restoreUserData} from '../server/userDataBackup.js';

const REGION='us-east-1', ACCOUNT='378477120101';
const INSTANCE='i-0896b2f2f421b847b', GROUP='sg-0d7dabbfa4cdc91cc';
const BUCKET='thesisforge-production-378477120101-us-east-1';
const MAX_EXPORT_BYTES=16*1024*1024;
export function privateBackupOutput(destination, repository) {
  if(typeof destination!=='string'||!path.isAbsolute(destination)||fs.existsSync(destination)) throw Error('new_private_output_required');
  const parent=fs.realpathSync(path.dirname(destination));
  if(!fs.statSync(parent).isDirectory()||parent===path.parse(parent).root) throw Error('new_private_output_required');
  const output=path.join(parent,path.basename(destination)),repo=fs.realpathSync(repository);
  if(output===repo||output.startsWith(repo+path.sep)||output===os.homedir()||fs.existsSync(output)) throw Error('recovery_material_must_stay_outside_repository');
  return output;
}
export function matchingTemporaryIngressRules(rules,{group,ip,description}) {
  return (rules||[]).filter(rule=>rule.GroupId===group&&rule.IsEgress===false&&rule.IpProtocol==='tcp'
    &&rule.FromPort===22&&rule.ToPort===22&&rule.CidrIpv4===ip+'/32'&&rule.Description===description
    &&/^sgr-[a-f0-9]+$/.test(rule.SecurityGroupRuleId)).map(rule=>rule.SecurityGroupRuleId);
}
export function requireLegacyUserBackupPaths(env) {
  // Until the remote program shares resolveUserDataPaths, never silently back
  // up a legacy directory when USER_DATA_ROOT points the live app elsewhere.
  if(env.USER_DATA_ROOT)throw Error('user_data_root_requires_shared_path_resolver');
}
export function verifyRestoredCredentialEnvelopes(root,secret) {
  const portfolios=path.join(root,'portfolios');
  if(typeof secret!=='string'||!secret||!fs.statSync(portfolios).isDirectory())throw Error('invalid_restored_credentials');
  const key=crypto.createHash('sha256').update(secret).digest();
  const result={connectionEnvelopes:0,recoveryEnvelopes:0,reportEnvelopes:0};
  for(const entry of fs.readdirSync(portfolios,{withFileTypes:true})) {
    if(!entry.isDirectory()||!/^[a-f0-9]{40}$/.test(entry.name))continue;
    const db=new DatabaseSync(path.join(portfolios,entry.name,'portfolio.sqlite'),{readOnly:true});
    try {
      const tables=new Set(db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r=>r.name));
      for(const [table,count] of [['portfolio_connections','connectionEnvelopes'],['portfolio_connection_recovery','recoveryEnvelopes'],['portfolio_report_snapshots','reportEnvelopes']]) {
        if(!tables.has(table))continue;
        for(const row of db.prepare(`SELECT encrypted_json FROM ${table}`).all()) {
          const parts=String(row.encrypted_json||'').split('.');
          if(parts.length!==3)throw Error('invalid_restored_credentials');
          const [iv,tag,ciphertext]=parts.map(p=>Buffer.from(p,'base64url'));
          if(iv.length!==12||tag.length!==16||!ciphertext.length)throw Error('invalid_restored_credentials');
          const decipher=crypto.createDecipheriv('aes-256-gcm',key,iv);
          decipher.setAAD(Buffer.from(table==='portfolio_report_snapshots'
            ?'thesisforge-portfolio-report-v1:'+entry.name:'thesisforge-portfolio-connection-v1'));
          decipher.setAuthTag(tag);
          const decoded=JSON.parse(Buffer.concat([decipher.update(ciphertext),decipher.final()]));
          if(!decoded||typeof decoded!=='object'||Array.isArray(decoded))throw Error('invalid_restored_credentials');
          result[count]++;
        }
      }
    } finally {db.close();}
  }
  return result;
}
export function validateEncryptedExport(value) {
  if (!value || !/^[a-f0-9-]{36}$/.test(value.generation) || !Array.isArray(value.objects)
    || value.objects.length<2 || value.objects.length>10001 || !Number.isSafeInteger(value.databases)
    || value.databases<1 || value.objects.length!==value.databases+1) throw Error('invalid_export');
  const names=new Set(); let bytes=0;
  for(const object of [...value.objects,{name:'recovery.enc',base64:value.recovery}]) {
    if(!/^(?:manifest|recovery|db-\d{5})\.enc$/.test(object.name) || names.has(object.name)
      || typeof object.base64!=='string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(object.base64)) throw Error('invalid_object');
    const decoded=Buffer.from(object.base64,'base64');
    if(decoded.toString('base64')!==object.base64 || decoded.length<36) throw Error('invalid_ciphertext');
    bytes+=decoded.length; names.add(object.name);
  }
  if(!names.has('manifest.enc') || bytes>MAX_EXPORT_BYTES) throw Error('invalid_export_size');
  return bytes;
}
export async function backupAwsUserData(destination) {
  const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
  const output=privateBackupOutput(destination,repo);
  fs.mkdirSync(output,{mode:0o700});
  const key=crypto.randomBytes(32).toString('hex');
  fs.writeFileSync(path.join(output,'recovery-key.hex'),key+'\n',{flag:'wx',mode:0o600});
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'tf-user-backup-'));fs.chmodSync(scratch,0o700);
  const run=(binary,args,options={})=>execFileSync(binary,args,{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:30000,...options});
  const aws=(...args)=>JSON.parse(run('aws',[...args,'--region',REGION,'--output','json']));
  let rule,operatorIp,ingressRequested=false;
  const ingressDescription='ThesisForge portfolio backup '+crypto.randomUUID();
  const findRules=()=>matchingTemporaryIngressRules(aws('ec2','describe-security-group-rules',
    '--filters','Name=group-id,Values='+GROUP).SecurityGroupRules,
    {group:GROUP,ip:operatorIp,description:ingressDescription});
  try {
    if(aws('sts','get-caller-identity').Account!==ACCOUNT) throw Error('wrong_aws_account');
    const info=aws('ec2','describe-instances','--instance-ids',INSTANCE).Reservations[0].Instances[0];
    if(info.State.Name!=='running'||!info.SecurityGroups.some(g=>g.GroupId===GROUP)) throw Error('target_changed');
    const block=aws('s3api','get-public-access-block','--bucket',BUCKET).PublicAccessBlockConfiguration;
    if(!['BlockPublicAcls','IgnorePublicAcls','BlockPublicPolicy','RestrictPublicBuckets'].every(k=>block[k]===true)) throw Error('bucket_not_private');
    const fingerprints=new Set((aws('ec2','get-console-output','--instance-id',INSTANCE).Output||'').match(/SHA256:[A-Za-z0-9+/=]+/g)||[]);
    if(!fingerprints.size) throw Error('unverified_host');
    const ip=(await(await fetch('https://checkip.amazonaws.com',{signal:AbortSignal.timeout(10000)})).text()).trim();
    if(!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)||ip.split('.').some(n=>Number(n)>255))throw Error('invalid_operator_ip');
    operatorIp=ip;
    run('ssh-keygen',['-q','-t','ed25519','-N','','-f',path.join(scratch,'key')]);
    ingressRequested=true;
    rule=aws('ec2','authorize-security-group-ingress','--group-id',GROUP,'--ip-permissions',JSON.stringify([
      {IpProtocol:'tcp',FromPort:22,ToPort:22,IpRanges:[{CidrIp:ip+'/32',Description:ingressDescription}]}
    ])).SecurityGroupRules?.[0]?.SecurityGroupRuleId;
    if(!rule)throw Error('missing_exact_ingress_rule');
    const keys=run('ssh-keyscan',['-T','10','-t','ed25519,ecdsa',info.PublicIpAddress]);const verified=[];
    for(const line of keys.split('\n').filter(x=>x&&!x.startsWith('#'))) {
      fs.writeFileSync(path.join(scratch,'candidate'),line+'\n',{mode:0o600});
      if(fingerprints.has(run('ssh-keygen',['-lf',path.join(scratch,'candidate'),'-E','sha256']).split(/\s+/)[1])) verified.push(line);
    }
    if(!verified.length)throw Error('host_key_mismatch');
    fs.writeFileSync(path.join(scratch,'known_hosts'),verified.join('\n')+'\n',{mode:0o600});
    if(!aws('ec2-instance-connect','send-ssh-public-key','--instance-id',INSTANCE,'--instance-os-user','ec2-user',
      '--ssh-public-key',fs.readFileSync(path.join(scratch,'key.pub'),'utf8').trim()).Success)throw Error('eic_failed');
    const module=fs.readFileSync(new URL('../server/userDataBackup.js',import.meta.url),'utf8');
    const program=`
      import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';
      import {execFileSync} from 'node:child_process';import {DatabaseSync} from 'node:sqlite';
      const requireLegacyUserBackupPaths=${requireLegacyUserBackupPaths.toString()};
      const verifyRestoredCredentialEnvelopes=${verifyRestoredCredentialEnvelopes.toString()};
      const {backupUserData,restoreUserData}=await import('data:text/javascript;base64,${Buffer.from(module).toString('base64')}');
      const env=JSON.parse(execFileSync('/opt/elasticbeanstalk/bin/get-config',['environment'],{encoding:'utf8'}));
      requireLegacyUserBackupPaths(env);
      const user=execFileSync('systemctl',['show','web.service','--property=User','--value'],{encoding:'utf8'}).trim();
      if(!/^[a-z_][a-z0-9_-]*$/.test(user)||user==='root')throw Error('unverified_app_identity');
      const uid=Number(execFileSync('id',['-u',user],{encoding:'utf8'}));
      const gid=Number(execFileSync('id',['-g',user],{encoding:'utf8'}));
      if(!Number.isInteger(uid)||uid<=0||!Number.isInteger(gid))throw Error('invalid_app_identity');
      process.setgroups([]);process.setgid(gid);process.setuid(uid);
      const research=env.SQLITE_DB_PATH;
      if(!research||!path.isAbsolute(research)||!fs.existsSync(research))throw Error('missing_research_path');
      const portfolios=env.USER_PORTFOLIO_DATA_DIR||path.join(path.dirname(research),'user-portfolios');
      const paths={research,portfolios,registry:path.join(portfolios,'portfolio-admin.sqlite'),
        login:env.LOGIN_ACTIVITY_DB_PATH||path.join(portfolios,'login-activity.sqlite'),investment:env.INVESTMENT_DB_PATH||null};
      const effectiveKey=env.PORTFOLIO_CREDENTIALS_KEY||env.SUPABASE_JWT_SECRET;
      if(!effectiveKey)throw Error('missing_credential_recovery_key');
      const key=${JSON.stringify(key)};
      const temp=fs.mkdtempSync('/var/tmp/thesisforge-user-backup-');fs.chmodSync(temp,0o700);
      try {
        const result=await backupUserData({paths,output:path.join(temp,'encrypted'),key,keyId:'owner-recovery-v1'});
        if(result.bytes>${MAX_EXPORT_BYTES})throw Error('operator_transfer_bound');
        const restored=await restoreUserData({input:path.join(temp,'encrypted'),output:path.join(temp,'restored'),key});
        if(restored.databases!==result.databases)throw Error('restore_mismatch');
        const credentialValidation=verifyRestoredCredentialEnvelopes(path.join(temp,'restored'),effectiveKey);
        const recovery={version:1,paths,credentialKey:effectiveKey,
          credentialKeySource:env.PORTFOLIO_CREDENTIALS_KEY?'PORTFOLIO_CREDENTIALS_KEY':'SUPABASE_JWT_SECRET',
          adminEmails:env.ADMIN_EMAILS||null,supabaseUrl:env.SUPABASE_URL||null,
          note:'Original key bytes and authenticated subject IDs must be preserved. Do not derive ownership from email.'};
        const iv=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',Buffer.from(key,'hex'),iv);
        cipher.setAAD(Buffer.from('thesisforge-user-recovery-v1:'+result.generation));
        const sealed=Buffer.concat([Buffer.from('TFUR0001'),iv,cipher.update(JSON.stringify(recovery)),cipher.final(),cipher.getAuthTag()]);
        const objects=fs.readdirSync(path.join(temp,'encrypted')).map(name=>({name,base64:fs.readFileSync(path.join(temp,'encrypted',name)).toString('base64')}));
        console.log(JSON.stringify({...result,node:process.version,objects,recovery:sealed.toString('base64'),verifiedRemoteRestore:true,credentialValidation}));
      } finally {fs.rmSync(temp,{recursive:true,force:true});}
    `;
    const value=JSON.parse(run('ssh',['-i',path.join(scratch,'key'),'-o','BatchMode=yes','-o','IdentitiesOnly=yes',
      '-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+path.join(scratch,'known_hosts'),'-o','ConnectTimeout=15',
      'ec2-user@'+info.PublicIpAddress,'sudo /bin/bash -lc "node --input-type=module"'],
      {input:program,stdio:['pipe','pipe','pipe'],timeout:120000,maxBuffer:32*1024*1024}));
    validateEncryptedExport(value);
    const exported=path.join(output,'encrypted'),downloaded=path.join(output,'downloaded');
    fs.mkdirSync(exported,{mode:0o700});fs.mkdirSync(downloaded,{mode:0o700});
    const prefix='database-backups/user-data/'+value.generation+'/';
    const objects=[...value.objects.filter(o=>o.name!=='manifest.enc'),{name:'recovery.enc',base64:value.recovery},value.objects.find(o=>o.name==='manifest.enc')];
    for(const object of objects) {
      const file=path.join(exported,object.name);fs.writeFileSync(file,Buffer.from(object.base64,'base64'),{flag:'wx',mode:0o600});
      aws('s3api','put-object','--bucket',BUCKET,'--key',prefix+object.name,'--body',file,'--server-side-encryption','AES256','--if-none-match','*');
      const target=path.join(downloaded,object.name);
      aws('s3api','get-object','--bucket',BUCKET,'--key',prefix+object.name,target);fs.chmodSync(target,0o600);
      if(!fs.readFileSync(file).equals(fs.readFileSync(target)))throw Error('s3_object_mismatch');
    }
    // Key recovery is a separate envelope, never fed to the SQLite manifest.
    const recoveryFile=path.join(downloaded,'recovery.enc'),blob=fs.readFileSync(recoveryFile);
    if(!blob.subarray(0,8).equals(Buffer.from('TFUR0001')))throw Error('invalid_recovery_header');
    const cipher=crypto.createDecipheriv('aes-256-gcm',Buffer.from(key,'hex'),blob.subarray(8,20));
    cipher.setAAD(Buffer.from('thesisforge-user-recovery-v1:'+value.generation));cipher.setAuthTag(blob.subarray(-16));
    const recovery=JSON.parse(Buffer.concat([cipher.update(blob.subarray(20,-16)),cipher.final()]));
    if(!recovery.credentialKey||!recovery.paths.portfolios)throw Error('invalid_recovery_material');
    fs.renameSync(recoveryFile,path.join(output,'recovery.enc'));
    const restored=await restoreUserData({input:downloaded,output:path.join(output,'restored'),key});
    const credentialValidation=verifyRestoredCredentialEnvelopes(path.join(output,'restored'),recovery.credentialKey);
    if(JSON.stringify(credentialValidation)!==JSON.stringify(value.credentialValidation))throw Error('restored_credential_count_mismatch');
    const report={status:'verified_off_host_user_backup',capturedAt:new Date().toISOString(),instance:INSTANCE,
      bucket:BUCKET,prefix,generation:value.generation,databases:restored.databases,bytes:restored.bytes,
      objects:objects.length,node:value.node,remoteRestore:value.verifiedRemoteRestore,offHostRestore:true,
      credentialRecoveryEnvelopeVerified:true,productionDatabasesWritten:false,consistency:value.consistency,
      credentialValidation,
      recoveryKeyLocation:'recovery-key.hex (private local file, not uploaded)',keyStorageIndependentOfBackup:true};
    fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2),{flag:'wx',mode:0o600});
    return report;
  } finally {
    try {
      // An authorize timeout may still have created a rule. Recover only this
      // operation's exact /32 TCP22 UUID-tagged rule; never revoke others.
      if(ingressRequested) {
        const ids=findRules();
        if(ids.length)aws('ec2','revoke-security-group-ingress','--group-id',GROUP,'--security-group-rule-ids',...ids);
        if(findRules().length)throw Error('ingress_remains');
      }
    }
    catch {console.error(JSON.stringify({status:'URGENT_cleanup_required',group:GROUP,rule,operation:ingressDescription}));throw Error('ingress_cleanup_failed');}
    finally {fs.rmSync(scratch,{recursive:true,force:true});}
  }
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  if(process.argv[2]!=='--backup-real-users'||!process.argv[3]||process.argv.length!==4) {
    console.error('Explicit --backup-real-users <new absolute private directory outside repository> required');process.exitCode=1;
  } else try {console.log(JSON.stringify(await backupAwsUserData(process.argv[3]),null,2));}
  catch {console.error('AWS user backup did not complete. No live database was replaced. Keep the private recovery directory for diagnosis; no secrets emitted.');process.exitCode=1;}
}
