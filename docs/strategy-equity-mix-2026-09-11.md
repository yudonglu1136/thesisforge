# Strategy equity mix — local implementation

## Interaction

The first Strategies card opens **Build your equity mix**. The dialog supports Guru, four-factor, QQQ, SPY and SCHD independently or together. Percentages divide the equity allocation and must total 100%. Each input also shows its effective share of the total portfolio before leverage. CTA remains a separate total-portfolio allocation; leverage remains the fourth card with 4% annual financing.

Example: Guru 40% + factors 30% + QQQ 30%, with CTA 30%, means 28% Guru + 21% factors + 21% QQQ + 30% CTA before leverage.

CTA can now have an independent hold, calendar or flexible-tranche policy via its own card. The example above is the initial allocation; thereafter CTA and equity weights can drift or change according to that policy. Equity selection remains quarterly. See [CTA rules](strategy-cta-rules-2026-09-11.md).

The modal has presets, explicit normalization and Guru selection/Top N. **Configure factors** opens the factor section: growth, profitability, cash flow and durable ROIC each have an independent switch and threshold. Any nonempty subset is valid, including a single-factor strategy. ROIC supports a 3–5-year observation window and a required passing-year count, such as 4 of 5. Selection ranking is chosen from enabled factors only; Top N remains adjustable. Cancel discards the modal draft. Apply changes configuration only; Run performs the simulation. Save rules stores an owner-private reusable configuration, including the factor switches and individual parameters. No orders or brokerage changes occur.

## Simulation contract

- New explicit `equityMix` rules use an initial allocation followed by calendar-quarter rebalances. Legacy saved Guru rules without this field retain their disclosure-driven schedule and cash policies.
- Decisions use the preceding session's publicly available filings and models. Four factors are quarterly revenue YoY, TTM operating margin, TTM FCF margin and consecutive annual pre-tax ROIC. Defaults are 15%, 10%, 5%, and 15% in each of 5 years, respectively. The default factor portfolio is Top 10.
- Factor candidates pass all **enabled** thresholds, then the optional valuation filter, then rank descending by the chosen enabled metric. Lowest annual ROIC is a tie-breaker only when ROIC is enabled; ticker is the final deterministic tie-breaker. Disabling growth removes both its screening constraint and any hidden growth ranking. This refills from the qualified pool. Guru selection retains the chosen Top N survivors without adding lower-ranked holdings.
- ROIC requires a complete, consecutive, publicly available annual history across the whole observation window, even when fewer years must exceed the threshold. Missing years cannot count as passing years. Disabled factors neither screen nor require their metric history. Legacy saved mixes lacking factor switches expand to the original all-four rules, with every observation year required to pass.
- The valuation exclusion is `price / fair value - 1 > threshold`; equality passes. Missing, stale, non-comparable models do not pass an enabled filter. QQQ, SPY and SCHD are exempt from individual-company DCF filtering.
- Every enabled component retains its configured allocation. Its eligible stocks split that allocation equally; repeated tickers across components are combined. An empty enabled component blocks that run instead of leaving cash or silently changing another component's budget.
- Weights drift between rebalances. The shared audited execution engine computes trades, costs, CTA and leverage. An active adjusted-price gap blocks the affected curve; no interpolation, zero-return fill or silently shortened dates.
- Historical snapshots retain the component contributions, combined position weights, decision dates, model prices and exclusion reasons. The comparison curves are unfiltered equity mix, filtered equity mix, CTA blend, optional financed blend and SPY buy-and-hold.

## Data boundaries

The factor universe is current stored operating-company coverage, **not a survivorship-free historical universe**. Historical financial models are retrospective reconstructions. These limitations appear in the UI and response provenance; these simulations are not actual manager fund returns.

The explicit `STRATEGY_COMPOSITION_PRICE_DB_PATH` research source supplies complete, single-vintage adjusted-close series. It does not rewrite the strict Guru strategy database. CTA continues using the existing audited ETF series. Exact comparison closes remain separate from adjusted return prices.

Local prepared source: `/Users/yudonglu/Documents/investment-composition-prices-20260911/prices.sqlite`. The archive was copied into a new directory and SCHD added with 3,743 daily observations from 2011-10-20 through 2026-09-10. Raw response, source hashes, typed series and audit records are stored. Original price, financial and Guru databases were preserved.

Reproducible preparation: `node scripts/prepare-composition-prices.mjs SOURCE_SQLITE NEW_OUTPUT_DIRECTORY 2026-09-10`. The output directory must be new. Set the resulting database path only on the local backend launcher. No production deployment was performed.

## Verification

- Backend rule, execution, PIT, source, persistence and legacy regression tests; synthetic fixtures are isolated from preview databases.
- English/Chinese widget tests, including 390px / 150% text, exact allocation payloads, cancel, saved rules, invalid totals and empty factor drafts.
- Real local HTTP: QQQ/SPY/SCHD 50/25/25 + KMLM 30% over five years produced 1,255 daily observations and 21 snapshots; every snapshot allocated 100% before leverage.
- Real local HTTP: Guru/factors/QQQ 40/30/30 + KMLM 30% with 1.5× leverage over one year produced 252 daily observations and 5 snapshots; the financed result was ready.
- Real local HTTP: four-factor Top 10 + KMLM 30% over five years produced 1,255 daily observations and 21 fully allocated snapshots.
- In-app browser: configured custom index weights, applied without a Guru, ran a real backtest, inspected comparison curves and opened historical holdings. Previous-quarter navigation was verified visually.
- Independent-factor extension: all 15 nonempty factor subsets, missing disabled metrics, ROIC passing-year counts, PIT dates, ranking and owner-private configuration roundtrips are covered by backend regressions. The focused backend suite passes 79 tests; the strategy widget suite passes 35 tests, including single-factor editing/restoration and bilingual mobile layouts.
- Real local HTTP: a cash-flow-only Top 10 (FCF margin ≥ 8%) and a growth + ROIC Top 10 (ROIC ≥ 15% in 4 of 5 years, ranked by lowest ROIC) each completed the 2025-09-10 → 2026-09-10 period with 5 rebalances and no cash allocation.
- In-app browser extension acceptance: disabled growth, profitability and ROIC, edited cash-flow threshold to 8%, applied the single-factor mix, then ran the one-year period with a 30% valuation premium limit and KMLM 30%. All four comparison curves rendered with 252 daily observations; the completed-run rule summary showed only cash flow, Top 10 and cash-flow ranking, with 0% cash at the last rebalance.

These checks confirm supported paths; they do not claim every arbitrary configuration has sufficient historical data or eligible securities.
