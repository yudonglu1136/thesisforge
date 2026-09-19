import test from 'node:test';
import assert from 'node:assert/strict';
import { parseSrt, storyBoundaries } from './export-thesisforge-research-story.mjs';

test('parses neural sentence timestamps precisely', () => {
  assert.deepEqual(parseSrt('1\n00:00:03,367 --> 00:00:04,987\nFirst, pick a holding.\n'), [{ start: 3.367, end: 4.987, text: 'First, pick a holding.' }]);
});
test('rejects reversed speech boundaries', () => {
  assert.throws(() => parseSrt('1\n00:00:04,000 --> 00:00:03,000\nOops.'));
});
test('rejects a different or truncated narration instead of guessing cut points', () => {
  assert.throws(() => storyBoundaries([{ start: 0, end: 1, text: 'Unrelated story.' }], 35));
});
