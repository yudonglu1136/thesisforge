// Read-only IBKR report retrieval through the operator connection configured in
// AWS. Credentials remain in memory; neither AWS nor a user connection is edited.
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {ibkrReportRange} from '../server/ibkrReportRange.js';
const out=process.argv[2];
if(!out)throw new Error('Usage: node scripts/pull-owner-portfolio.mjs <private-output-directory> [--days 1..365 | YYYY-MM-DD YYYY-MM-DD]');
const range=process.argv[3]==='--days'?{periodDays:Number(process.argv[4])}:{fromDate:process.argv[3],toDate:process.argv[4]};
ibkrReportRange(range);
const root=path.resolve(out);fs.mkdirSync(root,{recursive:true,mode:0o700});
const settings=JSON.parse(execFileSync('aws',['elasticbeanstalk','describe-configuration-settings','--region','us-east-1',
  '--application-name','guru-analysis-dashboard','--environment-name','guru-analysis-api-prod',
  '--query',"ConfigurationSettings[0].OptionSettings[?Namespace=='aws:elasticbeanstalk:application:environment' && (OptionName=='IBKR_FLEX_TOKEN' || OptionName=='IBKR_FLEX_QUERY_ID')]"]));
const config=Object.fromEntries(settings.map(r=>[r.OptionName,r.Value]));
if(!config.IBKR_FLEX_TOKEN||!config.IBKR_FLEX_QUERY_ID)throw new Error('AWS operator connector is not configured');
// Isolate adapter dependencies from the public runtime and private account stores.
process.env.SQLITE_DB_PATH=path.join(root,'adapter.sqlite');
process.env.USER_PORTFOLIO_DATA_DIR=path.join(root,'adapter-users');
const {loadIbkrFlexXml}=await import('../server/portfolioClient.js');
try {
  const report=await loadIbkrFlexXml(config.IBKR_FLEX_QUERY_ID,{ibkrFlexToken:config.IBKR_FLEX_TOKEN},range);
  const sanitize=v=>Array.isArray(v)?v.map(sanitize):v&&typeof v==='object'
    ?Object.fromEntries(Object.entries(v).filter(([k])=>!/token|password|secret|queryid|referencecode/i.test(k)).map(([k,x])=>[k,sanitize(x)])):v;
  const content=JSON.stringify(sanitize(report));
  fs.writeFileSync(path.join(root,'report.json'),content,{mode:0o600,flag:'wx'});
  const metadata={version:'owner-report-download-v1',retrievedAt:new Date().toISOString(),
    source:'IBKR report retrieved using AWS EB operator connector',awsEnvironment:'guru-analysis-api-prod',
    sha256:crypto.createHash('sha256').update(content).digest('hex'),requestedRange:range,credentialsCopied:false,productionModified:false};
  fs.writeFileSync(path.join(root,'download.json'),JSON.stringify(metadata,null,2),{mode:0o600,flag:'wx'});
  console.log(JSON.stringify(metadata));
} catch(e) {
  // Do not emit provider URLs, query parameters or response bodies.
  console.error('Owner report retrieval failed; no credentials stored. '+String(e.message).replaceAll(config.IBKR_FLEX_TOKEN,'[redacted]').replaceAll(config.IBKR_FLEX_QUERY_ID,'[redacted]'));
  process.exitCode=1;
}
