#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { parseArgs } from 'node:util';

const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fail = code => { throw new Error(code); };

export function installAiInsightsArtifact({ source, target }) {
  source = path.resolve(source); target = path.resolve(target);
  const release = JSON.parse(fs.readFileSync(path.join(source, 'release-manifest.json'), 'utf8'));
  if (release.version !== 'ai-insights-runtime-release-v1' || release.state !== 'verified'
    || release.checks?.privateDataExcluded !== true || !Array.isArray(release.files)) fail('invalid_ai_insights_release');
  const verify = root => {
    for (const entry of release.files) {
      const file = path.resolve(root, entry.relativePath);
      if (!file.startsWith(`${root}${path.sep}`) || !fs.statSync(file).isFile()
        || fs.statSync(file).size !== entry.bytes || digest(file) !== entry.sha256) fail('ai_insights_install_file_mismatch');
    }
  };
  verify(source);
  if (fs.existsSync(target)) {
    const installed = JSON.parse(fs.readFileSync(path.join(target, 'release-manifest.json'), 'utf8'));
    if (installed.releaseId !== release.releaseId) fail('ai_insights_install_target_conflict');
    verify(target); return { status: 'already_installed', ...release };
  }
  const stage = `${target}.part`;
  if (fs.existsSync(stage)) fail('ai_insights_partial_install_requires_review');
  fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  fs.mkdirSync(stage, { recursive: true, mode: 0o700 });
  try {
    for (const entry of release.files) {
      const destination = path.join(stage, entry.relativePath);
      fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
      fs.copyFileSync(path.join(source, entry.relativePath), destination, fs.constants.COPYFILE_EXCL);
      fs.chmodSync(destination, 0o400);
    }
    fs.copyFileSync(path.join(source, 'release-manifest.json'), path.join(stage, 'release-manifest.json'), fs.constants.COPYFILE_EXCL);
    fs.chmodSync(path.join(stage, 'release-manifest.json'), 0o400);
    verify(stage);
    fs.renameSync(stage, target); fs.chmodSync(target, 0o500);
    return { status: 'installed', ...release };
  } catch (error) {
    fs.rmSync(stage, { recursive: true, force: true }); throw error;
  }
}

if (import.meta.url === new URL(`file://${path.resolve(process.argv[1])}`).href) {
  try {
    const { values } = parseArgs({ options: { source: { type: 'string' }, target: { type: 'string' } } });
    console.log(JSON.stringify(installAiInsightsArtifact(values)));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
