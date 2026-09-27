# Fact OS daily synchronization repair — 2026-09-27

## Confirmed production incident

The enabled 07:30 Asia/Riyadh schedule ran on September 27. Stocks, daily and
holdings failed with HTTP 429; funds failed coherent-extraction verification.
The previous complete data-ready release remains September 25. All six group
manifest checksums and generations matched its receipt. No API global active
pointer exists; Research uses a separately pinned scoped release. Neither
data-ready nor recent cache creation proves automatic website freshness.

## Implementation

- Shared request admission/cooldown, conservative default worker concurrency,
  and meaningful bounded backoff for rate limits without a provider hint.
- Typed source-mutation failure and one re-extraction attempt, retaining the
  full hash verification and immutable old source history.
- Explicit `--data-only --activate-daily` option reuses installation, live ACK
  and publication fencing; default data-only behavior remains unchanged.
- Tests cover shared cooldown, missing/long Retry-After, bounded source retry,
  schema failures, explicit activation opt-in, activation failure and source
  completeness. No live source credentials are used in tests.

## Gates and remaining scope

Verification: `python -m unittest discover -s fact_os -t .` passed 260 tests;
the focused sync/worker suite passed 46 tests. `git diff --check` passed.

The production private-data backup/restore permission gate remains unresolved.
No global activation is authorized by a local test result. The existing API
install target must be verified after EB replacement, scoped Research pointer
selection reviewed, and full public-analysis warmup passed before opting in.
CloudWatch alarms currently have no notification destination; the only existing
SNS topic is billing-specific and was not repurposed without approval.

Local Fact OS storage audit passed with no duplicate raw bytes. The repository
layout audit still reports the eleven pre-existing legacy paths; none were
deleted or hidden. The package's `audit:fact-os-storage` fixed output name
already existed, so this run used the append-only receipt
`data/fact_os/audit/storage-sync-repair-20260927.json` instead of overwriting it.

Backtest/model publication and private broker jobs are not added to the public
daily job. Deployment and actual scheduled acceptance must be recorded
separately; this document alone does not assert either.

## AWS worker installation

After explicit authorization to upload code, pause the public schedule, verify
and restore/rollback, the worker-only release was installed on the existing
instance. No instance/volume expansion, API activation or private account
operation was performed.

- Runtime commit: `48dc2c1cba6f24e21a0337fd74215663b1d2a287` (sync fix
  `817a0fa` plus portable synthetic-capacity fixtures).
- Code archive SHA-256:
  `54a1a9e66a4c8f0b84d03a56d8107fe096faf3abc4d48adfa8a24e21be3e1e69`.
- Install command: `9030af35-d9c4-46b6-8cc4-da1e28b30b5b`; 46 tests passed
  on the actual worker using its Python 3.12 runtime before the atomic switch.
- Current code: `/opt/fact-os/releases/48dc2c1`; rollback code retained at
  `/opt/fact-os/releases/032da37`.
- Manual execution: `worker-upgrade-48dc2c1-20260927`; source command
  `adb85a56-b0e6-4056-b8ba-e2c4ce043be9`.
- Actual start: `2026-09-27T19:35:04.328Z`. Its manually supplied schedule key
  is `2026-09-27T20:00:00Z`, not its actual start time and not a Scheduler event.
- The first install attempt stopped before switching because the host default
  Python was incompatible with the existing SDK; the subsequent test run
  exposed fixture dependence on `/tmp` capacity. Production disk gates were
  preserved; low-capacity rejection remains explicitly tested.

Final source/group verification and schedule restoration are recorded in the
small local receipt `data/fact_os/audit/worker-upgrade-48dc2c1-20260927.json`.
Until that receipt is terminal, the manual data acceptance remains pending;
the next actual scheduled run remains a separate acceptance requirement.
