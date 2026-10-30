import test from 'node:test';
import assert from 'node:assert/strict';
import {questradeApiOrigin, refreshQuestradeSession, readQuestradeAccounts} from './questradeReadOnly.js';
const now = Date.parse('2026-10-30T07:00:00Z');
const response = value => ({ok: true, json: async () => value});
const session = {apiOrigin: 'https://api01.iq.questrade.com', accessToken: 'synthetic-access-token',
  expiresAt: '2026-10-30T07:30:00Z'};

test('rejects untrusted API origins, credential URLs and redirected credential requests', async () => {
  for (const url of ['http://api01.iq.questrade.com', 'https://localhost',
    'https://api01.iq.questrade.com.evil.test', 'https://a:b@api01.iq.questrade.com',
    'https://api01.iq.questrade.com:8443', 'https://api01.iq.questrade.com/v1/orders']) {
    assert.throws(() => questradeApiOrigin(url));
  }
  assert.equal(questradeApiOrigin(session.apiOrigin + '/v1/'), session.apiOrigin);
  await assert.rejects(readQuestradeAccounts(session, {now, fetchImpl: async (_, options) => {
    assert.equal(options.redirect, 'error'); throw new Error('secret response');
  }}), {message: 'questrade_connection_failed'});
});

test('rotated tokens must be persisted before any account fetch', async () => {
  let saved;
  const s = await refreshQuestradeSession('synthetic-refresh-token', {now,
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://login.questrade.com/oauth2/token');
      assert.equal(options.method, 'POST');
      assert.equal(options.body.get('grant_type'), 'refresh_token');
      return response({access_token: session.accessToken, refresh_token: 'rotated-refresh-token',
        token_type: 'Bearer', expires_in: 1800, api_server: session.apiOrigin});
    }, persistSession: async value => {saved = value;}});
  assert.equal(saved, s);
  assert.equal(saved.refreshToken, 'rotated-refresh-token');
  await assert.rejects(refreshQuestradeSession('synthetic-refresh-token'), /persistence_required/);
});

test('account reads expose only fixed GETs and preserve currency views without double counting', async () => {
  const paths = [];
  const report = await readQuestradeAccounts(session, {now, fetchImpl: async (url, options) => {
    assert.equal(options.method, 'GET'); paths.push(new URL(url).pathname);
    if (url.endsWith('/accounts')) return response({accounts: [{number: '1234', type: 'Margin'}]});
    if (url.endsWith('/balances')) return response({perCurrencyBalances: [{currency: 'USD', cash: 10}],
      combinedBalances: [{currency: 'USD', totalEquity: 110}, {currency: 'CAD', totalEquity: 150}]});
    return response({positions: [{symbol: 'EXAMPLE', symbolId: 42, openQuantity: 2, currentMarketValue: 100}]});
  }});
  assert.deepEqual(paths, ['/v1/accounts', '/v1/accounts/1234/balances', '/v1/accounts/1234/positions']);
  assert.equal(report.accounts.length, 1);
  assert.equal(report.accounts[0].balances.combinedBalances.length, 2);
});

test('invalid identities, expired sessions and upstream failures never produce partial success', async () => {
  await assert.rejects(readQuestradeAccounts({...session, expiresAt: '2020-01-01'}, {now}), /expired/);
  await assert.rejects(readQuestradeAccounts(session, {now,
    fetchImpl: async () => response({accounts: [{number: '../orders'}]})}), /invalid_accounts/);
  await assert.rejects(readQuestradeAccounts(session, {now,
    fetchImpl: async () => ({ok: false, status: 401})}), /authorization_expired/);
});
