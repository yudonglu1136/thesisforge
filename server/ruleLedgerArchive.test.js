import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {readRuleLedgerArchive,ruleLedgerArchiveIdentity} from './ruleLedgerArchive.js';
import {RULE_ANALYSIS_VERSION,serializeRuleLedger} from './rulePortfolioAnalysis.js';

const hash=b=>createHash('sha256').update(b).digest('hex');
function fixture(root){
  const snapshotId='a'.repeat(64),sourceGeneration='b'.repeat(64);
  const dates=['2024-01-02','2024-01-03','2024-01-04'];
  const dashboard={snapshotId,universe:{id:'all'},dataThrough:dates[1],styles:[{id:'quality_rank'}],
    backtest:{curve:dates.slice(0,2).map((date,i)=>({date,quality_rank:1+i*.1}))}};
  const ledger=serializeRuleLedger({version:RULE_ANALYSIS_VERSION,snapshotId,styles:[{id:'quality_rank',events:[],
    days:dates.map((date,i)=>({date,nav:1+i*.1,pnl:new Map(),fees:new Map(),positions:new Map()}))}]});
  const value={version:'strategy-ledger-public-analysis-v1',snapshotId,sourceGeneration,ledger};
  const bytes=gzipSync(JSON.stringify(value)),file=`${hash(bytes)}.json.gz`;
  fs.writeFileSync(path.join(root,file),bytes);
  fs.writeFileSync(path.join(root,'manifest.json'),JSON.stringify({schemaVersion:1,method:RULE_ANALYSIS_VERSION,
    entries:{all:{snapshotId,sourceGeneration,file,sha256:hash(bytes),bytes:bytes.length}}}));
  return {dashboard,file};
}
test('frozen ledger binds the exact published curve and trims future days',()=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'rule-ledger-'));
  try{
    const {dashboard}=fixture(root),identity=ruleLedgerArchiveIdentity(root);
    const result=readRuleLedgerArchive(dashboard,{root,identity});
    assert.equal(result.adjustmentBasis,'published_snapshot_price_vintage');
    assert.equal(result.ledger.styles[0].days.length,2);
    assert.equal(result.sourceGeneration,'b'.repeat(64));
    const wrong=structuredClone(dashboard);wrong.backtest.curve[1].quality_rank+=.001;
    assert.throws(()=>readRuleLedgerArchive(wrong,{root,identity}),/rule_analysis_nav_mismatch/);
    assert.throws(()=>readRuleLedgerArchive({...dashboard,snapshotId:'c'.repeat(64)},{root,identity}),/rule_ledger_snapshot_mismatch/);
    fs.appendFileSync(path.join(root,'manifest.json'),' ');
    assert.throws(()=>readRuleLedgerArchive(dashboard,{root,identity}),/rule_ledger_archive_changed/);
  }finally{fs.rmSync(root,{recursive:true,force:true});}
});
test('corrupt or missing archived prices never fall back to changing current prices',()=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'rule-ledger-corrupt-'));
  try{
    const {dashboard,file}=fixture(root),identity=ruleLedgerArchiveIdentity(root);
    fs.writeFileSync(path.join(root,file),'broken');
    assert.throws(()=>readRuleLedgerArchive(dashboard,{root,identity}),/rule_ledger_archive_invalid/);
  }finally{fs.rmSync(root,{recursive:true,force:true});}
});
