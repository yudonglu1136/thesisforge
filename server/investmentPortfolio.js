import { finite, isoDate } from './investmentMath.js';
import {localOwnerPortfolio} from './portfolioSnapshotStore.js';
import {portfolioMarketContext,portfolioValuations} from './portfolioRisk.js';
import {portfolioHome} from './portfolioHome.js';
import {portfolioGuruContext,portfolioGuruActivity,portfolioGuruBooks} from './portfolioGuruActivity.js';
import {portfolioSyncResult} from './portfolioSyncResult.js';
import {loadDividendCalendarForTickers} from './dividendClient.js';

const n = x => finite(x) ? x : null;
const sum = xs => xs.reduce((s, x) => s + x, 0);
const ratio = (a, b) => finite(a) && b > 0 ? a / b : null;
const day = v => { try { return isoDate(String(v ?? '').slice(0, 10)); } catch { return null; } };
const symbol = v => /^[A-Z][A-Z0-9.-]{0,14}$/.test(v ?? '') ? v : null;
const currency = v => /^[A-Z]{3}$/.test(v ?? '') ? v : null;
const empty = (status, asOf) => ({version: 'portfolio-research-v1', status, asOf, groups: [], managers: [], positions: []});

function dividendReadTimeoutMs() {
  const configured=Number(process.env.PORTFOLIO_DIVIDEND_READ_TIMEOUT_MS);
  return Number.isFinite(configured)?Math.max(250,Math.min(10_000,configured)):2_500;
}

function withDeadline(promise,ms) {
  let timer;
  const timeout=new Promise((_,reject)=>{timer=setTimeout(()=>reject(Object.assign(new Error('portfolio_dividend_read_timeout'),{code:'portfolio_dividend_read_timeout'})),ms);});
  return Promise.race([promise,timeout]).finally(()=>clearTimeout(timer));
}

function trailingYearStart(asOf) {
  const value=new Date(`${isoDate(asOf)}T00:00:00Z`);
  value.setUTCFullYear(value.getUTCFullYear()-1);
  return value.toISOString().slice(0,10);
}

function eligibleDividendPositions(analysis) {
  return analysis.groups.flatMap(group=>group.positions.filter(position=>{
    if(position.kind!=='equity'||!(position.quantity>0)||!(position.price>0)||!(position.value>0)||!(position.fxRateToBase>0))return false;
    const expected=position.quantity*position.price*position.fxRateToBase;
    return Math.abs(expected-position.value)<=Math.max(1,Math.abs(position.value)*.01);
  }).map(position=>({...position,baseCurrency:group.currency,quoteCurrency:position.currency})));
}

