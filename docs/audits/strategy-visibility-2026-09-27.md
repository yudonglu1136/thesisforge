# Rule portfolio visibility recovery — 2026-09-27

## Evidence and cause

Read-only production probe `12bf4d6e-dbf9-4a22-b91f-e61045421c3d`
verified the actual code-bundled, validated dashboard snapshots as `webapp`:

| Universe | First observation | Last observation | Points | Snapshot SHA-256 |
| --- | --- | --- | ---: | --- |
| All | 2013-01-02 | 2026-09-21 | 3450 | f54f6a0727e6f56f5d6c01bf69f6a1d44cd4996617272e8d915b86a9a36da95b |
| S&P 500 | 2013-01-02 | 2026-09-21 | 3450 | 6c0b226a63084fb86e4b5a33c28f4d43c6212a8049a180fe34534bbdf66d32de |
| Nasdaq 100 / QQQ proxy | 2020-01-02 | 2026-09-21 | 1688 | 282819cf26b8d53de530d50e05f84808ad057644306f589d1f41d355c451f214 |

Canonical-mode routes unnecessarily queued a second, cutoff-keyed copy of an
already precomputed dashboard. Before that copy existed they returned HTTP 200
with `status:updating` and an empty curve. The current UI interpreted the empty
curve as no observed history and did not automatically refetch.
The production index contained a subsequently generated All-market copy,
consistent with this cold-request failure.

## Fix

Both production and local dashboard reads use the existing validated, cached
published-snapshot loader. This is not an on-request backtest or financial/price
database scan. Source-file changes invalidate the cache; cutoff slicing and
snapshot conflicts remain enforced. No fabricated or previously rejected curve
is introduced. Source hashes, curve values and data-through dates are unchanged.
The server no longer returns a misleading empty updating response for this route.

Range attribution remains independently protected by canonical-price replay and
compatible-cohort checks. This recovery does not certify the known
`rule_analysis_nav_mismatch` or resolve global Fact OS activation. An available
published curve is not proof of currently available stock P&L attribution.

## Checks

- New canonical-mode regression failed before the fix (500 rather than a
  verified published response when an unnecessary build was attempted).
- 35 Node tests passed across route authentication, all three universes, cutoff
  slicing, stale snapshots, snapshot validation, public artifacts, attribution,
  coverage, refresh and release isolation.
- 60 transport/performance tests passed.
- No frontend code changed. Existing date-range, metrics and chart UI is reused.
- No source data, user records, historical models, pricing or return formula
  changed. No sync, database copy, backtest rebuild or GC performed.

## Release

Deploy only the scoped committed change to the existing AWS backend; preserve
both Vercel aliases. Rollback version is `research-dcf-8b9421c`.
Detailed release identity and live response verification are retained in
`data/fact_os/audit/strategy-visibility-release-20260927.json`.
Production browser verification needs a signed-in session; no authentication
bypass is allowed. Global readiness failures remain separate and visible.
