import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {ruleBundlePaths, readRuleBundleManifest} from './rulePortfolioBundle.js';

const hash=x=>createHash('sha256').update(x).digest('hex');
function fixture(t){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'rule-bundle-test-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const entries=Object.fromEntries(['all','sp500','nasdaq100'].map(id=>[id,
    {file:`${id}.json`,snapshotId:hash(id),dataThrough:'2026-09-30'}]));
  const manifest={schemaVersion:'rule-portfolio-bundle-v1',entries,
    ledgerIdentity:hash('ledger'),sourceGeneration:hash('source'),sourceManifestSha256:hash('catalog')};
  fs.writeFileSync(path.join(root,'rule-manifest.json'),JSON.stringify(manifest));
  return {root,manifest};
}
test('bundle pins all three curves and the single matching ledger archive',t=>{
  const {root,manifest}=fixture(t),out=ruleBundlePaths(root,'sp500');
  assert.equal(out.file,path.join(root,'sp500.json'));
  assert.equal(out.snapshotId,manifest.entries.sp500.snapshotId);
  assert.equal(out.ledgerRoot,path.join(root,'ledger'));
  assert.equal(out.ledgerIdentity,manifest.ledgerIdentity);
  assert.match(out.identity,/^[a-f0-9]{64}$/);
});
test('legacy inputs have no bundle; missing required bundle never falls back',t=>{
  const {root}=fixture(t);
  fs.unlinkSync(path.join(root,'rule-manifest.json'));
  assert.equal(ruleBundlePaths(root,'all'),null);
  assert.throws(()=>readRuleBundleManifest(root,{required:true}),/bundle_missing/);
});
test('incomplete sets, path escape, unknown schema and mixed dates fail closed',t=>{
  const {root,manifest}=fixture(t);
  const check=(edit)=>{const m=structuredClone(manifest);edit(m);
    fs.writeFileSync(path.join(root,'rule-manifest.json'),JSON.stringify(m));
    assert.throws(()=>ruleBundlePaths(root,'all'),/bundle_invalid/);};
  check(m=>delete m.entries.sp500);
  check(m=>m.entries.all.file='../all.json');
  check(m=>m.schemaVersion='future');
  check(m=>m.entries.all.dataThrough='2026-09-29');
  check(m=>m.ledgerIdentity='');
  check(m=>delete m.sourceManifestSha256);
});
