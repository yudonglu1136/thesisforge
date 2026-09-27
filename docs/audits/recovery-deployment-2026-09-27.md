# Recovery deployment — 2026-09-27

## Source and test gates

- Discover test migration / recoverable unrelated-work archival:
  `260f50e9e064a57ad5be59685408488509a3ad8a`.
- Deployed application commit:
  `e5c121d96d145926033708961ae7afe6a4f25d34`.
- Source provenance: clean trunk, zero tracked changes, zero untracked files,
  exact published remote SHA verified before both packages.
- Flutter full suite: 645 passed; final brace-only lint adjustment followed by
  targeted Discover recheck. Flutter analyze and bilingual literal audit pass.
- Final complete backend suite: 1,754 passed, 15 skipped, zero failed (1,769
  total). Two unrelated uncommitted tests were preserved in the archive rather
  than silently included in this release. The new ANALYZE regression adds one.
- 13F runtime/archive targeted suite: 20 passed. The ANALYZE case first failed
  with `investment_release_unexpected_source_table`, then passed. Only SQLite's
  reserved `sqlite_stat1` / `sqlite_stat4` metadata is admitted; unrelated
  private tables, hash mismatches and writable artifacts remain rejected.
- Production build passed with authentication bypass explicitly false.
- Full local Fact OS storage audit passed, 20,986,624,377 bytes, zero duplicate
  raw bytes. Receipt: `data/fact_os/audit/storage-release-e5c121d-20260927.json`.
  The standard output name already existed, so a new append-only receipt name
  was used; the older receipt was not overwritten.
- Repository storage-layout audit retains its 11 pre-existing failures:
  unexpected valuation source DB and ten retired sibling directories. No
  database or sibling directory was deleted to force a pass.

## Actual production changes

- EB application `thesisforge-api`, environment `thesisforge-api-prod`:
  `recovery-e5c121d`, Ready / Green.
- Backend package SHA-256:
  `ff3ee7f8147465877af581efca0925538eaa2fdbb9f9987e7768e0b8e87075c2`.
  No SQLite, frontend or private data was bundled.
- Vercel project `thesisforge`: deployment
  `dpl_5Hx3Cpb3WUshDgpSGQ27RgvcF3YW`, READY, production URL
  `https://thesisforge-d9n2hnjm6-yudonglu1136s-projects.vercel.app`.
- Separate `vercel inspect` calls confirm both `thesisforge.tech` and
  `www.thesisforge.tech` resolve to that exact deployment.
- Frontend main bundle SHA-256:
  `34dc29496731bc4048996de4165c9f1cd745b8838bc4fbaee229aa54589baf0d`.
- Three published-price-vintage rule ledgers (8,475,276 compressed bytes)
  installed under `/var/app/data/rule-ledgers`. Manifest SHA-256:
  `2e12b6a17897b9e8aa0fc295bd964e97096255ba92edb973ccf40738a6b1afbd`.
  SSM `14c3fe1f-3c37-444b-9aed-09e984a888a1` confirms installation plus actual
  `webapp` reads matching all three deployed snapshot identities. No strategy
  curve, source price or historical valuation was recomputed or replaced.

## Live verification and honest remaining blockers

- Public Research and Portfolio routes return 401 without authentication;
  internal release route returns 404 through the public proxy.
- Research response retains the exact scoped release
  `ee3a14209c96a9cec758c9472711bca34c47fb4ab46c3f810b7f1f56b7b2ff08`.
- Eight concurrent public health requests all completed in approximately
  2.4 seconds and returned the existing explicit HTTP 503. This is not a
  performance benchmark or healthy-release assertion. Database, Guru source
  and valuation checks are healthy; Guru curves are 0/57 current/displayable,
  and legacy market prices are stale (2026-09-18). These gates were not relaxed.
- Vercel error scan found the eight health-503 requests; no clean-error claim.
- Global Fact OS `active.json` remains absent. The API host has no configured
  dedicated `USER_DATA_BACKUP_KEY`; the required encrypted user-backup and
  isolated restore gate cannot be completed from the available configuration.
  Full activation was **not attempted** or bypassed. The existing completed
  encrypted EBS snapshot `snap-00e5fa3158e0ddfcf` is not represented as a
  substitute for this separate gate. Research scoped activation is unchanged.
- Production Chrome displayed sign-in. User login was requested; private
  sessions were not extracted and authentication was not bypassed. Logged-in
  Fundamentals, Portfolio and attribution UI acceptance remains pending.
- No daily sync/backfill, Guru curve rebuild, private broker/NAV job, global
  data activation, or garbage collection was run in this release step.

## Rollback and preservation

Prior EB application version: `strategy-visible-90c2e09`. Prior Vercel
deployment: `dpl_EnGJ3nXsMUagugHGV81qiuAPesGz`
(`thesisforge-ahvcfnxp7-yudonglu1136s-projects.vercel.app`). Code rollback must
preserve all live user edits and data pointers. The new immutable ledger files
and hash-named manifest history remain available for diagnosis; do not delete
facts or restore a stale user database to roll back code.

Unrelated work remains recoverable in the archive documented by
`release-source-recovery-2026-09-27.md`. This record confirms the two source/test
blockers and the application deployment, not completion of every platform
incident or full global data activation.
