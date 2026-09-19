import crypto from "node:crypto";
import { readFileSync } from "node:fs";

// Independent implementation: never invokes the producer or trusts its ready
// status, bridge totals, method labels, FX conversion, or output checksum.
const raw = readFileSync(new URL("./config/guru-current-economic-evidence.json", import.meta.url), "utf8");
const config = JSON.parse(raw);
const hash = crypto.createHash("sha256").update(raw).digest("hex");
const close = (a, b) => typeof a === "number" && Number.isFinite(a) && Math.abs(a - b) < 1e-7;

export function auditGuruCurrentEconomicValuation(result) {
  const failures = [];
  const fail = (code) => failures.push({ ticker: result?.ticker, code });
  const c = config.companies[result?.ticker];
  if (!c || result?.status !== "ready_current_scenario") return { ok: false, failures: [{ code: "missing_supported_current_result" }] };
  if (result.evidenceSha256 !== hash || result.asOfDate !== config.reviewedAt || result.periodEndDate !== c.periodEndDate ||
      result.financialAvailableDate !== c.financialAvailableDate || result.currency !== c.quoteCurrency ||
      result.reportingCurrency !== c.reportingCurrency || result.releaseReady !== false) fail("current_scope_or_evidence_mismatch");
  if (JSON.stringify(result.sources) !== JSON.stringify(c.sources)) fail("source_evidence_changed");
  const p = Object.values(c.periods);
  const sum = (key) => p.reduce((n, row) => n + row.coefficient * row[key], 0);
  const e = result.economics || {};
  const basic = c.shareObservations.find((s) => s.periodEndDate === c.periodEndDate).outstanding / 1e6;
  if (!close(e.basicSharesM, basic) || !close(e.originalProviderSharesM, c.sourceTtm.providerSharesM) ||
      !close(e.reportedCfoLessCashCapexM, sum("cfoM") - sum("cashPpeM"))) fail("independent_cash_or_common_share_reconciliation");
  const scenarios = result.scenarios || [];
  if (scenarios.length !== 3 || new Set(scenarios.map((r) => r.name)).size !== 3) fail("scenario_count_or_duplicates");
  for (const name of ["bear", "base", "bull"]) {
    const actual = scenarios.find((r) => r.name === name);
    const a = c.scenarios[name];
    if (!actual) { fail(`missing_scenario:${name}`); continue; }
    let expectedValue;
    if (result.ticker === "SPOT") {
      const fcfe = sum("cfoM") - sum("cashPpeM") - sum("leasePrincipalM") - sum("sbcM") -
        Math.max(0, sum("managementCapexM") - sum("cashPpeM"));
      const denominator = basic + c.claims.exercisableOptions / 1e6;
      if (!close(e.parentEconomicFcfeM, fcfe) || !close(e.denominatorSharesM, denominator) ||
          e.extraDebtDeductionM !== 0 || e.extraCashAdditionM !== 0 || e.existingUnvestedAwardsAddedToDenominator !== 0 ||
          !close(e.reconciliationReserveM, 9)) fail("parent_fcfe_claims_or_double_count");
      if (!close(e.currentFx?.units_per_eur, 1.1622) || e.currentFx?.rate_date !== "2026-09-04" ||
          !String(e.currentFx?.source_url).startsWith("https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?")) fail("current_currency_conversion_mismatch");
      let pv = 0;
      let lastFlow;
      for (let i = 0; i < 5; i += 1) {
        const flow = fcfe * a.growthRates.slice(0, i + 1).reduce((product, g) => product * (1 + g), 1);
        const discounted = flow / Math.pow(1 + a.ke, i + 1);
        const row = actual.explicit?.[i];
        if (!row || row.year !== i + 1 || !close(row.growth, a.growthRates[i]) ||
            !close(row.fcfeM, flow) || !close(row.presentValueM, discounted)) fail(`explicit_year_mismatch:${name}:${i + 1}`);
        pv += discounted;
        lastFlow = flow;
      }
      const terminal = lastFlow * (1 + a.terminalGrowth) / (a.ke - a.terminalGrowth);
      const terminalPv = terminal / Math.pow(1 + a.ke, 5);
      const equity = pv + terminalPv;
      expectedValue = equity / denominator * 1.1622;
      if (actual.method !== "parent_economic_fcfe_dcf" || !close(actual.ke, a.ke) ||
          !close(actual.terminalGrowth, a.terminalGrowth) || actual.explicit?.length !== 5 ||
          !close(actual.terminalValueM, terminal) || !close(actual.terminalPresentValueM, terminalPv) ||
          !close(actual.equityValueM, equity) || !close(actual.terminalValueShare, terminalPv / equity)) fail(`independent_dcf_recompute:${name}`);
    } else {
      const diagnostic = sum("cfoM") - sum("cashPpeM") - sum("sbcM") - sum("capitalizedSbcM") - sum("otherFinancingOutflowM");
      const denominator = (basic + (c.claims.allOptions + c.claims.unvestedRsus + c.claims.esppPotentialShares) / 1e6) * (1 + a.newGrantDilution);
      const forwardRevenue = c.sourceTtm.revenueM * (1 + a.revenueGrowth);
      const ev = forwardRevenue * a.evSales;
      const equity = ev + c.balanceSheet.shortTermSecuritiesM + c.balanceSheet.longTermSecuritiesM - c.balanceSheet.financialBorrowingsM;
      expectedValue = equity / denominator;
      if (!close(e.diagnosticCashAfterCompensationM, diagnostic) || e.diagnosticOnlyNotDcf !== true ||
          !close(e.cashReservedForOperationsM, c.balanceSheet.cashM)) fail("iot_cash_cost_or_operating_reserve_mismatch");
      if (actual.method !== "explicit_ntm_ev_sales_not_dcf" || actual.terminalValueM != null ||
          !close(actual.denominatorSharesM, denominator) || !close(actual.nextRevenueM, forwardRevenue) ||
          !close(actual.enterpriseValueM, ev) || !close(actual.equityValueM, equity) ||
          !close(actual.evSales, a.evSales) || !close(actual.newGrantDilution, a.newGrantDilution)) fail(`independent_ev_sales_recompute:${name}`);
    }
    if (!close(actual.fairValue, expectedValue)) fail(`per_share_or_currency_mismatch:${name}`);
    if (name === "base" && !close(result.fairValue, expectedValue)) fail("headline_value_mismatch");
  }
  return { ok: failures.length === 0, failures, scope: "independent_current_scenario_recomputation_not_release_authorization" };
}
