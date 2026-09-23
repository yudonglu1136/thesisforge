# Unified Fact OS pipeline operations

The writer runs independently of the API and the Vercel frontend. A successful
fetch, build or upload is **not** a successful release. Installation, an actual
`webapp` account canonical read, live API release ACK, and the fenced S3 pointer
are separate gates. No provider credential belongs on the API host.

## Runtime and ownership

- AWS stack: `thesisforge-fact-os`, region `us-east-1`.
- One `factos` writer, encrypted retained gp3 volume mounted at `/var/lib/fact-os`.
- Writer root: `/var/lib/fact-os/data`; immutable code: `/opt/fact-os/releases`.
- Secret reference: Secrets Manager `thesisforge/fact-os/sharadar`; instance role
  resolves the value in memory, never a shell argument or a logged environment.
- Schedule: `07:30 Asia/Riyadh`. The IaC default is **DISABLED**. Enable only
  after the real manual chain passes and the previous public-data job is retired.
- SSM run and install documents use explicit numeric versions. When updating a
  document, update `RunDocumentVersion` / `InstallDocumentVersion` in the stack.
  Never silently select `$LATEST`.
- Production Run Command output goes to `/thesisforge/fact-os/worker` (30-day
  retention). The encrypted Scheduler DLQ records delivery failures separately
  from execution-failure and timeout CloudWatch alarms. Notification destinations
  are not yet configured; do not describe these console alarms as paging/email.
- API install root: `/var/app/data/fact-os`; immutable public read releases only.
  API leases: `/var/app/data/fact-os-leases`, owned by `webapp`, mode 0700.
- `fact-os/authority/*` in private S3 contains migration-only licensed raw and
  canonical objects, metadata rows and checksums. API IAM cannot read this prefix.
- `fact-os/published/*` contains allowlisted immutable read artifacts. Manifest is
  uploaded last. The API role is read-only on this prefix.

## Commands and receipts

### Daily data-only contract (2026-09-23)

The operator deferred backtests. The fixed AWS daily document now passes
`--data-only`, selecting the explicit `aws-data-daily` registry: canonical,
AI Insights, institutional 13F, Research inputs, public observations (quotes /
quality), and Strategy inputs. All 14 sources and all six automatic groups must
pass. It does not build Guru curves, publish reviewed valuation models, change
personal strategies, install on the API, or mutate the API active pointer.
Full/manual runs still retain the original review gates.

Exit zero in this mode means **data ready**, not production API activation.
Private S3 `fact-os/data-ready/latest.json` is a separate conditional-write
pointer, with `dataSyncStatus=verified` and `actualApiActivation=not_requested`.
Each candidate and its validated objects remain immutable under the existing
published namespace; the run receipt still says `staged_not_activated`.
The Step Functions terminal success is `DataReady`. A stale worker, failed
source, missing group or mismatched generation cannot mark data ready. Never
use this result to declare website freshness or the Guru health matrix green.

Retry an existing validated data run with
`bin/fact-os-worker --data-only --scheduled-for <same timestamp> --resume-publication <runId>.json`.
The profile and timestamp must match. This reuses the exact snapshot without
fetching sources. A source failure requires a new run after fixing the source;
publication retry cannot turn a failed fetch into a successful sync.

Extract checkpoints now belong to one attempt, keyed by full query context,
schema and last successful sync. Successful runs cannot lend stale SF3 leaves
to the next run. A verification mutation invalidates the complete attempt;
the next attempt fetches and double-checks a new coherent set. Raw archives and
prior canonical facts remain intact.

Worker-only code releases may be built with `git archive` from committed trunk
using an explicit runtime-code allowlist. They contain no database, data tree,
credentials, frontend or uncommitted work. This is not an EB application package
and does not bypass the backend source-clean deployment gate. Retain the old
worker code directory; roll back the code symlink only while no writer is active.
Keep the AWS schedule disabled during an unverified worker upgrade. Enable only
after manual data readiness, then pause the duplicate local **public-data** job;
broker/NAV jobs are outside this cutover.

`python -m fact_os --root <writer-root> pipeline --pipeline-action plan` shows
required/optional source readiness and content/version-based invalidation.
`--pipeline-action run` and `resume` use the same validated result ledger.
Pass the same `--profile` and `--scheduled-for` to resume the **same pinned input**;
a new schedule creates a new input snapshot. Changed code creates a new plan.

