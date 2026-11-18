import test from 'node:test';
import assert from 'node:assert/strict';
import { foldResearchRecords } from './researchWorkbench.js';

test('foldResearchRecords folds edits, status transitions, tags, and hides archived theses while preserving root id', () => {
  const raw = [
    {
      id: 'rec-1',
      ticker: 'AMZN',
      asOf: '2026-08-01',
      question: 'Initial cloud margin question?',
      supportingEvidence: 'AWS +19%',
      opposingEvidence: 'Capex rising',
      invalidationCondition: 'AWS margin < 30%',
      reviewDate: '2026-11-01',
      tags: ['Earnings', 'Moat'],
      status: 'open',
      createdAt: '2026-08-01T10:00:00Z',
    },
    {
      id: 'rec-1-rev2',
      parentRecordId: 'rec-1',
      ticker: 'AMZN',
      asOf: '2026-11-02',
      question: 'Updated cloud & custom silicon margin question?',
      supportingEvidence: 'AWS +21%, Trainium ramp',
      opposingEvidence: 'Capex $75B',
      invalidationCondition: 'AWS margin < 32%',
      reviewDate: '2027-02-01',
      tags: ['Earnings', 'Valuation'],
      status: 'validated',
      createdAt: '2026-11-02T10:00:00Z',
    },
    {
      id: 'rec-2',
      ticker: 'FACT',
      asOf: '2026-09-10',
      question: 'Temporary exploratory note',
      status: 'open',
    },
    {
      id: 'rec-2-del',
      parentRecordId: 'rec-2',
      ticker: 'FACT',
      asOf: '2026-09-12',
      question: 'Temporary exploratory note',
      status: 'archived',
    },
  ];

  // Historical cutoff before revision shows original open thesis
  const asOfAug = foldResearchRecords(raw, { asOf: '2026-08-15' });
  assert.equal(asOfAug.length, 1);
  assert.equal(asOfAug[0].id, 'rec-1');
  assert.equal(asOfAug[0].status, 'open');
  assert.equal(asOfAug[0].question, 'Initial cloud margin question?');

  // Latest view shows folded revision 2 for AMZN and hides archived FACT note
  const active = foldResearchRecords(raw);
  assert.equal(active.length, 1);
  assert.equal(active[0].id, 'rec-1');
  assert.equal(active[0].revisionCount, 2);
  assert.equal(active[0].status, 'validated');
  assert.deepEqual(active[0].tags, ['Earnings', 'Valuation']);
  assert.equal(
    active[0].question,
    'Updated cloud & custom silicon margin question?',
  );

  // includeArchived surfaces archived note for audit
  const all = foldResearchRecords(raw, { includeArchived: true });
  assert.equal(all.length, 2);
  assert.equal(all[1].status, 'archived');
});
