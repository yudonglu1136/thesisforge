import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';

export const RULE_BUNDLE_SCHEMA='rule-portfolio-bundle-v1';
export const RULE_BUNDLE_UNIVERSES=Object.freeze(['all','sp500','nasdaq100']);
const hash=x=>createHash('sha256').update(x).digest('hex');
const hex=x=>/^[a-f0-9]{64}$/.test(x??'');
const fail=code=>{throw Object.assign(new Error(code),{status:503});};

// Small immutable manifest only. The installer verifies every payload and the
// complete ledger before activation; the dashboard loader also checks its own
// exact snapshot hash on read. No request-time canonical scan or backtest.
export function readRuleBundleManifest(root,{required=false}={}) {
  if(!root){if(required)fail('rule_bundle_missing');return null;}
  const file=path.join(root,'rule-manifest.json');
  if(!fs.existsSync(file)){if(required)fail('rule_bundle_missing');return null;}
  let bytes,value;
  try{bytes=fs.readFileSync(file);value=JSON.parse(bytes);}catch{fail('rule_bundle_invalid');}
  if(value.schemaVersion!==RULE_BUNDLE_SCHEMA||!hex(value.ledgerIdentity)||!hex(value.sourceGeneration)||!hex(value.sourceManifestSha256)||
     Object.keys(value.entries??{}).sort().join(',')!==[...RULE_BUNDLE_UNIVERSES].sort().join(','))fail('rule_bundle_invalid');
  const dates=new Set();
  for(const id of RULE_BUNDLE_UNIVERSES){
    const e=value.entries[id];
    if(e?.file!==`${id}.json`||!hex(e.snapshotId)||!/^\d{4}-\d{2}-\d{2}$/.test(e.dataThrough??'')||
      !Number.isFinite(Date.parse(e.dataThrough))||new Date(e.dataThrough).toISOString().slice(0,10)!==e.dataThrough)
      fail('rule_bundle_invalid');
    dates.add(e.dataThrough);
  }
  if(dates.size!==1)fail('rule_bundle_invalid');
  return {manifest:value,identity:hash(bytes)};
}

export function ruleBundlePaths(root,universe,{required=false}={}) {
  const result=readRuleBundleManifest(root,{required});
  if(!result)return null;
  const entry=result.manifest.entries[universe];
  if(!entry)fail('rule_bundle_invalid_universe');
  return {...entry,identity:result.identity,file:path.join(root,entry.file),
    ledgerRoot:path.join(root,'ledger'),ledgerIdentity:result.manifest.ledgerIdentity};
}
