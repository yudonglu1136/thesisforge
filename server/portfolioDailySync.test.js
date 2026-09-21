import test from 'node:test';
import assert from 'node:assert/strict';
import { syncRegisteredPortfolioUsers } from './portfolioClient.js';

const users = [
  {
    userId: '11111111-1111-4111-8111-111111111111',
    email: 'owner-one@example.test',
    connection: { configured: true },
  },
  {
    userId: '22222222-2222-4222-8222-222222222222',
    email: 'owner-two@example.test',
    connection: { configured: true },
  },
  {
    userId: '33333333-3333-4333-8333-333333333333',
    connection: { configured: false },
  },
  { userId: 'local-dev-user', connection: { configured: true } },
];

test('daily portfolio sync refreshes only configured production owners and records NAV', async () => {
  const calls = [], clears = [];
  const result = await syncRegisteredPortfolioUsers({
    listUsers: async () => ({ users }),
    clearCache: (user) => clears.push(user.id),
    loadDashboard: async (options) => {
      calls.push(options);
      if (options.user.id.startsWith('2')) {
        return {
          source: { mode: 'saved_broker_report' },
          freshness: { status: 'stale' },
          connection: { status: 'stale_report' },
          performanceStatus: { pointCount: 8 },
        };
      }
      return {
        source: { mode: 'live' },
        freshness: { status: 'current_report' },
        connection: { status: 'linked' },
        performanceStatus: { pointCount: 12 },
      };
    },
  });
  assert.equal(result.status, 'degraded');
  assert.deepEqual(result, {
    status: 'degraded', connected: 2, attempted: 2, synced: 1,
    degraded: 1, failed: 0, navPoints: 20,
  });
  assert.equal(calls.length, 2);
  assert.ok(calls.every((row) => row.forceRefresh && row.captureNav));
  assert.deepEqual(clears, [
    users[0].userId, users[0].userId,
    users[1].userId, users[1].userId,
  ]);
  assert.ok(!JSON.stringify(result).includes('@example.test'));
});

test('daily portfolio sync reports failures without exposing owner identity', async () => {
  const result = await syncRegisteredPortfolioUsers({
    listUsers: async () => ({ users: [users[0]] }),
    clearCache: () => {},
    loadDashboard: async () => { throw new Error('private owner failure'); },
  });
  assert.deepEqual(result, {
    status: 'degraded', connected: 1, attempted: 1, synced: 0,
    degraded: 0, failed: 1, navPoints: 0,
  });
  assert.ok(!JSON.stringify(result).includes('private owner failure'));
});
