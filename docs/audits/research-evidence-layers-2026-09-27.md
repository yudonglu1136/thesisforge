# Research evidence-layer recovery — 2026-09-27

## Confirmed failure

Production nginx metadata (SSM `c11b9110-d8cc-4211-8e52-a8aa8c8a2e92`)
shows PLTR documents HTTP 200 at 04:42 UTC, alongside fundamentals and insiders
HTTP 503. Flutter's `Future.wait` discarded the successful document result when
fundamentals failed, then misleadingly rendered an unavailable catalog.

The backend canonical serving recovery is already deployed as
`research-statements-999de00`. A fresh production read under the webapp account,
the actual runtime InvestmentSource and the Research release middleware
(SSM `39c7b5d9-f75a-46f2-b173-591010039a1e`) returned:

- PLTR, cutoff 2026-09-27, six months: 136 insider records, first page 20.
- 25 announcement catalog records / 25 source links / zero readable bodies.

No source rows, body text, transaction intent, or synthetic trading signals
were created. No sync, database write or global data activation was performed.

## Frontend change

- Financial history and announcement requests settle independently.
- A successful catalog renders without waiting for a financial scan.
- Financial failure has its own warning and retry; documents remain visible.
- Announcement failure has a retry and is not described as an empty catalog.
- Existing ticker/cutoff request guards, authentication, and independent
  insider pagination/retry behavior remain intact.

## Checks

The regression failed before the fix (successful document was missing) and
passed afterward. Targeted Research/insider/chart widget tests: 31 passed;
backend Research/insider/release-context tests: 7 passed. i18n audit passed;
Flutter analyze found no issues.

Full Flutter suite: 610 passed / 32 failed. The unchanged `da3ceac` baseline
has the identical 32 failure names (608 passed); no new failing tests. These
existing Discover lenses, valuation memory, growth quality, Portfolio Guru and
opportunity assertions were not changed or suppressed. This is not a full-suite
pass. Production browser currently shows the normal sign-in page;
authenticated visual verification requires the user's login, not an auth bypass.

This frontend-only repair retains backend `research-statements-999de00` and its
verified Research data release. The previous Vercel deployment for rollback is
`dpl_Hq4GHqMSbVcrnkvBxr36gbDse1Vm`.
