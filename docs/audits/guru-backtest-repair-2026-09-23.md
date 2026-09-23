# Guru backtest repair — 2026-09-23

## Scope and evidence

User authorized repair, removal of unusable Guru entries, testing and production
publication. The baseline was `faba7bf9807c9cf0e1288065dcb33c7aea072435` on
`trunk`. Unrelated working-tree documentation and rendering scripts are not
part of this release.

Confirmed defects:

- With Fact OS enabled, a public `refresh=1` discarded a valid audited SEC
  simulation and returned `pit_unavailable`. Protected refresh jobs entered the
  same fail-closed read branch and could not recompute the SEC simulation.
- Cache compatibility and writes did not consistently bind the payload's Guru
  identity to the requested key. Production's inspected rows did not have an
  identity mismatch; the reproduction demonstrates a missing guard, not a
  claim that all existing returns were misassigned.
- A proxy could match a strict failure timestamp while belonging to another
  refresh generation. Both identities must match when generations exist.
- A failed full filing read could leave the simulation continuing with a
  partial history. The protected refresh now fails without replacing the prior
  published curve.
- The strategy UI described missing filing/model/price evidence as if the
  user's valuation filter alone excluded every stock.
- SQLite journal-mode negotiation ran before the busy timeout was installed,
  causing a reproduced concurrent startup failure in the full regression suite.
- Production health falsely treated four existing expression indexes as
  incompatible because SQL casing and punctuation whitespace differed. Its
  fallback scans approached the 8-second health-worker deadline. SQL-token
  comparison now accepts formatting differences while preserving the exact
  quoted JSON paths and string literals.
- Transient SEC transport failures could invalidate an otherwise usable full
  history. Read-only requests now have at most three attempts; auth, missing
  documents, parsing and identifier failures still fail immediately. History
  diagnostics retain accession, report period, status, code and message.
- The production publisher's 30-minute hard deadline was shorter than the
  observed 30.5-minute 5Y and 38.5-minute 10Y sequential population runs. The
  default is now 60 minutes per window, bounded at 90 minutes. All exact-key,
  current-generation, strict/proxy and final health checks remain mandatory.

## Retirement, not archival deletion

The current Discover catalog, new-strategy catalog and refresh population omit:

| ID | Reason |
| --- | --- |
| `chamath-palihapitiya` | Configured reporting entity is not a verified identity match. |
| `john-stamas` | Required historical price coverage is not independently verifiable. |
| `nick-sleep-qais-zakaria` | Closed partnership; no current supported simulation. |

All configured identities, filings, avatar assets and historical/private
records remain intact. Direct retired backtest requests return an explicit
unsupported/retired result. No SQL deletion was used. There are 30 enabled
manager13f profiles and 57 required manager/window pairs, derived from the
catalog. Existing limited-history window policies were not shortened.

## Implementation boundaries

Public Fact OS requests remain cache-only. Only protected refresh/repair jobs
explicitly opt into verified SEC-disclosure computation. SF3 quarter ends are
never substituted for actual disclosure times. Strict 90% execution coverage,
the separately labelled proxy contract, Renaissance 5Y strict requirement,
security-master versions and total-return price requirements are unchanged.

The visible catalog is filtered at read time; immutable research releases and
saved user work are not rewritten to remove retired managers. Dashboard cache
object reuse and single-flight semantics are retained. Cache reads no longer
claim that a background refresh is running when none was started.

## Verification

- Reproducing tests failed before the refresh/identity fixes and passed after.
- Exact committed-source Node regression: 1,669 passed, 15 skipped, 0 failed
  (1,684 total). A separate current-workspace run also covered the other task's
  uncommitted tests; those files are not included in this release.
- Final targeted Node regression: 68 passed, 0 failed.
- Flutter strategy/mix regression: 46 passed, including EN/ZH 390px at 150% text.
- Flutter analyze: no issues.
- Full Flutter regression: 579 passed, 32 failed. All 32 failures were
  independently reproduced on baseline `faba7bf`; the exact failure-name sets
  match. They concern retired Discover lenses/quality controls and adjacent
  valuation/portfolio expectations. No assertion was removed and no affected
  adjacent implementation is being bundled as a speculative fix.
