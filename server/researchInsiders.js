import { createHash } from 'node:crypto';
import { queryFacts } from './factRepository.js';

export const INSIDER_METHOD = 'reported-insider-activity-v1';
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const bad = message => Object.assign(new Error(message), { status: 400 });
const numeric = x => typeof x === 'number' && Number.isFinite(x) ? x : null;
const day = value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
  && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0,10) === value;
const bucket = () => ({ value: 0, lines: 0, priced: 0, unpriced: 0 });
function add(target, value) {
  target.lines++;
  if (value !== null && value > 0) { target.priced++; target.value += value; }
  else target.unpriced++;
}
function finish(target) {
  if (target.lines && !target.priced) target.value = null;
  target.complete = target.unpriced === 0;
  return target;
}

// USD is the explicit SF2 field contract, not a guess from the security master:
// https://sharadar.com/docs/insiders (transactionvalue and transactionpricepershare).
// P/S include both open-market and private trades; they do not establish intent.
export async function researchInsiders(ticker, asOf, options = {}, read = queryFacts) {
  ticker = String(ticker).trim().toUpperCase();
  if (!/^[A-Z0-9.^_-]{1,24}$/.test(ticker) || !day(asOf)) throw bad('invalid_insider_query');
  const months = Number(options.months ?? 6), limit = Number(options.limit ?? 20), offset = Number(options.offset ?? 0);
  const kind = options.kind ?? 'all';
  if (![3,6,12].includes(months) || !Number.isInteger(limit) || limit < 1 || limit > 50
      || !Number.isInteger(offset) || offset < 0 || offset > 20000
      || !['all','purchase','sale','other'].includes(kind)) throw bad('invalid_insider_query');
  // Calendar-month window, with an explicit partial first/current month.
  const end = new Date(`${asOf}T00:00:00Z`);
  const first = new Date(Date.UTC(end.getUTCFullYear(), end.getUTCMonth()-months+1, 1));
  const start = first.toISOString().slice(0,10);
  const facts = await read('get_insider_transactions',[ticker,start,asOf]);
  const raw = facts.rows.filter(r => day(r.date) && r.date >= start && r.date <= asOf);
  // Without accession/amendment linkage, matching by row number could count the
  // same trade twice. Quarantine affected owners for this window, show the rows.
  const amended = new Set(raw.filter(r => /\/A$/.test(r.formtype)).map(r => r.ownername));
  const timeline = Array.from({length:months},(_,i)=>({
    month:new Date(Date.UTC(first.getUTCFullYear(),first.getUTCMonth()+i,1)).toISOString().slice(0,7),
    purchases:bucket(),sales:bucket(),
  }));
  const summary = {purchases:bucket(),sales:bucket(),otherLines:0,excludedLines:0,reportingNames:0};
  const rows = raw.map(r => {
    const code = r.transactioncode ?? '', security = r.securityadcode ?? '';
    const action = code === 'P' ? 'purchase' : code === 'S' ? 'sale'
      : !code ? 'holding' : ['A','M','C','F','G'].includes(code) ? code : 'other';
    let exclusion = null;
    if (amended.has(r.ownername)) exclusion = 'amendment_unresolved';
    else if (!day(r.transactiondate) || r.transactiondate > r.date) exclusion = 'invalid_transaction_date';
    else if (!['4','5'].includes(r.formtype)) exclusion = 'not_transaction_form';
    else if (!['purchase','sale'].includes(action)) exclusion = 'not_purchase_sale';
    else if (!['NA','ND'].includes(security)) exclusion = 'derivative_or_unknown_security';
    else if ((action === 'purchase' && (security !== 'NA' || !(r.transactionshares > 0)))
       || (action === 'sale' && (security !== 'ND' || !(r.transactionshares < 0)))) exclusion = 'inconsistent_direction';
    if (!exclusion) {
      const key = action === 'purchase' ? 'purchases' : 'sales';
      const value = numeric(r.transactionvalue);
      add(summary[key],value);add(timeline.find(m=>m.month===r.date.slice(0,7))[key],value);
    } else {
      summary.excludedLines++;
      if (!['purchase','sale'].includes(action) || !['NA','ND'].includes(security)) summary.otherLines++;
    }
    return {...r,id:r.fact_id,kind:action,exclusion,
      valueUsd:numeric(r.transactionvalue),priceUsd:numeric(r.transactionpricepershare),
      shares:numeric(r.transactionshares),holdingsAfter:numeric(r.sharesownedfollowingtransaction)};
  });
  finish(summary.purchases);finish(summary.sales);
  summary.netReportedValue = summary.purchases.complete && summary.sales.complete
    ? summary.purchases.value-summary.sales.value : null;
  summary.reportingNames = new Set(rows.map(r=>r.ownername)).size;
  for (const m of timeline) {finish(m.purchases);finish(m.sales);}
  // Stable across unrelated source updates; changes on an affected row or method.
  const snapshotId = hash([INSIDER_METHOD,facts.security_id,start,asOf,rows.map(r=>r.id)]);
  if (options.snapshotId && options.snapshotId !== snapshotId)
    throw Object.assign(new Error('insider_snapshot_changed'),{status:409});
  const filtered = rows.filter(r => kind === 'all' || (kind === 'other'
    ? !['purchase','sale'].includes(r.kind) || !['NA','ND'].includes(r.securityadcode) : r.kind === kind && ['NA','ND'].includes(r.securityadcode)));
  const cik = /^sec:cik:(\d+)$/.exec(facts.company_id ?? '')?.[1];
  return {methodVersion:INSIDER_METHOD,ticker:facts.ticker,asOf,start,windowMonths:months,currency:'USD',snapshotId,
    sourceAsOf:facts.source_as_of,sourceGeneration:facts.generation,securityId:facts.security_id,
    coverage:rows.length?'available':'no_filings_in_window',pitBasis:'filing_date_filtered_current_vendor_snapshot',
    sourceLinkStatus:cik?'issuer_search_only':'unavailable',
    sourceSearchUrl:cik?`https://www.sec.gov/edgar/browse/?CIK=${cik}&owner=only`:null,
    summary,months:timeline,total:filtered.length,offset,limit,rows:filtered.slice(offset,offset+limit)};
}
