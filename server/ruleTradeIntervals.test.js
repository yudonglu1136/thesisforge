import test from 'node:test';
import assert from 'node:assert/strict';
import { ruleTradeIntervals } from './ruleTradeIntervals.js';

const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} != ${b}`);
const events = [
  { date: '2024-01-02', side: 'buy', quantity: 10, quantityBefore: 0, quantityAfter: 10, price: 10, cost: 1 },
  { date: '2024-02-01', side: 'buy', quantity: 5, quantityBefore: 10, quantityAfter: 15, price: 20, cost: 2 },
  { date: '2024-03-01', side: 'sell', quantity: 12, quantityBefore: 15, quantityAfter: 3, price: 30, cost: 3 },
];
const args = { events, start: '2024-01-02', end: '2024-04-01', inception: true,
  opening: null, closing: { value: 75, price: 25 }, origin: 1, gross: 235, costs: 6, supported: true };

test('one sale spans two FIFO purchases; remaining lot is a mark, not a sale', () => {
  const r = ruleTradeIntervals(args);
  assert.deepEqual(r.intervals.map(r => [r.buyDate, r.quantity, r.status]), [
    ['2024-01-02', 10, 'closed'], ['2024-02-01', 2, 'closed'], ['2024-02-01', 3, 'open']]);
  close(r.intervals[0].netContribution, 196.5);
  close(r.intervals[1].netContribution, 18.7);
  close(r.intervals[2].netContribution, 13.8);
  close(r.realized + r.unrealized, 229);
});

test('clipped range resets only remaining cost basis and scales all quantities and amounts equally', () => {
  const r = ruleTradeIntervals({ ...args, start: '2024-02-01', inception: false,
    opening: { value: 300, price: 20 }, origin: 2, gross: 67.5, costs: 1.5 });
  assert.ok(r.intervals.every(r => r.carriedIn && r.entryDate === '2024-02-01' && r.entryPrice === 20));
  assert.deepEqual(r.intervals.map(r => r.quantity), [5, 1, 1.5]);
  close(r.reconciliation.net, 66);
  assert.ok(r.intervals.every(r => r.entryCost === 0));
});

test('losses and full liquidation remain signed and closed', () => {
  const r = ruleTradeIntervals({ ...args, events: [events[0], {
    date: '2024-03-01', side: 'sell', quantity: 10, quantityBefore: 10, quantityAfter: 0, price: 5, cost: 1 }],
    closing: null, gross: -50, costs: 2 });
  close(r.intervals[0].netContribution, -52);
  close(r.intervals[0].returnOnBasis, -.52);
  assert.equal(r.intervals[0].exitKind, 'exit');
  close(r.unrealized, 0);
});

test('oversells, inconsistent holdings and broken P&L fail rather than masking a residual', () => {
  for (const mutate of [
    a => { a.events[2].quantity = 16; },
    a => { a.events[2].quantityAfter = 4; },
    a => { a.closing.value = 76; },
    a => { a.gross = 236; },
    a => { a.costs = 7; },
  ]) {
    const a = structuredClone(args); mutate(a);
    assert.throws(() => ruleTradeIntervals(a), /lot_mismatch/);
  }
  assert.equal(ruleTradeIntervals({ ...args, supported: false }).status, 'unavailable_corporate_action');
});
