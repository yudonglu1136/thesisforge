import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';
import { DatabaseSync } from 'node:sqlite';

const [repo, databasePath] = process.argv.slice(2);
if (!repo || !databasePath) throw new Error('Usage: node profiler.mjs REPO SQLITE');
const server = (file) => pathToFileURL(path.join(repo, 'server', file)).href;
const { createSystemHealth } = await import(server('systemHealthCore.js'));
const { readDatabaseTableSummariesFrom } = await import(server('databaseTableSummaries.js'));
const { holdingResolutionVersion } = await import(server('cusipOverrides.js'));
const backtestSource = fs.readFileSync(path.join(repo, 'server/backtest.js'), 'utf8');
const value = (key) => backtestSource.match(new RegExp(`export const ${key} = "([^"]+)"`))?.[1];
const identity = {
  backtestEndGraceDays: 12,
  manager13fBacktestMethodVersion: value('manager13fBacktestMethodVersion'),
  manager13fProxyMethodVersion: value('manager13fProxyMethodVersion'),
  manager13fSecurityMasterVersion: holdingResolutionVersion()
};
const db = new DatabaseSync(databasePath, { readOnly: true });
db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=250; PRAGMA cache_size=-8192; PRAGMA mmap_size=0; BEGIN');
const timings = [];
const start = performance.now();
const timedDb = { prepare(sql) {
  const before = performance.now();
  const prepared = db.prepare(sql);
  return { all(...args) { return prepared.all(...args); }, get(...args) {
    const result = prepared.get(...args);
    const item = { table: sql.match(/FROM\s+(\w+)/i)?.[1], ms: +(performance.now() - before).toFixed(2), rowCount: result?.row_count };
    timings.push(item);
    process.stdout.write(JSON.stringify({ phase: 'summary', ...item }) + '\n');
    return result;
  } };
} };
let payloadReadMs = 0, parseMs = 0, payloadBytes = 0, payloadRows = 0;
const read = (table, id, years) => {
  const before = performance.now();
  let row;
  try { row = db.prepare(`SELECT payload_json FROM ${table} WHERE guru_id=? AND years=?`).get(id, years); } catch { return null; }
  payloadReadMs += performance.now() - before;
  if (!row?.payload_json) return null;
  payloadBytes += Buffer.byteLength(row.payload_json); payloadRows += 1;
  const parsedStart = performance.now();
  try { return JSON.parse(row.payload_json); } catch { return null; }
  finally { parseMs += performance.now() - parsedStart; }
};
const health = createSystemHealth({ ...identity,
  databaseInfo: () => ({ path: databasePath }),
  readDatabaseTableSummaries: () => readDatabaseTableSummariesFrom(timedDb),
  readGuruBacktest: (id, years) => read('guru_backtests', id, years),
  readGuruBacktestProxy: (id, years) => read('guru_backtest_proxies', id, years)
});
const tables = readDatabaseTableSummariesFrom(timedDb);
const matrixStart = performance.now();
const now = Date.parse('2026-09-12T21:00:00Z');
const curves = health.summarizeGuruCurveAvailability({ now });
const matrixMs = performance.now() - matrixStart;
const result = health.buildPublicSystemHealth({ tables, guruCurves: curves, now });
process.stdout.write(JSON.stringify({ phase: 'complete', totalMs: +(performance.now() - start).toFixed(2), matrixMs: +matrixMs.toFixed(2),
  payloadReadMs: +payloadReadMs.toFixed(2), parseMs: +parseMs.toFixed(2), payloadBytes, payloadRows,
  expectedRows: curves.expectedRows, displayable: curves.displayable, failures: curves.failures.length,
  summaryMs: +timings.reduce((sum, item) => sum + item.ms, 0).toFixed(2), rssMb: +(process.memoryUsage().rss / 1024 / 1024).toFixed(1), status: result.status }) + '\n');
db.close();
