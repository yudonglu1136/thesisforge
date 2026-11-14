import assert from "node:assert/strict";
import test from "node:test";

import {
  activeCashAcquisition,
  activeStockConversion,
  cashAcquisitionForHolding,
  manager13fCorporateActionCatalogVersion,
  preExecutionCashAcquisition,
  preExecutionStockConversion,
  stockConversionForHolding
} from "./corporateActions.js";

test("TWTR and CHNG cash mergers resolve only by exact CUSIP", () => {
  const twitter = preExecutionCashAcquisition(
    { cusip: "90184L102", ticker: "TWTR" },
    { reportDate: "2022-09-30", executionDate: "2022-11-15" }
  );
  const change = preExecutionCashAcquisition(
    { cusip: "15912K100", ticker: "CHNG" },
    { reportDate: "2022-09-30", executionDate: "2022-11-15" }
  );

  assert.equal(twitter?.effectiveDate, "2022-10-27");
  assert.equal(twitter?.publicTradingEndExclusive, "2022-10-28");
  assert.equal(twitter?.consideration.amountPerShare, 54.20);
  assert.equal(change?.effectiveDate, "2022-10-03");
  assert.equal(change?.consideration.amountPerShare, 25.75);
  assert.equal(change?.consideration.additionalCashPerShare, 2.00);
  assert.equal(change?.consideration.totalCashEntitlementPerShare, 27.75);
  assert.equal(cashAcquisitionForHolding({ ticker: "TWTR" }), null);
  assert.match(manager13fCorporateActionCatalogVersion, /^manager13f-corporate-actions-v1-[a-f0-9]{16}$/);
});

test("TWTR keeps its genuine October 27 close before the October 28 cash transition", () => {
  const holding = { cusip: "90184L102", ticker: "TWTR" };
  assert.equal(preExecutionCashAcquisition(holding, {
    reportDate: "2022-06-30",
    executionDate: "2022-10-27"
  }), null);
  assert.equal(activeCashAcquisition(holding, {
    executionDate: "2022-10-27"
  })?.publicTradingEndExclusive, "2022-10-28");
  assert.equal(preExecutionCashAcquisition(holding, {
    reportDate: "2022-06-30",
    executionDate: "2022-10-28"
  })?.consideration.totalCashEntitlementPerShare, 54.20);
});

test("an acquisition after execution is an active settlement, not pre-execution cash", () => {
  const holding = { cusip: "15912K100", ticker: "CHNG" };
  assert.equal(preExecutionCashAcquisition(holding, {
    reportDate: "2022-06-30",
    executionDate: "2022-08-15"
  }), null);
  assert.equal(activeCashAcquisition(holding, {
    executionDate: "2022-08-15"
  })?.effectiveDate, "2022-10-03");
});

test("private rollover and non-cash consideration never enter the cash path", () => {
  const holding = { cusip: "90184L102", ticker: "TWTR" };
  assert.equal(cashAcquisitionForHolding(holding, {
    holderHasPrivateRollover: true
  }), null);
  assert.equal(cashAcquisitionForHolding(holding, {
    actions: [{
      id: "synthetic-private-rollover",
      cusip: "90184L102",
      ticker: "TWTR",
      actionType: "private_rollover",
      effectiveDate: "2022-10-27",
      consideration: {
        type: "private_equity",
        amountPerShare: 54.20,
        additionalCashPerShare: 0,
        totalCashEntitlementPerShare: 54.20,
        currency: "USD"
      },
      publicShareScope: "negotiated_rollover_holders_only",
      sources: ["https://www.sec.gov/"]
    }]
  }), null);
});

test("ARCH resolves as an exact stock conversion and never as terminal cash", () => {
  const holding = { cusip: "03940R107", ticker: "ARCH" };
  assert.equal(cashAcquisitionForHolding(holding), null);
  assert.equal(preExecutionStockConversion(holding, {
    reportDate: "2024-09-30",
    executionDate: "2025-02-14"
  })?.consideration.successorTicker, "CNR");
  assert.equal(activeStockConversion(holding, {
    executionDate: "2024-11-15"
  })?.consideration.successorSharesPerShare, 1.326);
  assert.equal(stockConversionForHolding({ ticker: "ARCH" }), null);
  assert.equal(stockConversionForHolding(holding, {
    holderHasPrivateRollover: true
  }), null);
});

test("ROKU resolves as an exact stock-and-cash conversion after Nov 6, 2026 close", () => {
  const holding = { cusip: "77543R102", ticker: "ROKU" };
  assert.equal(cashAcquisitionForHolding(holding), null);
  const active = activeStockConversion(holding, { executionDate: "2026-08-14" });
  assert.equal(active?.id, "roku-fox-2026");
  assert.equal(active?.effectiveDate, "2026-11-09");
  assert.equal(active?.consideration.type, "stock_and_cash");
  assert.equal(active?.consideration.successorTicker, "FOXA");
  assert.equal(active?.consideration.successorSharesPerShare, 0.9799);
  assert.equal(active?.consideration.totalCashEntitlementPerShare, 95.30);
});