- i18n audit: pass. Performance suite: 60 passed.
- Launch-readiness and production-auth build guards: 40 passed. The bounded
  prewarm/loopback regression adds 24 passing tests, including a 40-minute
  accepted deadline and rejection above 90 minutes.
- Production Flutter artifact built with auth bypass disabled; SHA-256:
  `004fefe83f01b9b5eb414dbc4f56a710379774a9a66b5d3b7e12f3388664fc38`.
- Fact OS storage audit: pass; no duplicate raw archives.
- General storage audit still reports 11 pre-existing findings. No database or
  historical directory was deleted to obtain a clean audit.
- Real strategy sample: 16 selectable cases, 3 ready, 13 explicitly blocked,
  no exceptions; two retired choices are excluded. Source gaps and valuation
  exclusions are not converted into fictional returns. This is not a claim
  that every arbitrary strategy configuration is now runnable.
- First isolated real-data matrix: 51/57 displayable, six filing-read failures
  across Baillie Gifford 10Y, Klarman 10Y, Peltz 5Y/10Y and Halvorsen 5Y/10Y.
  This run failed; it is not an acceptance receipt. Its source file remained
  byte-identical and its snapshot passed SQLite integrity checks. All four
  managers' ten-year official histories subsequently read without filing errors
  or blocked report dates; these diagnostics do not replace full acceptance.
- Full real-data matrix with bounded SEC transport retries: **57/57 pass**
  (23 strict, 34 explicitly labelled public-sleeve proxies), completed
  `2026-09-23T14:07:27.996Z`. The 5Y matrix is 30/30; the permitted 10Y matrix
  is 27/27. Both generated JSON and Markdown acceptance reports accompany this
  audit. SQLite integrity is `ok`; the source SHA-256 remains
  `9bb2c803a7771bd27444b3f802b6f3b69bc947673e74e0a3146ddf86d57b01e6`.
- Browser local Guru directory: 30 active profiles; retirement is reflected in
  holdings and consensus. An Ackman Top-5 custom strategy with valuation
  filtering disabled produces 1,255 real daily observations and 21 rebalance
  snapshots; required missing valuation inputs instead produce the specific
  source-gap message. EN desktop and ZH 390px mobile were exercised without
  page overflow or browser errors. Final production verification is recorded below.
- Same production DB, read-only health table-summary diagnostic (three rounds):
  5,630/5,898/3,628ms before, 575/519/57ms after; all six result semantic hashes
  identical. This is a bounded diagnostic, not a 60-sample API p95 claim.
- Full-health worker concurrency benchmark on one immutable local SQLite
  source: three rounds per revision, 60 reads at concurrency 20 per round.
  Median p95 1,098.88ms before / 200.59ms after (81.75% reduction), exactly
  three shared workers per round, identical complete response hashes. Gzip
  54,871 → 5,626 bytes. This measures the bounded health service, not network
  latency or a claim that all API paths improved by that amount.
- The repository's five-route API benchmark was also run on the same SQLite
  snapshot with three paired repetitions, 200 samples / concurrency 20, after
  the real backtest worker finished. Its prohibited raw file-copy step was
  replaced in a temporary runner by the SQLite online backup API. All five
  routes returned 200, conditional requests returned 304, and large responses
  compressed by over 75%. The generic `check:performance` gate **did not pass**:
  it rejects the intentionally changed Guru populations, and local millisecond
  p95 measurements also exceeded its 5% regression threshold on four paths
  (including unchanged valuation handlers). Do not call this a full API
  performance certification. Independent response comparisons in all three
  repetitions prove that removing exactly the three authorized retired IDs
  makes both changed Guru responses byte-identical after the benchmark's
  existing volatile-field normalization. No checker or assertion was weakened.
- Actual AWS `webapp` account successfully read the canonical Python/Parquet
  path: eight SPY adjusted-close observations from September 10–21. SSM
  receipt `3bc885f9-ff44-40f3-b1e0-2e1e7adb3e76` verifies permissions and the
  installed reader, not a new data publication.

Private detailed logs and the isolated acceptance report are under
`/private/tmp/guru-*20260923*`; they are not packaged into the app.

## Additional production findings and repairs

The first AWS full-window run exposed a source transport failure that the local
acceptance did not reproduce. In particular, TCI/Chris Hohn accession
`0001647251-25-000003` returned HTTP 503 from the official SEC directory JSON
while its original `.txt` submission returned HTTP 200 (8,045 bytes, SHA-256
`019b12139eb7b396f94dcce3d9a940c9c010f7a5fea89db3cc76b8be271b8518`).
SSM receipt: `03629681-93e0-42ad-b217-25be81423665`.

