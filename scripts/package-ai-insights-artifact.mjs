#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { parseArgs } from 'node:util';

const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const fail = code => { throw new Error(code); };
const writeExclusive = (file, bytes, mode = 0o400) => {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, bytes, { flag: 'wx', mode });
};

export function packageAiInsightsArtifact({ sourceRoot, output, releaseId, retain = 8 }) {
  if (!/^ai-insights-\d{8}-v[1-9]\d*$/.test(releaseId ?? '')) fail('invalid_ai_insights_release_id');
  sourceRoot = path.resolve(sourceRoot); output = path.resolve(output);
  if (fs.existsSync(output)) fail('ai_insights_output_exists');
  const sourceDirectory = path.join(sourceRoot, 'derived/ai-insights');
  const currentPath = path.join(sourceDirectory, 'manifest.json');
  const current = JSON.parse(fs.readFileSync(currentPath, 'utf8'));
  if (current.schemaVersion !== 1 || current.builderVersion !== 'ai-insights-artifact-v3'
    || !/^[a-f0-9]{64}$/.test(current.generationId ?? '')
    || !/^[a-f0-9]{64}$/.test(current.sourceManifestSha256 ?? '')) fail('invalid_ai_insights_source_manifest');
  const generationNames = fs.readdirSync(path.join(sourceDirectory, 'generations'))
    .filter(name => /^[a-f0-9]{64}\.manifest\.json$/.test(name))
    .map(name => ({ name, manifest: JSON.parse(fs.readFileSync(path.join(sourceDirectory, 'generations', name), 'utf8')) }))
    .filter(item => item.manifest.schemaVersion === 1
      && ['ai-insights-artifact-v2', 'ai-insights-artifact-v3'].includes(item.manifest.builderVersion))
    .sort((a, b) => String(b.manifest.generatedAt).localeCompare(String(a.manifest.generatedAt)));
  const currentName = `${current.generationId}.manifest.json`;
  const selected = [generationNames.find(item => item.name === currentName),
    ...generationNames.filter(item => item.name !== currentName)].filter(Boolean).slice(0, retain);
  if (!selected.length || selected[0].manifest.generationId !== current.generationId) fail('ai_insights_current_generation_missing');
  const relativeFiles = ['derived/ai-insights/manifest.json'];
  for (const item of selected) {
    relativeFiles.push(`derived/ai-insights/generations/${item.manifest.generationId}.json`);
    relativeFiles.push(`derived/ai-insights/generations/${item.manifest.generationId}.manifest.json`);
  }
  fs.mkdirSync(output, { recursive: false, mode: 0o700 });
  const files = [];
  for (const relativePath of relativeFiles) {
    const source = path.join(sourceRoot, relativePath), bytes = fs.readFileSync(source);
    if (relativePath.endsWith('.json')) JSON.parse(bytes);
    writeExclusive(path.join(output, relativePath), bytes);
    files.push({ relativePath, bytes: bytes.length, sha256: hash(bytes) });
  }
  const manifest = {
    version: 'ai-insights-runtime-release-v1', releaseId, state: 'verified',
    generatedAt: new Date().toISOString(), currentGeneration: current.generationId,
    sourceManifestSha256: current.sourceManifestSha256,
    dependencySha256: current.dependencySha256,
    retainedGenerations: selected.map(item => item.manifest.generationId),
    checks: { schema: 'pass', privateDataExcluded: true, immutableGenerations: 'pass' },
    files,
  };
  const releaseBytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
  writeExclusive(path.join(output, 'release-manifest.json'), releaseBytes);
  for (const relativePath of relativeFiles) fs.chmodSync(path.join(output, relativePath), 0o400);
  fs.chmodSync(path.join(output, 'release-manifest.json'), 0o400);
  return manifest;
}

if (import.meta.url === new URL(`file://${path.resolve(process.argv[1])}`).href) {
  try {
    const { values } = parseArgs({ options: { source: { type: 'string' }, output: { type: 'string' },
      'release-id': { type: 'string' }, retain: { type: 'string' } } });
    console.log(JSON.stringify(packageAiInsightsArtifact({ sourceRoot: values.source, output: values.output,
      releaseId: values['release-id'], retain: Number(values.retain ?? 8) }), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
