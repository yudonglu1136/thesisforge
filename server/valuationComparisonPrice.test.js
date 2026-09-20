import test from "node:test";
import assert from "node:assert/strict";
import {
  valuationComparisonPriceContract, resolveValuationComparisonPrice,
  auditValuationComparisonPrice, selectValuationComparisonPrice, comparisonPricesEqual,
  mergeValuationComparisonHistory
} from "./valuationComparisonPrice.js";

// Synthetic prices only; licensed historical rows stay outside the repository.
const PAID = "jansen-sharadar-sep-split-adjusted";
const point = (overrides = {}) => ({
  id: "paid-snapshot", kind: "released_snapshot", source: PAID,
  date: "2020-05-01", priceSymbol: "SYNTH", close: 200,
  quoteCurrency: "USD", unit: "currency_per_share", sourceField: "close", ...overrides
});
const request = (overrides = {}) => ({
  asOfDate: "2020-05-04", priceDate: "2020-05-01", priceSymbol: "SYNTH",
  quoteCurrency: "USD", declaredSource: PAID, candidates: [point()], ...overrides
});

test("history merge rejects an unsupported provider instead of mixing vintages", () => {
  const existing = [{ date: "2020-05-01", close: 200, source: PAID }];
  const incremental = [{ date: "2020-05-01", close: 153, source: "unsupported" }];
  const before = JSON.stringify({ existing, incremental });
  assert.throws(() => mergeValuationComparisonHistory({ existing, incremental, priceSymbol: "SYNTH", quoteCurrency: "USD" }), /Unverified/);
  assert.equal(JSON.stringify({ existing, incremental }), before);
});

test("history merge fails on same-series conflict or unverifiable source", () => {
  const existing = [{ date: "2020-05-01", close: 200, source: PAID }];
  for (const [source, close] of [[PAID, 153], ["sharadar-paid-api-split-adjusted", 153], ["unsupported-merged", 200]]) {
    assert.throws(() => mergeValuationComparisonHistory({ existing,
      incremental: [{ date: "2020-05-01", close, source }], priceSymbol: "SYNTH", quoteCurrency: "USD"
    }), /same_series_price_conflict|Unverified comparison-price source/);
  }
});

test("history merge never silently enables an unsupported provider", () => {
  const existing = [{ date: "2020-05-01", close: 20, source: "unsupported" }];
  assert.throws(() => mergeValuationComparisonHistory({ existing, priceSymbol: "SYNTH.L", quoteCurrency: "GBP" }), /Unverified/);
});

test("source contracts distinguish raw provider close from adjusted_close", () => {
  assert.equal(valuationComparisonPriceContract(PAID).basis, "split_adjusted_ex_cash_dividends_and_spinoffs");
  for (const source of ["paid", "audited:unknown", "unsupported", "toString"]) {
    assert.equal(valuationComparisonPriceContract(source), null);
  }
});

test("expected source is fixed before inspecting output, not raw-storage-first", () => {
  const candidates = [point({ id: "guru", kind: "raw_price_point", source: "unsupported", close: 153 }), point()];
  const resolved = resolveValuationComparisonPrice(request({ candidates }));
  assert.equal(resolved.expectedPrice, 200);
  assert.equal(resolved.excluded[0].reason, "unverified_candidate_source");
  assert.equal(auditValuationComparisonPrice({ ...request({ candidates }), outputPrice: 200 }).status, "ready");
  assert.equal(auditValuationComparisonPrice({ ...request({ candidates }), outputPrice: 153 }).reason, "stored_market_price_unit_mismatch");
  assert.equal(auditValuationComparisonPrice({ ...request({ candidates }), outputPrice: 999 }).reason, "stored_market_price_unit_mismatch");
});

test("unsupported-only history fails closed", () => {
  const result = resolveValuationComparisonPrice(request({
    declaredSource: "unsupported", candidates: [point(), point({ id: "raw", source: "unsupported", close: 153 })]
  }));
  assert.equal(result.status, "blocked");
  assert.equal(result.reason, "unverified_declared_price_source");
});

test("a claimed source without a real row fails even if another provider matches", () => {
  assert.equal(resolveValuationComparisonPrice(request({ candidates: [point({ source: "unsupported" })] })).reason, "declared_price_source_unreconciled");
  assert.equal(resolveValuationComparisonPrice(request({ declaredSource: "unreviewed" })).reason, "unverified_declared_price_source");
});

test("same-series conflict remains a blocker including different paid ingestion paths", () => {
  for (const source of [PAID, "sharadar-paid-api-split-adjusted", "audited:sharadar-paid-api"]) {
    const result = resolveValuationComparisonPrice(request({ candidates: [point(), point({ id: "conflict", source, close: 200.01 })] }));
    assert.equal(result.reason, "same_series_price_conflict");
  }
});

test("fixed tight tolerance is not expanded for rounding or provider discrepancies", () => {
  assert.equal(comparisonPricesEqual(20, 20.000001), true);
  assert.equal(comparisonPricesEqual(20, 20.0005), false);
  assert.equal(comparisonPricesEqual(20, NaN), false);
});

