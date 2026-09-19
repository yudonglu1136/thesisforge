# Strategy structured storage acceptance — 2026-09-10

## Outcome and boundary

The available local strategy inputs are now stored in a separate SQLite
warehouse with 21 tables, typed metrics, source lineage, indexes and foreign
keys. Import and read adapters are implemented. This is **storage acceptance,
not a strategy data-quality release**. The existing preview and production
have not been switched to this warehouse. No push or deployment was performed.

Canonical local generation:
`output/strategy-store-20260910/strategy-current.sqlite`

Source database (read-only throughout):
`output/investment-workflow-20260908/runtime.sqlite`

Serving cutoff: `2026-08-28`. Import date is not substituted for a source's
publication date. The database retains source records and their quality states;
the reader applies the requested historical cutoff.

Content manifest:
`f79265e76ce2fd3c483422e1130bf585572be94feaa59f65f7de0c2a05eedb3e`

## Imported inventory

| Data | Rows | Interpretation |
| --- | ---: | --- |
| Managers | 29 | Configured profiles, not 29 independently verified identities. |
| Filing history inputs | 1,109 | Includes 1,091 unverified legacy/incomplete books; not full raw 13F coverage. |
| Filing holding rows | 10,958 | Original class, CUSIP, share count, value and resolution status kept separately. |
| Raw SEC document lines | 2,345 | Raw information-table evidence, including non-common claims. |
| Price observations | 3,829,922 | Separate provider/origin series; not that many distinct market dates. |
| PIT financial records | 65,038 | 780,456 structured metric rows; raw payloads and units preserved. |
| Management guidance events | 85,312 | Evidence records, not automatically accepted model inputs. |
| Valuation model nodes | 31,953 | 1,565,706 structured metric rows plus original inputs/outputs. |
| Model comparison-price evidence | 31,636 | Exact model-period/version price and currency lineage. |
| ETF catalog | 2 | Actual KMLM and DBMF price series, no pre-inception synthetic data. |
| Security identity claims | 2,363 | Public security master and review status. |
| Corporate actions | 10 | Effective date, consideration and source evidence. |

## Verification performed

`npm run test:strategy:db`: **50 passed, 0 failed**.

Tests cover raw debt/common separation, unknown class handling, manager
quarantine, immutable-key conflict rollback, XML hash checks, NULL preservation,
future-source exclusion, reading without the original ETF/filing JSON files,
cutoff/version failures and generation changes when a price changes.

Two independent full imports produced identical manifest and per-table content
hashes. `scripts/verify-strategy-database.mjs` returned `pass` for all 14 checks:

- Original raw price counts and OHLC/adjusted-close/volume values reconcile.
- Source financial payloads, dates and currencies reconcile.
- Guidance payloads, amounts and observation dates reconcile.
- Model inputs, outputs and fair values reconcile.
- SQLite integrity check passes; foreign-key violations: 0.
- Verification is query-only; source writes: 0.
- Repeated import manifest and all table hashes agree.
- Known manager identity mismatch remains quarantined.
- Structured database reader works against the imported generation.
- KMLM and DBMF each cover all 1,255 requested benchmark sessions in the
  `2021-08-28` to `2026-08-28` window. This does not certify the stock sleeve.

Detailed result: `output/strategy-store-20260910/verification.json`.
Database files and licensed/private data are mode `0600` and remain in ignored
`output/`; they are not added to Git. `git diff --check` passes.

## Unresolved source-quality backlog

The quality-analysis workflow influenced the implementation: importing a row
does not approve it for investment use. Missing values remain NULL, conflicting
prices remain separate, and source classifications are never inferred merely
from a `-COMMON` suffix.

| Category | Issue records | Treatment |
| --- | ---: | --- |
| Manager identity | 1 | Known incorrectly attributed filer blocked by the new reader. |
| Comparison price | 1,834 | Conflicting evidence retained without averaging/overwriting. |
| Filing book | 1,091 | Legacy/incomplete inputs remain unverified. |
| Security identity | 1,132 | Unresolved claims are not silently converted to common shares. |
| Valuation coverage | 453 | Held identifiers without exact model coverage recorded explicitly. |

These are issue records, not disjoint counts of affected companies. In
particular, the 453 held identifiers may include ETFs and unresolved symbols;
they are not a claim that 453 operating companies require a conventional DCF.

The next data-quality release must reconcile full original common-stock books,
manager attribution, disputed price series and eligible missing models before
enabling `STRATEGY_DATA_DB_PATH` across the preview or production. Existing
saved user rules and portfolios were not changed. The 90% execution gate was
not lowered.

See [schema and operating instructions](../strategy-database.md).
