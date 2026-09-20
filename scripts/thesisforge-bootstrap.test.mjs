import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(
  path.join(root, '.platform', 'hooks', 'predeploy', '00_bootstrap_thesisforge_data.sh'),
  'utf8',
);

test('fresh AWS bootstrap keeps release inputs immutable and runtime writable only by webapp', () => {
  assert.match(source, /chown -R root:root "\$release_root"/);
  assert.match(source, /chmod 0555 "\$release_root"/);
  assert.match(source, /chown webapp:webapp "\$runtime_db"/);
  assert.match(source, /chmod 0600 "\$runtime_db"/);
  assert.match(source, /chown webapp:webapp \/var\/app\/data/);
  assert.match(source, /runuser -u webapp -- env THESISFORGE_BOOTSTRAP_DB/);
  assert.match(source, /PRAGMA journal_mode=WAL/);
  assert.match(source, /runtime_wal_not_writable/);
  assert.match(source, /runtime-bootstrap\.json/);
  assert.match(source, /runtime_bootstrap_receipt_mismatch/);
  assert.match(source, /verifiedBeforeMutation:true/);
  assert.doesNotMatch(source, /chown -R root:root "\$release_root" "\$runtime_db"/);
});

test('fresh AWS bootstrap requires exact immutable S3 artifacts before publishing files', () => {
  assert.match(source, /thesisforge-production-378477120101-us-east-1/);
  assert.match(source, /actual_bytes.*bytes/);
  assert.match(source, /actual_digest.*digest/);
  assert.match(source, /mv "\$temp" "\$target"/);
  assert.match(source, /privateDataExcluded:true/);
});
