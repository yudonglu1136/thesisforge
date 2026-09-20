import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import {
  sp500AliasEntries,
  sp500CompanyTickers,
  sp500UniverseSummary
} from "./sp500ValuationUniverse.js";
import {
  guruValuationExpectedTickerSet,
  guruValuationUniverseSummary
} from "./guruValuationUniverse.js";
import { guidancePlusMinusCenterM } from "./importSecQuarterlyValuations.js";
import {
  independentGuidanceMidpointMismatch,
  independentHistoricalActualAmountMismatch,
  independentNonGuidanceOwnerAmountMismatch,
  independentParallelMetricAmountMismatch
} from "./guidanceEvidenceAudit.js";
import { valuationMarketPriceSymbol } from "./tickerAliases.js";
import { inspectUnmodeledFinancialPeriods } from "./valuationCoverageAudit.js";
import { inspectValuationTemporalContinuity } from "./valuationTemporalAudit.js";
import { auditGuidanceCoverageRelease, guidanceReleaseEventKey } from "./guidanceCoverageReleaseAudit.js";
import { auditFinancialCoverageRelease } from "./financialCoverageReleaseAudit.js";
import { auditReviewedShareCount } from "./reviewedShareCountAudit.js";
import { auditReviewedEconomicInput } from "./reviewedEconomicInputs.js";
import { auditReviewedFinancialSource } from "./reviewedFinancialSourceAudit.js";
import { auditValuationComparisonPrice } from "./valuationComparisonPrice.js";
import { separateOriginalRevenueOccurrences } from "./guidanceOccurrenceAudit.js";
import { reviewedCurrentFromEnvironment, auditReviewedCurrentDatabase, applyReviewedCurrentPeriodDispositions } from "./reviewedCurrentFullRebuild.js";

const REQUIRE_TRANSCRIPT_QA = process.env.PIT_RELEASE_REQUIRE_TRANSCRIPT_QA !== "false";
const REQUIRE_BILINGUAL_QA = process.env.PIT_RELEASE_REQUIRE_BILINGUAL_QA !== "false";
const TRACE_MEMORY = process.env.PIT_RELEASE_TRACE_MEMORY === "true";
const REPORT_PATH = String(process.env.PIT_RELEASE_REPORT_PATH || "").trim();

const VALUATION_TABLES = new Set([
  "valuation_pit_source_metadata",
  "valuation_pit_financials",
  "valuation_pit_guidance",
  "valuation_pit_model_runs",
  "valuation_pit_price_observations",
  "valuation_ticker_snapshots",
  "valuation_snapshots"
]);

function reportProgress(stage) {
  const memory = process.memoryUsage();
  console.error(JSON.stringify({
    stage,
    rssMb: Math.round(memory.rss / 1_048_576),
    heapUsedMb: Math.round(memory.heapUsed / 1_048_576),
    externalMb: Math.round(memory.external / 1_048_576)
  }));
}

function assertNoFindings(label, findings) {
  if (!Array.isArray(findings) || findings.length === 0) return;
  throw new Error(`${label} found ${findings.length} issue(s): ${JSON.stringify(findings.slice(0, 20))}`);
}

function openDatabase(filePath) {
  return new DatabaseSync(path.resolve(filePath), { readOnly: true });
}

function tableCounts(db, { excludeValuation = false } = {}) {
  const tables = db.prepare(`
    SELECT name
    FROM sqlite_master
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
  `).all().map((row) => row.name);
  return Object.fromEntries(tables
    .filter((table) => !excludeValuation || !VALUATION_TABLES.has(table))
    .map((table) => [table, Number(db.prepare(`SELECT COUNT(*) AS count FROM "${table}"`).get().count)]));
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value)
    .filter(([key]) => !["generatedAt", "runCreatedAt", "fetchedAt"].includes(key))
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, child]) => [key, canonicalize(child)]));
}

function canonicalJson(value) {
  try {
    return JSON.stringify(canonicalize(JSON.parse(value)));
  } catch {
    return String(value ?? "");
  }
}

