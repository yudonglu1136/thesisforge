import { InvestmentSource } from './investmentSource.js';
import { guruStudy } from './investmentGuruStudy.js';
import { InvestmentStore } from './investmentStore.js';
import { resolveInvestmentRuntimeConfig, verifiedInvestmentOwner } from './investmentRuntimeConfig.js';
import { InvestmentService } from './investmentService.js';
import { earningsResearch } from './investmentEarnings.js';
import { researchCompanies } from './investmentCompanies.js';
import { registerPortfolioAnalysisRoute } from './investmentPortfolio.js';
import { registerStrategyLabRoutes } from './strategyLabRoutes.js';
import { registerHedgeRoutes } from './hedgeRoutes.js';
import { createAiInsightsService } from './investmentAiInsights.js';
import { fundamentalGuruQuarter } from './investmentFundamentals.js';
import { buildGuruHoldingsMatrix, buildOpportunities, opportunityCompanySummary, saveWatch, reviewWatch, saveWatchReview } from './investmentOpportunities.js';
import { institutional13fInsights, institutional13fInsightDetail, institutional13fSectorDetail } from './institutional13fInsights.js';
import { buildFundamentalDiscovery, buildFundamentalCompany, saveFundamentalObservation,
  listFundamentalObservations, reviewFundamentalObservation } from './fundamentalResearch.js';
import { researchDocuments, researchFundamentals, researchInstitutions, researchPublishedModel,
  saveResearchRecord, listResearchRecords } from './researchWorkbench.js';
import { loadInvestorStyleDashboard } from './investorStyleDashboard.js';
import { withInvestmentMarketFacts } from './investmentMarketRoutes.js';
import { factOsEnabled } from './factRepository.js';

