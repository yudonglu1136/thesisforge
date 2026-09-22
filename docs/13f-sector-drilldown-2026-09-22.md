# Active-manager sector drill-down — 2026-09-22

## Product

Discover → 13F Insights → Active funds → click any sector. The lazy dialog
shows additions, reductions and net quantity effects, sector weight before/after,
stocks, industries and managers. Industry rows drill into their stocks; stock
rows open Research → Institutions. Search, direction filters and 20-row paging
preserve complete-population ranks and unfiltered sector totals. EN/ZH and 390px
layouts are supported. No canonical or private account data is changed.

## Method and boundaries

- `active-sector-v1`, deterministic Python over the complete comparable active
  subset, not the bounded Top 40/50 detail sample. Missing entire filings are
  excluded, not called exits. Only established new/exit positions use zero.
- Split-adjusted share changes are valued at a common current-quarter implied
  price. Use the median of same-ticker position value/share ratios; positions
  of at least USD 1m are preferred when at least three exist. Fall back to the
  split-adjusted prior price only if no current reference exists.
- Independently validate each quarter against that quarter's reference. A
  value/share discrepancy beyond max(5% expected value, USD 0.1m) is excluded
  from estimated amounts, never repaired. Missing inputs are counted separately.
  This is a conservative consistency screen, not independent quote verification.
- Real example caught in verification: DIAMANT's prior AAPL shares/value were
  inconsistent and generated an artificial approximately USD 11bn Technology
  reduction. The estimator now quarantines such records. Raw facts are retained.
- Added/reduced amounts are summed before netting, so internal rotations remain
  visible even when net change is small. They are **not actual trades, fund flows
  or a causal statement about manager intention**. USD millions are converted
  only for presentation. Price and quantity effects are distinct.
- Reported-value residual is shown only with complete amount/price coverage.
  With partial data, absent values remain unknown; weights use available reported
  values. Current industry taxonomy is applied to both quarters, not claimed as
  historical taxonomy. Active classification is a conservative manager-level
  proxy, not verification that every underlying fund is active.
- Quarter-end +45 days is a visibility proxy, not the true SEC filing date.
  History is limited to the available 12 active-scope quarters.

## Data artifact and replay

- Sidecar: `13f-insights-20260922-v12`, schema `institutional-13f-artifact-v7`.
- Generation: `4de73e2dc50afeca711248cc9f6d3fdf5243d55041ee59adb044df0f689b7e7a`.
- Database SHA-256: `01b485571912970d082e98e8740fe1fbc23ccfcde01a375db92070fdf02f1d16`.
- 366,616,576 bytes; 149 sector-quarter payloads, 2023Q3–2026Q2.
- 2026Q2 Technology: 744 securities, 2,038 managers, 75,743 comparable positions;
  72,040 priced, 2,293 source inconsistencies, 1,410 missing inputs. Partial
  amount estimates are explicitly labeled at sector and row level.
- Writer lock, SQLite backup API, append-only generation rows, immutable release,
  per-payload SHA checks, manifest-last packaging. Replaying identical inputs
  inserts zero rows and preserves 36 candidate snapshot rows and oldest date.
- All four existing all-institution tables reconcile byte-semantically to v10.
  Stock, manager and industry sums reconcile to every sector summary.
- Audit receipts: `data/fact_os/audit/sector-drilldown-v12-reconcile-20260922.json`,
  `sector-v12-storage-20260922.json`, and timestamped `13f-active-insights-*`.
  These ignored artifacts stay out of Git and private user stores stay out of
  the deployment bundle. v11 is an unreleased pre-quality-check candidate.

## Verification

- Python: 8 tests, including split neutrality, missing filing vs exit, missing
  values, full population, stable ordering, 1,000× share errors and rounding.
- Full Node suite: 1,652 pass, 15 skipped, zero fail. Focused API/package/runtime
  tests re-run after final changes; independent temporary install root validates
  v7 runtime schema, hashes and ownership rules.
- Performance transport regressions: 60 pass. Direct-function local reads:
  cold 8.35ms; 60 warm samples p95 0.12ms; 15,580-byte page / 4,251-byte gzip.
  These are not HTTP or production latencies and not a before/after optimization
  claim. No complete-sector payload is sent to the initial page or client.
- Flutter focused: 24 pass, including EN/ZH desktop/390px, lazy loading,
  failure/retry, race suppression and navigation. Analyze and i18n pass.
- Full Flutter suite: 565 pass, 32 pre-existing failures (27 Discover lenses,
  two growth/quality, one opportunities, one portfolio Guru, one valuation memory).
  The same failures were independently reproduced at the pre-change baseline;
  no assertions were removed and no failure is reported as a pass.
- Storage: Fact OS audit passes with zero duplicate raw bytes and stable
  canonical manifests. Repository layout audit still reports 11 pre-existing
  findings (one legacy SQLite path and ten retired sibling directories). No
  databases or unrelated directories were deleted to obtain a green result.
- Browser: actual Technology → industry → stocks; NVDA filter preserves #17;
  opens NVDA Research Institutions with cutoff 2026-09-21; returning retains the
  active scope and 2026Q2. EN desktop and 390px layouts verified. Screenshots
  retained in `/private/tmp/sector-drilldown-*.png` during release validation.
- Production-mode Flutter build passed with auth bypass explicitly false.

## Release and recovery plan

Deploy only committed/published trunk from a clean bounded `/private/tmp`
checkout, preserving other workspace edits. AWS backend first (compatible with
v10), install v12 private sidecar with hash/row verification, then Vercel frontend.
Do not change the public/private databases, authentication, domains or API topology.

Rollback baseline: AWS `ai-insights-f338dc9`, sidecar v10, Vercel
`dpl_3aYVqqZ96dXca2sKa7JEZGBod1Ft` / `thesisforge-bqbbikrcj-yudonglu1136s-projects.vercel.app`.
Restore the sidecar environment pointers before reverting an old backend that
does not accept schema v7; alias both public domains together. No rollback
rewrites user data. Deployment results are recorded after actual verification.
