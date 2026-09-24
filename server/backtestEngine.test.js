import assert from "node:assert/strict";
import test from "node:test";

import {
  adjustedClosePriceMap,
  filingExecutionDecision,
  nextTradingSessionAfter,
  resolveTrailingCommonPriceEnd,
  simulateDriftedPortfolio
} from "./backtestEngine.js";

function map(rows) {
  return new Map(rows);
}

test("13F execution is always on the first session strictly after public acceptance date", () => {
  const sessions = ["2024-05-16", "2024-05-17", "2024-05-20", "2024-05-21"];
  assert.equal(nextTradingSessionAfter(sessions, "2024-05-17T08:00:00-04:00"), "2024-05-20");
  assert.equal(nextTradingSessionAfter(sessions, "2024-05-17T18:00:00-04:00"), "2024-05-20");

  const accepted = filingExecutionDecision({
    filingDate: "2024-05-17",
    acceptanceDateTime: "2024-05-17T18:00:00-04:00"
  }, sessions);
  assert.equal(accepted.executionDate, "2024-05-20");
  assert.equal(accepted.executionTimestampSource, "sec_acceptance_datetime");
  assert.equal(accepted.usedLegacyFilingDateFallback, false);

  const legacy = filingExecutionDecision({ filingDate: "2024-05-17" }, sessions);
  assert.equal(legacy.executionDate, "2024-05-20");
  assert.equal(legacy.executionTimestampSource, "legacy_filing_date");
  assert.equal(legacy.usedLegacyFilingDateFallback, true);
});

test("drifted holdings produce one reconciled equity and attribution engine", () => {
  const tradingDates = ["2024-01-02", "2024-01-03", "2024-01-04", "2024-01-05"];
  const priceMaps = new Map([
    ["SPY", map([
      ["2024-01-02", 100], ["2024-01-03", 101], ["2024-01-04", 102], ["2024-01-05", 103]
    ])],
    ["A", map([
      ["2024-01-02", 100], ["2024-01-03", 110], ["2024-01-04", 120], ["2024-01-05", 132]
    ])],
    ["B", map([
      ["2024-01-02", 100], ["2024-01-03", 90], ["2024-01-04", 80], ["2024-01-05", 80]
    ])]
  ]);
  const rebalances = [
    {
      reportDate: "2023-12-31",
      filingDate: "2024-01-01",
      executionDate: "2024-01-02",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 2,
      pricedPositions: 2,
      weights: [
        { ticker: "A", issuer: "A", sector: "Technology", industry: "Software", value: 50, weight: 0.5 },
        { ticker: "B", issuer: "B", sector: "Financials", industry: "Banks", value: 50, weight: 0.5 }
      ]
    },
    {
      reportDate: "2024-03-31",
      filingDate: "2024-01-03",
      executionDate: "2024-01-04",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 1,
      pricedPositions: 1,
      weights: [{ ticker: "A", issuer: "A", sector: "Technology", industry: "Software", value: 100, weight: 1 }]
    }
  ];

  const result = simulateDriftedPortfolio({ rebalances, tradingDates, priceMaps });
  assert.equal(result.ok, true);
  assert.equal(result.equity.length, 4);
  assert.ok(Math.abs(result.equity[1].value - 1) < 1e-12);
  assert.ok(Math.abs(result.equity[2].value - 1) < 1e-12);
  assert.ok(Math.abs(result.equity[3].value - 1.1) < 1e-12);
  assert.equal(result.quarterContributions.length, 2);
  assert.equal(result.quarterContributions[0].endDate, "2024-01-04");
  assert.ok(Math.abs(result.quarterContributions[0].portfolioReturn) < 1e-12);
  assert.ok(Math.abs(result.quarterContributions[1].portfolioReturn - 0.1) < 1e-12);
  for (const quarter of result.quarterContributions) {
    const contributionSum = quarter.contributions.reduce(
      (sum, holding) => sum + holding.contributionPct,
      0
    );
    assert.ok(Math.abs(contributionSum - quarter.portfolioReturn) < 1e-12);
    assert.ok(Math.abs(quarter.attributionReconciliation) < 1e-12);
    assert.ok(Math.abs(quarter.sectorContributionReturn - quarter.portfolioReturn) < 1e-12);
    assert.ok(Math.abs(quarter.sectorAttributionReconciliation) < 1e-12);
    assert.ok(Math.abs(quarter.industryContributionReturn - quarter.portfolioReturn) < 1e-12);
    assert.ok(Math.abs(quarter.industryAttributionReconciliation) < 1e-12);
  }
  assert.deepEqual(result.quarterContributions[0].sectorContributions.map((row) => row.label), [
    "Technology",
    "Financials"
  ]);
  assert.ok(Math.abs(result.reconciliation.headlineTotalReturn - 0.1) < 1e-12);
  assert.ok(Math.abs(result.reconciliation.attributionTotalReturn - 0.1) < 1e-12);
  assert.ok(Math.abs(result.reconciliation.difference) < 1e-12);
});

