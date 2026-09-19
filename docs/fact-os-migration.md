# Local Fact OS migration — audit and release gates

Scope: `/Users/yudonglu/Documents/fundamental-analysis`, local only. No production
credentials, production database, AWS or Vercel release is changed by this work.
This is the existing ThesisForge/Guru Intelligence application, not a new project.

Status: **local Fact OS data-layer migration accepted**. The checks below separate
completed local gates from unsupported source semantics and future deployment work.
The 15-item delivery report is [fact-os-final-report.md](fact-os-final-report.md).
Local Fact OS data-layer acceptance now passes: both real API passes, both fixed-input
offline replays, stable 14-table audit, storage deduplication, legacy preservation,
and actual offline consumer probes. This is not browser end-to-end or production
acceptance; the semantic limitations below remain explicit.
Earlier interrupted receipts are retained as failure evidence, not successful runs.
The current user's migration brief supersedes the older repository instructions
that prescribe SEC/Yahoo sourcing or further Ontology development. Existing
models, private portfolios and research material remain separate from vendor facts.

## 1. Existing architecture and initial inventory

Read-only inventory taken 2026-09-19. `PRAGMA quick_check` returned `ok` for all
three databases below. No private portfolio payloads, identity rows or keys were
printed. The inventory is reproducible with `scripts/audit-fact-os.py`.

| Existing store | Size in bytes | Purpose |
|---|---:|---|
| `server/data/guru-analysis.sqlite` | 709,148,672 | Quantitative caches, published model artifacts, asset metadata; also contains legacy account NAV table |
| `server/data/valuation-pit-source.sqlite` | 110,100,480 | Partial Sharadar AR financials, issuer guidance, FX evidence |
| `server/data/ontology-snapshot.sqlite` | 105,721,856 | Pre-existing compressed endpoint responses; not a canonical facts store |
| `server/cache/` | approximately 5.4 MiB | SEC submissions/holdings and market-price JSON caches |
| `server/data/user-portfolios/` | not profiled | Private admin registry and separately encrypted per-user SQLite connections/NAV; excluded from migration |

The main SQLite database's initial table counts:

| Table | Rows | Boundary |
|---|---:|---|
| `price_points` | 2,105,837 | Retired quantitative source; retain for rollback |
| `dashboard_snapshots` | 1 | Old derived Guru cache |
| `guru_snapshots` | 28 | Old derived Guru cache |
| `guru_exposure_snapshots` | 19 | Old derived Guru cache |
| `guru_backtests` | 37 | Old derived backtest cache |
| `valuation_snapshots` | 1 | Published model dashboard |
| `valuation_ticker_snapshots` | 141 | Published model artifacts |
| `valuation_pit_financials` | 15,894 | Partial AR input archive |
| `valuation_pit_guidance` | 18,418 | Issuer/transcript evidence; preserve |
| `valuation_pit_model_runs` | 7,612 | Model audit artifacts; preserve |
| `valuation_pit_source_metadata` | 18 | Prior import metadata |
| `valuation_pit_price_observations` | 0 | Existing empty table |
| `dividend_events` | 58 | Old Nasdaq/Yahoo dividends |
| `portfolio_nav_points` | 1 | **Private legacy account data: do not migrate/delete** |
| `guru_assets` | 28 | Non-quantitative assets: preserve |
| `ticker_assets` | 8 | Non-quantitative assets: preserve |
| `valuation_podcast_insights` | 23 | Research material: preserve |
| `background_job_runs` | 12 | Operational audit history: preserve |
| `cache_revisions` | 7 | Existing cache metadata |
| `dbmf_snapshots` | 1 | Pre-existing legacy artifact: no new feature built |

The PIT source has 15,894 financial periods, 141 financial coverage records,
18,418 guidance events, 141 guidance coverage records, 8,245 FX reference rows,
and 17 metadata records. The pre-existing Ontology archive has 10,366 compressed
responses and two metadata records. Neither is evidence of full Sharadar coverage.

### Initial price-semantics defect

`server/marketData.js` imported Yahoo **quote.close**, not `adjclose`, and cached it
under a generic `close`. The physical SQLite schema additionally has an
`adjusted_close` column, but the normal market loader does not establish its basis.
Old `backtest.js` and portfolio return calculations consumed this generic close.
Never reinterpret these persisted numbers as Sharadar total-return prices.

## 2. New architecture and isolation

```text
Sharadar authenticated bulk/API (sync subsystem only)
    -> raw ZIP + original schema + checksums
    -> validated, typed, immutable Parquet partitions
    -> transactional DuckDB writer catalog + atomically published read manifest
    -> offline FactRepository / Node adapter
    -> existing application consumers
```

