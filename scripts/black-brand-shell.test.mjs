import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const root = new URL('../', import.meta.url);

function pngDimensions(buffer, label) {
  assert.equal(buffer.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', `${label} must be a valid PNG`);
  return `${buffer.readUInt32BE(16)}x${buffer.readUInt32BE(20)}`;
}

test('startup, favicon, PWA manifest, and app brand use only ThesisForge and the Black Edition mark', () => {
  const html = fs.readFileSync(new URL('web/index.html', root), 'utf8');
  const refreshHtml = fs.readFileSync(new URL('web/refresh.html', root), 'utf8');
  const isrgHtml = fs.readFileSync(new URL('web/research/isrg/index.html', root), 'utf8');
  const manifest = JSON.parse(fs.readFileSync(new URL('web/manifest.json', root), 'utf8'));
  const mainDart = fs.readFileSync(new URL('lib/main.dart', root), 'utf8');
  const officialBlackMark = fs.readFileSync(new URL('assets/branding/thesisforge-black-mark.png', root));
  const fallbackMark = fs.readFileSync(new URL('assets/branding/thesisforge-mark.png', root));

  assert.equal(Buffer.compare(officialBlackMark, fallbackMark), 0, 'both branding assets must be the official black mark');
  assert.equal(manifest.name, 'ThesisForge');
  assert.equal(manifest.short_name, 'ThesisForge');
  assert.equal(manifest.theme_color, '#000000');
  assert.equal(manifest.background_color, '#000000');
  assert.ok(manifest.icons.length >= 2, 'manifest must declare web install icons');

  for (const icon of manifest.icons) {
    const cleanPath = icon.src.split('?')[0];
    assert.match(icon.src, /\?v=/, `${icon.src} must include a cache-busting query`);
    const bytes = fs.readFileSync(new URL(`web/${cleanPath}`, root));
    assert.equal(icon.sizes, pngDimensions(bytes, cleanPath));
  }

  assert.match(html, /<title>ThesisForge<\/title>/);
  assert.match(html, /rel="icon"[^>]+brand\/thesisforge-black-mark-64\.png\?v=/);
  assert.match(html, /rel="apple-touch-icon"[^>]+brand\/thesisforge-black-mark-192\.png\?v=/);
  assert.match(html, /class="app-loading-mark"[^>]+brand\/thesisforge-black-mark-192\.png\?v=/);
  assert.doesNotMatch(html, /#22d3a6|#40d8b0|#0d1f24/i);
  assert.match(isrgHtml, /rel="icon"[^>]+brand\/thesisforge-black-mark-64\.png\?v=/);
  assert.match(isrgHtml, /brand\/thesisforge-black-mark-192\.png\?v=/);

  const retiredBrandRe = /guru\s*intel(?:l?igence)?|updating\s+guru|大师投研智库/i;
  for (const [label, text] of [
    ['web/index.html', html],
    ['web/refresh.html', refreshHtml],
    ['web/manifest.json', JSON.stringify(manifest)],
    ['web/research/isrg/index.html', isrgHtml],
    ['lib/main.dart', mainDart],
  ]) {
    assert.doesNotMatch(text, retiredBrandRe, `${label} must not contain retired Guru brand names`);
  }
});