test("provider price aliases do not relabel point-in-time holding identity", () => {
  const tradingDates = ["2020-02-18", "2020-02-19", "2020-02-20"];
  const priceMaps = new Map([
    ["SPY", map([
      ["2020-02-18", 100], ["2020-02-19", 101], ["2020-02-20", 102]
    ])],
    ["STLA", map([
      ["2020-02-18", 10], ["2020-02-19", 11], ["2020-02-20", 12]
    ])]
  ]);
  const rebalances = [{
    reportDate: "2019-12-31",
    filingDate: "2020-02-14",
    executionDate: "2020-02-18",
    coveragePct: 1,
    cashWeight: 0,
    selectedPositions: 1,
    pricedPositions: 1,
    weights: [{
      ticker: "FCAU",
      priceSymbol: "STLA",
      issuer: "FIAT CHRYSLER AUTOMOBILES N",
      value: 100,
      weight: 1
    }]
  }];

  const trailing = resolveTrailingCommonPriceEnd({
    rebalances,
    tradingDates,
    priceMaps,
    requestedEnd: "2020-02-20"
  });
  assert.deepEqual(trailing.activeTickers, ["STLA"]);
  assert.equal(trailing.reason, "requested_market_end_covered");

  const result = simulateDriftedPortfolio({ rebalances, tradingDates, priceMaps });
  assert.equal(result.ok, true);
  assert.ok(Math.abs(result.equity.at(-1).value - 1.2) < 1e-12);
  assert.equal(result.quarterContributions[0].contributions[0].ticker, "FCAU");
  assert.equal(result.quarterContributions[0].contributions[0].priceSymbol, "STLA");
});

test("unpriced execution weight remains cash rather than being renormalized", () => {
  const tradingDates = ["2024-01-02", "2024-01-03"];
  const priceMaps = new Map([
    ["SPY", map([["2024-01-02", 100], ["2024-01-03", 100]])],
    ["A", map([["2024-01-02", 100], ["2024-01-03", 110]])]
  ]);
  const result = simulateDriftedPortfolio({
    tradingDates,
    priceMaps,
    rebalances: [{
      reportDate: "2023-12-31",
      filingDate: "2024-01-01",
      executionDate: "2024-01-02",
      coveragePct: 0.8,
      cashWeight: 0.2,
      selectedPositions: 2,
      pricedPositions: 1,
      weights: [{ ticker: "A", issuer: "A", value: 80, weight: 0.8 }]
    }]
  });

  assert.equal(result.ok, true);
  assert.ok(Math.abs(result.equity.at(-1).value - 1.08) < 1e-12);
  assert.ok(Math.abs(result.quarterContributions[0].portfolioReturn - 0.08) < 1e-12);
  assert.equal(result.quarterContributions[0].cashWeight, 0.2);
});

test("adjusted-close mapping neutralizes a split and includes the total-return basis", () => {
  const securityMap = adjustedClosePriceMap([
    { date: "2024-01-02", close: 100, adjustedClose: 50 },
    { date: "2024-01-03", close: 50, adjustedClose: 50 }
  ]);
  const result = simulateDriftedPortfolio({
    tradingDates: ["2024-01-02", "2024-01-03"],
    priceMaps: new Map([
      ["SPY", map([["2024-01-02", 100], ["2024-01-03", 100]])],
      ["A", securityMap]
    ]),
    rebalances: [{
      reportDate: "2023-12-31",
      filingDate: "2024-01-01",
      executionDate: "2024-01-02",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 1,
      pricedPositions: 1,
      weights: [{ ticker: "A", issuer: "A", value: 100, weight: 1 }]
    }]
  });

  assert.equal(result.ok, true);
  assert.ok(Math.abs(result.equity.at(-1).value - 1) < 1e-12);
  assert.ok(Math.abs(result.quarterContributions[0].portfolioReturn) < 1e-12);
});