// This is a transparent current-holdings estimate, not broker cash income.
// Sharadar ACTIONS dividend values are already adjusted to the current share
// basis, so current verified shares can be multiplied by the trailing sum
// without manufacturing a split jump.
export function attachPortfolioTrailingDividends(analysis,calendar,{asOf,startDate=trailingYearStart(asOf)}={}) {
  const endDate=isoDate(asOf);
  const sharadar=calendar?.status?.source==='sharadar_fact_os';
  const unavailable=new Set((calendar?.status?.unavailable??[]).map(row=>row.ticker));
  const eventsByTicker=new Map();
  if(sharadar)for(const event of calendar.events??[]){
    const ticker=symbol(event.ticker),amount=n(event.amount),eventDate=day(event.exDate??event.date);
    if(!ticker||!(amount>0)||!eventDate||eventDate<startDate||eventDate>endDate)continue;
    const rows=eventsByTicker.get(ticker)??[];rows.push({...event,date:eventDate,amount});eventsByTicker.set(ticker,rows);
  }
  for(const group of analysis.groups??[]) {
    const byTicker=new Map();
    for(const position of group.positions??[]) {
      if(position.kind!=='equity'||!(position.quantity>0)||!(position.price>0)||!(position.value>0)||!(position.fxRateToBase>0))continue;
      const expected=position.quantity*position.price*position.fxRateToBase;
      if(Math.abs(expected-position.value)>Math.max(1,Math.abs(position.value)*.01))continue;
      const ticker=symbol(position.ticker);if(!ticker)continue;
      const previous=byTicker.get(ticker);
      byTicker.set(ticker,{ticker,name:position.name||ticker,sector:position.sector||'Unclassified',
        quantity:(previous?.quantity??0)+position.quantity,
        value:(previous?.value??0)+position.value,
        fxNumerator:(previous?.fxNumerator??0)+position.quantity*position.fxRateToBase});
    }
    const rows=[];
    for(const holding of byTicker.values()) {
      const events=eventsByTicker.get(holding.ticker)??[];
      const perShare=sum(events.map(event=>event.amount));
      const averageFx=holding.quantity>0?holding.fxNumerator/holding.quantity:null;
      const amount=perShare>0&&averageFx>0?perShare*holding.quantity*averageFx:0;
      if(amount>0)rows.push({id:`dividends:${holding.ticker}`,ticker:holding.ticker,name:holding.name,
        category:'dividends',sector:holding.sector,amount,perShare,quantity:holding.quantity,
        eventCount:events.length,value:amount});
    }
    rows.sort((a,b)=>b.amount-a.amount||a.ticker.localeCompare(b.ticker));
    const total=sum(rows.map(row=>row.amount));
    const weight=amount=>total>0?amount/total:0;
    const byInstrument=rows.map(row=>({...row,weight:weight(row.amount)}));
    const bySectorMap=new Map();
    for(const row of rows)bySectorMap.set(row.sector,(bySectorMap.get(row.sector)??0)+row.amount);
    const bySector=[...bySectorMap].map(([name,amount])=>({id:name,name,category:'dividends',amount,value:amount,weight:weight(amount)}))
      .sort((a,b)=>b.amount-a.amount||a.name.localeCompare(b.name));
    const eligible=[...byTicker.keys()];
    const covered=sharadar?eligible.filter(ticker=>!unavailable.has(ticker)).length:0;
    group.home.trailingDividends={status:sharadar?'ready':'unavailable',fromDate:startDate,toDate:endDate,
      annualAmount:sharadar?total:null,grossReceived:sharadar?total:null,eventCount:sharadar?rows.reduce((count,row)=>count+row.eventCount,0):0,
      estimatedYield:sharadar&&group.longValue>0?total/group.longValue:null,
      coveredHoldings:covered,eligibleHoldings:eligible.length,unavailableTickers:eligible.filter(ticker=>unavailable.has(ticker)),
      byInstrument:sharadar?byInstrument:[],bySector:sharadar?bySector:[],
      byType:sharadar&&total>0?[{id:'dividends',category:'dividends',amount:total,value:total,weight:1}]:[],
      basis:'current_verified_shares_x_trailing_12_month_sharadar_split_adjusted_dividend_per_share_sum',
      source:'sharadar_actions_ex_date_not_broker_cash_receipt',
      actualReceiptStatus:group.home?.history?.income?.status??'income_history_required'};
  }
  return analysis;
}

