import { refreshDividendCalendarForTickers } from "./dividendClient.js";
import { loadPortfolioDashboard } from "./portfolioClient.js";

const payload = await loadPortfolioDashboard({ forceRefresh: true });
const result = await refreshDividendCalendarForTickers(payload.holdings || [], { force: true });

console.log(JSON.stringify({
  refreshedAt: result.refreshedAt,
  tickers: result.tickers,
  startDate: result.startDate,
  endDate: result.endDate,
  eventCount: result.eventCount,
  declaredCount: result.declaredCount,
  estimatedCount: result.estimatedCount,
  nasdaq: result.nasdaq,
  historicalEstimates: result.historicalEstimates
}, null, 2));
