import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { DatabaseSync } from 'node:sqlite';
import { backupUserData, restoreUserData } from '../server/userDataBackup.js';

// Explicit operator smoke test, NEVER a startup hook or a production data export.
// Only synthetic databases are created. No running application store is opened.
const bucket='guru-analysis-dashboard-eb-378477120101-us-east-1';
const prefix=`database-backups/user-data-validation/${crypto.randomUUID()}/`;
const run=promisify(execFile);
const uploaded=[];
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tf-user-aws-validation-'));
const started=Date.now();
async function aws(args) {
  const env={...process.env,AWS_MAX_ATTEMPTS:'1',AWS_PAGER:''};
  delete env.USER_DATA_BACKUP_KEY;
  delete env.PORTFOLIO_CREDENTIALS_KEY;
  try {
    const {stdout}=await run('aws',[...args,'--region','us-east-1','--cli-connect-timeout','5','--cli-read-timeout','20','--output','json'],{
      env,timeout:30000,maxBuffer:512*1024
    });
    return stdout.trim()?JSON.parse(stdout):{};
  } catch {throw new Error('AWS validation operation failed');}
}
try {
  if(process.argv.slice(2).join(' ')!=='--synthetic-only') throw new Error('Run explicitly with --synthetic-only');
  const portfolios=path.join(temp,'synthetic');fs.mkdirSync(portfolios,{mode:0o700});
  for(const [n,nav] of [[1,100],[2,900]]) {
    const dir=path.join(portfolios,String(n).repeat(40));fs.mkdirSync(dir,{mode:0o700});
    const db=new DatabaseSync(path.join(dir,'portfolio.sqlite'));
    try {
      db.exec('CREATE TABLE portfolio_nav_points(date TEXT PRIMARY KEY, nav REAL)');
      db.prepare('INSERT INTO portfolio_nav_points VALUES(?,?)').run('2026-01-01',nav);
    } finally {db.close();}
  }
  const key=crypto.randomBytes(32).toString('hex'); // Ephemeral, no real broker key.
  const output=path.join(temp,'encrypted');
  const result=await backupUserData({paths:{portfolios,registry:path.join(portfolios,'portfolio-admin.sqlite'),login:path.join(portfolios,'login-activity.sqlite')},output,key});
  // A manifest is a completion marker. Publish it only after every ciphertext.
  const names=fs.readdirSync(output).sort((a,b)=>Number(a==='manifest.enc')-Number(b==='manifest.enc'));
  for(const name of names) {
    const object=prefix+name;
    const receipt=await aws(['s3api','put-object','--bucket',bucket,'--key',object,'--body',path.join(output,name),'--server-side-encryption','AES256','--if-none-match','*']);
    uploaded.push({object,version:receipt.VersionId});
  }
  const downloaded=path.join(temp,'downloaded');fs.mkdirSync(downloaded,{mode:0o700});
  for(const name of names) {
    const dest=path.join(downloaded,name);
    await aws(['s3api','get-object','--bucket',bucket,'--key',prefix+name,dest]);
    fs.chmodSync(dest,0o600);
    if(!fs.readFileSync(dest).equals(fs.readFileSync(path.join(output,name)))) throw new Error('Remote byte verification failed');
  }
  const restored=path.join(temp,'restored');
  await restoreUserData({input:downloaded,output:restored,key});
  for(const [n,nav] of [[1,100],[2,900]]) {
    const db=new DatabaseSync(path.join(restored,'portfolios',String(n).repeat(40),'portfolio.sqlite'),{readOnly:true});
    try {if(db.prepare('SELECT nav FROM portfolio_nav_points').get().nav!==nav) throw new Error('Tenant value mismatch');}
    finally {db.close();}
  }
  console.log(JSON.stringify({status:'synthetic_aws_backup_restore_verified',databases:result.databases,objects:names.length,bytes:result.bytes,durationMs:Date.now()-started,productionDataTouched:false}));
} catch {
  console.error('Synthetic AWS backup validation failed. No production database was accessed.');
  process.exitCode=1;
} finally {
  let cleanupFailed=false;
  for(const {object,version} of uploaded) {
    // Exact keys successfully created by this invocation, never recursive S3 deletion.
    try {await aws(['s3api','delete-object','--bucket',bucket,'--key',object,...(version?['--version-id',version]:[])]);}
    catch {cleanupFailed=true;}
  }
  fs.rmSync(temp,{recursive:true,force:true}); // Only mkdtemp-created synthetic data.
  if(cleanupFailed) {
    console.error(`Some synthetic encrypted validation objects need cleanup in ${bucket}/${prefix}`);
    process.exitCode=1;
  } else if(uploaded.length) console.log(JSON.stringify({status:'synthetic_objects_removed',objects:uploaded.length}));
}