// No sample/legacy operator portfolio can be re-labelled as an account owner.
// The broker adapter supplies untouched report inputs, before display heuristics.
export function analysePortfolio(payload, {asOf, valuations = new Map(), books = [], sectors = new Map(), guruCoverage = {}, includeComparisons = true} = {}) {
  isoDate(asOf);
  const savedReport = payload?.source?.mode === 'saved_broker_report' && payload?.freshness?.status === 'stale';
  if (!payload?.source?.userScoped || !['live', 'multi_account_live', 'saved_broker_report'].includes(payload.source.mode))
    return empty(payload?.connection?.status === 'error' ? 'connection_error' : 'account_required', asOf);
  if (!['linked', 'linked_empty', 'linked_partial'].includes(payload.connection?.status)
    && !(savedReport && payload.connection?.status === 'stale_report')) return empty('connection_error', asOf);
  if (!(payload.analysisAccounts?.length)) return empty(payload.holdings?.length ? 'report_inputs_unavailable' : 'empty_account', asOf);

  const groups = [];
  const guruContext=portfolioGuruContext(books,asOf,guruCoverage);
  for (const base of [...new Set(payload.analysisAccounts.map(a => currency(a.currency)))]) {
    const accounts = payload.analysisAccounts.filter(a => currency(a.currency) === base);
    const positions = accounts.flatMap((a, ai) => (a.positions ?? []).map((h, hi) => {
      const quoteCurrency = currency(h.currency), reportDate = day(a.reportDate);
      const kind = String(h.assetCategory ?? '').toUpperCase();
      const cash = kind === 'CASH';
      const stock = ['STK', 'STOCK', 'EQUITY', 'COMMON STOCK'].includes(kind);
      const fx = base && quoteCurrency === base ? 1 : n(h.fxRateToBase);
      const value = base && quoteCurrency && fx > 0 && finite(h.localValue) ? h.localValue * fx : null;
      const quantity = n(h.quantity), price = n(h.price), ticker = symbol(h.ticker);
      // An ETF or derivative having an underlying ticker is never given that
      // underlying's DCF. No guessed shares, pence conversion or ADR matching.
      const consistent = quantity !== null && price > 0 && finite(h.localValue) &&
        Math.abs(quantity * price - h.localValue) <= Math.max(1, Math.abs(h.localValue) * .01);
      const model = ticker ? valuations.get(ticker) : null;
      let modelStatus = cash || !stock || !(quantity > 0) ? 'outside_model_scope'
        : !ticker ? 'identity_unresolved'
        : !reportDate ? 'report_date_missing'
        : !consistent || value === null ? 'units_or_fx_unverified'
        : !model || !(model.fairValue > 0) || !day(model.date) || model.date > asOf ? 'no_model'
        : !quoteCurrency || quoteCurrency !== model.currency ? 'currency_mismatch' : 'covered';
      const covered = modelStatus === 'covered';
      return {id: `${base ?? 'unknown'}:${ai}:${hi}`, accountNumber: ai + 1, ticker: ticker ?? String(h.ticker ?? 'Unresolved'),
        name: String(h.name ?? h.ticker ?? ''), cusip: h.cusip || null, assetCategory: kind,
        kind: cash ? 'cash' : kind==='ACCRUAL'?'accrual':stock ? 'equity' : 'other', currency: quoteCurrency, reportDate,
        quantity, price, value, fxRateToBase: n(fx), sector: sectors.get(ticker) ?? null,
        unrealizedPnl: stock && consistent && value !== null && finite(h.costBasisMoney)
          ? (h.localValue-h.costBasisMoney)*fx : null,
        multiplier:n(h.multiplier),strike:n(h.strike),expiry:day(h.expiry),
        modelStatus, model: covered ? model : null,
        modelValue: covered ? quantity * model.fairValue * fx : null,
        modelGap: covered ? model.fairValue / price - 1 : null,
        modelDelta: covered ? quantity * model.fairValue * fx - value : null};
    }));
    const known = positions.filter(p => finite(p.value));
    const unpriced = positions.length - known.length;
    const net = unpriced || !base ? null : sum(known.map(p => p.value));
    const long = known.filter(p => !['cash','accrual'].includes(p.kind) && p.value > 0);
    const longValue = sum(long.map(p => p.value));
    const equities = long.filter(p => p.kind === 'equity');
    const equityValue = sum(equities.map(p => p.value));
    const covered = equities.filter(p => p.modelStatus === 'covered');
    const coveredMark = sum(covered.map(p => p.value));
    const coveredModel = sum(covered.map(p => p.modelValue));
    const byName = new Map();
    for (const p of long) byName.set(p.ticker, (byName.get(p.ticker) ?? 0) + p.value);
    const concentration = [...byName].map(([ticker, value]) => ({ticker, value, weight: ratio(value, longValue)})).sort((a, b) => b.value - a.value);
    const bySector = new Map();
    for (const p of long) bySector.set(p.sector || 'Unclassified', (bySector.get(p.sector || 'Unclassified') ?? 0) + p.value);
    const reportedNav = accounts.every(a => finite(a.reportedNav)) ? sum(accounts.map(a => a.reportedNav)) : null;
    for (const p of positions) {
      p.netWeight = ratio(p.value, net);
      p.longWeight = p.value > 0 && !['cash','accrual'].includes(p.kind) ? ratio(p.value, longValue) : null;
      p.equityWeight = p.value > 0 && p.kind === 'equity' ? ratio(p.value, equityValue) : null;
      p.contribution = ratio(p.modelDelta, net);
    }
    const delta = covered.length ? coveredModel - coveredMark : null;
    const stress = [-.2, -.1].map(move => ({move,
      pnl: equityValue ? equityValue * move : null,
      netImpact: ratio(equityValue ? equityValue * move : null, net),
      remaining: net !== null && equityValue ? net + equityValue * move : null}));
    const comparisons = includeComparisons ? compareManagers(positions, equityValue, books, asOf) : [];
    for (const p of positions) {
      p.guruActivity=portfolioGuruActivity(p,guruContext);
      p.gurus=p.guruActivity.rows.filter(m=>m.held);
    }
    groups.push({currency: base, accountCount: accounts.length,
      reportDates: [...new Set(accounts.map(a => day(a.reportDate)))],
      netValue: net, reportedNav, reconciliation: finite(net) && finite(reportedNav) ? net - reportedNav : null,
      unpriced, positions, cash: sum(known.filter(p => p.kind === 'cash').map(p => p.value)),
      grossExposure: sum(known.filter(p => !['cash','accrual'].includes(p.kind)).map(p => Math.abs(p.value))),
      longValue, equityValue, shortValue: sum(known.filter(p => !['cash','accrual'].includes(p.kind) && p.value < 0).map(p => p.value)),
      otherValue: sum(known.filter(p => p.kind === 'other').map(p => p.value)),
      coverage: {count: covered.length, total: long.length, marketValue: coveredMark,
        weight: ratio(coveredMark, longValue), denominator: 'known_positive_non_cash_market_value'},
      valuation: {coveredMark, coveredModel: covered.length ? coveredModel : null,
        gap: ratio(delta, coveredMark), delta, netImpact: ratio(delta, net),
        markedRemainderValue: finite(net) && delta !== null ? net + delta : null},
      concentration, top5Weight: longValue ? sum(concentration.slice(0, 5).map(x => x.weight)) : null,
      sectors: [...bySector].map(([name, value]) => ({name, value, weight: ratio(value, longValue)})).sort((a,b)=>b.value-a.value),
      stress, comparisons,
      home: portfolioHome(accounts,positions,base),
    });
  }
  return {version: 'portfolio-research-v1', status: payload.connection.status === 'linked_partial' ? 'partial_accounts' : 'ready', asOf,
    source: savedReport ? 'saved_authenticated_broker_report' : payload.source.localOwnerSnapshot?'local_owner_broker_snapshot':'existing_authenticated_broker_report',
    ...(payload.freshness ? {freshness:payload.freshness} : {}),
    retrievedAt:payload.source.retrievedAt??null, generatedAt: payload.generatedAt ?? null,
    groups, managers: books.map(b => ({...b.guru, reportDate: b.filing.reportDate, availableAt: b.filing.filingDate})),
    methodology: {holdings: 'Latest saved/connected broker report; not reconstructed historical ownership.',
      value: 'Reported units × published fair value × report FX. Remainder held at reported marks. Not a complete portfolio fair value or expected return.',
      denominator: 'Net weights and impacts divide by summed reported holding marks including cash, not broker NAV. Reported NAV is reconciled separately. Unknown holding values block this denominator; positive-exposure coverage uses known marks only.',
      stress: 'Long equities marked down uniformly; cash, shorts, derivatives and other securities unchanged. Not VaR.',
      guru: 'Current reported long-equity allocation vs disclosed common-long 13F book. Not trade advice or fund performance.',
      sectors: 'Current stored issuer classifications, not historical PIT classifications.'}};
}

