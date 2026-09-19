# Value Flow — integrated industry research

## Implementation brief and chart contract

Audience: an individual investor discovering an AI-related business, deciding which company to investigate in Research. This is not a stock recommendation or a strategy backtest.

Primary question: how do company-wide reported growth, cash generation and published valuation compare across the AI value-chain classification?

The default opens Compute chips with an explicit company selection and real dated observations. Eight selectable stage cards replace the terminal-only link. A company comparison and evidence panel connect stage → company → valuation/financial research without losing the workspace cutoff. Company logos reuse the shared StockLogo component. All interface copy is EN/ZH.

Chart family: hierarchy/ordered stage map, with exact-number company comparison (not a money-flow Sankey). Equal-size cards encode classification, not revenue exposure. A price-versus-published-value pair is exact lookup, not a fabricated return curve. No implied adjacent-stage contracts, no undated company links, no heat score repackaged as a return or valuation signal. Native Flutter is the rendering surface; mint is the selected/data highlight, amber is caution, neutral for context. Signed labels provide non-color distinction. Responsive card grid and vertically stacked evidence on mobile; no decorative empty panels.

Data: existing local paid PIT valuation inputs and price history; read-only scalar source extraction for the curated 74 ticker set, latest eligible model per ticker and cutoff, previous comparable fiscal period. Dates and currency checks gate model-gap and change calculations. Classification comes from the existing ontology_seed.json, version 2026-08-14, with translations from the existing Ontology i18n dictionary. Classification is current/retrospective, not a point-in-time investable universe. Financial/price/Guru observations must be public by asOf. Company-wide revenue is not AI-segment revenue.

Optional Guru evidence uses the existing disclosure aggregation, with its full/extracted-book scope shown. Absence from a bounded extract is not zero ownership. Optional source failure cannot invent zero holders or suppress valid financial data.

Acceptance: exact ticker navigation; dates survive drilldown; stage/search/filter/sort cause meaningful visible changes; missing data and failed requests have distinct usable states; no June cutoff can receive August financial evidence; no null-to-zero or currency mixing; empty filters offer reset; desktop and 390px EN/ZH visual verification and automated tests.

## Delivered and verified

- `GET /api/investment/value-flow?asOf=YYYY-MM-DD` is authenticated, preview-only, read-only and returns the curated map plus dated financial/price/disclosure evidence. A bounded per-source one-entry cache (60s, SQLite data-version checked) avoids repeated source extraction; response copies are isolated.
- No dates/numbers come from the empty default Ontology snapshot or its latest-only company fallback. The taxonomy is packaged configuration, not a dependency on an absolute developer path. No production source DB was changed.
- June 1: 74 mapped, 54 financial observations, 53 currency-comparable price/value pairs. August 28: 74 / 54 / 54. Missing 20 model records are not inferred, imported or regenerated in this interface task.
- Native Flutter preserves stage/search/filter/selected company when entering and returning from Research. The save-decision service recognizes `value_flow` as an origin only for mapped companies and records the retrospective classification version, without auto-saving a scenario or endorsing a model.
- Tests: 378 Flutter; 118 focused Node; 41 performance; 22 Ontology Node plus 3 exporter Python. Analyzer, i18n and local release web build pass. Nine new Node tests cover date isolation, null/breadth denominators, currency mismatch, nested future lineage, same-quarter revisions, method/version comparison, optional Guru failure, missing price versus missing model, taxonomy integrity.
- Browser acceptance: stage switching, global PLTR search, exact valuation route with unchanged cutoff, back-to-value-chain retaining search, value filter reducing Compute chips to NVDA/QCOM, mobile AMD selection and return-to-comparison, both languages. Output images: `output/value-flow-20260910/`.

All prices, gaps and growth figures are model/source observations, not investment recommendations. Standalone legacy Ontology remains unchanged. This is a local preview delivery; no deployment was requested or performed.
