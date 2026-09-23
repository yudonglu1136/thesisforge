import {DatabaseSync} from 'node:sqlite';
import {signature} from './investmentMath.js';
import {holdingResolutionVersion} from './cusipOverrides.js';
import {manager13fCorporateActionCatalogVersion} from './corporateActions.js';
import {selectedBook} from './strategyLab.js';
import {strategyModelTickers} from './strategyValuationLinks.js';
import {linkedStrategyComparisonPrices} from './strategyCompositionPrices.js';
import {enabledManager13fGurus} from './gurus.js';

// All permitted Top N requests are subsets of the exact Top 10 at each filing.
// Keep complete books for validation / audit, but do not load price and model
// history for thousands of unselected Renaissance positions into each worker.
export function strategyMarketHoldings(histories) {
 return [...histories.values()].flatMap(filings=>filings.flatMap(f=>{
  const book=selectedBook(f,10);
  // A valid but short extract can support a smaller requested N. Keep its
  // entire market universe; the engine still enforces the requested depth.
  return book.holdings??(book.error==='insufficient_top_n_extract'?f.holdings??[]:[]);
 }));
}

// Read-only serving adapter. It never imports files, fetches SEC data, or
// silently falls back to a stale JSON artifact when the database is invalid.
export function openStrategyDatabase(file) {
 const db=new DatabaseSync(file,{readOnly:true});
 try {
  db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=3000;');
  const meta=db.prepare('SELECT * FROM warehouse_meta WHERE id=1').get();
  if(meta?.schema_version!==1||meta.state!=='complete'||!meta.manifest_hash)throw Error('strategy_database_incomplete');
  if(meta.security_version!==holdingResolutionVersion()||meta.action_version!==manager13fCorporateActionCatalogVersion)throw Error('strategy_database_version_mismatch');
  return {db,meta,close:()=>db.close()};
 }catch(e){db.close();throw e;}
}
export function storedStrategyCatalog(file,asOf) {
 const {db,meta,close}=openStrategyDatabase(file);
 try {
  const managers=db.prepare(`SELECT m.id,m.display_name name,m.entity_name entityName,m.identity_status identityStatus,
    MIN(f.public_date) firstFiling,MAX(f.public_date) lastFiling,COUNT(f.id) quarters
    FROM managers m LEFT JOIN filings f ON f.manager_id=m.id AND f.public_date<=?
    WHERE m.simulation_enabled=1 AND m.identity_status!='blocked' GROUP BY m.id ORDER BY m.display_name`).all(asOf)
    .filter(m=>enabledManager13fGurus.some(g=>g.id===m.id));
  const freshnessRow=db.prepare("SELECT content FROM source_documents WHERE kind='market_refresh_summary' ORDER BY stored_at DESC LIMIT 1").get();
  const freshness=freshnessRow?JSON.parse(freshnessRow.content):null;
  return {version:'strategy-lab-catalog-v1',asOf,managers:managers.map(m=>({...m,avatar:`/guru-avatars/${m.id}.png`,topNLimit:10,publicProxy:m.id==='renaissance-technologies'})),topNLimit:10,
   etfs:db.prepare(`SELECT e.symbol ticker,1 available,e.first_date first,e.last_date last,s.source_label source,s.return_basis returnBasis
     FROM etf_catalog e JOIN price_series s ON s.id=e.series_id ORDER BY e.symbol`).all().map(e=>({...e,available:true})),
   storage:{schemaVersion:1,generation:meta.manifest_hash,cutoff:meta.cutoff,freshness,issues:db.prepare('SELECT * FROM coverage_summary').all()}};
 }finally{close();}
}
export function loadStoredStrategyData(file,rules,{comparisonPrices:compare,actionFor,extraSymbols=[]}) {
 const {db,meta,close}=openStrategyDatabase(file);
 try {
  if(rules.end>meta.cutoff)throw Error('strategy_database_cutoff_exceeded');
  const histories=new Map(),symbols=new Set(['SPY',...extraSymbols]);
  for(const id of rules.managers) {
   const manager=db.prepare('SELECT * FROM managers WHERE id=?').get(id);
   if(!manager)throw Error('strategy_database_unknown_manager');
   const filings=db.prepare('SELECT * FROM filings WHERE manager_id=? AND public_date<=? ORDER BY public_date,accession').all(id,rules.end);
   histories.set(id,filings.map(f=>{
    const rows=db.prepare(`SELECT h.*,r.ticker,r.price_symbol,r.status resolution_status,r.resolution_source
     FROM filing_holdings h JOIN holding_resolutions r ON r.filing_id=h.filing_id AND r.ordinal=h.ordinal
     WHERE h.filing_id=? ORDER BY h.ordinal`).all(f.id);
    const holdings=rows.map(h=>({cusip:h.cusip,issuer:h.issuer,title:h.security_title,shareType:h.amount_type,putCall:h.put_call,
     value:h.value_usd,shares:h.reported_shares,ticker:h.ticker,reportedTicker:h.reported_ticker,priceSymbol:h.price_symbol,
     guruId:id,reportDate:f.report_date,accessionNumber:f.accession,identityResolved:h.resolution_status==='resolved',identitySource:h.resolution_source,
     claimType:h.claim_type}));
    return {reportDate:f.report_date,publicDate:f.public_date,accession:f.accession,sourceUrl:f.source_url,
     sourceFailure:manager.identity_status==='blocked'?'manager_identity_mismatch':f.classification_status==='unverified'||rows.some(h=>h.claim_type==='unknown')?'filing_classification_unverified':null,
     amendmentUnreviewed:/\/A$/i.test(f.form),missingOriginal:f.book_scope==='missing_original',
     complete:f.book_scope==='original_common_book',holdings:holdings.filter(h=>h.claimType==='common')};
   }));
  }
  const all=strategyMarketHoldings(histories);
  for(const h of all){if(h.ticker)symbols.add(h.ticker);if(h.priceSymbol)symbols.add(h.priceSymbol);}
  for(const r of db.prepare('SELECT DISTINCT successor_ticker FROM corporate_actions WHERE successor_ticker IS NOT NULL').all())symbols.add(r.successor_ticker);
  const start=new Date(Date.parse(rules.start)-400*86400000).toISOString().slice(0,10),priceMaps=new Map(),provenance={};
  const raw=db.prepare(`SELECT p.date,p.adjusted_close value,s.source_label source FROM price_observations p JOIN price_series s ON s.id=p.series_id
    WHERE s.symbol=? AND s.storage_kind='raw_price_points' AND p.date>=? AND p.date<=? ORDER BY p.date`);
  for(const symbol of symbols) {
   const rows=raw.all(symbol,start,rules.end);priceMaps.set(symbol,new Map(rows.filter(r=>r.value>0).map(r=>[r.date,r.value])));
   provenance[symbol]={rows:rows.length,hash:signature(rows),sources:[...new Set(rows.map(r=>r.source))]};
  }
  const dates=raw.all('SPY',start,rules.end).map(r=>r.date),etfProvenance={};
  for(const e of db.prepare('SELECT * FROM etf_catalog').all()) {
   const rows=db.prepare('SELECT date,adjusted_close FROM price_observations WHERE series_id=? AND date<=? ORDER BY date').all(e.series_id,rules.end);
   priceMaps.set(e.symbol,new Map(rows.map(r=>[r.date,r.adjusted_close])));
   etfProvenance[e.symbol]={first:e.first_date,last:e.last_date,hash:e.points_hash,returnBasis:'total_return_adjusted_close'};
  }
  const valuations=new Map(),comparisonPrices=new Map();
  if(rules.valuationEnabled)for(const ticker of strategyModelTickers([...all.map(h=>h.ticker).filter(Boolean),...extraSymbols])) {
   const version=db.prepare('SELECT model_version FROM valuation_nodes WHERE ticker=? AND as_of_date<=? ORDER BY as_of_date DESC,model_version DESC LIMIT 1').get(ticker,rules.end)?.model_version;
   valuations.set(ticker,version?db.prepare(`SELECT as_of_date date,model_version version,currency,fair_value fairValue,
     json_extract(input_json,'$.sourceRecord.sourceTicker') sourceTicker
     FROM valuation_nodes WHERE ticker=? AND model_version=? AND as_of_date<=? AND quality_status='lineage_valid' ORDER BY as_of_date`).all(ticker,version,rules.end):[]);
   const snaps=db.prepare(`SELECT p.date,p.close,s.source_label source,s.quote_currency currency FROM price_observations p JOIN price_series s ON s.id=p.series_id
     WHERE s.symbol=? AND s.storage_kind='valuation_snapshot' AND p.date<=? ORDER BY p.date`).all(ticker,rules.end);
   const daily=db.prepare(`SELECT p.date,p.close,s.source_label source FROM price_observations p JOIN price_series s ON s.id=p.series_id
     WHERE s.symbol=? AND s.storage_kind='raw_price_points' AND p.date>=? AND p.date<=? ORDER BY p.date`).all(ticker,start,rules.end);
   const currencies=new Set(snaps.map(p=>p.currency));
   comparisonPrices.set(ticker,compare({currency:currencies.size===1?[...currencies][0]:null,priceHistory:snaps},daily,rules.end));
  }
  const data={histories,dates,priceMaps,valuations,comparisonPrices,actionFor,sources:{adapter:'strategy-structured-sqlite-v1',generation:meta.manifest_hash,
   securityMaster:meta.security_version,corporateActions:meta.action_version,cutoff:meta.cutoff,prices:provenance,etfs:etfProvenance,
   classificationPolicy:'original_verified_common_only; legacy extracts retained as unverified evidence'}};
  return rules.valuationEnabled?linkedStrategyComparisonPrices(process.env.STRATEGY_COMPOSITION_PRICE_DB_PATH,data,rules.end):data;
 }finally{close();}
}
