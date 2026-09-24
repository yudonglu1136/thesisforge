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

Production verification pending at this source commit. Code-only release;
no database, Fact OS generation, scheduler, private records or secrets changed.
Existing 2023-01-03 through 2026-09-21 coverage is unchanged; this is not a
2013-history release. Unrelated dirty 2013 backtest work is excluded.

Rollback targets: EB `range-current-de05905`; Vercel
`dpl_DC9PToXuQkbKLYLzouwSYjgWxyrm` for both public domain aliases. Restore code
only, retaining installed data and all user stores.
