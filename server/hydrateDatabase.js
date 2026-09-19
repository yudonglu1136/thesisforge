import { databaseInfo } from "./localDatabase.js";
import { gurus } from "./gurus.js";
import { loadGuruDashboard, loadGuruMarketContext } from "./secClient.js";
import { loadPriceSeries } from "./marketData.js";
import { loadGuruBacktest } from "./backtest.js";

const args = new Set(process.argv.slice(2));
const skipGuruRefresh = args.has("--skip-gurus");
const skipPrices = args.has("--skip-prices");
const skipBacktests = args.has("--skip-backtests");
const start = process.env.HYDRATE_START || "2020-01-01";
const end = process.env.HYDRATE_END || new Date().toISOString().slice(0, 10);
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const baseTickers = [
  "SPY",
  "QQQ",
  "AMZN",
  "TSLA",
  "PLTR",
  "NVDA",
  "AAPL",
  "MSFT",
  "META",
  "GOOGL",
  "GOOG",
  "UBER",
  "BN",
  "QSR",
  "HHH",
  "SEG",
  "HTZ",
  "PANW",
  "AVGO",
  "V",
  "CRM",
  "NFLX",
  "AB",
  "TEM",
  "VST",
  "ORCL",
  "AMD",
  "SHOP",
  "TSM",
  "JPM",
  "BAC",
  "WMT",
  "UNH",
  "LLY",
  "MA"
];

function log(message, payload) {
  if (payload === undefined) {
    console.log(message);
    return;
  }
  console.log(`${message} ${JSON.stringify(payload)}`);
}

function isTicker(value) {
  return /^[A-Z][A-Z0-9.-]{0,9}$/.test(String(value || "").trim().toUpperCase());
}

function addTicker(set, value) {
  const ticker = String(value || "").trim().toUpperCase();
  if (isTicker(ticker)) set.add(ticker);
}

function collectTickers(dashboard) {
  const tickers = new Set(baseTickers);
  for (const guru of dashboard.gurus || []) {
    addTicker(tickers, guru.focusTicker);
    addTicker(tickers, guru.summary?.latestTicker);
    for (const item of guru.holdings || []) addTicker(tickers, item.ticker);
    for (const item of guru.activity || []) addTicker(tickers, item.ticker);
    for (const item of guru.transactions || []) addTicker(tickers, item.ticker);
  }
  return [...tickers].sort();
}

function summarizeGuru(guru) {
  return {
    id: guru.id,
    status: guru.status,
    dataStatus: guru.dataStatus?.status || "",
    holdings: guru.holdings?.length || 0,
    activity: guru.activity?.length || 0,
    transactions: guru.transactions?.length || 0
  };
}

async function hydrateGurus() {
  if (skipGuruRefresh) {
    log("[hydrate] skipping guru refresh");
    return await loadGuruDashboard({ forceRefresh: false });
  }

  log("[hydrate] refreshing guru snapshots slowly");
  const refreshed = await loadGuruDashboard({ forceRefresh: true });
  log("[hydrate] refresh result", refreshed.gurus.map(summarizeGuru));
  return await loadGuruDashboard({ forceRefresh: false });
}

async function hydrateContextPrices(dashboard) {
  for (const guru of dashboard.gurus || []) {
    const ticker = guru.focusTicker || guru.summary?.latestTicker || guru.holdings?.[0]?.ticker || guru.transactions?.[0]?.ticker;
    if (!ticker) continue;
    try {
      const context = await loadGuruMarketContext(guru.id, { ticker });
      log("[hydrate] context", {
        guru: guru.id,
        ticker: context.selectedTicker,
        operations: context.operations.length,
        spyPoints: context.market.spy.points.length,
        selectedPoints: context.market.selected.points.length,
        spySource: context.market.spy.source,
        selectedSource: context.market.selected.source
      });
    } catch (error) {
      log("[hydrate] context skipped", { guru: guru.id, reason: error.message });
    }
    await wait(400);
  }
}

async function hydratePrices(tickers) {
  if (skipPrices) {
    log("[hydrate] skipping prices");
    return;
  }

  log("[hydrate] hydrating prices", { start, end, tickers: tickers.length });
  let ok = 0;
  let missing = 0;
  for (const ticker of tickers) {
    try {
      const series = await loadPriceSeries(ticker, {
        start,
        end,
        priceType: "RAW_CLOSE"
      });
      if (series.points.length) ok += 1;
      else missing += 1;
      log("[hydrate] price", {
        ticker,
        source: series.source,
        cache: series.cache || "",
        points: series.points.length,
        first: series.points[0]?.date || "",
        last: series.points.at(-1)?.date || ""
      });
    } catch (error) {
      missing += 1;
      log("[hydrate] price failed", { ticker, reason: error.message });
    }
    await wait(350);
  }
  log("[hydrate] price summary", { ok, missing });
}

async function hydrateBacktests() {
  if (skipBacktests) {
    log("[hydrate] skipping guru backtests");
    return;
  }

  for (const guru of gurus.filter((item) => item.type === "manager13f" || item.type === "congress")) {
    try {
      const payload = await loadGuruBacktest(guru.id, { refresh: false });
      log("[hydrate] backtest", {
        guru: guru.id,
        status: payload.status,
        start: payload.window?.start || "",
        end: payload.window?.end || "",
        cagr: payload.summary?.cagr ?? null,
        benchmarkCagr: payload.summary?.benchmark?.cagr ?? null,
        rebalances: payload.summary?.rebalances || 0
      });
    } catch (error) {
      log("[hydrate] backtest failed", { guru: guru.id, reason: error.message });
    }
    await wait(600);
  }
}

async function main() {
  log("[hydrate] local database", databaseInfo());
  const dashboard = await hydrateGurus();
  log("[hydrate] local dashboard", {
    cache: dashboard.cache,
    gurus: dashboard.gurus.map(summarizeGuru)
  });

  await hydrateContextPrices(dashboard);
  const tickers = collectTickers(dashboard);
  await hydratePrices(tickers);
  await hydrateBacktests();
  log("[hydrate] done", { database: databaseInfo().path });
}

main().catch((error) => {
  console.error("[hydrate] failed", error);
  process.exitCode = 1;
});
