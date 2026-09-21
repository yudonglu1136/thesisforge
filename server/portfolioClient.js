import { XMLParser } from "fast-xml-parser";
import {reportAnalysisAccounts} from './portfolioReport.js';
import {ibkrReportRange} from './ibkrReportRange.js';
import { AsyncUserCache } from './asyncUserCache.js';
import {
  readPriceSeriesFromDb,
  readPortfolioNavPoints,
  writeBackgroundJobRun,
  writePortfolioNavPoint
} from "./localDatabase.js";
import {
  readDividendCalendarForTickers,
  loadDividendCalendarForTickers
} from "./dividendClient.js";
import { factOsEnabled, canonicalListingRequest } from "./factRepository.js";
import { loadPriceSeries } from "./marketData.js";
import { canonicalTicker, logoUrlForTicker } from "./logoClient.js";
import { loadValuationDashboard } from "./valuationClient.js";
import { factGeneration } from "./valuationFacts.js";
import {
  isSterlingCurrency,
  marketTickerCandidates,
  normalizeTicker,
  portfolioDisplayTicker,
  valuationLookupKeysForSnapshot,
  valuationTickerCandidates
} from "./tickerAliases.js";
import {
  markPortfolioConnectionSync,
  listAdminPortfolioUsers,
  portfolioConnectionRevision,
  portfolioConnectionAccounts,
  readPortfolioConnection,
  readUserPortfolioReport,
  readUserPortfolioNavPoints,
  writeUserPortfolioReport,
  writeUserPortfolioNavPoint
} from "./userPortfolioStore.js";

const yodleeBaseUrl = String(process.env.YODLEE_BASE_URL || "").replace(/\/+$/, "");
const yodleeAccessToken = process.env.YODLEE_ACCESS_TOKEN || "";
const yodleeProviderAccountId = process.env.YODLEE_PROVIDER_ACCOUNT_ID || "";

const ibkrFlexBaseUrl = String(
  process.env.IBKR_FLEX_BASE_URL ||
    "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService"
).replace(/\/+$/, "");
const ibkrFlexToken = process.env.IBKR_FLEX_TOKEN || process.env.YODLEE_IBKR_TOKEN || "";
const ibkrFlexQueryId =
  process.env.IBKR_FLEX_QUERY_ID || process.env.YODLEE_IBKR_QUERY_ID || "";
const ibkrFlexHistoryQueryId =
  process.env.IBKR_FLEX_HISTORY_QUERY_ID ||
  process.env.YODLEE_IBKR_HISTORY_QUERY_ID ||
  "";
const portfolioCacheTtlMs = finiteNumber(process.env.PORTFOLIO_CACHE_TTL_MS, 15 * 60 * 1000);

const xmlParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  parseAttributeValue: true,
  parseTagValue: true,
  trimValues: true
});

const portfolioCache = new AsyncUserCache();
let portfolioNavRecorderStarted = false;
const productionUserId = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

const ibkrFlexEndpointHosts = new Set([
  "ndcdyn.interactivebrokers.com",
  "gdcdyn.interactivebrokers.com"
]);

const ibkrFlexStatementHosts = new Set([
  "ndcdyn.interactivebrokers.com",
  "gdcdyn.interactivebrokers.com",
  "www.interactivebrokers.com"
]);

