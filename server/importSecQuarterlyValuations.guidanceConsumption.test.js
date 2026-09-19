import assert from "node:assert/strict";
import test from "node:test";
import { digestGuidanceMetrics } from "./importSecQuarterlyValuations.js";
import { readPitGuidance } from "./importPitQuarterlyValuations.js";
import { DatabaseSync } from "node:sqlite";

function sourceMetric(id, quote, { amount = null, growth = null, scope = "full_year", subject = "company_total_or_unspecified", quality = "clear", sourceType = "downloaded_online_earnings_transcript", position = quote.toLowerCase().indexOf("revenue") } = {}) {
  return { id, evidence_id: id, source_type: sourceType,
    actual_or_guidance: "guidance", metric_name: "revenue_guidance",
    observed_at: "2026-08-01", fiscal_period: "Q22026", amount,
    model_amount_m: amount, currency: "USD", unit: "reported millions",
    growth_yoy: growth, quality_status: quality,
    evidence_excerpt: quote, value_text: quote, excerpt: quote,
    payload_json: JSON.stringify({ guidance_scope: scope, guidance_subject: subject, metric_position: position }) };
}

test("named-month quarterly targets survive but fiscal-year month dates and old-quarter comparisons do not supply quarterly scope", () => {
  for (const [id, quote, amount] of [
    ["4d04c34114525e56ba498b53", "With better context, June quarter revenue is expected to be in the range of $1.85 billion Â± $150 million, an increase of 12% sequentially and 16% year-on-year at the midpoint.", 1850],
    ["d176ad17aaa6be0cafa460cc", "With that as context, September quarter revenue is expected to be in a range of $2.1 billion Â± $150 million, an increase of 11% sequentially and 44% year-over-year at the midpoint.", 2100],
    ["b4a56e39df17c0bd4da88ef9", "We expect September quarter revenue to be in a range of $4.1 billion Â± $100 million, which represents a 56% year-over-year improvement at the midpoint.", 4100],
  ]) {
    const result = digestGuidanceMetrics([sourceMetric(id, quote, { amount, scope: "quarter" })], { sourceDatabase: "valuation-pit-guidance" });
    assert.equal(result.revenueQuarterGuidanceM, amount);
    assert.deepEqual(result.guidanceSelection.revenue.quarterEvidenceIds, [id]);
  }
  for (const quote of ["For the fiscal year ending June 2026, we expect revenue of $4 billion.", "For full-year 2026, we expect revenue of $4 billion, compared with the prior June quarter."]) {
    assert.equal(digestGuidanceMetrics([sourceMetric("wrong-quarter", quote, { amount: 4000, scope: "quarter" })], { sourceDatabase: "valuation-pit-guidance" }).revenueQuarterGuidanceM, null);
  }
});

test("typed source with unresolved target period stays research and contributes no money or growth", () => {
  const original = "We expect the $50 million-$55 million in revenue to be recovered throughout the rest of the calendar year, so it is deferred, not lost.";
  const row = sourceMetric("021c35bc5fc20098faaaa6cb", original, { amount: 52.5, growth: 8, scope: null });
  const result = digestGuidanceMetrics([row]);
  assert.equal(result.revenueGuidanceM, null);
  assert.equal(result.revenueUnscopedGuidanceM, null);
  assert.equal(result.revenueQuarterGuidanceM, null);
  assert.equal(result.revenueGuidanceGrowth, null);
  assert.deepEqual(result.guidanceSelection.revenue.unscopedEvidenceIds, []);
  assert.deepEqual(result.scalarEvidenceIds.revenueGuidanceGrowth, []);
  assert.equal(result.evidence[0].excerpt, original);
  assert.equal(result.rejectedSourceGuidance[0].reason, "source_target_period_unresolved");
});

