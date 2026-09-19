# Strategies population repair — 2026-09-10

## Reported failure and verified repair

User configuration: Dev Kantesaria / Li Lu / Samantha McLemore, Top 5,
price / fair value premium cap 30%, redistribute expensive exclusions,
KMLM 30%, leverage 1×, 10 bps, 2025-08-28 through 2026-08-28.

The serving API reproduced `filing_classification_unverified` for Dev's
2025 Q2 original, accession `0001697868-25-000005`. The prior repair covered
Bill Ackman / Li Lu / Warren Buffett only. Most other managers still used
unverified legacy extracts. The execution gate was working; its input recovery
scope was incomplete. Portraits were already working and were not changed.

After recovering Dev and Samantha's 40 available quarters since 2021 Q2,
the exact request returned HTTP 200 / `ready`: 252 daily observations,
10 disclosure rebalances, 100% minimum execution coverage, 71.4% minimum
model coverage. Missing estimates remain cash. The browser was used to select
these exact managers and run 1Y; all four curves and the statistics table
rendered. Browser logs contained no warning or error.

Evidence: `output/strategy-broad-repair-20260910-focus/verification.json`,
`verification.screenshot.json`, and `desktop-chart.png`. The focus matrix
has 28 ready / 5 explicitly blocked cases: two older Dev Top 10 configurations
have an unresolved security identifier, and Samantha has no five-year starting
filing. Her available history starts with 2021 Q4; no earlier holdings were made up.

## Broader recovery

- Downloaded and independently verified 454 additional quarters for the other
  22 enabled managers, covering 2021 Q2 through 2026 Q2.
- Reconciled exact SEC information-table and cover documents: original form,
  CIK, report period, raw entry count and raw value sum, then common-claim
  classification and duplicate-CUSIP aggregation before Top N selection.
- The SEC manifest contained four omitted originals for Druckenmiller,
  Gerstner, Laffont and Gayner. Exact document hashes and cover reconciliation
  restored their original publication dates. Later amendments are not imported
  into earlier decision dates. `originalStrategyHistory` now accepts this
  independently verified original metadata even when cached backtest history
  omitted the quarter.
- The narrow pre-2023 recovery uses the historical thousands-of-USD reporting
  unit, not a price-per-share heuristic. SEC changed this convention on
  2023-01-03: [EDGAR Filer Manual v64](https://www.sec.gov/files/edgar/filermanual/archive/efmvol2-v64.pdf).
- Chamath's configured SC US filer remains an identity block. It was not
  relabelled as Social Capital, removed from the selectable population, or
  counted as a successful recovery.

## Unreconciled original documents

- Gerstner 2021 Q3: cover says 30 entries / 12,234,313 reporting units;
  original table contains 31 entries / 12,482,740. Not rounding.
- Gerstner 2021 Q4: cover says 20 entries / 3,682,012;
  original table contains 25 entries / 10,516,418. Not rounding.
- Gerstner 2022 Q1 original also fails cover/table reconciliation.
- Stan Moss 2023 Q4: raw table total reconciles to the cover, but the current
  common-class parser's total 41,464,039,057 differs from cached canonical
  common value 41,460,551,357. This reconciliation remains explicit, not waived.

These are retained as source failures for affected historical configurations.
Their existence does not prevent the user's reproduced one-year configuration.

## Safety and reproducibility

- Canonical source `output/investment-workflow-20260908/runtime.sqlite` opened
  read-only; source writes remain zero. No production / AWS / Git push.
- Old strategy databases retained. New imports use independent files and an
  atomic, no-clobber publish after integrity, foreign-key and table-hash checks.
- Focus import changed only evidence, filing, holding and issue tables. Price,
  financial, guidance, ETF and valuation model fingerprints were unchanged.
- `scripts/verify-strategy-population.mjs` derives its population from the
  serving catalog and reports every configured manager, including failures.
  It runs 1Y / 3Y / 5Y × Top 1 / 5 / 10, plus the exact user mix and variants.
  It checks full requested trading coverage for ready curves, strictly ordered
  positive observations, allocation conservation and PIT disclosure/model dates.
- `scripts/recover-strategy-manifest-gaps.mjs` is a source recovery utility, not
  an automatic fallback inside an HTTP request. Cover conflicts still fail closed.

## Final generation and results

Serving database: `output/strategy-broad-repair-20260910-merged/strategy.sqlite`.
Generation: `6d6045944e79d277fd16582bb52327f3491c296a1c187fc5ba4af2a07aa1d3fd`.
Integrity `ok`, foreign-key violations 0, source writes 0. Only the same six
evidence / filing / holding / issue table fingerprints changed; all price,
financial, guidance and valuation fingerprints match the previous serving DB.

The 27 identity-unblocked managers have 561 verified quarterly books in the
five-year coverage range. Four unreconciled quarters remain as described above;
Samantha has 19 available quarters rather than 21.

The full 258-case matrix in `final-verification.json` reports 201 ready and
57 blocked, never a blanket all-pass: 36 execution coverage failures, 9 manager
identity failures, 3 insufficient manager histories, 3 unreconciled classifications
and 6 missing/reconciliation-blocked originals. The three original conflicts for
Gerstner affect the same older windows; the six original failures are Stan Moss's
3Y / 5Y variants. Some failures stop at their first issue, not an exhaustive
inventory of every downstream missing price.

For the screenshot's 1Y / Top 5 settings, 25 of 28 managers individually run.
The remaining three are Chamath (filer identity), Soros (unresolved claim
530307305) and Peltz (JHG execution unavailable). Different Top N or dates can
expose other genuine gaps. This is not a claim that all possible mixtures work.

The broader matrix also identified a software bug: full SEC books contain
reported zero-value tail rows. `selectedBook` previously rejected the entire book
before ranking, even when those rows could never be selected. It now validates
and aggregates all claims, ranks positive reported values only, and retains zero
rows in the source warehouse. Missing/negative values, conflicting identifiers,
missing execution prices and the 90% gate still fail. Added regressions verify
that zeros neither block positive Top N nor receive fictitious equal weights.

Tests: 69 backend tests pass; prior 13-case Bill/Li/Warren regression passes.
The new zero-value fix also makes Renaissance's 1Y and 3Y configurations run.
Calculation provenance is `strategy-positive-common-book-20260910-v2`; the
existing response schema remains v1 for frontend compatibility.

Final serving HTTP checks: the user's exact mix, Renaissance Top 5 and Gavin
Baker Top 5 each return 200 / ready / 252 observations on the new generation.
Measured response times were approximately 0.76s / 5.79s / 0.82s respectively.
The browser also reran the user's exact configuration after the final switch,
and its rebalance audit exposes historical valuation decisions and cash slots.

Local launcher updated; no frontend changes or rebuild required this turn.
No AWS deployment or Git push was performed.
