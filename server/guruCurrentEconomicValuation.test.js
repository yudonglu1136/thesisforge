import test from "node:test";
import assert from "node:assert/strict";
import { buildGuruCurrentEconomicValuation } from "./guruCurrentEconomicValuation.js";
import { auditGuruCurrentEconomicValuation } from "./guruCurrentEconomicValuationAudit.js";

function input(ticker) {
  const spot = ticker === "SPOT";
  const period = spot ? "2026-06-30" : "2026-05-02";
  const available = spot ? "2026-08-04" : "2026-06-09";
  const financial = {
    ticker, sourceDimension: "ART", periodEndDate: period, asOfDate: available,
    financialStatementCurrency: "USD", sourceFinancialStatementCurrency: spot ? "EUR" : "USD",
    revenue_m: spot ? 20857.1195 : 1730.595,
    cfo_m: spot ? 3842.5555 : 265.011,
    capex_m: spot ? 80.605 : 30.082,
    fcf_after_capex_m: spot ? 3761.9505 : 234.929,
    shares_m: spot ? 205.788241 : 582.710082,
    sourceRecord: {
      sourceTicker: ticker, dimension: "ART", reportperiod: period, datekey: available,
      sourceCurrency: spot ? "EUR" : "USD", modelCurrency: "USD", currencyScale: spot ? 1.1515 : 1,
      appliedShareFactor: 1, sharefactor: 1,
      rawShareCounts: { sharesbas: spot ? 205788241 : 582710082 },
      fxConversion: spot ? {
        sourceCurrency: "EUR", targetCurrency: "USD", sourceRateDate: available, targetRateDate: available,
        sourceUnitsPerEur: 1, targetUnitsPerEur: 1.1515, conversionRate: 1.1515,
        sourceUrl: "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?format=csvdata"
      } : null
    }
  };
  return { ticker, asOfDate: "2026-09-05", financial, fxRecords: [{ currency: "USD", rate_date: "2026-09-04", units_per_eur: 1.1622,
    source_url: "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?startPeriod=2026-08-22&endPeriod=2026-09-04&format=csvdata" }] };
}
const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-7, `${a} != ${b}`);

test("SPOT independently reconciles EUR source cash, cash leases and actual common denominator", () => {
  const result = buildGuruCurrentEconomicValuation(input("SPOT"));
  assert.equal(result.status, "ready_current_scenario");
  near(result.economics.ttm.cfoM, 2933 + 1652 - 1248);
  near(result.economics.ttm.leasePrincipalM, 73 + 36 - 44);
  near(result.economics.ttm.sbcM, 247 + 142 - 115);
  near(result.economics.parentEconomicFcfeM, 3337 - 70 - 65 - 274 - 9);
  near(result.economics.basicSharesM, (210241268 - 4657063) / 1e6);
  near(result.economics.denominatorSharesM, (210241268 - 4657063 + 2789877) / 1e6);
  assert.equal(result.economics.extraDebtDeductionM, 0);
  assert.equal(result.economics.extraCashAdditionM, 0);
  assert.equal(auditGuruCurrentEconomicValuation(result).ok, true);
});

test("IOT negative after-compensation cash is not converted into a positive DCF", () => {
  const result = buildGuruCurrentEconomicValuation(input("IOT"));
  near(result.economics.diagnosticCashAfterCompensationM, 234.929 - 315.375 - 9.5 - 0.647);
  assert.ok(result.economics.diagnosticCashAfterCompensationM < 0);
  assert.equal(result.scenarios.every((s) => s.method === "explicit_ntm_ev_sales_not_dcf" && !s.explicit), true);
  near(result.economics.securitiesAddedM, 585.333 + 477.072);
  const expected = (1730.595 * 1.25 * 10 + 585.333 + 477.072) /
    ((582710082 + 5396988 + 21744310 + 1015333) / 1e6 * 1.02);
  near(result.fairValue, expected);
  assert.equal(auditGuruCurrentEconomicValuation(result).ok, true);
});

