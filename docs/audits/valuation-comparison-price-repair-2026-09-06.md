# Comparison-only price repair — 2026-09-06

## Scope and initial findings

The additive 537-security model rebuild was blocked by the existing price-series
contract, starting at ABNB on 2026-08-28. The inventory uses the importer's exact
`price_points` query (`close > 0`, latest 10,000 rows per mapped price symbol),
unchanged source contracts, and unchanged numerical tolerance. It also invokes
the actual `mergeValuationComparisonHistory` implementation for every snapshot.

The read-only seed contains 537 snapshots and 937,479 snapshot comparison points.
The selected raw-price scope contains 1,466,224 positive observations. There are
76 blocking same-series conflicts across 61 securities: 60 securities on
2026-08-28 and 16 SPGI observations in 2001. All conflicts are Yahoo-versus-Yahoo;
there are zero existing Sharadar-versus-Sharadar conflicts and zero unknown
source identifiers in this scope. Before repair, 61 complete history merges fail.

## Independent source and narrow repair

For the 16 SPGI dates, the repair independently rereads the original paid local
Sharadar parquet `close` field. The 60 August 28 observations are absent from
that local partition, so an authenticated request through the existing paid
Sharadar client retrieves the exact ticker/date rows from the stocks endpoint.
The original response is frozen without credentials; its values are read again
by the preparer, independently of the normalized diagnostic output.

All 76 observations and their `lastupdated` adjustment vintages are no later than
the 2026-09-05 source cutoff. Neither `closeadj` nor `closeunadj` is substituted
for `close`. ABNB's original paid `close` is 189.43, dated 2026-08-28 and last
updated 2026-08-31. This is a new paid-series observation, not an assertion that
the two conflicting Yahoo observations are numerically equivalent.

The preparer requires a new `price-lane` output database and audit directory. It
changes only `valuation_ticker_snapshots.payload_json.priceHistory` and the
explicitly named `comparisonPriceSourceEvidence` metadata. Every replacement
point retains its native paid source identifier, field, adjustment basis,
cutoff, source-vintage date, and original-row hash. Original complete snapshot
JSON, original Yahoo points, raw database-price rows and paid-source evidence
are archived in a gzip JSON audit artifact.

In the NEW offline preparation database only, one exact, verified cache-revision
UPDATE trigger is temporarily suspended inside the snapshot-edit transaction
and then restored from its original SQL. This prevents offline seed preparation
from incrementing runtime cache state. A mismatched trigger definition is
rejected; an exception rolls back both the snapshot writes and trigger DDL.
All schema objects and trigger definitions must be exact afterward. This
mechanism must not be used for production or the final atomic release: the
subsequent normal model importer refreshes caches through normal triggers.

No `price_points`, financial input, valuation model, Guru backtest, user, login,
portfolio, or other non-snapshot row is changed. Snapshot `generated_at`, security
membership and every non-price payload field are preserved. Unrelated snapshot
payload strings are byte-exact. Every non-snapshot table is compared in both
directions, with row counts, and the original database hash must remain exact.

An existing paid-series conflict, missing original price, duplicate original
security/date, future adjustment vintage, non-USD snapshot, changed inventory
target, unknown provider, or failed post-repair actual merge remains blocking.
The script does not widen any gate, relabel Yahoo as paid, or change the model's
current-price field. A subsequent full model import must regenerate the latter
using its normal independently audited price selection.

## Reproduction

From the repository root:

```sh
python3 -m unittest scripts/test_prepare_valuation_comparison_prices.py
node --test scripts/inventory-valuation-comparison-conflicts.test.mjs
python3 scripts/prepare-valuation-comparison-prices.py \
  --source-db output/guru-valuation-expansion-2026-09-05/additive-full-rebuild-v30-four-20260906/model-diagnostic-run1.sqlite \
  --output-db output/guru-valuation-expansion-2026-09-05/price-lane-seed-v2-20260906.sqlite \
  --parquet /Users/yudonglu/Documents/jansen_us_firm_replication/data/sharadar/parquet/prices \
  --paid-api-raw output/guru-valuation-expansion-2026-09-05/price-lane-paid-api-raw-20260906.json \
  --source-cutoff 2026-09-05 \
  --audit-dir output/guru-valuation-expansion-2026-09-05/price-lane-prep-v2-20260906
```

The machine-readable result is `price-lane-prep-v2-20260906/report.json`. The first
candidate was correctly rejected when its cache-revision side effect violated
the exact-preservation gate; it must not be used. A repaired
comparison-price seed is **not** a model-release certificate: the full source,
model, economic-review and two-run release gates still apply. No production or
Git deployment is performed by this lane.

## Verified result

- Blocking same-series conflicts: **76 → 0**; affected securities: **61 → 0**.
- Actual core comparison-history merge failures: **61 → 0**, all **537** tested.
- Snapshot point count remains **937,479**; selected raw observations remain
  **1,466,224**. Exactly 76 snapshot points replaced across 61 snapshots.
- Original database unchanged; every non-snapshot table, schema/trigger
  definition, cache revision and unrelated snapshot passes exact preservation.
- Price-lane tests: **10 Python + 5 Node passed**, including trigger mismatch
  refusal and transaction rollback. Entire lane regression: **103 Python +
  14 Node passed** (includes the price tests).
- Original database SHA-256:
  `10e88850abddba31ac70702567e9b5fe1b3cbb945c5cff1258c8cebbfe6ada96`.
- Ready v2 seed SHA-256:
  `cc9b2e30835771af507eddbe455a5a13033e4670bf4e3537818f8bc73175262d`.
- Original snapshot/evidence archive SHA-256:
  `cac5baa8efd796ba80a6611a59a13adef40052b46a588f8cc8d571cbdce10ce1`.

The main integration task received the ready seed and the report path for the
normal full model import. This result clears only the comparison-price blocker,
not other source/economic-review or final deployment gates.
