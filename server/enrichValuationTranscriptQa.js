import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { normalizeEarningsPeriod, readTranscriptQaBundleByTickerPeriod } from "./transcriptQaClient.js";
import { transcriptQaCoverageSummary } from "./valuationTranscriptQa.js";
import { auditedQaTranslation, selectedQaTranslation, qaTranslationSources, assertAttachedQaTranslations } from "./valuationQaTranslationIntegrity.js";

const CURRENT_DB_PATH = process.env.SQLITE_DB_PATH || path.join(process.cwd(), "server/data/guru-analysis.sqlite");
const YOUTUBE_DB_PATH = process.env.YOUTUBE_TRANSCRIPT_DB_PATH || "/Users/yudonglu/Documents/youtube_transcript_db/transcripts.sqlite";
const SHOULD_TRANSLATE_ZH = process.env.TRANSCRIPT_QA_TRANSLATE_ZH === "true";
const FORCE_RETRANSLATE_ZH = process.env.TRANSCRIPT_QA_FORCE_RETRANSLATE_ZH === "true";
const GENERATED_AT = String(process.env.TRANSCRIPT_QA_GENERATED_AT || "").trim() || null;
const TRANSLATION_CACHE_PATH = String(process.env.TRANSCRIPT_QA_TRANSLATION_CACHE_PATH || "").trim() || null;
const TRANSLATION_AUDIT_PATH = String(process.env.TRANSCRIPT_QA_TRANSLATION_AUDIT_PATH || "").trim() || null;
const ENRICHMENT_VERSION = "valuation-transcript-qa-v3-audited-cache-only";
const FALLBACK_ANSWER = "Management response context is not available in the structured transcript extract.";

