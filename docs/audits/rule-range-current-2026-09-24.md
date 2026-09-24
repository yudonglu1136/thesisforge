# Rule portfolio range follow-up — 2026-09-24

Scope: Quality Rank Top 10 and Ackman quantitative proxy only. Saved user
strategies, Guru replication, source facts and private stores are not modified.

## Delivered behavior

- Shared start/end calendar controls, observed-session slider, 1/3/5/10-year
  presets, reset and URL restoration (`strategyTab`, `strategyFrom`, `strategyTo`).
- Both strategies' return, Sharpe (0% risk-free), volatility, maximum drawdown,
  stock win rate, payoff ratio, P&L distribution and extreme-stock evidence use
  that same interval. Loading/error states retain a visible distribution section;
  stale bars are not shown for the new range.
- The current selected quarter is executed and marked through the latest
  observed source day rather than waiting for its next completed quarter.
  Latest selection remains explicitly an incomplete return window.

## Source and independent checks

- Published input snapshot: `6f800cc44e5239b362451feb1b472625792e04236b4a6b00d28cdc6de2c7eb5b`.
- New snapshot: `4d4829b04e78520fc9376ed74d1939a9589ac4acda9f2348ab4cfac169f153b6`.
- Actual coverage: **2023-01-03–2026-09-21**, 932 sessions and 15 executions.
  September 21 is the latest canonical SPY/source price day, not today's date.
- Builder ran from clean committed source `68eee50`, not the unrelated dirty
  mixed-consideration engine experiment. It read existing immutable Fact OS;
  only the derived JSON changed. All pre-terminal historical marks reconciled.
  July 1 now includes its real rebalance fee, previously an unexecuted terminal
  mark; no artificial terminal liquidation was introduced.
- Independent stdlib Python share/fee replay: **932 × 2 daily checks passed**,
  including all turnover, scores, weights and headline metrics.
- Canonical interval replay: full, latter half, 101 sessions and 2 sessions all
  reconcile stock net P&L to portfolio return (maximum floating residual <1e-12).
  Local cold 17.28s; subsequent ranges 18–33ms. Not a production latency claim.
- Flutter strategy regression: **55 passed**, including calendar selection,
  presets, stale responses, both strategies, EN/ZH and 390px layouts.
- Flutter analyze: no issues. Bilingual audit passed. Production build passed
  with authentication bypass disabled.
- Fact OS full storage audit passed: no duplicate raw bytes. Repository layout
  retains 11 pre-existing findings (legacy sibling roots and one public DB);
  none were deleted or masked by this task. Original audit output is append-only.

## Explicitly NOT completed: 2013 extension

The older 2013 replay audit identifies mixed cash/share corporate actions and
CELG's BMY/CVR consideration. A fresh read-only native Sharadar query for BMYRT,
BMY.RT, BMY-RI, BMY.R and BMYr in the relevant 2019 window returned HTTP 200 with
zero observations for every candidate. Canonical identity has only ordinary BMY.
There is no verified, licensed historical CVR daily series in the current source.
CVR cannot be omitted, guessed, substituted with ordinary BMY or valued using
its subsequently expired outcome. Failed quarters cannot be concatenated away.
The UI explicitly states this coverage gap; 10Y is not labeled ten years of
available data. Full 2013-to-present delivery remains blocked on that history
and a reconciled corporate-action replay. No claim of completion is made.

## Release and rollback

Rollback backend: `range-api-b8968db`; frontend:
`dpl_85PrRhj1DqBoFmoYbkE5MbMJ4Das` (both production aliases).
Code-only EB deployment; no database, raw prices, credentials or user data in
the package. Production activation and browser evidence are recorded separately
after deploy. Reverting code/assets does not overwrite live private records.
