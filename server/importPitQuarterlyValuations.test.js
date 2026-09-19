import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { assertSafeImportMode, compactSnapshotPriceHistory, guidanceCoverageBlockers, issuerReviewBlockers, publicationMetadata, readPitGuidance } from "./importPitQuarterlyValuations.js";

test("published comparison-price proofs keep source hashes without private workstation paths", () => {
  const snapshot = { ticker: "TEST", latest: { baseFairValue: 12.5 }, priceHistory: [
    { date: "2026-08-28", close: 10, source: "sharadar-paid-api-split-adjusted", sourceEvidence: {
      origin: "/Users/research/private/original-price-response.json", originalRowSha256: "exact-original-row-hash",
      sourceCutoff: "2026-09-05", originalResponsePath: "/tmp/private/raw-response.json",
      sourceUrl: "https://api.sharadar.com/v1.0/data/stocks", comparisonOnly: true } }
  ] };
  const before = structuredClone(snapshot);
  const result = compactSnapshotPriceHistory(snapshot);
  assert.deepEqual(snapshot, before);
  assert.equal(result.latest.baseFairValue, 12.5);
  assert.equal(result.priceHistory[0].close, 10);
  assert.equal(result.priceHistory[0].sourceEvidence.origin, "source-artifact://original-price-response.json");
  assert.equal(result.priceHistory[0].sourceEvidence.originalResponsePath, "source-artifact://raw-response.json");
  assert.equal(result.priceHistory[0].sourceEvidence.originalRowSha256, "exact-original-row-hash");
  assert.equal(result.priceHistory[0].sourceEvidence.sourceUrl, "https://api.sharadar.com/v1.0/data/stocks");
  assert.ok(!JSON.stringify(result).includes("/Users/"));
  assert.ok(!JSON.stringify(result).includes("/tmp/"));
});

test("reconstructed runtime metadata cannot collide or carry old Q&A release approval", () => {
  const inherited = new Map([
    ["model_version", "old-model"], ["market_price_unit_policy", "old-policy"],
    ["transcript_qa_enrichment_version", "old-qa"],
    ["transcript_qa_enrichment_summary", '{"updatedTickers":532}'],
    ["transcript_qa_translation_audit", '{"status":"pass"}'],
    ["source_fingerprint", "original-source-hash"],
    ["guidance_extraction_version", "reviewed-parser"],
    ["inherited_issuer_profile_review", "source-review-not-release-approval"],
    ["guidance_coverage_summary", '{"covered":520}']
  ]);
  const before = [...inherited];
  const current = publicationMetadata(inherited, "new-model");
  assert.deepEqual([...inherited], before);
  assert.equal(current.get("model_version"), "new-model");
  assert.match(current.get("market_price_unit_policy"), /already stored in the quoted security currency/);
  assert.equal([...current.keys()].some((key) => key.startsWith("transcript_qa_")), false);
  for (const key of ["source_fingerprint", "guidance_extraction_version", "inherited_issuer_profile_review", "guidance_coverage_summary"])
    assert.equal(current.get(key), inherited.get(key));
  const db = new DatabaseSync(":memory:");
  try {
    db.exec("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT, imported_at TEXT)");
    const insert = db.prepare("INSERT INTO metadata VALUES(?,?,?)");
    for (const [key, value] of current) insert.run(key, value, "2026-09-05T20:00:00.000Z");
    assert.equal(db.prepare("SELECT value FROM metadata WHERE key='model_version'").get().value, "new-model");
    assert.equal(db.prepare("SELECT count(*) AS count FROM metadata").get().count, current.size);
  } finally { db.close(); }
});

