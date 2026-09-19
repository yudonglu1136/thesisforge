# Strategy Lab — implementation and audit contract

## Product

Inside the existing Flutter Strategies workspace: select one or more managers,
each manager's Top 1–10 common-long holdings, an optional maximum price premium
to published fair value, and an optional KMLM/DBMF ETF allocation. Research only;
this neither places orders nor alters a connected portfolio or old strategy.

The comparison is unfiltered Guru selection, valuation-filtered stocks, the
filtered stock/CTA blend, and SPY, over the identical requested period. No
automatic best-parameter search or claim of out-of-sample performance.

## Rules fixed before results

- Rank the stored canonical quarterly common-long extract by reported value,
  after aggregating exact CUSIPs. Supported Top N is capped at the extract's
  documented Top 10 scope, not a claim of full-book availability.
- Merge duplicate securities across managers; equal-weight unique securities.
  Do not substitute an issuer or another share class for unresolved identity.
- First execute at a market close strictly after public availability. Historical
  runs use the last eligible book per manager and rebalance after each selected
  manager's newly public **original quarterly** filing. Weights drift between
  events. Later amendments/confidential supplements are deliberately not applied;
  this is an original-disclosure strategy, not a silently hindsight-restated book.
- Filter decision uses the preceding SPY session's stored comparison close and
  the latest model available by that session. Premium = price / fair value - 1;
  strictly greater than the threshold is expensive. Published fair value may
  be blended; do not label it a standalone DCF.
- Missing/incomparable/stale model inputs retain their original slot in cash.
  Expensive-stock slots may either remain cash or be redistributed across
  valuation-eligible names, as explicitly selected. Do not backfill Top N with
  lower-ranked stocks. All-excluded stocks remain cash, not a fabricated return.
- CTA is a fraction of the total portfolio, reset at the same disclosure
  rebalances. It is a real ETF adjusted-close series, never a pre-launch index
  reconstruction. Cash earns 0%; no leverage, interest, tax, or extra ETF fee
  deduction. ETF fees are already reflected in observed prices.
- Stocks/ETF/SPY returns use dividend- and split-adjusted closes. Missing active
  observations fail closed. Execution coverage must be at least 90% of selected
  equal-weight stock slots before valuation filtering; missing price slots stay
  cash and may not be redistributed. Corporate actions use the existing audited
  engine/catalog; unsupported actions remain failures.
- Modeled costs apply to gross traded notional (buys plus sells), including
  entry, at each rebalance. Fractional units allowed. Comparison curves use the
  same cost rule; SPY is a separately labeled gross buy-and-hold benchmark.
- Source models were reconstructed retrospectively. The result is a
  retrospective PIT research replay, not an archived live strategy.

## Chart contract

- Question: how do filtering and the CTA sleeve change the same historical
  selection's growth and drawdown?
- Native Flutter straight-segment daily indexed line chart, starting at 100
  before modeled entry costs; a separate drawdown mode. At least 20 observations
  required, otherwise a data-coverage state. No smoothing or invented sessions.
- Mint selected blend, blue filtered stocks, muted unfiltered stocks, amber
  dashed SPY; explicit labels, legend, and a dated hover/tap readout.
- Free two-handle range selection rebases all curves and recomputes metrics
  from full daily observations. No resampling in the returned analytical data.
- Allocation: labeled stock/CTA/cash strip. Rebalance audit: exact lookup table
  with source quarter, decision date, excluded reasons, price/FV and weights.
- Desktop and 390×844 mobile, EN/ZH, loading/errors/empty/changed-rule states.

## Sources and release boundary

Read-only runtime SQLite: guru exposure, stored audited filing metadata,
valuation PIT model runs, comparison prices, and adjusted price_points. ETF
prices are a separate private, hashed artifact; no replacement of paid rows.
One coherent published model version per issuer is replayed; historical input
availability and guidance lineage are checked at each model node. Comparison
snapshots may be sampled: daily raw closes can backfill them only when a known
provider/field/basis has at least two corroborating overlaps with no conflicts,
inside the verified snapshot date bounds. Adjusted return prices are never used
as price/fair-value comparison prices.

Eighteen missing original SEC information tables were recovered from exact
stored SEC accession/XML links and reconciled to the audited original common-long
total (including the historical dollars/thousands scale). Raw XML and parsed
full-CUSIP books live in a separate hashed private artifact. This restores three
Buffett quarterly rebalances that exposure snapshots had replaced with later
supplements. Original filing metadata is used only for the calendar and source
identity; previously pruned Top-8 backtest weights are never used as holdings.

One recovery is blocked: Stan Moss, 2023-12-31 original accession
`0001172661-24-000776`, public 2024-02-13. Parsed common-long value is
$41,464,039,057 versus stored $41,460,551,357, a $3,487,700 difference. No amount
was altered to force reconciliation. A run crossing its 2024-02-14 execution
fails explicitly with `original_filing_missing`, rather than retaining an older
quarter. All source SQLite handles in recovery/verification are read-only.

