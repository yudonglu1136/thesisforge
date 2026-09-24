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
| S&P 500 | Canonical Sharadar SP500 historical quarter snapshots plus effective-date additions/removals | 2013-01-02–2026-09-21, continuous |
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

Both S&P and all-market Ackman proxies hold CELG at its 2019 cash/stock/CVR
acquisition. The canonical source has no BMYRT daily series. The reviewed action
therefore uses the issuer-reported $2.30 first trade on November 21, explicitly
liquidates the CVR at that price with 25bp cost, and carries the BMY stock claim.
This restores one continuous 2013–2026 public-market simulation without claiming
an actual Ackman trade or inventing CVR observations. Missing or altered evidence
fails snapshot validation.

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
- CELG: $50 + one BMY share + one BMYRT CVR. The right is modeled sold at the
  issuer-reported $2.30 first trade, net $2.29425 after 25bp, on November 21, 2019.

## Immutable inputs and reproducibility

Canonical generation:
`134e95b9d4e40564d3b3af62f177f98a80fb8df4ac30f1c79a8504d870e0ca29`.
No canonical or runtime database writes are part of this release.

Artifact SHA-256:

- All: `f54f6a0727e6f56f5d6c01bf69f6a1d44cd4996617272e8d915b86a9a36da95b`
- S&P: `6c0b226a63084fb86e4b5a33c28f4d43c6212a8049a180fe34534bbdf66d32de`
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

- Full Node: 1,735 passed, 15 explicitly skipped, zero failures.
- Final route/snapshot/range tests: 24 passed, including auth, incorrect universe,
  wrong snapshot, delayed publication and pre-coverage requests.
- Performance regression suite: 60 passed.
- Canonical Fact OS Python: 247 passed. Rule/universe Python: 10 passed.
- Independent Python daily replay: all 3,450 observations per S&P strategy
  across one segment, and all 1,688 per Nasdaq strategy reconciled.
- Actual canonical interval analysis: six S&P windows and four Nasdaq windows,
  including turnover, P&L residual and distribution-count reconciliation.
- Focused Flutter: 17 passed, including EN/ZH 390px, preserved intervals and
  out-of-order universe responses. Analyze, i18n and production-auth build pass.
- Full Flutter: 608 passed, **32 pre-existing adjacent failures**. Exact failure
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
results are recorded below, not inferred from local tests.

### Production acceptance

- Feature commit: `18b8bf6f669d0fb1b36d07fa471aec846831b290`, pushed to trunk.
- AWS: `universe-18b8bf6`, Ready/Green; deployment completed September 24,
  2026 at 14:31:40 UTC. Private code archive SHA-256:
  `ff7ebbed5d36c7d3a30db6a9ab42ee5745b4c863c7753f0c629ddbb7e0056e13`.
- Frontend: `dpl_2DfSXM2ZUEFsLux5udyVa3Qjkhni`, Ready, verified on **both**
  apex and www, URL `thesisforge-3il63207z-yudonglu1136s-projects.vercel.app`.
  Published Flutter JavaScript hash equals the locally verified production-auth
  build: `db704e1a855249df986ad064329bf0fe1e205fad82951416904dfc7075677645`.
- AWS actual `webapp` user: read-only canonical replay command
  `374a75b4-7731-48cb-bc8c-e10186f1abd2` succeeded for all three exact hashes.
  Six all-market, six S&P and four Nasdaq intervals passed, including 2013/2014,
  turnover, distribution counts, independently recomputed metrics and residuals.
  Receipt: `data/fact_os/audit/rule-universes-production-20260924.json` locally;
  full host report `/var/tmp/universe-18b8bf6-verification.json` (root-only).
- Runtime cold replay timings: all-market 13.8s, S&P 11.8s, Nasdaq 4.1s;
  subsequent tested interval calculations at most 336ms / 106ms / 86ms. These are
  host verification timings, not browser latency or a p95 performance claim.
- Both public domains return Vercel app responses and 401 for unauthenticated
  private universe endpoints. Eight concurrent health requests passed HTTP 200 /
  `ok:true`; the existing `stale/degraded` market-prices warning (September 18
  legacy price date) remains explicit. This task does not claim all data current.
- Replaying identical immutable inputs produced byte-identical new snapshots.
- Signed-in production browser: switched from all market to Nasdaq and S&P;
  Nasdaq shows 1,688 observations and 231.52% / 244.38% net interval returns,
  matching host replay. Chinese **390×844 CSS pixels** shows the S&P 2014
  interval with 252 observations, 19.09% / 14.51% returns and 82.78% / 133.73%
  one-way turnover. Source filing and snapshot hashes match the release.
  Browser screenshots and raw test logs are retained in the ignored release
  evidence directory `data/releases/rule-universe-sec-20260924/verification/`.

The public API, deployed code and canonical reads have been checked together;
no production database replacement or developer authentication bypass was used.