function compareManagers(positions, equityValue, books, asOf) {
  const user = new Map();
  for (const p of positions.filter(p => p.equityWeight !== null)) {
    const previous = user.get(p.ticker);
    user.set(p.ticker, {weight: (previous?.weight ?? 0) + p.equityWeight, cusips: [...(previous?.cusips ?? []), p.cusip].filter(Boolean)});
  }
  return books.filter(b => b.filing.filingDate <= asOf).map(b => {
    const common = b.holdings.filter(h => finite(h.value) && h.value > 0 && h.shares > 0);
    const total = sum(common.map(h => h.value));
    const complete = b.full && common.length === b.holdings.length && total > 0;
    const guru = new Map();
    for (const h of common) {
      if (!symbol(h.ticker)) continue;
      const prev = guru.get(h.ticker);
      guru.set(h.ticker, {weight: (prev?.weight ?? 0) + (complete ? h.value / total : 0),
        cusips: [...(prev?.cusips ?? []), h.cusip].filter(Boolean)});
    }
    const differences = [...new Set([...user.keys(), ...guru.keys()])].map(ticker => {
      const u = user.get(ticker), g = guru.get(ticker);
      const identity = u?.cusips.length && g?.cusips.length &&
        (!u.cusips.every(c => g.cusips.includes(c)) || !g.cusips.every(c => u.cusips.includes(c)))
        ? 'claim_mismatch' : 'exact_ticker';
      return {ticker, userWeight: u?.weight ?? 0,
        guruWeight: complete && identity !== 'claim_mismatch' ? g?.weight ?? 0 : null,
        difference: complete && identity !== 'claim_mismatch' ? (u?.weight ?? 0) - (g?.weight ?? 0) : null,
        shared: !!u && !!g && identity !== 'claim_mismatch', identity};
    }).sort((a,b) => Math.abs(b.difference ?? b.userWeight) - Math.abs(a.difference ?? a.userWeight));
    const shared = differences.filter(d => d.shared);
    return {guruId: b.guru.id, name: b.guru.name, avatar: b.guru.avatar,
      reportDate: b.filing.reportDate, availableAt: b.filing.filingDate, accession: b.filing.accessionNumber,
      complete, sharedCount: shared.length, sharedUserWeight: equityValue ? sum(shared.map(d => d.userWeight)) : null,
      overlap: complete && equityValue && differences.every(d=>d.identity!=='claim_mismatch')
        ? sum(shared.map(d => Math.min(d.userWeight, d.guruWeight))) : null, differences};
  }).sort((a,b) => (b.overlap ?? b.sharedUserWeight ?? -1) - (a.overlap ?? a.sharedUserWeight ?? -1));
}

