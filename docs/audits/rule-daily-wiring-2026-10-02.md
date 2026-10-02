# Public rule daily pipeline: implementation and AWS candidate verification

This is a candidate receipt, not a claim of production activation or scheduled acceptance.

The opt-in `--rule-portfolios` path replaces the strategy input-only group with
one three-universe curve/ledger bundle. It preserves the six-group public-only
activation scope and does not touch Guru study curves, reviewed valuation models
or user/private portfolios. IaC `RulePortfolios` defaults false until acceptance.

External inputs are acquired before planning, archived, checksummed and pinned:
public FRED DGS10, official SEC QQQ N-PORT holdings resolved to exact canonical
CUSIPs/permatickers, and the exact prior published public curve/ledger bundle.
The original quality and Ackman selection formulas are reused as runtime code.
Missing, stale or ambiguous inputs stop the group. New corporate actions outside
the already modeled dividends/splits require review. This is current-vintage
research reconstruction, not archival historical index membership or fund returns.

AWS candidate evidence:

- Dependency command `caf9e6ff-41a1-436b-8649-613f225150c8`: verified.
  DGS10 through 2026-09-30; QQQ disclosure through 2026-08-28.
- Quarter generation `34d20bdd-d563-4482-af3d-523346e96752`: verified. September
  30 signal, next observed session execution, all three universes and both rules.
  Common universe 1,605 rows; zero future financial publications.
- First atomic attempt correctly failed because a Node cache token was used
  instead of the canonical catalog SHA-256. Fixed in `27e887d`; gates unchanged.
- Atomic retry `49bef610-4513-421c-98f5-0bbcf7e8d6b0`: verified, data through
  2026-10-01, 3,458 all-market/S&P observations, 1,696 QQQ observations.
  Bundle `c7c7737ef78ae0cbe1f2cb4dbdbf914f8a268676b3e95d5bce07412c30f19733`.
  Canonical source `17e464826b5a887570e8c13f08dc9bb1da1c9d884c9c8187fae0d589b4ca3efd`.
  Daily NAV replay and window-level P&L/distribution reconciliation passed.

Tests: Node full suite 1,767 passed, zero failed, 15 skipped; performance 60
passed. Python Fact OS suite 275 passed after adding the runtime and worker
flag-wiring regressions. Full storage audit passed with zero
duplicate raw bytes; the 11 pre-existing legacy layout findings remain preserved.

The October 2 scheduled public run failed on upstream holdings-universe mutation.
Its classifier now invalidates the extraction attempt and uses the existing
single bounded retry, without reducing source coherence verification.

Deployment remains gated by a full worker run, API installation and exact live
ACK. The next real Scheduler execution must be separately attested. Retain old
worker code, application version and active public pointer; do not delete source
archives or rollback generations to fit an installation.

## Production wiring and live validation in progress

- Backend `rule-daily-5057558` deployed Ready/Green, rollback application
  `public-inode-1b1f721`. Existing public release continues serving pending
  data installation. This is not a strategy-data activation claim.
- CloudFormation `rule-daily-c842432` completed, with RulePortfolios=true,
  ActivateDaily=true, RunDocument 7 and InstallDocument 2. Actual document
  arguments and State Machine numeric document version were independently
  re-read. The public schedule remains DISABLED pending acceptance.
- Worker AMI is pinned to its existing image. An earlier preview that proposed
  instance replacement was discarded without execution; no worker, disk or
  API capacity expansion occurred.
- Full real manual worker command `806182d6-8f91-46ea-b393-db33ad7acb41`
  runs immutable code `5057558`, scheduled-for `2026-10-02T11:20:00Z`.
  This is a manual validation, not a Scheduler-triggered success. Sources are
  processed under the existing single writer lock. Code pointer remains
  `/opt/fact-os/releases/48dc2c1` until validation and safe cutover.
- Both formal frontend aliases resolve to
  `dpl_Grk2DSdw6sqgZs5NDGWfaftrkQrk`,
  `thesisforge-4oy0ewyv5-yudonglu1136s-projects.vercel.app`.
- Actual API probe `a3798033-cf14-43a5-bfad-cff19ab94234` confirms the retained
  release `e7be0d842e359b7b9efebc860a28bec54b513946c441c3f2eef7621bb5fa004b`,
  Research/Fundamentals/public-analysis ready. It is the OLD strategy bundle.
- Public aggregate health is still 503 for stale Guru-study/legacy price
  readiness, whose check code was not changed by this release. Do not claim
  overall platform health or reduce its gates to certify this public rule job.