Canonical licensed data lives under `data/fact_os/`. It is excluded from Git.
The migration writes a separate directory and never replaces the old application
SQLite file with the new warehouse. Existing guidance, model inputs/outputs and
private portfolio databases are not treated as Sharadar facts.

Backup/isolation rule: keep old SQLite files and cache directories intact, capture
consistent SQLite backups before any eventual derived-artifact rebuild, and run
that rebuild on a separate copy. Verify all unrelated table counts before release.
Copying a live WAL database with a plain file copy is not a valid snapshot: use
SQLite backup API. A future local cutover must not overwrite private NAV rows.

Verified rollback backup created with `scripts/backup-fact-os-legacy.py`:
`data/fact_os/legacy_backup/guru-analysis.before-fact-os.sqlite` (709,148,672 bytes).
SHA256: `45731e05381e81b7a88cde46b714380a50024ef3704a488ea17741438dd50d45`.
`integrity_check=ok`, all 20 table counts retained in `legacy_backup/backup.json`.
Directory mode is 0700 and backup/receipt mode 0600. Per-user portfolio databases
were not opened/copied; the legacy NAV already inside the main DB is preserved.
Final `legacy-preservation-header-aware-final.json` re-verifies the original
backup SHA and byte count, both integrity checks, and all 20 original table counts.
Every byte after the 100-byte SQLite header is also identical between original
and backup (SHA256 `c20c8e04e0ad8b33f153a2e6bd4e140a5fcf87120c5cce77de1b71fb82d86957`).
Their only differences are offsets 26, 27, 43, 94, 95, 98 and 99: the backup API's
change/schema counters and writer-version metadata. An earlier helper incorrectly
required whole-file hashes to match each other; its failed diagnostic receipt
`legacy-preservation-final.json` is retained. The corrected check permits only
these defined header metadata ranges, requires unchanged initial backup checksum,
and never rewrites either SQLite file. Three regression tests reject arbitrary or
truncated header differences.

## 3. Source tables, grain and coverage

Actual table schemas are fetched from Sharadar's public schema endpoint and retained
in the local catalog. Never infer source schemas from the old partial archive.

| Dataset | Natural key | Main semantic caution |
|---|---|---|
| stocks / SEP | ticker, date | Raw, split and total-return close are different |
| funds / SFP | ticker, date | ETF data must come from funds, not a stocks fallback |
| fundamentals / SF1 | ticker, dimension, date, reportperiod | Keep all six AR/MR dimensions; fiscalperiod is a label |
| daily | ticker, date | Market cap and EV source units are USD millions |
| actions | date, action, ticker, name, contraticker, contraname | Empty-string components may be valid; action units vary |
| tickers | table, permaticker, ticker | permaticker identifies a security/share class, not necessarily a company |
| holdings / SF3 | ticker, investorid, securitytype, date | SHR, PUT, CLL and all other source security types remain separate; units thousands, value USD millions |
| holdings_ticker / SF3A | date, ticker | `percentoftotal` is not issuer shares-outstanding ownership percentage |
| holdings_investor / SF3B | date, investorid | Investor metadata by reported quarter |
| events | date, ticker | Event classifications, not exact disclosure timestamps |
| insiders | ticker, date, formtype, ownername, rownum | Older archives used filingdate; schema drift requires explicit migration |
| descriptions | table, indicator | Official field/unit metadata |
| metrics | ticker, date | Source-specific metric definitions retained |
| sp500 | date, action, ticker | Historical membership events, not current-universe backfill |

Live row counts and min/max dates belong in the generated audit report, not stale
handwritten totals. `backfill_complete` means validated authenticated full bulk,
not merely a successfully imported partial archive. Remote entitlement state and
local historical coverage are recorded separately. Future scheduled ex-dividend
dates in Actions are not automatically corrupted/future-leaked historical events.

## 4. Runtime migration matrix

The file list reflects the active server in this repository, not the separate
`guru-intelligence` folder. Status must be checked against integration tests before
claiming all application screens have migrated.

