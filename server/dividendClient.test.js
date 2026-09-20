import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import test from "node:test";

process.env.SQLITE_DB_PATH = path.join(os.tmpdir(), `guru-dividend-test-${process.pid}.sqlite`);
process.env.SYNC_BUNDLED_VALUATION_SNAPSHOTS = "false";
process.env.SYNC_BUNDLED_DIVIDEND_CALENDAR = "false";

const { __dividendTestInternals } = await import("./dividendClient.js");

const { isLondonDividendTicker, normalizeDividendMoneyUnit, safeHoldingQuantity } =
  __dividendTestInternals;

test("AZN is treated as a London ordinary-share dividend ticker", () => {
  assert.equal(isLondonDividendTicker("AZN"), true);
  assert.equal(isLondonDividendTicker("AZN.L"), true);
});

test("London pence dividends are normalized before payout math", () => {
  assert.deepEqual(
    normalizeDividendMoneyUnit({
      ticker: "AZN",
      amount: 159.5,
      currency: "GBP",
      source: "london_dividend_history"
    }),
    { amount: 1.595, currency: "GBP", multiplier: 0.01, normalizedFrom: "GBP" }
  );

  assert.deepEqual(
    normalizeDividendMoneyUnit({
      ticker: "AZN.L",
      amount: 159.5,
      currency: "GBp",
      source: "london_dividend_history"
    }),
    { amount: 1.595, currency: "GBP", multiplier: 0.01, normalizedFrom: "GBp" }
  );

  assert.deepEqual(
    normalizeDividendMoneyUnit({
      ticker: "HSBA",
      amount: 103,
      currency: "GBP",
      source: "london_dividend_history"
    }),
    { amount: 1.03, currency: "GBP", multiplier: 0.01, normalizedFrom: "GBP" }
  );
});

test("normal GBP and USD amounts are not divided by 100", () => {
  assert.deepEqual(
    normalizeDividendMoneyUnit({
      ticker: "AZN",
      amount: 1.595,
      currency: "GBP",
      source: "london_dividend_history"
    }),
    { amount: 1.595, currency: "GBP", multiplier: 1, normalizedFrom: "" }
  );

  assert.deepEqual(
    normalizeDividendMoneyUnit({
      ticker: "V",
      amount: 6,
      currency: "USD",
      source: "london_dividend_history"
    }),
    { amount: 6, currency: "USD", multiplier: 1, normalizedFrom: "" }
  );
});

test("GBP holding prices only use pence when it explains market value", () => {
  assert.equal(
    Math.round(
      safeHoldingQuantity({
        ticker: "AZN",
        quantity: 100,
        price: 12000,
        value: 15240,
        currency: "GBP",
        fxRateToBase: 1.27
      })
    ),
    100
  );

  assert.equal(
    Math.round(
      safeHoldingQuantity({
        ticker: "UKHIGH",
        quantity: 10,
        price: 150,
        value: 1905,
        currency: "GBP",
        fxRateToBase: 1.27
      })
    ),
    10
  );
});
