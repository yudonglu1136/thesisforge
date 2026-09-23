# AI Insights: sector-quarter contributor logos

## Scope and contract

- Retain the restored chart-led overview, now with a full-width heatmap and
  larger cells (sector growth / existing StockLogo + ticker / contribution pp).
- Keep sector names visible during horizontal scrolling on narrow screens.
- Reuse `aggregateQuarter`'s PIT-filtered, corporate-action-screened matched
  population. Select the largest **positive revenue delta**, not highest
  issuer growth or largest absolute decline. Denominator is the sector's
  matched base-period revenue. YoY and QoQ leaders are independent.
- Equal deltas use ticker order and disclose a tie count. No positive delta
  means no winner; a missing/invalid denominator remains unavailable.
- Return only one leader per comparison with source revision IDs and dates;
  no per-cell request or full contribution roster is introduced.
- Preserve cell → same quarter/sector rankings, snapshot context, Research
  evidence, fixed ranks, exports and underlying financial formulas.
- No new logos, financial database edits, artifact rebuilds, model changes,
  scheduled jobs or user-data changes.

## Verification

- New backend regressions failed before implementation, then passed.
- AI Node/API/artifact suite: 22 passed. Performance/cache suite: 60 passed.
- AI widget suite: 17 passed; analyzer and bilingual audit passed.
- Real artifact `b8c7e5105b5885fa99692e0c036a39dedac5e93f17885d6582463889e33b12f0`:
  cutoff 2026-09-22 / 2026Q2 / 8 quarters / 13 sectors; 208 basis/cell checks,
  all shown leaders have local logo assets; original artifact unchanged.
- Whole dirty-workspace Flutter run: 575 passed / 41 failed. Clean pre-feature
  trunk source: 580 passed / 32 failed. The extra nine failures are confined to
  the concurrent Strategy UI work in `investment_workflow_test.dart`; those
  files are excluded from this feature. Do not call the whole suite green.
- Storage layout audit remains blocked by the existing runtime/sibling path
  violations; no database was deleted or copied to make it pass.

## Release verification

- Feature commit: `c6c79f351ab1bf58dd7d604974ff2d822f10c1f6`, pushed to `trunk`.
- Clean committed source: full Node suite 1,690 passed / 15 skipped / 0 failed.
  Clean release Flutter suite: 583 passed / 32 failed, with the **identical**
  failure-name set as the clean pre-feature baseline (580 passed / 32 failed).
  No assertions were removed and no unrelated source files were packaged.
- Production build passed with developer authentication disabled. Compiled
  `main.dart.js` SHA-256 is
  `03ac7a41bf1a74de1f55ebcd294a2f0e573cda2fea362fc2f570a9def102cb4c`;
  both public domains serve those exact bytes, including the new feature and
  excluding the local developer-entry UI.
- Vercel: `dpl_HwtTcB9ADn3iJE7MDzDo8VcdVmoK`,
  `thesisforge-31og70j4h-yudonglu1136s-projects.vercel.app`, READY.
  Both `thesisforge.tech` and `www.thesisforge.tech` alias this deployment.
- AWS: `thesisforge-api-prod`, version `ai-contributors-c6c79f3`, Ready / Green.
  Code-only package SHA-256:
  `6cb49721dfb159e25b3dccffdc0d108450f583a48b79a46ffcb6e9319ce2e621`.
  No database, provider archive, private data, or frontend build was included.
- Deployed service SHA-256 matches the tested commit:
  `d6ecb4ebf68b69f5492f094372770f404ff9314760b58766845d49459dbddf0a`.
  Read-only execution as the actual API OS user (`webapp`, uid 900) passed
  208 YoY/QoQ cell checks across 13 sectors, with 205 positive leaders;
  missing/non-positive cases remain explicit. Snapshot replay was identical.
  Existing AI generation and source facts were unchanged.
- The API origin and each public domain passed eight concurrent health calls,
  preserving the existing complete Guru curve matrix. AI/private routes denied
  unauthenticated reads (401); internal routes remained hidden (404).
  NVDA, MU, TSM, MSFT, and ORCL logo PNGs returned valid bytes on both domains.
- Real-artifact browser checks: English desktop at 1280×720, Chinese 390px
  iframe, YoY/QoQ selection, hover evidence, fixed sector labels, and cell →
  quarter/sector rankings. A browser instrumentation MutationObserver error
  occurred in the mobile QA wrapper; the visible app and widget checks passed.
  Local development preview builds were not published. The production browser
  session required login, so an authenticated production visual replay remains
  unverified; the deployed asset bytes and production-service data were checked
  independently, not presented as an authenticated browser test.

Rollback: restore EB version `data-consistency-afa52bd` and Vercel deployment
`dpl_CEWXrwazhjM8bmLV6TggoAyHXLg7`
(`thesisforge-ekmvt1433-yudonglu1136s-projects.vercel.app`), assigning **both**
domains together. No data rollback is needed for this code-only feature.
