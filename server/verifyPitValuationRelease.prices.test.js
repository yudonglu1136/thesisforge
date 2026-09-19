import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { inspectModels } from "./verifyPitValuationRelease.js";

// Entirely synthetic, in-memory fixtures. No live/local production database,
// network request, licensed vendor rows, or application database import.
const TICKER = "SYNTH";
const PERIOD = "2020-Q1";
const VERSION = "synthetic-price-regression-v2";
const DATE = "2020-05-04";
const PAID = "jansen-sharadar-sep-split-adjusted";
const PRICE_COUNTERS = [
  "storedMarketPriceChecks", "snapshotMarketPriceChecks",
  "pitMarketPriceObservationChecks", "storedMarketPriceDateMisses",
  "comparisonPriceBasisExclusions"
];

function modelPayload({ declaredSource = PAID, outputPrice = 200 } = {}) {
  const fairValue = 240;
  const targetPrice3Y = fairValue * 1.05 ** 3;
  const semantics = {
    modelVersion: VERSION,
    priceExcludedFromFairValue: true,
    scoreInputs: {
      sharesM: 10, profile: "synthetic_price_fixture", modelRoute: "synthetic_price_fixture",
      methodWeights: { "synthetic-owner-value": 1 }
    }
  };
  return {
    input: {
      currency: "USD",
      financial: { currency: "USD", shares_m: 10 },
      sourceRecord: {
        currency: "USD", sourceCurrency: "USD", modelCurrency: "USD",
        datekey: DATE, periodEndDate: "2020-03-31"
      },
      valuationSemantics: semantics
    },
    output: {
      currency: "USD", quoteCurrency: "USD", fairValue, targetPrice3Y,
      priceDate: DATE, priceAtDate: outputPrice,
      upsideDownside: fairValue / outputPrice - 1,
      expectedReturn3Y: (targetPrice3Y / outputPrice) ** (1 / 3) - 1,
      methodOutputs: [{ key: "synthetic-owner-value", value: fairValue }],
      dataSnapshot: {
        modelVersion: VERSION, valuationSemantics: semantics,
        asOfPriceSource: { priceDate: DATE, source: declaredSource },
        financialSource: { currency: "USD" }
      }
    }
  };
}

function inspectFixture(t, {
  declaredSource = PAID,
  outputPrice = 200,
  rawPoints = [],
  // Independent security quote-unit metadata, not numerical price evidence.
  snapshot = { priceHistory: [] },
  observations = []
} = {}) {
  const db = new DatabaseSync(":memory:");
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE valuation_pit_guidance (source_id TEXT PRIMARY KEY);
    CREATE TABLE valuation_pit_model_runs (
      ticker TEXT, fiscal_period TEXT, model_version TEXT, as_of_date TEXT,
      financial_available_at TEXT, guidance_max_observed_at TEXT,
      input_json TEXT, output_json TEXT, generated_at TEXT,
      PRIMARY KEY (ticker, fiscal_period, model_version)
    );
    CREATE TABLE price_points (
      symbol TEXT, date TEXT, open REAL, high REAL, low REAL, close REAL,
      volume INTEGER, source TEXT, updated_at TEXT, adjusted_close REAL,
      PRIMARY KEY (symbol, date)
    );
    CREATE TABLE valuation_ticker_snapshots (
      ticker TEXT PRIMARY KEY, generated_at TEXT, payload_json TEXT
    );
    CREATE TABLE valuation_pit_price_observations (
      ticker TEXT, fiscal_period TEXT, model_version TEXT, price_symbol TEXT,
      price_date TEXT, close REAL, quote_currency TEXT, source TEXT,
      payload_json TEXT, imported_at TEXT,
      PRIMARY KEY (ticker, fiscal_period, model_version)
    );
  `);
  const model = modelPayload({ declaredSource, outputPrice });
  db.prepare(`INSERT INTO valuation_pit_model_runs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
    TICKER, PERIOD, VERSION, DATE, DATE, null,
    JSON.stringify(model.input), JSON.stringify(model.output), `${DATE}T21:00:00Z`
  );
  for (const point of rawPoints) db.prepare(`
    INSERT INTO price_points (symbol, date, close, source, adjusted_close, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(point.symbol || TICKER, point.date || DATE, point.close, point.source ?? null,
    point.adjustedClose ?? null, `${DATE}T22:00:00Z`);
  if (snapshot) db.prepare(`INSERT INTO valuation_ticker_snapshots VALUES (?, ?, ?)`).run(
    TICKER, `${DATE}T21:00:00Z`, JSON.stringify({ ticker: TICKER, currency: "USD", ...snapshot })
  );
  for (const observation of observations) {
    const source = observation.source ?? PAID;
    const date = observation.date || DATE;
    db.prepare(`INSERT INTO valuation_pit_price_observations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
      observation.ticker || TICKER, observation.period || PERIOD,
      observation.modelVersion || VERSION, observation.priceSymbol || TICKER,
      date, observation.close ?? 200, observation.quoteCurrency || "USD", source,
      JSON.stringify({ ticker: TICKER, sourceTicker: TICKER, asOfDate: DATE,
        source: { priceDate: date, source } }),
      observation.importedAt || `${DATE}T21:00:00Z`
    );
  }
  const changesBefore = db.prepare("SELECT total_changes() AS n").get().n;
  const rawBefore = db.prepare("SELECT * FROM price_points ORDER BY symbol,date").all();
  const audit = inspectModels(db);
  assert.equal(db.prepare("SELECT total_changes() AS n").get().n, changesBefore, "Inspector must not write to the database");
  assert.deepEqual(db.prepare("SELECT * FROM price_points ORDER BY symbol,date").all(), rawBefore, "Guru/raw prices must remain byte-for-byte logical equivalents");
  assert.equal(audit.rows, 1);
  assert.equal(audit.priceInputChecks, 1);
  for (const key of PRICE_COUNTERS) assert.ok(Number.isInteger(audit[key]) && audit[key] >= 0, `Missing/non-numeric price counter: ${key}`);
  return audit;
}

