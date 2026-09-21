# 13F split-normalized share history

## Scope

This benchmark compares the prior compact 13F artifact (`v4`) with the
split-normalized shares artifact (`v7`). Both runs used the same local machine,
runtime, request (`asOf=2026-09-18`, `quarter=2026-06-30`, `ticker=GOOGL`), and
three runs of 60 samples. The figures below are the median result across runs.
It is a local regression check, not a production latency claim.

## Result

- Cold p95: 30.96 ms to 31.88 ms (+2.96%).
- Cold p50: 24.57 ms to 26.50 ms (+7.86%).
- Warm p95: 0.112 ms to 0.097 ms (-12.85%).
- Response: 64,222 bytes to 65,736 bytes (+2.36%).
- Artifact: 175,616,000 bytes to 177,000,448 bytes (+0.79%).
- Critical cold-p95 regression gate (maximum 5%): pass.

The compact artifact stores one split factor per security-quarter and derives
the raw reported shares and common basis date at the API boundary. This avoids
duplicating those derivable fields across 171,697 history rows.

## Correctness checks

- SQLite integrity: `ok`.
- Natural-key duplicates: 0.
- GOOGL 2021/Q3 raw 13F shares: 439,144.3 thousand.
- GOOGL 2021/Q3 current-basis shares: 8,782,886.0 thousand (20:1 factor).
- GOOGL 2021/Q3 institutional ownership: 66.16%.
- GOOGL 2022/Q3 factor: 1 after the split became effective.

The calculation uses exact Sharadar `actions` rows with `action='split'` only;
it does not infer splits from price movements. Historical shares are multiplied
by the product of later split factors through the current share-basis date.
