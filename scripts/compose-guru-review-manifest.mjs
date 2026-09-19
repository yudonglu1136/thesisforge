import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createGuruValuationUniverse } from '../server/guruValuationUniverse.js';

const sha = value => crypto.createHash('sha256').update(value).digest('hex');

// Combine exact already-reviewed company records; composition grants no new
// approval and cannot convert a research queue into a historical model license.
export function composeReviewManifest(recipe) {
  if (recipe?.schemaVersion !== 1 || !Array.isArray(recipe.parts) || !recipe.parts.length ||
      !/^\d{4}-\d{2}-\d{2}$/.test(recipe.sourceCutoff || '') ||
      !/^\d{4}-\d{2}-\d{2}$/.test(recipe.asOf || '') || recipe.sourceCutoff > recipe.asOf) {
    throw new Error('Explicit dated composition recipe required');
  }
  const companies = [], provenance = [], selected = new Set();
  for (const part of recipe.parts) {
    if (!Array.isArray(part.tickers) || !part.tickers.length || new Set(part.tickers).size !== part.tickers.length) {
      throw new Error('Each part requires an exact nonempty duplicate-free scope');
    }
    const bytes = fs.readFileSync(part.path);
    if (!/^[a-f0-9]{64}$/.test(part.sha256 || '') || sha(bytes) !== part.sha256) {
      throw new Error('Reviewed source manifest hash mismatch');
    }
    const manifest = JSON.parse(bytes);
    if (!Array.isArray(manifest.companies) || manifest.asOf > recipe.asOf) {
      throw new Error('Invalid or future source manifest');
    }
    for (const ticker of part.tickers) {
      const matches = manifest.companies.filter(row => row.ticker === ticker);
      if (matches.length !== 1 || selected.has(ticker)) throw new Error('Duplicate or absent exact ticker');
      const company = matches[0];
      if (company.reviewStatus !== 'reviewed' || company.releaseNeeds?.length) {
        throw new Error(`${ticker}: research-only issuer cannot be promoted by composition`);
      }
      companies.push(structuredClone(company));
      selected.add(ticker);
    }
    provenance.push({ path: part.path, sha256: part.sha256, sourceAsOf: manifest.asOf,
      sourceReviewScope: manifest.reviewScope || manifest.rootReviewDecision || manifest.status || null,
      tickers: [...part.tickers].sort() });
  }
  const result = { schemaVersion: 1, asOf: recipe.asOf, sourceCutoff: recipe.sourceCutoff,
    status: 'composed_reviewed_inputs_full_additive_release_pending', releaseAuthorized: false,
    policy: 'Exact company records copied from hash-bound reviewed manifests. No new issuer, source, model, historical-node, or deployment approval is created. Every normal full release gate remains mandatory.',
    sourceManifests: provenance, companies: companies.sort((a, b) => a.ticker.localeCompare(b.ticker)) };
  createGuruValuationUniverse(result);
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const [recipePath, outputPath] = process.argv.slice(2);
  if (!recipePath || !outputPath) throw new Error('Usage: node scripts/compose-guru-review-manifest.mjs <recipe.json> <NEW output.json>');
  const result = composeReviewManifest(JSON.parse(fs.readFileSync(recipePath)));
  fs.writeFileSync(outputPath, JSON.stringify(result, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ status: result.status, tickers: result.companies.map(row => row.ticker),
    releaseAuthorized: false, sha256: sha(fs.readFileSync(outputPath)) }));
}
