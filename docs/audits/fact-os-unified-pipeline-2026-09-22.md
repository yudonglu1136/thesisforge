# Unified AWS Fact OS pipeline — implementation and partial rollout record

Status recorded on 2026-09-22. **Not a completed production cutover or a scheduled acceptance.**

## Released code and deployed infrastructure

- Core pipeline: `69eda733f19b3777315567a917811aa46b2a02bf`.
- Quote/quality consumers and cache fencing: `ac4e6c164a98c7845d60ff83b48cc49243c710ef`.
- Installed immutable worker code: `d6ecf19020936cd56d17592193da4176020520b3`.
- Monitoring IaC: `96dba9fb83add8d5750db2713bba7fc7abf4f00a`.
- AWS region: `us-east-1`; stack: `thesisforge-fact-os`.
  Monitoring change set `fact-os-monitoring-96dba9f` reached `UPDATE_COMPLETE`;
  it did not replace the running worker, data volume or secret.
- Worker: `i-037be49f4a4038ac4`; encrypted retained gp3 volume:
  `vol-0ee8b8122d9f37dfe`, 100 GiB, mounted at `/var/lib/fact-os`.
- Worker install command: `e54d0cf3-419a-431b-953f-62ba6fbf9fab`, verified `Success`.
- Worker code object: `fact-os/code/d6ecf19/worker.zip`, SHA-256
  `35644863ddaaf250eb9eb762988d4312733c1d33d5116b761a7d77988bdfc9c0`.
- Secret reference: Secrets Manager `thesisforge/fact-os/sharadar`; the exact
  secret is resolved by the worker instance role in memory. No value is recorded
  here or passed in shell arguments. The API role cannot read the authority prefix.
- Scheduler: `thesisforge-fact-os-daily`, **DISABLED**, `07:30 Asia/Riyadh`.
- Fixed SSM document versions: RunDocument `4`, InstallDocument `1`.
- State machine: `StateMachine-nnBDf6aVwQto`.
- Worker log group: `/thesisforge/fact-os/worker`; encrypted dispatch DLQ:
  `thesisforge-fact-os-DispatchDlq-tj34Fe4pqkpn`. The schedule remains disabled.
- Production API is **unchanged**: EB `thesisforge-api-prod`, version
  `sector-c7b4026`, verified Ready/Green. No new Fact OS active release ID exists.
- No frontend deployment or domain change was performed for this pipeline.

## Authority bootstrap — actually verified on AWS

Migration `81d1c529e87f6a1314540a120e27ff0ce0f2920095d0844b6a5acb1b41f89d57`
uploaded and restored 738 verified objects, 13,803,012,188 bytes. This includes
immutable raw archives and retained canonical generations, not a copied private
or runtime database. Only allowlisted metadata rows were imported. The import
command `fc3c85a9-1931-4923-9c47-2971aabf251c` completed successfully. Initial
post-import free space was approximately 80 GiB.

All 14 source tables below had `backfill_complete=true` after AWS restoration.
These are **bootstrap counts**, not claims that the later live refresh completed.

| Table | Restored rows | Latest source date |
|---|---:|---|
| tickers | 74,258 | 2026-09-21 |
| stocks | 45,367,234 | 2026-09-21 |
| funds | 15,644,026 | 2026-09-21 |
| fundamentals | 3,218,331 | 2026-09-21 |
| daily | 39,830,663 | 2026-09-21 |
| actions | 702,545 | 2026-09-22 |
| holdings | 81,202,367 | 2026-06-30 |
| holdings_ticker | 670,111 | 2026-06-30 |
| holdings_investor | 306,476 | 2026-06-30 |
| events | 2,531,745 | 2026-09-21 |
| insiders | 11,555,542 | 2026-09-21 |
| descriptions | 384 | Not a dated observation table |
| metrics | 43,775 | 2026-09-21 |
| sp500 | 61,189 | 2026-09-21 |

Total restored rows: 201,208,646. Raw archives were not deleted.

## Actual live AWS run — still pending

- Manual SSM command: `2703457b-ea30-4e48-81c5-96c3cdfbf008`.
- Mode: `--stage-only`. It performs real native fetch, ingestion, builds and
  private S3 candidate upload, but cannot install or activate production data.
- Worker log: `/var/lib/fact-os/verification/pipeline-stage-20260922.log`.
- Receipts: `/var/lib/fact-os/data/audit/pipeline/` and private S3 `fact-os/runs/`.
- Last inspected phase at approximately 15:51 UTC: native ticker sync succeeded
  (74,245 input rows, 74,258 retained rows, max date 2026-09-22); stock extract
  had reached 259 complete query leaves and 1,623,548 rows. Extract progress is
  **not** an accepted catalog, completed source sync, or publication.
- Other live source refreshes and all live AWS derived builds remain pending
  until the final run receipt is inspected. A manual run cannot satisfy the
  first scheduled-trigger acceptance.
