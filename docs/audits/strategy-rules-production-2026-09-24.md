# Strategy rule portfolios — production verification

## Delivered scope

Code commit `3c12a8dc3d92d7bb264aec902b261c8491ad2799` was pushed to `trunk`
and deployed on 2026-09-24. The original Strategy builder remains the default;
the Rule portfolios tab provides Quality Rank Top 10 and an Ackman quantitative
proxy, daily comparison against SPY, drawdowns, quarterly targets and score/source
evidence. This is not certification of the entire older Strategy/Guru audit epic.

## Release identities and recovery

| Component | Verified production release | Previous rollback release |
| --- | --- | --- |
| Vercel `thesisforge` | `dpl_CkW8qr9Gxr6kF2W99rU4VneWjikB` — `thesisforge-8n5f6q732-yudonglu1136s-projects.vercel.app` | `dpl_7E7hDTrPckQYswsEGxT4i4QLKYxh` — `thesisforge-8aqr2glgp-yudonglu1136s-projects.vercel.app` |
| EB `thesisforge-api-prod` | `strategy-rules-3c12a8d`, Ready / Green / Ok | `ai-contributors-c6c79f3` |

Both public domains were inspected individually and resolve to the same Ready
Vercel deployment. Their downloaded `main.dart.js` hashes match the tested build:
`61b4fa97d20523692a9b02a747aa89b647706ee64684ba79a07c891c5e7c289e`.
Production auth bypass is disabled. No DNS, CORS, database-path, credentials,
scheduler, private portfolio or data-activation configuration was changed.

Backend bundle: private S3 `releases/strategy-rules-3c12a8d.zip`, SHA-256
`151179d0ea49d3a203e3c7f5eeb4897865a80d5c5a9c39cfe9d70ab8bb8a8c8b`.
The unchanged packaging guard ran against a clean, bounded tracked-source export
of the exact committed SHA. The unrelated dirty backtest engine and research files
were not committed or packaged. No database or complete Fact OS tree was copied.

Rollback is code-only: restore the previous EB application version and promote
the previous Vercel deployment to **both** aliases. Keep current user stores and
published data untouched. The previous releases remain available; rollback was
not necessary for this release.

## Fresh checks

| Check | Actual result |
| --- | --- |
| Clean committed Node suite | 1,700 passed, 15 skipped, zero failures |
| Full Flutter | 588 passed, 32 failed; exact same failure-name set reproduced on `868a5f0`, zero new failures |
| Analyzer / i18n / production build | Passed |
| Performance regression suite | 60 passed |
| Fact OS storage content audit | Passed, zero duplicate raw bytes |
| Repository storage layout | 11 existing findings, unchanged; no databases or retired directories deleted |
| Public health | 8 concurrent requests per host (apex, www, backend), all HTTP 200 / `ok:true` |
| Auth / private namespace | Investor-style API without credentials: 401; public `/api/internal/health`: 404 on all three hosts |
| Actual API user | UID 900 read and validated the installed snapshot, hashes, metrics and historical cutoff |
| Snapshot errors | Wrong snapshot 409; invalid date 400; early date explicitly unavailable |
| Authenticated production UI | Default builder, both rule portfolios, daily curves, drawdown, historical quarter, evidence; EN/ZH desktop and 390x844 checked |

The production health matrix preserves 57/57 displayable Guru manager/window rows
(23 strict and 34 explicitly labelled proxies), 533 valuation rows and all 14
required SQLite tables. **Health is serviceable `stale`, not fully healthy**:
the market-price module still reports 2026-09-18, as it did before this code
release. Other health modules remain healthy. Initial eight-way apex health max
latency was 4.615s; warm www and direct-backend checks were under 0.74s. This is
an availability check, not a general production performance guarantee.

Vercel's inspected error-level records were Node `DEP0169` URL-parser deprecation
warnings on successful HTTP 200 requests, not a claim of zero platform warnings.
The old Flutter failures remain in Discover/Research/Portfolio files; details and
fresh logs are retained locally at `data/fact_os/audit/strategy-release-20260924/`.
The original delivery's 1,703 Node passes included unrelated working-tree tests;
the publishable clean source has 1,700 passes. No assertions were removed.

## Data boundaries

Snapshot SHA-256:
`6f800cc44e5239b362451feb1b472625792e04236b4a6b00d28cdc6de2c7eb5b`.
Source generation:
`134e95b9d4e40564d3b3af62f177f98a80fb8df4ac30f1c79a8504d870e0ca29`.
Coverage is 2023-01-03 through 2026-07-01: 876 daily observations, 15 quarterly
selections and 14 completed return windows per portfolio. This is a fixed,
versioned research artifact, not a newly enabled daily strategy publisher.
It uses current-vintage facts filtered by original availability dates, not strict
archived-vintage PIT. It is neither actual Ackman fund performance nor validated
alpha. Saved user strategies are untouched.

## Separate AWS daily-sync verification: failed, not accepted

The real Scheduler trigger at **07:30 Asia/Riyadh on 2026-09-24** ran, but execution
`606ab4a7-48ae-44e7-8e10-a8bbc28d81da` failed at 08:34 Riyadh with
`FactOsDailyDataNotVerified`. `holdings` ingestion hit Sharadar HTTP 503; the other
13 sources completed/retained unchanged data. Canonical and institutional-13F
tasks were blocked by the missing required dependency; AI, public observations,
Research inputs and Strategy inputs built successfully, but that does **not**
make the complete publication successful.

The S3 data-ready pointer correctly stayed on the prior verified run
`579f705726cc2ea6b8c0fcc22ae5659d1d4cd506785d5135b64d8197d6c03fa4`.
That receipt explicitly says `actualApiActivation: not_requested`; data readiness
is not website activation. The failure alarm did enter ALARM at 05:35:56 UTC,
then returned to OK as its window expired. Current alarm OK is not run success.
Dispatch DLQ was empty and worker free space was about 70 GiB.

This check was read-only: no retry, sync, backfill, backtest, scheduler change,
secret-value read, API data activation or GC. Full receipt:
`data/fact_os/audit/aws-daily-monitor-20260924T083000Z.json`.
Today's all-14-table scheduled acceptance remains **failed**; do not report the
whole daily pipeline as problem-free because the Strategy code release succeeded.
