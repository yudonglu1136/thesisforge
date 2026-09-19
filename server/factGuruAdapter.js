import { queryFacts, queryFactsBatch, FactDataError } from "./factRepository.js";

const source = { label: "Sharadar local Fact OS", table: "SF3 / SF3A / SF3B", pitSupported: false };
const previousQuarter = (quarter) => {
  const date = new Date(`${quarter}T00:00:00Z`);
  date.setUTCMonth(Math.floor(date.getUTCMonth() / 3) * 3, 1);
  date.setUTCDate(0);
  return date.toISOString().slice(0, 10);
};

export function canCompareReportingEntities(current, prior) {
  return !prior || (current.rows.length === 1 && prior.rows.length === 1 && current.rows[0].investor_id === prior.rows[0].investor_id);
}

export function mapFactHolding(row, totalValue) {
  return {
    id: `${row.ticker}:${row.security_type}`, ticker: row.ticker,
    issuer: row.issuer_name || row.ticker, cusip: null,
    shares: row.units, value: row.value_usd,
    putCall: row.security_type === "CLL" ? "CALL" : ["CALL", "PUT"].includes(row.security_type) ? row.security_type : "",
    securityType: row.security_type, titleOfClass: row.security_type,
    pctPortfolio: totalValue > 0 && row.value_usd != null ? row.value_usd / totalValue : null,
    rank: row.rank ?? null, source: "sharadar_fact_os", provenance: row.provenance
  };
}

export function mapFactChange(row, totalValue) {
  const action = { NEW: "new", INCREASED: "increased", DECREASED: "reduced", EXITED: "sold_out", UNCHANGED: "unchanged" }[row.change] || "unknown";
  return {
    id: `${row.ticker}:${row.security_type}`, ticker: row.ticker, issuer: row.ticker,
    securityType: row.security_type, putCall: row.security_type === "CLL" ? "CALL" : ["CALL", "PUT"].includes(row.security_type) ? row.security_type : "",
    shares: row.current_units, prevShares: row.previous_units,
    value: row.current_value_usd, previousValue: row.previous_value_usd,
    changeShares: row.unit_change,
    changePct: row.percentage_change == null ? null : row.percentage_change / 100,
    pctPortfolio: totalValue > 0 && row.current_value_usd != null ? row.current_value_usd / totalValue : null,
    action, reportDate: row.quarter, filingDate: null,
    source: "sharadar_fact_os", provenance: row.provenance,
    note: "Reported share change, not a verified trade; corporate actions may affect share counts."
  };
}

export function unavailableFactGuru(guru, error) {
  return {
    ...guru, status: "local_missing", disclosureKind: guru.type === "manager13f" ? "13F-HR" : guru.type,
    generatedAt: new Date().toISOString(), source,
    summary: { totalValue: null, totalPositions: null, reportDate: null, filingDate: null, message: error.message },
    holdings: [], activity: [], transactions: [],
    dataStatus: { status: "unavailable", reason: error.code || "local_data_unavailable", message: error.message },
    pitSupported: false
  };
}

async function identitiesForGuru(guru) {
  const ciks = [...new Set([guru.cik, ...(guru.alternateCiks || [])].filter(Boolean))];
  const responses = await queryFactsBatch(ciks.map((cik) => ({ method: "resolve_investor", args: [], kwargs: { cik } })));
  const identities = responses.filter((r) => r.ok).map((r) => r.result);
  // A reporting-entity transition must not silently reuse the earlier entity.
  if (identities.length !== ciks.length || !identities.length) {
    throw new FactDataError("unverified_investor_mapping", "One or more configured SEC filers cannot be matched exactly to Sharadar investor metadata. No similarly named fund or cached holdings were substituted.");
  }
  return identities;
}

