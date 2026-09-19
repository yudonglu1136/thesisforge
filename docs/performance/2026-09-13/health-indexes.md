# Exact health-summary indexes

This is a health-worker/database-read optimization, not a claim that production
data is ready. The complete enabled-manager × 5Y/10Y matrix and all method,
security-master, policy, freshness, strict audit and proxy linkage gates remain
unchanged. The tested historical fixture correctly reports 0/64 displayable.

## Diagnosis

Read-only profiling used `scripts/profile-public-health.mjs` with the same
8 MiB SQLite page cache, disabled mmap and read transaction as the worker. It
never imports a writable database initializer. Local candidate-v6 has 533
valuation snapshots, 4,463,919 prices and 105 stored strict/proxy payloads read by
the full matrix (56,468,540 bytes).

| Operation | Original local ms | Indexed local ms |
| --- | ---: | ---: |
| Valuation JSON source-date aggregate | 2,865.17 | 0.03 |
| Price count and date aggregates | 1,597.39 | 12.15 |
| All 14 table summaries | 4,498.76 | 41.97 |
| Full 64-item matrix | 427.26 | 423.60 |
| Complete health build | 4,928.39 | 467.57 |

The deployment operator separately measured the old AWS path at 13,049 ms:
valuation 5,165 ms, prices 3,439 ms, full matrix 4,240 ms. That exceeds the
unchanged eight-second deadline. These remote numbers are diagnostic baseline
evidence only; optimized AWS timing still requires post-install verification.

## What changes

Four optional SQLite indexes cover the *existing* valuation generated-at/source
expression and price date/updated-at expressions. Scalar COUNT/MAX subqueries
allow exact covering-index counts and MAX seeks instead of scanning multi-GB
JSON/price tables. Dates are not sampled, inferred from export timestamps or
cached. SQLite updates the indexes in the same transaction as inserts,
corrections and deletions. Old/missing/incompatible-index schemas retain the
original aggregate implementation. Runtime requests remain read-only.

No matrix, worker limit, cache TTL, endpoint payload, auth or portfolio logic is
changed. Index creation is explicit operator maintenance, not a startup hook.

## Reproducibility and validation

Use Node v22.22.3, SQLite 3.51.3. The indexed disposable snapshot is
3,228,553,216 bytes, SHA-256
`857037fb93bd2137b4638226ae71298cdb51b299bf500d163239230595fb9200`.
It was cloned from the immutable candidate-v6 snapshot; only the four indexes
were added. Approximate file growth is 231 MB (221 MiB).

From the repository root:

```sh
node scripts/profile-public-health.mjs "$PWD" /absolute/path/readonly-snapshot.sqlite
node scripts/benchmark-health-indexes.mjs "$PWD" /absolute/path/indexed-snapshot.sqlite /absolute/path/indexed-snapshot.sqlite
node --test server/*.test.js
npm run test:performance
```

The benchmark executes the original `47973e1` summary code versus the new code
on the **same byte-identical indexed database**, using fresh 256 MiB workers,
the unchanged eight-second limit, three runs of 60 requests at concurrency 20.
Requests coalesce normally: three actual database audits per run. TTLs are zero
for the benchmark so all three waves execute. The as-of instant is fixed.
OS cache warming is not disabled; per-run timings must be retained, not only
the fastest run. Complete response bytes and all business fields are checked.

Final isolated same-file run: before P95s 2,964.67 / 1,061.12 / 1,165.96 ms;
after P95s 218.59 / 209.19 / 221.21 ms. Median P95 improves from **1,165.96 to
218.59 ms (81.25%)**. No backend test suite was running during this final
measurement. Earlier exploratory runs are not used for this final aggregate.

Complete response SHA-256 is
`cbcb23e3c3049b6a42710549f891f1461ba0eb1d3f91cb38c049ca2de0b455a1`.
Response size is 57,461 bytes; gzip is 5,669 bytes. All 64 matrix outcomes are
identical. The fixture fails health for actual data reasons, not a worker
timeout. Results are retained in `health-index-results.json`.

Validation completed: 1,263 backend tests and 53 existing performance tests
passed. Tests cover legacy fallback, exact scalar results including null/empty
dates, updates/deletes, empty tables, malformed JSON, atomic rollback,
incompatible-name rejection, idempotence, preserving private BLOBs and schema,
read-only startup behavior, eight-call coalescing and responsive anonymous auth.

This targeted benchmark does not substitute for the repository's separate
seven-route `check:performance` release contract. No production post-migration
performance or complete deployment approval is claimed here.

## Explicit maintenance / rollback

`scripts/install-health-summary-indexes.mjs --database /exact/path.sqlite`
defaults to read-only inspection. `--execute` additionally requires the exact
current inode/device, a non-root database owner, a fresh verified user-backup
receipt/generation and completed rollback EBS snapshot acknowledgement, using
the same gates as the approved WAL maintenance tool. Lock waiting is capped at
one second and the child process has a two-minute wall deadline. Page cache is
8 MiB, temp sorting is file-backed, WAL autocheckpoint is 1,000 pages and retained
journal size limit is 64 MiB; active readers can still temporarily grow WAL.

All four CREATE INDEX statements run in one transaction. Unexpected schema or
malformed source JSON aborts installation. Existing index names are never
overwritten. Only indexes are added; application rows are never updated.
Runtime does not require them, so reverting this code needs no data rollback.

Run the migration only in the approved maintenance window after checking disk
headroom. If it times out, preserve all database/WAL/journal files and inspect
with SQLite; do not delete sidecars or retry blindly. Root must verify the
actual AWS bounded worker after installation and still require the full current
Guru matrix/data-quality gates before declaring release readiness.
