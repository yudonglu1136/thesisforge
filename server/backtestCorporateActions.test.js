import assert from "node:assert/strict";
import test from "node:test";

import {
  buildManager13fWeights,
  manager13fPriceRequirements
} from "./backtest.js";

function holding({
  ticker,
  priceSymbol,
  priceSymbolAudit,
  cusip,
  issuer = ticker,
  value,
  shares = 1_000
}) {
  return {
    ticker,
    ...(priceSymbol ? { priceSymbol } : {}),
    ...(priceSymbolAudit ? { priceSymbolAudit } : {}),
    cusip,
    issuer,
    title: "COM",
    shareType: "SH",
    putCall: "",
    value,
    shares
  };
}

test("Pabrai FCAU identity uses only its audited Sharadar STLA price symbol", () => {
  const fca = holding({
    ticker: "FCAU",
    priceSymbol: "STLA",
    priceSymbolAudit: {
      provider: "Sharadar SEP",
      rule: "provider_canonical_ticker_contains_pre_rename_history"
    },
    cusip: "N31738102",
    issuer: "FIAT CHRYSLER AUTOMOBILES N",
    value: 100
  });
  const snapshot = { reportDate: "2019-12-31", holdings: [fca] };

  assert.deepEqual(
    manager13fPriceRequirements(snapshot, "2020-02-18", {
      guruId: "mohnish-pabrai"
    }),
    [{ ticker: "STLA" }]
  );

  const model = buildManager13fWeights(snapshot, new Map([
    ["FCAU", new Map()],
    ["STLA", new Map([["2020-02-18", 13.42]])]
  ]), "2020-02-18", { guruId: "mohnish-pabrai" });

  assert.equal(model.coveragePct, 1);
  assert.equal(model.weights[0].ticker, "FCAU");
  assert.equal(model.weights[0].priceSymbol, "STLA");
  assert.equal(model.weights[0].priceSymbolAudit.provider, "Sharadar SEP");
  assert.deepEqual(model.unpricedPositions, []);
});

test("TWTR acquired after quarter-end but before execution becomes audited cash", () => {
  const weights = buildManager13fWeights({
    reportDate: "2022-09-30",
    holdings: [
      holding({ ticker: "AAPL", cusip: "037833100", value: 80 }),
      holding({ ticker: "TWTR", cusip: "90184L102", value: 20 })
    ]
  }, new Map([
    ["AAPL", new Map([["2022-11-15", 150]])],
    ["TWTR", new Map()]
  ]), "2022-11-15", { guruId: "dan-loeb" });

  assert.equal(weights.coveragePct, 1);
  assert.equal(weights.pricedValue, 80);
  assert.equal(weights.cashSettledValue, 20);
  assert.equal(weights.executionResolvedValue, 100);
  assert.ok(Math.abs(weights.cashWeight - 0.2) < 1e-12);
  assert.ok(Math.abs(weights.corporateActionCashWeight - 0.2) < 1e-12);
  assert.equal(weights.pricedPositions, 1);
  assert.equal(weights.cashSettledPositions, 1);
  assert.deepEqual(weights.unpricedPositions, []);
  assert.equal(weights.corporateActionResolutions[0].actionId, "twitter-x-holdings-2022");
  assert.equal(weights.corporateActionResolutions[0].reportedBookWeight, 0.2);
  assert.equal(weights.corporateActionResolutions[0].modeledPreDisclosureReturn, 0);
});

test("CHNG held before closing remains priced and carries its future cash action", () => {
  const weights = buildManager13fWeights({
    reportDate: "2022-06-30",
    holdings: [holding({
      ticker: "CHNG",
      cusip: "15912K100",
      issuer: "Change Healthcare Inc.",
      value: 100
    })]
  }, new Map([
    ["CHNG", new Map([["2022-08-15", 24.50]])]
  ]), "2022-08-15", { guruId: "david-einhorn" });

  assert.equal(weights.coveragePct, 1);
  assert.equal(weights.cashSettledPositions, 0);
  assert.equal(weights.weights[0].corporateAction.actionId, "change-healthcare-unitedhealth-2022");
  assert.equal(weights.weights[0].corporateAction.terminalCashPrice, 25.75);
  assert.equal(weights.weights[0].corporateAction.additionalCashPerShare, 2);
  assert.equal(weights.weights[0].corporateAction.terminalCashEntitlementPerShare, 27.75);
});

