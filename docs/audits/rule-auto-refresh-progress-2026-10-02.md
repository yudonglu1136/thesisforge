# Rule strategy automatic refresh — incomplete release

Audit time: 2026-10-01 22:36 UTC / 2026-10-02 01:36 Asia/Riyadh.

This is a partial implementation receipt, **not** a production release or a
scheduled-activation acceptance. The website's existing strategy snapshots
have not been replaced by these candidates.

## Confirmed causes

1. The six-group public daily pipeline currently publishes `strategy_inputs`
   as a canonical input vector. It does not rebuild the rule portfolios.
   `publicAnalysisWorker.js` loads the committed investor-style snapshots;
   warming that cache does not extend their observation dates.
2. Replaying those snapshots directly against revised current adjusted prices
   fails `refresh_changed_historical_nav`. AWS command
   `abf4859b-67b2-44e3-8aeb-1499effa1f14` reproduced this failure. Relaxing this
   check would rewrite published history and is not an acceptable solution.
3. The latest stored selection for both strategies in all three universes is
   2026-06-30, executed 2026-07-01. Extending past September 30 requires a new
   quarter selection. `new_quarter_selection_required` remains enforced.

## Implemented and tested

Commit `7938c1d` adds an explicit published-price-vintage adapter. It recovers
recorded marks from the checksummed matching ledger, replays the complete
original ledger, and appends observed returns in its original adjusted units
using an exact common-date anchor. It does not overwrite canonical prices,
infer missing prices, fabricate corporate actions, or change old NAV.

The refresh CLI optionally accepts the exact ledger archive directory. Missing
anchors, mismatched snapshots, inconsistent marks, and unsupported exchange
mark bases fail closed. All existing quarter and reconciliation guards remain.

- Targeted Node tests: 8 passed, 0 failed.
- Full Node server suite: 1,758 passed, 0 failed, 15 skipped (1,773 total).
- Full historical replay using all three actual archived public ledgers passed.
- Real AWS candidate builds from one pinned canonical snapshot passed for all
  three universes. Each build runs `buildRuleLedger` to reconcile daily NAV,
  turnover and fees. This is not independent live API verification.

Pinned canonical input:
`3e68ee713d4eeff8e95550441058e157db896298bcfeb299cb18ed5fde75ac6e`.

| Universe | Candidate through | Observations | Candidate SHA-256 |
| --- | --- | ---: | --- |
| All market | 2026-09-30 | 3457 | `927a8ea4336060585c22a5672a599f1ae1d85fc68f1e1675bc55ed161e4bdb55` |
| S&P 500 | 2026-09-30 | 3457 | `d9b629b91a61c5ed9222261e1fa1613e7ce5db589e9468092543adb890617974` |
| Nasdaq 100 / QQQ filings | 2026-09-30 | 1695 | `cb2685e4f00430f8f3aaa9c566d8b573f0e57c50dc9f36a5d201781dff1c5d49` |

SSM candidate receipts: `471d64dc-a551-4774-be8a-26251921aa64` (all market),
`5144d520-a8ec-4dfe-81dc-b71cce13111e` (S&P 500 and Nasdaq 100).

Code-only worker archive was staged under private S3
`fact-os/code/7938c1d-rule-vintage.tar.gz`, SHA-256
`28011221f7ef90a0826d9c62724a15e8f92d04d76d842f78c29283b702fe5b98`.
It was extracted to `/opt/fact-os/releases/7938c1d` for offline candidates only.
The worker's current symlink and scheduler were not switched. Candidates are
under `/var/lib/fact-os/data/staging/rule-daily-20261002/`.

An earlier download attempt under the `releases/` S3 prefix failed with 403.
The retry used the already-authorized `fact-os/code/` prefix, without changing
IAM permissions. No source sync, backfill, private account access or API
activation was performed for these candidates.

## Work still required before claiming completion

- Package each new curve with its exact corresponding derived ledger, range
  statistics and checksum manifest; preserve archived versions for replay.
- Connect the complete bundle to the pipeline registry, immutable input
  fingerprint, installer, request-pinned runtime, cache generation and live ACK.
- Implement next-quarter selection using the existing versioned rules and
  properly pinned fundamentals, rates, memberships and corporate-action inputs.
  The original feature adapter is archived rather than installed as a runtime
  dependency; DGS10 acquisition is not in the daily contract. QQQ membership
  currently binds to an older whole-catalog identity and needs genuine identity
  revalidation, not a hand-edited generation value.
- Verify automatic no-change/retry, failure retention, all three universes,
  both curves and range attribution in production.
- Accept a real Scheduler-triggered public API activation after the installer
  fix. The October 2 07:30 Asia/Riyadh invocation had not yet occurred at this
  receipt's audit time. The October 1 manual recovery is not that evidence.

## Storage and production boundaries

`audit:storage-layout` still reports the same 11 legacy layout findings: the
extra valuation source database and retired sibling/recovery directories.
Nothing was deleted to make this check pass. The npm Fact OS audit initially
refused to overwrite the existing `storage-layout-latest.json`; its retry uses
the new small receipt `data/fact_os/audit/storage-rule-vintage-20261002.json`.
That full Fact OS audit passed: 20,986,658,840 total bytes, zero duplicate raw
bytes, and 4,948,907,099 retained Parquet bytes.
No database or complete data tree was copied.

Existing public serving recovery and rollback identities remain documented in
`public-serving-recovery-2026-10-01.md`. There is no new strategy production
release ID, and no assertion that the site currently serves these candidates.