const priceFailures = (audit) => audit.failures.filter((failure) =>
  failure.priceAudit || /price|market/i.test(failure.code || ""));
function assertNoPriceFailures(audit) {
  assert.deepEqual(priceFailures(audit), []);
}
function assertPriceFailure(audit, pattern) {
  const failures = priceFailures(audit);
  assert.ok(failures.length > 0, `Expected a price failure, received ${JSON.stringify(audit)}`);
  assert.match(JSON.stringify(failures), pattern);
}

test("release inspector accepts declared Sharadar against different Yahoo without changing raw prices", (t) => {
  const audit = inspectFixture(t, {
    rawPoints: [{ source: "yahoo", close: 153, adjustedClose: 130 }],
    snapshot: {
      priceSource: { source: "yahoo+sqlite-merged" },
      priceHistory: [{ date: DATE, source: PAID, close: 200 }]
    },
    observations: [{ close: 200 }]
  });
  assertNoPriceFailures(audit);
  assert.equal(audit.comparisonPriceBasisExclusions, 1);
  assert.equal(audit.storedMarketPriceChecks, 0, "Different-basis raw close cannot be counted as expected-price proof");
  assert.equal(audit.snapshotMarketPriceChecks, 1);
});

test("release inspector blocks conflicting quotes in the same declared source series", (t) => {
  const audit = inspectFixture(t, {
    rawPoints: [{ source: PAID, close: 201 }],
    snapshot: { priceHistory: [{ date: DATE, source: PAID, close: 200 }] },
    observations: [{ close: 200 }]
  });
  assertPriceFailure(audit, /same_series_price_conflict/);
});

test("a different model version PIT observation cannot corroborate the current model", (t) => {
  const audit = inspectFixture(t, {
    observations: [{ modelVersion: "synthetic-price-regression-v1", close: 200,
      importedAt: "2020-05-10T00:00:00Z" }]
  });
  assertPriceFailure(audit, /(?:source_unreconciled|missing_price_evidence)/);
  assert.equal(audit.pitMarketPriceObservationChecks, 0);
});

test("snapshot points without source cannot borrow a merged or claimed top-level source", async (t) => {
  for (const priceSource of ["yahoo+sqlite-merged", { source: PAID, previousSource: "yahoo+sqlite-merged" }]) {
    await t.test(JSON.stringify(priceSource), (subtest) => {
      const audit = inspectFixture(subtest, {
        snapshot: { priceSource, priceHistory: [{ date: DATE, close: 200 }] }
      });
      assertPriceFailure(audit, /(?:source_unreconciled|unverified_candidate_source)/);
      assert.equal(audit.snapshotMarketPriceChecks, 0);
    });
  }
});

test("an exact-version PIT quote preserves declared-source lineage against a different raw series", (t) => {
  const audit = inspectFixture(t, {
    rawPoints: [{ source: "yahoo", close: 153 }], observations: [{ close: 200 }]
  });
  assertNoPriceFailures(audit);
  assert.equal(audit.pitMarketPriceObservationChecks, 1);
  assert.equal(audit.comparisonPriceBasisExclusions, 1);
});

test("a wrong output cannot choose the other provider merely because its value matches", (t) => {
  const audit = inspectFixture(t, {
    outputPrice: 153,
    rawPoints: [{ source: "yahoo", close: 153 }],
    snapshot: { priceHistory: [{ date: DATE, source: PAID, close: 200 }] },
    observations: [{ close: 200 }]
  });
  assertPriceFailure(audit, /stored_market_price_unit_mismatch/);
});

test("existing Yahoo-declared models can reconcile truthful raw Yahoo lineage", (t) => {
  const audit = inspectFixture(t, {
    declaredSource: "yahoo", rawPoints: [{ source: "yahoo", close: 200, adjustedClose: 175 }]
  });
  assertNoPriceFailures(audit);
  assert.equal(audit.storedMarketPriceChecks, 1);
  assert.equal(audit.comparisonPriceBasisExclusions, 0);
});
