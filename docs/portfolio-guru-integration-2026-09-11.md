# Owner portfolio: valuation and Guru evidence

Implemented in the existing Home and Portfolio holdings views; no account data
or provider records were changed. No production deployment or data refresh.

## Reader flow

- Each equity retains its portfolio weight and valuation gap, with direct
  valuation and financial-evidence navigation.
- An expandable Guru activity section shows the common disclosed quarter,
  holder count, numbers adding/new and reducing/exited, and a named list with
  portraits, disclosed Guru weights, share changes and filing dates.
- Portrait/name detail buttons open that manager's exact filing. Exited
  managers remain in the activity list but are not counted as current holders.
- Home and full Portfolio reuse the same component and evidence. The existing
  percentage-only privacy mode still masks owner amounts and quantities.

## Source and calculation

`portfolioGuruBooks` starts with the configured Discover common-long catalog
and its cutoff-bounded filing calendar. UI snapshots can contain only 80 rows;
they are not sufficient to claim all holdings or all changes. For each exact
manager/accession/quarter, the portfolio reader uses the already configured
strategy SQLite warehouse's `filings`, `filing_holdings`, and
`holding_resolutions`. It requires a complete warehouse, original verified
common-long books, reconciled row counts and dollar totals, and resolved
security identities. The previous calendar quarter must also be complete and
available by the current filing date. No network fetch or database write occurs.

Current and previous shares are compared by exact CUSIP, after aggregating
duplicate source rows. Missing current shares are an exit only when both books
are complete. A missing prior quarter produces unknown change, not a new
position. GOOG and GOOGL holders are separate, irrespective of any separately
reviewed economic valuation-model mapping. Options and short positions do not
inherit underlying-company Guru ownership.

The shared Discover ownership transformation is extracted without changing its
existing semantics. Portfolio validates change arithmetic and uses one common
report quarter with one row per manager. Counts are manager counts, not net
buying dollars. These are unadjusted reported share changes, not verified trades;
the UI notes corporate actions and reporting lag. Where the warehouse is absent
or invalid, explicit existing observations remain usable, but truncated books,
missing managers and unknown changes are labelled partial. No-match is scoped
to covered filings, not a claim that no investor owns the company.

## Verification

- 44 backend tests: portfolio ownership/auth/calculations, existing Discover
  regressions, duplicate claims, exits, future filings, missing quarter,
  partial-book fallback and restored small positions beyond the UI extract.
- 494 Flutter tests pass, including exact Guru filing navigation and 390px
  EN/ZH at 150% text scale with privacy enabled.
- Flutter analysis, bilingual audit, ontology verification/tests, performance
  tests, production build and local preview build pass.
- Real authenticated Home and Portfolio responses agree on all equity Guru
  activity. As-of 2026-09-10 selects 2026 Q2, with 27 covered reporting managers.
  The local complete books restore small positions and missing reductions that
  the top-80 snapshot omitted; all counts are computed, not hard-coded.
- Browser checked at 1280×720 and 390×844: EN/ZH expanded Guru names,
  counts, portrait buttons, exact-quarter navigation, privacy retention and
  full Portfolio holdings. No browser runtime errors observed. Existing
  portfolio risk-price coverage and unmatched foreign listings are not repaired
  by this feature; their unavailable states remain visible.

Local preview: http://127.0.0.1:5186/?view=home&asOf=2026-09-10&lang=en
