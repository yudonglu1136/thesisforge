# Public daily source 503 recovery

## Outcome

The November 3 scheduler failed on holdings HTTP 503. Thirteen sources
succeeded, but canonical and institutional groups were blocked, so the website
correctly retained its previous complete release. Capacity was not the cause.

The authorized manual recovery completed and activated on November 4 Saudi
time (November 3 UTC). All fourteen sources are ready. Canonical, institutional
13F and strategy inputs rebuilt successfully; AI Insights, public observations
and Research inputs reused verified unchanged artifacts. Independent API reads
confirm Fundamentals, Research, public analysis and rule portfolios ready.

- Worker: `5057558-holdings-961226d`, commit `961226d2e84c76c010b889cdd3018a8a27d6c2cb`.
- Run: `c9ca1aa11930d6dfdd4a80f257a574ab214f313c2ac6cf5960a08ac1df98746b`.
- Serving release: `49ae8b523905e650dfc9490462247a0758830d0af69b07a28bc8ba86832f1803`.
- All/sp500/nasdaq100 curves and ledgers: through `2026-11-02`.
- QQQ benchmark remains present in the verified Nasdaq bundle.
- Actual API ACK, host pointer and published group generations match; bundle
  identity and each universe snapshot hash match the installation manifest.
- API free: 6,989,672,448 bytes; worker free: 9,434,296,320 bytes at final checks.
- Original daily schedule restored: ENABLED, 07:30 Asia/Riyadh, RunDocument 7.

This is manual recovery, not proof of the next scheduled execution. Independently
accept November 4's real `trigger=scheduler` run. Guru legacy curves/prices and
reviewed valuation warnings remain separate; this is not a whole-site health claim.

## Change

Source queries already had four attempts, but 5xx without Retry-After previously
waited about 1/2/4 seconds. Apply the existing shared 30/60/120-second cooldown to
500/502/503/504, respect bounded provider hints, and emit sanitized retry metadata.
Persistent holdings failures can subdivide after all attempts: dates first, then
verified exhaustive ticker ranges. Both halves cover the entire parent interval,
including symbols absent from discovery. Unsplittable scopes, auth/schema/429
errors and second-pass failures remain fatal. No publication gates were relaxed.

A fixed 10,000-row experiment produced 636 requests without a complete leaf after
roughly 30 minutes; it was cancelled, with code rollback and schedule restoration.
The final version retains normal 100,000-row holdings requests and subdivides only
saturated or persistently failing scopes. No partial trial changed serving data.

## Validation and preservation

Full Fact OS suite: 284 passed. Tests cover provider cooldowns, exhaustive range
coverage, indivisible failures and second-pass failure retaining accepted history.
The final manual run reused thirteen same-day verified source content versions,
then re-read only holdings. It verified 81 leaves / 5,786,581 range records twice
and rechecked ticker discovery. This is processed volume, not newly added rows.

Accepted holdings retain 82,096,521 rows from 2013-06-30 through 2026-09-30.
Same-input replay returned `unchanged`: content version, partitions, counts and
oldest/newest dates were unchanged. No database copies, historical cleanup,
capacity expansion, private jobs or old Research pointer restoration occurred.

Operational evidence: `data/fact_os/audit/source-recovery-adaptive-2026-11-03.json`,
including independent API command `974f7815-47b6-4584-99b2-23676f3f5ecc` and replay
command `d055dd75-f5d6-4baa-ab39-358bd8266b6e`. Failed/cancelled earlier trials are
retained as small receipts, not relabelled as successful runs.
