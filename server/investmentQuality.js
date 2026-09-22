import { finite, isoDate } from './investmentMath.js';
import { observationAliases } from './publicObservationSource.js';

// Annual observations, not monthly carry-forwards from a ranked factor panel.
// All user thresholds are applied transparently in the screen, not to models.
export function opportunityQuality(source, asOf) {
  isoDate(asOf);
  const result = new Map();
  const db=source.publicFactsDb??source.db;
  if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='investment_quality_annual'").get()) return result;
  const rows = db.prepare(`WITH eligible AS (
    SELECT *, ROW_NUMBER() OVER(
      PARTITION BY ticker,report_period
      ORDER BY available_at,source_hash
    ) publication_n
    FROM investment_quality_annual
    WHERE available_at<=? AND report_period<=? AND dimension='ART'
  ), visible AS (
    SELECT *, ROW_NUMBER() OVER(
      PARTITION BY ticker ORDER BY fiscal_year DESC,report_period DESC
    ) n
    FROM eligible WHERE publication_n=1
  )
  SELECT * FROM visible WHERE n<=10 ORDER BY ticker,fiscal_year DESC,report_period DESC`).all(asOf,asOf);
  for (const r of rows) {
    if (!result.has(r.ticker)) result.set(r.ticker, {source:'Jansen / Sharadar SF1',version:'annual-quality-v1',asOf,years:[],status:'available'});
    const q=result.get(r.ticker);
    q.years.push({year:r.fiscal_year,periodEnd:r.report_period,availableAt:r.available_at,
      roic:finite(r.roic)&&r.invested_capital_avg>0?r.roic:null,
      operatingMargin:finite(r.operating_margin)?r.operating_margin:null,
      fcfMargin:finite(r.fcf_margin)?r.fcf_margin:null,
      cashConversion:finite(r.cash_conversion)?r.cash_conversion:null,
      issues:JSON.parse(r.issues_json),sourceTicker:r.source_ticker,sourceHash:r.source_hash,dimension:r.dimension});
  }
  for (const q of result.values()) {
    q.latestPeriodEnd=q.years[0].periodEnd;
    // Year-end disclosures can lag by months, but stale annual data is not a
    // current quality signal. No substitution of an older, healthier window.
    if ((Date.parse(asOf)-Date.parse(q.latestPeriodEnd))/86400000>550) q.status='stale';
  }
  for(const [ticker,canonical] of observationAliases(source))if(result.has(canonical))result.set(ticker,result.get(canonical));
  return result;
}
