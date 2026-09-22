// Read-only acceptance probe: run with the API UID and production Fact OS paths.
// Public health alone does not prove financial data can be served.
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { buildFundamentalDiscovery, buildFundamentalCompany } from '../server/fundamentalResearch.js';

const asOf = process.argv[2] ?? new Date().toISOString().slice(0,10);
const started = performance.now();
const browse = await buildFundamentalDiscovery(asOf,{lens:'all',limit:30});
assert.equal(browse.asOf,asOf);
assert.ok(browse.coverage.factCompanies > 0 && browse.rows.length > 0);
assert.ok(browse.rows.every(row => row.available_at <= asOf));
const coldMs = performance.now()-started;
const search = await buildFundamentalDiscovery(asOf,{search:'UBER',lens:'all'});
assert.ok(search.rows.some(row=>row.ticker==='UBER'));
const detail = await buildFundamentalCompany({},'UBER',asOf);
assert.equal(detail.ticker,'UBER');
assert.ok(detail.quarterly.length > 0 && detail.sources.length > 0);
assert.ok(detail.sources.every(row=>row.availableAt <= asOf));
const page = await buildFundamentalDiscovery(asOf,{lens:'all',limit:30,offset:30});
assert.ok(!page.rows.some(row=>browse.rows.some(first=>first.ticker===row.ticker)));
const runs=[];
for(let repetition=0;repetition<3;repetition++) {
  const samples=[];
  for(let i=0;i<3;i++) await Promise.all(Array.from({length:20},async()=>{
    const t=performance.now();
    const result=await buildFundamentalDiscovery(asOf,{search:'UBER',lens:'all'});
    assert.deepEqual(result,search);
    samples.push(performance.now()-t);
  }));
  samples.sort((a,b)=>a-b);
  runs.push({samples:60,concurrency:20,p50Ms:samples[29],p95Ms:samples[56],maxMs:samples.at(-1)});
}
console.log(JSON.stringify({status:'pass',asOf,catalogGeneration:browse.catalogGeneration,
  coverage:browse.coverage,coldMs,readOnly:true,privateDataTouched:false,
  uber:{quarterlyPeriods:detail.quarterly.length,trendPoints:detail.trend.length,
    revenueGrowth:detail.company.metrics.revenueGrowth,operatingMargin:detail.company.metrics.operatingMargin},
  repeatability:runs},null,2));
