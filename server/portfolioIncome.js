import crypto from 'node:crypto';

const categories = new Map([
  ['Dividends', 'dividends'],
  ['Bond Interest Received', 'bond_interest'],
  ['Broker Interest Received', 'cash_interest'],
  ['Payment In Lieu Of Dividends', 'substitute_dividends'],
]);
const excluded = new Set(['Withholding Tax', 'Other Fees', 'Broker Interest Paid', 'Bond Interest Paid',
  'Commission Adjustments', 'Sales Tax', 'Transaction Fees', 'Advisor Fees',
  'Deposits/Withdrawals', 'Internal Cash Transfer', 'Internal Cash Transfers']);
const finite = v => v != null && v !== '' && typeof v !== 'boolean' && Number.isFinite(Number(v)) ? Number(v) : null;
const iso = value => {
  const d = String(value ?? '').split(';')[0].replace(/^(\d{4})(\d{2})(\d{2})$/, '$1-$2-$3');
  return /^\d{4}-\d{2}-\d{2}$/.test(d) && Number.isFinite(Date.parse(d)) && new Date(d).toISOString().slice(0, 10) === d ? d : null;
};

// Cash transactions only: never accruals, expected dividends, security market
// values or trade profits. Currency conversion uses the transaction's own FX.
export function brokerIncome(statement, currency, rows) {
  const fromDate = iso(statement.fromDate), toDate = iso(statement.toDate);
  const cash = rows(statement, 'CashTransaction');
  const events = cash.filter(r => categories.has(r.type)).map(r => {
    const sourceAmount = finite(r.amount), sourceCurrency = String(r.currency ?? '');
    const fx = sourceCurrency === currency ? 1 : finite(r.fxRateToBase);
    const ticker = String(r.symbol ?? '').trim(), category = categories.get(r.type);
    // Same economic row without a distinct transaction ID is ambiguous, not a
    // second receipt. The account boundary is retained by the snapshot table.
    const identity = r.transactionID || r.transactionId || JSON.stringify([
      r.dateTime, r.type, ticker, r.assetCategory, r.description, sourceAmount, sourceCurrency, fx,
    ]);
    return {eventKey: crypto.createHash('sha256').update(String(identity)).digest('hex'),
      date: iso(r.dateTime), ticker, assetCategory: String(r.assetCategory ?? ''), category,
      sourceCurrency, sourceAmount, fxRateToBase: fx,
      amount: sourceAmount !== null && fx > 0 ? sourceAmount * fx : null};
  });
  const taxEvents = cash.filter(r => r.type === 'Withholding Tax').map((r, idx) => {
    const sourceAmount = finite(r.amount), sourceCurrency = String(r.currency ?? '');
    const fx = sourceCurrency === currency ? 1 : finite(r.fxRateToBase);
    const ticker = String(r.symbol ?? '').trim();
    const identity = r.transactionID || r.transactionId || JSON.stringify([
      'tax', idx, r.dateTime, ticker, r.description, sourceAmount, sourceCurrency, fx,
    ]);
    return {eventKey: crypto.createHash('sha256').update(String(identity)).digest('hex'),
      date: iso(r.dateTime), ticker, sourceCurrency, sourceAmount, fxRateToBase: fx,
      amount: sourceAmount !== null && fx > 0 ? sourceAmount * fx : null};
  });
  const taxesValid = taxEvents.every(r => r.sourceCurrency && r.date && fromDate && toDate &&
    r.date >= fromDate && r.date <= toDate && r.amount !== null);
  const status = !rows(statement, 'CashTransactions').length ? 'cash_section_missing' :
    !currency || !fromDate || !toDate || fromDate > toDate ||
    cash.some(r => !categories.has(r.type) && !excluded.has(r.type)) ||
    events.some(r => !r.sourceCurrency || !r.date || r.date < fromDate || r.date > toDate || r.amount === null ||
      (!r.ticker && r.category !== 'cash_interest')) ||
    new Set(events.map(r => r.eventKey)).size !== events.length ? 'income_rows_need_review' : 'ready';
  return {incomeStatus: status, income: status === 'ready' ? events : [],
    dividendTaxStatus: status === 'ready' && taxesValid ? 'ready' : 'unavailable',
    dividendTaxes: status === 'ready' && taxesValid ? taxEvents : []};
}

