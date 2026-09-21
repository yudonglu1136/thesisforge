# 13F Insights v3 performance

## Scope

- 60 cold reads and 60 warm reads per artifact.
- Same PIT date (`2026-09-18`), quarter (`2026-06-30`) and selected security (`MSFT`).
- Each cold sample opens a fresh read-only SQLite connection and includes JSON serialization.
- Each warm sample reuses one read-only connection and the bounded one-snapshot cache.

## Results

| Metric | Embedded-detail baseline | Lazy-detail v3 | Change |
| --- | ---: | ---: | ---: |
| Cold p50 | 1,318.10 ms | 33.53 ms | 97.46% faster |
| Cold p95 | 1,368.86 ms | 36.03 ms | 97.37% faster |
| Warm p50 | 43.87 ms | 17.52 ms | 60.06% faster |
| Warm p95 | 54.08 ms | 21.72 ms | 59.85% faster |
| Identity JSON | 3.55 MB | 3.83 MB | 7.96% larger due to market and normalized-change fields |
| Gzip JSON | 440 KB | 644 KB | 83.18% smaller than the v3 identity response |

The v3 artifact is larger on disk because it preserves eight quarters of per-security and per-filer drill-down rows in normalized append-only tables. Initial reads are materially faster because the summary endpoint no longer inflates the complete detail book; the selected security detail and history are read lazily.

## Validation

- Flutter desktop, 1280px and 390px responsive tests pass in English and Chinese.
- Runtime sidecar integrity, immutable-byte and natural-key validation tests pass.
- Repository performance contract passes all 60 tests.
- Production build and bilingual literal audit pass.

Raw measurements: `13f-insights-v3.json`.
