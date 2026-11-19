import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const downloadHtmlPath = path.join(rootDir, 'web', 'download', 'index.html');
const mobileconfigPath = path.join(rootDir, 'web', 'download', 'ThesisForge_iPhone_App.mobileconfig');
const dmgPath = path.join(rootDir, 'web', 'download', 'ThesisForge_macOS_v1.0.dmg');
const vercelPath = path.join(rootDir, 'vercel.json');

test('iPhone .mobileconfig file passes Apple plutil validation and launches ThesisForge full-screen', () => {
  assert.ok(fs.existsSync(mobileconfigPath), 'web/download/ThesisForge_iPhone_App.mobileconfig must exist');
  const lintOut = execFileSync('plutil', ['-lint', mobileconfigPath], { encoding: 'utf8' });
  assert.match(lintOut, /OK/);

  const xml = fs.readFileSync(mobileconfigPath, 'utf8');
  // Apple iOS PayloadType is strictly case-sensitive: must be com.apple.webClip.managed (capital C!)
  assert.match(xml, /<string>com\.apple\.webClip\.managed<\/string>/);
  assert.doesNotMatch(xml, /com\.apple\.webclip\.managed/);
  assert.match(xml, /<key>FullScreen<\/key>\s*<true\/>/);
  assert.match(xml, /<key>IgnoreManifestScope<\/key>\s*<true\/>/);
  assert.match(xml, /<key>Precomposed<\/key>\s*<true\/>/);
  assert.match(xml, /<key>IsRemovable<\/key>\s*<true\/>/);
  assert.match(xml, /https:\/\/(?:www\.)?thesisforge\.tech\/\?launch=ios_webclip/);
  assert.match(xml, /<string>ThesisForge<\/string>/);
  assert.doesNotMatch(xml, /guru\s*intel+igence/i);
});

test('macOS .dmg disk image exists in web/download and is non-trivial UDZO bundle', () => {
  assert.ok(fs.existsSync(dmgPath), 'web/download/ThesisForge_macOS_v1.0.dmg must exist');
  const stat = fs.statSync(dmgPath);
  assert.ok(stat.size > 500 * 1024, `expected DMG > 500 KB, got ${stat.size} bytes`);
  assert.ok(stat.size < 25 * 1024 * 1024, `expected DMG < 25 MB, got ${stat.size} bytes`);
});

test('Direct Download Center HTML uses dark obsidian theme and official black ThesisForge brand', () => {
  const html = fs.readFileSync(downloadHtmlPath, 'utf8');
  assert.match(html, /#080b0f/i);
  assert.match(html, /\/download\/ThesisForge_iPhone_App\.mobileconfig/);
  assert.match(html, /\/download\/ThesisForge_macOS_v1\.0\.dmg/);
  assert.match(html, /thesisforge-apple-touch-icon-180\.png/);
  assert.doesNotMatch(html, /guru\s*intel+igence/i);
  // Ensure the .mobileconfig link does not force HTML download attribute which would bypass iOS Profile prompt
  const mobileconfigAnchor = html.match(/<a[^>]*ThesisForge_iPhone_App\.mobileconfig[^>]*>/);
  assert.ok(mobileconfigAnchor, 'must include anchor for .mobileconfig');
  assert.doesNotMatch(mobileconfigAnchor[0], /\bdownload=/i);
});

test('vercel.json serves /download/ and Apple installer MIME types before SPA fallback', () => {
  const vercel = JSON.parse(fs.readFileSync(vercelPath, 'utf8'));
  const routes = vercel.routes;

  const fsIdx = routes.findIndex((r) => r.handle === 'filesystem');
  const catchAllIdx = routes.findIndex((r) => r.src === '/(.*)' && r.dest === '/index.html');
  const mobileconfigIdx = routes.findIndex((r) => r.src === '^/download/ThesisForge_iPhone_App\\.mobileconfig$');
  const dmgIdx = routes.findIndex((r) => r.src === '^/download/ThesisForge_macOS_v1\\.0\\.dmg$');
  const downloadIndexIdx = routes.findIndex((r) => r.src === '^/download/$' && r.dest === '/download/index.html');

  assert.ok(mobileconfigIdx >= 0 && mobileconfigIdx < fsIdx, '.mobileconfig header route must precede filesystem');
  assert.ok(dmgIdx >= 0 && dmgIdx < fsIdx, '.dmg header route must precede filesystem');
  assert.ok(downloadIndexIdx >= 0 && downloadIndexIdx < catchAllIdx, '/download/ route must precede SPA catch-all');
  assert.ok(fsIdx < catchAllIdx, 'filesystem handle must precede SPA catch-all');

  assert.equal(routes[mobileconfigIdx].headers['Content-Type'], 'application/x-apple-aspen-config');
  assert.equal(routes[dmgIdx].headers['Content-Type'], 'application/x-apple-diskimage');
});
