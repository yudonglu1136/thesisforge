import { isoDate } from './investmentMath.js';
import { readFileSync } from 'node:fs';
import { fundamentalCompanyIndex } from './fundamentalResearch.js';
import { factGeneration } from './factRepository.js';
import { publicAnalysisArtifacts } from './publicAnalysisArtifact.js';

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

function resolveSnapshotNames(source, cache) {
  if (cache.snapshotNames) return cache.snapshotNames;
  const map = new Map();
  try {
    const rows = source.db.prepare(
      "SELECT ticker, json_extract(payload_json, '$.name') AS name FROM valuation_ticker_snapshots",
    ).all();
    for (const row of rows) {
      if (row?.ticker && row?.name) map.set(row.ticker, row.name);
    }
  } catch {
    // Fallback gracefully if snapshot table is empty in minimal fixtures.
  }
  cache.snapshotNames = map;
  return map;
}

function rankAndSliceDirectory(entries, search, limit) {
  let matched;
  if (!search) {
    matched = entries.slice(0, limit).map(item => item.publicRow);
  } else {
    const words = search.split(/\s+/).filter(Boolean);
    const hits = [];
    for (const item of entries) {
      if (words.every(w => item.haystack.includes(w))) {
        const score = item.tickerLower === search
          ? 0
          : item.tickerLower.startsWith(search)
            ? 1
            : item.nameLower.startsWith(search)
              ? 2
              : 3;
        hits.push({ score, ticker: item.publicRow.ticker, publicRow: item.publicRow });
      }
    }
    hits.sort((a, b) => a.score - b.score || a.ticker.localeCompare(b.ticker));
    matched = hits.slice(0, limit).map(h => h.publicRow);
  }
  return matched;
}

async function loadFullDirectoryForCutoff(source, cache, asOf) {
  let currentFactGen = 'none';
  try {
    currentFactGen = (await factGeneration()) ?? 'none';
  } catch {
    currentFactGen = 'none';
  }
  const dirKey = `${asOf}|${currentFactGen}`;
  if (cache.fullByAsOf.has(dirKey)) return cache.fullByAsOf.get(dirKey);
  if (cache.inFlight.has(dirKey)) return cache.inFlight.get(dirKey);

  const promise = (async () => {
    const models = source.db.prepare(`
        SELECT ticker, MAX(as_of_date) availableAt
        FROM valuation_pit_model_runs
        WHERE as_of_date <= ? AND financial_available_at <= as_of_date
          AND (guidance_max_observed_at IS NULL OR guidance_max_observed_at <= as_of_date)
        GROUP BY ticker ORDER BY ticker
    `).all(asOf);
    const snapshotNames = resolveSnapshotNames(source, cache);

    let facts = null;
    try {
      const precomputed = publicAnalysisArtifacts.get('fundamentals', { asOf }, { clone: false });
      if (precomputed?.exact && Array.isArray(precomputed.value?.companies)) {
        facts = {
          catalog_generation: precomputed.value.catalog_generation ?? currentFactGen,
          companies: precomputed.value.companies,
        };
      }
    } catch {
      facts = null;
    }
    if (!facts) {
      facts = await fundamentalCompanyIndex(asOf, { search: '', limit: 20000 });
    }

    const modelByTicker = new Map(models.map(row => [row.ticker, row]));
    const rawRows = (facts.companies ?? []).map(row => {
      const model = modelByTicker.get(row.ticker);
      modelByTicker.delete(row.ticker);
      return {
        ticker: row.ticker,
        name: row.name ?? row.ticker,
        availableAt: model?.availableAt ?? row.available_at,
        financialAvailableAt: row.available_at,
        periodEnd: row.period_end,
        currency: row.currency ?? null,
        coverage: model ? 'stored_model' : 'fact_os_only',
      };
    });
    for (const row of modelByTicker.values()) {
      const name = issuerNames.get(row.ticker) || snapshotNames.get(row.ticker) || row.ticker;
      rawRows.push({ ...row, name, coverage: 'stored_model' });
    }
    rawRows.sort((a, b) => a.ticker.localeCompare(b.ticker));
    const entries = rawRows.map(publicRow => {
      const tickerLower = String(publicRow.ticker).toLowerCase();
      const nameLower = String(publicRow.name ?? '').toLowerCase();
      return {
        tickerLower,
        nameLower,
        haystack: `${tickerLower} ${nameLower}`,
        publicRow,
      };
    });
    const built = { entries, catalogGeneration: facts.catalog_generation };
    if (cache.fullByAsOf.size >= 8) {
      cache.fullByAsOf.delete(cache.fullByAsOf.keys().next().value);
    }
    cache.fullByAsOf.set(dirKey, built);
    return built;
  })().finally(() => {
    cache.inFlight.delete(dirKey);
  });

  cache.inFlight.set(dirKey, promise);
  return promise;
}

