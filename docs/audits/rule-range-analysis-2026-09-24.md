# Selected-range analytics for the two rule portfolios

## Scope and statistical contract

`GET /api/investment/investor-styles/analysis` is authenticated and binds its
request to the reviewed dashboard SHA, cutoff and two observed session dates.
It does not refresh strategies, publish new prices, modify user records or change
the existing curve. Both Quality Rank Top 10 and the Ackman quantitative proxy
are analyzed irrespective of which curve/holdings tab the user selects.

- Return, calendar CAGR, sample annualized volatility (252 sessions), zero-Rf
  Sharpe and peak-to-trough MDD use every daily **net** NAV in the window.
- At the global first observation, initial entry cost is included. At an
  interior start, that session's post-cost close is the opening mark; preceding
  returns and the opening session's already-paid costs are excluded.
- Stock P&L is additive attribution, including marked open holdings, not FIFO
  closed-trade accounting. Repeated exposures to the same ticker are aggregated.
  Win rate = profitable stocks / (profitable + losing stocks); flat stocks are
  disclosed separately. Payoff = mean winning net P&L / absolute mean losing net
  P&L. An absent winning or losing population yields null, never zero/infinity.
- Histogram bins are fixed for both strategies and measure net contribution in
  percentage points of starting NAV; bar lengths are stock counts.
- Illustrative dollar amounts scale the selected interval to USD 100,000. They
  are not the user's account balance. Actual rebalance buys/partial sales retain
  dates and total-return-adjusted simulation prices. Boundary marks and open
  positions are labelled separately. These are **not historical raw fills**.
- Corporate cash settlement is not a sale. Verified stock conversions net the
  successor claim against its target. Conversion returns stay with the source
  sleeve until the next rebalance. No missing price is interpolated or filled.
- The latest displayed but unexecuted quarterly selection is not executed or
  charged simply because its date equals the last curve observation.

## Data and replay

Canonical Fact OS identity-based price reads use the existing repository, bounded
batches and immutable-generation checks. No database, raw prices or duplicate
security master is created. The in-memory replay is single-flight and invalidated
on source generation/cutoff changes. All daily NAVs, recorded turnover/costs and
stock P&L sums must reconcile before stock analytics become available. A newer
price generation incompatible with the published curve fails explicitly; it does
not silently replace the curve. The ordinary NAV metrics remain usable on error.

Reviewed portfolio snapshot:
`6f800cc44e5239b362451feb1b472625792e04236b4a6b00d28cdc6de2c7eb5b`.
History: **2023-01-03–2026-07-01**, 876 sessions. This does not complete the
separate 2013 extension. Current-vintage research limitations remain unchanged.

## Fresh local verification

- 17 dedicated Node snapshot/route/range tests pass.
- 69 engine/Strategy/snapshot/range regressions pass (working-tree engine also
  contains unrelated existing tests; publishable-source verification is separate).
- 35 affected Flutter strategy/date/widget tests pass.
- 60 transport/performance regressions pass.
- Full Flutter analyzer, bilingual literal audit and production-mode Flutter web
  build pass; build authentication bypass is false.
- Real canonical replay validates all 876 sessions for both portfolios. Full,
  half, 101-session and two-session intervals reconcile within 2e-15 NAV units.
- Local cold replay ~13.8 seconds; cached range calculations 16–20 ms. Full
  response ~195 KB before transport compression. This is not a production SLA.
- Browser verified actual data in English desktop and Chinese 390x844 layouts,
  including distribution and buy/sell detail dialog. Widget tests cover rapid
  range races, stale response rejection, loading/error recovery and narrow layout.
- Repository storage layout still reports the same 11 pre-existing findings;
  unrelated databases/directories have not been removed to pass the gate.

Reproduce aggregate-only data verification (no licensed price rows emitted):

```sh
node scripts/verify-rule-range-analysis.mjs
node --test server/rulePortfolioAnalysis.test.js server/investorStyleDashboard.test.js server/investorStyleDashboardRoutes.test.js
flutter test test/investment_investor_styles_test.dart test/investment_strategy_lab_test.dart test/investment_strategy_dates_test.dart
```

## Release status

Backend commit `b8968dba969c066b2219873c616d77f6a09b3134` is published to trunk.
EB `thesisforge-api-prod` is Ready/Green on `range-api-b8968db`. Backend package
SHA-256 is `ba97684e71a3696596eb1af6da15f11d5a680d9a243a233e61c814a1cba68aba`.
Rollback code version: `insiders-api-ab359e2`; no runtime data was replaced.

Fresh committed-source Node suite: 1,715 passed, 15 skipped, zero failed.
Production replay as `webapp`, through the same publication middleware as API
requests, passed all four windows (SSM `9e6f9c7e-167b-4a41-b500-b8791c568ed9`).
Cold replay was 45.9 seconds; cached ranges 32–90 ms. The standalone verifier
now enters that request context too: its initial env-only invocation correctly
failed because it did not resolve the active canonical root.
The local browser's actual slider drag also verified 2024-04-12–2026-07-01:
both strategies' statistics and best/worst stocks changed together.
Storage-content receipt `rule-range-storage-20260924.json` passed with zero raw
duplicates; the 11 existing repository-layout findings remain separate.

Frontend commit `bd59ef7443bed25f1f58db63423fa48210440c1b` was deployed by the
existing trunk CI to Vercel `dpl_9rEq9b1BYw1qJyUW84NkrutLQ8fz` (Ready):
`https://thesisforge-5so4jdvcb-yudonglu1136s-projects.vercel.app`.
Both `thesisforge.tech` and `www.thesisforge.tech` were independently inspected
and pointed to that same deployment. Its production build enforces auth bypass
false. Eight concurrent health reads returned 200/ok; the existing market-price
module is explicitly stale (source 2026-09-18), not a new analytics regression.
Unauthenticated range requests return 401; public internal-release probes return
404. No authentication settings, credentials, prices or user data were changed.

**Remaining acceptance boundary:** the validation browser has no production
Google session and shows the login page. Authenticated production UI interaction
therefore remains pending user login; neither runtime replay nor public health
is claimed as an authenticated browser pass. English desktop, Chinese 390px,
range dragging and stock dialogs were actually verified on the local build.
Screenshot: `/private/tmp/rule-range-analysis-zh-desktop.png` (local, not online).
The full Flutter suite was not certified; only the affected 35 tests plus full
analyze/i18n/build are reported. Existing unrelated suite/layout findings remain.

This task leaves
the pre-existing 2013 builders, modified backtest engine, design QA and other
uncommitted work untouched.
