import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { isRetiredApiPath } from './retiredProductRoutes.js';

const configPath = fileURLToPath(new URL('../ops/caddy/Caddyfile', import.meta.url));
const config = fs.readFileSync(configPath, 'utf8');
const apiConfig = config.slice(config.indexOf('\napi.thesisforge.tech {'));
const matcher = apiConfig.match(/^\s*@retired_product path_regexp retired_product (.+)$/m)?.[1];
assert.ok(matcher?.startsWith('(?i)^'), 'Retirement uses an anchored, case-insensitive Caddy RE2 matcher');
// These expressions use only the common JS/RE2 syntax. Caddy matches the
// decoded path; query strings are not part of its path_regexp input.
const retiredPattern = new RegExp(matcher.slice(4), 'i');
const caddyMatches = path => retiredPattern.test(decodeURIComponent(path.split(/[?#]/, 1)[0]));

test('Caddy locally retires every legacy API family and the dedicated health probe', () => {
  for (const path of ['/api/ontology', '/api/dbmf', '/api/strategies', '/api/decision', '/api/market']) {
    for (const suffix of ['', '/', '/nested/snapshot?as_of=2026-08-13']) {
      const route = `${path}${suffix}`;
      assert.equal(isRetiredApiPath(route), true, route);
      assert.equal(caddyMatches(route), true, route);
      assert.equal(caddyMatches(route.toUpperCase()), true, route);
    }
  }
  for (const path of ['/api/overview', '/api/graph', '/api/methodology', '/api/timeline',
    '/api/rankings', '/api/snapshot', '/api/company/PLTR', '/api/investment/value-flow']) {
    for (const route of [path, `${path}/`, `${path}?refresh=1`]) {
      assert.equal(isRetiredApiPath(route), true, route);
      assert.equal(caddyMatches(route), true, route);
    }
  }
  for (const route of ['/ontology-health', '/ontology-health/', '/ONTOLOGY-HEALTH',
    '/api/%6fntology/overview', '/api/company/%50LTR']) {
    assert.equal(caddyMatches(route), true, route);
  }
});

test('Caddy does not retire active investment, CTA, Guru, valuation or similarly named paths', () => {
  for (const route of ['/api/health', '/api/gurus', '/api/gurus/bill-ackman',
    '/api/valuation/PLTR', '/api/portfolio', '/api/admin/system-health',
    '/api/investment/discover', '/api/investment/ai-insights',
    '/api/investment/strategy-lab', '/api/investment/strategy-backtests',
    '/api/investment/strategy-rules', '/api/marketplace', '/api/ontology-extra',
    '/api/strategies-extra', '/api/graphing', '/api/company', '/api/company/PLTR/extra',
    '/ontology-health-extra']) {
    assert.equal(isRetiredApiPath(route), false, route);
    assert.equal(caddyMatches(route), false, route);
  }
});

test('retired Caddy handler returns no-store JSON 410 without any forwarding or method restriction', () => {
  const handler = apiConfig.match(/handle @retired_product \{([\s\S]*?)^  \}/m)?.[1];
  assert.ok(handler);
  assert.match(handler, /header Cache-Control "no-store"/);
  assert.match(handler, /header Content-Type "application\/json"/);
  assert.match(handler, /respond `\{"error":"module_retired"\}` 410/);
  assert.doesNotMatch(handler, /reverse_proxy|rewrite|forward_auth|request_body|\bmethod\b/);
  assert.doesNotMatch(config, /8791/);
  assert.match(apiConfig, /handle \{\s*reverse_proxy 127\.0\.0\.1:8787\s*\}/);
  assert.ok(apiConfig.indexOf('handle @retired_product') < apiConfig.indexOf('reverse_proxy 127.0.0.1:8787'));
  assert.match(config, /handle \/api\/\* \{\s*reverse_proxy http:\/\/thesisforge-api-prod-378477120101\.us-east-1\.elasticbeanstalk\.com/);
});

test('Caddy adapts the actual configuration when the operator supplies its binary', t => {
  const binary = process.env.CADDY_TEST_BINARY;
  if (!binary) return t.skip('Set CADDY_TEST_BINARY to run the real Caddy parser; no daemon is started');
  const result = spawnSync(binary, ['adapt', '--config', configPath, '--adapter', 'caddyfile'],
    { encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  const adapted = JSON.parse(result.stdout);
  assert.ok(adapted.apps?.http?.servers);
  assert.doesNotMatch(result.stdout, /8791/);
  assert.match(result.stdout, /module_retired/);
});