After exhausting bounded transport retries, 13F readers may now discover the
typed information-table attachment through that exact official original. The
original must match accession, filer CIK, report period and form. Ambiguous or
unsafe filenames still fail; 401/403/404, rate limits and long Retry-After values
do not use this path. There is no mirror, guessed filename, substitute quarter
or invented holding. A regression first reproduced the directory-503 failure.
Protected bulk diagnostics now retain filing identities and error codes without
exposing arbitrary transport details. Previous failed runs remain failed.

Canonical holding prices now reuse `queryFactsBatch`, preserving exact active
intervals, explicit total-return basis, source identity and per-observation
provenance. Batches are bounded to eight (six by the default backtest worker).
Missing or changed inputs remain fail-closed; SQLite/network fallback is not
introduced. The repository's generation guard, reader lease and cache are reused.

Three fresh-process repetitions on six real 10Y histories show identical semantic
hashes and a median reader time of 2,371.85ms → 1,282.66ms (45.9% reduction).
Peak reader-process RSS increased from about 160MiB to 311MiB; bounded batches
are important. This is not an API p95 or production-wide speed claim. Reproduce
with `node scripts/benchmark-guru-price-reader.mjs`; the JSON report is under
`docs/performance/2026-09-23/guru-repair/price-reader-batch.json`.

Independent real 5Y recomputations for Ackman, Chase Coleman and Renaissance
produce identical status, window, summary, equity response, rebalances and
quarterly-contribution hashes before/after batching. They use memory-only
databases, official SEC sources and unchanged canonical Parquet. Exact-source
batch regression: 1,674 passed / 15 skipped / zero failures; performance tests
60/60. The final exact-source regression including the directory fallback is
1,676 passed / 15 skipped / zero failures (1,691 total).

The Fact OS audit passed again (20,983,490,701 bytes, zero duplicate raw bytes).
Its append-only receipt is `data/fact_os/audit/guru-batch-storage-20260923T1510.json`;
the default `storage-layout-latest.json` already existed and was not overwritten.
General storage audit still has the same 11 existing findings.

## Production and rollback

Pre-deploy EB version: `fundamental-702448f`; environment `thesisforge-api-prod`.
Pre-deploy Vercel deployment: `dpl_6z8qsn8121iGTnahRPTZC9vjGyRr`, both app domains.
Public health was HTTP 503 before this repair despite EB reporting Green.
After accepting the existing indexes, a read-only full health audit completed
in 1,274ms and exposed the independent freshness failure: the old curves were
approximately 64 hours old, beyond the unchanged 48-hour generated-age gate.
A code deploy alone cannot clear that failure; canonical full-matrix production
recomputation and its health attestation are still required.

Verified rollback material, before any production curve write:

- SQLite backup `/var/app/data/backups/guru-repair-20260923.sqlite`, integrity
  `ok`, SHA-256 `c0c8cbe5b989f5b3ebe7ebc8b02ff8be369efa68b196b0edc0ff0302601953b4`.
- Completed source EBS snapshot `snap-01cd197439e20633d` of
  `vol-04879aae99266e0e9` and completed encrypted rollback copy
  `snap-0d35b97fbd109bad2`.

Before any production curve write, verify the SQLite backup and completed EBS
rollback snapshot. Publish via the loopback-only prewarm runner with explicit
5Y/10Y, immutable generation and exact method/security-master identities. A
failed matrix must not produce a success marker. Preserve the previous app
version and database backup until post-deploy API and UI verification passes.

This repair does not pretend that the separately deployed data-only Fact OS
daily scheduler already publishes Guru backtests. Its deferred backtest group
and any remaining custom-strategy source gaps must be reported separately.

The final production-success receipt is recorded below. Earlier failed and
in-progress observations are retained as execution history, not final status.

## Production execution history

- Initial frontend: Vercel `dpl_4VrUUXD5YFAc7taKGTZM7hyBXTV7`,
  `https://thesisforge-5wo783dzn-yudonglu1136s-projects.vercel.app`.
  Both apex and `www` resolved to this production deployment. The frontend
  contains the catalog retirement and source-gap messaging; auth bypass is off.
