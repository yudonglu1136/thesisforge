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
  page overflow or browser errors. Production verification: **pending**.
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

Commit/push/deployment identities and final matrix acceptance will be appended
after verification. **This document is not a production-success receipt yet.**