test("ARCH converted before execution requires CNR and does not fabricate ARCH cash", () => {
  const weights = buildManager13fWeights({
    reportDate: "2024-09-30",
    holdings: [holding({
      ticker: "ARCH",
      cusip: "03940R107",
      issuer: "Arch Resources, Inc.",
      value: 100
    })]
  }, new Map([
    ["ARCH", new Map()],
    ["CNR", new Map([["2025-02-14", 80]])]
  ]), "2025-02-14", { guruId: "mohnish-pabrai" });

  assert.equal(weights.coveragePct, 1);
  assert.equal(weights.cashSettledPositions, 0);
  assert.equal(weights.weights[0].ticker, "CNR");
  assert.equal(weights.weights[0].corporateAction, undefined);
  assert.equal(weights.weights[0].corporateActionResolution.actionType, "stock_conversion");
  assert.equal(weights.corporateActionResolutions[0].successorSharesPerShare, 1.326);
});

test("Trian JHG private rollover stays unpriced and cannot pass as a cash action", () => {
  const weights = buildManager13fWeights({
    reportDate: "2026-06-30",
    holdings: [holding({
      ticker: "JHG",
      cusip: "G4474Y214",
      issuer: "Janus Henderson Group plc",
      value: 100
    })]
  // Even if a provider accidentally recycles or carries a stale JHG quote,
  // the exact holder/quarter limitation takes precedence over that number.
  }, new Map([["JHG", new Map([["2026-08-17", 99]])]]), "2026-08-17", {
    guruId: "nelson-peltz"
  });

  assert.equal(weights.coveragePct, 0);
  assert.equal(weights.cashSettledPositions, 0);
  assert.equal(weights.pricedPositions, 0);
  assert.equal(weights.corporateActionResolutions.length, 0);
  assert.equal(
    weights.unpricedPositions[0].reason,
    "reported_security_private_before_execution"
  );
  assert.equal(weights.unpricedPositions[0].executionLimitation.syntheticPriceUsed, false);
});

test("Trian's prior JHG holding requires public prices only through June 30", () => {
  const requirements = manager13fPriceRequirements({
    reportDate: "2026-03-31",
    holdings: [holding({
      ticker: "JHG",
      cusip: "G4474Y214",
      issuer: "Janus Henderson Group plc",
      value: 100
    })]
  }, "2026-05-18", { guruId: "nelson-peltz" });

  assert.deepEqual(requirements, [{
    ticker: "JHG",
    endExclusive: "2026-07-01"
  }]);
});

test("active TWTR requires its October 27 public close before cash conversion", () => {
  const requirements = manager13fPriceRequirements({
    reportDate: "2022-06-30",
    holdings: [holding({
      ticker: "TWTR",
      cusip: "90184L102",
      issuer: "Twitter, Inc.",
      value: 100
    })]
  }, "2022-08-15", { guruId: "david-tepper" });

  assert.deepEqual(requirements, [{
    ticker: "TWTR",
    endExclusive: "2022-10-28"
  }]);
});

test("active ROKU carries FOXA + $95.30 mixed conversion starting Nov 9, 2026", () => {
  const snapshot = {
    reportDate: "2026-06-30",
    holdings: [holding({
      ticker: "ROKU",
      cusip: "77543R102",
      issuer: "Roku, Inc.",
      value: 100
    })]
  };
  const requirements = manager13fPriceRequirements(snapshot, "2026-08-14", {
    guruId: "renaissance-technologies"
  });
  assert.deepEqual(requirements, [
    { ticker: "ROKU", endExclusive: "2026-11-09" },
    { ticker: "FOXA", startInclusive: "2026-11-09" }
  ]);

  const weights = buildManager13fWeights(snapshot, new Map([
    ["ROKU", new Map([["2026-08-14", 98.5]])],
    ["FOXA", new Map([["2026-11-09", 67.69]])]
  ]), "2026-08-14", { guruId: "renaissance-technologies" });
  assert.equal(weights.coveragePct, 1);
  assert.equal(weights.weights[0].corporateAction.actionId, "roku-fox-2026");
  assert.equal(weights.weights[0].corporateAction.considerationType, "stock_and_cash");
  assert.equal(weights.weights[0].corporateAction.successorTicker, "FOXA");
  assert.equal(weights.weights[0].corporateAction.successorSharesPerShare, 0.9799);
  assert.equal(weights.weights[0].corporateAction.terminalCashEntitlementPerShare, 95.30);
});
