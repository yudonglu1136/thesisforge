# Four Discover research lenses

Implemented locally on 2026-09-09. No GitHub push or production deployment.

## Product behavior

| Entry | Evidence shown | Next step |
| --- | --- | --- |
| Shared additions | New/increasing managers, real portraits, prior/current reported shares, share-change percentage, ending disclosed-book weight and filing date/source | Open the manager's exact selected-stock quarterly history; then test the price |
| Growing businesses | Prior/current quarterly revenue growth, TTM operating margin, FCF margin and capex/revenue; percentage-point changes | Read the selected company's quarterly earnings evidence and Q&A, then set assumptions |
| Value moving up | Exact dated prior/latest published values, comparable model revision, date-aligned financial observations | Stress-test the selected company in the personal valuation worksheet |
| Two sides of the trade | Separate increased/new and reduced/exited manager rosters, portraits, share changes, book weights and filings | Investigate ownership disagreement without inventing motives, then test valuation |

The same company may qualify for several screens. Switching cards now changes
the research question, leading/trailing list columns, selected-company evidence
and specific action. It does not overwrite data or a user's scenario. Existing
price/value history, historical dates, full holder disclosures and Research
navigation remain accessible. Returning from Research keeps the selected lens.

## Evidence boundaries

The current bounded local extract at 2026-08-28 contains 27 managers, 573
securities and 243 comparable valuations. Lens counts are 52 / 55 / 108 / 17;
these are overlapping screens, not additive or claims of all-market coverage.

- Share changes use a positive observed previous-share denominator; new or
  missing-denominator positions do not receive an invented percentage.
- Ending weight is within each manager's disclosed common-long book, not fund
  AUM or an inferred purchase size. Groups use reported actions, excluding mixed
  claims. Corporate-action adjustments remain explicitly unverified.
- The read API now returns the actual previous fair-value endpoint, when present.
  A revision requires strictly ordered dates and nonempty matching currency,
  formula and model version. Missing currency cannot qualify as comparable.
- Financial comparison is shown only when detail-history dates match both
  revision endpoints. It is not a causal attribution bridge or standalone DCF.
- Selecting another historical timeline date hides the cutoff-specific lens
  evidence rather than silently presenting current evidence as historical.
- Missing models remain missing. Model-dependent actions cannot invent coverage.

## Verification

- Flutter: 337 tests passed, including 28 focused lens tests; EN/ZH and desktop/
  phone layouts, grouping, navigation, missing data, expansion and no-write checks.
- Backend investment suites: 65 passed, including exact revision endpoints,
  cutoff isolation and missing-currency exclusion. Performance suite: 41 passed.
- Analyzer, bilingual audit, release build and diff whitespace check pass.
- Real browser: all four screens on GOOGL; growth → earnings/Q&A; revision →
  private assumption worksheet; back preserves context; Buffett → exact filing
  and GOOGL quarterly trajectory; EN/ZH 390px mobile; final console error log empty.
- Paired visual comparison, iteration history and scope are in `design-qa.md`.
  Native captures are under `output/discover-lenses-20260909/`.

The preview is loopback-only and uses the existing private development-auth
configuration. It is not a production artifact and must not be deployed as-is.
