# Local all-price refresh — 2026-09-11

## Outcome

The active local preview at http://127.0.0.1:5186 now reads the verified
`investment-prices-release-20260911` runtime and strategy databases through
its existing loopback backend on port 8789. The latest completed US session
is **2026-09-10**. No September 11 closing prices were invented.

This is a completed population audit and a **partial, verified repair**, not
an assertion that every security is current or every strategy can run.

| Check | Result |
| --- | ---: |
| Security identifiers checked across local price/research/strategy stores | 1,600 |
| Provider identifiers with validated September 10 daily prices archived | 1,563 |
| Valid daily observations archived, including historical observations | 4,507,839 |
| Current adjusted return series in both serving stores | 1,517 |
| Previous runtime identifiers with a September 10 price | 720 |
| Observations appended to serving runtime | 1,559,248 |
| Observations appended to strategy raw series | 1,572,841 |
| Current research comparison-quote snapshots | 527 / 533 |
| Old runtime price rows changed | 0 |
| Protected non-price runtime tables unchanged | 25 |
| SQLite integrity / foreign-key violations | ok / 0 |

The old count of 720 measures terminal price dates; the new 1,517 count
additionally requires a positive adjusted close. Counts are security
identifiers, not distinct operating companies or coverage percentages.

## Why the previous update was insufficient

1. The historical factor replay read Jansen's separate Sharadar price archive,
   which stopped on August 19. Updating the app database did not update that
   input. The original paid archive has not been overwritten.
2. Some serving securities had fresh closes but absent adjusted closes, or
   historical interior gaps. A global `MAX(date)` was not proof of coverage.
3. A bounded Sharadar API probe returned HTTP 403, `Exceeds free tier`, with a
   subscription-required response. No subscription was purchased. The
   refresh used the application's existing Yahoo price source, retaining raw
   responses, exact identifiers, currencies and corporate-action evidence.

## Unresolved coverage — do not suppress

The archive statuses are 1,563 current, 7 stale, 10 delisted-history and 20
failed. In addition, **44 provider-current identifiers cannot safely extend
their stored return histories** because the historical close/share basis or
dividend-adjustment basis conflicts. These groups must not be added together
as a count of current listed companies; legacy tickers and aliases exist.

Six research comparison snapshots are not at September 10:

| Security | Last stored comparison quote |
| --- | --- |
| APH | 2026-08-27 |
| AZN | 2026-08-14 |
| BA.L | 2026-09-09 |
| DGE.L | 2026-09-09 |
| EA | 2026-08-10 |
| LSEG | 2026-08-14 |

APH requires a model/share-basis review around its split. London-series
September 10 bars with a close outside the supplied high/low were rejected;
USD/GBP/GBp or ADR/local-share identities were not silently substituted.
Retired identifiers retain dated historical observations. An upstream 404 is
not classified as a verified delisting. LEN.B and UHAL.B also retain explicit
provider-identity failures pending a fresh, auditable class-share import.

The complete per-identifier statuses, remaining sessions and reasons are in
[price-coverage.csv](/Users/yudonglu/Documents/investment-prices-release-20260911/price-coverage.csv).
The machine-readable receipt is
[final-price-audit.json](/Users/yudonglu/Documents/investment-prices-release-20260911/final-price-audit.json).
Safe closure requires reconciling these conflicts against verified source
and corporate-action evidence, or restored access to the paid source; a
coverage-gate waiver is not a repair.

## Verification

- Twelve new append/reconciliation tests and four provider-parser tests pass.
- Every old price row and protected financial/model table was compared with
  the source generation. Runtime snapshot cache invalidation is recorded.
- Live API checks confirm the serving generation, KMLM/DBMF cutoffs, AMZN,
  MSFT and NVDA research quotes, and rejection of a September 11 backtest end.
- Additional research API checks: ANET, TER and AVGO each return a September
  10 price. Their financial-publication dates remain unchanged. In
  particular, AVGO's June 9 model evidence was **not** refreshed by this
  price-only operation.
- Unfiltered, DBMF-50% and 1.5x control backtests complete with 1,255 daily
  observations ending September 10 and 21 holding snapshots. The historical
  Ackman + 30% valuation-filter configuration is still correctly blocked by
  `no_eligible_stocks`; current prices do not create eligible stocks.
- Browser verification confirms the rendered strategy page shows September
  10, 1,517 return securities and 527 comparison quotes, with no console
  errors. No user strategy rules were saved or trades submitted.
- The earlier quarterly factor experiments were replayed to September 10
  with 2,498 daily observations and no missing held-price sessions. Each
  ticker uses an entire fresh return history, not a cross-vendor price-level
  splice. EA retains its entire original historical series for its actual
  holding interval. Historical selection/model evidence and decision quotes
  remain fixed. Independent ledger and metric verification passes.

[Live API test receipt](/Users/yudonglu/Documents/investment-prices-release-20260911/live-api-verification.json)
· [Updated factor-comparison chart](/Users/yudonglu/Documents/guru-intelligence/output/fundamental-pit-premium50-current-20260911/pit-top10-premium-comparison.png)

## Reproducibility and scope

Generation: `77a50e15e4c2c517be7b752720795662457765743e5798f7c24c0eca5d073ae2`.

Scripts: `harvest-all-local-prices.py`, `append-all-local-prices.mjs`,
`audit-local-price-release.py`, `replay-fundamental-pit-prices.mjs` and
`render-fundamental-pit-comparison.py`. The release contains the population
audit, source hashes, import manifest and integrity proof. Earlier database
generations remain available; the local launcher alone was repointed.

This operation covers local daily security prices. It does not update
financial statements, Guru filings or published performance caches, broker
NAV, saved scenarios, intraday prices, or option chains. Nothing was deployed
to AWS or production. The experimental factor chart remains subject to its
original present-universe/survivorship and retrospective-model limitations;
these are not live or out-of-sample returns.
