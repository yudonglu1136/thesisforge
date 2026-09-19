# Backtest snapshot inspector

Scope: local Strategy Lab UI, no production deployment or source-data refresh.

## Interaction and meaning

- A Historical snapshot selector is visible in the results area, including the
  Performance view. Select any rebalance date or use previous/next; this opens
  Holdings & filters without running or saving a strategy.
- Desktop compares final held positions with filtered stocks side by side.
  Narrow layouts stack them. Filters are visible rather than hidden in an
  expansion tile. Unavailable manager books are counted separately from stocks.
- Each valuation exclusion uses its saved decision price, model value, premium,
  price date and model date. The threshold comes from the completed result's
  rules, not unsaved controls. Missing models, stale models, incomparable
  currencies, execution/identity gaps and corporate-action cash have distinct
  explanations. Unknown quantities are not turned into zeros.
- Allocation text explains the existing policy: fully invested eligible stocks
  share the stock sleeve equally; CTA remains fixed. Cash and leveraged exposure
  are reported separately. These are post-rebalance simulated target weights,
  not brokerage positions or daily drifted weights.
- Historical inputs remain bound to the same completed run. Company links open
  research at the workspace cutoff, explicitly separate from historical evidence.
- Existing performance curves and rebalance audit remain available. Blocked
  runs do not create completed holding snapshots.

## Source acceptance

The unchanged local API was checked with Bill Ackman, Top 5, 30% premium limit,
KMLM 30%, 1x leverage, 10 bps, 2025-09-10 through 2026-09-10. It returned five
completed snapshots. On 2025-09-10 AMZN was excluded at a recorded 98.2889%
premium; on 2026-08-17 it was included at 13.7382%. MSFT was excluded from the
latter at 49.8748%, with a 2026-08-14 comparison price and 2026-07-29 model.
BN and HHH had no usable model in that decision. These are stored model outputs,
not claims about the correctness of fair value or current investment advice.

Tests cover multi-date switching, immutable prior-run thresholds, no implicit
run/save, blocked runs, manager-vs-stock counts, EN/ZH mobile at 150% text and
backend preservation of dated exclusion evidence. No backtest calculation,
eligibility policy, authentication, portfolio privacy or API payload was changed.

## Verification completed

- 497 full Flutter tests passed; after the final display-only refinement, all
  27 targeted Strategy Lab / leverage tests and Flutter analysis passed again.
- 65 existing strategy engine / matrix / leverage / route tests passed. The
  final 12-test fully-invested suite also passed with the new provenance test
  (66 distinct backend tests across those suites).
- Bilingual audit, Ontology source/built checks, 22 Ontology Node tests and three
  Python tests passed. Production-config and local-preview builds succeeded.
- Actual local API and browser acceptance verified the date dropdown, previous
  snapshot control, synchronized held/filter counts and dated valuation inputs.
  Desktop 1280x720 and mobile 390x844 were inspected in EN/ZH, with no browser
  error logs. Screenshots are in
  `output/strategy-snapshot-inspector-20260911/{desktop,mobile}-{en,zh}.png`.
