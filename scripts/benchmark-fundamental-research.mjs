import { performance } from 'node:perf_hooks';
import { buildFundamentalCompany, buildFundamentalDiscovery } from '../server/fundamentalResearch.js';

const asOf = process.argv[2] ?? '2026-09-21';
const started = performance.now();
const slowing = await buildFundamentalDiscovery(asOf, { lens: 'slowing_growth_margin_up' });
const coldList = performance.now();
await buildFundamentalDiscovery(asOf, { lens: 'growth_profit_sync' });
const warmLens = performance.now();
const uberSearch = await buildFundamentalDiscovery(asOf, { search: 'UBER' });
const warmSearch = performance.now();
const detail = await buildFundamentalCompany({}, 'UBER', asOf, { lens: 'slowing_growth_margin_up' });
const detailed = performance.now();

console.log(JSON.stringify({
  version: 'fundamental-benchmark-v1', asOf,
  timingsMs: {
    coldList: Math.round(coldList - started),
    warmLens: Math.round(warmLens - coldList),
    warmSearch: Math.round(warmSearch - warmLens),
    uberDetail: Math.round(detailed - warmSearch),
  },
  coverage: slowing.coverage,
  signalCounts: slowing.counts,
  uber: {
    discovery: uberSearch.rows[0] ?? null,
    judgment: detail.judgment,
    importantChanges: detail.importantChanges.length,
    quarterlyPeriods: detail.quarterly.length,
    trendPoints: detail.trend.length,
    peerContext: detail.peerContext,
    valuationStatus: detail.valuation?.valuationStatus ?? 'not_modeled',
    researchGaps: detail.researchGaps,
    observedDividendActions: detail.dividends.length,
    sectionIds: detail.sections.map(section => section.id),
  },
}, null, 2));
