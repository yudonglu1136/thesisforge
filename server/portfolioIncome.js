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

export function brokerRealizedOptions(statement, currency, rows) {
  const fromDate = iso(statement.fromDate), toDate = iso(statement.toDate);
  const validPeriod = Boolean(currency && fromDate && toDate && fromDate <= toDate);
  if (!rows(statement, 'Trades').length) {
    return {realizedOptionsStatus: 'trades_section_missing', realizedOptions: []};
  }
  if (!validPeriod) {
    return {realizedOptionsStatus: 'trade_rows_need_review', realizedOptions: []};
  }
  const trades = rows(statement, 'Trade');
  const realizedOptions = [];
  for (let i = 0; i < trades.length; i += 1) {
    const r = trades[i];
    if (String(r.assetCategory ?? '').toUpperCase() !== 'OPT') continue;
    const occ = parseOccOptionSymbol(r.symbol);
    const desc = String(r.description ?? '').trim();
    const right = String(
      r.putCall ||
      occ?.right ||
      (/\sC$/i.test(desc) ? 'C' : /\sP$/i.test(desc) ? 'P' : '')
    ).toUpperCase();
    if (right !== 'C' && right !== 'P') continue;
    const tradeDate = iso(r.tradeDate);
    const expiry = iso(r.expiry) || occ?.expiry || null;
    if (!tradeDate || tradeDate < fromDate || tradeDate > toDate) continue;
    const openClose = String(r.openCloseIndicator ?? '').toUpperCase();
    if (openClose === 'O') continue;
    const sourceCurrency = String(r.currency ?? currency);
    const fx = sourceCurrency === currency ? 1 : finite(r.fxRateToBase);
    const pnl = finite(r.fifoPnlRealized);
    // Zero FIFO P&L rows are opening fills or ITM assignments folded into stock basis.
    if (pnl === null || !(fx > 0) || pnl === 0) continue;
    const amount = pnl * fx;
    const qty = finite(r.quantity);
    const contracts = qty !== null && Math.abs(qty) > 0 ? Math.abs(qty) : 1;
    const tradePrice = finite(r.tradePrice);
    const proceeds = finite(r.proceeds);
    const txType = String(r.transactionType ?? '');
    const buySell = String(r.buySell ?? '').toUpperCase();
    const isExpired = Boolean(
      expiry &&
      tradeDate === expiry &&
      (txType === '' || txType === 'BookTrade') &&
      (tradePrice === null || tradePrice === 0) &&
      (proceeds === null || proceeds === 0)
    );
    const outcome = isExpired
      ? (amount > 0 ? 'expired' : 'expired_loss')
      : (amount > 0 ? 'tp' : 'sl');
    const prefix = right === 'C' ? 'call' : 'put';
    const kind = `${prefix}_${outcome}`;
    const underlying = String(
      r.underlyingSymbol || occ?.underlying || String(r.symbol ?? '').trim().split(/\s+/)[0] || ''
    ).trim().toUpperCase();
    const strike = finite(r.strike) ?? occ?.strike ?? null;
    const identity = r.tradeID || r.transactionID || JSON.stringify(['opt_realized', i, r.symbol, tradeDate, qty, pnl, sourceCurrency]);
    realizedOptions.push({
      eventKey: crypto.createHash('sha256').update(String(identity)).digest('hex'),
      date: tradeDate,
      ticker: underlying || String(r.symbol ?? '').trim(),
      contract: String(r.symbol ?? '').trim(),
      name: desc || String(r.symbol ?? '').trim(),
      right,
      strike,
      expiry,
      contracts,
      buySell,
      isExpired,
      outcome,
      kind,
      sourceCurrency,
      sourceAmount: pnl,
      fxRateToBase: fx,
      amount,
      category: right === 'C' ? 'realized_call' : 'realized_put',
    });
  }
  return {realizedOptionsStatus: 'ready', realizedOptions};
}

// Confirmed expired short Calls only: kept for legacy compatibility alongside
// brokerRealizedOptions (which captures all Call & Put expiry/TP/SL P&L).
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
      right: 'C',
      strike,
      expiry,
      contracts: qty !== null ? qty : 1,
      isExpired: true,
      outcome: 'expired',
      kind: 'call_expired',
      sourceCurrency,
      sourceAmount: pnl,
      fxRateToBase: fx,
      amount,
      category: 'expired_short_call',
    });
  }
  return {expiredCallsStatus: 'ready', expiredShortCalls};
}

