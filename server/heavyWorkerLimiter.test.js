import assert from 'node:assert/strict';
import test from 'node:test';
import { HeavyWorkerLimiter } from './heavyWorkerLimiter.js';

test('HeavyWorkerLimiter bounds concurrency and prioritizes interactive high-priority jobs', async () => {
  const limiter = new HeavyWorkerLimiter({ maxActive: 1 });
  const order = [];
  let active = 0;
  let peakActive = 0;

  let releaseFirst;
  const firstGate = new Promise((resolve) => {
    releaseFirst = resolve;
  });

  const job1 = limiter.run(async () => {
    active += 1;
    peakActive = Math.max(peakActive, active);
    order.push('start:1');
    await firstGate;
    order.push('end:1');
    active -= 1;
    return 'one';
  });

  await new Promise((resolve) => setImmediate(resolve));

  const jobNormal = limiter.run(
    async () => {
      active += 1;
      peakActive = Math.max(peakActive, active);
      order.push('run:normal');
      active -= 1;
      return 'normal';
    },
    { priority: 'normal' },
  );

  const jobHigh = limiter.run(
    async () => {
      active += 1;
      peakActive = Math.max(peakActive, active);
      order.push('run:high');
      active -= 1;
      return 'high';
    },
    { priority: 'high' },
  );

  releaseFirst();
  const results = await Promise.all([job1, jobNormal, jobHigh]);
  assert.deepEqual(results, ['one', 'normal', 'high']);
  assert.equal(peakActive, 1);
  assert.deepEqual(order, ['start:1', 'end:1', 'run:high', 'run:normal']);
});
