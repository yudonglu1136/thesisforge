# Daily source ingestion versus website activation — 2026-09-28

## Live evidence

- Scheduler is enabled at 07:30 Asia/Riyadh. Execution
  `9e6ab9ed-48c5-4937-812f-0b07a5c84df5` has `trigger=scheduler`, started
  04:30:34 UTC and ended successfully at 06:50:50 UTC.
- Its worker receipt explicitly reports `staged_not_activated` and
  `actualApiActivation=not_requested`, candidate
  `1ba553a7518306e03d512ac621507570c2eeb837a731a2546954cdc943c73613`.
  The existing independent morning audit records all 14 sources and six groups
  verified, stocks/funds through 2026-09-25. This is not API serving success.
- Stack RunDocumentVersion is 5, InstallDocumentVersion 1. Its API target is
  `i-0896b2f2f421b847b`, while EB currently serves on `i-0eabc67533fb38fca`.
- A fresh read-only SSM inspection of the serving instance
  (`ef0adfb3-9186-442e-9cad-8a52e8f5fa4b`) confirms no global active pointer,
  Research recovery release
  `ee3a14209c96a9cec758c9472711bca34c47fb4ab46c3f810b7f1f56b7b2ff08`,
  12,437,950,464 free bytes, and `USER_DATA_BACKUP_KEY` absent. Only presence
  was inspected; no credential value or private user data was output.
- The first diagnostic SSM command had a shell-quoting syntax error and made
  no changes; the corrected JSON-file dispatch succeeded.

## Safe implementation completed

The stack generator now provides explicit default-off `ActivateDaily`, using
the existing worker installer/ACK path and separate `ApiActivated`/`DataReady`
terminal states. No new scheduler, source, database or API is introduced.
The new regression first failed for the missing parameter, then passed.
Worker, API installer and IaC suites: 25 tests passed; diff whitespace check
passed. These code changes have not been deployed or enabled.

## Blocking prerequisites / next authorized step

First full activation requires the documented encrypted user-data backup and
isolated restore verification, plus encrypted EBS rollback. The user previously
excluded private-account operations. A dedicated backup key is not configured;
do not substitute the account encryption key, skip the gate, or silently read
private stores. Obtain specific authorization for backup-only handling before
continuing that prerequisite. Preserve all live user records and broker jobs.

Then reconcile scoped Research selection, inspect candidate size versus actual
capacity, install and ACK the exact six-group candidate on the current EB host,
and only after successful manual serving verification enable daily activation
with updated, fixed document versions and the correct API target. Preserve the
old release on every failure. Guru curves and historical model publication
remain separate reviewed jobs; activation alone cannot make their health green.

No sync, data activation, schedule change, cloud deployment, GC or private-account
operation was performed in this diagnostic/fix turn.

## Follow-up: approved public-only path

The operator subsequently approved connecting public website data without a
new backup key or private-account handling. A separate exact-six-group
`public-daily` installer mode is being implemented. It switches only the public
manifest, preserves the scoped recovery pointer, and validates Research along
with Fundamentals and precomputed public analysis. The legacy private-data
migration gates still apply to any operation outside that public-only scope.

Candidate manifest payload budget is 4,112,241,865 bytes (3.83 GiB), before
possible reuse; the last actual API free-space measurement was 12,437,950,464
bytes. Installation must recheck capacity and preserve the 1 GiB reserve.
All previous generations and raw archives are retained; no GC or expansion
is authorized. This budget is not a claim of indefinite daily retention capacity.

New Research cutover regression reproduced the stale scoped-pointer behavior,
then passed with explicit public-daily selection and rollback coverage.
Publication/worker/installer/IaC focused suites: 43 passed. Full release results
and actual deployment identities must be appended after completion.

Release checks: full Node suite 1,755 passed / 15 existing skips / zero failures;
Fact OS full suite 260 passed; transport/performance protection 60 passed;
AWS CloudFormation template validation passed. Full local storage audit passed
(20,986,644,021 bytes; zero duplicate raw bytes), receipt
`data/fact_os/audit/storage-public-daily-20260928.json`. Layout audit retains
the eleven previously documented findings; no files were deleted or ignored
to force a pass. Rollback application remains `recovery-e5c121d`.

