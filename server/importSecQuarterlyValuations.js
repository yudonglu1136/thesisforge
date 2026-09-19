import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { readTranscriptQaByTickerPeriod } from "./transcriptQaClient.js";
import { sp500ValuationProfile } from "./sp500ValuationUniverse.js";
import { guruValuationProfile } from "./guruValuationUniverse.js";
import { prepareReviewedEconomicRows, applyReviewedEquityClaims } from "./reviewedEconomicInputs.js";

const CURRENT_DB_PATH = process.env.SQLITE_DB_PATH || path.join(process.cwd(), "server/data/guru-analysis.sqlite");
const YOUTUBE_DB_PATH = process.env.YOUTUBE_TRANSCRIPT_DB_PATH
  || path.join(os.homedir(), "Documents/youtube_transcript_db/transcripts.sqlite");
const TRINITY_MODEL_DIR = process.env.TRINITY_MODEL_DIR
  || path.join(os.homedir(), "Documents/ai-trinity-dashboard");
const TRINITY_MODEL_PATH = process.env.TRINITY_MODEL_PATH
  || path.join(TRINITY_MODEL_DIR, "trinity_model.json");
const CACHE_DIR = process.env.SEC_FACTS_CACHE_DIR || path.join(process.cwd(), "server/data/sec-companyfacts");
const SEC_USER_AGENT = process.env.SEC_USER_AGENT || "thesisforge-guru-analysis yudonglu1136@gmail.com";
const DEFAULT_TICKERS = (process.env.SEC_VALUATION_TICKERS || "ALL")
  .split(",")
  .map((ticker) => ticker.trim().toUpperCase())
  .filter(Boolean);

const SEC_FACTS_URL = "https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json";
const SEC_TICKER_MAP_URL = "https://www.sec.gov/files/company_tickers.json";
const SEC_TICKER_MAP_CACHE_PATH = path.join(CACHE_DIR, "company_tickers.json");
const MAX_EVIDENCE_EXCERPTS = 4;
const OUTPUT_START_DATE = process.env.SEC_VALUATION_START_DATE || "2010-01-01";

const TAGS = {
  revenue_m: [
    "RevenuesNetOfInterestExpense",
    "RevenueFromContractWithCustomerExcludingAssessedTax",
    "RevenueFromContractWithCustomerIncludingAssessedTax",
    "Revenues",
    "SalesRevenueNet",
    "Revenue"
  ],
  gross_profit_m: ["GrossProfit"],
  operating_income_m: [
    "OperatingIncomeLoss",
    "ProfitLossFromOperatingActivities",
    "OperatingProfitLossOperating"
  ],
  net_income_m: [
    "NetIncomeLoss",
    "NetIncomeLossAvailableToCommonStockholdersBasic",
    "ProfitLoss",
    "ProfitLossAttributableToOwnersOfParent",
    "ProfitLossAttributableToOrdinaryEquityHoldersOfParentEntity"
  ],
  cfo_m: ["NetCashProvidedByUsedInOperatingActivities", "CashFlowsFromUsedInOperatingActivities"],
  capex_m: [
    "PaymentsToAcquirePropertyPlantAndEquipment",
    "PurchaseOfPropertyPlantAndEquipmentClassifiedAsInvestingActivities"
  ]
};

const SHARE_TAGS = [
  "WeightedAverageNumberOfDilutedSharesOutstanding",
  "WeightedAverageNumberOfSharesOutstandingBasic",
  "WeightedAverageNumberOfShareOutstandingBasicAndDiluted",
  "WeightedAverageShares",
  "AdjustedWeightedAverageShares",
  "DilutedWeightedAverageShares"
];

const SHARE_POINT_TAGS = [
  "EntityCommonStockSharesOutstanding",
  "CommonStockSharesOutstanding",
  "CommonStockSharesIssued"
];

const POINT_TAGS = {
  equity_m: [
    "StockholdersEquity",
    "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest",
    "PartnersCapital",
    "Equity",
    "EquityAttributableToOwnersOfParent"
  ],
  assets_m: ["Assets"],
  cash_m: [
    "CashAndCashEquivalents",
    "CashAndCashEquivalentsAtCarryingValue",
    "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents",
    "CashAndDueFromBanks",
    "Cash"
  ],
  debt_m: []
};

const CORE_DISCLOSURE_METRICS = [
  "revenue_m",
  "gross_profit_m",
  "operating_income_m",
  "net_income_m",
  "cfo_m",
  "capex_m"
];

const DEBT_TOTAL_TAGS = [
  "Debt",
  "DebtAndFinanceLeaseObligations",
  "LongTermDebtAndFinanceLeaseObligations",
  "Borrowings",
  "FinancialLiabilitiesAtAmortisedCost",
  "FinancialLiabilities"
];

const DEBT_COMPONENT_TAGS = [
  "LongTermDebtAndFinanceLeaseObligationsCurrent",
  "LongTermDebtAndFinanceLeaseObligationsNoncurrent",
  "LongTermDebtCurrent",
  "LongTermDebtNoncurrent",
  "ShortTermBorrowings",
  "ShortTermDebtCurrent",
  "DebtCurrent",
  "LongTermDebt",
  "CurrentBorrowingsAndCurrentPortionOfNoncurrentBorrowings",
  "CurrentPortionOfLongtermBorrowings",
  "LongtermBorrowings",
  "NoncurrentPortionOfOtherNoncurrentBorrowings"
];

const TRINITY_TO_DASHBOARD_TICKER = {
  GOOG: "GOOGL"
};

const VALUATION_PROFILES = {
  AAPL: "mega_cap_platform",
  AAOI: "optical_networking_turnaround",
  ABNB: "platform_marketplace_reinvestment",
  ADBE: "software_growth",
  ADI: "semiconductor_value",
  ADP: "information_services",
  ADSK: "software_growth",
  AEP: "power_utility",
  ALNY: "emerging_biotech",
  AMZN: "platform_reinvestment",
  AMAT: "semiconductor_equipment",
  AMD: "semiconductor_growth",
  AMGN: "biopharma",
  ANET: "networking_hardware",
  APP: "hypergrowth_ai_software",
  ARM: "semiconductor_growth",
  ASML: "semiconductor_equipment",
  AUTL: "emerging_biotech",
  AVAV: "defense_growth",
  AVGO: "semiconductor_growth",
  AXON: "defense_growth",
  AXP: "card_network_lender",
  AZN: "biopharma",
  "BA.L": "defense_prime",
  BAC: "bank",
  BE: "energy_technology",
  BKNG: "platform_marketplace_reinvestment",
  BKR: "industrial_growth",
  BMY: "biopharma",
  BNY: "capital_markets",
  CB: "insurance",
  CCEP: "quality_consumer",
  CDNS: "software_growth",
  CEG: "power_utility",
  CHTR: "media_telecom",
  CIEN: "optical_networking_turnaround",
  CMCSA: "media_telecom",
  COHR: "optical_networking_turnaround",
  COST: "quality_consumer",
  CPAY: "payments_processor",
  CPRT: "information_services",
  CRM: "software_growth",
  CRWD: "software_growth",
  CSCO: "networking_hardware",
  CSX: "industrial_growth",
  CTAS: "industrial_growth",
  CTSH: "information_services",
  DASH: "platform_marketplace_reinvestment",
  DDOG: "software_growth",
  "DGE.L": "quality_consumer",
  DXCM: "medtech_platform",
  EA: "interactive_entertainment",
  EQT: "energy_e_and_p",
  ESTC: "software_growth",
  EXC: "power_utility",
  FANG: "energy_e_and_p",
  FAST: "industrial_growth",
  FER: "industrial_growth",
  FI: "payments_processor",
  FIS: "payments_processor",
  FISV: "payments_processor",
  FTNT: "software_growth",
  GEHC: "mature_medtech",
  GILD: "biopharma",
  GPN: "payments_processor",
  GS: "capital_markets",
  GOOG: "ads_ai_platform",
  GOOGL: "ads_ai_platform",
  GTLB: "software_growth",
  HON: "industrial_growth",
  HOOD: "capital_markets",
  IBM: "information_services",
  IBKR: "capital_markets",
  IDXX: "medtech_platform",
  INSM: "emerging_biotech",
  INTC: "semiconductor_cyclical",
  INTU: "software_growth",
  ISRG: "medtech_platform",
  JPM: "bank",
  KDP: "quality_consumer",
  KHC: "quality_consumer",
  KLAC: "semiconductor_equipment",
  KTOS: "defense_growth",
  LEGN: "emerging_biotech",
  LITE: "optical_networking_turnaround",
  LLY: "biopharma_growth",
  LIN: "industrial_gases_compounder",
  LMT: "defense_prime",
  LRCX: "semiconductor_equipment",
  LSEG: "information_services",
  MA: "payments_network",
  MAR: "quality_consumer",
  MCK: "healthcare_distribution",
  MCHP: "semiconductor_value",
  MDLZ: "quality_consumer",
  MELI: "platform_marketplace_reinvestment",
  META: "mega_cap_platform",
  MNST: "quality_consumer",
  MPWR: "semiconductor_growth",
  MRVL: "semiconductor_growth",
  MS: "capital_markets",
  MSFT: "mega_cap_platform",
  MSTR: "bitcoin_treasury_software",
  MU: "semiconductor_cyclical",
  NOC: "defense_prime",
  NOW: "software_growth",
  NFLX: "subscription_streaming_platform",
  NXPI: "semiconductor_value",
  NTRA: "genetic_diagnostics_growth",
  NTRS: "capital_markets",
  NVDA: "semiconductor_growth",
  ODFL: "industrial_growth",
  ORCL: "mega_cap_platform",
  ORLY: "quality_consumer",
  PANW: "software_growth",
  PAYX: "information_services",
  PCAR: "industrial_growth",
  PEP: "quality_consumer",
  PDD: "platform_marketplace_reinvestment",
  PFG: "capital_markets",
  PLTR: "hypergrowth_ai_software",
  PYPL: "payments_processor",
  QCOM: "semiconductor_value",
  REGN: "biopharma_growth",
  RKLB: "space_launch_growth",
  ROP: "industrial_growth",
  RJF: "capital_markets",
  ROST: "quality_consumer",
  RTX: "defense_prime",
  SBUX: "quality_consumer",
  SCHW: "capital_markets",
  SE: "platform_marketplace_reinvestment",
  SHOP: "platform_marketplace_reinvestment",
  SNDK: "semiconductor_storage_cycle",
  SNOW: "software_growth",
  SPCX: "space_platform_ipo",
  STX: "semiconductor_storage_cycle",
  STT: "capital_markets",
  SNPS: "software_growth",
  TEM: "emerging_health_ai",
  TMUS: "media_telecom",
  TTWO: "interactive_entertainment",
  TXN: "semiconductor_value",
  TRI: "information_services",
  TRV: "insurance",
  TSLA: "ev_autonomy_platform",
  TSM: "semiconductor_foundry",
  UNH: "managed_care",
  V: "payments_network",
  VRSK: "information_services",
  VRTX: "biopharma_growth",
  WBD: "media_telecom",
  WDAY: "software_growth",
  WDC: "semiconductor_storage_cycle",
  WMT: "quality_consumer",
  XEL: "power_utility",
  XYZ: "payments_processor",
  ZS: "hypergrowth_ai_software"
};

const SEC_FACT_UNIT_OVERRIDES = {
  CCEP: "EUR",
  FER: "EUR"
};

const SHARE_COUNT_OVERRIDES = {
  V: {
    sharesM: 1945.5,
    source: "legacy Fundamental Analysis Visa FY2026 Q2 diluted share count"
  }
};