test("a historical currency amount reported in revenue cannot be turned into a forecast by prior guidance wording", () => {
  const quote = "For the first quarter, Agilent reported $1.8 billion in revenue, growing 4.4% on a core basis within our November guidance range.";
  const result = digestGuidanceMetrics([sourceMetric("353c91f517b7f391d5ebc35e", quote, { amount: 1800, growth: 4.4, scope: "quarter" })]);
  assert.equal(result.revenueQuarterGuidanceM, null);
  assert.equal(result.revenueGuidanceGrowth, null);
  assert.equal(result.evidence[0].excerpt, quote);
});

test("actual revenue beats and the amount of the beat are not new management targets", () => {
  for (const quote of [
    "For the quarter, worldwide net sales of $121.2 billion exceeded the top end of our revenue guidance range and represented an increase of 10% year-over-year.",
    "The company closed the first quarter with sales of $1,560 million and a diluted EPS of $0.71, exceeding the high end of the company's guidance for sales and EPS by $25 million and $0.04 respectively.",
  ]) {
    for (const owner of [...quote.matchAll(/\b(?:revenue|sales)\b/g)]) {
      const result = digestGuidanceMetrics([sourceMetric("actual-beat", quote, { amount: 25, growth: 10, scope: "quarter", position: owner.index })]);
      assert.equal(result.revenueQuarterGuidanceM, null, quote);
      assert.equal(result.revenueGuidanceGrowth, null, quote);
      assert.equal(result.evidence[0].excerpt, quote);
    }
  }
  const current = "For the next quarter, we expect revenue of $1.6 billion, exceeding our previous guidance of $1.5 billion.";
  assert.equal(digestGuidanceMetrics([sourceMetric("current-beat", current, { amount: 1600, scope: "quarter" })]).revenueQuarterGuidanceM, 1600);
});

test("named business run rates, brand sales and currency drags remain research rather than company levels", () => {
  for (const quote of [
    "We expect our revenue for HAPS business this year to roughly be equivalent to our run rate of last fiscal year, which is around $60 million.",
    "For the full year, we still expect UGG brand sales to increase by approximately 4%.",
    "For the full year, we expect an approximate $265 million impact to revenues.",
  ]) {
    const owner = [...quote.matchAll(/\b(?:revenues?|sales)\b/g)][0];
    const result = digestGuidanceMetrics([sourceMetric("component", quote, { amount: 60, growth: 4, position: owner.index })]);
    assert.equal(result.revenueGuidanceM, null);
    assert.equal(result.revenueGuidanceGrowth, null);
    assert.equal(result.evidence[0].excerpt, quote);
  }
  assert.equal(digestGuidanceMetrics([sourceMetric("total", "For the full year, we expect total revenue of $600 million.", { amount: 600 })]).revenueGuidanceM, 600);
});

test("expense-to-revenue denominators and explicitly excluded business owners never borrow neighboring money", () => {
  const quote = "In addition, for Q2 2022, we expect non-GAAP gross margin to be approximately 54%, non-GAAP operating expenses to be approximately $1.56 billion or 24% of revenue, non-GAAP interest expense, taxes and other to be approximately $270 million.";
  const result = digestGuidanceMetrics([sourceMetric("6a597fe5fa23236287865594", quote, { amount: 270, growth: 24, scope: "quarter" })]);
  assert.equal(result.revenueQuarterGuidanceM, null);
  assert.equal(result.revenueGuidanceGrowth, null);
  const excluded = "For the year, we forecast total underlying base business organic sales growth, which excludes COVID testing sales, to be in the range of 8%-10%.";
  const subset = sourceMetric("18bffc3ee99b7dbc665d3621", excluded, { growth: 9, position: excluded.lastIndexOf("sales") });
  assert.equal(digestGuidanceMetrics([subset]).revenueGuidanceGrowth, null);
});

test("an annual FCF level survives a different later long-term conversion target", () => {
  const quote = "We continue to expect over $1.5 billion of free cash flow for the full year, with full-year free cash flow conversion toward the high end of our long-term target range of 75%-85%.";
  const row = { ...sourceMetric("d676498fd7e29e5e581e7517", quote, { amount: 1500, position: quote.indexOf("free cash flow") }), metric_name: "free_cash_flow_guidance" };
  const result = digestGuidanceMetrics([row]);
  assert.equal(result.fcfGuidanceM, 1500);
  assert.deepEqual(result.guidanceSelection.freeCashFlow.acceptedEvidenceIds, [row.id]);
});