KMLM issuer: https://kraneshares.com/etf/kmlm/ (inception 2020-12-01).
DBMF issuer: https://www.imgp.com/us/fund/US53700T8273/ (inception 2019-05-07).
Actual first price observation, not an invented launch close, bounds the run.

Local preview only. Production activation, deployment and source migrations
require a separate reviewed release. Never publish a development-auth build.

## Verification

Completed local acceptance on 2026-09-10; not a production deployment.

- 370 Flutter tests passed, including 13 Strategy Lab tests: explicit run/save,
  manager selection, Top N, premium/CTA payloads, same-result numeric transport,
  dirty/result separation, stale cutoff rejection, retry, private save/cancel,
  exact-symbol research navigation, daily range math, and both languages at
  390×844 / 1.5× text. Full analyzer: no issues. Release web build passed.
- 119 backend tests passed across strategy rules/source artifacts/routes,
  the existing backtest engine, investment workflow and portfolio regression
  suites. Coverage includes original filing gaps, options/debt/CUSIP parsing,
  no-lookahead execution, premium boundary arithmetic, all-cash periods,
  unknown slots, corporate actions, price holes, CTA drift, gross turnover
  costs, owner isolation/idempotence, and the two-worker concurrency bound.
- 41 existing API/performance regression tests and bilingual audit passed.
- Nine real-source scenarios: seven complete, two expected explicit blockers
  (KMLM before inception and the unreconciled Stan Moss original). Deterministic
  reruns matched; all ledger target weights sum to one; every model precedes
  its decision date and every execution follows public filing availability.
  Verification source writes: **0**. Source-load plus calculation took
  35–464 ms across this local run; a real HTTP worker request took 505 ms.
  These are observed timings, not a production latency SLA or a before/after gain.
- Browser checked 1600×1100 desktop and 390×844 mobile EN/ZH: manager avatars,
  three-step inputs, KMLM 30% / DBMF 50% switching, dirty results, dated audit,
  recovered 2025-05-16 book, growth/drawdown, free range and responsive tables.
  Exact GOOGL drilldown opened the Valuation worksheet at the unchanged workspace
  cutoff; historical audit inputs remained separate. Browser error log was
  empty. Numerical screenshot values match backend audit.

Real-source diagnostic:
`output/strategy-lab-20260909/verification-release-candidate.json`.
Older `verification-final.json` and screenshots 01–03 precede original-filing
recovery and are superseded, not final evidence. Current screenshots 04–12
include the builder, 13-rebalance KMLM/DBMF results, audit and mobile EN/ZH views.

### Reproducible numerical example (not an investment recommendation)

Warren Buffett, Top 5, 2023-08-28 → 2026-08-28, 30% maximum price premium,
expensive slots redistributed to eligible names, 10 bps on buys plus sells,
cash 0%, KMLM target 30%. All four series have 754 daily observations; there
are 13 rebalances and 100% minimum execution/model coverage for this example.

| Series | Total return | CAGR | Max drawdown |
| --- | ---: | ---: | ---: |
| Guru, unfiltered | 89.68% | 23.78% | −18.44% |
| Valuation-filtered stocks | 91.76% | 24.23% | −13.26% |
| 70% filtered sleeve + 30% KMLM | 60.55% | 17.09% | −9.15% |
| SPY, gross buy-and-hold | 80.36% | 21.72% | −18.76% |

At the same dates, DBMF 50% produces 61.62% total return / 17.35% CAGR /
−6.29% maximum drawdown. A tighter 15% limit with KMLM 30% produces 25.01%
total return / 7.72% CAGR; its latest equity sleeve is all cash. Filtering is
not assumed to improve returns. Ackman's five-year replay runs, but minimum
valuation coverage is 0% in early history: its cash-heavy result is explicitly
flagged, not evidence of a fully covered valuation strategy. Neither ETF is
backfilled before its actual first observation; stock-only comparisons remain
available when the CTA series is blocked.

### Local runtime wiring

The existing gated local preview requires these additional environment values:

```sh
STRATEGY_ETF_INPUT_PATH=output/strategy-lab-20260909/etf-inputs.json
STRATEGY_FILING_INPUT_PATH=output/strategy-lab-20260909/original-filings/filings.json
```

New artifacts can be prepared with `scripts/build-strategy-etf-inputs.mjs` and
`scripts/build-strategy-filing-inputs.mjs`; they do not migrate the paid source DB.
Use a new output directory for filing recovery. The read-only repeatable check
is `scripts/verify-strategy-lab.mjs runtime.sqlite etfs.json NEW_REPORT.json`
with the filing artifact environment variable above. New routes are the gated,
authenticated `/api/investment/strategy-lab`, `/strategy-backtests` and
`/strategy-rules`. Backtesting does not save anything; Save rules appends an
owner-scoped version and leaves old terminal strategy records untouched.
