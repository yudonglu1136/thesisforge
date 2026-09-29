import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const root = new URL('../', import.meta.url);
test('startup, favicon and install icon use the shipped Black Edition mark', () => {
  const html = fs.readFileSync(new URL('web/index.html', root), 'utf8');
  const manifest = JSON.parse(fs.readFileSync(new URL('web/manifest.json', root)));
  const mark = fs.readFileSync(new URL('assets/branding/thesisforge-black-mark.png', root));
  assert.equal(manifest.theme_color, '#000000');
  assert.equal(manifest.background_color, '#000000');
  for (const icon of manifest.icons) {
    assert.match(icon.src, /thesisforge-black-mark\.png\?v=/);
    assert.equal(icon.sizes, `${mark.readUInt32BE(16)}x${mark.readUInt32BE(20)}`);
  }
  assert.match(html, /rel="icon"[^>]+thesisforge-black-mark/);
  assert.match(html, /rel="apple-touch-icon"[^>]+thesisforge-black-mark/);
  assert.doesNotMatch(html, /#22d3a6|#40d8b0|#0d1f24|favicon\.png/i);
});
