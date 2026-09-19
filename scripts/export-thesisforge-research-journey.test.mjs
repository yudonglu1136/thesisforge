import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { validateCapture, expandCaptureManifests, layerSvg, srtTimestamp } from './export-thesisforge-research-journey.mjs';

const valid = () => ({
  outputDir: '/tmp/research-journey-test', capturedAt: '2026-09-05T00:00:00Z',
  guruName: 'Example Manager', ticker: 'TEST',
  holdingEvidence: 'Fixture only; never used as production screen content.',
  scenes: [0, 1, 2, 2, 3, 3].map((step) => ({
    step, durationSeconds: 5, instruction: 'Inspect the selected stock.',
    benefit: 'Compare reported holdings with a dated model estimate.',
    dataDate: 'Test fixture, not financial evidence',
    sourceUrl: 'https://www.thesisforge.tech/?view=guru&lang=en',
    source: '/tmp/test-source.jpg', mediaType: 'image',
  })),
});

test('accepts coherent ordered thirty-second journey', () => {
  const config = valid();
  assert.equal(validateCapture(config), config);
});
test('rejects a different valuation ticker', () => {
  const config = valid(); config.scenes[5].ticker = 'OTHER';
  assert.throws(() => validateCapture(config), /differs/);
});
test('rejects backward journey steps', () => {
  const config = valid(); config.scenes[4].step = 1;
  assert.throws(() => validateCapture(config), /without going backward/);
});
test('rejects missing reported holding evidence', () => {
  const config = valid(); config.holdingEvidence = '';
  assert.throws(() => validateCapture(config), /holdingEvidence/);
});
test('rejects a disconnected screen collage', () => {
  const config = valid(); config.scenes[0].panels = [{}, {}];
  assert.throws(() => validateCapture(config), /Disconnected UI panels/);
});
test('rejects localhost presented as current production', () => {
  const config = valid(); config.scenes[0].sourceUrl = 'http://localhost:8080/';
  assert.throws(() => validateCapture(config), /real production/);
});
test('rejects incomplete screenshot timing', () => {
  const config = valid(); delete config.scenes[0].source;
  config.scenes[0].frames = [{ path: '/tmp/a.jpg', durationSeconds: 2 }];
  assert.throws(() => validateCapture(config), /durations do not equal/);
});
test('rejects excessive caption lengths', () => {
  const config = valid(); config.scenes[0].instruction = 'x'.repeat(89);
  assert.throws(() => validateCapture(config), /instruction must be/);
});
test('caption SVG escapes exact copy without changing display text', () => {
  const config = valid(); config.scenes[0].instruction = 'Check revenue & margin < assumptions.';
  const svg = layerSvg(config, 0, true).toString();
  assert.match(svg, /revenue &amp; margin &lt; assumptions/);
  assert.match(svg, /Position history/);
  assert.match(svg, /Valuation/);
  assert.doesNotMatch(svg, /Explore the ISRG case/);
});
test('SRT time carries milliseconds through minute boundary', () => {
  assert.equal(srtTimestamp(59.9998), '00:01:00,000');
  assert.equal(srtTimestamp(31.5), '00:00:31,500');
});
test('timestamped selection preserves order and exactly rescales durations', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'journey-manifest-test-'));
  try {
    const file = path.join(directory, 'capture.json');
    await writeFile(file, JSON.stringify({
      frames: [{ file: 'a.jpg', t: 0 }, { file: 'b.jpg', t: 2 }, { file: 'c.jpg', t: 5 }],
      duration: 8, capturedAt: '2026-09-05T00:00:00Z', captureMethod: 'Test fixture only',
      sourceUrl: 'https://www.thesisforge.tech/',
    }));
    const config = valid();
    delete config.scenes[0].source;
    config.scenes[0].captureManifest = file;
    config.scenes[0].startSeconds = 1;
    config.scenes[0].endSeconds = 7;
    const result = await expandCaptureManifests(config);
    assert.deepEqual(result.scenes[0].frames.map((frame) => path.basename(frame.path)), ['a.jpg', 'b.jpg', 'c.jpg']);
    assert.equal(result.scenes[0].frames.reduce((sum, frame) => sum + frame.durationSeconds, 0), 5);
    assert.equal(result.scenes[0].captureProvenance.timingScale, 1.2);
    assert.equal(result.scenes[0].captureProvenance.selectedStartSeconds, 1);
    assert.equal(config.scenes[0].frames, undefined, 'Input manifest remains unmodified.');
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test('capture manifest refuses path traversal', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'journey-manifest-test-'));
  try {
    const file = path.join(directory, 'capture.json');
    await writeFile(file, JSON.stringify({ frames: [{ file: '../outside.jpg', t: 0 }, { file: 'b.jpg', t: 2 }], duration: 5 }));
    const config = valid(); delete config.scenes[0].source;
    config.scenes[0].captureManifest = file;
    await assert.rejects(() => expandCaptureManifests(config), /plain basenames/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
