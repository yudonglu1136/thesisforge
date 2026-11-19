import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function pngDimensions(filePath) {
  const bytes = fs.readFileSync(filePath);
  assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', `${filePath} must be a valid PNG`);
  return `${bytes.readUInt32BE(16)}x${bytes.readUInt32BE(20)}`;
}

test('web/index.html declares full-screen iOS WebApp viewport, SafeArea CSS, 180px icon, and 5 iPhone splash screens', () => {
  const html = fs.readFileSync(path.join(rootDir, 'web', 'index.html'), 'utf8');
  const vercel = JSON.parse(fs.readFileSync(path.join(rootDir, 'vercel.json'), 'utf8'));

  assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1\.0, viewport-fit=cover">/);
  assert.match(html, /<meta name="format-detection" content="telephone=no">/);
  assert.match(html, /<meta name="apple-mobile-web-app-capable" content="yes">/);
  assert.match(html, /<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">/);
  assert.match(html, /height:\s*100dvh/);
  assert.match(html, /overscroll-behavior:\s*none/);
  assert.match(html, /env\(safe-area-inset-top/);

  const icon180 = path.join(rootDir, 'web', 'brand', 'thesisforge-apple-touch-icon-180.png');
  assert.equal(pngDimensions(icon180), '180x180');

  const expectedSplash = [
    ['brand/ios-splash/splash-750x1334.png', '750x1334'],
    ['brand/ios-splash/splash-1170x2532.png', '1170x2532'],
    ['brand/ios-splash/splash-1179x2556.png', '1179x2556'],
    ['brand/ios-splash/splash-1290x2796.png', '1290x2796'],
    ['brand/ios-splash/splash-1320x2868.png', '1320x2868'],
  ];

  for (const [relPath, expectedSize] of expectedSplash) {
    assert.ok(
      html.includes(`href="${relPath}?v=`),
      `web/index.html must reference ${relPath} with cache busting`,
    );
    const fullPath = path.join(rootDir, 'web', relPath);
    assert.equal(pngDimensions(fullPath), expectedSize, `${relPath} dimensions`);
  }

  for (const samplePath of [
    '/brand/thesisforge-apple-touch-icon-180.png',
    '/brand/ios-splash/splash-1179x2556.png',
  ]) {
    const matched = vercel.routes.find(
      (route) => route.headers?.['Cache-Control'] && new RegExp(route.src).test(samplePath),
    );
    assert.ok(matched, `${samplePath} must match an explicit cache rule in vercel.json`);
    assert.match(matched.headers['Cache-Control'], /must-revalidate/);
  }
});