function parseJson(value, fallback = null) {
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function digestRows(rows) {
  const hash = crypto.createHash("sha256");
  for (const row of rows) hash.update(`${JSON.stringify(row)}\n`);
  return hash.digest("hex");
}

function modelSignature(db) {
  const rows = db.prepare(`
    SELECT ticker, fiscal_period, model_version, as_of_date,
           financial_available_at, guidance_max_observed_at, input_json, output_json
    FROM valuation_pit_model_runs
    ORDER BY ticker, fiscal_period, model_version
  `).iterate();
  return digestRows((function* canonicalModelRows() {
    for (const row of rows) {
      yield {
        ...row,
        input_json: canonicalJson(row.input_json),
        output_json: canonicalJson(row.output_json)
      };
    }
  })());
}

const DYNAMIC_JSON_FIELDS = ["generatedAt", "runCreatedAt", "fetchedAt"];
const DYNAMIC_JSON_FIELD_PATTERN = new RegExp(
  `"(${DYNAMIC_JSON_FIELDS.join("|")})"\\s*:\\s*"(?:\\\\.|[^"\\\\])*"`,
  "g"
);

function normalizeDynamicJsonFields(value) {
  return String(value || "").replace(DYNAMIC_JSON_FIELD_PATTERN, '"$1":"<omitted>"');
}

function hashLargeJsonColumn(hash, db, { table, idColumn, idValue, jsonColumn }) {
  const length = Number(db.prepare(`
    SELECT length(${jsonColumn}) AS length
    FROM ${table}
    WHERE ${idColumn} = ?
  `).get(idValue)?.length || 0);
  const readChunk = db.prepare(`
    SELECT substr(${jsonColumn}, ?, ?) AS chunk
    FROM ${table}
    WHERE ${idColumn} = ?
  `);
  const chunkSize = 1_048_576;
  const overlap = 4_096;
  let carry = "";
  for (let offset = 1; offset <= length; offset += chunkSize) {
    const chunk = String(readChunk.get(offset, chunkSize, idValue)?.chunk || "");
    const combined = carry + chunk;
    const isLast = offset + chunkSize > length;
    if (isLast) {
      hash.update(normalizeDynamicJsonFields(combined));
      carry = "";
      break;
    }
    let cut = Math.max(0, combined.length - overlap);
    for (const field of DYNAMIC_JSON_FIELDS) {
      const marker = `"${field}"`;
      const markerStart = combined.lastIndexOf(marker, cut);
      if (markerStart >= Math.max(0, cut - 512)) cut = Math.min(cut, markerStart);
    }
    hash.update(normalizeDynamicJsonFields(combined.slice(0, cut)));
    carry = combined.slice(cut);
  }
  if (carry) hash.update(normalizeDynamicJsonFields(carry));
}

function snapshotSignature(db) {
  const hash = crypto.createHash("sha256");
  for (const row of db.prepare(`
    SELECT ticker, payload_json
    FROM valuation_ticker_snapshots
    ORDER BY ticker
  `).iterate()) {
    hash.update(`ticker\0${row.ticker}\0`);
    hash.update(normalizeDynamicJsonFields(row.payload_json));
    hash.update("\n");
  }
  for (const row of db.prepare(`
    SELECT id
    FROM valuation_snapshots
    ORDER BY id
  `).iterate()) {
    hash.update(`dashboard\0${row.id}\0`);
    hashLargeJsonColumn(hash, db, {
      table: "valuation_snapshots",
      idColumn: "id",
      idValue: row.id,
      jsonColumn: "payload_json"
    });
    hash.update("\n");
  }
  return hash.digest("hex");
}

function finite(value) {
  if (value == null || value === "") return null;
  return Number.isFinite(Number(value)) ? Number(value) : null;
}

function ratioMagnitude(left, right) {
  const a = finite(left);
  const b = finite(right);
  if (a == null || b == null || a === 0 || b === 0) return null;
  return Math.max(Math.abs(a / b), Math.abs(b / a));
}

function signChanged(left, right) {
  const a = finite(left);
  const b = finite(right);
  return a != null && b != null && a !== 0 && b !== 0 && Math.sign(a) !== Math.sign(b);
}

function daysBetween(left, right) {
  const a = Date.parse(left);
  const b = Date.parse(right);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return null;
  return Math.abs(b - a) / 86_400_000;
}

function* modelRows(db) {
  for (const row of db.prepare(`
    SELECT ticker, fiscal_period, model_version, as_of_date, financial_available_at,
           guidance_max_observed_at, input_json, output_json
    FROM valuation_pit_model_runs
    ORDER BY ticker, as_of_date, fiscal_period
  `).iterate()) {
    yield {
      ...row,
      ticker: String(row.ticker).toUpperCase(),
      input: JSON.parse(row.input_json),
      output: JSON.parse(row.output_json)
    };
  }
}

function hasChinese(value) {
  return /[\u3400-\u9fff]/.test(String(value || ""));
}

function inspectTranscriptQaSnapshots(db, { requireBilingual = true } = {}) {
  const allowedStatuses = new Set([
    "has_qa",
    "locked_preview",
    "no_segments",
    "partial_transcript",
    "qa_not_found",
    "qa_parse_miss",
    "transcript_not_in_source"
  ]);
  const failures = [];
  const statusCounts = {};
  let tickers = 0;
  let totalPeriods = 0;
  let coveragePeriods = 0;
  let qaPeriods = 0;
  let qaRows = 0;
  let bilingualQaRows = 0;
  let researchAfterModelNodePeriods = 0;
  const qaSourceFields = new Set();

  const tickerList = db.prepare(`
    SELECT ticker
    FROM valuation_ticker_snapshots
    ORDER BY ticker
  `).all().map((row) => String(row.ticker).toUpperCase());
  const snapshot = db.prepare(`
    SELECT payload_json
    FROM valuation_ticker_snapshots
    WHERE ticker = ?
  `);
  let processedTickers = 0;
  for (const ticker of tickerList) {
    const payload = parseJson(snapshot.get(ticker)?.payload_json, {});
    if (payload?.dataQuality?.valuationStatus === "not_applicable") continue;
    processedTickers += 1;
    if (TRACE_MEMORY && processedTickers % 25 === 0) reportProgress(`transcript-qa:${processedTickers}`);
    tickers += 1;
    const history = Array.isArray(payload.history) ? payload.history : [];
    let tickerCoveragePeriods = 0;
    let tickerQaPeriods = 0;
    let tickerQaRows = 0;
    let tickerBilingualQaRows = 0;
    const tickerStatusCounts = {};
    for (const row of history) {
      totalPeriods += 1;
      const youtube = row?.dataSnapshot?.youtubeEarnings || {};
      const coverage = youtube.qaCoverage;
      const qa = Array.isArray(youtube.qa) ? youtube.qa : [];
      if (!coverage || typeof coverage !== "object") {
        failures.push({ ticker, period: row.label || row.periodId, code: "missing_transcript_qa_coverage" });
        continue;
      }
      coveragePeriods += 1;
      tickerCoveragePeriods += 1;
      const status = String(coverage.status || "");
      statusCounts[status] = (statusCounts[status] || 0) + 1;
      tickerStatusCounts[status] = (tickerStatusCounts[status] || 0) + 1;
      if (!allowedStatuses.has(status)) {
        failures.push({ ticker, period: row.label || row.periodId, code: "invalid_transcript_qa_status", status });
      }
      if (coverage.researchOnly !== true || coverage.includedInValuationInputs !== false) {
        failures.push({ ticker, period: row.label || row.periodId, code: "transcript_qa_not_marked_research_only" });
      }
      const expectedAfterModelNode = Boolean(
        coverage.callDate && row.asOfDate &&
        String(coverage.callDate).slice(0, 10) > String(row.asOfDate).slice(0, 10)
      );
      if (Boolean(coverage.availableAfterModelNode) !== expectedAfterModelNode) {
        failures.push({ ticker, period: row.label || row.periodId, code: "wrong_transcript_availability_flag" });
      }
      if (expectedAfterModelNode) researchAfterModelNodePeriods += 1;
      if (Number(coverage.qaCount || 0) !== qa.length) {
        failures.push({ ticker, period: row.label || row.periodId, code: "transcript_qa_count_mismatch" });
      }
      if (status === "has_qa" && !qa.length) {
        failures.push({ ticker, period: row.label || row.periodId, code: "has_qa_without_rows" });
      }
      if (status !== "has_qa" && qa.length) {
        failures.push({ ticker, period: row.label || row.periodId, code: "qa_rows_with_non_qa_status", status });
      }
      if (!qa.length) continue;
      qaPeriods += 1;
      tickerQaPeriods += 1;
      for (const item of qa) {
        qaRows += 1;
        tickerQaRows += 1;
        const bilingual = hasChinese(item?.questionZh) && hasChinese(item?.answerZh);
        if (bilingual) {
          bilingualQaRows += 1;
          tickerBilingualQaRows += 1;
        }
        if (!String(item?.question || "").trim() || !String(item?.answer || "").trim()) {
          failures.push({ ticker, period: row.label || row.periodId, code: "incomplete_transcript_qa_row" });
        }
        const question = String(item?.question || "").trim();
        const answer = String(item?.answer || "").trim();
        if (question) qaSourceFields.add(question);
        if (answer) qaSourceFields.add(answer);
        if (/introduce (?:the )?(?:first|next) question|take (?:the )?(?:first|next) question/i.test(question)) {
          failures.push({ ticker, period: row.label || row.periodId, code: "procedural_transcript_question" });
        }
        if (/^(?:Operator|Investor Relations)\s*:/i.test(answer)) {
          failures.push({ ticker, period: row.label || row.periodId, code: "procedural_transcript_answer" });
        }
        if (requireBilingual && !bilingual) {
          failures.push({ ticker, period: row.label || row.periodId, code: "missing_bilingual_transcript_qa" });
        }
      }
    }
    const stored = payload?.dataQuality?.transcriptQaCoverage || {};
    const expectedStored = {
      totalPeriods: history.length,
      coveragePeriods: tickerCoveragePeriods,
      qaPeriods: tickerQaPeriods,
      qaRows: tickerQaRows,
      bilingualQaRows: tickerBilingualQaRows,
      statusCounts: tickerStatusCounts
    };
    if (canonicalJson(JSON.stringify(stored)) !== canonicalJson(JSON.stringify(expectedStored))) {
      failures.push({ ticker, code: "transcript_qa_summary_mismatch", stored, expected: expectedStored });
    }
  }
  reportProgress("transcript-qa:snapshots-complete");

  const modelPayloadsWithQa = Number(db.prepare(`
    SELECT COUNT(*) AS count
    FROM valuation_pit_model_runs
    WHERE instr(COALESCE(input_json, ''), '"qa"') > 0
       OR instr(COALESCE(output_json, ''), '"qa"') > 0
  `).get().count);
  reportProgress("transcript-qa:model-leak-check");
  if (modelPayloadsWithQa) failures.push({ code: "transcript_qa_leaked_into_model_payload", count: modelPayloadsWithQa });

  const dashboardNumber = (key) => {
    const marker = `"${key}"`;
    const snippet = String(db.prepare(`
      SELECT substr(payload_json, instr(payload_json, ?) + length(?), 80) AS value_tail
      FROM valuation_snapshots
      WHERE id = 'latest' AND instr(payload_json, ?) > 0
    `).get(marker, marker, marker)?.value_tail || "");
    const match = snippet.match(/^\s*:\s*(-?\d+(?:\.\d+)?)/);
    return match ? Number(match[1]) : null;
  };
  const dashboardSummary = {
    tickerCount: dashboardNumber("transcriptQaTickerCount"),
    eventCount: dashboardNumber("transcriptQaEventCount"),
    coverageRows: dashboardNumber("transcriptQaCoverageRows")
  };
  reportProgress("transcript-qa:dashboard-summary");
  if (dashboardSummary.tickerCount !== tickers) {
    failures.push({ code: "dashboard_transcript_ticker_count_mismatch" });
  }
  if (dashboardSummary.eventCount !== qaRows) {
    failures.push({ code: "dashboard_transcript_event_count_mismatch" });
  }
  if (dashboardSummary.coverageRows !== coveragePeriods) {
    failures.push({ code: "dashboard_transcript_coverage_count_mismatch" });
  }
  const storedTranslationAudit = JSON.parse(db.prepare(`
    SELECT value FROM valuation_pit_source_metadata WHERE key = 'transcript_qa_translation_audit'
  `).get()?.value || "null");
  reportProgress("transcript-qa:translation-audit");
  if (requireBilingual && qaRows > 0) {
    if (storedTranslationAudit?.status !== "pass") {
      failures.push({ code: "missing_or_failed_transcript_translation_audit" });
    } else {
      const accepted = Number(storedTranslationAudit.statusCounts?.pass || 0) +
        Number(storedTranslationAudit.statusCounts?.approved || 0);
      if (Number(storedTranslationAudit.usedSourceCount) !== qaSourceFields.size || accepted !== qaSourceFields.size) {
        failures.push({
          code: "transcript_translation_audit_count_mismatch",
          storedUsedSourceCount: storedTranslationAudit.usedSourceCount,
          storedAcceptedCount: accepted,
          expectedSourceFields: qaSourceFields.size
        });
      }
      if (!/^[a-f0-9]{64}$/.test(String(storedTranslationAudit.cacheSha256 || "")) ||
          !/^[a-f0-9]{64}$/.test(String(storedTranslationAudit.auditSha256 || ""))) {
        failures.push({ code: "transcript_translation_artifact_hash_missing" });
      }
    }
  }
  return {
    tickers,
    totalPeriods,
    coveragePeriods,
    qaPeriods,
    qaRows,
    bilingualQaRows,
    researchAfterModelNodePeriods,
    uniqueSourceFields: qaSourceFields.size,
    translationAudit: storedTranslationAudit,
    statusCounts: Object.fromEntries(Object.entries(statusCounts).sort(([left], [right]) => left.localeCompare(right))),
    modelPayloadsWithQa,
    failures
  };
}

function expectedTickerSet(baselineDb) {
  const baselineTickers = [];
  for (const row of baselineDb.prepare(`
    SELECT ticker
    FROM valuation_ticker_snapshots
    ORDER BY ticker
  `).iterate()) {
    baselineTickers.push(row.ticker);
  }
  return guruValuationExpectedTickerSet(baselineTickers);
}

function inspectUniverseManifest() {
  const summary = sp500UniverseSummary();
  const manifest = JSON.parse(fs.readFileSync(summary.manifestPath, "utf8"));
  const companies = Array.isArray(manifest.companies) ? manifest.companies : [];
  const tickers = companies.map((company) => String(company.ticker || "").toUpperCase());
  const ciks = companies.map((company) => String(company.cik || "")).filter(Boolean);
  const shareClasses = companies.flatMap((company) => company.shareClasses || []);
  const aliases = sp500AliasEntries();
  return {
    asOf: summary.asOf,
    manifestPath: summary.manifestPath,
    securityCount: summary.securityCount,
    companyCount: summary.companyCount,
    uniqueTickerCount: new Set(tickers).size,
    uniqueCikCount: new Set(ciks).size,
    shareClassCount: shareClasses.length,
    aliasCount: aliases.length,
    aliases: aliases.map(([alias, canonical]) => ({ alias, canonical }))
  };
}

function inspectSp500PriceCoverage(db) {
  const summary = sp500UniverseSummary();
  const manifest = JSON.parse(fs.readFileSync(summary.manifestPath, "utf8"));
  const snapshot = db.prepare(`
    SELECT json_extract(payload_json, '$.priceHistory') AS price_history_json,
           json_extract(payload_json, '$.latest') AS latest_json
    FROM valuation_ticker_snapshots
    WHERE ticker = ?
  `);
  const failures = [];
  let positiveLatestPrices = 0;
  let nonPositiveStoredPoints = 0;
  let storedPoints = 0;
  let latestPriceDate = null;

  for (const company of manifest.companies || []) {
    const ticker = String(company.ticker).toUpperCase();
    const snapshotRow = snapshot.get(ticker) || {};
    const history = parseJson(snapshotRow.price_history_json, []);
    const latest = parseJson(snapshotRow.latest_json, {});
    const positiveHistory = history.filter((point) => finite(point?.close) > 0);
    const latestPositivePoint = positiveHistory.at(-1) || null;
    storedPoints += history.length;
    nonPositiveStoredPoints += history.length - positiveHistory.length;
    const latestPrice = finite(latest?.latestPrice);
    if (latestPrice > 0) positiveLatestPrices += 1;
    latestPriceDate = [latestPriceDate, latest?.latestPriceDate].filter(Boolean).sort().at(-1) || null;
    if (!(latestPrice > 0)) failures.push({ ticker, code: "missing_positive_latest_price" });
    if (!latestPositivePoint) failures.push({ ticker, code: "missing_positive_price_history" });
    if (company.lastPriceDate && String(latestPositivePoint?.date || "") < String(company.lastPriceDate)) {
      failures.push({
        ticker,
        code: "price_history_older_than_manifest_source",
        latestPriceDate: latestPositivePoint?.date || null,
        manifestPriceDate: company.lastPriceDate
      });
    }
  }
  return {
    companies: (manifest.companies || []).length,
    positiveLatestPrices,
    storedPoints,
    nonPositiveStoredPoints,
    latestPriceDate,
    failures
  };
}

function inspectTrackedPriceCoverage(db, expectedTickers) {
  const snapshot = db.prepare(`
    SELECT json_extract(payload_json, '$.priceHistory') AS price_history_json,
           json_extract(payload_json, '$.latest') AS latest_json
    FROM valuation_ticker_snapshots
    WHERE ticker = ?
  `);
  const failures = [];
  let storedPoints = 0;

  for (const ticker of [...expectedTickers].sort()) {
    const row = snapshot.get(ticker);
    if (!row) {
      failures.push({ ticker, code: "missing_snapshot" });
      continue;
    }
    const history = parseJson(row.price_history_json, []);
    const latest = parseJson(row.latest_json, {});
    const invalidPoints = history.filter((point) => !(finite(point?.close) > 0));
    storedPoints += history.length;
    if (invalidPoints.length) {
      failures.push({ ticker, code: "nonpositive_stored_price", count: invalidPoints.length });
    }
    if (!history.some((point) => finite(point?.close) > 0)) {
      failures.push({ ticker, code: "missing_positive_price_history" });
    }
    if (!(finite(latest?.latestPrice) > 0)) {
      failures.push({ ticker, code: "missing_positive_latest_price" });
    }
  }

  return {
    tickers: expectedTickers.size,
    storedPoints,
    failures
  };
}

function sourceMetadata(db) {
  return Object.fromEntries(db.prepare(`
    SELECT key, value
    FROM valuation_pit_source_metadata
    ORDER BY key
  `).all().map((row) => [row.key, row.value]));
}

function inspectFinancialCoverage(db, baselineDb, expectedTickers, metadata) {
  const hasTable = (database, table) => Boolean(database.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table));
  const rawRows = (database) => database.prepare(`
    SELECT ticker, source_ticker, fiscal_period, dimension, available_at, payload_json
    FROM valuation_pit_financials ORDER BY ticker, fiscal_period, dimension
  `).iterate();
  const dispositions = (database) => database.prepare(`
    SELECT ticker,
           json_extract(payload_json, '$.dataQuality.valuationStatus') AS valuation_status,
           json_extract(payload_json, '$.dataQuality.derivedInstrument') AS derived_instrument,
           json_extract(payload_json, '$.dataQuality.sourceTicker') AS source_ticker
    FROM valuation_ticker_snapshots ORDER BY ticker
  `).iterate();
  const baselineMetadata = hasTable(baselineDb, "valuation_pit_source_metadata") ? sourceMetadata(baselineDb) : {};
  return auditFinancialCoverageRelease({
    requiredTickers: expectedTickers,
    ledger: JSON.parse(metadata.financial_coverage_by_ticker || "null"),
    financialRows: rawRows(db), snapshotDispositions: dispositions(db),
    modelCounts: new Map(db.prepare("SELECT ticker, COUNT(*) AS count FROM valuation_pit_model_runs GROUP BY ticker").all().map((row) => [String(row.ticker).toUpperCase(), Number(row.count)])),
    declaredSummary: JSON.parse(metadata.financial_coverage_summary || "{}"),
    baselineTickers: baselineDb.prepare("SELECT ticker FROM valuation_ticker_snapshots ORDER BY ticker").all().map((row) => row.ticker),
    baselineLedger: JSON.parse(baselineMetadata.financial_coverage_by_ticker || "null"),
    baselineFinancialRows: hasTable(baselineDb, "valuation_pit_financials") ? rawRows(baselineDb) : null,
    baselineSnapshotDispositions: dispositions(baselineDb)
  });
}

