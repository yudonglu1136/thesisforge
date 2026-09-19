# Fundamentals: combine factors → shortlist → company evidence

Local delivery only. No production deployment, valuation rewrite, portfolio
mutation or synthetic observations. The dashboard design keeps the rules and
their results visible together; the company workbench separates financial and
13F reporting quarters.

## Interaction and interpretation

- Growth, profitability, cash flow and durable ROIC are independently toggleable
  factors. Card counts describe each individual factor across the same covered
  universe; the result list combines them with ALL or ANY logic.
- Default: quarterly revenue YoY >=15%, TTM operating margin >=10%, TTM FCF margin
  >=5%, all required. These are editable research thresholds, not calibrated
  investment scores. Optional strict quarter-over-quarter improvement requires
  positive changes in each enabled quarterly metric.
- Optional ROIC: every year in a complete 3/5/10-year window >= user threshold
  (default 15%, five years). Uses the paid Jansen/SF1 **pre-tax EBIT / average
  invested capital** series, not after-tax ROIC. Same annual lineage, continuity
  and freshness gates as `discover-growth-quality-2026-09-10.md`.
- Missing / non-finite inputs do not pass. ALL rejects any selected missing
  factor; ANY can include a company on another passing factor, with the missing
  factor marked explicitly. No selected factors means unfiltered coverage.
- Default ranking is number of matching selected factors, then ticker. This is
  a transparent screen, not a composite quality rating or buy recommendation.
  Revenue, metric-change and model-gap sorting and a price-below-model filter
  remain available. Weakening cash/margin inspection remains a separate lens.
- Each row shows the matched-factor count. The company workbench has Valuation,
  Financials and Guru quarter tabs. Valuation explains each condition, shows
  dated price/model/gap and links to the existing private assumption worksheet.
  Financials compares quarter metrics and retains the horizontal eight-quarter
  evidence table and entry into full financials/management guidance.
- Guru quarter shows manager avatars, reported new/increased/reduced/exited
  holdings, share changes, weights, filing dates and source links. Calendar 13F
  quarter is independent of company fiscal quarter and workspace cutoff.
  Share changes are not labeled verified executions. Missing activity is not
  labeled unchanged. Tiny nonzero weights are not rounded to zero.
- Company, rules, query, detail tab and selected Guru quarter are retained for
  an in-session Research round trip. Cutoff changes reset the Guru-quarter
  selection. Out-of-order responses cannot overwrite another ticker/date.

## Data and API

`buildFundamentals()` reads the existing PIT model/financial source and joins
the existing structured annual quality table by exact ticker and cutoff.
It does not change model formulas or use market price as a model input.

Authenticated, read-only, private/no-store endpoint:

`GET /api/investment/fundamentals/:ticker/gurus?asOf=YYYY-MM-DD&quarter=YYYY-MM-DD`

This reuses the existing Discover exact-common-claim aggregation and cached
quarter books. Only publicly available filings qualify. Full current books need
the matching accession; otherwise the response explicitly uses historical
extracts. No matching row is not proof of no ownership. Same 27-manager signal
universe as Discover, including its quant exclusions. No substitute ticker.

## Observed reconciliation — 2026-08-28 cutoff

Source: local `output/investment-workflow-20260908/runtime.sqlite`, read-only
API checks, and browser UI (not an independent audit of every issuer filing).

| Condition | Companies passing |
|---|---:|
| Covered operating companies | 459 |
| Growth >=15% | 146 |
| TTM operating margin >=10% | 339 |
| TTM FCF margin >=5% | 351 |
| Five consecutive annual ROIC observations each >=15% | 132 |
| ALL growth + profitability + cash flow | 81 |
| ALL above + five-year ROIC | 38 |

There are 455 comparable quarter pairs. Latest growth is unavailable for five
companies; 21 companies lack a complete valid five-year ROIC window. Two invalid
source nodes and 71 other model routes are withheld by the existing source gate.

Example drilldown: MSFT fiscal 2026-Q4 financials (disclosed 2026-07-29), while
Guru report quarter 2026-06-30 has 11 observed holders, four adds/new and five
reductions/exits, across 27 full current books. The 2026-03-31 selection instead
has six observed holders, one add/new and six reductions/exits across 27
historical extracts. These counts must not be interpreted as an ownership
increase between equally complete universes.

## Verification

- Flutter full suite: 429 passed; backend investment suite: 124 passed.
- New tests exercise ALL/ANY, nulls and invalid thresholds, strict improvement,
  missing ROIC, editable conditions, separate valuation/financial/Guru tabs,
  historical-quarter switching, identity failure, response races, restoration
  and EN/ZH 390px layouts at 120% text size.
- Existing PIT tests cover future disclosures, amendments, exact share-class
  identity, price age/currency, quality availability and private authentication.
- Analyzer, bilingual audit and local release build pass. A discovered annual
  window dropdown overflow was fixed with an expanded layout.
- Browser checks use actual local records and do not save investment decisions:
  1600px English ALL/ROIC count reconciliation (81 → 38), MSFT Guru Q2 → Q1,
  entry into the MSFT DCF worksheet and return with all four rules, search and
  Guru Q1 retained. At 390px Chinese, AAPL financials show eight actual quarters
  and the Guru tab displays current-quarter avatars, shares and dated filings.

The shortlist is an investigation aid. Historical reconstructions are not
archived real-time recommendations, and reported growth may reflect acquisition
or base effects. Cash flow here is CFO less capex, not verified parent FCFE.
