// Export an inspection-only audit database. Never changes market or user data.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('Usage: export-research-guidance-audit.mjs <full-report.json> <new-private-directory>');
const report = JSON.parse(fs.readFileSync(input));
const dir = path.resolve(output);
if (fs.existsSync(dir)) throw new Error('Audit export must use a new directory');
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
const dbFile = path.join(dir, 'guidance-audit.sqlite');
const db = new DatabaseSync(dbFile);
try {
  db.exec(`CREATE TABLE audit_run (id INTEGER PRIMARY KEY, as_of TEXT, generated_at TEXT, scope TEXT, summary_json TEXT);
    CREATE TABLE forecast_audit (ticker TEXT PRIMARY KEY, model_date TEXT, available INTEGER, old_first_growth REAL, corrected_first_growth REAL, corrected_revenue_m REAL, payload_json TEXT);
    CREATE TABLE guidance_finding (id INTEGER PRIMARY KEY, check_name TEXT, code TEXT, ticker TEXT, source_id TEXT, fiscal_period TEXT, model_date TEXT, payload_json TEXT);
    CREATE INDEX guidance_finding_ticker ON guidance_finding(ticker,code);
    CREATE TABLE forecast_finding (id INTEGER PRIMARY KEY, ticker TEXT, code TEXT, payload_json TEXT); BEGIN;`);
  db.prepare('INSERT INTO audit_run VALUES(1,?,?,?,?)').run(report.asOf, report.generatedAt, report.scope, JSON.stringify(report.summary));
  const forecast = db.prepare('INSERT INTO forecast_audit VALUES(?,?,?,?,?,?,?)');
  for (const row of report.forecast) forecast.run(row.ticker, row.modelDate, Number(row.available), row.legacyFirstGrowth, row.firstGrowth, row.firstRevenueM, JSON.stringify(row));
  const finding = db.prepare('INSERT INTO guidance_finding VALUES(NULL,?,?,?,?,?,?,?)');
  for (const [name, check] of Object.entries(report.checks)) for (const row of check.failures) {
    finding.run(name, row.code, row.ticker ?? null, row.sourceId ?? null, row.period ?? row.fiscalPeriod ?? null,
      row.asOfDate ?? row.asOf ?? row.modelDate ?? null, JSON.stringify(row));
  }
  const forecastFinding = db.prepare('INSERT INTO forecast_finding VALUES(NULL,?,?,?)');
  for (const row of report.forecastFailures) forecastFinding.run(row.ticker, row.code, JSON.stringify(row));
  db.exec('COMMIT');
  const counts = {
    forecastRows: db.prepare('SELECT COUNT(*) n FROM forecast_audit').get().n,
    guidanceFindings: db.prepare('SELECT COUNT(*) n FROM guidance_finding').get().n,
    forecastFailures: db.prepare('SELECT COUNT(*) n FROM forecast_finding').get().n,
  };
  fs.writeFileSync(path.join(dir, 'summary.json'), JSON.stringify({ asOf: report.asOf, scope: report.scope, ...report.summary, ...counts }, null, 2) + '\n', { mode: 0o600 });
  const common = { label: 'Local stored guidance and forecast audit',
    files: ['verified.json', 'guidance-audit.sqlite', 'audit-research-forecast-guidance.mjs'],
    filters: [`Evidence available by ${report.asOf}`, 'Latest model per company for forecast checks'],
    caveats: ['Automated checks of stored original excerpts are not a fresh review of every official document.', 'Guidance findings overlap; they are not counts of distinct companies. Published models and user-saved assumptions were not rewritten.'] };
  const googl = report.forecast.find(r => r.ticker === 'GOOGL');
  const receipt = { schemaVersion: 1, items: [
    { id: 'forecast-correction', title: 'GOOGL 首年 0% 来自预填映射，不是管理层指引', queries: [{ id: 'googl-path', source: { ...common,
      metricDefinitions: ['The corrected first model year uses the stored normalized growth assumption; FCFE margins reconcile the existing cash-flow path. The model year is not fiscal-year guidance.'] },
      rows: [{ oldGrowthPct: googl.legacyFirstGrowth * 100, newGrowthPct: googl.firstGrowth * 100, revenueM: googl.firstRevenueM, dcf: googl.scenarioDcf }],
      columns: [{ field: 'oldGrowthPct', label: 'Old growth (%)' }, { field: 'newGrowthPct', label: 'New model assumption (%)' }, { field: 'revenueM', label: 'Revenue (USD m)' }, { field: 'dcf', label: 'DCF (USD/share)' }] }] },
    { id: 'population-audit', title: '全库自动审计范围与剩余问题', queries: [{ id: 'all-records', source: { ...common,
      tables: ['valuation_pit_guidance', 'valuation_pit_model_runs', 'valuation_pit_financials'],
      metricDefinitions: ['The guidance audit checks all stored events and dated model references; the forecast audit checks the latest model for each company.'] },
      rows: [{ guidanceRows: report.summary.guidanceRows, modelRuns: report.summary.modelRuns, correctedTtmAnchors: report.summary.legacyCollapsedTtmAnchors, supportedForecasts: report.summary.supportedForecasts, remainingGuidanceFindings: counts.guidanceFindings, forecastFailures: counts.forecastFailures }],
      columns: ['guidanceRows', 'modelRuns', 'correctedTtmAnchors', 'supportedForecasts', 'remainingGuidanceFindings', 'forecastFailures'] }] },
  ] };
  fs.writeFileSync(path.join(dir, 'receipt.json'), JSON.stringify(receipt, null, 2), { mode: 0o600 });
  console.log(JSON.stringify({ ...counts, integrity: db.prepare('PRAGMA integrity_check').get().integrity_check }));
} finally { db.close(); fs.chmodSync(dbFile, 0o600); }