export async function researchCompanies(source, asOf, { search = '', limit = 120 } = {}) {
  isoDate(asOf);
  search = String(search ?? '').trim().toLowerCase().slice(0, 80);
  limit = Math.max(1, Math.min(200, Number.parseInt(limit, 10) || 120));
  const generation = source.db.prepare('PRAGMA data_version').get().data_version;
  const totalChanges = source.db.prepare('SELECT total_changes() n').get().n;
  let cache = indexes.get(source);
  if (!cache || cache.generation !== generation || cache.changes !== totalChanges) {
    cache = {
      generation,
      changes: totalChanges,
      snapshotNames: null,
      dates: new Map(),
      fullByAsOf: new Map(),
      inFlight: new Map(),
    };
    indexes.set(source, cache);
  }

  // Custom test fixtures inject `source.fundamentalCompanyIndex`; preserve direct
  // per-query delegation when present, while production uses the O(1) full-cutoff index.
  if (typeof source.fundamentalCompanyIndex === 'function') {
    const requestKey = `${asOf}|${search}|${limit}`;
    if (cache.dates.has(requestKey)) return structuredClone(cache.dates.get(requestKey));
    const models = source.db.prepare(`
        SELECT ticker, MAX(as_of_date) availableAt
        FROM valuation_pit_model_runs
        WHERE as_of_date <= ? AND financial_available_at <= as_of_date
          AND (guidance_max_observed_at IS NULL OR guidance_max_observed_at <= as_of_date)
        GROUP BY ticker ORDER BY ticker
    `).all(asOf);
    const snapshotNames = resolveSnapshotNames(source, cache);
    const facts = await source.fundamentalCompanyIndex(asOf, { search, limit });
    const modelByTicker = new Map(models.map(row => [row.ticker, row]));
    const companies = (facts.companies ?? []).map(row => {
      const model = modelByTicker.get(row.ticker);
      modelByTicker.delete(row.ticker);
      return {
        ticker: row.ticker,
        name: row.name ?? row.ticker,
        availableAt: model?.availableAt ?? row.available_at,
        financialAvailableAt: row.available_at,
        periodEnd: row.period_end,
        currency: row.currency ?? null,
        coverage: model ? 'stored_model' : 'fact_os_only',
      };
    });
    for (const row of modelByTicker.values()) {
      const name = issuerNames.get(row.ticker) || snapshotNames.get(row.ticker) || row.ticker;
      if (!search || `${row.ticker} ${name}`.toLowerCase().includes(search)) {
        companies.push({ ...row, name, coverage: 'stored_model' });
      }
    }
    const rank = row => (row.ticker.toLowerCase() === search
      ? 0
      : row.ticker.toLowerCase().startsWith(search)
        ? 1
        : row.name.toLowerCase().startsWith(search)
          ? 2
          : 3);
    companies.sort((a, b) => rank(a) - rank(b) || a.ticker.localeCompare(b.ticker));
    companies.splice(limit);
    const result = {
      asOf,
      companies,
      catalogGeneration: facts.catalog_generation,
      coverage: {
        factCompanies: companies.filter(row => row.coverage === 'fact_os_only').length,
        modeledCompanies: companies.filter(row => row.coverage === 'stored_model').length,
      },
      identityPolicy:
        'Fact OS companies remain searchable without a valuation model. Model and financial dates respect the research cutoff; full research validation occurs when opened.',
    };
    if (cache.dates.size >= 32) cache.dates.delete(cache.dates.keys().next().value);
    cache.dates.set(requestKey, result);
    return structuredClone(result);
  }

  const directory = await loadFullDirectoryForCutoff(source, cache, asOf);
  const companies = rankAndSliceDirectory(directory.entries, search, limit);
  return structuredClone({
    asOf,
    companies,
    catalogGeneration: directory.catalogGeneration,
    coverage: {
      factCompanies: companies.filter(row => row.coverage === 'fact_os_only').length,
      modeledCompanies: companies.filter(row => row.coverage === 'stored_model').length,
    },
    identityPolicy:
      'Fact OS companies remain searchable without a valuation model. Model and financial dates respect the research cutoff; full research validation occurs when opened.',
  });
}