- A later live alias check resolved both domains to Ready deployment
  `dpl_578GajpxHzk2wm1Q7Duk4PBegfDE`,
  `https://thesisforge-pbtzqtxu3-yudonglu1136s-projects.vercel.app`.
  The actually served `main.dart.js` is byte-identical to the reviewed production
  artifact (4,763,776 bytes; SHA-256
  `004fefe83f01b9b5eb414dbc4f56a710379774a9a66b5d3b7e12f3388664fc38`).
  Both public build metadata endpoints attest the same hash and enabled
  investment workflow. The changed deployment ID is not a different UI build.
- Initial backend release: `guru-repair-3c849cb`, committed source
  `3c849cbba87f4ba8c81a544b89d5913d9c2dffbb`.
  Its canonical run (SSM `3167f044-b01a-4dcc-8d43-37a205883c7e`) ended
  **failed** at 2026-09-23T15:28:12Z. The 5Y window had 15 strict-ready,
  10 separately labelled proxies and five filing-read failures (Chase Coleman,
  Chris Hohn, Nelson Peltz, Andreas Halvorsen and Mohnish Pabrai).
  It did not proceed to 10Y or create a completion marker.
- Fixed backend: `guru-repair-175b4a2`, committed source
  `175b4a210fe44757e76bef9b710e7070f4e2efce`. EB reported Ready/Green at
  2026-09-23T15:43:21Z. Private release ZIP SHA-256:
  `1c07668988b03b0dab9958b11b88a186ec71660898907d1bd90118d305f2d894`.
  The exact-source package excludes concurrent uncommitted work, including
  unrelated `backtestEngine.js` changes.
- New canonical publication: SSM `d9d4147c-23d8-4e04-a5be-2504f241af74`,
  started 2026-09-23T15:44:27Z, generation
  `a36efbb08ea688e41d6f8bbb44c83fa687ccda2bdd958c5a76d88bae1b3c658a`.
  The runner verified deployed source hashes, the existing rollback backup,
  disabled production auth bypass, disk headroom and absence of another writer.
  Final 57-row validation was pending at launch; EB Green was not that validation.
- Post-deploy authenticated browser checks loaded the 30-manager Guru catalog
  and its 30 comparable style rows. Those style rows belong to the installed
  immutable Research release, ending 2026-09-18. They are not represented as
  proof that the newly recomputed runtime 5Y/10Y matrix is complete.
- The new 5Y pass restored every manager that had a filing-read failure in the
  initial production attempt: Chase Coleman, Chris Hohn, Andreas Halvorsen and
  Mohnish Pabrai returned strict `ready`; Nelson Peltz returned the separately
  allowed `proxy_ready` result. No source-coverage gate was reduced. The
  2026-09-23T16:14 progress receipt `5cc29c92-0f85-4c84-842e-fcd82e5e7444`
  recorded 25 processed rows and no hard failure. This intermediate progress
  is not the final two-window attestation.
- At 2026-09-23T16:24:53.915Z the new production 5Y window passed all
  30 current-generation manager checks: 19 strict-ready and 11 permitted
  proxies, zero hard failures. The runner then started 10Y sequentially.
  SSM progress receipt: `15ef127d-552c-4a1b-ab65-435e53dc11ff`.
  The low-level strict-refresh counter calls proxies failures by design;
  all 11 are separately attested `proxy_ready`, not hidden source failures.

## Browser return-path repair

The final authenticated browser round trip found an additional existing Guru
preview defect: returning from Strategies restored the selected ticker but not
its price/model preview. `GuruHoldingsMatrix.update` requested detail only when
the ticker changed. The same condition also skipped the re-read after a cutoff
change cleared the detail cache. The focused regression first failed with an
empty request list, then passed after requesting an uncached selected ticker.
Successful previews still avoid duplicate requests when display controls change.

- Frontend code: `8cbc819d90e790f68eb28ec4dd80981cfd030ac1`, pushed to `trunk`.
  Only `lib/investment_guru_holdings.dart` and its test were included.
- Guru holdings/study tests: 31/31. Full isolated Flutter run: 580 passed,
  32 failed. All 32 failure names exactly match both the earlier full run and
  the independently tested original baseline. Analyze and i18n passed.