function normalizeRealizedOptionRow(r) {
  if (!r) return null;
  const amount = finite(r.amount);
  const d = iso(r.date);
  if (!d || amount === null || amount === 0) return null;
  const occ = parseOccOptionSymbol(r.contract || r.symbol || r.ticker);
  const name = String(r.name || r.contract || r.ticker || '').trim();
  const right = String(
    r.right ||
    occ?.right ||
    (r.category === 'expired_short_call' || r.category === 'realized_call' ? 'C' : '') ||
    (r.category === 'realized_put' ? 'P' : '') ||
    (/\sC$/i.test(name) ? 'C' : /\sP$/i.test(name) ? 'P' : '')
  ).toUpperCase();
  if (right !== 'C' && right !== 'P') return null;
  const expiry = iso(r.expiry) || occ?.expiry || null;
  const isExpired = typeof r.isExpired === 'boolean'
    ? r.isExpired
    : Boolean(r.category === 'expired_short_call' || (expiry && d === expiry));
  const outcome = r.outcome || (isExpired ? (amount > 0 ? 'expired' : 'expired_loss') : (amount > 0 ? 'tp' : 'sl'));
  const prefix = right === 'C' ? 'call' : 'put';
  const kind = r.kind || `${prefix}_${outcome}`;
  const ticker = String(r.ticker || occ?.underlying || name.split(/\s+/)[0] || 'OPT').trim().toUpperCase();
  const contracts = finite(r.contracts) !== null && Math.abs(finite(r.contracts)) > 0 ? Math.abs(finite(r.contracts)) : 1;
  const eventKey = r.eventKey || crypto.createHash('sha256').update(`${r.contract || ticker}:${d}:${amount}:${right}`).digest('hex');
  return {
    eventKey,
    date: d,
    ticker,
    contract: String(r.contract || name || ticker).trim(),
    name,
    right,
    strike: finite(r.strike) ?? occ?.strike ?? null,
    expiry,
    contracts,
    isExpired,
    outcome,
    kind,
    amount,
    category: right === 'C' ? 'realized_call' : 'realized_put',
  };
}

function fallbackRealizedOptionsFromRealized(history) {
  if (history?.tradeStatus !== 'ready' || !Array.isArray(history?.realized)) return null;
  const rows = [];
  for (const r of history.realized) {
    if (String(r.assetCategory ?? '').toUpperCase() !== 'OPT') continue;
    const occ = parseOccOptionSymbol(r.ticker);
    const name = String(r.name ?? r.ticker ?? '').trim();
    const right = occ?.right || (/\sC$/i.test(name) ? 'C' : /\sP$/i.test(name) ? 'P' : '');
    if (right !== 'C' && right !== 'P') continue;
    const d = iso(r.date);
    const pnl = finite(r.pnl);
    if (!d || pnl === null || pnl === 0) continue;
    const expiry = occ?.expiry || null;
    const isExpired = Boolean(expiry && d === expiry);
    const outcome = isExpired ? (pnl > 0 ? 'expired' : 'expired_loss') : (pnl > 0 ? 'tp' : 'sl');
    const prefix = right === 'C' ? 'call' : 'put';
    rows.push({
      eventKey: r.eventKey || crypto.createHash('sha256').update(`${r.ticker}:${d}:${pnl}`).digest('hex'),
      date: d,
      ticker: occ?.underlying || String(r.ticker ?? '').trim().split(/\s+/)[0] || 'OPT',
      contract: String(r.ticker ?? '').trim(),
      name,
      right,
      strike: occ?.strike ?? null,
      expiry,
      contracts: 1,
      isExpired,
      outcome,
      kind: `${prefix}_${outcome}`,
      amount: pnl,
      category: right === 'C' ? 'realized_call' : 'realized_put',
    });
  }
  return rows;
}

