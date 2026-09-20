import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {XMLParser} from 'fast-xml-parser';
import {gurus} from './gurus.js';
import {InvestmentSource,assertLineage} from './investmentSource.js';
import {originalStrategyHistory,strategyFilingArtifact} from './strategyFilings.js';
import {strategyEtfs} from './strategyLabSource.js';
import {signature} from './investmentMath.js';
import {is13fCommonLongHolding,is13fOptionHolding,isClearlyNonCommonEquityTitle} from './thirteenF.js';
import {tickerResolutionForHolding,priceSymbolResolutionForHolding,holdingResolutionVersion} from './cusipOverrides.js';
import {manager13fCorporateActions,manager13fCorporateActionCatalogVersion} from './corporateActions.js';
import {valuationComparisonPriceContract,comparisonPricesEqual} from './valuationComparisonPrice.js';

export const STRATEGY_DATABASE_VERSION=1;
const nullable=v=>v??null;
const positive=n=>Number.isFinite(n)&&n>0;
const key=(...parts)=>signature(parts);
const sha256=value=>crypto.createHash('sha256').update(value).digest('hex');
const unit=k=>k==='shares_m'?'million_shares':k.endsWith('_m')?'currency_millions':k.endsWith('_pct')?'percent':'source_unit';
export function claimClassification(h) {
 if(is13fOptionHolding(h))return {type:'option',status:'verified',reason:'explicit_put_call'};
 if(h.shareType==='PRN'||isClearlyNonCommonEquityTitle(h))return {type:'non_common',status:'verified',reason:'explicit_non_common_claim'};
 if(h.shareType==='SH'&&h.title&&is13fCommonLongHolding(h))return {type:'common',status:'verified',reason:'explicit_common_share_class'};
 return {type:'unknown',status:'unverified',reason:'missing_security_class_fields'};
}
// A repeated immutable key is allowed only if the entire typed row agrees.
export function immutableInsert(db,table,row) {
 if(!/^[a-z_]+$/.test(table))throw Error('invalid_table');
 const fields=Object.keys(row),values=fields.map(k=>nullable(row[k]));
 const result=db.prepare(`INSERT OR IGNORE INTO ${table} (${fields.join(',')}) VALUES (${fields.map(()=>'?').join(',')})`).run(...values);
 if(result.changes)return;
 const match=db.prepare(`SELECT 1 FROM ${table} WHERE ${fields.map(k=>`${k} IS ?`).join(' AND ')} LIMIT 1`).get(...values);
 if(!match)throw Error('immutable_record_conflict:'+table);
}
export function parseDocumentRows(xml) {
 const parsed=new XMLParser({ignoreAttributes:false,parseTagValue:false,removeNSPrefix:true,trimValues:true}).parse(xml);
 const raw=parsed.informationTable?.infoTable;
 if(!raw)throw Error('missing_information_table');
 return (Array.isArray(raw)?raw:[raw]).map(r=>({cusip:String(r.cusip??'').toUpperCase(),issuer:String(r.nameOfIssuer??''),title:String(r.titleOfClass??''),
  shareType:String(r.shrsOrPrnAmt?.sshPrnamtType??'').toUpperCase(),putCall:String(r.putCall??'').toUpperCase(),
  shares:Number(r.shrsOrPrnAmt?.sshPrnamt),value:Number(r.value)}));
}

/** Build a NEW immutable local warehouse. The source DB is read-only and held
 * in one SQLite read transaction. Publication is owned by the CLI after checks.
 * No source downloads, valuation recalculation, or cache repair happens here. */