test("all corroborating pairs must agree, not just each one with the preferred row", () => {
  const candidates = [point({ close: 1, id: "a", kind: "original_vendor" }), point({ close: 1 + 9e-8, id: "b" }), point({ close: 1 - 9e-8, id: "c" })];
  assert.equal(resolveValuationComparisonPrice(request({ candidates })).reason, "same_series_price_conflict");
});

test("date, currency, units, field and storage metadata fail closed", () => {
  for (const [change, reason] of [
    [{ quoteCurrency: "GBP" }, "price_currency_mismatch"],
    [{ unit: "pence_per_share" }, "price_unit_mismatch"],
    [{ sourceField: "adjusted_close" }, "price_source_field_mismatch"],
    [{ sourceField: "closeadj" }, "price_source_field_mismatch"],
    [{ close: 0 }, "invalid_source_price"],
    [{ close: "200" }, "invalid_source_price"],
    [{ close: Infinity }, "invalid_source_price"],
    [{ kind: "model_output" }, "unverified_price_storage_kind"],
    [{ payloadSource: "unsupported" }, "price_payload_source_mismatch"]
  ]) assert.equal(resolveValuationComparisonPrice(request({ candidates: [point(change)] })).reason, reason);
  assert.equal(resolveValuationComparisonPrice(request({ priceDate: "2020-05-05" })).reason, "future_price_date");
  assert.equal(resolveValuationComparisonPrice(request({ priceDate: "2020-02-31" })).reason, "invalid_price_date");
  assert.equal(resolveValuationComparisonPrice(request({ quoteCurrency: "GBX" })).reason, "invalid_quote_currency");
});

test("GBP and .L remain quoted units with no double division", () => {
  const result = resolveValuationComparisonPrice(request({
    priceSymbol: "SYNTH.L", quoteCurrency: "GBP",
    candidates: [point({ priceSymbol: "SYNTH.L", quoteCurrency: "GBP", close: 125 })]
  }));
  assert.equal(result.expectedPrice, 125);
});

test("PIT observations are bound to ticker, fiscal period AND exact model version", () => {
  const scope = { ticker: "SYNTH", fiscalPeriod: "2020-Q1", modelVersion: "v1" };
  const candidate = point({ ...scope, kind: "pit_observation" });
  assert.equal(resolveValuationComparisonPrice(request({ ...scope, candidates: [candidate] })).status, "ready");
  for (const key of Object.keys(scope)) {
    const result = resolveValuationComparisonPrice(request({ ...scope, candidates: [{ ...candidate, [key]: "wrong" }] }));
    assert.equal(result.reason, "declared_price_source_unreconciled");
    assert.equal(result.excluded[0].reason, `pit_${key}_mismatch`);
  }
});

test("unrelated symbols or dates never prove source lineage", () => {
  for (const changes of [{ priceSymbol: "OTHER" }, { date: "2020-04-30" }]) {
    assert.equal(resolveValuationComparisonPrice(request({ candidates: [point(changes)] })).reason, "declared_price_source_unreconciled");
  }
});

test("proof ordering is deterministic and does not modify candidates", () => {
  const candidates = [point({ id: "raw", kind: "raw_price_point" }), point({ id: "original", kind: "original_vendor" })];
  const copy = structuredClone(candidates);
  const a = resolveValuationComparisonPrice(request({ candidates }));
  const b = resolveValuationComparisonPrice(request({ candidates: [...candidates].reverse() }));
  assert.deepEqual(a, b);
  assert.deepEqual(candidates, copy);
  assert.equal(a.selectedEvidenceId, "original");
  assert.equal(a.priceExcludedFromFairValue, true);
});

test("new import policy chooses latest paid observation without unsupported-provider value matching", () => {
  const candidates = [point({ date: "2020-04-30", close: 190 }), point(), point({ date: "2020-05-04", source: "unsupported", close: 300 })];
  const result = selectValuationComparisonPrice(request({ candidates, policy: { mode: "prefer_sharadar_split_only" }, maxAgeCalendarDays: 4 }));
  assert.equal(result.priceDate, "2020-05-01");
  assert.equal(result.expectedPrice, 200);
  assert.equal(result.ageCalendarDays, 3);
});

test("new import has no hidden provider fallback, price policy, or staleness tolerance", () => {
  assert.equal(selectValuationComparisonPrice(request()).reason, "missing_explicit_maximum_price_age");
  assert.equal(selectValuationComparisonPrice(request({ maxAgeCalendarDays: 4 })).reason, "missing_explicit_price_policy");
  assert.equal(selectValuationComparisonPrice(request({ policy: { mode: "prefer_sharadar_split_only" }, maxAgeCalendarDays: 2 })).reason, "stale_comparison_price");
  assert.equal(selectValuationComparisonPrice(request({ candidates: [point({ source: "unsupported" })], policy: { mode: "prefer_sharadar_split_only" }, maxAgeCalendarDays: 4 })).reason, "no_price_for_explicit_policy");
  const explicit = selectValuationComparisonPrice(request({ candidates: [point({ source: "unsupported" })], policy: { mode: "declared_provider_close", source: "unsupported" }, maxAgeCalendarDays: 4 }));
  assert.equal(explicit.status, "blocked");
  assert.equal(explicit.reason, "missing_explicit_price_policy");
});
