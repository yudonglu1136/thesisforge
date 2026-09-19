import assert from "node:assert/strict";
import test from "node:test";
import {
  attachMstrCryptoMetrics,
  buildEquityDcf,
  buildValuationRows,
  cycleContextForRows,
  cycleNormalizeNetIncome,
  digestGuidanceMetrics,
  hasExplicitValuationProfile,
  normalizedGrowthInputs,
  normalizedGrowthPct,
  normalizedRevenueGrowthForRows,
  normalizedMarginRatio,
  normalizedNetIncomePower,
  profileSettings,
  resolveTrailingFinancialValue,
  resolveForwardRevenueGuidance,
  valuationFreeCashFlow
} from "./importSecQuarterlyValuations.js";

function guidance(metricName, amount, excerpt, qualityStatus = "clear") {
  return {
    actual_or_guidance: "guidance",
    metric_name: metricName,
    amount,
    unit: "USD millions",
    currency: "USD",
    quality_status: qualityStatus,
    excerpt
  };
}

test("official revenue_guidance growth feeds the valuation digest", () => {
  const metric = guidance(
    "revenue_guidance",
    null,
    "Organic constant currency growth in total income raised to 7.0-7.5%."
  );
  metric.growth_yoy = 7.25;

  const digest = digestGuidanceMetrics([metric]);

  assert.equal(digest.revenueGrowth, 7.25);
  assert.equal(digest.revenueGuidanceGrowth, 7.25);
});

test("multi-year CAGR cannot become next-period revenue growth even with an old company-total label", () => {
  const target = {
    ...guidance("revenue_guidance", null,
      "We expect compounded annual growth in total revenue of 30% from 2025 to 2028."),
    growth_yoy: 30, evidence_id: "multi-year", guidance_subject: "company_total_or_unspecified"
  };
  const annual = {
    ...guidance("revenue_guidance", null, "We expect total revenue growth of 12% for FY2026."),
    growth_yoy: 12, evidence_id: "annual", guidance_scope: "full_year", guidance_subject: "company_total"
  };
  for (const scope of [undefined, "multi_year_target"]) {
    const result = digestGuidanceMetrics([{ ...target, guidance_scope: scope }, annual]);
    assert.equal(result.revenueGuidanceGrowth, 12);
    assert.deepEqual(result.scalarEvidenceIds.revenueGuidanceGrowth, ["annual"]);
    assert.equal(result.evidence.length, 2, "Original multi-year target remains research evidence");
  }
});

test("scalar guidance lineage excludes a same-valued subset and records deduplicated contributors", () => {
  const total = {
    ...guidance("revenue_guidance", null, "We expect total revenue growth of 30% for FY2026."),
    growth_yoy: 30, evidence_id: "total", guidance_subject: "company_total"
  };
  const subset = { ...total, evidence_id: "subset", guidance_subject: "segment_or_subset" };
  const duplicate = { ...total, evidence_id: "duplicate" };
  const operating = { ...guidance("operating_margin", null, "Operating margin guidance is 15%."),
    margin_pct: 15, evidence_id: "operating" };
  const gross = { ...guidance("gross_margin", null, "Gross margin guidance is 25%."),
    margin_pct: 25, evidence_id: "gross" };
  const blocked = { ...gross, evidence_id: "rejected", quality_status: "currency_conflict" };
  const digest = digestGuidanceMetrics([total, subset, duplicate, operating, gross, blocked]);
  assert.equal(digest.revenueGuidanceGrowth, 30);
  assert.deepEqual(digest.scalarEvidenceIds, {
    revenueGrowth: ["total"], revenueGuidanceGrowth: ["total"],
    operatingMargin: ["operating"], grossMargin: ["gross"]
  });
});

test("historical annual revenue cannot become guidance through better-than-expected wording", () => {
  const quote = "We ended the year with a better-than-expected Holiday quarter. For the year, revenue exceeded $4 billion.";
  const actual = { ...guidance("revenue_guidance", 4000, quote), evidence_id: "reported-year",
    guidance_scope: "full_year", guidance_subject: "company_total_or_unspecified" };
  const forward = { ...guidance("revenue_guidance", 4200, "For the full year, we expect revenue of $4.2 billion."),
    evidence_id: "forward-year", guidance_scope: "full_year" };
  for (const position of [undefined, quote.indexOf("revenue exceeded")]) {
    const result = digestGuidanceMetrics([{ ...actual, metric_position: position }, forward]);
    assert.equal(result.revenueGuidanceM, 4200);
    assert.deepEqual(result.guidanceSelection.revenue.acceptedEvidenceIds, ["forward-year"]);
    assert.equal(result.rejectedHistoricalGuidance[0].evidenceId, "reported-year");
    assert.equal(result.evidence.length, 2);
  }
});

test("a forward owned metric is not rejected because its prior comparator is in the same quote", () => {
  const quote = "Revenue was $4 billion last year. For the full year, we expect revenue of $4.2 billion.";
  const metric = { ...guidance("revenue_guidance", 4200, quote), evidence_id: "forward",
    guidance_scope: "full_year", metric_position: quote.indexOf("revenue of") };
  const result = digestGuidanceMetrics([metric]);
  assert.equal(result.revenueGuidanceM, 4200);
  assert.deepEqual(result.rejectedHistoricalGuidance, []);
});

test("official issuer guidance overrides same-period transcript extraction", () => {
  const transcriptFcf = guidance(
    "free_cash_flow_guidance",
    2_950,
    "We expect free cash flow of $2.95 billion."
  );
  transcriptFcf.currency = "USD";
  transcriptFcf.source_type = "downloaded_online_earnings_transcript";
  const officialFcf = guidance(
    "free_cash_flow_guidance",
    2_400,
    "For full year 2026, our guidance is equity free cash flow of at least GBP 2.4 billion."
  );
  officialFcf.currency = "GBP";
  officialFcf.source_type = "official_issuer_results_release";
  officialFcf.payload_json = JSON.stringify({ guidance_scope: "full_year", guidance_year: 2026, guidance_subject: "company_total" });

  const digest = digestGuidanceMetrics([transcriptFcf, officialFcf]);

  assert.equal(digest.fcfGuidanceM, 2_400);
  assert.equal(digest.metricCount, 1);
});

test("official SEC guidance overrides same-period transcript extraction", () => {
  const transcriptRevenue = guidance(
    "revenue_guidance",
    9_400,
    "For the full year, we expect revenue of approximately $9.4 billion."
  );
  transcriptRevenue.source_type = "downloaded_online_earnings_transcript";
  transcriptRevenue.payload_json = JSON.stringify({ guidance_scope: "full_year" });
  const officialRevenue = guidance(
    "revenue_guidance",
    9_800,
    "For the full year, company revenue is expected to be $9.8 billion."
  );
  officialRevenue.source_type = "official_issuer_sec_filing";
  officialRevenue.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "company_total"
  });

  const digest = digestGuidanceMetrics([transcriptRevenue, officialRevenue]);

  assert.equal(digest.revenueGuidanceM, 9_800);
  assert.equal(digest.metricCount, 1);
});

test("PLTR Q2 uses explicit FY revenue and FCF guidance, not Q3 guidance", () => {
  const digest = digestGuidanceMetrics([
    guidance(
      "revenue_guidance",
      2160,
      "For Q3 2026, we expect revenue of between $2.16 billion and $2.164 billion."
    ),
    guidance(
      "revenue_guidance",
      8154,
      "For full year 2026, we are raising our revenue guidance to between $8.15 billion and $8.158 billion."
    ),
    guidance(
      "free_cash_flow_guidance",
      4500,
      "We are raising adjusted free cash flow guidance to between $4.5 billion and $4.7 billion for this year."
    ),
    guidance(
      "operating_income_guidance",
      1728,
      "For Q3 2026, adjusted income from operations is expected between $1.292 billion and $1.296 billion."
    ),
    guidance(
      "operating_income_guidance",
      4700,
      "We are raising adjusted free cash flow guidance and continue to expect GAAP operating income and net income."
    )
  ]);

  assert.equal(digest.revenueGuidanceM, 8154);
  assert.equal(digest.fcfGuidanceM, 4500);
  assert.equal(digest.operatingIncomeGuidanceM, null);
  assert.equal(digest.guidanceSelection.revenue.mode, "explicit_full_year");
  assert.equal(digest.guidanceSelection.revenue.rejectedQuarterCount, 1);
  assert.equal(digest.revenueQuarterGuidanceM, 2160);
});

