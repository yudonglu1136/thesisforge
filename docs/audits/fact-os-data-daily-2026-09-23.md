# AWS Fact OS daily data automation

Scope: the operator explicitly deferred backtests. This change automates public
Fact OS ingestion and validated derived staging, **not API activation**, reviewed
valuation publication, personal strategies, private portfolios or broker/NAV.

## Implemented and tested

- Worker code: `032da37314e9694fa0048bbda9e6384882a143c3`, committed and pushed to
  trunk. Runtime `/opt/fact-os/releases/032da37`; old `d6ecf19` retained.
- Explicit `aws-data-daily` profile: all 14 tables and six automatic groups.
  Full/manual Guru and valuation review gates are unchanged.
- Conditional `fact-os/data-ready/latest.json` is separate from serving
  `fact-os/published/active.json`. Only exact complete validated runs can advance
  it. `dataSyncStatus=verified` does not mean the website has activated data.
- Fixed SSM RunDocument version **5**, Step Functions success **DataReady**.
  No EC2 replacement, EBS replacement or secret replacement in the change set.
- Extract checkpoint regression reproduced before repair: historical leaf
  caches survived successful syncs and caused legitimate SF3 revisions to fail
  one leaf at a time. Checkpoints now resume one attempt; a successful sync or
  detected mutation starts a new attempt without deleting raw archives.
- Python: 214 Fact OS tests and 11 IaC/installer tests passed. Focused Node
  canonical-consumer / artifact tests: 14 passed.
- Full Node server suite: **1,659 passed, 15 existing skips, zero failures**
  (1,674 total). The first sandbox run hit `listen EPERM`; the identical suite
  was rerun with localhost binding permission, without weakening assertions.
- Full local storage audit passed, 20,983,487,612 logical bytes,
  **zero duplicate raw bytes**. Receipt:
  `data/fact_os/audit/storage-layout-data-daily-20260923.json`.
- Repository layout audit still reports 11 pre-existing legacy database/sibling
  findings. No database/directory was deleted and no assertion was relaxed.

## AWS and acceptance ledger

- Region `us-east-1`, stack `thesisforge-fact-os`, worker
  `i-037be49f4a4038ac4`, encrypted retained volume `vol-0ee8b8122d9f37dfe`.
- Secret reference `thesisforge/fact-os/sharadar`, fetched only in worker memory
  through its instance role. No secret value in code, archive, argv or report.
- Private artifact bucket versioning enabled; all four S3 public-access blocks
  enabled. Code archive SHA-256:
  `69fb7ed6efa8aeb56e608f874615e733554ada6af5e9d76c84b91937b8d86da2`.
  The 604,046 uncompressed bytes / 66 archive entries contain runtime source
  only, no source databases, user data or environment files.
- Worker installation SSM: `1da065c6-e5d5-4b46-a959-86f454e350b0`, success.
- Old full-mode stage run `4d1ac5cb8423de9245c420fe5268bcb6d847e172af513721cced65883ffa1ebd`
  accepted 11 tables; three SF3 tables failed verification and retained old
  facts. It was **not** daily cutover success.
- New manual acceptance execution:
  `arn:aws:states:us-east-1:378477120101:execution:StateMachine-nnBDf6aVwQto:data-daily-manual-032da37-20260923`.
  SSM `299c9f21-905c-45ba-b529-4036650717ef`, started 2026-09-23 10:37:49 UTC;
  scheduled input `2026-09-23T10:38:00Z`, trigger **manual-verification**.
  Status: **SUCCEEDED**, stopped **2026-09-23 11:35:40 UTC**, approximately
  58 minutes. Run receipt
  `579f705726cc2ea6b8c0fcc22ae5659d1d4cd506785d5135b64d8197d6c03fa4`;
  `failedSources=[]`, all six tasks succeeded or unchanged.
  Candidate release
  `6b56be838529aa657aff1400fddebc7e1f6004f48ab1b764f1cee0b762ce3b58`.
  This is real **manual data-only** acceptance, not a scheduled run or API ACK.
- Daily schedule **ENABLED**: `07:30 Asia/Riyadh` / `04:30 UTC`. Stack
  `UPDATE_COMPLETE`; fixed RunDocument version **5**. Enable change set
  `enable-data-daily-032da37` modified only `DailySchedule`, with no replacement.
  First genuine scheduled acceptance **pending** until **2026-09-24 07:30
  Asia/Riyadh**. Its input must contain `trigger=scheduler`; today's manual
  success is not substituted for that future evidence.
- CloudWatch `/thesisforge/fact-os/worker`, 30-day retention, failure/timeout
  alarms and encrypted dispatch DLQ. No external email/paging destination yet.
- Independent post-run acceptance SSM
  `f87f9d73-bb7a-4408-9f79-61d95ac47cbb`: **Success**. At
  `2026-09-23T11:37:42.923703+00:00`, checked matching local/S3 run receipts,
  all six manifest content hashes, generation identities and **358 unique
  remote objects' byte sizes, SHA-256 metadata and encryption**. The builder
  and publisher had already verified the actual local file bytes before upload.
