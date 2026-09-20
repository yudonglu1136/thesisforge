import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";
import {
  attachMstrCryptoMetrics,
  buildValuationRows,
  compactTicker,
  digestGuidanceMetrics,
  guidancePlusMinusCenterM,
  hasExplicitValuationProfile,
  profileSettings,
  readPriceHistoryFromDb,
  updateTickerSnapshot
} from "./importSecQuarterlyValuations.js";
import {
  guidanceBoundaryAudit,
  guidanceMetricsBeforeNextFinancialRelease,
  nextDistinctFinancialReleaseDate
} from "./pitGuidanceBoundary.js";
import { valuationMarketPriceSymbol } from "./tickerAliases.js";
import { nullableFiniteNumber } from "./pitScalar.js";
import { preserveTranscriptQaByFiscalPeriod } from "./valuationTranscriptQa.js";
import { independentGuidanceCurrencyMismatch } from "./guidanceEvidenceAudit.js";
import { financialCoverageLedger } from "./financialCoverageReleaseAudit.js";
import { mergeValuationComparisonHistory } from "./valuationComparisonPrice.js";
import { reviewedCurrentFromEnvironment, bindReviewedCurrentFinancialPeriods, sourceCurrentBindingMetadata } from "./reviewedCurrentFullRebuild.js";

const TARGET_DB_PATH = process.env.SQLITE_DB_PATH || path.join(process.cwd(), "server/data/guru-analysis.sqlite");
const SOURCE_DB_PATH = process.env.PIT_VALUATION_SOURCE_PATH || path.join(process.cwd(), "server/data/valuation-pit-source.sqlite");
const MODEL_VERSION = process.env.PIT_VALUATION_MODEL_VERSION || "pit-valuation-v56-reviewed-economic-inputs-2026-09-06";
const GENERATED_AT_OVERRIDE = process.env.PIT_VALUATION_GENERATED_AT || "";
const SEC_FACTS_CACHE_DIR = process.env.SEC_FACTS_CACHE_DIR || path.join(process.cwd(), "server/data/sec-companyfacts");
const PIT_SOURCE_LABEL = "valuation-pit-source";
const PIT_GUIDANCE_LABEL = "valuation-pit-guidance";
const APPLY = process.argv.includes("--apply");
const ALLOW_INCOMPLETE = process.argv.includes("--allow-incomplete");

// Reconstructed PIT sources can contain metadata from the prior published
// runtime. Model/price policy and Q&A approval belong to the NEW build, not to
// its inherited source. Preserve source lineage, but never inherit release proof.
export function publicationMetadata(sourceMetadata, modelVersion = MODEL_VERSION) {
  const metadata = new Map([...sourceMetadata].filter(([key]) =>
    key !== "model_version" && key !== "market_price_unit_policy"
      && !key.startsWith("transcript_qa_")
  ));
  metadata.set("model_version", modelVersion);
  metadata.set("market_price_unit_policy",
    "price_points values are already stored in the quoted security currency; ticker suffixes never trigger an additional unit conversion");
  return metadata;
}

function parseJson(value, fallback = null) {
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function finiteNumber(value) {
  return nullableFiniteNumber(value);
}

function releaseGeneratedAt() {
  if (!GENERATED_AT_OVERRIDE) return new Date().toISOString();
  const parsed = new Date(GENERATED_AT_OVERRIDE);
  if (!Number.isFinite(parsed.getTime())) {
    throw new Error(`Invalid PIT_VALUATION_GENERATED_AT: ${GENERATED_AT_OVERRIDE}`);
  }
  return parsed.toISOString();
}

function margin(numerator, denominator) {
  return numerator != null && denominator ? numerator / denominator * 100 : null;
}

function maxDate(...dates) {
  return dates.filter(Boolean).sort().at(-1) || null;
}

const FISCAL_CALENDAR_TRANSITIONS = {
  GPN: {
    start: "2016-06-01",
    end: "2017-12-31",
    note: "Global Payments changed its fiscal year end from May 31 to December 31 and reported a seven-month transition period ending December 31, 2016.",
    source: "https://www.sec.gov/Archives/edgar/data/1123360/000112336018000007/gpn20171231-10k.htm"
  },
  MOS: {
    start: "2013-06-01",
    end: "2014-12-31",
    note: "Mosaic changed its fiscal year end from May 31 to December 31 and reported a seven-month transition period ending December 31, 2013.",
    source: "https://www.sec.gov/Archives/edgar/data/1285785/000161803415000005/mos-20141231x10k.htm"
  }
};

function markFiscalCalendarTransition(ticker, row) {
  const periodEndDate = String(row?.periodEndDate || row?.sourceRecord?.reportperiod || "").slice(0, 10);
  const transition = FISCAL_CALENDAR_TRANSITIONS[ticker];
  if (!transition || periodEndDate < transition.start || periodEndDate > transition.end) return row;
  return {
    ...row,
    sourceRecord: {
      ...(row.sourceRecord || {}),
      fiscalCalendarTransition: true,
      fiscalCalendarTransitionNote: `${transition.note} Provider fiscal labels are preserved while valuation nodes remain ordered by first-visible filing date.`,
      fiscalCalendarTransitionSource: transition.source
    }
  };
}

function sanitizeReleasePayload(value, key = "") {
  if (Array.isArray(value)) return value.map((child) => sanitizeReleasePayload(child, key));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([childKey, child]) => [childKey, sanitizeReleasePayload(child, childKey)])
    );
  }
  if (
    typeof value === "string" &&
    /(path|file|database|root|origin)$/i.test(key) &&
    path.isAbsolute(value)
  ) {
    return `source-artifact://${path.basename(value)}`;
  }
  return value;
}

function normalizePeriod(period) {
  const value = String(period || "").trim().toUpperCase().replace(/\s+/g, "");
  const leadingQuarter = value.match(/^Q([1-4])(?:FY)?(20\d{2})$/);
  if (leadingQuarter) return `Q${leadingQuarter[1]}${leadingQuarter[2]}`;
  const trailingQuarter = value.match(/^(20\d{2})-?Q([1-4])$/);
  if (trailingQuarter) return `Q${trailingQuarter[2]}${trailingQuarter[1]}`;
  return value;
}

