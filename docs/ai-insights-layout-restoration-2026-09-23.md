# AI Insights — restore the chart-led overview

## Scope and cause

The launch implementation put a compact company desk before the economic charts
and hid the original overview in a collapsed `Market context & detailed trends`
panel. The requested charts and full rankings were still present, not lost data.
This release restores the user's original screenshot layout using those existing
widgets, not a repository rollback:

- Summary amounts → capital-investment bars → three growth lines.
- Sector heatmap and revenue contributors together on wide screens, stacked on
  narrow screens; their quarterly data tables remain available.
- Full company rankings, search, peer scores, comparison, evidence, and exports
  retain their original dedicated views.
- Company detail selection is retained for the existing Research handoff.

No API, Fact OS, scoring, PIT, artifact, 13F, Fundamentals, Research model, or
private-account storage changes. Unrelated working-tree files are not included.

## Verification

- A regression test first failed against the compact/collapsed implementation;
  it now requires all original chart sections outside an accordion, in order.
- AI Flutter tests: 16 passed, including full rankings → evidence → Research
  context, fixed snapshot, cutoff races, missing data, narrow screens and export.
- Full Flutter: 578 passed, 32 existing failures. The failed test-name set is
  identical to the pre-release Fundamentals baseline; no new failures.
- AI Node/API/artifact tests: 20 passed.
- Full Node server suite: 1,659 passed, 15 skipped, no failures.
- Flutter analysis, bilingual literal audit and production build passed.
- Real local API: generation
  `b8c7e5105b5885fa99692e0c036a39dedac5e93f17885d6582463889e33b12f0`,
  2026Q2 / cutoff 2026-09-21, 50 revenue companies, eight displayed quarters.
- Browser: Chinese and English, 1440px desktop / 390×844 mobile, overview,
  YoY/QoQ, rankings, company search and source/score detail; no console errors.
  Local screenshots live under `/private/tmp/ai-restored-*.png` (not data bundles).
- Production build has `AUTH_DEV_BYPASS=false`, the existing Supabase settings
  and workflow enabled. Compiled `main.dart.js` SHA-256:
  `3edd34bf483898cba15e858227b6fdfb5a416611d048e9c79e1d7a5f51262f78`.

## Publication and rollback

Frontend-only trunk release through the existing Vercel `thesisforge` project.
Both public aliases must resolve to the same ready release; compare downloaded
JavaScript to the build hash above. The backend and data generations are not
redeployed. Rollback target recorded before publication:
`dpl_89YUfr7TuDRKGY5SQ7qNdDJp8TqM` / `thesisforge-q64w3zt03-yudonglu1136s-projects.vercel.app`.

The pre-release aggregate `/api/health` remains HTTP 503 due to the previously
recorded stale Guru curve matrix. This UI release does not refresh those curves
or weaken their readiness thresholds. Production login protection remains on;
an unauthenticated shell is not an authenticated end-to-end acceptance test.