- Full AWS public storage audit **passed**:
  `/var/lib/fact-os/data/audit/storage-data-daily-20260923.json`;
  30,499,097,245 logical bytes, zero duplicate raw bytes, 7,454,569,160 retained
  Parquet bytes. Immutable snapshots can share physical inodes. Actual volume
  free space was 78,647,476,224 bytes after this run. No data was deleted.

### Real source acceptance on 2026-09-23

All 14 source status records report `backfill_complete=true`, a successful run
today and no current source error. Dates below describe source coverage, not
artificial daily dates for quarterly holdings.

| Source | Result | Canonical rows | Latest source date |
| --- | --- | ---: | --- |
| tickers | unchanged | 74,269 | 2026-09-23 |
| stocks | unchanged | 45,374,877 | 2026-09-22 |
| funds | unchanged | 15,651,380 | 2026-09-22 |
| fundamentals | unchanged | 3,218,498 | 2026-09-22 |
| daily | unchanged | 39,837,568 | 2026-09-22 |
| actions | unchanged | 704,340 | 2026-09-22 |
| holdings | ingested | 81,204,493 | 2026-06-30 |
| holdings_ticker | ingested | 670,129 | 2026-06-30 |
| holdings_investor | ingested | 306,485 | 2026-06-30 |
| events | unchanged | 2,531,985 | 2026-09-22 |
| insiders | unchanged | 11,556,607 | 2026-09-22 |
| descriptions | ingested | 384 | no dated series |
| metrics | unchanged | 56,135 | 2026-09-22 |
| sp500 | unchanged | 61,692 | 2026-09-22 |

The SF3 refresh verified 99 complete queries / three quarter windows, accepted
7,256,835 input rows and retained the oldest 2013-06-30 history. Canonical
holdings grew by 988 rows; ticker and investor summaries grew by 12 and four.
This is a real verification of the checkpoint repair, not just a mocked test.
Fundamentals reported `invalid_pit_period: 25` in the source-quality receipt;
successful ingestion does not assert that every vendor period is valid.

### Accepted derived groups

| Group | Result | Generation |
| --- | --- | --- |
| canonical | succeeded | `a2eafbdb976b005e2a1334a7ce9bdc5a774029983f7fd65c61eb3bcc6e213744` |
| ai_insights | unchanged | `abcb9fcbaa67328ee2792d188e2e04a576686d7baecffe61971278128e1192e9` |
| institutional_13f | succeeded | `048557caf2d1f0b4717633fac5260eca2fd94533b5d39a9aa721fa5a21224643` |
| public_observations | unchanged | `c584a9368d1ed834fdfcb6bce10375a07c7be1273f3f5cefdf08a6f24e82bfa1` |
| research_inputs | succeeded | `0e87c60b1470a69b3c47a667e7f03ea27747ab938cface4de5452119c0821ca8` |
| strategy_inputs | unchanged | `05e0fa8b31a7db5ebcd6d21399891877fd1b05fc4a2388b66df740430df2cf42` |

The source changes caused the relevant groups to rebuild. Unchanged AI,
quote/quality and strategy groups reused validated generations. Research and
Strategy groups are canonical input releases, not personal backtest/model
publication. Guru curves and reviewed model publication were deferred.

## Other production surfaces

Both public domains were checked and resolve to the same Ready Vercel deployment
`dpl_CRYeVox9sKWf7ZyW8cr7zrcJ6vFy`,
`https://thesisforge-46eny3xkq-yudonglu1136s-projects.vercel.app`.
This was the existing Git integration reacting to the code push. Daily AWS data
updates do not build the frontend.

API deployment, active data pointer and private stores remain unchanged. Existing
API Guru-curve health failures are explicitly outside this data-only acceptance.
The API's existing public auto-refresh switches for Guru and dividends are
already false; no broker/NAV timer was stopped. The local duplicate public-data
writer has been retired: existing automation `thesisforge` was changed to
**ThesisForge AWS 数据日更验收**, a read-only 10:00 daily check. It cannot run sync,
backfill, deploy, activate the API or GC; the existing failed-runs-only
notification preference was retained. This desktop follow-up is supplemental:
the AWS Scheduler and worker run independently of the local computer.

## Maintenance and rollback

See `docs/fact-os-pipeline-operations.md`, daily data-only contract. On a source
failure keep prior validated facts, diagnose that table and start a new schedule
identity; do not relabel the failed receipt. For an upload-only failure resume
the same profile/time and exact receipt, without refetching sources. Keep raw,
saved snapshot pins and rollback generations. The 16 GiB free-space preflight
must not be bypassed. No auto-GC expansion is included.

To suspend this data workflow, set the existing stack ScheduleState to DISABLED;
do not disable broker/NAV jobs. With no writer active, the retained old worker
code directory permits a symlink rollback, but re-enabling must use a compatible
fixed RunDocument version: old code does not recognize `--data-only`.

Daily windows do not establish complete capture of arbitrarily old revisions
in tables without `lastupdated`; SF3 refreshes the recent three quarters.
Quarterly holdings dates remain quarter-end, never falsely relabeled as daily
transactions or exact SEC disclosure dates.
