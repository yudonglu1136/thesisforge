# ThesisForge single-root consolidation — 2026-09-19

## Decision

The only product root is `/Users/yudonglu/Documents/thesisforge`. Guru
Intelligence, Fundamental Analysis, valuation, portfolio, strategy and the
local Sharadar Fact OS are modules of this repository. Dated sibling folders
are retired build/data copies, not separate products.

## Canonical data locations

- Fact OS: `data/fact_os/`
- Public compatibility SQLite: `server/data/guru-analysis.sqlite`
- Active private portfolio: `server/data/user-portfolios/`
- Distinct private recovery objects: `server/data/private-recovery/by-sha/`

## Pre-delete evidence

- Fact OS full read-only audit passed all 14 datasets, full natural-key scans,
  required-table completeness and offline probes. Total canonical observations:
  201,159,454.
- Fact OS storage audit passed at 7,952,997,925 bytes, with zero byte-identical
  raw duplicates and zero retained unreferenced Parquet bytes.
- Runtime SQLite `PRAGMA quick_check` is `ok`.
- Consumer cutover tests passed: 20/20 canonical repository/valuation tests and
  122/122 affected legacy price, 13F, backtest and dividend regression tests.
- 339 private files from the old worktrees/backups collapse to 149 unique
  content hashes. Every one of those hashes is present in the canonical active
  store or the content-addressed recovery vault; missing unique hashes: 0.
- The retired directory set occupied 101,332,040 KiB (96.64 GiB) before
  deletion. Large directories were repeat market-price, strategy-repair,
  release, migration-source, or old application worktrees; none is an active
  canonical data root.

## Cleanup and verification result

- Removed 97,981,788 KiB (93.44 GiB) of non-private retired projects, release
  candidates, refresh trees, and repeated market/strategy data. The volume now
  has 318 GiB available.
- The complete server suite passes outside the restricted sandbox: 1,614
  passed, 0 failed, 1 intentionally skipped. The first sandboxed run produced
  only loopback-listener `EPERM` errors and was not treated as a product result.
- JavaScript syntax checks pass for the storage auditor and all Fact OS consumer
  modules changed during consolidation.
- The final layout audit is intentionally still blocked by three retired source
  worktrees and seven private-backup source folders. Their distinct private
  content is already preserved in the canonical active store/recovery vault,
  but the originals will not be permanently deleted without explicit approval.

Remaining retired source roots at the close of this pass:

- `fundamental-analysis/` — 2,435,968 KiB
- `fundamental-analysis-sp500/` — 18,604 KiB
- `guru-intelligence/` — 882,156 KiB
- seven `thesisforge-private-*` source backups — 13,524 KiB combined

Once deletion of those private-bearing originals is explicitly approved, remove
the exact audited paths and rerun `npm run audit:storage-layout`; no new copy or
intermediate archive should be created.

## Append-only rule

New upstream observations enter only through the Fact OS sync pipeline. Raw
responses are content-addressed; natural keys prevent repeated facts; derived
Parquet is immutable and published manifest-last. Experiments must pin the
manifest or use bounded temporary files. Creating another project/database
copy to append data is prohibited by `AGENTS.md` and
`scripts/audit-storage-layout.mjs`.

## Required recurring checks

```sh
npm run audit:fact-os
npm run audit:fact-os-storage
npm run audit:storage-layout
```

The final layout audit must report `pass`; any recreated retired sibling,
unexpected runtime database, or bulk database/Parquet artifact under docs or
outputs is a release blocker.
