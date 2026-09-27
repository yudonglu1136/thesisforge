# Platform recovery follow-up — 2026-09-27

This is a partial recovery, not a production acceptance or an all-issues-fixed claim.

## Changes

- Fundamentals no longer treats an `updating` precompute response with empty
  rows as a successful empty screening result. It preserves filters and reports
  preparation explicitly in both languages; retry loads the verified result.
- The compact Portfolio holdings table had dropped access to existing Guru
  filing evidence. Desktop and mobile rows now open the shared evidence component
  without fetching private data or performing financial work in the UI. Selecting
  a manager closes the dialog and passes the exact manager/accession to navigation.
- Updated the invalid FCFE input assertion to the existing negative-cash-flow
  contract, and the read-only-model fixture to the current coverage/reconciliation
  response. The latter still checks the exact published value and absence of a
  personal DCF starting point; it no longer expects the retired trend layout in
  the published reconciliation tab.

## Verification

- Targeted Flutter regression: 55 passed (Fundamentals, Portfolio visual/evidence,
  worksheet memory and opportunities), including 390px, 150% text, both languages
  and privacy-on evidence navigation.
- Flutter static analysis: no issues. Bilingual literal audit: passed.
- Full Flutter suite freshly rerun: 616 passed, 29 failed. The failures are
  27 old Discover-lens widget flows and two growth-quality flows still selecting
  `discover-collection-*` controls from the retired Discover explorer layout.
  These assertions were not removed or counted as passing. Migration to current
  product flows remains unfinished and blocks frontend acceptance.
- Final evidence-dialog regression after adding close-before-navigation checks:
  five passed.
- Production-config build passed with `NODE_ENV=production`, auth bypass explicitly
  false and workflow enabled. Output remained isolated at
  `/private/tmp/thesisforge-recovery-web-20260927-v2`, never promoted.
  Compiled main SHA-256:
  `34dc29496731bc4048996de4165c9f1cd745b8838bc4fbaee229aa54589baf0d`.
- Real-browser acceptance for this new UI and controlled p95 measurements are
  still pending. Widget tests/build success do not replace either.
- No licensed data, portfolio amounts, auth values or provider secrets were exported.

## Production and blocking conditions

Fresh read-only EB inspection confirms `thesisforge-api-prod` is still on
`strategy-visible-90c2e09`, Ready/Green. That infrastructure status does not certify
the failing application/data paths. The earlier backend recovery commit
`a16df70bbf5394b8301fb63ffcbc56cec934292d` has not been deployed.

The existing source gate rejects the working tree: unrelated `design-qa.md`
changes and 866 untracked files were present before this follow-up. They include
research documents and owner-compounder implementation belonging to other work.
No reset, stash, deletion, archival, blanket staging or fake clean checkout was
used. The gate has not been weakened. Ownership-safe archival requires explicit
authorization or completion by the originating tasks.

The deployment/data-activation sequence and rollback requirements remain in
`platform-backend-release-2026-09-27.md`. Full global Fact OS activation, private
frozen-ledger installation and authenticated production UI verification are still
pending; daily data-ready publication is not API activation. Guru freshness and
daily upstream synchronization failures remain separate unresolved items.
