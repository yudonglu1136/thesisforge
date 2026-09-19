import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PRICE_TYPES, queryFactsBatch } from "./factRepository.js";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SOURCE = "Sharadar Local Fact OS";
const MODEL_NOTICE = "Published valuation and its recorded inputs are archived model artifacts, not a newly recomputed valuation. Current financial facts are sourced separately from Local Fact OS.";

export function factGeneration() {
  const root = path.resolve(process.env.FACT_OS_ROOT || path.join(projectRoot, "data/fact_os"));
  try {
    const stat = fs.statSync(path.join(root, "manifests/catalog.json"));
    return `${root}:${stat.mtimeMs}:${stat.size}`;
  } catch { return `${root}:unavailable`; }
}

function finite(value) {
  return value !== null && value !== undefined && value !== "" && Number.isFinite(Number(value)) ? Number(value) : null;
}

function latestFinancial(rows, cutoff) {
  return [...(rows || [])].filter(row => String(row.available_at || row.datekey || row.date || "") <= cutoff &&
    String(row.reportperiod || row.period_end || "") <= cutoff)
    .sort((a, b) => String(a.reportperiod || a.period_end || "").localeCompare(String(b.reportperiod || b.period_end || "")) ||
      String(a.available_at || a.datekey || a.date || "").localeCompare(String(b.available_at || b.datekey || b.date || ""))).at(-1) || null;
}

function usdAmount(row, field, usdField) {
  if (!row) return null;
  const reportedUsd = usdField ? finite(row[usdField]) : null;
  if (reportedUsd !== null) return reportedUsd;
  const amount = finite(row[field]); const fx = finite(row.fxusd);
  return amount !== null && fx > 0 ? amount / fx : null;
}

// Keep vendor fields out of the presentation layer and units explicit. ARQ is
// used only for quarterly growth; ART is already trailing twelve months, never
// multiplied by four. Missing facts do not inherit archived model inputs.
export function financialDisplay({ quarterly = [], trailing = [], asOf }) {
  const quarter = latestFinancial(quarterly, asOf);
  const ttm = latestFinancial(trailing, asOf);
  const calendar = String(quarter?.calendardate || quarter?.reportperiod || "");
  const priorCalendar = calendar ? `${Number(calendar.slice(0, 4)) - 1}${calendar.slice(4)}` : "";
  const priorQuarter = latestFinancial(quarterly.filter(row =>
    String(row.calendardate || row.reportperiod || "") === priorCalendar), asOf);
  const revenue = usdAmount(ttm, "revenue", "revenueusd");
  const quarterRevenue = usdAmount(quarter, "revenue", "revenueusd");
  const priorRevenue = usdAmount(priorQuarter, "revenue", "revenueusd");
  const cfo = usdAmount(ttm, "ncfo"); const capex = usdAmount(ttm, "capex");
  const fcf = cfo !== null && capex !== null ? cfo - Math.abs(capex) : null;
  const operatingIncome = finite(ttm?.opinc); const reportedRevenue = finite(ttm?.revenue);
  const shares = finite(ttm?.shareswadil); const sharefactor = finite(ttm?.sharefactor);
  return { currency: "USD", dimension: "ART", periodEnd: ttm?.reportperiod || ttm?.period_end || null,
    availableAt: ttm?.available_at || ttm?.datekey || ttm?.date || null,
    quarterlyPeriodEnd: quarter?.reportperiod || quarter?.period_end || null,
    revenueM: revenue === null ? null : revenue / 1e6,
    quarterlyRevenueGrowthRatio: quarterRevenue !== null && priorRevenue > 0 ? quarterRevenue / priorRevenue - 1 : null,
    operatingMarginRatio: operatingIncome !== null && reportedRevenue > 0 ? operatingIncome / reportedRevenue : null,
    freeCashFlowM: fcf === null ? null : fcf / 1e6,
    freeCashFlowMarginRatio: fcf !== null && revenue > 0 ? fcf / revenue : null,
    dilutedShareEquivalentsM: shares !== null && sharefactor > 0 ? shares * sharefactor / 1e6 : null,
    cashFlowBasis: "CFO minus absolute capex; not verified parent FCFE",
    provenance: { trailing: ttm?.provenance || null, quarterly: quarter?.provenance || null,
      priorQuarter: priorQuarter?.provenance || null } };
}

