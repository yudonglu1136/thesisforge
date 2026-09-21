# Fundamental research workbench — local delivery report

Date: 2026-09-21  
Scope: local implementation and verification only; no production deployment.

## Delivered flow

The Fundamental area now uses the Fact OS company universe rather than the valuation-model universe. The implemented path is:

1. Search 5,418 companies with reported facts.
2. Start from one of six deterministic business-change questions.
3. Open a company workspace with an evidence-backed judgment, three changes, contrary evidence or an explicit explanation gap, and a relevant trend.
4. Inspect formula, comparison period, public-availability date, source lineage, and method version.
5. Continue into research, optional valuation assumptions, or save an observation for later review.

The six discovery lenses are growth plus profit, slowing growth plus improving margin, profit improvement plus weaker cash conversion, per-share dilution, capital awaiting return, and operations-versus-price divergence. Rankings use signal magnitude, evidence completeness and filing recency; ticker is only the final tie-break.

## Real-data coverage

- Fact companies: 5,418
- Companies with at least one comparable change signal: 1,578
- Latest public-availability date in the discovery universe: 2026-09-18
- Fundamentals table: 3,217,652 rows, 1990-06-06 through 2026-09-18
- Discovery uses the latest visible ARQ revision by requested as-of date. MRQ/MRY restated dimensions are not mixed into historical reported analysis.
- The full Fact OS audit completed with no missing required tables, no incomplete backfills, no duplicate natural keys, and a stable catalog generation.
- Fact OS storage audit passed with `raw_duplicate_bytes = 0`.

Specialist companies remain searchable. The six default discovery rankings intentionally require an operating-company template, at least eight comparable quarters, at least USD 100 million of TTM revenue, and bounded growth/margins so tiny-base and non-comparable records do not dominate the default research feed.

## UBER verification

The selected “slowing growth, improving profitability” path produces:

- Quarterly revenue growth: +12.2%, versus +14.5% for the prior comparable observation
- Growth deceleration: -2.3 percentage points
- TTM operating margin: 12.1%, up 0.5 percentage points from the prior quarter and 2.6 percentage points year over year
- TTM FCF margin: 18.3%
- Contrary evidence: TTM common net income declined 24.1%
- Candidate peer set: 213 companies after economic-template-first grouping
- Valuation status: not modeled; the company remains fully searchable and researchable
- Explicit research gap: Gross Bookings, Trips and take rate are not present in the current Fact OS schema

## Performance

Measured locally with `npm run bench:fundamental` against the current Fact OS catalog:

| Path | Time |
| --- | ---: |
| Cold discovery universe | 2,189 ms |
| Warm lens switch | 8 ms |
| Warm search | 8 ms |
| UBER detail with history, lineage, peers and optional valuation check | 741 ms |

The discovery endpoint returns a compact ranked subset rather than all raw rows. A short-lived, generation-aware universe cache serves lens/search changes; detailed company history and source records load only when a company is opened.

## Validation performed

- `flutter analyze`: no issues
- Fundamental Flutter tests: 9 passed, including Chinese, English and 390px flows
- Fundamental Node and authenticated route tests: 20 passed
- Fact OS repository tests: 28 passed
- Full Fact OS audit with full key scan and offline probes: passed
- Flutter Web production build: passed
- Manual in-app-browser verification: desktop and 390px mobile, English and Chinese, UBER discovery to detail, source lineage modal

The automated cases cover missing quarters, negative comparison bases, duplicate amendments, facts without a valuation model, different currencies, stale/missing prices and valuation model-version changes. Missing and inapplicable values remain unknown rather than being filled with zero.

## Semantics and limits

- `netCommonFinancing` is presented as net common-stock financing, not gross repurchases.
- Capital return is explicitly labeled pre-tax capital return, not after-tax ROIC.
- Working-capital causality is not inferred from balance changes alone.
- Price comparisons use Sharadar split-adjusted close.
- Company-specific KPIs such as ARR, orders, Trips and take rate are shown as research gaps when absent.
- Banking, insurance and payments companies are classified separately; unsupported specialist metrics are not fabricated.
- Peer groups are candidate research sets, not mechanically approved comparables.
- Saved observations preserve the selected lens and evidence so the claim can be reviewed later.

The repository-wide storage-layout audit still reports pre-existing retired sibling directories and the zero-byte `server/data/valuation-pit-source.sqlite`. They were not created or modified by this work and were intentionally left untouched to protect unrelated local data.