| Old feature / entry point | Old source | New semantic entry point / required handling |
|---|---|---|
| `marketData.loadPriceSeries` | SQLite, Yahoo HTTP, JSON, local CSV | `get_price_history`, explicit price type; no fallback |
| Guru copy simulation `backtest.js` | Cached custom 13F + generic prices | Local SF3 holdings + total-return price history; enforce PIT availability limitation |
| `secClient.loadGuruDashboard` | SEC scraper + SQLite/JSON snapshots | `get_investor_portfolio`, holder changes, verified identity mapping |
| `secClient.loadGuruExposureHistory` | SEC filing parser + exposure snapshots | Historical local investor portfolios |
| `secClient.loadGuruMarketContext` | Guru snapshot + generic prices | Local holdings + explicit market series |
| `dividendClient.readDividendCalendarForTickers` | Nasdaq/Yahoo persisted dividend events | `get_dividends`; no invented pay date or future annual projection |
| `portfolioClient.attachPortfolioAnalytics` | Direct `readPriceSeriesFromDb` | Local total-return prices; private broker balances remain separate |
| `valuationClient` live quoted prices/financials | Embedded old snapshot financials/Yahoo prices | Canonical raw prices + `get_fundamentals`; historical model artifacts explicitly separate |
| `valuationImporter.js` new ticker/price import | `loadPriceSeries` + derived snapshots | Canonical raw price loader, no live source calls |
| `scripts/build-pit-valuation-source.py` | Jansen partial Parquet + SQLite prices | Canonical AR FactRepository export; same existing model algorithm |
| `importPitQuarterlyValuations.js` | Partial PIT SQLite export | Derived export built from canonical facts; issuer guidance preserved |
| `refreshLatestPrices.js` / `hydrateDatabase.js` | Yahoo and old source caches | Fact OS sync; derived cache rebuilding must identify its source generation |
| `refresh13fData.js` | SEC scrape/cache refresh | SF3 recent-quarter sync; no scrape fallback |
| `refreshDividendCalendar.js` | Nasdaq/Yahoo refresh | Actions sync and local dividend reads |
| Old offline valuation import/alias scripts | Direct SQLite price_points and external financial archives | Retain for rollback only; not a canonical runtime source |
| Pre-existing `ontologyClient` response archive | Separate SQLite compressed snapshots | Default canonical mode fails closed before DB/cache/route callbacks; health exposes only archived status; explicit rollback is separate |

Non-quantitative exception: avatars, logos, earnings transcripts and management
guidance are not replaced with fabricated Sharadar equivalents. Broker portfolio
data remains user-specific broker data. This is not a market-data fallback.

## 5. Price and PIT contracts

| Canonical type | Sharadar field | Appropriate use |
|---|---|---|
| RAW_CLOSE | closeunadj | Historical quoted price and current valuation comparison |
| SPLIT_ADJUSTED_CLOSE | close | Price-return series, with disclosed split-adjustment basis |
| TOTAL_RETURN_ADJUSTED_CLOSE | closeadj | Total shareholder return, includes supported distributions |

Use AR filing/date key as financial availability; report period alone is not
knowledge time. ARQ, ART and ARY stay separate. MRQ/MRT/MRY are explicitly
restated/non-PIT and cannot be requested as historical AR replay. Do not treat an
ART row as a quarter and sum it four times. Upstream lastupdated is provenance,
not a historical filing date. Missing values remain null.

SF3 has **no actual filing-availability timestamp** in its official schema. A
quarter-end holdings observation is not proof that the portfolio was knowable
that day. Historical institutional displays and QoQ changes work, but an exact
filing-timed historical trading simulation must not manufacture a 45-day date or
reuse the old scraper silently. Explicitly report unsupported PIT rather than
claiming a new Sharadar-backed simulation is equivalent to the prior SEC replay.

Share-count change classifications are reported holdings differences; stock
splits/corporate actions can change counts without a manager actively trading.

## 6. Reusable ownership, entities and features

SF3A ownership history compares only adjacent quarters. SF3 holder changes perform
a full union of institutions in the current/prior quarter and classify NEW,
INCREASED, UNCHANGED, DECREASED and EXITED; security type stays in the key.
An absent/unfinished quarter must not imply every holder exited.

Security identity is `permaticker`, verified issuer CIK where available is the
company identity, and institution identity is the vendor investor ID. No fuzzy
manager-name merge or guessed CIK is acceptable. Registry metrics carry units,
source field/derivation and provenance. Deterministic feature definitions carry
version and their underlying facts. This creates no stock ranking or new model.

## 7. Sync, permanence and operation

`python -m fact_os backfill` downloads full historical bundles. `python -m fact_os
sync` refreshes changed records with per-table state and overlapping recent
windows. Holdings families refresh recent quarters, not only today's date.
Natural-key UPSERT preserves old rows absent from a later shorter response.
Schema drift and invalid rows must be explicit, never silently dropped.

