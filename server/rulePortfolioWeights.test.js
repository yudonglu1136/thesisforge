import assert from 'node:assert/strict';
import test from 'node:test';
import { qualityRankWeights } from './rulePortfolioWeights.js';

test('Top 10 uses sqrt(11-rank), normalized then capped; not the old buffered portfolio', () => {
  const rows = Array.from({ length: 12 }, (_, i) => ({ ticker: `T${i}`, rank: i + 1 }));
  const out = qualityRankWeights(rows);
  const denominator = rows.slice(0, 10).reduce((s, r) => s + Math.sqrt(11 - r.rank), 0);
  assert.equal(out.positions.length, 10);
  out.positions.forEach((r, i) => {
    assert.ok(Math.abs(r.weight - Math.sqrt(10 - i) / denominator) < 1e-14);
    assert.ok(r.weight <= .15);
  });
  assert.ok(Math.abs(out.cashWeight) < 1e-14);
});
test('fewer names leave capped excess in cash; empty selection is cash', () => {
  const out = qualityRankWeights([{ ticker: 'A', rank: 1 }, { ticker: 'B', rank: 2 }]);
  assert.deepEqual(out.positions.map(r => r.weight), [.15, .15]);
  assert.equal(out.cashWeight, .7);
  assert.deepEqual(qualityRankWeights([]), { positions: [], cashWeight: 1 });
});
test('invalid or duplicate ranks/identities fail instead of altering the allocation', () => {
  for (const rows of [[{ ticker: 'A', rank: 0 }], [{ ticker: 'A', rank: 1 }, { ticker: 'B', rank: 1 }],
    [{ ticker: 'A', rank: 1 }, { ticker: 'A', rank: 2 }], [{ ticker: 'A', rank: NaN }]]) {
    assert.throws(() => qualityRankWeights(rows), /invalid_quality_rank/);
  }
});