export function registerInvestmentRoutes(app,service) {
  // One service instance owns generation caches and snapshot validation for
  // both reads and saved research. A second route-local instance can otherwise
  // observe another manifest generation during the same user workflow.
  const aiInsights = service.aiInsights ??= createAiInsightsService();
  const aiQuery = request => ({...request.query, asOf: service.date(request.query.asOf)});
  function route(method,path,handler,{cacheControl='private, no-store'}={}) {app[method]('/api/investment'+path,async (req,res)=>{
    // These URLs are cutoff-based, not immutable generation URLs. Revalidate
    // across a data-only publication; browser SWR must not serve the old release.
    res.setHeader('Cache-Control',service.source?.canonicalMarket&&cacheControl!=='private, no-store'
      ?'private, no-cache':cacheControl);
    if(!req.user?.id)return res.status(401).json({error:'unauthorized'});
    try {res.json(await withInvestmentMarketFacts(service,req.user.id,req,path,()=>handler(req.user.id,req)));}catch(e){
      res.setHeader('Cache-Control','private, no-store');
      if(e.name==='FactDataError') {
        const safeCodes=['local_runtime_unavailable','local_data_unavailable','local_snapshot_changed','local_query_timeout'];
        console.error('[investment:facts]',path,safeCodes.includes(e.code)?e.code:'local_query_failed');
        return res.status(503).json({error:safeCodes.includes(e.code)?e.code:'local_query_failed'});
      }
      res.status(e.status??500).json({error:e.status?e.message:'investment_request_failed'});
    }
  });}
  route('get','/13f-sectors/:sector',(_,r)=>institutional13fSectorDetail(service.source,r.params.sector,
    service.date(r.query.asOf),r.query.quarter??null,r.query));
  route('get','/home',(owner,r)=>service.home(owner,r.query.asOf));
  route('get','/discover',(owner,r)=>service.discover(owner,r.query.asOf));
  route('get','/guru-study',(_,r)=>guruStudy(service.source,service.date(r.query.asOf),r.query.period??'common'));
  route('get','/investor-styles',(_,r)=>loadInvestorStyleDashboard({asOf:service.date(r.query.asOf),snapshotId:r.query.snapshotId}),
    {cacheControl:'private, max-age=300, stale-while-revalidate=3600'});
  route('get','/companies',(_,r)=>researchCompanies(service.source,service.date(r.query.asOf),{
    search:r.query.search,limit:r.query.limit,
  }));
  route('get','/ai-insights',(_,r)=>aiInsights.overview(aiQuery(r)));
  route('get','/ai-insights/rankings',(_,r)=>aiInsights.rankings(aiQuery(r)));
  route('get','/ai-insights/compare',(_,r)=>aiInsights.compare(aiQuery(r)));
  route('get','/ai-insights/methodology',()=>aiInsights.methodology());
  route('get','/ai-insights/companies/:ticker',(_,r)=>aiInsights.company(r.params.ticker,aiQuery(r)));
  route('get','/fundamentals',(_,r)=>(service.fundamentalDiscovery??buildFundamentalDiscovery)(service.date(r.query.asOf),{
    lens:r.query.lens,search:r.query.search,limit:r.query.limit,offset:r.query.offset,sort:r.query.sort,
    minRevenueGrowth:r.query.minRevenueGrowth,minOperatingMargin:r.query.minOperatingMargin,
    minFcfMargin:r.query.minFcfMargin,
  }),{cacheControl:'private, max-age=300, stale-while-revalidate=3600'});
  route('get','/fundamentals/:ticker',(_,r)=>(service.fundamentalCompany??buildFundamentalCompany)(service.source,r.params.ticker,service.date(r.query.asOf),{lens:r.query.lens}),
    {cacheControl:'private, max-age=300, stale-while-revalidate=3600'});
  route('get','/fundamentals/:ticker/gurus',(_,r)=>fundamentalGuruQuarter(service.source,r.params.ticker,service.date(r.query.asOf),r.query.quarter??null));
  route('get','/fundamental-observations',(owner,r)=>listFundamentalObservations(service,owner,r.query.ticker??null));
  route('post','/fundamental-observations',(owner,r)=>saveFundamentalObservation(service,owner,r.body));
  route('get','/fundamental-observations/:id/review',(owner,r)=>reviewFundamentalObservation(service,owner,r.params.id,r.query.asOf));
  route('get','/opportunities',(_,r)=>buildOpportunities(service.source,service.date(r.query.asOf),r.query.quarter??null));
  route('get','/guru-holdings',(owner,r)=>({
    ...buildGuruHoldingsMatrix(service.source,service.date(r.query.asOf),r.query.quarter??null),
    // The first Guru screen only needs this compact directory. Bundling it
    // avoids blocking the matrix on the much broader Discover payload while
    // preserving owner-scoped follow state.
    gurus:service.guruDirectory(owner),
  }),
    {cacheControl:'private, max-age=300, stale-while-revalidate=3600'});
  route('get','/13f-insights',(_,r)=>institutional13fInsights(service.source,service.date(r.query.asOf),r.query.quarter??null,{
    ticker:r.query.ticker,action:r.query.action,rank:r.query.rank,segment:r.query.segment,
    search:r.query.search,limit:r.query.limit,scope:r.query.scope,
  }),{cacheControl:'private, max-age=300, stale-while-revalidate=3600'});
  route('get','/13f-insights/:ticker',(_,r)=>institutional13fInsightDetail(service.source,r.params.ticker,service.date(r.query.asOf),r.query.quarter??null,r.query.scope??'all'),
    {cacheControl:'private, max-age=300, stale-while-revalidate=3600'});
  route('get','/opportunities/:ticker',(_,r)=>opportunityCompanySummary(service.source,r.params.ticker,service.date(r.query.asOf)),
    {cacheControl:'private, max-age=300, stale-while-revalidate=3600'});
  route('post','/watches',(owner,r)=>saveWatch(service,owner,r.body));
  route('get','/watches/:id',(owner,r)=>reviewWatch(service,owner,r.params.id,r.query.asOf));
  route('post','/watch-reviews',(owner,r)=>saveWatchReview(service,owner,r.body));
  route('get','/gurus/:id',(_,r)=>service.source.guruDetail(r.params.id,service.date(r.query.asOf)));
  route('get','/research/:ticker',(owner,r)=>service.research(owner,r.params.ticker,r.query.asOf));
  route('get','/research/:ticker/documents',(_,r)=>researchDocuments(service.source,r.params.ticker,service.date(r.query.asOf)));
  route('get','/research/:ticker/fundamentals',(_,r)=>researchFundamentals(service,r.params.ticker,r.query.asOf));
  route('get','/research/:ticker/institutions',(_,r)=>researchInstitutions(service,r.params.ticker,r.query.asOf,r.query.quarter??null));
  route('get','/research/:ticker/published-model',(_,r)=>researchPublishedModel(service,r.params.ticker,r.query.asOf));
  route('get','/research/:ticker/records',(owner,r)=>listResearchRecords(service,owner,r.params.ticker));
  route('get','/research/:ticker/earnings',(_,r)=>earningsResearch(service.source,r.params.ticker,service.date(r.query.asOf),r.query.period));
  route('post','/research-records',(owner,r)=>saveResearchRecord(service,owner,r.body));
  route('post','/calculate',(_,r)=>service.calculate(r.body));
  route('post','/valuation-drafts',(owner,r)=>service.saveWorksheet(owner,r.body));
  route('post','/scenarios',(owner,r)=>service.saveScenario(owner,r.body));
  route('post','/decisions',(owner,r)=>service.saveDecision(owner,r.body));
  route('get','/review/:id',(owner,r)=>service.reviewContext(owner,r.params.id,r.query.asOf));
  route('post','/reviews',(owner,r)=>service.saveReview(owner,r.body));
  route('post','/follows',(owner,r)=>service.follow(owner,r.body));
  route('post','/strategies',(owner,r)=>service.strategy(owner,r.body));
  route('get','/portfolio',(owner,r)=>service.portfolio(owner,r.query.asOf));
}
export function investmentProductionIdentity(req, res, next) {
  // requireAuth supplies both objects only after verifying the bearer token.
  // A frontend owner field, local preview identity or mismatched admin context
  // must never become a production investment-journal owner.
  if (!verifiedInvestmentOwner(req.user?.id) || req.auth?.user?.id !== req.user.id)
    return res.status(401).json({error:'unauthorized'});
  next();
}

export function enableInvestmentPreview(app) {
  const config=resolveInvestmentRuntimeConfig();
  if(!config)return;
  if(config.production)app.use('/api/investment',investmentProductionIdentity);
  const source=new InvestmentSource(config.research,{insightsFile:config.insights,canonicalMarket:factOsEnabled()});
  let store;
  try {store=new InvestmentStore(config.investment,undefined,{verifiedOwnersOnly:config.production});}
  catch(error){source.close();throw error;}
  const aiInsights=createAiInsightsService({factRoot:config.aiInsightsRoot});
  const service=new InvestmentService(source,store,undefined,{aiInsights});
  registerInvestmentRoutes(app,service);
  registerStrategyLabRoutes(app,service);
  registerHedgeRoutes(app,service);
  registerPortfolioAnalysisRoute(app,service, async options => {
    const {loadPortfolioDashboard} = await import('./portfolioClient.js');
    return loadPortfolioDashboard(options);
  });
  return service;
}
