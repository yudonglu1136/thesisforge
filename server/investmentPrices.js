import { finite, isoDate } from './investmentMath.js';
import { observationAliases } from './publicObservationSource.js';
import { marketQuotes } from './investmentMarketContext.js';

const validTicker = value => /^[A-Z][A-Z0-9.-]{0,14}$/.test(String(value ?? ''));

/**
 * Latest split-adjusted market closes published by the append-only Fact OS
 * bridge. This table is optional so older audited releases remain readable.
 */
export function investmentCurrentQuotes(source, tickers, asOf) {
  isoDate(asOf);
  const names=[...new Set(tickers.map(x=>String(x??'').toUpperCase()).filter(validTicker))];
  const canonical=marketQuotes(names,asOf);
  if(canonical)return canonical;
  const result=new Map();
  if(!names.length)return result;
  const db=source.publicFactsDb??source.db,aliases=observationAliases(source);
  const symbols=[...new Set(names.map(t=>aliases.get(t)??t))];
  const exists=db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='investment_current_quotes'").get();
  if(!exists)return result;
  const placeholders=symbols.map(()=>'?').join(',');
  const rows=db.prepare(`WITH corrections AS (
    SELECT *,ROW_NUMBER() OVER(
      PARTITION BY ticker,price_date ORDER BY imported_at DESC,source_hash DESC
    ) correction_n
    FROM investment_current_quotes
    WHERE price_date<=? AND ticker IN (${placeholders})
  ), ranked AS (
    SELECT *,ROW_NUMBER() OVER(
      PARTITION BY ticker ORDER BY price_date DESC,imported_at DESC,source_hash DESC
    ) quote_n
    FROM corrections WHERE correction_n=1
  ) SELECT ticker,price_date,close,source,source_ticker,source_generation
    FROM ranked WHERE quote_n=1 ORDER BY ticker`).all(asOf,...symbols);
  for(const row of rows)if(finite(row.close)&&row.close>0)for(const ticker of names.filter(t=>(aliases.get(t)??t)===row.ticker))result.set(ticker,{
    value:row.close,date:row.price_date,source:row.source,
    sourceTicker:row.source_ticker,sourceGeneration:row.source_generation,
    adjustment:'Sharadar SEP split-adjusted close; dividends excluded',
  });
  return result;
}

export function preferInvestmentQuote(current, stored) {
  // Canonical availability, currency and basis are authoritative. A newer
  // archived price or a missing canonical quote never enables legacy fallback.
  if(current?.canonical)return current;
  if(!current)return stored;
  if(stored?.date && stored.date>current.date)return stored;
  return {...current,currency:stored?.currency??null};
}