function priorPrice(points, date) {
  if (!date) return null;
  let low = 0; let high = points.length - 1; let result = null;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    if (points[middle].date <= String(date).slice(0, 10)) { result = points[middle]; low = middle + 1; }
    else high = middle - 1;
  }
  return result;
}

function priceComparison(price, fairValue, targetPrice) {
  const value = finite(price); const fair = finite(fairValue); const target = finite(targetPrice);
  return {
    upsideToBase: value > 0 && fair !== null ? fair / value - 1 : null,
    expectedReturn3Y: value > 0 && target > 0 ? (target / value) ** (1 / 3) - 1 : null
  };
}

// A US-listed ADR is not the same quoted security as its London listing. Never
// use a US dollar price in an existing GBP model without a verified conversion.
export function quoteCompatible(snapshot) {
  return (!snapshot.currency || String(snapshot.currency).toUpperCase() === "USD") &&
    !String(snapshot.ticker || snapshot.key || "").toUpperCase().endsWith(".L");
}

export function overlayValuationFacts(snapshot, { prices = [], quarterly = [], trailing = [], errors = [], asOf, detail = true } = {}) {
  const cutoff = asOf || new Date().toISOString().slice(0, 10);
  const points = quoteCompatible(snapshot) ? prices
    .filter(point => finite(point.value ?? point.close) > 0 && String(point.date) <= cutoff)
    .map(point => ({ date: String(point.date), close: finite(point.value ?? point.close), source: SOURCE,
      priceType: PRICE_TYPES.RAW_CLOSE, provenance: point.provenance || null }))
    .sort((a, b) => a.date.localeCompare(b.date)) : [];
  const latestPrice = points.at(-1) || null;
  const latest = { ...(snapshot.latest || {}), latestPrice: latestPrice?.close ?? null,
    latestPriceDate: latestPrice?.date ?? null, latestPriceSource: latestPrice ? SOURCE : "unavailable",
    priceType: PRICE_TYPES.RAW_CLOSE,
    ...priceComparison(latestPrice?.close, snapshot.latest?.baseFairValue, snapshot.latest?.targetPrice3Y),
    publishedModelStatus: "archived_not_recomputed", modelInputPolicy: MODEL_NOTICE };
  if (detail) {
    const anchor = priorPrice(points, snapshot.latest?.valuationAnchorDate);
    latest.valuationAnchorPrice = anchor?.close ?? null;
    latest.valuationAnchorDate = anchor?.date ?? null;
  } else {
    // The dashboard batch has only the latest point, not an archival quote.
    latest.valuationAnchorPrice = null;
    latest.valuationAnchorDate = null;
  }
  const history = detail ? (snapshot.history || []).filter(row => !row.asOfDate || row.asOfDate <= cutoff).map(row => {
    const quoted = priorPrice(points, row.asOfDate);
    const comparison = priceComparison(quoted?.close, row.fairValue, row.targetPrice3Y);
    return { ...row, currentPrice: quoted?.close ?? null, priceAtDate: quoted?.close ?? null,
      priceDate: quoted?.date ?? null, upsideDownside: comparison.upsideToBase, expectedReturn3Y: comparison.expectedReturn3Y,
      publishedModelStatus: "archived_not_recomputed", publishedModelNotice: MODEL_NOTICE,
      // Preserve exactly the recorded input -> published value trace. These are
      // historical model inputs, not the current canonical financials below.
      dataSnapshot: { ...(row.dataSnapshot || {}), role: "archived_model_inputs",
        factsSourceStatus: "recorded_model_inputs_not_current_facts" } };
  }) : snapshot.history;
  return { ...snapshot, latest, ...(detail ? { history } : {}), priceHistory: points,
    priceSource: { source: SOURCE, priceType: PRICE_TYPES.RAW_CLOSE, localOnly: true, status: points.length ? "available" : "missing" },
    currentFinancials: { source: SOURCE, asOf: cutoff, quarterly: latestFinancial(quarterly, cutoff),
      trailingTwelveMonths: latestFinancial(trailing, cutoff),
      display: financialDisplay({ quarterly, trailing, asOf: cutoff }),
      status: latestFinancial(quarterly, cutoff) || latestFinancial(trailing, cutoff) ? "available" : detail ? "missing" : "open_detail_for_financial_facts",
      note: "AR facts retain filing availability and dimension. These are not substituted into archived model outputs." },
    ...(detail ? { financialHistory: { quarterly, trailingTwelveMonths: trailing, source: SOURCE } } : {}),
    dataQuality: { ...(snapshot.dataQuality || {}), canonicalFactsSource: SOURCE,
      pricePoints: points.length, hasLivePriceSeries: points.length > 0,
      publishedModelStatus: "archived_not_recomputed", modelInputPolicy: MODEL_NOTICE,
      factErrors: [...errors, ...(!quoteCompatible(snapshot) ? ["quoted_security_currency_not_supported"] : [])] },
    warnings: [...new Set([...(snapshot.warnings || []), MODEL_NOTICE,
      ...(!latestPrice ? ["No compatible local quote. No Yahoo/legacy price has been substituted."] : [])])] };
}

