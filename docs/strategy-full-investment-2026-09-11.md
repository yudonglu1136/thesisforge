# Strategy Lab: full investment and historical holdings

## User-authorized allocation change

New runs default to `excludedAllocation: fully_invested`. A selected Top-N stock
with unavailable execution/model evidence or excessive valuation does not keep
a cash slot. Eligible unique stock claims share the entire stock sleeve equally;
the chosen CTA percentage stays fixed. No lower-ranked or future holding is
substituted. Leverage continues to use the fixed 4% annual financing model.

An unavailable manager book is excluded as a whole, with its reason and first
stored disclosure date. A manager can join only after an actual public filing.
An incomplete/unverified book is never represented as a verified Top-N book.
Conflicting security identities still block the run.

This is explicitly labelled an **eligible-subset simulation, not strict Guru
replication**. Existing saved `cash` and `redistribute` rules remain unchanged,
and the original strict 90% execution-coverage requirement remains in those
modes and the original Guru engine. New owner-private rules save only when
the user explicitly asks to save.

## Historical holdings

`holdingSnapshots` derives from the same target allocations and dated NAV used
by the completed backtest. Previous/next controls and the complete date dropdown
browse every actual disclosure rebalance, not just the last 12 quarters.

Each snapshot exposes stocks, CTA, allocation weights, leveraged exposure when
enabled, manager identities/portraits, decision-time valuation comparisons,
excluded candidates, skipped manager books and underlying public filings.
It is a post-rebalance **simulated** snapshot; weights drift between rebalances.
It is not a brokerage account or a claim of daily unchanged allocations.
Browsing does not rerun the strategy, save rules or alter its cutoff. Research
navigation explicitly opens at the workspace cutoff rather than silently
replacing the historical decision inputs.

Snapshots are returned with the run and regenerated reproducibly from its rules,
calculation version and database generation. They are not a new permanent
brokerage-history store. Failed runs do not display target snapshots as held
positions.

## Honest limits

- If a rebalance has no eligible stock, the requested simulation stops with
  `no_eligible_stocks`. It does not fabricate a 100% CTA/cash result or weaken
  the user's valuation filter.
- A missing mark while already holding a position remains a data error. The
  strategy does not use that future gap to retrospectively exclude the stock.
- Cash acquisition settlements currently require explicit reinvestment handling;
  this mode blocks with `cash_settlement_requires_reinvestment` rather than
  claiming a cash-free completion. Stock-conversion transition gaps and
  conflicting claims likewise remain explicit blockers.
- Fewer eligible stocks increase concentration. Coverage warnings and exclusion
  provenance remain visible even when allocation is fully invested.

## Verification

Exact user basket: Dev Kantesaria / Li Lu / Samantha McLemore, Top 5,
2021-08-28 through 2026-08-28, 27% premium limit, KMLM 30%, 1×, 10 bps:
1,255 daily observations, 31 snapshots, all target cash weights zero.
First rebalance 2021-08-30: MU 35%, AAPL 35%, KMLM 30%.
Samantha is absent before her first stored public filing (2022-02-14), not
backfilled into 2021. The requested date range is unchanged.

Local HTTP acceptance also passed for 30% premium, valuation filter off, no CTA,
DBMF 50% and 1.5× leverage. Every snapshot reconciles to the corresponding
curve's NAV and source ledger. Checks never saved user rules or wrote source
data. Reproduce with `scripts/verify-strategy-full-investment.mjs` and a new
private output directory; use only a loopback origin and an authorized local
development token.

Frontend: 456 tests; targeted snapshot tests include full-date browsing,
manager labels, first/last boundaries, blocked states and EN/ZH mobile at 150%
text size. Backend: 70 tests, including 27,000 synthetic parameter combinations,
legacy-policy regression, missing data, costs, duplicate instruments across
sleeves, publication timing, owner isolation and leverage reconciliation.
Analyze, bilingual audit, Ontology tests/verification and production no-bypass
build passed. Local preview build remains separate on port 5186.

Real-data population sweep: 3,234 configurations over all 28 managers, every
integer Top 1–10 and 1/3/5/10-year horizon, every manager pair and rotating
multi-manager/CTA/leverage interactions. Completed: 1,549 ready, 1,685 explicitly
blocked, zero calculation assertions/errors, zero duplicate or missing cases.
The all-configurations-ready gate therefore correctly remains **failed**, not
green. Blockers: 1,564 no eligible stock at some rebalance; 47 active price gaps;
41 cash settlements requiring reinvestment; 27 stock-conversion transition gaps;
6 conflicting security identities. This is not an exhaustive test of continuous
slider values, arbitrary dates or every possible manager subset. Source SQLite
integrity/foreign keys passed with zero source writes.

Private machine-readable results:
`/Users/yudonglu/Documents/strategy-full-investment-20260911-final/`;
exact user acceptance:
`/Users/yudonglu/Documents/strategy-full-investment-acceptance-20260911/`.
These are local audit artifacts, not public web assets. No production deployment
or push is part of this change.

HTTP/worker parity: 42 population cases passed, with unauthenticated access
denied and zero saved-rule writes. Snapshot parity uses the exact requested
source window on both sides; the population sweep's cached ten-year source
extract has different provenance-derived IDs. The verifier compares all fields,
including IDs, against the exact-window offline calculation, while retaining
the original population-curve hash checks. It does not discard discrepancies
in holdings, weights, prices or NAV.

Native in-app browser: original three-manager 30%/KMLM-30% five-year strategy
runs successfully. Final app checked at 1440×1000 and 390×844 in EN/ZH; all-date
dropdown reaches 2021-08-30, previous/next switches actual holdings, and language
switch retains the selected snapshot. Stock logos and Guru portraits/names
render correctly. Exclusion details identify Samantha's first public filing;
first/last navigation boundaries and zero cash are visible. Browser error log
was empty. `desktop-en.png`, `mobile-en.png`, and `mobile-zh.png` in the private
acceptance directory preserve native screenshots. No browser save action was
performed.