function inspectStoredPlusMinusGuidance(db, rejectedEventKeys = new Set()) {
  const rows = db.prepare(`
    SELECT source_id, ticker, fiscal_period, observed_at, metric_name, amount,
           value_text, evidence_excerpt, source_database
    FROM valuation_pit_guidance
    WHERE instr(COALESCE(value_text, '') || ' ' || COALESCE(evidence_excerpt, ''), '±') > 0
       OR instr(COALESCE(value_text, '') || ' ' || COALESCE(evidence_excerpt, ''), 'Â±') > 0
       OR lower(COALESCE(value_text, '') || ' ' || COALESCE(evidence_excerpt, '')) LIKE '%plus or minus%'
       OR lower(COALESCE(value_text, '') || ' ' || COALESCE(evidence_excerpt, '')) LIKE '%+ or -%'
       OR (COALESCE(value_text, '') || ' ' || COALESCE(evidence_excerpt, '')) LIKE '%+/-%'
    ORDER BY ticker, observed_at, metric_name
  `).all();
  const failures = [];
  let monetaryCenterChecks = 0;
  let researchOnlyRows = 0;
  for (const row of rows) {
    if (rejectedEventKeys.has(guidanceReleaseEventKey(row))) { researchOnlyRows += 1; continue; }
    const evidence = `${row.value_text || ""} ${row.evidence_excerpt || ""}`;
    const centerM = guidancePlusMinusCenterM(evidence, row.metric_name);
    if (centerM == null) continue;
    monetaryCenterChecks += 1;
    const storedAmountM = finite(row.amount);
    if (!closeEnough(storedAmountM, centerM)) {
      failures.push({
        ticker: String(row.ticker).toUpperCase(),
        period: row.fiscal_period,
        observedAt: row.observed_at,
        metricName: row.metric_name,
        code: "plus_minus_guidance_center_mismatch",
        storedAmountM,
        expectedCenterM: centerM,
        sourceDatabase: row.source_database
      });
    }
  }
  return {
    rowsWithPlusMinus: rows.length,
    monetaryCenterChecks,
    researchOnlyRows,
    failures
  };
}

function inspectStoredIndependentGuidanceAmounts(db, rejectedEventKeys = new Set()) {
  const rows = db.prepare(`
    SELECT source_id, ticker, fiscal_period, observed_at, metric_name, amount,
           value_text, evidence_excerpt, source_database
    FROM valuation_pit_guidance
    WHERE amount IS NOT NULL
    ORDER BY ticker, observed_at, metric_name
  `).iterate();
  const failures = [];
  let rowsAudited = 0;
  let parallelMetricChecks = 0;
  let researchOnlyRows = 0;
  for (const row of rows) {
    rowsAudited += 1;
    if (rejectedEventKeys.has(guidanceReleaseEventKey(row))) { researchOnlyRows += 1; continue; }
    const evidence = String(row.evidence_excerpt || row.value_text || "");
    const historicalActualMismatch = independentHistoricalActualAmountMismatch({
      amount: row.amount,
      evidence
    });
    if (historicalActualMismatch) {
      failures.push({
        ticker: String(row.ticker).toUpperCase(),
        period: row.fiscal_period,
        observedAt: row.observed_at,
        metricName: row.metric_name,
        code: "historical_actual_stored_as_guidance",
        ...historicalActualMismatch,
        sourceDatabase: row.source_database
      });
      continue;
    }
    const nonGuidanceOwnerMismatch = independentNonGuidanceOwnerAmountMismatch({
      metricName: row.metric_name,
      amount: row.amount,
      evidence
    });
    if (nonGuidanceOwnerMismatch) {
      failures.push({
        ticker: String(row.ticker).toUpperCase(),
        period: row.fiscal_period,
        observedAt: row.observed_at,
        metricName: row.metric_name,
        code: "non_guidance_amount_owner_mismatch",
        ...nonGuidanceOwnerMismatch,
        sourceDatabase: row.source_database
      });
      continue;
    }
    const parallelMismatch = independentParallelMetricAmountMismatch({
      metricName: row.metric_name,
      amount: row.amount,
      evidence
    });
    if (parallelMismatch) {
      parallelMetricChecks += 1;
      failures.push({
        ticker: String(row.ticker).toUpperCase(),
        period: row.fiscal_period,
        observedAt: row.observed_at,
        metricName: row.metric_name,
        code: "parallel_guidance_metric_amount_mismatch",
        ...parallelMismatch,
        sourceDatabase: row.source_database
      });
      continue;
    }
    const mismatch = independentGuidanceMidpointMismatch({ amount: row.amount, evidence });
    if (!mismatch) continue;
    failures.push({
      ticker: String(row.ticker).toUpperCase(),
      period: row.fiscal_period,
      observedAt: row.observed_at,
      metricName: row.metric_name,
      code: "independent_guidance_values_averaged",
      ...mismatch,
      sourceDatabase: row.source_database
    });
  }
  return { rowsAudited, parallelMetricChecks, researchOnlyRows, failures };
}

function inspectStoredGuidanceLineage(db, expectedExtractionVersion) {
  const rows = db.prepare(`
    SELECT source_id, source_database, ticker, fiscal_period, metric_name,
           amount, growth_yoy, growth_qoq, margin_pct, payload_json
    FROM valuation_pit_guidance
    ORDER BY ticker, fiscal_period, observed_at, source_id
  `).iterate();
  const scalarFields = ["amount", "growth_yoy", "growth_qoq", "margin_pct"];
  const allowedSubjects = new Set([
    "company_total",
    "company_total_or_unspecified",
    "segment_or_subset",
    "non_company_or_non_periodic"
  ]);
  const failures = [];
  let rowsAudited = 0;
  let transcriptSubjectChecks = 0;
  let scalarChecks = 0;
  for (const row of rows) {
    rowsAudited += 1;
    const payload = parseJson(row.payload_json, null);
    if (!payload || typeof payload !== "object") {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, sourceId: row.source_id, code: "invalid_guidance_payload" });
      continue;
    }
    for (const field of scalarFields) {
      scalarChecks += 1;
      const stored = finite(row[field]);
      const source = finite(payload[field]);
      if ((stored == null) !== (source == null) || (stored != null && !closeEnough(stored, source))) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          sourceId: row.source_id,
          code: "guidance_scalar_lineage_mismatch",
          field,
          stored,
          source
        });
      }
    }
    if (row.source_database !== "downloaded_online_earnings_transcript") continue;
    transcriptSubjectChecks += 1;
    const nested = payload.payload_json && typeof payload.payload_json === "object"
      ? payload.payload_json
      : payload;
    const subject = String(nested.guidance_subject || "").trim().toLowerCase();
    if (!allowedSubjects.has(subject)) {
      failures.push({
        ticker: row.ticker,
        period: row.fiscal_period,
        sourceId: row.source_id,
        code: "missing_structured_guidance_subject",
        subject: subject || null
      });
    }
    if (expectedExtractionVersion && String(nested.extraction_version || "") !== expectedExtractionVersion) {
      failures.push({
        ticker: row.ticker,
        period: row.fiscal_period,
        sourceId: row.source_id,
        code: "stale_guidance_extraction_version",
        extractionVersion: nested.extraction_version || null,
        expectedExtractionVersion
      });
    }
  }
  const sameQuoteGroups = db.prepare(`
    SELECT ticker, fiscal_period, observed_at, metric_name, value_text,
           SUM(CASE WHEN amount IS NULL AND growth_yoy IS NULL AND growth_qoq IS NULL AND margin_pct IS NULL THEN 1 ELSE 0 END) AS empty_rows,
           SUM(CASE WHEN amount IS NOT NULL OR growth_yoy IS NOT NULL OR growth_qoq IS NOT NULL OR margin_pct IS NOT NULL THEN 1 ELSE 0 END) AS valued_rows
    FROM valuation_pit_guidance
    WHERE source_database = 'downloaded_online_earnings_transcript'
    GROUP BY ticker, fiscal_period, observed_at, metric_name, value_text
    HAVING empty_rows > 0 AND valued_rows > 0
    ORDER BY ticker, fiscal_period, observed_at, metric_name
  `).all();
  const sameQuoteRows = db.prepare(`
    SELECT metric_name, value_text, payload_json FROM valuation_pit_guidance
    WHERE source_database = 'downloaded_online_earnings_transcript'
      AND ticker = ? AND fiscal_period = ? AND observed_at = ?
      AND metric_name = ? AND value_text = ?
    ORDER BY source_id
  `);
  const emptyDuplicates = [];
  let separateOriginalOccurrenceGroups = 0;
  for (const row of sameQuoteGroups) {
    const originals = sameQuoteRows.all(row.ticker, row.fiscal_period, row.observed_at, row.metric_name, row.value_text);
    if (separateOriginalRevenueOccurrences(originals)) {
      separateOriginalOccurrenceGroups += 1;
    } else {
      emptyDuplicates.push(row);
    }
  }
  for (const row of emptyDuplicates) {
    failures.push({
      ticker: row.ticker,
      period: row.fiscal_period,
      observedAt: row.observed_at,
      metricName: row.metric_name,
      code: "empty_duplicate_guidance_event",
      emptyRows: Number(row.empty_rows),
      valuedRows: Number(row.valued_rows)
    });
  }
  return { rowsAudited, scalarChecks, transcriptSubjectChecks, emptyDuplicates: emptyDuplicates.length,
    sameQuoteMixedValueGroups: sameQuoteGroups.length, separateOriginalOccurrenceGroups, failures };
}

function inspectReleasePathLeaks(db) {
  const checks = [
    ["valuation_pit_source_metadata", "value"],
    ["valuation_pit_guidance", "payload_json"],
    ["valuation_pit_model_runs", "input_json"],
    ["valuation_pit_model_runs", "output_json"],
    ["valuation_ticker_snapshots", "payload_json"],
    ["valuation_snapshots", "payload_json"]
  ];
  const localPrefixes = ["/Users/", "/tmp/", "/var/folders/", "/home/"];
  const failures = [];
  for (const [table, column] of checks) {
    const query = db.prepare(`
      SELECT rowid AS id
      FROM ${table}
      WHERE instr(COALESCE(${column}, ''), ?) > 0
      ORDER BY rowid
    `);
    for (const prefix of localPrefixes) {
      for (const row of query.iterate(prefix)) failures.push({ table, column, id: row.id, prefix });
    }
  }
  return { checks: checks.length, failures };
}

function collectForbiddenPriceInputs(value, pathParts = [], matches = []) {
  if (Array.isArray(value)) {
    value.forEach((child, index) => collectForbiddenPriceInputs(child, [...pathParts, String(index)], matches));
    return matches;
  }
  if (!value || typeof value !== "object") return matches;
  for (const [key, child] of Object.entries(value)) {
    const nextPath = [...pathParts, key];
    if (/^(?:priceAtDate|currentPrice|marketPrice|valuationAnchorPrice)$/i.test(key) && child != null) {
      matches.push(nextPath.join("."));
    }
    collectForbiddenPriceInputs(child, nextPath, matches);
  }
  return matches;
}

function closeEnough(actual, expected, tolerance = 1e-7) {
  if (!Number.isFinite(actual) || !Number.isFinite(expected)) return false;
  return Math.abs(actual - expected) <= tolerance * Math.max(1, Math.abs(actual), Math.abs(expected));
}

