# Guru holdings first-paint optimization v2

Date: 2026-09-21  
Surface: Discover → Guru holdings & consensus  
Snapshot: `data/releases/thesisforge-20260920-v3/research.sqlite`  
Runtime: local Flutter web debug client + local Node API

## Problem verified

The ownership-only matrix endpoint was already fast, but the screen still made unrelated work part of first paint:

- `/api/investment/home` took 1.294 s and returned 38,601 bytes in the measured warm local run.
- `/api/investment/discover` took 1.210 s and returned 59,717 bytes.
- The off-screen style/performance panel immediately requested `/api/investment/guru-study`, then a Guru detail route, and built both scatter plots and the full directory.
- The selected company detail was requested in the same rendering turn as the matrix.
- The Guru matrix could not render its selected columns until the separate Discover catalog arrived.

## Change

1. The cacheable Guru matrix response now includes the compact, owner-scoped Guru directory needed by the first screen. The response remains private and varies by authorization.
2. Discover → Guru no longer starts the full Home or Discover requests.
3. Style/performance is mounted and requested only when the user chooses **Load comparison** or the existing rail CTA.
4. Selected-company detail starts 180 ms after matrix selection so the first frame gets priority.
5. The matrix contract is versioned as `guru-holdings-matrix-v2`; the client adds `bootstrap=guru-directory-v1` so a previously cached v1 response cannot produce an empty manager rail after rollout.

No holding, weight, quarter, action, or consensus calculation changed.

## User-perceived measurement

The same authenticated local snapshot, viewport, URL state, and DOM-ready condition were measured before and after. Ready means the 33-manager directory and current-quarter consensus rows are both interactive.

| Measurement | Before | After | Change |
| --- | ---: | ---: | ---: |
| Full navigation to useful Guru screen | 4,742 ms | 2,623 ms | **44.7% faster** |
| Off-screen style/performance work at first paint | Loaded | Deferred | Removed from critical path |

The production build will not include Flutter debug compilation overhead, so these numbers are intentionally a conservative local comparison rather than a production latency claim.

## API concurrency benchmark

Each run used 60 samples at concurrency 20 across 12 quarters. The median of three run-level p95 values is reported.

| Route implementation | Concurrent p95 |
| --- | ---: |
| Prior full Opportunities dependency | 14,564.4 ms |
| Ownership-only Guru matrix | 177.3 ms |
| Improvement | **98.8%** |

All 180 baseline/candidate response pairs had identical ownership semantic hashes.

Artifacts:

- `guru-holdings-v2-run-1.json`
- `guru-holdings-v2-run-2.json`
- `guru-holdings-v2-run-3.json`

## Transport verification

- Identity response: 858,501 bytes
- Gzip response: 87,209 bytes
- Wire reduction: 89.8%
- `Cache-Control: private, max-age=300, stale-while-revalidate=3600`
- `Vary: Authorization, Origin, Accept-Encoding`
- Matching ETag returned HTTP 304

## Verification

- `flutter test test/investment_guru_holdings_test.dart test/investment_guru_study_test.dart`
- `node --test server/investmentOpportunities.test.js server/investmentWorkflow.test.js`
- `npm run test:performance`
- `npm run audit:i18n`
- `flutter analyze`
- `npm run build`
- Browser visual verification at desktop; widget coverage at 1280 px and 390 px, including enlarged text and English/Chinese variants.

All listed checks passed.
