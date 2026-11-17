import { gurus } from './gurus.js';
import { guruCapitalStructure } from './guruCapitalStructures.js';
import { finite, change } from './investmentMath.js';
import { selectManagerBacktestCache } from './backtest.js';
import { opportunityValuations } from './investmentOpportunities.js';
import { investmentCurrentQuotes, preferInvestmentQuote } from './investmentPrices.js';
import { dataReleaseId } from './dataReleaseContext.js';
import { marketFactsVersion } from './investmentMarketContext.js';

const profileCaches = new WeakMap();
const parseJson = row => {
  if (!row?.payload_json) return null;
  try { return JSON.parse(row.payload_json); } catch { return null; }
};
const scalar = v => finite(v) ? Number(v) : null;
const isCommonClaim = h => h?.holdingBucket
  ? h.holdingBucket === 'common_long'
  : String(h?.id ?? '').endsWith('-COMMON');
const validTicker = t => typeof t === 'string' && /^[A-Z][A-Z0-9.-]{0,14}$/.test(t) ? t : null;

function hasTable(db, name) {
  return Boolean(db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name));
}

function downsampleCurve(points, maxPoints = 220) {
  if (points.length <= maxPoints) return points;
  let peakIdx = 0, troughIdx = 0;
  let peakVal = -Infinity, maxDd = 0, runningPeak = points[0].v;
  for (let i = 0; i < points.length; i += 1) {
    const v = points[i].v;
    if (v > peakVal) { peakVal = v; peakIdx = i; }
    if (v > runningPeak) runningPeak = v;
    const dd = runningPeak > 0 ? v / runningPeak - 1 : 0;
    if (dd < maxDd) { maxDd = dd; troughIdx = i; }
  }
  const keep = new Set([0, points.length - 1, peakIdx, troughIdx]);
  const step = (points.length - 1) / (maxPoints - 1);
  for (let i = 1; i < maxPoints - 1; i += 1) keep.add(Math.round(i * step));
  return [...keep].sort((a, b) => a - b).map(idx => points[idx]);
}