export function parseOccOptionSymbol(rawSymbol) {
  const match = String(rawSymbol ?? '').trim().match(/^([A-Z0-9.]+?)\s*(\d{2})(\d{2})(\d{2})([CP])(\d{8})$/i);
  if (!match) return null;
  const [, underlying, yy, mm, dd, right, strikeDigits] = match;
  const expiry = iso(`20${yy}${mm}${dd}`);
  const strike = Number(strikeDigits) / 1000;
  if (!expiry || !Number.isFinite(strike) || strike <= 0) return null;
  return {
    underlying: underlying.toUpperCase(),
    expiry,
    right: right.toUpperCase(),
    strike,
  };
}

// Confirmed expired short Calls only: requires expiration-date BookTrade close
// on a short Call (BUY to close at $0 price/proceeds) with positive realized
// FIFO P&L (OTM worthless expiry; ITM assigned calls have 0 option FIFO P&L).
export function brokerExpiredShortCalls(statement, currency, rows) {
  const fromDate = iso(statement.fromDate), toDate = iso(statement.toDate);
  const validPeriod = Boolean(currency && fromDate && toDate && fromDate <= toDate);
  if (!rows(statement, 'Trades').length) {
    return {expiredCallsStatus: 'trades_section_missing', expiredShortCalls: []};
  }
  if (!validPeriod) {
    return {expiredCallsStatus: 'trade_rows_need_review', expiredShortCalls: []};
  }
  const trades = rows(statement, 'Trade');
  const expiredShortCalls = [];
  for (let i = 0; i < trades.length; i += 1) {
    const r = trades[i];
    if (String(r.assetCategory ?? '').toUpperCase() !== 'OPT') continue;
    const occ = parseOccOptionSymbol(r.symbol);
    const right = String(r.putCall || occ?.right || (/\sC$/i.test(String(r.description ?? '').trim()) ? 'C' : '')).toUpperCase();
    if (right !== 'C') continue;
    const tradeDate = iso(r.tradeDate);
    const expiry = iso(r.expiry) || occ?.expiry || null;
    if (!tradeDate || !expiry || tradeDate !== expiry) continue;
    if (tradeDate < fromDate || tradeDate > toDate) continue;
    if (r.transactionType !== undefined && String(r.transactionType) !== '' && String(r.transactionType) !== 'BookTrade') continue;
    if (r.openCloseIndicator !== undefined && String(r.openCloseIndicator) !== '' && String(r.openCloseIndicator).toUpperCase() !== 'C') continue;
    if (r.buySell !== undefined && String(r.buySell) !== '' && String(r.buySell).toUpperCase() !== 'BUY') continue;
    const qty = finite(r.quantity);
    if (qty !== null && !(qty > 0)) continue;
    const tradePrice = finite(r.tradePrice);
    if (tradePrice !== null && tradePrice !== 0) continue;
    const proceeds = finite(r.proceeds);
    if (proceeds !== null && proceeds !== 0) continue;
    const sourceCurrency = String(r.currency ?? currency);
    const fx = sourceCurrency === currency ? 1 : finite(r.fxRateToBase);
    const pnl = finite(r.fifoPnlRealized);
    if (pnl === null || !(fx > 0) || !(pnl * fx > 0)) continue;
    const amount = pnl * fx;
    const underlying = String(r.underlyingSymbol || occ?.underlying || String(r.symbol ?? '').trim().split(/\s+/)[0] || '').trim().toUpperCase();
    const strike = finite(r.strike) ?? occ?.strike ?? null;
    const identity = r.tradeID || r.transactionID || JSON.stringify(['exp_call', i, r.symbol, tradeDate, qty, pnl, sourceCurrency]);
    expiredShortCalls.push({
      eventKey: crypto.createHash('sha256').update(String(identity)).digest('hex'),
      date: tradeDate,
      ticker: underlying || String(r.symbol ?? '').trim(),
      contract: String(r.symbol ?? '').trim(),
      name: String(r.description ?? r.symbol ?? '').trim(),
      strike,
      expiry,
      contracts: qty !== null ? qty : 1,
      sourceCurrency,
      sourceAmount: pnl,
      fxRateToBase: fx,
      amount,
      category: 'expired_short_call',
    });
  }
  return {expiredCallsStatus: 'ready', expiredShortCalls};
}