function finiteNumber(value, fallback = 0) {
  if (value === null || value === undefined || value === "") return fallback;
  const cleaned = String(value).replace(/[$,%]/g, "").replace(/,/g, "").trim();
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function isRealUser(user) {
  const id = String(user?.id || "").trim();
  const adminHash = String(user?.adminPortfolioHash || "").trim();
  return Boolean((id && id !== "local-dev-user") || /^[a-f0-9]{40}$/i.test(adminHash));
}

function portfolioCacheIdentity(user) {
  const adminHash = String(user?.adminPortfolioHash || "").trim().toLowerCase();
  if (/^[a-f0-9]{40}$/.test(adminHash)) return `userhash:${adminHash}`;
  const id = String(user?.id || "").trim();
  return id ? `user:${id}` : "legacy";
}

function portfolioCachePrefix(user) {
  return `${JSON.stringify(portfolioCacheIdentity(user))}:facts:`;
}

function portfolioCacheKey(user) {
  const source = factOsEnabled() ? `sharadar:${factGeneration()}` : "legacy";
  return `${portfolioCachePrefix(user)}${source}`;
}

function portfolioAnalyticsPriceSource() {
  return factOsEnabled()
    ? "Sharadar Local Fact OS (total-return-adjusted)"
    : "local SQLite price_points";
}

function legacyPortfolioConnection() {
  if (ibkrFlexToken && ibkrFlexQueryId) {
    return {
      configured: true,
      provider: "ibkr_flex",
      ibkrFlexBaseUrl,
      ibkrFlexToken,
      ibkrFlexQueryId,
      ibkrFlexHistoryQueryId,
      status: {
        configured: true,
        provider: "IBKR Third-Party Reports",
        institution: "Interactive Brokers",
        status: "linked",
        message: "Legacy backend IBKR token is configured for local/operator mode.",
        storage: "backend_environment"
      }
    };
  }
  if (yodleeBaseUrl && yodleeAccessToken) {
    return {
      configured: true,
      provider: "yodlee_core",
      yodleeBaseUrl,
      yodleeAccessToken,
      yodleeProviderAccountId,
      status: {
        configured: true,
        provider: "Yodlee Core APIs",
        institution: "Interactive Brokers",
        status: "linked",
        message: "Legacy backend Yodlee API credentials are configured for local/operator mode.",
        storage: "backend_environment"
      }
    };
  }
  return null;
}

function onboardingPortfolio(user, statusOverride = null) {
  return normalizePortfolio({
    connection: {
      provider: "IBKR Third-Party Reports",
      institution: "Interactive Brokers",
      registered: false,
      configured: false,
      status: "not_configured",
      message: "Connect your IBKR Third-Party Reports token to load your own portfolio.",
      storage: "per_user_encrypted_sqlite",
      setup: {
        provider: "ibkr_flex",
        endpoint: "/api/portfolio/connection",
        fields: ["ibkrFlexToken", "ibkrFlexQueryId"],
        userScoped: true,
        encryptedAtRest: true
      },
      ...(statusOverride || {})
    },
    accounts: [],
    holdings: [],
    transactions: [],
    performance: [],
    dividends: [],
    source: {
      label: "User portfolio onboarding",
      mode: "user_scoped",
      userScoped: Boolean(user?.id)
    }
  });
}

function portfolioErrorPayload(user, error, status = {}) {
  return normalizePortfolio({
    connection: {
      provider: status.provider || "IBKR Third-Party Reports",
      institution: status.institution || "Interactive Brokers",
      registered: Boolean(status.registered ?? true),
      configured: true,
      status: "error",
      message: error.message,
      storage: status.storage || "per_user_encrypted_sqlite",
      updatedAt: status.updatedAt,
      lastConnectedAt: status.lastConnectedAt || "",
      lastError: error.message
    },
    accounts: [],
    holdings: [],
    transactions: [],
    performance: [],
    dividends: [],
    source: {
      label: "User portfolio connection",
      mode: "error",
      userScoped: Boolean(user?.id)
    }
  });
}

function isoDate(value = new Date()) {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return new Date().toISOString().slice(0, 10);
  return parsed.toISOString().slice(0, 10);
}

function normalizeReportDate(value) {
  const raw = String(value || "").trim();
  if (/^\d{8}$/.test(raw)) return `${raw.slice(0, 4)}-${raw.slice(4, 6)}-${raw.slice(6, 8)}`;
  return raw ? isoDate(raw) : isoDate();
}

function portfolioSample() {
  const holdings = [
    { ticker: "AAPL", name: "Apple Inc.", sector: "Technology", quantity: 318, price: 209.43, costBasis: 54320, dayChange: 0.006 },
    { ticker: "MSFT", name: "Microsoft Corporation", sector: "Technology", quantity: 142, price: 478.91, costBasis: 61240, dayChange: 0.004 },
    { ticker: "NVDA", name: "NVIDIA Corporation", sector: "Semiconductors", quantity: 396, price: 143.85, costBasis: 39210, dayChange: 0.014 },
    { ticker: "AMZN", name: "Amazon.com, Inc.", sector: "Consumer Internet", quantity: 224, price: 188.77, costBasis: 34480, dayChange: -0.003 },
    { ticker: "GOOGL", name: "Alphabet Inc.", sector: "Communication Services", quantity: 206, price: 178.22, costBasis: 31390, dayChange: 0.002 },
    { ticker: "TSM", name: "Taiwan Semiconductor", sector: "Semiconductors", quantity: 188, price: 205.18, costBasis: 29200, dayChange: 0.009 },
    { ticker: "CASH", name: "USD Cash", sector: "Cash", quantity: 38750, price: 1, costBasis: 38750, dayChange: 0 }
  ].map((holding) => ({
    ...holding,
    value: holding.quantity * holding.price,
    unrealizedPnl: holding.quantity * holding.price - holding.costBasis
  }));

  return attachStoredDividendCalendar(normalizePortfolio({
    connection: {
      provider: "Yodlee / IBKR",
      institution: "Interactive Brokers",
      configured: false,
      status: "not_configured",
      message: "IBKR/Yodlee credentials are not configured. Showing local sample structure."
    },
    accounts: [
      {
        id: "sample-ibkr",
        provider: "Interactive Brokers",
        name: "IBKR Individual",
        accountType: "Brokerage",
        currency: "USD",
        value: holdings.reduce((sum, holding) => sum + holding.value, 0),
        cash: 38750,
        status: "sample"
      }
    ],
    holdings,
    transactions: [],
    source: {
      label: "Portfolio module sample",
      mode: "sample"
    }
  }));
}

function addDays(date, days) {
  const next = new Date(date);
  next.setDate(next.getDate() + days);
  return next;
}

function percentLabel(value) {
  if (!Number.isFinite(value)) return "";
  const sign = value >= 0 ? "+" : "";
  return `${sign}${(value * 100).toFixed(1)}%`;
}

function clamp(value, min, max) {
  if (!Number.isFinite(value)) return null;
  return Math.max(min, Math.min(max, value));
}

function mean(values) {
  const clean = values.filter(Number.isFinite);
  if (!clean.length) return null;
  return clean.reduce((sum, value) => sum + value, 0) / clean.length;
}

function standardDeviation(values) {
  const avg = mean(values);
  if (avg == null) return null;
  const clean = values.filter(Number.isFinite);
  if (clean.length < 2) return null;
  const variance = clean.reduce((sum, value) => sum + (value - avg) ** 2, 0) / (clean.length - 1);
  return Math.sqrt(variance);
}

function productReturn(returns) {
  const clean = returns.filter(Number.isFinite);
  if (!clean.length) return null;
  return clean.reduce((value, dailyReturn) => value * (1 + dailyReturn), 1) - 1;
}

function annualizedReturn(totalReturn, dailyCount) {
  if (!Number.isFinite(totalReturn) || !dailyCount || dailyCount <= 0 || totalReturn <= -0.999) return null;
  return (1 + totalReturn) ** (252 / dailyCount) - 1;
}

function annualizedVolatility(returns) {
  const stdev = standardDeviation(returns);
  return stdev == null ? null : stdev * Math.sqrt(252);
}

function sharpeRatio(annualReturn, annualVolatility, riskFreeRate) {
  if (!Number.isFinite(annualReturn) || !Number.isFinite(annualVolatility) || annualVolatility <= 0) return null;
  return (annualReturn - riskFreeRate) / annualVolatility;
}

function trailingReturnFromPoints(points) {
  if (!points.length) return null;
  const first = points.find((point) => finiteNumber(point.close, NaN) > 0);
  const last = [...points].reverse().find((point) => finiteNumber(point.close, NaN) > 0);
  if (!first || !last || first === last) return null;
  return finiteNumber(last.close) / finiteNumber(first.close) - 1;
}

function dailyReturnMap(points) {
  const map = new Map();
  const returns = [];
  let previous = null;
  for (const point of points) {
    const close = finiteNumber(point.close, NaN);
    if (!Number.isFinite(close) || close <= 0) continue;
    if (previous?.close > 0) {
      const dailyReturn = close / previous.close - 1;
      if (Number.isFinite(dailyReturn)) {
        map.set(point.date, dailyReturn);
        returns.push(dailyReturn);
      }
    }
    previous = { date: point.date, close };
  }
  return { map, returns };
}

function valuationLabel(gap) {
  if (!Number.isFinite(gap)) {
    return { key: "missing", label: "No model", labelZh: "无估值", tone: "neutral" };
  }
  if (gap >= 0.18) return { key: "cheap", label: "Undervalued", labelZh: "偏便宜", tone: "positive" };
  if (gap <= -0.18) return { key: "expensive", label: "Expensive", labelZh: "偏贵", tone: "negative" };
  return { key: "fair", label: "Fair range", labelZh: "接近公允", tone: "neutral" };
}

function valuationMapFromDashboard(dashboard) {
  const map = new Map();
  for (const row of dashboard?.tickers || []) {
    for (const key of valuationLookupKeysForSnapshot(row)) {
      map.set(key, row);
    }
    if (row.key) {
      for (const key of valuationTickerCandidates(row.key, {
        currency: row.currency,
        companyName: row.companyName || row.name
      })) {
        map.set(key, row);
      }
    }
  }
  return map;
}

function portfolioPriceSymbols(holding = {}) {
  const normalized = normalizeTicker(holding.ticker);
  if (!normalized || normalized.startsWith("CASH")) return [];
  if (factOsEnabled()) {
    const listing = canonicalListingRequest(holding);
    return listing.unavailable ? [] : [listing.ticker];
  }
  return marketTickerCandidates(normalized, {
    currency: holding.currency,
    companyName: holding.name || holding.companyName
  });
}

function valuationForHolding(valuationMap, holding = {}) {
  for (const candidate of valuationTickerCandidates(holding.ticker, {
    currency: holding.currency,
    companyName: holding.name || holding.companyName
  })) {
    const valuation = valuationMap.get(candidate);
    if (valuation) return valuation;
  }
  return null;
}

function buildValuationOverlay(holding, valuationRow) {
  const latest = valuationRow?.latest || {};
  const modelPrice = finiteNumber(latest.latestPrice, NaN);
  const fairValue = finiteNumber(latest.baseFairValue, NaN);
  const targetPrice3Y = finiteNumber(latest.targetPrice3Y, NaN);
  const expectedReturn3Y = finiteNumber(latest.expectedReturn3Y, NaN);
  const fallbackGap = finiteNumber(latest.upsideToBase, NaN);
  const gap = Number.isFinite(modelPrice) && modelPrice > 0 && Number.isFinite(fairValue)
    ? fairValue / modelPrice - 1
    : fallbackGap;
  const label = valuationLabel(gap);

  if (!valuationRow || (!Number.isFinite(gap) && !Number.isFinite(fairValue))) {
    return {
      covered: false,
      ticker: normalizeTicker(holding.ticker),
      label: label.label,
      labelZh: label.labelZh,
      tone: label.tone
    };
  }

  return {
    covered: true,
    ticker: normalizeTicker(valuationRow.ticker || holding.ticker),
    name: valuationRow.name || valuationRow.companyName || holding.name,
    currency: valuationRow.currency || holding.currency || "USD",
    latestPrice: Number.isFinite(modelPrice) ? modelPrice : finiteNumber(holding.price, null),
    latestPriceDate: latest.latestPriceDate || "",
    fairValue: Number.isFinite(fairValue) ? fairValue : null,
    gap: Number.isFinite(gap) ? gap : null,
    targetPrice3Y: Number.isFinite(targetPrice3Y) ? targetPrice3Y : null,
    expectedReturn3Y: Number.isFinite(expectedReturn3Y) ? expectedReturn3Y : null,
    priceSource: Number.isFinite(modelPrice)
      ? latest.latestPriceSource || "legacy_model_quote"
      : "broker_reported_mark",
    publishedModelStatus:
      valuationRow.publishedModelStatus ||
      valuationRow.dataQuality?.publishedModelStatus ||
      latest.publishedModelStatus ||
      null,
    modelInputPolicy:
      valuationRow.dataQuality?.modelInputPolicy ||
      latest.modelInputPolicy ||
      null,
    label: label.label,
    labelZh: label.labelZh,
    tone: label.tone,
    coverageKind: valuationRow.dataQuality?.valuationCoverageKind || "",
    auditStatus: valuationRow.dataQuality?.modelInputAudit?.status || "",
    model: valuationRow.model || null
  };
}

function modelImpliedForwardReturn({ valuation, trailingReturn }) {
  const gap = finiteNumber(valuation?.gap, NaN);
  const expectedReturn3Y = finiteNumber(valuation?.expectedReturn3Y, NaN);
  const momentum = clamp(trailingReturn, -0.25, 0.35);
  const oneYearGapConvergence = Number.isFinite(gap) ? clamp(gap * 0.55, -0.35, 0.65) : null;
  const targetReturn = Number.isFinite(expectedReturn3Y) ? clamp(expectedReturn3Y, -0.25, 0.45) : null;
  const components = [];
  if (oneYearGapConvergence != null) components.push({ weight: 0.62, value: oneYearGapConvergence });
  if (targetReturn != null) components.push({ weight: 0.28, value: targetReturn });
  if (momentum != null) components.push({ weight: components.length ? 0.10 : 0.35, value: momentum });
  if (!components.length) return null;
  const weightSum = components.reduce((sum, item) => sum + item.weight, 0);
  return components.reduce((sum, item) => sum + item.value * item.weight, 0) / weightSum;
}

async function attachPortfolioAnalytics(payload) {
  if (factOsEnabled()) {
    const calendar = await loadDividendCalendarForTickers(payload.holdings || []);
    payload = {
      ...payload,
      dividendCalendar: calendar.events,
      dividendCalendarStatus: calendar.status
    };
  }
  try {
    const riskFreeRate = finiteNumber(process.env.PORTFOLIO_ANALYTICS_RISK_FREE_RATE, 0.04);
    const today = new Date();
    const end = isoDate(today);
    const start = isoDate(addDays(today, -400));
    const valuationDashboard = await loadValuationDashboard();
    const valuationMap = valuationMapFromDashboard(valuationDashboard);
    const investableHoldings = (payload.holdings || [])
      .filter((holding) => {
        const ticker = normalizeTicker(holding.ticker);
        return ticker && !ticker.startsWith("CASH") && finiteNumber(holding.value) > 0;
      });

    const analyticsRows = [];
    const returnsByTicker = new Map();
    const weightsByTicker = new Map();
    let pricedWeight = 0;
    let modelWeight = 0;
    let weightedForwardReturn = 0;

    for (const holding of investableHoldings) {
      const ticker = normalizeTicker(holding.ticker);
      const valuation = buildValuationOverlay(holding, valuationForHolding(valuationMap, holding));
      let priceSymbol = "";
      let pricePoints = [];
      for (const candidate of portfolioPriceSymbols(holding)) {
        const candidatePoints = factOsEnabled()
          ? (await loadPriceSeries(candidate, {
              start,
              end,
              priceType: "TOTAL_RETURN_ADJUSTED_CLOSE"
            })).points
          : readPriceSeriesFromDb(candidate, start, end);
        if (candidatePoints.length > pricePoints.length) {
          priceSymbol = candidate;
          pricePoints = candidatePoints;
        }
        if (candidatePoints.length >= 120) break;
      }
      const { map, returns } = dailyReturnMap(pricePoints);
      const trailingReturn = trailingReturnFromPoints(pricePoints);
      const volatility = annualizedVolatility(returns);
      const weight = finiteNumber(holding.weight);
      const forwardReturn = modelImpliedForwardReturn({ valuation, trailingReturn });
      const coverage = pricePoints.length >= 120 ? "full" : pricePoints.length >= 40 ? "partial" : "limited";

      if (map.size) {
        returnsByTicker.set(ticker, map);
        weightsByTicker.set(ticker, weight);
        pricedWeight += weight;
      }
      if (valuation.covered) modelWeight += weight;
      if (Number.isFinite(forwardReturn)) weightedForwardReturn += weight * forwardReturn;

      analyticsRows.push({
        ticker,
        name: holding.name || valuation.name || ticker,
        logoUrl: holding.logoUrl || `/api/logo/${ticker}`,
        value: finiteNumber(holding.value),
        weight,
        valuation,
        trailingReturn,
        annualVolatility: volatility,
        forwardExpectedReturn: Number.isFinite(forwardReturn) ? forwardReturn : null,
        expectedContribution: Number.isFinite(forwardReturn) ? weight * forwardReturn : null,
        pricePointCount: pricePoints.length,
        coverage
      });
    }

    const allReturnDates = [...new Set(
      [...returnsByTicker.values()].flatMap((map) => [...map.keys()])
    )].sort();
    const portfolioReturns = [];
    const dailyCoverage = [];
    for (const date of allReturnDates) {
      let dailyReturn = 0;
      let coverageWeight = 0;
      for (const [ticker, map] of returnsByTicker.entries()) {
        if (!map.has(date)) continue;
        const weight = weightsByTicker.get(ticker) || 0;
        dailyReturn += weight * map.get(date);
        coverageWeight += weight;
      }
      if (coverageWeight >= 0.55) {
        portfolioReturns.push(dailyReturn);
        dailyCoverage.push(coverageWeight);
      }
    }

    const historicalTotalReturn = productReturn(portfolioReturns);
    const historicalAnnualReturn = annualizedReturn(historicalTotalReturn, portfolioReturns.length);
    const historicalVolatility = annualizedVolatility(portfolioReturns);
    const historicalSharpe = sharpeRatio(historicalAnnualReturn, historicalVolatility, riskFreeRate);
    const forwardVolatility = Number.isFinite(historicalVolatility) ? historicalVolatility * 1.05 : null;
    const forwardSharpe = sharpeRatio(weightedForwardReturn, forwardVolatility, riskFreeRate);
    const averageCoverage = mean(dailyCoverage);

    const enrichedHoldings = (payload.holdings || []).map((holding) => {
      const ticker = normalizeTicker(holding.ticker);
      const analytics = analyticsRows.find((row) => row.ticker === ticker);
      if (!analytics) {
        return {
          ...holding,
          valuation: buildValuationOverlay(holding, valuationForHolding(valuationMap, holding)),
          analytics: null
        };
      }
      return {
        ...holding,
        valuation: analytics.valuation,
        analytics: {
          trailingReturn: analytics.trailingReturn,
          annualVolatility: analytics.annualVolatility,
          forwardExpectedReturn: analytics.forwardExpectedReturn,
          expectedContribution: analytics.expectedContribution,
          coverage: analytics.coverage,
          pricePointCount: analytics.pricePointCount
        }
      };
    });

    return {
      ...payload,
      holdings: enrichedHoldings,
      analytics: {
        generatedAt: new Date().toISOString(),
        source: {
          valuation: valuationDashboard?.source?.label || "valuation dashboard",
          prices: portfolioAnalyticsPriceSource(),
          methodology: "Current-weight reconstruction; historical risk from one-year daily returns; forward return from partial fair-value gap convergence, 3Y model IRR, and capped momentum."
        },
        assumptions: {
          riskFreeRate,
          tradingDays: 252,
          gapConvergenceOneYear: 0.55,
          forwardVolatilityStressMultiplier: 1.05
        },
        coverage: {
          holdingCount: investableHoldings.length,
          valuationCovered: analyticsRows.filter((row) => row.valuation?.covered).length,
          valuationCoveredWeight: modelWeight,
          priceCovered: analyticsRows.filter((row) => row.pricePointCount >= 120).length,
          priceCoveredWeight: pricedWeight,
          averageDailyWeightCoverage: averageCoverage
        },
        window: {
          start,
          end,
          dailyReturnCount: portfolioReturns.length
        },
        historicalOneYear: {
          totalReturn: historicalTotalReturn,
          annualizedReturn: historicalAnnualReturn,
          volatility: historicalVolatility,
          sharpe: historicalSharpe,
          riskFreeRate
        },
        forwardOneYear: {
          expectedReturn: weightedForwardReturn,
          volatility: forwardVolatility,
          sharpe: forwardSharpe,
          potentialPnl: finiteNumber(payload.summary?.totalValue) * weightedForwardReturn,
          riskFreeRate
        },
        holdings: analyticsRows
          .sort((left, right) => finiteNumber(right.value) - finiteNumber(left.value))
          .map((row) => ({
            ...row,
            valuationGapLabel: row.valuation?.label || "No model",
            valuationGapLabelZh: row.valuation?.labelZh || "无估值",
            trailingReturnLabel: percentLabel(row.trailingReturn),
            volatilityLabel: percentLabel(row.annualVolatility),
            forwardExpectedReturnLabel: percentLabel(row.forwardExpectedReturn)
          }))
      }
    };
  } catch (error) {
    return {
      ...payload,
      analytics: {
        generatedAt: new Date().toISOString(),
        status: "error",
        message: error.message,
        holdings: []
      }
    };
  }
}

function isLondonPortfolioTicker(value) {
  const ticker = normalizeTicker(value);
  return marketTickerCandidates(ticker).some((candidate) => candidate.endsWith(".L"));
}

function isSterlingPortfolioCurrency(value) {
  return isSterlingCurrency(value);
}

function asArray(value) {
  if (value === null || value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

function textValue(value, fallback = "") {
  if (value === null || value === undefined) return fallback;
  const text = String(value).trim();
  return text || fallback;
}

function pick(row, keys, fallback = "") {
  for (const key of keys) {
    if (row && row[key] !== undefined && row[key] !== null && row[key] !== "") return row[key];
  }
  return fallback;
}

function collectByKey(node, key, output = []) {
  if (!node || typeof node !== "object") return output;
  if (Array.isArray(node)) {
    for (const item of node) collectByKey(item, key, output);
    return output;
  }
  for (const [name, value] of Object.entries(node)) {
    if (name === key) output.push(...asArray(value));
    collectByKey(value, key, output);
  }
  return output;
}

function normalizeYodleeAccount(account) {
  const balance = account.balance || account.currentBalance || account.availableBalance || {};
  return {
    id: String(account.id || account.accountId || account.providerAccountId || ""),
    provider: account.providerName || account.provider || "Yodlee",
    name: account.accountName || account.nickname || account.name || "Brokerage account",
    accountType: account.accountType || account.CONTAINER || account.container || "investment",
    currency: balance.currency || account.currency || "USD",
    value: finiteNumber(balance.amount ?? account.balance?.amount ?? account.value),
    cash: finiteNumber(account.cash?.amount ?? account.cash),
    status: account.accountStatus || account.status || "linked"
  };
}

function normalizeYodleeHolding(holding) {
  const security = holding.security || holding.securityDetail || {};
  const price = finiteNumber(holding.price?.amount ?? holding.price ?? security.price);
  const quantity = finiteNumber(holding.quantity ?? holding.units ?? holding.shares);
  const value = finiteNumber(
    holding.value?.amount ??
      holding.marketValue?.amount ??
      holding.marketValue ??
      holding.value,
    quantity * price
  );
  const costBasis = finiteNumber(holding.costBasis?.amount ?? holding.costBasis);
  const rawTicker = security.symbol || holding.symbol || holding.ticker;
  const currency = String(holding.currency || security.currency || "USD").trim() || "USD";
  const companyName = security.description || security.name || holding.description || holding.name || "Security";
  return {
    ticker: portfolioDisplayTicker(rawTicker, { currency, companyName }),
    name: companyName,
    sector: security.sector || holding.sector || "Unclassified",
    quantity,
    price,
    value,
    costBasis,
    unrealizedPnl: costBasis ? value - costBasis : finiteNumber(holding.unrealizedPnl),
    currency,
    dayChange: finiteNumber(holding.dayChangePercent ?? holding.changePercent)
  };
}

async function yodleeGet(path, connection = {}) {
  const baseUrl = String(connection.yodleeBaseUrl || yodleeBaseUrl || "").replace(/\/+$/, "");
  const accessToken = connection.yodleeAccessToken || yodleeAccessToken;
  const providerAccountId = connection.yodleeProviderAccountId || yodleeProviderAccountId;
  if (!baseUrl || !accessToken) {
    throw new Error("Yodlee credentials are not configured.");
  }
  const url = new URL(`${baseUrl}${path}`);
  if (providerAccountId) url.searchParams.set("providerAccountId", providerAccountId);
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
      Accept: "application/json"
    },
    signal: AbortSignal.timeout(20_000)
  });
  if (!response.ok) {
    throw new Error(`Yodlee ${path} failed with ${response.status}`);
  }
  return response.json();
}

