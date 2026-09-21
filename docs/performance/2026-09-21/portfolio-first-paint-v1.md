# Portfolio first-paint performance — 2026-09-21

## Finding

Portfolio used one blocking request for saved account data, legacy dashboard
analytics, full-market valuation models, Guru books, SPY risk history and a
Sharadar dividend RPC. A busy Fact OS queue could therefore keep the entire
page on its loading state.

## Change

- The client first requests `scope=summary` and renders verified holdings and
  portfolio-only valuation output.
- `scope=detail` loads risk, Guru comparisons and TTM dividends in the
  background. A failure preserves the already-rendered holdings.
- The analysis route no longer runs the older dashboard analytics before its
  own analysis.
- The summary valuation query is bounded to exact portfolio tickers.
- The Sharadar dividend enhancement has a 2.5 second response deadline so a
  shared Fact OS queue cannot block the complete detail response indefinitely.
- `Server-Timing` separates account read, analysis build and dividend time;
  requests over one second emit a structured aggregate warning without user
  identity or portfolio values.

## Reproducible local result

Command:

```sh
node scripts/benchmark-portfolio-first-paint.mjs --samples 60
```

Using the same 2026-09-20 release database and a fixed synthetic seven-stock
portfolio:

| Measure | Before | After |
|---|---:|---:|
| Cold median | 1,294.5 ms | 25.6 ms |
| Improvement | — | 98.0% |
| Warm summary median | — | 6.0 ms |
| Warm summary p95 | — | 6.6 ms |

This is a local read-only compute benchmark, not production network latency.
No private portfolio data is contained in the fixture or report. Raw results
are in `portfolio-first-paint-v1.json`.

## Verification

- Portfolio API and risk tests: 34 passed.
- Portfolio Flutter regression suite: 43 passed, including a deliberately
  unresolved detail request proving that the summary remains visible.
- Performance transport suite: 60 passed.
- Flutter static analysis: passed.