function fallbackExpiredShortCallsFromRealized(history) {
  if (history?.tradeStatus !== 'ready' || !Array.isArray(history?.realized)) return null;
  const rows = [];
  for (const r of history.realized) {
    if (String(r.assetCategory ?? '').toUpperCase() !== 'OPT') continue;
    const occ = parseOccOptionSymbol(r.ticker);
    if (!occ || occ.right !== 'C') continue;
    const d = iso(r.date);
    const pnl = finite(r.pnl);
    if (!d || d !== occ.expiry || pnl === null || !(pnl > 0)) continue;
    rows.push({
      eventKey: r.eventKey || crypto.createHash('sha256').update(`${r.ticker}:${d}:${pnl}`).digest('hex'),
      date: d,
      ticker: occ.underlying,
      contract: String(r.ticker ?? '').trim(),
      name: String(r.name ?? r.ticker ?? '').trim(),
      strike: occ.strike,
      expiry: occ.expiry,
      contracts: null,
      amount: pnl,
      category: 'expired_short_call',
    });
  }
  return rows;
}

function enumerateMonths(fromDate, toDate) {
  if (!fromDate || !toDate || fromDate > toDate) return [];
  const [fy, fm] = fromDate.slice(0, 7).split('-').map(Number);
  const [ty, tm] = toDate.slice(0, 7).split('-').map(Number);
  const months = [];
  let y = fy, m = fm;
  while (y < ty || (y === ty && m <= tm)) {
    months.push(`${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}`);
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
    if (months.length > 120) break;
  }
  return months;
}

function collectPendingShortCalls(accounts, baseCurrency) {
  const byContract = new Map();
  for (const account of accounts ?? []) {
    if (baseCurrency && account.currency !== baseCurrency) continue;
    for (const pos of account.positions ?? []) {
      if (String(pos.assetCategory ?? '').toUpperCase() !== 'OPT') continue;
      const qty = finite(pos.quantity);
      if (qty === null || !(qty < 0)) continue;
      const occ = parseOccOptionSymbol(pos.ticker);
      const right = occ?.right || (/\sC$/i.test(String(pos.name ?? '').trim()) ? 'C' : '');
      if (right !== 'C') continue;
      const quoteCurrency = String(pos.currency ?? account.currency ?? '');
      const fx = quoteCurrency && quoteCurrency === account.currency ? 1 : finite(pos.fxRateToBase);
      const costBasis = finite(pos.costBasisMoney);
      const localValue = finite(pos.localValue);
      const collected = costBasis !== null && costBasis < 0 && fx > 0 ? -costBasis * fx : null;
      const mark = localValue !== null && fx > 0 ? localValue * fx : null;
      const key = String(pos.ticker ?? '').trim();
      const prev = byContract.get(key);
      const underlying = occ?.underlying || key.split(/\s+/)[0] || key;
      const expiry = iso(pos.expiry) || occ?.expiry || null;
      const strike = finite(pos.strike) ?? occ?.strike ?? null;
      byContract.set(key, {
        contract: key,
        ticker: underlying,
        name: String(pos.name ?? key).trim(),
        strike,
        expiry,
        contracts: (prev?.contracts ?? 0) + Math.abs(qty),
        collectedPremium: prev
          ? (prev.collectedPremium !== null && collected !== null ? prev.collectedPremium + collected : null)
          : collected,
        currentMark: prev
          ? (prev.currentMark !== null && mark !== null ? prev.currentMark + mark : null)
          : mark,
      });
    }
  }
  const rows = [...byContract.values()].sort((a, b) =>
    String(a.expiry ?? '9999-99-99').localeCompare(String(b.expiry ?? '9999-99-99')) ||
    a.ticker.localeCompare(b.ticker)
  );
  const allCollectedKnown = rows.length > 0 && rows.every(r => finite(r.collectedPremium) !== null);
  return {
    count: rows.length,
    totalContracts: rows.reduce((s, r) => s + r.contracts, 0),
    collectedPremium: allCollectedKnown ? rows.reduce((s, r) => s + r.collectedPremium, 0) : null,
    confirmed: false,
    rows,
  };
}

