import { prepareReviewedEconomicRows, reviewedNonModelableReason } from "./reviewedEconomicInputs.js";

function finite(value) {
  if (value == null || value === "") return null;
  return Number.isFinite(Number(value)) ? Number(value) : null;
}

function parseJson(value, fallback = null) {
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function selectFinancialPeriod(key, candidates) {
  const hasCoreFinancials = (row) =>
    row?.payload?.revenue_m != null || row?.payload?.net_income_m != null || row?.payload?.cfo_m != null;
  const arq = candidates.find((row) => row.dimension === "ARQ" && hasCoreFinancials(row));
  const art = candidates.find((row) => row.dimension === "ART" && hasCoreFinancials(row));
  const base = arq || art || candidates[0];
  return {
    key,
    ticker: String(base.ticker).toUpperCase(),
    fiscalPeriod: base.fiscal_period,
    availableAt: candidates.map((row) => row.available_at).filter(Boolean).sort().at(-1),
    base: base.payload,
    trailing: (art || base).payload,
    baseDimension: base.dimension,
    hasCoreFinancials: hasCoreFinancials(base) || Boolean(art),
    hasReportedTrailing: Boolean(art)
  };
}

export function* selectedFinancialPeriods(db) {
  let currentKey = null;
  let candidates = [];
  for (const row of db.prepare(`
    SELECT ticker, fiscal_period, dimension, available_at, payload_json
    FROM valuation_pit_financials
    ORDER BY ticker, fiscal_year, fiscal_quarter, dimension
  `).iterate()) {
    const key = `${String(row.ticker).toUpperCase()}::${row.fiscal_period}`;
    if (currentKey && key !== currentKey) {
      yield selectFinancialPeriod(currentKey, candidates);
      candidates = [];
    }
    currentKey = key;
    const payload = parseJson(row.payload_json, {});
    candidates.push({ ...row, payload });
  }
  if (currentKey && candidates.length) yield selectFinancialPeriod(currentKey, candidates);
}

function fiscalQuarterOrdinal(fiscalPeriod) {
  const match = /^(\d{4})-Q([1-4])$/.exec(String(fiscalPeriod || ""));
  return match ? Number(match[1]) * 4 + Number(match[2]) - 1 : null;
}

function consecutiveQuarterFlowKeys(periods, index) {
  const window = periods.slice(Math.max(0, index - 3), index + 1);
  if (window.length < 4 || window.some((period) => !period.hasCoreFinancials || period.baseDimension !== "ARQ")) {
    return false;
  }
  const ordinals = window.map((period) => fiscalQuarterOrdinal(period.fiscalPeriod));
  return ordinals.every((ordinal, position) => ordinal != null && (
    position === 0 || ordinal === ordinals[position - 1] + 1
  ));
}

export function inspectUnmodeledFinancialPeriods(db) {
  const modeled = new Set();
  for (const row of db.prepare(`
    SELECT ticker, fiscal_period
    FROM valuation_pit_model_runs
  `).iterate()) modeled.add(`${String(row.ticker).toUpperCase()}::${row.fiscal_period}`);
  const firstModeledAt = new Map(db.prepare(`
    SELECT ticker, MIN(as_of_date) AS first_modeled_at
    FROM valuation_pit_model_runs
    GROUP BY ticker
  `).all().map((row) => [String(row.ticker).toUpperCase(), row.first_modeled_at]));
  const profiles = new Map();
  const latestModel = db.prepare(`
    SELECT input_json, output_json
    FROM valuation_pit_model_runs
    WHERE ticker = ?
    ORDER BY as_of_date DESC, fiscal_period DESC
    LIMIT 1
  `);
  for (const tickerRow of db.prepare(`
    SELECT DISTINCT ticker
    FROM valuation_pit_model_runs
    ORDER BY ticker
  `).iterate()) {
    const ticker = String(tickerRow.ticker).toUpperCase();
    const row = latestModel.get(ticker);
    const input = parseJson(row.input_json, {});
    const output = parseJson(row.output_json, {});
    profiles.set(
      ticker,
      input.valuationSemantics?.scoreInputs?.profile ||
        output.dataSnapshot?.valuationSemantics?.scoreInputs?.profile ||
        null
    );
  }
  const financialProfiles = new Set(["bank", "insurance", "card_network_lender", "credit_services", "capital_markets"]);
  const earningsProfiles = new Set(["asset_manager", "insurance_broker", "managed_care", "payments_processor"]);
  const gaps = [];
  let selectedCount = 0;

  const inspectTickerPeriods = (periods) => {
    periods.sort((left, right) =>
      (fiscalQuarterOrdinal(left.fiscalPeriod) ?? Number.MAX_SAFE_INTEGER) -
      (fiscalQuarterOrdinal(right.fiscalPeriod) ?? Number.MAX_SAFE_INTEGER)
    );
    for (let index = 0; index < periods.length; index += 1) {
      const period = periods[index];
      selectedCount += 1;
      const hasTrueTrailingBasis = period.hasReportedTrailing || consecutiveQuarterFlowKeys(periods, index);
      let reviewedExclusion = null;
      let invalidReviewedExclusion = null;
      try {
        reviewedExclusion = reviewedNonModelableReason({ ticker: period.ticker, fiscalPeriod: period.fiscalPeriod,
          availableDate: period.availableAt, periodEndDate: period.base?.periodEndDate,
          currency: period.base?.financialStatementCurrency });
      } catch (error) { invalidReviewedExclusion = error.message; }
      if (modeled.has(period.key) && !reviewedExclusion && !invalidReviewedExclusion) continue;
      let data = period.trailing || period.base;
      if (!reviewedExclusion && !invalidReviewedExclusion) {
        try {
          const [fiscalYear, fiscalQuarter] = period.fiscalPeriod.split("-");
          const [economicRow] = prepareReviewedEconomicRows({ ticker: period.ticker, rows: [{ ...period.base,
            fiscalYear: Number(fiscalYear), fiscalQuarter, financialAvailableAt: period.availableAt,
            pitTrailingTwelveMonths: period.trailing }] });
          if (economicRow.reviewedEconomicInput) data = economicRow.pitTrailingTwelveMonths;
        } catch (error) { invalidReviewedExclusion = error.message; }
      }
      const profile = profiles.get(period.ticker) || null;
      const revenue = finite(data.revenue_m);
      const netIncome = finite(data.net_income_m);
      const cfo = finite(data.cfo_m);
      const capex = finite(data.capex_m);
      const fcf = data.reviewedEconomicInput ? finite(data.fcf_after_capex_m) :
        cfo != null && capex != null ? cfo - capex : finite(data.fcf_after_capex_m);
      const shares = finite(data.shares_m ?? period.base?.shares_m);
      const equity = finite(data.equity_m ?? period.base?.equity_m);
      const cash = finite(data.cash_m ?? period.base?.cash_m) || 0;
      const debt = finite(data.debt_m ?? period.base?.debt_m) || 0;
      const conservativeReportedEarnings = netIncome > 0 ? netIncome * 0.75 : null;
      const economicallyMaterialEarnings = conservativeReportedEarnings > 0 &&
        (!(revenue > 0) || conservativeReportedEarnings / revenue >= 0.01);
      const economicallyMaterialFcf = fcf > 0 && (!(revenue > 0) || fcf / revenue >= 0.01);
      let reason;
      let unexpectedlyModelable = false;

      if (invalidReviewedExclusion) {
        reason = "invalid_reviewed_economic_inputs_or_exclusion";
        unexpectedlyModelable = true;
      } else if (reviewedExclusion) {
        reason = modeled.has(period.key) ? "pre_ipo_period_incorrectly_modeled" : reviewedExclusion;
        unexpectedlyModelable = modeled.has(period.key);
      } else if (!period.hasCoreFinancials) {
        reason = "incomplete_provider_income_statement";
      } else if (!hasTrueTrailingBasis) {
        reason = "insufficient_consecutive_quarters_for_true_ttm";
      } else if (!(shares > 0)) {
        reason = "missing_positive_period_end_shares";
      } else if (period.ticker === "MSTR") {
        reason = String(period.availableAt) < "2020-08-11"
          ? "specialized_bitcoin_treasury_model_not_applicable_before_strategy"
          : "bitcoin_fair_value_not_point_in_time_visible";
      } else if (!(revenue > 0)) {
        reason = Math.abs(revenue || 0) < 1 && Math.abs(equity || 0) < 10
          ? "predecessor_shell_or_preoperating_entity"
          : "precommercial_no_positive_revenue";
      } else if (financialProfiles.has(profile) && !(equity > 0)) {
        reason = "nonpositive_reported_equity_for_roe_book_model";
      } else if (earningsProfiles.has(profile) && !economicallyMaterialEarnings) {
        reason = "no_economically_material_through_cycle_earnings";
      } else if (profile === "power_utility" && !economicallyMaterialEarnings && economicallyMaterialFcf) {
        reason = "corroborative_fcf_lacks_standalone_evidence";
      } else if (!economicallyMaterialEarnings && !economicallyMaterialFcf) {
        reason = "no_economically_material_earnings_or_owner_cash_flow";
      } else if (["emerging_biotech", "emerging_health_ai"].includes(profile) && revenue * 2 + cash - debt <= 0) {
        reason = "no_positive_equity_value_after_net_debt";
      } else if (period.availableAt && firstModeledAt.get(period.ticker) &&
          String(period.availableAt) < String(firstModeledAt.get(period.ticker))) {
        reason = "insufficient_independent_initial_model_evidence";
      } else {
        reason = "financials_appear_modelable_but_no_valuation_was_emitted";
        unexpectedlyModelable = true;
      }

      gaps.push({
        ticker: period.ticker,
        fiscalPeriod: period.fiscalPeriod,
        availableAt: period.availableAt,
        profile,
        reason,
        unexpectedlyModelable,
        inputs: {
          revenue,
          netIncome,
          conservativeReportedEarnings,
          fcf,
          shares,
          equity,
          cash,
          debt,
          hasReportedTrailing: period.hasReportedTrailing,
          hasTrueTrailingBasis
        }
      });
    }
  };

  let currentTicker = null;
  let tickerPeriods = [];
  for (const period of selectedFinancialPeriods(db)) {
    if (currentTicker && period.ticker !== currentTicker) {
      inspectTickerPeriods(tickerPeriods);
      tickerPeriods = [];
    }
    currentTicker = period.ticker;
    tickerPeriods.push(period);
  }
  if (tickerPeriods.length) inspectTickerPeriods(tickerPeriods);

  const reasonCounts = Object.fromEntries([...gaps.reduce((counts, gap) => {
    counts.set(gap.reason, (counts.get(gap.reason) || 0) + 1);
    return counts;
  }, new Map()).entries()].sort(([left], [right]) => left.localeCompare(right)));
  return {
    selectedFinancialPeriods: selectedCount,
    modeledPeriods: modeled.size,
    explicitlyUnmodeledPeriods: gaps.length,
    affectedTickers: new Set(gaps.map((gap) => gap.ticker)).size,
    reasonCounts,
    unexpected: gaps.filter((gap) => gap.unexpectedlyModelable),
    gaps
  };
}
