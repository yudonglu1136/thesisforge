# Rule portfolios: atomic bundle implementation, not deployed

This receipt supersedes only the implementation checklist in
`rule-auto-refresh-progress-2026-10-02.md`. It is **not** a scheduled or
production strategy activation receipt.

## Implemented

- Offline `scripts/build-rule-daily-bundle.mjs` pins a canonical catalog and
  an exact prior curve/ledger bundle (or the explicitly supplied bootstrap
  ledger). It retains published marks and rejects a changed input catalog.
- `rule-portfolio-bundle-v1` contains all market, S&P 500 and QQQ-disclosure
  universes at one common observed cutoff, each paired with its exact compressed
  P&L ledger. Each file is checksummed and synced; the manifest is written last,
  then the staged directory is renamed. Conflicts never overwrite prior output.
- Validation replays daily NAV from the recorded price marks and checks range
  reconciliation and distribution counts. Missing or inconsistent members abort
  the complete bundle. Identical inputs targeting the same output are a no-op.
- Research API strategy loaders and public-analysis workers can consume the
  request-pinned strategy bundle. A required bundle never falls back silently
  to the old committed curve or an independently rebuilt ledger.
- Installer validation and the live public-analysis ACK check the actual
  snapshot identities, ledger identity and cutoff for all three universes.
  Old-date cached results cannot pass a new bundle activation.
- An append-only quarterly adapter accepts source-bound packets emitted by the
  existing selection builder. It enforces consecutive quarter clocks, actual
  next-session execution and existing allocation rules. It does not generate
  those packets by itself. Unknown future corporate actions remain blocked.

## Verification

- Node full server suite: 1,766 passed, zero failed, 15 skipped (1,781 total).
  A sandboxed attempt failed to bind localhost; the permission-enabled rerun
  above passed. No assertions were removed.
- Subsequent targeted public-analysis suite: four passed, including the new
  old-cutoff ACK rejection test. Bundle/quarter tests passed after adding
  manifest source-hash validation and filesystem sync operations.
- Python Fact OS suite: 262 passed.
- Installer/publication targeted Python suite: 27 passed.
- Transport/cache performance regression suite: 60 passed. This is not a
  production-latency benchmark.
- Full Fact OS storage audit passed: 20,986,661,953 bytes, zero duplicate raw
  bytes, 4,948,907,099 retained Parquet bytes. Receipt:
  `data/fact_os/audit/storage-rule-bundle-20261002.json`.
- Storage layout still reports the same 11 legacy findings. No databases,
  archives, retained generations or private accounts were removed or modified.

## Not complete / not activated

The production registry still emits `strategy_inputs` as an input vector.
This change deliberately does not silently change that contract while the
October 2 scheduled worker is running. The following are still required:

1. Pin the previous published bundle as a planner dependency, with correct
   no-new-session reuse and restart semantics, then call the bundle builder
   from the existing single-writer daily pipeline.
2. Install the original feature adapter as versioned runtime code and generate
   the new-quarter selection packets from pinned inputs. Dated DGS10 rates and
   genuine QQQ security-identity revalidation must be added; neither may be
   replaced by relabelled older metadata.
3. Stage the actual October quarter bundle, validate all six strategy curves
   and their ledgers, install on AWS and obtain live API ACK before switching
   the scheduled worker. Retain the original schedule/code for rollback.
4. Verify a real Scheduler-triggered build/install/ACK. Manual candidates and
   local tests do not satisfy this acceptance.

Read-only AWS inspection found execution
`056abf33-481d-40a3-b204-3b619a77c829` started at
2026-10-02 07:30:34 Asia/Riyadh and was still RUNNING at inspection.
No scheduled success is inferred. No scheduler, current worker, EB release,
API pointer or S3 published pointer was changed by this implementation.

The website strategy date is therefore not claimed to have advanced. The
previous September 30 candidate builds remain staging-only evidence.