function isLeapYear(year) {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

function mapMonthDayToYear(targetYear, mmdd) {
  if (mmdd === '02-29' && !isLeapYear(targetYear)) return `${String(targetYear).padStart(4, '0')}-02-28`;
  return `${String(targetYear).padStart(4, '0')}-${mmdd}`;
}

function buildTickerBreakdown(divEvents, callEvents, totalAmount) {
  const map = new Map();
  const ensure = ticker => {
    const key = ticker || 'OTHER';
    if (!map.has(key)) {
      map.set(key, {ticker: key, dividends: 0, expiredCalls: 0, total: 0, dividendCount: 0, callCount: 0});
    }
    return map.get(key);
  };
  for (const r of divEvents) {
    const tb = ensure(r.ticker || 'CASH');
    tb.dividends += r.amount;
    tb.total += r.amount;
    tb.dividendCount += 1;
  }
  for (const r of callEvents) {
    const tb = ensure(r.ticker || 'OPT');
    tb.expiredCalls += r.amount;
    tb.total += r.amount;
    tb.callCount += (r.contracts ?? 1);
  }
  return [...map.values()]
    .map(row => ({...row, share: totalAmount > 0 ? row.total / totalAmount : 0}))
    .sort((a, b) => b.total - a.total || a.ticker.localeCompare(b.ticker));
}

function buildConfirmedEventRows(divEvents, callEvents, limit = 30) {
  return [
    ...divEvents.map(r => ({
      date: r.date,
      ticker: r.ticker || 'CASH',
      kind: 'dividend',
      label: r.category === 'substitute_dividends' ? 'PIL dividend' : 'Cash dividend',
      contracts: null,
      strike: null,
      expiry: null,
      amount: r.amount,
    })),
    ...callEvents.map(r => ({
      date: r.date,
      ticker: r.ticker,
      kind: 'expired_call',
      label: r.name || r.contract,
      contracts: r.contracts,
      strike: r.strike,
      expiry: r.expiry,
      amount: r.amount,
    })),
  ]
    .sort((a, b) => b.date.localeCompare(a.date) || b.amount - a.amount)
    .slice(0, limit);
}

export function portfolioPassiveIncome(accounts, baseCurrency = null) {
  const scoped = baseCurrency ? (accounts ?? []).filter(a => a.currency === baseCurrency) : (accounts ?? []);
  const pendingShortCalls = collectPendingShortCalls(scoped, baseCurrency);
  const histories = scoped.map(a => a.passiveHistoryEvidence ?? a.historyEvidence);
  const covered = histories.length > 0 && histories.every(h => h?.fromDate && h?.toDate);
  const fromDate = covered ? histories.map(h => h.fromDate).sort().at(-1) : null;
  const toDate = covered ? histories.map(h => h.toDate).sort()[0] : null;
  const validWindow = Boolean(covered && fromDate && toDate && fromDate <= toDate);

  const dividendsReady = validWindow && histories.every(h => h.incomeStatus === 'ready');
  const callArrays = validWindow ? histories.map(h =>
    h.expiredCallsStatus === 'ready' && Array.isArray(h.expiredShortCalls)
      ? h.expiredShortCalls
      : fallbackExpiredShortCallsFromRealized(h)
  ) : [];
  const expiredCallsReady = validWindow && callArrays.every(Array.isArray);

  const dividendEvents = dividendsReady
    ? histories.flatMap(h => h.income ?? []).filter(r =>
        (r.category === 'dividends' || r.category === 'substitute_dividends') &&
        r.amount > 0 &&
        r.date >= fromDate &&
        r.date <= toDate
      )
    : [];
  const taxReady = dividendsReady && histories.every(h => h.dividendTaxStatus === 'ready' && Array.isArray(h.dividendTaxes));
  const taxEvents = taxReady
    ? histories.flatMap(h => h.dividendTaxes ?? []).filter(r => r.date >= fromDate && r.date <= toDate)
    : [];
  const expiredCallEvents = expiredCallsReady
    ? callArrays.flat().filter(r => r.amount > 0 && r.date >= fromDate && r.date <= toDate)
    : [];

  const ready = dividendsReady && expiredCallsReady;
  const dividendsGross = dividendsReady ? dividendEvents.reduce((s, r) => s + r.amount, 0) : null;
  const withholdingTax = taxReady ? taxEvents.reduce((s, r) => s + r.amount, 0) : null;
  const dividendsNet = dividendsReady && withholdingTax !== null ? dividendsGross + withholdingTax : null;
  const expiredCallsTotal = expiredCallsReady ? expiredCallEvents.reduce((s, r) => s + r.amount, 0) : null;
  const totalConfirmed = ready ? dividendsGross + expiredCallsTotal : null;

  const monthMap = new Map(
    (ready ? enumerateMonths(fromDate, toDate) : []).map(m => [
      m,
      {month: m, dividends: 0, expiredCalls: 0, total: 0, dividendCount: 0, callCount: 0},
    ])
  );

  if (ready) {
    for (const r of dividendEvents) {
      const ym = r.date.slice(0, 7);
      const bucket = monthMap.get(ym);
      if (bucket) {
        bucket.dividends += r.amount;
        bucket.total += r.amount;
        bucket.dividendCount += 1;
      }
    }
    for (const r of expiredCallEvents) {
      const ym = r.date.slice(0, 7);
      const bucket = monthMap.get(ym);
      if (bucket) {
        bucket.expiredCalls += r.amount;
        bucket.total += r.amount;
        bucket.callCount += 1;
      }
    }
  }

  const byTicker = ready ? buildTickerBreakdown(dividendEvents, expiredCallEvents, totalConfirmed) : [];
  const recentEvents = ready ? buildConfirmedEventRows(dividendEvents, expiredCallEvents, 30) : [];

  const availableYears = [];
  const annual = {};
  if (ready) {
    const startY = Number(fromDate.slice(0, 4));
    const endY = Number(toDate.slice(0, 4));
    for (let y = endY; y >= startY; y -= 1) {
      const yr = String(y).padStart(4, '0');
      const priorYr = String(y - 1).padStart(4, '0');
      availableYears.push(yr);
      const yrStart = fromDate > `${yr}-01-01` ? fromDate : `${yr}-01-01`;
      const yrEnd = toDate < `${yr}-12-31` ? toDate : `${yr}-12-31`;
      const yrDivs = dividendEvents.filter(r => r.date >= yrStart && r.date <= yrEnd);
      const yrTaxes = taxEvents.filter(r => r.date >= yrStart && r.date <= yrEnd);
      const yrCalls = expiredCallEvents.filter(r => r.date >= yrStart && r.date <= yrEnd);

      const yrDivGross = yrDivs.reduce((s, r) => s + r.amount, 0);
      const yrTaxSum = taxReady ? yrTaxes.reduce((s, r) => s + r.amount, 0) : null;
      const yrDivNet = yrTaxSum !== null ? yrDivGross + yrTaxSum : null;
      const yrCallSum = yrCalls.reduce((s, r) => s + r.amount, 0);
      const yrTotal = yrDivGross + yrCallSum;

      const monthly12 = [];
      for (let m = 1; m <= 12; m += 1) {
        const mm = String(m).padStart(2, '0');
        const ym = `${yr}-${mm}`;
        const priorYm = `${priorYr}-${mm}`;
        const curBucket = monthMap.get(ym);
        const prevBucket = monthMap.get(priorYm);
        monthly12.push({
          month: ym,
          covered: Boolean(curBucket),
          dividends: curBucket?.dividends ?? 0,
          expiredCalls: curBucket?.expiredCalls ?? 0,
          total: curBucket?.total ?? 0,
          dividendCount: curBucket?.dividendCount ?? 0,
          callCount: curBucket?.callCount ?? 0,
          priorYearMonth: priorYm,
          priorYearCovered: Boolean(prevBucket),
          priorYearDividends: prevBucket?.dividends ?? 0,
          priorYearCalls: prevBucket?.expiredCalls ?? 0,
          priorYearTotal: prevBucket?.total ?? 0,
        });
      }

      const targetPriorStart = mapMonthDayToYear(y - 1, yrStart.slice(5));
      const targetPriorEnd = mapMonthDayToYear(y - 1, yrEnd.slice(5));
      const overlapPriorStart = fromDate > targetPriorStart ? fromDate : targetPriorStart;
      const overlapPriorEnd = toDate < targetPriorEnd ? toDate : targetPriorEnd;

      let yoy;
      if (overlapPriorStart <= overlapPriorEnd) {
        const compCurrStart = mapMonthDayToYear(y, overlapPriorStart.slice(5));
        const compCurrEnd = mapMonthDayToYear(y, overlapPriorEnd.slice(5));
        const currDivComp = dividendEvents
          .filter(r => r.date >= compCurrStart && r.date <= compCurrEnd)
          .reduce((s, r) => s + r.amount, 0);
        const currCallComp = expiredCallEvents
          .filter(r => r.date >= compCurrStart && r.date <= compCurrEnd)
          .reduce((s, r) => s + r.amount, 0);
        const currTotalComp = currDivComp + currCallComp;

        const priorDivComp = dividendEvents
          .filter(r => r.date >= overlapPriorStart && r.date <= overlapPriorEnd)
          .reduce((s, r) => s + r.amount, 0);
        const priorCallComp = expiredCallEvents
          .filter(r => r.date >= overlapPriorStart && r.date <= overlapPriorEnd)
          .reduce((s, r) => s + r.amount, 0);
        const priorTotalComp = priorDivComp + priorCallComp;
        const fullSamePeriod = overlapPriorStart === targetPriorStart && overlapPriorEnd === targetPriorEnd;

        yoy = {
          status: fullSamePeriod ? 'full_same_period' : 'overlapping_subperiod',
          priorYear: priorYr,
          currentFrom: compCurrStart,
          currentTo: compCurrEnd,
          priorFrom: overlapPriorStart,
          priorTo: overlapPriorEnd,
          currentTotal: currTotalComp,
          priorTotal: priorTotalComp,
          deltaTotal: currTotalComp - priorTotalComp,
          pctTotal: priorTotalComp > 0 ? (currTotalComp - priorTotalComp) / priorTotalComp : null,
          currentCalls: currCallComp,
          priorCalls: priorCallComp,
          deltaCalls: currCallComp - priorCallComp,
          pctCalls: priorCallComp > 0 ? (currCallComp - priorCallComp) / priorCallComp : null,
          currentDividends: currDivComp,
          priorDividends: priorDivComp,
          deltaDividends: currDivComp - priorDivComp,
          pctDividends: priorDivComp > 0 ? (currDivComp - priorDivComp) / priorDivComp : null,
        };
      } else {
        yoy = {
          status: 'prior_year_unavailable',
          priorYear: priorYr,
          currentFrom: yrStart,
          currentTo: yrEnd,
          priorFrom: null,
          priorTo: null,
          currentTotal: yrTotal,
          priorTotal: null,
          deltaTotal: null,
          pctTotal: null,
          currentCalls: yrCallSum,
          priorCalls: null,
          deltaCalls: null,
          pctCalls: null,
          currentDividends: yrDivGross,
          priorDividends: null,
          deltaDividends: null,
          pctDividends: null,
        };
      }

      annual[yr] = {
        year: yr,
        fromDate: yrStart,
        toDate: yrEnd,
        isFullYear: yrStart === `${yr}-01-01` && yrEnd === `${yr}-12-31`,
        isYtd: yr === toDate.slice(0, 4) && yrStart === `${yr}-01-01` && yrEnd < `${yr}-12-31`,
        totalConfirmed: yrTotal,
        dividends: {
          grossAmount: yrDivGross,
          withholdingTax: yrTaxSum,
          netAmount: yrDivNet,
          eventCount: yrDivs.length,
        },
        expiredCalls: {
          amount: yrCallSum,
          settlementCount: yrCalls.length,
          contractCount: yrCalls.reduce((s, r) => s + (r.contracts ?? 1), 0),
        },
        monthly: monthly12,
        byTicker: buildTickerBreakdown(yrDivs, yrCalls, yrTotal),
        recentEvents: buildConfirmedEventRows(yrDivs, yrCalls, 50),
        yoy,
      };
    }
  }

  return {
    status: ready ? 'ready' : (dividendsReady || expiredCallsReady) ? 'partial' : 'history_required',
    fromDate,
    toDate,
    totalConfirmed,
    dividends: {
      status: dividendsReady ? 'ready' : 'cash_history_required',
      grossAmount: dividendsGross,
      withholdingTax,
      netAmount: dividendsNet,
      eventCount: dividendEvents.length,
    },
    expiredCalls: {
      status: expiredCallsReady ? 'ready' : 'trade_history_required',
      amount: expiredCallsTotal,
      settlementCount: expiredCallEvents.length,
      contractCount: expiredCallEvents.reduce((s, r) => s + (r.contracts ?? 1), 0),
    },
    availableYears,
    annual,
    monthly: [...monthMap.values()],
    byTicker,
    recentEvents,
    pendingShortCalls,
    basis: 'confirmed_broker_cash_dividends_plus_otm_expired_short_call_fifo_net_premium',
  };
}

export function portfolioIncome(accounts) {
  const histories = accounts.map(a => a.historyEvidence);
  const covered = histories.length > 0 && histories.every(h => h?.fromDate && h?.toDate);
  const fromDate = covered ? histories.map(h => h.fromDate).sort().at(-1) : null;
  const toDate = covered ? histories.map(h => h.toDate).sort()[0] : null;
  const ready = covered && fromDate <= toDate && histories.every(h => h.incomeStatus === 'ready');
  const events = ready ? histories.flatMap(h => h.income ?? []).filter(r => r.date >= fromDate && r.date <= toDate) : [];
  // Positive received amounts form the pie. Negative reversals remain separate;
  // a pie of gross receipts must never be described as net income or a yield.
  const receipts = events.filter(r => r.amount > 0);
  const grossReceived = ready ? receipts.reduce((n, r) => n + r.amount, 0) : null;
  const reversals = ready ? events.filter(r => r.amount < 0).reduce((n, r) => n + r.amount, 0) : null;
  const sources = new Map(), types = new Map();
  for (const r of receipts) {
    const ticker = r.ticker || 'CASH', key = `${r.category}:${r.assetCategory}:${ticker}`;
    sources.set(key, {id: key, ticker, category: r.category, amount: (sources.get(key)?.amount ?? 0) + r.amount});
    types.set(r.category, (types.get(r.category) ?? 0) + r.amount);
  }
  const weight = amount => grossReceived > 0 ? amount / grossReceived : 0;
  return {status: ready ? 'ready' : 'income_history_required', fromDate, toDate,
    grossReceived, reversals, eventCount: events.length,
    byInstrument: [...sources.values()].map(r => ({...r, weight: weight(r.amount)})).sort((a, b) => b.amount - a.amount),
    byType: [...categories.values()].map(category => ({id: category, category, amount: ready ? types.get(category) ?? 0 : null,
      weight: ready ? weight(types.get(category) ?? 0) : null})),
    basis: 'reported_positive_cash_income_before_tax_fees_and_reversals_not_yield',
    // Bond interest may include accrued interest on a trade, not just coupons.
    source: 'ibkr_cash_transactions_reported_fx',
  };
}
