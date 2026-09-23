# Fact OS daily synchronization — production re-verification

Status: **not an accepted daily production cutover**. Inspected 2026-09-23.
Base source commit: `11274a72cb3ee8749d65acdfafd2b8c63fb43d41`.
No frontend, private portfolio/NAV job, production database or scheduler was
changed during this verification. Unrelated dirty working-tree files remain.

## Verified AWS state

- Account `378477120101`, region `us-east-1`, stack `thesisforge-fact-os`
  is `UPDATE_COMPLETE`.
- Dedicated writer `i-037be49f4a4038ac4`; retained encrypted 100 GiB volume
  `vol-0ee8b8122d9f37dfe`; approximately 78 GiB available before this run.
- Installed worker commit remains
  `d6ecf19020936cd56d17592193da4176020520b3`.
- Secrets Manager reference `thesisforge/fact-os/sharadar` has an
  `AWSCURRENT` version. The existing role-based access and real upstream fetch
  work. No secret value was read into this report, shell parameters or logs.
- Schedule `thesisforge-fact-os-daily` remains **DISABLED**,
  `07:30 Asia/Riyadh`. The associated state machine has **zero executions**.
  First genuine scheduled acceptance is pending, not inferred from SSM.
- Local Codex `thesisforge` public-data daily automation is still active.
  Retire it only after the AWS chain has been accepted. No broker/NAV job was
  stopped or modified.

## Prior live run completed; inspect the actual receipt, not old progress

SSM `2703457b-ea30-4e48-81c5-96c3cdfbf008` completed at
`2026-09-22T17:02:45.484Z`. Its exit code 2 is the intentional stage-only
boundary, not proof of an ingestion failure.

Run `e576b231d6a6057d4927de3f7786fa7ad446cc4ed2dcf0c9f45cce3bc5339cba`:
all 14 source tables complete, `failedSources=[]`; six tasks succeeded;
two independent external review gates blocked; publication
`staged_not_activated`. Candidate
`cbd8ea59d4c412814c40b164955985811e3a0be857baaa7de568c393a815f71f`.

| Source | Accepted rows | Source maximum |
|---|---:|---|
| tickers | 74,258 | 2026-09-22 |
| stocks | 45,367,279 | 2026-09-21 |
| funds | 15,644,026 | 2026-09-21 |
| fundamentals | 3,218,331 | 2026-09-21 |
| daily | 39,830,663 | 2026-09-21 |
| actions | 702,545 | 2026-09-22 |
| holdings | 81,203,505 | 2026-06-30 |
| holdings_ticker | 670,117 | 2026-06-30 |
| holdings_investor | 306,481 | 2026-06-30 |
| events | 2,531,745 | 2026-09-21 |
| insiders | 11,555,542 | 2026-09-21 |
| descriptions | 384 | Not a dated observation table |
| metrics | 43,775 | 2026-09-21 |
| sp500 | 61,189 | 2026-09-21 |

| Publication group | Actual status / limitation |
|---|---|
| canonical | Build passed. A separately scoped canonical version is live. |
| ai_insights | Build passed: 4,478 facts / 59 companies. Not activated by the pipeline. |
| institutional_13f | All/active seven-table build passed. Not activated by the pipeline. |
| public_observations | 196,104 quotes and 175,277 annual-quality rows built. Not activated. |
| research_inputs | Versioned input vector built; facts can read the active canonical release. |
| strategy_inputs | Input vector built, **not** a live Strategy price/warehouse adapter. |
| guru_strict | Blocked on independent accepted SEC evidence and reviewed manager/window matrix. |
| valuation_candidates | Blocked on reviewed model-release adapter; published historical models remain unchanged. |

## Live API checks

SSM read-only probe `684b1fb7-4137-49da-9c8d-ff67e4889a11` verified the
existing internal loopback data-release endpoint, authenticated without emitting
its credential. Active release:
`5c318a56abe766f1e74e41ac2a84c7efd80d5d612649af88d99dda15b46f3e84`.
Only `canonical` is active, generation
`def80071e34055dd536687757ad5f920e2a8083da0a830cc6dcf7b7709fe660f`.
All 14 tables are readable; Fundamentals is ready with 5,419 fact companies.

The S3 `fact-os/published/active.json` pointer is absent, despite that separately
installed canonical release. This must be reconciled against a real API ACK;
do not bypass the expected-previous-release fence on the next installation.

Strategy still uses the static `thesisforge-20260920-v3/strategy.sqlite` and
`composition.sqlite` release. Public health is **failed**, with 0/59 required
Guru manager/window curves currently displayable (freshness/coverage checks).
Do not hide these failures, cosmetically refresh timestamps, or claim Sharadar
has refreshed independent SEC evidence or all saved backtests.

## New safe fixes and tests

Regression tests first reproduced missing pre-download capacity checks and
duplicate immutable payload storage. Implemented:

- Writer preflight: 8 GiB estimated additional bytes + 8 GiB reserve, recorded
  before credential resolution/source fetch; no retention cleanup to force pass.
- Whole-candidate API capacity check, with 1 GiB reserve; unchanged, verified,
  read-only bytes use hardlinks from the exact previous public group.
- Corrupt/writable/out-of-namespace prior files cannot become reuse candidates;
  insufficient space leaves the active pointer and old data intact.
- ACK checks all candidate group generations plus complete canonical coverage;
  publisher rejects incomplete/stale group ACKs before changing S3 active state.
- AI/13F validators run with the real `webapp` identity.

Fresh tests: Fact OS **207 passed**; installer/IaC/storage scripts **13 passed**;
Node release-reader tests **13 passed**; performance contracts **60 passed**.
Full Node suite passed after granting localhost test bindings: **1,659 passed,
15 skipped, zero failed** (1,674 total). The first sandbox run had 66
`listen EPERM` failures; the identical suite was rerun, not weakened.

Full Fact OS storage audit passed, raw duplicate bytes **0**. Receipt:
`data/fact_os/audit/storage-layout-20260923-pipeline-reverify.json`.
The npm fixed `storage-layout-latest.json` output already existed; the audit was
rerun to a new dated receipt without overwriting prior evidence.
Repository-wide storage layout still has the same **11 existing findings**:
legacy valuation source database and ten retired sibling directories, some
holding private recovery material. Nothing was deleted to force a pass.

## Current manual re-verification and blockers

A fresh 14-table `--stage-only` run was dispatched through SSM:
`15172e16-7a63-4430-99e8-1cded5f6dd16`. It began around 09:29 UTC;
`2026-09-23T09:40:00Z` is its manually supplied run label, **not** a Scheduler
trigger. Tickers already accepted 74,269 retained rows dated 2026-09-23.
Other source/build final results are pending at this checkpoint. Outputs go to
the existing CloudWatch worker log group and `audit/pipeline/` receipts.

API root `vol-04879aae99266e0e9` is still unencrypted, approximately 8.9 GiB
free. No fresh encrypted rollback copy/restore acceptance exists for this
cutover. The earlier rejected unencrypted snapshot action was not retried.
Authorization for encrypted-storage maintenance (possible backend interruption)
has been requested; no instance/volume was stopped, replaced or deleted.

Do not enable the daily schedule until that safety boundary, remaining
consumer adapters, S3/API pointer reconciliation, installation/ACK and complete
online acceptance are resolved. A clean release source must also be assembled
without resetting/stashing/committing another task's changes. First scheduled
acceptance remains pending even after a successful manual run.