- Stage-only deliberately exits 2 and records `staged_not_activated`; inspect
  source/task statuses separately rather than treating that code as either a
  full production success or proof of a failed source fetch.

## Consumer and publication-group scope

| Group | Implemented behavior | Current acceptance boundary |
|---|---|---|
| canonical | Pinned 14-table read release, checksum/repository validation | AWS bootstrap verified; fresh build/API activation pending |
| ai_insights | Existing builder/packager, stable financial IDs, dependency/config fingerprints, archived generations | Offline tests passed; live AWS build pending |
| institutional_13f | Existing all/active builders, seven-table atomic group, matching quarter matrix | Live AWS build pending; not a strict SEC/Guru refresh |
| research_inputs | Versioned canonical input vector and release-aware Fact OS/cache reads | API production activation pending |
| public_observations | Existing annual quality formulas plus a 45-day quote projection | Real local build verified; live AWS build pending |
| strategy_inputs | Versioned canonical input vector | Full legacy Strategy/CTA publication adapter still requires implementation/review |
| guru_strict | Explicit independent SEC and reviewed manager/window-matrix gate | Blocked; external adapters not yet attached |
| valuation_candidates | Reviewed model-release gate; never auto-publishes models | Blocked; reviewed-model adapter not yet attached |

The real local observation projection contains 196,073 quotes and 175,277 annual
quality rows, 142,970,880 bytes, latest price date 2026-09-21. SHA-256:
`351b17f457d5c7efd1b5b8a09de0b5d04231b0ce56d2a51e3ecca4acdb0e48d0`.
Full price history stays in canonical Fact OS. Personal strategies, models,
observations, broker credentials and NAV records were not rewritten.

## Verification performed

- Python Fact OS suite: **200 passed**.
- Node server suite with isolated default test database: **1,655 passed,
  15 skipped, 0 failed** (1,670 total).
- Performance contract suite: **60 passed**; not a production latency claim.
- IaC tests: **5 passed**. Separate installer/storage boundary tests passed.
- Explicit regressions: firstPriceDate dependency invalidation; stable financial
  evidence identity after price-only changes; no-op manifests; revision lineage;
  committed-catalog recovery; pinned retry inputs; optional-source failure;
  atomic publication/fencing; corrupt artifacts; actual-user probe coverage;
  concurrent reader-cache generation changes; isolated spill directories; and
  stage-only never invoking API installation/activation.
- Three earlier Node suite failures were `database is locked` during shared
  default SQLite initialization, not failed business assertions. The relevant
  33 tests and then the full suite passed with `SQLITE_DB_PATH=:memory:`. No
  assertions were removed or weakened.
- Fact OS storage audit passed, raw duplicate bytes = 0. Receipt:
  `data/fact_os/audit/storage-unified-pipeline-20260922-consumers.json`.
  Physical allocation was approximately 14.7 GB; hardlinks are not double-counted.
- `audit:storage-layout` still reports **11 existing findings**: the legacy
  `valuation-pit-source.sqlite` and ten retired sibling directories, including
  private recovery/backup copies. None was deleted to force a pass.
- Source-provenance and backend packaging passed for `d6ecf19`; the package
  excludes SQLite, PIT migration payloads and the frontend. Rebuild from the
  then-current verified trunk before a later production deployment.
- No Flutter/UI change was made in this pipeline task; no new UI acceptance is
  claimed.
- Unchanged production baseline at 15:43 UTC: eight concurrent public health
  calls returned 200/healthy; unauthenticated investment-company API returned
  401. This does not verify any new pipeline data release.

## Blocking safety boundary and remaining work

The current API root volume `vol-04879aae99266e0e9` is unencrypted. A request to
create a new unencrypted rollback snapshot was rejected by the safety check;
it was not executed or retried indirectly. Short maintenance to migrate to
encrypted API storage was requested from the user and is awaiting approval.
Production activation has not been attempted. The local public schedule and
private broker/NAV jobs remain unchanged.

An optional recurring Codex follow-up monitor was also rejected pending explicit
user authorization. Permission was requested; **no recurring app monitor was
created**. The already-running AWS command continues independently. Operators
must inspect its final receipt; do not infer completion from this dated record.

Still required: finish the live worker run and resolve its real failures;
complete the external consumer adapters; establish approved encrypted rollback
and restore verification; deploy/install with the actual API UID and obtain the
live release ACK; verify online consumers; retire only duplicate public writers;
enable the AWS daily schedule; observe an actual scheduled trigger. CloudWatch
alarm notification destinations are not configured. API instance replacement
bootstrap and reference-aware pin expiry remain explicit limitations; pins are
currently retained conservatively, never raw-archive GC.

For diagnostics, resume, rollback and retention policy, see
[`docs/fact-os-pipeline-operations.md`](../fact-os-pipeline-operations.md).
