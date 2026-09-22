# Active-manager sector visual refinement — 2026-09-22

## Scope

Presentation-only refinement of Discover → 13F Insights → Active funds → sector.
The existing active-sector-v1 API, generation/quarter/cutoff pinning, ranks,
20-row paging, source exclusions and Research navigation are unchanged.
No data rebuild, backend deployment, schema change or private-store write.

- Bordered summary separates net estimated change, additions and reductions.
- Company cards reuse `StockLogo` and its exact-symbol identity/fallback.
  Industries and managers use category icons instead of a misleading stock logo.
- Compact stock/industry/manager tabs, direction filters and search.
- Each row separates identity, net change, adds/reductions and within-sector
  weight. Position counts and coverage details expand without another request.
- Missing/inconsistent-input warnings remain visible while collapsed; missing
  figures remain em dashes. Methodology and value reconciliation remain available
  in Coverage & calculation details. Amounts are not labeled actual cash flows.
- Responsive EN/ZH desktop and 390px layouts; narrow screens wrap metrics instead
  of horizontal scrolling. The close control remains visible while scrolling.

## Verification on the release tree

- `flutter test test/investment_13f_sector_test.dart`: 9 passed. Includes both
  languages at 1280/390px, logos, expansion without fetch, fixed rank and pinned
  paging/filter context, missing values, industry → stocks → Research, retry and
  out-of-order responses.
- `node --test server/institutional13fSector.test.js`: 4 passed.
- `npm run test:server`: 1,655 passed, 15 skipped, zero failed.
- `flutter analyze`, `npm run audit:i18n`, `git diff --check`: passed.
- Production `npm run build`: passed with `NODE_ENV=production`, explicit
  `AUTH_DEV_BYPASS=false`, same-origin API and investment workflow enabled.
  Isolated output: `/private/tmp/thesisforge-sector-polish-dist-20260922`.
- Full `flutter test`: **568 passed, 32 failed**. The failure distribution matches
  the independently reproduced baseline documented in
  `13f-sector-drilldown-2026-09-22.md`: Discover lenses 27, growth/quality 2,
  opportunities 1, portfolio Guru 1, valuation memory 1. This is not a fully green
  suite. No test was removed or assertion weakened; this release does not repair
  those adjacent pages.
- Real-data browser: 2026Q2 Technology, 2026-09-22 cutoff; English/Chinese desktop
  1440×1000 and mobile 390×844. Logos, detail expansion, industry view and search
  verified. Filtering AMD to net additions retains its sector rank #5 and sector
  totals; Research opens AMD Institutions at the same cutoff; return retains
  active scope and quarter.
- Screenshots and this run's logs: `/private/tmp/sector-polish-*`.

No storage work was performed. Existing storage-layout findings documented by
the earlier sector release were not deleted or reclassified to obtain a pass.

## Release isolation and recovery

Release starts from remote trunk `c433900d64799ca32db87dcc9e4ac6e2b9f9b031`.
The unrelated local Strategy commit is preserved on
`local/strategy-ledger-aa96d88`, not included in this release. Existing dirty
design notes, audit files and other tasks' scripts remain outside the commit.

Deploy the committed trunk frontend to Vercel project `thesisforge`. Keep the
existing AWS API/data unchanged. Verify both custom domains resolve to the same
Ready deployment, the auth boundary and public API health. Then inspect the
authenticated production sector UI. Local validation is not production validation.

Pre-release rollback target for **both** domains:
`dpl_EBrvpxLnJvDDNmL29mT1RmrWJiuq`,
`thesisforge-pmgh82ev8-yudonglu1136s-projects.vercel.app`.
If production checks fail, return both aliases to this Ready deployment; no
database restore is involved. Final deployment identity and checks are recorded
in the task's release receipt after deployment, not pre-claimed here.
