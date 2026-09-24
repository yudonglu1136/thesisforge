// Presentation attribution only: never changes published NAV or historical
// modeled costs. FIFO pairs post-cost simulated units, not broker tax lots.
export function ruleTradeIntervals({ events, start, end, opening, closing, inception, origin, gross, costs, supported }) {
  const method = 'fifo-post-cost-v1';
  if (!supported) return { method, status: 'unavailable_corporate_action', intervals: [] };
  const lots = [], intervals = [];
  let serial = 0;
  const fail = () => { throw Object.assign(new Error('rule_analysis_lot_mismatch'), { status: 503 }); };
  const near = (a, b) => Math.abs(a - b) <= 1e-8 * Math.max(1, Math.abs(b));
  const units = () => lots.reduce((a, l) => a + l.quantity, 0);
  function row(lot, quantity, date, price, exitCost, status, exitKind) {
    const entryCost = lot.cost * quantity / lot.quantity;
    const entryValue = quantity * lot.entryPrice / origin;
    const grossContribution = quantity * (price - lot.entryPrice) / origin;
    const costContribution = (entryCost + exitCost) / origin;
    return { id: `${lot.id}:${date}:${intervals.length}`, buyDate: lot.buyDate, buyPrice: lot.buyPrice,
      entryDate: lot.entryDate, entryPrice: lot.entryPrice, exitDate: date, exitPrice: price,
      carriedIn: lot.carriedIn, status, exitKind, quantity: quantity / origin,
      entryValue, exitValue: quantity * price / origin, entryCost: entryCost / origin,
      exitCost: exitCost / origin, grossContribution, costContribution,
      netContribution: grossContribution - costContribution,
      returnOnBasis: entryValue > 0 ? (grossContribution - costContribution) / entryValue : null };
  }
  function apply(e, include) {
    if (!Number.isFinite(e.quantity) || e.quantity < 0) fail();
    if (!near(units(), e.quantityBefore)) fail();
    if (e.side === 'buy') {
      lots.push({ id: ++serial, quantity: e.quantity, buyDate: e.date, buyPrice: e.price,
        entryDate: e.date, entryPrice: e.price, cost: include ? e.cost : 0, carriedIn: false });
    } else if (e.side === 'sell') {
      if (e.quantity > units() + 1e-12) fail();
      let remaining = e.quantity;
      while (remaining > 1e-15 && lots.length) {
        const lot = lots[0], amount = Math.min(remaining, lot.quantity);
        const paired = row(lot, amount, e.date, e.price, include ? e.cost * amount / e.quantity : 0,
          'closed', e.quantityAfter <= 1e-15 ? 'exit' : 'trim');
        if (include) intervals.push(paired);
        lot.cost *= 1 - amount / lot.quantity;
        lot.quantity -= amount;
        remaining -= amount;
        if (lot.quantity <= 1e-15) lots.shift();
      }
      if (remaining > 1e-12) fail();
    } else if (e.side === 'fee' && include) {
      // An exact zero quantity change can still carry the historical model's
      // target-turnover cost. Keep it explicit rather than fabricating a fill.
      intervals.push({ id: `fee:${e.date}`, status: 'fee', exitDate: e.date, quantity: 0,
        entryValue: 0, grossContribution: 0, costContribution: e.cost / origin,
        netContribution: -e.cost / origin, returnOnBasis: null });
    }
    if (!near(units(), e.quantityAfter)) fail();
  }
  const prior = events.filter(e => !inception && e.date <= start);
  for (const e of prior) apply(e, false);
  if (!inception) {
    if (!near(units(), opening ? opening.value / opening.price : 0)) fail();
    for (const lot of lots) {
      lot.entryDate = start;
      lot.entryPrice = opening.price;
      lot.cost = 0;
      lot.carriedIn = true;
    }
  }
  for (const e of events.filter(e => (inception ? e.date >= start : e.date > start) && e.date <= end)) apply(e, true);
  if (!near(units(), closing ? closing.value / closing.price : 0)) fail();
  for (const lot of lots) intervals.push(row(lot, lot.quantity, end, closing.price, 0, 'open', 'mark'));
  const sums = intervals.reduce((a, r) => ({ gross: a.gross + r.grossContribution,
    costs: a.costs + r.costContribution, net: a.net + r.netContribution }), { gross: 0, costs: 0, net: 0 });
  if (!near(sums.gross, gross) || !near(sums.costs, costs) || !near(sums.net, gross - costs)) fail();
  return { method, status: 'available', intervals,
    realized: intervals.filter(r => r.status === 'closed').reduce((a, r) => a + r.netContribution, 0),
    unrealized: intervals.filter(r => r.status === 'open').reduce((a, r) => a + r.netContribution, 0),
    feeOnly: intervals.filter(r => r.status === 'fee').reduce((a, r) => a + r.netContribution, 0),
    reconciliation: { gross: sums.gross, costs: sums.costs, net: sums.net, difference: sums.net - (gross - costs) } };
}