function fixture({ currency = null, amount = 80_000, reportingCurrency = "MXN", availableAt = "2026-07-01", growth = null, rate = 20, withRates = true, typedSource = true } = {}) {
  const db = new DatabaseSync(":memory:");
  db.exec(`CREATE TABLE pit_financial_periods(ticker TEXT, available_at TEXT, currency TEXT, payload_json TEXT);
    CREATE TABLE pit_guidance_events(id TEXT, ticker TEXT, fiscal_period TEXT, actual_or_guidance TEXT, quality_status TEXT, observed_at TEXT, metric_name TEXT, amount REAL, currency TEXT, unit TEXT, value_text TEXT, evidence_excerpt TEXT, source_url TEXT, growth_yoy REAL, source_type TEXT, payload_json TEXT);
    CREATE TABLE pit_fx_reference_rates(currency TEXT, rate_date TEXT, units_per_eur REAL, source_url TEXT);`);
  db.prepare("INSERT INTO pit_financial_periods VALUES (?, ?, ?, ?)").run("TBBB", availableAt, "USD", JSON.stringify(reportingCurrency ? { sourceFinancialStatementCurrency: reportingCurrency, sourceRecord: { sourceCurrency: reportingCurrency, dataset: "Audited issuer reporting currency fixture" } } : { financialStatementCurrency: "USD" }));
  const quote = amount == null ? "We expect full year revenue growth of 15%." : "We expect full year revenue of 80 billion.";
  db.prepare("INSERT INTO pit_guidance_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").run("fixture", "TBBB", "Q22026", "guidance", "clear", "2026-08-01", "revenue_guidance", amount, currency, "reported millions", quote, quote, "https://example.test/issuer-release", growth,
    typedSource ? "downloaded_online_earnings_transcript" : null,
    JSON.stringify(typedSource ? { guidance_scope: "full_year", guidance_subject: "company_total", metric_position: quote.indexOf("revenue") } : {}));
  if (withRates) {
    const insert = db.prepare("INSERT INTO pit_fx_reference_rates VALUES (?, ?, ?, ?)");
    insert.run("MXN", "2026-07-31", rate, "https://www.ecb.europa.eu/fixture");
    insert.run("USD", "2026-07-31", 1, "https://www.ecb.europa.eu/fixture");
    insert.run("MXN", "2026-08-02", 2, "https://www.ecb.europa.eu/future-fixture");
  }
  return db;
}

function read(options) {
  const db = fixture(options);
  try {
    const result = readPitGuidance(db, ["TBBB"]);
    return { metric: result.metricsByPeriod.get("TBBB::Q22026")[0], digest: result.byPeriod.get("TBBB::Q22026"), raw: result.rows[0] };
  } finally { db.close(); }
}

test("unknown guidance currency resolves from visible issuer currency and uses prior ECB FX", () => {
  const { metric, digest, raw } = read();
  assert.equal(raw.currency, null);
  assert.equal(metric.currency_resolution.resolvedSourceCurrency, "MXN");
  assert.equal(metric.currency_resolution.status, "issuer_reporting_currency");
  assert.equal(metric.model_amount_m, 4_000);
  assert.equal(metric.fx_conversion.sourceRateDate, "2026-07-31");
  assert.equal(digest.revenueGuidanceM, 4_000);
});

test("explicit guidance USD is not overwritten by a Mexican issuer reporting currency", () => {
  const { metric } = read({ currency: "USD", amount: 4_000 });
  assert.equal(metric.model_amount_m, 4_000);
  assert.equal(metric.currency_resolution.status, "explicit_guidance_currency");
  assert.equal(metric.fx_conversion, null);
});

test("unknown monetary currency cannot silently inherit quoted USD", () => {
  const { metric, digest } = read({ reportingCurrency: null });
  assert.equal(metric.model_amount_m, null);
  assert.equal(metric.quality_status, "currency_unresolved");
  assert.equal(metric.model_exclusion_reason, "guidance_source_currency_unresolved");
  assert.equal(digest.revenueGuidanceM, null);
  assert.equal(digest.revenueUnscopedGuidanceM, null);
});

test("a later financial release cannot resolve historical guidance currency", () => {
  const { metric, digest } = read({ availableAt: "2026-08-02" });
  assert.equal(metric.quality_status, "currency_unresolved");
  assert.equal(digest.revenueGuidanceM, null);
});

test("missing or invalid FX blocks raw-amount fallback", () => {
  for (const options of [{ withRates: false }, { rate: 0 }, { rate: -20 }]) {
    const { metric, digest } = read({ currency: "MXN", ...options });
    assert.equal(metric.model_amount_m, null);
    assert.equal(metric.quality_status, "fx_unavailable");
    assert.equal(digest.revenueGuidanceM, null);
  }
});

test("percentage-only guidance is unchanged without any currency evidence", () => {
  const { metric, digest } = read({ amount: null, reportingCurrency: null, growth: 15, withRates: false });
  assert.equal(metric.quality_status, "clear");
  assert.equal(metric.currency_resolution.status, "not_monetary");
  assert.equal(digest.revenueGuidanceGrowth, 15);
  assert.equal(digest.revenueGuidanceM, null);
});

test("resolved currency alone cannot authorize an untyped PIT source", () => {
  const { metric, digest, raw } = read({ typedSource: false });
  assert.equal(raw.source_type, null);
  assert.equal(metric.model_amount_m, 4_000);
  assert.equal(digest.revenueGuidanceM, null);
  assert.equal(digest.rejectedSourceGuidance[0].reason, "pit_source_identity_missing");
});

test("conflicting issuer reporting-currency evidence fails closed", () => {
  const db = fixture();
  try {
    db.prepare("INSERT INTO pit_financial_periods VALUES (?, ?, ?, ?)").run("TBBB", "2026-07-01", "USD", JSON.stringify({ sourceFinancialStatementCurrency: "USD" }));
    const metric = readPitGuidance(db, ["TBBB"]).metricsByPeriod.get("TBBB::Q22026")[0];
    assert.equal(metric.quality_status, "currency_unresolved");
  } finally { db.close(); }
});