function resolveAccountRealizedOptions(account) {
  const passiveSlot = account?.passiveHistoryEvidence;
  const currentHist = account?.historyEvidence;
  if (passiveSlot?.realizedOptionsStatus === 'ready' && Array.isArray(passiveSlot.realizedOptions)) {
    return passiveSlot.realizedOptions.map(normalizeRealizedOptionRow).filter(Boolean);
  }
  const fromCurrent = currentHist?.realizedOptionsStatus === 'ready' && Array.isArray(currentHist.realizedOptions)
    ? currentHist.realizedOptions.map(normalizeRealizedOptionRow).filter(Boolean)
    : fallbackRealizedOptionsFromRealized(currentHist);

  // If a pre-upgrade saved passive ledger exists without realizedOptions, use full Call+Put
  // realized P&L from currentHist for its covered window and supplement older dates from
  // legacy expiredShortCalls (deduped by eventKey) so live users immediately see TP/SL P&L.
  if (passiveSlot) {
    const legacyExpired = passiveSlot.expiredCallsStatus === 'ready' && Array.isArray(passiveSlot.expiredShortCalls)
      ? passiveSlot.expiredShortCalls.map(normalizeRealizedOptionRow).filter(Boolean)
      : null;
    if (Array.isArray(fromCurrent)) {
      const merged = new Map();
      const currentFrom = iso(currentHist?.fromDate);
      for (const r of legacyExpired ?? []) {
        if (!currentFrom || r.date < currentFrom) merged.set(r.eventKey, r);
      }
      for (const r of fromCurrent) {
        merged.set(r.eventKey, r);
      }
      return [...merged.values()].sort((a, b) => a.date.localeCompare(b.date));
    }
    return legacyExpired;
  }

  if (Array.isArray(fromCurrent)) return fromCurrent;
  if (currentHist?.expiredCallsStatus === 'ready' && Array.isArray(currentHist.expiredShortCalls)) {
    return currentHist.expiredShortCalls.map(normalizeRealizedOptionRow).filter(Boolean);
  }
  return null;
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

function collectPendingShortOptions(accounts, baseCurrency, targetRight) {
  const byContract = new Map();
  for (const account of accounts ?? []) {
    if (baseCurrency && account.currency !== baseCurrency) continue;
    for (const pos of account.positions ?? []) {
      if (String(pos.assetCategory ?? '').toUpperCase() !== 'OPT') continue;
      const qty = finite(pos.quantity);
      if (qty === null || !(qty < 0)) continue;
      const occ = parseOccOptionSymbol(pos.ticker);
      const fallbackRight = /\sC$/i.test(String(pos.name ?? '').trim())
        ? 'C'
        : /\sP$/i.test(String(pos.name ?? '').trim())
          ? 'P'
          : '';
      const right = occ?.right || fallbackRight;
      if (right !== targetRight) continue;
      const quoteCurrency = String(pos.currency ?? account.currency ?? '');
      const fx = quoteCurrency && quoteCurrency === account.currency ? 1 : finite(pos.fxRateToBase);
      const costBasis = finite(pos.costBasisMoney);
      const localValue = finite(pos.localValue);
      const mult = finite(pos.multiplier) > 0 ? finite(pos.multiplier) : 100;
      const collected = costBasis !== null && costBasis < 0 && fx > 0 ? -costBasis * fx : null;
      const mark = localValue !== null && fx > 0 ? localValue * fx : null;
      const key = String(pos.ticker ?? '').trim();
      const prev = byContract.get(key);
      const underlying = occ?.underlying || key.split(/\s+/)[0] || key;
      const expiry = iso(pos.expiry) || occ?.expiry || null;
      const strike = finite(pos.strike) ?? occ?.strike ?? null;
      const contracts = (prev?.contracts ?? 0) + Math.abs(qty);
      const collateral = strike !== null && fx > 0 ? strike * mult * contracts * fx : null;
      byContract.set(key, {
        contract: key,
        ticker: underlying,
        right: targetRight,
        name: String(pos.name ?? key).trim(),
        strike,
        expiry,
        contracts,
        collateralExposure: targetRight === 'P' ? collateral : null,
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
  const allCollateralKnown = targetRight === 'P' && rows.length > 0 && rows.every(r => finite(r.collateralExposure) !== null);
  return {
    count: rows.length,
    totalContracts: rows.reduce((s, r) => s + r.contracts, 0),
    collectedPremium: allCollectedKnown ? rows.reduce((s, r) => s + r.collectedPremium, 0) : null,
    ...(targetRight === 'P'
      ? {collateralExposure: allCollateralKnown ? rows.reduce((s, r) => s + r.collateralExposure, 0) : null}
      : {}),
    confirmed: false,
    rows,
  };
}

function collectPendingShortCalls(accounts, baseCurrency) {
  return collectPendingShortOptions(accounts, baseCurrency, 'C');
}

function collectPendingShortPuts(accounts, baseCurrency) {
  return collectPendingShortOptions(accounts, baseCurrency, 'P');
}

function isLeapYear(year) {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

function mapMonthDayToYear(targetYear, mmdd) {
  if (mmdd === '02-29' && !isLeapYear(targetYear)) return `${String(targetYear).padStart(4, '0')}-02-28`;
  return `${String(targetYear).padStart(4, '0')}-${mmdd}`;
}

function summarizeOptions(optionEvents, ready = true) {
  let amount = 0, callAmount = 0, putAmount = 0;
  let expiredAmount = 0, closedProfitAmount = 0, closedLossAmount = 0;
  let callCount = 0, putCount = 0;
  let contractCount = 0, callContractCount = 0, putContractCount = 0;
  let winCount = 0, lossCount = 0;
  for (const r of optionEvents) {
    const a = r.amount;
    const c = r.contracts ?? 1;
    amount += a;
    contractCount += c;
    if (r.right === 'P') {
      putAmount += a;
      putCount += 1;
      putContractCount += c;
    } else {
      callAmount += a;
      callCount += 1;
      callContractCount += c;
    }
    if (a > 0) winCount += 1;
    else if (a < 0) lossCount += 1;
    if (r.isExpired) expiredAmount += a;
    else if (a > 0) closedProfitAmount += a;
    else closedLossAmount += a;
  }
  return {
    status: ready ? 'ready' : 'trade_history_required',
    amount: ready ? amount : null,
    callAmount: ready ? callAmount : null,
    putAmount: ready ? putAmount : null,
    expiredAmount: ready ? expiredAmount : null,
    closedProfitAmount: ready ? closedProfitAmount : null,
    closedLossAmount: ready ? closedLossAmount : null,
    settlementCount: optionEvents.length,
    callCount,
    putCount,
    contractCount,
    callContractCount,
    putContractCount,
    winCount,
    lossCount,
  };
}

function buildTickerBreakdown(divEvents, optionEvents, totalAmount) {
  const map = new Map();
  const ensure = ticker => {
    const key = ticker || 'OTHER';
    if (!map.has(key)) {
      map.set(key, {
        ticker: key,
        dividends: 0,
        callPnl: 0,
        putPnl: 0,
        optionsPnl: 0,
        expiredCalls: 0,
        total: 0,
        dividendCount: 0,
        callCount: 0,
        putCount: 0,
        optionCount: 0,
      });
    }
    return map.get(key);
  };
  for (const r of divEvents) {
    const tb = ensure(r.ticker || 'CASH');
    tb.dividends += r.amount;
    tb.total += r.amount;
    tb.dividendCount += 1;
  }
  for (const r of optionEvents) {
    const tb = ensure(r.ticker || 'OPT');
    const c = r.contracts ?? 1;
    if (r.right === 'P') {
      tb.putPnl += r.amount;
      tb.putCount += c;
    } else {
      tb.callPnl += r.amount;
      tb.callCount += c;
    }
    tb.optionsPnl += r.amount;
    tb.expiredCalls += r.amount;
    tb.total += r.amount;
    tb.optionCount += c;
  }
  return [...map.values()]
    .map(row => ({...row, share: totalAmount > 0 ? row.total / totalAmount : 0}))
    .sort((a, b) => Math.abs(b.total) - Math.abs(a.total) || b.total - a.total || a.ticker.localeCompare(b.ticker));
}

function buildConfirmedEventRows(divEvents, optionEvents, limit = 50) {
  return [
    ...divEvents.map(r => ({
      date: r.date,
      ticker: r.ticker || 'CASH',
      kind: 'dividend',
      right: null,
      outcome: null,
      category: r.category,
      label: r.category === 'substitute_dividends' ? 'PIL dividend' : 'Cash dividend',
      contracts: null,
      strike: null,
      expiry: null,
      amount: r.amount,
    })),
    ...optionEvents.map(r => ({
      date: r.date,
      ticker: r.ticker,
      kind: r.kind || (r.right === 'P' ? (r.amount >= 0 ? 'put_tp' : 'put_sl') : (r.isExpired && r.amount > 0 ? 'call_expired' : r.amount >= 0 ? 'call_tp' : 'call_sl')),
      right: r.right || 'C',
      outcome: r.outcome || (r.isExpired ? (r.amount > 0 ? 'expired' : 'expired_loss') : (r.amount > 0 ? 'tp' : 'sl')),
      label: r.name || r.contract,
      contracts: r.contracts,
      strike: r.strike,
      expiry: r.expiry,
      amount: r.amount,
    })),
  ]
    .sort((a, b) => b.date.localeCompare(a.date) || Math.abs(b.amount) - Math.abs(a.amount))
    .slice(0, limit);
}

export function portfolioPassiveIncome(accounts, baseCurrency = null) {
  const scoped = baseCurrency ? (accounts ?? []).filter(a => a.currency === baseCurrency) : (accounts ?? []);
  const pendingShortCalls = collectPendingShortCalls(scoped, baseCurrency);
  const pendingShortPuts = collectPendingShortPuts(scoped, baseCurrency);
  const histories = scoped.map(a => a.passiveHistoryEvidence ?? a.historyEvidence);
  const covered = histories.length > 0 && histories.every(h => h?.fromDate && h?.toDate);
  const fromDate = covered ? histories.map(h => h.fromDate).sort().at(-1) : null;
  const toDate = covered ? histories.map(h => h.toDate).sort()[0] : null;
  const validWindow = Boolean(covered && fromDate && toDate && fromDate <= toDate);

  const dividendsReady = validWindow && histories.every(h => h.incomeStatus === 'ready');
  const optionArrays = validWindow ? scoped.map(resolveAccountRealizedOptions) : [];
  const optionsReady = validWindow && optionArrays.every(Array.isArray);

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
  const optionEvents = optionsReady
    ? optionArrays.flat().filter(r => r.amount !== 0 && r.date >= fromDate && r.date <= toDate)
    : [];

  const ready = dividendsReady && optionsReady;
  const dividendsGross = dividendsReady ? dividendEvents.reduce((s, r) => s + r.amount, 0) : null;
  const withholdingTax = taxReady ? taxEvents.reduce((s, r) => s + r.amount, 0) : null;
  const dividendsNet = dividendsReady && withholdingTax !== null ? dividendsGross + withholdingTax : null;
  const optionsSummary = summarizeOptions(optionEvents, optionsReady);
  const optionsTotal = optionsSummary.amount;
  const totalConfirmed = ready ? dividendsGross + optionsTotal : null;
  const totalConfirmedNet = ready ? (dividendsNet ?? dividendsGross) + optionsTotal : null;

  const monthMap = new Map(
    (ready ? enumerateMonths(fromDate, toDate) : []).map(m => [
      m,
      {
        month: m,
        dividends: 0,
        callPnl: 0,
        putPnl: 0,
        optionsPnl: 0,
        expiredCalls: 0,
        total: 0,
        dividendCount: 0,
        callCount: 0,
        putCount: 0,
        optionCount: 0,
      },
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
    for (const r of optionEvents) {
      const ym = r.date.slice(0, 7);
      const bucket = monthMap.get(ym);
      if (bucket) {
        if (r.right === 'P') {
          bucket.putPnl += r.amount;
          bucket.putCount += 1;
        } else {
          bucket.callPnl += r.amount;
          bucket.callCount += 1;
        }
        bucket.optionsPnl += r.amount;
        bucket.expiredCalls += r.amount;
        bucket.total += r.amount;
        bucket.optionCount += 1;
      }
    }
  }

  const byTicker = ready ? buildTickerBreakdown(dividendEvents, optionEvents, totalConfirmed) : [];
  const recentEvents = ready ? buildConfirmedEventRows(dividendEvents, optionEvents, 50) : [];

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
      const yrOpts = optionEvents.filter(r => r.date >= yrStart && r.date <= yrEnd);

      const yrDivGross = yrDivs.reduce((s, r) => s + r.amount, 0);
      const yrTaxSum = taxReady ? yrTaxes.reduce((s, r) => s + r.amount, 0) : null;
      const yrDivNet = yrTaxSum !== null ? yrDivGross + yrTaxSum : null;
      const yrOptSummary = summarizeOptions(yrOpts, true);
      const yrOptSum = yrOptSummary.amount;
      const yrTotal = yrDivGross + yrOptSum;

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
          callPnl: curBucket?.callPnl ?? 0,
          putPnl: curBucket?.putPnl ?? 0,
          optionsPnl: curBucket?.optionsPnl ?? 0,
          expiredCalls: curBucket?.optionsPnl ?? 0,
          total: curBucket?.total ?? 0,
          dividendCount: curBucket?.dividendCount ?? 0,
          callCount: curBucket?.callCount ?? 0,
          putCount: curBucket?.putCount ?? 0,
          optionCount: curBucket?.optionCount ?? 0,
          priorYearMonth: priorYm,
          priorYearCovered: Boolean(prevBucket),
          priorYearDividends: prevBucket?.dividends ?? 0,
          priorYearCallPnl: prevBucket?.callPnl ?? 0,
          priorYearPutPnl: prevBucket?.putPnl ?? 0,
          priorYearOptions: prevBucket?.optionsPnl ?? 0,
          priorYearCalls: prevBucket?.optionsPnl ?? 0,
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
        const currOptComp = optionEvents
          .filter(r => r.date >= compCurrStart && r.date <= compCurrEnd)
          .reduce((s, r) => s + r.amount, 0);
        const currTotalComp = currDivComp + currOptComp;

        const priorDivComp = dividendEvents
          .filter(r => r.date >= overlapPriorStart && r.date <= overlapPriorEnd)
          .reduce((s, r) => s + r.amount, 0);
        const priorOptComp = optionEvents
          .filter(r => r.date >= overlapPriorStart && r.date <= overlapPriorEnd)
          .reduce((s, r) => s + r.amount, 0);
        const priorTotalComp = priorDivComp + priorOptComp;
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
          currentOptions: currOptComp,
          priorOptions: priorOptComp,
          deltaOptions: currOptComp - priorOptComp,
          pctOptions: priorOptComp > 0 ? (currOptComp - priorOptComp) / priorOptComp : null,
          currentCalls: currOptComp,
          priorCalls: priorOptComp,
          deltaCalls: currOptComp - priorOptComp,
          pctCalls: priorOptComp > 0 ? (currOptComp - priorOptComp) / priorOptComp : null,
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
          currentOptions: yrOptSum,
          priorOptions: null,
          deltaOptions: null,
          pctOptions: null,
          currentCalls: yrOptSum,
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
        options: {
          amount: yrOptSummary.amount,
          callAmount: yrOptSummary.callAmount,
          putAmount: yrOptSummary.putAmount,
          expiredAmount: yrOptSummary.expiredAmount,
          closedProfitAmount: yrOptSummary.closedProfitAmount,
          closedLossAmount: yrOptSummary.closedLossAmount,
          settlementCount: yrOptSummary.settlementCount,
          callCount: yrOptSummary.callCount,
          putCount: yrOptSummary.putCount,
          contractCount: yrOptSummary.contractCount,
          callContractCount: yrOptSummary.callContractCount,
          putContractCount: yrOptSummary.putContractCount,
          winCount: yrOptSummary.winCount,
          lossCount: yrOptSummary.lossCount,
        },
        expiredCalls: {
          amount: yrOptSummary.amount,
          settlementCount: yrOptSummary.settlementCount,
          contractCount: yrOptSummary.contractCount,
        },
        monthly: monthly12,
        byTicker: buildTickerBreakdown(yrDivs, yrOpts, yrTotal),
        recentEvents: buildConfirmedEventRows(yrDivs, yrOpts, 60),
        yoy,
      };
    }
  }

  return {
    status: ready ? 'ready' : (dividendsReady || optionsReady) ? 'partial' : 'history_required',
    fromDate,
    toDate,
    totalConfirmed,
    totalConfirmedNet,
    dividends: {
      status: dividendsReady ? 'ready' : 'cash_history_required',
      grossAmount: dividendsGross,
      withholdingTax,
      netAmount: dividendsNet,
      eventCount: dividendEvents.length,
    },
    options: optionsSummary,
    expiredCalls: {
      status: optionsReady ? 'ready' : 'trade_history_required',
      amount: optionsTotal,
      settlementCount: optionsSummary.settlementCount,
      contractCount: optionsSummary.contractCount,
    },
    availableYears,
    annual,
    monthly: [...monthMap.values()],
    byTicker,
    recentEvents,
    pendingShortCalls,
    pendingShortPuts,
    basis: 'confirmed_broker_cash_dividends_plus_realized_call_put_option_fifo_pnl',
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