test("a missing active price fails closed instead of booking zero return", () => {
  const result = simulateDriftedPortfolio({
    tradingDates: ["2024-01-02", "2024-01-03"],
    priceMaps: new Map([
      ["SPY", map([["2024-01-02", 100], ["2024-01-03", 101]])],
      ["A", map([["2024-01-02", 100]])]
    ]),
    rebalances: [{
      reportDate: "2023-12-31",
      filingDate: "2024-01-01",
      executionDate: "2024-01-02",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 1,
      pricedPositions: 1,
      weights: [{ ticker: "A", issuer: "A", value: 100, weight: 1 }]
    }]
  });

  assert.equal(result.ok, false);
  assert.equal(result.status, "incomplete_price_coverage");
  assert.equal(result.failure.code, "missing_active_price");
  assert.equal(result.failure.date, "2024-01-03");
  assert.deepEqual(result.failure.tickers, ["A"]);
  assert.match(result.failure.policy, /fail_closed/);
  assert.equal(result.equity.length, 1);
});

test("active CHNG cash settlement includes the merger price and one special dividend", () => {
  const result = simulateDriftedPortfolio({
    tradingDates: ["2022-09-30", "2022-10-03", "2022-10-04"],
    priceMaps: new Map([
      ["SPY", map([
        ["2022-09-30", 100], ["2022-10-03", 100], ["2022-10-04", 100]
      ])],
      // The audited terminal row was 27.49 and did not contain a later
      // ex-date adjustment for the $2 cash distribution.
      ["CHNG", map([["2022-09-30", 27.49]])]
    ]),
    rebalances: [{
      reportDate: "2022-06-30",
      filingDate: "2022-08-12",
      executionDate: "2022-09-30",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 1,
      pricedPositions: 1,
      weights: [{
        ticker: "CHNG",
        issuer: "Change Healthcare Inc.",
        value: 100,
        weight: 1,
        corporateAction: {
          actionId: "change-healthcare-unitedhealth-2022",
          considerationType: "cash",
          effectiveDate: "2022-10-03",
          terminalCashPrice: 25.75,
          additionalCashPerShare: 2.00,
          terminalCashEntitlementPerShare: 27.75,
          currency: "USD"
        }
      }]
    }]
  });

  assert.equal(result.ok, true);
  assert.ok(Math.abs(result.equity.at(-1).value - 27.75 / 27.49) < 1e-12);
  assert.equal(
    result.quarterContributions[0]
      .contributions[0]
      .corporateActionResolution
      .terminalCashPrice,
    25.75
  );
  assert.equal(
    result.quarterContributions[0]
      .contributions[0]
      .corporateActionResolution
      .additionalCashPerShare,
    2
  );
  assert.equal(result.corporateActionTransitionSessions.length, 0);
});

test("active TWTR uses its October 27 close and converts to cash on October 28", () => {
  const result = simulateDriftedPortfolio({
    tradingDates: ["2022-10-26", "2022-10-27", "2022-10-28"],
    priceMaps: new Map([
      ["SPY", map([
        ["2022-10-26", 100], ["2022-10-27", 100], ["2022-10-28", 100]
      ])],
      // A recycled-symbol quote on the transition date must not replace the
      // audited merger entitlement.
      ["TWTR", map([
        ["2022-10-26", 50], ["2022-10-27", 53.70], ["2022-10-28", 1]
      ])]
    ]),
    rebalances: [{
      reportDate: "2022-06-30",
      executionDate: "2022-10-26",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 1,
      pricedPositions: 1,
      weights: [{
        ticker: "TWTR",
        issuer: "Twitter, Inc.",
        value: 100,
        weight: 1,
        corporateAction: {
          actionId: "twitter-x-holdings-2022",
          considerationType: "cash",
          effectiveDate: "2022-10-27",
          publicTradingEndExclusive: "2022-10-28",
          terminalCashPrice: 54.20,
          additionalCashPerShare: 0,
          terminalCashEntitlementPerShare: 54.20,
          currency: "USD"
        }
      }]
    }]
  });

  assert.equal(result.ok, true);
  assert.ok(Math.abs(result.equity[1].value - 53.70 / 50) < 1e-12);
  assert.ok(Math.abs(result.equity[2].value - 54.20 / 50) < 1e-12);
  assert.equal(
    result.quarterContributions[0]
      .contributions[0]
      .corporateActionResolution
      .settledOnOrBefore,
    "2022-10-28"
  );
});