async function combinedHistory(identities) {
  const responses = await queryFactsBatch(identities.map((id) => ({ method: "get_investor_history", args: [id.investor_id] })));
  for (const response of responses) if (!response.ok) throw new FactDataError(response.error.code, response.error.message);
  // Multiple reporting entities can overlap. Do not sum duplicate books or
  // choose one by performance/AUM; an explicit issuer mapping is required.
  const byQuarter = new Map();
  responses.forEach((response, i) => response.result.forEach((row) => {
    const group = byQuarter.get(row.quarter) || [];
    group.push({ ...row, investor_id: identities[i].investor_id }); byQuarter.set(row.quarter, group);
  }));
  return [...byQuarter].sort(([a], [b]) => a.localeCompare(b)).map(([quarter, rows]) => ({ quarter, rows }));
}

async function portfolioAt(item, prior = null) {
  if (item.rows.length !== 1) throw new FactDataError("overlapping_filer_books", "Multiple configured filers report in this quarter. Their books require a verified non-duplicate reporting-entity mapping before aggregation.");
  const row = item.rows[0];
  const [portfolio, changes] = await queryFactsBatch([
    { method: "get_investor_portfolio", args: [row.investor_id, item.quarter], kwargs: { security_type: null } },
    { method: "get_investor_changes", args: [row.investor_id, item.quarter], kwargs: { security_type: null } }
  ]);
  if (!portfolio.ok) throw new FactDataError(portfolio.error.code, portfolio.error.message);
  const totalValue = row.value_usd;
  const holdings = portfolio.result.map((h) => mapFactHolding(h, totalValue));
  const changedReportingEntity = !canCompareReportingEntities(item, prior);
  const comparable = changes.ok && !changedReportingEntity;
  const activity = comparable ? changes.result.map((h) => mapFactChange(h, totalValue)) : [];
  const byId = new Map(activity.map((h) => [h.id, h]));
  for (const holding of holdings) {
    const change = byId.get(holding.id);
    Object.assign(holding, { action: change?.action || "unknown", changeShares: change?.changeShares ?? null, changePct: change?.changePct ?? null });
  }
  return { row, totalValue, holdings, activity, changeStatus: comparable ? "available" : "unavailable", changeMessage: changedReportingEntity ? "The reporting entities differ from the preceding quarter. A transfer between filers is not classified as a new Guru purchase or exit without a verified consolidated-book mapping." : changes.error?.message || "" };
}

export async function loadFactGuru(guru) {
  if (guru.type !== "manager13f") return unavailableFactGuru(guru, new FactDataError("unsupported_identity", "This profile is not a 13F institutional manager. No historical custom holdings feed is used by the local Fact OS."));
  try {
    const history = await combinedHistory(await identitiesForGuru(guru));
    const latest = history.at(-1);
    if (!latest) throw new FactDataError("local_data_unavailable", "No local investor-quarter holdings are available.");
    const prior = history.find((h) => h.quarter === previousQuarter(latest.quarter));
    const book = await portfolioAt(latest, prior);
    const weights = book.holdings.map((h) => h.pctPortfolio).filter((v) => Number.isFinite(v)).sort((a, b) => b - a);
    const priorValue = prior?.rows.length === 1 ? prior.rows[0].value_usd : null;
    const filing = { form: "13F-HR", cik: guru.cik, reportDate: latest.quarter, filingDate: null, accessionNumber: null, primaryDocument: null, secUrl: null, source: "sharadar_fact_os" };
    return {
      ...guru, status: "local-db", disclosureKind: "13F-HR", generatedAt: new Date().toISOString(), source,
      latestFiling: filing, previousFiling: null,
      summary: { reportDate: latest.quarter, filingDate: null, previousReportDate: prior?.quarter || null,
        totalValue: book.totalValue, previousValue: priorValue,
        valueChange: book.totalValue != null && priorValue != null ? book.totalValue - priorValue : null,
        totalPositions: book.row.reported_positions,
        newPositions: book.changeStatus === "available" ? book.activity.filter((h) => h.action === "new").length : null,
        increasedPositions: book.changeStatus === "available" ? book.activity.filter((h) => h.action === "increased").length : null,
        reducedPositions: book.changeStatus === "available" ? book.activity.filter((h) => h.action === "reduced").length : null,
        soldOutPositions: book.changeStatus === "available" ? book.activity.filter((h) => h.action === "sold_out").length : null,
        top10Weight: weights.slice(0, 10).reduce((a, b) => a + b, 0), topHoldingWeight: weights[0] ?? null,
        concentrationHhi: weights.reduce((a, b) => a + b * b, 0), turnoverProxy: null },
      holdings: book.holdings, activity: book.activity.filter((h) => h.action !== "unchanged"), transactions: [],
      dataStatus: { status: "local-db", reason: "sharadar_canonical", message: "Local SF3 quarterly positions. Actual filing dates are not supplied; these observations cannot be used as historical knowledge dates.", changeStatus: book.changeStatus, changeMessage: book.changeMessage },
      pitSupported: false
    };
  } catch (error) { return unavailableFactGuru(guru, error); }
}

