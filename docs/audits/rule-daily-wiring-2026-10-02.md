# Public rule daily pipeline: implemented, manually activated, schedule enabled

Updated October 2: real manual production activation passed and the original
schedule is ENABLED. First scheduled acceptance of the new rule bundle remains
pending October 3. The earlier candidate/in-progress sections below are retained
as chronology, not the final state.

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

## Final manual production evidence

- Full worker run `e59a65d5867d719e005d725c2195a4f8059ee32dec3c648389f7a51e3a5d51bd`
  completed all 14 sources `ready` and all six tasks `succeeded`, no failed
  sources. This run was manually invoked for `2026-10-02T11:20:00Z`.
- The run itself generated September 30 signal / October executable-quarter
  selections for both rules in all three universes. Common feature population
  1,605; future financial publications zero. Public rates and exact QQQ
  identities were acquired before planning and frozen into the input snapshot.
- Bundle identity
  `0ec0c920a68b529aa74ca6a1b35f7dd81178e702f8a34d5287afe6cd06d94b17`:
  all-market and S&P 500 each have 3,458 daily observations, QQQ universe 1,696;
  all end on October 1. Full daily replay and range P&L checks passed. No new
  calendar-day prices were manufactured. Existing execution conventions remain.
- First installation `de6cca9d-1fc5-47d3-ad85-9d5396db36d8` correctly failed
  before writing payloads: required 3,572,804,966 bytes plus the 1 GiB reserve
  exceeded free space. No capacity gate was reduced.
- Tested operator maintenance `032aea9` consolidated 189 checksum-identical
  canonical Parquet paths into shared immutable inodes. All paths and content
  remain; no archives, product SQLite, private records or historical versions
  were deleted. Actual space reclaimed 553,578,496 bytes. Five tests cover
  corruption, symlinks/writability, locking, failure preservation, open readers,
  noncanonical isolation and no-op replay. API receipt:
  `audit/canonical-inode-dedup-a20cbcfd98d8483ab6056521c30a6f25.json`.
- Retry reused the exact validated run without fetching or rebuilding.
  Worker publication `db7bf75f-606c-420f-bae9-cd40a56adc98` and API install
  `6eda3d90-cb0e-4d43-abe9-27ddac982648` both succeeded.
- Serving release:
  `e9a012aacd0fea66cee5feecb6656e6b26a9ba65cb281c55ca8b06480114da5c`.
  Strategy group:
  `c1e547c6d5dc47ec336682121c22690f6828bbc2745ac76d604ae1e86fcde8a8`.
  S3 data-ready, S3 active, run receipt and API installed/serving versions and
  every group generation agree. Actual API user reads and canonical coverage
  passed; independent live probe `dcde021d-6f84-4da6-b0e8-2320baf1583b` returned
  HTTP 200/verified, Fundamentals 5,429 companies, Research AMZN/PLTR ready,
  and all three rule curve/ledger identities matching the manifest.
- The worker pointer was switched to `5057558` only while holding the writer
  lock after publication completed. Old code `48dc2c1` is retained, and its
  runtime successfully opened the current metadata database read-only.
- Change set `rule-daily-enable-20261002` updated ONLY DailySchedule, no resource
  replacement. Stack UPDATE_COMPLETE; schedule ENABLED, `cron(30 7 * * ? *)`,
  explicit `Asia/Riyadh`, original State Machine and `trigger=scheduler` input.
  RunDocument 7 includes `--data-only --activate-daily --rule-portfolios`.
- Internal public URL remains 404; unauthenticated strategy URL remains 401.
  Both frontend domains were reverified on the same Vercel deployment
  `dpl_FUXNGu4Ze9jFBjfFxapqYabxujFJ` after maintenance-code push. No frontend
  logic changed. The actual backend is `rule-daily-5057558`.
- Local full Fact OS storage audit passed again: 20,986,670,870 logical bytes,
  zero duplicate raw bytes. The same 11 legacy storage-layout findings remain;
  no databases or sibling archives were deleted to make that check green.

## Remaining acceptance and operating limits

1. October 3 Scheduler-triggered end-to-end acceptance is pending. Existing
   read-only monitor was updated to check the new curve/ledger/quarter bundle,
   exact API ACK and capacity; its failed-runs-only preference is preserved.
2. The browser remains logged out. Authenticated visible curve/range-table
   interaction has not been claimed as passed; the user has been asked to log
   in. Server-side production activation is independently verified above.
3. API disk has only 1,332,977,664 bytes free (96% used), roughly 259 MB beyond
   the required 1 GiB reserve. A later candidate may fail capacity protection.
   No expansion was authorized for this operation and no historical retention
   was weakened. This is NOT an unlimited-storage or guaranteed-future-run claim.
4. Public aggregate health has the separate stale Guru-study/legacy-price
   readiness failure. This rule-publication release does not certify the Guru
   matrix or overwrite reviewed valuations/private accounts.

Rollback: retain worker `48dc2c1`, EB `public-inode-1b1f721`, prior serving
release `e7be0d842e359b7b9efebc860a28bec54b513946c441c3f2eef7621bb5fa004b`
and all immutable objects. Pause public scheduling before a rollback, use the
existing expected-release installer/ACK/S3 fence, and roll back worker code and
RunDocument/RulePortfolios settings together; old worker cannot accept the new
flag. Do not rewind only a curve or only a ledger, or touch private stores.
