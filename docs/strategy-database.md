# Structured strategy database

This is an additive SQLite warehouse for the local Strategy Lab. It preserves
the original runtime database unchanged. It is not a fresh 13F update, a new
valuation release, or a claim that missing historical data has been repaired.

## Data model

| Tables | Grain and purpose |
| --- | --- |
| `warehouse_meta` | One immutable import generation: cutoff, versions, semantic hash and original table counts. |
| `source_documents`, `document_holdings` | Original source content plus one row per SEC information-table line; raw reported units remain distinct from USD-normalized book values. |
| `managers`, `manager_entities` | Manager profile and each configured filer CIK; explicit identity review state. |
| `filing_manifest` | Manager × original accession from the public SEC manifest, with document URL/hash. This manifest is a historical selected-book inventory, not full live coverage. |
| `filings`, `filing_holdings` | Manager × accession, then each stored claim; report/public dates, security title, SH/PRN, put/call, CUSIP, shares and value. Legacy Top10 extracts remain explicitly incomplete and unverified. |
| `holding_resolutions`, `security_identifiers` | Exact filing-line identity resolution and independently built public security master. Issuer-name fallbacks remain unresolved. |
| `corporate_actions` | Effective-dated action and consideration; full reviewed rule/evidence retained. The serving policy must match the stored action version. |
| `price_series`, `price_observations`, `etf_catalog` | Symbol × provider × storage origin, then actual trading date. Raw close, adjusted close and snapshot prices are separate; conflicting observations are never overwritten or averaged. |
| `financial_records`, `financial_metrics` | Ticker × fiscal period × ARQ/ART dimension, then named metric with unit and lineage. Original payload/statement currency preserved. |
| `guidance_events` | Original source owner × event ID; observed date, fiscal period, owned metric, amount, unit, currency, speaker, excerpt and quality state. Stored evidence is not automatic model authorization. |
| `valuation_nodes`, `valuation_metrics` | Ticker × fiscal period × model version, then financial/TTM metric. Fair value, formula, model date, source-availability dates and original inputs/outputs remain separate. A blended value is not relabeled DCF. |
| `model_price_evidence` | Exact model-version/fiscal-period comparison price, with provider and quote currency. |
| `coverage_issues` | Deterministic issue ID, category, severity, manager/filing/ticker/date and evidence. Missing values stay NULL. |

`verified_common_holdings` excludes unverified security classifications and the
known incorrectly attributed manager. It verifies claim classification, **not**
all manager identities, return histories or valuation models. Configured managers
not independently reviewed in this migration remain `configured_unreviewed`.

## Local import

Run from the repository root. Choose a new output filename for every generation:

```sh
node scripts/import-strategy-database.mjs \
  --source output/investment-workflow-20260908/runtime.sqlite \
  --output output/strategy-store-20260910/strategy-current.sqlite \
  --as-of 2026-08-28 \
  --etfs output/strategy-lab-20260909/etf-inputs.json \
  --filings output/strategy-lab-20260909/original-filings/filings.json
```

Optional `--evidence` points to a private JSON array of exact source-document
descriptors (`file`, `url`, optional raw SHA-256 `hash`, `scale`, `kind`). It does
not execute instructions from those documents. Files are read without downloads.
Optional `--generated-at` fixes the import timestamp for reproducible releases;
do not use a future timestamp or relabel the underlying data cutoff.

The source is held in one read transaction with `query_only=ON`. The importer
writes only a NEW candidate, checks source counts, foreign keys and integrity,
then publishes with an atomic no-clobber hard link. No `INSERT OR REPLACE` or
destructive in-place migration is used. Identical immutable rows are idempotent;
same-key conflicting data aborts the transaction. Failed candidates are retained
at the reported `.building-*` path for inspection, never selected for serving.

Every table has a deterministic content hash. Generation identity includes all
price and financial values, not just row counts. A one-price change changes the
generation. Import wall-clock time is excluded from semantic hashes. Original
source event dates and source payloads are preserved.

```sh
node scripts/verify-strategy-database.mjs \
  output/strategy-store-20260910/strategy-current.sqlite \
  output/investment-workflow-20260908/runtime.sqlite
```

An optional third argument is the previous generation's `.import.json`, for an
exact repeated-import manifest/table-hash comparison. A fourth argument writes
the verification result to a new private JSON file. The completed local import
and remaining quality backlog are recorded in
[`audits/strategy-structured-database-2026-09-10.md`](audits/strategy-structured-database-2026-09-10.md).
Licensed row-level data,
the SQLite files and private evidence remain in ignored `output/`, never Git.

## Serving integration and rollout boundary

`STRATEGY_DATA_DB_PATH` opts the existing Strategy Lab catalog/worker into
`server/strategyDatabase.js`. ETF, filing, price and valuation reads then come
from SQLite; the runtime no longer needs the original ETF/filing JSON files.
The old reader remains unchanged when this variable is absent. An invalid
configured database never silently falls back to old artifacts.

Do **not** enable this switch globally merely because import passed. The strict
reader rejects legacy books whose security fields are not verified, the known
manager mismatch, stale schema/security/action versions and a requested end
beyond the stored cutoff. A storage import pass is separate from a strategy
release pass. Complete original common books, missing models and disputed price
evidence must still be reconciled before promoting all strategies.

The runtime corporate-action evaluator remains shared code, bound to the exact
stored action version; action records and source evidence are queryable in SQL.
The migration does not change manager names/CIKs in the production catalog,
lower the 90% execution gate, or modify a user's saved rules and portfolios.

## Example queries

```sql
-- Disposition and backlog, not a claim of healthy strategy performance.
SELECT * FROM coverage_summary ORDER BY severity, category;

-- Exact security evidence (PRN must not become a U common-stock price).
SELECT cusip, security_title, amount_type, reported_value, value_multiplier
FROM document_holdings WHERE cusip IN ('91332UAB7', '91332U101');

-- Annual/quarterly dimensions and missing values are kept distinct.
SELECT f.ticker, f.fiscal_period, f.dimension, f.available_at, f.currency,
       m.metric, m.value, m.unit
FROM financial_records f JOIN financial_metrics m ON m.record_id=f.id
WHERE f.ticker='NVDA' AND m.metric IN ('revenue_m','fcf_after_capex_m')
ORDER BY f.available_at DESC, f.dimension;

-- Evidence, not silent consumption of management statements.
SELECT ticker, fiscal_period, observed_at, metric, amount, unit, currency,
       quality_status, speaker, source_url
FROM guidance_events WHERE ticker='NVDA' ORDER BY observed_at DESC;

-- Native fair-value field, available at a chosen cutoff, with model version.
SELECT ticker, fiscal_period, as_of_date, model_version, currency,
       fair_value, formula, quality_status
FROM valuation_nodes WHERE ticker='NVDA' AND as_of_date<='2026-08-28'
ORDER BY as_of_date DESC;
```

## Required tests

Run `node --test server/strategyDatabase.test.js server/strategyLab.test.js
server/strategyLabRoutes.test.js server/strategyFilings.test.js`.
Coverage includes debt/common separation, unverified legacy classifications,
manager quarantine, immutable-key conflicts and rollback, independent raw XML
hash validation, source preservation, NULL handling, future-source quarantine,
reader operation without JSON artifacts, generation changes on one price edit,
identical repeat imports, schema/version mismatch and cutoff enforcement.

This task does not authorize a production migration. An AWS promotion requires
a separate approved release, rollback material and the existing repository gates.