function inspectSourceCurrencyConversion(row, recordType, sourceRecord, failures) {
  const note = String(sourceRecord?.currencyScaleNote || "");
  const sourceCurrency = String(
    sourceRecord?.sourceCurrency || sourceRecord?.currency || ""
  ).toUpperCase();
  const modelCurrency = String(
    sourceRecord?.modelCurrency || sourceRecord?.currency || ""
  ).toUpperCase();
  const conversion = sourceRecord?.fxConversion || null;
  const context = { ticker: row.ticker, period: row.fiscal_period, recordType };

  if (/fallback|requires review|cross-listing ratio|price[- ]ratio|local price/i.test(note)) {
    failures.push({
      ...context,
      code: "invalid_currency_conversion_policy",
      currencyScaleNote: note
    });
  }
  if (!sourceCurrency || !modelCurrency || sourceCurrency === modelCurrency) {
    if (conversion) {
      failures.push({ ...context, code: "unnecessary_currency_conversion", sourceCurrency, modelCurrency });
    }
    const scale = finite(sourceRecord?.currencyScale);
    if (scale != null && !closeEnough(scale, 1)) {
      failures.push({ ...context, code: "same_currency_non_unit_scale", scale, sourceCurrency, modelCurrency });
    }
    return 0;
  }

  if (!conversion || typeof conversion !== "object") {
    failures.push({ ...context, code: "missing_currency_conversion_lineage", sourceCurrency, modelCurrency });
    return 1;
  }
  const conversionSource = String(conversion.sourceCurrency || "").toUpperCase();
  const conversionTarget = String(conversion.targetCurrency || "").toUpperCase();
  if (conversionSource !== sourceCurrency || conversionTarget !== modelCurrency) {
    failures.push({
      ...context,
      code: "currency_conversion_pair_mismatch",
      sourceCurrency,
      modelCurrency,
      conversionSource,
      conversionTarget
    });
  }
  const sourceUnitsPerEur = finite(conversion.sourceUnitsPerEur);
  const targetUnitsPerEur = finite(conversion.targetUnitsPerEur);
  const conversionRate = finite(conversion.conversionRate);
  const expectedRate = sourceUnitsPerEur > 0 && targetUnitsPerEur > 0
    ? targetUnitsPerEur / sourceUnitsPerEur
    : null;
  if (!(expectedRate > 0) || !closeEnough(conversionRate, expectedRate)) {
    failures.push({
      ...context,
      code: "currency_conversion_rate_math",
      sourceUnitsPerEur,
      targetUnitsPerEur,
      conversionRate,
      expectedRate
    });
  }
  if (!closeEnough(finite(sourceRecord.currencyScale), expectedRate)) {
    failures.push({
      ...context,
      code: "currency_scale_rate_mismatch",
      currencyScale: finite(sourceRecord.currencyScale),
      expectedRate
    });
  }
  if (!/data-api\.ecb\.europa\.eu/i.test(String(conversion.sourceUrl || "")) || !/ECB/i.test(note)) {
    failures.push({
      ...context,
      code: "currency_conversion_not_official_ecb",
      sourceUrl: conversion.sourceUrl || null,
      currencyScaleNote: note
    });
  }
  const financialDate = String(sourceRecord.datekey || row.financial_available_at || "").slice(0, 10);
  for (const field of ["sourceRateDate", "targetRateDate"]) {
    const rateDate = String(conversion[field] || "").slice(0, 10);
    if (!rateDate) {
      failures.push({ ...context, code: "missing_currency_rate_date", field });
      continue;
    }
    if (rateDate > financialDate || rateDate > row.as_of_date) {
      failures.push({ ...context, code: "future_financial_currency_rate", field, rateDate, financialDate });
    }
    const ageDays = daysBetween(rateDate, financialDate);
    if (ageDays == null || ageDays > 10) {
      failures.push({ ...context, code: "stale_financial_currency_rate", field, rateDate, financialDate, ageDays });
    }
  }
  return 1;
}

