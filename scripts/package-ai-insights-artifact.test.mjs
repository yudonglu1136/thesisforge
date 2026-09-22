import test from 'node:test';
import a from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { packageAiInsightsArtifact } from './package-ai-insights-artifact.mjs';
import { installAiInsightsArtifact } from './install-ai-insights-artifact.mjs';
import { validateAiInsightsArtifact } from '../server/investmentRuntimeConfig.js';

const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

test('AI artifact packages only bounded derived JSON and installs idempotently', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tf-ai-package-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const source = path.join(root, 'facts'), directory = path.join(source, 'derived/ai-insights/generations');
  fs.mkdirSync(directory, { recursive: true });
  const generation = 'a'.repeat(64), sourceGeneration = 'b'.repeat(64), dependency = 'c'.repeat(64);
  const artifact = { schemaVersion: 1, builderVersion: 'ai-insights-artifact-v3', methodologyVersion: 'ai-insights-v1',
    generationId: generation, generatedAt: '2026-09-22T00:00:00Z', sourceManifestSha256: sourceGeneration,
    dependencySha256: dependency, universeVersion: 'test', universeSha256: 'd'.repeat(64), companies: [], facts: [], inventory: {} };
  const artifactBytes = Buffer.from(JSON.stringify(artifact));
  fs.writeFileSync(path.join(directory, `${generation}.json`), artifactBytes);
  const current = { schemaVersion: 1, builderVersion: 'ai-insights-artifact-v3', generationId: generation,
    generatedAt: artifact.generatedAt, sourceManifestSha256: sourceGeneration, dependencySha256: dependency,
    universeVersion: 'test', universeSha256: 'd'.repeat(64),
    artifactPath: `derived/ai-insights/generations/${generation}.json`, artifactSha256: sha(artifactBytes),
    bytes: artifactBytes.length, rowCount: 0, companyCount: 0, inventory: {} };
  fs.writeFileSync(path.join(source, 'derived/ai-insights/manifest.json'), JSON.stringify(current));
  fs.writeFileSync(path.join(directory, `${generation}.manifest.json`), JSON.stringify(current));
  fs.writeFileSync(path.join(source, 'warehouse.duckdb'), 'private raw database');
  const packaged = path.join(root, 'package');
  const release = packageAiInsightsArtifact({ sourceRoot: source, output: packaged,
    releaseId: 'ai-insights-20260922-v1' });
  a.equal(release.files.some(file => file.relativePath.includes('warehouse')), false);
  const target = path.join(root, 'installed', release.releaseId);
  a.equal(installAiInsightsArtifact({ source: packaged, target }).status, 'installed');
  a.equal(installAiInsightsArtifact({ source: packaged, target }).status, 'already_installed');
  const trustedUid = fs.statSync(target).uid;
  a.equal(validateAiInsightsArtifact(target, path.join(target, 'release-manifest.json'), { trustedUid }).currentGeneration, generation);
  fs.chmodSync(path.join(target, 'derived/ai-insights/generations', `${generation}.json`), 0o600);
  fs.appendFileSync(path.join(target, 'derived/ai-insights/generations', `${generation}.json`), 'x');
  fs.chmodSync(path.join(target, 'derived/ai-insights/generations', `${generation}.json`), 0o400);
  a.throws(() => validateAiInsightsArtifact(target, path.join(target, 'release-manifest.json'), { trustedUid }), /mismatch|hash/);
  fs.chmodSync(target, 0o700);
});

test('Elastic Beanstalk installer consumes the packaged release directory', () => {
  const hook = fs.readFileSync(
    path.resolve('.platform/hooks/postdeploy/06-install-ai-insights.sh'),
    'utf8',
  );
  a.match(hook, /roots != \{expected_root\}/);
  a.match(hook, /source_root="\$\{download\}\/source\/\$\{release_id\}"/);
  a.match(hook, /--source "\$\{source_root\}" --target "\$\{target\}"/);
  a.doesNotMatch(hook, /--source "\$\{download\}\/source"/);
  a.match(hook, /chmod 0755 "\$\(dirname "\$\{runtime_root\}"\)" "\$\{runtime_root\}"/);
  a.ok(
    hook.indexOf('chmod 0755') < hook.indexOf('if [ -e "${target}" ]'),
    'parent traversal permissions must be repaired even when the release already exists',
  );
});
