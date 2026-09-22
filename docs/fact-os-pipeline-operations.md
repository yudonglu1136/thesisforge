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
- API install root: `/var/app/data/fact-os`; immutable public read releases only.
  API leases: `/var/app/data/fact-os-leases`, owned by `webapp`, mode 0700.
- `fact-os/authority/*` in private S3 contains migration-only licensed raw and
  canonical objects, metadata rows and checksums. API IAM cannot read this prefix.
- `fact-os/published/*` contains allowlisted immutable read artifacts. Manifest is
  uploaded last. The API role is read-only on this prefix.

## Commands and receipts

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