test("parser currency conflicts remain audit evidence and cannot regain a monetary input", () => {
  const db = fixture();
  try {
    db.exec("UPDATE pit_guidance_events SET quality_status='currency_conflict'");
    const result = readPitGuidance(db, ["TBBB"]);
    const metric = result.metricsByPeriod.get("TBBB::Q22026")[0];
    assert.equal(result.rows.length, 1);
    assert.equal(metric.quality_status, "currency_conflict");
    assert.equal(metric.model_amount_m, null);
    assert.equal(result.byPeriod.get("TBBB::Q22026").revenueGuidanceM, null);
  } finally { db.close(); }
});

test("raw actual and research evidence survives import without entering model digests", () => {
  for (const [kind, status] of [["actual", "historical_actual"], ["guidance", "research_only_cash_noncash_mapping"], ["guidance", "currency_unresolved"]]) {
    const db = fixture();
    try {
      db.prepare("UPDATE pit_guidance_events SET actual_or_guidance=?,quality_status=?").run(kind, status);
      const result = readPitGuidance(db, ["TBBB"]);
      assert.equal(result.rows.length, 1, `${kind}/${status} must remain auditable`);
      assert.equal(result.rows[0].quality_status, status);
      assert.equal(result.byPeriod.size, 0);
      assert.equal(result.metricsByPeriod.size, 0);
    } finally { db.close(); }
  }
});

test("independent source-text audit blocks an old MXN amount incorrectly stored as USD", () => {
  const db = fixture({ currency: "USD" });
  try {
    db.exec("UPDATE pit_guidance_events SET evidence_excerpt='In Mexican pesos, we expect full year revenue of $80 billion.'");
    const result = readPitGuidance(db, ["TBBB"]);
    const metric = result.metricsByPeriod.get("TBBB::Q22026")[0];
    assert.equal(metric.quality_status, "currency_conflict");
    assert.equal(metric.currency_resolution.independentEvidenceMismatch.reason, "source_currency_mismatch");
    assert.equal(result.byPeriod.get("TBBB::Q22026").revenueGuidanceM, null);
  } finally { db.close(); }
});

test("missing, duplicate or unacceptable coverage rows block every modeled issuer", () => {
  const models = [{ ticker: "AAA", status: "covered" }, { ticker: "BBB", status: "annual_only" }];
  assert.deepEqual(guidanceCoverageBlockers(models, [{ ticker: "AAA", status: "covered" }]).map((r) => [r.ticker, r.status]), [["BBB", "guidance_missing_coverage"]]);
  assert.equal(guidanceCoverageBlockers([{ ticker: "AAA" }], [{ ticker: "AAA", status: "covered" }, { ticker: "aaa", status: "covered" }])[0].status, "guidance_duplicate_coverage");
  assert.equal(guidanceCoverageBlockers([{ ticker: "AAA" }], [{ ticker: "AAA", status: "missing" }])[0].status, "guidance_missing");
  for (const status of ["covered", "covered_official_filing", "no_quantified_official_guidance"]) assert.deepEqual(guidanceCoverageBlockers([{ ticker: "AAA" }], [{ ticker: "AAA", status }]), []);
});

test("allow-incomplete remains diagnostic-only and is rejected before database opening", () => {
  assert.doesNotThrow(() => assertSafeImportMode({ apply: false, allowIncomplete: true }));
  assert.doesNotThrow(() => assertSafeImportMode({ apply: true, allowIncomplete: false }));
  assert.throws(() => assertSafeImportMode({ apply: true, allowIncomplete: true }), /dry-run only/);
  const child = spawnSync(process.execPath, ["server/importPitQuarterlyValuations.js", "--apply", "--allow-incomplete"], { encoding: "utf8", env: { ...process.env, SQLITE_DB_PATH: "/nonexistent/no-db-write.sqlite", PIT_VALUATION_SOURCE_PATH: "/nonexistent/no-source.sqlite" } });
  assert.notEqual(child.status, 0);
  assert.match(child.stderr, /dry-run only/);
  assert.doesNotMatch(child.stderr, /database not found|source not found/);
});

test("optional issuer review ledger preserves old sources but rejects pending/missing staging rows", () => {
  const models = [{ ticker: "TBBB" }];
  assert.deepEqual(issuerReviewBlockers(models, null), []);
  assert.deepEqual(issuerReviewBlockers(models, [{ ticker: "TBBB", status: "reviewed" }]), []);
  for (const rows of [[], [{ ticker: "TBBB", status: "pending_economic_review" }]]) assert.equal(issuerReviewBlockers(models, rows)[0].status, "issuer_pending_economic_review");
});
