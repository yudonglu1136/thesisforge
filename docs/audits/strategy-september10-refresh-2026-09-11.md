# September 10 local market-data repair

Scope: local preview only, requested market cutoff **2026-09-10**. No production writes, credential changes, saved-rule changes or trades. This is a partial source refresh, **not** an assertion that all financial, brokerage or simulation data is current and complete.

## What was wrong

The selected workspace/end date was September 10, while the separate strategy database and CTA artifacts ended August 28. The database reader rejected the newer end; the worker and UI collapsed that error into a generic failure. Advancing the URL could not refresh the source database.

The repair now validates database/CTA freshness before computation and gives a specific bilingual error without silently changing the requested dates. The UI displays actual market coverage, keeps financial/model publication dates, and distinguishes an empty eligible stock basket from a source failure.

## Source-backed changes

- KMLM, DBMF and SPY have actual daily observations through September 10.
- 720 securities have current return observations; 527 have current comparison quotes. These are coverage counts, not a claim that every historical security has current trading data.
- The first accepted refresh added 6,923 price rows and separately reconciled 371 terminal records against archived confirming daily responses. Old private database generations remain available.
- Population testing identified additional BRK.B symbol mapping, truncated KEYS history, SPCX listing-boundary coverage, and UNP dividend-adjustment-vintage issues. Recovery added 2,689 real observations and corrected three UNP adjustment records. It did not synthesize sessions or alter the strict Guru execution-coverage gate.
- Current comparison-only Yahoo quotes are explicitly vendor-labelled. Earlier Sharadar quotes and model inputs are not overwritten or described as the same adjustment basis.
- Contradictory opening-price fields are quarantined as missing; source documents retain the original values. Validated closing/adjusted prices are unchanged. These records are not represented as verified complete OHLC bars.
- Official SEC submission directories were checked for all 29 configured 13F managers, including alternate CIKs. No new holdings-bearing HR filing was missing through September 10. An old-CIK Ackman NT notice is not a new holdings book.
- Financial/guidance/model and strict/proxy Guru cache tables were retained. This task does not certify a new strict Guru 5Y/10Y return-cache release.

## Remaining restrictions

- The existing fundamental-data subscription returns an authorization/subscription error. Financial inputs and valuations were **not** rebuilt or re-dated to September 10.
- The newest retrievable AWS brokerage report is September 9. It cannot establish September 10 NAV or daily P&L. No synthetic account history was substituted.
- BRK.A's September 10 upstream close is inconsistent with its day's high/low; it remains withheld. EA has a similar current quote-quality rejection. APH's intervening split requires a price/share-basis review before a newer comparison quote can be attached to the old model. Unverified non-USD units also remain unchanged.
- Historical private rollovers, unsupported corporate-action transitions, ambiguous security identities, and cash-settlement reinvestment cases remain explicit blockers. A market-date refresh does not resolve these distinct economic/data contracts.

## Exact screenshot configuration

Bill Ackman / Top 5 / 30% premium limit / fully invested eligible stocks / 30% KMLM / 1× / 10 bps / September 10, 2021–September 10, 2026 reaches the engine after refresh. It stops on September 10, 2021 because LOW, A, CMG and HLT exceed the limit and QSR lacks an eligible model. No stock remains to receive redistributed money. The UI lists each excluded stock and its reason. No threshold, Top N, manager, date, or CTA allocation is changed automatically.

A separate diagnostic with the valuation filter off produces 1,255 daily observations through September 10 and 21 historical rebalance snapshots, with 70% stock / 30% CTA / 0% cash target allocation. It is a different test, not a completed result for the original filtered configuration.

## Verification and recovery

- Flutter: all 464 tests passed; analyzer clean; local preview and production-mode builds passed. No deployment was performed.
- Bilingual audit, Ontology verification/tests, performance tests and targeted source/strategy tests passed.
- The population matrix covers 3,234 cases: all 28 enabled managers, every Top 1–10 and 1/3/5/10-year horizon, all manager pairs, and discrete valuation/CTA/leverage/cost interactions. This is not every continuous date or slider combination.
- Private machine-readable matrix, source hashes, original responses, field quarantine receipts and database manifests are retained outside the repository. Licensed rows, account data and credentials are not included here.
- Only after source integrity/foreign-key checks and read-only original-generation checks does the preview launcher switch databases. Earlier generations remain intact for rollback; restore the former explicit database paths in the local launcher and restart the local backend. Do not reset or delete the databases to roll back.

Final generation: `d0fc8d947c38301f96a4072bde18e582d4e67ed5b82de1d31ec0d1e9b955cfdf`.
All 3,234 cases completed: 1,503 ready, 1,731 blocked, zero exceptions or invalid results. The all-ready gate remains **failed**. Of the blocked cases, 1,526 have no eligible stocks; the remainder involve missing active prices, corporate actions, cash reinvestment, or conflicting security identities. The final 42-case local HTTP/worker parity audit passed, including honest blocked outcomes. This does not certify that all backtests work.

Detailed counts and private receipt locations are recorded in the companion JSON audit. No original user rules were saved or overwritten during verification.