test("PLTR Q1 prefers total FY revenue over quarterly and segment guidance", () => {
  const digest = digestGuidanceMetrics([
    guidance(
      "revenue_guidance",
      7656,
      "We are raising our full year 2026 revenue guidance midpoint to $7.656 billion."
    ),
    guidance(
      "revenue_guidance",
      3224,
      "We are raising our U.S. commercial revenue guidance to in excess of $3.224 billion."
    ),
    guidance(
      "revenue_guidance",
      1797,
      "For Q2 2026, we expect revenue of between $1.797 billion and $1.801 billion."
    ),
    guidance(
      "operating_income_guidance",
      4446,
      "For full year 2026, we are raising our adjusted income from operations guidance to between $4.440 billion and $4.452 billion."
    )
  ]);

  assert.equal(digest.revenueGuidanceM, 7656);
  assert.equal(digest.operatingIncomeGuidanceM, 4446);
  assert.equal(digest.guidanceSelection.operatingIncome.mode, "explicit_full_year");
});

test("year-only annual wording is a safe fallback when no quarter scope is present", () => {
  const digest = digestGuidanceMetrics([
    guidance("revenue_guidance", 9200, "For 2027, we expect revenue of approximately $9.2 billion."),
    guidance("revenue_guidance", 2400, "For Q1 2027, we expect revenue of approximately $2.4 billion.")
  ]);

  assert.equal(digest.revenueGuidanceM, 9200);
  assert.equal(digest.guidanceSelection.revenue.mode, "explicit_full_year");
  assert.equal(digest.guidanceSelection.revenue.rejectedQuarterCount, 1);
});

test("structured guidance scope makes an issuer bullet explicit full-year guidance", () => {
  const metric = guidance(
    "free_cash_flow_guidance",
    2700,
    "Equity free cash flow at least GBP 2.7 billion."
  );
  metric.payload_json = JSON.stringify({ guidance_scope: "full_year", guidance_year: 2026 });

  const digest = digestGuidanceMetrics([metric]);

  assert.equal(digest.fcfGuidanceM, 2700);
  assert.equal(digest.guidanceSelection.freeCashFlow.mode, "explicit_full_year");
});

test("structured full-year scope outranks a later quarter token in the same sentence", () => {
  const metric = guidance(
    "revenue_guidance",
    23_000,
    "We expect full-year total revenue of $23 billion, with Q3 revenue near $6 billion."
  );
  metric.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "company_total"
  });

  const digest = digestGuidanceMetrics([metric]);

  assert.equal(digest.revenueGuidanceM, 23_000);
  assert.equal(digest.revenueQuarterGuidanceM, null);
  assert.equal(digest.guidanceSelection.revenue.mode, "explicit_full_year");
});

test("structured revenue subject keeps total sales and rejects data-center sales in one sentence", () => {
  const excerpt = "We now expect full year sales to be roughly $23 billion and full year data center revenue of approximately $2 billion.";
  const total = guidance("revenue_guidance", 23_000, excerpt);
  total.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "company_total_or_unspecified"
  });
  const segment = guidance("revenue_guidance", 2_000, excerpt);
  segment.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "segment_or_subset"
  });

  const digest = digestGuidanceMetrics([total, segment]);

  assert.equal(digest.revenueGuidanceM, 23_000);
  assert.equal(digest.guidanceSelection.revenue.acceptedCount, 1);
  assert.equal(digest.guidanceSelection.revenue.rejectedSemanticCount, 1);
});

test("service revenue remains research evidence but cannot become total company revenue", () => {
  const metric = guidance(
    "revenue_guidance",
    77_000,
    "We expect full-year service revenues of $77 billion, with Q3 expectations of $19.3 billion."
  );
  metric.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "segment_or_subset"
  });

  const digest = digestGuidanceMetrics([metric]);

  assert.equal(digest.revenueGuidanceM, null);
  assert.equal(digest.revenueQuarterGuidanceM, null);
  assert.equal(digest.guidanceSelection.revenue.rejectedSemanticCount, 1);
});

test("repeated evidence from two management sections cannot weight the guidance median", () => {
  const repeated = guidance(
    "revenue_guidance",
    100,
    "For the full year, we expect total revenue of $100 million."
  );
  const duplicate = { ...repeated, speaker: "Second management speaker" };
  const secondSignal = guidance(
    "revenue_guidance",
    300,
    "For the full year, our total revenue range has a $300 million midpoint."
  );

  const digest = digestGuidanceMetrics([repeated, duplicate, secondSignal]);

  assert.equal(digest.revenueGuidanceM, 200);
  assert.equal(digest.metricCount, 2);
});

test("professional services, asset sales, and market revenue cannot become company revenue", () => {
  const digest = digestGuidanceMetrics([
    guidance("revenue_guidance", 180, "For Q2, we expect professional services revenue of $180 million."),
    guidance("revenue_guidance", 1_900, "We project total asset sales of $1.9 billion by 2028."),
    guidance("revenue_guidance", 300_000, "We estimate the NAND market will exceed $300 billion in revenue.")
  ]);

  assert.equal(digest.revenueGuidanceM, null);
  assert.equal(digest.revenueQuarterGuidanceM, null);
  assert.equal(digest.guidanceSelection.revenue.rejectedSemanticCount, 3);
});

test("structured multi-year target remains evidence but is excluded from annual guidance", () => {
  const metric = guidance(
    "revenue_guidance",
    20_000,
    "We plan to grow our annualized sales run rate to $20 billion by the end of 2026."
  );
  metric.payload_json = JSON.stringify({
    guidance_scope: "multi_year_target",
    guidance_subject: "non_company_or_non_periodic"
  });

  const digest = digestGuidanceMetrics([metric]);

  assert.equal(digest.revenueGuidanceM, null);
  assert.equal(digest.revenueQuarterGuidanceM, null);
  assert.equal(digest.guidanceSelection.revenue.rejectedSemanticCount, 1);
});

test("annual FCF guidance is not averaged with a multi-year cumulative target", () => {
  const annual = guidance(
    "free_cash_flow_guidance",
    1_500,
    "We have raised our in-year free cash flow guide to more than £1.5 billion."
  );
  annual.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "company_total"
  });
  const cumulative = guidance(
    "free_cash_flow_guidance",
    6_000,
    "We continue to target more than £6 billion of free cash flow over the three-year period."
  );
  cumulative.payload_json = JSON.stringify({
    guidance_scope: "multi_year_target",
    guidance_subject: "non_company_or_non_periodic"
  });

  const digest = digestGuidanceMetrics([annual, cumulative]);

  assert.equal(digest.fcfGuidanceM, 1_500);
  assert.equal(digest.guidanceSelection.freeCashFlow.mode, "explicit_full_year");
  assert.equal(digest.guidanceSelection.freeCashFlow.acceptedCount, 1);
});

test("segment operating income and discontinued-operation FCF cannot become company guidance", () => {
  const segmentIncome = guidance(
    "operating_income_guidance",
    7_000,
    "For the full year, the Health Services segment expects adjusted operating income of $7 billion."
  );
  segmentIncome.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "segment_or_subset"
  });
  const discontinuedFcf = guidance(
    "free_cash_flow_guidance",
    250,
    "We expect $250 million of free cash flow from our discontinued operations in full year 2025."
  );
  discontinuedFcf.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "segment_or_subset"
  });

  const digest = digestGuidanceMetrics([segmentIncome, discontinuedFcf]);

  assert.equal(digest.operatingIncomeGuidanceM, null);
  assert.equal(digest.fcfGuidanceM, null);
  assert.equal(digest.guidanceSelection.operatingIncome.rejectedSemanticCount, 1);
  assert.equal(digest.guidanceSelection.freeCashFlow.rejectedSemanticCount, 1);
});

test("company operating income and FCF levels survive the subject gate", () => {
  const companyIncome = guidance(
    "operating_income_guidance",
    16_750,
    "In aggregate, we expect full-year enterprise adjusted operating income of $16.75 billion."
  );
  companyIncome.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "company_total"
  });
  const companyFcf = guidance(
    "free_cash_flow_guidance",
    2_500,
    "We expect aggregate company free cash flow of approximately $2.5 billion in 2026."
  );
  companyFcf.payload_json = JSON.stringify({
    guidance_scope: "full_year",
    guidance_subject: "company_total"
  });

  const digest = digestGuidanceMetrics([companyIncome, companyFcf]);

  assert.equal(digest.operatingIncomeGuidanceM, 16_750);
  assert.equal(digest.fcfGuidanceM, 2_500);
});

test("an operating-income delta cannot masquerade as the annual absolute level", () => {
  const digest = digestGuidanceMetrics([
    guidance(
      "operating_income_guidance",
      400,
      "We estimate this will decrease full-year operating income by approximately $400 million."
    )
  ]);

  assert.equal(digest.operatingIncomeGuidanceM, null);
  assert.equal(digest.guidanceSelection.operatingIncome.rejectedSemanticCount, 1);
});