function parseJson(value, fallback = null) {
  if (!value) return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function periodKeyFromHistoryRow(row) {
  const year = Number(row?.fiscalYear);
  const quarterMatch = String(row?.fiscalQuarter || row?.label || row?.periodId || "")
    .toUpperCase()
    .match(/Q([1-4])/);
  if (Number.isFinite(year) && quarterMatch) return `Q${quarterMatch[1]}${year}`;
  const text = String(row?.label || row?.periodId || "").toUpperCase();
  const qfy = text.match(/Q([1-4])\s*(?:FY)?\s*(20\d{2})/);
  if (qfy) return `Q${qfy[1]}${qfy[2]}`;
  const fyq = text.match(/(?:FY)?\s*(20\d{2}).*Q([1-4])/);
  if (fyq) return `Q${fyq[2]}${fyq[1]}`;
  return normalizeEarningsPeriod(text);
}

function hasChinese(value) {
  return /[\u3400-\u9fff]/.test(String(value || ""));
}

function enoughChineseForSource(translated, source) {
  const output = String(translated || "").trim();
  const input = String(source || "").trim();
  if (!output || !input) return false;
  if (!hasChinese(output)) return false;
  if (input.length < 80) return true;
  const asciiWords = output.match(/[A-Za-z]{4,}/g) || [];
  const chineseChars = output.match(/[\u3400-\u9fff]/g) || [];
  return chineseChars.length >= Math.max(8, Math.floor(asciiWords.length * 0.35));
}

function textValue(value, fallback = "") {
  return String(value || fallback || "").trim();
}

function translationSource(value, fallback = "") {
  const source = textValue(value, fallback);
  return source || "";
}

function needsStoredChinese(existingValue, sourceValue) {
  const source = translationSource(sourceValue);
  if (!SHOULD_TRANSLATE_ZH || !source) return false;
  if (FORCE_RETRANSLATE_ZH) return true;
  return !enoughChineseForSource(existingValue, source);
}

function titleToChinese(value) {
  const title = textValue(value);
  if (!title) return "";
  const earningsCallMatch = title.match(/^(.+?)\s+\(([A-Z.]+)\)\s+Earnings Call:\s+Q([1-4])\s+(\d{4})$/i);
  if (earningsCallMatch) {
    const [, company, ticker, quarter, year] = earningsCallMatch;
    return `${company}（${ticker.toUpperCase()}）${year} 年 Q${quarter} 财报电话会`;
  }
  return title
    .replace(/\bEarnings Call\b/gi, "财报电话会")
    .replace(/\bQ([1-4])\s+(\d{4})\b/gi, "$2 年 Q$1");
}

function askedByToChinese(value) {
  const askedBy = textValue(value);
  if (!askedBy) return "";
  return askedBy
    .replace(/\s+—\s+Chief Executive Officer\b/gi, " — 首席执行官")
    .replace(/\s+—\s+Chief Financial Officer\b/gi, " — 首席财务官")
    .replace(/\s+—\s+Chief Operating Officer\b/gi, " — 首席运营官")
    .replace(/\s+—\s+Chairman and CEO\b/gi, " — 董事长兼 CEO")
    .replace(/\s+—\s+President and CEO\b/gi, " — 总裁兼 CEO")
    .replace(/\s+—\s+Analyst\b/gi, " — 分析师");
}

function missingCoverage(ticker, period, historyRow, existingCoverage = {}) {
  return {
    ticker,
    fiscalPeriod: period,
    status: textValue(existingCoverage.status, "transcript_not_in_source"),
    reason: textValue(
      existingCoverage.reason,
      "No earnings-call transcript is stored for this ticker/period in the local transcript database."
    ),
    qaCount: Number(existingCoverage.qaCount || 0),
    segmentCount: Number(existingCoverage.segmentCount || 0),
    questionLikeCount: Number(existingCoverage.questionLikeCount || 0),
    placeholderCount: Number(existingCoverage.placeholderCount || 0),
    callDate: existingCoverage.callDate || historyRow.asOfDate || null,
    title: existingCoverage.title || null,
    url: existingCoverage.url || null,
    sourceId: existingCoverage.sourceId || null
  };
}

function resolvedQaForHistoryRow(ticker, historyRow, qaByPeriod, coverageByPeriod) {
  const period = periodKeyFromHistoryRow(historyRow);
  const key = `${ticker}::${period}`;
  const qa = qaByPeriod.get(key) || [];
  const existingQa = historyRow.dataSnapshot?.youtubeEarnings?.qa || [];
  const existingCoverage = historyRow.dataSnapshot?.youtubeEarnings?.qaCoverage || {};
  const hasCurrentSourceCoverage = coverageByPeriod.has(key);
  const coverage = coverageByPeriod.get(key) || missingCoverage(ticker, period, historyRow, existingCoverage);
  const qaRows = hasCurrentSourceCoverage
    ? (qa.length && existingQa.length ? mergeStoredQaTranslations(qa, existingQa) : qa)
    : existingQa;
  const nextCoverage = {
    ...coverage,
    ticker,
    fiscalPeriod: period,
    qaCount: qaRows.length || Number(coverage.qaCount || 0),
    researchOnly: true,
    includedInValuationInputs: false,
    researchAvailableAt: coverage.callDate || null,
    availableAfterModelNode: Boolean(
      coverage.callDate && historyRow.asOfDate &&
      String(coverage.callDate).slice(0, 10) > String(historyRow.asOfDate).slice(0, 10)
    )
  };
  if (qaRows.length) {
    nextCoverage.status = "has_qa";
    nextCoverage.reason = "Structured analyst Q&A is attached for this valuation period.";
    nextCoverage.qaCount = qaRows.length;
  }
  return {
    period,
    key,
    qaRows,
    coverage: nextCoverage,
    hasFreshQa: qa.length > 0,
    preservedExistingQa: !hasCurrentSourceCoverage && existingQa.length > 0
  };
}

function qaIdentity(qa) {
  const sourceId = textValue(qa.sourceId);
  const segmentIndex = textValue(qa.segmentIndex);
  if (sourceId && segmentIndex) return `${sourceId}::${segmentIndex}`;
  return `${textValue(qa.fiscalPeriod)}::${textValue(qa.question).toLowerCase()}`;
}

function mergeStoredQaTranslations(freshRows, existingRows) {
  const existingByKey = new Map();
  for (const row of existingRows) {
    existingByKey.set(qaIdentity(row), row);
  }
  return freshRows.map((row) => {
    const existing = existingByKey.get(qaIdentity(row));
    if (!existing) return row;
    return {
      ...row,
      questionZh: existing.questionZh || row.questionZh,
      answerZh: existing.answerZh || row.answerZh,
      askedByZh: existing.askedByZh || row.askedByZh,
      titleZh: existing.titleZh || row.titleZh
    };
  });
}

function collectTranslationSources(qaRows, sources) {
  if (!SHOULD_TRANSLATE_ZH) return;
  for (const source of qaTranslationSources(qaRows, FALLBACK_ANSWER)) sources.add(source);
}

async function translateSourcesToChinese(sources) {
  const cachedTranslations = readTranslationCache();
  const values = [...sources].filter((source) =>
    source && !enoughChineseForSource(cachedTranslations.get(source), source)
  );
  if (values.length) {
    const sample = values.slice(0, 3).map((value) => value.slice(0, 120));
    throw new Error(
      `Audited local transcript translation cache is incomplete: ${values.length} source fields are missing. ` +
      `Run scripts/translate-valuation-qa-mlx.py first. Samples: ${JSON.stringify(sample)}`
    );
  }
  if (SHOULD_TRANSLATE_ZH && !TRANSLATION_CACHE_PATH) {
    throw new Error(
      "TRANSCRIPT_QA_TRANSLATION_CACHE_PATH is required when TRANSCRIPT_QA_TRANSLATE_ZH=true."
    );
  }
  if (SHOULD_TRANSLATE_ZH && !fs.existsSync(TRANSLATION_CACHE_PATH)) {
    throw new Error(`Audited transcript translation cache not found at ${TRANSLATION_CACHE_PATH}`);
  }
  return new Map(cachedTranslations);
}

function readTranslationCache() {
  if (!TRANSLATION_CACHE_PATH || !fs.existsSync(TRANSLATION_CACHE_PATH)) return new Map();
  const payload = parseJson(fs.readFileSync(TRANSLATION_CACHE_PATH, "utf8"), {});
  return new Map(
    Object.entries(payload || {}).filter(([source, translated]) =>
      enoughChineseForSource(translated, source)
    )
  );
}

function fileSha256(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function auditedTranslationLineage(sources, translations) {
  if (!SHOULD_TRANSLATE_ZH) return null;
  if (!TRANSLATION_AUDIT_PATH) {
    throw new Error(
      "TRANSCRIPT_QA_TRANSLATION_AUDIT_PATH is required when TRANSCRIPT_QA_TRANSLATE_ZH=true."
    );
  }
  if (!fs.existsSync(TRANSLATION_AUDIT_PATH)) {
    throw new Error(`Audited transcript translation report not found at ${TRANSLATION_AUDIT_PATH}`);
  }
  const payload = parseJson(fs.readFileSync(TRANSLATION_AUDIT_PATH, "utf8"), {});
  const sourceAudits = payload.sources && typeof payload.sources === "object" ? payload.sources : {};
  const statusCounts = {};
  const failures = [];
  for (const source of sources) {
    const audit = sourceAudits[source];
    const status = String(audit?.status || "missing");
    statusCounts[status] = (statusCounts[status] || 0) + 1;
    const expectedSourceHash = crypto.createHash("sha256").update(source).digest("hex");
    if (!audit || !["pass", "approved"].includes(status)) {
      failures.push({ source: source.slice(0, 160), status });
      continue;
    }
    if (audit.source_sha256 !== expectedSourceHash) {
      failures.push({ source: source.slice(0, 160), status, code: "source_hash_mismatch" });
    }
    if (!enoughChineseForSource(translations.get(source), source)) {
      failures.push({ source: source.slice(0, 160), status, code: "cache_translation_missing" });
    }
    try {
      auditedQaTranslation(source, translations, sourceAudits);
    } catch (error) {
      failures.push({ source: source.slice(0, 160), status, code: error.message });
    }
  }
  if (failures.length) {
    throw new Error(
      `Transcript translation audit failed for ${failures.length} used source fields. ` +
      `Samples: ${JSON.stringify(failures.slice(0, 5))}`
    );
  }
  return {
    status: "pass",
    model: payload.model || null,
    numericProtection: payload.numericProtection || null,
    systemPromptSha256: payload.systemPromptSha256 || null,
    retrySystemPromptSha256: payload.retrySystemPromptSha256 || null,
    usedSourceCount: sources.size,
    statusCounts: Object.fromEntries(Object.entries(statusCounts).sort(([left], [right]) => left.localeCompare(right))),
    cacheSha256: fileSha256(TRANSLATION_CACHE_PATH),
    auditSha256: fileSha256(TRANSLATION_AUDIT_PATH)
  };
}

function translatedValue(sourceValue, existingValue, translatedBySource) {
  // Existing Chinese may come from an older, differently audited generation.
  // The used-source audit above binds the exact cache text attached here.
  void existingValue;
  const source = translationSource(sourceValue);
  if (!source) return "";
  return selectedQaTranslation(source, translatedBySource);
}

function translateQaRowsToChinese(qaRows, translatedBySource) {
  if (!SHOULD_TRANSLATE_ZH) return qaRows;
  const translatedRows = qaRows.map((qa) => {
    const answer = translationSource(qa.answer, FALLBACK_ANSWER);
    const next = { ...qa };
    next.answer = answer;
    next.questionZh = translatedValue(qa.question, next.questionZh, translatedBySource);
    next.answerZh = translatedValue(answer, next.answerZh, translatedBySource);
    if (FORCE_RETRANSLATE_ZH || !next.titleZh) next.titleZh = titleToChinese(next.title);
    if (FORCE_RETRANSLATE_ZH || !next.askedByZh) next.askedByZh = askedByToChinese(next.askedBy || next.speaker);
    return next;
  });
  assertAttachedQaTranslations(translatedRows, translatedBySource, FALLBACK_ANSWER);
  return translatedRows;
}

if (!fs.existsSync(CURRENT_DB_PATH)) {
  throw new Error(`Valuation database not found at ${CURRENT_DB_PATH}`);
}
if (!fs.existsSync(YOUTUBE_DB_PATH)) {
  throw new Error(`YouTube transcript database not found at ${YOUTUBE_DB_PATH}`);
}

const currentDb = new DatabaseSync(CURRENT_DB_PATH);
const youtubeDb = new DatabaseSync(YOUTUBE_DB_PATH, { readOnly: true });

try {
  const tickerList = currentDb.prepare("SELECT ticker FROM valuation_ticker_snapshots ORDER BY ticker")
    .all()
    .map((row) => String(row.ticker || "").toUpperCase())
    .filter(Boolean);
  const tickerSet = new Set(tickerList);
  const snapshotByTicker = currentDb.prepare(`
    SELECT payload_json
    FROM valuation_ticker_snapshots
    WHERE ticker = ?
  `);
  const { qaByPeriod, coverageByPeriod } = readTranscriptQaBundleByTickerPeriod(youtubeDb, tickerSet);
  const translationSources = new Set();

  for (const ticker of tickerList) {
    const snapshot = parseJson(snapshotByTicker.get(ticker)?.payload_json, {});
    const history = Array.isArray(snapshot.history) ? snapshot.history : [];
    for (const historyRow of history) {
      const { qaRows } = resolvedQaForHistoryRow(ticker, historyRow, qaByPeriod, coverageByPeriod);
      if (qaRows.length) collectTranslationSources(qaRows, translationSources);
    }
  }
  const translatedBySource = await translateSourcesToChinese(translationSources);
  const translationAuditLineage = auditedTranslationLineage(translationSources, translatedBySource);

  const statement = currentDb.prepare(`
    INSERT INTO valuation_ticker_snapshots (ticker, generated_at, payload_json)
    VALUES (?, ?, ?)
    ON CONFLICT(ticker) DO UPDATE SET
      generated_at = excluded.generated_at,
      payload_json = excluded.payload_json
  `);

  let updatedTickers = 0;
  let updatedRows = 0;
  let attachedQa = 0;
  let coverageRows = 0;
  let rowsWithoutQa = 0;
  let lockedPreviewRows = 0;
  let missingTranscriptRows = 0;
  let parseMissRows = 0;
  let preservedQaRows = 0;
  currentDb.exec("BEGIN");
  try {
    for (const ticker of tickerList) {
      const snapshot = parseJson(snapshotByTicker.get(ticker)?.payload_json, {});
      const history = Array.isArray(snapshot.history) ? snapshot.history : [];
      let tickerChanged = false;
      const nextHistory = [];
      for (const historyRow of history) {
        const { qaRows, coverage, preservedExistingQa } = resolvedQaForHistoryRow(
          ticker,
          historyRow,
          qaByPeriod,
          coverageByPeriod
        );
        tickerChanged = true;
        updatedRows += 1;
        coverageRows += 1;
        if (preservedExistingQa) preservedQaRows += 1;
        if (!qaRows.length) rowsWithoutQa += 1;
        if (coverage.status === "locked_preview") lockedPreviewRows += 1;
        if (coverage.status === "transcript_not_in_source") missingTranscriptRows += 1;
        if (coverage.status === "qa_parse_miss") parseMissRows += 1;
        const translatedQa = translateQaRowsToChinese(qaRows, translatedBySource);
        attachedQa += translatedQa.length;
        nextHistory.push({
          ...historyRow,
          dataSnapshot: {
            ...(historyRow.dataSnapshot || {}),
            youtubeEarnings: {
              ...(historyRow.dataSnapshot?.youtubeEarnings || {}),
              qa: translatedQa,
              qaCoverage: coverage
            }
          }
        });
      }
      if (!tickerChanged) continue;
      updatedTickers += 1;
      const generatedAt = GENERATED_AT || new Date().toISOString();
      const coverageSummary = transcriptQaCoverageSummary(nextHistory);
      const nextSnapshot = {
        ...snapshot,
        generatedAt,
        history: nextHistory,
        dataQuality: {
          ...(snapshot.dataQuality || {}),
          transcriptQaPeriods: coverageSummary.qaPeriods,
          transcriptQaCoverage: coverageSummary
        }
      };
      statement.run(ticker, generatedAt, JSON.stringify(nextSnapshot));
    }
    const dashboard = parseJson(currentDb.prepare("SELECT payload_json FROM valuation_snapshots WHERE id = ?").get("latest")?.payload_json, {});
    if (dashboard && Object.keys(dashboard).length) {
      const generatedAt = GENERATED_AT || new Date().toISOString();
      currentDb.prepare(`
        INSERT INTO valuation_snapshots (id, generated_at, payload_json)
        VALUES (?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          generated_at = excluded.generated_at,
          payload_json = excluded.payload_json
      `).run("latest", generatedAt, JSON.stringify({
        ...dashboard,
        generatedAt,
        summary: {
          ...(dashboard.summary || {}),
          transcriptQaTickerCount: updatedTickers,
          transcriptQaEventCount: attachedQa,
          transcriptQaCoverageRows: coverageRows,
          transcriptQaRowsWithoutQa: rowsWithoutQa
        }
      }));
    }
    const enrichmentSummary = {
      version: ENRICHMENT_VERSION,
      generatedAt: GENERATED_AT || null,
      updatedTickers,
      updatedRows,
      attachedQa,
      coverageRows,
      rowsWithoutQa,
      lockedPreviewRows,
      missingTranscriptRows,
      parseMissRows,
      preservedQaRows,
      translationPolicy: SHOULD_TRANSLATE_ZH ? "stored_bilingual" : "english_only"
    };
    const metadataStatement = currentDb.prepare(`
      INSERT INTO valuation_pit_source_metadata (key, value, imported_at)
      VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        imported_at = excluded.imported_at
    `);
    const metadataAt = GENERATED_AT || new Date().toISOString();
    metadataStatement.run("transcript_qa_enrichment_version", ENRICHMENT_VERSION, metadataAt);
    metadataStatement.run("transcript_qa_enrichment_summary", JSON.stringify(enrichmentSummary), metadataAt);
    if (translationAuditLineage) {
      metadataStatement.run(
        "transcript_qa_translation_audit",
        JSON.stringify(translationAuditLineage),
        metadataAt
      );
    } else {
      currentDb.prepare("DELETE FROM valuation_pit_source_metadata WHERE key = ?")
        .run("transcript_qa_translation_audit");
    }
    currentDb.exec("COMMIT");
  } catch (error) {
    currentDb.exec("ROLLBACK");
    throw error;
  }
  currentDb.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  console.log(JSON.stringify({
    currentDbPath: CURRENT_DB_PATH,
    youtubeDbPath: YOUTUBE_DB_PATH,
    updatedTickers,
    updatedRows,
    attachedQa,
    coverageRows,
    rowsWithoutQa,
    lockedPreviewRows,
    missingTranscriptRows,
    parseMissRows,
    preservedQaRows
  }, null, 2));
} finally {
  youtubeDb.close();
  currentDb.close();
}
