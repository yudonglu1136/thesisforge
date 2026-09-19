import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { inspectDatabase, compareDatabases } from './database-release-audit.mjs';

function fixture(t, sql = '') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tf-schema-audit-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'test.sqlite');
  const db = new DatabaseSync(file);
  db.exec(sql);
  t.after(() => db.close());
  return { dir, file, db };
}
const research = `CREATE TABLE price_points(symbol TEXT, date TEXT, close REAL, PRIMARY KEY(symbol,date));
 CREATE TABLE guru_snapshots(guru_id TEXT PRIMARY KEY, payload_json TEXT);
 CREATE TABLE guru_backtests(guru_id TEXT, years INTEGER, payload_json TEXT, PRIMARY KEY(guru_id,years));`;

test('audit is read-only, includes committed WAL and emits no private rows or paths', t => {
  const { file, db } = fixture(t, `PRAGMA journal_mode=WAL; CREATE TABLE login_activity_users(user_key TEXT PRIMARY KEY, email TEXT);`);
  db.prepare('INSERT INTO login_activity_users VALUES(?,?)').run('private-id', 'private@example.invalid');
  const result = inspectDatabase(file, 'login');
  assert.equal(result.status, 'inspected');
  assert.equal(result.tables[0].rows, 1);
  assert.equal(result.tables[0].dataSha256, null);
  assert.doesNotMatch(JSON.stringify(result), /private-id|private@example|tf-schema-audit-/);
  assert.equal(db.prepare('SELECT email FROM login_activity_users').get().email, 'private@example.invalid');
});

test('missing database is not created and private fingerprints are forbidden', t => {
  const { file, dir } = fixture(t);
  const missing = path.join(dir, 'missing.sqlite');
  assert.throws(() => inspectDatabase(missing, 'login'));
  assert.equal(fs.existsSync(missing), false);
  assert.throws(() => inspectDatabase(file, 'investment', { digestTables: ['investment_events'] }), /only_allowlisted/);
  assert.throws(() => inspectDatabase(file, 'research', { digestTables: ['portfolio_nav_points'] }), /only_allowlisted/);
  const link = path.join(dir, 'link.sqlite'); fs.symlinkSync(file, link);
  assert.throws(() => inspectDatabase(link, 'login'), /regular/);
});

test('a lightweight live schema inventory never claims full integrity or row counts', t => {
  const { file } = fixture(t, research);
  const a = inspectDatabase(file, 'research', { schemaOnly: true });
  assert.equal(a.status, 'inventory_only');
  assert.equal(a.integrityOk, null);
  assert.equal(a.tables[0].rows, null);
  const result = compareDatabases(a, a);
  assert.equal(result.schemaMatch, true);
  assert.equal(result.integrityVerified, false);
  assert.equal(result.status, 'blocked');
  assert.deepEqual(compareDatabases(inspectDatabase(file, 'research'), a).rowCountsDiffer, []);
  assert.throws(() => inspectDatabase(file, 'research', { schemaOnly: true, digestTables: ['price_points'] }));
});

test('CLI writes a new private receipt but never replaces an existing receipt', t => {
  const { file, dir } = fixture(t, research);
  const output = path.join(dir, 'receipt.json');
  const args = [new URL('./database-release-audit.mjs', import.meta.url).pathname,
    'inspect', '--db', file, '--kind', 'research', '--output', output];
  const first = spawnSync(process.execPath, args, { encoding: 'utf8', timeout: 10_000 });
  assert.equal(first.status, 0);
  const original = fs.readFileSync(output, 'utf8');
  assert.equal(fs.statSync(output).mode & 0o777, 0o600);
  assert.equal(spawnSync(process.execPath, args, { encoding: 'utf8', timeout: 10_000 }).status, 1);
  assert.equal(fs.readFileSync(output, 'utf8'), original);
});

test('wrong database, missing tables and foreign-key violations fail closed', t => {
  const { file, db } = fixture(t, research);
  assert.equal(inspectDatabase(file, 'strategy').status, 'blocked');
  assert.equal(inspectDatabase(file, 'research', { digestTables: ['valuation_pit_guidance'] }).status, 'blocked');
  db.exec('PRAGMA foreign_keys=OFF; CREATE TABLE child(id TEXT REFERENCES guru_snapshots(guru_id)); INSERT INTO child VALUES(\'missing\');');
  assert.equal(inspectDatabase(file, 'research').foreignKeyViolations, 1);
});

