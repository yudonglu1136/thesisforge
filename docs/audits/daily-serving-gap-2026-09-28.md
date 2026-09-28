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