function inspectModels(db, { reviewedCurrentCandidates = new Map() } = {}) {
  const rows = modelRows(db);
  const failures = [];
  const guidanceEvidenceIds = new Set(db.prepare(`
    SELECT source_id FROM valuation_pit_guidance ORDER BY source_id
  `).all().map((row) => String(row.source_id)));
  const storedPriceOnDate = db.prepare(`
    SELECT date, close, source
    FROM price_points
    WHERE symbol = ? AND date = ?
  `);
  const snapshotPricePayload = db.prepare(`
    SELECT payload_json
    FROM valuation_ticker_snapshots
    WHERE ticker = ?
  `);
  const pitPriceObservation = db.prepare(`
    SELECT ticker, fiscal_period, model_version, price_symbol, price_date,
           close, quote_currency, source, payload_json
    FROM valuation_pit_price_observations
    WHERE ticker = ? AND fiscal_period = ? AND model_version = ?
  `);
  let snapshotPriceTicker = null;
  let snapshotPriceCache = new Map();
  let snapshotQuoteCurrency = null;
  const snapshotPriceOnDate = (ticker, date) => {
    if (snapshotPriceTicker !== ticker) {
      const payload = parseJson(snapshotPricePayload.get(ticker)?.payload_json, {});
      snapshotPriceTicker = ticker;
      snapshotQuoteCurrency = payload.currency || null;
      snapshotPriceCache = new Map((Array.isArray(payload?.priceHistory) ? payload.priceHistory : [])
        .filter((point) => point?.date && finite(point?.close) > 0)
        .map((point) => [String(point.date).slice(0, 10), point]));
    }
    return snapshotPriceCache.get(date) ?? null;
  };
  let rowCount = 0;
  let dcfRows = 0;
  let maxTerminalValueShare = 0;
  let minDcfSpread = Infinity;
  let sourceDateChecks = 0;
  let metricSourceDateChecks = 0;
  let priceInputChecks = 0;
  let storedMarketPriceChecks = 0;
  let snapshotMarketPriceChecks = 0;
  let pitMarketPriceObservationChecks = 0;
  let storedMarketPriceDateMisses = 0;
  let comparisonPriceBasisExclusions = 0;
  let fcfCapChecks = 0;
  let profileMethodChecks = 0;
  let shareBasisChecks = 0;
  let methodArithmeticChecks = 0;
  let targetArithmeticChecks = 0;
  let currencyConversionChecks = 0;
  let guidanceScopeChecks = 0;
  let guidanceUseChecks = 0;
  let guidanceEvidenceLineageChecks = 0;
  let growthInputChecks = 0;
  let equityBridgeChecks = 0;
  let reviewedCurrentRows = 0;
  const financialProfiles = new Set(["bank", "insurance", "card_network_lender", "credit_services", "capital_markets"]);
  const earningsProfiles = new Set(["asset_manager", "insurance_broker", "managed_care", "payments_processor"]);
  const revenueStageProfiles = new Set(["emerging_biotech", "emerging_health_ai"]);
  const revenueGuidanceRoutes = new Set(["operating_company", "multi_method_growth", "revenue_stage"]);
  const operatingGuidanceRoutes = new Set(["operating_company", "multi_method_growth"]);
  const growthInputRoutes = new Set([
    "operating_company",
    "multi_method_growth",
    "customer_cash_earnings",
    "revenue_stage"
  ]);
  const expectedProfiles = new Map([
    ["CIEN", "optical_networking_turnaround"],
    ["COHR", "optical_networking_turnaround"],
    ["CPAY", "payments_processor"],
    ["FI", "payments_processor"],
    ["FIS", "payments_processor"],
    ["FISV", "payments_processor"],
    ["GPN", "payments_processor"],
    ["MA", "payments_network"],
    ["PYPL", "payments_processor"],
    ["V", "payments_network"],
    ["XYZ", "payments_processor"]
  ]);

  for (const row of rows) {
    rowCount += 1;
    if (reviewedCurrentCandidates.has(row.ticker)) {
      // Only the strict source/claims/arithmetic+stored-row replay above can
      // provide this map. Current-specific FCFE models are not generic score
      // models; never force them through a WACC/normalized-margin surrogate.
      const expected = reviewedCurrentCandidates.get(row.ticker).modelRuns[0];
      if (row.fiscal_period !== expected.fiscalPeriod || row.as_of_date !== expected.asOfDate ||
        row.financial_available_at !== expected.financialAvailableAt || row.guidance_max_observed_at !== expected.guidanceMaxObservedAt) {
        failures.push({ ticker: row.ticker, code: "reviewed_current_temporal_scope_changed" });
      }
      reviewedCurrentRows += 1;
      sourceDateChecks += 1; priceInputChecks += 1; methodArithmeticChecks += 1; shareBasisChecks += 1;
      continue;
    }
    const input = row.input;
    const output = row.output;
    const fairValue = finite(output.fairValue);
    const semantics = input.valuationSemantics || output.dataSnapshot?.valuationSemantics || {};
    const scoreInputs = semantics.scoreInputs || {};
    const dcf = scoreInputs.equityDcf || null;
    const sharesM = finite(scoreInputs.sharesM);
    const profile = String(scoreInputs.profile || "");
    const modelRoute = String(scoreInputs.modelRoute || "");
    const methodOutputs = Array.isArray(output.methodOutputs) ? output.methodOutputs : [];
    const methodOutputKeys = new Set(methodOutputs.map((entry) => entry?.key).filter(Boolean));
    const methodOutputValues = new Map(methodOutputs.map((entry) => [entry?.key, finite(entry?.value)]));
    const forbiddenPriceInputs = collectForbiddenPriceInputs(input);
    const expectedProfile = expectedProfiles.get(row.ticker);
    const optionalityMultiplier = finite(scoreInputs.optionalityMultiplier) ?? 1;
    const targetPE = finite(scoreInputs.targetPE);
    const evSalesMultiple = finite(scoreInputs.evSalesMultiple);
    const normalizedMargin = finite(scoreInputs.normalizedMargin);
    const guidanceSelection = input.guidance?.guidanceSelection || {};
    const forwardRevenueSource = String(scoreInputs.forwardRevenueSource || "");
    const financialSourceRecord = input.sourceRecord || input.trailingTwelveMonthsSourceRecord || {};
    const financialPeriodEnd = String(financialSourceRecord.periodEndDate || "").slice(0, 10);
    const financialEventDate = String(financialSourceRecord.eventDate || "").slice(0, 10);

    for (const [metric, selection] of Object.entries(guidanceSelection)) {
      if (!selection || typeof selection !== "object") continue;
      for (const [countField, idField, subjectField] of [
        ["acceptedCount", "acceptedEvidenceIds", "acceptedSubjects"],
        ["unscopedCount", "unscopedEvidenceIds", "unscopedSubjects"],
        ["acceptedQuarterCount", "quarterEvidenceIds", "quarterSubjects"]
      ]) {
        const count = finite(selection[countField]) || 0;
        const evidenceIds = Array.isArray(selection[idField]) ? selection[idField].map(String) : [];
        const subjects = Array.isArray(selection[subjectField]) ? selection[subjectField].map(String) : [];
        if (count > 0 && evidenceIds.length === 0) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_selected_guidance_evidence_ids", metric, countField, count });
        }
        for (const evidenceId of evidenceIds) {
          guidanceEvidenceLineageChecks += 1;
          if (!guidanceEvidenceIds.has(evidenceId)) {
            failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "selected_guidance_evidence_id_missing", metric, evidenceId });
          }
        }
        const forbiddenSubjects = subjects.filter((subject) =>
          ["segment_or_subset", "non_company_or_non_periodic"].includes(subject)
        );
        if (forbiddenSubjects.length) {
          failures.push({
            ticker: row.ticker,
            period: row.fiscal_period,
            code: "non_company_guidance_selected",
            metric,
            subjects: forbiddenSubjects
          });
        }
      }
    }

    if (!(fairValue > 0)) failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "invalid_fair_value" });
    if (!(sharesM > 0)) failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "invalid_share_count", sharesM });
    if (row.financial_available_at > row.as_of_date) failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "future_financial" });
    if (financialPeriodEnd) {
      sourceDateChecks += 1;
      if (financialPeriodEnd > row.financial_available_at) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: "financial_period_ends_after_source_available",
          financialPeriodEnd,
          financialAvailableAt: row.financial_available_at
        });
      }
    }
    if (financialEventDate) {
      sourceDateChecks += 1;
      if (financialEventDate > row.as_of_date) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: "financial_event_after_model_node",
          financialEventDate,
          asOfDate: row.as_of_date
        });
      }
    }
    if (row.guidance_max_observed_at && row.guidance_max_observed_at > row.as_of_date) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "future_guidance" });
    }
    if (semantics.priceExcludedFromFairValue !== true) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "price_not_excluded" });
    }
    priceInputChecks += 1;
    if (forbiddenPriceInputs.length) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "market_price_in_model_input", paths: forbiddenPriceInputs });
    }
    const outputPriceDate = String(output.priceDate || "").slice(0, 10);
    const outputPrice = finite(output.priceAtDate);
    if (outputPrice != null) {
      const priceSymbol = valuationMarketPriceSymbol(row.ticker);
      const storedPrice = storedPriceOnDate.get(priceSymbol, outputPriceDate);
      const snapshotPoint = snapshotPriceOnDate(row.ticker, outputPriceDate);
      const observation = pitPriceObservation.get(row.ticker, row.fiscal_period, row.model_version);
      const shared = { priceSymbol, quoteCurrency: snapshotQuoteCurrency, sourceField: "close", unit: "currency_per_share" };
      const candidates = [];
      if (storedPrice) candidates.push({ ...shared, ...storedPrice, id: "price_points", kind: "raw_price_point" });
      if (snapshotPoint) candidates.push({ ...shared, ...snapshotPoint, id: "valuation_ticker_snapshots.priceHistory", kind: "released_snapshot" });
      if (observation) candidates.push({
        ...shared, id: "valuation_pit_price_observations", kind: "pit_observation",
        ticker: observation.ticker, fiscalPeriod: observation.fiscal_period, modelVersion: observation.model_version,
        priceSymbol: observation.price_symbol, quoteCurrency: observation.quote_currency,
        date: observation.price_date, close: finite(observation.close), source: observation.source,
        payloadSource: parseJson(observation.payload_json, {})?.source?.source
      });
      // Resolve source/field/adjustment basis before comparing numbers. Matching
      // storage alone proves lineage, not independent original-vendor
      // verification; that source audit is a separate release artifact.
      const priceAudit = auditValuationComparisonPrice({
        ticker: row.ticker, fiscalPeriod: row.fiscal_period, modelVersion: row.model_version,
        asOfDate: row.as_of_date, priceDate: outputPriceDate, priceSymbol,
        quoteCurrency: snapshotQuoteCurrency,
        declaredSource: output.dataSnapshot?.asOfPriceSource?.source,
        candidates, outputPrice
      });
      comparisonPriceBasisExclusions += priceAudit.excluded?.length || 0;
      if (priceAudit.status === "ready") {
        if (priceAudit.selectedEvidenceKind === "raw_price_point") storedMarketPriceChecks += 1;
        if (priceAudit.selectedEvidenceKind === "released_snapshot") snapshotMarketPriceChecks += 1;
        if (priceAudit.selectedEvidenceKind === "pit_observation") pitMarketPriceObservationChecks += 1;
      } else {
        if (priceAudit.reason === "declared_price_source_unreconciled") storedMarketPriceDateMisses += 1;
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: priceAudit.reason,
          asOfDate: row.as_of_date,
          priceSymbol,
          priceDate: outputPriceDate,
          outputPrice,
          priceAudit
        });
      }
    }

    const shareSource = input.trailingTwelveMonthsSourceRecord || input.sourceRecord || {};
    for (const [sourceRecord, financialSources, financial] of [
      [input.sourceRecord, output.dataSnapshot?.secCompanyFacts?.sourceTags, input.financial],
      [input.trailingTwelveMonthsSourceRecord, output.dataSnapshot?.financialSource?.trailingTwelveMonthsSources, input.trailingTwelveMonths]
    ]) {
      failures.push(...auditReviewedFinancialSource({ ticker: row.ticker, fiscalPeriod: row.fiscal_period,
        sourceRecord: sourceRecord || {}, financialSources: financialSources || {}, financial: financial || {},
        asOfDate: row.as_of_date }).failures);
    }
    const rawShareCounts = shareSource.rawShareCounts;
    const reviewedShareAudit = auditReviewedShareCount({
      ticker: row.ticker,
      fiscalPeriod: row.fiscal_period,
      sourceRecord: shareSource,
      financialShareSource: output.dataSnapshot?.secCompanyFacts?.sourceTags?.shares_m,
      scoreSharesM: sharesM,
      financialSharesM: finite(input.financial?.shares_m),
      trailingSharesM: finite(input.trailingTwelveMonths?.shares_m),
      asOfDate: row.as_of_date
    });
    if (reviewedShareAudit.applies) {
      shareBasisChecks += 1;
      failures.push(...reviewedShareAudit.failures);
    }
    if (!reviewedShareAudit.applies && rawShareCounts && typeof rawShareCounts === "object") {
      shareBasisChecks += 1;
      const basicShares = finite(rawShareCounts.sharesbas);
      const dilutedShares = finite(rawShareCounts.shareswadil);
      const weightedShares = finite(rawShareCounts.shareswa);
      const expectedBasis = basicShares > 0
        ? "sharesbas"
        : dilutedShares > 0
          ? "shareswadil"
          : weightedShares > 0
            ? "shareswa"
            : null;
      const reportedBasis = String(shareSource.shareCountBasis || "");
      const shareFactor = finite(shareSource.appliedShareFactor) ?? finite(shareSource.sharefactor) ?? 1;
      const expectedSharesM = expectedBasis ? finite(rawShareCounts[expectedBasis]) * shareFactor / 1_000_000 : null;
      if (!expectedBasis) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_positive_source_share_basis" });
      } else if (reportedBasis !== expectedBasis) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "wrong_source_share_basis", reportedBasis, expectedBasis });
      }
      if (!closeEnough(sharesM, expectedSharesM)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "source_share_factor_math", sharesM, expectedSharesM, shareFactor });
      }
      if (!/period-end basic (?:ordinary )?shares/i.test(String(shareSource.shareCountPolicy || ""))) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_share_basis_policy" });
      }
    }
    if (semantics.shareBasisAdjustmentFactor != null) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "retroactive_share_basis_adjustment_present" });
    }
    if (expectedProfile && profile !== expectedProfile) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "wrong_economic_profile", profile, expectedProfile });
    }
    if (!modelRoute) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_model_route" });
    }
    if (optionalityMultiplier > 1.000001) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "base_optionality_uplift", optionalityMultiplier });
    }
    if (targetPE != null && targetPE > 72.000001) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "target_pe_hard_bound", targetPE });
    }
    if (evSalesMultiple != null && evSalesMultiple > 40.000001) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "ev_sales_hard_bound", evSalesMultiple });
    }
    if (normalizedMargin != null && normalizedMargin > 65.000001) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "normalized_margin_hard_bound", normalizedMargin });
    }
    if (growthInputRoutes.has(modelRoute)) {
      growthInputChecks += 1;
      const growthInput = scoreInputs.growthInput;
      if (!growthInput || typeof growthInput !== "object") {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_growth_input_lineage", modelRoute });
      } else {
        const growthValue = finite(growthInput.value);
        const baseGrowth = finite(growthInput.baseGrowthPct);
        const fundamentalGrowth = finite(growthInput.fundamentalGrowthPct);
        const reportedFundamentalGrowth = finite(growthInput.reportedFundamentalGrowthPct);
        const fundamentalGrowthEvidenceWeight = finite(growthInput.fundamentalGrowthEvidenceWeight);
        const minimumSampleCount = finite(growthInput.minimumSampleCount);
        const reportedGuidanceGrowth = finite(growthInput.reportedGuidanceGrowthPct);
        const boundedGuidanceGrowth = finite(growthInput.boundedGuidanceGrowthPct);
        const guidanceWeight = finite(growthInput.guidanceWeight);
        const maxGuidanceDelta = finite(growthInput.maxGuidanceDeltaPct);
        const capPct = finite(growthInput.capPct);
        const normalizedWindow = finite(growthInput.normalizedWindow);
        const normalizedSampleCount = finite(growthInput.normalizedSampleCount);
        const evidenceGuidanceGrowth = finite(input.guidance?.revenueGuidanceGrowth);
        const allowedSources = new Set([
          "pit_financials_evidence_ramp_bounded_guidance_blend",
          "pit_financials_bounded_guidance_blend",
          "pit_financials_evidence_ramp",
          "pit_financials",
          "conservative_default_bounded_guidance_blend",
          "conservative_default"
        ]);
        if (!allowedSources.has(growthInput.source)) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "invalid_growth_input_source", source: growthInput.source });
        }
        if (!(normalizedWindow >= 1) || !(normalizedSampleCount >= 0 && normalizedSampleCount <= normalizedWindow)) {
          failures.push({
            ticker: row.ticker,
            period: row.fiscal_period,
            code: "invalid_growth_normalization_window",
            normalizedWindow,
            normalizedSampleCount
          });
        }
        if (growthInput.source.startsWith("pit_financials") && !(normalizedSampleCount > 0)) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_growth_financial_samples" });
        }
        if (!closeEnough(growthValue, finite(scoreInputs.revenueGrowth))) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "growth_value_lineage_mismatch", growthValue, revenueGrowth: finite(scoreInputs.revenueGrowth) });
        }
        if (
          (reportedGuidanceGrowth == null) !== (evidenceGuidanceGrowth == null) ||
          (reportedGuidanceGrowth != null && !closeEnough(reportedGuidanceGrowth, evidenceGuidanceGrowth))
        ) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "growth_guidance_lineage_mismatch", reportedGuidanceGrowth, evidenceGuidanceGrowth });
        }
        if (!(guidanceWeight >= 0 && guidanceWeight <= 0.250001) || !(maxGuidanceDelta >= 0 && maxGuidanceDelta <= 15.000001) || !(capPct > 0)) {
          failures.push({
            ticker: row.ticker,
            period: row.fiscal_period,
            code: "growth_guidance_bound_invalid",
            guidanceWeight,
            maxGuidanceDelta,
            capPct
          });
        } else {
          const clampGrowth = (value, low, high) => Math.min(high, Math.max(low, value));
          const expectedMinimumSampleCount = Math.max(1, minimumSampleCount ?? 4);
          const expectedInsufficientGrowthHistory = normalizedSampleCount != null &&
            normalizedSampleCount < expectedMinimumSampleCount;
          const expectedEvidenceWeight = reportedFundamentalGrowth == null || expectedInsufficientGrowthHistory
            ? 0
            : normalizedSampleCount == null
              ? 1
              : clampGrowth(
                (normalizedSampleCount - expectedMinimumSampleCount + 1) / 4,
                0.25,
                1
              );
          const expectedFundamentalGrowth = expectedEvidenceWeight > 0 ? reportedFundamentalGrowth : null;
          if (!closeEnough(fundamentalGrowthEvidenceWeight, expectedEvidenceWeight)) {
            failures.push({
              ticker: row.ticker,
              period: row.fiscal_period,
              code: "growth_evidence_weight_math",
              fundamentalGrowthEvidenceWeight,
              expectedEvidenceWeight
            });
          }
          if (Boolean(growthInput.insufficientGrowthHistory) !== expectedInsufficientGrowthHistory) {
            failures.push({
              ticker: row.ticker,
              period: row.fiscal_period,
              code: "growth_insufficient_history_flag",
              insufficientGrowthHistory: growthInput.insufficientGrowthHistory,
              expectedInsufficientGrowthHistory
            });
          }
          if (
            (fundamentalGrowth == null) !== (expectedFundamentalGrowth == null) ||
            (fundamentalGrowth != null && !closeEnough(fundamentalGrowth, expectedFundamentalGrowth))
          ) {
            failures.push({
              ticker: row.ticker,
              period: row.fiscal_period,
              code: "growth_fundamental_lineage_mismatch",
              fundamentalGrowth,
              expectedFundamentalGrowth
            });
          }
          const expectedBaseGrowth = expectedFundamentalGrowth == null
            ? 5
            : 5 * (1 - expectedEvidenceWeight) + expectedFundamentalGrowth * expectedEvidenceWeight;
          if (!closeEnough(baseGrowth, expectedBaseGrowth)) {
            failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "growth_base_lineage_mismatch", baseGrowth, expectedBaseGrowth });
          }
          const expectedBoundedGuidance = reportedGuidanceGrowth == null
            ? null
            : clampGrowth(reportedGuidanceGrowth, expectedBaseGrowth - maxGuidanceDelta, expectedBaseGrowth + maxGuidanceDelta);
          if (
            (boundedGuidanceGrowth == null) !== (expectedBoundedGuidance == null) ||
            (boundedGuidanceGrowth != null && !closeEnough(boundedGuidanceGrowth, expectedBoundedGuidance))
          ) {
            failures.push({
              ticker: row.ticker,
              period: row.fiscal_period,
              code: "growth_guidance_bound_math",
              boundedGuidanceGrowth,
              expectedBoundedGuidance
            });
          }
          const expectedRawGrowth = expectedBaseGrowth * (1 - guidanceWeight) +
            (expectedBoundedGuidance ?? expectedBaseGrowth) * guidanceWeight;
          const expectedGrowth = clampGrowth(expectedRawGrowth, -20, capPct);
          if (!closeEnough(growthValue, expectedGrowth)) {
            failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "growth_blend_math", growthValue, expectedGrowth });
          }
          if (reportedGuidanceGrowth == null && guidanceWeight !== 0) {
            failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "growth_weight_without_guidance", guidanceWeight });
          }
          if (reportedGuidanceGrowth != null && guidanceWeight > 0.250001) {
            failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "growth_guidance_weight_above_contract", guidanceWeight });
          }
          const expectedSource = expectedFundamentalGrowth != null && reportedGuidanceGrowth != null
            ? expectedEvidenceWeight < 1
              ? "pit_financials_evidence_ramp_bounded_guidance_blend"
              : "pit_financials_bounded_guidance_blend"
            : expectedFundamentalGrowth != null
              ? expectedEvidenceWeight < 1
                ? "pit_financials_evidence_ramp"
                : "pit_financials"
              : reportedGuidanceGrowth != null
                ? "conservative_default_bounded_guidance_blend"
                : "conservative_default";
          if (growthInput.source !== expectedSource) {
            failures.push({
              ticker: row.ticker,
              period: row.fiscal_period,
              code: "growth_source_lineage_mismatch",
              source: growthInput.source,
              expectedSource
            });
          }
        }
      }
    }
    guidanceScopeChecks += 1;
    if (forwardRevenueSource === "unscoped_annual_guidance") {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "unscoped_annual_revenue_used" });
    }
    if (forwardRevenueSource === "full_year_guidance" && guidanceSelection.revenue?.mode !== "explicit_full_year") {
      failures.push({
        ticker: row.ticker,
        period: row.fiscal_period,
        code: "full_year_revenue_without_explicit_scope",
        mode: guidanceSelection.revenue?.mode || null
      });
    }
    if (finite(scoreInputs.guidanceOperatingIncomeM) > 0 && guidanceSelection.operatingIncome?.mode !== "explicit_full_year") {
      failures.push({
        ticker: row.ticker,
        period: row.fiscal_period,
        code: "operating_income_guidance_without_explicit_scope",
        mode: guidanceSelection.operatingIncome?.mode || null
      });
    }
    if (finite(scoreInputs.fcfGuidanceM) > 0 && guidanceSelection.freeCashFlow?.mode !== "explicit_full_year") {
      failures.push({
        ticker: row.ticker,
        period: row.fiscal_period,
        code: "fcf_guidance_without_explicit_scope",
        mode: guidanceSelection.freeCashFlow?.mode || null
      });
    }
    if (revenueGuidanceRoutes.has(modelRoute) && guidanceSelection.revenue?.mode === "explicit_full_year") {
      guidanceUseChecks += 1;
      if (forwardRevenueSource !== "full_year_guidance" && !scoreInputs.revenueGuidanceRejectedReason) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: "explicit_revenue_guidance_silently_ignored",
          modelRoute,
          reportedRevenueGuidanceM: finite(scoreInputs.reportedRevenueGuidanceM)
        });
      }
    }
    if (operatingGuidanceRoutes.has(modelRoute) && guidanceSelection.operatingIncome?.mode === "explicit_full_year") {
      guidanceUseChecks += 1;
      if (!(finite(scoreInputs.guidanceOperatingIncomeM) > 0) && !scoreInputs.guidanceOperatingIncomeRejectedReason) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: "explicit_operating_income_guidance_silently_ignored",
          modelRoute,
          reportedGuidanceOperatingIncomeM: finite(scoreInputs.reportedGuidanceOperatingIncomeM)
        });
      }
    }
    if (operatingGuidanceRoutes.has(modelRoute) && guidanceSelection.freeCashFlow?.mode === "explicit_full_year") {
      guidanceUseChecks += 1;
      if (!(finite(scoreInputs.fcfGuidanceM) > 0) && !scoreInputs.fcfGuidanceRejectedReason) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: "explicit_fcf_guidance_silently_ignored",
          modelRoute,
          reportedFcfGuidanceM: finite(scoreInputs.reportedFcfGuidanceM)
        });
      }
    }

    const methodWeights = scoreInputs.methodWeights && typeof scoreInputs.methodWeights === "object"
      ? Object.entries(scoreInputs.methodWeights)
      : [];
    const salesWeight = finite(scoreInputs.methodWeights?.["ev-sales-equity-value"]);
    if (salesWeight > 0) {
      equityBridgeChecks += 1;
      const salesRetention = finite(scoreInputs.salesEquityRetention);
      const minimumSalesRetention = finite(scoreInputs.minimumSalesEquityRetention) ?? 0.01;
      if (!(salesRetention >= minimumSalesRetention) || scoreInputs.salesValueRejectionReason) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: "fragile_ev_to_equity_bridge",
          salesWeight,
          salesRetention,
          minimumSalesRetention,
          reason: scoreInputs.salesValueRejectionReason || null
        });
      }
    }
    let reconstructedFairValue = null;
    if (methodWeights.length) {
      const weightSum = methodWeights.reduce((sum, [, weight]) => sum + (finite(weight) || 0), 0);
      if (!closeEnough(weightSum, 1)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "method_weights_do_not_sum_to_one", weightSum });
      }
      let weightedValue = 0;
      for (const [key, rawWeight] of methodWeights) {
        const weight = finite(rawWeight);
        const value = methodOutputValues.get(key);
        if (!(weight >= 0 && weight <= 1)) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "invalid_method_weight", key, weight });
          continue;
        }
        if (weight > 0 && !(value > 0)) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "weighted_method_missing_positive_value", key, value });
          continue;
        }
        if (value != null) weightedValue += value * weight;
      }
      reconstructedFairValue = weightedValue * (finite(scoreInputs.optionalityMultiplier) ?? 1);
    } else if (financialProfiles.has(profile)) {
      const bookValue = methodOutputValues.get("roe-implied-book-value");
      const epsValue = methodOutputValues.get("eps-cross-check");
      const bookWeight = (methodOutputValues.get("financial-method-weighting") ?? NaN) / 100;
      reconstructedFairValue = bookValue != null && epsValue != null && Number.isFinite(bookWeight)
        ? bookValue * bookWeight + epsValue * (1 - bookWeight)
        : null;
    } else if (earningsProfiles.has(profile)) {
      reconstructedFairValue = methodOutputValues.get("through-cycle-eps");
    } else if (profile === "bitcoin_treasury_software") {
      reconstructedFairValue = ["btc-treasury-nav", "software-business-value", "net-cash-debt-bridge"]
        .reduce((sum, key) => sum + (methodOutputValues.get(key) || 0), 0);
    } else if (revenueStageProfiles.has(profile)) {
      const valuationRevenue = finite(scoreInputs.valuationRevenue);
      const evSalesMultiple = finite(scoreInputs.evSalesMultiple);
      const cashM = finite(scoreInputs.cashM) || 0;
      const debtM = finite(scoreInputs.debtM) || 0;
      reconstructedFairValue = valuationRevenue != null && evSalesMultiple != null && sharesM > 0
        ? Math.max(0, valuationRevenue * evSalesMultiple + cashM - debtM) / sharesM
        : null;
    }
    const economicInputAudit = auditReviewedEconomicInput({
      ticker: row.ticker, fiscalPeriod: row.fiscal_period,
      marker: scoreInputs.reviewedEconomicInput, financial: input.financial,
      trailing: input.trailingTwelveMonths, sharesM, fairValue,
      reconstructedBeforeClaims: reconstructedFairValue, asOfDate: row.as_of_date
    });
    failures.push(...economicInputAudit.failures);
    if (economicInputAudit.applies && economicInputAudit.claimsPerShare != null && reconstructedFairValue != null) {
      reconstructedFairValue -= economicInputAudit.claimsPerShare;
    }
    methodArithmeticChecks += 1;
    if (!closeEnough(fairValue, reconstructedFairValue)) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "fair_value_method_arithmetic", fairValue, reconstructedFairValue, profile });
    }

    const targetPrice3Y = finite(output.targetPrice3Y);
    const priceAtDate = finite(output.priceAtDate);
    const upsideDownside = finite(output.upsideDownside);
    const expectedReturn3Y = finite(output.expectedReturn3Y);
    targetArithmeticChecks += 1;
    if (!(targetPrice3Y > 0)) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "invalid_three_year_target", targetPrice3Y });
    } else {
      const impliedGrowth = (targetPrice3Y / fairValue) ** (1 / 3) - 1;
      if (!(impliedGrowth >= -1e-9 && impliedGrowth <= 0.140001)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "three_year_target_growth_out_of_bounds", impliedGrowth });
      }
      if (priceAtDate > 0) {
        const expectedUpside = fairValue / priceAtDate - 1;
        const expectedReturn = (targetPrice3Y / priceAtDate) ** (1 / 3) - 1;
        if (!closeEnough(upsideDownside, expectedUpside)) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "upside_math", upsideDownside, expectedUpside });
        }
        if (!closeEnough(expectedReturn3Y, expectedReturn)) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "three_year_expected_return_math", expectedReturn3Y, expectedReturn });
        }
      }
    }
    let rowFinancialSourceDateChecks = 0;
    for (const [recordType, sourceRecord] of Object.entries({
      base: input.sourceRecord || {},
      trailing_twelve_months: input.trailingTwelveMonthsSourceRecord || {}
    })) {
      currencyConversionChecks += inspectSourceCurrencyConversion(
        row,
        recordType,
        sourceRecord,
        failures
      );
      for (const [field, filed] of Object.entries({
        datekey: sourceRecord.datekey,
        eventDate: sourceRecord.eventDate,
        filedAt: sourceRecord.filedAt
      })) {
        if (!filed) continue;
        sourceDateChecks += 1;
        rowFinancialSourceDateChecks += 1;
        if (filed > row.as_of_date) {
          failures.push({
            ticker: row.ticker,
            period: row.fiscal_period,
            code: "future_financial_source",
            recordType,
            field,
            filed
          });
        }
        if (filed > row.financial_available_at) {
          failures.push({
            ticker: row.ticker,
            period: row.fiscal_period,
            code: "financial_source_after_recorded_availability",
            recordType,
            field,
            filed,
            financialAvailableAt: row.financial_available_at
          });
        }
      }
    }
    if (rowFinancialSourceDateChecks === 0) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_financial_source_date" });
    }
    for (const [metric, source] of Object.entries(output.dataSnapshot?.secCompanyFacts?.sourceTags || {})) {
      const filed = source?.filed;
      if (!filed) continue;
      sourceDateChecks += 1;
      metricSourceDateChecks += 1;
      if (filed > row.as_of_date) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "future_metric_source", metric, filed });
      }
      if (filed > row.financial_available_at) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: "metric_source_after_recorded_availability",
          metric,
          filed,
          financialAvailableAt: row.financial_available_at
        });
      }
    }
    for (const evidence of input.guidance?.evidence || []) {
      const observedAt = evidence?.observedAt;
      if (!observedAt) continue;
      sourceDateChecks += 1;
      if (observedAt > row.as_of_date) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "future_guidance_evidence", observedAt });
      }
    }
    for (const conversion of input.guidance?.fxConversions || []) {
      for (const field of ["sourceRateDate", "targetRateDate"]) {
        const rateDate = conversion?.[field];
        if (!rateDate) continue;
        sourceDateChecks += 1;
        if (rateDate > row.as_of_date) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "future_fx_rate", field, rateDate });
        }
      }
    }
    const rawFcf = finite(scoreInputs.rawValuationFreeCashFlow);
    const valuationFcf = finite(scoreInputs.valuationFreeCashFlow);
    const valuationRevenue = finite(scoreInputs.valuationRevenue ?? scoreInputs.ttmRevenue);
    const valuationFcfCapMargin = finite(scoreInputs.valuationFreeCashFlowCapMargin);
    if (rawFcf != null || valuationFcf != null) {
      fcfCapChecks += 1;
      if (rawFcf != null && valuationFcf != null && valuationFcf > Math.max(0, rawFcf) + 1e-7) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "fcf_cap_increased_input", rawFcf, valuationFcf });
      }
      if (!(valuationFcfCapMargin >= 0.08 && valuationFcfCapMargin <= 0.650001)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_or_invalid_fcf_sustainability_cap", valuationFcfCapMargin });
      }
      if (valuationFcf > 0 && valuationRevenue > 0 && valuationFcf / valuationRevenue > valuationFcfCapMargin + 1e-7) {
        failures.push({
          ticker: row.ticker,
          period: row.fiscal_period,
          code: "fcf_margin_above_sustainability_cap",
          fcfMargin: valuationFcf / valuationRevenue,
          valuationFcfCapMargin
        });
      }
    }
    const burdenPct = finite(scoreInputs.belowOperatingIncomeBurden);
    if (burdenPct != null && !(burdenPct >= 0 && burdenPct <= 25.000001)) {
      failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "below_operating_burden_out_of_bounds", burdenPct });
    }
    if (earningsProfiles.has(profile)) {
      profileMethodChecks += 1;
      if (dcf || methodOutputKeys.has("fcfe-dcf") || methodOutputKeys.has("roe-implied-book-value")) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "customer_cash_flow_or_book_value_method_used", profile });
      }
      if (!(finite(scoreInputs.normalizedEps) > 0) || !methodOutputKeys.has("through-cycle-eps")) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_through_cycle_eps_method", profile });
      }
      if (!methodOutputKeys.has("customer-cash-flow-exclusion")) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "missing_customer_cash_flow_exclusion", profile });
      }
    }
    if (financialProfiles.has(profile)) {
      profileMethodChecks += 1;
      if (dcf || methodOutputKeys.has("fcfe-dcf")) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "financial_customer_cash_flow_used_in_dcf", profile });
      }
    }
    if (dcf) {
      dcfRows += 1;
      const discountRate = finite(dcf.discountRate);
      const terminalGrowth = finite(dcf.terminalGrowth);
      const terminalValueShare = finite(dcf.terminalValueShare);
      const presentValueM = finite(dcf.presentValueM);
      const terminalValueM = finite(dcf.terminalValueM);
      const terminalPresentValueM = finite(dcf.terminalPresentValueM);
      const dcfFairValue = finite(dcf.fairValue);
      const cycleHaircut = finite(semantics.scoreInputs?.cycleHaircut) ?? 1;
      const annualCashFlows = Array.isArray(dcf.annualCashFlows) ? dcf.annualCashFlows : [];
      if (!(discountRate - terminalGrowth >= 0.045 - 1e-9)) failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "invalid_dcf_spread" });
      if (!(discountRate >= 0.085 && discountRate <= 0.18)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "discount_rate_out_of_bounds", discountRate });
      }
      if (!(terminalGrowth >= 0.01 && terminalGrowth <= 0.04)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "terminal_growth_out_of_bounds", terminalGrowth });
      }
      if (!(terminalValueShare > 0 && terminalValueShare <= 0.8)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "terminal_value_concentration", terminalValueShare });
      }
      if (annualCashFlows.length !== 5) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "invalid_dcf_horizon", years: annualCashFlows.length });
      }
      for (const cashFlow of annualCashFlows) {
        const year = finite(cashFlow.year);
        const fcfM = finite(cashFlow.fcfM);
        const cashFlowPresentValueM = finite(cashFlow.presentValueM);
        const expectedPresentValueM = fcfM != null && year != null && discountRate != null
          ? fcfM / (1 + discountRate) ** year
          : null;
        if (!closeEnough(cashFlowPresentValueM, expectedPresentValueM)) {
          failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "dcf_cash_flow_math", year });
        }
      }
      const finalFcfM = finite(annualCashFlows.at(-1)?.fcfM);
      const expectedTerminalValueM = finalFcfM != null && discountRate != null && terminalGrowth != null
        ? finalFcfM * (1 + terminalGrowth) / (discountRate - terminalGrowth)
        : null;
      const expectedTerminalPresentValueM = expectedTerminalValueM != null && discountRate != null
        ? expectedTerminalValueM / (1 + discountRate) ** 5
        : null;
      const expectedPresentValueM = annualCashFlows.reduce((sum, cashFlow) => sum + (finite(cashFlow.presentValueM) || 0), 0) + (terminalPresentValueM || 0);
      const expectedDcfFairValue = presentValueM != null && sharesM != null ? presentValueM / sharesM * cycleHaircut : null;
      if (!closeEnough(terminalValueM, expectedTerminalValueM)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "dcf_terminal_value_math" });
      }
      if (!closeEnough(terminalPresentValueM, expectedTerminalPresentValueM)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "dcf_terminal_discount_math" });
      }
      if (!closeEnough(presentValueM, expectedPresentValueM)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "dcf_present_value_math" });
      }
      if (!closeEnough(dcfFairValue, expectedDcfFairValue)) {
        failures.push({ ticker: row.ticker, period: row.fiscal_period, code: "dcf_per_share_math" });
      }
      maxTerminalValueShare = Math.max(maxTerminalValueShare, terminalValueShare || 0);
      minDcfSpread = Math.min(minDcfSpread, (discountRate || 0) - (terminalGrowth || 0));
    }
  }

  return {
    rows: rowCount,
    reviewedCurrentRows,
    dcfRows,
    failures,
    maxTerminalValueShare,
    minDcfSpread: Number.isFinite(minDcfSpread) ? minDcfSpread : null,
    sourceDateChecks,
    metricSourceDateChecks,
    priceInputChecks,
    storedMarketPriceChecks,
    snapshotMarketPriceChecks,
    pitMarketPriceObservationChecks,
    storedMarketPriceDateMisses,
    comparisonPriceBasisExclusions,
    fcfCapChecks,
    profileMethodChecks,
    shareBasisChecks,
    methodArithmeticChecks,
    targetArithmeticChecks,
    currencyConversionChecks,
    guidanceScopeChecks,
    guidanceUseChecks,
    guidanceEvidenceLineageChecks,
    growthInputChecks,
    equityBridgeChecks
  };
}

