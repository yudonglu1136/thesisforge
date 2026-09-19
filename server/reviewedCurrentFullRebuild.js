import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { loadReviewedCurrentValuationCandidates, auditStoredReviewedCurrentCandidate } from "./reviewedCurrentValuationCandidates.js";

const sha = (value) => createHash("sha256").update(typeof value === "string" ? value : JSON.stringify(value)).digest("hex");
const sameNumber = (a, b) => typeof a === "number" && typeof b === "number" && Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= 1e-8 * Math.max(1, Math.abs(a), Math.abs(b));

/** External evidence is mandatory even when the database claims current-ready. */
export function reviewedCurrentFromEnvironment(env = process.env) {
  const file = env.PIT_REVIEWED_CURRENT_MANIFEST, digest = env.PIT_REVIEWED_CURRENT_MANIFEST_SHA256;
  if (!file && !digest) return null;
  if (!file || !/^[a-f0-9]{64}$/.test(digest || "")) throw new Error("Both independently pinned current-manifest settings are required");
  return loadReviewedCurrentValuationCandidates({ manifestJson: readFileSync(file, "utf8"), expectedManifestSha256: digest });
}

/** Retain every original financial row; authorize only the reviewed current
 * quarter. The unmodeled ledger is source-bound, not an issuer-wide exemption. */
export function bindReviewedCurrentFinancialPeriods(candidate, sourceRows) {
  const run = candidate.modelRuns[0], ticker = candidate.ticker;
  if (!sourceRows.length || sourceRows.some((r) => r.ticker !== ticker || r.source_ticker !== ticker ||
    !["ARQ", "ART"].includes(r.dimension) || !/^20\d{2}-Q[1-4]$/.test(r.fiscal_period) ||
    r.available_at > run.financialAvailableAt || r.report_period > run.output.periodEndDate)) throw new Error(`${ticker}: current review is stale or source identities do not match`);
  const latest = sourceRows.filter((r) => r.fiscal_period === run.fiscalPeriod && r.dimension === "ART");
  if (latest.length !== 1 || latest[0].available_at !== run.financialAvailableAt || latest[0].report_period !== run.output.periodEndDate) throw new Error(`${ticker}: missing exact reviewed current ART source`);
  const financial = JSON.parse(latest[0].payload_json), record = financial.sourceRecord || {};
  const raw = ticker === "SPOT" ? candidate.modelRuns[0].input.financial : null;
  if (record.sourceTicker !== ticker || record.datekey !== run.financialAvailableAt || record.reportperiod !== run.output.periodEndDate || record.dimension !== "ART") throw new Error(`${ticker}: current ART lineage differs from original reviewed source`);
  if (raw) {
    for (const field of ["revenue_m", "cfo_m", "capex_m", "operating_income_m", "net_income_m", "shares_m"]) if (!sameNumber(financial[field], raw[field])) throw new Error(`${ticker}: original paid ART mismatch: ${field}`);
    if (record.sourceCurrency !== "EUR" || financial.financialStatementCurrency !== "USD" || !sameNumber(record.currencyScale, raw.sourceRecord.currencyScale)) throw new Error(`${ticker}: paid reporting/model currency mismatch`);
  } else {
    const source = candidate.modelRuns[0].input.economicInput;
    if (record.sourceCurrency !== "MXN" || !(record.currencyScale > 0) || financial.financialStatementCurrency !== "USD") throw new Error(`${ticker}: paid reporting/model currency mismatch`);
    for (const [field, inputKey] of [["revenue_m", "sourceRevenue"], ["cfo_m", "sourceCfo"], ["capex_m", "sourceCapex"]]) if (!sameNumber(financial[field] / record.currencyScale, source[inputKey])) throw new Error(`${ticker}: original paid ART mismatch: ${field}`);
  }
  const periods = new Map();
  for (const row of sourceRows) {
    if (!periods.has(row.fiscal_period)) periods.set(row.fiscal_period, []);
    const list = periods.get(row.fiscal_period);
    if (list.some((r) => r.dimension === row.dimension)) throw new Error(`${ticker}: duplicate financial period/dimension`);
    list.push({ dimension: row.dimension, availableAt: row.available_at, reportPeriod: row.report_period, payloadSha256: sha(row.payload_json) });
  }
  const ledger = [...periods].sort(([a], [b]) => a.localeCompare(b)).map(([fiscalPeriod, rows]) => ({ ticker, fiscalPeriod,
    status: fiscalPeriod === run.fiscalPeriod ? "modeled_current_only" : "explicitly_unmodeled",
    reason: fiscalPeriod === run.fiscalPeriod ? "source_reviewed_current_economic_model" : "historical_cash_flow_claims_and_assumptions_not_reviewed_current_only_model",
    reviewedAsOfDate: run.asOfDate, manifestSha256: candidate.currentSourceBinding.manifestSha256,
    sourceRows: rows.sort((a, b) => a.dimension.localeCompare(b.dimension)) }));
  const result = structuredClone(candidate);
  result.snapshot.dataQuality.currentSourceBinding = { ...candidate.currentSourceBinding, financialPeriodLedgerSha256: sha(ledger) };
  result.snapshot.dataQuality.financialPeriodDispositions = ledger;
  result.snapshot.dataQuality.pitFinancialRows = sourceRows.length;
  return result;
}