export function importStrategyDatabase({sourceFile,targetFile,cutoff,etfFile,filingFile,
 manifestFile=new URL('./config/guru-sec-cusip-manifest.json',import.meta.url),
 securityFile=new URL('./config/guru-security-master.json',import.meta.url),
 evidenceFiles=[],catalog=gurus,generatedAt=new Date().toISOString(),progress=()=>{}}) {
 if(!/^\d{4}-\d{2}-\d{2}$/.test(cutoff))throw Error('invalid_cutoff');
 if(fs.existsSync(targetFile)||path.resolve(sourceFile)===path.resolve(targetFile))throw Error('target_must_be_new');
 const source=new InvestmentSource(sourceFile),db=new DatabaseSync(targetFile);
 fs.chmodSync(targetFile,0o600);
 const put=(table,row)=>immutableInsert(db,table,row);
 const has=t=>!!source.db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(t);
 const each=(table,fn)=>{if(has(table))for(const r of source.db.prepare(`SELECT * FROM ${table}`).iterate())fn(r);};
 const sourceCounts={};
 const doc=(kind,locator,content)=>{
  const hash=sha256(content),id=key(kind,locator,hash);
  put('source_documents',{id,kind,locator,sha256:hash,content,stored_at:generatedAt});return id;
 };
 const issue=(category,severity,scope,reason,evidence={})=>put('coverage_issues',{id:key(category,scope,reason),category,severity,
  manager_id:null,filing_id:null,ticker:null,date:null,...scope,reason,evidence_json:JSON.stringify(evidence)});
 try {
  source.db.exec('BEGIN');
  for(const t of ['guru_exposure_snapshots','guru_backtests','price_points','valuation_pit_financials','valuation_pit_guidance','valuation_pit_model_runs','valuation_pit_price_observations','valuation_ticker_snapshots'])if(has(t))sourceCounts[t]=source.db.prepare(`SELECT count(*) n FROM ${t}`).get().n;
  db.exec(fs.readFileSync(new URL('./strategyDatabaseSchema.sql',import.meta.url),'utf8'));
  db.exec('BEGIN IMMEDIATE');
  put('warehouse_meta',{id:1,schema_version:1,cutoff,generated_at:generatedAt,state:'building',security_version:holdingResolutionVersion(),
   action_version:manager13fCorporateActionCatalogVersion,manifest_hash:null,source_counts_json:JSON.stringify(sourceCounts)});
  const configId=doc('manager_catalog','server/gurus.js',JSON.stringify(catalog));
  const managerList=catalog.filter(g=>g.type==='manager13f'),managerIds=new Set(managerList.map(g=>g.id));
  for(const g of managerList) {
   const blocked=g.id==='chamath-palihapitiya'&&g.cik==='0001607841';
   const evidenceUrl=blocked?'https://www.sec.gov/Archives/edgar/data/1607841/000095012325008327/xslForm13F_X02/primary_doc.xml':null;
   put('managers',{id:g.id,display_name:g.name,entity_name:g.entityName,simulation_enabled:g.disableSimulation?0:1,
    identity_status:blocked?'blocked':'configured_unreviewed',identity_reason:blocked?'sc_us_is_not_verified_as_social_capital':null,evidence_url:evidenceUrl,source_id:configId});
   for(const [i,cik] of [...new Set([g.cik,...g.alternateCiks??[]].filter(Boolean))].entries())put('manager_entities',{manager_id:g.id,cik,entity_role:i?'alternate':'primary',review_status:blocked?'blocked':'configured_unreviewed'});
   if(blocked)issue('manager_identity','critical',{manager_id:g.id},'filer_manager_mismatch',{cik:g.cik,evidenceUrl});
  }
  const manifest=JSON.parse(fs.readFileSync(manifestFile,'utf8')),manifestId=doc('sec_manifest','guru-sec-cusip-manifest',JSON.stringify(manifest));
  for(const f of manifest.filings??[])if(managerIds.has(f.managerId))put('filing_manifest',{manager_id:f.managerId,accession:f.accessionNumber,cik:f.cik,form:f.form,
   report_date:f.reportDate,public_date:f.filingDate,document_url:f.documentUrl,document_hash:f.documentSha256,
   selected_count:f.selectedCommonLongCusipCount,reported_count:f.reportedCusipCount,source_id:manifestId});
  const master=JSON.parse(fs.readFileSync(securityFile,'utf8')),masterId=doc('security_master','guru-security-master',JSON.stringify(master));
  for(const [status,collection] of [['resolved',master.securities],['unresolved',master.unresolved],['ambiguous',master.ambiguous]]) {
   for(const [k,v] of Array.isArray(collection)?collection.map(r=>[r.cusip,r]):Object.entries(collection??{})) {
    const r=typeof v==='object'&&v!==null?v:{value:v};
    const cusip=r.cusip??k;if(!cusip)continue;
    put('security_identifiers',{cusip,ticker:r.ticker??r.symbol,status,source_id:masterId,evidence_json:JSON.stringify(r)});
   }
  }
  const actionId=doc('corporate_actions','server/corporateActions.js',JSON.stringify(manager13fCorporateActions));
  for(const a of manager13fCorporateActions)put('corporate_actions',{id:a.id,cusip:a.cusip,ticker:a.ticker,action_type:a.actionType,effective_date:a.effectiveDate,
   cash_per_share:a.consideration?.totalCashEntitlementPerShare,currency:a.consideration?.currency,successor_ticker:a.consideration?.successorTicker,
   conversion_ratio:a.consideration?.successorSharesPerShare,evidence_json:JSON.stringify(a),source_id:actionId});
  const originals=strategyFilingArtifact(filingFile);
  if(filingFile)doc('filing_artifact','original-filings',fs.readFileSync(filingFile,'utf8'));
  const rawDocuments=[];
  for(const r of originals.values())for(const d of r.documents)rawDocuments.push({...d,file:path.join(path.dirname(filingFile),d.accessionNumber+'.xml'),scale:r.scale});
  for(const r of originals.values())for(const d of r.coverDocuments??[]) {
   const file=path.join(path.dirname(filingFile),d.accessionNumber+'.cover.xml');
   if(fs.existsSync(file))rawDocuments.push({...d,file,kind:'sec_cover'});
  }
  rawDocuments.push(...evidenceFiles);
  for(const d of rawDocuments) {
   if(!fs.existsSync(d.file)){issue('source_document','high',{},'missing_document:'+d.url);continue;}
   const content=fs.readFileSync(d.file,'utf8');
   if(d.hash&&sha256(content)!==d.hash)throw Error('source_document_hash_mismatch');
   const id=doc(d.kind??'sec_information_table',d.url,content);
   if(d.kind==='sec_cover')continue;
   for(const [i,r] of parseDocumentRows(content).entries())put('document_holdings',{document_id:id,ordinal:i,cusip:r.cusip,issuer:r.issuer,
    security_title:r.title,amount_type:r.shareType,put_call:r.putCall,amount:r.shares,reported_value:r.value,value_multiplier:d.scale,claim_type:claimClassification(r).type});
  }
  progress('filings');
  for(const g of managerList) {
   const acceptance=new Map();
   if(has('guru_backtests'))for(const r of source.db.prepare('SELECT payload_json FROM guru_backtests WHERE guru_id=? ORDER BY years DESC').all(g.id))for(const f of JSON.parse(r.payload_json).rebalances??[])
    if(f.filing?.accessionNumber&&f.publicDate)acceptance.set(f.filing.accessionNumber,f.publicDate);
   for(const f of originalStrategyHistory(source,g.id,cutoff,originals)) {
    const accession=f.accessionNumber||'missing-'+f.reportDate,id=key(g.id,accession),publicDate=[f.filingDate,acceptance.get(accession)].filter(Boolean).sort().at(-1);
    const recovered=originals.get(g.id+':'+accession);
    // Original, independently reconciled books take precedence over a UI extract.
    const useRecovered=recovered&&recovered.reportDate===f.reportDate&&recovered.publicDate===publicDate;
    const holdings=useRecovered?recovered.holdings:f.topHoldings??[];
    const scope=useRecovered?'original_common_book':f.missingOriginal?'missing_original':'legacy_top10';
    const sourceId=doc('filing_input',g.id+':'+accession,JSON.stringify(useRecovered?recovered:f));
    put('filings',{id,manager_id:g.id,accession,report_date:f.reportDate,public_date:publicDate,form:f.filing?.form??'13F-HR',cik:f.filing?.cik??g.cik,
     source_url:f.filing?.secUrl,book_scope:scope,classification_status:useRecovered?'verified':f.missingOriginal?'blocked':'unverified',
     expected_position_count:useRecovered?holdings.length:f.positionCount,row_count:holdings.length,
     selected_value_usd:holdings.reduce((s,h)=>s+(Number.isFinite(h.value)?h.value:0),0),common_value_usd:useRecovered?recovered.commonLongValue:null,source_id:sourceId,payload_hash:signature(holdings)});
    if(scope!=='original_common_book')issue('filing_book','high',{manager_id:g.id,filing_id:id,date:f.reportDate},scope==='missing_original'?'original_filing_missing':'legacy_classification_unverified');
    for(const [i,h] of holdings.entries()) {
     const cl=claimClassification(h);
     put('filing_holdings',{filing_id:id,ordinal:i,cusip:h.cusip??'',reported_id:h.id,issuer:h.issuer,security_title:h.title,amount_type:h.shareType,
      put_call:h.putCall,reported_shares:h.shares,value_usd:h.value,reported_ticker:h.ticker,claim_type:cl.type,classification_status:cl.status,classification_reason:cl.reason});
     const input={...h,guruId:g.id,reportDate:f.reportDate,accessionNumber:accession},resolution=tickerResolutionForHolding(input),price=priceSymbolResolutionForHolding(input);
     const resolved=resolution.status==='resolved'&&resolution.source!=='curated_issuer_override';
     put('holding_resolutions',{filing_id:id,ordinal:i,ticker:resolved?resolution.ticker:h.ticker,price_symbol:resolved?price.symbol:null,
      status:resolved?'resolved':'unresolved',resolution_source:resolution.source,resolution_version:holdingResolutionVersion()});
     if(!resolved)issue('security_identity','high',{manager_id:g.id,filing_id:id,ticker:h.ticker??null,date:f.reportDate},'unresolved_claim:'+h.cusip,{source:resolution.source});
    }
   }
  }
  const snapshots=new Map();each('valuation_ticker_snapshots',r=>snapshots.set(r.ticker,JSON.parse(r.payload_json)));
  const marketDoc=doc('runtime_table','price_points',JSON.stringify({rowCount:sourceCounts.price_points,cutoff,policy:'original rows, no price repairs'}));
  const seriesCache=new Map();
  const series=(symbol,label,storage,currency,sourceId=marketDoc,returnBasis='provider_adjusted_close')=>{
   label=label??'unknown';const id=key(symbol,label,storage);if(seriesCache.has(id))return id;
   const c=valuationComparisonPriceContract(label);
   put('price_series',{id,symbol,provider:c?.provider,source_label:label,storage_kind:storage,close_basis:c?.basis,return_basis:returnBasis,
    quote_currency:currency,status:c?'recognized_source':'unverified_source',source_id:sourceId});seriesCache.set(id,true);return id;
  };
  const priceInsert=db.prepare('INSERT INTO price_observations VALUES (?,?,?,?,?,?,?,?,?,?)');
  let n=0;
  each('price_points',r=>{
   const id=series(r.symbol,r.source,'raw_price_points',snapshots.get(r.symbol)?.currency);
   priceInsert.run(id,r.date,nullable(r.open),nullable(r.high),nullable(r.low),nullable(r.close),nullable(r.adjusted_close),nullable(r.volume),nullable(r.updated_at),positive(r.close)?'valid':'invalid_close');
   if(++n%500000===0)progress('prices '+n);
  });
  for(const [ticker,s] of snapshots) {
   const documentId=doc('price_snapshot_metadata',ticker,JSON.stringify({currency:s.currency,priceSource:s.priceSource,points:s.priceHistory?.length??0}));
   for(const r of s.priceHistory??[]) {
    const label=r.source??s.priceSource;
    const id=series(ticker,typeof label==='string'?label:JSON.stringify(label),'valuation_snapshot',s.currency,documentId,null);
    put('price_observations',{series_id:id,date:r.date,open:r.open,high:r.high,low:r.low,close:r.close,adjusted_close:null,volume:r.volume,observed_at:null,quality_status:positive(r.close)?'valid':'invalid_close'});
   }
  }
  const etfs=strategyEtfs(etfFile),etfDoc=doc('etf_artifact','strategy-etfs',JSON.stringify(etfs));
  for(const [ticker,e] of Object.entries(etfs)) {
   if(!String(e.source??'').toLowerCase().includes('sharadar'))throw Error('cta_etf_source_must_be_sharadar');
   const id=series(ticker,e.sourceLabel??'sharadar_fact_os_sfp','cta_etf',e.currency,etfDoc,e.returnBasis);
   for(const r of e.points)priceInsert.run(id,r.date,null,null,null,r.close,r.adjustedClose,null,e.downloadedAt??null,'valid');
   put('etf_catalog',{symbol:ticker,inception:e.inception,first_date:e.first,last_date:e.last,series_id:id,source_url:e.url,points_hash:e.pointsSha256,downloaded_at:e.downloadedAt});
  }
  progress('financials and guidance');
  each('valuation_pit_financials',r=>{
   const id=key(r.ticker,r.fiscal_period,r.dimension),p=JSON.parse(r.payload_json);
   put('financial_records',{id,ticker:r.ticker,source_ticker:r.source_ticker,fiscal_period:r.fiscal_period,fiscal_year:r.fiscal_year,fiscal_quarter:r.fiscal_quarter,
    dimension:r.dimension,available_at:r.available_at,report_period:r.report_period,currency:r.currency,
    quality_status:r.report_period&&r.report_period<=r.available_at?'stored_pit':'date_unverified',source_record_json:JSON.stringify(p.sourceRecord??{}),raw_payload_json:r.payload_json});
   for(const [metric,value] of Object.entries(p))if(metric.endsWith('_m')||metric.endsWith('_pct'))put('financial_metrics',{record_id:id,metric,value:Number.isFinite(value)?value:null,unit:unit(metric),lineage_json:p.sources?.[metric]?JSON.stringify(p.sources[metric]):null});
  });
  each('valuation_pit_guidance',r=>put('guidance_events',{id:key(r.source_database,r.source_id),source_database:r.source_database,source_event_id:r.source_id,ticker:r.ticker,
   fiscal_period:r.fiscal_period,observed_at:r.observed_at,metric:r.metric_name,amount:r.amount,unit:r.unit,currency:r.currency,growth_yoy:r.growth_yoy,growth_qoq:r.growth_qoq,
   margin_pct:r.margin_pct,quality_status:r.quality_status,confidence:r.confidence,speaker:r.speaker,source_url:r.source_url,evidence_excerpt:r.evidence_excerpt,raw_payload_json:r.payload_json}));
  progress('valuation nodes');
  each('valuation_pit_model_runs',r=>{
   const id=key(r.ticker,r.fiscal_period,r.model_version),input=JSON.parse(r.input_json),output=JSON.parse(r.output_json);
   let valid=r.financial_available_at<=r.as_of_date&&(!r.guidance_max_observed_at||r.guidance_max_observed_at<=r.as_of_date);
   try{assertLineage(input,r.as_of_date);}catch{valid=false;}
   put('valuation_nodes',{id,ticker:r.ticker,fiscal_period:r.fiscal_period,model_version:r.model_version,as_of_date:r.as_of_date,financial_available_at:r.financial_available_at,
    guidance_available_at:r.guidance_max_observed_at,currency:input.sourceRecord?.currency,fair_value:output.fairValue,formula:input.valuationSemantics?.fairValueFormula??output.method,
    quality_status:valid?'lineage_valid':'lineage_invalid',input_json:r.input_json,output_json:r.output_json});
   for(const section of ['financial','trailingTwelveMonths'])for(const [metric,value] of Object.entries(input[section]??{}))if(value===null||typeof value==='number')
    put('valuation_metrics',{node_id:id,section,metric,value:Number.isFinite(value)?value:null,unit:unit(metric)});
   if(!valid)issue('valuation_lineage','critical',{ticker:r.ticker,date:r.as_of_date},'future_or_invalid_model_source:'+r.model_version);
  });
  each('valuation_pit_price_observations',r=>put('model_price_evidence',{ticker:r.ticker,fiscal_period:r.fiscal_period,model_version:r.model_version,
   price_symbol:r.price_symbol,price_date:r.price_date,close:r.close,quote_currency:r.quote_currency,source_label:r.source,payload_json:r.payload_json}));
  // One record per exact held ticker: absence is not inferred from a blank UI.
  for(const r of db.prepare("SELECT DISTINCT ticker FROM holding_resolutions WHERE ticker IS NOT NULL AND ticker NOT IN (SELECT ticker FROM valuation_nodes)").all())
   issue('valuation_coverage','high',{ticker:r.ticker},'no_persisted_model');
  progress('price conflict audit');
  const overlaps=db.prepare(`SELECT a.symbol,a.source_label,b.source_label other_source,p.date,p.close snapshot_close,q.close raw_close
   FROM price_series a JOIN price_observations p ON p.series_id=a.id
   JOIN price_series b ON b.symbol=a.symbol AND b.storage_kind='raw_price_points'
    AND a.provider=b.provider AND a.close_basis=b.close_basis
   JOIN price_observations q ON q.series_id=b.id AND q.date=p.date
   WHERE a.storage_kind='valuation_snapshot' AND a.provider IS NOT NULL`);
  for(const r of overlaps.iterate())if(positive(r.snapshot_close)&&positive(r.raw_close)&&!comparisonPricesEqual(r.snapshot_close,r.raw_close))
   issue('comparison_price','high',{ticker:r.symbol,date:r.date},'same_series_price_conflict:'+r.source_label+':'+r.other_source,{snapshot:r.snapshot_close,raw:r.raw_close});
  const counts=Object.fromEntries(db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name!='warehouse_meta' ORDER BY name").all().map(({name})=>[name,db.prepare(`SELECT count(*) n FROM ${name}`).get().n]));
  if(counts.financial_records!==(sourceCounts.valuation_pit_financials??0)||counts.valuation_nodes!==(sourceCounts.valuation_pit_model_runs??0)||counts.guidance_events!==(sourceCounts.valuation_pit_guidance??0))throw Error('source_count_mismatch');
  const foreignKeys=db.prepare('PRAGMA foreign_key_check').all();if(foreignKeys.length)throw Error('foreign_key_check_failed');
  // Generation identity must change when one price/metric changes, even when
  // row counts and source-document metadata remain identical. Wall-clock import
  // time is intentionally excluded; raw source dates remain part of the hash.
  const tableHashes={};
  for(const table of Object.keys(counts)) {
   const columns=db.prepare(`PRAGMA table_info(${table})`).all();
   const fields=columns.map(c=>c.name).filter(c=>table!=='source_documents'||!['content','stored_at'].includes(c));
   const order=columns.filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>c.name);
   const hash=crypto.createHash('sha256');
   for(const row of db.prepare(`SELECT ${fields.join(',')} FROM ${table} ORDER BY ${order.join(',')}`).iterate())hash.update(JSON.stringify(row)+'\n');
   tableHashes[table]=hash.digest('hex');progress('attested '+table);
  }
  const manifestHash=signature({cutoff,counts,sourceCounts,tableHashes,security:holdingResolutionVersion(),actions:manager13fCorporateActionCatalogVersion});
  db.prepare("UPDATE warehouse_meta SET state='complete',manifest_hash=? WHERE id=1").run(manifestHash);
  db.exec('COMMIT');
  if(db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok')throw Error('integrity_check_failed');
  const issues=db.prepare('SELECT * FROM coverage_summary ORDER BY severity,category').all();
  return {schemaVersion:1,cutoff,counts,sourceCounts,tableHashes,issues,manifestHash,sourceWrites:source.db.prepare('SELECT total_changes() n').get().n,integrity:'ok',foreignKeys:foreignKeys.length};
 }catch(e){try{db.exec('ROLLBACK');}catch{}throw e;}
 finally{try{source.db.exec('ROLLBACK');}catch{}source.close();db.close();}
}