function cleanSnapshot(snapshot) {
  const inferredCik = snapshot.cik ||
    snapshot.dataQuality?.secCompanyFacts?.cik ||
    [...(snapshot.history || [])].reverse().find((row) => row?.dataSnapshot?.secCompanyFacts?.cik)
      ?.dataSnapshot?.secCompanyFacts?.cik ||
    null;
  return {
    ticker: snapshot.ticker,
    key: snapshot.key,
    name: snapshot.name,
    sector: snapshot.sector,
    industry: snapshot.industry,
    currency: snapshot.currency,
    description: snapshot.description,
    cik: inferredCik,
    cusip: snapshot.cusip,
    aliases: Array.isArray(snapshot.aliases) ? snapshot.aliases : [],
    valuationProfile: hasExplicitValuationProfile(snapshot.ticker)
      ? profileSettings(snapshot.ticker).profile
      : snapshot.valuationProfile,
    sp500MembershipAsOf: snapshot.sp500MembershipAsOf,
    priceHistory: Array.isArray(snapshot.priceHistory) ? snapshot.priceHistory : [],
    priceSource: snapshot.priceSource,
    latest: {
      latestPrice: snapshot.latest?.latestPrice ?? null,
      latestPriceDate: snapshot.latest?.latestPriceDate ?? null,
      latestPriceSource: snapshot.latest?.latestPriceSource ?? null
    },
    dataQuality: {
      pricePoints: snapshot.priceHistory?.length || snapshot.dataQuality?.pricePoints || 0,
      hasLivePriceSeries: Boolean(snapshot.priceHistory?.length)
    }
  };
}

function compactPriceHistory(points, maxPoints = 1800) {
  const sorted = [...(Array.isArray(points) ? points : [])]
    .filter((point) => point?.date && finiteNumber(point.close) > 0)
    .sort((left, right) => String(left.date).localeCompare(String(right.date)));
  if (sorted.length <= maxPoints) return sorted;
  const recentCount = Math.min(260, Math.floor(maxPoints / 3));
  const recent = sorted.slice(-recentCount);
  const older = sorted.slice(0, -recentCount);
  const olderBudget = maxPoints - recent.length;
  const sampled = [];
  for (let index = 0; index < olderBudget; index += 1) {
    const sourceIndex = Math.min(
      older.length - 1,
      Math.floor(index * (older.length - 1) / Math.max(1, olderBudget - 1))
    );
    const point = older[sourceIndex];
    if (!sampled.length || sampled.at(-1).date !== point.date) sampled.push(point);
  }
  return [...sampled, ...recent];
}

export function compactSnapshotPriceHistory(snapshot) {
  const validHistory = (Array.isArray(snapshot.priceHistory) ? snapshot.priceHistory : [])
    .filter((point) => point?.date && finiteNumber(point.close) > 0);
  const fullCount = validHistory.length;
  // Dated comparison-price proof may retain a private source path in the
  // staging seed. Publish its artifact identity and hashes, never the local
  // workstation path; the private original remains unchanged for audit.
  const priceHistory = compactPriceHistory(validHistory).map(point => sanitizeReleasePayload(point));
  return {
    ...snapshot,
    priceHistory,
    dataQuality: {
      ...(snapshot.dataQuality || {}),
      pricePoints: fullCount,
      storedPricePoints: priceHistory.length,
      priceStoragePolicy: "stratified history plus latest 260 daily observations"
    }
  };
}