test("annual EBIT level is distinct from other targets in its paragraph and from EBIT charges", () => {
  const quote = "For the full year 2025, we expect adjusted EBIT of $6 billion-$6.5 billion and free cash flow of $2 billion-$3 billion.";
  const row = { ...sourceMetric("current-ebit", quote, { amount: 6250, position: quote.indexOf("adjusted EBIT") }), metric_name: "operating_income_guidance" };
  assert.equal(digestGuidanceMetrics([row]).operatingIncomeGuidanceM, 6250);
  for (const invalid of ["This year, we expect to incur $3 billion-$3.5 billion of the EBIT charges, with negative cash effects of $1 billion.", "For Q4, we expect an FX drag of $37 million on EBIT.", "For Q1, we expect adjusted EBIT to be down $1.1 billion from 2019."]) {
    const offset = invalid.indexOf("adjusted EBIT") >= 0 ? invalid.indexOf("adjusted EBIT") : invalid.indexOf("EBIT");
    const bad = { ...sourceMetric("driver", invalid, { amount: 3250, position: offset, scope: invalid.includes("This year") ? "full_year" : "quarter" }), metric_name: "operating_income_guidance" };
    const result = digestGuidanceMetrics([bad]);
    assert.equal(result.operatingIncomeGuidanceM, null);
    assert.equal(result.guidanceSelection.operatingIncome.quarterlyAmountM, null);
  }
});

test("clear total-company labels do not turn historical deferred revenue into a forecast", () => {
  for (const [id, quote] of [
    ["ea63336f43e80a6316437401", "This reduced the number of shipping days in China, and we estimate shifted $10 million in revenue out of Q1."],
    ["6ea02000f7e537f2ec1f0c69", "We estimate the lockdowns deferred $50 million-$55 million of revenue into future quarters, impacting growth in Q2 by roughly 350 basis points."]
  ]) {
    const result = digestGuidanceMetrics([sourceMetric(id, quote, { amount: 10, scope: "quarter" })]);
    assert.equal(result.revenueQuarterGuidanceM, null);
    assert.deepEqual(result.guidanceSelection.revenue.quarterEvidenceIds, []);
    assert.equal(result.evidence[0].excerpt, quote);
    assert.equal(result.rejectedSourceGuidance[0].reason, "source_owned_quote_is_not_forward");
  }
});

test("valid original quarterly and annual targets retain exact independent contributor IDs", () => {
  const quarter = sourceMetric("quarter", "For Q3, we expect revenue of $120 million, up 10% year-over-year.", { amount: 120, growth: 10, scope: "quarter" });
  const annual = sourceMetric("annual", "For the full year, we expect revenue of $500 million, up 12% year-over-year.", { amount: 500, growth: 12 });
  const result = digestGuidanceMetrics([quarter, annual]);
  assert.equal(result.revenueQuarterGuidanceM, 120);
  assert.equal(result.revenueGuidanceM, 500);
  assert.equal(result.revenueGuidanceGrowth, 11);
  assert.deepEqual(result.guidanceSelection.revenue.acceptedEvidenceIds, ["annual"]);
  assert.deepEqual(result.guidanceSelection.revenue.quarterEvidenceIds, ["quarter"]);
  assert.equal(result.evidence.length, 2);
});

test("unusable official evidence does not suppress a separately valid transcript target", () => {
  const official = sourceMetric("official-unscoped", "We expect revenue of $900 million.", { amount: 900, scope: null, sourceType: "official_issuer_sec_filing" });
  const transcript = sourceMetric("transcript-annual", "For fiscal 2026, we expect revenue of $500 million.", { amount: 500 });
  const result = digestGuidanceMetrics([official, transcript]);
  assert.equal(result.revenueGuidanceM, 500);
  assert.deepEqual(result.guidanceSelection.revenue.acceptedEvidenceIds, ["transcript-annual"]);
  assert.equal(result.evidence.length, 2);
});

