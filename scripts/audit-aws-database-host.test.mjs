import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

test('host operator tool requires explicit invocation before accessing AWS', () => {
  const result = spawnSync(process.execPath, [new URL('./audit-aws-database-host.mjs', import.meta.url).pathname], {
    encoding: 'utf8', timeout: 10_000
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Explicit --read-only required/);
});

test('host operator guardrails retain verified identity, exact ingress cleanup and isolated restore', () => {
  const source = fs.readFileSync(new URL('./audit-aws-database-host.mjs', import.meta.url), 'utf8');
  assert.match(source, /StrictHostKeyChecking=yes/);
  assert.match(source, /fingerprints\.has\(fingerprint\)/);
  assert.match(source, /CidrIp: `\$\{myIp\}\/32`/);
  assert.match(source, /finally \{[\s\S]*revoke-security-group-ingress[\s\S]*--security-group-rule-ids/);
  assert.match(source, /process\.setgid\(gid\);process\.setuid\(uid\)/);
  assert.match(source, /output:path\.join\(scratch,'restored'\)/);
  assert.match(source, /offHostBackupVerified:false/);
  assert.doesNotMatch(source, /StrictHostKeyChecking=no|0\.0\.0\.0\/0|reboot-instances|update-environment/);
});