function ensurePitTables(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS valuation_pit_source_metadata (
      key TEXT PRIMARY KEY, value TEXT NOT NULL, imported_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS valuation_pit_financials (
      ticker TEXT NOT NULL, source_ticker TEXT NOT NULL, fiscal_period TEXT NOT NULL,
      fiscal_year INTEGER NOT NULL, fiscal_quarter TEXT NOT NULL, dimension TEXT NOT NULL,
      available_at TEXT NOT NULL, report_period TEXT, currency TEXT NOT NULL,
      payload_json TEXT NOT NULL, imported_at TEXT NOT NULL,
      PRIMARY KEY (ticker, fiscal_period, dimension)
    );
    CREATE INDEX IF NOT EXISTS idx_valuation_pit_financials_ticker_available
      ON valuation_pit_financials (ticker, available_at);
    CREATE TABLE IF NOT EXISTS valuation_pit_guidance (
      source_database TEXT NOT NULL, source_id TEXT NOT NULL, ticker TEXT NOT NULL,
      fiscal_period TEXT, observed_at TEXT, metric_name TEXT, amount REAL, unit TEXT,
      currency TEXT, growth_yoy REAL, growth_qoq REAL, margin_pct REAL, value_text TEXT,
      quality_status TEXT, confidence REAL, speaker TEXT, source_url TEXT,
      evidence_excerpt TEXT, payload_json TEXT NOT NULL, imported_at TEXT NOT NULL,
      PRIMARY KEY (source_database, source_id)
    );
    CREATE INDEX IF NOT EXISTS idx_valuation_pit_guidance_ticker_period
      ON valuation_pit_guidance (ticker, fiscal_period, observed_at);
    CREATE TABLE IF NOT EXISTS valuation_pit_model_runs (
      ticker TEXT NOT NULL, fiscal_period TEXT NOT NULL, model_version TEXT NOT NULL,
      as_of_date TEXT NOT NULL, financial_available_at TEXT NOT NULL,
      guidance_max_observed_at TEXT, input_json TEXT NOT NULL, output_json TEXT NOT NULL,
      generated_at TEXT NOT NULL,
      PRIMARY KEY (ticker, fiscal_period, model_version)
    );
    CREATE INDEX IF NOT EXISTS idx_valuation_pit_model_runs_ticker_asof
      ON valuation_pit_model_runs (ticker, as_of_date);
    CREATE TABLE IF NOT EXISTS valuation_pit_price_observations (
      ticker TEXT NOT NULL, fiscal_period TEXT NOT NULL, model_version TEXT NOT NULL,
      price_symbol TEXT NOT NULL, price_date TEXT NOT NULL, close REAL NOT NULL,
      quote_currency TEXT, source TEXT, payload_json TEXT NOT NULL, imported_at TEXT NOT NULL,
      PRIMARY KEY (ticker, fiscal_period, model_version)
    );
    CREATE INDEX IF NOT EXISTS idx_valuation_pit_price_observations_symbol_date
      ON valuation_pit_price_observations (price_symbol, price_date);
  `);
}

function buildQuarterlyRows(sourceRows, guidanceByPeriod, guidanceMetricsByPeriod, ticker, sourceTicker) {
  const parsed = sourceRows.map((row) => markFiscalCalendarTransition(ticker, parseJson(row.payload_json, {})));
  const hasCoreFinancials = (row) =>
    row.revenue_m != null || row.net_income_m != null || row.cfo_m != null;
  const rowsByPeriod = new Map();
  for (const row of parsed) {
    const key = `${row.fiscalYear}::${row.fiscalQuarter}`;
    rowsByPeriod.set(key, [...(rowsByPeriod.get(key) || []), row]);
  }
  const selected = [...rowsByPeriod.values()]
    .map((candidates) => {
      const arq = candidates.find((row) => row.sourceDimension === "ARQ" && hasCoreFinancials(row));
      const art = candidates.find((row) => row.sourceDimension === "ART" && hasCoreFinancials(row));
      const base = arq || art;
      if (!base) return null;
      return {
        ...base,
        pitTrailingTwelveMonths: art || null,
        trailingTwelveMonthsSourceRecord: art?.sourceRecord || null,
        trailingTwelveMonthsAvailableAt: art?.asOfDate || null
      };
    })
    .filter(Boolean);
  const releasedRows = selected.map((row) => ({
    ...row,
    requiresReportedTrailingBasis: true,
    financialAvailableAt: maxDate(row.asOfDate, row.trailingTwelveMonthsAvailableAt)
  }));
  const byPeriod = new Map(releasedRows.map((row) => [`${row.fiscalYear}::${row.fiscalQuarter}`, row]));
  return releasedRows
    .map((row) => {
      const prior = byPeriod.get(`${row.fiscalYear - 1}::${row.fiscalQuarter}`);
      const guidanceKey = `${ticker}::Q${String(row.fiscalQuarter).replace("Q", "")}${row.fiscalYear}`;
      const sourceGuidanceKey = `${sourceTicker}::Q${String(row.fiscalQuarter).replace("Q", "")}${row.fiscalYear}`;
      const candidateMetrics = guidanceMetricsByPeriod?.get(guidanceKey) ||
        guidanceMetricsByPeriod?.get(sourceGuidanceKey) ||
        [];
      const nextFinancialAvailableAt = nextDistinctFinancialReleaseDate(releasedRows, row.financialAvailableAt);
      const boundedMetrics = guidanceMetricsBeforeNextFinancialRelease(candidateMetrics, nextFinancialAvailableAt);
      let guidance = boundedMetrics.length
        ? digestGuidanceMetrics(boundedMetrics, { sourceDatabase: PIT_GUIDANCE_LABEL })
        : null;
      if (!guidanceMetricsByPeriod && !candidateMetrics.length) {
        const legacyGuidance = guidanceByPeriod.get(guidanceKey) || guidanceByPeriod.get(sourceGuidanceKey) || null;
        guidance = nextFinancialAvailableAt && legacyGuidance?.maxObservedAt >= nextFinancialAvailableAt
          ? null
          : legacyGuidance;
      }
      const asOfDate = maxDate(row.financialAvailableAt, guidance?.maxObservedAt);
      return {
        ...row,
        asOfDate,
        pitGuidance: guidance,
        pitGuidanceBoundary: guidanceBoundaryAudit(candidateMetrics, boundedMetrics, nextFinancialAvailableAt),
        revenue_growth_pct: row.revenue_m != null && prior?.revenue_m
          ? (row.revenue_m / prior.revenue_m - 1) * 100
          : null,
        gross_margin_pct: margin(row.gross_profit_m, row.revenue_m),
        operating_margin_pct: margin(row.operating_income_m, row.revenue_m),
        fcf_after_capex_m: row.cfo_m != null && row.capex_m != null
          ? row.cfo_m - row.capex_m
          : row.fcf_after_capex_m
      };
    })
    .sort((left, right) => String(left.asOfDate).localeCompare(String(right.asOfDate)));
}

function attachPointInTimeSupplements(ticker, rows, existingSnapshot) {
  if (ticker !== "MSTR") return rows;
  const historicalCik = [...(existingSnapshot?.history || [])].reverse()
    .find((row) => row?.dataSnapshot?.secCompanyFacts?.cik)
    ?.dataSnapshot?.secCompanyFacts?.cik;
  const cik = String(
    existingSnapshot?.cik || existingSnapshot?.dataQuality?.secCompanyFacts?.cik || historicalCik || ""
  )
    .replace(/\D/g, "")
    .padStart(10, "0");
  const cachePath = path.join(SEC_FACTS_CACHE_DIR, `${cik}.json`);
  if (!cik || !fs.existsSync(cachePath)) return rows;
  const payload = parseJson(fs.readFileSync(cachePath, "utf8"), {});
  return attachMstrCryptoMetrics(payload?.facts || {}, rows, { pointInTime: true }).map((row) => {
    const supplementalDates = Object.values(row.sources || {}).map((source) => source?.filed).filter(Boolean);
    return {
      ...row,
      asOfDate: maxDate(row.asOfDate, ...supplementalDates),
      financialAvailableAt: maxDate(row.financialAvailableAt, ...supplementalDates),
      sourceRecord: {
        ...(row.sourceRecord || {}),
        supplementalSource: "SEC CompanyFacts crypto-asset disclosures only",
        supplementalCachePath: `sec-companyfacts-cache/${path.basename(cachePath)}`,
        supplementalPitPolicy: "earliest filing date per fiscal period"
      }
    };
  });
}

export function readPitGuidance(source, tickers) {
  const placeholders = tickers.map(() => "?").join(",");
  if (!placeholders) return { rows: [], byPeriod: new Map() };
  const statement = source.prepare(`
    SELECT *
    FROM pit_guidance_events
    WHERE ticker IN (${placeholders})
    ORDER BY ticker, fiscal_period, observed_at, id
  `);
  const rows = [];
  for (const row of statement.iterate(...tickers)) rows.push(row);
  const targetCurrencies = new Map(source.prepare(`
    SELECT ticker, MAX(currency) AS currency
    FROM pit_financial_periods
    WHERE ticker IN (${placeholders})
    GROUP BY ticker
  `).all(...tickers).map((row) => [String(row.ticker).toUpperCase(), String(row.currency).toUpperCase()]));
  const reportingEvidenceByTicker = new Map();
  for (const item of source.prepare(`
    SELECT ticker, available_at, payload_json
    FROM pit_financial_periods WHERE ticker IN (${placeholders})
    ORDER BY ticker, available_at DESC
  `).all(...tickers)) {
    const ticker = String(item.ticker).toUpperCase();
    if (!reportingEvidenceByTicker.has(ticker)) reportingEvidenceByTicker.set(ticker, []);
    reportingEvidenceByTicker.get(ticker).push(item);
  }
  const issuerCurrencyAtOrBefore = (ticker, observedAt) => {
    if (!/^\d{4}-\d{2}-\d{2}/.test(String(observedAt || ""))) return null;
    const candidates = (reportingEvidenceByTicker.get(ticker) || []).filter((item) =>
      item.available_at && item.available_at <= observedAt
    );
    if (!candidates.length) return null;
    // Multiple dimensions at the same visible event must agree. Never borrow
    // the model/quote currency or a later issuer disclosure as source currency.
    const latestDate = candidates[0].available_at;
    const values = candidates.filter((item) => item.available_at === latestDate).flatMap((item) => {
      const payload = parseJson(item.payload_json, {});
      return [
        ["reportingCurrency", payload.reportingCurrency],
        ["sourceFinancialStatementCurrency", payload.sourceFinancialStatementCurrency],
        ["sourceRecord.reportingCurrency", payload.sourceRecord?.reportingCurrency],
        ["sourceRecord.sourceCurrency", payload.sourceRecord?.sourceCurrency]
      ].filter(([, value]) => /^[A-Z]{3}$/.test(String(value || "").toUpperCase())).map(([field, value]) => ({
        currency: String(value).toUpperCase(),
        field,
        availableAt: item.available_at,
        source: payload.sourceRecord?.sourceUrl || payload.sourceRecord?.dataset || null
      }));
    });
    return new Set(values.map((item) => item.currency)).size === 1 ? values[0] : null;
  };
  const hasFxRates = Boolean(source.prepare(`
    SELECT 1 AS present FROM sqlite_master
    WHERE type='table' AND name='pit_fx_reference_rates'
  `).get());
  const fxRates = new Map();
  if (hasFxRates) {
    for (const row of source.prepare(`
      SELECT currency, rate_date, units_per_eur, source_url
      FROM pit_fx_reference_rates
      ORDER BY currency, rate_date
    `).all()) {
      const currency = String(row.currency).toUpperCase();
      fxRates.set(currency, [...(fxRates.get(currency) || []), row]);
    }
  }
  const rateAtOrBefore = (currency, observedAt) => {
    if (!/^\d{4}-\d{2}-\d{2}/.test(String(observedAt || ""))) return null;
    if (currency === "EUR") return { rate_date: observedAt, units_per_eur: 1, source_url: "ECB EUR reference base" };
    const candidates = fxRates.get(currency) || [];
    for (let index = candidates.length - 1; index >= 0; index -= 1) {
      if (String(candidates[index].rate_date) <= String(observedAt)) return candidates[index];
    }
    return null;
  };
  const grouped = new Map();
  for (const row of rows) {
    // Preserve every original event in the release ledger, including actuals,
    // excluded capital budgets and unresolved research. Retention is separate
    // from permission to consume it in a numerical model.
    if (row.actual_or_guidance !== "guidance" ||
        !["clear", "ambiguous", "currency_conflict"].includes(row.quality_status)) continue;
    const ticker = String(row.ticker || "").toUpperCase();
    const fiscalPeriod = normalizePeriod(row.fiscal_period);
    if (!ticker || !fiscalPeriod) continue;
    const key = `${ticker}::${fiscalPeriod}`;
    const targetCurrency = targetCurrencies.get(ticker) || null;
    const reportedSourceCurrency = String(row.currency || "").trim().toUpperCase() || null;
    const sourceAmountM = guidancePlusMinusCenterM(
      `${row.value_text || ""} ${row.evidence_excerpt || ""}`,
      row.metric_name
    ) ??
      finiteNumber(row.amount);
    let modelAmountM = sourceAmountM;
    let fxConversion = null;
    let qualityStatus = row.quality_status;
    let rejectionReason = null;
    const issuerCurrencyEvidence = !reportedSourceCurrency && sourceAmountM != null
      ? issuerCurrencyAtOrBefore(ticker, row.observed_at)
      : null;
    const sourceCurrency = reportedSourceCurrency || issuerCurrencyEvidence?.currency || null;
    const rejectMonetaryInput = (status, reason) => {
      modelAmountM = null;
      qualityStatus = status;
      rejectionReason = reason;
    };
    const currencyEvidenceMismatch = sourceCurrency && sourceAmountM != null
      ? independentGuidanceCurrencyMismatch({
        amount: sourceAmountM,
        currency: sourceCurrency,
        evidence: row.evidence_excerpt || row.value_text
      })
      : null;
    if (row.quality_status === "currency_conflict" || currencyEvidenceMismatch) {
      rejectMonetaryInput("currency_conflict", "guidance_conflicting_source_currency");
    } else if (sourceAmountM != null && (!sourceCurrency || !targetCurrency)) {
      rejectMonetaryInput("currency_unresolved", !sourceCurrency ? "guidance_source_currency_unresolved" : "guidance_model_currency_unresolved");
    } else if (modelAmountM != null && sourceCurrency !== targetCurrency) {
      const sourceRate = rateAtOrBefore(sourceCurrency, row.observed_at);
      const targetRate = rateAtOrBefore(targetCurrency, row.observed_at);
      if (Number(sourceRate?.units_per_eur) > 0 && Number.isFinite(Number(sourceRate.units_per_eur)) &&
          Number(targetRate?.units_per_eur) > 0 && Number.isFinite(Number(targetRate.units_per_eur))) {
        const conversionRate = Number(targetRate.units_per_eur) / Number(sourceRate.units_per_eur);
        modelAmountM *= conversionRate;
        fxConversion = {
          sourceCurrency,
          targetCurrency,
          sourceAmountM,
          modelAmountM,
          conversionRate,
          sourceRateDate: sourceRate.rate_date,
          targetRateDate: targetRate.rate_date,
          source: targetRate.source_url || sourceRate.source_url
        };
      } else {
        rejectMonetaryInput("fx_unavailable", "guidance_event_visible_fx_unavailable");
      }
    }
    grouped.set(key, [...(grouped.get(key) || []), {
      ...row,
      quality_status: qualityStatus,
      model_amount_m: modelAmountM,
      model_currency: targetCurrency,
      fx_conversion: fxConversion,
      currency_resolution: {
        status: rejectionReason ? "rejected" : sourceAmountM == null ? "not_monetary" : issuerCurrencyEvidence ? "issuer_reporting_currency" : "explicit_guidance_currency",
        reportedSourceCurrency,
        resolvedSourceCurrency: sourceCurrency,
        targetCurrency,
        issuerEvidence: issuerCurrencyEvidence,
        independentEvidenceMismatch: currencyEvidenceMismatch,
        rejectionReason
      },
      model_exclusion_reason: rejectionReason,
      evidence_id: row.id,
      evidence_url: row.source_url,
      excerpt: row.evidence_excerpt
    }]);
  }
  const byPeriod = new Map();
  for (const [key, metrics] of grouped) {
    byPeriod.set(key, digestGuidanceMetrics(metrics, { sourceDatabase: PIT_GUIDANCE_LABEL }));
  }
  return { rows, byPeriod, metricsByPeriod: grouped };
}

function insertRawGuidance(db, rows, importedAt) {
  const insert = db.prepare(`
    INSERT INTO valuation_pit_guidance (
      source_database, source_id, ticker, fiscal_period, observed_at, metric_name,
      amount, unit, currency, growth_yoy, growth_qoq, margin_pct, value_text,
      quality_status, confidence, speaker, source_url, evidence_excerpt,
      payload_json, imported_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  for (const row of rows) {
    const releasePayload = sanitizeReleasePayload({
      ...row,
      payload_json: parseJson(row.payload_json, row.payload_json)
    });
    insert.run(
      row.source_type || "pit_management_guidance",
      String(row.id),
      String(row.ticker || "").toUpperCase(),
      normalizePeriod(row.fiscal_period),
      row.observed_at || null,
      row.metric_name || null,
      finiteNumber(row.amount),
      row.unit || null,
      row.currency || null,
      finiteNumber(row.growth_yoy),
      finiteNumber(row.growth_qoq),
      finiteNumber(row.margin_pct),
      row.value_text || null,
      row.quality_status || null,
      finiteNumber(row.extraction_confidence),
      row.speaker || null,
      row.source_url || null,
      row.evidence_excerpt || null,
      JSON.stringify(releasePayload),
      importedAt
    );
  }
}

function updateDashboard(db, previousDashboard, snapshots, generatedAt, sourceMetadata) {
  const compact = snapshots.map(compactTicker).sort((left, right) =>
    String(left.ticker || "").localeCompare(String(right.ticker || ""))
  );
  const summary = {
    ...(previousDashboard.summary || {}),
    tickerCount: snapshots.length,
    historyRows: snapshots.reduce((sum, ticker) => sum + (ticker.history?.length || 0), 0),
    pricePointCount: snapshots.reduce((sum, ticker) => sum + (ticker.priceHistory?.length || 0), 0),
    livePriceTickerCount: snapshots.filter((ticker) =>
      finiteNumber(ticker.latest?.latestPrice) > 0 &&
      (ticker.priceHistory || []).some((point) => finiteNumber(point?.close) > 0)
    ).length,
    positiveUpsideCount: snapshots.filter((ticker) => finiteNumber(ticker.latest?.upsideToBase) > 0).length,
    negativeUpsideCount: snapshots.filter((ticker) => finiteNumber(ticker.latest?.upsideToBase) < 0).length,
    pitFinancialTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.pitFinancialRows > 0).length,
    quarterlyBackendValuationTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.pitValuationRows > 0).length,
    unsupportedValuationTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.valuationStatus === "not_applicable").length,
    latestPriceDate: snapshots.map((ticker) => ticker.latest?.latestPriceDate).filter(Boolean).sort().at(-1) || null
  };
  const payload = {
    ...previousDashboard,
    generatedAt,
    source: {
      upstreamLabel: "Jansen Sharadar as-reported PIT financials + audited ECB quote-currency normalization + official UK issuer PIT disclosures + event-visible management guidance",
      modelVersion: MODEL_VERSION,
      sourceFingerprint: sourceMetadata.get("source_fingerprint") || null,
      pitCutoffField: "datekey",
      revisionPolicy: "earliest datekey per fiscal period; later restatements excluded",
      transcriptPolicy: "guidance only; transcript/Q&A retained separately"
    },
    summary,
    tickers: compact
  };
  db.prepare(`
    INSERT INTO valuation_snapshots (id, generated_at, payload_json)
    VALUES ('latest', ?, ?)
    ON CONFLICT(id) DO UPDATE SET generated_at = excluded.generated_at, payload_json = excluded.payload_json
  `).run(generatedAt, JSON.stringify(payload));
}

