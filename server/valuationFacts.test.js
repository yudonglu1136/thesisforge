import test from "node:test";
import assert from "node:assert/strict";
import { overlayValuationFacts, loadCanonicalValuationDetail, loadCanonicalValuationDashboard, financialDisplay } from "./valuationFacts.js";

function sample() {
  return { ticker: "MSFT", currency: "USD", latest: { latestPrice: 900, latestPriceDate: "2030-01-01",
    latestPriceSource: "yahoo", baseFairValue: 120, targetPrice3Y: 133.1, valuationAnchorDate: "2020-01-04", valuationAnchorPrice: 900 },
    priceHistory: [{ date: "2030-01-01", close: 900, source: "yahoo" }],
    history: [{ asOfDate: "2020-01-04", fairValue: 120, targetPrice3Y: 133.1,
      currentPrice: 900, priceAtDate: 900, dataSnapshot: { fiscalFinancials: { revenue_m: 42 }, valuationSemantics: { version: "original" } } }] };
}

test("canonical quoted prices replace old quotes without changing recorded model inputs", () => {
  const original = sample();
  const result = overlayValuationFacts(original, { asOf: "2020-01-05", prices: [
    { date: "2020-01-03", value: 100 }, { date: "2020-01-06", value: 300 }
  ], quarterly: [{ reportperiod: "2019-12-31", available_at: "2020-01-04", revenue: 12 }],
  trailing: [{ reportperiod: "2019-12-31", available_at: "2020-01-04", revenue: 50 }] });
  assert.equal(result.latest.latestPrice, 100);
  assert.equal(result.latest.latestPriceSource, "Sharadar Local Fact OS");
  assert.equal(result.history[0].priceAtDate, 100);
  assert.equal(result.history[0].fairValue, 120);
  assert.deepEqual(result.history[0].dataSnapshot.fiscalFinancials, original.history[0].dataSnapshot.fiscalFinancials);
  assert.equal(result.history[0].dataSnapshot.role, "archived_model_inputs");
  assert.equal(result.currentFinancials.trailingTwelveMonths.revenue, 50);
  assert.equal(result.priceHistory.length, 1);
  assert.equal(original.latest.latestPrice, 900);
});

test("missing facts never fall back to embedded Yahoo or financial snapshot", () => {
  const result = overlayValuationFacts(sample(), { asOf: "2020-01-05" });
  assert.equal(result.latest.latestPrice, null);
  assert.equal(result.latest.upsideToBase, null);
  assert.equal(result.history[0].currentPrice, null);
  assert.deepEqual(result.priceHistory, []);
  assert.equal(result.currentFinancials.status, "missing");
  assert.equal(result.latest.baseFairValue, 120);
});

test("foreign quoted currency cannot silently use a US ADR quote", () => {
  const result = overlayValuationFacts({ ...sample(), ticker: "AZN", currency: "GBP" }, {
    prices: [{ date: "2020-01-03", value: 100 }], asOf: "2020-01-05"
  });
  assert.equal(result.latest.latestPrice, null);
  assert.ok(result.dataQuality.factErrors.includes("quoted_security_currency_not_supported"));
});

test("detail dispatches local AR queries with cutoff and explicit raw-price basis", async () => {
  let requests;
  const result = await loadCanonicalValuationDetail(sample(), { asOf: "2020-01-05", readBatch: async batch => {
    requests = batch;
    return [{ ok: true, result: [{ date: "2020-01-03", value: 100 }] },
      { ok: false, error: { code: "local_data_unavailable" } }, { ok: true, result: [] }];
  } });
  assert.equal(requests[0].args[3], "RAW_CLOSE");
  assert.equal(requests[0].kwargs.dataset, "auto");
  assert.equal(requests.filter(r => r.method === "get_price_history").length, 1);
  assert.equal(requests[1].args[1], "ARQ");
  assert.equal(requests[2].args[1], "ART");
  assert.equal(requests[1].kwargs.as_of, "2020-01-05");
  assert.ok(result.dataQuality.factErrors.includes("local_data_unavailable"));
  assert.equal(result.latest.latestPrice, 100);
});

test("dashboard uses one batch and never treats latest quote as model-date quote", async () => {
  let calls = 0;
  const rows = await loadCanonicalValuationDashboard([sample()], { asOf: "2020-01-05", readBatch: async requests => {
    calls += 1;
    assert.equal(requests[0].method, "get_prices");
    assert.deepEqual(requests[0].args, [["MSFT"], "2020-01-05", "RAW_CLOSE"]);
    return [{ ok: true, result: { MSFT: { date: "2020-01-03", value: 100 } } }, { ok: true, result: {} }];
  } });
  assert.equal(calls, 1);
  assert.equal(rows[0].latest.latestPrice, 100);
  assert.equal(rows[0].latest.valuationAnchorPrice, null);
});

test("ETF quote uses official master routing once with no cross-dataset fallback", async () => {
  const rows = await loadCanonicalValuationDashboard([{ ...sample(), ticker: "SPY" }], { asOf: "2020-01-05", readBatch: async requests => {
    assert.equal(requests[0].kwargs.dataset, "auto");
    assert.equal(requests[0].args[2], "RAW_CLOSE");
    assert.equal(requests.filter(r => r.method === "get_prices").length, 1);
    return [{ ok: true, result: { SPY: { date: "2020-01-03", value: 200 } } },
      { ok: true, result: { SPY: null } }];
  } });
  assert.equal(rows[0].latest.latestPrice, 200);
  assert.equal(rows[0].latest.latestPriceSource, "Sharadar Local Fact OS");
});

test("financial display uses ART once, quarterly YoY, explicit USD conversion and nulls", () => {
  const result = financialDisplay({ asOf: "2020-05-01", quarterly: [
    { reportperiod: "2019-03-31", calendardate: "2019-03-31", available_at: "2019-04-15", revenueusd: 100e6 },
    { reportperiod: "2020-03-31", calendardate: "2020-03-31", available_at: "2020-04-15", revenueusd: 120e6 },
    { reportperiod: "2020-03-31", calendardate: "2020-03-31", available_at: "2020-06-01", revenueusd: 999e6 }
  ], trailing: [
    { reportperiod: "2020-03-31", available_at: "2020-04-15", revenueusd: 450e6, revenue: 900e6,
      ncfo: 180e6, capex: -30e6, opinc: 270e6, fxusd: 2, shareswadil: 20e6, sharefactor: .5 }
  ] });
  assert.equal(result.revenueM, 450);
  assert.ok(Math.abs(result.quarterlyRevenueGrowthRatio - .2) < 1e-10);
  assert.equal(result.freeCashFlowM, 75);
  assert.equal(result.operatingMarginRatio, .3);
  assert.equal(result.freeCashFlowMarginRatio, 1 / 6);
  assert.equal(result.dilutedShareEquivalentsM, 10);
  assert.equal(result.currency, "USD");
  assert.equal(result.dimension, "ART");
});

test("financial display never invents FX, prior revenue or future period facts", () => {
  const result = financialDisplay({ asOf: "2020-05-01", trailing: [
    { reportperiod: "2020-03-31", available_at: "2020-04-15", revenue: 900e6, ncfo: 180e6, capex: -30e6 },
    { reportperiod: "2020-06-30", available_at: "2020-04-15", revenueusd: 999e6 }
  ] });
  assert.equal(result.periodEnd, "2020-03-31");
  assert.equal(result.revenueM, null);
  assert.equal(result.quarterlyRevenueGrowthRatio, null);
  assert.equal(result.freeCashFlowM, null);
  assert.equal(result.dilutedShareEquivalentsM, null);
});
