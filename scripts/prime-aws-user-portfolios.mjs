// One-off operator action, not an HTTP route, deployment, migration or scheduler.
// A verified off-host backup must already exist. Only the deployed application's
// real broker reader may append reports; this wrapper never rewrites a database.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {DatabaseSync} from 'node:sqlite';
import {matchingTemporaryIngressRules} from './backup-aws-user-data.mjs';

const REGION='us-east-1',ACCOUNT='378477120101',ENVIRONMENT='thesisforge-api-prod';
const INSTANCE='i-0896b2f2f421b847b',GROUP='sg-0d7dabbfa4cdc91cc';
const RUNTIME_FILES=['scripts/prime-user-portfolio-reports.mjs','server/portfolioClient.js',
  'server/userPortfolioStore.js','server/userDataPaths.js','server/asyncUserCache.js',
  'server/portfolioReport.js','server/portfolioHistory.js','server/portfolioIncome.js'];

export function validatePrimeOptions({expectedRelease,expectedConnected,expectedUsers,expectedDatabases}) {
  if(!/^[a-zA-Z0-9._-]{1,100}$/.test(expectedRelease||'')||!Number.isSafeInteger(expectedConnected)||expectedConnected<1
    ||!Number.isSafeInteger(expectedUsers)||expectedUsers<expectedConnected
    ||!Number.isSafeInteger(expectedDatabases)||expectedDatabases<expectedConnected||expectedDatabases>expectedUsers)throw Error('explicit_release_and_user_counts_required');
}
export function verifyPrimeRelease(environment,resources,expectedRelease) {
  if(environment?.EnvironmentName!==ENVIRONMENT||environment.VersionLabel!==expectedRelease
    ||environment.Status!=='Ready'||environment.Health!=='Green'
    ||resources?.Instances?.length!==1||resources.Instances[0].Id!==INSTANCE)throw Error('deployment_target_changed');
}

// Private hashes stay in remote process memory, never in the receipt. Compare
// all pre-existing owners, exact encrypted credentials, and every NAV column,
// including timestamps. Reports may be added/refreshed, never removed.
export function capturePortfolioPreservationState(locations) {
  const digest=value=>crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
  const read=file=>{
    const stat=fs.lstatSync(file);
    if(!stat.isFile()||stat.isSymbolicLink()||stat.nlink!==1)throw Error('unsafe_private_database');
    const db=new DatabaseSync(file,{readOnly:true});db.exec('PRAGMA query_only=ON;');return db;
  };
  const rootStat=fs.lstatSync(locations.portfolios);
  if(!rootStat.isDirectory()||rootStat.isSymbolicLink())throw Error('unsafe_private_directory');
  const registry=read(locations.registry);let owners;
  try {owners=registry.prepare('SELECT user_hash,user_id FROM portfolio_user_registry ORDER BY user_hash').all().map(row=>[row.user_hash,digest(row)]);}
  finally {registry.close();}
  const stores={};
  for(const entry of fs.readdirSync(locations.portfolios,{withFileTypes:true})) {
    if(entry.isSymbolicLink())throw Error('unsafe_private_directory');
    if(!entry.isDirectory())continue;
    if(!/^[a-f0-9]{40}$/.test(entry.name))throw Error('unknown_private_directory');
    const directory=path.join(locations.portfolios,entry.name);
    if(fs.lstatSync(directory).isSymbolicLink())throw Error('unsafe_private_directory');
    const db=read(path.join(directory,'portfolio.sqlite'));
    try {
      const tables=new Set(db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r=>r.name));
      const connections=db.prepare('SELECT provider,encrypted_json,created_at FROM portfolio_connections ORDER BY provider').all();
      const nav=db.prepare('SELECT * FROM portfolio_nav_points ORDER BY account_id,date').all();
      const reports=tables.has('portfolio_report_snapshots')?db.prepare('SELECT provider,connection_revision,report_date FROM portfolio_report_snapshots ORDER BY provider,connection_revision,report_date').all():[];
      stores[entry.name]={connections:connections.map(r=>[r.provider,digest(r)]),
        nav:nav.map(r=>[JSON.stringify([r.account_id,r.date]),digest(r)]),reports:reports.map(digest)};
    } finally {db.close();}
  }
  return {owners,stores};
}
export function verifyPortfolioPreservation(before,after) {
  const contains=(prior,current)=>{const map=new Map(current);return prior.every(([key,value])=>map.get(key)===value);};
  if(!contains(before.owners,after.owners))throw Error('owner_records_changed');
  let connections=0,navRows=0,reportRowsBefore=0,reportRowsAfter=0;
  for(const [key,prior] of Object.entries(before.stores)) {
    const current=after.stores[key];
    if(!current||!contains(prior.connections,current.connections))throw Error('connection_ciphertext_changed');
    if(!contains(prior.nav,current.nav))throw Error('original_nav_changed');
    const reports=new Set(current.reports);
    if(prior.reports.some(report=>!reports.has(report)))throw Error('saved_report_removed');
    connections+=prior.connections.length;navRows+=prior.nav.length;
    reportRowsBefore+=prior.reports.length;reportRowsAfter+=current.reports.length;
  }
  return {ownersPreserved:before.owners.length,databasesPreserved:Object.keys(before.stores).length,
    connectionCiphertextsPreserved:connections,originalNavRowsPreserved:navRows,
    reportRowsBefore,reportRowsAfter,newReportRows:reportRowsAfter-reportRowsBefore};
}

