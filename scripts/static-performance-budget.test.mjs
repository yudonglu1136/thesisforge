import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

import { gurus } from '../server/gurus.js';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const indexPath = path.join(rootDir, 'web', 'index.html');
const vercelPath = path.join(rootDir, 'vercel.json');
const avatarDir = path.join(rootDir, 'web', 'guru-avatars');
const mainPath = path.join(rootDir, 'lib', 'main.dart');
const flutterBuildPath = path.join(rootDir, 'scripts', 'flutter-build.sh');
const browserLocationPath = path.join(rootDir, 'lib', 'browser_location_web.dart');

function inlineBootScript() {
  const html = fs.readFileSync(indexPath, 'utf8');
  const match = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
    .find((entry) => entry[1].includes('flutter-cache-migration-v2'));
  assert.ok(match, 'web/index.html must contain the inline Flutter bootstrap');
  return match[1];
}

function createBrowserHarness(url, storage = new Map()) {
  const counters = {
    cacheDeletes: 0,
    unregisters: 0,
    flutterLoads: 0,
    redirects: [],
  };
  const location = new URL(url);
  location.replace = (target) => counters.redirects.push(target);
  const localStorage = {
    getItem: (key) => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, String(value)),
  };
  const cacheStorage = {
    keys: async () => ['legacy-flutter-cache'],
    delete: async () => {
      counters.cacheDeletes += 1;
      return true;
    },
  };
  const loadingShell = { dataset: {}, remove: () => {} };
  const window = {
    location,
    localStorage,
    caches: cacheStorage,
    addEventListener: () => {},
    requestAnimationFrame: (callback) => callback(),
    setTimeout: () => 0,
  };
  class MutationObserver {
    observe() {}
    disconnect() {}
  }
  const context = {
    URL,
    Promise,
    MutationObserver,
    window,
    localStorage,
    navigator: {
      serviceWorker: {
        controller: {},
        getRegistrations: async () => [
          {
            unregister: async () => {
              counters.unregisters += 1;
              return true;
            },
          },
        ],
      },
    },
    caches: cacheStorage,
    document: {
      getElementById: (id) => (id === 'app-loading-shell' ? loadingShell : null),
      querySelector: () => null,
      createElement: () => ({}),
      body: {
        appendChild: () => {
          counters.flutterLoads += 1;
        },
      },
    },
  };
  return { context, counters, storage };
}

async function runBoot(harness) {
  vm.runInNewContext(inlineBootScript(), harness.context);
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
}

function pngDimensions(filePath) {
  const header = fs.readFileSync(filePath).subarray(0, 24);
  assert.equal(header.toString('hex', 0, 8), '89504e470d0a1a0a', `${filePath} is not PNG`);
  assert.equal(header.toString('ascii', 12, 16), 'IHDR', `${filePath} has no PNG IHDR`);
  return {
    width: header.readUInt32BE(16),
    height: header.readUInt32BE(20),
  };
}

function cacheHeaderFor(vercel, resourcePath) {
  for (const route of vercel.routes) {
    if (!route.headers?.['Cache-Control']) continue;
    if (new RegExp(route.src).test(resourcePath)) {
      return route.headers['Cache-Control'];
    }
  }
  return '';
}

test('legacy cache migration runs once and repeat visits keep the Flutter cache', async () => {
  const storage = new Map();
  const first = createBrowserHarness('https://www.thesisforge.tech/', storage);
  await runBoot(first);
  assert.equal(first.counters.unregisters, 1);
  assert.equal(first.counters.cacheDeletes, 1);
  assert.equal(first.counters.flutterLoads, 0);
  assert.equal(first.counters.redirects.length, 1);
  assert.match(first.counters.redirects[0], /cache-migration=flutter-cache-migration-v2/);

  const repeat = createBrowserHarness('https://www.thesisforge.tech/', storage);
  await runBoot(repeat);
  assert.equal(repeat.counters.unregisters, 0);
  assert.equal(repeat.counters.cacheDeletes, 0);
  assert.equal(repeat.counters.flutterLoads, 1);
});

test('auth callbacks retain their URL and load Flutter without cleanup or retirement redirects', async () => {
  for (const route of [
    '/?code=oauth-code',
    '/?view=ontology&code=oauth-code&lang=zh',
    '/?mode=dbmf&code=oauth-code',
    '/ontology/?code=oauth-code',
    '/dbmf/history?error=access_denied',
    '/ontology/#access_token=synthetic-test-token',
    '/?returnTo=%2Fontology%2F%3Flang%3Dzh&code=oauth-code',
  ]) {
    const auth = createBrowserHarness(`https://www.thesisforge.tech${route}`);
    await runBoot(auth);
    assert.equal(auth.counters.unregisters, 0, route);
    assert.equal(auth.counters.cacheDeletes, 0, route);
    assert.equal(auth.counters.flutterLoads, 1, route);
    assert.deepEqual(auth.counters.redirects, [], route);
  }
});

test('retired webpage bookmarks return to Discover and retain only explicit language', async () => {
  for (const route of [
    '/?view=ontology', '/?mode=ontology', '/?view=dbmf', '/?mode=dbmf',
    '/ontology', '/ontology/', '/ontology/index.html', '/ontology/history',
    '/dbmf', '/dbmf/history', '/ONTOLOGY/',
  ]) {
    for (const language of ['', 'en', 'zh']) {
      const suffix = language ? `${route.includes('?') ? '&' : '?'}lang=${language}&viewState=obsolete` : '';
      const retired = createBrowserHarness(`https://www.thesisforge.tech${route}${suffix}#old-tab`);
      await runBoot(retired);
      assert.equal(retired.counters.unregisters, 0);
      assert.equal(retired.counters.cacheDeletes, 0);
      assert.equal(retired.counters.flutterLoads, 0);
      assert.deepEqual(retired.counters.redirects, [`/?view=discover${language ? `&lang=${language}` : ''}`], route);
    }
  }
});