test("a fully acquired pre-execution book starts and remains in audited cash", () => {
  const resolution = {
    actionId: "twitter-x-holdings-2022",
    considerationType: "cash",
    timing: "before_modeled_execution"
  };
  const result = simulateDriftedPortfolio({
    tradingDates: ["2022-11-15", "2022-11-16"],
    priceMaps: new Map([["SPY", map([
      ["2022-11-15", 100], ["2022-11-16", 101]
    ])]]),
    rebalances: [{
      reportDate: "2022-09-30",
      executionDate: "2022-11-15",
      coveragePct: 1,
      cashWeight: 1,
      selectedPositions: 1,
      pricedPositions: 0,
      cashSettledPositions: 1,
      corporateActionResolutions: [resolution],
      weights: []
    }]
  });

  assert.equal(result.ok, true);
  assert.equal(result.equity.at(-1).value, 1);
  assert.equal(result.quarterContributions[0].cashWeight, 1);
  assert.deepEqual(result.quarterContributions[0].contributions, []);
});

test("a private rollover is not converted to terminal cash", () => {
  const result = simulateDriftedPortfolio({
    tradingDates: ["2022-10-26", "2022-10-27", "2022-10-28"],
    priceMaps: new Map([
      ["SPY", map([
        ["2022-10-26", 100], ["2022-10-27", 100], ["2022-10-28", 100]
      ])],
      ["ROLL", map([["2022-10-26", 50]])]
    ]),
    rebalances: [{
      reportDate: "2022-06-30",
      executionDate: "2022-10-26",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 1,
      pricedPositions: 1,
      weights: [{
        ticker: "ROLL",
        issuer: "Private rollover holder",
        value: 100,
        weight: 1,
        corporateAction: {
          actionId: "private-rollover",
          considerationType: "private_equity",
          effectiveDate: "2022-10-27",
          terminalCashEntitlementPerShare: 54.20
        }
      }]
    }]
  });

  assert.equal(result.ok, false);
  assert.equal(result.failure.code, "missing_active_price");
  assert.equal(result.failure.date, "2022-10-27");
  assert.equal(
    result.failure.details[0].reason,
    "private_rollover_not_publicly_replicable"
  );
  assert.equal(result.failure.details[0].syntheticPriceUsed, false);
});

test("JHG remains public through June 30 and fails exactly at the July 1 private transition", () => {
  const result = simulateDriftedPortfolio({
    tradingDates: ["2026-06-29", "2026-06-30", "2026-07-01"],
    priceMaps: new Map([
      ["SPY", map([
        ["2026-06-29", 100], ["2026-06-30", 101], ["2026-07-01", 102]
      ])],
      // The final genuine public close remains valid on June 30. A recycled
      // symbol quote on July 1 would still be rejected by the action boundary.
      ["JHG", map([
        ["2026-06-29", 42], ["2026-06-30", 43], ["2026-07-01", 99]
      ])]
    ]),
    rebalances: [{
      reportDate: "2026-03-31",
      executionDate: "2026-06-29",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 1,
      pricedPositions: 1,
      weights: [{
        ticker: "JHG",
        issuer: "Janus Henderson Group plc",
        value: 100,
        weight: 1,
        corporateAction: {
          actionId: "trian-janus-henderson-private-rollover-2026",
          actionType: "private_rollover",
          considerationType: "private_equity_rollover",
          effectiveDate: "2026-06-30",
          publicTradingEndExclusive: "2026-07-01",
          syntheticPriceUsed: false
        }
      }]
    }]
  });

  assert.equal(result.ok, false);
  assert.equal(result.equity.at(-1).date, "2026-06-30");
  assert.equal(result.failure.date, "2026-07-01");
  assert.equal(
    result.failure.details[0].reason,
    "private_rollover_not_publicly_replicable"
  );
  assert.equal(result.failure.details[0].publicTradingEndExclusive, "2026-07-01");
});