`sync`, `backfill` and `import-archive` enter the same batch drain. The ingestion
transaction appends `source_change_events`; catalog recovery occurs before
planning. `pipeline_source_events` records which accepted events were planned
and consumed. A consumed source event does not imply successful publication.

Operational tables in the existing metadata DuckDB:
`pipeline_runs`, `pipeline_tasks`, `pipeline_source_events`,
`publication_attempts`. Human/machine receipts: `audit/pipeline/<runId>.json`.
The current source operational status is `sync/status.json`, not catalog identity.

The AWS entrypoint `bin/fact-os-worker --scheduled-for <ISO timestamp>` fetches
all authorized native tables, fixes the input snapshot, builds independent
groups and requests API installation. Exit zero requires a verified publication
**and** a complete successful/no-change run. Degraded groups remain explicit.
To retry only publication, pass `--resume-publication <runId>.json`; no fetch or
rebuild occurs. Failed publication retains a receipt and its last phase.
`--stage-only` performs real ingestion, builds and immutable private-S3 staging,
but never sends the API install command or changes the active S3 pointer. Its
receipt says `staged_not_activated` and its exit code is 2, deliberately not a
production-success signal. The root-owned installed `CODE_COMMIT` is recorded
separately from the task implementation fingerprint.

## Safety and rollback

Do not edit an installed Parquet or SQLite. Failed independent groups keep their
previous group references. Missing source dependencies never become zero data.
The installer validates each existing product validator before switching
`active.json`, probes with the real API UID, and restores the previous pointer
if the live ACK fails. New requests pin the new release; old requests retain
their old handles until drained. Expected-previous-release fencing rejects an
old worker; older scheduled runs require explicit operator rollback review.

For an operator rollback, select a retained, verified product manifest, verify
its file hashes and compatibility groups, and perform the same installer/read
probes using the exact current release as the fence. Restore the S3 active
pointer with its current ETag only after the API ACK. Do not change application
user stores, broker credentials, archived facts, historical models or research
records. Restore the previous EB application version independently when code
rollback is required.

Snapshot pins protect every referenced canonical partition. No automatic pin
expiry is enabled until saved-research and rollback retention reconciliation is
verified. Raw archives are never GC candidates. This conservative retention
requires capacity monitoring; it is not an unlimited-storage claim.

The worker now records `audit/pipeline/capacity-latest.json` before resolving
the source credential: an 8 GiB incremental/staging/build allowance plus an
8 GiB free-space reserve. Insufficient space fails before source fetch. This
is a conservative launch budget, not an upper bound on future supplier history;
capacity must still be reviewed as coverage grows.

The API installer budgets all candidate groups before downloading their
payloads, leaving at least 1 GiB free. Byte-identical files from the exact
previous immutable group are hash-verified and hardlinked into the new version,
not downloaded/copied again. Writable, corrupt or out-of-namespace prior files
are not reused. No archive, saved snapshot, user database or rollback generation
is deleted to pass a capacity check. Failed activation still restores only the
active pointer; both immutable versions remain available.

The live API ACK must include every candidate group at exactly its expected
generation and complete readable canonical coverage. Publication cannot treat
a matching root release ID with missing/stale group IDs as success. AI and 13F
production validators run as `webapp`, not only as root. These safeguards require
deployment of both the worker/publisher and the API installer before acceptance;
a local test pass does not mean the current production code includes them.

## Deliberate boundaries / remaining release gates

The registry separates canonical read data, AI Insights, all/active 13F and
Research/Strategy input vectors. The latter are **inputs**, not newly published
valuation models or recomputed personal backtests. Existing model releases and
saved user results stay unchanged.

Guru strict/proxy publishing requires independently accepted SEC evidence plus
the reviewed complete manager/window matrix. Valuation candidates require the
reviewed model release and its original seven-table gate. Until those external
adapters are attached, the registry reports these tasks **blocked**; it does not
pretend that Sharadar SF3 has exact acceptance times or publish unaudited models.
`public_observations` reuses the existing annual quality formulas and provides a
45-day current-quote projection. Exact canonical symbols use the existing
audited model aliases on read. Full price history stays in canonical Fact OS.
Its API handles and model comparison caches are pinned to the request release;
the historical model database is not rewritten. Strategy data-release adapters
still require separate review before claiming every consumer is on automatic
daily publication.

The current AWS install target is one explicitly configured EB instance. Before
an EB replacement/multi-instance rollout, update and verify the install target
and restore the active release on each serving instance. A green health response
alone is insufficient. First scheduled acceptance is pending until the actual
Scheduler execution, source receipt, builds, install and API ACK are inspected.
