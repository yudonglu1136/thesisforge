# Local canonical consumer cutover

This change is local to `fundamental-analysis`; it does not deploy or alter AWS,
Vercel, user accounts, broker credentials, or private portfolio databases.

## Source selection

`FACT_OS_ENABLED` is enabled by default. Set `FACT_OS_ROOT` only when the local
store is not `data/fact_os`, and `FACT_OS_PYTHON` only when the interpreter is not
`.venv-fact-os/bin/python`. The Node reader passes **no provider or portfolio
credentials** to Python. `fact_os.rpc` exposes only named repository read methods;
there is no arbitrary SQL, network endpoint, sync, or write operation.

The reader pins an immutable Parquet catalog, uses bounded sequential local scans,
and caches at most 512 results / 64 MB keyed by catalog generation. A catalog change
invalidates the cache; missing runtime/data returns explicit unavailability. A batch
that crosses catalog generations is rejected and can be retried. Missing canonical
data does not enable Yahoo, SEC parsing, old SQLite facts, or cached return curves.
Every application RPC checks that each required table has a complete verified
backfill. Coverage can be inspected while incomplete; a direct diagnostic RPC can
explicitly request `allow_partial: true`, but the application bridge never sends
that flag. Partially migrated archives therefore cannot appear to be complete app
data.

Portfolio and dividend readers retain the exact broker listing: `.L` is never
stripped to try a US ADR, and a company name is not treated as listing evidence.
An incompatible/unverified quote currency is explicitly unavailable. An explicit
USD `quoteCurrency`/`priceCurrency`/`tradingCurrency` can be distinct from the
account's display/base currency; the exact ticker still resolves through the
official local security master.

`FACT_OS_ENABLED=0` is an explicit operator rollback to old code, logs a warning,
and voids the canonical-only guarantee. It is not an automatic failure fallback.

## Existing consumers

| Consumer | Active canonical source | Meaning / limitation |
| --- | --- | --- |
| `marketData.loadPriceSeries` | `FactRepository.get_price_history` | Mandatory explicit raw, split-adjusted, or total-return-adjusted basis; stock and fund tables are both Sharadar sources |
| Portfolio risk / trailing returns | Local total-return-adjusted prices | No price-point SQLite fallback; broker NAV, cash income, and user records stay untouched |
| Portfolio dividend calendar | Local actions | Historical ex-date, split-adjusted USD/share; no invented payment date or payout from current shares |
| Guru dashboard | Local SF3, SF3B, ticker metadata | Exact CIK matching including configured alternate filers; missing/overlapping reporting-entity mapping is explicit |
| Guru exposure history | Local SF3 / SF3B | Reported quarter observations, shares, value, original security types, ranks, weights, and changes |
| Guru market context | Local total-return-adjusted prices | No trade-date markers fabricated from quarter ends |
| Guru historical copy simulation | Unavailable until verified disclosure timing exists | SF3 does not supply actual filing availability timestamps; old cached simulations are not returned |
| Valuation import endpoint | Local valuation read | It no longer spawns the custom SEC fundamentals importer in canonical mode |
| Legacy price refresh CLI | Retired guard | Use Fact OS `sync`; old price-point writes are not run |
| Dividend / Guru-backtest automatic refreshers | Disabled in query process | Canonical ingestion owns schedules, not app reads |
| Legacy Ontology strategy/ranking/market/heatmap/DBMF snapshot endpoints | Explicitly unavailable | HTTP 503 with `archived_quantitative_source_unavailable`; no old SQLite or hot-cache quantitative payloads returned. Health remains safe metadata only. No Ontology was rebuilt. |

The valuation adapter is handled separately in `valuationClient.js`. Existing model
artifacts are not automatically recomputed merely by changing their market-price
or raw-financial source. Rebuilding models and verifying their lineage is a separate
release gate. No DCF or portfolio algorithm is rewritten by these adapters.

Portfolio analytical overlays identify their actual price mode and retain the
archived-model status and input policy when projecting valuation summaries. A
broker-reported mark remains explicitly distinguished from a canonical market
quote. The in-memory overlay cache is scoped by user, source mode, and canonical
catalog generation; publishing a new generation invalidates that user's older
overlay without changing private account records. Canonical Guru profiles use an
unavailable disclosure-timing label, never a copy-simulation eligibility label.