function latestTicker(db, ticker) {
  const row = db.prepare(`
    SELECT fiscal_period, as_of_date, input_json, output_json
    FROM valuation_pit_model_runs
    WHERE ticker = ?
    ORDER BY as_of_date DESC
    LIMIT 1
  `).get(ticker);
  if (!row) return null;
  const input = JSON.parse(row.input_json);
  const output = JSON.parse(row.output_json);
  const scoreInputs = input.valuationSemantics?.scoreInputs || output.dataSnapshot?.valuationSemantics?.scoreInputs || {};
  return {
    ticker,
    fiscalPeriod: row.fiscal_period,
    asOfDate: row.as_of_date,
    fairValue: finite(output.fairValue),
    targetPrice3Y: finite(output.targetPrice3Y),
    priceAtDate: finite(output.priceAtDate),
    method: output.method,
    dcfFairValue: finite(scoreInputs.equityDcf?.fairValue),
    discountRate: finite(scoreInputs.equityDcf?.discountRate),
    terminalGrowth: finite(scoreInputs.equityDcf?.terminalGrowth),
    terminalValueShare: finite(scoreInputs.equityDcf?.terminalValueShare),
    normalizedNetIncome: finite(scoreInputs.normalizedNetIncome),
    belowOperatingIncomeBurden: finite(scoreInputs.belowOperatingIncomeBurden)
  };
}