export function assertSafeImportMode({ apply = APPLY, allowIncomplete = ALLOW_INCOMPLETE } = {}) {
  if (apply && allowIncomplete) throw new Error("Unsafe PIT import: --allow-incomplete is dry-run only and cannot be combined with --apply.");
}

export function guidanceCoverageBlockers(modelTickers, guidanceCoverage) {
  const acceptableStatuses = new Set(["covered", "covered_official_filing", "no_quantified_official_guidance"]);
  return modelTickers.flatMap((model) => {
    const ticker = String(model.ticker || "").toUpperCase();
    const matches = guidanceCoverage.filter((row) => String(row.ticker || "").toUpperCase() === ticker);
    if (matches.length !== 1) return [{
      ticker,
      status: matches.length ? "guidance_duplicate_coverage" : "guidance_missing_coverage",
      note: `Expected exactly one guidance coverage row; found ${matches.length}.`
    }];
    const row = matches[0];
    return acceptableStatuses.has(row.status) ? [] : [{
      ticker,
      status: `guidance_${row.status || "missing"}`,
      note: row.note || "Management guidance coverage has not passed the PIT evidence review."
    }];
  });
}

export function issuerReviewBlockers(modelTickers, issuerReviews = null, reviewedCurrent = new Map()) {
  if (issuerReviews == null) return [];
  return modelTickers.flatMap((model) => {
    const ticker = String(model.ticker || "").toUpperCase();
    const rows = issuerReviews.filter((row) => String(row.ticker || "").toUpperCase() === ticker);
    const current = reviewedCurrent.get(ticker);
    const currentBound = current && rows.length === 1 && rows[0].status === "reviewed_current_only" &&
      rows[0].reason.includes(current.currentSourceBinding.manifestSha256);
    return rows.length === 1 && (rows[0].status === "reviewed" && !current || currentBound) ? [] : [{
      ticker,
      status: "issuer_pending_economic_review",
      note: rows[0]?.reason || "The staged issuer requires an explicit completed economic, share/ADR and cash-flow review."
    }];
  });
}

