import test from 'node:test';
import assert from 'node:assert/strict';
import {portfolioBrokerCatalog} from './portfolioBrokerCatalog.js';

test('broker selection distinguishes usable connections from unconfigured integrations', () => {
  const c = portfolioBrokerCatalog();
  assert.equal(c.access, 'read_only');
  assert.deepEqual(c.brokers.map(b => b.id), ['ibkr_flex', 'questrade', 'futu']);
  assert.deepEqual(c.brokers.filter(b => b.available).map(b => b.id), ['ibkr_flex', 'questrade', 'futu']);
  assert.equal(c.brokers[1].connectionMethod, 'personal_api_authorization');
  assert.equal(c.brokers[2].connectionMethod, 'local_opend_connector');
});

test('catalog cannot retain caller mutations or contain account credentials', () => {
  const c = portfolioBrokerCatalog();
  c.brokers[1].available = false;
  assert.equal(portfolioBrokerCatalog().brokers[1].available, true);
  assert.doesNotMatch(JSON.stringify(portfolioBrokerCatalog()), /token|password|secret/i);
});