test("ARCH stock conversion uses CNR shares and audits the non-trading transition day", () => {
  const result = simulateDriftedPortfolio({
    tradingDates: ["2025-01-13", "2025-01-14", "2025-01-15"],
    priceMaps: new Map([
      ["SPY", map([
        ["2025-01-13", 100], ["2025-01-14", 101], ["2025-01-15", 102]
      ])],
      ["ARCH", map([["2025-01-13", 150]])],
      ["CNR", map([["2025-01-15", 120]])]
    ]),
    rebalances: [{
      reportDate: "2024-09-30",
      executionDate: "2025-01-13",
      coveragePct: 1,
      cashWeight: 0,
      selectedPositions: 1,
      pricedPositions: 1,
      weights: [{
        ticker: "ARCH",
        issuer: "Arch Resources, Inc.",
        value: 100,
        weight: 1,
        corporateAction: {
          actionId: "arch-resources-core-natural-resources-2025",
          considerationType: "stock",
          effectiveDate: "2025-01-14",
          successorFirstTradingDate: "2025-01-15",
          successorTicker: "CNR",
          successorSharesPerShare: 1.326
        }
      }]
    }]
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.corporateActionTransitionSessions, [{
    date: "2025-01-14",
    actions: [{
      ticker: "ARCH",
      successorTicker: "CNR",
      effectiveDate: "2025-01-14",
      successorFirstTradingDate: "2025-01-15",
      actionId: "arch-resources-core-natural-resources-2025"
    }]
  }]);
  assert.equal(result.equity.some((point) => point.date === "2025-01-14"), false);
  assert.ok(Math.abs(result.equity.at(-1).value - (120 * 1.326) / 150) < 1e-12);
  assert.equal(
    result.quarterContributions[0].contributions[0].corporateActionResolution.successorTicker,
    "CNR"
  );
});

test("mixed stock and cash consideration preserves both merger entitlements", () => {
  const result = simulateDriftedPortfolio({
    tradingDates: ["2023-09-21", "2023-09-22", "2023-09-25"],
    priceMaps: new Map([
      ["SPY", map([["2023-09-21", 100], ["2023-09-22", 100], ["2023-09-25", 100]])],
      ["MMP", map([["2023-09-21", 65]])],
      ["OKE", map([["2023-09-22", 63], ["2023-09-25", 66]])]
    ]),
    rebalances: [{
      reportDate: "2023-06-30",
      executionDate: "2023-09-21",
      cashWeight: 0,
      weights: [{
        ticker: "MMP", weight: 1,
        corporateAction: {
          actionId: "mmp-oneok-2023",
          considerationType: "stock_and_cash",
          effectiveDate: "2023-09-22",
          successorTicker: "OKE",
          successorSharesPerShare: 0.667,
          terminalCashEntitlementPerShare: 25
        }
      }]
    }]
  });

  assert.equal(result.ok, true);
  assert.ok(Math.abs(result.equity.at(-1).value - (66 * 0.667 + 25) / 65) < 1e-12);
  assert.equal(
    result.quarterContributions[0].contributions[0].corporateActionResolution.considerationType,
    "stock_and_cash"
  );
});

test("multiple 13F rebalances on one execution date fail closed", () => {
  const shared = {
    filingDate: "2024-01-01",
    executionDate: "2024-01-02",
    coveragePct: 1,
    cashWeight: 0,
    selectedPositions: 1,
    pricedPositions: 1,
    weights: [{ ticker: "A", issuer: "A", value: 100, weight: 1 }]
  };
  const result = simulateDriftedPortfolio({
    tradingDates: ["2024-01-02", "2024-01-03"],
    priceMaps: new Map([
      ["SPY", map([["2024-01-02", 100], ["2024-01-03", 101]])],
      ["A", map([["2024-01-02", 100], ["2024-01-03", 101]])]
    ]),
    rebalances: [
      { ...shared, reportDate: "2023-09-30" },
      { ...shared, reportDate: "2023-12-31" }
    ]
  });

  assert.equal(result.ok, false);
  assert.equal(result.failure.code, "duplicate_execution_date");
  assert.equal(result.failure.date, "2024-01-02");
  assert.deepEqual(result.equity, []);
});

test("multiple active series sharing a bounded trailing vendor lag move the effective end", () => {
  const result = resolveTrailingCommonPriceEnd({
    rebalances: [{
      executionDate: "2026-08-17",
      weights: [
        { ticker: "AAA", weight: 0.4 },
        { ticker: "BBB", weight: 0.4 },
        { ticker: "CCC", weight: 0.2 }
      ]
    }],
    tradingDates: ["2026-08-27", "2026-08-28", "2026-08-31", "2026-09-01"],
    priceMaps: new Map([
      ["SPY", map([["2026-09-01", 100]])],
      ["AAA", map([["2026-08-27", 50]])],
      ["BBB", map([["2026-08-27", 75]])],
      ["CCC", map([["2026-09-01", 125]])]
    ]),
    requestedEnd: "2026-09-01",
    maxLagDays: 7
  });

  assert.equal(result.effectiveEnd, "2026-08-27");
  assert.equal(result.adjusted, true);
  assert.equal(result.lagDays, 5);
  assert.equal(result.reason, "bounded_trailing_vendor_lag");
  assert.deepEqual(result.latestDates, [
    { ticker: "SPY", date: "2026-09-01" },
    { ticker: "AAA", date: "2026-08-27" },
    { ticker: "BBB", date: "2026-08-27" },
    { ticker: "CCC", date: "2026-09-01" }
  ]);
  assert.deepEqual(result.staleActiveTickers, ["AAA", "BBB"]);
});

test("one stale active security is never treated as a common vendor lag", () => {
  const result = resolveTrailingCommonPriceEnd({
    rebalances: [{
      executionDate: "2026-08-17",
      weights: [
        { ticker: "AAA", weight: 0.5 },
        { ticker: "BBB", weight: 0.5 }
      ]
    }],
    tradingDates: ["2026-08-27", "2026-09-01"],
    priceMaps: new Map([
      ["SPY", map([["2026-09-01", 100]])],
      ["AAA", map([["2026-09-01", 50]])],
      ["BBB", map([["2026-08-27", 75]])]
    ]),
    requestedEnd: "2026-09-01",
    maxLagDays: 7
  });

  assert.equal(result.effectiveEnd, "2026-09-01");
  assert.equal(result.adjusted, false);
  assert.equal(result.lagDays, 5);
  assert.equal(result.reason, "insufficient_common_lag_evidence");
  assert.deepEqual(result.staleActiveTickers, ["BBB"]);
});

test("multiple stale active securities with mixed cutoffs remain fail closed", () => {
  const result = resolveTrailingCommonPriceEnd({
    rebalances: [{
      executionDate: "2026-08-17",
      weights: [
        { ticker: "AAA", weight: 0.4 },
        { ticker: "BBB", weight: 0.4 },
        { ticker: "CCC", weight: 0.2 }
      ]
    }],
    tradingDates: ["2026-08-26", "2026-08-27", "2026-09-01"],
    priceMaps: new Map([
      ["SPY", map([["2026-09-01", 100]])],
      ["AAA", map([["2026-08-27", 50]])],
      ["BBB", map([["2026-08-26", 75]])],
      ["CCC", map([["2026-09-01", 125]])]
    ]),
    requestedEnd: "2026-09-01",
    maxLagDays: 7
  });

  assert.equal(result.effectiveEnd, "2026-09-01");
  assert.equal(result.adjusted, false);
  assert.equal(result.lagDays, 6);
  assert.equal(result.reason, "mixed_trailing_dates");
  assert.deepEqual(result.staleActiveTickers, ["AAA", "BBB"]);
});

test("a benchmark map that does not reach its own market end cannot authorize an adjustment", () => {
  const result = resolveTrailingCommonPriceEnd({
    rebalances: [{
      executionDate: "2026-08-17",
      weights: [
        { ticker: "AAA", weight: 0.5 },
        { ticker: "BBB", weight: 0.5 }
      ]
    }],
    tradingDates: ["2026-08-27", "2026-09-01"],
    priceMaps: new Map([
      ["SPY", map([["2026-08-27", 100]])],
      ["AAA", map([["2026-08-27", 50]])],
      ["BBB", map([["2026-08-27", 75]])]
    ]),
    requestedEnd: "2026-09-01",
    maxLagDays: 7
  });

  assert.equal(result.effectiveEnd, "2026-09-01");
  assert.equal(result.adjusted, false);
  assert.equal(result.reason, "benchmark_end_missing");
});

test("a common trailing lag beyond the audit bound remains fail closed", () => {
  const result = resolveTrailingCommonPriceEnd({
    rebalances: [{
      executionDate: "2026-08-01",
      weights: [
        { ticker: "AAA", weight: 0.5 },
        { ticker: "BBB", weight: 0.5 }
      ]
    }],
    tradingDates: ["2026-08-20", "2026-09-01"],
    priceMaps: new Map([
      ["SPY", map([["2026-09-01", 100]])],
      ["AAA", map([["2026-08-20", 50]])],
      ["BBB", map([["2026-08-20", 75]])]
    ]),
    requestedEnd: "2026-09-01",
    maxLagDays: 7
  });

  assert.equal(result.effectiveEnd, "2026-09-01");
  assert.equal(result.adjusted, false);
  assert.equal(result.lagDays, 12);
  assert.equal(result.reason, "common_end_exceeds_max_lag");
});