test("quarter shorthand, ARR and segment guides cannot become annual total revenue", () => {
  const digest = digestGuidanceMetrics([
    guidance("revenue_guidance", 3977.5, "For Q3, we expect subscription revenues between $3.975 billion and $3.980 billion."),
    guidance("revenue_guidance", 100000, "For fiscal year 2027, AI semiconductor revenue will exceed $100 billion."),
    guidance("revenue_guidance", 56000, "For the full year 2026, AI semiconductor revenue will be $56 billion."),
    guidance("revenue_guidance", 20500, "We forecast semiconductor revenue of approximately $20.5 billion."),
    guidance("revenue_guidance", 8900, "We forecast software revenue of approximately $8.9 billion."),
    guidance("revenue_guidance", 6607.5, "For the full fiscal year 2027, annual recurring revenue will be $6.6075 billion."),
    guidance("free_cash_flow_guidance", 1040, "We expect free cash flow margin of 35% and 1.04 billion weighted average shares.")
  ]);

  assert.equal(digest.revenueGuidanceM, null);
  assert.equal(digest.fcfGuidanceM, null);
  assert.equal(digest.guidanceSelection.revenue.rejectedSemanticCount, 6);
});

test("year outlook survives when a Q3 shorthand guide is also present", () => {
  const digest = digestGuidanceMetrics([
    guidance("revenue_guidance", 6340, "For our updated outlook for 2026, we now expect revenue of $6.34 billion."),
    guidance("revenue_guidance", 1625, "For Q3, we expect revenue of $1.625 billion.")
  ]);

  assert.equal(digest.revenueGuidanceM, 6340);
  assert.equal(digest.guidanceSelection.revenue.mode, "explicit_full_year");
});

test("GEV original company guidance range is annual and outranks segment amounts", () => {
  const digest = digestGuidanceMetrics([
    guidance(
      "revenue_guidance",
      36_500,
      "For revenue, we're trending towards the higher end of our original $36 billion-$37 billion guidance range."
    ),
    guidance(
      "revenue_guidance",
      500,
      "Absent the approximately $500 million benefit of the one-time settlement in the third quarter of last year, we expect Wind revenue to increase low single digits."
    ),
    guidance(
      "revenue_guidance",
      300,
      "In Wind, EBITDA losses are trending towards the bottom of our $200 million-$400 million range."
    )
  ]);

  assert.equal(digest.revenueGuidanceM, 36_500);
  assert.equal(digest.guidanceSelection.revenue.mode, "explicit_full_year");
  assert.equal(digest.revenueQuarterGuidanceM, 500);
});

test("plus-minus revenue guidance uses the center instead of averaging the tolerance", () => {
  const metric = guidance(
    "revenue_guidance",
    2_100,
    "For Q1, we expect revenue to be $4.1 billion, ±$100 million."
  );

  const digest = digestGuidanceMetrics([metric]);

  assert.equal(digest.revenueQuarterGuidanceM, 4_100);
});

test("attached mojibake plus-minus marker still resolves the monetary center", () => {
  const metric = guidance(
    "revenue_guidance",
    100,
    "Revenue is expected to be $3.1 billionÂ±, $100 million."
  );

  const digest = digestGuidanceMetrics([metric]);

  assert.equal(digest.revenueUnscopedGuidanceM, 3_100);
});

test("plus-minus centers stay attached to their own metric in a multi-metric sentence", () => {
  const excerpt = "For the year, revenues are $7.3 billion ±$75 million and free cash flow is $800 million ±$50 million.";
  const digest = digestGuidanceMetrics([
    guidance("revenue_guidance", 3_687.5, excerpt),
    guidance("free_cash_flow_guidance", 425, excerpt)
  ]);

  assert.equal(digest.revenueGuidanceM, 7_300);
  assert.equal(digest.fcfGuidanceM, 800);
});

test("a capex plus-minus amount cannot become revenue guidance from the same sentence", () => {
  const excerpt = "We expect a low single-digit revenue decline and capital expenditures of $650 million ± 5%.";
  const metric = guidance("revenue_guidance", null, excerpt);

  const digest = digestGuidanceMetrics([metric]);

  assert.equal(digest.revenueUnscopedGuidanceM, null);
});

test("triple-digit growth is capped instead of discarded to the default", () => {
  const settings = { normalizedGrowthCapPct: 45 };
  assert.equal(normalizedGrowthPct({ revenue_growth_pct: null }, null, settings), 5);
  assert.equal(normalizedGrowthPct({ revenue_growth_pct: 99.9 }, null, settings), 45);
  assert.equal(normalizedGrowthPct({ revenue_growth_pct: 105.9 }, null, settings), 45);
  assert.equal(normalizedGrowthPct({ revenue_growth_pct: 1_500 }, null, settings), 45);
  assert.equal(normalizedGrowthPct({ revenue_growth_pct: -100 }, null, settings), -20);
});

test("research transcript growth cannot alter the valuation growth input", () => {
  const result = normalizedGrowthInputs(
    { normalized_revenue_growth_pct: 12, normalized_revenue_growth_window: 8, normalized_revenue_growth_sample_count: 8 },
    { revenueGrowth: 90 },
    {}
  );

  assert.equal(result.value, 12);
  assert.equal(result.source, "pit_financials");
  assert.equal(result.reportedGuidanceGrowthPct, null);
});

test("explicit management growth guidance has bounded minority influence", () => {
  const result = normalizedGrowthInputs(
    { normalized_revenue_growth_pct: 10 },
    { revenueGrowth: 90, revenueGuidanceGrowth: 60 },
    {}
  );

  assert.equal(result.boundedGuidanceGrowthPct, 25);
  assert.equal(result.guidanceWeight, 0.25);
  assert.equal(result.value, 13.75);
  assert.equal(result.source, "pit_financials_bounded_guidance_blend");
});

test("management growth guidance cannot become the sole growth forecast", () => {
  const result = normalizedGrowthInputs(
    { normalized_revenue_growth_pct: null },
    { revenueGuidanceGrowth: 80 },
    {}
  );

  assert.equal(result.baseGrowthPct, 5);
  assert.equal(result.boundedGuidanceGrowthPct, 20);
  assert.equal(result.guidanceWeight, 0.25);
  assert.equal(result.value, 8.75);
  assert.equal(result.source, "conservative_default_bounded_guidance_blend");
});

test("EBITDA and cumulative multi-year FCF cannot masquerade as annual guidance", () => {
  const digest = digestGuidanceMetrics([
    guidance(
      "revenue_guidance",
      2_300,
      "We expect CapEx of $2.0-$2.2 billion and EBITDA of approximately $2.2-$2.4 billion."
    ),
    guidance(
      "free_cash_flow_guidance",
      1_150,
      "We anticipate $200 million of free cash flow in 2019 and $2.1 billion in cumulative free cash flow over the five-year period."
    )
  ]);

  assert.equal(digest.revenueGuidanceM, null);
  assert.equal(digest.revenueUnscopedGuidanceM, null);
  assert.equal(digest.fcfGuidanceM, null);
  assert.equal(digest.guidanceSelection.revenue.rejectedSemanticCount, 1);
  assert.equal(digest.guidanceSelection.freeCashFlow.rejectedSemanticCount, 1);
});

test("discontinued-operation cash flow cannot enter continuing-company DCF", () => {
  const digest = digestGuidanceMetrics([
    guidance(
      "free_cash_flow_guidance",
      250,
      "We expect $250 million of free cash flow from our discontinued operations in the full year 2025."
    )
  ]);

  assert.equal(digest.fcfGuidanceM, null);
  assert.equal(digest.guidanceSelection.freeCashFlow.rejectedSemanticCount, 1);
});

test("loss-period cycle burden excludes negative net margins", () => {
  const rows = [
    { fiscalQuarter: "Q4", revenue_m: 1_000, operating_income_m: 100, net_income_m: -50, shares_m: 100, sources: { revenue_m: { form: "10-K" } } },
    { fiscalQuarter: "Q4", revenue_m: 1_000, operating_income_m: 120, net_income_m: -20, shares_m: 100, sources: { revenue_m: { form: "10-K" } } }
  ];

  const context = cycleContextForRows(rows, rows.length - 1, 2);
  assert.equal(context.belowOperatingBurdenPct, null);
});

test("through-cycle EPS fades old profitable samples instead of dropping at a hard window edge", () => {
  const rows = Array.from({ length: 18 }, (_, index) => {
    const netIncome = index === 0 ? 500 : 50;
    return {
      fiscalQuarter: "Q1",
      revenue_m: 1_000,
      operating_income_m: netIncome,
      net_income_m: netIncome,
      shares_m: 100,
      pitTrailingTwelveMonths: {
        revenue_m: 1_000,
        operating_income_m: netIncome,
        net_income_m: netIncome
      },
      sources: {}
    };
  });

  const before = cycleContextForRows(rows, 16, 16).eps;
  const after = cycleContextForRows(rows, 17, 16).eps;
  assert.ok(before > 0 && after > 0);
  assert.ok(Math.max(before, after) / Math.min(before, after) < 1.1);
});

