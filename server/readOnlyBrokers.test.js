import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'broker-readonly-'));
process.env.USER_PORTFOLIO_DATA_DIR = path.join(root, 'users');
process.env.PORTFOLIO_CREDENTIALS_KEY = 'synthetic-broker-test-key';
const store = await import('./userPortfolioStore.js');
const broker = await import('./readOnlyBrokers.js');
test.after(() => {store.closeUserPortfolioStores(); fs.rmSync(root, {recursive: true, force: true});});
const user = {id: 'synthetic-owner'}, other = {id: 'synthetic-other'};
const response = body => ({ok: true, json: async () => body});
const fetchImpl = async url => {
  if (url.endsWith('/token')) return response({access_token: 'synthetic-access-token',
    refresh_token: 'synthetic-rotated-token', token_type: 'Bearer', expires_in: 1800,
    api_server: 'https://api01.iq.questrade.com'});
  if (url.endsWith('/accounts')) return response({accounts: [{number: '1234', type: 'Margin'}]});
  if (url.endsWith('/balances')) return response({perCurrencyBalances: [{currency: 'CAD', cash: 10, totalEquity: 10}], combinedBalances: []});
  return response({positions: []});
};

test('Questrade persists encrypted rotated tokens and snapshots without touching IBKR', async () => {
  store.savePortfolioConnection(user, {ibkrFlexToken: 'SYNTHETIC_IBKR_TOKEN', ibkrFlexQueryId: '123456'});
  const revision = store.portfolioConnectionRevision(user);
  const result = await broker.syncQuestrade(user, {refreshToken: 'synthetic-start-token', fetchImpl});
  assert.equal(result.status, 'connected');
  assert.equal(result.snapshot.accounts[0].balances[0].currency, 'CAD');
  assert.doesNotMatch(JSON.stringify(result), /synthetic.*token/);
  assert.equal(store.portfolioConnectionRevision(user), revision);
  assert.equal(broker.readBrokerStatus(other, 'questrade').snapshot, null);
  assert.equal(store.readReadOnlyBroker(user, 'questrade').session.refreshToken, 'synthetic-rotated-token');
  store.closeUserPortfolioStores();
  assert.equal(broker.readBrokerStatus(user, 'questrade').snapshot.accounts.length, 1);
});

test('failed sync retains previous snapshot and excludes parallel refreshes', async () => {
  const prior = broker.readBrokerStatus(user, 'questrade').snapshot;
  await assert.rejects(broker.syncQuestrade(user, {fetchImpl: async () => {throw Error('sensitive');}}), /broker_sync_failed/);
  assert.deepEqual(broker.readBrokerStatus(user, 'questrade').snapshot, prior);
  assert.equal(broker.readBrokerStatus(user, 'questrade').status, 'error');
  let release;
  const pending = broker.syncQuestrade(user, {fetchImpl: async url => {
    if (url.endsWith('/token')) await new Promise(resolve => {release = resolve;});
    return fetchImpl(url);
  }});
  await assert.rejects(broker.syncQuestrade(user, {fetchImpl}), /broker_sync_busy/);
  broker.disconnectBroker(user, 'questrade');
  release();
  await assert.rejects(pending, /broker_connection_changed/);
  assert.equal(broker.readBrokerStatus(user, 'questrade').connected, false);
});

test('Futu token is owner scoped, upload-only, revocable and rejects stale data', () => {
  const {connectorToken} = broker.pairFutu(user);
  const input = {provider: 'futu', access: 'read_only', retrievedAt: new Date().toISOString(),
    account: {acc_id: 42, trd_env: 'REAL'}, funds: {currency: 'USD', total_assets: 100}, positions: []};
  assert.equal(broker.acceptFutuSnapshot(connectorToken, input).ok, true);
  assert.equal(broker.readBrokerStatus(user, 'futu').snapshot.accounts[0].balances[0].totalEquity, 100);
  assert.equal(broker.readBrokerStatus(other, 'futu').snapshot, null);
  assert.doesNotMatch(JSON.stringify(broker.readBrokerStatus(user, 'futu')), /tokenHash|connectorToken/);
  assert.throws(() => broker.acceptFutuSnapshot(connectorToken, {...input, retrievedAt: '2020-01-01'}), /invalid/);
  broker.pairFutu(user);
  assert.throws(() => broker.acceptFutuSnapshot(connectorToken, input), /unauthorized/);
  const next = broker.pairFutu(user).connectorToken;
  broker.disconnectBroker(user, 'futu');
  assert.throws(() => broker.acceptFutuSnapshot(next, input), /unauthorized/);
});