Daily local scheduling is configured as Codex heartbeat automation `thesisforge`,
ACTIVE at 07:30 in the host's current Asia/Riyadh timezone, with failures-only
notifications. Its saved configuration was read back from
`~/.codex/automations/thesisforge/automation.toml`. It runs this project's
`bin/fact-os sync`, checks `bin/fact-os status`, and may run `bin/fact-os gc
--apply` after successful sync. Garbage collection is limited to unreferenced,
retired derived Parquet generations; raw archives are retained permanently.
The job explicitly excludes production and private user databases, and skips
concurrent ingestion instead of duplicating downloads. Configuration is verified;
the next unattended scheduled execution has not yet occurred in this audit.
Production scheduling is explicitly deferred by the user. Repeated sync and
subscription-downgrade tests must verify row counts, oldest dates, and duplicate
keys as well as process exit.

## 8. Validation and scoped release gates

```bash
.venv-fact-os/bin/python -m unittest discover -s fact_os -t . -p 'test_*.py'
.venv-fact-os/bin/python scripts/audit-fact-os.py --sqlite-inventory --full --offline-probes --require-complete
node --test server/valuationFacts.test.js
.venv-fact-os/bin/python -m unittest discover -s scripts -p 'test_fact_os_valuation_export.py'
node --test server/*.test.js
flutter test
flutter analyze lib/main.dart test/valuation_fact_card_test.dart
```

The audit script pins the published manifest, reads immutable Parquet through an
in-memory DuckDB connection, checks table grains/date coverage/dimensions, and can
run the actual repository with socket connections disabled. It never prints
licensed record-level data, credentials or private portfolio rows. Run it after
all backfills complete; partial migration correctly reports missing datasets.

Verified adapter tests: eight Node tests cover raw-price replacement, absent-data
behavior, avoiding US ADR/GBP quote mixing, AR cutoff propagation, one-batch
dashboard loading, ETF prices from the local funds table, exact financial units,
and rejecting future-period/missing-FX inputs. Three Python export
tests cover keeping ART unannualized, earliest AR rows independently by dimension,
and rejecting missing FX/share-factor assumptions. The four initially completed
tables (tickers, actions, holdings_ticker, holdings_investor) had zero duplicate
natural keys and zero null keys on a full scan. Later full-download checkpoints
have individually scanned the other ten tables too, with no duplicate/null keys.
The final stable all-table audit, `migration-final-verified.json`, now passes after
both real syncs and offline replays; individual earlier checkpoints were not
treated as the migration completion gate.

The valuation runtime now exposes current canonical financial facts separately
from exact archived model-input bundles. Quotes and comparison ratios use local
raw prices; published fair values are not falsely declared recomputed. Existing
historical model-input panels continue to be historical model artifacts, not a
current financial statement service. The latest financial card in `lib/main.dart`
now consumes `currentFinancials.display`, a semantic, explicitly USD projection:
ART TTM revenue, ARQ same-quarter YoY revenue growth, TTM operating/FCF margins,
TTM CFO minus capex, and diluted share equivalents. It labels source/availability,
keeps missing values missing, and does not apply the generic percentage heuristic
to source ratios. Selecting an older model quarter retains the archival input
card. No model value was changed or declared refreshed.

Latest completed regression runs: existing Node suite **51/51**, Fact OS Python
suite **127/127** (10.997 seconds), complete Flutter suite **15/15**, migration helper
tests **32/32** (including fourteen replay-verifier and three backup-header tests). Python
includes six A→B→A/no-op regressions and nine reporting-currency tests. Flutter
includes ten canonical-quote boundary regressions. These complement, rather than
substitute for, the separately recorded successful live and offline warehouse runs.
Missing canonical quoted prices are displayed as missing rather than zero in the
valuation overview/detail/output cards. `flutter analyze lib/main.dart
test/valuation_fact_card_test.dart` found no issues. These synthetic/regression
checks supplement, not replace, final real warehouse coverage validation. Official
source anomalies retain `_quality_issues`; the audit separately counts the raw
anomalies and fails any unflagged invalid record. Semantic readers must reject
invalid facts even when the authenticated raw archive contains them.

Additional real-data evidence captured under `data/fact_os/audit/`:

- `migration-key-audit-20260919.json`: full natural-key scans of tickers (74,232),
  actions (699,833), holdings_ticker (670,111), holdings_investor (306,476), all
  duplicate/null keys zero.
- `migration-holdings-financials-audit-20260919.json`: fundamentals (3,217,358
  rows, all six dimensions, 112 source columns) and holdings (81,202,367 rows,
  eight security types), all duplicate/null keys zero. The 25 official financial
  observations whose report period is after availability are all explicitly
  flagged; no unflagged PIT anomaly was found. These rows are retained raw but
  rejected by semantic financial reads.