test('current Discover, research and DBMF CTA selection do not trigger retirement redirects', async () => {
  const storage = new Map([['guru-cache-migration:flutter-cache-migration-v2', 'complete']]);
  for (const route of ['/?view=discover', '/?view=research&valuation=PLTR', '/?view=strategies&cta=DBMF', '/ontology-business']) {
    const current = createBrowserHarness(`https://www.thesisforge.tech${route}`, storage);
    await runBoot(current);
    assert.deepEqual(current.counters.redirects, [], route);
    assert.equal(current.counters.flutterLoads, 1, route);
  }
});

test('entry resources revalidate and versioned assets use immutable caching', () => {
  const vercel = JSON.parse(fs.readFileSync(vercelPath, 'utf8'));
  for (const resource of ['/', '/index.html', '/main.dart.js', '/flutter_bootstrap.js']) {
    const header = cacheHeaderFor(vercel, resource);
    assert.ok(header, `${resource} must have an explicit cache policy`);
    assert.doesNotMatch(header, /(?:^|,)\s*no-store(?:\s|,|$)/i, `${resource} must be cacheable`);
    assert.match(header, /must-revalidate/i, `${resource} must revalidate safely`);
  }

  assert.match(cacheHeaderFor(vercel, '/guru-avatars/warren-buffett.png'), /immutable/i);
  const mainSource = fs.readFileSync(mainPath, 'utf8');
  assert.match(mainSource, /_guruAvatarAssetVersion\s*=\s*'144-\d{8}(?:r[1-9]\d*)?'/);
  assert.match(mainSource, /final url = resolvedGuruAvatarUrl\(guru\)/);
  assert.match(mainSource, /return versionedGuruAvatarUrl\(value\)/);
  assert.match(mainSource, /return versionedGuruAvatarUrl\('\/guru-avatars\/\$id\.png'\)/);
});

test('retired module assets and build hooks are absent while legacy webpages reach Flutter', () => {
  for (const relative of ['web/ontology', 'scripts/sync-ontology-frontend.py']) {
    const location = path.join(rootDir, relative);
    assert.ok(!fs.existsSync(location) || (fs.statSync(location).isDirectory() && fs.readdirSync(location).length === 0), `${relative} must contain no retired app`);
  }
  const mainSource = fs.readFileSync(mainPath, 'utf8');
  assert.doesNotMatch(mainSource, /class Ontology|_ontologyPayload|\/api\/ontology|\/api\/dbmf/);
  for (const relative of ['scripts/flutter-build.sh', 'scripts/vercel-build.sh', 'scripts/audit-i18n.mjs']) {
    assert.doesNotMatch(fs.readFileSync(path.join(rootDir, relative), 'utf8'), /ontology/i, `${relative} must not rebuild or validate a removed app`);
  }
  const buildSource = fs.readFileSync(flutterBuildPath, 'utf8');
  assert.match(buildSource, /Production builds must set AUTH_DEV_BYPASS=false/);
  assert.match(buildSource, /verify-workflow-artifact\.mjs/);
  const vercel = JSON.parse(fs.readFileSync(vercelPath, 'utf8'));
  for (const resource of ['/ontology', '/ontology/', '/ontology/index.html', '/dbmf', '/dbmf/history']) {
    const route = vercel.routes.find((entry) => entry.dest && new RegExp(entry.src).test(resource));
    assert.equal(route?.dest, '/index.html', resource);
    assert.match(cacheHeaderFor(vercel, resource), /must-revalidate/);
  }
  assert.ok(vercel.routes.some((route) => route.src === '^/research/isrg/$' && route.dest === '/research/isrg/index.html'));
  assert.ok(vercel.routes.some((route) => route.src === '/api/(.*)' && route.dest === '/api/proxy.js?path=/api/$1'));
  assert.match(fs.readFileSync(path.join(rootDir, 'lib/investment_strategy_lab.dart'), 'utf8'), /'KMLM', 'DBMF'/);
});

test('UI avatar payload stays within the 144px and 1 MiB performance budgets', () => {
  const avatarFiles = fs
    .readdirSync(avatarDir)
    .filter((name) => name.endsWith('.png'))
    .sort();
  const expectedAvatarFiles = gurus.map((guru) => `${guru.id}.png`).sort();
  assert.deepEqual(
    avatarFiles,
    expectedAvatarFiles,
    'every configured guru must have exactly one matching UI avatar',
  );

  let totalBytes = 0;
  for (const fileName of avatarFiles) {
    const filePath = path.join(avatarDir, fileName);
    const dimensions = pngDimensions(filePath);
    assert.ok(dimensions.width <= 144, `${fileName} is ${dimensions.width}px wide`);
    assert.ok(dimensions.height <= 144, `${fileName} is ${dimensions.height}px high`);
    totalBytes += fs.statSync(filePath).size;
  }
  assert.ok(totalBytes <= 1024 * 1024, `avatar payload is ${totalBytes} bytes`);
});

test('browser history normalization preserves the Forward stack', () => {
  const browserLocationSource = fs.readFileSync(browserLocationPath, 'utf8');
  const mainSource = fs.readFileSync(mainPath, 'utf8');
  assert.match(browserLocationSource, /bool replaceCurrent = false/);
  assert.match(browserLocationSource, /replaceCurrent[\s\S]*history\.replaceState/);
  assert.match(browserLocationSource, /history\.pushState/);
  assert.match(
    mainSource,
    /_persistRouteState\(replaceCurrent: true\)/,
    'data-driven default selection must normalize the current entry instead of creating a new one',
  );
});