function parseJson(value, fallback = null) {
  if (!value) return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function finiteNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function clamp(value, min, max) {
  const number = finiteNumber(value);
  if (number == null) return null;
  return Math.max(min, Math.min(max, number));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function addDays(dateText, daysToAdd) {
  const date = new Date(`${dateText}T00:00:00Z`);
  if (Number.isNaN(date.getTime())) return null;
  date.setUTCDate(date.getUTCDate() + daysToAdd);
  return date.toISOString().slice(0, 10);
}

function pct(n, d) {
  if (n == null || d == null || d === 0) return null;
  return (n / d - 1) * 100;
}

function margin(n, d) {
  if (n == null || d == null || d === 0) return null;
  return n / d * 100;
}

function days(row) {
  if (!row?.start || !row?.end) return null;
  const start = Date.parse(row.start);
  const end = Date.parse(row.end);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  return Math.round((end - start) / 86400000) + 1;
}

function normalizeCik(cik) {
  return String(cik || "").replace(/\D/g, "").padStart(10, "0");
}

function secCompanyFactsUrl(cik) {
  return SEC_FACTS_URL.replace("{cik}", normalizeCik(cik));
}

function sumFiniteValues(rows, key) {
  const values = rows
    .map((row) => finiteNumber(row?.[key]))
    .filter((value) => value != null);
  return values.length ? values.reduce((sum, value) => sum + value, 0) : null;
}

function buildSpacexTrinityModel(trinity) {
  const spacex = trinity?.spacex || {};
  const ipo = spacex.ipo_terms || {};
  const companyRow = (trinity?.companies || []).find((row) => String(row?.ticker || "").toUpperCase() === "SPCX") || {};
  const research = trinity?.investment_research || {};
  const quarterlyRows = (research.quarterly_financials || []).filter((row) => String(row?.company || "").toUpperCase() === "SPCX");
  const segmentRows = (research.segment_financials || []).filter((row) => String(row?.company || "").toUpperCase() === "SPCX");
  const sourceUrl = ipo.source_url || companyRow.source_url || quarterlyRows[0]?.source || null;
  const sharesM = finiteNumber(ipo.total_shares_post_offering) != null
    ? finiteNumber(ipo.total_shares_post_offering) / 1_000_000
    : null;
  if (!(sharesM > 0) || !sourceUrl) return null;

  const annualSegments = segmentRows.filter((row) =>
    Number(row?.fiscal_year) === 2025 &&
    String(row?.fiscal_quarter || "").trim() === "2025" &&
    String(row?.data_type || "").includes("reported")
  );
  const latestSegments = segmentRows.filter((row) =>
    Number(row?.fiscal_year) === 2026 &&
    /^Q1\b/i.test(String(row?.fiscal_quarter || "")) &&
    String(row?.data_type || "").includes("reported")
  );
  const latestReported = quarterlyRows.find((row) => Number(row?.fiscal_year) === 2026) || quarterlyRows[0] || {};
  const latestGrossProfit = sumFiniteValues(latestSegments, "gross_profit");
  const annualGrossProfit = sumFiniteValues(annualSegments, "gross_profit");
  const annualAdjustedEbitda = sumFiniteValues(annualSegments, "adjusted_ebitda");
  const annualCapex = sumFiniteValues(annualSegments, "capex");

  const annualFinancials = annualSegments.length ? [{
    period: "FY2025",
    source_url: sourceUrl,
    data_type: "SpaceX S-1/A reported segment total",
    revenue_m: sumFiniteValues(annualSegments, "revenue"),
    revenue_growth_pct: null,
    gross_profit_m: annualGrossProfit,
    gross_margin_pct: margin(annualGrossProfit, sumFiniteValues(annualSegments, "revenue")),
    operating_income_m: sumFiniteValues(annualSegments, "operating_income"),
    operating_margin_pct: margin(sumFiniteValues(annualSegments, "operating_income"), sumFiniteValues(annualSegments, "revenue")),
    net_income_m: null,
    cfo_m: null,
    capex_m: annualCapex,
    fcf_after_capex_m: annualAdjustedEbitda != null && annualCapex != null ? annualAdjustedEbitda - annualCapex : null,
    cash_m: finiteNumber(ipo.actual_cash_m_at_2026_03_31),
    debt_m: finiteNumber(ipo.total_long_term_debt_m)
  }] : [];

  const latestRevenue = finiteNumber(latestReported.revenue);
  const latestOperatingIncome = finiteNumber(latestReported.operating_income);
  return {
    ticker: "SPCX",
    cik: normalizeCik(ipo.cik || "1181412"),
    company: companyRow.company || ipo.issuer || "SpaceX",
    category: companyRow.category || "space / connectivity / AI data center",
    sector: "Space platform IPO",
    latest_reported_period: "Q1 2026 S-1/A",
    diluted_or_outstanding_shares_m: sharesM,
    sources: [{ label: ipo.filing || "SpaceX S-1/A", url: sourceUrl }],
    annual_financials: annualFinancials,
    latest_quarter: {
      period: "Q1 FY2026",
      end_date: "2026-03-31",
      source_url: sourceUrl,
      data_type: latestReported.data_type || "SpaceX S-1/A reported latest quarter",
      revenue_m: latestRevenue,
      revenue_growth_pct: finiteNumber(latestReported.revenue_growth_pct ?? companyRow.latest_revenue_growth_pct),
      gross_profit_m: latestGrossProfit,
      gross_margin_pct: margin(latestGrossProfit, latestRevenue),
      operating_income_m: latestOperatingIncome,
      operating_margin_pct: finiteNumber(latestReported.operating_margin_pct) ?? margin(latestOperatingIncome, latestRevenue),
      net_income_m: finiteNumber(latestReported.net_income),
      cfo_m: null,
      capex_m: sumFiniteValues(latestSegments, "capex"),
      fcf_after_capex_m: finiteNumber(latestReported.fcf),
      cash_m: finiteNumber(ipo.pro_forma_as_adjusted_cash_m) ?? finiteNumber(ipo.actual_cash_m_at_2026_03_31),
      debt_m: finiteNumber(ipo.total_long_term_debt_m)
    }
  };
}

function readTrinityCompanyModels(trinity) {
  const models = new Map();
  for (const [sourceTicker, model] of Object.entries(trinity.public_company_models || {})) {
    const ticker = String(model?.ticker || sourceTicker).toUpperCase();
    const dashboardTicker = dashboardTickerForTrinity(ticker);
    models.set(dashboardTicker, { ...model, ticker });
    models.set(ticker, { ...model, ticker });
  }

  if (!fs.existsSync(TRINITY_MODEL_DIR)) return models;
  for (const file of fs.readdirSync(TRINITY_MODEL_DIR)) {
    if (!file.endsWith("_model.json")) continue;
    const model = parseJson(fs.readFileSync(path.join(TRINITY_MODEL_DIR, file), "utf8"), null);
    if (!model?.ticker) continue;
    const ticker = String(model.ticker).toUpperCase();
    const dashboardTicker = dashboardTickerForTrinity(ticker);
    models.set(dashboardTicker, { ...model, ticker });
    models.set(ticker, { ...model, ticker });
  }

  const spacexModel = buildSpacexTrinityModel(trinity);
  if (spacexModel?.ticker) {
    models.set(spacexModel.ticker, spacexModel);
  }

  return models;
}

async function fetchJsonWithCache(url, cachePath) {
  if (fs.existsSync(cachePath) && process.env.SEC_FACTS_REFRESH !== "1") {
    return parseJson(fs.readFileSync(cachePath, "utf8"), {});
  }
  const response = await fetch(url, {
    headers: {
      "User-Agent": SEC_USER_AGENT,
      "Accept": "application/json"
    }
  });
  if (!response.ok) {
    throw new Error(`SEC request failed ${response.status}: ${url}`);
  }
  const payload = await response.json();
  fs.mkdirSync(path.dirname(cachePath), { recursive: true });
  fs.writeFileSync(cachePath, JSON.stringify(payload));
  return payload;
}

async function readSecTickerMap() {
  const payload = await fetchJsonWithCache(SEC_TICKER_MAP_URL, SEC_TICKER_MAP_CACHE_PATH);
  const byTicker = new Map();
  for (const item of Object.values(payload || {})) {
    const ticker = String(item.ticker || "").toUpperCase();
    if (!ticker) continue;
    byTicker.set(ticker, item);
  }
  return byTicker;
}

function unitsFor(facts, tag, unit = "USD") {
  for (const namespace of ["us-gaap", "ifrs-full", "dei"]) {
    const item = facts?.[namespace]?.[tag];
    const units = item?.units?.[unit];
    if (Array.isArray(units)) return units;
  }
  return [];
}

function secFactUnitForTicker(ticker) {
  return SEC_FACT_UNIT_OVERRIDES[String(ticker || "").toUpperCase()] || "USD";
}

function rowValueM(row) {
  const value = finiteNumber(row?.val);
  return value == null ? null : value / 1_000_000;
}

function shareValueM(row) {
  const value = finiteNumber(row?.val);
  if (value == null) return null;
  // Some newer filers report share counts in thousands even though the XBRL unit is "shares".
  if (value >= 10_000 && value < 1_000_000) return value / 1_000;
  return value / 1_000_000;
}

function inferFiscalYearEnd(facts, unit = "USD") {
  const annualRows = Object.values(TAGS).flat()
    .flatMap((tag) => unitsFor(facts, tag, unit))
    .filter((row) => ["10-K", "20-F", "40-F"].includes(row?.form) && days(row) >= 300 && row.end)
    .sort((left, right) => String(left.end).localeCompare(String(right.end)) || String(left.filed).localeCompare(String(right.filed)));
  const latest = annualRows.at(-1);
  if (!latest?.end) return { month: 12, day: 31 };
  const [, month, day] = String(latest.end).split("-").map(Number);
  return { month, day };
}

function fiscalPeriodFromEnd(endDate, fiscalYearEnd) {
  const [calendarYear, month, day] = String(endDate || "").split("-").map(Number);
  if (!calendarYear || !month || !day) return null;
  const rowEnd = dateUtc(endDate);
  let nearest = null;
  if (rowEnd != null) {
    for (const candidateYear of [calendarYear - 1, calendarYear, calendarYear + 1]) {
      for (const fiscalQuarter of ["Q1", "Q2", "Q3", "Q4"]) {
        const expectedEnd = expectedFiscalPeriodEndDate(candidateYear, fiscalQuarter, fiscalYearEnd);
        if (expectedEnd == null) continue;
        const diffDays = Math.abs(rowEnd - expectedEnd) / 86_400_000;
        if (diffDays > 45) continue;
        if (!nearest || diffDays < nearest.diffDays) {
          nearest = { fiscalYear: candidateYear, fiscalQuarter, diffDays };
        }
      }
    }
  }
  if (nearest) {
    return {
      fiscalYear: nearest.fiscalYear,
      fiscalQuarter: nearest.fiscalQuarter
    };
  }
  const fiscalYear = (month > fiscalYearEnd.month || (month === fiscalYearEnd.month && day > fiscalYearEnd.day))
    ? calendarYear + 1
    : calendarYear;
  const fiscalEndMonth = fiscalYearEnd.month;
  const offset = (month - fiscalEndMonth + 12) % 12;
  if (offset === 3) return { fiscalYear, fiscalQuarter: "Q1" };
  if (offset === 6) return { fiscalYear, fiscalQuarter: "Q2" };
  if (offset === 9) return { fiscalYear, fiscalQuarter: "Q3" };
  if (offset === 0) return { fiscalYear, fiscalQuarter: "Q4" };
  const fallbackQuarter = `Q${Math.max(1, Math.min(4, Math.ceil((offset || 12) / 3)))}`;
  return { fiscalYear, fiscalQuarter: fallbackQuarter };
}

function dateUtc(dateText) {
  const [year, month, day] = String(dateText || "").split("-").map(Number);
  if (!year || !month || !day) return null;
  return Date.UTC(year, month - 1, day);
}

function monthEndCandidate(year, month, day) {
  const monthIndex = month - 1;
  const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return Date.UTC(year, monthIndex, Math.min(day, lastDay));
}

function expectedFiscalPeriodEndDate(fiscalYear, fiscalQuarter, fiscalYearEnd) {
  const year = finiteNumber(fiscalYear);
  const fp = String(fiscalQuarter || "").toUpperCase();
  if (!year || !fiscalYearEnd?.month || !fiscalYearEnd?.day) return null;
  const quartersBeforeYearEnd = { Q1: 3, Q2: 2, Q3: 1, Q4: 0, FY: 0 }[fp];
  if (quartersBeforeYearEnd == null) return null;
  let month = fiscalYearEnd.month - quartersBeforeYearEnd * 3;
  let calendarYear = year;
  while (month <= 0) {
    month += 12;
    calendarYear -= 1;
  }
  return monthEndCandidate(calendarYear, month, fiscalYearEnd.day);
}

function reportedPeriodMatchesEndDate(row, fiscalYearEnd, reportedFy, reportedFp) {
  const rowEnd = dateUtc(row?.end);
  const expectedEnd = expectedFiscalPeriodEndDate(reportedFy, reportedFp, fiscalYearEnd);
  if (rowEnd == null || expectedEnd == null) return false;
  const toleranceDays = reportedFp === "FY" ? 65 : 45;
  return Math.abs(rowEnd - expectedEnd) / 86_400_000 <= toleranceDays;
}

function matchesReportedFiscalYear(row, derived) {
  const reportedFy = finiteNumber(row?.fy);
  const fiscalYear = finiteNumber(derived?.fiscalYear);
  if (reportedFy == null || fiscalYear == null) return true;
  return reportedFy === fiscalYear;
}

function filingLagDays(row) {
  const filed = dateUtc(row?.filed);
  const end = dateUtc(row?.end);
  if (filed == null || end == null) return null;
  return (filed - end) / 86_400_000;
}

function isLikelyCurrentDisclosure(row, derived) {
  const lag = filingLagDays(row);
  if (lag == null || lag < -5) return false;
  const form = String(row?.form || "").toUpperCase();
  const isAnnualForm = ["10-K", "20-F", "40-F"].includes(form);
  const threshold = isAnnualForm || derived?.fiscalQuarter === "FY" ? 185 : 140;
  return lag <= threshold;
}

function reportedFiscalPeriod(row, derived, fiscalYearEnd) {
  const reportedFy = finiteNumber(row?.fy);
  const reportedFp = String(row?.fp || "").toUpperCase();
  if (reportedFy != null && ["Q1", "Q2", "Q3", "Q4"].includes(reportedFp)) {
    if (reportedPeriodMatchesEndDate(row, fiscalYearEnd, reportedFy, reportedFp)) {
      return { fiscalYear: reportedFy, fiscalQuarter: reportedFp, source: "reported" };
    }
    if (derived && isLikelyCurrentDisclosure(row, derived)) return { ...derived, source: "filed-derived" };
    if (derived) return { ...derived, source: "comparative-derived" };
    return null;
  }
  if (reportedFy != null && reportedFp === "FY") {
    if (reportedPeriodMatchesEndDate(row, fiscalYearEnd, reportedFy, "FY")) {
      return { fiscalYear: reportedFy, fiscalQuarter: "FY", source: "reported" };
    }
    if (derived && isLikelyCurrentDisclosure(row, derived)) return { ...derived, source: "filed-derived" };
    if (derived) return { ...derived, source: "comparative-derived" };
    return null;
  }
  if (!derived) return null;
  return { ...derived, source: "derived" };
}

function factRowsForMetric(facts, metric, fiscalYearEnd, options = {}) {
  const tags = options.tags || TAGS[metric] || [];
  const unit = options.unit || "USD";
  const rows = [];
  for (const tag of tags) {
    for (const row of unitsFor(facts, tag, unit)) {
      if (!row?.fy || !row?.fp || !row?.filed || !row?.end || !row?.form) continue;
      const rowDays = days(row);
      const value = options.valueTransform ? options.valueTransform(row) : rowValueM(row);
      if (value == null || rowDays == null) continue;
      const derived = fiscalPeriodFromEnd(row.end, fiscalYearEnd);
      const period = reportedFiscalPeriod(row, derived, fiscalYearEnd);
      if (!period) continue;
      if (period.source === "comparative-derived") continue;
      if (period.source === "derived" && !matchesReportedFiscalYear(row, derived)) continue;
      const isAnnual = ["10-K", "20-F", "40-F"].includes(row.form) && rowDays >= 300;
      rows.push({
        ...row,
        metric,
        tag,
        fy: period.fiscalYear,
        fp: isAnnual ? "FY" : period.fiscalQuarter,
        originalFy: row.fy,
        originalFp: row.fp,
        fiscalPeriodSource: period.source,
        filed: row.filed,
        end: row.end,
        rowDays,
        value
      });
    }
  }
  return rows;
}

function chooseAsReported(rows) {
  return [...rows].sort((left, right) =>
    String(left.filed).localeCompare(String(right.filed)) ||
    String(left.tag).localeCompare(String(right.tag)) ||
    Math.abs((left.rowDays || 0) - 91) - Math.abs((right.rowDays || 0) - 91)
  )[0] || null;
}

function directQuarterRows(rows) {
  const direct = new Map();
  for (const row of rows) {
    if (!["10-Q", "6-K"].includes(row.form)) continue;
    if (!["Q1", "Q2", "Q3"].includes(row.fp)) continue;
    if (row.rowDays < 55 || row.rowDays > 125) continue;
    const key = `${row.fy}::${row.fp}`;
    const existing = direct.get(key);
    const chosen = chooseAsReported(existing ? [existing, row] : [row]);
    direct.set(key, chosen);
  }
  return direct;
}

function ytdRows(rows) {
  const ytd = new Map();
  for (const row of rows) {
    if (!["Q1", "Q2", "Q3", "FY"].includes(row.fp)) continue;
    if (row.fp === "FY" && !["10-K", "20-F", "40-F"].includes(row.form)) continue;
    if (row.fp !== "FY" && !["10-Q", "6-K"].includes(row.form)) continue;
    if (row.fp === "Q1" && (row.rowDays < 55 || row.rowDays > 125)) continue;
    if (row.fp === "Q2" && (row.rowDays < 130 || row.rowDays > 215)) continue;
    if (row.fp === "Q3" && (row.rowDays < 220 || row.rowDays > 310)) continue;
    if (row.fp === "FY" && row.rowDays < 300) continue;
    const key = `${row.fy}::${row.fp}`;
    const existing = ytd.get(key);
    const chosen = chooseAsReported(existing ? [existing, row] : [row]);
    ytd.set(key, chosen);
  }
  return ytd;
}

function buildMetricQuarterMap(facts, metric, fiscalYearEnd, options = {}) {
  const rows = factRowsForMetric(facts, metric, fiscalYearEnd, options);
  const direct = directQuarterRows(rows);
  const ytd = ytdRows(rows);
  const years = [...new Set(rows.map((row) => row.fy))].sort((left, right) => left - right);
  const quarters = new Map();

  for (const fy of years) {
    const previousYtd = { Q1: null, Q2: null, Q3: null };
    for (const fp of ["Q1", "Q2", "Q3"]) {
      const key = `${fy}::${fp}`;
      const directRow = direct.get(key);
      const ytdRow = ytd.get(key);
      let value = directRow?.value ?? null;
      let source = directRow || ytdRow || null;
      if (value == null && ytdRow) {
        if (fp === "Q1") value = ytdRow.value;
        if (fp === "Q2" && previousYtd.Q1) value = ytdRow.value - previousYtd.Q1.value;
        if (fp === "Q3" && previousYtd.Q2) value = ytdRow.value - previousYtd.Q2.value;
      }
      if (ytdRow) previousYtd[fp] = ytdRow;
      if (value != null && source) {
        quarters.set(key, {
          value,
          filed: source.filed,
          end: source.end,
          tag: source.tag,
          form: source.form,
          derived: !directRow && Boolean(ytdRow)
        });
      }
    }

    const annual = ytd.get(`${fy}::FY`);
    const q1 = quarters.get(`${fy}::Q1`);
    const q2 = quarters.get(`${fy}::Q2`);
    const q3 = quarters.get(`${fy}::Q3`);
    if (options.deriveAnnualQ4 !== false && annual && q1 && q2 && q3) {
      quarters.set(`${fy}::Q4`, {
        value: annual.value - q1.value - q2.value - q3.value,
        filed: annual.filed,
        end: annual.end,
        tag: annual.tag,
        form: annual.form,
        derived: true
      });
    } else if ((options.deriveAnnualQ4 !== false || options.annualOnlyAsQ4) && annual && !q1 && !q2 && !q3) {
      quarters.set(`${fy}::Q4`, {
        value: annual.value,
        filed: annual.filed,
        end: annual.end,
        tag: annual.tag,
        form: annual.form,
        derived: false,
        annualOnly: true
      });
    }
  }
  return quarters;
}

function choosePointRow(rows) {
  return [...rows].sort((left, right) =>
    (left.priority || 0) - (right.priority || 0) ||
    String(left.filed).localeCompare(String(right.filed)) ||
    String(left.tag).localeCompare(String(right.tag))
  )[0] || null;
}

function buildPointMetricMap(facts, metric, fiscalYearEnd, options = {}) {
  const tags = options.tags || POINT_TAGS[metric] || [];
  const unit = options.unit || "USD";
  const scale = options.scale || 1_000_000;
  const rows = [];
  for (const tag of tags) {
    for (const row of unitsFor(facts, tag, unit)) {
      const rawValue = finiteNumber(row?.val);
      const value = options.valueTransform ? options.valueTransform(row) : rawValue;
      if (value == null || !row?.filed || !row?.end || !row?.form) continue;
      const derived = fiscalPeriodFromEnd(row.end, fiscalYearEnd);
      const period = reportedFiscalPeriod(row, derived, fiscalYearEnd);
      if (!period || period.fiscalQuarter === "FY") continue;
      if (period.source === "comparative-derived") continue;
      if (period.source === "derived" && !matchesReportedFiscalYear(row, derived)) continue;
      rows.push({
        ...row,
        metric,
        tag,
        priority: tags.indexOf(tag),
        fy: period.fiscalYear,
        fp: period.fiscalQuarter,
        originalFy: row.fy,
        originalFp: row.fp,
        fiscalPeriodSource: period.source,
        filed: row.filed,
        end: row.end,
        value: options.valueTransform ? value : value / scale
      });
    }
  }

  const points = new Map();
  for (const row of rows) {
    const key = `${row.fy}::${row.fp}`;
    const existing = points.get(key);
    points.set(key, choosePointRow(existing ? [existing, row] : [row]));
  }
  return points;
}

function sumPointMaps(maps, key) {
  const rows = maps.map((map) => map.get(key)).filter(Boolean);
  if (!rows.length) return null;
  return {
    value: rows.reduce((sum, row) => sum + (finiteNumber(row.value) || 0), 0),
    filed: rows.map((row) => row.filed).filter(Boolean).sort().at(-1),
    end: rows.map((row) => row.end).filter(Boolean).sort().at(-1),
    tag: rows.map((row) => row.tag).join("+"),
    form: rows.map((row) => row.form).filter(Boolean).sort().at(-1),
    derived: false
  };
}

function buildDebtMetricMap(facts, fiscalYearEnd, options = {}) {
  const unit = options.unit || "USD";
  const totalMap = buildPointMetricMap(facts, "debt_m", fiscalYearEnd, { tags: DEBT_TOTAL_TAGS, unit });
  const componentMaps = DEBT_COMPONENT_TAGS.map((tag) => buildPointMetricMap(facts, "debt_m", fiscalYearEnd, { tags: [tag], unit }));
  const keys = new Set([
    ...totalMap.keys(),
    ...componentMaps.flatMap((map) => [...map.keys()])
  ]);
  const debt = new Map();
  for (const key of keys) {
    const componentRow = sumPointMaps(componentMaps, key);
    const totalRow = totalMap.get(key);
    const row = componentRow || totalRow;
    if (row) debt.set(key, row);
  }
  return debt;
}

function buildQuarterlyFinancials(facts, ticker = "") {
  const financialStatementCurrency = secFactUnitForTicker(ticker);
  const fiscalYearEnd = inferFiscalYearEnd(facts, financialStatementCurrency);
  const metricMaps = Object.fromEntries(Object.keys(TAGS).map((metric) => [
    metric,
    buildMetricQuarterMap(facts, metric, fiscalYearEnd, { unit: financialStatementCurrency })
  ]));
  const pointMaps = Object.fromEntries(Object.keys(POINT_TAGS).map((metric) => [
    metric,
    buildPointMetricMap(facts, metric, fiscalYearEnd, { unit: financialStatementCurrency })
  ]));
  const debtMap = buildDebtMetricMap(facts, fiscalYearEnd, { unit: financialStatementCurrency });
  const sharesFlowMap = buildMetricQuarterMap(facts, "shares_m", fiscalYearEnd, {
    tags: SHARE_TAGS,
    unit: "shares",
    deriveAnnualQ4: false,
    annualOnlyAsQ4: true,
    valueTransform: shareValueM
  });
  const sharesPointMap = buildPointMetricMap(facts, "shares_m", fiscalYearEnd, {
    tags: SHARE_POINT_TAGS,
    unit: "shares",
    scale: 1_000_000,
    valueTransform: shareValueM
  });
  const keys = new Set([
    ...Object.values(metricMaps).flatMap((map) => [...map.keys()]),
    ...Object.values(pointMaps).flatMap((map) => [...map.keys()]),
    ...debtMap.keys(),
    ...sharesFlowMap.keys(),
    ...sharesPointMap.keys()
  ]);
  const rows = [...keys].map((key) => {
    const [fyText, fp] = key.split("::");
    const fy = Number(fyText);
    const metricData = {};
    const sources = {};
    for (const [metric, map] of Object.entries(metricMaps)) {
      const row = map.get(key);
      if (!row) continue;
      metricData[metric] = row.value;
      sources[metric] = {
        tag: row.tag,
        filed: row.filed,
        form: row.form,
        end: row.end,
        derived: row.derived,
        annualOnly: Boolean(row.annualOnly)
      };
    }
    const debtRow = debtMap.get(key);
    if (debtRow) {
      metricData.debt_m = debtRow.value;
      sources.debt_m = {
        tag: debtRow.tag,
        filed: debtRow.filed,
        form: debtRow.form,
        end: debtRow.end,
        derived: debtRow.derived
      };
    }
    for (const [metric, map] of Object.entries(pointMaps)) {
      if (metric === "debt_m") continue;
      const row = map.get(key);
      if (!row) continue;
      metricData[metric] = row.value;
      sources[metric] = {
        tag: row.tag,
        filed: row.filed,
        form: row.form,
        end: row.end,
        derived: false
      };
    }
    const shareRow = sharesFlowMap.get(key) || sharesPointMap.get(key);
    if (shareRow) {
      metricData.shares_m = shareRow.value;
      sources.shares_m = {
        tag: shareRow.tag,
        filed: shareRow.filed,
        form: shareRow.form,
        end: shareRow.end,
        derived: shareRow.derived,
        annualOnly: Boolean(shareRow.annualOnly)
      };
    }
    const filedDates = Object.values(sources).map((source) => source.filed).filter(Boolean).sort();
    const coreFiledDates = CORE_DISCLOSURE_METRICS
      .map((metric) => sources[metric]?.filed)
      .filter(Boolean)
      .sort();
    const endDates = Object.values(sources).map((source) => source.end).filter(Boolean).sort();
    return {
      key,
      fiscalYear: fy,
      fiscalQuarter: fp,
      label: `FY${fy} ${fp}`,
      asOfDate: coreFiledDates.at(-1) || filedDates.at(-1) || null,
      periodEndDate: endDates.at(-1) || null,
      financialStatementCurrency,
      ...metricData,
      sources
    };
  });

  rows.sort((left, right) =>
    left.fiscalYear - right.fiscalYear ||
    Number(left.fiscalQuarter.replace("Q", "")) - Number(right.fiscalQuarter.replace("Q", ""))
  );

  const byPeriod = new Map(rows.map((row) => [`${row.fiscalYear}::${row.fiscalQuarter}`, row]));
  for (const row of rows) {
    const prior = byPeriod.get(`${row.fiscalYear - 1}::${row.fiscalQuarter}`);
    row.revenue_growth_pct = pct(row.revenue_m, prior?.revenue_m);
    row.gross_margin_pct = margin(row.gross_profit_m, row.revenue_m);
    row.operating_margin_pct = margin(row.operating_income_m, row.revenue_m);
    row.fcf_after_capex_m = row.cfo_m != null && row.capex_m != null ? row.cfo_m - row.capex_m : null;
  }

  return rows
    .filter((row) => row.asOfDate && row.net_income_m != null && (row.revenue_m != null || row.equity_m != null))
    .map((row) => ({
      ...row,
      fiscalYearEnd
    }));
}

export function attachMstrCryptoMetrics(facts, rows, { pointInTime = false } = {}) {
  const fiscalYearEnd = inferFiscalYearEnd(facts);
  const cryptoMetricMap = ({ tag, unit, scale }) => {
    const points = new Map();
    for (const row of unitsFor(facts, tag, unit)) {
      const rawValue = finiteNumber(row?.val);
      const period = fiscalPeriodFromEnd(row?.end, fiscalYearEnd);
      if (rawValue == null || !period || period.fiscalQuarter === "FY" || !row?.filed || !row?.form) continue;
      const key = `${period.fiscalYear}::${period.fiscalQuarter}`;
      const value = rawValue / scale;
      const candidate = {
        value,
        filed: row.filed,
        form: row.form,
        end: row.end,
        tag,
        derived: false
      };
      const existing = points.get(key);
      const isPreferred = pointInTime
        ? String(candidate.filed).localeCompare(String(existing?.filed || "9999-12-31")) < 0
        : String(candidate.filed).localeCompare(String(existing?.filed || "")) > 0;
      if (!existing || isPreferred) {
        points.set(key, candidate);
      }
    }
    return points;
  };
  const fairValueMap = cryptoMetricMap({ tag: "CryptoAssetFairValue", unit: "USD", scale: 1_000_000 });
  const costMap = cryptoMetricMap({ tag: "CryptoAssetCost", unit: "USD", scale: 1_000_000 });
  const unitMap = cryptoMetricMap({ tag: "CryptoAssetNumberOfUnits", unit: "Bitcoin", scale: 1 });

  return rows.map((row) => {
    const key = `${row.fiscalYear}::${row.fiscalQuarter}`;
    const visibleAtRow = (metric) => metric && (!pointInTime || String(metric.filed) <= String(row.asOfDate));
    const fairValue = visibleAtRow(fairValueMap.get(key)) ? fairValueMap.get(key) : null;
    const cost = visibleAtRow(costMap.get(key)) ? costMap.get(key) : null;
    const units = visibleAtRow(unitMap.get(key)) ? unitMap.get(key) : null;
    if (!fairValue && !cost && !units) return row;
    return {
      ...row,
      crypto_asset_fair_value_m: fairValue?.value ?? row.crypto_asset_fair_value_m,
      crypto_asset_cost_m: cost?.value ?? row.crypto_asset_cost_m,
      crypto_asset_units: units?.value ?? row.crypto_asset_units,
      sources: {
        ...(row.sources || {}),
        ...(fairValue ? {
          crypto_asset_fair_value_m: {
            tag: fairValue.tag,
            filed: fairValue.filed,
            form: fairValue.form,
            end: fairValue.end,
            derived: false
          }
        } : {}),
        ...(cost ? {
          crypto_asset_cost_m: {
            tag: cost.tag,
            filed: cost.filed,
            form: cost.form,
            end: cost.end,
            derived: false
          }
        } : {}),
        ...(units ? {
          crypto_asset_units: {
            tag: units.tag,
            filed: units.filed,
            form: units.form,
            end: units.end,
            derived: false,
            unit: "Bitcoin"
          }
        } : {})
      }
    };
  });
}

function pricePointAtOrBefore(points = [], date) {
  const target = Date.parse(date);
  if (!Number.isFinite(target)) return null;
  return [...points]
    .filter((point) => point.date && finiteNumber(point.close) > 0 && Date.parse(point.date) <= target)
    .sort((left, right) => String(left.date).localeCompare(String(right.date)))
    .at(-1) || null;
}

function latestPricePoint(points = []) {
  return [...points]
    .filter((point) => point.date && finiteNumber(point.close) > 0)
    .sort((left, right) => String(left.date).localeCompare(String(right.date)))
    .at(-1) || null;
}

export function readPriceHistoryFromDb(db, ticker, limit = 1800) {
  try {
    const rows = db.prepare(`
      SELECT date, open, high, low, close, volume, source
      FROM price_points
      WHERE symbol = ? AND close > 0
      ORDER BY date DESC
      LIMIT ?
    `).all(ticker, limit);
    return rows
      .reverse()
      .map((row) => ({
        date: row.date,
        open: finiteNumber(row.open),
        high: finiteNumber(row.high),
        low: finiteNumber(row.low),
        close: finiteNumber(row.close),
        volume: finiteNumber(row.volume),
        source: row.source || "local price_points"
      }))
      .filter((row) => row.date && row.close > 0);
  } catch {
    return [];
  }
}

export function baseValuationSnapshot({ ticker, companyModel, secInfo, priceHistory }) {
  const latestPrice = latestPricePoint(priceHistory);
  const generatedAt = new Date().toISOString();
  const name = companyModel?.company || secInfo?.title || ticker;
  return {
    generatedAt,
    ticker,
    key: ticker.toLowerCase(),
    name,
    sector: companyModel?.sector || profileSettings(ticker).label || "Public equity",
    currency: "USD",
    description: `${name} valuation snapshot generated from SEC CompanyFacts and local price history.`,
    modelType: "SEC quarterly Fundamental Analysis model",
    latest: {
      latestPrice: finiteNumber(latestPrice?.close),
      latestPriceDate: latestPrice?.date || null,
      latestPriceSource: latestPrice?.source || null,
      valuationAnchorPrice: null,
      valuationAnchorDate: null,
      baseFairValue: null,
      upsideToBase: null,
      targetPrice3Y: null,
      expectedReturn3Y: null,
      fairValueSource: "SEC CompanyFacts financials + transcript guidance model",
      fairValueInputPolicy: "reported financials / guidance only; price excluded"
    },
    scenarios: [],
    history: [],
    methodCards: [],
    assumptions: [],
    warnings: ["Initialized valuation snapshot from local price history so SEC import can add the ticker."],
    priceHistory,
    priceSource: latestPrice?.source || "local price_points",
    dataQuality: {
      pricePoints: priceHistory.length,
      hasLivePriceSeries: priceHistory.length >= 120,
      priceDisplayMode: priceHistory.length >= 120 ? "daily-price-line" : "as-of-price-anchors",
      valuationCoverageKind: "unsupported",
      hasQuarterlyValuationRuns: false,
      sourceNote: "Initialized from local price_points; fair values are added by the SEC quarterly importer.",
      fairValueSource: "pending SEC CompanyFacts import",
      secCompanyFacts: {
        cik: secInfo?.cik_str || companyModel?.cik || null,
        company: name,
        pendingImport: true
      }
    }
  };
}

function fiscalQuarterOrdinal(row) {
  const year = finiteNumber(row?.fiscalYear);
  const quarter = Number(String(row?.fiscalQuarter || "").replace("Q", ""));
  return Number.isInteger(year) && quarter >= 1 && quarter <= 4
    ? year * 4 + quarter - 1
    : null;
}

function isReportedQuarterFlow(row, key) {
  return row?.sourceDimension !== "ART" &&
    row?.sourceRecord?.metricsAreTrailingTwelveMonths !== true &&
    !row?.sources?.[key]?.annualOnly &&
    finiteNumber(row?.[key]) != null;
}

function trailingSum(rows, index, key) {
  const window = rows.slice(Math.max(0, index - 3), index + 1);
  if (window.length < 4 || window.some((row) => !isReportedQuarterFlow(row, key))) return null;
  const ordinals = window.map(fiscalQuarterOrdinal);
  if (ordinals.some((ordinal) => ordinal == null) || ordinals.some((ordinal, position) =>
    position > 0 && ordinal !== ordinals[position - 1] + 1
  )) return null;
  return window.reduce((sum, row) => sum + Number(row[key]), 0);
}

function isAnnualOnlyFinancialRow(row) {
  return Boolean(row?.sourceRecord?.metricsAreTrailingTwelveMonths) ||
    (row?.fiscalQuarter === "Q4" && CORE_DISCLOSURE_METRICS.some((metric) =>
      Boolean(row?.sources?.[metric]?.annualOnly)
    ));
}

function isSecCompanyFactsModelSource(sourceType) {
  return String(sourceType || "").startsWith("sec_companyfacts_");
}

function isPitFinancialModelSource(sourceType) {
  const value = String(sourceType || "");
  return value.startsWith("jansen_pit_") || value.startsWith("official_issuer_pit_");
}

function isVerifiedFinancialModelSource(sourceType) {
  return isSecCompanyFactsModelSource(sourceType) || isPitFinancialModelSource(sourceType);
}

function latestProviderTrailingValue(rows, index, key) {
  for (let sampleIndex = index; sampleIndex >= 0; sampleIndex -= 1) {
    const value = finiteNumber(rows[sampleIndex]?.pitTrailingTwelveMonths?.[key]);
    if (value != null) {
      return {
        value,
        source: sampleIndex === index ? "current_reported_ttm" : "prior_reported_ttm",
        sourceIndex: sampleIndex
      };
    }
  }
  return null;
}

export function resolveTrailingFinancialValue(rows, index, key, annualizationFactor) {
  const row = rows[index];
  const providerTrailing = latestProviderTrailingValue(rows, index, key);
  if (providerTrailing?.source === "current_reported_ttm") return providerTrailing;
  if (isAnnualOnlyFinancialRow(row)) {
    const value = finiteNumber(row?.[key]);
    return value == null ? null : { value, source: "current_reported_annual", sourceIndex: index };
  }
  const ttmValue = trailingSum(rows, index, key);
  if (ttmValue != null) return { value: ttmValue, source: "four_consecutive_quarters", sourceIndex: index };
  if (providerTrailing) return providerTrailing;
  const currentValue = finiteNumber(row?.[key]);
  if (currentValue == null || row?.requiresReportedTrailingBasis) return null;
  return {
    value: currentValue * annualizationFactor,
    source: "single_period_annualized",
    sourceIndex: index
  };
}

function trailingOrAnnualValue(rows, index, key, annualizationFactor) {
  return resolveTrailingFinancialValue(rows, index, key, annualizationFactor)?.value ?? null;
}

function latestKnownValue(rows, index, key) {
  for (let i = index; i >= 0; i -= 1) {
    const value = finiteNumber(rows[i]?.[key]);
    if (value != null) return value;
  }
  return null;
}

function latestKnownValueWithin(rows, index, key, maxRows) {
  const floor = Math.max(0, index - maxRows);
  for (let i = index; i >= floor; i -= 1) {
    const value = finiteNumber(rows[i]?.[key]);
    if (value != null) return value;
  }
  return null;
}

function annualizationFactorForRow(row) {
  return row?.fiscalQuarter === "Q4" && ["10-K", "20-F", "40-F"].includes(row?.sources?.revenue_m?.form)
    ? 1
    : 4;
}

function weightedWinsorizedMean(entries, halfLife = 8) {
  if (!entries.length) return null;
  const ordered = entries.map((entry) => entry.value).sort((left, right) => left - right);
  const quantile = (fraction) => ordered[Math.min(
    ordered.length - 1,
    Math.floor((ordered.length - 1) * fraction)
  )];
  const floor = quantile(0.1);
  const ceiling = quantile(0.9);
  let weightedTotal = 0;
  let totalWeight = 0;
  for (const entry of entries) {
    const weight = 0.5 ** (entry.age / halfLife);
    weightedTotal += clamp(entry.value, floor, ceiling) * weight;
    totalWeight += weight;
  }
  return totalWeight > 0 ? weightedTotal / totalWeight : null;
}

function trailingResolutionSourceKey(resolution) {
  if (!resolution) return "missing";
  if (["current_reported_ttm", "prior_reported_ttm"].includes(resolution.source)) {
    return `reported_ttm:${resolution.sourceIndex}`;
  }
  return `${resolution.source}:${resolution.sourceIndex}`;
}

function combinedTrailingSourceKey(...resolutions) {
  return resolutions.map(trailingResolutionSourceKey).join("|");
}

function cycleEpsStatsForRows(rows, index, windowSize = 32) {
  const start = Math.max(0, index - Math.max(1, windowSize) + 1);
  const entriesBySource = new Map();
  for (let sampleIndex = start; sampleIndex <= index; sampleIndex += 1) {
    const factor = annualizationFactorForRow(rows[sampleIndex]);
    const netIncomeResolution = resolveTrailingFinancialValue(
      rows,
      sampleIndex,
      "net_income_m",
      factor
    );
    const netIncome = netIncomeResolution?.value ?? null;
    const shares = latestKnownValueWithin(rows, sampleIndex, "shares_m", 8);
    const eps = netIncome != null && shares > 0 ? netIncome / shares : null;
    if (eps > 0 && eps <= 10_000) {
      entriesBySource.set(trailingResolutionSourceKey(netIncomeResolution), {
        value: eps,
        age: index - sampleIndex
      });
    }
  }
  const entries = [...entriesBySource.values()];
  const sparseValue = entries.length >= 2 ? weightedWinsorizedMean(entries) : null;
  return {
    value: entries.length >= 4 ? weightedWinsorizedMean(entries) : null,
    sparseValue,
    positiveSampleCount: entries.length
  };
}

export function cycleContextForRows(rows, index, windowSize = 8) {
  const start = Math.max(0, index - Math.max(1, windowSize) + 1);
  const samples = [];
  const revenueSources = new Set();
  const positiveFcfSources = new Set();
  for (let sampleIndex = start; sampleIndex <= index; sampleIndex += 1) {
    const factor = annualizationFactorForRow(rows[sampleIndex]);
    const revenueResolution = resolveTrailingFinancialValue(rows, sampleIndex, "revenue_m", factor);
    const operatingIncomeResolution = resolveTrailingFinancialValue(rows, sampleIndex, "operating_income_m", factor);
    const netIncomeResolution = resolveTrailingFinancialValue(rows, sampleIndex, "net_income_m", factor);
    const cfoResolution = resolveTrailingFinancialValue(rows, sampleIndex, "cfo_m", factor);
    const capexResolution = resolveTrailingFinancialValue(rows, sampleIndex, "capex_m", factor);
    const directFcfResolution = resolveTrailingFinancialValue(rows, sampleIndex, "fcf_after_capex_m", factor);
    const revenue = revenueResolution?.value ?? null;
    const operatingIncome = operatingIncomeResolution?.value ?? null;
    const netIncome = netIncomeResolution?.value ?? null;
    const cfo = cfoResolution?.value ?? null;
    const capex = capexResolution?.value ?? null;
    const directFcf = directFcfResolution?.value ?? null;
    const fcf = directFcf ?? (cfo != null && capex != null ? cfo - capex : null);
    const fcfSourceKey = directFcfResolution
      ? `direct:${trailingResolutionSourceKey(directFcfResolution)}`
      : `derived:${combinedTrailingSourceKey(cfoResolution, capexResolution)}`;
    const equity = latestKnownValue(rows, sampleIndex, "equity_m");
    const shares = latestKnownValueWithin(rows, sampleIndex, "shares_m", 8);
    if (!(revenue > 0)) continue;
    revenueSources.add(trailingResolutionSourceKey(revenueResolution));
    if (fcf > 0) positiveFcfSources.add(fcfSourceKey);
    const operatingMarginPct = margin(operatingIncome, revenue);
    const netMarginPct = margin(netIncome, revenue);
    samples.push({
      operatingMarginPct,
      netMarginPct,
      cfoMarginPct: margin(cfo, revenue),
      fcfMarginPct: margin(fcf, revenue),
      roePct: netIncome != null && equity > 0 ? netIncome / equity * 100 : null,
      eps: netIncome != null && shares > 0 ? netIncome / shares : null,
      belowOperatingBurdenPct: operatingMarginPct > 0 && netMarginPct > 0 && operatingMarginPct >= netMarginPct
        ? operatingMarginPct - netMarginPct
        : null,
      sourceKeys: {
        operatingMarginPct: combinedTrailingSourceKey(revenueResolution, operatingIncomeResolution),
        netMarginPct: combinedTrailingSourceKey(revenueResolution, netIncomeResolution),
        cfoMarginPct: combinedTrailingSourceKey(revenueResolution, cfoResolution),
        fcfMarginPct: `${trailingResolutionSourceKey(revenueResolution)}|${fcfSourceKey}`,
        roePct: `${trailingResolutionSourceKey(netIncomeResolution)}|equity:${sampleIndex}`,
        belowOperatingBurdenPct: combinedTrailingSourceKey(
          revenueResolution,
          operatingIncomeResolution,
          netIncomeResolution
        )
      }
    });
  }
  const metricMedian = (key, min, max) => {
    const uniqueValues = new Map();
    for (const sample of samples) {
      const value = finiteNumber(sample[key]);
      if (value == null || value < min || value > max) continue;
      uniqueValues.set(sample.sourceKeys[key], value);
    }
    return median([...uniqueValues.values()]);
  };
  const cycleEps = cycleEpsStatsForRows(rows, index, Math.max(32, windowSize));
  return {
    sampleCount: revenueSources.size,
    operatingMarginPct: metricMedian("operatingMarginPct", -100, 100),
    netMarginPct: metricMedian("netMarginPct", -100, 100),
    cfoMarginPct: metricMedian("cfoMarginPct", -100, 150),
    fcfMarginPct: metricMedian("fcfMarginPct", -100, 100),
    roePct: metricMedian("roePct", -100, 150),
    eps: cycleEps.value,
    sparseEps: cycleEps.sparseValue,
    positiveEpsSampleCount: cycleEps.positiveSampleCount,
    positiveFcfSampleCount: positiveFcfSources.size,
    belowOperatingBurdenPct: metricMedian("belowOperatingBurdenPct", 0, 25)
  };
}

function valuationMultiples(row, ttm) {
  const growth = finiteNumber(row.revenue_growth_pct) ?? 8;
  const opMargin = finiteNumber(ttm.operating_margin_pct ?? row.operating_margin_pct) ?? 25;
  const fcfMargin = finiteNumber(ttm.fcf_margin_pct) ?? 18;
  const capexIntensity = finiteNumber(ttm.capex_intensity_pct) ?? 8;
  const pe = clamp(20 + growth * 0.34 + (opMargin - 30) * 0.3 + fcfMargin * 0.08 - capexIntensity * 0.08, 18, 36);
  const fcfYield = clamp(0.048 - growth * 0.00035 - (opMargin - 30) * 0.00025 - Math.max(0, fcfMargin - 20) * 0.0001 + capexIntensity * 0.0003, 0.028, 0.06);
  const longRunGrowth = clamp(0.045 + Math.max(-5, Math.min(25, growth)) / 100 * 0.28 + Math.max(-10, Math.min(20, opMargin - 25)) / 100 * 0.08, 0.035, 0.13);
  return { pe, fcfYield, longRunGrowth };
}

const PROFILE_SETTINGS = {
  mega_cap_platform: {
    label: "Mega-cap platform",
    method: "TTM earnings power + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [20, 36],
    peBase: 24,
    fcfYieldRange: [0.032, 0.055],
    fcfYieldBase: 0.042,
    targetMargin: 0.29,
    fcfWeight: 0.42
  },
  ads_ai_platform: {
    label: "Search / ads AI platform",
    method: "Owner earnings + normalized platform EPS",
    normalizedGrowthWindow: 8,
    peRange: [22, 38],
    peBase: 25,
    fcfYieldRange: [0.032, 0.055],
    fcfYieldBase: 0.041,
    targetMargin: 0.31,
    fcfWeight: 0.26,
    maintenanceCapexIntensityPct: 0.14
  },
  platform_reinvestment: {
    label: "Platform reinvestment",
    method: "Normalized earnings power + FCFE DCF",
    peRange: [20, 38],
    peBase: 25,
    fcfYieldRange: [0.035, 0.06],
    fcfYieldBase: 0.046,
    targetMargin: 0.16,
    fcfWeight: 0.36
  },
  platform_marketplace_reinvestment: {
    label: "Platform reinvestment",
    method: "Marketplace EV/sales + normalized earnings + FCFE DCF",
    allowLossMakingStage: true,
    normalizedGrowthWindow: 4,
    normalizedGrowthCapPct: 65,
    forwardRevenueYears: 0,
    peRange: [20, 44],
    peBase: 25,
    peGrowthCoefficient: 0.26,
    peMarginCoefficient: 0.18,
    fcfYieldRange: [0.032, 0.075],
    fcfYieldBase: 0.052,
    fcfYieldGrowthCoefficient: 0.00025,
    fcfYieldMarginCoefficient: 0.00018,
    evSalesRange: [1.2, 8.0],
    evSalesBase: 2.5,
    evSalesGrowthCoefficient: 0.07,
    evSalesGrossMarginCoefficient: 0.035,
    evSalesFcfMarginCoefficient: 0.035,
    targetMargin: 0.14,
    marginActualWeight: 0.55,
    salesWeight: 0.48,
    earningsWeight: 0.30,
    fcfWeight: 0.22,
    defaultGrossMarginPct: 42
  },
  subscription_streaming_platform: {
    label: "Subscription streaming platform",
    method: "Paid-membership media platform EV/sales + normalized earnings + FCFE DCF",
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.45,
    normalizedGrowthWindow: 8,
    normalizedGrowthCapPct: 40,
    peRange: [24, 48],
    peBase: 31,
    peGrowthCoefficient: 0.24,
    peMarginCoefficient: 0.18,
    fcfYieldRange: [0.026, 0.058],
    fcfYieldBase: 0.038,
    fcfYieldGrowthCoefficient: 0.00022,
    fcfYieldMarginCoefficient: 0.00016,
    evSalesRange: [4.0, 13.0],
    evSalesBase: 6.2,
    evSalesGrowthCoefficient: 0.11,
    evSalesGrossMarginCoefficient: 0.04,
    evSalesFcfMarginCoefficient: 0.035,
    targetMargin: 0.28,
    marginActualWeight: 0.52,
    fcfWeight: 0.34,
    salesWeight: 0.34,
    earningsWeight: 0.32,
    defaultGrossMarginPct: 43,
    maintenanceCapexIntensityPct: 0.05
  },
  payments_network: {
    label: "Payments network",
    method: "High-ROIC EPS + FCFE DCF",
    peRange: [24, 40],
    peBase: 29,
    fcfYieldRange: [0.028, 0.046],
    fcfYieldBase: 0.035,
    targetMargin: 0.52,
    fcfWeight: 0.45
  },
  payments_processor: {
    label: "Payment processor",
    method: "Through-cycle payment processor EPS; customer funds excluded",
    normalizedGrowthWindow: 8,
    peRange: [12, 28],
    peBase: 17,
    peGrowthCoefficient: 0.16,
    peMarginCoefficient: 0,
    earningsActualWeight: 0.62
  },
  card_network_lender: {
    label: "Closed-loop card network / lender",
    method: "Premium ROE-implied P/B + EPS power",
    costOfEquity: 0.105,
    terminalGrowth: 0.035,
    pbRange: [2.0, 6.5],
    peRange: [12, 22],
    peBase: 15.5,
    bookWeight: 0.35,
    epsWeight: 0.65
  },
  software_growth: {
    label: "Enterprise software growth",
    method: "Rule-of-40 EV/sales + FCFE DCF + normalized earnings",
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.55,
    peRange: [28, 56],
    peBase: 34,
    fcfYieldRange: [0.026, 0.052],
    fcfYieldBase: 0.035,
    evSalesRange: [6.0, 28.0],
    evSalesBase: 10.0,
    evSalesGrowthCoefficient: 0.16,
    evSalesGrossMarginCoefficient: 0.06,
    evSalesFcfMarginCoefficient: 0.05,
    targetMargin: 0.28,
    fcfWeight: 0.32,
    salesWeight: 0.43,
    earningsWeight: 0.25,
    defaultGrossMarginPct: 76
  },
  hypergrowth_ai_software: {
    label: "Hypergrowth AI software",
    method: "Forward Rule-of-X EV/sales + FCFE DCF + normalized earnings",
    allowLossMakingStage: true,
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.75,
    forwardGrowthCapPct: 75,
    forwardScaleCap: 2.1,
    normalizedGrowthCapPct: 75,
    guidanceRevenueMaxScale: 2.2,
    guidanceOperatingMarginHaircut: 0.86,
    peRange: [32, 72],
    peBase: 42,
    peGrowthCoefficient: 0.34,
    peMarginCoefficient: 0.22,
    fcfYieldRange: [0.025, 0.05],
    fcfYieldBase: 0.034,
    fcfYieldGrowthCoefficient: 0.0003,
    fcfYieldMarginCoefficient: 0.00022,
    evSalesRange: [12.0, 40.0],
    evSalesBase: 20.0,
    evSalesGrowthCoefficient: 0.24,
    evSalesGrossMarginCoefficient: 0.09,
    evSalesFcfMarginCoefficient: 0.08,
    targetMargin: 0.42,
    fcfWeight: 0.25,
    salesWeight: 0.45,
    earningsWeight: 0.30,
    defaultGrossMarginPct: 80,
    bullCaseOptionalityMultiplier: 1.15
  },
  semiconductor_growth: {
    label: "AI semiconductor growth",
    method: "AI semiconductor EV/sales + FCFE DCF + cycle-adjusted EPS",
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.6,
    peRange: [22, 52],
    peBase: 30,
    fcfYieldRange: [0.026, 0.06],
    fcfYieldBase: 0.04,
    evSalesRange: [5.5, 24.0],
    evSalesBase: 8.5,
    evSalesGrowthCoefficient: 0.16,
    targetMargin: 0.34,
    fcfWeight: 0.32,
    salesWeight: 0.36,
    earningsWeight: 0.32,
    defaultGrossMarginPct: 52,
    cycleHaircut: 0.96
  },
  semiconductor_cyclical: {
    label: "Cyclical semiconductor",
    method: "AI-cycle normalized earnings power",
    forwardRevenueYears: 0.5,
    forwardFcfScaleCap: 1.35,
    peRange: [12, 32],
    peBase: 18,
    fcfYieldRange: [0.038, 0.085],
    fcfYieldBase: 0.058,
    targetMargin: 0.18,
    fcfWeight: 0.25,
    cycleHaircut: 0.95
  },
  semiconductor_storage_cycle: {
    label: "Storage semiconductor cycle",
    method: "NAND/storage cycle EV/sales + normalized earnings path",
    allowLossMakingStage: true,
    forwardRevenueYears: 0.75,
    forwardFcfScaleCap: 1.35,
    forwardScaleCap: 1.6,
    normalizedGrowthWindow: 6,
    normalizedGrowthCapPct: 85,
    peRange: [12, 30],
    peBase: 17,
    peGrowthCoefficient: 0.18,
    peMarginCoefficient: 0.11,
    fcfYieldRange: [0.04, 0.095],
    fcfYieldBase: 0.062,
    fcfYieldGrowthCoefficient: 0.0002,
    fcfYieldMarginCoefficient: 0.00012,
    evSalesRange: [1.0, 8.0],
    evSalesBase: 2.2,
    evSalesGrowthCoefficient: 0.08,
    evSalesGrossMarginCoefficient: 0.028,
    evSalesFcfMarginCoefficient: 0.02,
    targetMargin: 0.2,
    marginActualWeight: 0.42,
    fcfWeight: 0.16,
    salesWeight: 0.58,
    earningsWeight: 0.26,
    defaultGrossMarginPct: 38,
    cycleHaircut: 0.9
  },
  semiconductor_value: {
    label: "Semiconductor value",
    method: "Normalized EPS + FCFE DCF",
    peRange: [12, 24],
    peBase: 16,
    fcfYieldRange: [0.045, 0.075],
    fcfYieldBase: 0.058,
    targetMargin: 0.25,
    fcfWeight: 0.38,
    normalizeFcfAcrossCycle: true,
    cycleNormalizationWindow: 16,
    fcfActualWeight: 0.65
  },
  semiconductor_foundry: {
    label: "Advanced foundry",
    method: "Foundry earnings power + FCFE DCF",
    peRange: [18, 32],
    peBase: 23,
    fcfYieldRange: [0.035, 0.065],
    fcfYieldBase: 0.048,
    targetMargin: 0.42,
    fcfWeight: 0.32,
    cycleHaircut: 0.9
  },
  semiconductor_equipment: {
    label: "Semiconductor equipment",
    method: "Backlog-cycle normalized EPS + FCFE DCF",
    peRange: [18, 34],
    peBase: 24,
    fcfYieldRange: [0.035, 0.065],
    fcfYieldBase: 0.048,
    targetMargin: 0.3,
    fcfWeight: 0.34,
    cycleHaircut: 0.92
  },
  networking_hardware: {
    label: "AI networking hardware",
    method: "Normalized EPS + FCFE DCF",
    peRange: [20, 36],
    peBase: 25,
    fcfYieldRange: [0.035, 0.06],
    fcfYieldBase: 0.045,
    targetMargin: 0.32,
    fcfWeight: 0.36
  },
  optical_networking_turnaround: {
    label: "Optical networking turnaround",
    method: "AI optical networking EV/sales + normalized margin path",
    allowLossMakingStage: true,
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.25,
    forwardScaleCap: 1.75,
    normalizedGrowthWindow: 6,
    normalizedGrowthCapPct: 70,
    peRange: [18, 42],
    peBase: 24,
    peGrowthCoefficient: 0.24,
    peMarginCoefficient: 0.12,
    fcfYieldRange: [0.04, 0.095],
    fcfYieldBase: 0.064,
    fcfYieldGrowthCoefficient: 0.00022,
    fcfYieldMarginCoefficient: 0.00012,
    evSalesRange: [1.5, 12.0],
    evSalesBase: 3.6,
    evSalesGrowthCoefficient: 0.10,
    evSalesGrossMarginCoefficient: 0.035,
    evSalesFcfMarginCoefficient: 0.025,
    targetMargin: 0.16,
    marginActualWeight: 0.45,
    fcfWeight: 0.10,
    salesWeight: 0.64,
    earningsWeight: 0.26,
    minimumSalesEquityRetention: 0.2,
    defaultGrossMarginPct: 34,
    cycleHaircut: 0.92
  },
  bank: {
    label: "Large-cap bank",
    method: "ROE-implied P/B + EPS cross-check",
    costOfEquity: 0.105,
    terminalGrowth: 0.025,
    pbRange: [0.75, 2.25],
    peRange: [8, 14],
    peBase: 10.5
  },
  insurance: {
    label: "P&C insurance",
    method: "ROE-implied P/B + normalized EPS",
    costOfEquity: 0.095,
    terminalGrowth: 0.025,
    pbRange: [1.0, 2.8],
    peRange: [9, 16],
    peBase: 12
  },
  biopharma: {
    label: "Large-cap biopharma",
    method: "Pipeline-aware EPS + FCFE DCF",
    peRange: [10, 22],
    peBase: 14,
    fcfYieldRange: [0.05, 0.085],
    fcfYieldBase: 0.064,
    targetMargin: 0.27,
    fcfWeight: 0.4
  },
  biopharma_growth: {
    label: "Growth biopharma",
    method: "Growth-adjusted EPS power",
    peRange: [18, 34],
    peBase: 23,
    fcfYieldRange: [0.035, 0.065],
    fcfYieldBase: 0.048,
    targetMargin: 0.33,
    fcfWeight: 0.32,
    normalizeFcfAcrossCycle: true,
    cycleNormalizationWindow: 16,
    fcfActualWeight: 0.65
  },
  medtech_platform: {
    label: "Medtech platform",
    method: "Quality EPS + FCFE DCF",
    forwardRevenueYears: 1,
    normalizedGrowthWindow: 8,
    forwardFcfScaleCap: 1.4,
    peRange: [30, 62],
    peBase: 41,
    peGrowthCoefficient: 0.30,
    peMarginCoefficient: 0.18,
    fcfYieldRange: [0.022, 0.048],
    fcfYieldBase: 0.032,
    targetMargin: 0.34,
    marginActualWeight: 0.42,
    fcfWeight: 0.34
  },
  mature_medtech: {
    label: "Mature medical technology",
    method: "Normalized medical-device EPS + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [15, 30],
    peBase: 21,
    peGrowthCoefficient: 0.18,
    peMarginCoefficient: 0.1,
    fcfYieldRange: [0.04, 0.075],
    fcfYieldBase: 0.055,
    targetMargin: 0.18,
    marginActualWeight: 0.72,
    fcfWeight: 0.4,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.65
  },
  healthcare_distribution: {
    label: "Healthcare distribution",
    method: "Low-margin EPS + FCFE DCF",
    peRange: [10, 18],
    peBase: 13,
    fcfYieldRange: [0.055, 0.085],
    fcfYieldBase: 0.068,
    targetMargin: 0.025,
    fcfWeight: 0.45
  },
  managed_care: {
    label: "Managed care",
    method: "Through-cycle managed care EPS; policyholder cash excluded",
    normalizedGrowthWindow: 8,
    peRange: [12, 22],
    peBase: 16,
    peGrowthCoefficient: 0.1,
    peMarginCoefficient: 0,
    earningsActualWeight: 0.5
  },
  genetic_diagnostics_growth: {
    label: "Genetic diagnostics growth",
    method: "Diagnostics platform EV/sales + normalized margin earnings power",
    allowLossMakingStage: true,
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.35,
    forwardScaleCap: 1.85,
    normalizedGrowthWindow: 6,
    normalizedGrowthCapPct: 60,
    peRange: [22, 52],
    peBase: 30,
    peGrowthCoefficient: 0.28,
    peMarginCoefficient: 0.16,
    fcfYieldRange: [0.03, 0.075],
    fcfYieldBase: 0.048,
    fcfYieldGrowthCoefficient: 0.00024,
    fcfYieldMarginCoefficient: 0.00018,
    evSalesRange: [3.5, 18.0],
    evSalesBase: 6.5,
    evSalesGrowthCoefficient: 0.12,
    evSalesGrossMarginCoefficient: 0.05,
    evSalesFcfMarginCoefficient: 0.035,
    targetMargin: 0.24,
    marginActualWeight: 0.45,
    salesWeight: 0.55,
    earningsWeight: 0.30,
    fcfWeight: 0.15,
    defaultGrossMarginPct: 53,
    bullCaseOptionalityMultiplier: 1.04
  },
  defense_prime: {
    label: "Defense prime",
    method: "Backlog-quality EPS + FCFE DCF",
    peRange: [13, 22],
    peBase: 16,
    fcfYieldRange: [0.045, 0.075],
    fcfYieldBase: 0.058,
    targetMargin: 0.12,
    fcfWeight: 0.38,
    normalizeFcfAcrossCycle: true,
    cycleNormalizationWindow: 16,
    fcfActualWeight: 0.65
  },
  defense_growth: {
    label: "Defense growth",
    method: "Backlog proxy EV/sales + normalized margin earnings power",
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.35,
    peRange: [20, 42],
    peBase: 26,
    fcfYieldRange: [0.035, 0.07],
    fcfYieldBase: 0.05,
    evSalesRange: [3.0, 10.5],
    evSalesBase: 4.4,
    evSalesGrowthCoefficient: 0.08,
    targetMargin: 0.16,
    fcfWeight: 0.15,
    salesWeight: 0.55,
    earningsWeight: 0.30,
    defaultGrossMarginPct: 36
  },
  space_launch_growth: {
    label: "Space launch growth",
    method: "Launch cadence EV/sales + normalized margin earnings power",
    allowLossMakingStage: true,
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.25,
    forwardScaleCap: 1.8,
    normalizedGrowthWindow: 6,
    normalizedGrowthCapPct: 70,
    peRange: [22, 52],
    peBase: 30,
    peGrowthCoefficient: 0.28,
    peMarginCoefficient: 0.14,
    fcfYieldRange: [0.04, 0.09],
    fcfYieldBase: 0.06,
    evSalesRange: [2.5, 16.0],
    evSalesBase: 5.2,
    evSalesGrowthCoefficient: 0.12,
    evSalesGrossMarginCoefficient: 0.035,
    evSalesFcfMarginCoefficient: 0.025,
    targetMargin: 0.16,
    marginActualWeight: 0.45,
    fcfWeight: 0.10,
    salesWeight: 0.64,
    earningsWeight: 0.26,
    defaultGrossMarginPct: 32,
    cycleHaircut: 0.93
  },
  space_platform_ipo: {
    label: "Space platform IPO",
    method: "S-1/A revenue-stage SOTP proxy + post-IPO net cash bridge",
    allowLossMakingStage: true,
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.2,
    forwardScaleCap: 1.75,
    normalizedGrowthCapPct: 60,
    peRange: [28, 72],
    peBase: 38,
    peGrowthCoefficient: 0.34,
    peMarginCoefficient: 0.16,
    fcfYieldRange: [0.03, 0.08],
    fcfYieldBase: 0.052,
    evSalesRange: [8.0, 45.0],
    evSalesBase: 16.0,
    evSalesGrowthCoefficient: 0.18,
    evSalesGrossMarginCoefficient: 0.055,
    evSalesFcfMarginCoefficient: 0.025,
    targetMargin: 0.18,
    marginActualWeight: 0.35,
    fcfWeight: 0.08,
    salesWeight: 0.72,
    earningsWeight: 0.20,
    defaultGrossMarginPct: 50,
    bullCaseOptionalityMultiplier: 1.08
  },
  bitcoin_treasury_software: {
    label: "Bitcoin treasury / software",
    method: "BTC treasury NAV + software business value",
    allowLossMakingStage: true,
    treasuryHaircut: 0.98,
    softwareRevenueMultiple: 2.2,
    longRunGrowth: 0.08,
    peRange: [10, 26],
    peBase: 16,
    fcfYieldRange: [0.05, 0.11],
    fcfYieldBase: 0.075,
    targetMargin: 0.24,
    marginActualWeight: 0.35,
    fcfWeight: 0.20
  },
  energy_e_and_p: {
    label: "Natural gas E&P",
    method: "Cycle-normalized FCFE DCF",
    peRange: [7, 14],
    peBase: 9,
    fcfYieldRange: [0.075, 0.14],
    fcfYieldBase: 0.095,
    targetMargin: 0.2,
    fcfWeight: 0.55,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.5,
    cycleNormalizationWindow: 16,
    cycleHaircut: 0.78
  },
  power_utility: {
    label: "Power utility / generation",
    method: "Regulated/infrastructure EPS power",
    peRange: [14, 24],
    peBase: 17,
    fcfYieldRange: [0.055, 0.09],
    fcfYieldBase: 0.068,
    targetMargin: 0.18,
    marginActualWeight: 0.72,
    fcfWeight: 0.12,
    minimumStandaloneFcfEvidenceConfidence: 0.75,
    maintenanceCapexIntensityPct: 0.12,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.55,
    terminalGrowth: 0.022
  },
  quality_consumer: {
    label: "Quality consumer compounder",
    method: "Quality EPS + FCFE DCF",
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.25,
    peRange: [28, 52],
    peBase: 36,
    fcfYieldRange: [0.022, 0.044],
    fcfYieldBase: 0.031,
    targetMargin: 0.04,
    fcfWeight: 0.4
  },
  information_services: {
    label: "Information services",
    method: "Subscription data EPS + FCFE DCF",
    peRange: [18, 32],
    peBase: 23,
    fcfYieldRange: [0.038, 0.065],
    fcfYieldBase: 0.048,
    targetMargin: 0.26,
    fcfWeight: 0.44
  },
  media_telecom: {
    label: "Media / telecom network",
    method: "Subscriber/network earnings power + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [10, 24],
    peBase: 15,
    fcfYieldRange: [0.045, 0.085],
    fcfYieldBase: 0.06,
    targetMargin: 0.21,
    marginActualWeight: 0.62,
    fcfWeight: 0.44,
    normalizeFcfAcrossCycle: true,
    cycleNormalizationWindow: 16,
    fcfActualWeight: 0.65
  },
  interactive_entertainment: {
    label: "Interactive entertainment",
    method: "Content-cycle earnings power + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [18, 34],
    peBase: 23,
    fcfYieldRange: [0.035, 0.065],
    fcfYieldBase: 0.048,
    targetMargin: 0.24,
    marginActualWeight: 0.6,
    fcfWeight: 0.38,
    normalizeFcfAcrossCycle: true,
    cycleNormalizationWindow: 16,
    fcfActualWeight: 0.6
  },
  industrial_growth: {
    label: "Industrial growth",
    method: "Normalized industrial earnings power",
    peRange: [18, 38],
    peBase: 24,
    fcfYieldRange: [0.04, 0.075],
    fcfYieldBase: 0.055,
    targetMargin: 0.12,
    fcfWeight: 0.25,
    normalizeFcfAcrossCycle: true,
    cycleNormalizationWindow: 16,
    fcfActualWeight: 0.65
  },
  software_platform: {
    label: "Software platform",
    method: "Moderate-growth EV/sales + normalized earnings + FCFE DCF",
    allowLossMakingStage: true,
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.4,
    normalizedGrowthWindow: 8,
    normalizedGrowthCapPct: 45,
    peRange: [20, 44],
    peBase: 27,
    fcfYieldRange: [0.032, 0.065],
    fcfYieldBase: 0.045,
    evSalesRange: [3.0, 16.0],
    evSalesBase: 5.5,
    evSalesGrowthCoefficient: 0.11,
    evSalesGrossMarginCoefficient: 0.045,
    evSalesFcfMarginCoefficient: 0.035,
    targetMargin: 0.24,
    salesWeight: 0.38,
    earningsWeight: 0.32,
    fcfWeight: 0.30,
    defaultGrossMarginPct: 70
  },
  technology_hardware: {
    label: "Technology hardware",
    method: "Cycle-normalized EPS + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [13, 30],
    peBase: 19,
    fcfYieldRange: [0.04, 0.08],
    fcfYieldBase: 0.057,
    targetMargin: 0.15,
    fcfWeight: 0.38,
    normalizeFcfAcrossCycle: true,
    cycleNormalizationWindow: 16,
    fcfActualWeight: 0.6,
    cycleHaircut: 0.94
  },
  credit_services: {
    label: "Consumer and commercial credit",
    method: "ROE-implied P/B + normalized EPS",
    costOfEquity: 0.11,
    terminalGrowth: 0.025,
    pbRange: [0.8, 3.5],
    peRange: [8, 18],
    peBase: 11.5,
    bookWeight: 0.55,
    epsWeight: 0.45
  },
  capital_markets: {
    label: "Broker / capital markets",
    method: "Through-cycle ROE-implied P/B + EPS power",
    normalizedGrowthWindow: 8,
    costOfEquity: 0.11,
    terminalGrowth: 0.025,
    pbRange: [0.85, 4.5],
    peRange: [9, 22],
    peBase: 14,
    bookWeight: 0.48,
    epsWeight: 0.52,
    normalizedRoeRange: [0.06, 0.32],
    defaultRoe: 0.1,
    roeActualWeight: 0.55
  },
  asset_manager: {
    label: "Asset manager",
    method: "Through-cycle EPS power",
    normalizedGrowthWindow: 8,
    peRange: [9, 22],
    peBase: 14,
    peGrowthCoefficient: 0.1,
    peMarginCoefficient: 0,
    earningsActualWeight: 0.58
  },
  insurance_broker: {
    label: "Insurance broker",
    method: "Through-cycle brokerage EPS power",
    normalizedGrowthWindow: 8,
    peRange: [14, 28],
    peBase: 18,
    peGrowthCoefficient: 0.12,
    peMarginCoefficient: 0,
    earningsActualWeight: 0.65
  },
  reit: {
    label: "Equity REIT",
    method: "Normalized distributable cash flow + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [13, 25],
    peBase: 17,
    fcfYieldRange: [0.045, 0.085],
    fcfYieldBase: 0.062,
    targetMargin: 0.28,
    marginActualWeight: 0.65,
    fcfWeight: 0.78,
    maintenanceCapexIntensityPct: 0.05,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.6,
    terminalGrowth: 0.025
  },
  energy_infrastructure: {
    label: "Energy infrastructure / integrated",
    method: "Cycle-normalized owner earnings + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [7, 17],
    peBase: 10,
    fcfYieldRange: [0.065, 0.13],
    fcfYieldBase: 0.09,
    targetMargin: 0.12,
    marginActualWeight: 0.68,
    fcfWeight: 0.55,
    maintenanceCapexIntensityPct: 0.08,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.55,
    cycleHaircut: 0.82
  },
  materials: {
    label: "Materials / building products",
    method: "Cycle-normalized EPS + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [10, 25],
    peBase: 16,
    fcfYieldRange: [0.045, 0.095],
    fcfYieldBase: 0.066,
    targetMargin: 0.12,
    fcfWeight: 0.42,
    minimumReportedEarningsAnchorSamples: 4,
    minimumStandaloneFcfEvidenceConfidence: 0.625,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.55,
    cycleHaircut: 0.9
  },
  commodity_merchant: {
    label: "Commodity merchant / processor",
    method: "Low-margin cycle-normalized EPS + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [9, 18],
    peBase: 12,
    peGrowthCoefficient: 0.1,
    peMarginCoefficient: 0.06,
    fcfYieldRange: [0.06, 0.1],
    fcfYieldBase: 0.075,
    targetMargin: 0.035,
    marginActualWeight: 0.78,
    fcfWeight: 0.35,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.55,
    cycleHaircut: 0.9
  },
  consumer_staples: {
    label: "Consumer staples",
    method: "Normalized EPS + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [16, 32],
    peBase: 21,
    fcfYieldRange: [0.035, 0.065],
    fcfYieldBase: 0.048,
    targetMargin: 0.12,
    fcfWeight: 0.44
  },
  consumer_cyclical: {
    label: "Consumer cyclical",
    method: "Cycle-normalized EPS + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [10, 30],
    peBase: 18,
    fcfYieldRange: [0.04, 0.09],
    fcfYieldBase: 0.06,
    targetMargin: 0.1,
    fcfWeight: 0.4,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.6,
    cycleHaircut: 0.94
  },
  healthcare_services: {
    label: "Healthcare services / diagnostics",
    method: "Quality EPS + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [16, 36],
    peBase: 23,
    fcfYieldRange: [0.035, 0.075],
    fcfYieldBase: 0.052,
    targetMargin: 0.16,
    fcfWeight: 0.42
  },
  transportation: {
    label: "Transportation / travel",
    method: "Cycle-normalized EPS + FCFE DCF",
    normalizedGrowthWindow: 8,
    peRange: [9, 25],
    peBase: 15,
    fcfYieldRange: [0.045, 0.1],
    fcfYieldBase: 0.068,
    targetMargin: 0.1,
    fcfWeight: 0.42,
    normalizeFcfAcrossCycle: true,
    fcfActualWeight: 0.55,
    cycleHaircut: 0.9
  },
  industrial_gases_compounder: {
    label: "Industrial gases compounder",
    method: "Adjusted EPS guidance + owner-earnings FCFE DCF",
    historicalMethod: "Normalized industrial gas earnings + owner-earnings FCFE DCF",
    peRange: [26, 34],
    peBase: 27.5,
    peGrowthCoefficient: 0.22,
    peMarginCoefficient: 0.12,
    fcfYieldRange: [0.035, 0.055],
    fcfYieldBase: 0.044,
    fcfYieldGrowthCoefficient: 0.0002,
    fcfYieldMarginCoefficient: 0.00015,
    targetMargin: 0.23,
    marginActualWeight: 0.75,
    maintenanceCapexIntensityPct: 0.08,
    fcfWeight: 0.10,
    adjustedEpsGuidance: 17.75,
    adjustedEpsGuidanceRange: [17.60, 17.90],
    adjustedEpsGuidanceYear: 2026,
    adjustedEpsGuidanceVisibleFrom: "2026-02-06",
    adjustedOperatingMarginPct: 30.0,
    adjustedAfterTaxRocPct: 23.8,
    projectBacklogM: 10000,
    saleOfGasBacklogM: 7100
  },
  ev_autonomy_platform: {
    label: "EV / energy / autonomy platform",
    method: "Forward revenue power + autonomy/energy option value",
    forwardRevenueYears: 1,
    forwardFcfScaleCap: 1.35,
    peRange: [32, 72],
    peBase: 44,
    fcfYieldRange: [0.026, 0.065],
    fcfYieldBase: 0.045,
    evSalesRange: [3.5, 16.0],
    evSalesBase: 7.0,
    evSalesGrowthCoefficient: 0.12,
    evSalesGrossMarginCoefficient: 0.025,
    evSalesFcfMarginCoefficient: 0.035,
    targetMargin: 0.22,
    fcfWeight: 0.18,
    salesWeight: 0.52,
    earningsWeight: 0.30,
    bullCaseOptionalityMultiplier: 1.55
  },
  energy_technology: {
    label: "Energy technology",
    method: "EV/sales + FCFE DCF + normalized margin revenue power",
    peRange: [16, 30],
    peBase: 21,
    fcfYieldRange: [0.05, 0.085],
    fcfYieldBase: 0.065,
    evSalesRange: [1.0, 4.0],
    evSalesBase: 1.8,
    targetMargin: 0.1,
    fcfWeight: 0.30,
    salesWeight: 0.45,
    earningsWeight: 0.25,
    defaultGrossMarginPct: 28
  },
  emerging_biotech: {
    label: "Emerging biotech",
    method: "Revenue-stage biotech EV/sales + net cash",
    evSalesRange: [1.5, 7.0],
    evSalesBase: 2.8,
    targetMargin: 0,
    longRunGrowthRange: [0.0, 0.08],
    defaultGrossMarginPct: 68
  },
  emerging_health_ai: {
    label: "Emerging healthcare AI",
    method: "Revenue-stage healthcare AI EV/sales + net cash",
    evSalesRange: [2.0, 9.0],
    evSalesBase: 4.0,
    targetMargin: 0,
    longRunGrowthRange: [0.02, 0.12]
  }
};

function profileForTicker(ticker) {
  const normalized = String(ticker || "").toUpperCase();
  return VALUATION_PROFILES[normalized] || sp500ValuationProfile(normalized) || guruValuationProfile(normalized) || null;
}

export function valuationProfileNames() {
  return Object.keys(PROFILE_SETTINGS).sort();
}

export function hasExplicitValuationProfile(ticker) {
  const profile = profileForTicker(ticker);
  return Boolean(profile && Object.hasOwn(PROFILE_SETTINGS, profile));
}

export function profileSettings(ticker) {
  const profile = profileForTicker(ticker);
  if (!profile || !Object.hasOwn(PROFILE_SETTINGS, profile)) {
    throw new Error(`Missing explicit valuation profile for ${String(ticker || "").toUpperCase()}`);
  }
  return {
    profile,
    ...PROFILE_SETTINGS[profile]
  };
}

export function normalizedGrowthInputs(row, youtubeEvidence, settings = {}) {
  const cap = settings.normalizedGrowthCapPct ?? 45;
  const rawFundamentalGrowth = finiteNumber(row.normalized_revenue_growth_pct) ?? finiteNumber(row.revenue_growth_pct);
  const normalizedSampleCount = finiteNumber(row.normalized_revenue_growth_sample_count);
  const minimumSampleCount = Math.max(1, finiteNumber(settings.minimumGrowthSampleCount) ?? 4);
  const insufficientGrowthHistory = normalizedSampleCount != null && normalizedSampleCount < minimumSampleCount;
  const fundamentalGrowthEvidenceWeight = rawFundamentalGrowth == null || insufficientGrowthHistory
    ? 0
    : normalizedSampleCount == null
      ? 1
      : clamp((normalizedSampleCount - minimumSampleCount + 1) / 4, 0.25, 1);
  const fundamentalGrowth = fundamentalGrowthEvidenceWeight > 0 ? rawFundamentalGrowth : null;
  const reportedGuidanceGrowth = finiteNumber(youtubeEvidence?.revenueGuidanceGrowth);
  const maxGuidanceDelta = Math.max(0, finiteNumber(settings.guidanceGrowthMaxDeltaPct) ?? 15);
  const requestedGuidanceWeight = clamp(settings.guidanceGrowthWeight ?? 0.25, 0, 0.25);
  const baseGrowth = fundamentalGrowth == null
    ? 5
    : 5 * (1 - fundamentalGrowthEvidenceWeight) + fundamentalGrowth * fundamentalGrowthEvidenceWeight;
  const boundedGuidanceGrowth = reportedGuidanceGrowth == null
    ? null
    : clamp(reportedGuidanceGrowth, baseGrowth - maxGuidanceDelta, baseGrowth + maxGuidanceDelta);
  const guidanceWeight = boundedGuidanceGrowth != null ? requestedGuidanceWeight : 0;
  const rawValue = baseGrowth * (1 - guidanceWeight) + (boundedGuidanceGrowth ?? baseGrowth) * guidanceWeight;
  return {
    value: clamp(rawValue, -20, cap),
    source: fundamentalGrowth != null && reportedGuidanceGrowth != null
      ? fundamentalGrowthEvidenceWeight < 1
        ? "pit_financials_evidence_ramp_bounded_guidance_blend"
        : "pit_financials_bounded_guidance_blend"
      : fundamentalGrowth != null
        ? fundamentalGrowthEvidenceWeight < 1
          ? "pit_financials_evidence_ramp"
          : "pit_financials"
        : reportedGuidanceGrowth != null
          ? "conservative_default_bounded_guidance_blend"
          : "conservative_default",
    baseGrowthPct: baseGrowth,
    fundamentalGrowthPct: fundamentalGrowth,
    fundamentalGrowthEvidenceWeight,
    reportedFundamentalGrowthPct: rawFundamentalGrowth,
    insufficientGrowthHistory,
    minimumSampleCount,
    reportedGuidanceGrowthPct: reportedGuidanceGrowth,
    boundedGuidanceGrowthPct: boundedGuidanceGrowth,
    guidanceWeight,
    maxGuidanceDeltaPct: maxGuidanceDelta,
    capPct: cap,
    normalizedWindow: finiteNumber(row.normalized_revenue_growth_window),
    normalizedSampleCount
  };
}

export function normalizedGrowthPct(row, youtubeEvidence, settings = {}) {
  return normalizedGrowthInputs(row, youtubeEvidence, settings).value;
}

export function normalizedRevenueGrowthForRows(rows, index, windowSize = 8) {
  if (!(windowSize > 0)) return null;
  const values = rows
    .slice(Math.max(0, index - windowSize + 1), index + 1)
    .map((row) => finiteNumber(row.revenue_growth_pct))
    .filter((value) => value != null)
    .map((value) => clamp(value, -100, 1_000))
    .sort((left, right) => left - right);
  if (!values.length) return null;
  const floor = Math.floor(values.length * 0.15);
  const ceiling = Math.ceil(values.length * 0.85);
  const trimmed = values.slice(floor, Math.max(floor + 1, ceiling));
  return median(trimmed);
}

export function normalizedMarginRatio(ttm, settings) {
  const currentMargin = finiteNumber(ttm.operating_margin_pct);
  const cycleMargin = finiteNumber(ttm.cycle_operating_margin_pct);
  const opMargin = cycleMargin ?? currentMargin;
  const target = finiteNumber(settings.targetMargin) ?? 0.2;
  if (opMargin == null) return target;
  const actualWeight = clamp(settings.marginActualWeight ?? 0.7, 0.25, 0.9);
  const observedFloor = finiteNumber(settings.observedMarginFloor) ?? Math.min(target, Math.max(-0.05, target * 0.15));
  const observedCeiling = finiteNumber(settings.observedMarginCeiling) ?? 0.75;
  const normalizedObservedMargin = clamp(opMargin / 100, observedFloor, observedCeiling);
  const blendedMargin = normalizedObservedMargin * actualWeight + target * (1 - actualWeight);
  const floor = finiteNumber(settings.normalizedMarginFloor) ?? -0.05;
  const ceiling = finiteNumber(settings.normalizedMarginCap) ?? 0.6;
  return clamp(blendedMargin, floor, ceiling);
}

function adjustedPe(settings, growthPct, marginPct) {
  const [minPe, maxPe] = settings.peRange || [12, 30];
  const marginLift = finiteNumber(marginPct) != null ? (marginPct - 20) * (settings.peMarginCoefficient ?? 0.12) : 0;
  const pe = (settings.peBase || 18) + growthPct * (settings.peGrowthCoefficient ?? 0.22) + marginLift;
  return clamp(pe, minPe, maxPe);
}

function adjustedFcfYield(settings, growthPct, fcfMarginPct) {
  const [minYield, maxYield] = settings.fcfYieldRange || [0.04, 0.08];
  const fcfLift = finiteNumber(fcfMarginPct) != null ? (fcfMarginPct - 15) * (settings.fcfYieldMarginCoefficient ?? 0.00015) : 0;
  const yieldValue = (settings.fcfYieldBase || 0.055) - growthPct * (settings.fcfYieldGrowthCoefficient ?? 0.00022) - fcfLift;
  return clamp(yieldValue, minYield, maxYield);
}

function adjustedEvSales(settings, growthPct, grossMarginPct) {
  const [minMultiple, maxMultiple] = settings.evSalesRange || [1, 6];
  const normalizedGrossMargin = finiteNumber(grossMarginPct) ?? finiteNumber(settings.defaultGrossMarginPct);
  const marginLift = normalizedGrossMargin != null ? (normalizedGrossMargin - 55) * (settings.evSalesGrossMarginCoefficient ?? 0.035) : 0;
  const multiple = (settings.evSalesBase || 2.5) + growthPct * (settings.evSalesGrowthCoefficient ?? 0.045) + marginLift;
  return clamp(multiple, minMultiple, maxMultiple);
}

function forwardScaleFromGrowth(growthPct, settings) {
  const years = clamp(settings.forwardRevenueYears || 0, 0, 2) || 0;
  if (!years) return 1;
  const growth = clamp(growthPct, -30, settings.forwardGrowthCapPct ?? 65) / 100;
  return Math.max(0.55, Math.min(settings.forwardScaleCap || 2.4, (1 + growth) ** years));
}

function forwardMetric(value, scale) {
  const number = finiteNumber(value);
  if (number == null) return null;
  return number * scale;
}

function netCashM(ttm) {
  const cashM = finiteNumber(ttm.cash_m) || 0;
  const debtM = finiteNumber(ttm.debt_m) || 0;
  return cashM - debtM;
}

function plausibleGuidanceAmount(value, base, minScale, maxScale) {
  const amount = finiteNumber(value);
  const baseValue = finiteNumber(base);
  if (!(amount > 0) || !(baseValue > 0)) return null;
  const minValue = baseValue * minScale;
  const maxValue = baseValue * maxScale;
  if (amount < minValue || amount > maxValue) return null;
  return amount;
}

export function resolveForwardRevenueGuidance({
  ttmRevenue,
  formulaForwardRevenue,
  annualGuidanceM,
  unscopedGuidanceM,
  quarterlyGuidanceM,
  guidanceMode,
  settings = {}
}) {
  const base = finiteNumber(ttmRevenue);
  const formula = finiteNumber(formulaForwardRevenue);
  const reportedAnnualGuidanceM = finiteNumber(annualGuidanceM);
  const explicitAnnualScope = guidanceMode === "explicit_full_year";
  if (!(base > 0) || !(formula > 0)) {
    return {
      valuationRevenue: formula,
      annualGuidanceM: null,
      reportedAnnualGuidanceM,
      quarterlyGuidanceM: null,
      annualizedQuarterlyGuidanceM: null,
      boundedAnnualizedQuarterlyGuidanceM: null,
      quarterlyGuidanceWeight: null,
      source: "formula_forward",
      scope: "missing",
      rejectionReason: explicitAnnualScope ? "missing_positive_revenue_base" : null
    };
  }

  const maxScale = settings.guidanceRevenueMaxScale || Math.max(1.5, settings.forwardScaleCap || 2.1);
  const explicitAnnualGuidanceM = explicitAnnualScope
    ? plausibleGuidanceAmount(reportedAnnualGuidanceM, base, 0.65, maxScale)
    : null;
  if (explicitAnnualGuidanceM) {
    return {
      valuationRevenue: explicitAnnualGuidanceM,
      annualGuidanceM: explicitAnnualGuidanceM,
      reportedAnnualGuidanceM,
      quarterlyGuidanceM: null,
      annualizedQuarterlyGuidanceM: null,
      boundedAnnualizedQuarterlyGuidanceM: null,
      quarterlyGuidanceWeight: null,
      source: "full_year_guidance",
      scope: "explicit_full_year",
      rejectionReason: null
    };
  }

  const explicitQuarter = plausibleGuidanceAmount(quarterlyGuidanceM, base, 0.08, 0.75);
  const unscopedAmount = guidanceMode === "unscoped_fallback"
    ? finiteNumber(unscopedGuidanceM)
    : null;
  const unscopedScale = unscopedAmount && base ? unscopedAmount / base : null;
  const inferredQuarter = unscopedScale != null && unscopedScale >= 0.12 && unscopedScale <= 0.55
    ? unscopedAmount
    : null;
  const quarterGuide = explicitQuarter || inferredQuarter;
  if (quarterGuide) {
    const annualizedQuarterlyGuidanceM = quarterGuide * 4;
    const boundedAnnualized = clamp(annualizedQuarterlyGuidanceM, base * 0.55, base * maxScale);
    const guidanceWeight = clamp(settings.quarterlyGuidanceWeight ?? 0.65, 0.25, 0.85);
    return {
      valuationRevenue: boundedAnnualized * guidanceWeight + formula * (1 - guidanceWeight),
      annualGuidanceM: null,
      reportedAnnualGuidanceM,
      quarterlyGuidanceM: quarterGuide,
      annualizedQuarterlyGuidanceM,
      boundedAnnualizedQuarterlyGuidanceM: boundedAnnualized,
      quarterlyGuidanceWeight: guidanceWeight,
      source: "quarterly_guidance_blend",
      scope: explicitQuarter ? "explicit_quarter" : "inferred_quarter",
      rejectionReason: explicitAnnualScope ? "implausible_full_year_amount" : null
    };
  }

  return {
    valuationRevenue: formula,
    annualGuidanceM: null,
    reportedAnnualGuidanceM,
    quarterlyGuidanceM: null,
    annualizedQuarterlyGuidanceM: null,
    boundedAnnualizedQuarterlyGuidanceM: null,
    quarterlyGuidanceWeight: null,
    source: "formula_forward",
    scope: explicitAnnualScope ? "explicit_full_year_rejected" : "missing_or_implausible",
    rejectionReason: explicitAnnualScope ? "implausible_full_year_amount" : null
  };
}

function resolveExplicitAnnualGuidanceAmount({ mode, amount, base, minScale, maxScale }) {
  const reportedAmountM = finiteNumber(amount);
  if (mode !== "explicit_full_year") {
    return { amountM: null, reportedAmountM, rejectionReason: null };
  }
  const amountM = plausibleGuidanceAmount(reportedAmountM, base, minScale, maxScale);
  return {
    amountM,
    reportedAmountM,
    rejectionReason: amountM
      ? null
      : reportedAmountM > 0
        ? "implausible_full_year_amount"
        : "missing_positive_full_year_amount"
  };
}

function blendOperatingMarginWithGuidance(baseMargin, guidanceOperatingIncomeM, valuationRevenue, settings) {
  const reportedGuidanceMargin = guidanceOperatingIncomeM > 0 && valuationRevenue > 0
    ? guidanceOperatingIncomeM / valuationRevenue
    : null;
  if (!(reportedGuidanceMargin > 0)) {
    return {
      normalizedMargin: baseMargin,
      reportedGuidanceMargin: null,
      adjustedGuidanceMargin: null,
      guidanceWeight: null
    };
  }
  const adjustedGuidanceMargin = reportedGuidanceMargin * (settings.guidanceOperatingMarginHaircut || 0.85);
  const lowerBound = Math.max(0.01, baseMargin * 0.6);
  const upperBound = Math.min(0.65, Math.max(baseMargin * 1.55, baseMargin + 0.08));
  const boundedGuidanceMargin = clamp(adjustedGuidanceMargin, lowerBound, upperBound);
  const guidanceWeight = clamp(settings.guidanceOperatingMarginWeight ?? 0.65, 0.25, 0.85);
  return {
    normalizedMargin: baseMargin * (1 - guidanceWeight) + boundedGuidanceMargin * guidanceWeight,
    reportedGuidanceMargin,
    adjustedGuidanceMargin: boundedGuidanceMargin,
    guidanceWeight
  };
}

function forwardGuidanceVisibleForRow(row, settings) {
  const visibleFrom = settings.adjustedEpsGuidanceVisibleFrom;
  if (visibleFrom && row?.asOfDate) {
    return String(row.asOfDate).localeCompare(String(visibleFrom)) >= 0;
  }
  const guidanceYear = finiteNumber(settings.adjustedEpsGuidanceYear);
  const fiscalYear = finiteNumber(row?.fiscalYear);
  return guidanceYear != null && fiscalYear != null && fiscalYear >= guidanceYear;
}

export function valuationFreeCashFlow(ttm, settings) {
  const ttmFcf = finiteNumber(ttm.fcf_after_capex_m);
  const ttmCfo = finiteNumber(ttm.cfo_m);
  const ttmRevenue = finiteNumber(ttm.revenue_m);
  const ttmCapex = finiteNumber(ttm.capex_m);
  const cycleFcfMargin = finiteNumber(ttm.cycle_fcf_margin_pct);
  const cycleCfoMargin = finiteNumber(ttm.cycle_cfo_margin_pct);
  const cycleSampleCount = finiteNumber(ttm.cycle_sample_count) ?? 0;
  const positiveCycleFcfSampleCount = finiteNumber(ttm.cycle_positive_fcf_sample_count) ?? 0;
  const hasCycleFcfEvidence = positiveCycleFcfSampleCount >= 4;
  const fcfEvidenceConfidence = positiveCycleFcfSampleCount > 0
    ? clamp(0.25 + Math.max(0, positiveCycleFcfSampleCount - 1) * 0.125, 0.25, 1)
    : 0;
  const reportedFcfMargin = ttmFcf > 0 && ttmRevenue > 0 ? ttmFcf / ttmRevenue : null;
  const reportedFcfAnchor = ttmFcf > 0 && reportedFcfMargin >= 0.01
    ? ttmFcf * fcfEvidenceConfidence
    : null;
  const maintenanceIntensity = finiteNumber(settings.maintenanceCapexIntensityPct);
  const actualWeight = clamp(settings.fcfActualWeight ?? 0.65, 0.25, 0.9);
  const cycleFcfM = hasCycleFcfEvidence && ttmRevenue > 0 && cycleFcfMargin != null && cycleFcfMargin > 0
    ? ttmRevenue * cycleFcfMargin / 100
    : null;
  if (maintenanceIntensity > 0 && ttmRevenue > 0) {
    const cycleCfoM = cycleSampleCount >= 4 && cycleCfoMargin != null && cycleCfoMargin > 0
      ? ttmRevenue * cycleCfoMargin / 100
      : null;
    const normalizedCfoM = ttmCfo > 0 && cycleCfoM > 0
      ? ttmCfo * actualWeight + cycleCfoM * (1 - actualWeight)
      : ttmCfo > 0
        ? ttmCfo
        : cycleCfoM != null
          ? cycleCfoM * 0.7
          : null;
    const maintenanceCapexM = ttmRevenue * maintenanceIntensity;
    const normalizedFcf = normalizedCfoM != null
      ? normalizedCfoM - Math.min(Math.max(0, ttmCapex || 0), maintenanceCapexM)
      : null;
    return {
      reportedFcf: ttmFcf,
      normalizedFcf,
      cycleFcfM,
      reportedFcfAnchor,
      fcfEvidenceConfidence,
      maintenanceCapexM,
      growthCapexM: Math.max(0, (ttmCapex || 0) - maintenanceCapexM),
      capexIntensityPct: margin(ttmCapex, ttmRevenue),
      usesOwnerEarnings: true,
      usesCycleNormalization: cycleCfoM != null
    };
  }
  if (settings.normalizeFcfAcrossCycle && cycleFcfM > 0) {
    const fullEvidenceFcf = ttmFcf > 0
      ? ttmFcf * actualWeight + cycleFcfM * (1 - actualWeight)
      : cycleFcfM * 0.7;
    const normalizedFcf = fullEvidenceFcf * fcfEvidenceConfidence;
    return {
      reportedFcf: ttmFcf,
      normalizedFcf,
      cycleFcfM,
      reportedFcfAnchor,
      fcfEvidenceConfidence,
      maintenanceCapexM: null,
      growthCapexM: null,
      capexIntensityPct: margin(ttmCapex, ttmRevenue),
      usesOwnerEarnings: false,
      usesCycleNormalization: true,
      usesSparseReportedFcfAnchor: false
    };
  }
  if (settings.normalizeFcfAcrossCycle) {
    return {
      reportedFcf: ttmFcf,
      normalizedFcf: reportedFcfAnchor,
      cycleFcfM,
      reportedFcfAnchor,
      fcfEvidenceConfidence,
      maintenanceCapexM: null,
      growthCapexM: null,
      capexIntensityPct: margin(ttmCapex, ttmRevenue),
      usesOwnerEarnings: false,
      usesCycleNormalization: true,
      usesSparseReportedFcfAnchor: reportedFcfAnchor > 0,
      rejectionReason: reportedFcfAnchor > 0
        ? "sparse_reported_fcf_anchor"
        : reportedFcfMargin != null && reportedFcfMargin < 0.01
          ? "reported_fcf_below_one_percent_revenue_floor"
        : hasCycleFcfEvidence
        ? "no_positive_through_cycle_fcf"
        : "insufficient_independent_through_cycle_fcf_evidence"
    };
  }
  if (!(maintenanceIntensity > 0) || !(ttmCfo > 0) || !(ttmRevenue > 0) || !(ttmCapex > 0)) {
    return {
      reportedFcf: ttmFcf,
      normalizedFcf: ttmFcf,
      cycleFcfM,
      reportedFcfAnchor,
      fcfEvidenceConfidence,
      maintenanceCapexM: null,
      growthCapexM: null,
      capexIntensityPct: margin(ttmCapex, ttmRevenue),
      usesOwnerEarnings: false,
      usesCycleNormalization: false
    };
  }
  return {
    reportedFcf: ttmFcf,
    normalizedFcf: ttmFcf,
    cycleFcfM,
    reportedFcfAnchor,
    fcfEvidenceConfidence,
    maintenanceCapexM: null,
    growthCapexM: null,
    capexIntensityPct: margin(ttmCapex, ttmRevenue),
    usesOwnerEarnings: false,
    usesCycleNormalization: false
  };
}

const HIGH_RISK_DCF_PROFILES = new Set([
  "defense_growth",
  "emerging_biotech",
  "emerging_health_ai",
  "energy_technology",
  "ev_autonomy_platform",
  "genetic_diagnostics_growth",
  "hypergrowth_ai_software",
  "optical_networking_turnaround",
  "semiconductor_cyclical",
  "semiconductor_growth",
  "semiconductor_storage_cycle",
  "space_launch_growth",
  "space_platform_ipo"
]);

const LOWER_RISK_DCF_PROFILES = new Set([
  "ads_ai_platform",
  "information_services",
  "mega_cap_platform",
  "payments_network",
  "quality_consumer"
]);

const CYCLE_NORMALIZED_EARNINGS_PROFILES = new Set([
  "biopharma_growth",
  "commodity_merchant",
  "consumer_cyclical",
  "defense_growth",
  "defense_prime",
  "energy_e_and_p",
  "energy_infrastructure",
  "industrial_growth",
  "interactive_entertainment",
  "materials",
  "mature_medtech",
  "power_utility",
  "semiconductor_cyclical",
  "semiconductor_value",
  "technology_hardware",
  "transportation"
]);

export function normalizedNetIncomePower({
  ttm,
  valuationRevenue,
  normalizedOperatingMargin,
  taxRate = 0.19,
  allowLossPeriodTaxFallback = false
}) {
  const ttmRevenue = finiteNumber(ttm.revenue_m);
  const ttmOperatingIncome = finiteNumber(ttm.operating_income_m);
  const ttmNetIncome = finiteNumber(ttm.net_income_m);
  if (!(valuationRevenue > 0) || !(normalizedOperatingMargin > 0)) {
    return {
      netIncomeM: null,
      normalizedNetMargin: null,
      observedOperatingMargin: null,
      observedNetMargin: null,
      belowOperatingIncomeBurden: null
    };
  }

  const observedOperatingMargin = ttmRevenue > 0 && ttmOperatingIncome != null
    ? ttmOperatingIncome / ttmRevenue
    : null;
  const observedNetMargin = ttmRevenue > 0 && ttmNetIncome != null
    ? ttmNetIncome / ttmRevenue
    : null;
  const cycleOperatingMargin = finiteNumber(ttm.cycle_operating_margin_pct);
  const cycleNetMargin = finiteNumber(ttm.cycle_net_margin_pct);
  const cycleBurdenEligible = cycleOperatingMargin != null && cycleOperatingMargin > 0 &&
    cycleNetMargin != null && cycleNetMargin > 0;
  const cycleBelowOperatingBurden = cycleBurdenEligible
    ? finiteNumber(ttm.cycle_below_operating_burden_pct)
    : null;
  const observedBurden = observedOperatingMargin != null && observedNetMargin != null
    ? observedOperatingMargin - observedNetMargin
    : null;
  const observedBurdenEligible = observedOperatingMargin != null && observedOperatingMargin > 0 &&
    observedNetMargin != null && observedNetMargin > 0 &&
    observedBurden != null && observedBurden >= 0 && observedBurden <= 0.25;
  const normalizedBurdenSource = cycleBelowOperatingBurden != null
    ? cycleBelowOperatingBurden / 100
    : observedBurdenEligible
      ? observedBurden
      : null;
  const belowOperatingIncomeBurden = normalizedBurdenSource != null
    ? clamp(normalizedBurdenSource, 0, 0.25)
    : null;
  const taxBasedNetMargin = normalizedOperatingMargin * (1 - taxRate);
  const observedPositiveFloor = observedNetMargin != null && observedNetMargin > 0
    ? Math.min(observedNetMargin, taxBasedNetMargin) * 0.65
    : 0;
  const noPositiveProfitEvidence = !(observedOperatingMargin > 0 && observedNetMargin > 0) &&
    !(cycleOperatingMargin > 0 && cycleNetMargin > 0);
  const normalizedNetMargin = noPositiveProfitEvidence && !allowLossPeriodTaxFallback
    ? 0
    : belowOperatingIncomeBurden != null
    ? clamp(Math.max(normalizedOperatingMargin - belowOperatingIncomeBurden, observedPositiveFloor), 0, 0.6)
    : clamp(taxBasedNetMargin, 0, 0.6);

  return {
    netIncomeM: normalizedNetMargin > 0 ? valuationRevenue * normalizedNetMargin : null,
    normalizedNetMargin,
    observedOperatingMargin,
    observedNetMargin,
    belowOperatingIncomeBurden,
    cycleOperatingMargin: cycleOperatingMargin != null ? cycleOperatingMargin / 100 : null,
    cycleNetMargin: cycleNetMargin != null ? cycleNetMargin / 100 : null
  };
}

function allowsCycleLossPeriodTaxFallback(ttm, settings) {
  return CYCLE_NORMALIZED_EARNINGS_PROFILES.has(settings.profile) &&
    (finiteNumber(ttm.cycle_sample_count) ?? 0) >= 4 &&
    (finiteNumber(ttm.cycle_positive_eps_sample_count) ?? 0) >= 4 &&
    (finiteNumber(ttm.cycle_operating_margin_pct) ?? 0) > 0 &&
    (finiteNumber(ttm.cycle_net_margin_pct) ?? 0) > 0;
}

const MIN_INDEPENDENT_EARNINGS_SAMPLES = 4;

function hasSufficientEarningsHistory(ttm) {
  return (finiteNumber(ttm.cycle_positive_eps_sample_count) ?? 0) >= MIN_INDEPENDENT_EARNINGS_SAMPLES;
}

function conservativeReportedEarningsAnchor(ttm, taxRate = 0.19) {
  const reportedRevenueM = finiteNumber(ttm.revenue_m);
  const reportedNetIncomeM = finiteNumber(ttm.net_income_m);
  const reportedOperatingIncomeM = finiteNumber(ttm.operating_income_m);
  if (!(reportedNetIncomeM > 0) || !(reportedOperatingIncomeM > 0)) {
    return {
      value: null,
      beforeSparseCapM: null,
      afterTaxOperatingCapM: null,
      sparseHistoryCapM: null,
      rejectionReason: "no_positive_reported_earnings"
    };
  }
  const reportedNetMargin = reportedRevenueM > 0 ? reportedNetIncomeM / reportedRevenueM : null;
  if (reportedNetMargin != null && reportedNetMargin < 0.01) {
    return {
      value: null,
      beforeSparseCapM: null,
      afterTaxOperatingCapM: null,
      sparseHistoryCapM: null,
      rejectionReason: "reported_earnings_below_one_percent_revenue_floor"
    };
  }
  const netIncomeHaircutM = reportedNetIncomeM * 0.75;
  const afterTaxOperatingCapM = reportedOperatingIncomeM * (1 - clamp(taxRate, 0.05, 0.35)) * 0.9;
  const beforeSparseCapM = Math.min(netIncomeHaircutM, afterTaxOperatingCapM);
  const sparseEps = finiteNumber(ttm.cycle_sparse_eps);
  const sharesM = finiteNumber(ttm.shares_m);
  const positiveSampleCount = finiteNumber(ttm.cycle_positive_eps_sample_count) ?? 0;
  const sparseHistoryMultiplier = positiveSampleCount === 2
    ? 2
    : positiveSampleCount === 3
      ? 1.6
      : null;
  const sparseHistoryCapM = sparseHistoryMultiplier != null && sparseEps > 0 && sharesM > 0
    ? sparseEps * sharesM * sparseHistoryMultiplier
    : null;
  return {
    value: sparseHistoryCapM > 0 ? Math.min(beforeSparseCapM, sparseHistoryCapM) : beforeSparseCapM,
    beforeSparseCapM,
    afterTaxOperatingCapM,
    sparseHistoryCapM,
    rejectionReason: null
  };
}

function earningsHistoryConfidence(ttm) {
  const sampleCount = finiteNumber(ttm.cycle_positive_eps_sample_count) ?? 0;
  return clamp((sampleCount - MIN_INDEPENDENT_EARNINGS_SAMPLES + 1) / 5, 0, 1);
}

function blendEarningsHistoryWithReportedAnchor(normalizedNetIncomeM, reportedAnchorM, confidence) {
  const normalized = finiteNumber(normalizedNetIncomeM);
  const reported = finiteNumber(reportedAnchorM);
  if (!(normalized > 0)) return reported > 0 ? reported : null;
  if (!(confidence > 0)) return reported > 0 ? reported : null;
  if (!(reported > 0)) return normalized * confidence;
  return reported * (1 - confidence) + normalized * confidence;
}

function economicallyMaterialEarnings(value, valuationRevenue, { explicitGuidance = false } = {}) {
  const earningsM = finiteNumber(value);
  const revenueM = finiteNumber(valuationRevenue);
  if (!(earningsM > 0)) return { value: null, rejectionReason: "no_positive_normalized_earnings" };
  if (!explicitGuidance && revenueM > 0 && earningsM / revenueM < 0.01) {
    return {
      value: null,
      rejectionReason: "normalized_earnings_below_one_percent_revenue_floor"
    };
  }
  return { value: earningsM, rejectionReason: null };
}

function earningsMethodEvidenceConfidence({
  ttm,
  earningsHistoryEligible,
  earningsEvidenceConfidence,
  usesAdjustedEpsGuidance = false
}) {
  if (usesAdjustedEpsGuidance) return 1;
  const sampleCount = finiteNumber(ttm.cycle_positive_eps_sample_count) ?? 0;
  if (earningsHistoryEligible) return clamp(0.5 + earningsEvidenceConfidence * 0.5, 0.5, 1);
  if (sampleCount <= 0) return 0;
  return clamp(0.2 + sampleCount * 0.1, 0.3, 0.5);
}

function freeCashFlowMethodEvidenceConfidence({
  ttm,
  fcf = null,
  usesExplicitGuidance = false
}) {
  if (usesExplicitGuidance) return 1;
  const sampleCount = finiteNumber(ttm.cycle_positive_fcf_sample_count) ?? 0;
  const reportedFcf = finiteNumber(fcf?.reportedFcf ?? ttm.fcf_after_capex_m);
  if (!(reportedFcf > 0) && !(finiteNumber(fcf?.normalizedFcf) > 0)) return 0;
  if (sampleCount <= 0) return 0.25;
  return clamp(0.25 + Math.max(0, sampleCount - 1) * 0.125, 0.25, 1);
}

function valuationFreeCashFlowCapMargin(settings) {
  const targetMargin = Math.max(0, finiteNumber(settings.targetMargin) ?? 0.1);
  return clamp(
    finiteNumber(settings.maxFcfMarginPct) ?? Math.max(0.15, targetMargin * 1.5),
    0.08,
    0.65
  );
}

function capValuationFreeCashFlow(value, revenue, settings) {
  const fcfM = finiteNumber(value);
  const revenueM = finiteNumber(revenue);
  if (!(fcfM > 0) || !(revenueM > 0)) return fcfM;
  const maxMargin = valuationFreeCashFlowCapMargin(settings);
  return Math.min(fcfM, revenueM * maxMargin);
}

export function cycleNormalizeNetIncome(value, ttm, sharesM, settings) {
  const currentNetIncomeM = finiteNumber(value);
  const cycleEps = finiteNumber(ttm.cycle_eps);
  const positiveCycleSamples = finiteNumber(ttm.cycle_positive_eps_sample_count) ?? 0;
  if (!CYCLE_NORMALIZED_EARNINGS_PROFILES.has(settings.profile) || !(cycleEps > 0) ||
      positiveCycleSamples < 4 || !(sharesM > 0)) {
    return currentNetIncomeM;
  }
  const cycleNetIncomeM = cycleEps * sharesM;
  if (!(currentNetIncomeM > 0)) return cycleNetIncomeM * 0.65;
  const actualWeight = clamp(settings.earningsActualWeight ?? 0.68, 0.4, 0.85);
  const boundedCurrentNetIncomeM = clamp(
    currentNetIncomeM,
    cycleNetIncomeM * 0.4,
    cycleNetIncomeM * 2.5
  );
  return boundedCurrentNetIncomeM * actualWeight + cycleNetIncomeM * (1 - actualWeight);
}

function dcfRiskFloor(settings) {
  const explicit = finiteNumber(settings.costOfEquity);
  if (explicit != null) return explicit;
  if (HIGH_RISK_DCF_PROFILES.has(settings.profile)) return 0.115;
  if (settings.profile === "media_telecom" || settings.profile === "energy_e_and_p") return 0.105;
  if (LOWER_RISK_DCF_PROFILES.has(settings.profile)) return 0.09;
  return 0.10;
}

export function buildEquityDcf({ baseFcfM, sharesM, growthPct, ttm, settings, targetFcfYield, cycleHaircut = 1 }) {
  const startingFcfM = finiteNumber(baseFcfM);
  const shareCountM = finiteNumber(sharesM);
  if (!(startingFcfM > 0) || !(shareCountM > 0)) return null;

  const terminalGrowth = clamp(
    finiteNumber(settings.terminalGrowth) ?? (0.02 + clamp(growthPct, 0, 50) * 0.0003),
    0.01,
    0.04
  );
  const netDebtM = Math.max(0, (finiteNumber(ttm.debt_m) || 0) - (finiteNumber(ttm.cash_m) || 0));
  const netDebtToFcf = netDebtM / startingFcfM;
  const leveragePremium = clamp((netDebtToFcf - 2) * 0.0025, 0, 0.04);
  const yieldImpliedCost = (finiteNumber(targetFcfYield) || 0.055) + terminalGrowth + 0.005;
  const discountRate = clamp(
    Math.max(dcfRiskFloor(settings) + leveragePremium, yieldImpliedCost),
    0.085,
    0.18
  );
  const highRisk = HIGH_RISK_DCF_PROFILES.has(settings.profile);
  const nearTermGrowthCap = finiteNumber(settings.dcfNearTermGrowthCapPct) ?? (highRisk ? 35 : 22);
  const initialGrowth = clamp(growthPct, -20, nearTermGrowthCap) / 100;
  const annualCashFlows = [];
  let projectedFcfM = startingFcfM;
  let presentValueM = 0;

  for (let year = 1; year <= 5; year += 1) {
    const fade = (year - 1) / 4;
    const annualGrowth = year === 1
      ? 0
      : initialGrowth + (terminalGrowth - initialGrowth) * fade;
    if (year > 1) projectedFcfM *= 1 + annualGrowth;
    const discountedFcfM = projectedFcfM / (1 + discountRate) ** year;
    presentValueM += discountedFcfM;
    annualCashFlows.push({ year, growth: annualGrowth, fcfM: projectedFcfM, presentValueM: discountedFcfM });
  }

  const terminalValueM = projectedFcfM * (1 + terminalGrowth) / (discountRate - terminalGrowth);
  const terminalPresentValueM = terminalValueM / (1 + discountRate) ** 5;
  presentValueM += terminalPresentValueM;
  const fairValue = presentValueM / shareCountM * cycleHaircut;
  if (!(fairValue > 0) || !Number.isFinite(fairValue)) return null;

  return {
    fairValue,
    presentValueM,
    terminalValueM,
    terminalPresentValueM,
    terminalValueShare: terminalPresentValueM / presentValueM,
    discountRate,
    terminalGrowth,
    initialGrowth,
    netDebtM,
    netDebtToFcf,
    leveragePremium,
    annualCashFlows
  };
}

function blendValuationComponents(components) {
  const valid = components.filter((component) => component && finiteNumber(component.value) != null && component.value > 0 && component.weight > 0);
  const totalWeight = valid.reduce((sum, component) => sum + component.weight, 0);
  if (!totalWeight) return { fairValue: null, components: [] };
  return {
    fairValue: valid.reduce((sum, component) => sum + component.value * component.weight / totalWeight, 0),
    components: valid.map((component) => ({
      ...component,
      normalizedWeight: component.weight / totalWeight
    }))
  };
}

function evidenceAdjustedValuationComponents(components, { capSparseEarnings = false } = {}) {
  const adjusted = components.map((component) => ({
    ...component,
    requestedWeight: component.weight,
    weight: component.weight * clamp(component.evidenceConfidence ?? 1, 0, 1)
  }));
  if (capSparseEarnings) {
    const earnings = adjusted.find((component) =>
      component.key === "normalized-earnings-power" && finiteNumber(component.value) > 0
    );
    const independentWeight = adjusted
      .filter((component) => component !== earnings && finiteNumber(component.value) > 0)
      .reduce((sum, component) => sum + component.weight, 0);
    if (earnings && independentWeight > 0) earnings.weight = Math.min(earnings.weight, independentWeight);
  }
  return adjusted;
}

function growthEvSalesMultiple(settings, growthPct, grossMarginPct, fcfMarginPct) {
  const [minMultiple, maxMultiple] = settings.evSalesRange || [2, 10];
  const grossMargin = finiteNumber(grossMarginPct) ?? finiteNumber(settings.defaultGrossMarginPct) ?? 55;
  const fcfMargin = finiteNumber(fcfMarginPct) ?? 0;
  const base = settings.evSalesBase || 4;
  const multiple = base +
    growthPct * (settings.evSalesGrowthCoefficient ?? 0.12) +
    (grossMargin - 55) * (settings.evSalesGrossMarginCoefficient ?? 0.055) +
    Math.max(-10, Math.min(35, fcfMargin)) * (settings.evSalesFcfMarginCoefficient ?? 0.045);
  return clamp(multiple, minMultiple, maxMultiple);
}

function buildMultiMethodGrowthModel({ row, ttm, settings, youtubeEvidence }) {
  const sharesM = finiteNumber(ttm.shares_m);
  const ttmRevenue = finiteNumber(ttm.revenue_m);
  if (!(sharesM > 0) || !(ttmRevenue > 0)) return null;

  const growthInput = normalizedGrowthInputs(row, youtubeEvidence, settings);
  const growthPct = growthInput.value;
  const formulaForwardScale = forwardScaleFromGrowth(growthPct, settings);
  const formulaForwardRevenue = ttmRevenue * formulaForwardScale;
  const revenueGuidanceMode = youtubeEvidence?.guidanceSelection?.revenue?.mode;
  const revenueGuidance = resolveForwardRevenueGuidance({
    ttmRevenue,
    formulaForwardRevenue,
    annualGuidanceM: youtubeEvidence?.revenueGuidanceM,
    unscopedGuidanceM: youtubeEvidence?.revenueUnscopedGuidanceM,
    quarterlyGuidanceM: youtubeEvidence?.revenueQuarterGuidanceM,
    guidanceMode: revenueGuidanceMode,
    settings
  });
  const revenueGuidanceM = revenueGuidance.annualGuidanceM;
  const valuationRevenue = revenueGuidance.valuationRevenue;
  const revenueBasisLabel = revenueGuidance.source === "full_year_guidance"
    ? "FY guidance"
    : revenueGuidance.source === "quarterly_guidance_blend"
        ? "Quarterly-guidance blended forward"
        : settings.forwardRevenueYears
          ? "Forward"
          : "TTM";
  const forwardScale = valuationRevenue / ttmRevenue;
  const grossMarginPct = finiteNumber(ttm.gross_margin_pct ?? row.gross_margin_pct) ?? finiteNumber(settings.defaultGrossMarginPct);
  const baseNormalizedMargin = normalizedMarginRatio(ttm, settings);
  const operatingIncomeGuidance = resolveExplicitAnnualGuidanceAmount({
    mode: youtubeEvidence?.guidanceSelection?.operatingIncome?.mode,
    amount: youtubeEvidence?.operatingIncomeGuidanceM,
    base: valuationRevenue,
    minScale: 0.05,
    maxScale: 0.85
  });
  const guidanceOperatingIncomeM = operatingIncomeGuidance.amountM;
  const operatingMarginGuidance = blendOperatingMarginWithGuidance(
    baseNormalizedMargin,
    guidanceOperatingIncomeM,
    valuationRevenue,
    settings
  );
  const normalizedMargin = operatingMarginGuidance.normalizedMargin;
  const normalizedEarnings = normalizedNetIncomePower({
    ttm,
    valuationRevenue,
    normalizedOperatingMargin: normalizedMargin,
    allowLossPeriodTaxFallback: allowsCycleLossPeriodTaxFallback(ttm, settings)
  });
  const earningsHistoryEligible = hasSufficientEarningsHistory(ttm);
  const marginBasedNetIncome = earningsHistoryEligible ? normalizedEarnings.netIncomeM : null;
  const earningsAnchorAudit = conservativeReportedEarningsAnchor(ttm);
  const reportedEarningsAnchor = earningsAnchorAudit.value;
  const earningsEvidenceConfidence = earningsHistoryConfidence(ttm);
  const historyNormalizedNetIncome = earningsHistoryEligible
    ? cycleNormalizeNetIncome(marginBasedNetIncome, ttm, sharesM, settings)
    : null;
  const normalizedNetIncomeAudit = economicallyMaterialEarnings(blendEarningsHistoryWithReportedAnchor(
    historyNormalizedNetIncome,
    reportedEarningsAnchor,
    earningsEvidenceConfidence
  ), valuationRevenue);
  const normalizedNetIncome = normalizedNetIncomeAudit.value;
  const usesReportedEarningsAnchor = normalizedNetIncome > 0 && reportedEarningsAnchor != null && earningsEvidenceConfidence < 1;
  const effectiveNormalizedNetMargin = normalizedNetIncome > 0 && valuationRevenue > 0
    ? normalizedNetIncome / valuationRevenue
    : normalizedEarnings.normalizedNetMargin;
  const pe = adjustedPe(settings, growthPct, ttm.operating_margin_pct);
  const fcfYield = adjustedFcfYield(settings, growthPct, ttm.fcf_margin_pct);
  const evSales = growthEvSalesMultiple(settings, growthPct, grossMarginPct, ttm.fcf_margin_pct);
  const cycleHaircut = settings.cycleHaircut || 1;
  const optionalityMultiplier = 1;
  const bullCaseOptionalityMultiplier = finiteNumber(settings.bullCaseOptionalityMultiplier) || 1;
  const netCash = netCashM(ttm);
  const salesEnterpriseValueM = valuationRevenue * evSales;
  const salesEquityValueM = salesEnterpriseValueM + netCash;
  const minimumSalesEquityRetention = finiteNumber(settings.minimumSalesEquityRetention) ?? 0.01;
  const salesEquityRetention = salesEnterpriseValueM > 0
    ? salesEquityValueM / salesEnterpriseValueM
    : null;
  // A tiny residual after the net-debt bridge is numerical sensitivity, not a
  // defensible equity value. Exclude it and let independent methods carry the row.
  const salesValue = salesEquityValueM > 0 && salesEquityRetention >= minimumSalesEquityRetention
    ? salesEquityValueM / sharesM * cycleHaircut
    : null;
  const salesValueRejectionReason = salesEquityValueM > 0 && salesEquityRetention < minimumSalesEquityRetention
    ? "enterprise_value_nearly_cancelled_by_net_debt"
    : salesEquityValueM <= 0
      ? "nonpositive_equity_value_after_net_debt"
      : null;
  const earningsValue = normalizedNetIncome > 0 ? normalizedNetIncome / sharesM * pe * cycleHaircut : null;
  const ttmFcf = finiteNumber(ttm.fcf_after_capex_m);
  const freeCashFlowGuidance = resolveExplicitAnnualGuidanceAmount({
    mode: youtubeEvidence?.guidanceSelection?.freeCashFlow?.mode,
    amount: youtubeEvidence?.fcfGuidanceM,
    base: valuationRevenue,
    minScale: 0.03,
    maxScale: 0.85
  });
  const fcfGuidanceM = freeCashFlowGuidance.amountM;
  const rawValuationFcf = fcfGuidanceM || (ttmFcf && ttmFcf > 0
    ? forwardMetric(ttmFcf, Math.min(forwardScale, settings.forwardFcfScaleCap || 1.65))
    : null);
  const valuationFcf = capValuationFreeCashFlow(rawValuationFcf, valuationRevenue, settings);
  const equityDcf = buildEquityDcf({
    baseFcfM: valuationFcf,
    sharesM,
    growthPct,
    ttm,
    settings,
    targetFcfYield: fcfYield,
    cycleHaircut
  });
  const fcfValue = equityDcf?.fairValue || null;
  const earningsMethodConfidence = earningsValue > 0
    ? earningsMethodEvidenceConfidence({ ttm, earningsHistoryEligible, earningsEvidenceConfidence })
    : 0;
  const fcfMethodConfidence = fcfValue > 0
    ? freeCashFlowMethodEvidenceConfidence({ ttm, usesExplicitGuidance: fcfGuidanceM != null })
    : 0;
  const blended = blendValuationComponents(evidenceAdjustedValuationComponents([
    {
      key: "ev-sales-equity-value",
      value: salesValue,
      weight: settings.salesWeight ?? 0.4,
      evidenceConfidence: growthInput.fundamentalGrowthEvidenceWeight > 0
        ? Math.max(0.5, growthInput.fundamentalGrowthEvidenceWeight)
        : 0.5
    },
    {
      key: "normalized-earnings-power",
      value: earningsValue,
      weight: settings.earningsWeight ?? 0.3,
      evidenceConfidence: earningsMethodConfidence
    },
    {
      key: "fcfe-dcf",
      value: fcfValue,
      weight: settings.fcfWeight ?? 0.3,
      evidenceConfidence: fcfMethodConfidence
    }
  ], { capSparseEarnings: !earningsHistoryEligible }));
  if (!(blended.fairValue > 0)) return null;
  const fairValue = blended.fairValue * optionalityMultiplier;
  const longRunGrowth = clamp(0.035 + growthPct / 100 * 0.26 + Math.max(0, normalizedMargin) * 0.08, 0.025, 0.14);
  const componentWeight = (key) => blended.components.find((component) => component.key === key)?.normalizedWeight || 0;
  return {
    fairValue,
    targetPrice3Y: fairValue * (1 + longRunGrowth) ** 3,
    method: settings.method,
    longRunGrowth,
    methodOutputs: [
      {
        key: "ev-sales-equity-value",
        label: "EV/sales equity value",
        value: salesValue,
        format: "currency",
        description: salesValue
          ? `${revenueBasisLabel} revenue x ${evSales.toFixed(1)}x EV/sales plus ${netCash >= 0 ? "net cash" : "net debt"} bridge, divided by shares.`
          : salesValueRejectionReason === "enterprise_value_nearly_cancelled_by_net_debt"
            ? "EV/sales enterprise value was almost entirely cancelled by net debt, so the residual equity value was excluded as false precision."
            : "EV/sales enterprise value did not leave a positive equity value after the net-debt bridge."
      },
      {
        key: "normalized-earnings-power",
        label: usesReportedEarningsAnchor ? "Reported earnings anchor" : "Normalized earnings power",
        value: earningsValue,
        format: "currency",
        description: earningsValue
          ? usesReportedEarningsAnchor
            ? `The mature-margin estimate has ${(earningsEvidenceConfidence * 100).toFixed(0)}% evidence weight and is blended with a conservative reported trailing earnings anchor, then valued at ${pe.toFixed(1)}x P/E.`
            : `${revenueBasisLabel} revenue x ${(effectiveNormalizedNetMargin * 100).toFixed(1)}% effective normalized net margin / shares x ${pe.toFixed(1)}x P/E.`
          : "Normalized earnings were not usable, so the row relies on sales and/or FCF value."
      },
      {
        key: "fcfe-dcf",
        label: "Five-year FCFE DCF",
        value: fcfValue,
        format: "currency",
        description: fcfValue
          ? `${fcfGuidanceM ? "FY guidance" : settings.forwardRevenueYears ? "Forward-scaled" : "TTM"} equity FCF discounted at ${(equityDcf.discountRate * 100).toFixed(1)}%, fading toward ${(equityDcf.terminalGrowth * 100).toFixed(1)}% terminal growth.`
          : "FCF was unavailable or negative."
      },
      {
        key: "method-weighting",
        label: "Method weighting",
        value: componentWeight("ev-sales-equity-value") * 100,
        format: "percent",
        description: `${Math.round(componentWeight("ev-sales-equity-value") * 100)}% EV/sales / ${Math.round(componentWeight("normalized-earnings-power") * 100)}% earnings / ${Math.round(componentWeight("fcfe-dcf") * 100)}% FCFE DCF based on usable inputs.`
      }
    ],
    scoreInputs: {
      modelRoute: "multi_method_growth",
      profile: settings.profile,
      ttmRevenue,
      valuationRevenue,
      forwardScale,
      formulaForwardScale,
      forwardRevenueYears: settings.forwardRevenueYears || 0,
      revenueGuidanceM,
      reportedRevenueGuidanceM: revenueGuidance.reportedAnnualGuidanceM,
      revenueGuidanceRejectedReason: revenueGuidance.rejectionReason,
      quarterlyRevenueGuidanceM: revenueGuidance.quarterlyGuidanceM,
      annualizedQuarterlyRevenueGuidanceM: revenueGuidance.annualizedQuarterlyGuidanceM,
      boundedAnnualizedQuarterlyRevenueGuidanceM: revenueGuidance.boundedAnnualizedQuarterlyGuidanceM,
      quarterlyRevenueGuidanceWeight: revenueGuidance.quarterlyGuidanceWeight,
      revenueGuidanceScope: revenueGuidance.scope,
      forwardRevenueSource: revenueGuidance.source,
      ttmNetIncome: finiteNumber(ttm.net_income_m),
      earningsHistoryEligible,
      earningsEvidenceConfidence,
      requiredIndependentEarningsSamples: MIN_INDEPENDENT_EARNINGS_SAMPLES,
      reportedEarningsAnchor,
      reportedEarningsAnchorRejectionReason: earningsAnchorAudit.rejectionReason,
      reportedEarningsAnchorBeforeSparseCap: earningsAnchorAudit.beforeSparseCapM,
      reportedEarningsAfterTaxOperatingCap: earningsAnchorAudit.afterTaxOperatingCapM,
      sparseEarningsHistoryCap: earningsAnchorAudit.sparseHistoryCapM,
      historyNormalizedNetIncome,
      marginBasedNetIncome,
      normalizedNetIncome,
      normalizedNetIncomeRejectionReason: normalizedNetIncomeAudit.rejectionReason,
      effectiveNormalizedNetMargin: effectiveNormalizedNetMargin != null ? effectiveNormalizedNetMargin * 100 : null,
      cycleEps: ttm.cycle_eps,
      cyclePositiveEpsSampleCount: ttm.cycle_positive_eps_sample_count,
      cyclePositiveFcfSampleCount: ttm.cycle_positive_fcf_sample_count,
      earningsMethodEvidenceConfidence: earningsMethodConfidence,
      freeCashFlowMethodEvidenceConfidence: fcfMethodConfidence,
      observedOperatingMargin: normalizedEarnings.observedOperatingMargin != null ? normalizedEarnings.observedOperatingMargin * 100 : null,
      observedNetMargin: normalizedEarnings.observedNetMargin != null ? normalizedEarnings.observedNetMargin * 100 : null,
      belowOperatingIncomeBurden: normalizedEarnings.belowOperatingIncomeBurden != null ? normalizedEarnings.belowOperatingIncomeBurden * 100 : null,
      ttmFreeCashFlow: ttmFcf,
      rawValuationFreeCashFlow: rawValuationFcf,
      valuationFreeCashFlow: valuationFcf,
      valuationFreeCashFlowCapMargin: valuationFreeCashFlowCapMargin(settings),
      fcfGuidanceM,
      reportedFcfGuidanceM: freeCashFlowGuidance.reportedAmountM,
      fcfGuidanceRejectedReason: freeCashFlowGuidance.rejectionReason,
      guidanceOperatingIncomeM,
      reportedGuidanceOperatingIncomeM: operatingIncomeGuidance.reportedAmountM,
      guidanceOperatingIncomeRejectedReason: operatingIncomeGuidance.rejectionReason,
      reportedGuidanceOperatingMargin: operatingMarginGuidance.reportedGuidanceMargin != null
        ? operatingMarginGuidance.reportedGuidanceMargin * 100
        : null,
      guidanceOperatingMargin: operatingMarginGuidance.adjustedGuidanceMargin != null
        ? operatingMarginGuidance.adjustedGuidanceMargin * 100
        : null,
      guidanceOperatingMarginWeight: operatingMarginGuidance.guidanceWeight,
      revenueGrowth: growthPct,
      growthInput,
      grossMargin: grossMarginPct,
      operatingMargin: ttm.operating_margin_pct,
      normalizedMargin: normalizedMargin * 100,
      evSalesMultiple: evSales,
      salesEnterpriseValueM,
      salesEquityValueM,
      salesEquityRetention,
      minimumSalesEquityRetention,
      salesValueRejectionReason,
      targetPE: pe,
      targetFCFYield: fcfYield,
      equityDcf,
      netCashM: netCash,
      cashM: finiteNumber(ttm.cash_m),
      debtM: finiteNumber(ttm.debt_m),
      cycleHaircut,
      optionalityMultiplier,
      bullCaseOptionalityMultiplier,
      methodWeights: Object.fromEntries(blended.components.map((component) => [component.key, component.normalizedWeight])),
      requestedMethodWeights: Object.fromEntries(blended.components.map((component) => [component.key, component.requestedWeight])),
      sharesM
    },
    formula: `${Math.round(componentWeight("ev-sales-equity-value") * 100)}% EV/sales + ${Math.round(componentWeight("normalized-earnings-power") * 100)}% normalized earnings + ${Math.round(componentWeight("fcfe-dcf") * 100)}% five-year FCFE DCF${optionalityMultiplier !== 1 ? `, then x${optionalityMultiplier.toFixed(2)} platform optionality` : ""}; no market price input`
  };
}

function buildFinancialInstitutionModel({ ticker, row, ttm, settings }) {
  const sharesM = finiteNumber(ttm.shares_m);
  const equityM = finiteNumber(row.equity_m) ?? finiteNumber(ttm.equity_m);
  const netIncomeM = finiteNumber(ttm.net_income_m);
  if (!(sharesM > 0) || !(equityM > 0)) return null;
  const reportedRoe = netIncomeM != null ? netIncomeM / equityM : null;
  const cycleRoe = finiteNumber(ttm.cycle_roe_pct) != null ? finiteNumber(ttm.cycle_roe_pct) / 100 : null;
  const [minRoe, maxRoe] = settings.normalizedRoeRange || [0.04, 0.28];
  const actualWeight = clamp(settings.roeActualWeight ?? 0.65, 0.25, 0.9);
  const positiveReportedRoe = reportedRoe != null && reportedRoe > 0 ? reportedRoe : null;
  const positiveCycleRoe = cycleRoe != null && cycleRoe > 0 ? cycleRoe : null;
  const roeCandidate = positiveReportedRoe != null && positiveCycleRoe != null
    ? positiveReportedRoe * actualWeight + positiveCycleRoe * (1 - actualWeight)
    : positiveReportedRoe ?? positiveCycleRoe ?? finiteNumber(settings.defaultRoe) ?? 0.08;
  const roe = clamp(roeCandidate, minRoe, maxRoe);
  const bvps = equityM / sharesM;
  const costOfEquity = settings.costOfEquity || 0.1;
  const terminalGrowth = settings.terminalGrowth || 0.025;
  const pbRaw = (roe - terminalGrowth) / Math.max(0.01, costOfEquity - terminalGrowth);
  const pb = clamp(pbRaw, settings.pbRange[0], settings.pbRange[1]);
  const pe = clamp(settings.peBase + (roe - 0.11) * 18, settings.peRange[0], settings.peRange[1]);
  const normalizedNetIncomeM = equityM * roe;
  const epsValue = normalizedNetIncomeM / sharesM * pe;
  const bookValue = bvps * pb;
  const bookWeight = clamp(settings.bookWeight ?? 0.68, 0, 1);
  const epsWeight = settings.epsWeight != null
    ? clamp(settings.epsWeight, 0, 1)
    : 1 - bookWeight;
  const totalWeight = bookWeight + epsWeight || 1;
  const fairValue = (bookValue * bookWeight + epsValue * epsWeight) / totalWeight;
  const longRunGrowth = clamp(terminalGrowth + Math.max(-0.03, Math.min(0.08, roe - costOfEquity)) * 0.35, 0.015, 0.07);
  return {
    fairValue,
    targetPrice3Y: fairValue * (1 + longRunGrowth) ** 3,
    method: settings.method,
    longRunGrowth,
    methodOutputs: [
      {
        key: "roe-implied-book-value",
        label: "ROE-implied P/B value",
        value: bookValue,
        format: "currency",
        description: `Book value per share x ${pb.toFixed(2)}x implied P/B from ${(roe * 100).toFixed(1)}% through-cycle ROE and ${(costOfEquity * 100).toFixed(1)}% cost of equity.`
      },
      {
        key: "eps-cross-check",
        label: "EPS cross-check",
        value: epsValue,
        format: "currency",
        description: `Through-cycle EPS x ${pe.toFixed(1)}x normalized P/E; broker and asset-manager customer cash flows are excluded from FCFE DCF.`
      },
      {
        key: "financial-method-weighting",
        label: "Method weighting",
        value: bookWeight / totalWeight * 100,
        format: "percent",
        description: `${Math.round(bookWeight / totalWeight * 100)}% ROE-implied book value / ${Math.round(epsWeight / totalWeight * 100)}% EPS power.`
      },
      {
        key: "reported-equity",
        label: "Reported equity",
        value: equityM,
        format: "number",
        description: "SEC reported shareholders' equity, in USD millions."
      }
    ],
    scoreInputs: {
      modelRoute: "financial_institution",
      profile: settings.profile,
      ttmNetIncome: netIncomeM,
      normalizedNetIncome: normalizedNetIncomeM,
      equityM,
      sharesM,
      reportedRoe,
      cycleRoe,
      roe,
      targetPB: pb,
      targetPE: pe,
      costOfEquity,
      terminalGrowth
    },
    formula: `${Math.round(bookWeight / totalWeight * 100)}% ROE-implied book value + ${Math.round(epsWeight / totalWeight * 100)}% EPS cross-check; no market price input`
  };
}

function buildEarningsBusinessModel({ row, ttm, settings, youtubeEvidence }) {
  const sharesM = finiteNumber(ttm.shares_m);
  if (!(sharesM > 0)) return null;

  const netIncomeM = finiteNumber(ttm.net_income_m);
  const currentEps = netIncomeM != null && netIncomeM > 0 ? netIncomeM / sharesM : null;
  const cycleEps = finiteNumber(ttm.cycle_eps);
  const positiveCycleSamples = finiteNumber(ttm.cycle_positive_eps_sample_count) ?? 0;
  if (!(cycleEps > 0) || positiveCycleSamples < 4) return null;

  const actualWeight = clamp(settings.earningsActualWeight ?? 0.6, 0.25, 0.85);
  const boundedCurrentEps = cycleEps > 0
    ? currentEps > 0
      ? clamp(currentEps, cycleEps * 0.35, cycleEps * 2.5)
      : cycleEps * 0.65
    : currentEps;
  const normalizedEps = cycleEps > 0
    ? boundedCurrentEps * actualWeight + cycleEps * (1 - actualWeight)
    : boundedCurrentEps;
  if (!(normalizedEps > 0)) return null;

  const growthInput = normalizedGrowthInputs(row, youtubeEvidence, settings);
  const growthPct = growthInput.value;
  const pe = adjustedPe(settings, growthPct, null);
  const fairValue = normalizedEps * pe;
  const longRunGrowth = clamp(
    0.025 + Math.max(-10, Math.min(20, growthPct)) / 100 * 0.18,
    0.015,
    0.065
  );
  return {
    fairValue,
    targetPrice3Y: fairValue * (1 + longRunGrowth) ** 3,
    method: settings.method,
    longRunGrowth,
    methodOutputs: [
      {
        key: "through-cycle-eps",
        label: "Through-cycle EPS power",
        value: fairValue,
        format: "currency",
        description: `Point-in-time reported and trailing-cycle EPS blended to $${normalizedEps.toFixed(2)}, then valued at ${pe.toFixed(1)}x P/E.`
      },
      {
        key: "customer-cash-flow-exclusion",
        label: "Customer cash flows excluded",
        value: 100,
        format: "percent",
        description: "Customer, fund, brokerage, and policyholder cash flows are excluded from FCFE valuation."
      }
    ],
    scoreInputs: {
      modelRoute: "customer_cash_earnings",
      profile: settings.profile,
      ttmNetIncome: netIncomeM,
      currentEps,
      cycleEps,
      normalizedEps,
      cycleSampleCount: ttm.cycle_sample_count,
      cyclePositiveEpsSampleCount: ttm.cycle_positive_eps_sample_count,
      revenueGrowth: growthPct,
      growthInput,
      targetPE: pe,
      sharesM
    },
    formula: "Through-cycle normalized EPS x target P/E; no customer cash flow, book-value multiple, or market price input"
  };
}

function buildRevenueStageModel({ row, ttm, settings, youtubeEvidence }) {
  const sharesM = finiteNumber(ttm.shares_m);
  const ttmRevenue = finiteNumber(ttm.revenue_m);
  if (!(sharesM > 0) || !(ttmRevenue > 0)) return null;
  const growthInput = normalizedGrowthInputs(row, youtubeEvidence, settings);
  const growthPct = growthInput.value;
  const formulaForwardScale = forwardScaleFromGrowth(growthPct, settings);
  const formulaForwardRevenue = ttmRevenue * formulaForwardScale;
  const revenueGuidance = resolveForwardRevenueGuidance({
    ttmRevenue,
    formulaForwardRevenue,
    annualGuidanceM: youtubeEvidence?.revenueGuidanceM,
    unscopedGuidanceM: youtubeEvidence?.revenueUnscopedGuidanceM,
    quarterlyGuidanceM: youtubeEvidence?.revenueQuarterGuidanceM,
    guidanceMode: youtubeEvidence?.guidanceSelection?.revenue?.mode,
    settings
  });
  const valuationRevenue = revenueGuidance.valuationRevenue;
  const forwardScale = valuationRevenue / ttmRevenue;
  const revenueBasisLabel = revenueGuidance.source === "full_year_guidance"
    ? "FY guidance"
    : revenueGuidance.source === "quarterly_guidance_blend"
      ? "Quarterly-guidance blended forward"
      : settings.forwardRevenueYears
        ? "Forward"
        : "TTM";
  const grossMarginPct = finiteNumber(ttm.gross_margin_pct ?? row.gross_margin_pct) ?? finiteNumber(settings.defaultGrossMarginPct);
  const evSales = adjustedEvSales(settings, growthPct, grossMarginPct);
  const cashM = finiteNumber(ttm.cash_m) || 0;
  const debtM = finiteNumber(ttm.debt_m) || 0;
  const enterpriseValueM = valuationRevenue * evSales;
  const equityValueM = Math.max(0, enterpriseValueM + cashM - debtM);
  const fairValue = equityValueM / sharesM;
  const [minGrowth, maxGrowth] = settings.longRunGrowthRange || [0.0, 0.1];
  const longRunGrowth = clamp(0.02 + growthPct / 100 * 0.18, minGrowth, maxGrowth);
  return {
    fairValue,
    targetPrice3Y: fairValue * (1 + longRunGrowth) ** 3,
    method: settings.method,
    longRunGrowth,
    methodOutputs: [
      {
        key: "revenue-stage-enterprise-value",
        label: "Revenue-stage enterprise value",
        value: enterpriseValueM,
        format: "number",
        description: `${revenueBasisLabel} revenue x ${evSales.toFixed(1)}x EV/sales, based on revenue growth and gross-margin quality.`
      },
      {
        key: "net-cash-bridge",
        label: "Net cash bridge",
        value: cashM - debtM,
        format: "number",
        description: "Reported cash less debt, added to enterprise value before dividing by shares."
      }
    ],
    scoreInputs: {
      modelRoute: "revenue_stage",
      profile: settings.profile,
      ttmRevenue,
      valuationRevenue,
      forwardScale,
      formulaForwardScale,
      forwardRevenueYears: settings.forwardRevenueYears || 0,
      revenueGuidanceM: revenueGuidance.annualGuidanceM,
      reportedRevenueGuidanceM: revenueGuidance.reportedAnnualGuidanceM,
      revenueGuidanceRejectedReason: revenueGuidance.rejectionReason,
      quarterlyRevenueGuidanceM: revenueGuidance.quarterlyGuidanceM,
      annualizedQuarterlyRevenueGuidanceM: revenueGuidance.annualizedQuarterlyGuidanceM,
      boundedAnnualizedQuarterlyRevenueGuidanceM: revenueGuidance.boundedAnnualizedQuarterlyGuidanceM,
      quarterlyRevenueGuidanceWeight: revenueGuidance.quarterlyGuidanceWeight,
      revenueGuidanceScope: revenueGuidance.scope,
      forwardRevenueSource: revenueGuidance.source,
      revenueGrowth: growthPct,
      growthInput,
      grossMargin: grossMarginPct,
      evSalesMultiple: evSales,
      cashM,
      debtM,
      sharesM
    },
    formula: `${revenueBasisLabel} revenue x EV/sales + net cash, divided by shares; no market price input`
  };
}

function buildBitcoinTreasuryModel({ row, ttm, settings }) {
  const sharesM = finiteNumber(ttm.shares_m);
  const cryptoFairValueM = finiteNumber(row.crypto_asset_fair_value_m) ?? finiteNumber(ttm.crypto_asset_fair_value_m);
  const cryptoCostM = finiteNumber(row.crypto_asset_cost_m) ?? finiteNumber(ttm.crypto_asset_cost_m);
  const cryptoUnits = finiteNumber(row.crypto_asset_units) ?? finiteNumber(ttm.crypto_asset_units);
  if (!(sharesM > 0) || !(cryptoFairValueM > 0)) return null;

  const ttmRevenue = finiteNumber(ttm.revenue_m);
  const cashM = finiteNumber(ttm.cash_m) || 0;
  const debtM = finiteNumber(ttm.debt_m) || 0;
  const softwareRevenueMultiple = settings.softwareRevenueMultiple || 2.2;
  const treasuryHaircut = settings.treasuryHaircut || 0.98;
  const softwareValueM = ttmRevenue && ttmRevenue > 0 ? ttmRevenue * softwareRevenueMultiple : 0;
  const treasuryValueM = cryptoFairValueM * treasuryHaircut;
  const netCashMValue = cashM - debtM;
  const equityValueM = treasuryValueM + softwareValueM + netCashMValue;
  const fairValue = equityValueM / sharesM;
  if (!(fairValue > 0)) return null;

  const btcPerShare = cryptoUnits && sharesM ? cryptoUnits / (sharesM * 1_000_000) : null;
  const impliedBtcPrice = cryptoUnits && cryptoUnits > 0 ? cryptoFairValueM * 1_000_000 / cryptoUnits : null;
  const longRunGrowth = settings.longRunGrowth || 0.08;
  return {
    fairValue,
    targetPrice3Y: fairValue * (1 + longRunGrowth) ** 3,
    method: settings.method,
    longRunGrowth,
    methodOutputs: [
      {
        key: "btc-treasury-nav",
        label: "BTC treasury NAV",
        value: treasuryValueM / sharesM,
        format: "currency",
        description: `SEC reported crypto asset fair value x ${(treasuryHaircut * 100).toFixed(0)}% treasury haircut, divided by period-end quoted-security shares.`
      },
      {
        key: "software-business-value",
        label: "Software business value",
        value: softwareValueM / sharesM,
        format: "currency",
        description: `${ttmRevenue ? "TTM" : "Reported"} software revenue x ${softwareRevenueMultiple.toFixed(1)}x EV/sales.`
      },
      {
        key: "net-cash-debt-bridge",
        label: "Net cash / debt bridge",
        value: netCashMValue / sharesM,
        format: "currency",
        description: "Reported cash less debt, divided by period-end quoted-security shares."
      },
      {
        key: "btc-per-share",
        label: "BTC per share",
        value: btcPerShare,
        format: "number",
        description: "Reported BTC units divided by period-end quoted-security share count."
      }
    ],
    scoreInputs: {
      modelRoute: "bitcoin_treasury",
      profile: settings.profile,
      cryptoFairValueM,
      cryptoCostM,
      cryptoUnits,
      impliedBtcPrice,
      btcPerShare,
      ttmRevenue,
      softwareRevenueMultiple,
      softwareValueM,
      treasuryHaircut,
      treasuryValueM,
      cashM,
      debtM,
      netCashM: netCashMValue,
      sharesM
    },
    formula: "SEC reported BTC fair value x treasury haircut + software EV/sales value + cash - debt, divided by shares; no market price input"
  };
}

function buildOperatingCompanyModel({ ticker, row, ttm, settings, youtubeEvidence }) {
  const sharesM = finiteNumber(ttm.shares_m);
  const ttmRevenue = finiteNumber(ttm.revenue_m);
  const ttmNetIncome = finiteNumber(ttm.net_income_m);
  if (!(sharesM > 0) || !(ttmRevenue > 0)) return null;
  if (settings.profile === "bitcoin_treasury_software") {
    return buildBitcoinTreasuryModel({ row, ttm, settings });
  }
  if (["emerging_biotech", "emerging_health_ai"].includes(settings.profile)) {
    return buildRevenueStageModel({ row, ttm, settings, youtubeEvidence });
  }
  if ([
    "software_growth",
    "software_platform",
    "hypergrowth_ai_software",
    "defense_growth",
    "space_launch_growth",
    "space_platform_ipo",
    "genetic_diagnostics_growth",
    "semiconductor_growth",
    "semiconductor_storage_cycle",
    "optical_networking_turnaround",
    "energy_technology",
    "ev_autonomy_platform",
    "platform_marketplace_reinvestment",
    "subscription_streaming_platform"
  ].includes(settings.profile)) {
    return buildMultiMethodGrowthModel({ row, ttm, settings, youtubeEvidence });
  }

  const growthInput = normalizedGrowthInputs(row, youtubeEvidence, settings);
  const growthPct = growthInput.value;
  const formulaForwardScale = forwardScaleFromGrowth(growthPct, settings);
  const formulaForwardRevenue = ttmRevenue * formulaForwardScale;
  const revenueGuidance = resolveForwardRevenueGuidance({
    ttmRevenue,
    formulaForwardRevenue,
    annualGuidanceM: youtubeEvidence?.revenueGuidanceM,
    unscopedGuidanceM: youtubeEvidence?.revenueUnscopedGuidanceM,
    quarterlyGuidanceM: youtubeEvidence?.revenueQuarterGuidanceM,
    guidanceMode: youtubeEvidence?.guidanceSelection?.revenue?.mode,
    settings
  });
  const valuationRevenue = revenueGuidance.valuationRevenue;
  const forwardScale = valuationRevenue / ttmRevenue;
  const revenueBasisLabel = revenueGuidance.source === "full_year_guidance"
    ? "FY guidance"
    : revenueGuidance.source === "quarterly_guidance_blend"
      ? "Quarterly-guidance blended forward"
      : settings.forwardRevenueYears
        ? "Forward"
        : "TTM";
  const baseNormalizedMargin = normalizedMarginRatio(ttm, settings);
  const operatingIncomeGuidance = resolveExplicitAnnualGuidanceAmount({
    mode: youtubeEvidence?.guidanceSelection?.operatingIncome?.mode,
    amount: youtubeEvidence?.operatingIncomeGuidanceM,
    base: valuationRevenue,
    minScale: 0.05,
    maxScale: 0.85
  });
  const guidanceOperatingIncomeM = operatingIncomeGuidance.amountM;
  const operatingMarginGuidance = blendOperatingMarginWithGuidance(
    baseNormalizedMargin,
    guidanceOperatingIncomeM,
    valuationRevenue,
    settings
  );
  const normalizedMargin = operatingMarginGuidance.normalizedMargin;
  const guidanceVisible = forwardGuidanceVisibleForRow(row, settings);
  const adjustedEpsGuidance = guidanceVisible ? finiteNumber(settings.adjustedEpsGuidance) : null;
  const guidedAdjustedNetIncome = adjustedEpsGuidance && sharesM > 0
    ? adjustedEpsGuidance * sharesM
    : null;
  const normalizedEarnings = normalizedNetIncomePower({
    ttm,
    valuationRevenue,
    normalizedOperatingMargin: normalizedMargin,
    allowLossPeriodTaxFallback: allowsCycleLossPeriodTaxFallback(ttm, settings)
  });
  const earningsHistoryEligible = hasSufficientEarningsHistory(ttm);
  const marginBasedNetIncome = earningsHistoryEligible ? normalizedEarnings.netIncomeM : null;
  const earningsAnchorAudit = conservativeReportedEarningsAnchor(ttm);
  const positiveEarningsSamples = finiteNumber(ttm.cycle_positive_eps_sample_count) ?? 0;
  const minimumReportedEarningsAnchorSamples = Math.max(
    1,
    finiteNumber(settings.minimumReportedEarningsAnchorSamples) ?? 1
  );
  const reportedEarningsAnchor = positiveEarningsSamples >= minimumReportedEarningsAnchorSamples
    ? earningsAnchorAudit.value
    : null;
  const reportedEarningsAnchorRejectionReason = earningsAnchorAudit.value > 0 && reportedEarningsAnchor == null
    ? "insufficient_independent_earnings_history"
    : earningsAnchorAudit.rejectionReason;
  const earningsEvidenceConfidence = earningsHistoryConfidence(ttm);
  const historyNormalizedNetIncome = earningsHistoryEligible
    ? cycleNormalizeNetIncome(marginBasedNetIncome, ttm, sharesM, settings)
    : null;
  const normalizedNetIncomeCandidate = guidedAdjustedNetIncome != null
    ? guidedAdjustedNetIncome
    : blendEarningsHistoryWithReportedAnchor(
        historyNormalizedNetIncome,
        reportedEarningsAnchor,
        earningsEvidenceConfidence
      );
  const normalizedNetIncomeAudit = economicallyMaterialEarnings(
    normalizedNetIncomeCandidate,
    valuationRevenue,
    { explicitGuidance: guidedAdjustedNetIncome != null }
  );
  const normalizedNetIncome = normalizedNetIncomeAudit.value;
  const effectiveNormalizedNetMargin = normalizedNetIncome > 0 && valuationRevenue > 0
    ? normalizedNetIncome / valuationRevenue
    : normalizedEarnings.normalizedNetMargin;
  const usesAdjustedEpsGuidance = guidedAdjustedNetIncome != null && Math.abs(normalizedNetIncome - guidedAdjustedNetIncome) < 0.01;
  const usesReportedEarningsAnchor = normalizedNetIncome > 0 && guidedAdjustedNetIncome == null &&
    reportedEarningsAnchor != null && earningsEvidenceConfidence < 1;
  const pe = adjustedPe(settings, growthPct, ttm.operating_margin_pct);
  const fcfYield = adjustedFcfYield(settings, growthPct, ttm.fcf_margin_pct);
  const cycleHaircut = settings.cycleHaircut || 1;
  const earningsValue = normalizedNetIncome > 0 ? normalizedNetIncome / sharesM * pe * cycleHaircut : null;
  const fcf = valuationFreeCashFlow(ttm, settings);
  const ttmFcf = fcf.reportedFcf;
  const freeCashFlowGuidance = resolveExplicitAnnualGuidanceAmount({
    mode: youtubeEvidence?.guidanceSelection?.freeCashFlow?.mode,
    amount: youtubeEvidence?.fcfGuidanceM,
    base: valuationRevenue,
    minScale: 0.03,
    maxScale: 0.85
  });
  const fcfGuidanceM = freeCashFlowGuidance.amountM;
  const fcfBase = fcf.usesOwnerEarnings || fcf.usesCycleNormalization ? fcf.normalizedFcf : ttmFcf;
  const rawValuationFcf = fcfGuidanceM || (fcfBase && fcfBase > 0
    ? forwardMetric(fcfBase, Math.min(forwardScale, settings.forwardFcfScaleCap || 1.65))
    : null);
  const valuationFcf = capValuationFreeCashFlow(rawValuationFcf, valuationRevenue, settings);
  const equityDcf = buildEquityDcf({
    baseFcfM: valuationFcf,
    sharesM,
    growthPct,
    ttm,
    settings,
    targetFcfYield: fcfYield,
    cycleHaircut
  });
  const fcfValue = equityDcf?.fairValue || null;
  const requestedFcfWeight = clamp(settings.fcfWeight ?? 0.35, 0, 1);
  const earningsMethodConfidence = earningsValue > 0
    ? earningsMethodEvidenceConfidence({
        ttm,
        earningsHistoryEligible,
        earningsEvidenceConfidence,
        usesAdjustedEpsGuidance
      })
    : 0;
  const fcfMethodConfidence = fcfValue > 0
    ? freeCashFlowMethodEvidenceConfidence({
        ttm,
        fcf,
        usesExplicitGuidance: fcfGuidanceM != null
      })
    : 0;
  const minimumStandaloneFcfEvidenceConfidence = clamp(
    finiteNumber(settings.minimumStandaloneFcfEvidenceConfidence) ?? 0,
    0,
    1
  );
  if (!(earningsValue > 0) && fcfValue > 0 &&
      fcfMethodConfidence < minimumStandaloneFcfEvidenceConfidence) {
    return null;
  }
  const blended = blendValuationComponents(evidenceAdjustedValuationComponents([
    {
      key: "normalized-earnings-power",
      value: earningsValue,
      weight: 1 - requestedFcfWeight,
      evidenceConfidence: earningsMethodConfidence
    },
    {
      key: "fcfe-dcf",
      value: fcfValue,
      weight: requestedFcfWeight,
      evidenceConfidence: fcfMethodConfidence
    }
  ], {
    capSparseEarnings: !earningsHistoryEligible && !usesAdjustedEpsGuidance && requestedFcfWeight >= 0.3
  }));
  if (!(blended.fairValue > 0)) return null;
  const componentWeight = (key) => blended.components.find((component) => component.key === key)?.normalizedWeight || 0;
  const earningsWeight = componentWeight("normalized-earnings-power");
  const fcfWeight = componentWeight("fcfe-dcf");
  const optionalityMultiplier = 1;
  const bullCaseOptionalityMultiplier = finiteNumber(settings.bullCaseOptionalityMultiplier) || 1;
  const fairValue = blended.fairValue * optionalityMultiplier;
  const longRunGrowth = clamp(0.035 + growthPct / 100 * 0.3 + normalizedMargin * 0.08, 0.025, 0.14);
  return {
    fairValue,
    targetPrice3Y: fairValue * (1 + longRunGrowth) ** 3,
    method: usesAdjustedEpsGuidance ? settings.method : (settings.historicalMethod || settings.method),
    longRunGrowth,
    methodOutputs: [
      {
        key: "normalized-earnings-power",
        label: usesAdjustedEpsGuidance
          ? "Adjusted EPS power"
          : usesReportedEarningsAnchor
            ? "Reported earnings anchor"
            : "Normalized earnings power",
        value: earningsValue,
        format: "currency",
        description: usesAdjustedEpsGuidance
          ? `${settings.adjustedEpsGuidanceYear || "Forward"} adjusted EPS guidance midpoint $${adjustedEpsGuidance.toFixed(2)} x ${pe.toFixed(1)}x P/E.`
          : usesReportedEarningsAnchor
            ? `The mature-margin estimate has ${(earningsEvidenceConfidence * 100).toFixed(0)}% evidence weight and is blended with a conservative reported trailing earnings anchor, then valued at ${pe.toFixed(1)}x P/E.`
          : earningsValue
            ? `${revenueBasisLabel} revenue x ${(effectiveNormalizedNetMargin * 100).toFixed(1)}% effective normalized net margin / shares x ${pe.toFixed(1)}x P/E.`
            : "Normalized earnings were not positive, so the row relies on FCFE DCF."
      },
      {
        key: "fcfe-dcf",
        label: fcfGuidanceM
          ? "Guided FCFE DCF"
          : fcf.usesOwnerEarnings
          ? "Owner earnings FCFE DCF"
          : fcf.usesSparseReportedFcfAnchor
            ? "Evidence-haircut FCFE DCF"
          : fcf.usesCycleNormalization
            ? "Cycle-normalized FCFE DCF"
            : "Five-year FCFE DCF",
        value: fcfValue,
        format: "currency",
        description: fcfValue
          ? `${fcfGuidanceM ? "FY guidance equity FCF" : settings.forwardRevenueYears ? "Forward-scaled " : "TTM "}${fcfGuidanceM ? "" : fcf.usesOwnerEarnings ? "owner earnings FCF" : fcf.usesSparseReportedFcfAnchor ? "evidence-haircut reported equity FCF" : fcf.usesCycleNormalization ? "cycle-normalized equity FCF" : "equity FCF"} discounted at ${(equityDcf.discountRate * 100).toFixed(1)}%, fading toward ${(equityDcf.terminalGrowth * 100).toFixed(1)}% terminal growth.`
          : "FCF was unavailable or negative, so earnings power carries the row."
      },
      ...(fcf.usesOwnerEarnings ? [{
        key: "growth-capex-normalization",
        label: "Growth capex normalization",
        value: fcf.growthCapexM,
        format: "number",
        description: `Reported capex intensity ${formatPct(fcf.capexIntensityPct)}; model treats ${(settings.maintenanceCapexIntensityPct * 100).toFixed(1)}% of revenue as maintenance capex and the excess as AI/growth reinvestment.`
      }] : []),
      {
        key: "growth-margin-inputs",
        label: "Growth / margin input",
        value: growthPct,
        format: "percent",
        description: `Revenue growth input ${growthPct.toFixed(1)}%, TTM operating margin ${formatPct(ttm.operating_margin_pct)}.`
      },
      ...(guidanceVisible && settings.projectBacklogM ? [{
        key: "contracted-project-backlog",
        label: "Contracted project backlog",
        value: settings.projectBacklogM,
        format: "number",
        description: settings.saleOfGasBacklogM
          ? `$${(settings.projectBacklogM / 1000).toFixed(1)}B project backlog, including $${(settings.saleOfGasBacklogM / 1000).toFixed(1)}B sale-of-gas backlog. Growth capex is not treated like ordinary maintenance capex.`
          : `$${(settings.projectBacklogM / 1000).toFixed(1)}B project backlog. Growth capex is not treated like ordinary maintenance capex.`
      }] : []),
      ...(optionalityMultiplier !== 1 ? [{
        key: "platform-optionality",
        label: "Platform optionality",
        value: optionalityMultiplier,
        format: "multiple",
        description: "Explicit buy-side option value for businesses where current earnings do not fully reflect storage/autonomy/platform reinvestment."
      }] : [])
    ],
    scoreInputs: {
      modelRoute: "operating_company",
      profile: settings.profile,
      ttmRevenue,
      valuationRevenue,
      forwardScale,
      formulaForwardScale,
      forwardRevenueYears: settings.forwardRevenueYears || 0,
      revenueGuidanceM: revenueGuidance.annualGuidanceM,
      reportedRevenueGuidanceM: revenueGuidance.reportedAnnualGuidanceM,
      revenueGuidanceRejectedReason: revenueGuidance.rejectionReason,
      quarterlyRevenueGuidanceM: revenueGuidance.quarterlyGuidanceM,
      annualizedQuarterlyRevenueGuidanceM: revenueGuidance.annualizedQuarterlyGuidanceM,
      boundedAnnualizedQuarterlyRevenueGuidanceM: revenueGuidance.boundedAnnualizedQuarterlyGuidanceM,
      quarterlyRevenueGuidanceWeight: revenueGuidance.quarterlyGuidanceWeight,
      revenueGuidanceScope: revenueGuidance.scope,
      forwardRevenueSource: revenueGuidance.source,
      ttmNetIncome,
      earningsHistoryEligible,
      earningsEvidenceConfidence,
      requiredIndependentEarningsSamples: MIN_INDEPENDENT_EARNINGS_SAMPLES,
      reportedEarningsAnchor,
      reportedEarningsAnchorRejectionReason,
      reportedEarningsAnchorBeforeSparseCap: earningsAnchorAudit.beforeSparseCapM,
      reportedEarningsAfterTaxOperatingCap: earningsAnchorAudit.afterTaxOperatingCapM,
      sparseEarningsHistoryCap: earningsAnchorAudit.sparseHistoryCapM,
      historyNormalizedNetIncome,
      forwardGuidanceVisible: guidanceVisible,
      adjustedEpsGuidance,
      adjustedEpsGuidanceRange: settings.adjustedEpsGuidanceRange || null,
      adjustedEpsGuidanceYear: settings.adjustedEpsGuidanceYear || null,
      adjustedEpsGuidanceVisibleFrom: settings.adjustedEpsGuidanceVisibleFrom || null,
      guidedAdjustedNetIncome,
      marginBasedNetIncome,
      normalizedNetIncome,
      normalizedNetIncomeRejectionReason: normalizedNetIncomeAudit.rejectionReason,
      effectiveNormalizedNetMargin: effectiveNormalizedNetMargin != null ? effectiveNormalizedNetMargin * 100 : null,
      observedOperatingMargin: normalizedEarnings.observedOperatingMargin != null ? normalizedEarnings.observedOperatingMargin * 100 : null,
      observedNetMargin: normalizedEarnings.observedNetMargin != null ? normalizedEarnings.observedNetMargin * 100 : null,
      belowOperatingIncomeBurden: normalizedEarnings.belowOperatingIncomeBurden != null ? normalizedEarnings.belowOperatingIncomeBurden * 100 : null,
      ttmFreeCashFlow: ttmFcf,
      rawValuationFreeCashFlow: rawValuationFcf,
      valuationFreeCashFlow: valuationFcf,
      valuationFreeCashFlowCapMargin: valuationFreeCashFlowCapMargin(settings),
      fcfGuidanceM,
      reportedFcfGuidanceM: freeCashFlowGuidance.reportedAmountM,
      fcfGuidanceRejectedReason: freeCashFlowGuidance.rejectionReason,
      guidanceOperatingIncomeM,
      reportedGuidanceOperatingIncomeM: operatingIncomeGuidance.reportedAmountM,
      guidanceOperatingIncomeRejectedReason: operatingIncomeGuidance.rejectionReason,
      reportedGuidanceOperatingMargin: operatingMarginGuidance.reportedGuidanceMargin != null
        ? operatingMarginGuidance.reportedGuidanceMargin * 100
        : null,
      guidanceOperatingMargin: operatingMarginGuidance.adjustedGuidanceMargin != null
        ? operatingMarginGuidance.adjustedGuidanceMargin * 100
        : null,
      guidanceOperatingMarginWeight: operatingMarginGuidance.guidanceWeight,
      normalizedFreeCashFlow: fcf.normalizedFcf,
      cycleFreeCashFlow: fcf.cycleFcfM,
      reportedFreeCashFlowAnchor: fcf.reportedFcfAnchor,
      freeCashFlowEvidenceConfidence: fcf.fcfEvidenceConfidence,
      earningsMethodEvidenceConfidence: earningsMethodConfidence,
      freeCashFlowMethodEvidenceConfidence: fcfMethodConfidence,
      freeCashFlowNormalizationReason: fcf.rejectionReason || null,
      cycleSampleCount: ttm.cycle_sample_count,
      cycleEps: ttm.cycle_eps,
      cyclePositiveEpsSampleCount: ttm.cycle_positive_eps_sample_count,
      cyclePositiveFcfSampleCount: ttm.cycle_positive_fcf_sample_count,
      cycleOperatingMargin: ttm.cycle_operating_margin_pct,
      cycleNetMargin: ttm.cycle_net_margin_pct,
      cycleCfoMargin: ttm.cycle_cfo_margin_pct,
      cycleFcfMargin: ttm.cycle_fcf_margin_pct,
      maintenanceCapexM: fcf.maintenanceCapexM,
      growthCapexM: fcf.growthCapexM,
      capexIntensity: fcf.capexIntensityPct,
      revenueGrowth: growthPct,
      growthInput,
      operatingMargin: ttm.operating_margin_pct,
      normalizedMargin: normalizedMargin * 100,
      targetPE: pe,
      targetFCFYield: fcfYield,
      equityDcf,
      adjustedOperatingMargin: guidanceVisible ? settings.adjustedOperatingMarginPct : null,
      adjustedAfterTaxRoc: guidanceVisible ? settings.adjustedAfterTaxRocPct : null,
      projectBacklogM: guidanceVisible ? settings.projectBacklogM : null,
      saleOfGasBacklogM: guidanceVisible ? settings.saleOfGasBacklogM : null,
      cycleHaircut,
      optionalityMultiplier,
      bullCaseOptionalityMultiplier,
      methodWeights: {
        "normalized-earnings-power": earningsWeight,
        "fcfe-dcf": fcfWeight
      },
      requestedMethodWeights: Object.fromEntries(blended.components.map((component) => [component.key, component.requestedWeight])),
      sharesM
    },
    formula: `${Math.round(earningsWeight * 100)}% ${usesAdjustedEpsGuidance ? "adjusted EPS guidance power" : "normalized earnings power"} + ${Math.round(fcfWeight * 100)}% five-year FCFE DCF${optionalityMultiplier !== 1 ? `, then x${optionalityMultiplier.toFixed(2)} platform optionality` : ""}; no market price input`
  };
}

function buildBuySideValuationModel({ ticker, row, ttm, youtubeEvidence }) {
  const settings = profileSettings(ticker);
  if (["bank", "insurance", "card_network_lender", "credit_services", "capital_markets"].includes(settings.profile)) {
    return buildFinancialInstitutionModel({ ticker, row, ttm, settings });
  }
  if (["asset_manager", "insurance_broker", "managed_care", "payments_processor"].includes(settings.profile)) {
    return buildEarningsBusinessModel({ row, ttm, settings, youtubeEvidence });
  }
  return buildOperatingCompanyModel({ ticker, row, ttm, settings, youtubeEvidence });
}

export function buildValuationRows({
  ticker,
  trinityTicker,
  snapshot,
  companyModel,
  factsUrl,
  quarterlyRows,
  youtubeByPeriod,
  financialSource = {}
}) {
  quarterlyRows = prepareReviewedEconomicRows({ ticker, rows: quarterlyRows })
    .filter((row) => !row.reviewedNonModelableReason);
  const sourceType = financialSource.sourceType || "sec_companyfacts_quarterly_model";
  const annualSourceType = financialSource.annualSourceType || "sec_companyfacts_annual_model";
  const sourceQuality = financialSource.sourceQuality || "sec-companyfacts-quarterly-financials";
  const annualSourceQuality = financialSource.annualSourceQuality || "sec-companyfacts-annual-financials";
  const sourceName = financialSource.sourceName || "SEC CompanyFacts";
  const eventType = financialSource.eventType || "sec_quarterly_fundamental_model";
  const periodIdPrefix = financialSource.periodIdPrefix || "sec-companyfacts";
  const modelVersion = financialSource.modelVersion || null;
  const fallbackSharesM = finiteNumber(companyModel?.diluted_or_outstanding_shares_m);
  const priceHistory = Array.isArray(snapshot.priceHistory) ? snapshot.priceHistory : [];
  const rows = [];

  quarterlyRows.forEach((row, index) => {
    if (String(row.asOfDate).localeCompare(OUTPUT_START_DATE) < 0) return;
    const settings = profileSettings(ticker);
    const rowAnnualizationFactor = annualizationFactorForRow(row);
    const annualOnlyFinancialRow = isAnnualOnlyFinancialRow(row);
    const ttmRevenue = trailingOrAnnualValue(quarterlyRows, index, "revenue_m", rowAnnualizationFactor);
    const ttmGrossProfit = trailingOrAnnualValue(quarterlyRows, index, "gross_profit_m", rowAnnualizationFactor);
    const ttmOperatingIncome = trailingOrAnnualValue(quarterlyRows, index, "operating_income_m", rowAnnualizationFactor);
    const ttmNetIncome = trailingOrAnnualValue(quarterlyRows, index, "net_income_m", rowAnnualizationFactor);
    const ttmCfo = trailingOrAnnualValue(quarterlyRows, index, "cfo_m", rowAnnualizationFactor);
    const ttmCapex = trailingOrAnnualValue(quarterlyRows, index, "capex_m", rowAnnualizationFactor);
    const directlyReportedTtmFcf = trailingOrAnnualValue(
      quarterlyRows,
      index,
      "fcf_after_capex_m",
      rowAnnualizationFactor
    );
    const ttmFcf = directlyReportedTtmFcf ?? (
      ttmCfo != null && ttmCapex != null ? ttmCfo - ttmCapex : null
    );
    const trailingMetricBasis = Object.fromEntries([
      "revenue_m",
      "gross_profit_m",
      "operating_income_m",
      "net_income_m",
      "cfo_m",
      "capex_m",
      "fcf_after_capex_m"
    ].map((key) => [
      key,
      resolveTrailingFinancialValue(quarterlyRows, index, key, rowAnnualizationFactor)?.source || "unavailable"
    ]));
    const ttmEquity = latestKnownValue(quarterlyRows, index, "equity_m");
    const ttmAssets = latestKnownValue(quarterlyRows, index, "assets_m");
    const ttmCash = latestKnownValue(quarterlyRows, index, "cash_m");
    const ttmDebt = latestKnownValue(quarterlyRows, index, "debt_m");
    const ttmCryptoFairValue = latestKnownValue(quarterlyRows, index, "crypto_asset_fair_value_m");
    const ttmCryptoCost = latestKnownValue(quarterlyRows, index, "crypto_asset_cost_m");
    const ttmCryptoUnits = latestKnownValue(quarterlyRows, index, "crypto_asset_units");
    const shareOverride = SHARE_COUNT_OVERRIDES[ticker];
    const sharesM = finiteNumber(row.shares_m) ??
      latestKnownValueWithin(quarterlyRows, index, "shares_m", 8) ??
      fallbackSharesM ??
      finiteNumber(shareOverride?.sharesM);
    if (!(sharesM > 0)) return;

    const cycleContext = cycleContextForRows(
      quarterlyRows,
      index,
      Math.max(
        4,
        settings.cycleNormalizationWindow || (settings.normalizeFcfAcrossCycle ? 16 : settings.normalizedGrowthWindow || 8)
      )
    );
    const ttm = {
      revenue_m: ttmRevenue,
      gross_profit_m: ttmGrossProfit,
      operating_income_m: ttmOperatingIncome,
      net_income_m: ttmNetIncome,
      cfo_m: ttmCfo,
      capex_m: ttmCapex,
      shares_m: sharesM,
      equity_m: ttmEquity,
      assets_m: ttmAssets,
      cash_m: ttmCash,
      debt_m: ttmDebt,
      crypto_asset_fair_value_m: ttmCryptoFairValue,
      crypto_asset_cost_m: ttmCryptoCost,
      crypto_asset_units: ttmCryptoUnits,
      fcf_after_capex_m: ttmFcf,
      ...(row.reviewedEconomicInput ? {
        reported_fcf_after_capex_m: row.reviewedEconomicInput.ttm.reportedFcfM,
        reported_operating_financials: row.pitTrailingTwelveMonths.reported_operating_financials,
        reported_balance_financials: row.pitTrailingTwelveMonths.reported_balance_financials,
        economicCashFlowConvention: row.reviewedEconomicInput.ttm.convention
      } : {}),
      gross_margin_pct: margin(ttmGrossProfit, ttmRevenue),
      operating_margin_pct: margin(ttmOperatingIncome, ttmRevenue),
      net_margin_pct: margin(ttmNetIncome, ttmRevenue),
      fcf_margin_pct: margin(ttmFcf, ttmRevenue),
      capex_intensity_pct: margin(ttmCapex, ttmRevenue),
      cycle_sample_count: cycleContext.sampleCount,
      cycle_operating_margin_pct: cycleContext.operatingMarginPct,
      cycle_net_margin_pct: cycleContext.netMarginPct,
      cycle_cfo_margin_pct: cycleContext.cfoMarginPct,
      cycle_fcf_margin_pct: cycleContext.fcfMarginPct,
      cycle_roe_pct: cycleContext.roePct,
      cycle_eps: cycleContext.eps,
      cycle_sparse_eps: cycleContext.sparseEps,
      cycle_positive_eps_sample_count: cycleContext.positiveEpsSampleCount,
      cycle_positive_fcf_sample_count: cycleContext.positiveFcfSampleCount,
      cycle_below_operating_burden_pct: cycleContext.belowOperatingBurdenPct
    };
    const normalizedGrowthWindow = settings.normalizedGrowthWindow ?? 8;
    const normalizedGrowthStart = Math.max(0, index - normalizedGrowthWindow + 1);
    const normalizedGrowthSampleCount = quarterlyRows
      .slice(normalizedGrowthStart, index + 1)
      .filter((candidate) => finiteNumber(candidate.revenue_growth_pct) != null)
      .length;
    const normalizedRevenueGrowthPct = normalizedRevenueGrowthForRows(
      quarterlyRows,
      index,
      normalizedGrowthWindow
    );
    const pricePoint = pricePointAtOrBefore(priceHistory, row.asOfDate);
    const priceAtDate = finiteNumber(pricePoint?.close);
    const youtubeEvidence = Object.hasOwn(row, "pitGuidance")
      ? row.pitGuidance
      : youtubeByPeriod.get(`${ticker}::Q${row.fiscalQuarter.replace("Q", "")}${row.fiscalYear}`) ||
        youtubeByPeriod.get(`${trinityTicker}::Q${row.fiscalQuarter.replace("Q", "")}${row.fiscalYear}`) ||
        null;
    const modelRow = {
      ...row,
      normalized_revenue_growth_pct: normalizedRevenueGrowthPct,
      normalized_revenue_growth_window: normalizedGrowthWindow,
      normalized_revenue_growth_sample_count: normalizedGrowthSampleCount
    };
    const model = applyReviewedEquityClaims(
      buildBuySideValuationModel({ ticker, row: modelRow, ttm, youtubeEvidence }),
      row.reviewedEconomicInput, sharesM
    );
    if (!model || !(model.fairValue > 0)) return;
    const fairValue = model.fairValue;
    const targetPrice3Y = model.targetPrice3Y;

    rows.push({
      periodId: `${periodIdPrefix}-${ticker.toLowerCase()}-fy${row.fiscalYear}-${row.fiscalQuarter.toLowerCase()}`,
      runCreatedAt: new Date().toISOString(),
      label: row.label,
      asOfDate: row.asOfDate,
      fiscalYear: row.fiscalYear,
      fiscalQuarter: row.fiscalQuarter,
      eventType,
      sourceType: annualOnlyFinancialRow ? annualSourceType : sourceType,
      sourceUrl: factsUrl,
      currentPrice: priceAtDate,
      fairValue,
      upsideDownside: priceAtDate && priceAtDate > 0 ? fairValue / priceAtDate - 1 : null,
      targetPrice3Y,
      expectedReturn3Y: priceAtDate && priceAtDate > 0 ? (targetPrice3Y / priceAtDate) ** (1 / 3) - 1 : null,
      method: `Buy-side ${settings.label}: ${model.method}`,
      methodOutputs: model.methodOutputs,
      warnings: [],
      priceDate: pricePoint?.date || row.asOfDate,
      priceAtDate,
      dataSnapshot: {
        sourceType: annualOnlyFinancialRow ? annualSourceType : sourceType,
        sourceQuality: annualOnlyFinancialRow ? annualSourceQuality : sourceQuality,
        modelVersion,
        sourceMaxAsOfDate: row.asOfDate,
        selectedFinancialPeriod: {
          id: `${ticker}-${row.fiscalYear}-${row.fiscalQuarter}`,
          periodId: row.label,
          asOfDate: row.asOfDate,
          periodEndDate: row.periodEndDate,
          sourceType: sourceName,
          url: factsUrl
        },
        financialPeriodCount: 1,
        segmentFinancialCount: 0,
        guidanceCandidateCount: youtubeEvidence?.guidanceMetricCount || 0,
        transcriptCandidateCount: youtubeEvidence?.metricCount || 0,
        latestAnnualizedRevenue: ttmRevenue,
        latestAnnualizedOperatingIncome: ttmOperatingIncome,
        fiscalFinancials: {
          revenue_m: row.revenue_m,
          revenue_growth_pct: row.revenue_growth_pct,
          normalized_revenue_growth_pct: normalizedRevenueGrowthPct,
          normalized_revenue_growth_window: normalizedGrowthWindow,
          normalized_revenue_growth_sample_count: normalizedGrowthSampleCount,
          gross_profit_m: row.gross_profit_m,
          gross_margin_pct: row.gross_margin_pct,
          operating_income_m: row.operating_income_m,
          operating_margin_pct: row.operating_margin_pct,
          net_income_m: row.net_income_m,
          cfo_m: row.cfo_m,
          capex_m: row.capex_m,
          shares_m: row.shares_m,
          equity_m: row.equity_m,
          assets_m: row.assets_m,
          cash_m: row.cash_m,
          debt_m: row.debt_m,
          crypto_asset_fair_value_m: row.crypto_asset_fair_value_m,
          crypto_asset_cost_m: row.crypto_asset_cost_m,
          crypto_asset_units: row.crypto_asset_units,
          fcf_after_capex_m: row.fcf_after_capex_m,
          ...(row.reviewedEconomicInput ? {
            reported_fcf_after_capex_m: row.reviewedEconomicInput.quarter.reportedFcfM,
            reported_operating_financials: row.reported_operating_financials,
            reported_balance_financials: row.reported_balance_financials,
            reported_revenue_growth_pct: row.reported_revenue_growth_pct,
            economicCashFlowConvention: row.reviewedEconomicInput.quarter.convention
          } : {})
        },
        trailingTwelveMonths: ttm,
        trailingMetricBasis,
        annualizedFromSinglePeriod: Object.values(trailingMetricBasis).includes("single_period_annualized")
          ? rowAnnualizationFactor
          : null,
        asOfAssumptionOverrideKeys: [
          ...Object.keys(model.scoreInputs || {})
        ],
        asOfPriceSource: pricePoint ? {
          priceDate: pricePoint.date,
          source: pricePoint.source || "local daily close fallback"
        } : null,
        valuationSemantics: {
          sourceType: annualOnlyFinancialRow ? annualSourceType : sourceType,
          modelVersion,
          priceExcludedFromFairValue: true,
          shareBasisPolicy: "Use the PIT period-end share input supplied for this reporting node: basic shares multiplied once by the provider share factor, with diluted or weighted shares used only as fallback. Source shares are already corporate-action comparable; later share-count changes never retroactively rescale historical fair value.",
          fairValueFormula: model.formula,
          scoreInputs: model.scoreInputs
        },
        financialSource: {
          name: sourceName,
          modelVersion,
          record: row.sourceRecord || null,
          trailingTwelveMonthsRecord: row.trailingTwelveMonthsSourceRecord || null,
          ...(row.reviewedEconomicInput ? {
            trailingTwelveMonthsSources: row.pitTrailingTwelveMonths?.sources || {}
          } : {})
        },
        secCompanyFacts: {
          cik: companyModel.cik,
          company: companyModel.company || snapshot.name || ticker,
          url: factsUrl,
          periodEndDate: row.periodEndDate,
          sourceTags: row.sources,
          shareCountOverride: shareOverride || null
        },
        youtubeEarnings: youtubeEvidence,
        guidanceBoundary: row.pitGuidanceBoundary || null
      }
    });
  });

  return rows;
}

function parseTrinityPeriod(period, fallbackDate = null) {
  const text = String(period || "").toUpperCase();
  const qFirst = text.match(/Q([1-4])\s*(?:FY)?\s*(20\d{2})/);
  const fyFirst = text.match(/(?:FY)?\s*(20\d{2})\s*Q([1-4])/);
  const yearOnly = text.match(/\b(20\d{2})\b/);
  if (qFirst) return { fiscalYear: Number(qFirst[2]), fiscalQuarter: `Q${qFirst[1]}` };
  if (fyFirst) return { fiscalYear: Number(fyFirst[1]), fiscalQuarter: `Q${fyFirst[2]}` };
  if (yearOnly) return { fiscalYear: Number(yearOnly[1]), fiscalQuarter: "Q4" };
  if (fallbackDate) {
    const [year, month] = String(fallbackDate).split("-").map(Number);
    if (year && month) return { fiscalYear: year, fiscalQuarter: `Q${Math.max(1, Math.min(4, Math.ceil(month / 3)))}` };
  }
  return null;
}

function trinityAnnualReportDate(year) {
  return `${Number(year) + 1}-03-01`;
}

function metricFromMargin(revenueM, marginPctValue) {
  const revenue = finiteNumber(revenueM);
  const marginValue = finiteNumber(marginPctValue);
  return revenue != null && marginValue != null ? revenue * marginValue / 100 : null;
}

function annualizedTrinityMetric(value, multiplier) {
  const number = finiteNumber(value);
  return number == null ? null : number * multiplier;
}

function trinityAnnualizationMultiplier(row) {
  if (!row || row.sourceKind !== "quarter") return 1;
  const raw = row.raw || {};
  const text = `${raw.period || ""} ${raw.data_note || ""} ${raw.notes || ""} ${raw.data_type || ""}`.toLowerCase();
  if (text.includes("fy2025 total") || text.includes("annual") || text.includes("full year") || /fy20\d{2}\s*\//i.test(String(raw.period || ""))) {
    return 1;
  }
  return 4;
}

function buildTrinityFinancialRows(companyModel) {
  const rows = [];
  for (const annual of companyModel?.annual_financials || []) {
    const parsed = parseTrinityPeriod(annual.period);
    if (!parsed?.fiscalYear) continue;
    rows.push({
      sourceKind: "annual",
      fiscalYear: parsed.fiscalYear,
      fiscalQuarter: "Q4",
      label: `FY${parsed.fiscalYear}`,
      asOfDate: trinityAnnualReportDate(parsed.fiscalYear),
      periodEndDate: `${parsed.fiscalYear}-12-31`,
      sourceUrl: annual.source_url || companyModel.sources?.[0]?.url || null,
      raw: annual
    });
  }

  if (companyModel?.latest_quarter?.revenue_m != null) {
    const latest = companyModel.latest_quarter;
    const parsed = parseTrinityPeriod(latest.period, latest.end_date);
    if (parsed?.fiscalYear && parsed?.fiscalQuarter) {
      rows.push({
        sourceKind: "quarter",
        fiscalYear: parsed.fiscalYear,
        fiscalQuarter: parsed.fiscalQuarter,
        label: `FY${parsed.fiscalYear} ${parsed.fiscalQuarter}`,
        asOfDate: addDays(latest.end_date, 30) || latest.end_date || trinityAnnualReportDate(parsed.fiscalYear),
        periodEndDate: latest.end_date || null,
        sourceUrl: latest.source_url || companyModel.sources?.[0]?.url || null,
        raw: latest
      });
    }
  }

  return rows
    .filter((row) => row.asOfDate && String(row.asOfDate).localeCompare(OUTPUT_START_DATE) >= 0)
    .sort((left, right) => String(left.asOfDate).localeCompare(String(right.asOfDate)));
}

function buildTrinityValuationRows({ ticker, trinityTicker, snapshot, companyModel, youtubeByPeriod }) {
  const priceHistory = Array.isArray(snapshot.priceHistory) ? snapshot.priceHistory : [];
  const sharesM = finiteNumber(companyModel?.diluted_or_outstanding_shares_m);
  if (!(sharesM > 0)) return [];
  const settings = profileSettings(ticker);
  const rows = [];

  for (const row of buildTrinityFinancialRows(companyModel)) {
    const multiplier = trinityAnnualizationMultiplier(row);
    const raw = row.raw || {};
    const revenueM = annualizedTrinityMetric(raw.revenue_m, multiplier);
    const grossProfitM = annualizedTrinityMetric(raw.gross_profit_m, multiplier) ??
      metricFromMargin(revenueM, raw.gross_margin_pct);
    const operatingIncomeM = annualizedTrinityMetric(raw.operating_income_m, multiplier) ??
      metricFromMargin(revenueM, raw.operating_margin_pct);
    const netIncomeM = annualizedTrinityMetric(raw.net_income_m, multiplier);
    const cfoM = annualizedTrinityMetric(raw.cfo_m, multiplier);
    const capexM = annualizedTrinityMetric(raw.capex_m, multiplier);
    const fcfM = annualizedTrinityMetric(raw.fcf_after_capex_m, multiplier) ??
      (cfoM != null && capexM != null ? cfoM - capexM : null);
    const ttm = {
      revenue_m: revenueM,
      gross_profit_m: grossProfitM,
      operating_income_m: operatingIncomeM,
      net_income_m: netIncomeM,
      cfo_m: cfoM,
      capex_m: capexM,
      shares_m: sharesM,
      cash_m: annualizedTrinityMetric(raw.cash_m, 1),
      debt_m: annualizedTrinityMetric(raw.debt_m, 1),
      fcf_after_capex_m: fcfM,
      gross_margin_pct: raw.gross_margin_pct ?? margin(grossProfitM, revenueM),
      operating_margin_pct: raw.operating_margin_pct ?? margin(operatingIncomeM, revenueM),
      net_margin_pct: margin(netIncomeM, revenueM),
      fcf_margin_pct: margin(fcfM, revenueM),
      capex_intensity_pct: margin(capexM, revenueM)
    };
    const youtubeEvidence = youtubeByPeriod.get(`${ticker}::Q${row.fiscalQuarter.replace("Q", "")}${row.fiscalYear}`) ||
      youtubeByPeriod.get(`${trinityTicker}::Q${row.fiscalQuarter.replace("Q", "")}${row.fiscalYear}`) ||
      null;
    const model = buildBuySideValuationModel({
      ticker,
      row: {
        ...row,
        revenue_m: revenueM,
        revenue_growth_pct: raw.revenue_growth_pct,
        gross_margin_pct: ttm.gross_margin_pct,
        operating_margin_pct: ttm.operating_margin_pct
      },
      ttm,
      youtubeEvidence
    });
    if (!model || !(model.fairValue > 0)) continue;
    const pricePoint = pricePointAtOrBefore(priceHistory, row.asOfDate);
    const priceAtDate = finiteNumber(pricePoint?.close);
    rows.push({
      periodId: `trinity-financial-${ticker.toLowerCase()}-fy${row.fiscalYear}-${row.fiscalQuarter.toLowerCase()}-${row.sourceKind}`,
      runCreatedAt: new Date().toISOString(),
      label: row.label,
      asOfDate: row.asOfDate,
      fiscalYear: row.fiscalYear,
      fiscalQuarter: row.fiscalQuarter,
      eventType: "trinity_official_financial_model",
      sourceType: "trinity_official_financial_model",
      sourceUrl: row.sourceUrl,
      currentPrice: priceAtDate,
      fairValue: model.fairValue,
      upsideDownside: priceAtDate && priceAtDate > 0 ? model.fairValue / priceAtDate - 1 : null,
      targetPrice3Y: model.targetPrice3Y,
      expectedReturn3Y: priceAtDate && model.targetPrice3Y > 0 ? (model.targetPrice3Y / priceAtDate) ** (1 / 3) - 1 : null,
      method: `Buy-side ${settings.label}: ${model.method}`,
      methodOutputs: model.methodOutputs,
      warnings: row.sourceKind === "quarter"
        ? ["Latest-quarter Trinity row annualizes quarter metrics when full TTM history is unavailable."]
        : [],
      priceDate: pricePoint?.date || row.asOfDate,
      priceAtDate,
      dataSnapshot: {
        sourceType: "trinity_official_financial_model",
        sourceQuality: "ai-trinity-official-ir-financials",
        sourceMaxAsOfDate: row.asOfDate,
        selectedFinancialPeriod: {
          id: `${ticker}-${row.fiscalYear}-${row.fiscalQuarter}-${row.sourceKind}`,
          periodId: row.label,
          asOfDate: row.asOfDate,
          periodEndDate: row.periodEndDate,
          sourceType: row.sourceKind === "annual" ? "AI Trinity annual financials" : "AI Trinity latest-quarter financials",
          url: row.sourceUrl
        },
        financialPeriodCount: 1,
        segmentFinancialCount: 0,
        guidanceCandidateCount: youtubeEvidence?.guidanceMetricCount || 0,
        transcriptCandidateCount: youtubeEvidence?.metricCount || 0,
        latestAnnualizedRevenue: revenueM,
        latestAnnualizedOperatingIncome: operatingIncomeM,
        fiscalFinancials: {
          sourceKind: row.sourceKind,
          revenue_m: raw.revenue_m,
          revenue_growth_pct: raw.revenue_growth_pct,
          gross_profit_m: raw.gross_profit_m,
          gross_margin_pct: raw.gross_margin_pct,
          operating_income_m: raw.operating_income_m,
          operating_margin_pct: raw.operating_margin_pct,
          net_income_m: raw.net_income_m,
          cfo_m: raw.cfo_m,
          capex_m: raw.capex_m,
          shares_m: sharesM,
          cash_m: raw.cash_m,
          debt_m: raw.debt_m,
          fcf_after_capex_m: raw.fcf_after_capex_m
        },
        trailingTwelveMonths: ttm,
        asOfAssumptionOverrideKeys: Object.keys(model.scoreInputs || {}),
        asOfPriceSource: pricePoint ? {
          priceDate: pricePoint.date,
          source: pricePoint.source || "local daily close fallback"
        } : null,
        valuationSemantics: {
          sourceType: "trinity_official_financial_model",
          priceExcludedFromFairValue: true,
          shareBasisPolicy: "Use the PIT period-end share input supplied for this reporting node: basic shares multiplied once by the provider share factor, with diluted or weighted shares used only as fallback. Later share-count changes never retroactively rescale historical fair value.",
          fairValueFormula: model.formula,
          scoreInputs: model.scoreInputs
        },
        trinityModel: {
          sourcePath: TRINITY_MODEL_DIR,
          ticker: trinityTicker,
          company: companyModel.company || snapshot.name || ticker,
          latestReportedPeriod: companyModel.latest_reported_period,
          category: companyModel.category,
          sourceUrl: row.sourceUrl
        },
        youtubeEarnings: youtubeEvidence
      }
    });
  }

  return rows;
}

function formatPct(value) {
  const number = finiteNumber(value);
  return number == null ? "-" : `${number.toFixed(1)}%`;
}

function normalizePeriod(period) {
  const value = String(period || "").trim().toUpperCase().replace(/\s+/g, "");
  const leadingQuarter = value.match(/^Q([1-4])(?:FY)?(20\d{2})$/);
  if (leadingQuarter) return `Q${leadingQuarter[1]}${leadingQuarter[2]}`;
  const trailingQuarter = value.match(/^(20\d{2})Q([1-4])$/);
  if (trailingQuarter) return `Q${trailingQuarter[2]}${trailingQuarter[1]}`;
  return value;
}

function median(values) {
  const clean = values.map(finiteNumber).filter((value) => value != null).sort((left, right) => left - right);
  if (!clean.length) return null;
  const middle = Math.floor(clean.length / 2);
  return clean.length % 2 ? clean[middle] : (clean[middle - 1] + clean[middle]) / 2;
}

function metricValues(metrics, names, field = "growth_yoy") {
  const wanted = new Set(names);
  return metrics
    .filter((metric) => wanted.has(metric.metric_name))
    .map((metric) => metric[field])
    .filter((value) => finiteNumber(value) != null);
}

function metricText(metric) {
  return `${metric?.metric_name || ""} ${metric?.value_text || ""} ${metric?.excerpt || ""}`.toLowerCase();
}

function metricEvidenceText(metric) {
  return `${metric?.value_text || ""} ${metric?.excerpt || ""}`.toLowerCase();
}

function metricGuidanceScope(metric) {
  const payload = parseJson(metric?.payload_json, {});
  const nestedPayload = payload?.payload_json && typeof payload.payload_json === "object"
    ? payload.payload_json
    : {};
  return String(
    metric?.guidance_scope ||
    payload?.guidance_scope ||
    nestedPayload?.guidance_scope ||
    ""
  ).trim().toLowerCase();
}

function metricGuidanceSubject(metric) {
  const payload = parseJson(metric?.payload_json, {});
  const nestedPayload = payload?.payload_json && typeof payload.payload_json === "object"
    ? payload.payload_json
    : {};
  return String(
    metric?.guidance_subject ||
    payload?.guidance_subject ||
    nestedPayload?.guidance_subject ||
    ""
  ).trim().toLowerCase();
}

// Numerical PIT inputs require a dated, typed source contract. Research
// retention and the legacy untyped display digest are deliberately separate.
// This producer gate does not import or call the independent release auditor.
function sourceGuidanceConsumptionDecision(metric, { requireTypedSource = false } = {}) {
  if (!metric?.source_type) return requireTypedSource
    ? { accepted: false, reason: "pit_source_identity_missing" }
    : { accepted: true, reason: "legacy_untyped_research_digest" };
  if (!["downloaded_online_earnings_transcript", "official_issuer_sec_filing", "official_issuer_results_release"].includes(metric.source_type)) {
    return { accepted: false, reason: "pit_source_identity_unknown" };
  }
  const payload = parseJson(metric.payload_json, {});
  const evidence = String(metric.evidence_excerpt || metric.value_text || metric.excerpt || "").trim();
  const reject = (reason) => ({ accepted: false, reason });
  if (metric.actual_or_guidance !== "guidance") return reject("source_not_designated_forward");
  if (metric.quality_status !== "clear") return reject("source_quality_not_clear");
  if (metric.model_exclusion_reason || payload.model_exclusion_reason || payload.extraction_review_required) {
    return reject("source_has_unresolved_or_excluded_economics");
  }
  const scope = metricGuidanceScope(metric);
  if (!["full_year", "annual", "fiscal_year", "quarter"].includes(scope)) {
    return reject("source_target_period_unresolved");
  }
  if (!["company_total", "company_total_or_unspecified"].includes(metricGuidanceSubject(metric))) {
    return reject("source_is_not_a_company_total_target");
  }
  const ownerPattern = {
    revenue_guidance: /\b(?:revenues?|sales|total income)\b/gi,
    revenue_growth: /\b(?:revenues?|sales|total income)\b/gi,
    operating_income_guidance: /\b(?:operating (?:income|profit)|income from operations|(?:adjusted\s+)?ebit)\b/gi,
    free_cash_flow_guidance: /\b(?:free cash flow|fcf)\b/gi
  }[metric.metric_name];
  // These are the fields consumed by the numerical valuation routes. Other
  // typed research metrics remain available but cannot rescue a money target.
  if (!ownerPattern) return { accepted: true, reason: "non_route_display_metric" };
  const matches = [...evidence.matchAll(ownerPattern)];
  const position = metric.metric_position ?? payload.metric_position;
  const owner = Number.isInteger(position)
    ? matches.find((match) => match.index === position)
    : matches.length === 1 ? matches[0] : null;
  if (!owner) return reject("source_metric_owner_unresolved");
  const ownerIndex = matches.indexOf(owner);
  const prefix = evidence.slice(0, owner.index);
  const boundaries = [...prefix.matchAll(/[.;](?=\s+[A-Z]|$)|[;\n]/g)];
  const start = Math.max(boundaries.at(-1)?.index + 1 || 0, owner.index - 300);
  const end = matches[ownerIndex + 1]?.index ?? evidence.length;
  const owned = evidence.slice(start, end);
  const after = evidence.slice(owner.index + owner[0].length, end);
  const before = evidence.slice(start, owner.index);
  // The word revenue inside an expense-to-sales ratio is a denominator, not
  // a forecast owner. A neighboring interest/tax amount cannot rescue it.
  if (["revenue_guidance", "revenue_growth"].includes(metric.metric_name) &&
      (/%\s+of\s+(?:(?:total|net)\s+)?$/i.test(before) ||
       /\b(?:excluding|excludes|excluded)\s+[^,.;]{0,45}$/i.test(before) ||
       /\b(?:client funds interest|Americas|EMEA|APAC|fee|travel)\s*$/i.test(before))) {
    return reject("source_owned_metric_is_subset_or_ratio_denominator");
  }
  if (["revenue_guidance", "revenue_growth"].includes(metric.metric_name) &&
      (/\b(?:drag|headwind|tailwind|impact|contribution)\s+(?:on|to|in)\s*$/i.test(before) ||
       /\bbrand\s*$/i.test(before) ||
       /^\s+for\s+(?:(?:the|our)\s+)?[A-Z][A-Za-z0-9-]*(?:\s+[A-Z][A-Za-z0-9-]*)?\s+business\b/.test(after) ||
       /\b(?:run[- ]rate|annualized run rate|cumulative|incremental contribution|cost savings?)\b/i.test(owned))) {
    return reject("source_owned_metric_is_component_or_non_periodic");
  }
  if (metric.metric_name === "operating_income_guidance" &&
      (/^\s+(?:charges?|headwinds?|impacts?|drags?|declines?)\b/i.test(after) ||
       /\b(?:drag|impact|headwind|charges?|negative impact)\b[^.;]{0,80}$/i.test(before) ||
       /^\s+(?:to\s+be\s+)?down\b[^;]{0,80}\bfrom\b/i.test(after))) {
    return reject("source_owned_metric_is_driver_not_income_level");
  }
  if (/\b(?:segment|division|commercial|government|international|subscription|product|services?|software|data[ -]center|cloud|advertising|digital|regional|domestic|consumer|enterprise|china|acquisition|acquired|same[- ]store|comparable(?:[- ]store)?)\s*$/i.test(before) ||
      /^(?:\s+(?:for|of|from|in)\s+(?:the\s+|our\s+)?[^.;]{0,55}\b(?:segment|division|business unit|business area))\b/i.test(after)) {
    return reject("source_owned_quote_is_segment_or_subset");
  }
  const quarter = /\bq[1-4]\b|\b(?:first|second|third|fourth|next|current|this)\s+quarter\b|\bfor the quarter\b/i;
  const annual = /\b(?:full[- ]year|fiscal year|fiscal\s+(?:20)?\d{2}|annual|this year|for the year|fy\s*(?:20)?\d{2}|(?:guidance|outlook|for)\s+(?:fiscal\s+)?20\d{2}|20\d{2}\s+(?:(?:adjusted|net|total|revenue|sales|operating|income)\s+){0,5}(?:guidance|outlook))\b/i;
  const previousSentence = evidence.slice(0, start).trim().replace(/[.;]\s*$/, "").split(/[.;](?=\s+[A-Z]|$)/).at(-1) || "";
  const heading = /\b(?:guidance|outlook|forecast|expect(?:s)?|reaffirm|reiterat(?:ed|e))\b/i.test(previousSentence) ? previousSentence : "";
  const periodText = `${heading}. ${owned}`;
  const namedQuarter = [...periodText.matchAll(/\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+quarter\b/gi)].some((marker) =>
    !/\b(?:compared (?:with|to)|versus|prior|previous|last)\b[^.;]{0,55}$/i.test(periodText.slice(Math.max(0, marker.index - 70), marker.index)));
  const currentAnnualTable = /\bYear ended 31 December 20\d{2}\s*\|\s*(?:Updated )?guidance\b/i.test(periodText);
  if (!(scope === "quarter" ? quarter.test(periodText) || namedQuarter : annual.test(periodText) || currentAnnualTable)) {
    return reject("source_target_period_not_supported_by_owned_quote");
  }
  // A current revision can refer to a previously issued target. A historical
  // comparison cannot gain forward status from a different owner's outlook.
  const forward = /\b(?:guidance|outlook|expect(?:s)?|forecast(?:s)?|anticipat(?:e|es)|reaffirm(?:s|ed|ing)?|maintain(?:s|ed|ing)?|rais(?:e|ed|ing)|lower(?:ed|ing)?|updat(?:e|ed|ing)|reiterat(?:e|ed|ing)|will|plan(?:s)?|target(?:s)?)\b|\b(?:is|are) expected\s+(?:to|at|between)\b/i.test(owned) ||
    Boolean(heading) && /\b(?:guidance|outlook)\b/i.test(heading) && !/\b(?:prior|previous|historical)\b/i.test(heading);
  const historicalOwner = /^\s+(?:was|were|totaled|totalled|exceeded|reached|grew|increased|decreased|declined|came in at)\b/i.test(after) ||
    /\b(?:delivered|achieved|generated|recorded)\s+(?:(?:record|net|total|strong)\s+)*$/i.test(before) ||
    /\b(?:we|the company|the group|they)\s+reported\s+(?:(?:record|net|total|strong)\s+)*$/i.test(before) ||
    /\breported\s+\$[\d.,]+\s+(?:billion|million)\s+in\s*$/i.test(before) ||
    /\b(?:delivering|delivered)\s+(?:(?:strong|operational|organic|net|total)\s+)*$/i.test(before) && !/\b(?:expect|will|forecast|anticipate)\b/i.test(before) ||
    /\bresults\s+that\s+included\s*$/i.test(before) ||
    /\b(?:the company|we)\s+closed\s+the\s+(?:(?:first|second|third|fourth)\s+quarter|q[1-4])\s+with\s+(?:record\s+)?$/i.test(before);
  // A beat of a previously issued range is an actual (or a beat amount), not
  // the next forecast. Keep an explicit current forecast that compares itself
  // with a prior range; do not let a different later owner supply that verb.
  const directCurrentTarget = /\b(?:expect(?:s)?|forecast(?:s)?|anticipat(?:e|es)|will|target(?:s)?)\b/i.test(before) ||
    /^\s+(?:is|are)\s+expected\b/i.test(after);
  const historicalBeat = !directCurrentTarget &&
    /\b(?:exceeded|exceeding|met|within|in line with)\b[^.;]{0,110}\b(?:guidance|target|expectations?)\b/i.test(owned);
  const pastGuidance = /\b(?:previous|prior|original)\b[^.;]{0,45}\b(?:guidance|outlook)\b|\b(?:we|management)\s+(?:originally\s+)?(?:expected|anticipated|projected)\b/i.test(owned);
  const currentRevision = /\b(?:now|current|updated|raising|raised|revised|reaffirm(?:ing|ed)?|maintain(?:ing|ed)?)\b/i.test(owned) ||
    directCurrentTarget && !/\b(?:previous|prior|original|had expected)\b/i.test(before) &&
    /\b(?:compared (?:with|to)|versus|exceeding)\s+(?:(?:our|the)\s+)?(?:previous|prior|original)\s+guidance\b/i.test(after);
  if (!forward || historicalOwner || historicalBeat || pastGuidance && !currentRevision) return reject("source_owned_quote_is_not_forward");
  return { accepted: true, reason: "owned_forward_periodic_company_target" };
}

function historicalFactMislabeledGuidance(metric) {
  if (metric?.actual_or_guidance !== "guidance") return false;
  const owner = {
    revenue_guidance: /\b(?:revenues?|sales)\b/gi,
    revenue_growth: /\b(?:revenues?|sales)\b/gi,
    operating_income_guidance: /\b(?:operating (?:income|profit)|income from operations|ebit)\b/gi,
    free_cash_flow_guidance: /\b(?:free cash flow|fcf)\b/gi,
    operating_margin: /\boperating margin\b/gi,
    gross_margin: /\bgross margin\b/gi
  }[metric?.metric_name];
  if (!owner) return false;
  const text = String(metric.value_text || metric.excerpt || "");
  const payload = parseJson(metric.payload_json, {});
  const position = metric.metric_position ?? payload.metric_position;
  const matches = [...text.matchAll(owner)];
  // Use the extractor's owned metric position only when the original text
  // actually contains that owner there. No position means the first owner.
  const match = Number.isInteger(position) ? matches.find((item) => item.index === position) : matches[0];
  if (!match) return false;
  const afterOwner = text.slice(match.index + match[0].length);
  return /^\s+(?:was|were|totaled|totalled|exceeded|reached|grew|increased|decreased|declined|came in at)\b/i.test(afterOwner);
}

const REVENUE_SUBSET_PATTERN = /\b(?:commercial|government|international|segment|services?|subscription|product|software|semiconductor|data[ -]center|cloud|advertising|digital|licen[cs]e|maintenance|aftermarket|consumer|enterprise|domestic|overseas|regional|systemwide|same[- ]store|comparable[- ]store|professional services?|installed base management|systems?|other|packaging|china|dram|foundry(?: logic)?)\s+(?:revenue|revenues|sales)\b|\brevenue from (?:these|the) contracts\b|\bannual recurring revenue\b|\barr\b|\b(?:asset|property|land|home|portfolio) sales\b|\b(?:addressable|global|industry|nand|semiconductor) market\b[^.]{0,100}\brevenue\b|\bmarket (?:revenue|revenues|sales)\b|\b(?:revenue|sales) (?:stream|opportunity|pool)\b|\b(?:annualized )?(?:revenue|sales) run rate\b/i;

function isRevenueSubsetMetric(metric) {
  // A medium-term CAGR is not the next reporting year's growth rate. Keep
  // explicit long-horizon targets as research even if an older extraction
  // incorrectly marked the company subject as usable.
  if (isMultiYearGuidanceMetric(metric)) return true;
  const subject = metricGuidanceSubject(metric);
  if (["segment_or_subset", "non_company_or_non_periodic"].includes(subject)) return true;
  if (["company_total", "company_total_or_unspecified"].includes(subject)) return false;
  return REVENUE_SUBSET_PATTERN.test(metricEvidenceText(metric));
}

function isMultiYearGuidanceMetric(metric) {
  const scope = metricGuidanceScope(metric);
  if (["multi_year", "multi_year_target", "long_term", "medium_term", "non_periodic"].includes(scope)) return true;
  const evidence = metricOwnedSelectionText(metric);
  return /\b(?:compounded? annual growth|cagr)\b[^.;]{0,140}\b(?:from\s+)?20\d{2}\s+(?:to|through|[-–])\s+20\d{2}\b/i.test(evidence) ||
    /\b(?:long[- ]term|medium[- ]term|multi[- ]year)\b[^.;]{0,60}\b(?:targets?|goals?|objectives?|ambitions?)\b/i.test(evidence);
}

// Selection exclusions apply to the original owner, not a later metric in
// the same management paragraph. Keep legacy untyped display behavior intact.
function metricOwnedSelectionText(metric) {
  const evidence = String(metric.evidence_excerpt || metric.value_text || metric.excerpt || "");
  if (!metric.source_type) return metricEvidenceText(metric);
  const position = metric.metric_position ?? parseJson(metric.payload_json, {}).metric_position;
  if (!Number.isInteger(position)) return evidence;
  const ownerPatterns = /\b(?:revenues?|sales|operating (?:income|profit|cash flow)|income from operations|(?:adjusted\s+)?ebit(?:da)?|free cash flow|fcf|net income|capex|capital expenditures?|earnings per share|eps)\b/gi;
  const matches = [...evidence.matchAll(ownerPatterns)];
  const owner = matches.find((m) => m.index === position);
  if (!owner) return evidence;
  const next = matches.find((m) => m.index > position);
  const prefix = evidence.slice(0, position);
  const boundary = [...prefix.matchAll(/[.;](?=\s+[A-Z]|$)|[;\n]/g)].at(-1);
  const previous = matches.filter((m) => m.index < position).at(-1);
  const start = Math.max(boundary ? boundary.index + 1 : 0, previous ? previous.index + previous[0].length : 0, position - 100);
  return evidence.slice(start, next?.index ?? evidence.length);
}

const NON_COMPANY_GUIDANCE_PATTERN = /\b(?:segment|division|business unit|business area)\b[^.]{0,100}\b(?:operating income|operating profit|free cash flow|fcf)\b|\b(?:operating income|operating profit|free cash flow|fcf)\b[^.]{0,100}\b(?:segment|division|business unit|business area)\b|\bfrom (?:our |the )?discontinued operations?\b|\b(?:cumulative|aggregate)\b[^.]{0,80}\b(?:cash flow|fcf)\b|\bfinancial capacity\b|\b(?:cost )?savings?\b|\b(?:increase|decrease|improve|reduce|lower|impact|change)\b[^.]{0,120}\b(?:operating income|operating profit|free cash flow|fcf)\b[^.]{0,35}\bby\b|\b(?:operating income|operating profit|free cash flow|fcf)\b[^.]{0,80}\b(?:increase|decrease|improve|reduce|lower|impact|change)\b[^.]{0,35}\bby\b/i;

function isNonCompanyGuidanceMetric(metric) {
  if (isMultiYearGuidanceMetric(metric)) return true;
  const subject = metricGuidanceSubject(metric);
  if (["segment_or_subset", "non_company_or_non_periodic"].includes(subject)) return true;
  if (["company_total", "company_total_or_unspecified"].includes(subject)) return false;
  const evidence = metricEvidenceText(metric);
  if (/\b(?:total|aggregate) company free cash flow\b|\benterprise (?:adjusted )?operating (?:income|profit)\b/i.test(evidence)) {
    return false;
  }
  return NON_COMPANY_GUIDANCE_PATTERN.test(evidence);
}

function deduplicateGuidanceMetrics(metrics) {
  const seen = new Set();
  return metrics.filter((metric) => {
    const key = JSON.stringify([
      metric?.actual_or_guidance || null,
      metric?.metric_name || null,
      finiteNumber(metric?.model_amount_m),
      finiteNumber(metric?.amount),
      metric?.unit || null,
      metric?.currency || null,
      finiteNumber(metric?.growth_yoy),
      finiteNumber(metric?.growth_qoq),
      finiteNumber(metric?.margin_pct),
      metricGuidanceScope(metric) || null,
      metricGuidanceSubject(metric) || null,
      metricEvidenceText(metric)
    ]);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

const GUIDANCE_METRIC_TEXT_PATTERNS = {
  revenue_guidance: /\b(?:revenue|revenues|sales)\b/gi,
  free_cash_flow_guidance: /\b(?:free cash flow|fcf)\b/gi,
  capex_guidance: /\b(?:capital expenditures?|capex)\b/gi,
  operating_income_guidance: /\b(?:operating income|income from operations|operating profit)\b/gi,
  backlog_guidance: /\b(?:backlog|bookings|remaining performance obligation|rpo|arr)\b/gi
};

export function guidancePlusMinusCenterM(value, metricName = null) {
  const text = String(value || "").replaceAll("Â±", " ±");
  const matches = [...text.matchAll(
    /(?:US\s*)?[$£€]?\s*(\d[\d,]*(?:\.\d+)?)\s*(billion|million|thousand|bn|mm|mn|m)\b\s*,?\s*(?:(?:Â\s*)?±|\+\/-|\+\s+or\s+-|plus\s+or\s+minus)/gi
  )];
  if (!matches.length) return null;
  let match = matches[0];
  const normalizedMetricName = String(metricName || "").toLowerCase();
  const metricPattern = GUIDANCE_METRIC_TEXT_PATTERNS[normalizedMetricName];
  if (normalizedMetricName && !metricPattern) return null;
  if (metricPattern) {
    const positions = Object.entries(GUIDANCE_METRIC_TEXT_PATTERNS).flatMap(([name, pattern]) =>
      [...text.matchAll(pattern)].map((item) => ({ name, index: item.index }))
    );
    const ranked = matches
      .map((candidate) => {
        const nearest = positions
          .map((position) => ({
            ...position,
            distance: Math.abs(position.index - candidate.index)
          }))
          .sort((left, right) => left.distance - right.distance)[0];
        return { candidate, nearest };
      })
      .filter(({ nearest }) => nearest?.name === normalizedMetricName)
      .map(({ candidate, nearest }) => ({ candidate, distance: nearest.distance }))
      .sort((left, right) => left.distance - right.distance);
    if (!ranked.length || ranked[0].distance > 120) return null;
    match = ranked[0].candidate;
  }
  const amount = Number(match[1].replaceAll(",", ""));
  if (!Number.isFinite(amount)) return null;
  const scale = match[2].toLowerCase();
  if (["billion", "bn"].includes(scale)) return amount * 1_000;
  if (scale === "thousand") return amount / 1_000;
  return amount;
}

function metricAmountM(metric) {
  const normalizedAmount = finiteNumber(metric?.model_amount_m);
  if (normalizedAmount != null) return normalizedAmount;
  const plusMinusCenter = guidancePlusMinusCenterM(metricEvidenceText(metric), metric?.metric_name);
  if (plusMinusCenter != null) return plusMinusCenter;
  const amount = finiteNumber(metric?.amount);
  if (amount == null) return null;
  const unit = String(metric?.unit || "").toLowerCase();
  const text = metricText(metric);
  if (unit.includes("billion")) return amount * 1_000;
  if (unit.includes("million")) return amount;
  if (unit.includes("thousand")) return amount / 1_000;
  if (/\bbillions?\b/.test(text)) return amount * 1_000;
  if (/\bmillions?\b/.test(text)) return amount;
  if (/\bthousands?\b/.test(text)) return amount / 1_000;
  if (String(metric?.currency || "").toUpperCase() === "USD" && amount > 0 && amount < 100) return amount * 1_000;
  return amount;
}

function selectFullYearGuidanceM(
  metrics,
  { excludePatterns = [], requirePatterns = [], rejectMetric = null } = {}
) {
  const annualPatterns = [
    /full[- ]year/,
    /fiscal year/,
    /this year/,
    /annual/,
    /\bfy\s*(?:20)?\d{2}\b/,
    /\bfor the year\b/,
    /\b(?:outlook|guidance) for (?:fiscal )?20\d{2}\b/,
    /\bfor (?:fiscal )?20\d{2}\b/,
    /\boriginal\b[^.]{0,120}\bguidance range\b/
  ];
  const quarterPatterns = [
    /\bq[1-4]\b/,
    /\b(?:first|second|third|fourth)\s+quarter(?:\s+of\s+(?:(?:fiscal|calendar)\s+year\s+|fy\s*)?20\d{2})?\b/,
    /\bnext quarter\b/,
    /\bfor the quarter\b/
  ];
  const excludes = excludePatterns.map((pattern) =>
    pattern instanceof RegExp ? pattern : new RegExp(pattern, "i")
  );
  const requirements = requirePatterns.map((pattern) =>
    pattern instanceof RegExp ? pattern : new RegExp(pattern, "i")
  );
  const guidanceCandidates = metrics.filter((metric) => metric.actual_or_guidance === "guidance");
  const candidates = guidanceCandidates
    .filter((metric) => {
      const evidence = metricOwnedSelectionText(metric);
      return !(rejectMetric && rejectMetric(metric)) &&
        !excludes.some((pattern) => pattern.test(evidence)) &&
        (!requirements.length || requirements.some((pattern) => pattern.test(evidence)));
    });
  const scopedCandidates = candidates.filter((metric) => {
    const scope = metricGuidanceScope(metric);
    if (["full_year", "annual", "fiscal_year"].includes(scope)) return true;
    if (scope) return false;
    const evidence = metricEvidenceText(metric);
    return !quarterPatterns.some((pattern) => pattern.test(evidence));
  });
  const explicitAnnual = scopedCandidates.filter((metric) => {
    if (["full_year", "annual", "fiscal_year"].includes(metricGuidanceScope(metric))) return true;
    const evidence = metricEvidenceText(metric);
    return annualPatterns.some((pattern) => pattern.test(evidence));
  });
  const unscopedCandidates = scopedCandidates.filter((metric) => !explicitAnnual.includes(metric));
  const quarterCandidates = candidates.filter((metric) => {
    const scope = metricGuidanceScope(metric);
    if (["full_year", "annual", "fiscal_year"].includes(scope)) return false;
    if (scope === "quarter") return true;
    if (scope) return false;
    const evidence = metricEvidenceText(metric);
    return quarterPatterns.some((pattern) => pattern.test(evidence));
  });
  const values = explicitAnnual
    .map(metricAmountM)
    .filter((value) => value != null && value > 0);
  const unscopedValues = unscopedCandidates
    .map(metricAmountM)
    .filter((value) => value != null && value > 0);
  const quarterValues = quarterCandidates
    .map(metricAmountM)
    .filter((value) => value != null && value > 0);
  const selectionLineage = (selected) => ({
    evidenceIds: [...new Set(selected.map((metric) => metric?.evidence_id).filter(Boolean))].sort(),
    subjects: [...new Set(selected.map(metricGuidanceSubject).filter(Boolean))].sort()
  });
  const acceptedMetrics = explicitAnnual.filter((metric) => metricAmountM(metric) > 0);
  const unscopedMetrics = unscopedCandidates.filter((metric) => metricAmountM(metric) > 0);
  const acceptedQuarterMetrics = quarterCandidates.filter((metric) => metricAmountM(metric) > 0);
  const acceptedLineage = selectionLineage(acceptedMetrics);
  const unscopedLineage = selectionLineage(unscopedMetrics);
  const quarterLineage = selectionLineage(acceptedQuarterMetrics);
  return {
    amountM: median(values),
    unscopedAmountM: median(unscopedValues),
    quarterlyAmountM: median(quarterValues),
    mode: values.length ? "explicit_full_year" : unscopedValues.length ? "unscoped_fallback" : "missing",
    acceptedCount: values.length,
    unscopedCount: unscopedValues.length,
    acceptedQuarterCount: quarterValues.length,
    rejectedQuarterCount: candidates.length - scopedCandidates.length,
    rejectedSemanticCount: guidanceCandidates.length - candidates.length,
    acceptedEvidenceIds: acceptedLineage.evidenceIds,
    acceptedSubjects: acceptedLineage.subjects,
    unscopedEvidenceIds: unscopedLineage.evidenceIds,
    unscopedSubjects: unscopedLineage.subjects,
    quarterEvidenceIds: quarterLineage.evidenceIds,
    quarterSubjects: quarterLineage.subjects
  };
}

export function preferAuthoritativeGuidanceMetrics(metrics) {
  const authoritativeSourceTypes = new Set([
    "official_issuer_results_release",
    "official_issuer_sec_filing"
  ]);
  const officialMetricNames = new Set(
    metrics
      .filter((metric) => authoritativeSourceTypes.has(metric.source_type))
      .map((metric) => metric.metric_name)
      .filter(Boolean)
  );
  if (!officialMetricNames.size) return metrics;
  return metrics.filter((metric) =>
    !officialMetricNames.has(metric.metric_name) ||
    authoritativeSourceTypes.has(metric.source_type)
  );
}

export function digestGuidanceMetrics(metrics, { sourceDatabase = YOUTUBE_DB_PATH } = {}) {
  const selectedMetrics = deduplicateGuidanceMetrics(preferAuthoritativeGuidanceMetrics(metrics));
  // An unusable official excerpt must not hide a usable transcript target.
  // Establish the source contract before applying authority and deduplication.
  const sourceDecisions = new Map(metrics.map((metric) => [metric, sourceGuidanceConsumptionDecision(metric, {
    requireTypedSource: sourceDatabase === "valuation-pit-guidance"
  })]));
  const consumableMetrics = deduplicateGuidanceMetrics(preferAuthoritativeGuidanceMetrics(
    metrics.filter((metric) => sourceDecisions.get(metric).accepted)
  )).filter((metric) => !historicalFactMislabeledGuidance(metric));
  const clearMetrics = consumableMetrics.filter((metric) => metric.quality_status === "clear");
  const guidanceMetrics = selectedMetrics.filter((metric) => metric.actual_or_guidance === "guidance");
  const revenueIdentityPattern = /\b(?:revenue|revenues|sales|total income)\b/i;
  const semanticallyValidRevenueMetrics = clearMetrics.filter((metric) => {
    const evidence = metricEvidenceText(metric);
    return ["revenue_growth", "revenue_guidance"].includes(metric.metric_name) &&
      revenueIdentityPattern.test(evidence) &&
      !isRevenueSubsetMetric(metric);
  });
  const semanticallyValidRevenueGuidanceMetrics = semanticallyValidRevenueMetrics
    .filter((metric) => metric.actual_or_guidance === "guidance");
  const revenueGrowth = median(metricValues(
    semanticallyValidRevenueMetrics,
    ["revenue_growth", "revenue_guidance"]
  ));
  const revenueGuidanceGrowth = median(metricValues(
    semanticallyValidRevenueGuidanceMetrics,
    ["revenue_growth", "revenue_guidance"]
  ));
  const operatingMargin = median(metricValues(clearMetrics, ["operating_margin", "margin"], "margin_pct"));
  const grossMargin = median(metricValues(clearMetrics, ["gross_margin"], "margin_pct"));
  // Keep the exact contributors, not merely the aggregate value: two excluded
  // and accepted excerpts may quote the same percentage. The release audit
  // needs source IDs to prove that research-only evidence was not consumed.
  const scalarIds = (candidates, names, field = "growth_yoy") => [...new Set(candidates
    .filter((metric) => names.includes(metric.metric_name) && finiteNumber(metric[field]) != null)
    .map((metric) => metric.evidence_id)
    .filter(Boolean))].sort();
  const scalarEvidenceIds = {
    revenueGrowth: scalarIds(semanticallyValidRevenueMetrics, ["revenue_growth", "revenue_guidance"]),
    revenueGuidanceGrowth: scalarIds(semanticallyValidRevenueGuidanceMetrics, ["revenue_growth", "revenue_guidance"]),
    operatingMargin: scalarIds(clearMetrics, ["operating_margin", "margin"], "margin_pct"),
    grossMargin: scalarIds(clearMetrics, ["gross_margin"], "margin_pct")
  };
  const guidanceSourceMetrics = consumableMetrics.filter((metric) => ["clear", "ambiguous"].includes(metric.quality_status));
  const revenueGuidance = selectFullYearGuidanceM(
    guidanceSourceMetrics.filter((metric) => metric.metric_name === "revenue_guidance"),
    {
      requirePatterns: [revenueIdentityPattern],
      rejectMetric: isRevenueSubsetMetric
    }
  );
  const operatingIncomeGuidance = selectFullYearGuidanceM(
    guidanceSourceMetrics.filter((metric) => metric.metric_name === "operating_income_guidance"),
    {
      requirePatterns: [/\boperating (?:income|profit)\b|\bincome from operations\b|\b(?:adjusted\s+)?ebit\b/i],
      excludePatterns: [/\bnet income\b/i, /\bfree cash flow\b|\bfcf\b/i, /\b(?:adjusted )?ebitda\b/i],
      rejectMetric: isNonCompanyGuidanceMetric
    }
  );
  const fcfGuidance = selectFullYearGuidanceM(
    guidanceSourceMetrics.filter((metric) => metric.metric_name === "free_cash_flow_guidance"),
    {
      requirePatterns: [/\bfree cash flow\b|\bfcf\b/i],
      excludePatterns: [
        /free cash flow margin/i,
        /discontinued operations?/i,
        /weighted average.*shares/i,
        /\bcumulative\b/i,
        /\bover the (?:next )?(?:two|three|four|five|six|seven|eight|nine|ten|\d+)[ -]year/i,
        /\b(?:two|three|four|five|six|seven|eight|nine|ten|\d+)[ -]year period/i
      ],
      rejectMetric: isNonCompanyGuidanceMetric
    }
  );
  const observedDates = selectedMetrics.map((metric) => metric.observed_at).filter(Boolean).sort();
  const fxConversions = selectedMetrics
    .filter((metric) => metric.fx_conversion)
    .map((metric) => metric.fx_conversion);
  return {
    sourceDatabase,
    metricCount: selectedMetrics.length,
    clearMetricCount: clearMetrics.length,
    guidanceMetricCount: guidanceMetrics.length,
    actualMetricCount: selectedMetrics.filter((metric) => metric.actual_or_guidance === "actual").length,
    metricNames: [...new Set(selectedMetrics.map((metric) => metric.metric_name).filter(Boolean))].sort(),
    revenueGrowth,
    revenueGuidanceGrowth,
    operatingMargin,
    grossMargin,
    scalarEvidenceIds,
    revenueGuidanceM: revenueGuidance.amountM,
    revenueUnscopedGuidanceM: revenueGuidance.unscopedAmountM,
    revenueQuarterGuidanceM: revenueGuidance.quarterlyAmountM,
    operatingIncomeGuidanceM: operatingIncomeGuidance.amountM,
    fcfGuidanceM: fcfGuidance.amountM,
    guidanceSelection: {
      revenue: revenueGuidance,
      operatingIncome: operatingIncomeGuidance,
      freeCashFlow: fcfGuidance
    },
    rejectedHistoricalGuidance: selectedMetrics.filter(historicalFactMislabeledGuidance).map((metric) => ({
      evidenceId: metric.evidence_id || null, metricName: metric.metric_name,
      reason: "owned_metric_describes_historical_actual_not_forward_guidance"
    })),
    rejectedSourceGuidance: metrics.filter((metric) => !sourceDecisions.get(metric).accepted).map((metric) => ({
      evidenceId: metric.evidence_id || metric.id || null,
      metricName: metric.metric_name,
      reason: sourceDecisions.get(metric).reason
    })),
    guidanceConsumptionPolicy: {
      sourceEvidencePresent: metrics.length > 0,
      rejectedEvidenceCount: metrics.filter((metric) => !sourceDecisions.get(metric).accepted).length,
      policy: "Only scoped, owned forward company targets feed PIT numerical inputs; retained research does not imply guidance was absent.",
      missingUsableTargetIsNotNoManagementGuidance: true
    },
    fxConversions,
    minObservedAt: observedDates[0] || null,
    maxObservedAt: observedDates.at(-1) || null,
    evidence: buildEvidence(metrics)
  };
}

function buildEvidence(metrics) {
  const byEvidence = new Map();
  for (const metric of metrics) {
    if (!metric.evidence_id || byEvidence.has(metric.evidence_id)) continue;
    byEvidence.set(metric.evidence_id, {
      id: metric.evidence_id,
      url: metric.evidence_url || metric.url || null,
      excerpt: metric.excerpt || null,
      observedAt: metric.observed_at || null,
      fiscalPeriod: metric.fiscal_period || null,
      speaker: metric.speaker || null,
      metricName: metric.metric_name || null
    });
  }
  return [...byEvidence.values()]
    .filter((item) => item.excerpt || item.url)
    .slice(0, MAX_EVIDENCE_EXCERPTS);
}

export function readYoutubeEvidence(tickers, { guidanceOnly = false } = {}) {
  if (!fs.existsSync(YOUTUBE_DB_PATH)) return new Map();
  const db = new DatabaseSync(YOUTUBE_DB_PATH, { readOnly: true });
  try {
    const placeholders = tickers.map(() => "?").join(", ");
    if (!placeholders) return new Map();
    const transcriptQaByPeriod = readTranscriptQaByTickerPeriod(db, new Set(tickers));
    const rows = db.prepare(`
      SELECT
        me.id,
        me.ticker,
        me.metric_name,
        me.fiscal_period,
        me.actual_or_guidance,
        me.amount,
        me.unit,
        me.currency,
        me.growth_yoy,
        me.growth_qoq,
        me.margin_pct,
        me.value_text,
        me.quality_status,
        me.extraction_confidence,
        me.evidence_id,
        ev.excerpt,
        ev.url AS evidence_url,
        ev.observed_at,
        ev.speaker
      FROM ont_metric_events me
      LEFT JOIN ont_evidence ev ON ev.id = me.evidence_id
      WHERE me.ticker IN (${placeholders})
        AND me.fiscal_period IS NOT NULL
        AND me.quality_status IN ('clear', 'ambiguous')
        ${guidanceOnly ? "AND me.actual_or_guidance = 'guidance'" : ""}
      ORDER BY me.ticker ASC, me.fiscal_period ASC
    `).all(...tickers);
    const grouped = new Map();
    for (const row of rows) {
      const ticker = String(row.ticker || "").toUpperCase();
      const period = normalizePeriod(row.fiscal_period);
      if (!ticker || !period) continue;
      const key = `${ticker}::${period}`;
      grouped.set(key, [...(grouped.get(key) || []), row]);
    }
    const digests = new Map();
    for (const [key, metrics] of grouped) {
      digests.set(key, {
        ...digestGuidanceMetrics(metrics),
        qa: transcriptQaByPeriod.get(key) || []
      });
    }
    for (const [key, qa] of transcriptQaByPeriod.entries()) {
      if (digests.has(key)) continue;
      digests.set(key, {
        sourceDatabase: YOUTUBE_DB_PATH,
        metricCount: 0,
        clearMetricCount: 0,
        guidanceMetricCount: 0,
        actualMetricCount: 0,
        metricNames: [],
        evidence: [],
        qa
      });
    }
    return digests;
  } finally {
    db.close();
  }
}

function auditModelInputs(snapshot) {
  const history = Array.isArray(snapshot.history) ? snapshot.history : [];
  const secRows = history.filter((row) =>
    isVerifiedFinancialModelSource(row.sourceType) ||
    isVerifiedFinancialModelSource(row.dataSnapshot?.sourceType) ||
    isVerifiedFinancialModelSource(row.dataSnapshot?.valuationSemantics?.sourceType)
  ).length;
  const trinityRows = history.filter((row) => row.sourceType === "trinity_official_financial_model" || row.dataSnapshot?.sourceType === "trinity_official_financial_model").length;
  const financialRows = secRows + trinityRows;
  const sourceTypes = history.reduce((counts, row) => {
    const key = row.sourceType || row.dataSnapshot?.sourceType || "unknown";
    counts[key] = (counts[key] || 0) + 1;
    return counts;
  }, {});
  const uniqueFairValues = new Set(history.map((row) => Number(row.fairValue).toFixed(4))).size;
  const warnings = [];
  const coverageNotes = [];
  let status = "pass";
  if (!history.length) {
    status = "fail";
    warnings.push("No usable financial/guidance valuation history.");
  } else if (history.length < 4 && financialRows === 0) {
    status = "review";
    warnings.push("Limited valuation history and no verified financial/guidance rows.");
  } else if (history.length < 8) {
    coverageNotes.push("Limited valuation history; read as a point-in-time model until more quarters are available.");
  }
  if (!financialRows) {
    status = "review";
    warnings.push("No financial/guidance valuation rows are available.");
  }
  if (history.length > 1 && uniqueFairValues <= 1) {
    status = "review";
    warnings.push("Fair value history has too few distinct points.");
  } else if (history.length === 1) {
    coverageNotes.push("Single verified valuation snapshot available.");
  }
  const latestFairValue = finiteNumber(snapshot.latest?.baseFairValue);
  const latestPrice = finiteNumber(snapshot.latest?.latestPrice);
  const latestFairToPrice = latestFairValue && latestPrice ? latestFairValue / latestPrice : null;
  return {
    status,
    passesNoPriceAnchorAudit: true,
    fairValueInputPolicy: "reported-financials-guidance-and-scenario-assumptions",
    priceUsage: "comparison-price-series-only",
    sourceGrade: history.some((row) => isPitFinancialModelSource(row.sourceType) || isPitFinancialModelSource(row.dataSnapshot?.sourceType))
      ? "jansen-pit-financials"
      : secRows ? "sec-companyfacts-financials" : "ai-trinity-official-ir-financials",
    valuationRows: history.length,
    financialOrGuidanceEvidenceRows: financialRows,
    secCompanyFactsRows: secRows,
    trinityOfficialFinancialRows: trinityRows,
    currentPriceStoredRows: history.filter((row) => finiteNumber(row.priceAtDate) != null).length,
    methodPriceAnchorSignalCount: 0,
    methodPriceAnchorSignals: [],
    sourceTypes,
    uniqueFairValues,
    latestFairToPrice,
    warnings,
    coverageNotes
  };
}

function latestScenario(snapshot, latestRow, latestPrice) {
  const currentPrice = finiteNumber(latestRow?.priceAtDate ?? latestRow?.currentPrice);
  const latestMarketPrice = finiteNumber(latestPrice?.close ?? snapshot.latest?.latestPrice);
  const fairValue = finiteNumber(latestRow?.fairValue);
  const targetPrice3Y = finiteNumber(latestRow?.targetPrice3Y);
  return {
    scenario: "Base",
    currentPrice,
    fairValue,
    upsideDownside: currentPrice && fairValue ? fairValue / currentPrice - 1 : finiteNumber(latestRow?.upsideDownside),
    targetPrice3Y,
    expectedReturn3Y: latestMarketPrice && targetPrice3Y ? (targetPrice3Y / latestMarketPrice) ** (1 / 3) - 1 : finiteNumber(latestRow?.expectedReturn3Y),
    recommendedMethod: latestRow?.method || "SEC CompanyFacts quarterly FCF / earnings model",
    modelSummary: "SEC quarterly financials with transcript evidence overlay"
  };
}

export function updateTickerSnapshot({ ticker, snapshot, valuationRows, coverage }) {
  const history = valuationRows
    .filter((row) => row.asOfDate && finiteNumber(row.fairValue) != null)
    .sort((left, right) => String(left.asOfDate).localeCompare(String(right.asOfDate)));
  const latestRow = history.at(-1);
  const latestPrice = latestPricePoint(snapshot.priceHistory);
  const latestMarketPrice = finiteNumber(latestPrice?.close ?? snapshot.latest?.latestPrice);
  const latestFairValue = finiteNumber(latestRow?.fairValue);
  const latestTarget = finiteNumber(latestRow?.targetPrice3Y);
  const pricePoints = snapshot.priceHistory?.length || snapshot.dataQuality?.pricePoints || 0;
  const generatedAt = new Date().toISOString();
  const sourceLabel = coverage?.sourceLabel || "SEC CompanyFacts financials + transcript guidance model";
  const sourceNote = coverage?.sourceNote || "SEC CompanyFacts quarterly financials + YouTube earnings-call transcript evidence; fair value excludes market price.";
  const modelType = coverage?.modelType || "SEC quarterly Fundamental Analysis model";
  const profileLabel = profileSettings(ticker).label;
  const next = {
    ...snapshot,
    ticker,
    generatedAt,
    modelType,
    sector: profileLabel || snapshot.sector,
    latest: {
      ...(snapshot.latest || {}),
      latestPrice: latestMarketPrice ?? snapshot.latest?.latestPrice ?? null,
      latestPriceDate: latestPrice?.date || snapshot.latest?.latestPriceDate || null,
      latestPriceSource: latestPrice?.source || snapshot.latest?.latestPriceSource || snapshot.priceSource || null,
      valuationAnchorPrice: finiteNumber(latestRow?.priceAtDate ?? latestRow?.currentPrice ?? snapshot.latest?.valuationAnchorPrice),
      valuationAnchorDate: latestRow?.asOfDate || snapshot.latest?.valuationAnchorDate || null,
      baseFairValue: latestFairValue,
      fairValueSource: sourceLabel,
      fairValueInputPolicy: "reported financials / guidance only; price excluded",
      upsideToBase: latestMarketPrice && latestFairValue ? latestFairValue / latestMarketPrice - 1 : finiteNumber(latestRow?.upsideDownside ?? snapshot.latest?.upsideToBase),
      targetPrice3Y: latestTarget,
      expectedReturn3Y: latestMarketPrice && latestTarget ? (latestTarget / latestMarketPrice) ** (1 / 3) - 1 : finiteNumber(latestRow?.expectedReturn3Y ?? snapshot.latest?.expectedReturn3Y)
    },
    scenarios: latestRow ? [latestScenario(snapshot, latestRow, latestPrice)] : snapshot.scenarios,
    history,
    methodCards: [
      {
        key: "sec-quarterly-fundamental-model",
        label: coverage?.methodCardLabel || "AI Trinity-style financial model",
        value: history.length,
        format: "number",
        description: coverage?.methodCardDescription || "Fair values are rebuilt from reported financials, guidance evidence and buy-side scenario assumptions. Price is excluded."
      },
      {
        key: "price-anchor-audit",
        label: "Price anchor audit",
        value: 0,
        format: "number",
        description: "Market price is stored only for comparison, upside and chart hover."
      },
      ...(snapshot.methodCards || [])
        .filter((card) => !["sec-quarterly-fundamental-model", "price-anchor-audit", "youtube-earnings-metric-model"].includes(card?.key))
        .slice(0, 4)
    ],
    warnings: [
      `Imported ${history.length} ${coverage?.source || "financial"} valuation rows.`,
      ...(coverage.youtubePeriods ? [`Attached YouTube transcript metric evidence to ${coverage.youtubePeriods} matching periods.`] : []),
      ...(snapshot.warnings || []).filter((warning) =>
        !String(warning).includes("Imported") &&
        !String(warning).includes("Attached YouTube transcript") &&
        !String(warning).includes("Limited valuation history")
      )
    ],
    dataQuality: {
      ...(snapshot.dataQuality || {}),
      pricePoints,
      hasLivePriceSeries: pricePoints >= 120,
      priceDisplayMode: pricePoints >= 120 ? "daily-price-line" : "as-of-price-anchors",
      sourceNote,
      fairValueSource: sourceLabel,
      secCompanyFacts: coverage,
      secCompanyFactsQuarterlyRows: coverage?.secRows ?? history.filter((row) =>
        isVerifiedFinancialModelSource(row.sourceType) ||
        isVerifiedFinancialModelSource(row.dataSnapshot?.sourceType) ||
        isVerifiedFinancialModelSource(row.dataSnapshot?.valuationSemantics?.sourceType)
      ).length,
      trinityOfficialFinancialValuationRows: coverage?.trinityFinancialRows || 0,
      youtubeEarningsMetricValuationRows: 0,
      valuationCoverageKind: history.length >= 12 ? "quarterly" : history.length >= 4 ? "partial" : history.length ? "limited" : "unsupported",
      hasQuarterlyValuationRuns: history.length >= 12,
      excludedLegacyBackendRows: 0,
      excludedSnapshotRows: 0
    }
  };
  return {
    ...next,
    dataQuality: {
      ...next.dataQuality,
      modelInputAudit: auditModelInputs(next)
    }
  };
}

function legacyValuationScoreInputs(snapshot, row) {
  const assumptions = Array.isArray(snapshot.assumptions) ? snapshot.assumptions : [];
  const methodCards = Array.isArray(snapshot.methodCards) ? snapshot.methodCards : [];
  const isMarketAssumption = (assumption) => {
    const text = `${assumption?.key || ""} ${assumption?.label || ""} ${assumption?.category || ""}`.toLowerCase();
    return assumption?.category === "Market" || /current\s*price|market\s*price|share\s*price|price|gbp\s*usd|fx/.test(text);
  };
  const financialAssumptions = assumptions
    .filter((assumption) => !isMarketAssumption(assumption))
    .map((assumption) => ({
      key: assumption.key,
      label: assumption.label,
      value: assumption.value,
      source: assumption.source,
      category: assumption.category
    }));
  const marketComparisonInputsExcluded = assumptions
    .filter(isMarketAssumption)
    .map((assumption) => ({
      key: assumption.key,
      label: assumption.label,
      value: assumption.value,
      source: assumption.source,
      category: assumption.category
    }));
  const methodOutputs = methodCards
    .filter((card) => finiteNumber(card?.value) != null)
    .map((card) => ({
      key: card.key,
      label: card.label,
      value: card.value,
      format: card.format
    }));
  return {
    legacyModel: true,
    method: row.method || snapshot.modelType || "legacy financial/guidance model",
    financialAssumptions,
    methodOutputs,
    marketComparisonInputsExcluded,
    priceExcludedFromFairValue: true
  };
}

function normalizeLegacyFinancialSnapshot({ ticker, snapshot }) {
  const history = Array.isArray(snapshot.history) ? snapshot.history : [];
  if (!history.length || finiteNumber(snapshot.latest?.baseFairValue) == null) return null;
  const generatedAt = new Date().toISOString();
  const normalizedHistory = history.map((row) => {
    const sourceType = row.sourceType || row.dataSnapshot?.sourceType || row.dataSnapshot?.valuationSemantics?.sourceType || "legacy_fundamental_analysis";
    return {
      ...row,
      sourceType,
      dataSnapshot: {
        ...(row.dataSnapshot || {}),
        sourceType,
        valuationSemantics: {
          ...(row.dataSnapshot?.valuationSemantics || {}),
          sourceType,
          priceExcludedFromFairValue: true,
          fairValueFormula: row.dataSnapshot?.valuationSemantics?.fairValueFormula || `${row.method || snapshot.modelType || "Legacy Fundamental Analysis valuation model"}; no market price input`,
          scoreInputs: row.dataSnapshot?.valuationSemantics?.scoreInputs?.financialAssumptions
            ? row.dataSnapshot.valuationSemantics.scoreInputs
            : legacyValuationScoreInputs(snapshot, row)
        }
      }
    };
  });
  const next = {
    ...snapshot,
    ticker,
    generatedAt,
    latest: {
      ...(snapshot.latest || {}),
      fairValueSource: snapshot.latest?.fairValueSource || "Legacy Fundamental Analysis financial/guidance model",
      fairValueInputPolicy: snapshot.latest?.fairValueInputPolicy || "legacy financial/guidance model; price excluded from fair-value input"
    },
    history: normalizedHistory,
    dataQuality: {
      ...(snapshot.dataQuality || {}),
      sourceNote: snapshot.dataQuality?.sourceNote || "Legacy Fundamental Analysis valuation runs retained because SEC/Trinity inputs are unavailable.",
      fairValueSource: snapshot.dataQuality?.fairValueSource || "Legacy Fundamental Analysis financial/guidance model",
      valuationCoverageKind: snapshot.dataQuality?.valuationCoverageKind || (history.length >= 12 ? "quarterly" : "partial"),
      modelInputAudit: snapshot.dataQuality?.modelInputAudit || {
        status: history.length >= 12 ? "pass" : "review",
        passesNoPriceAnchorAudit: true,
        fairValueInputPolicy: "legacy-financial-guidance-model",
        priceUsage: "comparison-price-series-only",
        sourceGrade: "legacy-fundamental-analysis",
        valuationRows: history.length,
        financialOrGuidanceEvidenceRows: history.length,
        methodPriceAnchorSignalCount: 0,
        methodPriceAnchorSignals: [],
        warnings: ["Retained legacy Fundamental Analysis valuation because SEC/Trinity inputs were unavailable."]
      }
    }
  };
  return next;
}

export function compactTicker(snapshot) {
  const { priceHistory, ...compact } = snapshot;
  return {
    ...compact,
    history: (snapshot.history || []).slice(-12),
    dataQuality: {
      ...(snapshot.dataQuality || {}),
      fullHistoryRowsAvailable: snapshot.history?.length || 0
    }
  };
}

function dashboardTickerForTrinity(ticker) {
  return TRINITY_TO_DASHBOARD_TICKER[ticker] || ticker;
}

function secLookupTicker(ticker) {
  return String(ticker || "").toUpperCase().replace(".", "-");
}

function shouldPreserveLegacyBackendSnapshot(snapshot, valuationRows, sourceIsTrinity) {
  if (!sourceIsTrinity) return false;
  const legacyBackendRows = Number(snapshot?.dataQuality?.legacyBackendValuationRows || 0);
  const history = Array.isArray(snapshot?.history) ? snapshot.history : [];
  const distinctFairValues = new Set(
    history
      .map((row) => finiteNumber(row?.fairValue))
      .filter((value) => value != null)
      .map((value) => value.toFixed(4))
  ).size;
  const hasLegacyHistory = history.some((row) => {
    const sourceText = `${row?.sourceType || ""} ${row?.dataSnapshot?.sourceType || ""} ${row?.dataSnapshot?.valuationSemantics?.sourceType || ""}`.toLowerCase();
    return sourceText && !sourceText.includes("trinity_official_financial_model") && !sourceText.includes("sec_companyfacts_");
  });
  return legacyBackendRows >= 8 &&
    history.length >= 8 &&
    history.length > valuationRows.length &&
    distinctFairValues > 1 &&
    hasLegacyHistory;
}

async function main() {
  const trinity = fs.existsSync(TRINITY_MODEL_PATH)
    ? parseJson(fs.readFileSync(TRINITY_MODEL_PATH, "utf8"), {})
    : {};
  if (!fs.existsSync(TRINITY_MODEL_PATH)) {
    console.warn(`Trinity model not found at ${TRINITY_MODEL_PATH}; continuing with SEC CompanyFacts only.`);
  }
  const currentDb = new DatabaseSync(CURRENT_DB_PATH);
  try {
    const dashboard = parseJson(currentDb.prepare("SELECT payload_json FROM valuation_snapshots WHERE id = ?").get("latest")?.payload_json, {});
    const currentTickers = new Map(
      currentDb.prepare("SELECT ticker, payload_json FROM valuation_ticker_snapshots").all()
        .map((row) => [row.ticker, parseJson(row.payload_json, {})])
    );
    const trinityModels = readTrinityCompanyModels(trinity);
    const secTickerMap = await readSecTickerMap();
    const requestedTickers = DEFAULT_TICKERS.includes("ALL") ? [...currentTickers.keys()] : DEFAULT_TICKERS;
    const requested = requestedTickers.map((ticker) => {
      const companyModel = trinityModels.get(ticker);
      const secInfo = secTickerMap.get(secLookupTicker(ticker));
      const trinityTicker = companyModel?.ticker || ticker;
      const dashboardTicker = dashboardTickerForTrinity(trinityTicker);
      const normalizedTicker = currentTickers.has(dashboardTicker) ? dashboardTicker : ticker;
      const snapshot = currentTickers.get(normalizedTicker) ||
        baseValuationSnapshot({
          ticker: normalizedTicker,
          companyModel,
          secInfo,
          priceHistory: readPriceHistoryFromDb(currentDb, normalizedTicker)
        });
      const cik = companyModel?.cik || snapshot?.cik || snapshot?.dataQuality?.secCompanyFacts?.cik || secInfo?.cik_str;
      return {
        ticker: normalizedTicker,
        trinityTicker,
        snapshot,
        companyModel: {
          ...(companyModel || {}),
          ticker: trinityTicker,
          cik,
          company: companyModel?.company || secInfo?.title || snapshot?.name || ticker
        }
      };
    }).filter((item) => item.snapshot);

    const youtubeByPeriod = readYoutubeEvidence([...new Set(requested.flatMap((item) => [item.ticker, item.trinityTicker]))]);
    const updated = [];
    const skipped = [];

    for (const item of requested) {
      const { ticker, trinityTicker, companyModel } = item;
      const snapshot = item.snapshot;
      if (!currentTickers.has(ticker)) currentTickers.set(ticker, snapshot);
      let quarterlyRows = [];
      let secRows = [];
      let factsUrl = null;
      let cachePath = null;
      let cik = companyModel?.cik ? normalizeCik(companyModel.cik) : null;
      if (cik && cik !== "0000000000") {
        factsUrl = secCompanyFactsUrl(cik);
        cachePath = path.join(CACHE_DIR, `${cik}.json`);
        const factsPayload = await fetchJsonWithCache(factsUrl, cachePath);
        await sleep(140);
        const facts = factsPayload?.facts || {};
        quarterlyRows = buildQuarterlyFinancials(facts, ticker);
        if (ticker === "MSTR") {
          quarterlyRows = attachMstrCryptoMetrics(facts, quarterlyRows);
        }
        if (process.env.DEBUG_SEC_VALUATION_TICKER === ticker) {
          console.error(JSON.stringify({
            ticker,
            quarterlyRows: quarterlyRows.slice(-8).map((row) => ({
              key: row.key,
              label: row.label,
              asOfDate: row.asOfDate,
              revenue_m: row.revenue_m,
              net_income_m: row.net_income_m,
              crypto_asset_fair_value_m: row.crypto_asset_fair_value_m,
              crypto_asset_units: row.crypto_asset_units,
              shares_m: row.shares_m,
              sources: row.sources
            }))
          }, null, 2));
        }
        secRows = buildValuationRows({
          ticker,
          trinityTicker,
          snapshot: { ...snapshot, ticker },
          companyModel,
          factsUrl,
          quarterlyRows,
          youtubeByPeriod
        });
      }

      const trinityRows = secRows.length >= 4 ? [] : buildTrinityValuationRows({
        ticker,
        trinityTicker,
        snapshot: { ...snapshot, ticker },
        companyModel,
        youtubeByPeriod
      });
      const valuationRows = secRows.length >= 4 || !trinityRows.length ? secRows : trinityRows;
      const sourceIsTrinity = valuationRows === trinityRows;
      if (shouldPreserveLegacyBackendSnapshot(snapshot, valuationRows, sourceIsTrinity)) {
        const legacySourceLabel = "Legacy Fundamental Analysis financial/guidance model";
        const legacySourceNote = "Legacy Fundamental Analysis backend valuation runs: each fair-value bar is recomputed from event-visible financials/guidance and scenario assumptions; market price is used only for comparison, upside/downside, and return math.";
        const preserved = {
          ...snapshot,
          ticker,
          modelType: /ai trinity/i.test(String(snapshot.modelType || ""))
            ? "Fundamental Analysis backend valuation model"
            : snapshot.modelType || "Fundamental Analysis backend valuation model",
          generatedAt: new Date().toISOString(),
          latest: {
            ...(snapshot.latest || {}),
            fairValueSource: legacySourceLabel,
            fairValueInputPolicy: "event-visible financials/guidance and scenario assumptions; price excluded from fair-value input"
          },
          dataQuality: {
            ...(snapshot.dataQuality || {}),
            legacyValuationRows: snapshot.history?.length || snapshot.dataQuality?.legacyBackendValuationRows || 0,
            sourceNote: legacySourceNote,
            fairValueSource: legacySourceLabel,
            secCompanyFacts: snapshot.dataQuality?.secCompanyFacts
              ? {
                  ...snapshot.dataQuality.secCompanyFacts,
                  usedForFairValue: false,
                  supersededBy: "Legacy Fundamental Analysis backend valuation history"
                }
              : snapshot.dataQuality?.secCompanyFacts,
            trinityCandidateRowsSkipped: valuationRows.length,
            trinityCandidateSkipReason: "Preserved richer legacy backend valuation history over sparse AI Trinity proxy rows."
          },
          warnings: [
            "Preserved richer legacy backend valuation history over sparse AI Trinity proxy rows.",
            ...(snapshot.warnings || []).filter((warning) => !String(warning).includes("Preserved richer legacy backend"))
          ]
        };
        currentTickers.set(ticker, preserved);
        currentDb.prepare(`
          INSERT INTO valuation_ticker_snapshots (ticker, generated_at, payload_json)
          VALUES (?, ?, ?)
          ON CONFLICT(ticker) DO UPDATE SET
            generated_at = excluded.generated_at,
            payload_json = excluded.payload_json
        `).run(ticker, preserved.generatedAt, JSON.stringify(preserved));
        updated.push({
          ticker,
          source: "Preserved Legacy Fundamental Analysis",
          rows: preserved.history?.length || 0,
          secRows: secRows.length,
          trinityRows: valuationRows.length,
          quarterlyFinancialRows: quarterlyRows.length,
          youtubePeriods: 0
        });
        continue;
      }
      if (valuationRows.length < 1) {
        const legacy = normalizeLegacyFinancialSnapshot({ ticker, snapshot: { ...snapshot, ticker } });
        if (legacy) {
          currentTickers.set(ticker, legacy);
          currentDb.prepare(`
            INSERT INTO valuation_ticker_snapshots (ticker, generated_at, payload_json)
            VALUES (?, ?, ?)
            ON CONFLICT(ticker) DO UPDATE SET
              generated_at = excluded.generated_at,
              payload_json = excluded.payload_json
          `).run(ticker, legacy.generatedAt, JSON.stringify(legacy));
          updated.push({
            ticker,
            source: "Legacy Fundamental Analysis",
            rows: legacy.history?.length || 0,
            secRows: 0,
            trinityRows: 0,
            quarterlyFinancialRows: quarterlyRows.length,
            youtubePeriods: 0
          });
        } else {
          skipped.push({ ticker, reason: `no usable SEC or Trinity valuation rows` });
        }
        continue;
      }
      const youtubePeriods = valuationRows.filter((row) => row.dataSnapshot?.youtubeEarnings?.metricCount).length;
      const coverage = sourceIsTrinity ? {
        source: "AI Trinity official financials",
        sourceLabel: "AI Trinity official IR financial model",
        sourceNote: "AI Trinity single-stock financial model plus YouTube transcript evidence; fair value excludes market price.",
        modelType: "AI Trinity Fundamental Analysis model",
        methodCardLabel: "AI Trinity official financial model",
        methodCardDescription: "Fair values are rebuilt from AI Trinity annual/latest-quarter financials, official IR fields, transcript evidence and buy-side scenario assumptions. Price is excluded.",
        sourceUrl: companyModel.latest_quarter?.source_url || companyModel.sources?.[0]?.url || null,
        sourcePath: TRINITY_MODEL_DIR,
        cik,
        company: companyModel.company || snapshot.name || ticker,
        quarterlyFinancialRows: quarterlyRows.length,
        secRows: secRows.length,
        trinityFinancialRows: valuationRows.length,
        valuationRows: valuationRows.length,
        youtubePeriods,
        priceExcludedFromFairValue: true,
        modelInputPolicy: "AI Trinity official financials, normalized earnings/FCF or EV/sales assumptions; market price comparison only"
      } : {
        source: "SEC CompanyFacts",
        sourceLabel: "SEC CompanyFacts financials + transcript guidance model",
        sourceNote: "SEC CompanyFacts quarterly financials + YouTube earnings-call transcript evidence; fair value excludes market price.",
        sourceUrl: factsUrl,
        cachePath,
        cik,
        company: companyModel.company || snapshot.name || ticker,
        quarterlyFinancialRows: quarterlyRows.length,
        secRows: valuationRows.length,
        trinityFinancialRows: 0,
        valuationRows: valuationRows.length,
        youtubePeriods,
        priceExcludedFromFairValue: true,
        modelInputPolicy: "AI Trinity-style TTM financials, normalized earnings and five-year FCFE DCF; market price comparison only"
      };
      const next = updateTickerSnapshot({ ticker, snapshot: { ...snapshot, ticker }, valuationRows, coverage });
      currentTickers.set(ticker, next);
      currentDb.prepare(`
        INSERT INTO valuation_ticker_snapshots (ticker, generated_at, payload_json)
        VALUES (?, ?, ?)
        ON CONFLICT(ticker) DO UPDATE SET
          generated_at = excluded.generated_at,
          payload_json = excluded.payload_json
      `).run(ticker, next.generatedAt, JSON.stringify(next));
      updated.push({
        ticker,
        source: coverage.source,
        rows: valuationRows.length,
        secRows: secRows.length,
        trinityRows: sourceIsTrinity ? valuationRows.length : 0,
        quarterlyFinancialRows: quarterlyRows.length,
        youtubePeriods
      });
    }

    const tickersForDashboard = [...currentTickers.values()].map(compactTicker).sort((left, right) => {
      const leftUpside = Number(left.latest?.upsideToBase);
      const rightUpside = Number(right.latest?.upsideToBase);
      if (Number.isFinite(leftUpside) && Number.isFinite(rightUpside)) return rightUpside - leftUpside;
      return String(left.ticker || "").localeCompare(String(right.ticker || ""));
    });
    const snapshots = [...currentTickers.values()];
    const summary = {
      ...(dashboard.summary || {}),
      tickerCount: snapshots.length,
      historyRows: snapshots.reduce((sum, ticker) => sum + (ticker.history?.length || 0), 0),
      pricePointCount: snapshots.reduce((sum, ticker) => sum + (ticker.priceHistory?.length || 0), 0),
      livePriceTickerCount: snapshots.filter((ticker) => ticker.priceHistory?.length).length,
      latestPriceDate: snapshots.map((ticker) => ticker.latest?.latestPriceDate).filter(Boolean).sort().at(-1) || null,
      secCompanyFactsValuationTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.secCompanyFactsQuarterlyRows > 0).length,
      trinityOfficialFinancialValuationTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.trinityOfficialFinancialValuationRows > 0).length,
      youtubeEarningsTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.youtubeEarnings?.calls > 0).length,
      youtubeMetricValuationTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.youtubeEarningsMetricValuationRows > 0).length,
      unsupportedValuationTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.valuationCoverageKind === "unsupported").length,
      quarterlyBackendValuationTickerCount: snapshots.filter((ticker) => ticker.dataQuality?.hasQuarterlyValuationRuns).length,
      modelInputAuditPassCount: snapshots.filter((ticker) => ticker.dataQuality?.modelInputAudit?.status === "pass").length,
      modelInputAuditReviewCount: snapshots.filter((ticker) => ticker.dataQuality?.modelInputAudit?.status === "review").length,
      modelInputAuditFailCount: snapshots.filter((ticker) => ticker.dataQuality?.modelInputAudit?.status === "fail").length,
      positiveUpsideCount: tickersForDashboard.filter((ticker) => Number(ticker.latest?.upsideToBase) > 0).length,
      negativeUpsideCount: tickersForDashboard.filter((ticker) => Number(ticker.latest?.upsideToBase) < 0).length
    };
    const updatedDashboard = {
      ...dashboard,
      generatedAt: new Date().toISOString(),
      source: {
        ...(dashboard.source || {}),
        upstreamLabel: "SEC CompanyFacts + YouTube earnings-call transcript metric database",
        extraction: "SEC quarterly financials rebuilt into valuation rows with transcript evidence overlay",
        secCompanyFactsCache: CACHE_DIR,
        transcriptSource: YOUTUBE_DB_PATH,
        modelInputPolicy: "Fair value uses reported financials, normalized earnings/FCF assumptions and transcript evidence. Price is not accepted as a fair-value input."
      },
      summary,
      tickers: tickersForDashboard
    };
    currentDb.prepare(`
      INSERT INTO valuation_snapshots (id, generated_at, payload_json)
      VALUES (?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        generated_at = excluded.generated_at,
        payload_json = excluded.payload_json
    `).run("latest", updatedDashboard.generatedAt, JSON.stringify(updatedDashboard));
    currentDb.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    console.log(JSON.stringify({
      currentDbPath: CURRENT_DB_PATH,
      requested: DEFAULT_TICKERS,
      updated,
      skipped,
      summary
    }, null, 2));
  } finally {
    currentDb.close();
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