export async function loadCanonicalValuationDetail(snapshot, { asOf, readBatch = queryFactsBatch } = {}) {
  const cutoff = asOf || new Date().toISOString().slice(0, 10);
  const ticker = String(snapshot.ticker || snapshot.key || "").toUpperCase();
  const requests = [
    { method: "get_price_history", args: [ticker, "1900-01-01", cutoff, PRICE_TYPES.RAW_CLOSE], kwargs: { dataset: "auto" } },
    { method: "get_fundamentals", args: [ticker, "ARQ"], kwargs: { as_of: cutoff } },
    { method: "get_fundamentals", args: [ticker, "ART"], kwargs: { as_of: cutoff } }
  ];
  let results;
  try { results = await readBatch(requests); }
  catch (error) { results = requests.map(() => ({ ok: false, error: { code: error.code || "local_data_unavailable" } })); }
  const values = results.map(result => result?.ok ? result.result : []);
  return overlayValuationFacts(snapshot, { prices: values[0], quarterly: values[1], trailing: values[2], asOf: cutoff,
    errors: results.filter(result => !result?.ok).map(result => result?.error?.code || "local_data_unavailable") });
}

export async function loadCanonicalValuationDashboard(snapshots, { asOf, readBatch = queryFactsBatch } = {}) {
  const cutoff = asOf || new Date().toISOString().slice(0, 10);
  const tickers = [...new Set(snapshots.filter(quoteCompatible).map(row => String(row.ticker || row.key || "").toUpperCase()).filter(Boolean))];
  let prices = {}; let financials = {}; let errors = [];
  try {
    const results = await readBatch([
      { method: "get_prices", args: [tickers, cutoff, PRICE_TYPES.RAW_CLOSE], kwargs: { dataset: "auto" } },
      { method: "get_latest_fundamentals", args: [tickers, "ART"], kwargs: { as_of: cutoff } }
    ]);
    prices = results[0]?.ok ? results[0].result : {};
    financials = results[1]?.ok ? results[1].result : {};
    errors = results.filter(result => !result?.ok).map(result => result?.error?.code || "local_data_unavailable");
  } catch (error) { errors = [error.code || "local_data_unavailable"]; }
  return snapshots.map(snapshot => {
    const ticker = String(snapshot.ticker || snapshot.key || "").toUpperCase();
    const price = prices[ticker];
    return overlayValuationFacts(snapshot, { prices: price ? [price] : [], trailing: financials[ticker] ? [financials[ticker]] : [], errors, asOf: cutoff, detail: false });
  });
}
