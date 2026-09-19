# Fundamentals: business-change workbench

Native Flutter implementation; local preview only. No production models or paid data modified.

## Product brief

For a self-directed investor deciding what to research next: find changes in a
business, check whether profits and cash support the growth, then challenge the
price with a personal valuation. This is distinct from Guru ownership discovery
and the curated AI Value Flow taxonomy.

Primary flow: select a research question → compare current/prior observations →
select a company → inspect eight fiscal quarters and potential counter-evidence →
open financial evidence or personal valuation. Preserve filters and selection on return.

## Data / metric contract

One latest available operating-business model node per ticker, plus a distinct
prior fiscal period. Universe means stored operating-company coverage, NOT all
listed companies or a survivorship-free index. Sources are the existing read-only
PIT database and dated price history. No current price enters model valuation.
The allowlist includes `operating_company`, `multi_method_growth` and
`revenue_stage`; a blended valuation does not exclude NVDA/PLTR/TSLA from
fundamental research. Financial institutions, customer-cash businesses and
treasury-asset routes are not treated as comparable operating FCF businesses.

Validate complete latest-node lineage before display; invalid latest data is not
replaced by older data. Delta screens require adjacent ARQ periods (60–120 days),
same model version and currency. ART growth is withheld, not labeled quarterly.
Revenue growth is reported quarterly YoY, not organic growth. Margins are TTM.
Cash flow is CFO minus capex, not verified parent-economic FCFE. Comparisons are
observations, not causal attribution or a quality score. Missing values stay null.

Screen version: `fundamental-changes-v1`; categories overlap:

- Acceleration: revenue YoY ≥15%, up ≥5 percentage points versus prior quarter's YoY.
- Profit: positive revenue growth and positive operating margin, margin up ≥2pp.
- Cash: revenue YoY ≥15%, positive FCF margin, FCF margin flat or higher.
- Divergence: revenue YoY ≥15%, operating or FCF margin down ≥2pp.

Valuation gap = model fair value / dated price − 1; requires positive numbers,
matching currencies, price at/before cutoff and at most seven days old. Source
price and date remain visible when a gap is withheld. Values are historical PIT
reconstructions, not proof that the platform published a live signal then.

## Visual contract (before implementation)

- Compact ranked comparison table: exact company lookup, latest values and signed
  changes, no arbitrary composite score. Default sort: acceleration descending;
  each research screen changes its qualifying set and evidence emphasis.
- Selected company: horizontal eight-quarter matrix (family: cohort matrix),
  rows = revenue YoY / TTM operating margin / TTM FCF margin; columns = actual
  fiscal periods with source availability dates. Exact values carry meaning;
  mint/amber signs supplement text. No interpolation or fabricated quarters.
- Retain existing graphite/mint design tokens, stock logos and Guru avatars.
  Full-width stacked evidence on mobile; desktop table and inspection pane.
- Scope/source notes in expandable methodology; material coverage limitations
  remain next to the affected metric. Financial facts, model value and research
  questions have distinct labels.

## Reproducible checks

`node --test server/investmentFundamentals.test.js` — synthetic fixtures, not
production inputs. Runtime audit uses `buildFundamentals` with
`output/investment-workflow-20260908/runtime.sqlite` at 2026-06-01 / 2026-08-28.
Widget tests and desktop/mobile EN/ZH visual checks are recorded after completion.

## Validation results

Read-only runtime results (not a new valuation release):

| Cutoff | Stored tickers | Operating businesses | Comparable pairs | Comparable values | Acceleration | Profit | Cash | Divergence |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2026-06-01 | 532 | 459 | 452 | 455 | 67 | 41 | 55 | 28 |
| 2026-08-28 | 532 | 459 | 455 | 446 | 64 | 51 | 76 | 35 |

Both cuts exclude 71 non-operating model routes and withhold two invalid latest
source nodes. These are explicit existing coverage limits, not repaired or hidden
by the redesign. Categories overlap. No missing company or price is synthesized.

- 10 dedicated backend tests: thresholds/nulls, time cutoff, source lineage,
  revisions versus actual quarters, ARQ/ART distinctions, incompatible periods,
  multiple operating valuation routes, currencies/stale prices, cache isolation,
  authentication and private cache headers.
- 129 focused backend regressions passed across Fundamentals, Value Flow,
  Opportunities, personal workflow, Portfolio and Strategy Lab. Saved decisions
  retain `fundamental_research`, screen version, observed matching screens,
  source hash and comparison status; legacy ≥15% origin remains unchanged.
- 8 new widget tests; 23 focused widget regressions passed. Full Flutter suite:
  386 passed. Phone tests include 390px / 120% text and both languages. Stale
  async results and wrong-cutoff responses cannot overwrite the current view.
- Analyzer clean; bilingual audit passed; performance regression suite 41;
  Ontology 22 Node + 3 Python; production build and local preview build passed.
  `--built` Ontology verification is of generated `dist/`, not the preview folder.
- Browser: four distinct question screens, mobile NVDA search/detail, EN→ZH,
  exact SMCI valuation handoff and preserved screen/company on return. Evidence
  uses source observations, including negative margins and missing quarters.
- HTTP local checks: no-auth 401, impossible calendar date 422, June and August
  200 with private/no-store headers and counts reconciling to the source read.

Screenshots: `output/fundamentals-20260910/`. No production deployment, GitHub
push or production-auth certification. No performance improvement claim from
these local checks. This work does not alter the valuation model or source data.