test("owned source scope must be supported by the original text, not the classification label", () => {
  const result = digestGuidanceMetrics([sourceMetric("forged-annual", "For Q3, we expect revenue of $120 million.", { amount: 120, scope: "full_year" })]);
  assert.equal(result.revenueGuidanceM, null);
  assert.equal(result.rejectedSourceGuidance[0].reason, "source_target_period_not_supported_by_owned_quote");
});

test("a company-total label cannot override an explicitly named cloud revenue owner", () => {
  const result = digestGuidanceMetrics([sourceMetric("cloud", "For the full year, we expect cloud revenue to grow 35%.", { growth: 35, subject: "company_total" })]);
  assert.equal(result.revenueGuidanceGrowth, null);
  assert.equal(result.rejectedSourceGuidance[0].reason, "source_owned_quote_is_segment_or_subset");
});

test("ambiguous typed money and stale owner offsets cannot contribute to a model", () => {
  const quote = "For the full year, we expect revenue of $500 million.";
  for (const row of [sourceMetric("ambiguous", quote, { amount: 500, quality: "ambiguous" }),
    sourceMetric("wrong-owner", quote, { amount: 500, position: 0 })]) {
    const result = digestGuidanceMetrics([row]);
    assert.equal(result.revenueGuidanceM, null);
    assert.equal(result.evidence[0].excerpt, quote);
  }
});

test("the consumption producer does not depend on the independent source auditor", async () => {
  const { readFile } = await import("node:fs/promises");
  const source = await readFile(new URL("./importSecQuarterlyValuations.js", import.meta.url), "utf8");
  assert.doesNotMatch(source, /import[^;]*(?:guidanceCoverageReleaseAudit|guidanceEvidenceAudit|guidancePerShareEvidenceAudit)/);
});

test("the old incomplete official authority quote cannot become a full-year FCF target", () => {
  const quote = "Equity free cash flow of at least GBP 2.4 billion.";
  const row = { ...sourceMetric("incomplete-official", quote, { amount: 2400, sourceType: "official_issuer_results_release", position: quote.indexOf("free cash flow") }),
    metric_name: "free_cash_flow_guidance", currency: "GBP" };
  const result = digestGuidanceMetrics([row], { sourceDatabase: "valuation-pit-guidance" });
  assert.equal(result.fcfGuidanceM, null);
  assert.equal(result.evidence[0].excerpt, quote);
  assert.equal(result.guidanceConsumptionPolicy.missingUsableTargetIsNotNoManagementGuidance, true);
  assert.equal(result.rejectedSourceGuidance[0].reason, "source_target_period_not_supported_by_owned_quote");
});

test("PIT numerical route cannot use the legacy untyped display compatibility path", () => {
  const row = sourceMetric("missing-type", "For the full year, we expect revenue of $500 million.", { amount: 500 });
  delete row.source_type;
  const result = digestGuidanceMetrics([row], { sourceDatabase: "valuation-pit-guidance" });
  assert.equal(result.revenueGuidanceM, null);
  assert.equal(result.rejectedSourceGuidance[0].reason, "pit_source_identity_missing");
  assert.equal(result.evidence[0].id, "missing-type");
});

