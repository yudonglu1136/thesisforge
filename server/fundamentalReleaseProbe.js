import { buildFundamentalDiscovery } from './fundamentalResearch.js';

// Run inside the authenticated, loopback-only release request's pinned context.
// This validates useful data and warms the API process, not a separate CLI cache.
export async function verifyReleasedFundamentals(asOf, build = buildFundamentalDiscovery) {
  const snapshot = await build(asOf, {lens:'all',limit:1});
  if (snapshot?.asOf !== asOf || !(snapshot.coverage?.factCompanies > 0) ||
      !snapshot.rows?.length || snapshot.rows.some(row => !row.available_at || row.available_at > asOf)) {
    throw Error('fundamental_release_read_invalid');
  }
  return {status:'ready',asOf,catalogGeneration:snapshot.catalogGeneration,
    factCompanies:snapshot.coverage.factCompanies,latestAvailableAt:snapshot.coverage.latestAvailableAt};
}
