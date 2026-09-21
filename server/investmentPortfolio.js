import { finite, isoDate } from './investmentMath.js';
import {localOwnerPortfolio} from './portfolioSnapshotStore.js';
import {portfolioMarketContext,portfolioValuations} from './portfolioRisk.js';
import {portfolioHome} from './portfolioHome.js';
import {portfolioGuruContext,portfolioGuruActivity,portfolioGuruBooks} from './portfolioGuruActivity.js';
import {portfolioSyncResult} from './portfolioSyncResult.js';

const n = x => finite(x) ? x : null;
const sum = xs => xs.reduce((s, x) => s + x, 0);
const ratio = (a, b) => finite(a) && b > 0 ? a / b : null;
const day = v => { try { return isoDate(String(v ?? '').slice(0, 10)); } catch { return null; } };
const symbol = v => /^[A-Z][A-Z0-9.-]{0,14}$/.test(v ?? '') ? v : null;
const currency = v => /^[A-Z]{3}$/.test(v ?? '') ? v : null;
const empty = (status, asOf) => ({version: 'portfolio-research-v1', status, asOf, groups: [], managers: [], positions: []});

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
  const valuations = portfolioValuations(source, asOf);
  const sectors = new Map();
  const query = source.db.prepare("SELECT json_extract(payload_json,'$.sector') sector FROM valuation_ticker_snapshots WHERE ticker=?");
  for (const t of new Set(preliminary.groups.flatMap(g=>g.positions.map(p=>p.ticker)))) {
    const sector = query.get(t)?.sector;
    if (sector) sectors.set(t, sector);
  }
  // Reuse disclosed books for the actual holdings only. Home still skips the
  // unrelated whole-book overlap matrix and retrospective risk simulation.
  const guruCoverage=portfolioGuruBooks(source,asOf);
  const analysis=analysePortfolio(payload,{asOf,valuations,sectors,books:guruCoverage.books,guruCoverage,includeComparisons:!options.home});
  if(options.home) return analysis;
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
      const home=req.query.scope==='home';
      const loadStarted=performance.now();
      const payload = local??await loadPortfolio({
        // Keep the complete server-authenticated identity. In particular, an
        // authorized admin portfolio context must resolve to the same private
        // store here and in /api/portfolio/sync.
        user: req.user,
        forceRefresh,
        preferSaved: true,
        includeAnalytics: !home
      });
      const loadMs=performance.now()-loadStarted;
      const rate=req.query.riskFreeRate===undefined?.04:Number(req.query.riskFreeRate);
      if(!Number.isFinite(rate)||rate<0||rate>.2)return res.status(400).json({error:'invalid_risk_free_rate'});
      if(req.query.scope!==undefined&&req.query.scope!=='home')return res.status(400).json({error:'invalid_portfolio_scope'});
      const buildStarted=performance.now();
      const analysis=buildPortfolioAnalysis(service.source, payload, asOf,{riskFreeRate:rate,home});
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
      const buildMs=performance.now()-buildStarted;
      res.setHeader('Server-Timing',`portfolio-read;dur=${loadMs.toFixed(1)}, portfolio-build;dur=${buildMs.toFixed(1)}`);
      res.json(result);
    } catch (e) { res.status(e.status ?? 503).json({error: 'portfolio_analysis_unavailable'}); }
  };
  app.get('/api/investment/portfolio-analysis',respond(false));
  app.post('/api/investment/portfolio-analysis/sync',respond(true));
}
