import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

test('concurrent generation inspection cannot cache a stale read under the new catalog', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'fact-generation-race-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.mkdir(path.join(root, 'manifests'));
  const manifest = path.join(root, 'manifests/catalog.json');
  const runtime = path.join(root, 'fixture-runtime');
  // Only a synthetic RPC transport: all data and synchronization files are
  // confined to this test's empty temporary directory.
  await fs.writeFile(runtime, `#!${process.execPath}
const fs = require('node:fs');
const root = process.argv[process.argv.indexOf('--root') + 1];
let input = '';
process.stdin.on('data', data => input += data);
process.stdin.on('end', async () => {
  const value = JSON.parse(fs.readFileSync(root + '/manifests/catalog.json'));
  fs.writeFileSync(root + '/started', 'ready');
  while (!fs.existsSync(root + '/continue')) await new Promise(r => setTimeout(r, 10));
  const request = JSON.parse(input);
  const result = request.batch ? request.batch.map(() => ({ ok: true, result: value })) : value;
  process.stdout.write(JSON.stringify({ ok: true, result }));
});
`, { mode: 0o755 });
  const previous = { root: process.env.FACT_OS_ROOT, python: process.env.FACT_OS_PYTHON };
  process.env.FACT_OS_ROOT = root;
  process.env.FACT_OS_PYTHON = runtime;
  t.after(() => {
    for (const [key, value] of [['FACT_OS_ROOT', previous.root], ['FACT_OS_PYTHON', previous.python]]) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
  const { queryFacts, queryFactsBatch, factGeneration } = await import('./factRepository.js');
  for (const batch of [false, true]) {
    await fs.rm(path.join(root, 'started'), { force: true });
    await fs.rm(path.join(root, 'continue'), { force: true });
    await fs.writeFile(manifest, JSON.stringify({ version: batch ? 'old-batch' : 'old-single' }));
    const call = () => batch ? queryFactsBatch([{ method: 'get_coverage' }]) : queryFacts('get_coverage');
    const pending = call();
    const rejected = assert.rejects(pending, { code: 'local_snapshot_changed' });
    const deadline = Date.now() + 5000;
    while (true) {
      try { await fs.stat(path.join(root, 'started')); break; } catch { /* wait for fixture */ }
      assert.ok(Date.now() < deadline, 'synthetic RPC must start');
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    const before = await factGeneration();
    await fs.writeFile(manifest, JSON.stringify({ version: 'new-' + String(batch) + '-longer' }));
    assert.notEqual(await factGeneration(), before);
    await fs.writeFile(path.join(root, 'continue'), 'ready');
    await rejected;
    const next = await call();
    assert.equal(batch ? next[0].result.version : next.version, 'new-' + String(batch) + '-longer');
  }
});