test("through-cycle EPS requires four positive PIT observations", () => {
  const rows = [100, 200].map((netIncome) => ({
    fiscalQuarter: "Q1",
    revenue_m: 1_000,
    operating_income_m: netIncome,
    net_income_m: netIncome,
    shares_m: 100,
    pitTrailingTwelveMonths: {
      revenue_m: 1_000,
      operating_income_m: netIncome,
      net_income_m: netIncome
    },
    sources: {}
  }));

  const context = cycleContextForRows(rows, rows.length - 1, 8);
  assert.equal(context.eps, null);
  assert.equal(context.positiveEpsSampleCount, 2);
});

test("reused prior reported TTM counts as one independent cycle observation", () => {
  const rows = Array.from({ length: 3 }, (_, index) => ({
    fiscalYear: 2021,
    fiscalQuarter: `Q${index + 1}`,
    sourceDimension: "ARQ",
    requiresReportedTrailingBasis: true,
    revenue_m: index === 0 ? 250 : null,
    operating_income_m: index === 0 ? 40 : null,
    net_income_m: index === 0 ? 25 : null,
    cfo_m: index === 0 ? 35 : null,
    capex_m: index === 0 ? 5 : null,
    shares_m: 100,
    pitTrailingTwelveMonths: index === 0
      ? {
          revenue_m: 1_000,
          operating_income_m: 160,
          net_income_m: 100,
          cfo_m: 140,
          capex_m: 20,
          fcf_after_capex_m: 120
        }
      : undefined,
    sources: {}
  }));

  const context = cycleContextForRows(rows, rows.length - 1, 8);
  assert.equal(context.sampleCount, 1);
  assert.equal(context.positiveEpsSampleCount, 1);
  assert.equal(context.positiveFcfSampleCount, 1);
  assert.equal(context.eps, null);
});

test("PIT trailing values prefer reported TTM and never annualize one quarter", () => {
  const rows = [{
    fiscalYear: 2021,
    fiscalQuarter: "Q1",
    sourceDimension: "ARQ",
    revenue_m: 250,
    requiresReportedTrailingBasis: true,
    pitTrailingTwelveMonths: { revenue_m: 900 },
    sources: { revenue_m: { annualOnly: false } }
  }];

  assert.deepEqual(resolveTrailingFinancialValue(rows, 0, "revenue_m", 4), {
    value: 900,
    source: "current_reported_ttm",
    sourceIndex: 0
  });
  delete rows[0].pitTrailingTwelveMonths;
  assert.equal(resolveTrailingFinancialValue(rows, 0, "revenue_m", 4), null);
});

test("trailing sum requires four consecutive reported quarter flows", () => {
  const quarter = (fiscalYear, fiscalQuarter, revenue) => ({
    fiscalYear,
    fiscalQuarter,
    sourceDimension: "ARQ",
    revenue_m: revenue,
    requiresReportedTrailingBasis: true,
    sourceRecord: { metricsAreTrailingTwelveMonths: false },
    sources: { revenue_m: { annualOnly: false } }
  });
  const consecutive = [
    quarter(2020, "Q2", 200),
    quarter(2020, "Q3", 220),
    quarter(2020, "Q4", 240),
    quarter(2021, "Q1", 260)
  ];
  assert.deepEqual(resolveTrailingFinancialValue(consecutive, 3, "revenue_m", 4), {
    value: 920,
    source: "four_consecutive_quarters",
    sourceIndex: 3
  });

  const gap = [consecutive[0], consecutive[1], consecutive[3]];
  assert.equal(resolveTrailingFinancialValue(gap, 2, "revenue_m", 4), null);
});

test("reported annual rows are not mixed into a four-quarter sum", () => {
  const rows = [
    {
      fiscalYear: 2020,
      fiscalQuarter: "Q4",
      sourceDimension: "ART",
      revenue_m: 800,
      pitTrailingTwelveMonths: { revenue_m: 800 },
      requiresReportedTrailingBasis: true,
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: { revenue_m: { annualOnly: true } }
    },
    ...[1, 2, 3].map((quarter) => ({
      fiscalYear: 2021,
      fiscalQuarter: `Q${quarter}`,
      sourceDimension: "ARQ",
      revenue_m: 250,
      requiresReportedTrailingBasis: true,
      sourceRecord: { metricsAreTrailingTwelveMonths: false },
      sources: { revenue_m: { annualOnly: false } }
    }))
  ];

  assert.deepEqual(resolveTrailingFinancialValue(rows, 3, "revenue_m", 4), {
    value: 800,
    source: "prior_reported_ttm",
    sourceIndex: 0
  });
});

test("default eight-period growth normalization removes a single-quarter cliff", () => {
  const rows = [12, 11, 10, 9, 8, 7, 6, -20, 45].map((revenueGrowth) => ({
    revenue_growth_pct: revenueGrowth
  }));

  assert.equal(normalizedRevenueGrowthForRows(rows, 8), 8.5);
});

test("sparse non-comparable growth history cannot create a valuation-multiple cliff", () => {
  const result = normalizedGrowthInputs({
    normalized_revenue_growth_pct: 146.4,
    normalized_revenue_growth_sample_count: 1,
    normalized_revenue_growth_window: 6
  }, null, {
    normalizedGrowthCapPct: 70
  });

  assert.equal(result.value, 5);
  assert.equal(result.source, "conservative_default");
  assert.equal(result.fundamentalGrowthPct, null);
  assert.equal(result.reportedFundamentalGrowthPct, 146.4);
  assert.equal(result.insufficientGrowthHistory, true);
  assert.equal(result.minimumSampleCount, 4);
});

test("growth trend phases in once four PIT observations exist", () => {
  const result = normalizedGrowthInputs({
    normalized_revenue_growth_pct: 24,
    normalized_revenue_growth_sample_count: 4,
    normalized_revenue_growth_window: 8
  }, null, {});

  assert.equal(result.value, 9.75);
  assert.equal(result.source, "pit_financials_evidence_ramp");
  assert.equal(result.fundamentalGrowthEvidenceWeight, 0.25);
  assert.equal(result.insufficientGrowthHistory, false);
});

test("quarterly revenue guidance is annualized and blended without becoming FY guidance", () => {
  const result = resolveForwardRevenueGuidance({
    ttmRevenue: 302_969,
    formulaForwardRevenue: 439_305.05,
    annualGuidanceM: 108_000,
    unscopedGuidanceM: 108_000,
    quarterlyGuidanceM: null,
    guidanceMode: "unscoped_fallback",
    settings: { forwardScaleCap: 2.4 }
  });

  assert.equal(result.scope, "inferred_quarter");
  assert.equal(result.source, "quarterly_guidance_blend");
  assert.equal(result.annualGuidanceM, null);
  assert.equal(result.quarterlyGuidanceM, 108_000);
  assert.equal(result.annualizedQuarterlyGuidanceM, 432_000);
  assert.equal(result.boundedAnnualizedQuarterlyGuidanceM, 432_000);
  assert.equal(result.quarterlyGuidanceWeight, 0.65);
  assert.ok(Math.abs(result.valuationRevenue - 434_556.7675) < 1e-6);
});

test("annual-scale unscoped revenue cannot replace the formula forward input", () => {
  const result = resolveForwardRevenueGuidance({
    ttmRevenue: 5_000,
    formulaForwardRevenue: 5_500,
    annualGuidanceM: null,
    unscopedGuidanceM: 5_800,
    quarterlyGuidanceM: null,
    guidanceMode: "unscoped_fallback",
    settings: {}
  });

  assert.equal(result.source, "formula_forward");
  assert.equal(result.scope, "missing_or_implausible");
  assert.equal(result.valuationRevenue, 5_500);
});

test("explicit full-year revenue guidance remains the primary forward revenue input", () => {
  const result = resolveForwardRevenueGuidance({
    ttmRevenue: 7_100,
    formulaForwardRevenue: 8_200,
    annualGuidanceM: 8_154,
    quarterlyGuidanceM: 2_160,
    guidanceMode: "explicit_full_year",
    settings: {}
  });

  assert.equal(result.scope, "explicit_full_year");
  assert.equal(result.source, "full_year_guidance");
  assert.equal(result.valuationRevenue, 8_154);
  assert.equal(result.quarterlyGuidanceM, null);
});

