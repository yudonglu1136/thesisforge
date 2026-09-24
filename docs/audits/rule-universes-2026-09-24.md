# Rule portfolio universes — 2026-09-24

## Delivered scope

The Rule portfolios page now selects All market, S&P 500, or Nasdaq 100 · QQQ
filings. Both Quality Rank and Ackman quantitative proxy are rebuilt within the
selected eligible population **before percentile scoring and selection**. The
selection applies to curves, quarterly holdings, score evidence, range metrics,
stock attribution, P&L distributions and turnover. Explicit date selections are
retained/clamped to available history; changing universe does not edit saved
user strategies. Requests and cache keys bind universe and exact snapshot hash;
late responses cannot overwrite a newer selection.

“All market” retains the existing eligible US common-stock rules, including
USD 1bn market capitalization and financial/real-estate exclusions. It does not
mean every listed instrument passes the screen. Financial inputs remain
current-vintage research reconstruction, **not strict archived-vintage PIT**.

## Membership and coverage

| Universe | Source | Available backtest |
| --- | --- | --- |
| All market | Existing common cohort, unchanged artifact | 2013-01-02–2026-09-21 |
| S&P 500 | Canonical Sharadar SP500 historical quarter snapshots plus effective-date additions/removals | 2013-01-02–2026-09-21, with declared gaps |
| Nasdaq 100 proxy | QQQ public SEC N-PORT equity holdings, exact canonical CUSIP/permaticker resolution | 2020-01-02–2026-09-21 |

Nasdaq membership is the latest **publicly filed** QQQ snapshot available before
the signal date, not an exact official daily Nasdaq constituent history. A filing
on the signal date is conservatively deferred because daily metadata does not
establish availability before the close. A late amendment of an older period
cannot replace a newer portfolio. Twenty-eight quarterly filings cover 2019 Q3
through 2026 Q2, with 101–103 equity securities and zero unresolved identities.
The latest June 2026 decision uses the March 2026 portfolio filed May 28, not
the June portfolio published in August. The UI links each selected SEC filing.
Older annual filings do not establish continuous quarterly coverage; **2013–2019
Nasdaq performance is not supplied or fabricated**.

Official source entry: https://www.sec.gov/edgar/browse/?CIK=1067839 . Exact
accession URLs and SHA-256 values are in `server/config/rule-universe-qqq.json`.
The source archive is content addressed under ignored
`data/releases/rule-universe-sec-20260924/sources/` (about 3 MB). The derived
membership classification reuses Fact OS identity; it is not a new security master.
One reviewed FER ISIN/CUSIP bridge is linked to the SEC N-PX original in that
artifact. Raw filings, private stores, databases and credentials are not packaged.

Both S&P strategies hold CELG at its 2019 cash/stock/CVR acquisition. Missing
verified BMYRT daily prices leave 2019-11-20–2020-01-01 unavailable; 2020 is an
independently funded segment. Cross-gap returns and attribution fail closed.
The UI defaults S&P to the latest continuous segment, with 2013/2014 shortcuts
and date controls to inspect older complete intervals. Existing all-market
history is unchanged (its Ackman segment has the same pre-existing gap).

## Action evidence

Additional selected-book actions are explicitly reviewed in
`scripts/build-rule-history-actions.py`, including effective execution date,
legal completion date, identities, cash/stock terms and SEC original:

- LLTC: $46 + 0.2321 ADI; completed after close March 10, 2017, effective next
  session March 13.
- BMC: $46.25 cash, September 10, 2013.
- LO: $50.50 + 0.2909 RAI, June 12, 2015.
- ANSS: final $199.91 + 0.3399 SNPS, July 17, 2025 before open. Announced
  preliminary consideration and a vendor's extra price row are not substituted.

## Immutable inputs and reproducibility

Canonical generation:
`134e95b9d4e40564d3b3af62f177f98a80fb8df4ac30f1c79a8504d870e0ca29`.
No canonical or runtime database writes are part of this release.

Artifact SHA-256:

- All: `76f0a490efb29aaadcc84ea5015f095d63891bd75e3cd8cc4ddff4f38a406e0b`
- S&P: `ebfe7e38d1d59f20cb7cac3cfcbd152b9467754921173c920fbbbbd412af5847`
- Nasdaq: `282819cf26b8d53de530d50e05f84808ad057644306f589d1f41d355c451f214`
- SEC membership: `cd10b95965ed969bac9867a9d6ee401fb912be470ebd958a65fedb9819ff1968`

Producer stages: `build-sec-qqq-universe.py`, existing
`build-rule-history-actions.py`, `build-rule-portfolio-inputs.py --universe
sp500|nasdaq100`, then `replay-rule-portfolios.mjs`. Nasdaq additionally supplies
`--start 2020-01-01 --sec-universe server/config/rule-universe-qqq.json`.
All bounded input paths remain explicit CLI arguments; their hashes and the
scoring adapter, actions, selection builder and membership helper hashes are
bound in lineage. The previously reviewed local scoring adapter/common panel
are reused, not replaced or checked in as unrelated research work. Runtime
needs only committed derived snapshots and canonical data for range attribution.
Existing observation-refresh tooling accepts the universe as its fourth
argument; this feature does not add a timer or change saved research on a schedule.

## Fresh verification

- Full Node: 1,728 passed, 15 explicitly skipped, zero failures.
- Final route/snapshot/range tests: 24 passed, including auth, incorrect universe,
  wrong snapshot, delayed publication and pre-coverage requests.
- Performance regression suite: 60 passed.
- Canonical Fact OS Python: 247 passed. Rule/universe Python: 8 passed.
- Independent Python daily replay: all 3,422 observations per S&P strategy
  across two segments, and all 1,688 per Nasdaq strategy reconciled.
- Actual canonical interval analysis: six S&P windows and four Nasdaq windows,
  including turnover, P&L residual and distribution-count reconciliation.
- Focused Flutter: 17 passed, including EN/ZH 390px, preserved intervals and
  out-of-order universe responses. Analyze, i18n and production-auth build pass.
- Full Flutter: 604 passed, **32 pre-existing adjacent failures**. Exact failure
  names compared with the prior 2013 release: no new failures, none suppressed.
- Broader `scripts/test_fact_os*.py` run: 44 tests, 9 failures and 2 errors in
  the unchanged replay fixture (`catalog_database_mismatch:stocks`). This is
  separate from the passing 247-test canonical suite; no storage assertions or
  fixtures were weakened to make this release pass.
- Full Fact OS storage audit passes. Repository layout retains 11 existing
  findings, including retired sibling directories and the existing valuation
  source database; no unrelated storage was removed.
- Actual local browser: English desktop, Chinese 390px; switched all three
  populations, selected S&P 2013 (252 daily observations), and verified both
  tables change together. Final release verification is recorded below.

## Release and rollback

This is code plus small derived JSON; no database migration, auth bypass,
configuration rewrite, source ingestion or portfolio-store mutation.
Rollback targets before deployment: AWS `history2013-042b2cf`; Vercel
`dpl_7h1FhpK5yhExT7XdFq1Ydbqk2Sx6` /
`thesisforge-ko49491h6-yudonglu1136s-projects.vercel.app`.
Rollback switches the backend application version and both frontend aliases,
leaving live user data intact. Deployment identity and production read-back
results will be appended after verification, not inferred from local tests.
