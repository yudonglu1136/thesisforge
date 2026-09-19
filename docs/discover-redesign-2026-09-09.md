# Discover — dated research explorer

Scope: redesign and implement the existing local Flutter Discover route. This is not a deployment, new valuation release or historical filing refresh. The source is the existing isolated PIT runtime; the paid source tables, published models, prices, backtests and production accounts were not edited.

## Product changes

- Discover is now a discovery surface rather than a second Home. Four rule-based collections introduce concrete research questions, counts and real examples.
- Shared additions: at least two managers report a new position or increased shares. Growing businesses: operating-company route and reported quarterly revenue growth at least 15%. Value moving up: at least 5% increase between comparable published-model nodes. Two sides: at least two adding managers and at least two reducing/exiting managers. These are screens, not buy recommendations or quality scores.
- The explorer combines company identity, manager avatars and counts, reported adds/trims, reported revenue growth, model gap, dated model availability and model change.
- Search, manager filter, coverage filter and five sorts intersect. Nulls sort last, negative values remain visible, ties use ticker order, and filtered-out selections cannot masquerade as matching evidence. Filters survive reload and a round trip into valuation.
- Selection connects the exact ticker to the existing price/value curve, disclosure timeline, business metrics, guidance, watch action and personal-scenario or published-method route. Back returns to Discover, not Home. No extra trade, portfolio or watch record is created by exploring.
- Managers remains a full catalog and quarterly-research entry. Fundamentals covers the broader eligible operating-company universe with 15% / 25% / 50% growth thresholds and ticker search. Value Flow preserves the existing industry-graph handoff and its separate cutoff disclosure.
- Graphite palette, existing typography, genuine logos, avatars and chart components are reused. Desktop has four collections above list/detail; mobile uses a compact collection carousel and shows company detail without the collection rail. Form labels and selectable button semantics are retained.

## Dated data, not invented coverage

Observed at the local 2026-08-28 cutoff / 2026 Q2 filing quarter:

| Surface | Observed count |
| --- | ---: |
| Eligible concentrated-manager books represented | 27 |
| Observed common-share securities including reported exits | 573 |
| Comparable model-and-price observations | 243 |
| Shared-addition collection | 52 |
| Operating-company growth collection | 55 |
| Comparable upward model revisions | 108 |
| Two-sided disclosure collection | 17 |
| Broader operating-company growth screen, at least 15% | 101 |
| Broader growth screen, at least 50% | 18 |

Collection sets overlap; their counts must not be summed. The manager catalog is broader than the concentrated-manager screen. Missing models, unavailable prices and unreconciled currency remain explicit coverage gaps. Historical extracts still disclose manager counts as lower bounds. Reported growth is not organic growth; acquisition/base effects require further investigation.

## Implementation boundaries

`lib/investment_explorer.dart` contains the deterministic filter function and Discover components. Existing discovery, workflow, breadcrumb and Graphite-shell files handle navigation and retained functionality. `server/investmentOpportunities.js` adds only the stored, dated economic-route scalar to the existing bounded SQL read; it does not change any DCF, score, cash-flow, ownership or currency formula. No collection loads every company detail/transcript blob.

## Verification

- 15 new Discover tests: exact collection boundaries, non-operating/unknown route exclusion, null coverage, negative/tied sorts, intersected filters, search/reset, network retry, valuation round trip, actual dropdowns, broader-growth controls, both languages at 1487×1058 / 1280×720 / 390×844.
- Full Flutter suite: 237 passing. Static analysis: no issues. Release web preview build: passing.
- Workflow/read-model backend suite: 45 passing, including the new dated economic-route lineage test. Existing ownership, identity, temporal, immutability and private-route tests remain passing.
- Performance regression suite: 41 passing. No production latency or improvement percentage is claimed.
- Bilingual audit and tracked diff whitespace checks: passing.
- Browser: actual collection click, GOOGL search, personal-valuation open/back, URL-state preservation after reload, growth-threshold changes, manager catalog and responsive captures. Screenshots and final visual checks are recorded in the root `design-qa.md`.

Preview: `http://127.0.0.1:5184/?view=discover&asOf=2026-08-28&lang=en&candidate=NVDA`.

This private preview uses a development identity and must never be promoted as a production artifact. AWS / Vercel / GitHub have not been changed by this task.