function main() {
  assertSafeImportMode();
  const loadedCurrent = reviewedCurrentFromEnvironment();
  const reviewedCurrent = new Map((loadedCurrent?.candidates || []).map(c => [c.ticker, c]));
  if (!fs.existsSync(SOURCE_DB_PATH)) throw new Error(`PIT valuation source not found: ${SOURCE_DB_PATH}`);
  if (!fs.existsSync(TARGET_DB_PATH)) throw new Error(`Target database not found: ${TARGET_DB_PATH}`);
  const source = new DatabaseSync(SOURCE_DB_PATH, { readOnly: true });
  const target = new DatabaseSync(TARGET_DB_PATH);
  try {
    ensurePitTables(target);
    const previousDashboard = parseJson(
      target.prepare("SELECT payload_json FROM valuation_snapshots WHERE id = 'latest'").get()?.payload_json,
      {}
    );
    const currentSnapshotStatement = target.prepare(
      "SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker = ?"
    );
    const currentSnapshot = (ticker) => parseJson(
      currentSnapshotStatement.get(String(ticker).toUpperCase())?.payload_json,
      null
    );
    const coverage = source.prepare("SELECT * FROM pit_financial_coverage ORDER BY ticker").all();
    const guidanceCoverage = source.prepare("SELECT * FROM pit_guidance_coverage ORDER BY ticker").all();
    const sourceMetadata = new Map(
      source.prepare("SELECT key, value FROM pit_source_metadata").all().map((row) => [row.key, row.value])
    );
    const currentBinding = sourceCurrentBindingMetadata(loadedCurrent);
    if (currentBinding) {
      if (sourceMetadata.get("reviewed_current_candidates") !== JSON.stringify(currentBinding)) throw new Error("Full source does not bind the exact independently reviewed current candidates");
    } else if (sourceMetadata.has("reviewed_current_candidates")) throw new Error("Current-only source requires separately pinned original evidence manifest");
    const countStatuses = (rows) => Object.fromEntries(
      [...rows.reduce((counts, row) => {
        const status = String(row.status || "unknown");
        counts.set(status, (counts.get(status) || 0) + 1);
        return counts;
      }, new Map()).entries()].sort(([left], [right]) => left.localeCompare(right))
    );
    sourceMetadata.set("financial_coverage_summary", JSON.stringify(countStatuses(coverage)));
    sourceMetadata.set("financial_coverage_by_ticker", JSON.stringify(financialCoverageLedger(coverage)));
    sourceMetadata.set("guidance_coverage_summary", JSON.stringify(countStatuses(guidanceCoverage)));
    sourceMetadata.set("guidance_coverage_ticker_count", String(guidanceCoverage.length));
    sourceMetadata.set("guidance_no_quantified_tickers", JSON.stringify(
      guidanceCoverage
        .filter((row) => row.status === "no_quantified_official_guidance")
        .map((row) => String(row.ticker).toUpperCase())
        .sort()
    ));
    const blockers = coverage.filter((row) => row.status === "missing" || row.status === "external_required");
    const modelTickers = coverage.filter((row) => ["covered", "annual_only"].includes(row.status));
    blockers.push(...guidanceCoverageBlockers(modelTickers, guidanceCoverage));
    const hasIssuerReview = source.prepare("SELECT 1 AS present FROM sqlite_master WHERE type='table' AND name='pit_issuer_review'").get();
    blockers.push(...issuerReviewBlockers(modelTickers,
      hasIssuerReview ? source.prepare("SELECT ticker, status, reason FROM pit_issuer_review ORDER BY ticker").all() : null, reviewedCurrent));
    for (const ticker of reviewedCurrent.keys()) if (!modelTickers.some(r => r.ticker === ticker)) blockers.push({ ticker, status: "current_candidate_missing_full_source_coverage" });
    const evidenceTickers = [...new Set(modelTickers.flatMap((row) => [row.ticker, row.source_ticker]).filter(Boolean))];
    const pitGuidance = readPitGuidance(source, evidenceTickers);
    const guidanceByPeriod = pitGuidance.byPeriod;
    const guidanceMetricsByPeriod = pitGuidance.metricsByPeriod;
    const rawGuidance = pitGuidance.rows;
    const generatedAt = releaseGeneratedAt();
    const nextSnapshots = [];
    const modelRuns = [];
    const results = [];

    for (const coverageRow of modelTickers) {
      const ticker = String(coverageRow.ticker).toUpperCase();
      const sourceTicker = String(coverageRow.source_ticker || ticker).toUpperCase();
      if (reviewedCurrent.has(ticker)) {
        const sourceRows = source.prepare("SELECT * FROM pit_financial_periods WHERE ticker=? ORDER BY fiscal_period,dimension").all(ticker);
        const checked = bindReviewedCurrentFinancialPeriods(reviewedCurrent.get(ticker), sourceRows);
        const existing = currentSnapshot(ticker);
        if (!existing || String(existing.cik).replace(/^0+/, "") !== checked.snapshot.cik) throw new Error(`${ticker}: exact current metadata/CIK seed is absent`);
        // This branch preserves one reviewed point, never calls the generic
        // historical model and never promotes a current review to history.
        checked.snapshot.history = preserveTranscriptQaByFiscalPeriod(checked.snapshot.history, existing.history);
        nextSnapshots.push(compactSnapshotPriceHistory(checked.snapshot));
        modelRuns.push(...checked.modelRuns);
        results.push({ ticker, sourceTicker, financialRows: sourceRows.length, valuationRows: 1,
          currentOnly: true, historicalCurveAuthorized: false,
          explicitlyUnmodeledPeriods: checked.snapshot.dataQuality.financialPeriodDispositions.filter(r => r.status === "explicitly_unmodeled").length });
        continue;
      }
      if (!hasExplicitValuationProfile(ticker)) {
        blockers.push({ ticker, status: "missing_valuation_profile", note: "Covered PIT ticker has no explicit valuation profile." });
        continue;
      }
      const existing = currentSnapshot(ticker);
      if (!existing) {
        blockers.push({ ticker, status: "missing_target_snapshot", note: "No current ticker metadata or price history." });
        continue;
      }
      const sourceRows = source.prepare(`
        SELECT * FROM pit_financial_periods WHERE ticker = ? ORDER BY available_at, dimension
      `).all(ticker);
      const quarterlyRows = attachPointInTimeSupplements(
        ticker,
        buildQuarterlyRows(sourceRows, guidanceByPeriod, guidanceMetricsByPeriod, ticker, sourceTicker),
        existing
      );
      const existingPrices = Array.isArray(existing.priceHistory) ? existing.priceHistory : [];
      const databasePrices = readPriceHistoryFromDb(
        target,
        valuationMarketPriceSymbol(ticker),
        10_000
      );
      const snapshotBase = cleanSnapshot({
        ...existing,
        ticker,
        priceHistory: mergeValuationComparisonHistory({
          existing: existingPrices, incremental: databasePrices,
          priceSymbol: valuationMarketPriceSymbol(ticker), quoteCurrency: existing.currency
        })
      });
      const officialIssuerPit = ["BA.L", "LSEG"].includes(ticker);
      const factsUrl = officialIssuerPit
        ? `official-issuer://fundamentals/${sourceTicker}`
        : `jansen-sharadar://fundamentals/${sourceTicker}`;
      const financialSource = officialIssuerPit
        ? {
            sourceType: "official_issuer_pit_quarterly_model",
            annualSourceType: "official_issuer_pit_annual_model",
            sourceQuality: "official-issuer-as-reported-quarterly",
            annualSourceQuality: "official-issuer-as-reported-annual",
            sourceName: "Official issuer as-reported PIT disclosures",
            eventType: "pit_quarterly_fundamental_guidance_model",
            periodIdPrefix: "official-issuer-pit",
            modelVersion: MODEL_VERSION
          }
        : {
            sourceType: "jansen_pit_quarterly_model",
            annualSourceType: "jansen_pit_annual_model",
            sourceQuality: "jansen-sharadar-as-reported-quarterly",
            annualSourceQuality: "jansen-sharadar-as-reported-annual",
            sourceName: "Jansen Sharadar SF1 as-reported PIT financials with audited quote-currency normalization",
            eventType: "pit_quarterly_fundamental_guidance_model",
            periodIdPrefix: "jansen-pit",
            modelVersion: MODEL_VERSION
          };
      const valuationRows = buildValuationRows({
        ticker,
        trinityTicker: sourceTicker,
        snapshot: snapshotBase,
        companyModel: { ticker: sourceTicker, company: existing.name, cik: existing.cik || null },
        factsUrl,
        quarterlyRows,
        youtubeByPeriod: guidanceByPeriod,
        financialSource
      });
      if (!valuationRows.length) {
        blockers.push({
          ticker,
          sourceTicker,
          status: "zero_valuation_rows",
          financialRows: quarterlyRows.length,
          note: "PIT financials were available, but the valuation model produced no auditable historical node."
        });
        results.push({
          ticker,
          sourceTicker,
          financialRows: quarterlyRows.length,
          valuationRows: 0,
          guidancePeriods: 0
        });
        continue;
      }
      const snapshotValuationRows = preserveTranscriptQaByFiscalPeriod(
        valuationRows,
        existing.history
      );
      const youtubePeriods = valuationRows.filter((row) => row.dataSnapshot?.youtubeEarnings?.guidanceMetricCount).length;
      const next = updateTickerSnapshot({
        ticker,
        snapshot: snapshotBase,
        valuationRows: snapshotValuationRows,
        coverage: {
          source: officialIssuerPit ? "Official issuer PIT" : "Jansen Sharadar PIT",
          sourceLabel: officialIssuerPit
            ? "Official issuer as-reported financials + PIT management guidance"
            : "Jansen Sharadar as-reported PIT financials + audited ECB quote-currency normalization + PIT management guidance",
          sourceNote: officialIssuerPit
            ? "Each historical point uses the issuer result available on that date and only guidance observed before the next distinct financial release."
            : "Each historical point uses the first as-reported datekey record, audited nearest-prior ECB FX when quote-currency normalization is required, and only same-period guidance observed before the next distinct financial release.",
          modelType: "Point-in-time Fundamental Analysis model",
          methodCardLabel: "PIT financial + guidance model",
          methodCardDescription: "Constant-method historical replay using only financials and management guidance visible at each event.",
          sourcePath: PIT_SOURCE_LABEL,
          sourceFingerprint: sourceMetadata.get("source_fingerprint") || null,
          sourceTicker,
          quarterlyFinancialRows: quarterlyRows.length,
          secRows: valuationRows.length,
          valuationRows: valuationRows.length,
          youtubePeriods,
          modelVersion: MODEL_VERSION,
          priceExcludedFromFairValue: true,
          modelInputPolicy: "as-reported PIT financials + event-visible management guidance; market price comparison only"
        }
      });
      next.dataQuality = {
        ...next.dataQuality,
        pitFinancialRows: quarterlyRows.length,
        pitValuationRows: valuationRows.length,
        pitGuidancePeriods: youtubePeriods,
        modelVersion: MODEL_VERSION,
        sourceFingerprint: sourceMetadata.get("source_fingerprint") || null,
        revisionPolicy: "earliest datekey per fiscal period; guidance strictly before next distinct financial release"
      };
      nextSnapshots.push(compactSnapshotPriceHistory(next));
      for (const output of valuationRows) {
        const fiscalPeriod = `${output.fiscalYear}-${output.fiscalQuarter}`;
        const financial = quarterlyRows.find((row) => row.fiscalYear === output.fiscalYear && row.fiscalQuarter === output.fiscalQuarter);
        const guidance = output.dataSnapshot?.youtubeEarnings || null;
        modelRuns.push({
          ticker,
          fiscalPeriod,
          asOfDate: output.asOfDate,
          financialAvailableAt: financial?.financialAvailableAt || output.asOfDate,
          guidanceMaxObservedAt: guidance?.maxObservedAt || null,
          input: {
            financial: output.dataSnapshot?.fiscalFinancials || null,
            trailingTwelveMonths: output.dataSnapshot?.trailingTwelveMonths || null,
            guidance,
            valuationSemantics: output.dataSnapshot?.valuationSemantics || null,
            sourceRecord: output.dataSnapshot?.financialSource?.record || null,
            trailingTwelveMonthsSourceRecord: output.dataSnapshot?.financialSource?.trailingTwelveMonthsRecord || null
          },
          output,
          priceObservation: finiteNumber(output.priceAtDate) > 0 && output.priceDate
            ? {
                priceSymbol: valuationMarketPriceSymbol(ticker),
                priceDate: String(output.priceDate).slice(0, 10),
                close: finiteNumber(output.priceAtDate),
                quoteCurrency: existing.currency || null,
                source: output.dataSnapshot?.asOfPriceSource?.source || existing.priceSource || "snapshot price history",
                payload: {
                  ticker,
                  sourceTicker,
                  asOfDate: output.asOfDate,
                  source: output.dataSnapshot?.asOfPriceSource || null,
                  policy: "Exact raw market-price observation used only for comparison with the PIT fair-value output."
                }
              }
            : null
        });
      }
      results.push({ ticker, sourceTicker, financialRows: quarterlyRows.length, valuationRows: valuationRows.length, guidancePeriods: youtubePeriods });
    }

    const derivedCoverage = coverage.filter((row) => row.status === "derived");
    for (const coverageRow of derivedCoverage) {
      const ticker = String(coverageRow.ticker || "").toUpperCase();
      const sourceTicker = String(coverageRow.source_ticker || ticker).toUpperCase();
      const existing = currentSnapshot(ticker);
      if (!existing) continue;
      const snapshotBase = cleanSnapshot(existing);
      nextSnapshots.push(compactSnapshotPriceHistory({
        ...snapshotBase,
        modelType: "Derived instrument without issuer financial statements",
        latest: {
          ...snapshotBase.latest,
          valuationAnchorPrice: null,
          valuationAnchorDate: null,
          baseFairValue: null,
          fairValueSource: null,
          fairValueInputPolicy: "No issuer PIT model available for derived instruments",
          upsideToBase: null,
          targetPrice3Y: null,
          expectedReturn3Y: null
        },
        scenarios: [],
        history: [],
        methodCards: [],
        assumptions: {},
        warnings: [coverageRow.note || "Derived instrument; no issuer financial statement model."],
        dataQuality: {
          ...snapshotBase.dataQuality,
          pitFinancialRows: 0,
          pitValuationRows: 0,
          pitGuidancePeriods: 0,
          modelVersion: MODEL_VERSION,
          sourceFingerprint: sourceMetadata.get("source_fingerprint") || null,
          valuationStatus: "not_applicable",
          derivedInstrument: true,
          sourceTicker,
          sourceNote: coverageRow.note || null,
          priceExcludedFromFairValue: true
        }
      }));
      results.push({
        ticker,
        sourceTicker,
        financialRows: 0,
        valuationRows: 0,
        guidancePeriods: 0,
        derived: true
      });
    }
    if (blockers.length && !ALLOW_INCOMPLETE) {
      console.log(JSON.stringify({ apply: false, modelVersion: MODEL_VERSION, results, blockers, derivedCoverage }, null, 2));
      throw new Error(`PIT valuation import blocked by ${blockers.length} incomplete ticker(s).`);
    }
    if (!APPLY) {
      console.log(JSON.stringify({ apply: false, modelVersion: MODEL_VERSION, results, blockers, derivedCoverage, rawGuidanceRows: rawGuidance.length }, null, 2));
      return;
    }

    target.exec("BEGIN IMMEDIATE");
    try {
      target.exec(`
        DELETE FROM valuation_pit_source_metadata;
        DELETE FROM valuation_pit_financials;
        DELETE FROM valuation_pit_guidance;
        DELETE FROM valuation_pit_model_runs;
        DELETE FROM valuation_pit_price_observations;
        DELETE FROM valuation_ticker_snapshots;
        DELETE FROM valuation_snapshots;
      `);
      const insertMeta = target.prepare("INSERT INTO valuation_pit_source_metadata (key, value, imported_at) VALUES (?, ?, ?)");
      for (const [key, value] of publicationMetadata(sourceMetadata)) insertMeta.run(key, value, generatedAt);
      const insertFinancial = target.prepare(`
        INSERT INTO valuation_pit_financials (
          ticker, source_ticker, fiscal_period, fiscal_year, fiscal_quarter, dimension,
          available_at, report_period, currency, payload_json, imported_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);
      for (const row of source.prepare("SELECT * FROM pit_financial_periods ORDER BY ticker, available_at, dimension").iterate()) {
        insertFinancial.run(
          row.ticker, row.source_ticker, row.fiscal_period, row.fiscal_year, row.fiscal_quarter,
          row.dimension, row.available_at, row.report_period, row.currency, row.payload_json, generatedAt
        );
      }
      insertRawGuidance(target, rawGuidance, generatedAt);
      const insertSnapshot = target.prepare(`
        INSERT INTO valuation_ticker_snapshots (ticker, generated_at, payload_json) VALUES (?, ?, ?)
      `);
      for (const snapshot of nextSnapshots) insertSnapshot.run(snapshot.ticker, generatedAt, JSON.stringify(snapshot));
      const insertRun = target.prepare(`
        INSERT INTO valuation_pit_model_runs (
          ticker, fiscal_period, model_version, as_of_date, financial_available_at,
          guidance_max_observed_at, input_json, output_json, generated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);
      for (const run of modelRuns) {
        insertRun.run(
          run.ticker, run.fiscalPeriod, MODEL_VERSION, run.asOfDate, run.financialAvailableAt,
          run.guidanceMaxObservedAt, JSON.stringify(run.input), JSON.stringify(run.output), generatedAt
        );
      }
      const insertPriceObservation = target.prepare(`
        INSERT INTO valuation_pit_price_observations (
          ticker, fiscal_period, model_version, price_symbol, price_date, close,
          quote_currency, source, payload_json, imported_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);
      for (const run of modelRuns) {
        if (!run.priceObservation) continue;
        insertPriceObservation.run(
          run.ticker,
          run.fiscalPeriod,
          MODEL_VERSION,
          run.priceObservation.priceSymbol,
          run.priceObservation.priceDate,
          run.priceObservation.close,
          run.priceObservation.quoteCurrency,
          run.priceObservation.source,
          JSON.stringify(run.priceObservation.payload),
          generatedAt
        );
      }
      updateDashboard(target, previousDashboard, nextSnapshots, generatedAt, sourceMetadata);
      target.exec("COMMIT");
    } catch (error) {
      target.exec("ROLLBACK");
      throw error;
    }
    target.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    console.log(JSON.stringify({ apply: true, modelVersion: MODEL_VERSION, results, blockers, modelRuns: modelRuns.length, rawGuidanceRows: rawGuidance.length }, null, 2));
  } finally {
    source.close();
    target.close();
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) main();
