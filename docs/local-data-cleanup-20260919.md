# Local retired-data cleanup — 2026-09-19

Authorized scope: remove retired local data and generated experiment artifacts while preserving every private user-portfolio directory and the current Fact OS generation.

## Explicitly retained

- `data/fact_os/raw/`
- all Parquet paths referenced by `data/fact_os/manifests/catalog.json`
- `data/fact_os/fact_os.duckdb`, manifests, audit receipts and sync state
- `server/data/user-portfolios/`
- private portfolio directories in older worktrees
- the current mixed application database `server/data/guru-analysis.sqlite`, with its private `portfolio_nav_points` and still-published valuation/model/asset tables

## Removed as retired or regenerable

- unreferenced Fact OS Parquet rollback generations
- Fact OS legacy SQLite backup
- old Ontology, valuation-PIT source/migration, SEC Company Facts and official-PIT caches outside Fact OS
- regenerable server JSON caches and local output/build caches
- historical `guru-intelligence/output` experiment runs and copied candidate SQLite databases
- the partial Fact OS and legacy database/cache copies inside the old `guru-intelligence` worktree, excluding its private portfolio directory
- standalone historical market-refresh, Guru-addition, limited-release and packaged-release artifact directories
- generated data/build/cache copies in the old `fundamental-analysis-sp500` worktree, excluding its private portfolio directory

The current application database is compacted only by clearing tables documented by the accepted Fact OS migration as retired quantitative/derived caches. Published valuation/model artifacts, research/assets, and private NAV rows remain.

No production, AWS, Vercel, or current Fact OS raw/current-manifest file is part of this cleanup.

## Result

- Removed `guru-intelligence/output/` and `market-refresh-20260912/`; these contained repeated multi-gigabyte candidate SQLite databases.
- Removed standalone Guru-addition, limited-release and packaged-release artifact directories.
- Removed regenerable build/cache data from the old `guru-intelligence` and `fundamental-analysis-sp500` worktrees while preserving their private `user-portfolios/` directories.
- Removed the current project's unreferenced Parquet rollback generations, legacy backup, retired Ontology/valuation-PIT/SEC caches, and regenerable local caches/output.
- Current Fact OS validation after cleanup: 347 manifest references, 347 Parquet files, zero missing paths, zero unreferenced paths.
- Current application SQLite `PRAGMA quick_check`: `ok`; private `portfolio_nav_points` count remains 1.
- Free disk increased from 33 GiB to 225 GiB.

## Pending explicit authorization

The following were intentionally not modified because they can still be opened by old/current application code:

- old worktree partial `guru-intelligence/data/fact_os/` (about 601 MiB) and old worktree `server/data/guru-analysis.sqlite` (about 192 MiB), with its private sibling directory preserved separately;
- retired rows inside the current mixed `server/data/guru-analysis.sqlite`. Clearing them would modify the live compatibility database. Candidate tables are `price_points`, `dashboard_snapshots`, `guru_snapshots`, `guru_exposure_snapshots`, `guru_backtests`, `dividend_events`, `dbmf_snapshots`, `cache_revisions`, and `background_job_runs`.
