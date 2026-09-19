// Test-only exact dated observations, no production/provider credential payload.
export function tbbbCurrentAuditFixture() {
  const periods = [
    ["2024-12-31",16346.618,12315.604,"2025-04-10","2024-04-26"],
    ["2025-03-31",17131.788,12684.248,"2025-05-07","2024-05-23"],
    ["2025-06-30",18769.679,13574.347,"2025-08-11","2024-08-21"],
    ["2025-09-30",20278.992,14833.806,"2025-11-19","2024-11-25"],
    ["2025-12-31",21972.484,16346.618,"2026-03-11","2025-04-10"],
    ["2026-03-31",22860.346,17131.788,"2026-05-06","2025-05-07"],
    ["2026-06-30",26037.292,18769.679,"2026-08-12","2025-08-11"]
  ];
  const point = (periodEndDate, revenueM, availableDate) => ({ periodEndDate, revenueM, availableDate,
    scope: "company_total", currency: "MXN", unit: "million", sourceDimension: "ARQ",
    sourceRecord: { ticker: "TBBB", periodEndDate, datekey: availableDate, dataset: "test_only_dated_fixture" } });
  const observations = periods.map(([date, revenue, prior, available, comparatorAvailable]) => ({
    ...point(date, revenue, available), valuePct: (revenue / prior - 1) * 100,
    comparator: point(`${Number(date.slice(0,4)) - 1}${date.slice(4)}`, prior, comparatorAvailable)
  }));
  return { scenarioId: "base",
    economicInput: { asOfDate: "2026-09-05", periodEndDate: "2026-06-30", sourceCurrency: "MXN",
      sourceRevenue: 91149.114, sourceCfo: 7011.837, sourceCapex: 3772.646,
      rawSourceRecord: { ticker: "TBBB", datekey: "2026-08-12", reportperiod: "2026-06-30", dimension: "ART" } },
    financialTrendPct: 35.06348977093479,
    financialTrendEvidence: { asOfDate: "2026-09-05", unit: "percent", valuePct: 35.06348977093479,
      method: "normalizedRevenueGrowthForRows", windowSize: 8,
      selection: "latest_up_to_8_complete_observations_in_latest_8_period_window", observations },
    growthPolicySettings: { normalizedGrowthCapPct: 45, minimumGrowthSampleCount: 4, fundamentalGrowthPriorPct: 5 },
    fx: { baseCurrency: "USD", quoteCurrency: "MXN", rateDate: "2026-09-04", availableDate: "2026-09-04", mxnPerUsd: 19.6401 / 1.1622 }
  };
}
