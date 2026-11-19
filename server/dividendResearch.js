import { queryFactsBatch, PRICE_TYPES, factGeneration } from './factRepository.js';
import { finite, isoDate } from './investmentMath.js';
import { tickerKey } from './investmentSource.js';
import { peekCachedFundamentalCompany } from './fundamentalResearch.js';

export const DIVIDEND_RESEARCH_VERSION = 'dividend-research-v1';

const DIVIDEND_CACHE_TTL_MS = 10 * 60_000;
const dividendCaches = new WeakMap();
const fallbackSourceKey = {};

function getDividendCacheStore(source) {
  const key = source && typeof source === 'object' ? source : fallbackSourceKey;
  let store = dividendCaches.get(key);
  if (!store) {
    store = { entries: new Map(), inFlight: new Map() };
    dividendCaches.set(key, store);
  }
  return store;
}

function shiftDays(asOf, deltaDays) {
  const d = new Date(`${asOf}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + deltaDays);
  return d.toISOString().slice(0, 10);
}

function daysBetween(isoStart, isoEnd) {
  const a = Date.parse(`${isoStart}T00:00:00Z`);
  const b = Date.parse(`${isoEnd}T00:00:00Z`);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return 0;
  return Math.round((b - a) / 86_400_000);
}

function median(values) {
  const sorted = values.filter(finite).sort((a, b) => a - b);
  if (!sorted.length) return null;
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function mean(values) {
  const clean = values.filter(finite);
  if (!clean.length) return null;
  return clean.reduce((sum, v) => sum + v, 0) / clean.length;
}

function stddev(values, avg) {
  const clean = values.filter(finite);
  if (clean.length < 2 || !finite(avg)) return null;
  const variance = clean.reduce((acc, v) => acc + (v - avg) ** 2, 0) / clean.length;
  return Math.sqrt(variance);
}

function inferFrequency(dividendsAsc, asOf) {
  if (!dividendsAsc.length) {
    return { frequency: 'none', frequencyPerYear: 0, medianIntervalDays: null, active: false };
  }
  const latestDate = dividendsAsc.at(-1).exDate;
  const recentCutoff = shiftDays(latestDate, -760);
  const recent = dividendsAsc.filter(d => d.exDate >= recentCutoff);
  const sample = recent.length >= 3 ? recent : dividendsAsc.slice(-8);
  const gaps = [];
  for (let i = 1; i < sample.length; i += 1) {
    const gap = daysBetween(sample[i - 1].exDate, sample[i].exDate);
    if (gap >= 12 && gap <= 430) gaps.push(gap);
  }
  const med = median(gaps);
  let frequency = 'irregular';
  let frequencyPerYear = 0;
  let maxActiveSilenceDays = 420;
  if (med != null) {
    if (med >= 20 && med <= 42) {
      frequency = 'monthly';
      frequencyPerYear = 12;
      maxActiveSilenceDays = 70;
    } else if (med >= 68 && med <= 118) {
      frequency = 'quarterly';
      frequencyPerYear = 4;
      maxActiveSilenceDays = 165;
    } else if (med >= 150 && med <= 215) {
      frequency = 'semi_annual';
      frequencyPerYear = 2;
      maxActiveSilenceDays = 280;
    } else if (med >= 325 && med <= 405) {
      frequency = 'annual';
      frequencyPerYear = 1;
      maxActiveSilenceDays = 450;
    }
  } else if (sample.length === 1 && daysBetween(latestDate, asOf) <= 380) {
    frequency = 'irregular';
    frequencyPerYear = 1;
  }
  const daysSinceLatest = daysBetween(latestDate, asOf);
  const active = daysSinceLatest <= maxActiveSilenceDays;
  return { frequency, frequencyPerYear, medianIntervalDays: med, active, daysSinceLatest };
}

/**
 * Compute trailing 12-month split-adjusted dividend per share as of `dateIso`
 * without calendar weekend jitter (e.g. Q3 ex-date shifting by ±4 days YoY).
 */
function trailingAnnualDpsAt(dividendsAsc, endIndex, dateIso, regularCount) {
  if (endIndex < 0) return 0;
  const latest = dividendsAsc[endIndex];
  const maxSilence = regularCount === 12 ? 75 : regularCount === 4 ? 170 : regularCount === 2 ? 290 : 440;
  if (daysBetween(latest.exDate, dateIso) > maxSilence) {
    // Dividend suspended or paused: fall back to strict 365-day window so yield decays cleanly to 0.
    const cutoff = shiftDays(dateIso, -365);
    let sum = 0;
    for (let i = endIndex; i >= 0 && dividendsAsc[i].exDate > cutoff; i -= 1) {
      sum += dividendsAsc[i].amount;
    }
    return sum;
  }
  if (regularCount > 0 && endIndex + 1 >= regularCount) {
    const firstInCycle = dividendsAsc[endIndex - regularCount + 1];
    const spanDays = daysBetween(firstInCycle.exDate, latest.exDate);
    const expectedSpan = ((regularCount - 1) / regularCount) * 365.25;
    if (regularCount === 1 || Math.abs(spanDays - expectedSpan) <= 45) {
      let sum = 0;
      for (let i = endIndex - regularCount + 1; i <= endIndex; i += 1) {
        sum += dividendsAsc[i].amount;
      }
      return sum;
    }
  }
  const cutoff = shiftDays(dateIso, -366);
  let sum = 0;
  for (let i = endIndex; i >= 0 && dividendsAsc[i].exDate > cutoff; i -= 1) {
    sum += dividendsAsc[i].amount;
  }
  return sum;
}

function sampleYieldHistory(dailyPoints, maxPoints = 520) {
  if (dailyPoints.length <= maxPoints) return dailyPoints;
  // Preserve first, last, global min/max yield points, and evenly spaced weekly samples.
  const mustKeep = new Set([0, dailyPoints.length - 1]);
  let minIdx = 0;
  let maxIdx = 0;
  for (let i = 1; i < dailyPoints.length; i += 1) {
    if ((dailyPoints[i].yield ?? Infinity) < (dailyPoints[minIdx].yield ?? Infinity)) minIdx = i;
    if ((dailyPoints[i].yield ?? -Infinity) > (dailyPoints[maxIdx].yield ?? -Infinity)) maxIdx = i;
  }
  mustKeep.add(minIdx);
  mustKeep.add(maxIdx);
  const step = (dailyPoints.length - 1) / (maxPoints - 1);
  for (let k = 0; k < maxPoints; k += 1) {
    mustKeep.add(Math.round(k * step));
  }
  return [...mustKeep].sort((a, b) => a - b).map(idx => dailyPoints[idx]);
}

function computeCagr(annualFullYears, spanYears) {
  if (annualFullYears.length < spanYears + 1) return null;
  const endRow = annualFullYears.at(-1);
  const targetStartYear = endRow.year - spanYears;
  const startRow = annualFullYears.find(r => r.year === targetStartYear);
  if (!startRow || !(startRow.dps > 0) || !(endRow.dps > 0)) return null;
  return (endRow.dps / startRow.dps) ** (1 / spanYears) - 1;
}

function computeStreaks(annualFullYears, currentYearHasDividend, active, frequencyPerYear) {
  if (!active && !currentYearHasDividend) {
    return { consecutiveYearsPaid: 0, consecutiveYearsGrown: 0 };
  }
  let paid = 0;
  for (let i = annualFullYears.length - 1; i >= 0; i -= 1) {
    const row = annualFullYears[i];
    if (!(row.dps > 0)) break;
    if (i < annualFullYears.length - 1 && annualFullYears[i + 1].year - row.year !== 1) break;
    paid += 1;
  }
  const normalizedAnnualRate = row => {
    if (frequencyPerYear >= 4 && row.payoutCount > 0 && Math.abs(row.payoutCount - frequencyPerYear) <= 1) {
      return (row.dps / row.payoutCount) * frequencyPerYear;
    }
    return row.dps;
  };
  let grown = 0;
  for (let i = annualFullYears.length - 1; i >= 1; i -= 1) {
    const cur = annualFullYears[i];
    const prev = annualFullYears[i - 1];
    if (cur.year - prev.year !== 1) break;
    if (!(cur.dps > 0) || !(prev.dps > 0)) break;
    const curRate = normalizedAnnualRate(cur);
    const prevRate = normalizedAnnualRate(prev);
    if (curRate > prevRate * 1.001) {
      grown += 1;
    } else {
      break;
    }
  }
  return { consecutiveYearsPaid: paid, consecutiveYearsGrown: grown };
}

function evaluateSafety({ status, epsPayoutRatio, fcfPayoutRatio, hasCorporateFacts, isReit }) {
  if (status !== 'paying') return { level: 'none', basis: 'no_active_dividend' };
  if (!hasCorporateFacts) return { level: 'fund_distribution', basis: 'etf_or_fund_no_corporate_sf1' };
  const primary = finite(fcfPayoutRatio) ? fcfPayoutRatio : epsPayoutRatio;
  const basisName = finite(fcfPayoutRatio) ? (isReit ? 'cfo_payout' : 'fcf_payout') : 'eps_payout';
  if (!finite(primary)) return { level: 'unrated', basis: 'insufficient_earnings_or_fcf' };
  if (primary < 0) return { level: 'deficit', basis: 'negative_earnings_or_fcf' };
  const safeCap = isReit ? 0.80 : 0.65;
  const modCap = isReit ? 0.92 : 0.85;
  if (primary <= 0.40) return { level: 'very_safe', basis: basisName };
  if (primary <= safeCap) return { level: 'safe', basis: basisName };
  if (primary <= modCap) return { level: 'moderate', basis: basisName };
  return { level: 'stretched', basis: basisName };
}

export async function buildDividendResearch(source, rawTicker, rawAsOf) {
  const ticker = tickerKey(rawTicker);
  const asOf = isoDate(rawAsOf);
  const store = getDividendCacheStore(source);
  let factGen = 'none';
  try { factGen = (await factGeneration()) || 'none'; } catch { factGen = 'none'; }
  const cacheKey = `${ticker}|${asOf}|${factGen}`;
  const now = Date.now();
  const hit = store.entries.get(cacheKey);
  if (hit && hit.expiresAt > now && factGen !== 'none') {
    store.entries.delete(cacheKey);
    store.entries.set(cacheKey, hit);
    return structuredClone(hit.value);
  }
  if (store.inFlight.has(cacheKey)) {
    return structuredClone(await store.inFlight.get(cacheKey));
  }

  const compute = buildDividendResearchUncached(source, ticker, asOf, factGen);
  store.inFlight.set(cacheKey, compute);
  try {
    const result = await compute;
    if (factGen !== 'none') {
      if (store.entries.size >= 128) {
        store.entries.delete(store.entries.keys().next().value);
      }
      store.entries.set(cacheKey, { value: result, expiresAt: Date.now() + DIVIDEND_CACHE_TTL_MS });
    }
    return structuredClone(result);
  } finally {
    if (store.inFlight.get(cacheKey) === compute) store.inFlight.delete(cacheKey);
  }
}

async function buildDividendResearchUncached(source, ticker, asOf, factGen) {
  const divStart = shiftDays(asOf, -4050); // ~11.1 years so T-10Y point has full 365-day lookback
  const priceStart = shiftDays(asOf, -3660); // 10 years of daily split-adjusted prices
  const cachedFundamental = await peekCachedFundamentalCompany(source, ticker, asOf);
  const batch = [
    { method: 'get_dividends', args: [ticker, divStart, asOf] },
    { method: 'get_price_histories', args: [[{ ticker, start: priceStart, end: asOf }], PRICE_TYPES.SPLIT_ADJUSTED_CLOSE] },
    { method: 'get_price', args: [ticker, asOf, PRICE_TYPES.RAW_CLOSE] },
  ];
  if (!cachedFundamental) {
    batch.push({ method: 'get_fundamental_research', args: [ticker, asOf], kwargs: { quarters: 20, years: 10 } });
  }
  const responses = await queryFactsBatch(batch);

  const rawDividends = responses[0]?.ok && Array.isArray(responses[0].result) ? responses[0].result : [];
  const compactSeries = responses[1]?.ok && Array.isArray(responses[1].result?.series) ? responses[1].result.series[0]?.points ?? [] : [];
  const latestRawPrice = responses[2]?.ok ? responses[2].result : null;
  const fundamental = cachedFundamental
    ? {
        annual: cachedFundamental.annual,
        quarterly: cachedFundamental.quarterly,
        company: cachedFundamental.company,
        metrics: cachedFundamental.company?.metrics,
      }
    : (responses[3]?.ok ? responses[3].result : null);

  // Deduplicate same-day ex-dividend rows by summing (regular + special on same ex-date)
  const byExDate = new Map();
  for (const row of rawDividends) {
    const exDate = String(row.ex_date ?? row.date ?? '').slice(0, 10);
    const val = Number(row.value);
    if (!exDate || exDate > asOf || !Number.isFinite(val) || val <= 0) continue;
    byExDate.set(exDate, (byExDate.get(exDate) ?? 0) + val);
  }
  const dividendsAsc = [...byExDate.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([exDate, amount]) => ({
      exDate,
      amount: Number(amount.toFixed(6)),
      year: Number.parseInt(exDate.slice(0, 4), 10),
      month: Number.parseInt(exDate.slice(5, 7), 10),
    }));

  const pricesAsc = compactSeries
    .map(pt => ({
      date: String(pt[0] ?? '').slice(0, 10),
      close: finite(pt[1]) ? Number(pt[1]) : null,
    }))
    .filter(p => p.date && p.date <= asOf && finite(p.close) && p.close > 0)
    .sort((a, b) => a.date.localeCompare(b.date));

  const cadence = inferFrequency(dividendsAsc, asOf);
  const status = dividendsAsc.length === 0
    ? 'no_dividends'
    : (cadence.active ? 'paying' : 'suspended');

  // Build continuous daily yield series using two-pointer sweep over pricesAsc & dividendsAsc
  const dailyYieldSeries = [];
  let divPtr = -1;
  const priceByDate = new Map();
  for (const p of pricesAsc) {
    priceByDate.set(p.date, p.close);
    while (divPtr + 1 < dividendsAsc.length && dividendsAsc[divPtr + 1].exDate <= p.date) {
      divPtr += 1;
    }
    const ttmDps = dividendsAsc.length
      ? trailingAnnualDpsAt(dividendsAsc, divPtr, p.date, cadence.frequencyPerYear)
      : 0;
    const yld = p.close > 0 && ttmDps > 0 ? ttmDps / p.close : 0;
    dailyYieldSeries.push({
      date: p.date,
      price: Number(p.close.toFixed(4)),
      ttmDps: Number(ttmDps.toFixed(5)),
      yield: Number(yld.toFixed(6)),
    });
  }

  const latestSplitClose = pricesAsc.at(-1)?.close ?? null;
  const latestQuotedClose = finite(latestRawPrice?.value)
    ? Number(latestRawPrice.value)
    : latestSplitClose;

  const latestDivIndex = dividendsAsc.length - 1;
  const currentTtmDps = latestDivIndex >= 0
    ? trailingAnnualDpsAt(dividendsAsc, latestDivIndex, asOf, cadence.frequencyPerYear)
    : 0;
  const latestEvent = dividendsAsc.at(-1) ?? null;
  const annualizedDps = status === 'paying' && latestEvent && cadence.frequencyPerYear > 0
    ? Number((latestEvent.amount * cadence.frequencyPerYear).toFixed(5))
    : Number(currentTtmDps.toFixed(5));

  const currentYield = finite(latestSplitClose) && latestSplitClose > 0 && currentTtmDps > 0
    ? currentTtmDps / latestSplitClose
    : 0;
  const forwardYield = finite(latestSplitClose) && latestSplitClose > 0 && annualizedDps > 0
    ? annualizedDps / latestSplitClose
    : currentYield;

  // 5Y and 10Y historical yield statistics (over positive-yield sessions when paying)
  const cutoff5y = shiftDays(asOf, -1826);
  const yields5y = dailyYieldSeries
    .filter(pt => pt.date >= cutoff5y && pt.yield > 0)
    .map(pt => pt.yield);
  const yields10y = dailyYieldSeries
    .filter(pt => pt.yield > 0)
    .map(pt => pt.yield);

  const avgYield5y = mean(yields5y);
  const medianYield5y = median(yields5y);
  const stdYield5y = stddev(yields5y, avgYield5y);
  const highYield5y = yields5y.length ? Math.max(...yields5y) : null;
  const lowYield5y = yields5y.length ? Math.min(...yields5y) : null;
  const avgYield10y = mean(yields10y);
  const yieldVs5yAvgPct = finite(avgYield5y) && avgYield5y > 0 && currentYield > 0
    ? (currentYield - avgYield5y) / avgYield5y
    : null;

  // Annual dividend aggregation & corporate EPS / FCF coverage
  const asOfYear = Number.parseInt(asOf.slice(0, 4), 10);
  const asOfMonthDay = asOf.slice(5, 10);
  const isFullCurrentYear = asOfMonthDay >= '12-20';
  const minDisplayYear = asOfYear - 9;

  const annualByYear = new Map();
  for (const d of dividendsAsc) {
    if (d.year < minDisplayYear - 1) continue;
    const bucket = annualByYear.get(d.year) ?? { year: d.year, dps: 0, payoutCount: 0 };
    bucket.dps += d.amount;
    bucket.payoutCount += 1;
    annualByYear.set(d.year, bucket);
  }

  // Map corporate annual SF1 facts by fiscal report year for EPS & FCF/CFO per-share coverage
  const annualFactsByYear = new Map();
  const annualRows = Array.isArray(fundamental?.annual) ? fundamental.annual : [];
  const quarterlyRows = Array.isArray(fundamental?.quarterly) ? fundamental.quarterly : [];
  const hasCorporateFacts = annualRows.length > 0 || quarterlyRows.length > 0;
  const companyMeta = fundamental?.company ?? {};
  const isReit = /reit|real estate/i.test(`${companyMeta.sector ?? ''} ${companyMeta.industry ?? ''} ${companyMeta.sicindustry ?? ''}`);
  for (const row of annualRows) {
    const yr = Number.parseInt(String(row.reportperiod ?? '').slice(0, 4), 10);
    if (!Number.isFinite(yr)) continue;
    const shares = finite(row.shareswadil) ?? finite(row.shareswa) ?? finite(row.sharesbas);
    const eps = finite(row.epsdil) ?? finite(row.eps) ?? (finite(row.netinccmn) && shares > 0 ? row.netinccmn / shares : null);
    const cashMetric = isReit ? finite(row.ncfo) : finite(row.fcf);
    const fcfPs = !isReit && finite(row.fcfps) != null
      ? row.fcfps
      : (cashMetric != null && shares > 0 ? cashMetric / shares : null);
    const netInc = finite(row.netinccmn);
    const cashDivPaid = finite(row.ncfdiv) ? Math.abs(row.ncfdiv) : null;
    annualFactsByYear.set(yr, {
      eps,
      fcfPerShare: fcfPs,
      reportedDps: finite(row.dps),
      reportedPayoutRatio: finite(row.payoutratio),
      fcfPayoutFromCashFlow: cashDivPaid != null && cashMetric != null && cashMetric !== 0 ? cashDivPaid / cashMetric : null,
      epsPayoutFromIncome: cashDivPaid != null && netInc != null && netInc !== 0 ? cashDivPaid / netInc : null,
    });
  }

  const allYearsSorted = [...new Set([
    ...annualByYear.keys(),
    ...[...annualFactsByYear.keys()].filter(y => y >= minDisplayYear),
  ])].sort((a, b) => a - b);

  const annualAll = allYearsSorted.map((yr, idx) => {
    const divBucket = annualByYear.get(yr);
    const corp = annualFactsByYear.get(yr);
    const dps = divBucket ? Number(divBucket.dps.toFixed(5)) : (corp?.reportedDps ?? 0);
    const payoutCount = divBucket?.payoutCount ?? 0;
    const isYtdPartial = yr === asOfYear && !isFullCurrentYear && cadence.frequencyPerYear > 0 && payoutCount < cadence.frequencyPerYear;
    const prevYr = idx > 0 ? allYearsSorted[idx - 1] : null;
    const prevBucket = prevYr === yr - 1 ? annualByYear.get(prevYr) : null;
    const prevDps = prevBucket ? prevBucket.dps : null;
    const yoyGrowth = !isYtdPartial && finite(prevDps) && prevDps > 0 && dps > 0
      ? dps / prevDps - 1
      : null;
    const yearYields = dailyYieldSeries.filter(pt => pt.date.startsWith(`${yr}-`) && pt.yield > 0).map(pt => pt.yield);
    const eps = corp?.eps ?? null;
    const fcfPerShare = corp?.fcfPerShare ?? null;
    const epsPayoutRatio = corp?.epsPayoutFromIncome ?? (finite(eps) && eps !== 0 && dps > 0 ? dps / eps : corp?.reportedPayoutRatio ?? null);
    const fcfPayoutRatio = corp?.fcfPayoutFromCashFlow ?? (finite(fcfPerShare) && fcfPerShare !== 0 && dps > 0 ? dps / fcfPerShare : null);
    return {
      year: yr,
      label: isYtdPartial ? `${yr} YTD` : `${yr}`,
      isPartialYear: isYtdPartial,
      dps,
      payoutCount,
      yoyGrowth,
      avgYield: mean(yearYields),
      eps,
      fcfPerShare,
      epsPayoutRatio,
      fcfPayoutRatio,
    };
  });

  const annualFullYears = annualAll.filter(r => !r.isPartialYear && r.year < asOfYear + (isFullCurrentYear ? 1 : 0));
  const annualDisplay = annualAll.filter(r => r.year >= minDisplayYear);

  const cagr3y = status === 'no_dividends' ? null : computeCagr(annualFullYears, 3);
  const cagr5y = status === 'no_dividends' ? null : computeCagr(annualFullYears, 5);
  const cagr10y = status === 'no_dividends' ? null : (computeCagr(annualFullYears, 9) ?? computeCagr(annualFullYears, 8));
  const streaks = computeStreaks(
    annualFullYears,
    annualByYear.has(asOfYear),
    status === 'paying',
    cadence.frequencyPerYear,
  );

  // TTM EPS & FCF/CFO payout ratios from latest 4 consecutive quarters when available
  let ttmEpsPayoutRatio = null;
  let ttmFcfPayoutRatio = null;
  let ttmNetCommonFinancing = null;
  let dilutedSharesGrowth = finite(fundamental?.metrics?.dilutedSharesGrowth) ? fundamental.metrics.dilutedSharesGrowth : null;
  if (quarterlyRows.length >= 4) {
    const q4 = quarterlyRows.slice(0, 4);
    const sumField = key => q4.every(r => finite(r[key])) ? q4.reduce((s, r) => s + Number(r[key]), 0) : null;
    const ttmNetInc = sumField('netinccmn');
    const ttmCashMetric = isReit ? sumField('ncfo') : sumField('fcf');
    const ttmDivCash = sumField('ncfdiv');
    ttmNetCommonFinancing = sumField('ncfcommon');
    const divCashAbs = finite(ttmDivCash) ? Math.abs(ttmDivCash) : null;
    if (divCashAbs != null && divCashAbs > 0) {
      if (finite(ttmNetInc) && ttmNetInc !== 0) ttmEpsPayoutRatio = divCashAbs / ttmNetInc;
      if (finite(ttmCashMetric) && ttmCashMetric !== 0) ttmFcfPayoutRatio = divCashAbs / ttmCashMetric;
    } else if (currentTtmDps > 0) {
      const ttmEps = sumField('epsdil') ?? sumField('eps');
      const ttmFcfPs = !isReit ? sumField('fcfps') : null;
      if (finite(ttmEps) && ttmEps !== 0) ttmEpsPayoutRatio = currentTtmDps / ttmEps;
      if (finite(ttmFcfPs) && ttmFcfPs !== 0) ttmFcfPayoutRatio = currentTtmDps / ttmFcfPs;
    }
  }

  const safety = evaluateSafety({
    status,
    epsPayoutRatio: ttmEpsPayoutRatio,
    fcfPayoutRatio: ttmFcfPayoutRatio,
    hasCorporateFacts,
    isReit,
  });

  // Ex-dividend events with sequential change & ex-date yield
  const eventsDesc = dividendsAsc
    .map((ev, idx) => {
      const prev = idx > 0 ? dividendsAsc[idx - 1] : null;
      const changePct = prev && prev.amount > 0 ? ev.amount / prev.amount - 1 : null;
      let exPrice = priceByDate.get(ev.exDate) ?? null;
      if (exPrice == null && pricesAsc.length) {
        // Find nearest prior session within 7 days
        for (let k = pricesAsc.length - 1; k >= 0; k -= 1) {
          if (pricesAsc[k].date <= ev.exDate) {
            exPrice = pricesAsc[k].close;
            break;
          }
        }
      }
      const yieldOnExDate = finite(exPrice) && exPrice > 0 && cadence.frequencyPerYear > 0
        ? (ev.amount * cadence.frequencyPerYear) / exPrice
        : null;
      return {
        exDate: ev.exDate,
        year: ev.year,
        month: ev.month,
        amount: ev.amount,
        prevAmount: prev?.amount ?? null,
        changePct,
        priceOnExDate: exPrice,
        annualizedYieldOnExDate: yieldOnExDate,
      };
    })
    .reverse()
    .slice(0, 60);

  // 12-month seasonality calendar (trailing 3 years so active payout months are crystal clear)
  const seasonCutoff = shiftDays(asOf, -1100);
  const recentForSeason = dividendsAsc.filter(d => d.exDate >= seasonCutoff);
  const seasonality = Array.from({ length: 12 }, (_, idx) => {
    const month = idx + 1;
    const hits = recentForSeason.filter(d => d.month === month);
    const latestInMonth = hits.at(-1) ?? null;
    return {
      month,
      count3y: hits.length,
      active: hits.length > 0,
      latestExDate: latestInMonth?.exDate ?? null,
      latestAmount: latestInMonth?.amount ?? null,
    };
  });

  const estimatedNextExDate = status === 'paying' && latestEvent && finite(cadence.medianIntervalDays)
    ? shiftDays(latestEvent.exDate, Math.round(cadence.medianIntervalDays))
    : null;

  return {
    version: DIVIDEND_RESEARCH_VERSION,
    ticker,
    asOf,
    currency: 'USD',
    status,
    hasCorporateFacts,
    isReit,
    summary: {
      currentYield,
      forwardYield,
      ttmDps: Number(currentTtmDps.toFixed(5)),
      annualizedDps,
      latestPrice: latestQuotedClose,
      splitAdjustedPrice: latestSplitClose,
      frequency: cadence.frequency,
      frequencyPerYear: cadence.frequencyPerYear,
      medianIntervalDays: cadence.medianIntervalDays,
      avgYield5y,
      medianYield5y,
      stdYield5y,
      highYield5y,
      lowYield5y,
      avgYield10y,
      yieldVs5yAvgPct,
      cagr3y,
      cagr5y,
      cagr10y,
      consecutiveYearsPaid: streaks.consecutiveYearsPaid,
      consecutiveYearsGrown: streaks.consecutiveYearsGrown,
      epsPayoutRatio: ttmEpsPayoutRatio,
      fcfPayoutRatio: ttmFcfPayoutRatio,
      safetyLevel: safety.level,
      safetyBasis: safety.basis,
      latestExDate: latestEvent?.exDate ?? null,
      latestAmount: latestEvent?.amount ?? null,
      estimatedNextExDate,
      ttmNetCommonFinancing,
      dilutedSharesGrowth,
    },
    yieldHistory: sampleYieldHistory(dailyYieldSeries, 520),
    annualPayouts: annualDisplay,
    events: eventsDesc,
    seasonality,
    basisNote: 'Split-adjusted USD/share ex-dividend actions paired with split-adjusted closes as of the research cutoff.',
    catalogGeneration: factGen,
  };
}