- Local Node valuation integration returned MSFT ARQ/ART through 2026-06-30,
  available 2026-07-29; all six financial-card measures were populated from
  canonical data. At that check stocks/funds/daily were still pending, and price
  absence remained explicit. This partial check is not a full-price cutover claim.
- All 20 original application SQLite table counts still matched the consistent
  rollback backup after tests. No private portfolio payload was read or printed.
- `migration-stocks-audit-20260919.json`: all 45,354,729 stock-price records,
  1997-12-31 through 2026-09-18, have zero duplicate/null natural keys and zero
  invalid raw/split/total-return prices in the authenticated new source archive.
  `migration-price-semantics-20260919.json` compares every one of NVDA's 6,957
  observations (1999-01-22 through 2026-09-18) across all three semantic APIs
  against their exact warehouse fields, with zero mismatches and network disabled.
  Raw versus split prices differ on 6,386 dates; split versus total-return prices
  differ on 6,949, verifying these are genuinely different series, not aliases.
- Seven original full-download ZIPs now have content-addressed `.metadata.json`
  sidecars alongside them under `raw/`, recovered by
  `scripts/recover-fact-os-archive-metadata.py`. It joins unique recorded
  `verified_full_bulk` ingestion and bulk-redirect evidence to the exact file
  SHA256, saved resume ETag/length and ZIP member metadata. No network or vendor
  row changes occur. Exact download-completion time was not separately captured
  and remains null; ingestion observation and metadata recovery time are distinct.
  It rejects ambiguous runs, mismatched paths/lengths/checksums and overwriting
  conflicting metadata. Re-execution verifies the existing sidecar unchanged.
- `native-query-window-coverage.json`: native all-market SF1 queries were found
  to silently clip long historical ranges. Disjoint four-year windows recovered
  29,275 keys in the tested update scope, matching all six local dimensions with
  no missing/extra keys. This is a projected-key comparison, not an all-value audit.
- `native-incremental-window-evidence-20260919.json`: DAILY needs shorter initial
  windows than SF1. A stable four-year query response omitted 93,094 historical
  keys in the tested update scope; independent annual queries exposed the defect.
  The interrupted adaptive sync is not accepted, even though some tables succeeded.
- `daily-year-window-repair-verification-20260919.json`: one-calendar-year initial
  windows repaired the original 2026-09-04 through 2026-09-19 update scope. Saved
  raw and local scope both contain 291,900 rows; missing/extra/duplicate keys and
  differences in all ten typed source fields are zero. All 93,094 earlier missing
  keys are present. This is an independent local comparison, not another upstream
  download, and does not certify other tables or the pending two-pass run.
- `live-sync-table-horizons-verified.json` was safely interrupted in stocks before
  any completed second pass. It is not accepted. The latest frozen engine uses
  contiguous 31-day price seeds for known stocks/funds history, while retaining
  four-year seeds from 1900 to before the local earliest date; scope is not cut
  back to accelerate queries. DAILY keeps one-calendar-year initial windows.
- `live-sync-small-price-windows-verified.json`, started
  2026-09-19T14:48:44.235945+00:00, was also safely interrupted (SIGINT, exit 130).
  First-pass results cover 13 tables; holdings had extracted 7,255,286 records
  but was still verifying and had not published when the run stopped. No second
  pass completed, so this receipt is not accepted. Its matching start/observed
  fingerprints apply only to that interrupted engine version, not the new fix.
- High-risk replay defect, reproduced offline: `Store.ingest` skipped input when
  its checksum appeared in any past ingest run. In an A→B→A source-revision chain,
  the final A was therefore skipped and current canonical values wrongly stayed
  at B. Raw-file content addressing is valid; historical occurrence is not proof
  of current-table equality. The minimal fix is to remove that unsafe fast path
  and determine no-op from current typed contents, preserving immutable partitions
  and truthful per-row lineage. That fix is now applied only in `store.py`, with
  six new tests in `test_store_revision.py`; the complete 118-test Python suite
  passes. Each valid observation gets a metadata receipt, including no-ops, while
  a no-op leaves all current Parquet files and canonical `_ingestion_run` values
  unchanged. Multiple receipts for one checksum are observations, not duplicate
  facts; raw files remain content-addressed.