export async function loadFactGuruDashboard(gurus) {
  // Preload each phase in one Python reader, so a dashboard does not start a
  // subprocess (or rebuild the security master) for every individual manager.
  const ciks = [...new Set(gurus.filter((g) => g.type === "manager13f").flatMap((g) => [g.cik, ...(g.alternateCiks || [])]).filter(Boolean))];
  try {
    const identities = await queryFactsBatch(ciks.map((cik) => ({ method: "resolve_investor", args: [], kwargs: { cik } })));
    const investorIds = [...new Set(identities.filter((r) => r.ok).map((r) => r.result.investor_id))];
    if (investorIds.length) {
      const histories = await queryFactsBatch(investorIds.map((id) => ({ method: "get_investor_history", args: [id] })));
      const latestRequests = histories.flatMap((r, i) => {
        const latest = r.ok ? r.result.at(-1) : null;
        if (!latest) return [];
        return [
          { method: "get_investor_portfolio", args: [investorIds[i], latest.quarter], kwargs: { security_type: null } },
          { method: "get_investor_changes", args: [investorIds[i], latest.quarter], kwargs: { security_type: null } }
        ];
      });
      if (latestRequests.length) await queryFactsBatch(latestRequests);
    }
  } catch (error) {
    return gurus.map((guru) => unavailableFactGuru(guru, error));
  }
  const result = [];
  for (const guru of gurus) result.push(await loadFactGuru(guru));
  return result;
}

export async function loadFactGuruExposure(guru, { limit = 24 } = {}) {
  try {
    const allQuarters = await combinedHistory(await identitiesForGuru(guru));
    const quarters = allQuarters.slice(-Math.max(1, Math.min(200, Number(limit) || 24)));
    const requests = quarters.filter((item) => item.rows.length === 1).flatMap((item) => [
      { method: "get_investor_portfolio", args: [item.rows[0].investor_id, item.quarter], kwargs: { security_type: null } },
      { method: "get_investor_changes", args: [item.rows[0].investor_id, item.quarter], kwargs: { security_type: null } }
    ]);
    if (requests.length) await queryFactsBatch(requests);
    const history = []; const errors = [];
    for (const item of quarters) {
      try {
        const prior = allQuarters.find((row) => row.quarter === previousQuarter(item.quarter));
        const book = await portfolioAt(item, prior);
        history.push({
          reportDate: item.quarter, filingDate: null, accessionNumber: null,
          quarterLabel: `${item.quarter.slice(0, 4)} Q${Math.ceil(Number(item.quarter.slice(5, 7)) / 3)}`,
          reported13fValue: book.totalValue, positionCount: book.row.reported_positions,
          topHoldings: book.holdings, holdings: book.holdings, largestChanges: book.activity,
          filing: { reportDate: item.quarter, filingDate: null, form: "13F-HR" },
          pitSupported: false, changeStatus: book.changeStatus, changeMessage: book.changeMessage, provenance: book.row.provenance
        });
      } catch (error) { errors.push({ reportDate: item.quarter, reason: error.code || "local_data_unavailable", message: error.message }); }
    }
    return { generatedAt: new Date().toISOString(), status: history.length ? "local-db" : "missing", guru, source, history, latest: history.at(-1) || null, meta: { returnedQuarters: history.length, errors }, cache: { status: "local-only" } };
  } catch (error) {
    return { generatedAt: new Date().toISOString(), status: "missing", guru, source, history: [], latest: null, message: error.message, cache: { status: "unavailable" } };
  }
}
