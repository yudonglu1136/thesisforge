# 13F evidence and institution-trajectory experience

## Scope

This benchmark compares the prior split-normalized 13F artifact (`v7`) with
the behavior-research artifact (`v8`). Both runs used the same local machine,
runtime and bounded request (`asOf=2026-09-18`, `quarter=2026-06-30`,
`ticker=GOOGL`). Results are medians across three runs of 60 samples. This is a
local regression check, not a production latency claim.

## Result

- Cold p95: 37.05 ms to 32.43 ms (-12.48%).
- Cold p50: 27.03 ms to 26.56 ms (-1.73%).
- Warm p95: 0.097 ms to 0.119 ms (+0.022 ms absolute).
- Warm p50: 0.091 ms to 0.092 ms (+0.001 ms absolute).
- Response: 65,736 bytes to 64,546 bytes (-1.81%).
- Artifact: 177,000,448 bytes to 215,646,208 bytes (+21.83%).
- Critical cold-p95 regression gate (maximum 5%): pass.

The artifact grew because the top important changes now include bounded
eight-quarter institution trajectories and portfolio weights. The API still
loads only the selected security detail, and its cold response became faster
in this regression run. The warm percentage changes are large only because
both measurements are near one tenth of a millisecond.

## Correctness checks

- Complete comparable 13F population is evaluated before selecting important
  changes; the page is not deriving continuity from the old Top 50 rows.
- Shares in trajectories use the current split-adjusted share basis.
- Portfolio weight uses each filer's reported common-stock book, not fund AUM.
- Missing filer reports and reported zero positions remain distinct states.
- SQLite integrity: `ok`; duplicate snapshot/detail natural keys: 0.
- Artifact size is 205.7 MiB, below the 2 GiB deployment stop threshold.