export function buildPortfolioAnalysis(source, payload, asOf, options={}) {
  // Don't load public research when the private source is missing.
  const preliminary = analysePortfolio(payload, {asOf});
  if (!preliminary.groups.length) return preliminary;
  const portfolioTickers=[...new Set(preliminary.groups.flatMap(g=>g.positions.map(p=>p.ticker)).filter(symbol))];
  const valuations = portfolioValuations(source, asOf,portfolioTickers);
  const sectors = new Map();
  const query = source.db.prepare("SELECT json_extract(payload_json,'$.sector') sector FROM valuation_ticker_snapshots WHERE ticker=?");
  for (const t of new Set(preliminary.groups.flatMap(g=>g.positions.map(p=>p.ticker)))) {
    const sector = query.get(t)?.sector;
    if (sector) sectors.set(t, sector);
  }
  // The first paint must never scan the 13F warehouse. Guru comparison and
  // retrospective market context are background enhancements of the same
  // verified account payload.
  const guruCoverage=options.summary?{books:[]} : portfolioGuruBooks(source,asOf);
  const analysis=analysePortfolio(payload,{asOf,valuations,sectors,books:guruCoverage.books,guruCoverage,includeComparisons:!options.home});
  analysis.detailLevel=options.summary?'summary':options.home?'home':'detail';
  if(options.home||options.summary) return analysis;
  return portfolioMarketContext(source,analysis,payload,asOf,options);
}