SF3's share changes remain **reported units**, not split-adjusted trading intent.
All official security types are preserved. `CLL` is translated to the legacy UI's
`putCall: CALL` label only; its canonical `securityType` remains `CLL`. Reported book
weights use the SF3B reported total value, not fund NAV.

## Verification

```sh
node --test server/*.test.js
.venv-fact-os/bin/python -m unittest fact_os.test_rpc
flutter test --no-pub
flutter analyze --no-pub
```

Final verification passed all 51 Node consumer tests and all 15 Flutter tests.
The earlier timed 51-test Node run took 3.70 seconds; the final static analysis
reported no issues in 3.3 seconds. Coverage includes generation/source/user cache
separation, compact valuation provenance, canonical Guru simulation labels, and
10 new Flutter quote-boundary regressions. Canonical missing or incompatible
quotes cannot fall back to archived consensus prices or stale selected dashboard
rows; list comparisons, research details, and valuation verdicts use the same
safe quote. Archived model values and explicit legacy rollback behavior remain
unchanged. These are local tests, not production performance measurements.

The tests block `fetch`, seed old SQLite prices/backtests in a temporary test
database, and verify they are not used when canonical data is absent. They also
verify explicit price basis, option types, null missing values, change-rate units,
missing filing dates, and foreign-listing/US-ADR isolation. The RPC tests reject arbitrary methods and safely encode
dates / non-finite values.

### Final full-data consumer smoke

The [final consumer receipt](../data/fact_os/audit/consumer-offline-migration-final.json)
was produced on 2026-09-19 after the completed two-pass local sync and successful
same-input replay. The OS sandbox denied all network sockets for both Node and
its Python reader; the socket-denial probe passed and `fetchAttempts` was **0**.
No private account database was opened: archived published models were read from
a disposable public-model SQLite fixture. Runtime per-table completeness gates
remain enabled even though the local backfill is now complete.

| Real application adapter | Verified coverage / source | Measured latency |
| --- | --- | --- |
| NVDA price history, all three explicit bases | 6,957 points per basis; local `stocks` | 620–979 ms |
| MSFT price history, all three explicit bases | 7,223 points per basis; local `stocks` | 622–668 ms |
| SPY / QQQ / SCHD / KMLM total-return history | 7,223 / 6,925 / 3,749 / 1,455 points; official master auto-routes to local `funds` | 507 / 495 / 438 / 374 ms |
| MSFT valuation consumer | 133 ARQ + 133 ART rows; period 2026-06-30, available 2026-07-29 | 2,216 ms |
| AVGO valuation consumer | 70 ARQ + 70 ART rows; period 2026-08-02, available 2026-09-10 | 1,963 ms |

All ten price queries and both valuation quotes end on **2026-09-18**. Both
valuation consumers returned current local financial facts, retained
`archived_not_recomputed`, and passed exact archived fair-value equality checks.
These are end-to-end local adapter timings for this sequential smoke run, not
production load tests or a cold/warm latency guarantee.

### Earlier independent source / Guru checks

Earlier offline checks against local ticker/actions/SF3B partitions confirmed
that CIK 1336528 resolves to PERSQU and Microsoft's 2026 dividend records remain
ex-dividend events rather than fabricated account income. The following Guru
measurements are separate, earlier runs; they are not part of the final price and
financial consumer receipt above.

After the then-completed SF3 backfill (81,202,367 rows), the real local Guru dashboard was
measured with network reads disabled: 28 configured profiles, all 19 institutional
13F managers available, and 1,375 position rows. Cold read was 4,353 ms; warm read
was 27 ms. The other 9 profiles are not 13F managers and are explicitly unsupported
by this institutional adapter, not populated from old custom snapshots.

Ackman's full reported-quarter history took 2,347 ms cold / 8 ms warm and returned
49 unambiguous quarters from 2013-06-30 through 2026-06-30. Four intervening quarters
(2025 Q2–2026 Q1) have overlapping configured reporting entities. They are flagged
for a verified consolidated-book mapping; they are neither summed nor guessed.
The 2026 Q2 filing-entity transition does not become a fabricated list of new Guru
purchases: manager-level changes are explicitly unavailable across that boundary.
These are local read-path measurements, not production load or SLA claims.