- The new frozen-engine acceptance is `live-sync-revision-safe-verified.json`,
  with baseline `live-sync-revision-safe-source-start.json`. Both 14-table API
  passes completed successfully, from 2026-09-19T15:48:52.578931Z to
  18:41:04.149292Z. All four original assertions are true and errors is empty;
  final unchanged-engine verification also passes. Pass 2 is unchanged for every
  table. Independent replay and stable audits are not certified by these results.
  Earlier interrupted runs are not accepted or carried forward. Stocks,
  funds and DAILY are unchanged at 45,354,943 / 15,637,697 / 39,818,815 rows, with
  actual sync durations of 2,826.132 / 718.242 / 154.522 seconds respectively.
  The latest stocks run took 47.1 minutes, longer than the earlier interrupted
  run; do not assert stable performance gains or confuse full-market background
  synchronization with offline per-symbol query latency. First-pass holdings was
  unchanged at 81,202,367 local rows, input 7,255,286 across three quarters and
  99 double-verified leaves; elapsed 2,023.388 seconds (33.7 minutes).
- `revision-safe-insiders-events-tickers-audit-20260919.json`: insiders +190
  includes 70 Form 3, 113 Form 4 and seven restatement-status records, not 190 new
  trades. Forty-one AMD rows absent from the new source have an unresolved cause
  and are retained. Events +4 includes a possible CND/CRCL remapping whose distinct
  official issuer/security identities prohibit an inferred rename or company
  merge. Both datasets have zero dropped historical keys, duplicate official
  keys or incoming-field mismatches. Tickers' three additions represent two
  securities and were written in an earlier run; this pass is 74,235→74,235 with
  only a new metadata receipt and unchanged canonical row lineage.
- `verify-fact-os-replay.py` is supplementary offline same-input evidence, not a
  replacement for two successful real API passes. It requires a completed live
  receipt and exact current-input preflight before replaying recorded inputs.
  Legitimate upstream additions between the live passes must be explained with
  saved source keys; preserve any false static-count assertion rather than
  relabelling it true. An initial actual warehouse attempt
  failed preflight with `stale_or_missing_canonical_input:stocks` before any
  Store.ingest call. The failure is retained in
  `offline-replay-revision-safe-final.json`. Independent investigation found a
  verifier false positive: an older partition without `_quality_issues` acquires
  nulls through a mixed-schema union, although all ten official stocks fields
  matched. The partition-aware verifier fix has fourteen tests. The actual
  OS-network-denied rerun `offline-replay-partition-aware-final.json` passes all
  five assertions: 14 tables replayed twice unchanged, official input contents
  matched, dates/counts did not change, and all 366 Parquet paths/bytes/mtimes were
  unchanged. Only observation/audit metadata was written. Failed evidence is not
  relabelled successful; the rerun has its own receipt.
- `stocks-small-windows-verification-20260919.json`: all 2,688,554 saved incoming
  records match canonical keys and every one of the ten source fields. All 213
  appended keys occur in the raw source, no old key was lost, and 29 older
  partitions stayed unchanged. This is a stocks-only local integrity check.
- `actions-new-key-audit-20260919.json`: +266 official keys consist of two listed
  observations and 264 re-dated relationship observations, not 264 new economic
  events. Twelve existing-key value revisions are separate from appended keys.
- `metrics-sp500-new-key-audit-20260919.json`: metrics +230 is two new observed
  tickers and 228 changed observation dates; 8,058 existing keys have source-field
  revisions. The UGAZF backward-date revision has an unresolved upstream cause
  and remains preserved. The +503 sp500 records merely advance the `current`
  snapshot date; the constituent set and all other fields are unchanged. Both
  tables have zero duplicate official keys, lost old keys or incoming-field
  mismatches. Observation dates must not be reinterpreted as publication times.
- `consumer-offline-migration-final.json`: actual Node/Python consumers passed with
  OS-level network denial and zero fetch attempts. Latest prices for NVDA/MSFT
  (all three bases) and SPY/QQQ/SCHD/KMLM (official funds routing) reach 2026-09-18.
  MSFT has 133 and AVGO 70 canonical financial quarters; AVGO's latest availability
  is 2026-09-10. Archived model values stay unchanged and explicitly unrecomputed.
  Local stock history reads were 620–979 ms, funds 374–507 ms and MSFT/AVGO
  valuation adapters 2,216/1,963 ms; these
  measurements are not a browser-page benchmark or production SLA. Runtime:
  Python 3.14.7, DuckDB 1.5.5, httpx 0.28.1.
- `migration-final-verified.json`: OS-network-denied final audit at
  2026-09-19T18:53:15Z passes across all 14 tables and 201,159,454 facts/observations.
  Every natural-key duplicate/null count is zero; every state row count matches
  actual Parquet, all full backfills are complete, and no required table is absent.
  Both stock/fund price-invalid counts are zero. The 25 source financial PIT
  anomalies are flagged, with no unflagged invalid row. All ten offline semantic
  probes pass. Canonical manifest SHA is
  `7032087b9290d2c5b592ee60c0df74cfcf6f95f240e8f4ae72cea0fdefcda58e`, unchanged
  during this audit and matching the final storage audit. All three original
  SQLite files have `quick_check=ok`; the separate backup preservation result is
  recorded above. No private row payloads or per-user databases were opened.