export function registerPortfolioAnalysisRoute(app, service, loadPortfolio) {
  const respond = forceRefresh => async (req, res) => {
    res.setHeader('Cache-Control', 'private, no-store');
    res.vary('Authorization');
    res.vary('Accept-Encoding');
    if (!req.user?.id) return res.status(401).json({error: 'unauthorized'});
    try {
      const asOf = service.date(req.query.asOf);
      const local=localOwnerPortfolio(req.user);
      if (req.user.id === 'local-dev-user'&&!local) return res.json(empty('preview_account', asOf));
      // Never accept an owner ID/adminPortfolioHash in query/body. Ownership
      // comes exclusively from authentication, not a frontend-selected account.
      const scope=req.query.scope??'detail';
      if(!['home','summary','detail'].includes(scope))return res.status(400).json({error:'invalid_portfolio_scope'});
      const home=scope==='home',summary=scope==='summary';
      const loadStarted=performance.now();
      const payload = local??await loadPortfolio({
        // Keep the complete server-authenticated identity. In particular, an
        // authorized admin portfolio context must resolve to the same private
        // store here and in /api/portfolio/sync.
        user: req.user,
        forceRefresh,
        preferSaved: true,
        // This route owns its dated valuation/risk analysis. Loading the older
        // dashboard analytics here duplicated valuation, price-history and
        // dividend work before the actual analysis even began.
        includeAnalytics: false
      });
      const loadMs=performance.now()-loadStarted;
      const rate=req.query.riskFreeRate===undefined?.04:Number(req.query.riskFreeRate);
      if(!Number.isFinite(rate)||rate<0||rate>.2)return res.status(400).json({error:'invalid_risk_free_rate'});
      const buildStarted=performance.now();
      const analysis=buildPortfolioAnalysis(service.source, payload, asOf,{riskFreeRate:rate,home,summary});
      const buildMs=performance.now()-buildStarted;
      const dividendStarted=performance.now();
      if(!summary&&analysis.groups?.length){
        try{
          // Fact OS readers share a bounded queue. A long fundamental scan may
          // be ahead of this request, but Portfolio must still return usable
          // account data instead of waiting for that queue for up to minutes.
          const calendar=await withDeadline(loadDividendCalendarForTickers(eligibleDividendPositions(analysis),{
            startDate:trailingYearStart(asOf),endDate:asOf,
          }),dividendReadTimeoutMs());
          attachPortfolioTrailingDividends(analysis,calendar,{asOf});
        }catch{
          attachPortfolioTrailingDividends(analysis,{status:{source:'unavailable'},events:[]},{asOf});
        }
      }
      const dividendMs=performance.now()-dividendStarted;
      const result={
        ...analysis,
        // Connection metadata lets the client distinguish an unconfigured
        // account from a configured connection whose broker refresh failed.
        ...(payload?.connection?{connection:payload.connection}:{}),
      };
      if(forceRefresh){
        const sync=portfolioSyncResult(payload).response;
        // The analysis was built from this exact payload. Do not duplicate the
        // full private report in the response or make the client issue a
        // second, potentially divergent read.
        const {portfolio:_portfolio,...syncStatus}=sync;
        result.sync=syncStatus;
      }
      const totalMs=performance.now()-loadStarted;
      res.setHeader('Server-Timing',`portfolio-read;dur=${loadMs.toFixed(1)}, portfolio-build;dur=${buildMs.toFixed(1)}, portfolio-dividends;dur=${dividendMs.toFixed(1)}, total;dur=${totalMs.toFixed(1)}`);
      if(totalMs>1_000)console.warn('[portfolio-analysis] slow request',{scope,forceRefresh,totalMs:Number(totalMs.toFixed(1)),loadMs:Number(loadMs.toFixed(1)),buildMs:Number(buildMs.toFixed(1)),dividendMs:Number(dividendMs.toFixed(1)),groups:analysis.groups?.length??0});
      res.json(result);
    } catch (e) { res.status(e.status ?? 503).json({error: 'portfolio_analysis_unavailable'}); }
  };
  app.get('/api/investment/portfolio-analysis',respond(false));
  app.post('/api/investment/portfolio-analysis/sync',respond(true));
}
