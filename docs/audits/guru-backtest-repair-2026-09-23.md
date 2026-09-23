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
- Full Node server regression: 1,662 passed, 15 skipped, 0 failed (1,677 total).
- Final targeted Node regression: 68 passed, 0 failed.
- Flutter strategy/mix regression: 46 passed, including EN/ZH 390px at 150% text.
- Flutter analyze: no issues.
- i18n audit: pass. Performance suite: 60 passed.
- Production Flutter artifact built with auth bypass disabled; SHA-256:
  `004fefe83f01b9b5eb414dbc4f56a710379774a9a66b5d3b7e12f3388664fc38`.
- Fact OS storage audit: pass; no duplicate raw archives.
- General storage audit still reports 11 pre-existing findings. No database or
  historical directory was deleted to obtain a clean audit.
- Real strategy sample: 16 selectable cases, 3 ready, 13 explicitly blocked,
  no exceptions; two retired choices are excluded. Source gaps and valuation
  exclusions are not converted into fictional returns. This is not a claim
  that every arbitrary strategy configuration is now runnable.
- Full real-data Guru matrix: **pending**, isolated snapshot recomputation.
- Browser local Guru directory: 30 active profiles; retirement is reflected in
  holdings and consensus. Production authenticated verification: **pending**.

Private detailed logs and the isolated acceptance report are under
`/private/tmp/guru-*20260923*`; they are not packaged into the app.

## Production and rollback

Pre-deploy EB version: `fundamental-702448f`; environment `thesisforge-api-prod`.
Pre-deploy Vercel deployment: `dpl_6z8qsn8121iGTnahRPTZC9vjGyRr`, both app domains.
Public health was HTTP 503 before this repair despite EB reporting Green.

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