export async function primeAwsUserPortfolios(options) {
  validatePrimeOptions(options);
  const {expectedRelease,expectedConnected,expectedUsers,expectedDatabases}=options;
  const repository=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
  const hashes=Object.fromEntries(RUNTIME_FILES.map(file=>[file,crypto.createHash('sha256').update(fs.readFileSync(path.join(repository,file))).digest('hex')]));
  const run=(binary,args,extra={})=>execFileSync(binary,args,{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:30000,...extra});
  const aws=(...args)=>JSON.parse(run('aws',[...args,'--region',REGION,'--output','json']));
  const release=()=>{
    const e=aws('elasticbeanstalk','describe-environments','--environment-names',ENVIRONMENT).Environments[0];
    const r=aws('elasticbeanstalk','describe-environment-resources','--environment-name',ENVIRONMENT).EnvironmentResources;
    verifyPrimeRelease(e,r,expectedRelease);return e;
  };
  const configuration=e=>{
    const settings=aws('elasticbeanstalk','describe-configuration-settings','--application-name',e.ApplicationName,
      '--environment-name',ENVIRONMENT).ConfigurationSettings[0].OptionSettings;
    const sorted=settings.map(s=>[s.Namespace,s.OptionName,s.ResourceName||'',s.Value||'']).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b)));
    return crypto.createHash('sha256').update(JSON.stringify(sorted)).digest('hex');
  };
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'tf-portfolio-prime-'));fs.chmodSync(scratch,0o700);
  const description='ThesisForge portfolio prime '+crypto.randomUUID();
  let operatorIp,ingressRequested=false,rule;
  const findRules=()=>matchingTemporaryIngressRules(aws('ec2','describe-security-group-rules',
    '--filters','Name=group-id,Values='+GROUP).SecurityGroupRules,{group:GROUP,ip:operatorIp,description});
  try {
    if(aws('sts','get-caller-identity').Account!==ACCOUNT)throw Error('wrong_aws_account');
    const initialConfiguration=configuration(release());
    const info=aws('ec2','describe-instances','--instance-ids',INSTANCE).Reservations[0].Instances[0];
    if(info.State.Name!=='running'||!info.SecurityGroups.some(g=>g.GroupId===GROUP))throw Error('target_changed');
    const fingerprints=new Set((aws('ec2','get-console-output','--instance-id',INSTANCE).Output||'').match(/SHA256:[A-Za-z0-9+/=]+/g)||[]);
    if(!fingerprints.size)throw Error('unverified_host');
    const ip=(await(await fetch('https://checkip.amazonaws.com',{signal:AbortSignal.timeout(10000)})).text()).trim();
    if(!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)||ip.split('.').some(n=>Number(n)>255))throw Error('invalid_operator_ip');
    operatorIp=ip;run('ssh-keygen',['-q','-t','ed25519','-N','','-f',path.join(scratch,'key')]);
    ingressRequested=true;
    rule=aws('ec2','authorize-security-group-ingress','--group-id',GROUP,'--ip-permissions',JSON.stringify([
      {IpProtocol:'tcp',FromPort:22,ToPort:22,IpRanges:[{CidrIp:ip+'/32',Description:description}]}
    ])).SecurityGroupRules?.[0]?.SecurityGroupRuleId;
    if(!rule)throw Error('missing_exact_ingress_rule');
    const verified=[];
    for(const line of run('ssh-keyscan',['-T','10','-t','ed25519,ecdsa',info.PublicIpAddress]).split('\n').filter(x=>x&&!x.startsWith('#'))) {
      fs.writeFileSync(path.join(scratch,'candidate'),line+'\n',{mode:0o600});
      if(fingerprints.has(run('ssh-keygen',['-lf',path.join(scratch,'candidate'),'-E','sha256']).split(/\s+/)[1]))verified.push(line);
    }
    if(!verified.length)throw Error('host_key_mismatch');
    fs.writeFileSync(path.join(scratch,'known_hosts'),verified.join('\n')+'\n',{mode:0o600});
    if(!aws('ec2-instance-connect','send-ssh-public-key','--instance-id',INSTANCE,'--instance-os-user','ec2-user',
      '--ssh-public-key',fs.readFileSync(path.join(scratch,'key.pub'),'utf8').trim()).Success)throw Error('eic_failed');
    const program=`
      import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';
      import {execFileSync} from 'node:child_process';import {DatabaseSync} from 'node:sqlite';
      const capturePortfolioPreservationState=${capturePortfolioPreservationState.toString()};
      const verifyPortfolioPreservation=${verifyPortfolioPreservation.toString()};
      const env=JSON.parse(execFileSync('/opt/elasticbeanstalk/bin/get-config',['environment'],{encoding:'utf8'}));
      if(env.NODE_ENV!=='production'||env.API_AUTH_DEV_BYPASS==='true')throw Error('invalid_production_environment');
      const current=fs.realpathSync('/var/app/current');
      const working=execFileSync('systemctl',['show','web.service','--property=WorkingDirectory','--value'],{encoding:'utf8'}).trim();
      if(fs.realpathSync(working)!==current)throw Error('unverified_working_directory');
      const user=execFileSync('systemctl',['show','web.service','--property=User','--value'],{encoding:'utf8'}).trim();
      if(!/^[a-z_][a-z0-9_-]*$/.test(user)||user==='root')throw Error('unverified_app_identity');
      const uid=Number(execFileSync('id',['-u',user],{encoding:'utf8'}));
      const gid=Number(execFileSync('id',['-g',user],{encoding:'utf8'}));
      if(!Number.isInteger(uid)||uid<=0||!Number.isInteger(gid)||gid<0)throw Error('invalid_app_identity');
      process.setgroups([]);process.setgid(gid);process.setuid(uid);
      for(const [file,expected] of Object.entries(${JSON.stringify(hashes)})) {
        if(crypto.createHash('sha256').update(fs.readFileSync(path.join(current,file))).digest('hex')!==expected)throw Error('deployed_runtime_mismatch');
      }
      const {resolveUserDataPaths}=await import(path.join(current,'server/userDataPaths.js'));
      const locations=resolveUserDataPaths(env);
      const before=capturePortfolioPreservationState(locations);
      if(Object.keys(before.stores).length!==${expectedDatabases})throw Error('database_count_changed');
      let prime;
      try {
        const output=execFileSync(process.execPath,[path.join(current,'scripts/prime-user-portfolio-reports.mjs'),
          '--apply','--expected-connected','${expectedConnected}','--expected-users','${expectedUsers}'],
          {cwd:current,env,encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:540000,maxBuffer:1024*1024});
        prime=JSON.parse(output.trim());
      } catch(error) {
        try {prime=JSON.parse(String(error.stdout||'').trim());}catch{prime={status:'failed'};}
      }
      const preservation=verifyPortfolioPreservation(before,capturePortfolioPreservationState(locations));
      console.log(JSON.stringify({status:prime.status==='complete'?'verified_prime':'incomplete_prime',
        prime,preservation,ranAsApplicationUser:process.getuid()===uid,environmentUnchanged:true}));
    `;
    const receipt=JSON.parse(run('ssh',['-i',path.join(scratch,'key'),'-o','BatchMode=yes','-o','IdentitiesOnly=yes',
      '-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+path.join(scratch,'known_hosts'),'-o','ConnectTimeout=15',
      'ec2-user@'+info.PublicIpAddress,'sudo /bin/bash -lc "node --input-type=module"'],
      {input:program,stdio:['pipe','pipe','pipe'],timeout:600000,maxBuffer:2*1024*1024}));
    if(configuration(release())!==initialConfiguration)throw Error('environment_configuration_changed');
    if(!receipt?.preservation||receipt.ranAsApplicationUser!==true)throw Error('unverified_prime_receipt');
    return {...receipt,expectedRelease,instance:INSTANCE,capturedAt:new Date().toISOString(),
      databaseReplacementPerformed:false,temporaryIngressRemoved:true};
  } finally {
    try {
      if(ingressRequested){const ids=findRules();if(ids.length)aws('ec2','revoke-security-group-ingress','--group-id',GROUP,'--security-group-rule-ids',...ids);
        if(findRules().length)throw Error('ingress_remains');}
    } catch {
      console.error(JSON.stringify({status:'URGENT_cleanup_required',group:GROUP,rule,operation:description}));throw Error('ingress_cleanup_failed');
    } finally {fs.rmSync(scratch,{recursive:true,force:true});}
  }
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const {values}=parseArgs({options:{'prime-real-users':{type:'boolean'},'expected-release':{type:'string'},
      'expected-connected':{type:'string'},'expected-users':{type:'string'},'expected-databases':{type:'string'}}});
    if(!values['prime-real-users'])throw Error('explicit_operator_action_required');
    const result=await primeAwsUserPortfolios({expectedRelease:values['expected-release'],
      expectedConnected:Number(values['expected-connected']),expectedUsers:Number(values['expected-users']),
      expectedDatabases:Number(values['expected-databases'])});
    console.log(JSON.stringify(result));if(result.status!=='verified_prime')process.exitCode=1;
  } catch {console.error(JSON.stringify({status:'prime_not_verified',message:'Check the verified backup and operator receipt. No database replacement or automatic rollback was performed.'}));process.exitCode=1;}
}
