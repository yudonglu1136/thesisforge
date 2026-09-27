import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {installRuleLedgerArchive} from './install-rule-ledger-archive.mjs';
import {RULE_ANALYSIS_VERSION} from '../server/rulePortfolioAnalysis.js';
const sha=b=>createHash('sha256').update(b).digest('hex');
function fixture(){
  const base=fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()),'rule-install-'));
  const source=path.join(base,'source'),root=path.join(base,'installed');fs.mkdirSync(source);
  const snapshotId='a'.repeat(64),sourceGeneration='b'.repeat(64);
  const value={version:'strategy-ledger-public-analysis-v1',snapshotId,sourceGeneration,
    ledger:{version:'rule-ledger-artifact-v1',ledgerVersion:RULE_ANALYSIS_VERSION,snapshotId,
      styles:[{id:'quality_rank',events:[],days:[{date:'2024-01-02',nav:1,pnl:[],fees:[],positions:[]}]}]}};
  const bytes=gzipSync(JSON.stringify(value)),hash=sha(bytes),file=`${hash}.json.gz`;
  fs.writeFileSync(path.join(source,file),bytes);
  const entries=Object.fromEntries(['all','sp500','nasdaq100'].map(u=>[u,{snapshotId,sourceGeneration,file,sha256:hash,bytes:bytes.length}]));
  const manifest=JSON.stringify({schemaVersion:1,method:RULE_ANALYSIS_VERSION,entries});fs.writeFileSync(path.join(source,'manifest.json'),manifest);
  const load=({universe})=>({snapshotId,universe:{id:universe},dataThrough:'2024-01-02',styles:[{id:'quality_rank'}],
    backtest:{curve:[{date:'2024-01-02',quality_rank:1}]}});
  return {base,source,root,expectedManifest:sha(manifest),load,file};
}
test('archive installation is immutable, idempotent, manifest-last and retains rollback manifests',()=>{
  const f=fixture();try{
    assert.equal(installRuleLedgerArchive(f).status,'installed');
    const active=path.join(f.root,'manifest.json'),before=fs.statSync(active);
    assert.equal(installRuleLedgerArchive(f).status,'installed');
    assert.equal(fs.statSync(active).mtimeMs,before.mtimeMs);
    assert.equal(fs.statSync(path.join(f.root,f.file)).mode&0o222,0);
    assert.ok(fs.existsSync(path.join(f.root,'manifests',`${f.expectedManifest}.json`)));
  }finally{fs.rmSync(f.base,{recursive:true,force:true});}
});
test('bad checksum, wrong source snapshot and an occupied lock cannot switch the old manifest',()=>{
  const f=fixture();try{
    installRuleLedgerArchive(f);const before=fs.readFileSync(path.join(f.root,'manifest.json'),'utf8');
    assert.throws(()=>installRuleLedgerArchive({...f,expectedManifest:'0'.repeat(64)}),/checksum/);
    assert.throws(()=>installRuleLedgerArchive({...f,load:x=>({...f.load(x),snapshotId:'c'.repeat(64)})}),/snapshot_mismatch/);
    fs.writeFileSync(path.join(f.root,'.install.lock'),'');
    assert.throws(()=>installRuleLedgerArchive(f),/EEXIST/);
    assert.equal(fs.readFileSync(path.join(f.root,'manifest.json'),'utf8'),before);
  }finally{fs.rmSync(f.base,{recursive:true,force:true});}
});