- `storage-migration-final.json`: at 18:49 UTC the Fact OS directory contained
  8,809,478,021 logical bytes (8.81 GB / 8.20 GiB), 8,832,761,856 allocated bytes.
  Raw plus metadata was 4,781,246,763 bytes; all 38 content-addressed raw files
  match their SHA, with zero byte-identical duplicate files. Current Parquet is
  347 files / 3,163,460,374 bytes; 19 retained rollback files total 147,331,428
  bytes. No missing partitions or byte-identical Parquet duplicates were found,
  GC eligibility is zero and no files were deleted. Raw snapshots and derived
  columnar data intentionally coexist; only manifest-referenced data enters
  queries. The root disk had approximately 33 GiB free and 97% use, so capacity
  remains an operational watch item, not a claim of unlimited growth.
- The actual frontend/API for this project was not running at inspection
  (5174/8787/old 5186 not listening). The adjacent `guru-intelligence` preview on
  5184 is an older, separate project and was not changed. Adapter/Flutter tests
  do not establish that a browser currently displays this migrated application.
  A later local UI check can start `FACT_OS_ENABLED=1
  PORTFOLIO_NAV_AUTO_CAPTURE=false npm run dev`; this command was not executed
  during the audit and keeps the private NAV-capture timer off for that check.
- Final frontend review found and fixed an implicit archived-price fallback:
  canonical quotes absent in `valuationRowsFromTickers` must not use archived
  `externalConsensus.currentPrice`, and two detail views must not borrow an old
  `selectedRow`. A shared quote guard covers all three entrances and valuation
  verdict/filter eligibility. Missing remains missing; archived model fair values
  and explicit legacy rollback behavior are preserved. Ten new tests in
  `valuation_quote_boundary_test.dart` pass; the full Flutter suite is now 15.
- Reporting-currency metadata was separately corrected without altering source
  amounts or valuation algorithms. SF1 raw rows do not contain `currency`.
  Latest `get_metric` without as-of resolves reporting currency from the exact
  official SF1/permaticker master, with current-master provenance and currency
  PIT explicitly unsupported. BABA=CNY and TSM=TWD were verified locally; their
  SEP quotation currency must not be reused as financial reporting currency.
  Historical/as-of native currencies remain unknown. Unknown native amounts
  cannot combine with USD; a ratio may cancel currency only for the same security
  and exact same full SF1 row lineage. Existing USD valuation projections, seven
  metric definitions and FCFMargin v1 values are unchanged. Nine new regressions
  in `test_repository_currency.py` pass; synchronization-engine files were untouched.

### Interrupted acceptance history (not successful runs)

The concise 15-item report intentionally omits this chronology. Every old receipt
is retained in `data/fact_os/audit/`; a filename containing `accepted`, `final` or
`verified`, an empty error list, or a `finished_at` alone is not proof of acceptance.

| Receipt family | Finding / reason for restart | Status |
|---|---|---|
| `live-sync-idempotency*.json` | Non-zero skip limit, malformed source CSV fields, false-empty far-future bounds | Failed/interrupted; not accepted |
| `live-sync-accepted.json`, `live-sync-complete-extracts.json`, `live-sync-final-verified.json` | Native long SF1 scope clipping, ticker discovery and extraction completeness refinements | Earlier incomplete evidence; not accepted |
| `live-sync-range-verified.json` | Long blocking source reads; required explicit response/read bounds | Interrupted; not accepted |
| `live-sync-bounded-verified.json` | SF3 pass 1 succeeded in 1,558.872 seconds, stocks large CSV ranges timed out | Partial only; not accepted |
| `live-sync-price-bounded-verified.json` | A 10k row cap alone did not eliminate cross-date timeouts | Interrupted; not accepted |
| `live-sync-adaptive-verified.json` | Stocks succeeded in 1,950.676 seconds; DAILY four-year windows silently omitted 93,094 keys | Interrupted; not accepted |
| `live-sync-table-horizons-verified.json` | DAILY one-year scope fixed; saturated stock parent windows still excessively slow | Interrupted; not accepted |
| `live-sync-small-price-windows-verified.json` | Stocks 1,466.773 seconds; new A→B→A checksum defect found before SF3 publication | SIGINT exit 130; no complete second pass |
| `live-sync-revision-safe-verified.json` | Content-based no-op/revision fix; both 14-table API passes and final source fingerprint pass | Accepted live run; separate partition-aware replay and final stable audit also pass |

