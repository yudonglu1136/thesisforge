# Admin and valuation-coverage code release — 2026-09-06

## Outcome and scope

Production code release completed. This is **not** a completed valuation-data expansion or an all-platform health pass.

- GitHub `trunk`: `730dc21ff44a888966e71e9cc4fdfc05d1fd19e9` (verified with `git ls-remote`).
- AWS Elastic Beanstalk: `guru-admin-20260906-730dc21`, Ready / Green; update completed at 12:04:42 UTC.
- Vercel: production deployment `dpl_GmvxhpLbZNtgiVkTrgwiyFT8bAJ5`, Ready; Flutter web with Node API proxy, prebuilt deployment build approximately 14 seconds.
- Both `https://thesisforge.tech` and `https://www.thesisforge.tech` now resolve to that exact deployment. Promotion initially left www on the old deployment; explicit alias assignment corrected this, followed by inspection and asset-hash verification.
- Production URL: https://thesisforge.tech
- Deployment URL: https://fundamental-analysis-g7nyruosg-yudonglu1136s-projects.vercel.app

The 30-file commit ships Admin last-sign-in tracking, login-sorted portfolio registration groups, and distinct valuation coverage/error states. Unreviewed local financial-source/import/audit work and candidate valuation data were intentionally excluded. The release package contains no bundled SQLite database, PIT migration, or replacement valuation tables.

## User-visible acceptance

Verified through the already-authenticated production Chrome page, without reading or exporting session credentials:

1. Admin shows **Users & last sign-in**, newest known sign-in first, unknown timestamps last, with the displayed timezone.
2. Separate **Portfolio registered** and **No portfolio registered** groups render. The observed directory contained 14 platform-observed records: 2 registered and 12 unregistered. These are not a claim about total Supabase registrations; historical unlinked records can be present.
3. Last sign-in and last activity are displayed separately. Navigating or refreshing does not invent a new login timestamp. Historical unknown sign-ins remain “Not recorded.”
4. Gavin Baker → CRDO opens the new explicit **no published model** state. The misleading generic Retry button is absent. This verifies the new frontend and backend behavior, **not** a usable CRDO valuation.
5. Returned the authenticated product tab to Admin after verification. No private user identities, portfolio values, or Admin screenshots are included in this report or committed to Git.

## Clean-release verification

Tests were run against the committed release clone, not the unrelated dirty research tree:

| Check | Result |
| --- | --- |
| Backend tests | 512 passed, 0 failed |
| Flutter tests | 131 passed |
| Flutter analyzer | No issues |
| i18n audit | Passed |
| Performance/transport tests | 41 passed; overlaps backend coverage |
| Ontology tests | 3 Python and 22 Node passed |
| Module verification | Passed |
| Vercel production prebuild | Passed |
| Staged credential-pattern scan | No matches in the 30 release files |

Both production `main.dart.js` responses returned HTTP 200 with SHA-256:

`b02e4cb9bae390a5455ab709fac75670068377a14713267f20ee4c509cd1695e`

This matches the clean release artifact and contains the new Admin and unpublished-valuation UI strings.

Both domains deny unauthenticated `/api/admin/portfolio-users`, `/api/admin/login-activity`, and `/api/valuation/CRDO` with HTTP 401. `/api/internal/status` returns HTTP 404 and `no-store`. Authenticated Admin records rendered successfully in the browser. No auth bypass was enabled. The unauthenticated 401 responses were observed with Vercel's `public, max-age=0, must-revalidate` header; this is not a claim that all auth responses carry `no-store`.

The new Vercel deployment error-log query returned zero entries at the verification checkpoint. This is a bounded observation, not proof of absence of all production errors. An attempted preview `vercel curl` command failed because of CLI argument forwarding; production acceptance instead used actual domain inspection, HTTP responses, file hashes, and authenticated browser rendering.

## Remaining blockers — not concealed by this release

- **CRDO has no released valuation snapshot.** Its local candidate still belongs to the unfinished financial-data audit. Changing an error message or deploying code does not publish that model.
- Production valuation coverage remains **533 published ticker snapshots**. No claim is made that all requested Guru holdings are covered.
- Application `/api/health` remains HTTP 503, matching the pre-release condition: only **21/56** required 5Y/10Y manager curves are current and displayable. This is distinct from Elastic Beanstalk's infrastructure Green status.
- Eight concurrent post-release health requests across the two domains all returned the same condition: database healthy, 38 Guru snapshots, 21/56 current curves, 533 valuation snapshots, 2,895,383 price rows, and Ontology healthy. Response times were approximately 3.63–3.69 seconds. This is an acceptance sample, not a performance-improvement claim.
- No coverage threshold, model-audit gate, or health rule was weakened to obtain a pass. Background jobs already running on production may update normal runtime metadata; this report does not claim byte-identical runtime databases.

Next work is to complete and pass the financial-data publication audit before publishing CRDO and the other candidates, and separately restore current-generation Guru curve coverage. Neither is represented as completed by this code release.

## Rollback evidence

- Previous AWS version retained: `guru-stock-research-20260905-a4bad57`.
- Pre-release source EBS snapshot `snap-0ed18df9b9f070b91`: completed.
- Encrypted rollback copy `snap-0ae5f318a35068f25`: completed, encrypted.
- Code-only AWS package SHA-256: `89399481cb9aab1bacdf4c8afd40fe3accdf3f653c5674ac3f565499ba6f4dde`.
- Previous www Vercel deployment before correction: `dpl_9der1TnZ4A246uoPKnKsVhJPf7U3`; the verified new deployment owns both aliases now.

This post-release audit is a local handoff artifact. It is not included in commit `730dc21`; no extra documentation-only deployment was triggered after production verification.
