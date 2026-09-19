# Horizontal quarterly research book

Local implementation of the user's 2026-09-09 redesign request. No commit,
production deployment, backend modification or database write in this task.

## Experience

1. Choose a quarter from the horizontal strip. Each card shows fiscal quarter,
   publication date, quarterly revenue growth and TTM FCF margin. Scroll or use
   the arrows; jump to a fiscal year; Latest returns to the newest available row.
2. Read that quarter. Results & changes compares prior/current metrics and
   percentage-point differences. Guidance and Call Q&A show that quarter's
   stored evidence, sources and coverage; expanded answers retain original text.
3. Open valuation for the same company at the workspace cutoff. Historical
   browsing never edits or automatically fills the private hypothesis sheet.

The implementation adapts the legacy Guru `QuarterTimelineSelector` and
`ValuationQuarterResearchPanel` interaction to the existing Graphite research
workspace. It removes the redundant Follow the evidence heading, but preserves
the latest-company evidence, portraits, source disclosures and original curves.

## Data handling

- Reuses `company.history` already available in Research. The quarter API still
  fetches only the selected fiscal quarter's transcript/guide bundle.
- `earningsBookObservation` requires exact fiscal period and publication date,
  plus a date no later than the workspace cutoff. Missing observations show a
  dash, not zero or another quarter's metrics.
- Displayed dates separate fiscal period-end, publication and call date. The
  number of available quarters does not imply complete transcript coverage.
- Historical published model is not personal DCF and its change is not a causal
  earnings-call attribution. Existing source methods and calculations are intact.
- Request serial guards and exact ticker/cutoff/period checks are preserved.
  Failed or loading selection cannot display old selected-quarter detail as new.

## Verification

- 343 Flutter tests passed; 14 focused earnings tests include English/Chinese
  at 1487×1058, 1280×720 and 390×844, 1.5× phone text, direct selection, year
  jump/latest, exact node matching, missing data, failed/retried requests and
  late-response protection. Browsing never posts a save.
- Analyzer, bilingual audit, private release build and whitespace checks pass.
- Actual browser verified TSLA Q2 → Q1 (four stored Q&A) → 2025 Q4, expanded
  management answer, correct guidance/QA counts, valuation handoff, phone strip
  navigation and Chinese mode. Final error log empty.
- Source/final comparison and iteration details are in project `design-qa.md`.
  Screenshots: `output/earnings-quarterbook-20260909/`.

Preview uses loopback services and the existing private development-auth build.
Do not deploy this artifact with development authentication enabled.
