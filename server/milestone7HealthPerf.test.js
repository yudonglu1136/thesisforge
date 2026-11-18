import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {readDatabaseTableSummariesFrom} from './databaseTableSummaries.js';
import {loadBreakoutPullbackDashboard} from './breakoutPullbackStrategy.js';
import {loadQqqSchdRotationDashboard} from './qqqSchdRotationStrategy.js';

test('readDatabaseTableSummariesFrom reads Fact OS catalog.json stocks summary in O(1) when factOsRoot is active', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'm7-health-factos-'));
  const dbPath = path.join(dir, 'test.sqlite');
  const factRoot = path.join(dir, 'fact_os');
  fs.mkdirSync(path.join(factRoot, 'manifests'), {recursive: true});
  fs.writeFileSync(
    path.join(factRoot, 'manifests/catalog.json'),
    JSON.stringify({
      datasets: {
        stocks: {
          state: {
            dataset: 'stocks',
            min_date: '1997-12-31',
            max_date: '2026-11-17',
            watermark: '2026-11-17',
            row_count: 45714876,
          },
        },
      },
    }),
  );

  const db = new DatabaseSync(dbPath);
  db.exec('CREATE TABLE price_points (symbol TEXT, date TEXT, updated_at TEXT);');
  db.exec("INSERT INTO price_points VALUES ('SPY', '2026-11-13', '2026-11-13T00:00:00Z');");

  try {
    const legacy = readDatabaseTableSummariesFrom(db).find((s) => s.table === 'price_points');
    assert.equal(legacy.sourceAt, '2026-11-13');
    assert.equal(legacy.rowCount, 1);

    const canonical = readDatabaseTableSummariesFrom(db, {factOsRoot: factRoot}).find(
      (s) => s.table === 'price_points',
    );
    assert.equal(canonical.sourceAt, '2026-11-17');
    assert.equal(canonical.maxDate, '2026-11-17');
    assert.equal(canonical.rowCount, 45714876);
  } finally {
    db.close();
    fs.rmSync(dir, {recursive: true, force: true});
  }
});

test('tactical strategy dashboards return frozen memoized slices for O(1) jsonTransport WeakMap ETag hits', () => {
  const b1 = loadBreakoutPullbackDashboard({asOf: '2026-11-17', mode: 'flagship'});
  const b2 = loadBreakoutPullbackDashboard({asOf: '2026-11-17', mode: 'flagship'});
  assert.equal(b1, b2);
  assert.equal(Object.isFrozen(b1), true);

  const r1 = loadQqqSchdRotationDashboard({
    asOf: '2026-11-17',
    mode: 'm6',
    window: 'live_2011',
  });
  const r2 = loadQqqSchdRotationDashboard({
    asOf: '2026-11-17',
    mode: 'm6',
    window: 'live_2011',
  });
  assert.equal(r1, r2);
  assert.equal(Object.isFrozen(r1), true);
});
