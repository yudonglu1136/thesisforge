import crypto from "node:crypto";
import { readFileSync } from "node:fs";

const raw = readFileSync(new URL("./config/guru-current-economic-evidence.json", import.meta.url), "utf8");
const E = JSON.parse(raw);
export const GURU_CURRENT_EVIDENCE_SHA256 = crypto.createHash("sha256").update(raw).digest("hex");
const close = (a, b) => typeof a === "number" && Number.isFinite(a) && Math.abs(a - b) < 1e-7;
const date = (s) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s) &&
  Number.isFinite(Date.parse(s)) && new Date(s).toISOString().slice(0, 10) === s;
const block = (reason) => ({ status: "blocked", releaseReady: false, reason });

/**
 * Pure CURRENT scenario builder. No SQL, generic-profile override, historical
 * mutation or release permission. Input is the preserved normalized ART payload
 * plus independent ECB records for the model date (not provider fxusd).
 */
export function buildGuruCurrentEconomicValuation({ ticker, asOfDate, financial, fxRecords = [] } = {}) {
  const c = E.companies[ticker];
  if (!c) return block("unsupported_issuer");
  if (!date(asOfDate) || asOfDate !== E.reviewedAt) return block("current_review_date_only_no_historical_backfill");
  if (!financial || financial.ticker !== ticker || financial.sourceDimension !== "ART" ||
      financial.periodEndDate !== c.periodEndDate || financial.asOfDate !== c.financialAvailableDate ||
      financial.financialStatementCurrency !== c.quoteCurrency ||
      financial.sourceFinancialStatementCurrency !== c.reportingCurrency) return block("exact_reviewed_art_period_required");
  if (Object.values(c.sources).some((s) => !date(s.availableDate) || s.availableDate > asOfDate)) return block("source_not_available");
  const record = financial.sourceRecord;
  if (!record || record.sourceTicker !== ticker || record.dimension !== "ART" ||
      record.reportperiod !== c.periodEndDate || record.datekey !== c.financialAvailableDate ||
      record.sourceCurrency !== c.reportingCurrency || record.modelCurrency !== c.quoteCurrency ||
      !close(record.appliedShareFactor, 1) || !close(record.sharefactor, 1)) return block("raw_identity_or_security_units_mismatch");
  let inputFx = 1;
  if (c.reportingCurrency !== c.quoteCurrency) {
    const f = record.fxConversion;
    if (!f || f.sourceCurrency !== c.reportingCurrency || f.targetCurrency !== c.quoteCurrency ||
        f.sourceRateDate !== c.sourceFx.rateDate || f.targetRateDate !== c.sourceFx.rateDate ||
        !close(f.sourceUnitsPerEur, 1) || !close(f.targetUnitsPerEur, c.sourceFx.unitsPerEur) ||
        !close(f.conversionRate, c.sourceFx.unitsPerEur) || !close(record.currencyScale, f.conversionRate) ||
        !String(f.sourceUrl).startsWith("https://data-api.ecb.europa.eu/service/data/EXR/")) return block("source_fx_evidence_mismatch");
    inputFx = f.conversionRate;
  } else if (record.fxConversion != null || !close(record.currencyScale, 1)) return block("unexpected_source_fx");
  const expected = { revenue_m: "revenueM", cfo_m: "cfoM", capex_m: "capexM", fcf_after_capex_m: "rawFcfM" };
  for (const [field, key] of Object.entries(expected)) {
    if (!close(financial[field] / inputFx, c.sourceTtm[key])) return block(`reported_input_mismatch:${field}`);
  }
  if (!close(financial.shares_m, c.sourceTtm.providerSharesM) ||
      !close(record.rawShareCounts?.sharesbas / 1e6, c.sourceTtm.providerSharesM)) return block("original_share_count_mismatch");
  let outputFx = 1;
  let fxSource = null;
  if (c.reportingCurrency !== c.quoteCurrency) {
    const candidates = fxRecords.filter((r) => r.currency === c.quoteCurrency && date(r.rate_date) && r.rate_date <= asOfDate);
    candidates.sort((a, b) => b.rate_date.localeCompare(a.rate_date));
    const latest = candidates[0];
    if (!latest || latest.rate_date !== "2026-09-04" || !close(latest.units_per_eur, 1.1622) ||
        !String(latest.source_url).startsWith("https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?")) return block("independent_current_ecb_rate_required");
    if (candidates.filter((r) => r.rate_date === latest.rate_date).some((r) => !close(r.units_per_eur, latest.units_per_eur))) return block("conflicting_current_fx");
    outputFx = latest.units_per_eur;
    fxSource = structuredClone(latest);
  }
  const ttm = {};
  for (const p of Object.values(c.periods)) {
    for (const [k, value] of Object.entries(p)) if (k.endsWith("M")) ttm[k] = (ttm[k] || 0) + value * p.coefficient;
  }
  if (!close(ttm.cfoM, c.sourceTtm.cfoM) || !close(ttm.cashPpeM, c.sourceTtm.capexM)) return block("reported_ttm_reconciliation_failed");
  for (const s of c.shareObservations) {
    if (!Number.isSafeInteger(s.issued) || !Number.isSafeInteger(s.treasury) || s.issued - s.treasury !== s.outstanding ||
        s.periodEndDate > c.sources[s.sourceId].availableDate) return block("official_share_rollforward_failed");
  }
  const currentShares = c.shareObservations.find((s) => s.periodEndDate === c.periodEndDate).outstanding;
  const economics = {
    reportedCurrency: c.reportingCurrency, unit: "million", ttm,
    reportedCfoLessCashCapexM: ttm.cfoM - ttm.cashPpeM,
    basicSharesM: currentShares / 1e6, originalProviderSharesM: financial.shares_m,
    shareObservations: structuredClone(c.shareObservations),
    currentFx: fxSource, inputFinancialFx: structuredClone(record.fxConversion),
    conventions: structuredClone(c.conventions)
  };
  let scenarios;
  if (ticker === "SPOT") {
    const reserveM = Math.max(0, ttm.managementCapexM - ttm.cashPpeM);
    const fcfeM = ttm.cfoM - ttm.cashPpeM - ttm.leasePrincipalM - ttm.sbcM - reserveM;
    const sharesM = (currentShares + c.claims.exercisableOptions) / 1e6;
    Object.assign(economics, { reconciliationReserveM: reserveM, parentEconomicFcfeM: fcfeM,
      denominatorSharesM: sharesM, vestedOptionClaimBoundM: c.claims.exercisableOptions / 1e6,
      existingUnvestedAwardsAddedToDenominator: 0, extraDebtDeductionM: 0, extraCashAdditionM: 0 });
    scenarios = Object.entries(c.scenarios).map(([name, a]) => {
      let flow = fcfeM;
      const explicit = a.growthRates.map((growth, i) => {
        flow *= 1 + growth;
        return { year: i + 1, growth, fcfeM: flow, presentValueM: flow / (1 + a.ke) ** (i + 1) };
      });
      const terminalValueM = flow * (1 + a.terminalGrowth) / (a.ke - a.terminalGrowth);
      const terminalPresentValueM = terminalValueM / (1 + a.ke) ** explicit.length;
      const equityValueM = explicit.reduce((s, x) => s + x.presentValueM, 0) + terminalPresentValueM;
      return { name, ...a, method: "parent_economic_fcfe_dcf", explicit, terminalValueM,
        terminalPresentValueM, equityValueM, sourceValuePerShare: equityValueM / sharesM,
        fairValue: equityValueM / sharesM * outputFx, terminalValueShare: terminalPresentValueM / equityValueM };
    });
  } else {
    const diagnosticCashM = ttm.cfoM - ttm.cashPpeM - ttm.sbcM - ttm.capitalizedSbcM - ttm.otherFinancingOutflowM;
    const claimsM = (currentShares + c.claims.allOptions + c.claims.unvestedRsus + c.claims.esppPotentialShares) / 1e6;
    const b = c.balanceSheet;
    Object.assign(economics, { diagnosticCashAfterCompensationM: diagnosticCashM,
      diagnosticOnlyNotDcf: true, legacyClaimsBoundM: claimsM, cashReservedForOperationsM: b.cashM,
      securitiesAddedM: b.shortTermSecuritiesM + b.longTermSecuritiesM,
      operatingLeasesNotFinancingDebtM: b.operatingLeaseLiabilitiesM,
      legalAwardExcludedFromValuationM: 30.329 });
    scenarios = Object.entries(c.scenarios).map(([name, a]) => {
      const nextRevenueM = c.sourceTtm.revenueM * (1 + a.revenueGrowth);
      const denominatorSharesM = claimsM * (1 + a.newGrantDilution);
      const enterpriseValueM = nextRevenueM * a.evSales;
      const equityValueM = enterpriseValueM + economics.securitiesAddedM - b.financialBorrowingsM;
      return { name, ...a, method: "explicit_ntm_ev_sales_not_dcf", nextRevenueM,
        enterpriseValueM, equityValueM, denominatorSharesM, fairValue: equityValueM / denominatorSharesM };
    });
  }
  return {
    status: "ready_current_scenario", releaseReady: false, ticker, asOfDate,
    periodEndDate: c.periodEndDate, financialAvailableDate: c.financialAvailableDate,
    financialCutoff: E.financialCutoff,
    currency: c.quoteCurrency, reportingCurrency: c.reportingCurrency,
    modelVersion: "guru-current-economic-scenarios-v1-2026-09-05",
    evidenceSha256: GURU_CURRENT_EVIDENCE_SHA256, economics, scenarios,
    fairValue: scenarios.find((x) => x.name === "base").fairValue,
    sources: structuredClone(c.sources), assumptionRationale: c.assumptionRationale,
    historyPolicy: "Current scenario only; no historical node is approved, relabeled, dropped or overwritten. Source observations from historical filings are inputs only to the current TTM bridge.",
    warning: "Analyst scenarios, not company guidance or guaranteed returns. Full release integration and independent source audit remain required."
  };
}