## Public serving deployment (in progress)

Code `3909366e2c06ec4200515570f84ad05dceefa00d` was pushed to trunk and
deployed as EB `public-daily-3909366` (Ready/Green). This is application
deployment, not a data-serving acceptance. CloudFormation changeset
`public-serving-3909366` completed with `ActivateDaily=true`, RunDocument 6,
InstallDocument 2, current API instance `i-0eabc67533fb38fca`, and the schedule
temporarily **DISABLED**. No instance or volume was expanded.

Manual publication-only verification reuses scheduled run
`74a89dc42e131642a5c42dd11f72792c19785a8a7f400f93a8b9d0a076af87d0`;
it does not fetch sources or rebuild backtests. An initial command referenced
a mistyped receipt filename and failed before publication. The corrected
worker command is `01f55ef4-e56d-4d5e-9591-bf07bf0d0406`, with actual API
installer command `f8c878c9-ee74-402d-8e6a-600f9755bd7b`. Final acceptance and
schedule restoration must be recorded below; manual verification does not
count as the first scheduled API activation.

## Actual acceptance

- Installer and publication commands above completed successfully. Actual
  `webapp` reads, all fourteen canonical coverage/backfill checks, and live
  API ACK passed. Serving release is
  `075134daa3dac8f423445dd36f285e8e79ca8f4351a9c7df8f8d1058ffaee554`.
- The data-ready candidate and serving release have the same runId and all
  six identical group generation IDs. Root release IDs differ because their
  publication manifests refer to different prior-release chains (data-ready
  versus first global API installation); no payload objects were uploaded in
  the publication resume (`uploadedObjects=0`). Do not compare root IDs alone.
- Independent follow-up command `f26afdcd-5c88-4e3b-86f8-13accba381b0`
  re-read the live ACK: Research AMZN has 8 quarterly / 8 annual periods,
  PLTR 8 / 6; Fundamentals 5,428 companies, latest available 2026-09-25;
  public analysis ready. Eight precomputed jobs cover Fundamentals,
  opportunities, and summaries/ledgers for the three strategy universes.
  This does not assert new historical backtests were built.
- API disk free after installation: 8,323,096,576 bytes. Existing recovery
  pointer and old immutable releases retained. No private data read/migrated,
  no new secret, no source fetch, no GC, no instance expansion.
- CloudFormation completed and Scheduler restored to **ENABLED**, cron
  `30 7 * * ? *`, **Asia/Riyadh**, with API activation enabled. First scheduled
  serving acceptance remains **pending 2026-09-29 07:30 Asia/Riyadh**.
  The existing read-only monitor was updated to check both data-ready and
  actual serving ACK, rather than its obsolete data-only acceptance.
- Both production domains resolve to Vercel
  `dpl_6SMs64yd8xMDTYTiUDCsf7iTXLa6`,
  `thesisforge-amibzhy1g-yudonglu1136s-projects.vercel.app` (Ready).
  External Fundamentals requires authentication (401); internal ACK is not
  publicly accessible (404). No authentication bypass was enabled.
- Eight concurrent public health requests completed in 2.11–2.26 seconds,
  all **503**. The pre-existing aggregate Guru/legacy readiness gate is not
  certified by this public-data cutover; do not report the entire platform
  healthy or claim browser-authenticated page acceptance from these probes.

Rollback: disable the public scheduler; retain all immutable files. Installer
ACK failure restores the prior global pointer automatically. For this first
global cutover, reverting the global pointer to its absent prior state restores
the retained Research recovery selection. Application rollback target is
`recovery-e5c121d`. Original stack parameters/template were retained locally
under `/private/tmp/thesisforge-fact-os-before-public-serving-*`; do not blindly
restore its obsolete API instance ID. Guru/reviewed models and private jobs
remain outside this publication scope.