function computeSliceMetrics(rawSlice) {
  if (!rawSlice || rawSlice.length < 3) return null;
  const v0 = rawSlice[0].value, b0 = rawSlice[0].benchmark;
  if (!(v0 > 0) || !(b0 > 0)) return null;
  const rebased = rawSlice.map(p => ({
    d: p.date,
    v: p.value / v0,
    b: p.benchmark / b0,
  }));
  const start = rebased[0].d, end = rebased.at(-1).d;
  const elapsedYears = (Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / (365.25 * 86400_000);
  if (!(elapsedYears > 0)) return null;

  const endV = rebased.at(-1).v, endB = rebased.at(-1).b;
  const totalReturn = endV - 1;
  const benchmarkTotalReturn = endB - 1;
  const excessTotalReturn = totalReturn - benchmarkTotalReturn;
  const cagr = elapsedYears >= 0.45 ? Math.pow(endV, 1 / elapsedYears) - 1 : null;
  const benchmarkCagr = elapsedYears >= 0.45 ? Math.pow(endB, 1 / elapsedYears) - 1 : null;
  const excessCagr = cagr !== null && benchmarkCagr !== null ? cagr - benchmarkCagr : null;

  let peakV = rebased[0].v, maxDrawdown = 0;
  let peakB = rebased[0].b, benchmarkMaxDrawdown = 0;
  const retsV = [], retsB = [];
  for (let i = 0; i < rebased.length; i += 1) {
    const { v, b } = rebased[i];
    if (v > peakV) peakV = v;
    if (b > peakB) peakB = b;
    const ddV = v / peakV - 1;
    const ddB = b / peakB - 1;
    if (ddV < maxDrawdown) maxDrawdown = ddV;
    if (ddB < benchmarkMaxDrawdown) benchmarkMaxDrawdown = ddB;
    if (i > 0 && rebased[i - 1].v > 0 && rebased[i - 1].b > 0) {
      retsV.push(v / rebased[i - 1].v - 1);
      retsB.push(b / rebased[i - 1].b - 1);
    }
  }
  const sessionsPerYear = retsV.length / elapsedYears;
  const statsFor = arr => {
    if (arr.length < 5 || !(sessionsPerYear > 0)) return { vol: null, sharpe: null };
    const mean = arr.reduce((s, x) => s + x, 0) / arr.length;
    const variance = arr.reduce((s, x) => s + (x - mean) * (x - mean), 0) / (arr.length - 1);
    const vol = Math.sqrt(Math.max(0, variance) * sessionsPerYear);
    const sharpe = vol > 1e-9 ? (mean * sessionsPerYear) / vol : null;
    return { vol, sharpe };
  };
  const sv = statsFor(retsV), sb = statsFor(retsB);

  return {
    startDate: start,
    endDate: end,
    years: elapsedYears,
    totalReturn,
    benchmarkTotalReturn,
    excessTotalReturn,
    cagr,
    benchmarkCagr,
    excessCagr,
    volatility: sv.vol,
    benchmarkVolatility: sb.vol,
    sharpe: sv.sharpe,
    benchmarkSharpe: sb.sharpe,
    maxDrawdown,
    benchmarkMaxDrawdown,
    curve: downsampleCurve(rebased, 220),
  };
}

function summarizeWindowAttribution(quarterContributions, startDate, asOf) {
  const visible = (quarterContributions ?? []).filter(q =>
    q?.executionDate && q.executionDate <= asOf &&
    (!q.endDate || q.endDate <= asOf) &&
    (!startDate || (q.endDate ?? q.executionDate) >= startDate) &&
    finite(q.portfolioReturn) && finite(q.benchmarkReturn)
  );
  const byTicker = new Map();
  let winQuarters = 0;
  const quarters = visible.map(q => {
    const excessReturn = q.portfolioReturn - q.benchmarkReturn;
    if (excessReturn > 0) winQuarters += 1;
    const contribs = Array.isArray(q.contributions) ? q.contributions : [];
    for (const c of contribs) {
      if (!c?.ticker || !finite(c.contributionPct)) continue;
      const prev = byTicker.get(c.ticker) ?? {
        ticker: c.ticker,
        issuer: c.issuer || c.ticker,
        totalContributionPct: 0,
        quartersHeld: 0,
        maxWeight: 0,
      };
      prev.totalContributionPct += c.contributionPct;
      prev.quartersHeld += 1;
      if (finite(c.weight) && c.weight > prev.maxWeight) prev.maxWeight = c.weight;
      byTicker.set(c.ticker, prev);
    }
    const sorted = [...contribs].filter(c => finite(c?.contributionPct)).sort((a, b) => b.contributionPct - a.contributionPct);
    return {
      label: q.label || q.reportDate,
      reportDate: q.reportDate,
      filingDate: q.filingDate,
      executionDate: q.executionDate,
      endDate: q.endDate,
      portfolioReturn: q.portfolioReturn,
      benchmarkReturn: q.benchmarkReturn,
      excessReturn,
      coveragePct: scalar(q.coveragePct),
      topWinners: sorted.filter(c => c.contributionPct > 0).slice(0, 2).map(c => ({
        ticker: c.ticker,
        returnPct: scalar(c.returnPct),
        contributionPct: c.contributionPct,
        weight: scalar(c.weight),
      })),
      topDetractors: sorted.filter(c => c.contributionPct < 0).reverse().slice(0, 2).map(c => ({
        ticker: c.ticker,
        returnPct: scalar(c.returnPct),
        contributionPct: c.contributionPct,
        weight: scalar(c.weight),
      })),
    };
  });

  const allContributors = [...byTicker.values()];
  const topContributors = allContributors
    .filter(c => c.totalContributionPct > 0)
    .sort((a, b) => b.totalContributionPct - a.totalContributionPct)
    .slice(0, 6);
  const bottomContributors = allContributors
    .filter(c => c.totalContributionPct < 0)
    .sort((a, b) => a.totalContributionPct - b.totalContributionPct)
    .slice(0, 5);

  return {
    totalQuarters: visible.length,
    winQuarters,
    quarterlyWinRate: visible.length > 0 ? winQuarters / visible.length : null,
    quarters: quarters.reverse(),
    topContributors,
    bottomContributors,
  };
}

function loadGuruBacktestBundle(source, guruId, configured, asOf) {
  if (configured?.disableSimulation || configured?.type !== 'manager13f') {
    return { status: 'unsupported', simulationNote: configured?.simulationNote ?? null, windows: {} };
  }
  if (!hasTable(source.db, 'guru_backtests')) {
    return { status: 'unavailable', windows: {} };
  }
  const hasProxies = hasTable(source.db, 'guru_backtest_proxies');
  const readWindow = years => {
    const strict = parseJson(source.db.prepare('SELECT payload_json FROM guru_backtests WHERE guru_id=? AND years=?').get(guruId, years));
    const proxy = hasProxies
      ? parseJson(source.db.prepare('SELECT payload_json FROM guru_backtest_proxies WHERE guru_id=? AND years=?').get(guruId, years))
      : null;
    try {
      const selected = selectManagerBacktestCache(strict, proxy, years, guruId);
      if (selected?.payload && ['ready', 'proxy_ready'].includes(selected.payload.status)) {
        return { payload: selected.payload, kind: selected.kind };
      }
    } catch {
      // Fall through to unavailable
    }
    return null;
  };

  const w5 = readWindow(5);
  const w10 = readWindow(10);
  if (!w5 && !w10) {
    return { status: 'unavailable', simulationNote: configured?.simulationNote ?? null, windows: {} };
  }

  const windows = {};
  const quarterReturnByReportDate = {};

  const recordQuarterLookup = payload => {
    for (const qc of payload?.quarterContributions ?? []) {
      if (!qc?.reportDate || !qc?.executionDate || qc.executionDate > asOf) continue;
      if (qc.endDate && qc.endDate > asOf) continue;
      const tickerReturns = {};
      for (const c of qc.contributions ?? []) {
        if (c?.ticker) {
          tickerReturns[c.ticker] = {
            returnPct: scalar(c.returnPct),
            contributionPct: scalar(c.contributionPct),
            startPrice: scalar(c.startPrice),
            endPrice: scalar(c.endPrice),
          };
        }
      }
      quarterReturnByReportDate[qc.reportDate] = {
        label: qc.label,
        executionDate: qc.executionDate,
        endDate: qc.endDate,
        portfolioReturn: scalar(qc.portfolioReturn),
        benchmarkReturn: scalar(qc.benchmarkReturn),
        excessReturn: finite(qc.portfolioReturn) && finite(qc.benchmarkReturn)
          ? qc.portfolioReturn - qc.benchmarkReturn
          : null,
        byTicker: tickerReturns,
      };
    }
  };

  if (w10) recordQuarterLookup(w10.payload);
  if (w5) recordQuarterLookup(w5.payload);

  if (w5) {
    const eq5 = (w5.payload.equity ?? []).filter(p => p?.date && p.date <= asOf && finite(p.value) && finite(p.benchmark));
    if (eq5.length >= 3) {
      const endD = eq5.at(-1).date;
      const endYr = Number(endD.slice(0, 4));
      const cut1Y = `${String(endYr - 1).padStart(4, '0')}${endD.slice(4)}`;
      const cut3Y = `${String(endYr - 3).padStart(4, '0')}${endD.slice(4)}`;

      for (const [label, slice] of [
        ['1Y', eq5.filter(p => p.date >= cut1Y)],
        ['3Y', eq5.filter(p => p.date >= cut3Y)],
        ['5Y', eq5],
      ]) {
        const metrics = computeSliceMetrics(slice);
        if (metrics) {
          windows[label] = {
            window: label,
            kind: w5.kind,
            status: w5.payload.status,
            ...metrics,
            attribution: summarizeWindowAttribution(w5.payload.quarterContributions, metrics.startDate, asOf),
          };
        }
      }
    }
  }

  if (w10) {
    const eq10 = (w10.payload.equity ?? []).filter(p => p?.date && p.date <= asOf && finite(p.value) && finite(p.benchmark));
    const metrics10 = computeSliceMetrics(eq10);
    if (metrics10) {
      windows['10Y'] = {
        window: '10Y',
        kind: w10.kind,
        status: w10.payload.status,
        ...metrics10,
        attribution: summarizeWindowAttribution(w10.payload.quarterContributions, metrics10.startDate, asOf),
      };
    }
  }

  const defaultWindow = windows['5Y'] ? '5Y' : windows['10Y'] ? '10Y' : Object.keys(windows)[0] ?? null;
  return {
    status: defaultWindow ? 'ready' : 'unavailable',
    defaultWindow,
    benchmark: 'SPY',
    simulationNote: configured?.simulationNote ?? null,
    windows,
    quarterReturnByReportDate,
  };
}

function loadTickerMetadata(source, tickers, asOf) {
  const clean = [...new Set(tickers.map(validTicker).filter(Boolean))];
  if (!clean.length) return {};
  const meta = {};
  if (hasTable(source.db, 'valuation_ticker_snapshots')) {
    const rows = source.db.prepare(`SELECT ticker,
      json_extract(payload_json,'$.sector') sector,
      json_extract(payload_json,'$.industry') industry,
      json_extract(payload_json,'$.currency') currency,
      json_extract(payload_json,'$.priceHistory') history
      FROM valuation_ticker_snapshots WHERE ticker IN (${clean.map(() => '?').join(',')})`).all(...clean);
    for (const r of rows) {
      let close = null, closeDate = null;
      try {
        const pts = JSON.parse(r.history ?? '[]').filter(p => p.date <= asOf && finite(p.close) && p.close > 0);
        pts.sort((a, b) => a.date.localeCompare(b.date));
        const last = pts.at(-1);
        close = last?.close ?? null;
        closeDate = last?.date ?? null;
      } catch {
        // ignore malformed history
      }
      meta[r.ticker] = {
        sector: r.sector || null,
        industry: r.industry || null,
        currency: r.currency || null,
        price: close,
        priceDate: closeDate,
      };
    }
    const quotes = investmentCurrentQuotes(source, clean, asOf);
    for (const [ticker, quote] of quotes) {
      const prev = meta[ticker] ?? { sector: null, industry: null, currency: null, price: null, priceDate: null };
      const best = preferInvestmentQuote(quote, { value: prev.price, date: prev.priceDate, currency: prev.currency });
      meta[ticker] = {
        ...prev,
        currency: best.currency ?? prev.currency,
        price: scalar(best.value),
        priceDate: best.date ?? prev.priceDate,
      };
    }
  }
  if (hasTable(source.db, 'valuation_pit_model_runs')) {
    const vals = opportunityValuations(source, asOf, clean);
    for (const [ticker, v] of vals) {
      const cur = meta[ticker] ?? { sector: null, industry: null, currency: v.currency ?? null, price: null, priceDate: null };
      const comparable = finite(v?.fairValue) && v.fairValue > 0 && finite(cur.price) && cur.price > 0 &&
        Boolean(v.currency) && v.currency === cur.currency;
      meta[ticker] = {
        ...cur,
        fairValue: scalar(v.fairValue),
        valuationDate: v.date ?? null,
        valuationCurrency: v.currency ?? null,
        modelGap: comparable ? change(v.fairValue, cur.price) : null,
      };
    }
  }
  return meta;
}

function normalizeActionItem(item, totalCommonValue, previousCommonValue) {
  const shares = scalar(item.shares) ?? 0;
  const prevShares = scalar(item.prevShares ?? (finite(item.shares) && finite(item.changeShares) ? item.shares - item.changeShares : null));
  const changeShares = scalar(item.changeShares ?? (finite(shares) && finite(prevShares) ? shares - prevShares : null));
  const changePct = scalar(item.changePct) ?? (prevShares !== null && prevShares > 0 && changeShares !== null ? changeShares / prevShares : null);
  const weight = scalar(item.pctCommonLong ?? item.pctPortfolio) ??
    (finite(item.value) && finite(totalCommonValue) && totalCommonValue > 0 ? item.value / totalCommonValue : null);
  const prevWeight = item.action === 'new'
    ? 0
    : (finite(item.previousValue) && finite(previousCommonValue) && previousCommonValue > 0
        ? item.previousValue / previousCommonValue
        : null);
  const valueChange = scalar(item.valueChange) ??
    (finite(item.value) && finite(item.previousValue) ? item.value - item.previousValue : null);
  return {
    id: item.id ?? null,
    ticker: item.ticker ?? null,
    issuer: item.issuer ?? item.ticker ?? '',
    action: item.action ?? 'reported_holding',
    shares,
    prevShares,
    changeShares,
    changePct,
    value: scalar(item.value),
    previousValue: scalar(item.previousValue),
    valueChange,
    weight,
    previousWeight: prevWeight,
    weightDelta: weight !== null && prevWeight !== null ? weight - prevWeight : null,
  };
}

export function enrichGuruDetail(source, base) {
  const guruId = base.guru.id, asOf = base.asOf;
  const generation = `${source.db.prepare('PRAGMA data_version').get().data_version}:${dataReleaseId() ?? 'legacy'}:${marketFactsVersion() ?? 'stored'}`;
  let cache = profileCaches.get(source);
  if (!cache || cache.generation !== generation) {
    cache = { generation, items: new Map() };
    profileCaches.set(source, cache);
  }
  const cacheKey = `${guruId}:${asOf}`;
  if (cache.items.has(cacheKey)) return structuredClone(cache.items.get(cacheKey));

  const configured = gurus.find(g => g.id === guruId) ?? null;
  const snap = hasTable(source.db, 'guru_snapshots')
    ? parseJson(source.db.prepare('SELECT payload_json FROM guru_snapshots WHERE guru_id=?').get(guruId))
    : null;

  const snapMatchesFiling = f => Boolean(
    snap &&
    snap.summary?.reportDate === f?.reportDate &&
    snap.summary?.filingDate &&
    snap.summary.filingDate <= asOf &&
    snap.latestFiling?.accessionNumber === f?.accessionNumber
  );

  // Collect tickers across recent filings for sector & valuation enrichment
  const recentFilings = (base.history ?? []).slice(-4);
  const candidateTickers = new Set();
  for (const f of recentFilings) {
    if (f?.status === 'source_error') continue;
    for (const h of f?.topHoldings ?? []) if (h?.ticker) candidateTickers.add(h.ticker);
    for (const c of f?.largestChanges ?? []) if (c?.ticker) candidateTickers.add(c.ticker);
  }
  if (snap && snap.summary?.filingDate <= asOf) {
    for (const h of snap.holdings ?? []) if (h?.ticker) candidateTickers.add(h.ticker);
    for (const a of snap.activity ?? []) if (a?.ticker) candidateTickers.add(a.ticker);
  }
  const tickerMeta = loadTickerMetadata(source, [...candidateTickers], asOf);

  const enrichedHistory = (base.history ?? []).map(f => {
    if (f?.status === 'source_error') return f;
    const isFullSnap = snapMatchesFiling(f);
    const totalVal = scalar(isFullSnap ? (snap.summary?.commonLongValue ?? snap.summary?.totalValue) : f.reported13fValue);
    const prevVal = scalar(isFullSnap ? (snap.summary?.previousCommonLongValue ?? snap.summary?.previousValue) : f.previous13fValue);

    const rawHoldings = isFullSnap
      ? (snap.holdings ?? []).filter(isCommonClaim)
      : (f.topHoldings ?? []).filter(isCommonClaim);
    const rawChanges = isFullSnap
      ? (snap.activity ?? []).filter(isCommonClaim)
      : (f.largestChanges ?? []).filter(isCommonClaim);

    const changeById = new Map();
    for (const c of rawChanges) {
      const k = c.cusip ?? c.id ?? c.ticker;
      if (k && !changeById.has(k)) changeById.set(k, c);
    }

    const enrichedHoldings = rawHoldings.map(h => {
      const k = h.cusip ?? h.id ?? h.ticker;
      const ch = changeById.get(k);
      const merged = ch ? { ...ch, ...h, prevShares: ch.prevShares, previousValue: ch.previousValue, valueChange: ch.valueChange } : h;
      const norm = normalizeActionItem(merged, totalVal, prevVal);
      const tm = h.ticker ? tickerMeta[h.ticker] : null;
      return {
        ...h,
        pctPortfolio: norm.weight ?? scalar(h.pctPortfolio),
        action: f.comparisonStatus === 'previous_source_error' ? 'reported_holding' : norm.action,
        prevShares: f.comparisonStatus === 'previous_source_error' ? null : norm.prevShares,
        changeShares: f.comparisonStatus === 'previous_source_error' ? null : norm.changeShares,
        changePct: f.comparisonStatus === 'previous_source_error' ? null : norm.changePct,
        previousValue: f.comparisonStatus === 'previous_source_error' ? null : norm.previousValue,
        valueChange: f.comparisonStatus === 'previous_source_error' ? null : norm.valueChange,
        previousWeight: f.comparisonStatus === 'previous_source_error' ? null : norm.previousWeight,
        weightDelta: f.comparisonStatus === 'previous_source_error' ? null : norm.weightDelta,
        sector: tm?.sector ?? null,
        marketPrice: tm?.price ?? null,
        fairValue: tm?.fairValue ?? null,
        modelGap: tm?.modelGap ?? null,
      };
    });

    const normalizedMoves = f.comparisonStatus === 'previous_source_error'
      ? []
      : rawChanges
          .map(c => normalizeActionItem(c, totalVal, prevVal))
          .filter(c => ['new', 'increased', 'reduced', 'sold_out'].includes(c.action));

    const keyBuys = normalizedMoves
      .filter(c => c.action === 'new' || c.action === 'increased')
      .sort((a, b) => (b.weightDelta ?? b.weight ?? 0) - (a.weightDelta ?? a.weight ?? 0) || (b.valueChange ?? b.value ?? 0) - (a.valueChange ?? a.value ?? 0))
      .slice(0, 12);

    const keySells = normalizedMoves
      .filter(c => c.action === 'reduced' || c.action === 'sold_out')
      .sort((a, b) => (a.action === 'sold_out' ? -1 : 0) - (b.action === 'sold_out' ? -1 : 0) || (a.valueChange ?? -Infinity) - (b.valueChange ?? -Infinity))
      .slice(0, 12);

    // Sector distribution over visible holdings
    const sectorMap = new Map();
    for (const h of enrichedHoldings) {
      const w = scalar(h.pctPortfolio) ?? 0;
      if (!(w > 0)) continue;
      const sec = h.sector || 'Unclassified';
      const cur = sectorMap.get(sec) ?? { sector: sec, weight: 0, count: 0 };
      cur.weight += w;
      cur.count += 1;
      sectorMap.set(sec, cur);
    }
    const sectors = [...sectorMap.values()].sort((a, b) => b.weight - a.weight);
    const sortedWeights = enrichedHoldings.map(h => scalar(h.pctPortfolio) ?? 0).filter(w => w > 0).sort((a, b) => b - a);
    const top5Weight = sortedWeights.slice(0, 5).reduce((s, w) => s + w, 0);
    const top10Weight = scalar(isFullSnap ? snap.summary?.top10Weight : f.top10Weight) ??
      sortedWeights.slice(0, 10).reduce((s, w) => s + w, 0);

    return {
      ...f,
      bookScope: isFullSnap ? 'full_book' : 'top_extract',
      topHoldings: enrichedHoldings,
      top5Weight: sortedWeights.length ? top5Weight : null,
      top10Weight: sortedWeights.length ? top10Weight : null,
      concentrationHhi: scalar(isFullSnap ? snap.summary?.concentrationHhi : f.concentrationHhi),
      turnoverProxy: scalar(isFullSnap ? snap.summary?.turnoverProxy : f.turnoverProxy),
      moveCounts: f.comparisonStatus === 'previous_source_error' ? null : {
        newPositions: scalar(isFullSnap ? snap.summary?.newPositions : f.newPositions) ?? normalizedMoves.filter(m => m.action === 'new').length,
        increasedPositions: scalar(isFullSnap ? snap.summary?.increasedPositions : f.increasedPositions) ?? normalizedMoves.filter(m => m.action === 'increased').length,
        reducedPositions: scalar(isFullSnap ? snap.summary?.reducedPositions : f.reducedPositions) ?? normalizedMoves.filter(m => m.action === 'reduced').length,
        soldOutPositions: scalar(isFullSnap ? snap.summary?.soldOutPositions : f.soldOutPositions) ?? normalizedMoves.filter(m => m.action === 'sold_out').length,
      },
      keyBuys,
      keySells,
      sectors,
    };
  });

  const validFilings = enrichedHistory.filter(f => f?.status !== 'source_error');
  const recentValid = validFilings.slice(-8);
  const posCounts = recentValid.map(f => scalar(f.positionCount)).filter(v => v !== null && v > 0);
  const turnovers = recentValid.map(f => scalar(f.turnoverProxy)).filter(v => v !== null && v >= 0);
  const avgPositions = posCounts.length ? posCounts.reduce((s, v) => s + v, 0) / posCounts.length : null;
  const avgQuarterlyTurnover = turnovers.length ? turnovers.reduce((s, v) => s + v, 0) / turnovers.length : null;
  const latestValid = validFilings.at(-1) ?? null;

  const latestPos = scalar(latestValid?.positionCount) ?? avgPositions;
  const latestTop5 = scalar(latestValid?.top5Weight);
  const concentrationTier = latestPos !== null && latestPos <= 12 || (latestTop5 !== null && latestTop5 >= 0.70)
    ? 'ultra_concentrated'
    : latestPos !== null && latestPos <= 28 || (latestTop5 !== null && latestTop5 >= 0.50)
      ? 'concentrated'
      : latestPos !== null && latestPos > 100
        ? 'diversified_systematic'
        : 'balanced';

  const turnoverTier = avgQuarterlyTurnover === null
    ? 'unclassified'
    : avgQuarterlyTurnover <= 0.12
      ? 'low_turnover'
      : avgQuarterlyTurnover <= 0.28
        ? 'moderate_turnover'
        : 'active_rotation';

  const backtest = loadGuruBacktestBundle(source, guruId, configured, asOf);

  const enriched = {
    ...base,
    guru: {
      ...base.guru,
      chineseName: configured?.chineseName ?? null,
      role: configured?.role ?? null,
      thesisTag: configured?.thesisTag ?? null,
      cik: configured?.cik ?? null,
      notes: Array.isArray(configured?.notes) ? configured.notes : [],
      capitalStructure: base.guru.capitalStructure ?? (configured ? guruCapitalStructure(configured) : null),
    },
    styleProfile: {
      concentrationTier,
      turnoverTier,
      avgPositions,
      avgQuarterlyTurnover,
      latestTop5Weight: latestTop5,
      latestTop10Weight: scalar(latestValid?.top10Weight),
      latestHhi: scalar(latestValid?.concentrationHhi),
      totalFilings: validFilings.length,
    },
    backtest,
    tickerMeta,
    history: enrichedHistory,
    latest: enrichedHistory.at(-1) ?? null,
    coverage: enrichedHistory.at(-1)?.bookScope === 'full_book'
      ? 'full_latest_book_with_historical_extracts'
      : base.coverage,
  };

  if (cache.items.size >= 24) cache.items.delete(cache.items.keys().next().value);
  cache.items.set(cacheKey, enriched);
  return structuredClone(enriched);
}