test("producer never mutates provider records or historical observations", () => {
  const args = input("SPOT");
  const original = JSON.stringify(args);
  const result = buildGuruCurrentEconomicValuation(args);
  assert.equal(JSON.stringify(args), original);
  assert.equal(result.economics.shareObservations[0].outstanding, 205832527);
  assert.equal(result.economics.shareObservations[1].outstanding, 205620061);
  assert.notEqual(result.economics.shareObservations[0].outstanding, result.economics.shareObservations[2].outstanding);
});

for (const [name, mutate] of [
  ["historical date", (x) => { x.asOfDate = "2026-08-04"; }],
  ["future refresh without review", (x) => { x.asOfDate = "2026-09-06"; }],
  ["different financial period", (x) => { x.financial.periodEndDate = "2026-03-31"; }],
  ["ARQ pretending TTM", (x) => { x.financial.sourceDimension = "ARQ"; }],
  ["unknown source currency", (x) => { x.financial.sourceRecord.sourceCurrency = null; }],
  ["ADR factor", (x) => { x.financial.sourceRecord.appliedShareFactor = 2; }],
  ["future filing", (x) => { x.financial.asOfDate = "2026-09-08"; }],
  ["future FX", (x) => { x.fxRecords[0].rate_date = "2026-09-06"; }],
  ["inverted FX", (x) => { x.financial.sourceRecord.fxConversion.conversionRate = 1 / 1.1515; }],
  ["USD amounts treated as EUR", (x) => { x.financial.cfo_m = 3337; }],
  ["false raw share count", (x) => { x.financial.sourceRecord.rawShareCounts.sharesbas = 210241268; }],
  ["missing independent FX", (x) => { x.fxRecords = []; }],
  ["conflicting FX", (x) => { x.fxRecords.push({ ...x.fxRecords[0], units_per_eur: 1.17 }); }],
  ["wrong raw issuer", (x) => { x.financial.sourceRecord.sourceTicker = "SPOT1"; }]
]) test(`fail closed: ${name}`, () => {
  const args = input("SPOT"); mutate(args);
  const result = buildGuruCurrentEconomicValuation(args);
  assert.equal(result.status, "blocked");
  assert.equal(result.fairValue, undefined);
});

for (const [name, mutate] of [
  ["cash add-on", (x) => { x.economics.extraCashAdditionM = 5938; }],
  ["debt deducted again", (x) => { x.economics.extraDebtDeductionM = 466; }],
  ["double award charge", (x) => { x.economics.existingUnvestedAwardsAddedToDenominator = 1.456016; }],
  ["terminal shifted one year", (x) => { x.scenarios[1].terminalPresentValueM *= 1.1; }],
  ["discount mismatch", (x) => { x.scenarios[1].explicit[0].presentValueM = x.scenarios[1].explicit[0].fcfeM; }],
  ["FX omitted", (x) => { x.scenarios[1].fairValue = x.scenarios[1].sourceValuePerShare; }],
  ["header changed", (x) => { x.fairValue += 1; }],
  ["date backfill", (x) => { x.asOfDate = "2026-08-04"; }],
  ["self release permission", (x) => { x.releaseReady = true; }],
  ["scenario removed", (x) => { x.scenarios.pop(); }],
  ["source replaced", (x) => { x.sources.h12026.url = "https://example.com"; }]
]) test(`independent auditor rejects ${name}`, () => {
  const result = buildGuruCurrentEconomicValuation(input("SPOT")); mutate(result);
  assert.equal(auditGuruCurrentEconomicValuation(result).ok, false);
});

test("market quotes and EPS finance gain do not enter either valuation", () => {
  for (const ticker of ["IOT", "SPOT"]) {
    const args = input(ticker);
    const before = buildGuruCurrentEconomicValuation(args);
    args.marketPrice = 999999;
    args.financial.net_income_m = 999999;
    args.financial.currentPrice = 0.01;
    near(buildGuruCurrentEconomicValuation(args).fairValue, before.fairValue);
  }
});