test("readPitGuidance retains unknown and empty source types as research but rejects their numerical inputs", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec("CREATE TABLE pit_guidance_events (id TEXT,ticker TEXT,fiscal_period TEXT,observed_at TEXT,actual_or_guidance TEXT,metric_name TEXT,amount REAL,unit TEXT,currency TEXT,quality_status TEXT,evidence_excerpt TEXT,value_text TEXT,source_type TEXT,payload_json TEXT); CREATE TABLE pit_financial_periods (ticker TEXT,currency TEXT,available_at TEXT,payload_json TEXT)");
    db.prepare("INSERT INTO pit_financial_periods VALUES(?,?,?,?)").run("TEST", "USD", "2026-01-01", JSON.stringify({ reportingCurrency: "USD" }));
    const quote = "For the full year, we expect revenue of $500 million.";
    const insert = db.prepare("INSERT INTO pit_guidance_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
    for (const [id, type] of [["empty", ""], ["null", null], ["unknown", "unreviewed_blog"]]) {
      insert.run(id, "TEST", "Q22026", "2026-08-01", "guidance", "revenue_guidance", 500, "reported millions", "USD", "clear", quote, quote, type,
        JSON.stringify({ guidance_scope: "full_year", guidance_subject: "company_total", metric_position: quote.indexOf("revenue") }));
    }
    const result = readPitGuidance(db, ["TEST"]);
    assert.equal(result.rows.length, 3);
    const digest = result.byPeriod.get("TEST::Q22026");
    assert.equal(digest.revenueGuidanceM, null);
    assert.equal(digest.rejectedSourceGuidance.length, 3);
    assert.equal(digest.evidence.length, 3);
    assert.deepEqual(digest.guidanceSelection.revenue.acceptedEvidenceIds, []);
  } finally { db.close(); }
});

test("reported revenue is a forecast basis adjective, not the past-tense verb reported", () => {
  const quote = "We now expect our full year reported revenue to be in the range of $6.91 billion- $6.93 billion.";
  const row = sourceMetric("db24105ae37d1978bd212817", quote, { amount: 6920 });
  const result = digestGuidanceMetrics([row], { sourceDatabase: "valuation-pit-guidance" });
  assert.equal(result.revenueGuidanceM, 6920);
  const historical = "For the full year, we reported revenue of $6.92 billion, above our prior guidance.";
  assert.equal(digestGuidanceMetrics([sourceMetric("reported-actual", historical, { amount: 6920 })], { sourceDatabase: "valuation-pit-guidance" }).revenueGuidanceM, null);
});

test("a current raised expected range remains forward rather than being mistaken for past expected", () => {
  const quote = "As Mike indicated, we are raising our full year core revenue growth to an expected range of 7%-8%, up from our initial guide in November of 5.5%-7%.";
  const result = digestGuidanceMetrics([sourceMetric("ff9bb23451af8a65f7058922", quote, { growth: 7.5 })], { sourceDatabase: "valuation-pit-guidance" });
  assert.equal(result.revenueGuidanceGrowth, 7.5);
});

test("the immediate explicit annual guidance heading scopes the following original target", () => {
  const quote = "Looking ahead to the full year, we are raising our guidance for both revenue and EPS. We now expect revenue of $3.4 billion-$3.435 billion, which is up 6%-7% year-over-year as reported, or up 5%-6% in constant currency.";
  const row = sourceMetric("a22a4cf55a708ab9affdfba4", quote, { amount: 3417.5, growth: 6.5, position: quote.indexOf("revenue of") });
  const result = digestGuidanceMetrics([row], { sourceDatabase: "valuation-pit-guidance" });
  assert.equal(result.revenueGuidanceM, 3417.5);
  assert.equal(result.revenueGuidanceGrowth, 6.5);
  const unrelated = "The full year results were strong. We now expect revenue of $3.4 billion.";
  assert.equal(digestGuidanceMetrics([sourceMetric("unrelated-period", unrelated, { amount: 3400 })], { sourceDatabase: "valuation-pit-guidance" }).revenueGuidanceM, null);
});

test("dated annual current-guidance table header is not a historical results column", () => {
  const quote = "Year ended 31 December 2025 | Updated guidance. Sales | Increase in the range of 8% to 10%";
  const row = sourceMetric("882014c7cfd0df4c54a5d258", quote, { growth: 9, sourceType: "official_issuer_results_release", position: quote.indexOf("Sales") });
  assert.equal(digestGuidanceMetrics([row], { sourceDatabase: "valuation-pit-guidance" }).revenueGuidanceGrowth, 9);
  const historical = quote.replace("Updated guidance", "Historical results");
  assert.equal(digestGuidanceMetrics([sourceMetric("historical-table", historical, { growth: 9, sourceType: "official_issuer_results_release", position: historical.indexOf("Sales") })], { sourceDatabase: "valuation-pit-guidance" }).revenueGuidanceGrowth, null);
});
