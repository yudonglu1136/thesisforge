import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gunzipSync} from 'node:zlib';
import {RULE_ANALYSIS_VERSION,hydrateRuleLedger,serializeRuleLedger} from './rulePortfolioAnalysis.js';

const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const fail=code=>{throw Object.assign(new Error(code),{status:503});};
export const defaultRuleLedgerRoot=()=>process.env.RULE_LEDGER_ROOT??(process.env.NODE_ENV==='production'
  ?'/var/app/data/rule-ledgers':null);
export function ruleLedgerArchiveIdentity(root=defaultRuleLedgerRoot()) {
  if(!root)return null;
  const file=path.join(root,'manifest.json');
  if(!fs.existsSync(file))return null;
  return hash(fs.readFileSync(file));
}

// Published curves are immutable. Revised vendor adjustment factors must not
// be mixed into their stock attribution. This archive contains only derived
// public strategy ledgers, built with the original prices and strict replay.
// It is a private runtime artifact, never a database or a Git data fixture.
export function readRuleLedgerArchive(dashboard,{root=defaultRuleLedgerRoot(),identity=ruleLedgerArchiveIdentity(root)}={}) {
  if(!identity)return null;
  if(ruleLedgerArchiveIdentity(root)!==identity)fail('rule_ledger_archive_changed');
  let manifest;
  try{manifest=JSON.parse(fs.readFileSync(path.join(root,'manifest.json'),'utf8'));}catch{fail('rule_ledger_archive_invalid');}
  if(manifest.schemaVersion!==1||manifest.method!==RULE_ANALYSIS_VERSION)fail('rule_ledger_archive_invalid');
  const entry=manifest.entries?.[dashboard.universe?.id??'all'];
  if(entry?.snapshotId!==dashboard.snapshotId)fail('rule_ledger_snapshot_mismatch');
  if(!/^[a-f0-9]{64}\.json\.gz$/.test(entry.file??'')||entry.file!==`${entry.sha256}.json.gz`)
    fail('rule_ledger_archive_invalid');
  let value;
  try{
    const bytes=fs.readFileSync(path.join(root,entry.file));
    if(bytes.length!==entry.bytes||hash(bytes)!==entry.sha256)fail('rule_ledger_archive_invalid');
    value=JSON.parse(gunzipSync(bytes,{maxOutputLength:128*1024*1024}));
  }catch{fail('rule_ledger_archive_invalid');}
  if(value.version!=='strategy-ledger-public-analysis-v1'||value.snapshotId!==dashboard.snapshotId||
    value.ledger?.snapshotId!==dashboard.snapshotId||value.sourceGeneration!==entry.sourceGeneration)
    fail('rule_ledger_archive_invalid');
  const ledger=hydrateRuleLedger(value.ledger),cutoff=dashboard.dataThrough;
  if(ledger.styles.length!==dashboard.styles.length)fail('rule_ledger_archive_invalid');
  const trim=style=>style.segments?{...style,segments:style.segments.filter(s=>s.from<=cutoff).map(s=>({...trim(s),to:s.to>cutoff?cutoff:s.to}))}
    :{...style,days:style.days.filter(d=>d.date<=cutoff),events:style.events.filter(e=>e.date<=cutoff)};
  ledger.styles=ledger.styles.map(style=>{
    const source=dashboard.styles.find(s=>s.id===style.id);
    if(!source)fail('rule_ledger_archive_invalid');
    const days=(style.segments??[style]).flatMap(s=>s.days),byDate=new Map(days.map(d=>[d.date,d.nav]));
    for(const row of dashboard.backtest.curve){
      const expected=row[style.id];if(!Number.isFinite(expected))continue;
      const actual=byDate.get(row.date);
      if(!Number.isFinite(actual)||Math.abs(actual-expected)>1e-8*Math.max(1,Math.abs(expected)))fail('rule_analysis_nav_mismatch');
    }
    const result=trim(style);
    if(source.coverage)result.coverage=source.coverage;
    return result;
  });
  return {...value,ledger:serializeRuleLedger(ledger),archiveIdentity:identity,
    adjustmentBasis:'published_snapshot_price_vintage'};
}
