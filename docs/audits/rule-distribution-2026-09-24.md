# Rule portfolio distribution and turnover — 2026-09-24

## Scope and calculation

The two strategies now have side-by-side, shared-count-axis bar charts on wide
screens, stacked on narrow screens. Horizontal categories run loss to profit;
bar-top counts, exact-bound tooltips, tap/keyboard readouts and population
percentages remain visible. Bins describe net portfolio-return contribution in
percentage points, not individual-stock returns or probability density.

The additive `turnover` response has independent method version
`rule-range-turnover-v1`; existing range attribution v1 stays compatible.
One-way turnover sums `(buy notional + sell notional)/(2 * pre-trade NAV)`
over actual simulated executions. Annualization is `252 / daily return intervals`.
Inception includes initial entry (100% invested = 50% one-way). Later start
dates are post-trade closes, so their opening-day trades are excluded. A
no-trade interval is zero. Corporate-action exchanges are not active turnover.
This does not change saved backtests, NAVs, price sources or rebalance rules.

## Fresh checks

- Turnover regression written first and reproduced the missing field.
- Range service tests: 10 passed, including partial ranges, zero turnover and
  corporate-action treatment.
- Strategy widget tests: 13 passed, including EN/ZH 1280px and 390px layouts,
  exact bins, shared axes and interval-changing turnover values.
- Clean publishable source Node suite: 1,718 passed, 15 skipped, zero failed.
- Full Flutter: 600 passed, 32 failed. Failure names exactly match the previous
  baseline log (zero added/resolved); existing Discover/Research/Portfolio
  failures are not reclassified as passes or fixed by weakening assertions.
- Full Flutter analyzer, bilingual audit, 60 performance checks and production
  build passed; compiled authentication bypass remains disabled.
- The runtime verifier independently compares range turnover against persisted
  per-execution receipts and asserts distribution counts equal the population.

## Release gate and recovery

Production code commit `930795e8cf4beef01ad0e1b1a152577df0f7ae18` was pushed to
trunk and deployed. Code-only release;
no database, Fact OS generation, scheduler, private records or secrets changed.
Existing 2023-01-03 through 2026-09-21 coverage is unchanged; this is not a
2013-history release. Unrelated dirty 2013 backtest work is excluded.

Rollback targets: EB `range-current-de05905`; Vercel
`dpl_DC9PToXuQkbKLYLzouwSYjgWxyrm` for both public domain aliases. Restore code
only, retaining installed data and all user stores.

## Production verification

- EB `distribution-930795e`: Ready / Green. Package SHA-256
  `1bad4267e2d05ecb8003a15fa364aef93136f25fa17e767a3556b886cb3b4fea`.
  Unmodified provenance gate passed on a bounded, clean export of committed
  source; no SQLite, DuckDB, Parquet or frontend `dist` was packaged.
- Vercel app deployment `dpl_2xyiJ3jRTtKVyWGZYGFEBxdo87Fe`,
  `thesisforge-7eueev7az-yudonglu1136s-projects.vercel.app`, Ready. Both apex and
  www were independently inspected and served the same tested JS SHA-256:
  `ac81731787053e7836de76a39dc2639f44d9416833158e8675895885b879f31c`.
- Both domains: health HTTP 200 / `ok:true`, with existing `stale`/degraded
  source freshness (not claimed fully healthy); anonymous analysis HTTP 401.
- Actual `webapp` user, immutable request-scoped production input: SSM command
  `97ed1c6e-2cac-4752-a2b3-415c555735af` passed all four windows, both strategies.
  Every turnover reconciled with stored execution receipts and all distribution
  counts matched the stock population. Snapshot is unchanged:
  `4d4829b04e78520fc9376ed74d1939a9589ac4acda9f2348ab4cfac169f153b6`.
- Full-range one-way turnover: Quality 652.26925394%, Ackman 927.54650513%.
  Annualized: 176.55408377%, 251.06521943%; each has 15 execution dates.
- Signed-in production UI: both charts, exact-bound tap/hover readouts, EN/ZH
  desktop and 390x844 checked. Switching to 1Y selected 2025-09-22–2026-09-21
  (251 observations), updated turnover to 140.15% / 250.71%, annualized to
  141.27% / 252.71%, and populations to 18 / 60. Browser error log was empty.
- Cold standalone replay took 81.5 seconds under simultaneous browser replay;
  warm ranges took 61–160ms. This release does not claim to fix cold-start cost.
- Runtime receipt, fresh test logs and screenshots retained locally under
  `data/fact_os/audit/rule-distribution-20260924/` (not committed/licensed data).