Independent range evidence complements, not replaces, these receipts. SF1's nine
four-year windows yielded 29,275 distinct updated keys, missing/extra zero. DAILY
2000–2003 annual probes yielded 36,947 keys versus only 8,147 in the prior wide
extract for those years. The repair of the original 15-day update scope saved
291,900 rows, restored all 93,094 omitted keys and matched all ten typed source
fields. Stocks' small-window extract matched 2,688,554 incoming rows and ten
source fields, with every one of its 213 appended keys supported by raw data.
These timings involve changing upstream inputs and are not a controlled benchmark.

`scripts/export-fact-os-valuation-source.py`
exports a **new** compatible PIT source SQLite from FactRepository for the existing
model rebuild, preserving existing guidance/FX via SQLite backup. It refuses to
overwrite an existing file, detects source-generation changes, and never updates
the original application DB or runs/redefines a DCF. Foreign quoted securities
without a verified mapping remain explicit blockers. Rebuilding model outputs
also requires canonical raw-price materialization/adapter and validation on an
isolated candidate DB; the exporter alone does not complete that gate.

### Exact isolated model-rebuild plan (not executed)

1. Wait for validated full fundamentals, stocks, funds and tickers. Export to a
   new source file with `scripts/export-fact-os-valuation-source.py --output
   data/fact_os/derived/valuation-source.<run>.sqlite --as-of <cutoff>`.
2. Transactionally back up the application SQLite into a **new candidate** file.
   Do not operate on `server/data/guru-analysis.sqlite`. Preserve issuer guidance,
   research and private tables unchanged.
3. Materialize canonical RAW_CLOSE quotes into the candidate's valuation
   `priceHistory` and `price_points`, with source generation/basis. Existing
   `importPitQuarterlyValuations.js` chooses the longer of those two price arrays;
   retaining either old array can silently reintroduce old Yahoo quotes. Both
   candidate projections must be canonical before running it. No unsupported
   foreign security/currency mapping is guessed.
4. Update only import provenance labels from the old `jansen_pit_*` source labels
   to the actual source metadata. Keep existing `buildValuationRows`/DCF math and
   valuation profile constants unchanged.
5. Audit using `SQLITE_DB_PATH=<candidate.sqlite>
   PIT_VALUATION_SOURCE_PATH=<new-source.sqlite>
   node server/importPitQuarterlyValuations.js` without `--apply`. Even this mode
   creates PIT tables, so use only the isolated candidate. Do **not** use
   `--allow-incomplete` to hide blockers.
6. Only after blockers and PIT/input/price tests pass, run the same command with
   `--apply` **against the candidate**, validate model provenance and unrelated
   table counts, and review a local release separately. No rebuild or original
   DB replacement was performed as part of this audit.

Local data-layer acceptance gates (completed with the receipts above):

- Validated complete required datasets; row counts and date coverage recorded.
- No duplicate natural keys; typed prices/fundamentals valid or explicitly quarantined.
- Local NVDA prices, MSFT AR fundamentals/dividends, GOOGL ownership and holder changes.
- Two successful real API passes, with original assertions retained and any
  legitimate source changes explained; same-input replay must add no fact rows
  or Parquet generations and lose no older history.
- Shorter remote/denied entitlement cannot truncate local history.
- Ticker change/entity identity tests and exact adjustment semantics.
- Every active runtime consumer audited; no old cache or network fallback bypass.
- Derived model inputs are rebuilt from canonical facts or clearly archived; never relabel old model output as newly computed.
- User-data boundary, unrelated table counts, old rollback data unchanged.
- Daily local scheduling explicitly configured/verified; production remains untouched.

These gates do not certify exact 13F filing-time replay, all foreign identity
coverage, new derived model outputs, a running browser application, production
deployment, or the scheduler's first future unattended execution. Those remain
explicit boundaries, not hidden substitutions for missing facts.

## Official references

- [API and authenticated full-bulk protocol](https://sharadar.com/llms.txt)
- [Fundamentals and dimensions](https://sharadar.com/docs/fundamentals)
- [Stock price adjustments](https://sharadar.com/docs/stocks)
- [Security master](https://sharadar.com/docs/tickers)
- [Institutional holdings](https://sharadar.com/docs/holdings)
- [Ticker-level ownership](https://sharadar.com/docs/holdings-ticker)
- [Institution summaries](https://sharadar.com/docs/holdings-investor)
- [Usage and identifier notes](https://sharadar.com/docs/faqs)

Local entitlement is not permission to redistribute licensed data publicly. A
future production release needs its own entitlement/licensing and performance
checks; no such release is performed in this local migration.