test("implausible explicit full-year revenue is rejected with an auditable reason", () => {
  const result = resolveForwardRevenueGuidance({
    ttmRevenue: 7_100,
    formulaForwardRevenue: 8_200,
    annualGuidanceM: 700,
    quarterlyGuidanceM: null,
    guidanceMode: "explicit_full_year",
    settings: {}
  });

  assert.equal(result.source, "formula_forward");
  assert.equal(result.scope, "explicit_full_year_rejected");
  assert.equal(result.reportedAnnualGuidanceM, 700);
  assert.equal(result.rejectionReason, "implausible_full_year_amount");
  assert.equal(result.valuationRevenue, 8_200);
});

test("normalized earnings preserve the observed below-operating burden", () => {
  const result = normalizedNetIncomePower({
    ttm: {
      revenue_m: 54_396,
      operating_income_m: 12_663,
      net_income_m: 4_924
    },
    valuationRevenue: 54_396,
    normalizedOperatingMargin: 0.224
  });

  assert.ok(result.belowOperatingIncomeBurden > 0.13);
  assert.ok(result.normalizedNetMargin < 0.09);
  assert.ok(result.netIncomeM < 4_900);
});

test("cycle burden filters a one-quarter impairment from normalized earnings", () => {
  const result = normalizedNetIncomePower({
    ttm: {
      revenue_m: 10_000,
      operating_income_m: 2_000,
      net_income_m: -2_000,
      cycle_operating_margin_pct: 19,
      cycle_net_margin_pct: 10,
      cycle_below_operating_burden_pct: 8
    },
    valuationRevenue: 10_000,
    normalizedOperatingMargin: 0.18
  });

  assert.equal(result.belowOperatingIncomeBurden, 0.08);
  assert.ok(Math.abs(result.normalizedNetMargin - 0.1) < 1e-12);
  assert.ok(Math.abs(result.netIncomeM - 1_000) < 1e-9);
});

test("a barely profitable quarter retains its observed below-operating burden", () => {
  const result = normalizedNetIncomePower({
    ttm: {
      revenue_m: 1_000,
      operating_income_m: 112.6,
      net_income_m: 3.8,
      cycle_operating_margin_pct: 7.9,
      cycle_net_margin_pct: -1.4,
      cycle_below_operating_burden_pct: 10.9
    },
    valuationRevenue: 1_000,
    normalizedOperatingMargin: 0.08
  });

  assert.ok(Math.abs(result.belowOperatingIncomeBurden - 0.1088) < 1e-12);
  assert.ok(Math.abs(result.normalizedNetMargin - 0.0038 * 0.65) < 1e-12);
});

test("losses in both the reported period and cycle cannot manufacture normalized earnings", () => {
  const result = normalizedNetIncomePower({
    ttm: {
      revenue_m: 10_000,
      operating_income_m: 190,
      net_income_m: -300,
      cycle_operating_margin_pct: 1.5,
      cycle_net_margin_pct: -2.0,
      cycle_below_operating_burden_pct: 4.0
    },
    valuationRevenue: 10_000,
    normalizedOperatingMargin: 0.08
  });

  assert.equal(result.belowOperatingIncomeBurden, null);
  assert.equal(result.normalizedNetMargin, 0);
  assert.equal(result.netIncomeM, null);
});

test("a loss-making observed period cannot impose its one-off burden on normalized earnings", () => {
  const result = normalizedNetIncomePower({
    ttm: {
      revenue_m: 53_000,
      operating_income_m: -6_500,
      net_income_m: -16_900
    },
    valuationRevenue: 55_000,
    normalizedOperatingMargin: 0.073,
    taxRate: 0.19,
    allowLossPeriodTaxFallback: true
  });

  assert.equal(result.belowOperatingIncomeBurden, null);
  assert.ok(Math.abs(result.normalizedNetMargin - 0.073 * 0.81) < 1e-12);
  assert.ok(result.netIncomeM > 3_200);
});

test("a positive reported net margin cannot disappear when normalized operating margin is lower", () => {
  const result = normalizedNetIncomePower({
    ttm: {
      revenue_m: 22_430,
      operating_income_m: 3_643,
      net_income_m: 534
    },
    valuationRevenue: 22_430,
    normalizedOperatingMargin: 0.125
  });

  assert.ok(result.belowOperatingIncomeBurden > 0.13);
  assert.ok(result.normalizedNetMargin > 0);
  assert.ok(result.normalizedNetMargin < 0.02);
  assert.ok(result.netIncomeM > 300);
});

test("financial business models separate brokers, asset managers, and insurers", () => {
  assert.equal(profileSettings("GS").profile, "capital_markets");
  assert.equal(profileSettings("APO").profile, "asset_manager");
  assert.equal(profileSettings("AON").profile, "insurance_broker");
  assert.equal(profileSettings("CB").profile, "insurance");
  assert.equal(profileSettings("PYPL").profile, "payments_processor");
  assert.equal(profileSettings("CPAY").profile, "payments_processor");
  assert.equal(profileSettings("FIS").profile, "payments_processor");
  assert.equal(profileSettings("FISV").profile, "payments_processor");
  assert.equal(profileSettings("GPN").profile, "payments_processor");
  assert.equal(profileSettings("XYZ").profile, "payments_processor");
  assert.equal(profileSettings("CNC").profile, "managed_care");
  assert.equal(profileSettings("CIEN").profile, "optical_networking_turnaround");
  assert.equal(profileSettings("COHR").profile, "optical_networking_turnaround");
});