export function sourceCurrentBindingMetadata(loaded) {
  return loaded ? { schemaVersion: 1, manifestSha256: loaded.manifestSha256, historicalApproval: false,
    entries: loaded.candidates.map((c) => ({ ticker: c.ticker, ...c.currentSourceBinding })) } : null;
}

export function auditReviewedCurrentDatabase(db, loaded) {
  const results = [], candidates = new Map();
  const declared = db.prepare("SELECT value FROM valuation_pit_source_metadata WHERE key='reviewed_current_candidates'").get()?.value;
  if (!loaded) {
    const unbound = db.prepare("SELECT ticker FROM valuation_ticker_snapshots WHERE json_extract(payload_json,'$.dataQuality.currentOnly')=1").all();
    return { candidates, results, failures: declared || unbound.length ? [{ code: "current_only_release_missing_independent_manifest", tickers: unbound.map(r => r.ticker) }] : [] };
  }
  const failures = [];
  if (declared !== JSON.stringify(sourceCurrentBindingMetadata(loaded))) failures.push({ code: "current_only_manifest_metadata_mismatch" });
  for (const candidate of loaded.candidates) {
    try {
      const sourceRows = db.prepare("SELECT * FROM valuation_pit_financials WHERE ticker=? ORDER BY fiscal_period,dimension").all(candidate.ticker);
      const expected = bindReviewedCurrentFinancialPeriods(candidate, sourceRows);
      const saved = db.prepare("SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?").get(candidate.ticker);
      const snapshot = saved ? JSON.parse(saved.payload_json) : null;
      const modelRuns = db.prepare("SELECT * FROM valuation_pit_model_runs WHERE ticker=? ORDER BY as_of_date").all(candidate.ticker).map(r => ({ ticker: r.ticker,
        fiscalPeriod: r.fiscal_period, asOfDate: r.as_of_date, financialAvailableAt: r.financial_available_at,
        guidanceMaxObservedAt: r.guidance_max_observed_at, input: JSON.parse(r.input_json), output: JSON.parse(r.output_json) }));
      const audit = auditStoredReviewedCurrentCandidate({ expected, snapshot, modelRuns });
      const prices = db.prepare("SELECT * FROM valuation_pit_price_observations WHERE ticker=?").all(candidate.ticker);
      const quote = expected.modelRuns[0].priceObservation;
      const p = prices[0];
      if (prices.length !== 1 || p.fiscal_period !== expected.modelRuns[0].fiscalPeriod || p.price_symbol !== candidate.ticker ||
        p.price_date !== quote.priceDate || p.close !== quote.close || p.quote_currency !== quote.quoteCurrency || p.source !== quote.source ||
        sha(JSON.parse(p.payload_json)) !== sha(quote.payload)) audit.failures.push({ ticker: candidate.ticker, code: "current_comparison_price_observation_changed" });
      for (const key of ["currentSourceBinding", "financialPeriodDispositions", "pitFinancialRows"]) if (sha(snapshot?.dataQuality?.[key] ?? null) !== sha(expected.snapshot.dataQuality[key])) audit.failures.push({ ticker: candidate.ticker, code: `current_financial_disposition_changed:${key}` });
      audit.status = audit.failures.length ? "fail" : "pass";
      results.push(audit); failures.push(...audit.failures);
      if (!audit.failures.length) candidates.set(candidate.ticker, expected);
    } catch (error) { failures.push({ ticker: candidate.ticker, code: "current_source_replay_or_binding_failed", reason: error.message }); }
  }
  const actual = db.prepare("SELECT ticker FROM valuation_ticker_snapshots WHERE json_extract(payload_json,'$.dataQuality.currentOnly')=1").all().map(r => r.ticker).sort();
  if (JSON.stringify(actual) !== JSON.stringify(loaded.candidates.map(c => c.ticker).sort())) failures.push({ code: "unexpected_current_only_scope", actual });
  return { candidates, results, failures };
}

/** Replace only exact, already independently checked old-quarter dispositions.
 * Count closure, all unrelated issuers and unexpected periods remain enforced. */
export function applyReviewedCurrentPeriodDispositions(audit, candidates) {
  const gaps = audit.gaps.map(gap => {
    const candidate = candidates.get(gap.ticker);
    if (!candidate) return gap;
    const row = candidate.snapshot.dataQuality.financialPeriodDispositions.find(r => r.fiscalPeriod === gap.fiscalPeriod);
    if (!row || row.status !== "explicitly_unmodeled") return { ...gap, reason: "current_only_unmatched_financial_period", unexpectedlyModelable: true };
    return { ...gap, reason: row.reason, unexpectedlyModelable: false, currentOnlySourceBinding: row };
  });
  const reasonCounts = {};
  for (const row of gaps) reasonCounts[row.reason] = (reasonCounts[row.reason] || 0) + 1;
  return { ...audit, gaps, reasonCounts, unexpected: gaps.filter(r => r.unexpectedlyModelable) };
}
