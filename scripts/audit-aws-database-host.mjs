// Explicit operator audit of the existing EB host. No database/app mutations.
// Temporary SSH ingress is restricted to this operator's /32 and revoked in finally.
// The host key is verified against the AWS console, not trusted from ssh-keyscan alone.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';

const mode = process.argv.slice(2).join(' ');
if (!['--read-only', '--read-only --restore-drill'].includes(mode)) throw Error('Explicit --read-only required');
const restoreDrill = mode.endsWith('--restore-drill');
const instance = 'i-0896b2f2f421b847b', group = 'sg-0d7dabbfa4cdc91cc', region = 'us-east-1';
const aws = (...args) => JSON.parse(execFileSync('aws', [...args, '--region', region, '--output', 'json'], {
  encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000
}));
const run = (bin, args, extra = {}) => execFileSync(bin, args, {
  encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000, ...extra
});
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'tf-host-audit-'));
let rule;
try {
  const info = aws('ec2', 'describe-instances', '--instance-ids', instance).Reservations[0].Instances[0];
  if (info.State.Name !== 'running' || !info.SecurityGroups.some(g => g.GroupId === group)) throw Error('target_changed');
  const ip = info.PublicIpAddress;
  const output = aws('ec2', 'get-console-output', '--instance-id', instance).Output || '';
  const fingerprints = new Set(output.match(/SHA256:[A-Za-z0-9+/=]+/g) || []);
  if (!fingerprints.size) throw Error('No AWS-verified host key');
  const myIp = (await (await fetch('https://checkip.amazonaws.com', { signal: AbortSignal.timeout(10000) })).text()).trim();
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(myIp) || myIp.split('.').some(n => Number(n) > 255)) throw Error('Invalid operator IPv4');
  run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', path.join(temp, 'key')]);
  const permission = [{ IpProtocol: 'tcp', FromPort: 22, ToPort: 22,
    IpRanges: [{ CidrIp: `${myIp}/32`, Description: 'ThesisForge temporary read-only launch audit' }] }];
  const added = aws('ec2', 'authorize-security-group-ingress', '--group-id', group, '--ip-permissions', JSON.stringify(permission));
  rule = added.SecurityGroupRules?.[0]?.SecurityGroupRuleId;
  if (!rule) throw Error('Missing exact temporary rule ID');
  const keys = run('ssh-keyscan', ['-T', '10', '-t', 'ed25519,ecdsa', ip]);
  const verified = [];
  for (const line of keys.split('\n').filter(s => s && !s.startsWith('#'))) {
    const candidate = path.join(temp, 'candidate'); fs.writeFileSync(candidate, line + '\n', { mode: 0o600 });
    const fingerprint = run('ssh-keygen', ['-lf', candidate, '-E', 'sha256']).split(/\s+/)[1];
    if (fingerprints.has(fingerprint)) verified.push(line);
  }
  if (!verified.length) throw Error('Host fingerprint differs from AWS evidence');
  const knownHosts = path.join(temp, 'known_hosts'); fs.writeFileSync(knownHosts, verified.join('\n') + '\n', { mode: 0o600 });
  const sent = aws('ec2-instance-connect', 'send-ssh-public-key', '--instance-id', instance, '--instance-os-user', 'ec2-user',
    '--ssh-public-key', fs.readFileSync(path.join(temp, 'key.pub'), 'utf8').trim());
  if (!sent.Success) throw Error('Ephemeral key not accepted');
  const audit = fs.readFileSync(new URL('./database-release-audit.mjs', import.meta.url), 'utf8');
  const backupModule = restoreDrill ? fs.readFileSync(new URL('../server/userDataBackup.js', import.meta.url), 'utf8') : '';
  const program = `
    import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import crypto from 'node:crypto';
    import {DatabaseSync} from 'node:sqlite';
    import {execFileSync} from 'node:child_process';
    const {inspectDatabase}=await import('data:text/javascript;base64,${Buffer.from(audit).toString('base64')}');
    const env=JSON.parse(execFileSync('/opt/elasticbeanstalk/bin/get-config',['environment'],{encoding:'utf8'}));
    // Reading a WAL database can create SQLite sidecars. Use the running app's
    // identity so the audit cannot leave root-owned WAL/SHM files behind.
    const appUser=execFileSync('systemctl',['show','web.service','--property=User','--value'],{encoding:'utf8'}).trim();
    if(!/^[a-z_][a-z0-9_-]*$/.test(appUser)||appUser==='root')throw Error('Unverified application identity');
    const uid=Number(execFileSync('id',['-u',appUser],{encoding:'utf8'}).trim());
    const gid=Number(execFileSync('id',['-g',appUser],{encoding:'utf8'}).trim());
    if(!Number.isInteger(uid)||uid<=0||!Number.isInteger(gid))throw Error('Invalid application identity');
    process.setgroups([]);process.setgid(gid);process.setuid(uid);
    const keys=['SQLITE_DB_PATH','USER_DATA_ROOT','USER_PORTFOLIO_DATA_DIR','LOGIN_ACTIVITY_DB_PATH','INVESTMENT_DB_PATH','STRATEGY_DATA_DB_PATH','INVESTMENT_WORKFLOW_ENABLED','API_AUTH_PROVIDER','API_AUTH_DEV_BYPASS','NODE_ENV','GURU_BACKTEST_AUTO_REFRESH'];
    const config=Object.fromEntries(keys.filter(k=>env[k]!==undefined).map(k=>[k,env[k]]));
    const research=env.SQLITE_DB_PATH||'/var/app/current/server/data/guru-analysis.sqlite';
    const root=env.USER_PORTFOLIO_DATA_DIR||path.join(path.dirname(research),'user-portfolios');
    const databases=[];
    for(const [kind,file] of [['research',research],['strategy',env.STRATEGY_DATA_DB_PATH],['investment',env.INVESTMENT_DB_PATH]]) {
      if(file&&fs.existsSync(file)) {const stat=fs.statSync(file);databases.push({kind,bytes:stat.size,mode:(stat.mode&511).toString(8),audit:inspectDatabase(file,kind,{schemaOnly:true})});}
    }
    const privateGroups=new Map(); let privateCount=0,foreignOwnedSidecars=0;
    const add=(file,kind)=>{if(!fs.existsSync(file))return;const a=inspectDatabase(file,kind,{schemaOnly:true});privateCount++;
      for(const suffix of ['-wal','-shm'])if(fs.existsSync(file+suffix)&&fs.statSync(file+suffix).uid!==uid)foreignOwnedSidecars++;
      const id=kind+':'+a.schemaSha256;const g=privateGroups.get(id)||{kind,databases:0,audit:a};
      g.databases++;privateGroups.set(id,g);};
    add(path.join(root,'portfolio-admin.sqlite'),'registry');
    add(env.LOGIN_ACTIVITY_DB_PATH||path.join(root,'login-activity.sqlite'),'login');
    if(fs.existsSync(root))for(const e of fs.readdirSync(root,{withFileTypes:true}))if(e.isDirectory()&&/^[a-f0-9]{40}$/.test(e.name))add(path.join(root,e.name,'portfolio.sqlite'),'portfolio');
    const service=execFileSync('systemctl',['is-active','web.service'],{encoding:'utf8'}).trim();
    let ssm='unavailable';try{ssm=execFileSync('systemctl',['is-active','amazon-ssm-agent'],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();}catch{}
    const disk=fs.statfsSync(path.dirname(research));
    const publicDb=new DatabaseSync(research,{readOnly:true});let publicData;
    try {
      publicDb.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=3000; BEGIN');
      publicData={
        avgo:publicDb.prepare("SELECT fiscal_period,dimension,available_at,report_period FROM valuation_pit_financials WHERE ticker='AVGO' ORDER BY available_at DESC LIMIT 4").all(),
        benchmarkPrices:['SPY','QQQ','KMLM','DBMF','AVGO'].map(symbol=>({symbol,...publicDb.prepare('SELECT date,source FROM price_points WHERE symbol=? ORDER BY date DESC LIMIT 1').get(symbol)})),
        curveRows:publicDb.prepare('SELECT years,count(*) rows,min(end_date) earliestEnd,max(end_date) latestEnd FROM guru_backtests GROUP BY years').all()
      }; publicDb.exec('COMMIT');
    }finally{publicDb.close();}
    let restoreDrill=null;
    if(${restoreDrill}) {
      if(disk.bavail*disk.bsize<3*1024*1024*1024)throw Error('Insufficient scratch space');
      const {backupUserData,restoreUserData}=await import('data:text/javascript;base64,${Buffer.from(backupModule).toString('base64')}');
      const scratch=fs.mkdtempSync('/var/tmp/thesisforge-restore-drill-');fs.chmodSync(scratch,0o700);
      const key=crypto.randomBytes(32).toString('hex'),started=Date.now();
      try {
        const paths={research,portfolios:root,registry:path.join(root,'portfolio-admin.sqlite'),login:env.LOGIN_ACTIVITY_DB_PATH||path.join(root,'login-activity.sqlite'),investment:env.INVESTMENT_DB_PATH||null};
        const backup=await backupUserData({paths,output:path.join(scratch,'encrypted'),key,keyId:'ephemeral-restore-drill'});
        const restored=await restoreUserData({input:path.join(scratch,'encrypted'),output:path.join(scratch,'restored'),key});
        if(backup.databases!==privateCount+(env.INVESTMENT_DB_PATH?1:0)||backup.databases!==restored.databases)throw Error('Restore inventory mismatch');
        restoreDrill={status:restored.status,databases:restored.databases,bytes:restored.bytes,durationMs:Date.now()-started,
          productionDatabasesWritten:false,offHostBackupVerified:false,consistency:backup.consistency};
      }finally{fs.rmSync(scratch,{recursive:true,force:true});}
    }
    console.log(JSON.stringify({capturedAt:new Date().toISOString(),node:process.version,service,ssm,config,
      resources:{memoryBytes:os.totalmem(),freeMemoryBytes:os.freemem(),loadAverage:os.loadavg(),dataDiskAvailableBytes:disk.bavail*disk.bsize},
      filePermissions:{auditAsApplicationUser:true,foreignOwnedSidecars},
      configuredSecrets:{portfolioCredentialsKey:!!env.PORTFOLIO_CREDENTIALS_KEY,backupKey:!!env.USER_DATA_BACKUP_KEY},
      databases,privateCount,privateSchemaGroups:[...privateGroups.values()],publicData,restoreDrill}));
  `;
  const result = run('ssh', ['-i', path.join(temp, 'key'), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
    '-o', 'StrictHostKeyChecking=yes', '-o', `UserKnownHostsFile=${knownHosts}`, '-o', 'ConnectTimeout=15',
    `ec2-user@${ip}`, 'sudo /bin/bash -lc "node --input-type=module"'], {
      input: program, stdio: ['pipe', 'pipe', 'pipe'], timeout: 120_000, maxBuffer: 8 * 1024 * 1024
    });
  const data = JSON.parse(result.trim());
  const destination = fs.mkdtempSync(path.join(process.cwd(), 'output/aws-host-audit-'));
  fs.writeFileSync(path.join(destination, 'inventory.json'), JSON.stringify(data, null, 2), { mode: 0o600 });
  console.log(JSON.stringify({status:'read_only_host_audit_complete',output:destination,node:data.node,service:data.service,
    ssm:data.ssm,resources:data.resources,filePermissions:data.filePermissions,privateDatabases:data.privateCount,restoreDrill:data.restoreDrill,
    databases:data.databases.map(d=>({kind:d.kind,bytes:d.bytes,tables:d.audit.tables.length,integrity:d.audit.integrityOk,status:d.audit.status}))}));
} catch(error) {
  console.error(JSON.stringify({status:'host_audit_failed',stage:error.code||error.name,
    message: 'Audit did not complete; no raw command output or secrets emitted'}));
  process.exitCode=1;
} finally {
  if (rule) {
    try {aws('ec2','revoke-security-group-ingress','--group-id',group,'--security-group-rule-ids',rule);
      console.log(JSON.stringify({status:'temporary_ssh_ingress_removed',rule}));}
    catch { console.error(JSON.stringify({status:'URGENT_cleanup_required',group,rule}));process.exitCode=1; }
  }
  fs.rmSync(temp,{recursive:true,force:true});
}
