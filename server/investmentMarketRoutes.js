import { withCanonicalMarket } from './investmentMarketContext.js';
import { opportunityBooks } from './investmentOpportunities.js';
import { factGeneration } from './factRepository.js';

// Only price-consuming workflows are prepared. Holdings, filings, AI rankings
// and company search do not wait for market scans. One batch per request, not
// one subprocess per holding. Private ownership is resolved before any read.
export async function withInvestmentMarketFacts(service,owner,request,route,handler) {
  if(!service.source?.canonicalMarket)return handler();
  // The production opportunities endpoint reads its pinned public-analysis
  // artifact. Rebuilding a canonical quote batch here would defeat the
  // materialization boundary and make every user pay for the source scan.
  if(route==='/opportunities'&&service.publicAnalysis)return handler();
  // Research is a multi-source workspace: its model history, saved records,
  // filings and 13F coverage remain useful when a host has not installed a
  // canonical Fact OS release yet. Do not let the optional comparison-price
  // prefetch block the whole company. This is deliberately narrower than a
  // provider fallback: once any canonical generation is published, reads stay
  // fail-closed on corruption, timeout or generation changes, and every
  // price-sensitive write below still requires canonical facts.
  if(route==='/research/:ticker') {
    const getGeneration=service.marketReadOptions?.getGeneration??factGeneration;
    if(!await getGeneration())return handler();
  }
  const body=request.body??{},params=request.params??{};
  let tickers=[],historyTickers=[];
  const asOf=service.date(request.query?.asOf??body.asOf);
  if(['/research/:ticker','/opportunities/:ticker','/fundamentals/:ticker'].includes(route)) {
    tickers=[params.ticker];
    if(route==='/research/:ticker')historyTickers=tickers;
  } else if(['/calculate','/valuation-drafts','/scenarios','/decisions','/watches'].includes(route)) {
    tickers=[body.ticker];
  } else if(['/reviews','/review/:id'].includes(route)) {
    tickers=[service.store.get(owner,params.id??body.decisionId,'decision').ticker];
  } else if(['/watch-reviews','/watches/:id'].includes(route)) {
    tickers=[service.store.get(owner,params.id??body.watchId,'watch').ticker];
  } else if(['/home','/portfolio'].includes(route)) {
    tickers=service.heads(owner,asOf).map(d=>d.ticker);
    if(route==='/home')tickers.push(...service.store.list(owner,'watch').map(w=>w.ticker));
  } else if(route==='/opportunities') {
    tickers=opportunityBooks(service.source,asOf,request.query?.quarter??null).books
      .flatMap(b=>[...b.holdings,...b.activity].map(h=>h.ticker));
  } else return handler();
  return withCanonicalMarket(tickers,asOf,handler,{historyTickers,...service.marketReadOptions});
}