// Reuse the identical independent checks for pre-release diagnostics. Calling
// an individual inspector never emits a release pass or migration manifest.
export {
  inspectModels,
  inspectReleasePathLeaks,
  inspectStoredGuidanceLineage,
  inspectStoredIndependentGuidanceAmounts,
  inspectStoredPlusMinusGuidance,
  inspectTranscriptQaSnapshots,
  modelSignature,
  snapshotSignature
};

export function verifyPitValuationRelease(argv = process.argv.slice(2)) {
const loadedCurrent = reviewedCurrentFromEnvironment();
const [baselineArg, firstArg, secondArg] = argv;
if (!baselineArg || !firstArg || !secondArg) {
  throw new Error("Usage: node server/verifyPitValuationRelease.js <baseline.sqlite> <run1.sqlite> <run2.sqlite>");
}
const baseline = openDatabase(baselineArg);
const first = openDatabase(firstArg);
const second = openDatabase(secondArg);

try {
  reportProgress("start");
  const firstIntegrity = first.prepare("PRAGMA integrity_check").get().integrity_check;
  const secondIntegrity = second.prepare("PRAGMA integrity_check").get().integrity_check;
  assert.equal(firstIntegrity, "ok");
  assert.equal(secondIntegrity, "ok");
  reportProgress("integrity");

  const baselineNonValuation = tableCounts(baseline, { excludeValuation: true });
  const firstNonValuation = tableCounts(first, { excludeValuation: true });
  const secondNonValuation = tableCounts(second, { excludeValuation: true });
  assert.deepEqual(firstNonValuation, baselineNonValuation);
  assert.deepEqual(secondNonValuation, baselineNonValuation);
  reportProgress("table-counts");

  const firstCounts = tableCounts(first);
  const secondCounts = tableCounts(second);
  for (const table of VALUATION_TABLES) assert.equal(firstCounts[table], secondCounts[table]);
  const universeManifest = inspectUniverseManifest();
  assert.equal(universeManifest.securityCount, 503);
  assert.equal(universeManifest.companyCount, 500);
  assert.equal(universeManifest.uniqueTickerCount, 500);
  assert.equal(universeManifest.uniqueCikCount, 500);
  assert.equal(universeManifest.shareClassCount, 503);
  reportProgress("universe-manifest");
  const sp500PriceCoverage = inspectSp500PriceCoverage(first);
  assertNoFindings("S&P 500 price coverage", sp500PriceCoverage.failures);
  assert.equal(sp500PriceCoverage.positiveLatestPrices, universeManifest.companyCount);
  assert.equal(sp500PriceCoverage.nonPositiveStoredPoints, 0);
  reportProgress("sp500-price-coverage");
  const expectedTickers = expectedTickerSet(baseline);
  for (const candidate of loadedCurrent?.candidates || []) expectedTickers.add(candidate.ticker);
  const firstTickerSet = new Set();
  for (const row of first.prepare(`
    SELECT ticker
    FROM valuation_ticker_snapshots
    ORDER BY ticker
  `).iterate()) firstTickerSet.add(String(row.ticker).toUpperCase());
  const secondTickerSet = new Set();
  for (const row of second.prepare(`
    SELECT ticker
    FROM valuation_ticker_snapshots
    ORDER BY ticker
  `).iterate()) secondTickerSet.add(String(row.ticker).toUpperCase());
  assert.equal(firstCounts.valuation_ticker_snapshots, expectedTickers.size);
  assert.deepEqual([...firstTickerSet].sort(), [...expectedTickers].sort());
  assert.deepEqual([...secondTickerSet].sort(), [...expectedTickers].sort());
  reportProgress("ticker-sets");
  const trackedPriceCoverage = inspectTrackedPriceCoverage(first, expectedTickers);
  assertNoFindings("Tracked price coverage", trackedPriceCoverage.failures);
  reportProgress("tracked-price-coverage");
  const releasePathAudit = inspectReleasePathLeaks(first);
  assertNoFindings("Release path audit", releasePathAudit.failures);
  reportProgress("release-paths");
  const currentAudit = auditReviewedCurrentDatabase(first, loadedCurrent);
  assertNoFindings("Independent current-only source/model/storage audit", currentAudit.failures);
  const secondCurrentAudit = auditReviewedCurrentDatabase(second, loadedCurrent);
  assertNoFindings("Second-run independent current-only audit", secondCurrentAudit.failures);
  assert.deepEqual(secondCurrentAudit.results, currentAudit.results);
  const transcriptQaAudit = REQUIRE_TRANSCRIPT_QA
    ? inspectTranscriptQaSnapshots(first, { requireBilingual: REQUIRE_BILINGUAL_QA })
    : { skipped: true, reason: "PIT_RELEASE_REQUIRE_TRANSCRIPT_QA=false" };
  if (REQUIRE_TRANSCRIPT_QA) {
    assertNoFindings("Transcript Q&A audit", transcriptQaAudit.failures);
    assert.equal(transcriptQaAudit.coveragePeriods, transcriptQaAudit.totalPeriods);
    if (REQUIRE_BILINGUAL_QA) {
      assert.equal(transcriptQaAudit.bilingualQaRows, transcriptQaAudit.qaRows);
    }
  }
  reportProgress("transcript-qa");

  const notApplicableTickers = first.prepare(`
    SELECT ticker
    FROM valuation_ticker_snapshots
    WHERE json_extract(payload_json, '$.dataQuality.valuationStatus') = 'not_applicable'
    ORDER BY ticker
  `).all().map((row) => String(row.ticker).toUpperCase());
  const modelCounts = new Map(first.prepare(`
    SELECT ticker, COUNT(*) AS count
    FROM valuation_pit_model_runs
    GROUP BY ticker
  `).all().map((row) => [String(row.ticker).toUpperCase(), Number(row.count)]));
  for (const ticker of expectedTickers) {
    if (notApplicableTickers.includes(ticker)) continue;
    assert.ok((modelCounts.get(ticker) || 0) > 0, `No historical valuation nodes for ${ticker}`);
  }
  assert.ok(firstCounts.valuation_pit_model_runs >= expectedTickers.size - notApplicableTickers.length);
  reportProgress("model-coverage");

  const metadata = sourceMetadata(first);
  const financialCoverage = JSON.parse(metadata.financial_coverage_summary || "{}");
  const guidanceCoverage = JSON.parse(metadata.guidance_coverage_summary || "{}");
  const noQuantifiedGuidance = JSON.parse(metadata.guidance_no_quantified_tickers || "[]");
  const financialCoverageAudit = inspectFinancialCoverage(first, baseline, expectedTickers, metadata);
  assertNoFindings("Per-issuer financial coverage and retained-baseline audit", financialCoverageAudit.failures);
  const secondFinancialCoverageAudit = inspectFinancialCoverage(second, baseline, expectedTickers, sourceMetadata(second));
  assertNoFindings("Second-run per-issuer financial coverage audit", secondFinancialCoverageAudit.failures);
  assert.deepEqual(secondFinancialCoverageAudit.issuerReconciliation, financialCoverageAudit.issuerReconciliation);
  assert.deepEqual(financialCoverage, financialCoverageAudit.statusCounts);
  assert.deepEqual(
    Object.keys(guidanceCoverage).sort(),
    ["covered", "covered_official_filing", "no_quantified_official_guidance"]
  );
  assert.equal(
    Object.values(guidanceCoverage).reduce((sum, value) => sum + Number(value || 0), 0),
    expectedTickers.size - notApplicableTickers.length
  );
  assert.equal(
    Number(guidanceCoverage.no_quantified_official_guidance || 0),
    noQuantifiedGuidance.length
  );
  assert.equal(Number(metadata.guidance_coverage_ticker_count), expectedTickers.size - notApplicableTickers.length);
  assert.match(metadata.source_fingerprint || "", /^[a-f0-9]{64}$/);
  assert.ok(String(metadata.source || "").includes("Sharadar"));
  assert.ok(String(metadata.revision_policy || "").includes("earliest datekey"));
  assert.match(String(metadata.market_price_unit_policy || ""), /already stored in the quoted security currency/i);
  assert.match(String(metadata.pit_fx_policy || ""), /ECB daily reference rates/i);
  assert.doesNotMatch(
    String(metadata.pit_fx_policy || ""),
    /fixed[- ]rate fallback|market[- ]price ratio|cross[- ]listing ratio|requires review/i
  );
  assert.ok(String(metadata.paid_api_latest_financial_available_at || "") >= universeManifest.asOf);
  const modelVersions = first.prepare("SELECT DISTINCT model_version FROM valuation_pit_model_runs ORDER BY model_version").all();
  assert.deepEqual(modelVersions.map((row) => row.model_version), [metadata.model_version]);

  const financialCoverageStats = first.prepare(`
    SELECT COUNT(*) AS rows, COUNT(DISTINCT ticker) AS tickers,
           MIN(available_at) AS first_available_at, MAX(available_at) AS latest_available_at
    FROM valuation_pit_financials
  `).get();
  assert.equal(Number(financialCoverageStats.tickers), expectedTickers.size - notApplicableTickers.length);
  assert.ok(Number(financialCoverageStats.rows) > 60_000);
  assert.ok(String(financialCoverageStats.latest_available_at) >= universeManifest.asOf);
  const guidanceStats = first.prepare(`
    SELECT COUNT(*) AS events, COUNT(DISTINCT ticker) AS tickers,
           COUNT(DISTINCT ticker || '::' || fiscal_period) AS periods,
           MIN(observed_at) AS first_observed_at, MAX(observed_at) AS latest_observed_at
    FROM valuation_pit_guidance
  `).get();
  assert.ok(Number(guidanceStats.events) > 60_000);
  assert.ok(Number(guidanceStats.periods) > 13_000);
  const { rejectedEventKeys, ...guidanceCoverageAudit } = auditGuidanceCoverageRelease({
    rows: first.prepare(`
      SELECT * FROM valuation_pit_guidance
      ORDER BY ticker, fiscal_period, observed_at, source_database, source_id
    `).iterate(),
    financialRows: first.prepare(`
      SELECT ticker, available_at, currency, payload_json FROM valuation_pit_financials
      ORDER BY ticker, available_at DESC
    `).iterate(),
    modelRuns: first.prepare(`
      SELECT ticker, fiscal_period, as_of_date, input_json FROM valuation_pit_model_runs
      ORDER BY ticker, fiscal_period, as_of_date
    `).iterate(),
    requiredTickers: [...expectedTickers].filter((ticker) => !notApplicableTickers.includes(ticker)),
    noQuantifiedTickers: noQuantifiedGuidance,
    declaredCoverage: guidanceCoverage,
    declaredStats: guidanceStats
  });
  assertNoFindings("Independent guidance coverage and research-exclusion audit", guidanceCoverageAudit.failures);
  assert.equal(Number(guidanceStats.events), guidanceCoverageAudit.usableEvents + guidanceCoverageAudit.researchEvents);
  assert.equal(Number(guidanceStats.tickers), guidanceCoverageAudit.usableTickers + guidanceCoverageAudit.researchOnlyTickers.length);
  assert.equal(noQuantifiedGuidance.length, guidanceCoverageAudit.noEvidenceTickers.length + guidanceCoverageAudit.researchOnlyTickers.length);
  // A research exemption is allowed only after independent evidence/coverage
  // reconstruction AND model non-consumption checks have passed above. Raw
  // scalars still must reconcile to their unchanged stored source payload.
  const plusMinusGuidanceAudit = inspectStoredPlusMinusGuidance(first, rejectedEventKeys);
  assertNoFindings("Plus/minus guidance audit", plusMinusGuidanceAudit.failures);
  const independentGuidanceAudit = inspectStoredIndependentGuidanceAmounts(first, rejectedEventKeys);
  assertNoFindings("Independent guidance amount audit", independentGuidanceAudit.failures);
  const guidanceLineageAudit = inspectStoredGuidanceLineage(
    first,
    String(metadata.guidance_extraction_version || "")
  );
  assertNoFindings("Guidance scalar and semantic lineage audit", guidanceLineageAudit.failures);
  reportProgress("source-coverage");

  const firstModelSignature = modelSignature(first);
  reportProgress("first-model-signature");
  const secondModelSignature = modelSignature(second);
  reportProgress("second-model-signature");
  const firstSnapshotSignature = snapshotSignature(first);
  reportProgress("first-snapshot-signature");
  const secondSnapshotSignature = snapshotSignature(second);
  reportProgress("second-snapshot-signature");
  assert.equal(firstModelSignature, secondModelSignature);
  assert.equal(firstSnapshotSignature, secondSnapshotSignature);

  const modelAudit = inspectModels(first, { reviewedCurrentCandidates: currentAudit.candidates });
  reportProgress("model-audit");
  assertNoFindings("Model audit", modelAudit.failures);
  assert.ok(modelAudit.sourceDateChecks >= modelAudit.rows, "Every valuation node must audit at least one PIT source date");
  const unmodeledPeriodAudit = applyReviewedCurrentPeriodDispositions(inspectUnmodeledFinancialPeriods(first), currentAudit.candidates);
  reportProgress("unmodeled-period-audit");
  assertNoFindings("Unmodeled period audit", unmodeledPeriodAudit.unexpected);
  assert.equal(
    unmodeledPeriodAudit.selectedFinancialPeriods,
    unmodeledPeriodAudit.modeledPeriods + unmodeledPeriodAudit.explicitlyUnmodeledPeriods
  );
  const temporalAudit = inspectValuationTemporalContinuity(first, { unmodeledAudit: unmodeledPeriodAudit });
  reportProgress("temporal-audit");
  assertNoFindings("Temporal audit", temporalAudit.blockers);

  const rklx = JSON.parse(first.prepare("SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker = 'RKLX'").get().payload_json);
  assert.equal(rklx.dataQuality?.valuationStatus, "not_applicable");

  const releaseAudit = {
    status: "pass",
    valuationCounts: Object.fromEntries([...VALUATION_TABLES].map((table) => [table, firstCounts[table]])),
    nonValuationTablesPreserved: true,
    modelSignature: firstModelSignature,
    snapshotSignature: firstSnapshotSignature,
    modelAudit: {
      rows: modelAudit.rows,
      reviewedCurrentRows: modelAudit.reviewedCurrentRows,
      dcfRows: modelAudit.dcfRows,
      maxTerminalValueShare: modelAudit.maxTerminalValueShare,
      minDcfSpread: modelAudit.minDcfSpread,
      sourceDateChecks: modelAudit.sourceDateChecks,
      metricSourceDateChecks: modelAudit.metricSourceDateChecks,
      priceInputChecks: modelAudit.priceInputChecks,
      storedMarketPriceChecks: modelAudit.storedMarketPriceChecks,
      snapshotMarketPriceChecks: modelAudit.snapshotMarketPriceChecks,
      pitMarketPriceObservationChecks: modelAudit.pitMarketPriceObservationChecks,
      comparisonPriceBasisExclusions: modelAudit.comparisonPriceBasisExclusions,
      storedMarketPriceDateMisses: modelAudit.storedMarketPriceDateMisses,
      fcfCapChecks: modelAudit.fcfCapChecks,
      profileMethodChecks: modelAudit.profileMethodChecks,
      shareBasisChecks: modelAudit.shareBasisChecks,
      methodArithmeticChecks: modelAudit.methodArithmeticChecks,
      targetArithmeticChecks: modelAudit.targetArithmeticChecks,
      currencyConversionChecks: modelAudit.currencyConversionChecks,
      guidanceScopeChecks: modelAudit.guidanceScopeChecks,
      guidanceUseChecks: modelAudit.guidanceUseChecks,
      guidanceEvidenceLineageChecks: modelAudit.guidanceEvidenceLineageChecks,
      growthInputChecks: modelAudit.growthInputChecks,
      equityBridgeChecks: modelAudit.equityBridgeChecks
    },
    universe: {
      ...universeManifest,
      guru: guruValuationUniverseSummary(),
      expectedTickers: expectedTickers.size,
      modeledTickers: modelCounts.size,
      notApplicableTickers,
      priceCoverage: sp500PriceCoverage,
      trackedPriceCoverage
    },
    sourceCoverage: {
      metadata,
      financial: financialCoverageStats,
      financialCoverageAudit,
      guidance: guidanceStats,
      guidanceCoverageAudit,
      plusMinusGuidanceAudit,
      independentGuidanceAudit,
      guidanceLineageAudit
    },
    transcriptQaAudit,
    reviewedCurrentAudit: { manifestSha256: loadedCurrent?.manifestSha256 || null, results: currentAudit.results,
      historicalApproval: false, currentOnlyTickers: [...currentAudit.candidates.keys()].sort() },
    releasePathAudit,
    temporalAudit,
    unmodeledPeriodAudit: {
      selectedFinancialPeriods: unmodeledPeriodAudit.selectedFinancialPeriods,
      modeledPeriods: unmodeledPeriodAudit.modeledPeriods,
      explicitlyUnmodeledPeriods: unmodeledPeriodAudit.explicitlyUnmodeledPeriods,
      affectedTickers: unmodeledPeriodAudit.affectedTickers,
      reasonCounts: unmodeledPeriodAudit.reasonCounts,
      unexpected: unmodeledPeriodAudit.unexpected
    },
    focusTickers: ["PLTR", "CHTR", "GOOGL", "MSFT", "NVDA", "AON", "APO", "IBKR", "AZN", "LSEG"]
      .map((ticker) => latestTicker(first, ticker))
  };
  const releaseAuditJson = `${JSON.stringify(releaseAudit, null, 2)}\n`;
  if (REPORT_PATH) {
    const resolvedReportPath = path.resolve(REPORT_PATH);
    fs.mkdirSync(path.dirname(resolvedReportPath), { recursive: true });
    fs.writeFileSync(resolvedReportPath, releaseAuditJson, "utf8");
  }
  process.stdout.write(releaseAuditJson);
} finally {
  baseline.close();
  first.close();
  second.close();
}
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  verifyPitValuationRelease();
}