test("customer and policyholder cash-flow businesses use through-cycle EPS rather than FCFE DCF", () => {
  const buildRows = (ticker) => buildValuationRows({
    ticker,
    trinityTicker: ticker,
    snapshot: {
      ticker,
      name: ticker,
      currency: "USD",
      priceHistory: [{ date: "2026-08-01", close: 100, source: "test" }]
    },
    companyModel: { ticker, company: ticker },
    factsUrl: "test://pit",
    quarterlyRows: Array.from({ length: 8 }, (_, index) => {
      const fiscalYear = 2024 + Math.floor(index / 4);
      const month = String(index % 4 * 3 + 2).padStart(2, "0");
      return {
        fiscalYear,
        fiscalQuarter: `Q${index % 4 + 1}`,
        label: `FY${fiscalYear} Q${index % 4 + 1}`,
        asOfDate: `${fiscalYear}-${month}-15`,
        financialAvailableAt: `${fiscalYear}-${month}-15`,
        revenue_m: 10_000 + index * 200,
        revenue_growth_pct: 8,
        operating_income_m: 1_800,
        net_income_m: 1_200,
        cfo_m: 4_500,
        capex_m: 200,
        shares_m: 1_000,
        equity_m: 12_000,
        cash_m: 8_000,
        debt_m: 2_000,
        sources: {}
      };
    }),
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  for (const ticker of ["CPAY", "FIS", "FISV", "GPN", "PYPL", "XYZ", "CNC"]) {
    const latest = buildRows(ticker).at(-1);
    assert.ok(latest);
    assert.ok(latest.methodOutputs.some((row) => row.key === "through-cycle-eps"), ticker);
    assert.ok(latest.methodOutputs.some((row) => row.key === "customer-cash-flow-exclusion"), ticker);
    assert.equal(latest.methodOutputs.some((row) => row.key === "fcfe-dcf"), false, ticker);
    assert.equal(latest.dataSnapshot.valuationSemantics.scoreInputs.equityDcf, undefined, ticker);
  }
});

test("base fair value excludes unpriced optionality premiums", () => {
  for (const ticker of ["PLTR", "NTRA", "SPCX", "TSLA"]) {
    const settings = profileSettings(ticker);
    assert.equal(settings.optionalityMultiplier, undefined, ticker);
    assert.ok(settings.bullCaseOptionalityMultiplier > 1, ticker);
  }
});

test("cyclical earnings use only the trailing point-in-time EPS anchor", () => {
  const normalized = cycleNormalizeNetIncome(
    10,
    { cycle_eps: 5, cycle_positive_eps_sample_count: 4 },
    100,
    { profile: "power_utility", earningsActualWeight: 0.68 }
  );
  assert.equal(normalized, 296);
  assert.equal(
    cycleNormalizeNetIncome(10, { cycle_eps: 5, cycle_positive_eps_sample_count: 4 }, 100, { profile: "media_telecom" }),
    10
  );
  assert.equal(
    cycleNormalizeNetIncome(10, { cycle_eps: 5, cycle_positive_eps_sample_count: 1 }, 100, { profile: "power_utility" }),
    10
  );
});

test("industry margin target cannot cap a structurally higher company margin", () => {
  const highMargin = normalizedMarginRatio(
    { operating_margin_pct: 29.16 },
    { targetMargin: 0.04, marginActualWeight: 0.7 }
  );
  const lowMargin = normalizedMarginRatio(
    { operating_margin_pct: 4 },
    { targetMargin: 0.04, marginActualWeight: 0.7 }
  );

  assert.ok(highMargin > 0.21 && highMargin < 0.22);
  assert.equal(lowMargin, 0.04);
});

test("all formerly defaulted PIT issuers have explicit valuation profiles", () => {
  for (const ticker of ["DGE.L", "ESTC", "GTLB", "IBM", "ORCL", "SNOW"]) {
    assert.equal(hasExplicitValuationProfile(ticker), true, ticker);
  }
  assert.equal(hasExplicitValuationProfile("RKLX"), false);
});

test("MSTR point-in-time supplement cannot use a later comparative disclosure", () => {
  const facts = {
    "us-gaap": {
      CryptoAssetFairValue: {
        units: {
          USD: [{ val: 1_840_028_000, filed: "2026-02-19", end: "2022-12-31", form: "10-K" }]
        }
      }
    }
  };
  const early = attachMstrCryptoMetrics(facts, [{
    fiscalYear: 2022,
    fiscalQuarter: "Q4",
    asOfDate: "2023-02-16",
    sources: {}
  }], { pointInTime: true })[0];
  const visible = attachMstrCryptoMetrics(facts, [{
    fiscalYear: 2022,
    fiscalQuarter: "Q4",
    asOfDate: "2026-02-19",
    sources: {}
  }], { pointInTime: true })[0];

  assert.equal(early.crypto_asset_fair_value_m, undefined);
  assert.equal(visible.crypto_asset_fair_value_m, 1_840.028);
});

test("FCFE DCF is monotonic in cash flow and penalizes high leverage", () => {
  const common = {
    sharesM: 100,
    growthPct: 12,
    settings: { profile: "media_telecom" },
    targetFcfYield: 0.065
  };
  const lowLeverage = buildEquityDcf({
    ...common,
    baseFcfM: 1_000,
    ttm: { cash_m: 500, debt_m: 1_000 }
  });
  const highLeverage = buildEquityDcf({
    ...common,
    baseFcfM: 1_000,
    ttm: { cash_m: 500, debt_m: 10_000 }
  });
  const higherCashFlow = buildEquityDcf({
    ...common,
    baseFcfM: 1_250,
    ttm: { cash_m: 500, debt_m: 1_000 }
  });

  assert.ok(lowLeverage.fairValue > highLeverage.fairValue);
  assert.ok(higherCashFlow.fairValue > lowLeverage.fairValue);
  assert.ok(highLeverage.discountRate > lowLeverage.discountRate);
  assert.ok(highLeverage.discountRate > highLeverage.terminalGrowth);
  assert.ok(highLeverage.terminalValueShare > 0 && highLeverage.terminalValueShare < 1);
});

test("CHTR-like leverage receives a double-digit discount rate", () => {
  const result = buildEquityDcf({
    baseFcfM: 4_735,
    sharesM: 121.255667,
    growthPct: 1,
    ttm: { cash_m: 509, debt_m: 95_555 },
    settings: { profile: "media_telecom" },
    targetFcfYield: 0.07
  });

  assert.ok(result.discountRate >= 0.145);
  assert.ok(result.fairValue > 0 && result.fairValue < 400);
  assert.ok(result.terminalValueShare < 0.8);
});

test("LSEG uses issuer-reported equity FCF when CFO and capex are unavailable", () => {
  const rows = buildValuationRows({
    ticker: "LSEG",
    trinityTicker: "LSEG",
    snapshot: {
      ticker: "LSEG",
      name: "London Stock Exchange Group",
      currency: "GBP",
      priceHistory: [{ date: "2026-07-30", close: 86.06, source: "LSEG.L adjusted close in GBP" }]
    },
    companyModel: { ticker: "LSEG", company: "London Stock Exchange Group" },
    factsUrl: "official-issuer://lseg/h1-2026",
    quarterlyRows: [{
      fiscalYear: 2026,
      fiscalQuarter: "Q2",
      label: "FY2026 Q2",
      asOfDate: "2026-07-30",
      financialAvailableAt: "2026-07-30",
      revenue_m: 9_296,
      revenue_growth_pct: 5.89,
      operating_income_m: 3_788,
      net_income_m: 2_022.513,
      cfo_m: null,
      capex_m: null,
      fcf_after_capex_m: 2_715,
      shares_m: 497,
      cash_m: null,
      debt_m: 9_982,
      pitGuidance: {
        sourceDatabase: "valuation-pit-guidance",
        fcfGuidanceM: 2_700,
        guidanceSelection: {
          revenue: { mode: "missing" },
          operatingIncome: { mode: "missing" },
          freeCashFlow: { mode: "explicit_full_year" }
        }
      },
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: {}
    }],
    youtubeByPeriod: new Map(),
    financialSource: {
      sourceType: "jansen_pit_quarterly_model",
      annualSourceType: "jansen_pit_annual_model",
      sourceQuality: "official-issuer-pit",
      annualSourceQuality: "official-issuer-pit",
      sourceName: "LSEG official issuer releases",
      eventType: "pit_quarterly_fundamental_guidance_model",
      periodIdPrefix: "lseg-pit",
      modelVersion: "test"
    }
  });

  assert.equal(rows.length, 1);
  const scoreInputs = rows[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(scoreInputs.modelRoute, "operating_company");
  assert.equal(scoreInputs.ttmFreeCashFlow, 2_715);
  assert.equal(scoreInputs.reportedFcfGuidanceM, 2_700);
  assert.equal(scoreInputs.fcfGuidanceM, 2_700);
  assert.equal(scoreInputs.rawValuationFreeCashFlow, 2_700);
  assert.equal(scoreInputs.valuationFreeCashFlow, 2_700);
  assert.ok(scoreInputs.equityDcf);
  assert.equal(scoreInputs.equityDcf.netDebtM, 9_982);
  assert.ok(scoreInputs.methodWeights["fcfe-dcf"] > 0.4);
  assert.ok(rows[0].methodOutputs.find((row) => row.key === "fcfe-dcf")?.value > 0);
  assert.match(rows[0].methodOutputs.find((row) => row.key === "fcfe-dcf")?.description, /FY guidance equity FCF/);
});

test("one profitable filing cannot unlock mature normalized earnings power", () => {
  const rows = buildValuationRows({
    ticker: "CDW",
    trinityTicker: "CDW",
    snapshot: {
      ticker: "CDW",
      name: "CDW",
      currency: "USD",
      priceHistory: [{ date: "2021-02-15", close: 20, source: "test" }]
    },
    companyModel: { ticker: "CDW", company: "CDW" },
    factsUrl: "test://pit",
    quarterlyRows: [{
      fiscalYear: 2020,
      fiscalQuarter: "Q4",
      label: "FY2020 Q4",
      asOfDate: "2021-02-15",
      financialAvailableAt: "2021-02-15",
      revenue_m: 1_000,
      operating_income_m: 80,
      net_income_m: 2,
      fcf_after_capex_m: 100,
      shares_m: 100,
      cash_m: 100,
      debt_m: 100,
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: {}
    }],
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  assert.equal(rows.length, 1);
  const scoreInputs = rows[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(scoreInputs.earningsHistoryEligible, false);
  assert.equal(scoreInputs.cyclePositiveEpsSampleCount, 1);
  assert.equal(scoreInputs.marginBasedNetIncome, null);
  assert.equal(scoreInputs.reportedEarningsAnchor, null);
  assert.equal(scoreInputs.reportedEarningsAnchorRejectionReason, "reported_earnings_below_one_percent_revenue_floor");
  assert.equal(scoreInputs.normalizedNetIncome, null);
  assert.equal(scoreInputs.earningsMethodEvidenceConfidence, 0);
  assert.equal(scoreInputs.methodWeights["normalized-earnings-power"], 0);
  assert.equal(scoreInputs.methodWeights["fcfe-dcf"], 1);
});

test("sparse reported earnings cannot capitalize below-operating one-off gains", () => {
  const rows = buildValuationRows({
    ticker: "CDW",
    trinityTicker: "CDW",
    snapshot: {
      ticker: "CDW",
      name: "CDW",
      currency: "USD",
      priceHistory: [{ date: "2021-02-15", close: 20, source: "test" }]
    },
    companyModel: { ticker: "CDW", company: "CDW" },
    factsUrl: "test://pit",
    quarterlyRows: [{
      fiscalYear: 2020,
      fiscalQuarter: "Q4",
      label: "FY2020 Q4",
      asOfDate: "2021-02-15",
      financialAvailableAt: "2021-02-15",
      revenue_m: 1_000,
      operating_income_m: 80,
      net_income_m: 200,
      fcf_after_capex_m: 100,
      shares_m: 100,
      cash_m: 100,
      debt_m: 100,
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: {}
    }],
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  const scoreInputs = rows[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(scoreInputs.earningsHistoryEligible, false);
  assert.ok(Math.abs(scoreInputs.reportedEarningsAnchor - 58.32) < 1e-9);
  assert.ok(Math.abs(scoreInputs.normalizedNetIncome - 58.32) < 1e-9);
  assert.ok(Math.abs(scoreInputs.earningsMethodEvidenceConfidence - 0.3) < 1e-12);
  assert.equal(scoreInputs.freeCashFlowMethodEvidenceConfidence, 0.25);
  assert.equal(scoreInputs.methodWeights["normalized-earnings-power"], 0.5);
  assert.equal(scoreInputs.methodWeights["fcfe-dcf"], 0.5);
});

test("materials valuation waits for four independent profitable periods", () => {
  const quarterlyRows = [1, 2, 3, 4].map((quarter) => ({
    fiscalYear: 2020,
    fiscalQuarter: `Q${quarter}`,
    label: `FY2020 Q${quarter}`,
    asOfDate: `2020-${String(quarter * 3).padStart(2, "0")}-28`,
    financialAvailableAt: `2020-${String(quarter * 3).padStart(2, "0")}-28`,
    revenue_m: 1_000,
    operating_income_m: 100,
    net_income_m: 80,
    fcf_after_capex_m: 70,
    shares_m: 100,
    cash_m: 100,
    debt_m: 100,
    sourceRecord: { metricsAreTrailingTwelveMonths: true },
    sources: {}
  }));
  const rows = buildValuationRows({
    ticker: "DD",
    trinityTicker: "DD",
    snapshot: {
      ticker: "DD",
      name: "DuPont",
      currency: "USD",
      priceHistory: quarterlyRows.map((row) => ({ date: row.asOfDate, close: 20, source: "test" }))
    },
    companyModel: { ticker: "DD", company: "DuPont" },
    factsUrl: "test://pit",
    quarterlyRows,
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  assert.equal(rows.length, 1);
  const mature = rows[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(mature.cyclePositiveEpsSampleCount, 4);
  assert.ok(mature.methodWeights["normalized-earnings-power"] > 0);
});

test("a low requested DCF allocation is not promoted to half the valuation", () => {
  const quarterlyRows = [
    { quarter: 1, fcf: null },
    { quarter: 2, fcf: 100 }
  ].map(({ quarter, fcf }) => ({
    fiscalYear: 2020,
    fiscalQuarter: `Q${quarter}`,
    label: `FY2020 Q${quarter}`,
    asOfDate: `2020-${String(quarter * 3).padStart(2, "0")}-28`,
    financialAvailableAt: `2020-${String(quarter * 3).padStart(2, "0")}-28`,
    revenue_m: 1_000,
    operating_income_m: 120,
    net_income_m: 80,
    fcf_after_capex_m: fcf,
    shares_m: 100,
    cash_m: 100,
    debt_m: 100,
    sourceRecord: { metricsAreTrailingTwelveMonths: true },
    sources: {}
  }));
  const rows = buildValuationRows({
    ticker: "AEP",
    trinityTicker: "AEP",
    snapshot: {
      ticker: "AEP",
      name: "American Electric Power",
      currency: "USD",
      priceHistory: quarterlyRows.map((row) => ({ date: row.asOfDate, close: 20, source: "test" }))
    },
    companyModel: { ticker: "AEP", company: "American Electric Power" },
    factsUrl: "test://pit",
    quarterlyRows,
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  const scoreInputs = rows[1].dataSnapshot.valuationSemantics.scoreInputs;
  assert.ok(scoreInputs.methodWeights["normalized-earnings-power"] > 0.85);
  assert.ok(scoreInputs.methodWeights["fcfe-dcf"] < 0.15);
});

test("an immature corroborative utility DCF cannot become the sole valuation method", () => {
  const quarterlyRows = [1, 2, 3, 4, 5].map((quarter) => ({
    fiscalYear: 2020 + Math.floor((quarter - 1) / 4),
    fiscalQuarter: `Q${((quarter - 1) % 4) + 1}`,
    label: `period ${quarter}`,
    asOfDate: `202${Math.floor((quarter - 1) / 4)}-${String((((quarter - 1) % 4) + 1) * 3).padStart(2, "0")}-28`,
    financialAvailableAt: `202${Math.floor((quarter - 1) / 4)}-${String((((quarter - 1) % 4) + 1) * 3).padStart(2, "0")}-28`,
    revenue_m: 1_000,
    operating_income_m: 80,
    net_income_m: -20,
    cfo_m: 200,
    capex_m: 100,
    fcf_after_capex_m: 100,
    shares_m: 100,
    cash_m: 100,
    debt_m: 100,
    sourceRecord: { metricsAreTrailingTwelveMonths: true },
    sources: {}
  }));
  const rows = buildValuationRows({
    ticker: "AEP",
    trinityTicker: "AEP",
    snapshot: {
      ticker: "AEP",
      name: "American Electric Power",
      currency: "USD",
      priceHistory: quarterlyRows.map((row) => ({ date: row.asOfDate, close: 20, source: "test" }))
    },
    companyModel: { ticker: "AEP", company: "American Electric Power" },
    factsUrl: "test://pit",
    quarterlyRows,
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  assert.equal(rows.length, 1);
  const scoreInputs = rows[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(scoreInputs.cyclePositiveFcfSampleCount, 5);
  assert.equal(scoreInputs.methodWeights["normalized-earnings-power"], 0);
  assert.equal(scoreInputs.methodWeights["fcfe-dcf"], 1);
});

test("newly mature but economically de minimis earnings do not dilute DCF", () => {
  const quarterlyRows = [1, 2, 3, 4].map((quarter) => ({
    fiscalYear: 2020,
    fiscalQuarter: `Q${quarter}`,
    label: `FY2020 Q${quarter}`,
    asOfDate: `2020-${String(quarter * 3).padStart(2, "0")}-28`,
    financialAvailableAt: `2020-${String(quarter * 3).padStart(2, "0")}-28`,
    revenue_m: 2_700,
    operating_income_m: 192,
    net_income_m: 19,
    fcf_after_capex_m: 240,
    shares_m: 130,
    cash_m: 100,
    debt_m: 100,
    sourceRecord: { metricsAreTrailingTwelveMonths: true },
    sources: {}
  }));
  const rows = buildValuationRows({
    ticker: "VMC",
    trinityTicker: "VMC",
    snapshot: {
      ticker: "VMC",
      name: "Vulcan Materials",
      currency: "USD",
      priceHistory: quarterlyRows.map((row) => ({ date: row.asOfDate, close: 20, source: "test" }))
    },
    companyModel: { ticker: "VMC", company: "Vulcan Materials" },
    factsUrl: "test://pit",
    quarterlyRows,
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  const scoreInputs = rows.at(-1).dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(scoreInputs.earningsHistoryEligible, true);
  assert.equal(scoreInputs.normalizedNetIncome, null);
  assert.equal(scoreInputs.normalizedNetIncomeRejectionReason, "normalized_earnings_below_one_percent_revenue_floor");
  assert.equal(scoreInputs.methodWeights["normalized-earnings-power"], 0);
  assert.equal(scoreInputs.methodWeights["fcfe-dcf"], 1);
});

test("loss-making optical-networking equity residual below twenty percent is unmodeled", () => {
  const rows = buildValuationRows({
    ticker: "LITE",
    trinityTicker: "LITE",
    snapshot: {
      ticker: "LITE",
      name: "Lumentum",
      currency: "USD",
      priceHistory: [{ date: "2025-02-06", close: 70, source: "test" }]
    },
    companyModel: { ticker: "LITE", company: "Lumentum" },
    factsUrl: "test://pit",
    quarterlyRows: [{
      fiscalYear: 2025,
      fiscalQuarter: "Q2",
      label: "FY2025 Q2",
      asOfDate: "2025-02-06",
      financialAvailableAt: "2025-02-06",
      revenue_m: 1_414,
      operating_income_m: -382,
      net_income_m: -523,
      fcf_after_capex_m: -50,
      shares_m: 69.2,
      cash_m: 500,
      debt_m: 4_400,
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: {}
    }],
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  assert.equal(profileSettings("LITE").minimumSalesEquityRetention, 0.2);
  assert.equal(rows.length, 0);
});

test("cyclical profiles phase in a conservative reported-FCF anchor before four independent observations", () => {
  const rows = buildValuationRows({
    ticker: "URI",
    trinityTicker: "URI",
    snapshot: {
      ticker: "URI",
      name: "United Rentals",
      currency: "USD",
      priceHistory: [{ date: "2021-02-15", close: 20, source: "test" }]
    },
    companyModel: { ticker: "URI", company: "United Rentals" },
    factsUrl: "test://pit",
    quarterlyRows: [{
      fiscalYear: 2020,
      fiscalQuarter: "Q4",
      label: "FY2020 Q4",
      asOfDate: "2021-02-15",
      financialAvailableAt: "2021-02-15",
      revenue_m: 1_000,
      operating_income_m: 100,
      net_income_m: 60,
      cfo_m: 150,
      capex_m: 50,
      fcf_after_capex_m: 100,
      shares_m: 100,
      cash_m: 100,
      debt_m: 100,
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: {}
    }],
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "test", modelVersion: "test" }
  });

  assert.equal(rows.length, 1);
  const scoreInputs = rows[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(scoreInputs.cyclePositiveFcfSampleCount, 1);
  assert.equal(scoreInputs.cycleFreeCashFlow, null);
  assert.equal(scoreInputs.reportedFreeCashFlowAnchor, 25);
  assert.equal(scoreInputs.freeCashFlowEvidenceConfidence, 0.25);
  assert.equal(scoreInputs.freeCashFlowNormalizationReason, "sparse_reported_fcf_anchor");
  assert.equal(scoreInputs.normalizedFreeCashFlow, 25);
  assert.equal(scoreInputs.valuationFreeCashFlow, 25);
  assert.ok(scoreInputs.methodWeights["fcfe-dcf"] > 0);
});

test("a de minimis sparse FCF observation cannot create a false-precision DCF", () => {
  const result = valuationFreeCashFlow({
    revenue_m: 1_000,
    fcf_after_capex_m: 5,
    cycle_positive_fcf_sample_count: 1
  }, {
    normalizeFcfAcrossCycle: true
  });

  assert.equal(result.normalizedFcf, null);
  assert.equal(result.reportedFcfAnchor, null);
  assert.equal(result.rejectionReason, "reported_fcf_below_one_percent_revenue_floor");
});

test("operating-company model consumes only scoped and plausible annual guidance", () => {
  const buildRows = (pitGuidance) => buildValuationRows({
    ticker: "IBM",
    trinityTicker: "IBM",
    snapshot: {
      ticker: "IBM",
      name: "IBM",
      currency: "USD",
      priceHistory: [{ date: "2026-07-23", close: 250, source: "adjusted close" }]
    },
    companyModel: { ticker: "IBM", company: "IBM" },
    factsUrl: "provider://ibm/test",
    quarterlyRows: [{
      fiscalYear: 2026,
      fiscalQuarter: "Q2",
      label: "FY2026 Q2",
      asOfDate: "2026-07-23",
      periodEndDate: "2026-06-30",
      revenue_m: 70_000,
      revenue_growth_pct: 5,
      operating_income_m: 14_000,
      net_income_m: 9_000,
      fcf_after_capex_m: 11_000,
      shares_m: 930,
      cash_m: 12_000,
      debt_m: 55_000,
      pitGuidance,
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: {}
    }],
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "Jansen Sharadar SF1", modelVersion: "test" }
  });

  const scoped = buildRows({
    revenueGuidanceM: 74_000,
    operatingIncomeGuidanceM: 15_000,
    fcfGuidanceM: 12_000,
    guidanceSelection: {
      revenue: { mode: "explicit_full_year" },
      operatingIncome: { mode: "explicit_full_year" },
      freeCashFlow: { mode: "explicit_full_year" }
    }
  })[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(scoped.forwardRevenueSource, "full_year_guidance");
  assert.equal(scoped.valuationRevenue, 74_000);
  assert.equal(scoped.guidanceOperatingIncomeM, 15_000);
  assert.equal(scoped.fcfGuidanceM, 12_000);
  assert.equal(scoped.rawValuationFreeCashFlow, 12_000);

  const unscoped = buildRows({
    revenueUnscopedGuidanceM: 74_000,
    operatingIncomeGuidanceM: 15_000,
    fcfGuidanceM: 12_000,
    guidanceSelection: {
      revenue: { mode: "unscoped_fallback" },
      operatingIncome: { mode: "unscoped_fallback" },
      freeCashFlow: { mode: "unscoped_fallback" }
    }
  })[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.equal(unscoped.forwardRevenueSource, "formula_forward");
  assert.equal(unscoped.guidanceOperatingIncomeM, null);
  assert.equal(unscoped.fcfGuidanceM, null);
  assert.equal(unscoped.rawValuationFreeCashFlow, 11_000);
});

test("later source-share changes never retroactively rescale a PIT fair value", () => {
  const buildRows = (quarterlyRows) => buildValuationRows({
    ticker: "LSEG",
    trinityTicker: "LSEG",
    snapshot: {
      ticker: "LSEG",
      name: "London Stock Exchange Group",
      currency: "GBP",
      priceHistory: [
        { date: "2025-02-28", close: 114, source: "adjusted close" },
        { date: "2025-07-31", close: 108, source: "adjusted close" }
      ]
    },
    companyModel: { ticker: "LSEG", company: "London Stock Exchange Group" },
    factsUrl: "official-issuer://lseg/test",
    quarterlyRows,
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "official issuer PIT", modelVersion: "test" }
  });
  const first = {
    fiscalYear: 2025,
    fiscalQuarter: "Q1",
    label: "FY2025 Q1",
    asOfDate: "2025-02-28",
    periodEndDate: "2025-03-31",
    revenue_m: 8_800,
    operating_income_m: 3_300,
    net_income_m: 1_600,
    fcf_after_capex_m: 2_300,
    shares_m: 500,
    debt_m: 10_000,
    sourceRecord: { eventDate: "2025-02-28", metricsAreTrailingTwelveMonths: true },
    sources: {}
  };
  const second = {
    ...first,
    fiscalQuarter: "Q2",
    label: "FY2025 Q2",
    asOfDate: "2025-07-31",
    periodEndDate: "2025-06-30",
    shares_m: 1_000,
    sourceRecord: { eventDate: "2025-07-31", metricsAreTrailingTwelveMonths: true }
  };

  const standalone = buildRows([first]);
  const combined = buildRows([first, second]);

  assert.equal(combined[0].fairValue, standalone[0].fairValue);
  assert.equal(combined[0].targetPrice3Y, standalone[0].targetPrice3Y);
  assert.equal(combined[0].dataSnapshot.valuationSemantics.shareBasisAdjustmentFactor, undefined);
  assert.match(combined[0].dataSnapshot.valuationSemantics.shareBasisPolicy, /never retroactively rescale/i);
});

test("near-zero EV-to-equity residual is excluded instead of publishing false precision", () => {
  const rows = buildValuationRows({
    ticker: "BE",
    trinityTicker: "BE",
    snapshot: {
      ticker: "BE",
      name: "Bloom Energy",
      currency: "USD",
      priceHistory: [{ date: "2020-11-06", close: 14.63, source: "adjusted close" }]
    },
    companyModel: { ticker: "BE", company: "Bloom Energy" },
    factsUrl: "provider://be/test",
    quarterlyRows: [{
      fiscalYear: 2020,
      fiscalQuarter: "Q3",
      label: "FY2020 Q3",
      asOfDate: "2020-11-06",
      periodEndDate: "2020-09-30",
      revenue_m: 662.077,
      operating_income_m: -210,
      net_income_m: -253.269,
      fcf_after_capex_m: -160,
      shares_m: 166.19838,
      cash_m: 372.453,
      debt_m: 1_034.485,
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: {}
    }],
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "Jansen Sharadar SF1", modelVersion: "test" }
  });

  assert.deepEqual(rows, []);
});

test("material positive EV-to-equity residual remains usable", () => {
  const rows = buildValuationRows({
    ticker: "BE",
    trinityTicker: "BE",
    snapshot: {
      ticker: "BE",
      name: "Bloom Energy",
      currency: "USD",
      priceHistory: [{ date: "2024-11-07", close: 10.97, source: "adjusted close" }]
    },
    companyModel: { ticker: "BE", company: "Bloom Energy" },
    factsUrl: "provider://be/test",
    quarterlyRows: [{
      fiscalYear: 2024,
      fiscalQuarter: "Q3",
      label: "FY2024 Q3",
      asOfDate: "2024-11-07",
      periodEndDate: "2024-09-30",
      revenue_m: 1_258.38,
      operating_income_m: -80,
      net_income_m: -129.511,
      fcf_after_capex_m: -50,
      shares_m: 228.575978,
      cash_m: 549.151,
      debt_m: 1_694.25,
      sourceRecord: { metricsAreTrailingTwelveMonths: true },
      sources: {}
    }],
    youtubeByPeriod: new Map(),
    financialSource: { sourceName: "Jansen Sharadar SF1", modelVersion: "test" }
  });

  assert.equal(rows.length, 1);
  const score = rows[0].dataSnapshot.valuationSemantics.scoreInputs;
  assert.ok(score.salesEquityRetention > 0.01);
  assert.equal(score.salesValueRejectionReason, null);
});
