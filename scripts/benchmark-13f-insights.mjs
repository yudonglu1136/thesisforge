#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { DatabaseSync } from 'node:sqlite';
import { gzipSync } from 'node:zlib';
import { institutional13fInsights } from '../server/institutional13fInsights.js';

function argument(name, fallback = '') {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * fraction))];
}

function stats(values) {
  return {
    samples: values.length,
    p50Ms: percentile(values, .5),
    p95Ms: percentile(values, .95),
    minMs: Math.min(...values),
    maxMs: Math.max(...values),
  };
}

function openSource(databasePath) {
  const db = new DatabaseSync(databasePath, { readOnly: true });
  return { db, insightsDb: db };
}

function read(source, asOf, quarter, ticker) {
  return JSON.stringify(institutional13fInsights(source, asOf, quarter, {
    ticker,
    action: 'increased',
    rank: 'amount',
    segment: 'all',
    limit: 100,
  }));
}

function benchmark(databasePath, { samples, asOf, quarter, ticker }) {
  const cold = [];
  let serialized = '';
  for (let index = 0; index < samples; index += 1) {
    const started = performance.now();
    const source = openSource(databasePath);
    serialized = read(source, asOf, quarter, ticker);
    source.db.close();
    cold.push(performance.now() - started);
  }

  const source = openSource(databasePath);
  read(source, asOf, quarter, ticker);
  const warm = [];
  for (let index = 0; index < samples; index += 1) {
    const started = performance.now();
    serialized = read(source, asOf, quarter, ticker);
    warm.push(performance.now() - started);
  }
  source.db.close();

  return {
    database: path.resolve(databasePath),
    databaseBytes: fs.statSync(databasePath).size,
    responseBytes: Buffer.byteLength(serialized),
    gzipBytes: gzipSync(serialized).length,
    cold: stats(cold),
    warm: stats(warm),
  };
}

const baseline = argument('baseline');
const current = argument('current');
const output = argument('output');
const samples = Number.parseInt(argument('samples', '60'), 10);
if (!baseline || !current) throw new Error('--baseline and --current are required');
if (!Number.isInteger(samples) || samples < 60) throw new Error('--samples must be at least 60');

const options = {
  samples,
  asOf: argument('as-of', '2026-09-18'),
  quarter: argument('quarter', '2026-06-30'),
  ticker: argument('ticker', 'MSFT'),
};
const before = benchmark(baseline, options);
const after = benchmark(current, options);
const improvement = (beforeMs, afterMs) => (1 - afterMs / beforeMs) * 100;
const report = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  inputs: options,
  baseline: before,
  current: after,
  improvement: {
    coldP50Pct: improvement(before.cold.p50Ms, after.cold.p50Ms),
    coldP95Pct: improvement(before.cold.p95Ms, after.cold.p95Ms),
    warmP50Pct: improvement(before.warm.p50Ms, after.warm.p50Ms),
    warmP95Pct: improvement(before.warm.p95Ms, after.warm.p95Ms),
    responseBytesPct: improvement(before.responseBytes, after.responseBytes),
  },
};
const serialized = `${JSON.stringify(report, null, 2)}\n`;
if (output) {
  fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
  fs.writeFileSync(path.resolve(output), serialized);
}
process.stdout.write(serialized);