async function fetchXml(url, label) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/xml,text/xml,*/*",
      "User-Agent": "ThesisForge-Portfolio/1.0"
    },
    signal: AbortSignal.timeout(30_000)
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`${label} failed with ${response.status}`);
  }
  return body;
}

function flexResponseRoot(parsed) {
  return parsed.FlexStatementResponse || parsed.FlexQueryResponse || parsed;
}

function flexErrorMessage(root, fallback) {
  return [
    root.ErrorMessage,
    root.errorMessage,
    root.Message,
    root.message,
    root.ErrorCode ? `Error ${root.ErrorCode}` : "",
    root.errorCode ? `Error ${root.errorCode}` : ""
  ]
    .filter(Boolean)
    .join(" · ") || fallback;
}

function normalizePathname(pathname) {
  return String(pathname || "").replace(/\/+$/, "");
}

function isAllowedIbkrFlexEndpoint(url) {
  try {
    const parsed = url instanceof URL ? url : new URL(String(url));
    return (
      parsed.protocol === "https:" &&
      ibkrFlexEndpointHosts.has(parsed.hostname.toLowerCase()) &&
      normalizePathname(parsed.pathname).toLowerCase() ===
        "/accountmanagement/flexwebservice"
    );
  } catch (_error) {
    return false;
  }
}

function isAllowedIbkrFlexStatementUrl(url) {
  try {
    const parsed = url instanceof URL ? url : new URL(String(url));
    if (parsed.protocol !== "https:") return false;
    const host = parsed.hostname.toLowerCase();
    if (!ibkrFlexStatementHosts.has(host)) return false;
    const path = normalizePathname(parsed.pathname).toLowerCase();
    if (
      (host === "ndcdyn.interactivebrokers.com" ||
        host === "gdcdyn.interactivebrokers.com") &&
      path === "/accountmanagement/flexwebservice/getstatement"
    ) {
      return true;
    }
    return (
      host === "www.interactivebrokers.com" &&
      path === "/universal/servlet/flexstatementservice.getstatement"
    );
  } catch (_error) {
    return false;
  }
}

function flexStatementUrlFromRoot(root, flexBaseUrl) {
  const returnedUrl = textValue(
    root.Url || root.url || root.URL || root.StatementUrl || root.statementUrl
  );
  return returnedUrl ? new URL(returnedUrl) : new URL(`${flexBaseUrl}/GetStatement`);
}

function safeUrlLocation(url) {
  try {
    const parsed = url instanceof URL ? url : new URL(String(url));
    return `${parsed.hostname}${parsed.pathname}`;
  } catch (_error) {
    return "invalid_url";
  }
}

export async function loadIbkrFlexXml(queryId = ibkrFlexQueryId, connection = {}, range = {}) {
  const dates = ibkrReportRange(range);
  const flexToken = connection.ibkrFlexToken || ibkrFlexToken;
  const flexBaseUrl = String(connection.ibkrFlexBaseUrl || ibkrFlexBaseUrl).replace(/\/+$/, "");
  if (!flexToken || !queryId) {
    throw new Error("IBKR Flex token/query id are not configured.");
  }
  if (!isAllowedIbkrFlexEndpoint(flexBaseUrl)) {
    throw new Error("IBKR Flex endpoint is not allowed.");
  }
  const sendUrl = new URL(`${flexBaseUrl}/SendRequest`);
  sendUrl.searchParams.set("t", flexToken);
  sendUrl.searchParams.set("q", queryId);
  sendUrl.searchParams.set("v", "3");
  for (const [key, value] of Object.entries(dates)) sendUrl.searchParams.set(key, value);

  const sendXml = await fetchXml(sendUrl, "IBKR Flex SendRequest");
  const sendParsed = xmlParser.parse(sendXml);
  const sendRoot = flexResponseRoot(sendParsed);
  const status = textValue(sendRoot.Status || sendRoot.status).toLowerCase();
  if (status && status !== "success" && status !== "ok") {
    throw new Error(`IBKR SendRequest: ${flexErrorMessage(sendRoot, "Request failed.")}`);
  }

  const referenceCode = textValue(
    sendRoot.ReferenceCode || sendRoot.referenceCode || sendRoot.Reference || sendRoot.reference
  );
  if (!referenceCode) {
    throw new Error("IBKR Flex response did not include a reference code.");
  }

  const statementUrl = flexStatementUrlFromRoot(sendRoot, flexBaseUrl);
  if (!isAllowedIbkrFlexStatementUrl(statementUrl)) {
    throw new Error(
      `IBKR Flex statement URL host/path is not allowed: ${safeUrlLocation(statementUrl)}`
    );
  }
  statementUrl.searchParams.set("t", flexToken);
  statementUrl.searchParams.set("q", referenceCode);
  statementUrl.searchParams.set("v", "3");

  const delays = [800, 1600, 3200, 5000, 8000, 12_000, 15_000];
  let lastError = null;
  for (let attempt = 0; attempt < delays.length; attempt += 1) {
    if (attempt > 0) await new Promise((resolve) => setTimeout(resolve, delays[attempt - 1]));
    const statementXml = await fetchXml(statementUrl, "IBKR Flex GetStatement");
    const parsed = xmlParser.parse(statementXml);
    if (
      parsed.FlexStatement ||
      parsed.FlexStatements ||
      parsed.FlexQueryResponse?.FlexStatements ||
      parsed.FlexStatementResponse?.FlexStatements
    ) {
      return parsed;
    }
    if (parsed.FlexQueryResponse || parsed.FlexStatementResponse) {
      const root = flexResponseRoot(parsed);
      const rootStatus = textValue(root.Status || root.status).toLowerCase();
      lastError = new Error(`IBKR GetStatement: ${flexErrorMessage(root, "Statement is not ready.")}`);
      if (rootStatus === "success" || rootStatus === "ok") continue;
      if (/not ready|processing|try again|temporarily/i.test(lastError.message)) continue;
      throw lastError;
    }
    return parsed;
  }
  throw lastError || new Error("IBKR Flex statement was not ready.");
}

function normalizeIbkrPosition(row) {
  const assetCategory = textValue(pick(row, ["assetCategory", "category", "type"], "Security"));
  const rawSymbol = pick(row, [
    "symbol",
    "underlyingSymbol",
    "ticker",
    "conidSymbol",
    "isin",
    "cusip",
    "description"
  ]);
  const symbol = normalizeTicker(
    rawSymbol
  );
  if (!symbol) return null;
  const name = textValue(pick(row, ["description", "name", "issuer"], symbol), symbol);
  const currency = textValue(pick(row, ["currency", "currencyPrimary"], "USD"), "USD");
  const displayTicker = portfolioDisplayTicker(symbol, { currency, companyName: name });
  const underlyingTicker = normalizeTicker(
    pick(row, ["underlyingSymbol", "underlying", "rootSymbol"], "")
  );
  const logoTicker = underlyingTicker || canonicalTicker(displayTicker) || displayTicker || symbol;
  const quantity = finiteNumber(pick(row, ["quantity", "position", "shares", "units"]));
  const price = finiteNumber(pick(row, ["markPrice", "price", "closePrice", "reportDatePrice"]));
  const fxRateToBase = finiteNumber(pick(row, ["fxRateToBase", "fxRate"], 1), 1);
  const localValue = finiteNumber(
    pick(row, ["positionValue", "marketValue", "value", "currentValue", "notionalValue"]),
    quantity * price
  );
  const localCostBasis = finiteNumber(
    pick(row, ["costBasisMoney", "costBasis", "fifoPnlUnrealizedStart", "costBasisValue"])
  );
  const localUnrealizedPnl = finiteNumber(
    pick(row, ["fifoPnlUnrealized", "unrealizedPnl", "unrealizedPNL"]),
    localCostBasis ? localValue - localCostBasis : 0
  );
  const value = localValue * fxRateToBase;
  const costBasis = localCostBasis * fxRateToBase;
  const unrealizedPnl = localUnrealizedPnl * fxRateToBase;
  return {
    ticker: displayTicker,
    name,
    sector: assetCategory,
    quantity,
    price,
    value,
    costBasis,
    unrealizedPnl,
    fxRateToBase,
    currency,
    logoUrl: logoUrlForTicker(logoTicker, name),
    dayChange: 0,
    analysisPosition: {
      // Preserve reported inputs separately from legacy display heuristics.
      ticker: displayTicker, name, assetCategory,
      currency: textValue(pick(row, ["currency", "currencyPrimary"], "")),
      cusip: textValue(row.cusip || ""),
      quantity: finiteNumber(pick(row, ["quantity", "position", "shares", "units"]), NaN),
      price: finiteNumber(pick(row, ["markPrice", "price", "closePrice", "reportDatePrice"]), NaN),
      fxRateToBase: finiteNumber(pick(row, ["fxRateToBase", "fxRate"]), NaN),
      localValue: finiteNumber(pick(row, ["positionValue", "marketValue", "value", "currentValue"]), NaN)
    }
  };
}

function normalizeIbkrCash(row) {
  const currency = textValue(pick(row, ["currency", "reportCurrency", "baseCurrency"], "USD"), "USD");
  const levelOfDetail = textValue(row.levelOfDetail || "");
  if (currency !== "BASE_SUMMARY" && levelOfDetail !== "BaseCurrency") return null;
  const value = finiteNumber(
    pick(row, [
      "endingCash",
      "endingSettledCash",
      "settledCash",
      "cashBalance",
      "totalCash",
      "value",
      "amount"
    ])
  );
  if (!value) return null;
  return {
    ticker: "CASH",
    name: "Base Currency Cash",
    sector: "Cash",
    quantity: value,
    price: 1,
    value,
    costBasis: value,
    unrealizedPnl: 0,
    currency: "USD",
    dayChange: 0
  };
}

function combineHoldings(rows) {
  const byTicker = new Map();
  for (const row of rows) {
    if (!row || !row.ticker) continue;
    const key = row.ticker;
    const existing = byTicker.get(key);
    if (!existing) {
      byTicker.set(key, { ...row });
      continue;
    }
    const nextValue = finiteNumber(existing.value) + finiteNumber(row.value);
    const nextQuantity = finiteNumber(existing.quantity) + finiteNumber(row.quantity);
    byTicker.set(key, {
      ...existing,
      quantity: nextQuantity,
      value: nextValue,
      price: nextQuantity ? nextValue / nextQuantity : finiteNumber(row.price),
      costBasis: finiteNumber(existing.costBasis) + finiteNumber(row.costBasis),
      unrealizedPnl: finiteNumber(existing.unrealizedPnl) + finiteNumber(row.unrealizedPnl)
    });
  }
  return [...byTicker.values()];
}

function safeHoldingQuantity(holding = {}) {
  const quantity = finiteNumber(holding.quantity ?? holding.shares ?? holding.units ?? holding.position, NaN);
  const rawPrice = finiteNumber(holding.price ?? holding.markPrice ?? holding.closePrice ?? holding.reportDatePrice, NaN);
  const currency = textValue(holding.currency || holding.currencyPrimary || "USD", "USD");
  const ticker = normalizeTicker(holding.ticker || holding.symbol || holding.underlyingSymbol);
  const fxRateToBase = Math.max(0.000001, finiteNumber(holding.fxRateToBase ?? holding.fxRate, 1));
  const value = finiteNumber(
    holding.value?.amount ?? holding.marketValue?.amount ?? holding.marketValue ?? holding.positionValue ?? holding.value,
    NaN
  );
  let price = rawPrice;
  if (isSterlingPortfolioCurrency(currency) && rawPrice > 100) {
    const pencePrice = rawPrice / 100;
    const canCompareValue = Number.isFinite(quantity) && quantity > 0 && Number.isFinite(value) && value > 0;
    if (canCompareValue) {
      const rawError = Math.abs(quantity * rawPrice * fxRateToBase - value) / Math.max(1, Math.abs(value));
      const penceError = Math.abs(quantity * pencePrice * fxRateToBase - value) / Math.max(1, Math.abs(value));
      if (penceError < rawError && (penceError < 0.35 || rawError > 0.5)) price = pencePrice;
    } else if (isLondonPortfolioTicker(ticker) && rawPrice >= 1000) {
      price = pencePrice;
    }
  }
  if (!Number.isFinite(price) || price <= 0 || !Number.isFinite(value) || value <= 0) {
    return Number.isFinite(quantity) ? quantity : 0;
  }
  const priceInBase = price * fxRateToBase;
  const impliedQuantity = value / priceInBase;
  if (!Number.isFinite(quantity) || quantity <= 0) return impliedQuantity;
  const valueFromQuantity = quantity * priceInBase;
  const relativeValueError = Math.abs(valueFromQuantity - value) / Math.max(1, Math.abs(value));
  const quantityLooksLikeMarketValue =
    price > 1.01 && value > 100 && Math.abs(quantity - value) / Math.max(1, Math.abs(value)) < 0.03;
  const quantityIsImplausiblyHigh = price > 1.01 && quantity > impliedQuantity * 20;
  if (quantityLooksLikeMarketValue || quantityIsImplausiblyHigh || relativeValueError > 0.5) {
    return impliedQuantity;
  }
  return quantity;
}

function extractPerformance(parsed) {
  const candidates = [
    ...collectByKey(parsed, "EquitySummaryByReportDateInBase"),
    ...collectByKey(parsed, "EquitySummaryByReportDate"),
    ...collectByKey(parsed, "EquitySummaryInBase"),
    ...collectByKey(parsed, "ChangeInNAV")
  ];
  const byDate = new Map();
  candidates
    .map((row) => {
      const value = finiteNumber(
        pick(row, [
          "total",
          "totalEquity",
          "totalEquityInBase",
          "endingValue",
          "endingNAV",
          "endingNetAssetValue",
          "netAssetValue",
          "netLiquidationValue",
          "equityWithLoanValue"
        ])
      );
      const date = pick(row, ["reportDate", "date", "fromDate", "toDate"]);
      return value > 0 && date ? { date: normalizeReportDate(date), value } : null;
    })
    .filter(Boolean)
    .forEach((point) => byDate.set(point.date, point));

  const points = [...byDate.values()].sort((left, right) => left.date.localeCompare(right.date));
  const real = points.length >= 2;
  const singleDate = points[0]?.date;

  return {
    points,
    status: {
      real,
      pointCount: points.length,
      source: real ? "ibkr_flex_equity_summary" : "history_query_required",
      message: real
        ? "Real IBKR net liquidation history from Flex equity summary rows."
        : singleDate
          ? `Current IBKR/Yodlee report returned one NAV point (${singleDate}). ThesisForge will store one account NAV snapshot per day and draw the curve automatically after enough history accumulates.`
          : "Current IBKR/Yodlee report did not include historical NAV rows. ThesisForge will store daily account NAV snapshots from your portfolio refreshes."
    }
  };
}

function normalizeDividendEvent(row) {
  const searchable = [
    row.type,
    row.code,
    row.description,
    row.action,
    row.activityDescription,
    row.transactionType
  ]
    .filter(Boolean)
    .join(" ");
  if (searchable && !/dividend|div/i.test(searchable)) return null;

  const ticker = normalizeTicker(
    pick(row, ["symbol", "underlyingSymbol", "ticker", "conidSymbol", "isin", "description"])
  );
  const exDate = pick(row, ["exDate", "exDividendDate", "exDivDate"]);
  const payDate = pick(row, ["payDate", "paymentDate", "settlementDate", "dateTime", "reportDate"]);
  const recordDate = pick(row, ["recordDate"]);
  const date = exDate || payDate || recordDate || pick(row, ["reportDate", "date"]);
  const amount = finiteNumber(
    pick(row, [
      "amount",
      "netAmount",
      "grossAmount",
      "dividend",
      "dividendAmount",
      "value",
      "proceeds"
    ])
  );
  if (!ticker || !date || !amount) return null;

  return {
    ticker,
    name: textValue(pick(row, ["description", "securityDescription", "name"], ticker), ticker),
    exDate: exDate ? normalizeReportDate(exDate) : "",
    payDate: payDate ? normalizeReportDate(payDate) : "",
    recordDate: recordDate ? normalizeReportDate(recordDate) : "",
    date: normalizeReportDate(date),
    amount,
    currency: textValue(pick(row, ["currency", "currencyPrimary", "reportCurrency"], "USD"), "USD"),
    type: textValue(pick(row, ["type", "transactionType", "action"], "Dividend"), "Dividend"),
    logoUrl: logoUrlForTicker(ticker)
  };
}

function extractDividendCalendar(parsed) {
  const rows = [
    ...collectByKey(parsed, "OpenDividendAccrual"),
    ...collectByKey(parsed, "DividendAccrual"),
    ...collectByKey(parsed, "ChangeInDividendAccrual"),
    ...collectByKey(parsed, "CashTransaction"),
    ...collectByKey(parsed, "CorporateAction")
  ];
  const byKey = new Map();
  for (const row of rows) {
    const event = normalizeDividendEvent(row);
    if (!event) continue;
    byKey.set(
      [event.ticker, event.date, event.amount, event.currency, event.type].join("|"),
      event
    );
  }
  const events = [...byKey.values()].sort((left, right) => {
    const dateOrder = right.date.localeCompare(left.date);
    if (dateOrder) return dateOrder;
    return Math.abs(right.amount) - Math.abs(left.amount);
  });

  return {
    events,
    status: {
      source: events.length ? "ibkr_flex_report" : "not_available",
      pointCount: events.length,
      message: events.length
        ? "Dividend rows were extracted from the IBKR Flex report."
        : "Current IBKR Flex query does not include dividend accruals, cash dividend transactions, or future corporate-action calendar rows."
    }
  };
}

function attachStoredDividendCalendar(payload) {
  const tickerInputs = (payload.holdings || [])
    .filter((holding) => {
      const ticker = normalizeTicker(holding.ticker);
      return ticker && !ticker.startsWith("CASH");
    })
    .map((holding) => ({
      ticker: holding.ticker,
      name: holding.name || holding.companyName || holding.ticker,
      sector: holding.sector || holding.assetCategory || "",
      quantity: safeHoldingQuantity(holding),
      price: finiteNumber(holding.price),
      value: finiteNumber(holding.value),
      currency: holding.currency || "USD",
      fxRateToBase: finiteNumber(holding.fxRateToBase, 1),
      baseCurrency: payload.summary?.currency || "USD"
    }));
  const stored = readDividendCalendarForTickers(tickerInputs);
  const upstreamEvents = payload.dividends || [];
  const useStored = stored.events.length > 0;
  return {
    ...payload,
    dividends: useStored ? stored.events : upstreamEvents,
    dividendStatus: useStored
      ? stored.status
      : upstreamEvents.length
        ? payload.dividendStatus
        : stored.status,
    source: {
      ...payload.source,
      dividendCalendar: {
        source: useStored ? stored.status.source : payload.dividendStatus?.source || stored.status.source,
        pointCount: useStored ? stored.status.pointCount : upstreamEvents.length,
        startDate: stored.status.startDate,
        endDate: stored.status.endDate
      }
    }
  };
}

function attachStoredNavHistory(payload, options = {}) {
  const accountId = textValue(options.accountId || payload.accounts?.[0]?.id, "portfolio");
  const date = normalizeReportDate(
    options.date ||
      payload.source?.toDate ||
      payload.performance?.at(-1)?.date ||
      payload.generatedAt ||
      new Date()
  );
  const nav = finiteNumber(payload.summary?.totalValue);
  if (nav > 0 && options.captureNav !== false) {
    const point = {
      accountId,
      date,
      nav,
      cash: finiteNumber(payload.summary?.cash),
      source: options.source || payload.source?.label || "portfolio",
      sourceDate: options.sourceDate || payload.source?.toDate || date,
      payload: {
        holdings: payload.summary?.holdings,
        accounts: payload.summary?.accounts,
        currency: payload.summary?.currency
      }
    };
    if (options.user) {
      writeUserPortfolioNavPoint(options.user, point);
    } else {
      writePortfolioNavPoint(point);
    }
  }

  const storedPoints = options.user
    ? readUserPortfolioNavPoints(options.user, accountId)
    : readPortfolioNavPoints(accountId);
  if (!storedPoints.length) return payload;

  const useStoredHistory =
    storedPoints.length >= 2 || !truthyPerformanceStatus(payload.performanceStatus);
  if (!useStoredHistory) return payload;

  const real = storedPoints.length >= 2;
  return {
    ...payload,
    performance: storedPoints.map((point) => ({
      date: point.date,
      value: point.value,
      source: point.source || "sqlite_daily_nav"
    })),
    performanceStatus: {
      real,
      pointCount: storedPoints.length,
      source: "sqlite_daily_nav",
      message: real
        ? `Backend database NAV history: ${storedPoints.length} daily points accumulated from IBKR/Yodlee refreshes.`
        : `Captured the first daily NAV point (${storedPoints[0].date}). The chart will draw automatically after at least two daily snapshots.`
    },
    source: {
      ...payload.source,
      navHistory: {
        source: "sqlite_daily_nav",
        accountId,
        pointCount: storedPoints.length,
        startDate: storedPoints[0]?.date || "",
        endDate: storedPoints.at(-1)?.date || ""
      }
    }
  };
}

function truthyPerformanceStatus(status) {
  return status?.real === true || status?.real === "true";
}

export function normalizeIbkrFlexPortfolio(parsed, {
  historyParsed = null,
  historyError = null,
  user = null,
  connectionStatus = null,
  accountConfig = null,
  captureNav = true
} = {}) {
  const statement = collectByKey(parsed, "FlexStatement")[0] || {};
  const accountInfo = collectByKey(parsed, "AccountInformation")[0] || {};
  const equitySummary = collectByKey(parsed, "EquitySummaryByReportDateInBase")[0] || {};
  const openPositions = [
    ...collectByKey(parsed, "OpenPosition"),
    ...collectByKey(parsed, "Position"),
    ...collectByKey(parsed, "Holding")
  ].map(normalizeIbkrPosition);
  const cashRows = [
    ...collectByKey(parsed, "CashReport"),
    ...collectByKey(parsed, "CashReportCurrency"),
    ...collectByKey(parsed, "CashBalance"),
    ...collectByKey(parsed, "Cash")
  ].map(normalizeIbkrCash);
  const holdings = combineHoldings([...openPositions, ...cashRows]);
  const totalValue = holdings.reduce((sum, holding) => sum + finiteNumber(holding.value), 0);
  const accountId = textValue(
    statement.accountId ||
      accountInfo.accountId ||
      statement.accountAlias ||
      statement.account ||
      accountConfig?.id ||
      "ibkr-third-party"
  );
  const accountLabel = textValue(
    accountConfig?.label || statement.accountAlias || statement.accountId || accountId,
    "IBKR account"
  );
  const cash = holdings
    .filter((holding) => /cash/i.test(holding.sector || "") || normalizeTicker(holding.ticker).startsWith("CASH"))
    .reduce((sum, holding) => sum + finiteNumber(holding.value), 0);
  const performance = extractPerformance(historyParsed || parsed);
  const dividendCalendar = extractDividendCalendar(parsed);
  const sourceWarnings = [];
  if (!performance.status.real) sourceWarnings.push(performance.status.message);
  if (historyError) {
    sourceWarnings.push(`Historical IBKR Flex query failed: ${historyError.message}`);
  }
  if (!dividendCalendar.events.length) sourceWarnings.push(dividendCalendar.status.message);

  const payload = normalizePortfolio({
    connection: {
      provider: "IBKR Third-Party Reports",
      institution: "Interactive Brokers",
      registered: true,
      configured: true,
      status: holdings.length ? "linked" : "linked_empty",
      message: holdings.length
        ? "IBKR holdings loaded from the Yodlee third-party report token."
        : "IBKR report connected, but no holdings were returned.",
      storage: connectionStatus?.storage || (user ? "per_user_encrypted_sqlite" : "backend_environment"),
      updatedAt: connectionStatus?.updatedAt,
      lastConnectedAt: connectionStatus?.lastConnectedAt || "",
      tokenPreview: connectionStatus?.tokenPreview || "",
      queryId: connectionStatus?.queryId || accountConfig?.ibkrFlexQueryId || "",
      accountCount: connectionStatus?.accountCount || 1,
      accounts: connectionStatus?.accounts || []
    },
    accounts: [
      {
        id: accountId,
        connectionId: accountConfig?.id || accountId,
        queryId: accountConfig?.ibkrFlexQueryId || "",
        provider: "Interactive Brokers",
        name: accountLabel,
        accountType: "Brokerage",
        currency: textValue(accountInfo.currency || statement.currency || statement.reportCurrency, "USD"),
        value: finiteNumber(equitySummary.total, totalValue),
        cash,
        status: "linked"
      }
    ],
    holdings,
    transactions: [],
    performance: performance.points,
    performanceStatus: historyError
      ? {
          ...performance.status,
          source: "history_query_error",
          message: `Historical IBKR Flex query failed: ${historyError.message}`
        }
      : performance.status,
    dividends: dividendCalendar.events,
    dividendStatus: dividendCalendar.status,
    source: {
      label: "IBKR Third-Party Reports / Yodlee",
      mode: "live",
      userScoped: Boolean(user?.id),
      asOf: statement.toDate
        ? normalizeReportDate(statement.toDate)
        : statement.fromDate
          ? normalizeReportDate(statement.fromDate)
          : statement.whenGenerated || statement.generatedAt
            ? isoDate(statement.whenGenerated || statement.generatedAt)
            : undefined,
      fromDate: statement.fromDate ? normalizeReportDate(statement.fromDate) : undefined,
      toDate: statement.toDate ? normalizeReportDate(statement.toDate) : undefined,
      generatedAt: statement.whenGenerated || statement.generatedAt,
      historyQueryStatus: historyError ? "error" : historyParsed ? "available" : "not_requested",
      warnings: sourceWarnings
    }
  });
  payload.analysisAccounts = reportAnalysisAccounts(parsed,{historyParsed});
  return attachStoredNavHistory(attachStoredDividendCalendar(payload), {
    accountId,
    date: statement.toDate || statement.fromDate,
    source: "IBKR Third-Party Reports / Yodlee",
    sourceDate: statement.toDate || statement.fromDate,
    captureNav,
    user: user || null
  });
}

function normalizePortfolio({
  connection,
  accounts,
  holdings,
  transactions,
  source,
  performance,
  performanceStatus,
  dividends,
  dividendStatus
}) {
  const accountTotalValue = accounts.reduce((sum, account) => sum + finiteNumber(account.value), 0);
  const holdingsTotalValue = holdings.reduce((sum, holding) => sum + finiteNumber(holding.value), 0);
  const totalValue = holdingsTotalValue || accountTotalValue;
  const cash = holdings
    .filter((holding) => normalizeTicker(holding.ticker).startsWith("CASH") || /cash/i.test(holding.sector || ""))
    .reduce((sum, holding) => sum + finiteNumber(holding.value), 0);
  const investedValue = Math.max(0, totalValue - cash);
  const dayPnl = holdings.reduce(
    (sum, holding) => sum + finiteNumber(holding.value) * finiteNumber(holding.dayChange),
    0
  );
  const unrealizedPnl = holdings.reduce(
    (sum, holding) => sum + finiteNumber(holding.unrealizedPnl),
    0
  );
  const normalizedHoldings = holdings
    .map((holding) => {
      const cleanQuantity = safeHoldingQuantity(holding);
      const displayTicker = portfolioDisplayTicker(holding.ticker, {
        currency: holding.currency,
        companyName: holding.name || holding.companyName
      }) || "N/A";
      return {
        ...holding,
        quantity: cleanQuantity,
        ticker: displayTicker,
        logoUrl: holding.logoUrl || logoUrlForTicker(displayTicker, holding.name),
        weight: totalValue > 0 ? finiteNumber(holding.value) / totalValue : 0
      };
    })
    .sort((left, right) => finiteNumber(right.value) - finiteNumber(left.value));
  const bySector = new Map();
  for (const holding of normalizedHoldings) {
    const sector = holding.sector || "Unclassified";
    bySector.set(sector, (bySector.get(sector) || 0) + finiteNumber(holding.value));
  }
  const sectors = [...bySector.entries()]
    .map(([sector, value]) => ({
      sector,
      value,
      weight: totalValue > 0 ? value / totalValue : 0
    }))
    .sort((left, right) => right.value - left.value);

  return {
    generatedAt: new Date().toISOString(),
    source,
    connection,
    summary: {
      totalValue,
      investedValue,
      cash,
      dayPnl,
      dayPnlPct: totalValue > 0 ? dayPnl / totalValue : 0,
      unrealizedPnl,
      unrealizedPnlPct: totalValue > 0 ? unrealizedPnl / totalValue : 0,
      accounts: accounts.length,
      holdings: normalizedHoldings.filter((holding) => !normalizeTicker(holding.ticker).startsWith("CASH")).length,
      topWeight: normalizedHoldings[0]?.weight || 0,
      currency: accounts[0]?.currency || normalizedHoldings[0]?.currency || "USD"
    },
    accounts,
    holdings: normalizedHoldings,
    sectors,
    transactions,
    performance: performance || [],
    performanceStatus: performanceStatus || {
      real: Boolean(performance?.length >= 2),
      pointCount: performance?.length || 0,
      source: performance?.length >= 2 ? "provided" : "not_available",
      message: performance?.length >= 2
        ? "Performance points were provided by the upstream source."
        : "No real portfolio NAV history was returned by the upstream source."
    },
    dividends: dividends || [],
    dividendStatus: dividendStatus || {
      source: dividends?.length ? "provided" : "not_available",
      pointCount: dividends?.length || 0,
      message: dividends?.length
        ? "Dividend events were provided by the upstream source."
        : "No dividend calendar events were returned by the upstream source."
    }
  };
}

function buildSamplePerformance(totalValue) {
  const today = new Date();
  return Array.from({ length: 18 }, (_item, index) => {
    const date = new Date(today);
    date.setMonth(date.getMonth() - (17 - index));
    const growth = 1 + index * 0.018 + Math.sin(index / 2) * 0.025;
    return {
      date: isoDate(date),
      value: Math.round(totalValue * growth * 100) / 100,
      contribution: Math.sin(index / 3) * 0.012
    };
  });
}

async function loadYodleeDashboard(connection = {}, { user = null } = {}) {
  const [accountsPayload, holdingsPayload] = await Promise.all([
    yodleeGet("/accounts", connection),
    yodleeGet("/holdings", connection)
  ]);
  const accounts = (accountsPayload.account || accountsPayload.accounts || []).map(normalizeYodleeAccount);
  const holdings = (holdingsPayload.holding || holdingsPayload.holdings || []).map(normalizeYodleeHolding);
  const payload = normalizePortfolio({
    connection: {
      provider: "Yodlee",
      institution: "Interactive Brokers",
      configured: true,
      status: holdings.length ? "linked" : "linked_empty",
      message: holdings.length
        ? "IBKR holdings synced through Yodlee Core APIs."
        : "Yodlee is configured but returned no holdings."
    },
    accounts,
    holdings,
    transactions: [],
    source: {
      label: "Yodlee Core APIs",
      mode: "live",
      userScoped: Boolean(user?.id)
    }
  });
  return attachStoredNavHistory(attachStoredDividendCalendar(payload), {
    accountId: accounts[0]?.id || "portfolio",
    date: new Date(),
    source: "Yodlee Core APIs",
    user: user || null
  });
}

function aggregatePerformanceSeries(payloads = []) {
  const byDate = new Map();
  for (const payload of payloads) {
    for (const point of payload.performance || []) {
      const date = normalizeReportDate(point.date);
      const value = finiteNumber(point.value);
      if (!date || value <= 0) continue;
      byDate.set(date, (byDate.get(date) || 0) + value);
    }
  }
  return [...byDate.entries()]
    .map(([date, value]) => ({ date, value, source: "multi_account_aggregate" }))
    .sort((left, right) => left.date.localeCompare(right.date));
}

function aggregateDividendEvents(payloads = []) {
  const byKey = new Map();
  for (const payload of payloads) {
    for (const event of payload.dividends || []) {
      const key = [
        event.ticker,
        event.exDate || event.date,
        event.payDate,
        event.amount,
        event.currency
      ].join("|");
      if (!byKey.has(key)) byKey.set(key, event);
    }
  }
  return [...byKey.values()].sort((left, right) =>
    textValue(left.date || left.exDate).localeCompare(textValue(right.date || right.exDate))
  );
}

function aggregateIbkrPortfolios(payloads = [], {
  user = null,
  connectionStatus = null,
  errors = [],
  captureNav = true
} = {}) {
  const accountCount = payloads.reduce((sum, payload) => sum + (payload.accounts?.length || 0), 0);
  const performance = aggregatePerformanceSeries(payloads);
  const errorMessages = errors.map((error) => error?.message || String(error)).filter(Boolean);
  const sourceAsOfDates = payloads
    .map((payload) =>
      payload?.source?.asOf || payload?.source?.toDate || payload?.source?.generatedAt || ""
    )
    .filter((value) => value && !Number.isNaN(new Date(value).getTime()))
    .sort((left, right) => new Date(left).getTime() - new Date(right).getTime());
  const payload = normalizePortfolio({
    connection: {
      provider: "IBKR Third-Party Reports",
      institution: "Interactive Brokers",
      registered: true,
      configured: true,
      status: errorMessages.length ? "linked_partial" : "linked",
      message: errorMessages.length
        ? `Aggregated ${accountCount} IBKR/Yodlee account(s); ${errorMessages.length} account(s) failed to refresh.`
        : `Aggregated ${accountCount} IBKR/Yodlee account(s).`,
      storage: connectionStatus?.storage || (user ? "per_user_encrypted_sqlite" : "backend_environment"),
      updatedAt: connectionStatus?.updatedAt,
      lastConnectedAt: connectionStatus?.lastConnectedAt || "",
      lastError: errorMessages.join(" · "),
      accountCount,
      accounts: connectionStatus?.accounts || []
    },
    accounts: payloads.flatMap((payload) => payload.accounts || []),
    holdings: combineHoldings(payloads.flatMap((payload) => payload.holdings || [])),
    transactions: payloads.flatMap((payload) => payload.transactions || []),
    performance,
    performanceStatus: {
      real: performance.length >= 2,
      pointCount: performance.length,
      source: performance.length >= 2 ? "multi_account_aggregate" : "daily_nav_pending",
      message: performance.length >= 2
        ? `Aggregated NAV curve across ${accountCount} account(s).`
        : "ThesisForge will store one aggregate NAV snapshot per refresh and draw the curve after enough history accumulates."
    },
    dividends: aggregateDividendEvents(payloads),
    dividendStatus: {
      source: "multi_account_aggregate",
      pointCount: aggregateDividendEvents(payloads).length,
      message: "Dividend calendar aggregated across linked accounts."
    },
    source: {
      label: "IBKR Third-Party Reports / Yodlee",
      mode: "multi_account_live",
      asOf: sourceAsOfDates[0] || undefined,
      userScoped: Boolean(user?.id),
      warnings: errorMessages
    }
  });
  payload.analysisAccounts = payloads.flatMap(p => p.analysisAccounts || []);
  return attachStoredNavHistory(attachStoredDividendCalendar(payload), {
    accountId: "portfolio",
    date: new Date(),
    source: "IBKR/Yodlee multi-account aggregate",
    captureNav,
    user: user || null
  });
}

function withConnectionStatus(payload, status = {}) {
  if (!status || !Object.keys(status).length) return payload;
  return {
    ...payload,
    connection: {
      ...payload.connection,
      ...status,
      registered: true,
      configured: true
    }
  };
}

async function loadIbkrAccountPortfolio(connection, accountConfig, {
  user = null,
  connectionStatus = null,
  captureNav = true
} = {}) {
  const accountConnection = {
    ...connection,
    ...accountConfig,
    ibkrFlexBaseUrl: accountConfig.ibkrFlexBaseUrl || connection.ibkrFlexBaseUrl
  };
  const parsed = await loadIbkrFlexXml(accountConfig.ibkrFlexQueryId, accountConnection);
  let historyParsed = null;
  let historyError = null;
  if (
    accountConfig.ibkrFlexHistoryQueryId &&
    accountConfig.ibkrFlexHistoryQueryId !== accountConfig.ibkrFlexQueryId
  ) {
    try {
      historyParsed = await loadIbkrFlexXml(accountConfig.ibkrFlexHistoryQueryId, accountConnection);
    } catch (error) {
      historyError = error;
    }
  } else {
    // The existing template can return daily NAV and trades without a second
    // query ID. A failed history request must not erase the current holdings.
    try {
      historyParsed = await loadIbkrFlexXml(accountConfig.ibkrFlexQueryId, accountConnection, {periodDays:365});
    } catch (error) {
      historyError = error;
    }
  }
  return normalizeIbkrFlexPortfolio(parsed, {
    historyParsed,
    historyError,
    user,
    connectionStatus,
    captureNav,
    accountConfig
  });
}

async function loadFreshPortfolioDashboard({ user = null, captureNav = true } = {}) {
  let connection = null;
  let connectionStatus = null;
  let connectionRevision = null;

  if (isRealUser(user)) {
    const userConnection = readPortfolioConnection(user);
    connectionStatus = userConnection.status;
    if (!userConnection.configured || !userConnection.config) {
      return onboardingPortfolio(user, connectionStatus);
    }
    connection = userConnection.config;
    connectionRevision = userConnection.revision;
  } else {
    connection = legacyPortfolioConnection();
  }

  if (!connection?.configured && !connection?.provider) {
    return portfolioSample();
  }

  if (connection.provider === "ibkr_flex") {
    const accounts = portfolioConnectionAccounts(connection);
    if (!accounts.length) {
      throw new Error("No IBKR/Yodlee accounts are saved for this user.");
    }
    const scopedUser = isRealUser(user) ? user : null;
    const results = await Promise.allSettled(
      accounts.map((account) =>
        loadIbkrAccountPortfolio(connection, account, {
          user: scopedUser,
          connectionStatus,
          captureNav
        })
      )
    );
    const payloads = results
      .filter((result) => result.status === "fulfilled")
      .map((result) => result.value);
    const errors = results
      .filter((result) => result.status === "rejected")
      .map((result) => result.reason);
    if (!payloads.length) throw errors[0] || new Error("All IBKR/Yodlee accounts failed to refresh.");
    const reportErrors = [...errors, ...payloads
      .filter(payload => payload.source?.historyQueryStatus === "error")
      .map(() => new Error("Broker history query failed; current holdings are a partial report."))];
    let latestStatus = connectionStatus;
    if (isRealUser(user)) {
      if (portfolioConnectionRevision(user) !== connectionRevision) {
        throw Object.assign(new Error("Portfolio connection changed during synchronization."), {code:"portfolio_connection_changed"});
      }
      if (reportErrors.length) {
        markPortfolioConnectionSync(user, {ok:false,error:"Some broker accounts could not refresh; saved report retained."});
        const saved = savedPortfolioReportPayload(user);
        if (saved) return saved;
      } else {
        markPortfolioConnectionSync(user, { ok: true });
      }
      latestStatus = readPortfolioConnection(user).status;
    }
    const syncedPayloads = payloads.map((payload) => withConnectionStatus(payload, latestStatus));
    const result = syncedPayloads.length === 1 && accounts.length === 1 && !reportErrors.length
      ? syncedPayloads[0]
      : aggregateIbkrPortfolios(payloads, {
          user: scopedUser,
          connectionStatus: latestStatus,
          captureNav,
          errors: reportErrors
        });
    if (scopedUser && !reportErrors.length) {
      const saved = writeUserPortfolioReport(scopedUser, result, {connectionRevision});
      result.freshness = {status:"current_report",basis:"last_successful_broker_report",...saved,live:false};
    }
    return result;
  }
  if (connection.provider === "yodlee_core") {
    return loadYodleeDashboard(connection, { user: isRealUser(user) ? user : null });
  }

  return isRealUser(user) ? onboardingPortfolio(user, connectionStatus) : portfolioSample();
}

function savedPortfolioReportPayload(user) {
  const saved = readUserPortfolioReport(user);
  if (!saved) return null;
  const status = readPortfolioConnection(user).status;
  const message = `Broker refresh unavailable. Showing the saved report dated ${saved.reportAsOf}; not live quotes.`;
  return {
    ...saved.payload,
    connection: {...status, status:"stale_report", lastError:message, message},
    source: {...saved.payload.source, mode:"saved_broker_report", stale:true,
      retrievedAt:saved.retrievedAt, warnings:[...(saved.payload.source.warnings || []),message]},
    freshness:{status:"stale",basis:"last_successful_broker_report",
      reportAsOf:saved.reportAsOf,retrievedAt:saved.retrievedAt,live:false}
  };
}

export async function loadPortfolioDashboard({ forceRefresh = false, user = null, captureNav = true } = {}) {
  const cacheKey = portfolioCacheKey(user);
  return portfolioCache.load(cacheKey, async () => {
  try {
    const payload = await attachPortfolioAnalytics(await loadFreshPortfolioDashboard({ user, captureNav }));
    return { value: payload, ttlMs: portfolioCacheTtlMs };
  } catch (error) {
    if (isRealUser(user) && error.code !== "portfolio_connection_changed") {
      markPortfolioConnectionSync(user, { ok: false, error: error.message });
    }
    if (isRealUser(user)) {
      const saved = savedPortfolioReportPayload(user);
      if (saved) return {value:await attachPortfolioAnalytics(saved),ttlMs:Math.min(portfolioCacheTtlMs,60_000)};
    }
    const status = isRealUser(user) ? readPortfolioConnection(user).status : {};
    const fallbackPayload = isRealUser(user)
      ? portfolioErrorPayload(user, error, status)
      : {
          ...portfolioSample(),
          connection: {
            provider: ibkrFlexToken ? "IBKR Third-Party Reports" : "Yodlee",
            institution: "Interactive Brokers",
            configured: true,
            status: "error",
            message: error.message
          },
          source: {
            label: ibkrFlexToken
              ? "IBKR Third-Party Reports / Yodlee"
              : "Yodlee portfolio module",
            mode: "fallback"
          }
        };
    const payload = await attachPortfolioAnalytics(fallbackPayload);
    return { value: payload, ttlMs: Math.min(portfolioCacheTtlMs, 60_000) };
  }
  }, { forceRefresh });
}

export function clearPortfolioCache(user = null) {
  portfolioCache.delete(portfolioCacheKey(user));
}

// The scheduled path uses the same per-owner loader as the authenticated Sync
// button. It never falls back to the retired process-wide portfolio identity,
// and it logs only aggregate counts.
export async function syncRegisteredPortfolioUsers({
  listUsers = listAdminPortfolioUsers,
  loadDashboard = loadPortfolioDashboard,
  clearCache = clearPortfolioCache
} = {}) {
  const inventory = await listUsers();
  const targets = (inventory?.users || []).filter((row) =>
    productionUserId.test(String(row?.userId || "")) &&
    row?.connection?.configured === true
  );
  const result = {
    status: targets.length ? "success" : "skipped",
    connected: targets.length,
    attempted: 0,
    synced: 0,
    degraded: 0,
    failed: 0,
    navPoints: 0
  };
  for (const target of targets) {
    const user = { id: target.userId };
    result.attempted += 1;
    try {
      clearCache(user);
      const payload = await loadDashboard({
        user,
        forceRefresh: true,
        captureNav: true
      });
      const current = ["live", "multi_account_live"].includes(payload?.source?.mode) &&
        payload?.freshness?.status !== "stale" &&
        !["error", "stale_report", "linked_partial"].includes(payload?.connection?.status);
      if (current) result.synced += 1;
      else result.degraded += 1;
      result.navPoints += Number(payload?.performanceStatus?.pointCount || 0);
    } catch (_) {
      result.failed += 1;
    } finally {
      clearCache(user);
    }
  }
  if (result.failed || result.degraded) result.status = "degraded";
  return result;
}

export function startPortfolioNavRecorder({
  initialDelayMs = finiteNumber(process.env.PORTFOLIO_NAV_CAPTURE_INITIAL_DELAY_MS, 30_000),
  intervalMs = finiteNumber(process.env.PORTFOLIO_NAV_CAPTURE_INTERVAL_MS, 24 * 60 * 60 * 1000),
  syncUsers = syncRegisteredPortfolioUsers
} = {}) {
  if (portfolioNavRecorderStarted) return;
  portfolioNavRecorderStarted = true;

  const capture = async () => {
    const startedAt = new Date().toISOString();
    writeBackgroundJobRun("portfolio_nav_capture", {
      startedAt,
      status: "running",
      payload: { source: "scheduled-recorder" }
    });
    try {
      const status = await syncUsers();
      writeBackgroundJobRun("portfolio_nav_capture", {
        startedAt,
        finishedAt: new Date().toISOString(),
        status: status.status,
        payload: {
          source: "scheduled-user-sync",
          connected: status.connected,
          attempted: status.attempted,
          synced: status.synced,
          degraded: status.degraded,
          failed: status.failed,
          pointCount: status.navPoints
        }
      });
      console.log(
        `Portfolio daily sync complete: ${status.synced}/${status.connected} current; ${status.degraded} degraded; ${status.failed} failed.`
      );
    } catch (error) {
      writeBackgroundJobRun("portfolio_nav_capture", {
        startedAt,
        finishedAt: new Date().toISOString(),
        status: "failed",
        payload: {
          source: "scheduled-recorder",
          error: error.message
        }
      });
      console.warn(`Portfolio NAV capture failed: ${error.message}`);
    }
  };

  const initialTimer = setTimeout(capture, Math.max(1000, initialDelayMs));
  initialTimer.unref?.();
  const intervalTimer = setInterval(capture, Math.max(60_000, intervalMs));
  intervalTimer.unref?.();
}

export const __portfolioTestInternals = {
  portfolioPriceSymbols,
  portfolioCacheKey,
  portfolioAnalyticsPriceSource,
  buildValuationOverlay,
  isAllowedIbkrFlexEndpoint,
  isAllowedIbkrFlexStatementUrl,
  flexStatementUrlFromRoot,
  safeUrlLocation
};
