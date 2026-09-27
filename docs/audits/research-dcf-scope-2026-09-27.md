# Research DCF release-scope repair — 2026-09-27

## Reproduced defect

The Research-only recovery activated verified canonical data for Research GETs,
but the existing calculate, worksheet-save and scenario-save POST URLs were
outside that route prefix. Their canonical quote prefetch used the unavailable
global release, raising `local_data_unavailable` before calculation.

Production read-only probe `3f9fea36-7e58-42fe-8b63-5d151f6d2970`, running as
`webapp`, reproduced the calculate failure. The same public PLTR inputs inside
the Research release calculated USD 31.950828819057723 per share; reverse
calculation reproduced the canonical price with residual 8.53e-14.
This is the personal FCFE template, not the published multi-method value.

## Repair and safeguards

Precisely allowlist the three POST paths in the existing request-pinned release
middleware. No model formula, historical value, user journal, input validation,
snapshot comparison, ownership check or authentication change. Other modules
and global activation remain untouched. Invalid Research manifests fail closed.

## Verification before release

- Regression test failed before the fix (global instead of Research generation).
- 81 Node tests passed: release context, market routes/context, investment
  workflow, including 5Y/10Y, reverse DCF, persistence and ownership safeguards.
- Final release-context rerun: 2 passed, including corrupted manifest rejection.
- Transport/performance suite: 60 passed.
- No Flutter/UI changes; the deployed frontend remains compatible.
- No source ingestion, database copy, activation, backtest or GC was performed.

## Rollout and limitations

Backend-only release from committed trunk. Preserve the current pinned Research
release `ee3a14209c96a9cec758c9472711bca34c47fb4ab46c3f810b7f1f56b7b2ff08`.
Rollback application version: `research-statements-999de00`; no user-data
rollback. Completed encrypted EBS recovery copy: `snap-00e5fa3158e0ddfcf`.
Post-deployment identity and live calculation checks are recorded in the local
`data/fact_os/audit/research-dcf-release-20260927.json` receipt.

Existing aggregate health failures (Guru simulation readiness/legacy prices),
global data activation blockers, unrelated Flutter failures and storage-layout
audit findings are not resolved or hidden by this narrowly scoped fix.
Authenticated browser interaction requires an existing signed-in user session;
server-level production checks are not a claim of that browser verification.
