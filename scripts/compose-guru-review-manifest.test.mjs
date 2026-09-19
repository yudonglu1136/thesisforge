import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { composeReviewManifest } from './compose-guru-review-manifest.mjs';

const file = 'server/config/guru-valuation-reviewed-batch.json';
const bytes = fs.readFileSync(file);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const recipe = () => ({ schemaVersion: 1, asOf: '2026-09-06', sourceCutoff: '2026-09-05',
  parts: [{ path: file, sha256: sha(bytes), tickers: ['SOFI', 'POWL', 'CROX'] }] });

test('composition preserves exact reviewed records and grants no release approval', () => {
  const result = composeReviewManifest(recipe());
  assert.equal(result.releaseAuthorized, false);
  assert.deepEqual(result.companies.map(row => row.ticker), ['CROX', 'POWL', 'SOFI']);
  const source = JSON.parse(bytes);
  for (const row of result.companies) assert.deepEqual(row, source.companies.find(x => x.ticker === row.ticker));
});

test('composition rejects unreviewed, missing, duplicate, stale-hash and future parts', () => {
  for (const tickers of [['TBBB'], ['USFD'], ['CROX', 'CROX']]) {
    const input = recipe(); input.parts[0].tickers = tickers;
    assert.throws(() => composeReviewManifest(input));
  }
  const duplicate = recipe(); duplicate.parts.push(duplicate.parts[0]);
  assert.throws(() => composeReviewManifest(duplicate));
  const changed = recipe(); changed.parts[0].sha256 = '0'.repeat(64);
  assert.throws(() => composeReviewManifest(changed), /hash mismatch/);
  const future = recipe(); future.asOf = '2026-09-04';
  assert.throws(() => composeReviewManifest(future));
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'guru-review-composition-test-'));
  const modified = JSON.parse(bytes); modified.companies.find(row => row.ticker === 'CROX').releaseNeeds = ['Unresolved claims'];
  const draft = JSON.stringify(modified); const draftPath = path.join(temp, 'manifest.json');
  fs.writeFileSync(draftPath, draft);
  const pending = recipe(); pending.parts = [{ path: draftPath, sha256: sha(draft), tickers: ['CROX'] }];
  assert.throws(() => composeReviewManifest(pending), /research-only/);
});
