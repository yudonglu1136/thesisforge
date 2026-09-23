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

Publication identity and final rendered checks are recorded separately after
verification. Local development preview builds are never production artifacts.
