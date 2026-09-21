import { isoDate } from './investmentMath.js';
import { readFileSync } from 'node:fs';
import { fundamentalCompanyIndex } from './fundamentalResearch.js';

// A search index, not a valuation payload or a certification of model quality.
// Keep full financial/transcript blobs in SQLite; return identity + dated coverage.
const indexes = new WeakMap();
const issuerNames = new Map();
for (const file of ['sp500-valuation-universe.json', 'guru-valuation-universe.json']) {
  const catalog = JSON.parse(readFileSync(new URL(`./config/${file}`, import.meta.url), 'utf8'));
  for (const company of catalog.companies ?? []) {
    if (company.ticker && company.name) issuerNames.set(company.ticker, company.name);
  }
}
export async function researchCompanies(source, asOf,{search='',limit=120}={}) {
  isoDate(asOf);
  search=String(search??'').trim().toLowerCase().slice(0,80);
  limit=Math.max(1,Math.min(200,Number.parseInt(limit,10)||120));
  const generation = source.db.prepare('PRAGMA data_version').get().data_version;
  let cache = indexes.get(source);
  if (!cache || cache.generation !== generation || cache.changes !== source.db.prepare('SELECT total_changes() n').get().n) {
    cache = {generation, changes: source.db.prepare('SELECT total_changes() n').get().n, dates: new Map()};
    indexes.set(source, cache);
  }
  const requestKey=`${asOf}|${search}|${limit}`;
  if (cache.dates.has(requestKey)) return structuredClone(cache.dates.get(requestKey));
  const models = source.db.prepare(`
      SELECT ticker, MAX(as_of_date) availableAt
      FROM valuation_pit_model_runs
      WHERE as_of_date <= ? AND financial_available_at <= as_of_date
        AND (guidance_max_observed_at IS NULL OR guidance_max_observed_at <= as_of_date)
      GROUP BY ticker ORDER BY ticker
  `).all(asOf);
  // The existing issuer catalogs cover most names. Parse snapshot metadata only
  // for the remainder, not 500+ multi-megabyte chart/transcript documents.
  const lookup = source.db.prepare("SELECT json_extract(payload_json, '$.name') name FROM valuation_ticker_snapshots WHERE ticker=?");
  const facts=await (source.fundamentalCompanyIndex?.(asOf,{search,limit})??fundamentalCompanyIndex(asOf,{search,limit}));
  const modelByTicker=new Map(models.map(row=>[row.ticker,row]));
  const companies=(facts.companies??[]).map(row=>{
    const model=modelByTicker.get(row.ticker);modelByTicker.delete(row.ticker);
    return {ticker:row.ticker,name:row.name??row.ticker,
      availableAt:model?.availableAt??row.available_at,financialAvailableAt:row.available_at,
      periodEnd:row.period_end,currency:row.currency??null,
      coverage:model?'stored_model':'fact_os_only'};
  });
  for(const row of modelByTicker.values()){
    const name=issuerNames.get(row.ticker)||lookup.get(row.ticker)?.name||row.ticker;
    if(!search||`${row.ticker} ${name}`.toLowerCase().includes(search))companies.push({...row,name,coverage:'stored_model'});
  }
  const rank=row=>row.ticker.toLowerCase()===search?0:row.ticker.toLowerCase().startsWith(search)?1:
    row.name.toLowerCase().startsWith(search)?2:3;
  companies.sort((a,b)=>rank(a)-rank(b)||a.ticker.localeCompare(b.ticker));
  companies.splice(limit);
  const result = {asOf, companies,catalogGeneration:facts.catalog_generation,
    coverage:{factCompanies:companies.filter(row=>row.coverage==='fact_os_only').length,
      modeledCompanies:companies.filter(row=>row.coverage==='stored_model').length},
    identityPolicy: 'Fact OS companies remain searchable without a valuation model. Model and financial dates respect the research cutoff; full research validation occurs when opened.'};
  if (cache.dates.size >= 3) cache.dates.delete(cache.dates.keys().next().value);
  cache.dates.set(requestKey, result);
  return structuredClone(result);
}