- The first local build attempt inherited the source-verification Git environment
  into Flutter's SDK discovery and failed before producing an artifact. The
  verification-only Git environment was then scoped to source checks, and the
  normal SDK production build passed with authentication bypass disabled.
- Automatic Vercel production deployment:
  `dpl_3Jmmn5v7RFwtDwRFeHFXH9XJN6R1`,
  `https://thesisforge-bnrbqw7fe-yudonglu1136s-projects.vercel.app`.
  Both application domains serve the identical verified 4,763,806-byte JS:
  SHA-256 `038bcba2beaa7546347922a5d489e6a4ae3705638bd62a227a2a1049406339d7`.
  This frontend-only release does not restart the active backend prewarm.
- Fresh production browser verification: Ackman Top-5, 5Y, valuation off,
  no CTA, leverage 1 and 10bps returns 1,255 actual daily observations and
  21 rebalances. Latest holdings are UBER/BN/MSFT/AMZN/HHH at 20% targets.
  Turning valuation filtering on correctly blocks the missing 2021-09-20 QSR
  model separately from LOW/A/CMG/HLT price-limit exclusions, in both languages.
  No strategy or user record was saved. Browser error-level log count is zero.
- The new production Guru → Strategies → Guru round trip restores AMZN
  price USD 253.71 (2026-09-18) and published model USD 235.69 (2026-07-31),
  with the 30-manager catalog intact. These are installed Research-release
  values, not a claim that the Research release was rebuilt by this task.

## Final production acceptance

The canonical publication completed successfully at
**2026-09-23T17:29:49.730188Z**. All **57/57** required current-generation rows
passed: 5Y **30/30** (19 strict / 11 proxy) and 10Y **27/27** (4 strict /
23 proxy), with zero hard failures. All 30 active managers have a supported
5Y result; the existing 5Y-only policies for Li Lu, Pabrai and Soros are unchanged.
The 34 proxies remain separately labelled and are not presented as full-fund NAV.

An independent read-only attestation (`f6cd658e-9077-43bf-875b-f7f26eb0ddb9`)
verified the official completion marker, report hash, exact 57-key matrix,
method/security-master versions, per-window generation and idle refresh worker.
The canonical report SHA-256 is
`c39cdafbeaeefdf3453387059b51fb3daa261e4553b15d8e8233025fd78bbb1c`.
The production generation is
`a36efbb08ea688e41d6f8bbb44c83fa687ccda2bdd958c5a76d88bae1b3c658a`.

After the health cache TTL expired, eight concurrent reads at each of
`backend.thesisforge.tech`, `thesisforge.tech` and `www.thesisforge.tech` all
returned HTTP 200 / `ok: true`, identical curve hashes and 57/57 availability.
The overall health status is still `stale` because `market_prices` reports an
existing economic-source freshness warning. This is not a Guru curve failure
and is not represented as a fully fresh system-wide health result.
All responses retained active data-release identity
`5c318a56abe766f1e74e41ac2a84c7efd80d5d612649af88d99dda15b46f3e84`.
Observed latencies were 1,676–1,697ms direct, 498–606ms apex and 415–474ms www;
this small burst is not a new p95 benchmark. Anonymous strategy requests stayed
401, internal refresh status stayed externally 404 and retired Value Flow stayed
410 at all three origins. Authenticated browser verification remained successful.

Machine-readable evidence is
`guru-backtest-repair-2026-09-23.production.json`. Backend source/release remain
`175b4a2` / `guru-repair-175b4a2`; frontend source is `8cbc819`, with the verified
Vercel identity and artifact hash above. No unrelated work was committed.

### Explicit remaining limits

- Daily Fact OS data-only synchronization does **not** run this canonical Guru
  publication. The 48-hour generated-age gate is unchanged; recurring backtest
  publication remains a separate unfinished integration, not a scheduled pass.
- Research/Strategy's immutable installed data still end at 2026-09-18; current
  runtime Guru curves end at 2026-09-21. No historical release or user strategy
  was silently rewritten to align those dates.
- Custom valuation-filtered strategies can still be unavailable where historical
  filings, prices or models are genuinely missing. They now explain the gaps.
- The 32 baseline Flutter failures, 11 pre-existing storage findings and the
  generic five-route performance gate remain visible above. This is acceptance
  of the scoped Guru repair, not a claim that every repository check is green.
