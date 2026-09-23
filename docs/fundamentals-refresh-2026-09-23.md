# Fundamentals usability release — 2026-09-23

## Scope

UI-only follow-up to the verified Fact OS production restore (`702448f`). No
financial formulas, source records, historical valuations, private portfolios,
runtime databases, or unrelated working-tree changes are modified.

The previous view replaced both company results and the selected evidence panel
with a loading box for every search/filter request. A slow request could also
complete during the next search's debounce and display stale results.

## Changes

- Keep same-cutoff verified results and selected company visible while refreshing.
  Clearly label refresh failure and retain the previous result's lens and page.
- Invalidate requests on each keystroke, before debounce. Clear old facts and
  journal context immediately when cutoff/API changes; guard late journal and
  institutional responses.
- Reuse unchanged company evidence across search and sort operations. Restore the
  chosen detail tab when returning from Research. Reload evidence after an expired
  session recovers.
- Aligned desktop financial columns, company logos, readable metrics, bounded
  independently scrollable result list, and three-column mobile financial cards.
- Company-specific loading identity, actionable error/empty states, collapsed
  advanced filters, explicit report-period versus cutoff labels.

## Fresh verification

- Fundamentals + shortlist widget tests: 21 passed, including 7 new refresh,
  race, cutoff, authentication and return-context regressions. The initial
  nonblocking-refresh test failed against the old implementation before fixing it.
- Server suite: 1,659 passed; 15 skipped; 0 failures.
- Performance guard suite: 60 passed.
- Full Flutter run before the final one-line authentication cache reset:
  576 passed / 32 failures. Every failing test name matches the existing
  `fundamental-flutter-suite-final.log` baseline. The final focused suite verifies
  that reset. No assertions were deleted or weakened.
- Static analysis, bilingual literal audit and production build with
  `AUTH_DEV_BYPASS=false` passed. A separate localhost-only preview used the
  existing development-auth mechanism; it is not a production artifact.
- Real browser: English/Chinese desktop and 390px phone; real UBER search,
  published model decomposition, mobile company detail, Research navigation and
  return with selected company/search/cutoff preserved. Console has no new errors.
- Production API process read probe (`76b94925-9e4c-46d1-92a7-158d5e6ecd5a`):
  5,419 companies at cutoff 2026-09-23, latest available fact date 2026-09-21;
  cold 13,155 ms, subsequent reads 191 / 186 ms. These are in-process release-probe
  times, not claimed browser response times. Local public universe has 5,418
  companies; no copies of private or canonical databases were made.

## Boundaries and release safety

- A new uncached cutoff can still require an initial canonical scan. Loading is
  explicit; filtering an already loaded cutoff no longer blanks the workspace.
- Production authenticated-browser acceptance requires an existing signed-in
  session; server-side authorized data validation is not a substitute for it.
- Storage-layout audit still reports 11 pre-existing paths (legacy sibling
  projects and `server/data/valuation-pit-source.sqlite`). This UI-only release
  neither introduces nor deletes them. It does not claim a storage migration.
- Existing adjacent Flutter failures remain separate follow-up work, not a green
  full-suite claim.
- Frontend rollback target: Vercel `dpl_8NMQuTFa63DrTvzpPM1MGpwWwNcD`.
  Keep AWS `fundamental-702448f` and canonical data release
  `5c318a56abe766f1e74e41ac2a84c7efd80d5d612649af88d99dda15b46f3e84` unchanged.
  Push only these scoped UI/tests/docs to trunk, verify the Vercel build commit,
  both production aliases, public health proxy and authentication boundaries.