test('same row counts do not imply public data equality; int64 values stay exact', t => {
  const { file, db } = fixture(t, research);
  db.exec("INSERT INTO price_points VALUES('A','2026-09-10',100); INSERT INTO guru_snapshots VALUES('A','{}');");
  const first = inspectDatabase(file, 'research', { digestTables: ['price_points'] });
  db.exec('UPDATE price_points SET close=101');
  const next = inspectDatabase(file, 'research', { digestTables: ['price_points'] });
  assert.equal(compareDatabases(first, next).schemaMatch, true);
  assert.equal(compareDatabases(first, next).dataMatch, false);
  assert.equal(compareDatabases(first, next).status, 'blocked');
  db.exec('ALTER TABLE price_points ADD COLUMN shares INTEGER; UPDATE price_points SET shares=9007199254740993');
  const large = inspectDatabase(file, 'research', { digestTables: ['price_points'] });
  db.exec('UPDATE price_points SET shares=9007199254740992');
  assert.notEqual(large.tables.find(t => t.name === 'price_points').dataSha256,
    inspectDatabase(file, 'research', { digestTables: ['price_points'] }).tables.find(t => t.name === 'price_points').dataSha256);
});

test('column, index, trigger and user-version drift block schema synchronization', t => {
  const { file, db } = fixture(t, research);
  const before = inspectDatabase(file, 'research');
  assert.equal(compareDatabases(before, before).status, 'schema_verified');
  assert.equal(compareDatabases(before, before).dataMatch, null);
  db.exec('CREATE UNIQUE INDEX test_unique ON guru_snapshots(payload_json)');
  const index = inspectDatabase(file, 'research');
  assert.deepEqual(compareDatabases(index, before).missing, ['index:test_unique']);
  db.exec('ALTER TABLE price_points ADD COLUMN source TEXT');
  assert.ok(compareDatabases(index, inspectDatabase(file, 'research')).changed.includes('table:price_points'));
  db.exec("CREATE TRIGGER immutable BEFORE DELETE ON price_points BEGIN SELECT RAISE(ABORT,'immutable'); END;");
  assert.ok(compareDatabases(before, inspectDatabase(file, 'research')).extra.includes('trigger:immutable'));
  const version = inspectDatabase(file, 'research'); db.exec('PRAGMA user_version=2');
  assert.equal(compareDatabases(version, inspectDatabase(file, 'research')).userVersionMatch, false);
});

test('private user populations need not match; kind mismatch and invalid evidence are blocked', t => {
  const { file, db } = fixture(t, 'CREATE TABLE portfolio_user_registry(id TEXT PRIMARY KEY);');
  const before = inspectDatabase(file, 'registry');
  db.exec("INSERT INTO portfolio_user_registry VALUES('synthetic-user')");
  const next = inspectDatabase(file, 'registry');
  assert.equal(compareDatabases(before, next).status, 'schema_verified');
  assert.equal(compareDatabases(before, next).dataMatch, null);
  assert.deepEqual(compareDatabases(before, next).rowCountsDiffer, ['portfolio_user_registry']);
  assert.equal(compareDatabases(before, { ...next, kind: 'login' }).status, 'blocked');
  assert.equal(compareDatabases({}, {}).status, 'blocked');
});

test('existing research initializer migrates a legacy fixture twice without changing stored rows', t => {
  const { file, db } = fixture(t, `
    CREATE TABLE price_points(symbol TEXT NOT NULL,date TEXT NOT NULL,open REAL,high REAL,low REAL,close REAL NOT NULL,volume REAL,source TEXT,updated_at TEXT NOT NULL,PRIMARY KEY(symbol,date));
    CREATE TABLE portfolio_nav_points(account_id TEXT NOT NULL,date TEXT NOT NULL,nav REAL NOT NULL,cash REAL,source TEXT,source_date TEXT,payload_json TEXT,updated_at TEXT NOT NULL,PRIMARY KEY(account_id,date));
    INSERT INTO price_points VALUES('TEST','2026-09-10',100,101,99,100,15,'synthetic','2026-09-10');
    INSERT INTO portfolio_nav_points VALUES('synthetic-private','2026-09-10',123,4,'broker','2026-09-10','{}','2026-09-10');
  `);
  const price = db.prepare('SELECT * FROM price_points').get();
  const nav = db.prepare('SELECT * FROM portfolio_nav_points').all();
  const env = { ...process.env, SQLITE_DB_PATH: file,
    SYNC_BUNDLED_VALUATION_SNAPSHOTS: 'false', SYNC_BUNDLED_GURU_BACKTESTS: 'false',
    SYNC_BUNDLED_DIVIDEND_CALENDAR: 'false', SYNC_BUNDLED_PODCAST_INSIGHTS: 'false' };
  const migrate = () => {
    const run = spawnSync(process.execPath, ['--input-type=module', '-e', "await import('./server/localDatabase.js')"], {
      cwd: new URL('..', import.meta.url), env, encoding: 'utf8', timeout: 30_000
    });
    assert.equal(run.status, 0, run.stderr);
  };
  migrate();
  const first = inspectDatabase(file, 'research', { digestTables: ['price_points'] });
  migrate();
  const second = inspectDatabase(file, 'research', { digestTables: ['price_points'] });
  assert.equal(compareDatabases(first, second).status, 'schema_verified');
  assert.deepEqual(db.prepare('SELECT * FROM portfolio_nav_points').all(), nav);
  const after = db.prepare('SELECT * FROM price_points').get();
  assert.equal(after.adjusted_close, null); delete after.adjusted_close;
  assert.deepEqual(after, price);
});
